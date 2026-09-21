import Foundation

enum SourceBoundary {
    static func contains(_ url: URL, root: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}
