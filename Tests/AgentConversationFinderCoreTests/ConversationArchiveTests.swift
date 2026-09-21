import Foundation
import XCTest
@testable import AgentConversationFinderCore

final class ConversationArchiveTests: XCTestCase {
    func testPlannerRoutesCodexAccountsToTheirOwnHomes() throws {
        let home = URL(fileURLWithPath: "/Users/test")
        let executable = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")

        let openAI = try ConversationArchivePlanner.strategy(
            for: record(route: .codexOpenAI),
            shouldArchive: true,
            homeDirectory: home,
            codexExecutableURL: executable
        )
        let secondary = try ConversationArchivePlanner.strategy(
            for: record(route: .codexSecondary),
            shouldArchive: false,
            homeDirectory: home,
            codexExecutableURL: executable
        )

        XCTAssertEqual(
            openAI,
            .codex(
                ArchiveProcessRequest(
                    executableURL: executable,
                    arguments: ["archive", "session-1"],
                    environmentOverrides: ["CODEX_HOME": "/Users/test/.codex"]
                )
            )
        )
        XCTAssertEqual(
            secondary,
            .codex(
                ArchiveProcessRequest(
                    executableURL: executable,
                    arguments: ["unarchive", "session-1"],
                    environmentOverrides: ["CODEX_HOME": "/Users/test/.codex-secondary"]
                )
            )
        )
    }

    func testPlannerUsesLocalOnlyArchiveForClaude() throws {
        XCTAssertEqual(
            try ConversationArchivePlanner.strategy(
                for: record(route: .claude),
                shouldArchive: true,
                homeDirectory: URL(fileURLWithPath: "/Users/test"),
                codexExecutableURL: URL(fileURLWithPath: "/unused")
            ),
            .localOnly
        )
    }

    func testLocalArchiveRoundTripAndOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConversationFinderArchiveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let store = ConversationLocalArchiveStore(
            fileURL: directory.appendingPathComponent("local-archives-v1.json")
        )
        try store.save(["claude:one", "claude:two"])

        XCTAssertEqual(try store.load(), ["claude:one", "claude:two"])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    func testProcessExecutorIncludesStderrInFailure() throws {
        let request = ArchiveProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'archive failed' >&2; exit 7"],
            environmentOverrides: [:]
        )

        XCTAssertThrowsError(try ArchiveProcessExecutor.run(request)) { error in
            XCTAssertTrue(error.localizedDescription.contains("archive failed"))
        }
    }

    private func record(route: CommandRoute) -> ConversationRecord {
        ConversationRecord(
            sessionID: "session-1",
            storageKey: "fixture:session-1",
            title: "Fixture",
            workingDirectory: "/Users/test/Project",
            source: route == .claude ? .claudeCode : .codexCLI,
            environment: route == .codexSecondary ? .secondary : (route == .claude ? .claude : .openAI),
            createdAt: Date(timeIntervalSince1970: 100),
            lastConversationAt: Date(timeIntervalSince1970: 200),
            recentUserMessages: [],
            archived: false,
            integrity: .complete,
            route: route,
            workingDirectoryExists: true
        )
    }
}
