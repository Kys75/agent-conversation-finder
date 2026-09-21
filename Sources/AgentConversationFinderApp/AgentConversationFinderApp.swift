import SwiftUI

@main
struct AgentConversationFinderApp: App {
    @StateObject private var store = ConversationStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 1_200, minHeight: 700)
                .task { store.bootstrapIfNeeded() }
        }
        .defaultSize(width: 1_440, height: 860)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新会话索引") { store.refresh() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(store.isRefreshing)
            }
        }
    }
}
