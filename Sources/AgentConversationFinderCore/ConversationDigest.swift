import Foundation

public struct ConversationTranscriptCheckpoint: Codable, Hashable, Sendable {
    public var path: String
    public var byteOffset: UInt64
    public var fileSize: UInt64
    public var headerFingerprint: String
    public var codexMessageFormat: String? = nil

    public init(path: String, byteOffset: UInt64, fileSize: UInt64, headerFingerprint: String) {
        self.path = path
        self.byteOffset = byteOffset
        self.fileSize = fileSize
        self.headerFingerprint = headerFingerprint
    }
}

public struct ConversationDigest: Codable, Hashable, Sendable {
    public var summary: String
    public var currentFocus: String
    public var topics: [String]
    public var milestones: [String]
    public var openQuestions: [String]
    public var messageCount: Int
    public var userMessageCount: Int
    public var firstUserMessage: String?
    public var recentUserMessages: [String]
    public var searchableText: String
    public var topicScores: [String: Int]
    public var checkpoint: ConversationTranscriptCheckpoint
    public var lastTranscriptActivityAt: Date?

    public init(
        summary: String,
        currentFocus: String,
        topics: [String],
        milestones: [String],
        openQuestions: [String],
        messageCount: Int,
        userMessageCount: Int,
        firstUserMessage: String?,
        recentUserMessages: [String],
        searchableText: String,
        topicScores: [String: Int],
        checkpoint: ConversationTranscriptCheckpoint,
        lastTranscriptActivityAt: Date?
    ) {
        self.summary = summary
        self.currentFocus = currentFocus
        self.topics = topics
        self.milestones = milestones
        self.openQuestions = openQuestions
        self.messageCount = messageCount
        self.userMessageCount = userMessageCount
        self.firstUserMessage = firstUserMessage
        self.recentUserMessages = Array(recentUserMessages.suffix(3))
        self.searchableText = searchableText
        self.topicScores = topicScores
        self.checkpoint = checkpoint
        self.lastTranscriptActivityAt = lastTranscriptActivityAt
    }

    func sanitizingDisplayText() -> ConversationDigest {
        var result = self
        result.summary = DisplayTextSanitizer.sanitize(summary)
        result.currentFocus = DisplayTextSanitizer.sanitize(currentFocus)
        result.topics = topics.compactMap(DisplayTextSanitizer.sanitizeTopic)
        result.milestones = milestones.map(DisplayTextSanitizer.sanitize)
        result.openQuestions = openQuestions.map(DisplayTextSanitizer.sanitize)
        result.firstUserMessage = firstUserMessage.map(DisplayTextSanitizer.sanitize)
        result.recentUserMessages = recentUserMessages.map(DisplayTextSanitizer.sanitize)
        result.topicScores = topicScores.reduce(into: [:]) { scores, item in
            guard let topic = DisplayTextSanitizer.sanitizeTopic(item.key) else { return }
            scores[topic, default: 0] += item.value
        }
        return result
    }
}

struct TranscriptFileState {
    let path: String
    let fileSize: UInt64
    let modifiedAt: Date?
    let headerFingerprint: String

