//
//  RunCommandIntent.swift
//  iSH
//

import Foundation

#if canImport(AppIntents)
import AppIntents

@available(iOS 16.0, *)
struct RunCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "在 iSH 中运行脚本"
    static var description = IntentDescription("在 iSH Linux 环境中执行 Shell 脚本，任务期间自动开启音频保活。")

    // Run in background without forcing the app to open into foreground
    static var openAppWhenRun: Bool = false

    @Parameter(title: "脚本 / 命令", description: "需要执行的 Shell 命令或脚本")
    var command: String

    @Parameter(title: "工作目录", description: "执行命令的工作路径，默认 /root", default: "/root")
    var workingDirectory: String?

    @Parameter(title: "超时时间 (秒)", description: "最长等待执行时间，默认 300 秒", default: 300)
    var timeoutSeconds: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("在 iSH 中运行 \(\.$command)") {
            \.$workingDirectory
            \.$timeoutSeconds
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let timeout = Double(timeoutSeconds ?? 300)
        let cwd = (workingDirectory?.isEmpty == false) ? workingDirectory : "/root"

        let resultString: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            CommandRunner.shared().runCommand(command, cwd: cwd, timeout: timeout) { exitCode, output, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: output ?? "")
                }
            }
        }
        return .result(value: resultString)
    }
}

@available(iOS 16.0, *)
struct iSHShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunCommandIntent(),
            phrases: [
                "在 \(.applicationName) 中运行脚本",
                "在 \(.applicationName) 中执行命令"
            ],
            shortTitle: "运行脚本",
            systemImageName: "terminal"
        )
    }
}
#endif
