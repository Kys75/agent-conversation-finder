import AgentConversationFinderCore
import SwiftUI

private enum ConversationViewMode: String, CaseIterable, Identifiable {
    case folders
    case table

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .folders: return "按目录浏览"
        case .table: return "表格管理"
        }
    }
}

private struct WorkspacePathPresentation {
    let fullPath: String
    let name: String
    let parentPath: String?

    init(_ path: String) {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            fullPath = "未知工作目录"
            name = "未知工作目录"
            parentPath = nil
            return
        }

        let url = URL(fileURLWithPath: cleaned)
        let lastComponent = url.lastPathComponent
        fullPath = cleaned
        name = lastComponent.isEmpty ? cleaned : lastComponent

        let parent = url.deletingLastPathComponent().path
        parentPath = parent == cleaned || lastComponent.isEmpty ? nil : parent
    }
}

struct ContentView: View {
    @ObservedObject var store: ConversationStore
    @State private var viewMode: ConversationViewMode = .folders
    @AppStorage("conversationSort") private var persistedSort = ConversationSort.lastActivityDescending.rawValue

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(store: store, viewMode: $viewMode)
            Divider()
            FilterBar(store: store)
            if !store.warnings.isEmpty {
                WarningBanner(warnings: store.warnings)
            }
            if let notice = store.managementNotice {
                ManagementNoticeBanner(notice: notice)
            }
            Divider()
            if viewMode == .folders {
                HStack(spacing: 0) {
                    FolderSidebar(store: store)
                        .frame(minWidth: 270, idealWidth: 310, maxWidth: 350)
                    Divider()
                    ConversationList(store: store)
                        .frame(minWidth: 500, idealWidth: 590)
                    Divider()
                    ConversationDetail(store: store)
                        .frame(minWidth: 350, idealWidth: 430, maxWidth: 500)
                }
            } else {
                HStack(spacing: 0) {
                    ConversationTableView(store: store)
                    Divider()
                    ConversationDetail(store: store, emptyDescription: "从表格中选择一条会话")
                        .frame(minWidth: 350, idealWidth: 410, maxWidth: 480)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            store.sort = ConversationSort(rawValue: persistedSort) ?? .lastActivityDescending
        }
        .onChange(of: store.sort) { _, newValue in
            persistedSort = newValue.rawValue
        }
        .onChange(of: store.folderSummaries.map(\.path)) { _, visiblePaths in
            store.keepFolderSelectionVisible(in: visiblePaths)
        }
        .onChange(of: store.conversationsInSelectedFolder.map(\.id)) { _, visibleIDs in
            store.keepConversationSelectionVisible(in: visibleIDs)
        }
        .sheet(item: $store.recordBeingRenamed) { record in
            RenameConversationSheet(store: store, record: record)
        }
        .alert(
            store.recordBeingArchived?.archived == true ? "取消归档这条会话？" : "归档这条会话？",
            isPresented: Binding(
                get: { store.recordBeingArchived != nil },
                set: { if !$0 { store.cancelArchiveToggle() } }
            )
        ) {
            Button(store.recordBeingArchived?.archived == true ? "取消归档" : "归档") {
                store.confirmArchiveToggle()
            }
            Button("取消", role: .cancel) {
                store.cancelArchiveToggle()
            }
        } message: {
            if let record = store.recordBeingArchived {
                Text(
                    record.route == .claude
                        ? "Claude Code 没有原生归档命令，因此只会在寻回器中隐藏或恢复这条会话，不修改 Claude 原始记录。"
                        : "这会使用 \(record.environment.displayName) 环境的 Codex 原生归档功能。操作可随时撤销，不会删除会话。"
                )
            }
        }
    }
}

