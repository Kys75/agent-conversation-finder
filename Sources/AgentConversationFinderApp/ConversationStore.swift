import AgentConversationFinderCore
import AppKit
import Foundation

struct ConversationFolderSummary: Identifiable, Hashable {
    let path: String
    let conversationCount: Int
    let latestConversationAt: Date
    let latestCreatedAt: Date
    let exists: Bool

    var id: String { path }
    var displayName: String {
        guard !path.isEmpty else { return "未知工作目录" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

struct ConversationManagementNotice: Identifiable, Equatable {
    enum Kind {
        case success
        case failure
    }

    let id = UUID()
    let kind: Kind
    let message: String
}

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var records: [ConversationRecord] = []
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var warnings: [String] = []
    @Published private(set) var isRefreshing = false
    @Published var filter = ConversationFilter()
    @Published var sort: ConversationSort = .lastActivityDescending
    @Published var searchQuery = ""
    @Published var selectedFolderPath: String?
    @Published var selectedID: String?
    @Published private(set) var aliases: [String: String] = [:]
    @Published var recordBeingRenamed: ConversationRecord?
    @Published var renameDraft = ""
    @Published var recordBeingArchived: ConversationRecord?
    @Published private(set) var archiveOperationID: String?
    @Published private(set) var managementNotice: ConversationManagementNotice?
    @Published private(set) var copiedID: String?

    private let cacheStore: ConversationCacheStore
    private let aliasStore: ConversationAliasStore
    private let localArchiveStore: ConversationLocalArchiveStore
    private let indexService: ConversationIndexService
    private var localArchivedIDs: Set<String> = []
    private var hadCacheAtLaunch = false

    let configuration: RuntimeConfiguration
    private var configurationFailed = false

    init() {
        let loaded: RuntimeConfiguration
        var configurationWarning: String?
        do { loaded = try RuntimeConfiguration.load() }
        catch {
            loaded = RuntimeConfiguration()
            configurationWarning = "配置读取失败；修复 config.json 后重启：\(error.localizedDescription)"
        }
        configuration = loaded
        cacheStore = ConversationCacheStore(fileURL: loaded.profileStateDirectory.appendingPathComponent("index-v1.json"))
        aliasStore = ConversationAliasStore(fileURL: loaded.profileStateDirectory.appendingPathComponent("aliases-v1.json"))
        localArchiveStore = ConversationLocalArchiveStore(fileURL: loaded.profileStateDirectory.appendingPathComponent("local-archives-v1.json"))
        indexService = .live(configuration: loaded)
        if let configurationWarning {
            configurationFailed = true
            warnings = [configurationWarning]
            return
        }
        do {
            localArchivedIDs = try localArchiveStore.load()
        } catch {
            warnings = ["本地归档状态无法读取（\(error.localizedDescription)）"]
        }
        do {
            if let cache = try cacheStore.load() {
                hadCacheAtLaunch = true
                records = cache.records.map { record in
                    var record = record
                    if record.route == .claude {
                        record.archived = localArchivedIDs.contains(record.id)
                    }
                    return record
                }
                refreshedAt = cache.refreshedAt
                warnings.append(contentsOf: cache.warnings)
            }
        } catch {
            warnings.append("本地索引无法读取，将在刷新后重建（\(error.localizedDescription)）")
        }
        do {
            aliases = try aliasStore.load()
        } catch {
            warnings.append("本地会话别名无法读取（\(error.localizedDescription)）")
        }
    }

    var searchMatchedRecords: [ConversationRecord] {
        let matched = filter.apply(to: records, sort: sort).filter {
            ConversationSearch.matches($0, query: searchQuery, alias: aliases[$0.id])
        }
        guard sort == .titleAscending else { return matched }
        return matched.sorted { lhs, rhs in
            let titleOrder = displayTitle(for: lhs).localizedStandardCompare(displayTitle(for: rhs))
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.storageKey < rhs.storageKey
        }
    }

    var folderSummaries: [ConversationFolderSummary] {
        let grouped = Dictionary(grouping: searchMatchedRecords, by: \.workingDirectory)
        return grouped.map { path, records in
            ConversationFolderSummary(
                path: path,
                conversationCount: records.count,
                latestConversationAt: records.map(\.lastConversationAt).max() ?? .distantPast,
                latestCreatedAt: records.map(\.createdAt).max() ?? .distantPast,
                exists: records.contains(where: \.workingDirectoryExists)
            )
        }
        .sorted(by: folderIsOrderedBefore)
    }

    var conversationsInSelectedFolder: [ConversationRecord] {
        guard let selectedFolderPath else { return [] }
        return searchMatchedRecords.filter { $0.workingDirectory == selectedFolderPath }
    }

    var selectedRecord: ConversationRecord? {
        guard let selectedID else { return nil }
        return records.first { $0.id == selectedID }
    }

    func displayTitle(for record: ConversationRecord) -> String {
        aliases[record.id] ?? ConversationTitleGenerator.displayTitle(for: record)
    }

    func titleIsAlias(for record: ConversationRecord) -> Bool {
        aliases[record.id] != nil
    }

    func bootstrapIfNeeded() {
        guard !hadCacheAtLaunch, records.isEmpty else { return }
        refresh()
    }

    func refresh() {
        guard !configurationFailed else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        let previousRecords = records
        let service = indexService
        let cacheStore = cacheStore
        let localArchivedIDs = localArchivedIDs

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = service.refresh(previousRecords: previousRecords)
            let records = outcome.records.map { record in
                var record = record
                if record.route == .claude {
                    record.archived = localArchivedIDs.contains(record.id)
                }
                return record
            }
            let cache = ConversationCache(
                refreshedAt: Date(),
                records: records,
                warnings: outcome.warnings
            )
            var saveWarning: String?
            do {
                try cacheStore.save(cache)
            } catch {
                saveWarning = "索引已刷新，但缓存保存失败（\(error.localizedDescription)）"
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.records = records
                self.refreshedAt = cache.refreshedAt
                self.warnings = outcome.warnings + (saveWarning.map { [$0] } ?? [])
                self.isRefreshing = false
                self.hadCacheAtLaunch = true
                if let selectedID = self.selectedID,
                   self.conversationsInSelectedFolder.contains(where: { $0.id == selectedID }) {
                    return
                }
                if let selectedFolderPath = self.selectedFolderPath,
                   self.folderSummaries.contains(where: { $0.path == selectedFolderPath }) {
                    self.selectedID = nil
                } else {
                    self.selectedFolderPath = nil
                    self.selectedID = nil
                }
            }
        }
    }

    func selectFolder(_ folder: ConversationFolderSummary) {
        guard selectedFolderPath != folder.path else { return }
        selectedFolderPath = folder.path
        selectedID = nil
        copiedID = nil
    }

    func select(_ record: ConversationRecord) {
        selectedID = record.id
        copiedID = nil
    }

    func beginRename(_ record: ConversationRecord) {
        recordBeingRenamed = record
        renameDraft = aliases[record.id] ?? displayTitle(for: record)
    }

    func cancelRename() {
        recordBeingRenamed = nil
        renameDraft = ""
    }

    func saveRename() {
        guard let record = recordBeingRenamed else { return }
        let value = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = aliases
        if value.isEmpty {
            aliases.removeValue(forKey: record.id)
        } else {
            aliases[record.id] = value
        }
        do {
            try aliasStore.save(aliases)
            cancelRename()
        } catch {
            aliases = previous
            warnings.append("本地别名保存失败（\(error.localizedDescription)）")
        }
    }

    func removeAlias(for record: ConversationRecord) {
        guard aliases[record.id] != nil else { return }
        let previous = aliases
        aliases.removeValue(forKey: record.id)
        do {
            try aliasStore.save(aliases)
            if recordBeingRenamed?.id == record.id {
                renameDraft = ConversationTitleGenerator.displayTitle(for: record)
            }
        } catch {
            aliases = previous
            warnings.append("本地别名删除失败（\(error.localizedDescription)）")
        }
    }

    func requestArchiveToggle(_ record: ConversationRecord) {
        guard archiveOperationID == nil, !isRefreshing else { return }
        recordBeingArchived = record
    }

    func cancelArchiveToggle() {
        recordBeingArchived = nil
    }

    func confirmArchiveToggle() {
        guard !configurationFailed else { return }
        guard let record = recordBeingArchived,
              archiveOperationID == nil,
              !isRefreshing
        else { return }

        recordBeingArchived = nil
        archiveOperationID = record.id
        managementNotice = nil
        let shouldArchive = !record.archived
        let localArchiveStore = localArchiveStore
        var updatedLocalArchivedIDs = localArchivedIDs

        let strategy: ConversationArchiveStrategy
        do {
            if record.route == .claude {
                strategy = .localOnly
                if shouldArchive {
                    updatedLocalArchivedIDs.insert(record.id)
                } else {
                    updatedLocalArchivedIDs.remove(record.id)
                }
            } else {
                guard let executableURL = configuration.resolvedCodexExecutable() else {
                    throw ConversationArchiveError.missingExecutable("Codex.app / ChatGPT.app")
                }
                strategy = try ConversationArchivePlanner.strategy(
                    for: record,
                    shouldArchive: shouldArchive,
                    codexExecutableURL: executableURL,
                    configuration: configuration
                )
            }
        } catch {
            archiveOperationID = nil
            showManagementNotice(.failure, "操作失败：\(error.localizedDescription)")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Void, Error>
            do {
                switch strategy {
                case let .codex(request):
                    try ArchiveProcessExecutor.run(request)
                case .localOnly:
                    try localArchiveStore.save(updatedLocalArchivedIDs)
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.archiveOperationID = nil
                switch result {
                case .success:
                    if record.route == .claude {
                        self.localArchivedIDs = updatedLocalArchivedIDs
                    }
                    if let index = self.records.firstIndex(where: { $0.id == record.id }) {
                        self.records[index].archived = shouldArchive
                    }
                    if shouldArchive && !self.filter.includeArchived {
                        self.selectedID = nil
                    }
                    let scope = record.route == .claude ? "寻回器本地" : "Codex"
                    self.showManagementNotice(
                        .success,
                        shouldArchive ? "已在\(scope)归档“\(self.displayTitle(for: record))”" : "已取消归档“\(self.displayTitle(for: record))”"
                    )
                    self.persistCurrentCache()
                case let .failure(error):
                    self.showManagementNotice(.failure, "操作失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func keepConversationSelectionVisible(in visibleIDs: [String]) {
        guard let selectedID, visibleIDs.contains(selectedID) else {
            self.selectedID = nil
            copiedID = nil
            return
        }
    }

    func keepFolderSelectionVisible(in visiblePaths: [String]) {
        guard let selectedFolderPath, visiblePaths.contains(selectedFolderPath) else {
            self.selectedFolderPath = nil
            selectedID = nil
            copiedID = nil
            return
        }
    }

    func copyCommand(for record: ConversationRecord) {
        guard let command = CommandGenerator.command(for: record, configuration: configuration) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        copiedID = record.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.copiedID == record.id { self?.copiedID = nil }
        }
    }

    private func folderIsOrderedBefore(
        _ lhs: ConversationFolderSummary,
        _ rhs: ConversationFolderSummary
    ) -> Bool {
        let primary: ComparisonResult
        switch sort {
        case .lastActivityDescending:
            primary = rhs.latestConversationAt.compare(lhs.latestConversationAt)
        case .lastActivityAscending:
            primary = lhs.latestConversationAt.compare(rhs.latestConversationAt)
        case .createdDescending:
            primary = rhs.latestCreatedAt.compare(lhs.latestCreatedAt)
        case .createdAscending:
            primary = lhs.latestCreatedAt.compare(rhs.latestCreatedAt)
        case .titleAscending, .workingDirectoryAscending:
            primary = lhs.path.localizedStandardCompare(rhs.path)
        }
        if primary != .orderedSame { return primary == .orderedAscending }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    private func persistCurrentCache() {
        let cache = ConversationCache(
            refreshedAt: refreshedAt ?? Date(),
            records: records,
            warnings: warnings
        )
        let cacheStore = cacheStore
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try cacheStore.save(cache)
            } catch {
                DispatchQueue.main.async {
                    self?.showManagementNotice(.failure, "会话状态已更新，但缓存保存失败（\(error.localizedDescription)）")
                }
            }
        }
    }

    private func showManagementNotice(
        _ kind: ConversationManagementNotice.Kind,
        _ message: String
    ) {
        let notice = ConversationManagementNotice(kind: kind, message: message)
        managementNotice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.managementNotice?.id == notice.id {
                self?.managementNotice = nil
            }
        }
    }
}
