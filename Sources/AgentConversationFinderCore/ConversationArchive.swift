import Foundation

public struct ArchiveProcessRequest: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environmentOverrides: [String: String]

    public init(
        executableURL: URL,
        arguments: [String],
        environmentOverrides: [String: String]
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environmentOverrides = environmentOverrides
    }
}

public enum ConversationArchiveStrategy: Equatable, Sendable {
    case codex(ArchiveProcessRequest)
    case localOnly
}

public enum ConversationArchivePlanner {
    public static func strategy(
        for record: ConversationRecord,
        shouldArchive: Bool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexExecutableURL: URL,
        configuration: RuntimeConfiguration? = nil
    ) throws -> ConversationArchiveStrategy {
        guard record.route != .claude else { return .localOnly }

        guard !record.sessionID.isEmpty, !record.sessionID.hasPrefix("-") else {
            throw ConfigurationError.invalid("Invalid session identifier")
        }
        let codexHomeName: String
        switch record.route {
        case .codexOpenAI:
            codexHomeName = ".codex"
        case .codexSecondary:
            codexHomeName = ".codex-secondary"
        case .claude:
            return .localOnly
        }

        return .codex(
            ArchiveProcessRequest(
                executableURL: codexExecutableURL,
                arguments: [shouldArchive ? "archive" : "unarchive", record.sessionID],
                environmentOverrides: [
                    "CODEX_HOME": configuration?.codexHome(for: record.route).path ?? homeDirectory.appendingPathComponent(codexHomeName).path
                ]
            )
        )
    }


}

public enum ArchiveProcessExecutor {
    public static func run(_ request: ArchiveProcessRequest) throws {
        guard FileManager.default.isExecutableFile(atPath: request.executableURL.path) else {
            throw ConversationArchiveError.missingExecutable(request.executableURL.path)
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConversationFinderArchive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("stdout")
        let errorURL = temporaryDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)

        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            request.environmentOverrides,
            uniquingKeysWith: { _, override in override }
        )
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? outputHandle.close()
            try? errorHandle.close()
            throw error
        }
        try outputHandle.close()
        try errorHandle.close()

        guard process.terminationStatus == 0 else {
            let standardError = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let standardOutput = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = standardError.isEmpty ? standardOutput : standardError
            throw ConversationArchiveError.commandFailed(
                status: process.terminationStatus,
                detail: detail
            )
        }
    }
}

public struct ConversationLocalArchiveStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
            self.fileURL = applicationSupport
                .appendingPathComponent("Agent Conversation Finder", isDirectory: true)
                .appendingPathComponent("local-archives-v1.json")
        }
    }

    public func load() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return Set(try JSONDecoder().decode(Payload.self, from: data).archivedStorageKeys)
    }

    public func save(_ archivedStorageKeys: Set<String>) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let payload = Payload(
            schemaVersion: 1,
            archivedStorageKeys: archivedStorageKeys.sorted()
        )
        let data = try JSONEncoder().encode(payload)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let archivedStorageKeys: [String]
    }
}

public enum ConversationArchiveError: LocalizedError {
    case missingExecutable(String)
    case commandFailed(status: Int32, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .missingExecutable(path):
            return "找不到可执行的 Codex 程序（\(path)）"
        case let .commandFailed(status, detail):
            if detail.isEmpty { return "Codex 归档命令失败（退出码 \(status)）" }
            return "Codex 归档命令失败（退出码 \(status)）：\(detail)"
        }
    }
}