private struct HeaderView: View {
    @ObservedObject var store: ConversationStore
    @Binding var viewMode: ConversationViewMode

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent 会话寻回器")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                HStack(spacing: 8) {
                    Text("Codex App、Codex CLI 与 Claude Code 的本地统一入口")
                        .foregroundStyle(.secondary)
                    if let refreshedAt = store.refreshedAt {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text("上次刷新 \(AppDateFormatter.string(from: refreshedAt))")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
            }
            Spacer()
            Picker("查看方式", selection: $viewMode) {
                ForEach(ConversationViewMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 230)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(store.folderSummaries.count) 个工作目录")
                    .font(.title2.bold())
                Text("\(store.searchMatchedRecords.count) 条匹配 / 共 \(store.records.count) 条会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                store.refresh()
            } label: {
                Label(store.isRefreshing ? "正在刷新" : "手动刷新", systemImage: "arrow.clockwise")
                    .frame(minWidth: 84)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.isRefreshing)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }
}

private struct FilterBar: View {
    @ObservedObject var store: ConversationStore

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索用户全文、摘要、主题、标题、路径或会话 ID", text: $store.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.body)
                    if !store.searchQuery.isEmpty {
                        Button {
                            store.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("清空搜索")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.accentColor.opacity(store.searchQuery.isEmpty ? 0.18 : 0.55), lineWidth: 1)
                }

                if !store.searchQuery.isEmpty {
                    Text("匹配 \(store.searchMatchedRecords.count) 条")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }

            HStack(spacing: 12) {
                SourceMultiSelectMenu(selection: $store.filter.selectedSources)
                    .frame(width: 190)

                Picker("环境", selection: $store.filter.environment) {
                    Text("全部环境").tag(ConversationEnvironment?.none)
                    ForEach(ConversationEnvironment.allCases) { environment in
                        Text(environment.displayName).tag(Optional(environment))
                    }
                }
                .frame(width: 140)

                Picker("时间", selection: $store.filter.timeRange) {
                    ForEach(ConversationTimeRange.allCases) { range in
                        Text(range.displayName).tag(range)
                    }
                }
                .frame(width: 140)

                Picker("排序", selection: $store.sort) {
                    ForEach(ConversationSort.allCases) { sort in
                        Text(sort.displayName).tag(sort)
                    }
                }
                .frame(width: 190)

                Toggle("显示已归档", isOn: $store.filter.includeArchived)
                    .toggleStyle(.switch)
                    .fixedSize()
                Toggle("显示 new-chat 目录", isOn: $store.filter.includePlaceholderFolders)
                    .toggleStyle(.switch)
                    .fixedSize()
                Spacer()
            }

