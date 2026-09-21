import Foundation

public struct ConversationTitlePresentation: Equatable, Sendable {
    public let title: String
    public let isDerived: Bool
}

/// Produces a short, local-only display title without changing the source session.
public enum ConversationTitleGenerator {
    public static func displayTitle(for record: ConversationRecord) -> String {
        presentation(for: record).title
    }

    public static func isDerivedTitle(for record: ConversationRecord) -> Bool {
        presentation(for: record).isDerived
    }

    public static func presentation(for record: ConversationRecord) -> ConversationTitlePresentation {
        let fingerprint = fingerprint(for: record)
        if let cached = cache.value(for: record.storageKey, fingerprint: fingerprint) {
            return cached
        }

        let original = clean(record.title)
        let title = makeTitle(for: record, original: original)
        let presentation = ConversationTitlePresentation(title: title, isDerived: title != original)
        cache.insert(presentation, for: record.storageKey, fingerprint: fingerprint)
        return presentation
    }

    private static func makeTitle(for record: ConversationRecord, original: String) -> String {
        let digestContext = [
            record.digest?.summary,
            record.digest?.currentFocus,
            record.digest?.topics.joined(separator: " "),
            record.digest?.milestones.joined(separator: "\n")
        ].compactMap { $0 }
        let recent = (digestContext + record.recentUserMessages)
            .map(cleanMessage)
            .filter(isSubstantive)
        let context = ([original] + recent).joined(separator: "\n")

        if recent.isEmpty, isPlaceholderTitle(original) {
            return "空白会话"
        }

        if let recognized = recognizedTopic(
            original: original,
            context: context,
            workingDirectory: record.workingDirectory
        ) {
            return recognized
        }

        if isPreciseTitle(original) {
            return shortened(original, limit: 18)
        }

        return compactFallback(from: context, workingDirectory: record.workingDirectory)
            ?? fallbackTitle(workingDirectory: record.workingDirectory)
    }

    private static func fingerprint(for record: ConversationRecord) -> Int {
        var hasher = Hasher()
        hasher.combine(record.title)
        hasher.combine(record.workingDirectory)
        hasher.combine(record.recentUserMessages)
        hasher.combine(record.digest?.summary)
        hasher.combine(record.digest?.currentFocus)
        hasher.combine(record.digest?.topics)
        hasher.combine(record.digest?.messageCount)
        return hasher.finalize()
    }

    private static func recognizedTopic(
        original: String,
        context: String,
        workingDirectory: String
    ) -> String? {
        let contextLower = context.lowercased()

        if contextLower.contains("worktree") {
            return containsAny(context, ["合并", "分支"]) ? "Worktree 分支管理" : "Worktree 状态梳理"
        }
        if contextLower.contains("skill"), containsAny(context, ["更新", "规则", "配置"]) {
            return "Skill 规则配置"
        }
        if context.contains("对话"), containsAny(context, ["恢复", "查找", "搜索"]),
           containsAny(contextLower, ["codex", "claude", "agent"]) {
            return "Agent 对话查找与恢复"
        }
        if context.contains("Markdown 链接"), context.contains("绝对路径") {
            return contextLower.contains(".html") ? "HTML 文件路径输出" : "文件绝对路径输出"
        }
        if let arxivID = firstMatch(in: context,
            pattern: #"(?i)arxiv(?:\.org/(?:abs|pdf)/)?[\s:/]*(\d{4}\.\d{4,6})"#,
            captureGroup: 1) {
            return "arXiv \(arxivID) 文献整理"
        }
        return nil
    }

