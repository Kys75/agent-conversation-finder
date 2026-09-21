import Foundation

public enum ConversationTimeRange: String, CaseIterable, Identifiable {
    case all
    case last7Days
    case last30Days
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "全部时间"
        case .last7Days: return "最近 7 天"
        case .last30Days: return "最近 30 天"
        case .custom: return "自定义"
        }
    }
}

public struct ConversationFilter {
    public var selectedSources: Set<ConversationSource>
    public var environment: ConversationEnvironment?
    public var timeRange: ConversationTimeRange
    public var customStart: Date
    public var customEnd: Date
    public var folderQuery: String
    public var includeArchived: Bool
    public var includePlaceholderFolders: Bool

    public init(
        selectedSources: Set<ConversationSource> = [.codexCLI, .claudeCode],
        environment: ConversationEnvironment? = nil,
        timeRange: ConversationTimeRange = .all,
        customStart: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date(),
        customEnd: Date = Date(),
        folderQuery: String = "",
        includeArchived: Bool = false,
        includePlaceholderFolders: Bool = false
    ) {
        self.selectedSources = selectedSources
        self.environment = environment
        self.timeRange = timeRange
        self.customStart = customStart
        self.customEnd = customEnd
        self.folderQuery = folderQuery
        self.includeArchived = includeArchived
        self.includePlaceholderFolders = includePlaceholderFolders
    }

    public func apply(
        to records: [ConversationRecord],
        now: Date = Date(),
        sort: ConversationSort = .lastActivityDescending
    ) -> [ConversationRecord] {
        sort.sorted(records.filter { record in
            if !includeArchived && record.archived { return false }
            if !selectedSources.contains(record.source) { return false }
            if !includePlaceholderFolders && Self.isPlaceholderFolder(record.workingDirectory) {
                return false
            }
            if let environment, record.environment != environment { return false }

            let query = folderQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty && record.workingDirectory.localizedCaseInsensitiveContains(query) == false {
                return false
            }

            switch timeRange {
            case .all:
                break
            case .last7Days:
                if record.lastConversationAt < now.addingTimeInterval(-7 * 86_400) { return false }
            case .last30Days:
                if record.lastConversationAt < now.addingTimeInterval(-30 * 86_400) { return false }
            case .custom:
                let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: customEnd)) ?? customEnd
                if record.lastConversationAt < Calendar.current.startOfDay(for: customStart) || record.lastConversationAt >= endOfDay {
                    return false
                }
            }

            return true
        })
    }

    public static func isPlaceholderFolder(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return name.range(
            of: #"^new[\s_-]*chat(?:[\s_-]*\d+)?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
