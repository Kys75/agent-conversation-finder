import Foundation

public struct CodexSourceConfiguration: Sendable {
    public let homeURL: URL
    public let environment: ConversationEnvironment
    public let route: CommandRoute
    public let storageKeyPrefix: String
    public let displayName: String

    public static func openAI(homeURL: URL) -> CodexSourceConfiguration {
        CodexSourceConfiguration(
            homeURL: homeURL,
            environment: .openAI,
            route: .codexOpenAI,
            storageKeyPrefix: "codex-openai:",
            displayName: "Codex · OpenAI"
        )
    }

    public static func secondary(homeURL: URL) -> CodexSourceConfiguration {
        CodexSourceConfiguration(
            homeURL: homeURL,
            environment: .secondary,
            route: .codexSecondary,
            storageKeyPrefix: "codex-secondary:",
            displayName: "Codex · Secondary"
        )
    }
}

public struct CodexScanner: ConversationScanning, Sendable {
    public let configuration: CodexSourceConfiguration

    public var displayName: String { configuration.displayName }
    public var storageKeyPrefix: String { configuration.storageKeyPrefix }

    public init(configuration: CodexSourceConfiguration) {
        self.configuration = configuration
    }

    public func scan(previousRecords: [ConversationRecord]) throws -> ScanOutcome {
        guard FileManager.default.fileExists(atPath: configuration.homeURL.path) else {
            throw ScannerError.missingDirectory(configuration.homeURL.path)
        }

        let names = sessionNames()
        if let database = databaseURL() {
            do {
                let rows = try databaseRows(database: database)
                let previousByStorageKey = Dictionary(
                    uniqueKeysWithValues: previousRecords.map { ($0.storageKey, $0) }
                )
                let databaseRecords = rows.compactMap {
                        record(
                            from: $0,
                            sessionNames: names,
                            previousRecord: previousByStorageKey[configuration.storageKeyPrefix + $0.id]
                        )
                    }
                let currentByKey = previousByStorageKey.merging(
                    Dictionary(uniqueKeysWithValues: databaseRecords.map { ($0.storageKey, $0) }),
                    uniquingKeysWith: { _, current in current }
                )
                let files = try fallbackRecords(sessionNames: names, previousRecords: Array(currentByKey.values))
                let merged = Dictionary(uniqueKeysWithValues: files.map { ($0.storageKey, $0) })
                    .merging(Dictionary(uniqueKeysWithValues: databaseRecords.map { ($0.storageKey, $0) }),
                             uniquingKeysWith: { file, database in
                                 guard database.integrity == .missingTranscript, file.integrity != .missingTranscript else { return database }
                                 var recovered = file
                                 recovered.title = database.title
                                 recovered.archived = database.archived
                                 return recovered
                             })
                let missing = databaseRecords.filter { $0.integrity == .missingTranscript }.count
                return ScanOutcome(records: ConversationSort.lastActivityDescending.sorted(Array(merged.values)),
                    warnings: missing == 0 ? [] : ["\(displayName)：\(missing) 条索引记录的正文缺失或不在该来源目录内；已检查本地会话文件"])
            } catch {
                let fallback = try fallbackRecords(sessionNames: names, previousRecords: previousRecords)
                return ScanOutcome(
                    records: fallback,
                    warnings: ["\(displayName)：索引读取失败，已改用会话文件扫描（\(error.localizedDescription)）"]
                )
            }
        }

        return ScanOutcome(records: try fallbackRecords(sessionNames: names, previousRecords: previousRecords))
    }

    private func databaseURL() -> URL? {
        let primary = configuration.homeURL.appendingPathComponent("state_5.sqlite")
        if SourceBoundary.contains(primary, root: configuration.homeURL), FileManager.default.fileExists(atPath: primary.path) { return primary }
        let legacy = configuration.homeURL.appendingPathComponent("sqlite/state_5.sqlite")
        return SourceBoundary.contains(legacy, root: configuration.homeURL) && FileManager.default.fileExists(atPath: legacy.path) ? legacy : nil
    }

