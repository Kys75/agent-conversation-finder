import Foundation
import XCTest
@testable import AgentConversationFinderCore

final class ScannerTests: XCTestCase {
    func testEmptyDatabaseDoesNotHideUnindexedTranscript() throws {
        let home = try temporaryDirectory(named: "orphan-fixture")
        try writeFixtureTranscript(id: "orphan", text: "synthetic orphan message", to: home.appendingPathComponent("sessions/orphan.jsonl"))
        try createFixtureDatabase(at: home.appendingPathComponent("state_5.sqlite"))
        let outcome = try CodexScanner(configuration: .openAI(homeURL: home)).scan()
        XCTAssertEqual(outcome.records.map(\.sessionID), ["orphan"])
        XCTAssertTrue(outcome.records[0].digest?.searchableText.contains("synthetic orphan") == true)
    }

    func testForeignPathsAndSymlinksNeverReadOutsideSourceRoot() throws {
        let home = try temporaryDirectory(named: "primary-fixture")
        let other = try temporaryDirectory(named: "foreign-fixture")
        let foreign = other.appendingPathComponent("sessions/foreign.jsonl")
        try writeFixtureTranscript(id: "foreign", text: "foreign-private-fixture-marker", to: foreign)
        let database = home.appendingPathComponent("state_5.sqlite")
        try createFixtureDatabase(at: database)
        try runSQLite(database: database, sql: "INSERT INTO threads VALUES ('foreign', '\(foreign.path)', 1000, 1, 2000, 2, 'cli', '/tmp/fixture', 'Metadata only', 0);")
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sessions.appendingPathComponent("foreign.jsonl"), withDestinationURL: foreign)
        let outcome = try CodexScanner(configuration: .openAI(homeURL: home)).scan()
        XCTAssertEqual(outcome.records.count, 1)
        XCTAssertEqual(outcome.records[0].integrity, .missingTranscript)
        XCTAssertNil(outcome.records[0].digest)
        XCTAssertFalse(outcome.warnings.isEmpty)
        let claude = try temporaryDirectory(named: "claude-boundary")
        try FileManager.default.createSymbolicLink(at: claude.appendingPathComponent("projects"), withDestinationURL: other)
        XCTAssertTrue(try ClaudeScanner(homeURL: claude).scan().records.isEmpty)
    }

    func testCopiedAbsoluteTranscriptPathRelocatesInsideCurrentRoot() throws {
        let home = try temporaryDirectory(named: "relocated-fixture")
        let transcript = home.appendingPathComponent("sessions/year/copied.jsonl")
        try writeFixtureTranscript(id: "copied", text: "safe relocated fixture", to: transcript)
        let database = home.appendingPathComponent("state_5.sqlite")
        try createFixtureDatabase(at: database)
        try runSQLite(database: database, sql: "INSERT INTO threads VALUES ('copied', '/missing/old/root/sessions/year/copied.jsonl', 1000, 1, 2000, 2, 'cli', '/tmp/fixture', 'DB title', 1);")
        let outcome = try CodexScanner(configuration: .openAI(homeURL: home)).scan()
        XCTAssertEqual(outcome.records.count, 1)
        XCTAssertEqual(outcome.records[0].title, "DB title")
        XCTAssertTrue(outcome.records[0].archived)
        XCTAssertTrue(outcome.records[0].digest?.searchableText.contains("safe relocated") == true)
    }

    func testIncompleteTailIsRetriedAfterWriterFinishesMessage() throws {
        let home = try temporaryDirectory(named: "live-tail-fixture")
        let transcript = home.appendingPathComponent("sessions/live.jsonl")
        try writeFixtureTranscript(id: "live", text: "initial fixture", to: transcript)
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        let partial = #"{"type":"event_msg","payload":{"type":"user_message","message":"unfinished"#
        try handle.write(contentsOf: Data(partial.utf8))
        let scanner = CodexScanner(configuration: .openAI(homeURL: home))
        let initial = try scanner.scan()
        XCTAssertEqual(initial.records[0].digest?.userMessageCount, 1)
        try handle.write(contentsOf: Data(" fixture\"}}\n".utf8))
        try handle.close()
        let updated = try scanner.scan(previousRecords: initial.records)
        XCTAssertEqual(updated.records[0].digest?.userMessageCount, 2)
        XCTAssertEqual(updated.records[0].integrity, .complete)
        XCTAssertTrue(updated.records[0].digest?.searchableText.contains("unfinished fixture") == true)
    }

    private func writeFixtureTranscript(id: String, text: String, to url: URL) throws {
        try writeJSONLines([
            ["type": "session_meta", "payload": ["id": id, "source": "cli", "cwd": "/tmp/fixture", "timestamp": "2026-01-01T00:00:00Z"]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": text]]
        ], to: url)
    }

    private func createFixtureDatabase(at url: URL) throws {
        try runSQLite(database: url, sql: "CREATE TABLE threads (id TEXT, rollout_path TEXT, created_at_ms INTEGER, created_at INTEGER, updated_at_ms INTEGER, updated_at INTEGER, source TEXT, cwd TEXT, title TEXT, archived INTEGER);")
    }

    func testCodexDatabaseClassifiesAppAndUsesDatabaseTitle() throws {
        let home = try temporaryDirectory(named: "codex-oai")
        let transcript = home.appendingPathComponent("sessions/2026/08/12/rollout-app-session.jsonl")
        try writeJSONLines([
            ["timestamp": "2026-08-12T01:00:00Z", "type": "session_meta", "payload": ["id": "app-session", "timestamp": "2026-08-12T01:00:00Z", "cwd": "/Users/test/App", "source": "vscode"]],
            ["timestamp": "2026-08-12T01:01:00Z", "type": "event_msg", "payload": ["type": "user_message", "message": "第一条"]],
            ["timestamp": "2026-08-12T01:02:00Z", "type": "event_msg", "payload": ["type": "agent_message", "message": "回答"]],
            ["timestamp": "2026-08-12T01:03:00Z", "type": "event_msg", "payload": ["type": "user_message", "message": "最后一条"]]
        ], to: transcript)

        let database = home.appendingPathComponent("state_5.sqlite")
        try runSQLite(database: database, sql: """
            CREATE TABLE threads (
                id TEXT, rollout_path TEXT, created_at_ms INTEGER, created_at INTEGER,
                updated_at_ms INTEGER, updated_at INTEGER, source TEXT, cwd TEXT,
                title TEXT, archived INTEGER
            );
            INSERT INTO threads VALUES (
                'app-session', '\(transcript.path)', 1786496400000, 1786496400,
                1786496580000, 1786496580, 'vscode', '/Users/test/App',
                '数据库标题', 1
            );
            """)

        let outcome = try CodexScanner(configuration: .openAI(homeURL: home)).scan()
        XCTAssertEqual(outcome.records.count, 1)
        XCTAssertEqual(outcome.records[0].source, .codexApp)
        XCTAssertEqual(outcome.records[0].environment, .openAI)
        XCTAssertEqual(outcome.records[0].title, "数据库标题")
        XCTAssertEqual(outcome.records[0].recentUserMessages, ["第一条", "最后一条"])
        XCTAssertTrue(outcome.records[0].archived)
        XCTAssertEqual(outcome.records[0].route, .codexOpenAI)
    }

    func testCodexFallbackExcludesExecAndKeepsLastThreeMessages() throws {
        let home = try temporaryDirectory(named: "codex-secondary")
        let session = home.appendingPathComponent("sessions/2026/08/12/rollout-cli-session.jsonl")
        try writeJSONLines([
            ["timestamp": "2026-08-12T02:00:00Z", "type": "session_meta", "payload": ["id": "cli-session", "timestamp": "2026-08-12T02:00:00Z", "cwd": "/Users/test/CLI", "source": "cli"]],
            ["timestamp": "2026-08-12T02:01:00Z", "type": "event_msg", "payload": ["type": "user_message", "message": "one"]],
            ["timestamp": "2026-08-12T02:02:00Z", "type": "event_msg", "payload": ["type": "user_message", "message": "two"]],
            ["timestamp": "2026-08-12T02:03:00Z", "type": "event_msg", "payload": ["type": "user_message", "message": "three"]],
            ["timestamp": "2026-08-12T02:04:00Z", "type": "event_msg", "payload": ["type": "user_message", "message": "four"]]
        ], to: session)
        let exec = home.appendingPathComponent("sessions/2026/08/12/rollout-exec-session.jsonl")
        try writeJSONLines([
            ["timestamp": "2026-08-12T03:00:00Z", "type": "session_meta", "payload": ["id": "exec-session", "timestamp": "2026-08-12T03:00:00Z", "cwd": "/tmp", "source": "exec"]]
        ], to: exec)

        let outcome = try CodexScanner(configuration: .secondary(homeURL: home)).scan()
        XCTAssertEqual(outcome.records.map(\.sessionID), ["cli-session"])
        XCTAssertEqual(outcome.records[0].recentUserMessages, ["two", "three", "four"])
        XCTAssertEqual(outcome.records[0].digest?.userMessageCount, 4)
        XCTAssertTrue(outcome.records[0].digest?.summary.contains("one") == true)
        XCTAssertTrue(outcome.records[0].digest?.currentFocus.contains("four") == true)
        XCTAssertTrue(outcome.records[0].digest?.searchableText.contains("one") == true)
        XCTAssertEqual(outcome.records[0].title, "one")
        XCTAssertEqual(outcome.records[0].route, .codexSecondary)
    }

    func testCodexDatabaseDrainsLargeQueryOutputWithoutDeadlock() throws {
        let home = try temporaryDirectory(named: "codex-large")
        let database = home.appendingPathComponent("state_5.sqlite")
        try runSQLite(database: database, sql: """
            CREATE TABLE threads (
                id TEXT, rollout_path TEXT, created_at_ms INTEGER, created_at INTEGER,
                updated_at_ms INTEGER, updated_at INTEGER, source TEXT, cwd TEXT,
                title TEXT, archived INTEGER
            );
            WITH RECURSIVE seq(x) AS (
                VALUES(1) UNION ALL SELECT x + 1 FROM seq WHERE x < 800
            )
            INSERT INTO threads
            SELECT printf('session-%04d', x), '/missing/' || x || '.jsonl',
                   1786496400000 + x, 1786496400,
                   1786496500000 + x, 1786496500,
                   'cli', '/Users/test/project-' || x,
                   printf('Large fixture title %04d with enough text to exceed pipe buffers', x), 0
            FROM seq;
            """)

        let outcome = try CodexScanner(configuration: .secondary(homeURL: home)).scan()
        XCTAssertEqual(outcome.records.count, 800)
        XCTAssertTrue(outcome.records.allSatisfy { $0.integrity == .missingTranscript })
    }

    func testCodexIncrementalScanReusesUnchangedPreviewAndReloadsChangedRow() throws {
        let home = try temporaryDirectory(named: "codex-incremental")
        let transcript = home.appendingPathComponent("sessions/2026/08/12/rollout-session.jsonl")
        try writeJSONLines([
            ["timestamp": "2026-08-12T01:00:00Z", "type": "session_meta", "payload": ["id": "session", "cwd": "/Users/test/App", "source": "vscode"]],
            ["timestamp": "2026-08-12T01:01:00Z", "type": "event_msg", "payload": ["type": "user_message", "message": "旧消息"]]
        ], to: transcript)
        let database = home.appendingPathComponent("state_5.sqlite")
        try runSQLite(database: database, sql: """
            CREATE TABLE threads (
                id TEXT, rollout_path TEXT, created_at_ms INTEGER, created_at INTEGER,
                updated_at_ms INTEGER, updated_at INTEGER, source TEXT, cwd TEXT,
                title TEXT, archived INTEGER
            );
            INSERT INTO threads VALUES (
                'session', '\(transcript.path)', 1786496400000, 1786496400,
                1786496460000, 1786496460, 'vscode', '/Users/test/App', '标题', 0
            );
            """)

        let scanner = CodexScanner(configuration: .openAI(homeURL: home))
        let first = try scanner.scan()
        XCTAssertEqual(first.records[0].recentUserMessages, ["旧消息"])

        try writeJSONLines([
            ["timestamp": "2026-08-12T01:00:00Z", "type": "session_meta", "payload": ["id": "session", "cwd": "/Users/test/App", "source": "vscode"]],
            ["timestamp": "2026-08-12T01:02:00Z", "type": "event_msg", "payload": ["type": "user_message", "message": "新消息"]]
        ], to: transcript)

        let unchangedIndex = try scanner.scan(previousRecords: first.records)
        XCTAssertEqual(unchangedIndex.records[0].recentUserMessages, ["旧消息"])

        try runSQLite(database: database, sql: "UPDATE threads SET updated_at_ms = 1786496520000 WHERE id = 'session';")
        let changedIndex = try scanner.scan(previousRecords: first.records)
        XCTAssertEqual(changedIndex.records[0].recentUserMessages, ["新消息"])
    }

    func testCodexIncrementalDigestReadsOnlyAppendedTranscriptContent() throws {
        let home = try temporaryDirectory(named: "codex-digest-append")
        let transcript = home.appendingPathComponent("sessions/2026/08/12/rollout-session.jsonl")
        try writeJSONLines([
            ["timestamp": "2026-08-12T01:00:00Z", "type": "session_meta", "payload": ["id": "session", "cwd": "/Users/test/App", "source": "vscode"]],
            ["timestamp": "2026-08-12T01:01:00Z", "type": "event_msg", "payload": ["type": "user_message", "message": "最初规划全文索引"]]
        ], to: transcript)
        let database = home.appendingPathComponent("state_5.sqlite")
        try runSQLite(database: database, sql: """
            CREATE TABLE threads (
                id TEXT, rollout_path TEXT, created_at_ms INTEGER, created_at INTEGER,
                updated_at_ms INTEGER, updated_at INTEGER, source TEXT, cwd TEXT,
                title TEXT, archived INTEGER
            );
            INSERT INTO threads VALUES (
                'session', '\(transcript.path)', 1786496400000, 1786496400,
                1786496460000, 1786496460, 'vscode', '/Users/test/App', '全文索引', 0
            );
            """)

        let scanner = CodexScanner(configuration: .openAI(homeURL: home))
        let first = try scanner.scan()
        let originalOffset = try XCTUnwrap(first.records[0].digest?.checkpoint.byteOffset)

        let appended = try JSONSerialization.data(withJSONObject: [
            "timestamp": "2026-08-12T01:03:00Z",
            "type": "event_msg",
            "payload": ["type": "user_message", "message": "现在实现增量摘要并验证全文搜索"]
        ], options: [.sortedKeys])
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: appended + Data("\n".utf8))
        try handle.close()
        try runSQLite(database: database, sql: "UPDATE threads SET updated_at_ms = 1786496580000 WHERE id = 'session';")

        let second = try scanner.scan(previousRecords: first.records)
        let digest = try XCTUnwrap(second.records[0].digest)
        XCTAssertGreaterThan(digest.checkpoint.byteOffset, originalOffset)
        XCTAssertEqual(digest.userMessageCount, 2)
        XCTAssertEqual(digest.recentUserMessages, ["最初规划全文索引", "现在实现增量摘要并验证全文搜索"])
        XCTAssertTrue(digest.summary.contains("最初规划全文索引"))
        XCTAssertTrue(digest.summary.contains("增量摘要"))
    }

    func testClaudeUsesAITitleAndHistoryWhileExcludingSubagents() throws {
        let home = try temporaryDirectory(named: "claude")
        let main = home.appendingPathComponent("projects/project-a/claude-session.jsonl")
        try writeJSONLines([
            ["type": "user", "sessionId": "claude-session", "cwd": "/Users/test/Claude", "timestamp": "2026-08-12T04:00:00Z", "isSidechain": false, "message": ["role": "user", "content": "fallback"]],
            ["type": "assistant", "sessionId": "claude-session", "cwd": "/Users/test/Claude", "timestamp": "2026-08-12T04:01:00Z", "isSidechain": false, "message": ["role": "assistant", "content": "已完成 answer"]],
            ["type": "ai-title", "sessionId": "claude-session", "aiTitle": "Claude 标题"]
        ], to: main)
        let subagent = home.appendingPathComponent("projects/project-a/subagents/sub-session.jsonl")
        try writeJSONLines([
            ["type": "user", "sessionId": "sub-session", "cwd": "/tmp", "timestamp": "2026-08-12T04:00:00Z", "message": ["role": "user", "content": "hidden"]]
        ], to: subagent)

        let history = home.appendingPathComponent("history.jsonl")
        try writeJSONLines([
            ["display": "one", "timestamp": 1_786_500_001_000 as NSNumber, "project": "/Users/test/Claude", "sessionId": "claude-session"],
            ["display": "two", "timestamp": 1_786_500_002_000 as NSNumber, "project": "/Users/test/Claude", "sessionId": "claude-session"],
            ["display": "three", "timestamp": 1_786_500_003_000 as NSNumber, "project": "/Users/test/Claude", "sessionId": "claude-session"],
            ["display": "four", "timestamp": 1_786_500_004_000 as NSNumber, "project": "/Users/test/Claude", "sessionId": "claude-session"]
        ], to: history)

        let outcome = try ClaudeScanner(homeURL: home).scan()
        XCTAssertEqual(outcome.records.count, 1)
        XCTAssertEqual(outcome.records[0].title, "Claude 标题")
        XCTAssertEqual(outcome.records[0].recentUserMessages, ["two", "three", "four"])
        XCTAssertEqual(outcome.records[0].digest?.messageCount, 2)
        XCTAssertTrue(outcome.records[0].digest?.searchableText.contains("answer") == true)
        XCTAssertEqual(outcome.records[0].route, .claude)
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConversationFinderTests-\(UUID().uuidString)-\(name)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeJSONLines(_ objects: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = try objects.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func runSQLite(database: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "ScannerTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: error])
        }
    }
}
