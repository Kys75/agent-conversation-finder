import Foundation

public struct ConversationCacheStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
            self.fileURL = applicationSupport
                .appendingPathComponent("Agent Conversation Finder", isDirectory: true)
                .appendingPathComponent("index-v1.json")
        }
    }

    public func load() throws -> ConversationCache? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let cache = try JSONDecoder().decode(ConversationCache.self, from: data)
        let records = cache.records.map { record in
            var record = record
            record.digest = record.digest?.sanitizingDisplayText()
            return record
        }
        return ConversationCache(
            schemaVersion: cache.schemaVersion,
            refreshedAt: cache.refreshedAt,
            records: records,
            warnings: cache.warnings
        )
    }

    public func save(_ cache: ConversationCache) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let data = try JSONEncoder().encode(cache)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )
    }
}
