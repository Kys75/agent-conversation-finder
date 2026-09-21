import Foundation
import XCTest
@testable import AgentConversationFinderCore

final class ConversationDigestTests: XCTestCase {
    func testTracksConversationEvolutionWithoutTreatingApprovalAsNewFocus() {
        var builder = ConversationDigestBuilder(previous: nil)
        builder.appendUserMessage("先检查最后对话时间为什么排序不准确", timestamp: Date(timeIntervalSince1970: 1))
        builder.appendAssistantMessage("已完成时间来源诊断", timestamp: Date(timeIntervalSince1970: 2))
        builder.appendUserMessage("然后建立全文增量摘要和全文搜索", timestamp: Date(timeIntervalSince1970: 3))
        builder.appendUserMessage("同意，你现在改吧", timestamp: Date(timeIntervalSince1970: 4))

        let digest = builder.finish(checkpoint: checkpoint(offset: 100))

        XCTAssertEqual(digest.currentFocus, "然后建立全文增量摘要和全文搜索")
        XCTAssertTrue(digest.summary.contains("最后对话时间"))
        XCTAssertTrue(digest.summary.contains("全文增量摘要"))
        XCTAssertTrue(digest.milestones.contains(where: { $0.contains("时间来源诊断") }))
        XCTAssertEqual(digest.userMessageCount, 3)
        XCTAssertEqual(digest.messageCount, 4)
    }

    func testContinuesDigestFromCheckpointWithoutRepeatingPreviousMessages() {
        var initialBuilder = ConversationDigestBuilder(previous: nil)
        initialBuilder.appendUserMessage("设计会话摘要", timestamp: Date(timeIntervalSince1970: 1))
        let initial = initialBuilder.finish(checkpoint: checkpoint(offset: 100))

        var incrementalBuilder = ConversationDigestBuilder(previous: initial)
        incrementalBuilder.appendUserMessage("补充全文搜索", timestamp: Date(timeIntervalSince1970: 2))
        let updated = incrementalBuilder.finish(checkpoint: checkpoint(offset: 160))

        XCTAssertEqual(updated.userMessageCount, 2)
        XCTAssertEqual(updated.recentUserMessages, ["设计会话摘要", "补充全文搜索"])
        XCTAssertEqual(updated.checkpoint.byteOffset, 160)
    }

    func testSanitizesLongAddressesForDisplayButKeepsOriginalTextSearchable() {
        let URL = "https://github.com/openai/codex/issues/123?access_token=secret-value&utm_source=test"
        let path = "/Users/fixture/Desktop/sample-workspace/agent-conversation-finder/Sources/AgentConversationFinderCore/ConversationDigest.swift"
        var builder = ConversationDigestBuilder(previous: nil)
        builder.appendUserMessage("检查 \(URL) 和 \(path) 的问题", timestamp: Date(timeIntervalSince1970: 1))

        let digest = builder.finish(checkpoint: checkpoint(offset: 100))

        XCTAssertTrue(digest.summary.contains("[链接：github.com/openai/codex/issues/123]"))
        XCTAssertTrue(digest.summary.contains("[路径：…/AgentConversationFinderCore/ConversationDigest.swift]"))
        XCTAssertFalse(digest.summary.contains("access_token"))
        XCTAssertFalse(digest.summary.contains("/Users/fixture"))
        XCTAssertTrue(digest.searchableText.contains(URL))
        XCTAssertTrue(digest.searchableText.contains(path))
    }

    func testSanitizesLegacyDigestFieldsDuringIncrementalRefresh() {
        let path = "/Users/fixture/Desktop/very/long/project/Sources/Legacy.swift"
        var initialBuilder = ConversationDigestBuilder(previous: nil)
        initialBuilder.appendUserMessage("处理 \(path)", timestamp: Date(timeIntervalSince1970: 1))
        var initial = initialBuilder.finish(checkpoint: checkpoint(offset: 100))
        initial.currentFocus = "处理 \(path)"
        initial.milestones = ["已经修改 \(path)"]

        let refreshed = ConversationDigestBuilder(previous: initial)
            .finish(checkpoint: checkpoint(offset: 100))

        XCTAssertFalse(refreshed.summary.contains("/Users/fixture"))
        XCTAssertFalse(refreshed.currentFocus.contains("/Users/fixture"))
        XCTAssertFalse(refreshed.milestones.joined().contains("/Users/fixture"))
    }

    func testCollapsesEmbeddedDataInDisplayText() {
        let dataURI = "data:image/png;base64," + String(repeating: "A", count: 160)
        var builder = ConversationDigestBuilder(previous: nil)
        builder.appendUserMessage("检查这张图片 \(dataURI)", timestamp: Date(timeIntervalSince1970: 1))

        let digest = builder.finish(checkpoint: checkpoint(offset: 100))

        XCTAssertTrue(digest.summary.contains("[内嵌数据]"))
        XCTAssertFalse(digest.summary.contains(String(repeating: "A", count: 40)))
        XCTAssertTrue(digest.searchableText.contains(dataURI))
    }

    private func checkpoint(offset: UInt64) -> ConversationTranscriptCheckpoint {
        ConversationTranscriptCheckpoint(
            path: "/tmp/session.jsonl",
            byteOffset: offset,
            fileSize: offset,
            headerFingerprint: "header"
        )
    }
}
