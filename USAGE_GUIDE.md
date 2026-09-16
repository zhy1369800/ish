# iSH 快捷指令脚本执行与自动化使用指南

本文档全面介绍 iSH 新增的**快捷指令 (App Intent)**、**URL Scheme** 调用机制、**音频无声保活**以及**结合 tmux 打造 Agent 自动化闭环**的最佳实践。

---

## 目录
1. [功能概览](#1-功能概览)
2. [方式一：iOS 快捷指令 (App Intent)](#2-方式一ios-快捷指令-app-intent)
3. [方式二：URL Scheme (`ish://`) 调用](#3-方式二url-scheme-ish-调用)
4. [Linux 内核设备：`/dev/keepalive` 使用指南](#4-linux-内核设备devkeepalive-使用指南)
5. [深度结合：Tmux 驱动的 Agent 自动化闭环](#5-深度结合tmux-驱动的-agent-自动化闭环)
6. [常见问题与避坑提示](#6-常见问题与避坑提示)

---

## 1. 功能概览

```
┌──────────────────────────────────────────────────────────┐
│                   触发源 (Trigger Sources)               │
│  - iOS 快捷指令自动化 (Shortcuts App Intent)              │
│  - 第三方 Agent App (URL Scheme: ish://run)              │
│  - 系统通知推送 / 定时任务                                │
└────────────────────────────┬─────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────┐
│                     iSH CommandRunner                    │
│  1. beginKeepAlive() 自动启动无声音频混音保活             │
│  2. 挂载 /dev/pts/N 独立 PTY 虚拟终端                    │
│  3. fork init_child & execve("/bin/sh", "-c", cmd)       │
│  4. 捕获命令输出与退出码 (ExitCode)                       │
│  5. endKeepAlive() 任务完成，无任务时立即停用音频释放资源 │
└────────────────────────────┬─────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────┐
│                     执行目标环境                         │
│  - 直接轻量命令 (如 git pull, apk update, python script) │
│  - tmux 会话 (实现后台持久化、多步交互、抓屏决策)        │
└──────────────────────────────────────────────────────────┘
```

- **按需保活 (On-Demand Keep-Alive)**：无需任何后台配置，每次执行命令时自动开启无声音频循环播放，命令结束即刻停止，兼顾**无限后台运行时长**与**超低功耗**。
- **完全后台静默 (Background Execution)**：`openAppWhenRun = false`，不切前台、不弹窗打扰用户当前操作。

---

## 2. 方式一：iOS 快捷指令 (App Intent)

适用于：**iOS 16+ 系统的快捷指令 App、系统自动化触发器（如特定时间、连接 Wi-Fi、收到特定通知等）。**

### 2.1 参数说明

在快捷指令中搜索动词：**`在 iSH 中运行脚本`** 或 **`运行脚本`**。

| 参数名称 | 类型 | 必填 | 默认值 | 说明 |
| :--- | :--- | :---: | :---: | :--- |
| **脚本 / 命令** (`command`) | 文本 | **是** | - | 要在 iSH 终端中执行的完整 Shell 命令或脚本路径 |
| **工作目录** (`workingDirectory`) | 文本 | 否 | `/root` | 执行该命令的起始路径（相当于 `cd <path>`） |
| **超时时间 (秒)** (`timeoutSeconds`) | 整数 | 否 | `300` | 超时自动发 `SIGKILL` 强杀子进程并返回错误，防卡死 |

### 2.2 返回值
- **类型**：字符串（`String`）。
- **内容**：命令的标准输出（stdout）及标准错误（stderr）完整合并结果。

### 2.3 典型场景示例

#### 场景 2.3.1：拉取 Git 仓库并执行 Python 脚本
```sh
cd /root/my_agent && git pull && python3 main.py
```

#### 场景 2.3.2：备份特定配置文件到 iCloud 挂载目录
```sh
tar -czf /root/backup-$(date +%Y%m%d).tar.gz /root/configs
```

---

## 3. 方式二：URL Scheme (`ish://`) 调用

适用于：**第三方 App（如你自研的 Agent App）、Scriptable、Pythonista 或任何能发起 URL 跳转的应用。**

### 3.1 标准模式：`ish://run`

不关心回调，快速异步派发任务。

```
ish://run?cmd=<URL_ENCODED_COMMAND>&cwd=<DIR>&timeout=<SECONDS>
```

#### 参数说明：
- `cmd` 或 `command` (必填)：需经过 **URL Percent-Encoding** 编码的命令。
- `cwd` 或 `dir` (可选)：工作目录，默认为 `/root`。
- `timeout` (可选)：超时秒数，默认 `300`。

#### 示例：
```
ish://run?cmd=echo%20%22Hello%20Agent%22%20%3E%20%2Ftmp%2Ftest.log
```

---

### 3.2 回调模式：`ish://x-callback-url/run`

支持遵循 [x-callback-url 规范](http://x-callback-url.com/) 的全自动响应闭环。

```
ish://x-callback-url/run?cmd=<COMMAND>&x-success=<CALLBACK_URL>&x-error=<ERROR_CALLBACK_URL>
```

#### 回调回传参数：
- **执行成功 (`x-success`)**：
  - `output`：命令输出内容
  - `exitCode`：退出码（成功通常为 `0`）
- **执行失败或超时 (`x-error`)**：
  - `errorMessage`：错误描述（如 "Command timed out after 300.0 seconds"）
  - `errorCode`：错误代号

#### 示例（配合你自己的 Agent App）：
```
ish://x-callback-url/run?cmd=uptime&x-success=myagent%3A%2F%2Fcmd-done
```
iSH 执行完成后，系统会自动打开：
```
myagent://cmd-done?output=12%3A34%3A56%20up%201%20day...&exitCode=0
```

> ⚠️ **注意**：URL 中的参数（尤其是 `cmd` 和回调 URL）必须使用 URL 编码，避免命令内的 `&`、`=`、空格干扰 URL 解析。

---

## 4. Linux 内核设备：`/dev/keepalive` 使用指南

我们在 iSH 虚拟内核中挂载了 `/dev/keepalive`（动态主设备号 240，次设备号 2）。在 Alpine Linux 内部，任何 Shell 脚本都可以**直接控制与查询宿主机的音频保活状态**。

### 4.1 读取当前保活状态
```sh
cat /dev/keepalive
```
- 返回 `1`：当前正在运行无声音频保活（有活跃任务）。
- 返回 `0`：处于闲置省电模式（未启用保活）。

### 4.2 手动控制保活（适用于长时间运行的自主脚本）

如果你在 iSH 里用 `nohup` 或前台运行了一个需要连续跑几个小时的任务（如大规模编译、下载数据集、自建本地服务）：

#### 开启保活：
```sh
echo 1 > /dev/keepalive
# 或者
echo start > /dev/keepalive
# 或者
echo on > /dev/keepalive
```

#### 关闭保活：
```sh
echo 0 > /dev/keepalive
# 或者
echo stop > /dev/keepalive
# 或者
echo off > /dev/keepalive
```

> 💡 **原理提示**：底层采用引用计数管理。快捷指令每次执行命令会自动 +1/-1。通过 `/dev/keepalive` 手动写入也会安全增减计数，即使快捷指令的任务先结束，只要你手动加过计数，保活就不会被关闭。

---

## 5. 深度结合：Tmux 驱动的 Agent 自动化闭环

由于快捷指令的 `RunCommandIntent` 执行的是非交互式命令（类似 `ssh host "cmd"`），当遇到需要输入 `y/n`、输入密码或进行长流程交互时，**直接运行会卡死或直接退出**。

**最佳解法：使用 `tmux` 作为会话调度中心。**

### 5.1 架构设计
```
┌────────────────────────────────────────────────────────┐
│                        Agent 决策层                    │
│      (外部 Agent App / LLM 核心 / 通知自动化中心)      │
└───────────────▲────────────────────────┬───────────────┘
                │                        │
       抓屏感知 │ tmux capture-pane      │ 下发指令 tmux send-keys
                │                        │
┌───────────────┴────────────────────────▼───────────────┐
│                    iSH 终端运行环境                     │
│                                                        │
│  [tmux session: "agent"]                               │
│  ┌──────────────────────────────────────────────────┐  │
│  │ 窗口: worker                                     │  │
│  │ 正在运行交互式程序 (例如 apt-get / apk / python) │  │
│  │ 提示: "Do you want to continue? [Y/n]"            │  │
│  └──────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────┘
```

---

### 5.2 完整命令模板速查

#### 步骤 1：初始化常驻 tmux 会话（幂等，若已存在则忽略）
```sh
tmux has-session -t agent 2>/dev/null || tmux new-session -d -s agent -n worker
```

#### 步骤 2：向 tmux 会话派发执行命令
```sh
# 建议：将退出状态码顺便保存到临时文件，方便事后检测
tmux send-keys -t agent:worker "apk add --no-cache curl; echo \$? > /tmp/last_code" Enter
```

#### 步骤 3：Agent 捕获屏幕当前输出（感知环境，LLM 抓屏）
```sh
# 抓取当前面板最后 20 行内容
tmux capture-pane -t agent:worker -p -S -20
```

#### 步骤 4：Agent 决策后自动回复（例如确认 y/n 或密码）
使用 `-l` 参数（literal 文本，防止转义字符被破坏）：
```sh
tmux send-keys -t agent:worker -l "y"
tmux send-keys -t agent:worker Enter
```

#### 步骤 5：检测当前程序是否执行完毕
```sh
# 查看当前正在跑的程序名，如果是 sh / ash / bash 则说明脚本已经跑完，等待新命令
tmux display-message -t agent:worker -p '#{pane_current_command}'
```

#### 步骤 6：读取真实退出码
```sh
cat /tmp/last_code
```

---

### 5.3 进阶：自动化脚本封装示例

你可以在 iSH 的 `/usr/local/bin/agent-exec` 放置如下轻量调度脚本：

```sh
#!/bin/sh
# /usr/local/bin/agent-exec
CMD="$1"

# 确保 tmux 会话存在
tmux has-session -t agent 2>/dev/null || tmux new-session -d -s agent -n worker

# 清除旧状态
rm -f /tmp/agent_status /tmp/agent_output

# 执行命令并重定向输出同时保留退出码
tmux send-keys -t agent:worker "$CMD > /tmp/agent_output 2>&1; echo \$? > /tmp/agent_status" Enter
```

这样你的快捷指令只需触发：
```sh
agent-exec "git pull && make"
```
外部 Agent 可以随时通过 `cat /tmp/agent_output` 和 `cat /tmp/agent_status` 查询当前状态，完全不阻塞快捷指令通道！

---

## 6. 常见问题与避坑提示

### Q1: 快捷指令执行返回“iSH kernel is not yet running”？
- **原因**：iSH 刚刚冷启动或被系统完全杀掉过，Linux 内核与 PID 1 (init) 初始化需要约 1~2 秒。
- **现状**：代码中已经内置了 5 秒的冷启动自动轮询重试机制（50 次 × 100ms），绝大多数情况下能自动平滑等待启动完成。

### Q2: 命令输出太大，快捷指令卡死或内存暴涨？
- **建议**：快捷指令适合传递**几十 KB 以内**的文本摘要。若执行如 `find /` 或全量 `apk upgrade` 等海量日志任务，请务必在命令后加上重定向：
  ```sh
  my_long_script.sh > /root/run.log 2>&1
  ```
  然后仅 `echo "Task started, see /root/run.log"`。

### Q3: 为什么不需要担心系统杀后台？
- 只要有命令在执行，`AudioKeepAliveManager` 就会向系统申请激活 `AVAudioSessionCategoryPlayback` 并循环播放不可闻的 16-bit PCM 静音音轨。
- 只要 iOS 没有遭遇严重的整机内存告急（Jetsam OOM），后台任务可以持续执行直到完成。
