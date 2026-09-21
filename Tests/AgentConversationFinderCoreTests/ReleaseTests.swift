import Foundation
import XCTest
@testable import AgentConversationFinderCore

/// Every value in these tests is invented; tests never open live account directories.
final class ReleaseTests: XCTestCase {
    private func record(route: CommandRoute = .codexSecondary, archived: Bool = false, source: ConversationSource = .codexCLI) -> ConversationRecord {
        ConversationRecord(sessionID: "fixture-session", storageKey: "fixture:session", title: "未命名会话",
            workingDirectory: "/Users/fixture/Example's Project", source: source, environment: .secondary,
            createdAt: Date(timeIntervalSince1970: 1), lastConversationAt: Date(timeIntervalSince1970: 2),
            recentUserMessages: ["为演示项目配置 SQLite 搜索索引"], archived: archived,
            integrity: .complete, route: route, workingDirectoryExists: true)
    }

    func testCommandsQuoteAllArgumentsAndKeepPermissionsEnabled() {
        var configuration = RuntimeConfiguration(homeDirectory: URL(fileURLWithPath: "/Users/fixture"))
        configuration.secondaryCodexHome = URL(fileURLWithPath: "/tmp/secondary home")
        configuration.codexExecutable = "/tmp/custom tools/codex"
        let command = CommandGenerator.command(for: record(), configuration: configuration)!
        XCTAssertEqual(command, "env CODEX_HOME='/tmp/secondary home' '/tmp/custom tools/codex' -C '/Users/fixture/Example'\\''s Project' resume 'fixture-session'")
        XCTAssertFalse(command.contains("--yolo"))
        let claude = CommandGenerator.command(for: record(route: .claude), configuration: configuration)!
        XCTAssertEqual(claude, "(cd -- '/Users/fixture/Example'\\''s Project' && env CLAUDE_CONFIG_DIR='/Users/fixture/.claude' 'claude' --resume 'fixture-session')")
        XCTAssertFalse(claude.contains("--cwd"))
        XCTAssertFalse(claude.contains("--dangerously-skip-permissions"))
        let archived = CommandGenerator.command(for: record(archived: true), configuration: configuration)!
        XCTAssertEqual(archived.components(separatedBy: "CODEX_HOME=").count, 3)
        let primaryCLI = CommandGenerator.command(for: record(route: .codexOpenAI), configuration: configuration)!
        XCTAssertTrue(primaryCLI.hasPrefix("env CODEX_HOME='/Users/fixture/.codex'"))
        XCTAssertNil(CommandGenerator.recoveryGuidance(for: record(route: .codexOpenAI)))
        let appRecord = record(route: .codexOpenAI, source: .codexApp)
        XCTAssertNil(CommandGenerator.command(for: appRecord, configuration: configuration))
        XCTAssertNotNil(CommandGenerator.recoveryGuidance(for: appRecord))
    }

    func testConfigurationOverridesAndAccountIsolation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try Data(#"{"codexHome":"~/primary","secondaryCodexHome":"~/secondary","codexExecutable":"/tmp/tool bin/codex"}"#.utf8).write(to: file)
        let home = URL(fileURLWithPath: "/Users/fixture")
        let config = try RuntimeConfiguration.load(environment: ["ACF_CONFIG": file.path, "ACF_CLAUDE_HOME": "/tmp/claude"], homeDirectory: home)
        XCTAssertEqual(config.codexHome.path, "/Users/fixture/primary")
        XCTAssertEqual(config.claudeHome.path, "/tmp/claude")
        let strategy = try ConversationArchivePlanner.strategy(for: record(), shouldArchive: true,
            codexExecutableURL: URL(fileURLWithPath: config.codexExecutable), configuration: config)
        guard case let .codex(request) = strategy else { return XCTFail("Expected Codex archive") }
        XCTAssertEqual(request.environmentOverrides, ["CODEX_HOME": "/Users/fixture/secondary"])
        var changed = config
        changed.codexHome = URL(fileURLWithPath: "/tmp/another-account")
        XCTAssertNotEqual(config.profileStateDirectory, changed.profileStateDirectory)
        XCTAssertThrowsError(try RuntimeConfiguration.load(environment: ["ACF_CODEX_HOME": "relative"], homeDirectory: directory))
        XCTAssertThrowsError(try RuntimeConfiguration.load(environment: ["ACF_CODEX_HOME": "/same", "ACF_SECONDARY_CODEX_HOME": "/same"], homeDirectory: directory))
        XCTAssertThrowsError(try RuntimeConfiguration.load(environment: ["ACF_CONFIG": "/does-not-exist/fixture.json"], homeDirectory: directory))
    }

    func testSearchTitleAliasAndCombinedKeywords() {
        var value = record()
        value.title = "SQLite 索引配置"
        XCTAssertEqual(ConversationTitleGenerator.displayTitle(for: value), "SQLite 索引配置")
        XCTAssertTrue(ConversationSearch.matches(value, query: "sqlite 搜索"))
        XCTAssertTrue(ConversationSearch.matches(value, query: "待复查", alias: "待复查"))
        XCTAssertFalse(ConversationSearch.matches(value, query: "sqlite 不存在的字段"))
        XCTAssertTrue(ConversationSearch.matches(value, query: "fixture-session"))
        value.title = "未命名会话"
        value.recentUserMessages = ["请解释 /Users/fixture/Example/Sources/Parser.swift 中的边界情况"]
        XCTAssertFalse(ConversationTitleGenerator.displayTitle(for: value).contains("fixture"))
    }

    func testResponseItemScanningExcludesInjectedContextAndAvoidsDuplicateEvents() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = home.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = sessions.appendingPathComponent("fixture.jsonl")
        let lines: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "fixture", "source": "cli", "cwd": "/tmp/example", "timestamp": "2026-01-01T00:00:00Z"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "# AGENTS.md instructions for fixture"]]]],
            ["type": "response_item", "timestamp": "2026-01-01T00:01:00Z", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "检索合成订单样例"]]]],
            ["type": "event_msg", "timestamp": "2026-01-01T00:01:00Z", "payload": ["type": "user_message", "message": "检索合成订单样例"]],
            ["type": "response_item", "timestamp": "2026-01-01T00:02:00Z", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "已完成合成订单索引"]]]]
        ]
        var bytes = Data()
        for line in lines { bytes.append(try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])); bytes.append(0x0A) }
        try bytes.write(to: file)
        let scanner = CodexScanner(configuration: .secondary(homeURL: home))
        let initial = try scanner.scan()
        let value = try XCTUnwrap(initial.records.first)
        XCTAssertEqual(value.digest?.userMessageCount, 1)
        XCTAssertTrue(value.digest?.searchableText.contains("合成订单") == true)
        XCTAssertFalse(value.digest?.searchableText.contains("AGENTS.md") == true)
        let extra: [String: Any] = ["type": "response_item", "timestamp": "2026-01-01T00:03:00Z", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "添加合成库存索引"]]]]
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys]))
        try handle.write(contentsOf: Data([0x0A])); try handle.close()
        let refreshed = try scanner.scan(previousRecords: initial.records)
        XCTAssertEqual(refreshed.records.first?.digest?.userMessageCount, 2)
        XCTAssertTrue(refreshed.records.first?.digest?.searchableText.contains("库存") == true)
    }
}
