import Foundation
import XCTest
@testable import AgentConversationFinderCore

final class CacheStoreTests: XCTestCase {
    func testCacheRoundTripAndOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConversationFinderCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let store = ConversationCacheStore(fileURL: directory.appendingPathComponent("index-v1.json"))
        let cache = ConversationCache(refreshedAt: Date(timeIntervalSince1970: 123), records: [])
        try store.save(cache)

        XCTAssertEqual(try store.load(), cache)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    func testDecodesVersionOneRecordWithoutDigestAndActivityDiagnostics() throws {
        let record = ConversationRecord(
            sessionID: "old-session",
            storageKey: "old:session",
            title: "旧缓存",
            workingDirectory: "/tmp",
            source: .codexCLI,
            environment: .secondary,
            createdAt: Date(timeIntervalSince1970: 1),
            lastConversationAt: Date(timeIntervalSince1970: 2),
            recentUserMessages: ["旧消息"],
            archived: false,
            integrity: .complete,
            route: .codexSecondary,
            workingDirectoryExists: true
        )
        let encoded = try JSONEncoder().encode(ConversationCache(schemaVersion: 1, refreshedAt: Date(), records: [record]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        for key in [
            "digest", "lastActivitySource", "databaseUpdatedAt", "transcriptUpdatedAt",
            "historyUpdatedAt", "transcriptFileModifiedAt"
        ] {
            records[0].removeValue(forKey: key)
        }
        object["records"] = records
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ConversationCache.self, from: legacyData)
        XCTAssertEqual(decoded.records[0].sessionID, "old-session")
        XCTAssertNil(decoded.records[0].digest)
        XCTAssertNil(decoded.records[0].lastActivitySource)
    }

    func testLoadingExistingCacheSanitizesDigestWithoutChangingSearchText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConversationFinderCacheMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let URL = "https://example.com/a/very/long/report.html?token=secret"
        let path = "/Users/fixture/Desktop/project/Sources/Report.swift"
        var record = legacyRecord()
        record.digest = ConversationDigest(
            summary: "检查 \(URL) 和 \(path)",
            currentFocus: "修改 \(path)",
            topics: ["https", "Report.swift"],
            milestones: ["已检查 \(URL)"],
            openQuestions: [],
            messageCount: 2,
            userMessageCount: 1,
            firstUserMessage: "检查 \(URL)",
            recentUserMessages: ["修改 \(path)"],
            searchableText: "用户：检查 \(URL) 和 \(path)",
            topicScores: ["https": 2, "Report.swift": 2],
            checkpoint: ConversationTranscriptCheckpoint(
                path: "/tmp/session.jsonl",
                byteOffset: 100,
                fileSize: 100,
                headerFingerprint: "header"
            ),
            lastTranscriptActivityAt: Date(timeIntervalSince1970: 2)
        )
        let store = ConversationCacheStore(fileURL: directory.appendingPathComponent("index-v1.json"))
        try store.save(ConversationCache(refreshedAt: Date(), records: [record]))

        let loaded = try XCTUnwrap(store.load()?.records.first?.digest)

        XCTAssertFalse(loaded.summary.contains("token=secret"))
        XCTAssertFalse(loaded.summary.contains("/Users/fixture"))
        XCTAssertFalse(loaded.topics.contains("https"))
        XCTAssertTrue(loaded.searchableText.contains(URL))
        XCTAssertTrue(loaded.searchableText.contains(path))
    }

    private func legacyRecord() -> ConversationRecord {
        ConversationRecord(
            sessionID: "legacy-session",
            storageKey: "legacy:session",
            title: "旧缓存",
            workingDirectory: "/tmp",
            source: .codexCLI,
            environment: .secondary,
            createdAt: Date(timeIntervalSince1970: 1),
            lastConversationAt: Date(timeIntervalSince1970: 2),
            recentUserMessages: [],
            archived: false,
            integrity: .complete,
            route: .codexSecondary,
            workingDirectoryExists: true
        )
    }
}