    private func databaseRows(database: URL) throws -> [CodexDatabaseRow] {
        let query = """
            SELECT id, rollout_path,
                   COALESCE(created_at_ms, created_at * 1000) AS created_at_ms,
                   COALESCE(updated_at_ms, updated_at * 1000) AS updated_at_ms,
                   source, cwd, title, archived
            FROM threads
            WHERE source IN ('cli', 'vscode')
            ORDER BY updated_at_ms DESC;
            """

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentConversationFinder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("stdout")
        let errorURL = temporaryDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", database.path, query]
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()
        process.waitUntilExit()
        try outputHandle.close()
        try errorHandle.close()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
            throw ScannerError.sqlite(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let data = try Data(contentsOf: outputURL)
        if data.isEmpty { return [] }
        return try JSONDecoder().decode([CodexDatabaseRow].self, from: data)
    }

    private func record(
        from row: CodexDatabaseRow,
        sessionNames: [String: String],
        previousRecord: ConversationRecord?
    ) -> ConversationRecord? {
        guard let source = source(for: row.source) else { return nil }
        if configuration.environment == .secondary && source != .codexCLI { return nil }

        let createdAt = Date(timeIntervalSince1970: Double(row.createdAtMilliseconds) / 1_000)
        let updatedAt = Date(timeIntervalSince1970: Double(row.updatedAtMilliseconds) / 1_000)
        let transcriptURL = resolveTranscriptPath(row.rolloutPath)
        let previousCheckpoint = previousRecord?.digest?.checkpoint
        let currentFileSize = transcriptURL.flatMap { url in
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init)
        }
        let databaseChanged = previousRecord?.databaseUpdatedAt != updatedAt
        let fileWasAppended = currentFileSize.map { $0 > (previousCheckpoint?.fileSize ?? $0) } ?? false
        let previousDigestRecord = databaseChanged && !fileWasAppended ? nil : previousRecord
        let transcript = transcriptURL.flatMap {
            parseTranscript(at: $0, previousRecord: previousDigestRecord)
        }
        let cwd = row.cwd.isEmpty
            ? (transcript?.cwd ?? previousRecord?.workingDirectory ?? "")
            : row.cwd
        let fallbackTitle = transcript?.digest.firstUserMessage ?? previousRecord?.digest?.firstUserMessage
        let title = ConversationText.title(from: row.title.isEmpty
            ? (sessionNames[row.id] ?? fallbackTitle ?? previousRecord?.title)
            : row.title)
        let integrity: ConversationIntegrity
        if transcriptURL == nil {
            integrity = .missingTranscript
        } else if transcript == nil {
            integrity = .missingTranscript
        } else {
            integrity = transcript?.malformedLineCount == 0 ? .complete : .partial
        }
        let transcriptUpdatedAt = transcript?.digest.lastTranscriptActivityAt
            ?? previousRecord?.transcriptUpdatedAt
        let fileModifiedAt = transcript?.fileModifiedAt
            ?? previousRecord?.transcriptFileModifiedAt
        let activity = ConversationActivity.latest(
            transcript: transcriptUpdatedAt,
            database: updatedAt,
            file: fileModifiedAt,
            fallback: createdAt
        )
        let digest = transcript?.digest ?? previousRecord?.digest

        return ConversationRecord(
            sessionID: row.id,
            storageKey: configuration.storageKeyPrefix + row.id,
            title: title,
            workingDirectory: cwd,
            source: source,
            environment: configuration.environment,
            createdAt: transcript?.createdAt ?? previousRecord?.createdAt ?? createdAt,
            lastConversationAt: activity.date,
            recentUserMessages: digest?.recentUserMessages ?? previousRecord?.recentUserMessages ?? [],
            digest: digest,
            lastActivitySource: activity.source,
            databaseUpdatedAt: updatedAt,
            transcriptUpdatedAt: transcriptUpdatedAt,
            transcriptFileModifiedAt: fileModifiedAt,
            archived: row.archived != 0,
            integrity: integrity,
            route: configuration.route,
            workingDirectoryExists: FileManager.default.fileExists(atPath: cwd)
        )
    }

    private func resolveTranscriptPath(_ path: String) -> URL? {
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : configuration.homeURL.appendingPathComponent(path)
        if SourceBoundary.contains(url, root: configuration.homeURL), FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // A copied index may still use its old absolute root. Relocate only known session trees.
        let components = url.pathComponents
        if path.hasPrefix("/"), let index = components.firstIndex(where: { ["sessions", "archived_sessions"].contains($0) }) {
            let relocated = components[index...].reduce(configuration.homeURL) { $0.appendingPathComponent($1) }
            if SourceBoundary.contains(relocated, root: configuration.homeURL), FileManager.default.fileExists(atPath: relocated.path) {
                return relocated
            }
        }
        return nil
    }

    private func fallbackRecords(
        sessionNames: [String: String],
        previousRecords: [ConversationRecord]
    ) throws -> [ConversationRecord] {
        var urls: [URL] = []
        for directoryName in ["sessions", "archived_sessions"] {
            let directory = configuration.homeURL.appendingPathComponent(directoryName)
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard SourceBoundary.contains(url, root: configuration.homeURL) else { continue }
                urls.append(url)
            }
        }

