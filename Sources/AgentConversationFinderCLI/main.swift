import AgentConversationFinderCore
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let usage = """
acf doctor
acf scan [--query TEXT] [--json]

doctor validates configuration and reports local paths; it does not read conversations.
scan reads local conversations and prints results; it never executes recovery commands.
--query uses space-separated AND matching; --json emits records and warnings as JSON.
Configuration: ACF_CONFIG or ~/Library/Application Support/Agent Conversation Finder Shared/config.json
Output may contain private conversation content. Do not upload it or save it in this repository.
"""

do {
    if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] {
        print(usage)
        exit(0)
    }
    let configuration = try RuntimeConfiguration.load()
    if arguments == ["doctor"] {
        for (name, url) in [("Codex", configuration.codexHome), ("Claude", configuration.claudeHome)] {
            print("\(name): \(FileManager.default.fileExists(atPath: url.path) ? "exists" : "missing") \(url.path)")
        }
        if let secondary = configuration.secondaryCodexHome { print("Secondary Codex: \(secondary.path)") }
        print("State: \(configuration.profileStateDirectory.path)")
        print("Codex archive executable: \(configuration.resolvedCodexExecutable()?.path ?? "not found; set codexExecutable")")
        exit(0)
    }
    guard arguments.first == "scan" else { throw ConfigurationError.invalid(usage) }
    var query = ""
    var json = false
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--json": json = true
        case "--query":
            index += 1
            guard index < arguments.count else { throw ConfigurationError.invalid("--query needs text") }
            query = arguments[index]
        default: throw ConfigurationError.invalid("Unknown argument: \(arguments[index])")
        }
        index += 1
    }
    let outcome = ConversationIndexService.live(configuration: configuration).refresh(previousRecords: [])
    let records = outcome.records.filter { ConversationSearch.matches($0, query: query) }
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let result = ConversationCache(refreshedAt: Date(), records: records, warnings: outcome.warnings)
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    } else {
        for record in records {
            print("\(record.storageKey)\t\(ConversationTitleGenerator.displayTitle(for: record))\t\(record.workingDirectory)")
        }
        for warning in outcome.warnings { FileHandle.standardError.write(Data((warning + "\n").utf8)) }
    }
} catch {
    FileHandle.standardError.write(Data(("acf: \(error.localizedDescription)\n").utf8))
    exit(1)
}
