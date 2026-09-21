import Foundation

public enum CommandGenerator {
    public static func command(for record: ConversationRecord, configuration: RuntimeConfiguration = RuntimeConfiguration()) -> String? {
        guard !record.sessionID.hasPrefix("-"), !record.sessionID.isEmpty,
              record.workingDirectory.hasPrefix("/") else { return nil }
        let directory = shellQuote(record.workingDirectory)
        let sessionID = shellQuote(record.sessionID)

        switch record.route {
        case .codexOpenAI, .codexSecondary:
            guard record.source == .codexCLI else { return nil }
            let executable = shellQuote(configuration.codexExecutable)
            let codex = "env CODEX_HOME=\(shellQuote(configuration.codexHome(for: record.route).path)) \(executable)"
            if record.archived {
                return "\(codex) unarchive \(sessionID) && \(codex) -C \(directory) resume \(sessionID)"
            }
            return "\(codex) -C \(directory) resume \(sessionID)"
        case .claude:
            return "(cd -- \(directory) && env CLAUDE_CONFIG_DIR=\(shellQuote(configuration.claudeHome.path)) \(shellQuote(configuration.claudeExecutable)) --resume \(sessionID))"
        }
    }

    public static func recoveryGuidance(for record: ConversationRecord) -> String? {
        guard record.route == .codexOpenAI, record.source == .codexApp else { return nil }
        return "该会话属于 OpenAI Codex 本地环境，请前往 Codex App 的历史会话中查找并继续。"
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
