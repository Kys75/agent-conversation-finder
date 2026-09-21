import Foundation

public struct ClaudeScanner: ConversationScanning, Sendable {
    public let homeURL: URL
    public let storageKeyPrefix = "claude:"
    public let displayName = "Claude Code"

    public init(homeURL: URL) {
        self.homeURL = homeURL
    }

    public func scan(previousRecords: [ConversationRecord]) throws -> ScanOutcome {
        let projects = homeURL.appendingPathComponent("projects")
        guard FileManager.default.fileExists(atPath: projects.path) else {
            throw ScannerError.missingDirectory(projects.path)
        }

        let history = historyMessages()
        guard let enumerator = FileManager.default.enumerator(
            at: projects,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return ScanOutcome(records: []) }

        var recordsByID: [String: ConversationRecord] = [:]
        var warnings: [String] = []
        let previousByStorageKey = Dictionary(
            uniqueKeysWithValues: previousRecords.map { ($0.storageKey, $0) }
        )
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard SourceBoundary.contains(url, root: homeURL) else { continue }
            if url.pathComponents.contains("subagents") { continue }
            let sessionIDFromFile = url.deletingPathExtension().lastPathComponent
            let previousRecord = previousByStorageKey[storageKeyPrefix + sessionIDFromFile]
            guard let transcript = parseTranscript(at: url, previousRecord: previousRecord),
                  let sessionID = transcript.sessionID
            else { continue }

            let messageHistory = history[sessionID]?.sorted { $0.timestamp < $1.timestamp } ?? []
            let recentMessages = Array(messageHistory.compactMap(\.text).suffix(3))
            let fallbackMessages = recentMessages.isEmpty ? transcript.digest.recentUserMessages : recentMessages
            let fileCreation = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? nil
            let createdAt = transcript.createdAt ?? fileCreation ?? Date.distantPast
            let historyLast = messageHistory.last?.timestamp
            let activity = ConversationActivity.latest(
                transcript: transcript.digest.lastTranscriptActivityAt,
                history: historyLast,
                file: transcript.fileModifiedAt,
                fallback: createdAt
            )
            let cwd = transcript.cwd ?? messageHistory.last?.project ?? ""

            let record = ConversationRecord(
                sessionID: sessionID,
                storageKey: storageKeyPrefix + sessionID,
                title: ConversationText.title(from: transcript.title ?? fallbackMessages.first),
                workingDirectory: cwd,
                source: .claudeCode,
                environment: .claude,
                createdAt: createdAt,
                lastConversationAt: activity.date,
                recentUserMessages: fallbackMessages,
                digest: transcript.digest,
                lastActivitySource: activity.source,
                transcriptUpdatedAt: transcript.digest.lastTranscriptActivityAt,
                historyUpdatedAt: historyLast,
                transcriptFileModifiedAt: transcript.fileModifiedAt,
                archived: false,
                integrity: transcript.malformedLineCount == 0 ? .complete : .partial,
                route: .claude,
                workingDirectoryExists: FileManager.default.fileExists(atPath: cwd)
            )
            if let existing = recordsByID[sessionID], existing.lastConversationAt > record.lastConversationAt {
                continue
            }
            recordsByID[sessionID] = record
        }

        if recordsByID.isEmpty {
            warnings.append("Claude Code：没有找到可恢复的主会话文件")
        }
        return ScanOutcome(
            records: recordsByID.values.sorted { $0.lastConversationAt > $1.lastConversationAt },
            warnings: warnings
        )
    }

    private func historyMessages() -> [String: [ClaudeHistoryMessage]] {
        let url = homeURL.appendingPathComponent("history.jsonl")
        guard SourceBoundary.contains(url, root: homeURL), FileManager.default.fileExists(atPath: url.path) else { return [:] }
        var result: [String: [ClaudeHistoryMessage]] = [:]
        _ = try? JSONLReader.readObjects(at: url) { object in
            guard let sessionID = object["sessionId"] as? String,
                  let timestamp = ConversationDate.parse(object["timestamp"])
            else { return }
            let text = (object["display"] as? String).flatMap { ConversationText.preview($0) }
            let project = object["project"] as? String
            result[sessionID, default: []].append(
                ClaudeHistoryMessage(timestamp: timestamp, text: text, project: project)
            )
        }
        return result
    }

    private func parseTranscript(at url: URL, previousRecord: ConversationRecord?) -> ClaudeTranscript? {
        guard let fileState = TranscriptFileState(url: url) else { return nil }
        let canContinue = fileState.canContinue(from: previousRecord?.digest)
        let previousDigest = canContinue ? previousRecord?.digest : nil
        var transcript = ClaudeTranscript(
            sessionID: canContinue ? previousRecord?.sessionID : nil,
            cwd: canContinue ? previousRecord?.workingDirectory : nil,
            title: canContinue ? previousRecord?.title : nil,
            createdAt: canContinue ? previousRecord?.createdAt : nil,
            malformedLineCount: canContinue && previousRecord?.integrity == .partial ? 1 : 0
        )
        var builder = ConversationDigestBuilder(previous: previousDigest)
        do {
            let result = try JSONLReader.readObjects(
                at: url,
                fromOffset: previousDigest?.checkpoint.byteOffset ?? 0
            ) { object in
                if transcript.sessionID == nil { transcript.sessionID = object["sessionId"] as? String }
                if transcript.cwd == nil { transcript.cwd = object["cwd"] as? String }

                let type = object["type"] as? String
                if type == "ai-title", let title = object["aiTitle"] as? String, !title.isEmpty {
                    transcript.title = title
                    return
                }
                if type == "custom-title" {
                    let title = (object["customTitle"] as? String) ?? (object["title"] as? String)
                    if let title, !title.isEmpty { transcript.title = title }
                    return
                }

                guard object["isSidechain"] as? Bool != true,
                      type == "user" || type == "assistant"
                else { return }
                let timestamp = ConversationDate.parse(object["timestamp"])
                transcript.createdAt = minDate(transcript.createdAt, timestamp)

                if type == "user", let message = object["message"] as? [String: Any],
                   let text = humanText(from: message["content"]) {
                    builder.appendUserMessage(text, timestamp: timestamp)
                } else if type == "assistant", let message = object["message"] as? [String: Any] {
                    builder.appendAssistantMessage(humanText(from: message["content"]), timestamp: timestamp)
                }
            }
            transcript.malformedLineCount += result.malformedLineCount
            if transcript.sessionID == nil {
                transcript.sessionID = url.deletingPathExtension().lastPathComponent
            }
            transcript.digest = builder.finish(checkpoint: fileState.checkpoint(finalOffset: result.finalOffset))
            transcript.fileModifiedAt = fileState.modifiedAt
            return transcript
        } catch {
            return nil
        }
    }

    private func humanText(from content: Any?) -> String? {
        if let string = content as? String {
            let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard let blocks = content as? [[String: Any]] else { return nil }
        if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) { return nil }
        let text = blocks.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

private struct ClaudeHistoryMessage {
    let timestamp: Date
    let text: String?
    let project: String?
}

private struct ClaudeTranscript {
    var sessionID: String?
    var cwd: String?
    var title: String?
    var createdAt: Date?
    var digest: ConversationDigest!
    var fileModifiedAt: Date?
    var malformedLineCount = 0
}

private func minDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
    switch (lhs, rhs) {
    case let (lhs?, rhs?): return min(lhs, rhs)
    case let (lhs?, nil): return lhs
    case let (nil, rhs?): return rhs
    case (nil, nil): return nil
    }
}
