import Foundation

public enum ConversationSource: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case codexApp
    case codexCLI
    case claudeCode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codexApp: return "Codex App"
        case .codexCLI: return "Codex CLI"
        case .claudeCode: return "Claude Code"
        }
    }
}

public enum ConversationEnvironment: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case openAI
    case secondary
    case claude

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .secondary: return "Secondary"
        case .claude: return "Claude"
        }
    }
}

public enum ConversationIntegrity: String, Codable, Hashable, Sendable {
    case complete
    case partial
    case missingTranscript

    public var displayName: String {
        switch self {
        case .complete: return "完整"
        case .partial: return "部分记录无法读取"
        case .missingTranscript: return "记录文件缺失"
        }
    }
}

public enum ConversationActivitySource: String, Codable, Hashable, Sendable {
    case transcript
    case history
    case database
    case file

    public var displayName: String {
        switch self {
        case .transcript: return "会话正文"
        case .history: return "历史索引"
        case .database: return "数据库"
        case .file: return "文件时间"
        }
    }
}

public enum CommandRoute: String, Codable, Hashable, Sendable {
    case codexOpenAI
    case codexSecondary
    case claude
}

public struct ConversationRecord: Codable, Hashable, Identifiable, Sendable {
    public let sessionID: String
    public let storageKey: String
    public var title: String
    public var workingDirectory: String
    public let source: ConversationSource
    public let environment: ConversationEnvironment
    public var createdAt: Date
    public var lastConversationAt: Date
    public var recentUserMessages: [String]
    public var digest: ConversationDigest?
    public var lastActivitySource: ConversationActivitySource?
    public var databaseUpdatedAt: Date?
    public var transcriptUpdatedAt: Date?
    public var historyUpdatedAt: Date?
    public var transcriptFileModifiedAt: Date?
    public var archived: Bool
    public var integrity: ConversationIntegrity
    public let route: CommandRoute
    public var workingDirectoryExists: Bool

    public var id: String { storageKey }

    public init(
        sessionID: String,
        storageKey: String,
        title: String,
        workingDirectory: String,
        source: ConversationSource,
        environment: ConversationEnvironment,
        createdAt: Date,
        lastConversationAt: Date,
        recentUserMessages: [String],
        digest: ConversationDigest? = nil,
        lastActivitySource: ConversationActivitySource? = nil,
        databaseUpdatedAt: Date? = nil,
        transcriptUpdatedAt: Date? = nil,
        historyUpdatedAt: Date? = nil,
        transcriptFileModifiedAt: Date? = nil,
        archived: Bool,
        integrity: ConversationIntegrity,
        route: CommandRoute,
        workingDirectoryExists: Bool
    ) {
        self.sessionID = sessionID
        self.storageKey = storageKey
        self.title = title
        self.workingDirectory = workingDirectory
        self.source = source
        self.environment = environment
        self.createdAt = createdAt
        self.lastConversationAt = lastConversationAt
        self.recentUserMessages = Array(recentUserMessages.suffix(3))
        self.digest = digest
        self.lastActivitySource = lastActivitySource
        self.databaseUpdatedAt = databaseUpdatedAt
        self.transcriptUpdatedAt = transcriptUpdatedAt
        self.historyUpdatedAt = historyUpdatedAt
        self.transcriptFileModifiedAt = transcriptFileModifiedAt
        self.archived = archived
        self.integrity = integrity
        self.route = route
        self.workingDirectoryExists = workingDirectoryExists
    }
}

public struct ConversationCache: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let refreshedAt: Date
    public let records: [ConversationRecord]
    public let warnings: [String]

    public init(
        schemaVersion: Int = 2,
        refreshedAt: Date,
        records: [ConversationRecord],
        warnings: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.refreshedAt = refreshedAt
        self.records = records
        self.warnings = warnings
    }
}

public struct ScanOutcome: Sendable {
    public let records: [ConversationRecord]
    public let warnings: [String]

    public init(records: [ConversationRecord], warnings: [String] = []) {
        self.records = records
        self.warnings = warnings
    }
}
