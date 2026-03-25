import SwiftUI

#if os(macOS)
import AppKit

// MARK: - Mac Content View (三栏布局)
struct MacContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedConversation: Conversation?
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 左侧边栏 - 功能导航
            SidebarView(selectedTab: $appState.selectedTab, selectedConversation: $selectedConversation)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            // 右侧内容区
            DetailView(selectedTab: appState.selectedTab, conversation: selectedConversation)
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    NotificationCenter.default.post(name: .newChat, object: nil)
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                }
                
                #if os(macOS)
                Spacer()
                
                Button {
                    // 设置
                } label: {
                    Image(systemName: "gear")
                }
                #endif
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChat)) { _ in
            selectedConversation = nil
            appState.selectedTab = .chat
        }
    }
}

// MARK: - Sidebar View
struct SidebarView: View {
    @Binding var selectedTab: AppTab
    @Binding var selectedConversation: Conversation?
    @State private var conversations: [Conversation] = []
    
    var body: some View {
        List {
            // 功能导航
            Section("功能") {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.icon)
                        .tag(tab)
                        .selectionDisabled(tab == .chat)
                        .onTapGesture {
                            selectedTab = tab
                        }
                        .listRowBackground(selectedTab == tab ? Color.accentColor.opacity(0.2) : Color.clear)
                }
            }
            
            // 最近对话
            Section("最近对话") {
                ForEach(conversations) { conv in
                    ConversationRow(conversation: conv, isSelected: selectedConversation?.id == conv.id)
                        .onTapGesture {
                            selectedConversation = conv
                            selectedTab = .chat
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                conversations.removeAll { $0.id == conv.id }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("草包")
        .task {
            loadConversations()
        }
    }
    
    private func loadConversations() {
        if let data = UserDefaults.standard.data(forKey: "conversationHistory"),
           let saved = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = saved
        }
    }
}

// MARK: - Conversation Row
struct ConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "message")
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.headline)
                    .lineLimit(1)
                
                Text(conversation.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(6)
    }
}

// MARK: - Detail View
struct DetailView: View {
    let selectedTab: AppTab
    let conversation: Conversation?
    
    var body: some View {
        Group {
            switch selectedTab {
            case .chat:
                if let conv = conversation {
                    ConversationDetailView(conversation: conv)
                } else {
                    ChatView()
                }
            case .fortune:
                FortuneView()
            case .history:
                HistoryView()
            case .profile:
                ProfileView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Conversation Detail View (Mac)
struct ConversationDetailView: View {
    let conversation: Conversation
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(conversation.messages) { message in
                    MessageBubble(
                        message: message,
                        userSettings: UserSettings(),
                        onCopy: {},
                        onLike: {},
                        onDislike: {},
                        onRegenerate: {},
                        onDelete: {}
                    )
                }
            }
            .padding()
        }
        .navigationTitle(conversation.title)
    }
}

// MARK: - Preview
#Preview {
    MacContentView()
        .environmentObject(AppState())
        .frame(width: 1000, height: 700)
}
#endif
