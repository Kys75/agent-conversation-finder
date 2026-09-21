import XCTest
@testable import AgentConversationFinderCore

final class ConversationFilterTests: XCTestCase {
    func testAllowsAnyCombinationOfSelectedSources() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let records = [
            record("app", source: .codexApp, environment: .openAI, cwd: "/A", date: now),
            record("cli", source: .codexCLI, environment: .secondary, cwd: "/B", date: now),
            record("claude", source: .claudeCode, environment: .claude, cwd: "/C", date: now)
        ]

        var filter = ConversationFilter()
        filter.selectedSources = [.codexApp, .claudeCode]

        XCTAssertEqual(
            Set(filter.apply(to: records, now: now).map(\.sessionID)),
            Set(["app", "claude"])
        )
    }

    func testFiltersSourceEnvironmentFolderTimeAndArchives() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let records = [
            record("app", source: .codexApp, environment: .openAI, cwd: "/A", date: now, archived: false),
            record("cli", source: .codexCLI, environment: .secondary, cwd: "/B", date: now.addingTimeInterval(-8 * 86_400), archived: false),
            record("old", source: .codexCLI, environment: .openAI, cwd: "/A/old", date: now, archived: true)
        ]

        var filter = ConversationFilter()
        filter.selectedSources = [.codexApp]
        XCTAssertEqual(filter.apply(to: records, now: now).map(\.sessionID), ["app"])

        filter = ConversationFilter()
        filter.environment = .secondary
        XCTAssertEqual(filter.apply(to: records, now: now).map(\.sessionID), ["cli"])

        filter = ConversationFilter()
        filter.folderQuery = "/A"
        filter.includeArchived = true
        filter.selectedSources = Set(ConversationSource.allCases)
        XCTAssertEqual(Set(filter.apply(to: records, now: now).map(\.sessionID)), Set(["app", "old"]))

        filter = ConversationFilter()
        filter.timeRange = .last7Days
        filter.selectedSources = Set(ConversationSource.allCases)
        XCTAssertEqual(filter.apply(to: records, now: now).map(\.sessionID), ["app"])
    }

    func testDefaultHidesArchivedAndSortsByLastConversationDescending() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let records = [
            record("older", source: .codexCLI, environment: .secondary, cwd: "/B", date: now.addingTimeInterval(-10)),
            record("newer", source: .codexApp, environment: .openAI, cwd: "/A", date: now),
            record("claude", source: .claudeCode, environment: .claude, cwd: "/Claude", date: now.addingTimeInterval(-5)),
            record("placeholder", source: .codexCLI, environment: .secondary, cwd: "/Codex/2026-08-11/new-chat-2", date: now.addingTimeInterval(-1)),
            record("archived", source: .codexApp, environment: .openAI, cwd: "/A", date: now.addingTimeInterval(10), archived: true)
        ]

        XCTAssertEqual(ConversationFilter().apply(to: records, now: now).map(\.sessionID), ["claude", "older"])
    }

    func testCanExplicitlyIncludeCodexAppAndPlaceholderFolders() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let records = [
            record("app", source: .codexApp, environment: .openAI, cwd: "/A", date: now),
            record("placeholder", source: .codexCLI, environment: .secondary, cwd: "/Codex/New Chat 3", date: now)
        ]

        var filter = ConversationFilter()
        filter.selectedSources = Set(ConversationSource.allCases)
        filter.includePlaceholderFolders = true
        XCTAssertEqual(Set(filter.apply(to: records, now: now).map(\.sessionID)), Set(["app", "placeholder"]))

        filter = ConversationFilter()
        filter.selectedSources = [.codexApp]
        XCTAssertEqual(filter.apply(to: records, now: now).map(\.sessionID), ["app"])
    }

    func testSelectingNoSourcesReturnsNoConversations() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let records = [record("cli", source: .codexCLI, environment: .secondary, cwd: "/B", date: now)]
        var filter = ConversationFilter()
        filter.selectedSources = []

        XCTAssertTrue(filter.apply(to: records, now: now).isEmpty)
    }

    func testSupportsAllSharedSortOrdersAndStableTieBreaks() {
        let date = Date(timeIntervalSince1970: 2_000_000)
        var alpha = record("alpha", source: .codexCLI, environment: .secondary, cwd: "/Z", date: date)
        alpha.title = "Alpha"
        alpha.createdAt = date.addingTimeInterval(-20)
        var beta = record("beta", source: .claudeCode, environment: .claude, cwd: "/A", date: date)
        beta.title = "Beta"
        beta.createdAt = date.addingTimeInterval(-10)
        let records = [beta, alpha]
        var filter = ConversationFilter()
        filter.selectedSources = Set(ConversationSource.allCases)

        XCTAssertEqual(filter.apply(to: records, sort: .lastActivityDescending).map(\.sessionID), ["alpha", "beta"])
        XCTAssertEqual(filter.apply(to: records, sort: .createdDescending).map(\.sessionID), ["beta", "alpha"])
        XCTAssertEqual(filter.apply(to: records, sort: .createdAscending).map(\.sessionID), ["alpha", "beta"])
        XCTAssertEqual(filter.apply(to: records, sort: .titleAscending).map(\.sessionID), ["alpha", "beta"])
        XCTAssertEqual(filter.apply(to: records, sort: .workingDirectoryAscending).map(\.sessionID), ["beta", "alpha"])
    }

    func testActivityTimeUsesNewestSourceAndPrefersTranscriptOnTies() {
        let start = Date(timeIntervalSince1970: 100)
        let result = ConversationActivity.latest(
            transcript: start.addingTimeInterval(20),
            history: start.addingTimeInterval(10),
            database: start.addingTimeInterval(20),
            file: start.addingTimeInterval(15),
            fallback: start
        )

        XCTAssertEqual(result.date, start.addingTimeInterval(20))
        XCTAssertEqual(result.source, .transcript)
    }

    func testActivityTimeOnlyUsesFileMetadataAsFallback() {
        let start = Date(timeIntervalSince1970: 100)
        let semantic = ConversationActivity.latest(
            transcript: start.addingTimeInterval(10),
            file: start.addingTimeInterval(1_000),
            fallback: start
        )
        let fileFallback = ConversationActivity.latest(
            file: start.addingTimeInterval(1_000),
            fallback: start
        )

        XCTAssertEqual(semantic.date, start.addingTimeInterval(10))
        XCTAssertEqual(semantic.source, .transcript)
        XCTAssertEqual(fileFallback.source, .file)
    }

    private func record(
        _ id: String,
        source: ConversationSource,
        environment: ConversationEnvironment,
        cwd: String,
        date: Date,
        archived: Bool = false
    ) -> ConversationRecord {
        ConversationRecord(
            sessionID: id,
            storageKey: "fixture:\(id)",
            title: id,
            workingDirectory: cwd,
            source: source,
            environment: environment,
            createdAt: date.addingTimeInterval(-100),
            lastConversationAt: date,
            recentUserMessages: [],
            archived: archived,
            integrity: .complete,
            route: environment == .secondary ? .codexSecondary : .codexOpenAI,
            workingDirectoryExists: true
        )
    }
}