            if store.filter.timeRange == .custom {
                HStack {
                    Text("最后对话时间")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    DatePicker("开始", selection: $store.filter.customStart, displayedComponents: .date)
                    DatePicker("结束", selection: $store.filter.customEnd, displayedComponents: .date)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
}

private struct SourceMultiSelectMenu: View {
    @Binding var selection: Set<ConversationSource>

    var body: some View {
        Menu {
            ForEach(ConversationSource.allCases) { source in
                Toggle(source.displayName, isOn: binding(for: source))
            }
            Divider()
            Button("恢复默认") {
                selection = [.codexCLI, .claudeCode]
            }
        } label: {
            HStack(spacing: 6) {
                Text(summary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("来源")
        .accessibilityValue(summary)
        .help("可同时选择多个会话来源")
    }

    private var summary: String {
        if selection.isEmpty { return "未选择来源" }
        if selection.count == ConversationSource.allCases.count { return "全部来源" }
        if selection == [.codexCLI, .claudeCode] { return "Codex CLI + Claude" }
        return ConversationSource.allCases
            .filter(selection.contains)
            .map(\.displayName)
            .joined(separator: " + ")
    }

    private func binding(for source: ConversationSource) -> Binding<Bool> {
        Binding(
            get: { selection.contains(source) },
            set: { isSelected in
                if isSelected {
                    selection.insert(source)
                } else {
                    selection.remove(source)
                }
            }
        )
    }
}

private struct FolderSidebar: View {
    @ObservedObject var store: ConversationStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("工作目录", systemImage: "folder.fill")
                    .font(.headline)
                Spacer()
                Text("\(store.folderSummaries.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if store.folderSummaries.isEmpty {
                ContentUnavailableView(
                    "没有匹配的工作目录",
                    systemImage: "folder.badge.questionmark",
                    description: Text(store.records.isEmpty ? "点击手动刷新建立索引" : "尝试清空搜索或调整筛选")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.folderSummaries) { folder in
                            FolderRow(
                                folder: folder,
                                isSelected: store.selectedFolderPath == folder.path
                            ) {
                                store.selectFolder(folder)
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

private struct FolderRow: View {
    let folder: ConversationFolderSummary
    let isSelected: Bool
    let action: () -> Void

    private var pathPresentation: WorkspacePathPresentation {
        WorkspacePathPresentation(folder.path)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: folder.exists ? "folder.fill" : "folder.badge.questionmark")
                        .foregroundStyle(folder.exists ? Color.accentColor : .orange)
                    Text(pathPresentation.name)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Spacer()
                    Text("\(folder.conversationCount)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                if let parentPath = pathPresentation.parentPath {
                    Text(parentPath)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(pathPresentation.fullPath)
                }

                Text("最近 \(AppDateFormatter.string(from: folder.latestConversationAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(
                isSelected ? Color.accentColor.opacity(0.13) : Color(nsColor: .textBackgroundColor).opacity(0.55),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.55),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

private struct WarningBanner: View {
    let warnings: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.08))
    }
}

private struct ManagementNoticeBanner: View {
    let notice: ConversationManagementNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.kind == .success ? "checkmark.circle.fill" : "xmark.octagon.fill")
            Text(notice.message)
                .font(.caption.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(notice.kind == .success ? Color.green : Color.red)
        .padding(.horizontal, 22)
        .padding(.vertical, 9)
        .background((notice.kind == .success ? Color.green : Color.red).opacity(0.08))
    }
}

private struct ConversationList: View {
    @ObservedObject var store: ConversationStore

    var body: some View {
        Group {
            if store.isRefreshing && store.records.isEmpty {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text("正在建立本地会话索引…")
                        .font(.headline)
                    Text("正在读取用户全文与助手关键进展，并建立增量摘要")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.selectedFolderPath == nil {
                ContentUnavailableView(
                    "先选择一个工作目录",
                    systemImage: "folder",
                    description: Text("左侧只显示当前筛选和关键词下有结果的目录")
                )
            } else if store.conversationsInSelectedFolder.isEmpty {
                ContentUnavailableView(
                    "这个目录里没有匹配会话",
                    systemImage: "text.magnifyingglass",
                    description: Text("尝试清空搜索或调整筛选")
                )
            } else {
                VStack(spacing: 0) {
                    if let selectedFolderPath = store.selectedFolderPath {
                        let pathPresentation = WorkspacePathPresentation(selectedFolderPath)
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("当前目录")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.secondary)
                                Text(pathPresentation.name)
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                                if let parentPath = pathPresentation.parentPath {
                                    Text(parentPath)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(pathPresentation.fullPath)
                                }
                            }
                            Spacer()
                            Text("\(store.conversationsInSelectedFolder.count) 条会话")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                    }
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.conversationsInSelectedFolder) { record in
                                ConversationRow(
                                    record: record,
                                    displayTitle: store.displayTitle(for: record),
                                    titleIsAlias: store.titleIsAlias(for: record),
                                    isSelected: store.selectedID == record.id
                                ) {
                                    store.select(record)
                                } onRename: {
                                    store.beginRename(record)
                                } onArchive: {
                                    store.requestArchiveToggle(record)
                                }
                            }
                        }
                        .padding(14)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ConversationRow: View {
    let record: ConversationRecord
    let displayTitle: String
    let titleIsAlias: Bool
    let isSelected: Bool
    let action: () -> Void
    let onRename: () -> Void
    let onArchive: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Text("当前主题")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if titleIsAlias {
                            StatusBadge(text: "我的命名", color: .green)
                        } else if ConversationTitleGenerator.isDerivedTitle(for: record) {
                            StatusBadge(text: "本地概括", color: .teal)
                        }
                        Spacer()
                        SourceBadge(source: record.source)
                        EnvironmentBadge(environment: record.environment)
                        if record.archived {
                            StatusBadge(text: record.route == .claude ? "本地归档" : "已归档", color: .orange)
                        }
                    }

                    Text(displayTitle)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                HStack(spacing: 7) {
                    Label("创建 \(AppDateFormatter.string(from: record.createdAt))", systemImage: "calendar.badge.plus")
                    Text("·")
                    Label("最后对话 \(AppDateFormatter.string(from: record.lastConversationAt))", systemImage: "clock.arrow.circlepath")
                        .fontWeight(.semibold)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                RecentMessagesView(messages: record.recentUserMessages, expanded: false)
                if let digest = record.digest, !digest.summary.isEmpty {
                    Text(digest.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(14)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.11)
                    : Color(nsColor: .controlBackgroundColor).opacity(0.72),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.65) : Color(nsColor: .separatorColor).opacity(0.7),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: onRename) {
                Label("重命名", systemImage: "pencil")
            }
            Button(action: onArchive) {
                Label(
                    record.archived ? "取消归档" : "归档",
                    systemImage: record.archived ? "tray.and.arrow.up" : "archivebox"
                )
            }
        }
    }
}

private struct ConversationDetail: View {
    @ObservedObject var store: ConversationStore
    var emptyDescription: String? = nil

    var body: some View {
        Group {
            if let record = store.selectedRecord {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        WorkspacePathCard(record: record, prominent: true)

                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 7) {
                                Text("当前主题")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                if store.titleIsAlias(for: record) {
                                    StatusBadge(text: "我的命名", color: .green)
                                } else if ConversationTitleGenerator.isDerivedTitle(for: record) {
                                    StatusBadge(text: "本地概括", color: .teal)
                                }
                                Spacer()
                            }
                            Text(store.displayTitle(for: record))
                                .font(.title2.bold())
                                .textSelection(.enabled)
                            HStack {
                                SourceBadge(source: record.source)
                                EnvironmentBadge(environment: record.environment)
                                if record.archived {
                                    StatusBadge(text: record.route == .claude ? "本地归档" : "已归档", color: .orange)
                                }
                                if record.integrity != .complete {
                                    StatusBadge(text: record.integrity.displayName, color: .red)
                                }
                            }
                            HStack(spacing: 8) {
                                Button {
                                    store.beginRename(record)
                                } label: {
                                    Label("重命名", systemImage: "pencil")
                                }
                                .buttonStyle(.bordered)
                                Button {
                                    store.requestArchiveToggle(record)
                                } label: {
                                    Label(
                                        store.archiveOperationID == record.id
                                            ? "处理中"
                                            : (record.archived ? "取消归档" : "归档"),
                                        systemImage: store.archiveOperationID == record.id
                                            ? "clock.arrow.circlepath"
                                            : (record.archived ? "tray.and.arrow.up" : "archivebox")
                                    )
                                }
                                .buttonStyle(.bordered)
                                .disabled(store.archiveOperationID != nil || store.isRefreshing)
                                Spacer()
                            }
                            .controlSize(.small)
                        }

                        if store.titleIsAlias(for: record) {
                            DetailSection(title: "自动概括", systemImage: "wand.and.stars") {
                                Text(ConversationTitleGenerator.displayTitle(for: record))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }

                        if store.titleIsAlias(for: record) || ConversationTitleGenerator.isDerivedTitle(for: record) {
                            DetailSection(title: "原始标题", systemImage: "text.quote") {
                                Text(record.title)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }

                        if let digest = record.digest {
                            DetailSection(title: "全程摘要", systemImage: "text.book.closed") {
                                Text(digest.summary)
                                    .font(.callout)
                                    .textSelection(.enabled)

                                if !digest.currentFocus.isEmpty {
                                    LabeledContent("当前焦点") {
                                        Text(digest.currentFocus)
                                            .multilineTextAlignment(.trailing)
                                            .textSelection(.enabled)
                                    }
                                }

                                if !digest.topics.isEmpty {
                                    FlowingTags(tags: digest.topics)
                                }

                                Text("已跟踪 \(digest.messageCount) 条对话消息，其中 \(digest.userMessageCount) 条来自你")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }

                            if digest.milestones.count > 1 {
                                DetailSection(title: "关键阶段", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(Array(digest.milestones.enumerated()), id: \.offset) { index, milestone in
                                            HStack(alignment: .top, spacing: 8) {
                                                Text("\(index + 1)")
                                                    .font(.caption2.bold())
                                                    .foregroundStyle(Color.accentColor)
                                                    .frame(width: 18, height: 18)
                                                    .background(Color.accentColor.opacity(0.12), in: Circle())
                                                Text(milestone)
                                                    .font(.callout)
                                                    .foregroundStyle(.secondary)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                    }
                                }
                            }

                            if !digest.openQuestions.isEmpty {
                                DetailSection(title: "近期问题", systemImage: "questionmark.bubble") {
                                    ForEach(digest.openQuestions, id: \.self) { question in
                                        Text(question)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }

                        DetailSection(title: "最近的你", systemImage: "person.crop.circle") {
                            RecentMessagesView(messages: record.recentUserMessages, expanded: true, showsHeader: false)
                        }

                        DetailSection(title: "时间", systemImage: "clock") {
                            LabeledContent("创建", value: AppDateFormatter.string(from: record.createdAt))
                            LabeledContent("最后对话", value: AppDateFormatter.string(from: record.lastConversationAt))
                            if let source = record.lastActivitySource {
                                LabeledContent("排序依据", value: source.displayName)
                            }
                            ActivityTimeDiagnostics(record: record)
                        }

                        if let command = CommandGenerator.command(for: record, configuration: store.configuration) {
                            DetailSection(title: "恢复命令", systemImage: "terminal") {
                                Text(command)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                    }

                                Button {
                                    store.copyCommand(for: record)
                                } label: {
                                    Label(
                                        store.copiedID == record.id ? "已复制到剪贴板" : "一键复制命令",
                                        systemImage: store.copiedID == record.id ? "checkmark.circle.fill" : "doc.on.doc"
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)

                                Label("命令包含全权限参数，只应在你信任的工作目录中执行。", systemImage: "lock.open.trianglebadge.exclamationmark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let guidance = CommandGenerator.recoveryGuidance(for: record) {
                            DetailSection(title: "恢复方式", systemImage: "macbook.and.iphone") {
                                Label(guidance, systemImage: "bubble.left.and.bubble.right.fill")
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text("可根据下方的会话标识、当前主题和原工作目录定位这条对话。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        DetailSection(title: "会话标识", systemImage: "number") {
                            Text(record.sessionID)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView(
                    "选择一个会话",
                    systemImage: "text.bubble",
                    description: Text(
                        emptyDescription
                            ?? (store.selectedFolderPath == nil ? "先从左侧选择工作目录" : "再从中间选择具体会话")
                    )
                )
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }
}

private enum TableRecordStatus: String, CaseIterable, Identifiable {
    case all
    case complete
    case incomplete
    case archived

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: return "全部状态"
        case .complete: return "记录完整"
        case .incomplete: return "记录不完整"
        case .archived: return "已归档"
        }
    }
}

private struct ConversationTableRow: Identifiable {
    let record: ConversationRecord
    let title: String

    var id: String { record.id }
    var workingDirectory: String { record.workingDirectory.isEmpty ? "未知工作目录" : record.workingDirectory }
    var workingDirectoryPresentation: WorkspacePathPresentation { WorkspacePathPresentation(record.workingDirectory) }
    var source: String { record.source.displayName }
    var environment: String { record.environment.displayName }
    var createdAt: Date { record.createdAt }
    var lastConversationAt: Date { record.lastConversationAt }
    var latestMessage: String { record.recentUserMessages.last ?? "" }
    var status: String {
        if record.archived { return record.route == .claude ? "本地归档" : "已归档" }
        return record.integrity == .complete ? "完整" : record.integrity.displayName
    }
}

private struct ConversationTableView: View {
    @ObservedObject var store: ConversationStore
    @State private var titleFilter = ""
    @State private var folderFilter = ""
    @State private var messageFilter = ""
    @State private var statusFilter: TableRecordStatus = .all
    @State private var page = 0
    private let pageSize = 100

    private var allRows: [ConversationTableRow] {
        store.searchMatchedRecords
            .map { ConversationTableRow(record: $0, title: store.displayTitle(for: $0)) }
            .filter { row in
                if !titleFilter.isEmpty,
                   !row.title.localizedCaseInsensitiveContains(titleFilter),
                   !row.record.title.localizedCaseInsensitiveContains(titleFilter) {
                    return false
                }
                if !folderFilter.isEmpty,
                   !row.workingDirectory.localizedCaseInsensitiveContains(folderFilter) {
                    return false
                }
                if !messageFilter.isEmpty,
                   !(row.record.digest?.searchableText ?? row.record.recentUserMessages.joined(separator: "\n"))
                    .localizedCaseInsensitiveContains(messageFilter) {
                    return false
                }
                switch statusFilter {
                case .all:
                    return true
                case .complete:
                    return row.record.integrity == .complete
                case .incomplete:
                    return row.record.integrity != .complete
                case .archived:
                    return row.record.archived
                }
            }
    }

    private var pageCount: Int {
        max(1, Int(ceil(Double(allRows.count) / Double(pageSize))))
    }

    private var safePage: Int {
        min(page, pageCount - 1)
    }

    private var pageRows: [ConversationTableRow] {
        let start = safePage * pageSize
        guard start < allRows.count else { return [] }
        let end = min(start + pageSize, allRows.count)
        return Array(allRows[start..<end])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("筛选标题", text: $titleFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 150)
                TextField("筛选工作目录", text: $folderFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                TextField("筛选用户全文", text: $messageFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160)
                Picker("记录状态", selection: $statusFilter) {
                    ForEach(TableRecordStatus.allCases) { status in
                        Text(status.displayName).tag(status)
                    }
                }
                .frame(width: 130)

                Button("清空列筛选") {
                    titleFilter = ""
                    folderFilter = ""
                    messageFilter = ""
                    statusFilter = .all
                }
                .disabled(titleFilter.isEmpty && folderFilter.isEmpty && messageFilter.isEmpty && statusFilter == .all)

                Spacer()
                Button {
                    page = max(0, safePage - 1)
                    store.selectedID = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(safePage == 0)
                .help("上一页")

                Text("第 \(safePage + 1) / \(pageCount) 页 · 共 \(allRows.count) 条")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Button {
                    page = min(pageCount - 1, safePage + 1)
                    store.selectedID = nil
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(safePage >= pageCount - 1)
                .help("下一页")

                ControlGroup {
                    Button {
                        guard let record = store.selectedRecord else { return }
                        store.beginRename(record)
                    } label: {
                        Label("重命名所选", systemImage: "pencil")
                    }
                    .help("重命名所选会话")
                    .disabled(store.selectedID == nil)

                    Button {
                        guard let record = store.selectedRecord else { return }
                        store.requestArchiveToggle(record)
                    } label: {
                        Label(
                            store.selectedRecord?.archived == true ? "取消归档" : "归档所选",
                            systemImage: store.selectedRecord?.archived == true ? "tray.and.arrow.up" : "archivebox"
                        )
                    }
                    .help(store.selectedRecord?.archived == true ? "取消归档所选会话" : "归档所选会话")
                    .disabled(store.selectedID == nil || store.archiveOperationID != nil || store.isRefreshing)
                }
                .labelStyle(.iconOnly)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if allRows.isEmpty {
                ContentUnavailableView(
                    "表格中没有匹配会话",
                    systemImage: "tablecells",
                    description: Text("尝试清空关键词、列筛选或调整顶部筛选")
                )
            } else {
                Table(pageRows, selection: $store.selectedID) {
                    TableColumn("标题") { row in
                        HStack(spacing: 6) {
                            Text(row.title)
                                .lineLimit(2)
                            if store.titleIsAlias(for: row.record) {
                                Image(systemName: "pencil.circle.fill")
                                    .foregroundStyle(.green)
                                    .help("我的命名")
                            }
                        }
                    }
                    .width(min: 180, ideal: 240)

                    TableColumn("工作目录") { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.workingDirectoryPresentation.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                            if let parentPath = row.workingDirectoryPresentation.parentPath {
                                Text(parentPath)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .help(row.workingDirectory)
                    }
                    .width(min: 170, ideal: 230)

                    TableColumn("来源") { row in
                        Text(row.source)
                    }
                        .width(min: 80, ideal: 95)
                    TableColumn("环境") { row in
                        Text(row.environment)
                    }
                        .width(min: 65, ideal: 78)
                    TableColumn("创建时间") { row in
                        Text(AppDateFormatter.string(from: row.createdAt))
                    }
                    .width(min: 120, ideal: 130)
                    TableColumn("最后对话") { row in
                        Text(AppDateFormatter.string(from: row.lastConversationAt))
                            .fontWeight(.semibold)
                    }
                    .width(min: 120, ideal: 130)
                    TableColumn("最新输入") { row in
                        Text(row.latestMessage.isEmpty ? "—" : row.latestMessage)
                            .lineLimit(2)
                            .foregroundStyle(row.latestMessage.isEmpty ? .tertiary : .secondary)
                    }
                    .width(min: 180, ideal: 260)
                    TableColumn("状态") { row in
                        Text(row.status)
                    }
                        .width(min: 75, ideal: 90)
                }
                .onChange(of: statusFilter) { _, newValue in
                    resetPage()
                    if newValue == .archived {
                        store.filter.includeArchived = true
                    }
                }
            }
        }
        .onChange(of: titleFilter) { _, _ in resetPage() }
        .onChange(of: folderFilter) { _, _ in resetPage() }
        .onChange(of: messageFilter) { _, _ in resetPage() }
        .onChange(of: store.searchQuery) { _, _ in resetPage() }
        .onChange(of: store.filter.selectedSources) { _, _ in resetPage() }
        .onChange(of: store.filter.environment) { _, _ in resetPage() }
        .onChange(of: store.filter.timeRange) { _, _ in resetPage() }
        .onChange(of: store.filter.includeArchived) { _, _ in resetPage() }
        .onChange(of: store.filter.includePlaceholderFolders) { _, _ in resetPage() }
        .onChange(of: store.sort) { _, _ in resetPage() }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func resetPage() {
        page = 0
        store.selectedID = nil
    }
}

private struct RenameConversationSheet: View {
    @ObservedObject var store: ConversationStore
    let record: ConversationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "pencil.and.outline")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("重命名会话")
                        .font(.title2.bold())
                    Text("只改变寻回器中的本地别名，不修改 Codex 或 Claude 原始记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("本地别名")
                    .font(.headline)
                TextField("输入便于识别的名称", text: $store.renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .onSubmit { store.saveRename() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("原始标题")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(record.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack {
                if store.titleIsAlias(for: record) {
                    Button("清除本地别名") {
                        store.removeAlias(for: record)
                    }
                }
                Spacer()
                Button("取消") { store.cancelRename() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { store.saveRename() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct WorkspacePathCard: View {
    let record: ConversationRecord
    var prominent = false

    private var pathPresentation: WorkspacePathPresentation {
        WorkspacePathPresentation(record.workingDirectory)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.workingDirectoryExists ? "folder.fill" : "folder.badge.questionmark")
                .font(prominent ? .title3 : .body)
                .foregroundStyle(record.workingDirectoryExists ? Color.accentColor : .orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("工作目录")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(pathPresentation.name)
                    .font(.system(size: prominent ? 20 : 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .selectableText(prominent)

                if let parentPath = pathPresentation.parentPath {
                    Text(parentPath)
                        .font(.system(size: prominent ? 11.5 : 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(prominent ? 2 : 1)
                        .truncationMode(.middle)
                        .selectableText(prominent)
                        .help(pathPresentation.fullPath)
                }

                if !record.workingDirectoryExists {
                    Label("目录当前不存在；恢复命令会安全停止", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(prominent ? 13 : 11)
        .background(Color.accentColor.opacity(prominent ? 0.11 : 0.075), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(prominent ? 0.32 : 0.2), lineWidth: 1)
        }
    }
}

private struct RecentMessagesView: View {
    let messages: [String]
    let expanded: Bool
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsHeader {
                HStack {
                    Label("你最近说过", systemImage: "person.crop.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(messages.count) 条")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if messages.isEmpty {
                Text("没有可用的用户消息预览")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                    MessageBubble(
                        message: message,
                        label: messageLabel(index: index, total: messages.count),
                        isLatest: index == messages.count - 1,
                        expanded: expanded
                    )
                }
            }
        }
    }

    private func messageLabel(index: Int, total: Int) -> String {
        if index == total - 1 { return "最新" }
        if index == total - 2 { return "上一条" }
        return "较早"
    }
}

private struct MessageBubble: View {
    let message: String
    let label: String
    let isLatest: Bool
    let expanded: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(isLatest ? Color.accentColor : .secondary)
                .frame(width: 38, alignment: .leading)
                .padding(.top, 2)

            Text(message)
                .font(.callout)
                .foregroundStyle(isLatest ? .primary : .secondary)
                .fontWeight(isLatest ? .medium : .regular)
                .lineLimit(expanded ? nil : (isLatest ? 3 : 2))
                .selectableText(expanded)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isLatest ? Color.accentColor.opacity(0.09) : Color(nsColor: .textBackgroundColor).opacity(0.7),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(
                    isLatest ? Color.accentColor.opacity(0.28) : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: 1
                )
        }
    }
}

private extension View {
    @ViewBuilder
    func selectableText(_ enabled: Bool) -> some View {
        if enabled {
            textSelection(.enabled)
        } else {
            self
        }
    }
}

private struct FlowingTags: View {
    let tags: [String]

    private let columns = [
        GridItem(.adaptive(minimum: 72, maximum: 150), spacing: 6, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
            }
        }
    }
}

private struct ActivityTimeDiagnostics: View {
    let record: ConversationRecord

    var body: some View {
        Group {
            if let value = record.transcriptUpdatedAt {
                LabeledContent("正文时间", value: AppDateFormatter.string(from: value))
            }
            if let value = record.historyUpdatedAt {
                LabeledContent("History 时间", value: AppDateFormatter.string(from: value))
            }
            if let value = record.databaseUpdatedAt {
                LabeledContent("数据库时间", value: AppDateFormatter.string(from: value))
            }
            if let value = record.transcriptFileModifiedAt {
                LabeledContent("文件时间", value: AppDateFormatter.string(from: value))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SourceBadge: View {
    let source: ConversationSource

    var color: Color {
        switch source {
        case .codexApp: return .blue
        case .codexCLI: return .purple
        case .claudeCode: return .orange
        }
    }

    var body: some View {
        StatusBadge(text: source.displayName, color: color)
    }
}

private struct EnvironmentBadge: View {
    let environment: ConversationEnvironment

    var body: some View {
        StatusBadge(text: environment.displayName, color: .secondary)
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.11), in: Capsule())
            .fixedSize()
    }
}

enum AppDateFormatter {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func string(from date: Date) -> String {
        if date == .distantPast { return "未知" }
        return formatter.string(from: date)
    }
}