    private static func compactFallback(from context: String, workingDirectory: String) -> String? {
        let project = projectName(from: workingDirectory)
        let entity = technicalEntity(in: context)

        if containsAny(context, ["无法", "报错", "问题", "解决", "修复", "不工作", "不能用"]) {
            return shortened(entity.map { "\($0) 问题排查" } ?? project.map { "\($0) 问题排查" } ?? "问题排查", limit: 18)
        }
        if containsAny(context, ["解释", "讲一讲", "介绍", "原理", "是什么", "怎么工作"]) {
            return shortened(entity.map { "\($0) 讲解" } ?? project.map { "\($0) 内容讲解" } ?? "概念讲解", limit: 18)
        }
        if containsAny(context, ["整理", "记录", "归档", "总结"]) {
            return shortened(entity.map { "\($0) 整理" } ?? project.map { "\($0) 资料整理" } ?? "资料整理", limit: 18)
        }
        if containsAny(context, ["优化", "改进", "调整"]) {
            return shortened(entity.map { "\($0) 优化" } ?? project.map { "\($0) 优化" } ?? "功能优化", limit: 18)
        }
        if containsAny(context, ["配置", "安装", "下载", "连接"]) {
            return shortened(entity.map { "\($0) 安装配置" } ?? project.map { "\($0) 环境配置" } ?? "环境配置", limit: 18)
        }
        if containsAny(context, ["搭建", "实现", "开发", "做出来", "生成"]) {
            return shortened(entity.map { "\($0) 功能开发" } ?? project.map { "\($0) 功能开发" } ?? "功能开发", limit: 18)
        }
        if containsAny(context, ["查找", "找到", "搜索", "在哪"]) {
            return shortened(entity.map { "\($0) 查找" } ?? project.map { "\($0) 内容查找" } ?? "内容查找", limit: 18)
        }
        if containsAny(context, ["提前了解", "小白", "前置知识"]) {
            return shortened(project.map { "\($0) 前置知识" } ?? "前置知识准备", limit: 18)
        }
        if containsAny(context, ["多少钱", "价格", "一个月"]) {
            return shortened(entity.map { "\($0) 价格查询" } ?? "订阅价格查询", limit: 18)
        }
        if let entity {
            return shortened("\(entity) 相关任务", limit: 18)
        }
        if let project {
            return shortened("\(project) 项目任务", limit: 18)
        }
        return nil
    }

