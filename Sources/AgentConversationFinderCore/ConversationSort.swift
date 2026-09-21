import Foundation

public enum ConversationSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case lastActivityDescending
    case lastActivityAscending
    case createdDescending
    case createdAscending
    case titleAscending
    case workingDirectoryAscending

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lastActivityDescending: return "最后对话：新到旧"
        case .lastActivityAscending: return "最后对话：旧到新"
        case .createdDescending: return "创建时间：新到旧"
        case .createdAscending: return "创建时间：旧到新"
        case .titleAscending: return "标题：A 到 Z"
        case .workingDirectoryAscending: return "工作目录：A 到 Z"
        }
    }

    public func sorted(_ records: [ConversationRecord]) -> [ConversationRecord] {
        records.sorted(by: isOrderedBefore)
    }

    public func isOrderedBefore(_ lhs: ConversationRecord, _ rhs: ConversationRecord) -> Bool {
        let primary: ComparisonResult
        switch self {
        case .lastActivityDescending:
            primary = rhs.lastConversationAt.compare(lhs.lastConversationAt)
        case .lastActivityAscending:
            primary = lhs.lastConversationAt.compare(rhs.lastConversationAt)
        case .createdDescending:
            primary = rhs.createdAt.compare(lhs.createdAt)
        case .createdAscending:
            primary = lhs.createdAt.compare(rhs.createdAt)
        case .titleAscending:
            primary = lhs.title.localizedStandardCompare(rhs.title)
        case .workingDirectoryAscending:
            primary = lhs.workingDirectory.localizedStandardCompare(rhs.workingDirectory)
        }

        if primary != .orderedSame { return primary == .orderedAscending }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.storageKey < rhs.storageKey
    }
}

public enum ConversationActivity {
    public static func latest(
        transcript: Date? = nil,
        history: Date? = nil,
        database: Date? = nil,
        file: Date? = nil,
        fallback: Date
    ) -> (date: Date, source: ConversationActivitySource?) {
        let semanticCandidates: [(Date?, ConversationActivitySource)] = [
            (transcript, .transcript),
            (history, .history),
            (database, .database)
        ]
        let available = semanticCandidates.compactMap { date, source in date.map { ($0, source) } }
        if let latest = available.max(by: { $0.0 < $1.0 }) {
            return latest
        }
        if let file { return (file, .file) }
        return (fallback, nil)
    }
}
