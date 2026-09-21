import Foundation

enum DisplayTextSanitizer {
    static func sanitize(_ value: String) -> String {
        var result = replacingMatches(in: value, expression: dataURIExpression) { _ in
            "[内嵌数据]"
        }
        result = replacingMatches(in: result, expression: URLExpression, transform: compactURL)
        result = replacingMatches(in: result, expression: quotedUnixPathExpression, transform: compactPath)
        result = replacingMatches(in: result, expression: unixPathExpression, transform: compactPath)
        result = replacingMatches(in: result, expression: quotedTildePathExpression, transform: compactPath)
        result = replacingMatches(in: result, expression: tildePathExpression, transform: compactPath)
        result = replacingMatches(in: result, expression: quotedWindowsPathExpression, transform: compactPath)
        result = replacingMatches(in: result, expression: windowsPathExpression, transform: compactPath)
        return result
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitizeTopic(_ value: String) -> String? {
        let result = sanitize(value)
        let ignored = Set([
            "http", "https", "www", "com", "net", "org",
            "users", "desktop", "documents", "downloads", "tmp", "var", "usr"
        ])
        guard !result.isEmpty, !ignored.contains(result.lowercased()) else { return nil }
        return result
    }

    private static func compactURL(_ match: String) -> String {
        let (rawURL, trailingPunctuation) = splitTrailingPunctuation(from: match)
        let parseable = rawURL.lowercased().hasPrefix("www.") ? "https://" + rawURL : rawURL
        guard let components = URLComponents(string: parseable),
              let host = components.host?.lowercased(), !host.isEmpty
        else {
            return "[链接]" + trailingPunctuation
        }

        var label = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let port = components.port,
           !((components.scheme == "http" && port == 80) || (components.scheme == "https" && port == 443)) {
            label += ":\(port)"
        }

        let pathComponents = components.path
            .split(separator: "/")
            .compactMap { String($0).removingPercentEncoding }
            .filter { !$0.isEmpty }
        let usefulPath: [String]
        if label == "github.com" || label == "gitlab.com" {
            usefulPath = Array(pathComponents.prefix(4))
        } else if let last = pathComponents.last,
                  isUsefulURLPathComponent(last) {
            usefulPath = [last]
        } else {
            usefulPath = []
        }
        if !usefulPath.isEmpty {
            label += "/" + usefulPath.map(compactComponent).joined(separator: "/")
        }
        return "[链接：\(label)]" + trailingPunctuation
    }

    private static func compactPath(_ match: String) -> String {
        let unquoted = match.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let normalized = (unquoted.removingPercentEncoding ?? unquoted)
            .replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return "[路径]" }

        let leaf = components.last.map(compactComponent) ?? "路径"
        let genericParents = Set([
            "Desktop", "Documents", "Downloads", "tmp", "private", "var", "Users", "home"
        ])
        let suffix: String
        if components.count > 1 {
            let parent = compactComponent(components[components.count - 2])
            suffix = genericParents.contains(parent) ? leaf : parent + "/" + leaf
        } else {
            suffix = leaf
        }
        return "[路径：…/\(suffix)]"
    }

    private static func compactComponent(_ value: String) -> String {
        guard value.count > 40 else { return value }
        return String(value.prefix(18)) + "…" + String(value.suffix(12))
    }

    private static func isUsefulURLPathComponent(_ value: String) -> Bool {
        let lower = value.lowercased()
        let generic = Set(["index", "index.html", "home", "page", "view", "search"])
        guard !generic.contains(lower), value.count <= 80 else { return false }
        let alphanumericCount = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.count
        return alphanumericCount >= 2
    }

    private static func splitTrailingPunctuation(from value: String) -> (String, String) {
        var body = value
        var trailing = ""
        let punctuation = CharacterSet(charactersIn: ".,;:!?)]}")
        while let scalar = body.unicodeScalars.last, punctuation.contains(scalar) {
            trailing.insert(Character(String(scalar)), at: trailing.startIndex)
            body.removeLast()
        }
        return (body, trailing)
    }

    private static func replacingMatches(
        in value: String,
        expression: NSRegularExpression,
        transform: (String) -> String
    ) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = expression.matches(in: value, range: range)
        guard !matches.isEmpty else { return value }

        var result = value
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            let replacement = transform(String(result[swiftRange]))
            result.replaceSubrange(swiftRange, with: replacement)
        }
        return result
    }

    private static let dataURIExpression = try! NSRegularExpression(
        pattern: #"(?i)data:(?:image|application|text)/[^\s,;]+(?:;[^,\s]+)*,[A-Za-z0-9+/_=%-]{32,}"#
    )
    private static let URLExpression = try! NSRegularExpression(
        pattern: #"(?i)(?:https?://|www\.)[^\s<>\"'，。！？；、）】\]\}]+"#
    )
    private static let quotedUnixPathExpression = try! NSRegularExpression(
        pattern: #"(?i)([\"'])(/(?:Users|Volumes|Applications|Library|System|private|tmp|var|opt|usr|etc|home)/[^\"'\r\n]+)\1"#
    )
    private static let unixPathExpression = try! NSRegularExpression(
        pattern: #"(?i)(?<![:\p{L}\p{N}_])/(?:Users|Volumes|Applications|Library|System|private|tmp|var|opt|usr|etc|home)/[^\s\"'<>，。！？；、）】\)\]\}]+"#
    )
    private static let quotedTildePathExpression = try! NSRegularExpression(
        pattern: #"([\"'])(~/[^\"'\r\n]+)\1"#
    )
    private static let tildePathExpression = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_])~/[^\s\"'<>，。！？；、）】\)\]\}]+"#
    )
    private static let quotedWindowsPathExpression = try! NSRegularExpression(
        pattern: #"(?i)([\"'])([A-Z]:\\[^\"'\r\n]+)\1"#
    )
    private static let windowsPathExpression = try! NSRegularExpression(
        pattern: #"(?i)(?<![\p{L}\p{N}_])[A-Z]:\\[^\s\"'<>，。！？；、）】\)\]\}]+"#
    )
}
