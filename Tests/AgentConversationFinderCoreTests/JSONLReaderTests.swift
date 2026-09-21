import Foundation
import XCTest
@testable import AgentConversationFinderCore

final class JSONLReaderTests: XCTestCase {
    func testReadsManyLinesAcrossChunkBoundariesWithoutDroppingObjects() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConversationFinder-JSONL-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let lines = (0..<20_000).map { index in
            "{\"index\":\(index),\"message\":\"\(String(repeating: "x", count: index % 91))\"}"
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        var indexes: [Int] = []
        let result = try JSONLReader.readObjects(at: url) { object in
            if let index = object["index"] as? Int { indexes.append(index) }
        }

        XCTAssertEqual(result.malformedLineCount, 0)
        XCTAssertEqual(indexes.count, 20_000)
        XCTAssertEqual(indexes.first, 0)
        XCTAssertEqual(indexes.last, 19_999)
    }

    func testReadsFinalLineWithoutTrailingNewline() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConversationFinder-JSONL-tail-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try "{\"value\":1}\n{\"value\":2}".write(to: url, atomically: true, encoding: .utf8)

        var values: [Int] = []
        _ = try JSONLReader.readObjects(at: url) { object in
            if let value = object["value"] as? Int { values.append(value) }
        }

        XCTAssertEqual(values, [1, 2])
    }

    func testReadsNewestObjectsFirstAndStopsEarly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConversationFinder-JSONL-reverse-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let lines = (0..<10_000).map { "{\"index\":\($0)}" }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        var indexes: [Int] = []
        let result = try JSONLReader.readObjectsFromEnd(at: url) { object in
            if let index = object["index"] as? Int { indexes.append(index) }
            return indexes.count < 3
        }

        XCTAssertEqual(result.malformedLineCount, 0)
        XCTAssertEqual(indexes, [9_999, 9_998, 9_997])
    }

    func testDiscardsLongFilteredLineWithoutLosingFollowingObject() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConversationFinder-JSONL-filter-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let dropped = "{\"drop\":\"\(String(repeating: "x", count: 2 * 1_024 * 1_024))\"}"
        let kept = "{\"keep\":true,\"value\":42}"
        try (dropped + "\n" + kept + "\n").write(to: url, atomically: true, encoding: .utf8)
        let marker = Data("\"keep\":true".utf8)

        var values: [Int] = []
        let result = try JSONLReader.readObjects(
            at: url,
            shouldParse: { $0.prefix(256).range(of: marker) != nil }
        ) { object in
            if let value = object["value"] as? Int { values.append(value) }
        }

        let fileSize = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
        )
        XCTAssertEqual(values, [42])
        XCTAssertEqual(result.finalOffset, fileSize)
        XCTAssertEqual(result.malformedLineCount, 0)
    }
}