        let previousByPath: [String: ConversationRecord] = Dictionary(
            uniqueKeysWithValues: previousRecords.compactMap { record -> (String, ConversationRecord)? in
                guard let path = record.digest?.checkpoint.path else { return nil }
                return (path, record)
            }
        )
        var recordsByID: [String: ConversationRecord] = [:]
        for url in urls {
            let previousRecord = previousByPath[url.path]
            guard let transcript = parseTranscript(at: url, previousRecord: previousRecord),
                  let sessionID = transcript.sessionID,
                  let sourceName = transcript.source,
                  let source = source(for: sourceName)
            else { continue }
            if configuration.environment == .secondary && source != .codexCLI { continue }

            let createdAt = transcript.createdAt
                ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? Date.distantPast
            let activity = ConversationActivity.latest(
                transcript: transcript.digest.lastTranscriptActivityAt,
                file: transcript.fileModifiedAt,
                fallback: createdAt
            )
            let cwd = transcript.cwd ?? ""
            let record = ConversationRecord(
                sessionID: sessionID,
                storageKey: configuration.storageKeyPrefix + sessionID,
                title: ConversationText.title(from: sessionNames[sessionID] ?? transcript.digest.firstUserMessage),
                workingDirectory: cwd,
                source: source,
                environment: configuration.environment,
                createdAt: createdAt,
                lastConversationAt: activity.date,
                recentUserMessages: transcript.digest.recentUserMessages,
                digest: transcript.digest,
                lastActivitySource: activity.source,
                transcriptUpdatedAt: transcript.digest.lastTranscriptActivityAt,
                transcriptFileModifiedAt: transcript.fileModifiedAt,
                archived: url.pathComponents.contains("archived_sessions"),
                integrity: transcript.malformedLineCount == 0 ? .complete : .partial,
                route: configuration.route,
                workingDirectoryExists: FileManager.default.fileExists(atPath: cwd)
            )
            if let existing = recordsByID[sessionID], existing.lastConversationAt > record.lastConversationAt {
                continue
            }
            recordsByID[sessionID] = record
        }
        return recordsByID.values.sorted { $0.lastConversationAt > $1.lastConversationAt }
    }

    private func parseTranscript(at url: URL, previousRecord: ConversationRecord?) -> CodexTranscript? {
        guard let fileState = TranscriptFileState(url: url) else { return nil }
        let canContinue = fileState.canContinue(from: previousRecord?.digest)
        let previousDigest = canContinue ? previousRecord?.digest : nil
        var transcript = CodexTranscript(
            sessionID: canContinue ? previousRecord?.sessionID : nil,
            cwd: canContinue ? previousRecord?.workingDirectory : nil,
            source: canContinue ? rawSource(for: previousRecord?.source) : nil,
            createdAt: canContinue ? previousRecord?.createdAt : nil,
            malformedLineCount: canContinue && previousRecord?.integrity == .partial ? 1 : 0
        )
        var builder = ConversationDigestBuilder(previous: previousDigest)
        var messageFormat = previousDigest?.checkpoint.codexMessageFormat
        do {
            let result = try JSONLReader.readObjects(
                at: url,
                fromOffset: previousDigest?.checkpoint.byteOffset ?? 0,
                shouldParse: Self.shouldParseTranscriptLine
            ) { object in
                let type = object["type"] as? String
                let timestamp = ConversationDate.parse(object["timestamp"])

                if type == "session_meta", let payload = object["payload"] as? [String: Any] {
                    transcript.sessionID = (payload["id"] as? String) ?? (payload["session_id"] as? String)
                    transcript.cwd = payload["cwd"] as? String
                    transcript.source = payload["source"] as? String
                    transcript.createdAt = ConversationDate.parse(payload["timestamp"]) ?? timestamp
                    return
                }

                if type == "response_item", let payload = object["payload"] as? [String: Any],
                   payload["type"] as? String == "message",
                   let role = payload["role"] as? String, role == "user" || role == "assistant" {
                    if messageFormat == nil { messageFormat = "response_item" }
                    guard messageFormat == "response_item" else { return }
                    let content = payload["content"] as? [[String: Any]] ?? []
                    let text = content.compactMap { block -> String? in
                        guard ["input_text", "output_text", "text"].contains(block["type"] as? String ?? "") else { return nil }
                        return block["text"] as? String
                    }.joined(separator: "\n")
                    if role == "user" { builder.appendUserMessage(text, timestamp: timestamp) }
                    else { builder.appendAssistantMessage(text, timestamp: timestamp) }
                    return
                }
                guard type == "event_msg", let payload = object["payload"] as? [String: Any],
                      let eventType = payload["type"] as? String,
                      eventType == "user_message" || eventType == "agent_message"
                else { return }
                if messageFormat == nil { messageFormat = "event_msg" }
                guard messageFormat == "event_msg" else { return }
                if eventType == "user_message", let message = payload["message"] as? String {
                    builder.appendUserMessage(message, timestamp: timestamp)
                } else if eventType == "agent_message" {
                    builder.appendAssistantMessage(payload["message"] as? String, timestamp: timestamp)
                }
            }
            transcript.malformedLineCount += result.malformedLineCount
            var checkpoint = fileState.checkpoint(finalOffset: result.finalOffset)
            checkpoint.codexMessageFormat = messageFormat
            transcript.digest = builder.finish(checkpoint: checkpoint)
            transcript.fileModifiedAt = fileState.modifiedAt
            return transcript
        } catch {
            return nil
        }
    }

    private func source(for rawValue: String) -> ConversationSource? {
        switch rawValue {
        case "vscode": return .codexApp
        case "cli": return .codexCLI
        default: return nil
        }
    }

    private static func shouldParseTranscriptLine(_ data: Data.SubSequence) -> Bool {
        let prefix = data.prefix(16 * 1024)
        if firstRange(of: sessionMetaMarkers, in: prefix) != nil { return true }
        if prefix.range(of: Data(#""type":"response_item""#.utf8)) != nil
            || prefix.range(of: Data(#""type": "response_item""#.utf8)) != nil {
            return prefix.range(of: Data(#""type":"message""#.utf8)) != nil
                || prefix.range(of: Data(#""type": "message""#.utf8)) != nil
        }
        guard let eventRange = firstRange(of: eventMessageMarkers, in: prefix),
              let payloadRange = firstRange(of: payloadMarkers, in: prefix),
              data.count < 64 * 1024 || eventRange.lowerBound < payloadRange.lowerBound
        else { return false }
        return firstRange(of: userMessageMarkers, in: prefix) != nil
            || firstRange(of: agentMessageMarkers, in: prefix) != nil
    }

    private static func firstRange(
        of markers: [Data],
        in data: Data.SubSequence
    ) -> Range<Data.Index>? {
        markers.compactMap { data.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
    }

    private static let sessionMetaMarkers = [
        Data(#""type":"session_meta""#.utf8),
        Data(#""type": "session_meta""#.utf8)
    ]
    private static let eventMessageMarkers = [
        Data(#""type":"event_msg""#.utf8),
        Data(#""type": "event_msg""#.utf8)
    ]
    private static let payloadMarkers = [
        Data(#""payload":"#.utf8),
        Data(#""payload": "#.utf8)
    ]
    private static let userMessageMarkers = [
        Data(#""type":"user_message""#.utf8),
        Data(#""type": "user_message""#.utf8)
    ]
    private static let agentMessageMarkers = [
        Data(#""type":"agent_message""#.utf8),
        Data(#""type": "agent_message""#.utf8)
    ]

    private func rawSource(for source: ConversationSource?) -> String? {
        switch source {
        case .codexApp: return "vscode"
        case .codexCLI: return "cli"
        default: return nil
        }
    }

    private func sessionNames() -> [String: String] {
        let url = configuration.homeURL.appendingPathComponent("session_index.jsonl")
        guard SourceBoundary.contains(url, root: configuration.homeURL), FileManager.default.fileExists(atPath: url.path) else { return [:] }
        var result: [String: String] = [:]
        _ = try? JSONLReader.readObjects(at: url) { object in
            if let id = object["id"] as? String,
               let name = object["thread_name"] as? String,
               !name.isEmpty {
                result[id] = name
            }
        }
        return result
    }
}

private struct CodexDatabaseRow: Decodable {
    let id: String
    let rolloutPath: String
    let createdAtMilliseconds: Int64
    let updatedAtMilliseconds: Int64
    let source: String
    let cwd: String
    let title: String
    let archived: Int

    enum CodingKeys: String, CodingKey {
        case id
        case rolloutPath = "rollout_path"
        case createdAtMilliseconds = "created_at_ms"
        case updatedAtMilliseconds = "updated_at_ms"
        case source, cwd, title, archived
    }
}

private struct CodexTranscript {
    var sessionID: String?
    var cwd: String?
    var source: String?
    var createdAt: Date?
    var digest: ConversationDigest!
    var fileModifiedAt: Date?
    var malformedLineCount = 0
}

func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
    switch (lhs, rhs) {
    case let (lhs?, rhs?): return max(lhs, rhs)
    case let (lhs?, nil): return lhs
    case let (nil, rhs?): return rhs
    case (nil, nil): return nil
    }
}

enum ScannerError: LocalizedError {
    case missingDirectory(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .missingDirectory(let path): return "目录不存在：\(path)"
        case .sqlite(let message): return message.isEmpty ? "SQLite 读取失败" : message
        }
    }
}
