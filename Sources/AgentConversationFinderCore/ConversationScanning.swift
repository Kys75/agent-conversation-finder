import Foundation

public protocol ConversationScanning: Sendable {
    var displayName: String { get }
    var storageKeyPrefix: String { get }
    func scan(previousRecords: [ConversationRecord]) throws -> ScanOutcome
}

public extension ConversationScanning {
    func scan() throws -> ScanOutcome {
        try scan(previousRecords: [])
    }
}

public struct ConversationIndexService: Sendable {
    public let scanners: [any ConversationScanning]

    public init(scanners: [any ConversationScanning]) {
        self.scanners = scanners
    }

    public static func live(configuration: RuntimeConfiguration = RuntimeConfiguration()) -> ConversationIndexService {
        var scanners: [any ConversationScanning] = [
            CodexScanner(configuration: .openAI(homeURL: configuration.codexHome)),
            ClaudeScanner(homeURL: configuration.claudeHome)
        ]
        if let home = configuration.secondaryCodexHome {
            scanners.append(CodexScanner(configuration: .secondary(homeURL: home)))
        }
        return ConversationIndexService(scanners: scanners)
    }

    public func refresh(previousRecords: [ConversationRecord]) -> ScanOutcome {
        var records: [ConversationRecord] = []
        var warnings: [String] = []

        for scanner in scanners {
            do {
                let previousForSource = previousRecords.filter {
                    $0.storageKey.hasPrefix(scanner.storageKeyPrefix)
                }
                let outcome = try scanner.scan(previousRecords: previousForSource)
                records.append(contentsOf: outcome.records)
                warnings.append(contentsOf: outcome.warnings)
            } catch {
                records.append(contentsOf: previousRecords.filter {
                    $0.storageKey.hasPrefix(scanner.storageKeyPrefix)
                })
                warnings.append("\(scanner.displayName)：刷新失败，已保留上次结果（\(error.localizedDescription)）")
            }
        }

        return ScanOutcome(
            records: ConversationSort.lastActivityDescending.sorted(records),
            warnings: warnings
        )
    }
}
