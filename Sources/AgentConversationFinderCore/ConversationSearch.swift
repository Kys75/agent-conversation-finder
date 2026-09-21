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
        let searchableText = ([
            alias ?? "",
            presentation.title,
            record.title,
            record.workingDirectory,
            record.sessionID,
            record.source.displayName,
            record.environment.displayName,
            digest?.summary ?? "",
            digest?.currentFocus ?? "",
            digest?.topics.joined(separator: " ") ?? "",
            digest?.milestones.joined(separator: "\n") ?? "",
            digest?.openQuestions.joined(separator: "\n") ?? "",
            digest?.searchableText ?? ""
        ] + record.recentUserMessages)
            .map(normalized)
            .joined(separator: "\n")

        return tokens.allSatisfy(searchableText.contains)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "zh_CN")
        )
    }
}
