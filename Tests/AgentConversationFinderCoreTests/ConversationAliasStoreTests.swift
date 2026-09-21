import Foundation
import XCTest
@testable import AgentConversationFinderCore

final class ConversationAliasStoreTests: XCTestCase {
    func testAliasRoundTripAndOwnerOnlyPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConversationFinderAliasTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let store = ConversationAliasStore(fileURL: directory.appendingPathComponent("aliases-v1.json"))
        try store.save(["codex:one": "我的自定义标题", "claude:two": "另一个标题"])

        XCTAssertEqual(
            try store.load(),
            ["codex:one": "我的自定义标题", "claude:two": "另一个标题"]
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    func testMissingAliasFileLoadsEmptyDictionary() throws {
        let store = ConversationAliasStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-aliases-\(UUID().uuidString).json")
        )
        XCTAssertEqual(try store.load(), [:])
    }
}
