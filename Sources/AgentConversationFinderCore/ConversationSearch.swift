import Foundation

public enum ConversationSearch {
    public static func matches(
        _ record: ConversationRecord,
        query: String,
        alias: String? = nil
    ) -> Bool {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map(normalized)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return true }

        let presentation = ConversationTitleGenerator.presentation(for: record)
        let digest = record.digest
        var fields: [String] = [
            alias ?? "",
            presentation.title,
            record.title,
            record.workingDirectory,
            record.sessionID,
            record.source.displayName,
            record.environment.displayName
        ]
        fields.append(digest?.summary ?? "")
        fields.append(digest?.currentFocus ?? "")
        fields.append(digest?.topics.joined(separator: " ") ?? "")
        fields.append(digest?.milestones.joined(separator: "\n") ?? "")
        fields.append(digest?.openQuestions.joined(separator: "\n") ?? "")
        fields.append(digest?.searchableText ?? "")
        fields.append(contentsOf: record.recentUserMessages)
        let normalizedFields: [String] = fields.map(normalized)
        let searchableText = normalizedFields.joined(separator: "\n")

        return tokens.allSatisfy(searchableText.contains)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "zh_CN")
        )
    }
}