    init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return nil }
        path = url.path
        fileSize = size
        modifiedAt = attributes[.modificationDate] as? Date
        headerFingerprint = Self.fingerprintOfFirstLine(at: url)
    }

    func canContinue(from digest: ConversationDigest?) -> Bool {
        guard let checkpoint = digest?.checkpoint else { return false }
        return checkpoint.path == path
            && checkpoint.headerFingerprint == headerFingerprint
            && checkpoint.byteOffset <= fileSize
    }

    func checkpoint(finalOffset: UInt64) -> ConversationTranscriptCheckpoint {
        ConversationTranscriptCheckpoint(
            path: path,
            byteOffset: finalOffset,
            fileSize: fileSize,
            headerFingerprint: headerFingerprint
        )
    }

    private static func fingerprintOfFirstLine(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16 * 1024) else { return "" }
        let header = data.prefix { $0 != 0x0A }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in header {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct ConversationDigestBuilder {
    private static let maximumSearchableCharacters = 300_000
    private static let maximumMilestones = 6

    private var digest: ConversationDigest?
    private var firstUserMessage: String?
    private var currentFocus = ""
    private var milestones: [String] = []
    private var openQuestions: [String] = []
    private var recentUserMessages: [String] = []
    private var searchableText = ""
    private var topicScores: [String: Int] = [:]
    private var messageCount = 0
    private var userMessageCount = 0
    private var lastTranscriptActivityAt: Date?

    init(previous: ConversationDigest?) {
        digest = previous
        firstUserMessage = previous?.firstUserMessage.map(DisplayTextSanitizer.sanitize)
        currentFocus = previous.map { DisplayTextSanitizer.sanitize($0.currentFocus) } ?? ""
        milestones = previous?.milestones.map(DisplayTextSanitizer.sanitize) ?? []
        openQuestions = previous?.openQuestions.map(DisplayTextSanitizer.sanitize) ?? []
        recentUserMessages = previous?.recentUserMessages.map(DisplayTextSanitizer.sanitize) ?? []
        searchableText = previous?.searchableText ?? ""
        topicScores = previous?.topicScores.reduce(into: [:]) { scores, item in
            guard let topic = DisplayTextSanitizer.sanitizeTopic(item.key) else { return }
            scores[topic, default: 0] += item.value
        } ?? [:]
        messageCount = previous?.messageCount ?? 0
        userMessageCount = previous?.userMessageCount ?? 0
        lastTranscriptActivityAt = previous?.lastTranscriptActivityAt
    }

    mutating func appendUserMessage(_ value: String, timestamp: Date?) {
        guard let indexed = Self.normalized(value), !Self.looksLikeInjectedContext(indexed) else {
            recordActivity(timestamp)
            return
        }
        let displayText = DisplayTextSanitizer.sanitize(indexed)
        let preview = Self.preview(displayText, limit: 600)
        let focus = Self.preview(displayText, limit: 220)
        messageCount += 1
        userMessageCount += 1
        if firstUserMessage == nil { firstUserMessage = preview }
        recentUserMessages.append(preview)
        recentUserMessages = Array(recentUserMessages.suffix(3))
        appendSearchable("用户：" + indexed)
        scoreTopics(in: focus, weight: 2)

        if Self.isSubstantive(focus) {
            currentFocus = focus
            appendMilestone(focus)
            if Self.looksLikeQuestion(focus) {
                openQuestions.append(focus)
                openQuestions = Array(openQuestions.suffix(3))
            }
        }
        recordActivity(timestamp)
    }

    mutating func appendAssistantMessage(_ value: String?, timestamp: Date?) {
        messageCount += 1
        if let value, Self.looksLikeMilestone(value),
           let indexedExcerpt = Self.milestoneExcerpt(from: value) {
            let excerpt = DisplayTextSanitizer.sanitize(indexedExcerpt)
            appendSearchable("助手进展：" + indexedExcerpt)
            scoreTopics(in: excerpt, weight: 1)
            appendMilestone(excerpt)
        }
        recordActivity(timestamp)
    }

    mutating func recordActivity(_ timestamp: Date?) {
        lastTranscriptActivityAt = maxDate(lastTranscriptActivityAt, timestamp)
    }

    func finish(checkpoint: ConversationTranscriptCheckpoint) -> ConversationDigest {
        let topics = topicScores
            .sorted {
                if $0.value == $1.value { return $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                return $0.value > $1.value
            }
            .prefix(8)
            .map(\.key)
        let summary = Self.makeSummary(
            first: firstUserMessage,
            milestones: milestones,
            current: currentFocus
        )
        return ConversationDigest(
            summary: summary,
            currentFocus: currentFocus,
            topics: topics,
            milestones: milestones,
            openQuestions: openQuestions,
            messageCount: messageCount,
            userMessageCount: userMessageCount,
            firstUserMessage: firstUserMessage,
            recentUserMessages: recentUserMessages,
            searchableText: searchableText,
            topicScores: topicScores,
            checkpoint: checkpoint,
            lastTranscriptActivityAt: lastTranscriptActivityAt
        )
    }

    private mutating func appendSearchable(_ value: String) {
        let remaining = Self.maximumSearchableCharacters - searchableText.count
        guard remaining > 0 else { return }
        if !searchableText.isEmpty { searchableText.append("\n") }
        searchableText.append(contentsOf: value.prefix(remaining))
    }

    private mutating func appendMilestone(_ value: String) {
        guard milestones.last.map({ Self.similarity($0, value) < 0.58 }) ?? true else { return }
        if milestones.count >= Self.maximumMilestones {
            milestones.remove(at: milestones.count > 2 ? 1 : 0)
        }
        milestones.append(value)
    }

    private mutating func scoreTopics(in value: String, weight: Int) {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in Self.topicExpression.matches(in: value, range: range) {
            guard let matchRange = Range(match.range, in: value) else { continue }
            let token = String(value[matchRange])
                .trimmingCharacters(in: Self.topicEdgeCharacters)
            if Self.isUsefulTopic(token) {
                topicScores[token, default: 0] += weight
            }
        }
    }

    private static func makeSummary(first: String?, milestones: [String], current: String) -> String {
        let first = first.map { preview($0, limit: 130) }
        let current = current.isEmpty ? first : preview(current, limit: 150)
        guard let first else { return current ?? "尚未提取到可概括的正文" }
        guard let current, similarity(first, current) < 0.72 else { return first }

        let middle = milestones
            .dropFirst()
            .dropLast(milestones.count > 1 ? 1 : 0)
            .prefix(2)
            .map { preview($0, limit: 90) }
        var parts = ["最初围绕“\(first)”展开"]
        if !middle.isEmpty {
            parts.append("过程中推进了“\(middle.joined(separator: "”；“"))”")
        }
        parts.append("当前聚焦“\(current)”")
        return parts.joined(separator: "；") + "。"
    }

    private static func normalized(_ value: String) -> String? {
        let result = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func preview(_ value: String, limit: Int) -> String {
        let oneLine = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit)) + "…"
    }

    private static func isSubstantive(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard clean.count >= 4 else { return false }
        let generic = Set(["继续", "好的", "可以", "同意", "不同意", "开始吧", "就这样", "你继续", "继续做"])
        if generic.contains(clean) { return false }
        return clean.range(
            of: #"^(好的?|可以|同意)[，,。！!\s]*(就)?(你现在|现在|按.{0,24})?(做|改|开始|继续)(吧|了)?$"#,
            options: .regularExpression
        ) == nil
    }

    private static func looksLikeInjectedContext(_ value: String) -> Bool {
        value.hasPrefix("# AGENTS.md instructions")
            || value.hasPrefix("<codex_internal_context")
            || value.hasPrefix("<environment_context>")
            || value.hasPrefix("<skills_instructions>")
            || value.hasPrefix("<permissions instructions>")
            || value.hasPrefix("Another language model started to solve this problem")
    }

    private static func looksLikeQuestion(_ value: String) -> Bool {
        value.contains("？") || value.contains("?")
            || ["为什么", "怎么", "是否", "能不能", "有没有", "什么问题"].contains(where: value.contains)
    }

    private static func looksLikeMilestone(_ value: String) -> Bool {
        ["已完成", "完成了", "已经实现", "已经修改", "修复了", "根因", "问题在", "验证通过", "测试通过"]
            .contains(where: value.contains)
    }

    private static func milestoneExcerpt(from value: String) -> String? {
        let sentences = value.split(whereSeparator: { character in
            "。！？!?\n".contains(character)
        })
        guard let sentence = sentences.first(where: { looksLikeMilestone(String($0)) }) else { return nil }
        return preview(String(sentence), limit: 220)
    }

    private static func isUsefulTopic(_ value: String) -> Bool {
        guard value.count >= 2 && value.count <= 28 else { return false }
        let lower = value.lowercased()
        let ignored = Set([
            "这个", "那个", "现在", "然后", "可以", "需要", "一个", "一下", "已经", "还是", "就是",
            "我们", "你们", "他们", "什么", "怎么", "为什么", "里面", "这里", "这样", "进行", "使用",
            "链接", "路径", "内嵌数据",
            "the", "and", "for", "with", "from", "this", "that", "user", "assistant", "message"
        ])
        guard !ignored.contains(lower) else { return false }
        return value.range(of: #"[\p{L}\p{N}]"#, options: .regularExpression) != nil
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = characterBigrams(lhs)
        let right = characterBigrams(rhs)
        guard !left.isEmpty, !right.isEmpty else { return lhs == rhs ? 1 : 0 }
        let intersection = left.intersection(right).count
        let union = left.union(right).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private static func characterBigrams(_ value: String) -> Set<String> {
        let characters = Array(value.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
        guard characters.count > 1 else { return Set(characters.map(String.init)) }
        return Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
    }

    private static let topicExpression = try! NSRegularExpression(
        pattern: #"[A-Za-z][A-Za-z0-9_.+#-]{1,27}|[\p{Han}]{2,12}"#
    )
    private static let topicEdgeCharacters = CharacterSet(
        charactersIn: "的了在和与及对把将从为我你他她它这那就还也很能不"
    ).union(.whitespacesAndNewlines).union(.punctuationCharacters)
}