    private static func cleanMessage(_ value: String) -> String {
        var text = value
        if let range = text.range(of: #"##\s*My request(?: for Codex)?\s*:\s*"#, options: .regularExpression) {
            text = String(text[range.upperBound...])
        }
        text = text.replacingOccurrences(
            of: #"(?s)^# Files mentioned by the user:.*?##\s*My request(?: for Codex)?\s*:\s*"#,
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[#*_`]+"#, with: " ", options: .regularExpression)
        return clean(text)
    }

    private static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSubstantive(_ value: String) -> Bool {
        let text = clean(value)
            .replacingOccurrences(of: #"\[Image\s*#?\d*\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard text.count >= 4 else { return false }

        let generic = [
            "继续", "好的", "好", "可以", "行", "没问题", "同意", "不同意", "知道了", "明白了",
            "再输出一次", "你想想办法", "你继续", "继续做", "开始吧", "就这样"
        ]
        if generic.contains(text) { return false }
        if text.range(of: #"^(我已经|已经).{0,10}(好|完成|配置好|弄好)(一个)?(了)?$"#, options: .regularExpression) != nil {
            return false
        }
        return true
    }

    private static func isPreciseTitle(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 22 else { return false }
        let lower = value.lowercased()
        if lower.hasPrefix("http") || value.hasPrefix("/") || value.hasPrefix("[Image") { return false }
        let genericTitles = [
            "你好", "解释", "解释任务内容", "为项目命名", "这是不是错了", "在做什么", "处理这个问题",
            "帮我看一下这个问题", "未命名会话", "新对话", "new chat", "new-chat"
        ]
        if genericTitles.contains(where: { lower == $0.lowercased() }) { return false }
        let rawPromptPrefixes = [
            "你现在", "请你", "帮我", "给我", "我需要", "我希望", "我想让", "我会", "我之前",
            "网上有", "这是不是", "能不能", "不要运行", "Do not", "Files mentioned"
        ]
        if rawPromptPrefixes.contains(where: { value.hasPrefix($0) }) { return false }
        if containsAny(value, ["吗", "什么", "怎么", "为什么", "是否", "是不是"]) { return false }
        return true
    }

    private static func isPlaceholderTitle(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return ["", "你好", "未命名会话", "新对话", "new chat", "new-chat"]
            .contains(normalized)
    }

    private static func technicalEntity(in value: String) -> String? {
        let sanitized = value
            .replacingOccurrences(of: #"https?://\S+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?:/[^\s/]+){2,}"#, with: " ", options: .regularExpression)
        let matches = allMatches(in: sanitized, pattern: #"[A-Za-z][A-Za-z0-9_.-]{2,}"#)
        let ignored = Set([
            "the", "and", "for", "with", "from", "this", "that", "what", "why", "how",
            "request", "codex", "claude", "image", "users", "desktop", "documents", "project",
            "files", "mentioned", "user", "https", "http", "com", "html", "markdown",
            "library", "private", "var", "tmp", "worktree", "main", "source", "sources"
        ])
        return matches.first { candidate in
            !ignored.contains(candidate.lowercased())
                && (candidate.range(of: #"[A-Z0-9_.-]"#, options: .regularExpression) != nil
                    || candidate.count >= 5)
        }
    }

    private static func firstMatch(
        in value: String,
        pattern: String,
        captureGroup: Int
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              captureGroup < match.numberOfRanges,
              let captureRange = Range(match.range(at: captureGroup), in: value)
        else { return nil }
        return String(value[captureRange])
    }

    private static func allMatches(in value: String, pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: value) else { return nil }
            return String(value[matchRange])
        }
    }

    private static func clauseScore(_ value: String) -> Int {
        var score = min(value.count, 36)
        if value.count >= 8 && value.count <= 30 { score += 18 }
        if value.range(of: #"[A-Za-z]{2,}|\d+|\.\w{2,4}"#, options: .regularExpression) != nil { score += 7 }
        if containsAny(value, ["优化", "修复", "整理", "配置", "下载", "查找", "更新", "生成", "实现", "跑通", "解释", "对比", "设计"]) {
            score += 8
        }
        if value.hasPrefix("你") || value.hasPrefix("我觉得") || value.hasPrefix("我感觉") { score -= 4 }
        return score
    }

    private static func shortened(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let prefix = String(value.prefix(limit))
        let separators = ["，", ",", "：", ":"]
        for separator in separators {
            if let range = prefix.range(of: separator, options: .backwards),
               prefix.distance(from: prefix.startIndex, to: range.lowerBound) >= 10 {
                return String(prefix[..<range.lowerBound])
            }
        }
        return prefix + "…"
    }

    private static func fallbackTitle(workingDirectory: String) -> String {
        if let project = projectName(from: workingDirectory) {
            return "\(project) · 未命名会话"
        }
        return "未命名会话"
    }

    private static func projectName(from path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let value = URL(fileURLWithPath: path).lastPathComponent
        guard !value.isEmpty, value != "/" else { return nil }
        return value
    }

    private static func containsAll(_ value: String, _ needles: [String]) -> Bool {
        needles.allSatisfy(value.contains)
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains(where: value.contains)
    }

    private static let cache = TitleCache()
}

private final class TitleCache: @unchecked Sendable {
    private struct Entry {
        let fingerprint: Int
        let presentation: ConversationTitlePresentation
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func value(for storageKey: String, fingerprint: Int) -> ConversationTitlePresentation? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[storageKey], entry.fingerprint == fingerprint else { return nil }
        return entry.presentation
    }

    func insert(_ presentation: ConversationTitlePresentation, for storageKey: String, fingerprint: Int) {
        lock.lock()
        entries[storageKey] = Entry(fingerprint: fingerprint, presentation: presentation)
        lock.unlock()
    }
}
