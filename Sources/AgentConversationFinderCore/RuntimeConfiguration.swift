import Foundation

/// Paths are configuration, never embedded account identifiers or credentials.
public struct RuntimeConfiguration: Sendable {
    public var codexHome: URL
    public var secondaryCodexHome: URL?
    public var claudeHome: URL
    public var stateDirectory: URL
    public var codexExecutable: String
    public var claudeExecutable: String

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        codexHome = homeDirectory.appendingPathComponent(".codex")
        secondaryCodexHome = nil
        claudeHome = homeDirectory.appendingPathComponent(".claude")
        stateDirectory = homeDirectory.appendingPathComponent("Library/Application Support/Agent Conversation Finder Shared")
        codexExecutable = "codex"
        claudeExecutable = "claude"
    }

    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> RuntimeConfiguration {
        var result = RuntimeConfiguration(homeDirectory: homeDirectory)
        let configPath = environment["ACF_CONFIG"] ?? result.stateDirectory.appendingPathComponent("config.json").path
        let configURL = try path(configPath, homeDirectory: homeDirectory)
        var fields: [String: String] = [:]
        if FileManager.default.fileExists(atPath: configURL.path) {
            fields = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: configURL))
        } else if environment["ACF_CONFIG"] != nil {
            throw ConfigurationError.invalid("ACF_CONFIG points to a missing file")
        }
        let mapping = [
            "codexHome": "ACF_CODEX_HOME", "secondaryCodexHome": "ACF_SECONDARY_CODEX_HOME",
            "claudeHome": "ACF_CLAUDE_HOME", "stateDirectory": "ACF_STATE_DIR",
            "codexExecutable": "ACF_CODEX_EXECUTABLE", "claudeExecutable": "ACF_CLAUDE_EXECUTABLE"
        ]
        for key in fields.keys where mapping[key] == nil {
            throw ConfigurationError.invalid("Unknown configuration key: \(key)")
        }
        for (key, variable) in mapping {
            if let value = environment[variable] { fields[key] = value }
        }
        if let value = fields["codexHome"] { result.codexHome = try path(value, homeDirectory: homeDirectory) }
        if let value = fields["secondaryCodexHome"], !value.isEmpty {
            result.secondaryCodexHome = try path(value, homeDirectory: homeDirectory)
        }
        if let value = fields["claudeHome"] { result.claudeHome = try path(value, homeDirectory: homeDirectory) }
        if let value = fields["stateDirectory"] { result.stateDirectory = try path(value, homeDirectory: homeDirectory) }
        for key in ["codexExecutable", "claudeExecutable"] {
            guard let value = fields[key] else { continue }
            guard !value.isEmpty, !value.contains("\n") else {
                throw ConfigurationError.invalid("\(key) must be one executable name or absolute path")
            }
            let executable = value.contains("/") ? try path(value, homeDirectory: homeDirectory).path : value
            if key == "codexExecutable" { result.codexExecutable = executable }
            else { result.claudeExecutable = executable }
        }
        if result.secondaryCodexHome?.resolvingSymlinksInPath() == result.codexHome.resolvingSymlinksInPath() {
            throw ConfigurationError.invalid("Primary and secondary Codex homes must differ")
        }
        return result
    }

    public func codexHome(for route: CommandRoute) -> URL {
        route == .codexSecondary ? (secondaryCodexHome ?? codexHome) : codexHome
    }

    // Distinct source roots must never reuse another account's cached records or aliases.
    public var profileStateDirectory: URL {
        let identity = [codexHome.path, secondaryCodexHome?.path ?? "", claudeHome.path].joined(separator: "\n")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in identity.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return stateDirectory.appendingPathComponent("profiles/" + String(hash, radix: 16))
    }

    public func resolvedCodexExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let candidates: [String]
        if codexExecutable.contains("/") { candidates = [codexExecutable] }
        else {
            let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
                + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
            candidates = paths.map { URL(fileURLWithPath: $0).appendingPathComponent(codexExecutable).path }
                + (codexExecutable == "codex" ? ["/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex"] : [])
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map { URL(fileURLWithPath: $0) }
    }

    private static func path(_ value: String, homeDirectory: URL) throws -> URL {
        let expanded: String
        if value == "~" { expanded = homeDirectory.path }
        else if value.hasPrefix("~/") { expanded = homeDirectory.appendingPathComponent(String(value.dropFirst(2))).path }
        else { expanded = value }
        guard expanded.hasPrefix("/"), !expanded.contains("\n") else {
            throw ConfigurationError.invalid("Paths must be absolute or start with ~/")
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}

public enum ConfigurationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case let .invalid(message): return message }
    }
}
