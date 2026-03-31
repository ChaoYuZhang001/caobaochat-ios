import SwiftUI

struct HistoryView: View {
    @State private var conversations: [Conversation] = []
    @State private var isLoading = false
    @State private var searchText = ""
    
    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    emptyState
                } else {
                    conversationList
                }
            }
            .navigationTitle("历史记录")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        clearHistory()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.gray)
                    }
                }
            }
            #if os(iOS)
            .searchable(text: $searchText, prompt: "搜索对话")
            #endif
        }
        .task {
            loadHistory()
        }
    }
    
    // MARK: - Conversation List
    private var conversationList: some View {
        List {
            ForEach(filteredConversations) { conversation in
                NavigationLink(value: conversation) {
                    ConversationRowView(conversation: conversation)
                }
                .navigationDestination(for: Conversation.self) { conv in
                    ConversationDetailView(conversation: conv)
                }
            }
            .onDelete { indexSet in
                conversations.remove(atOffsets: indexSet)
                saveHistory()
            }
        }
        .listStyle(.plain)
    }
    
    private var filteredConversations: [Conversation] {
        if searchText.isEmpty {
            return conversations
        }
        return conversations.filter { 
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.preview.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 60))
                .foregroundStyle(.gray.opacity(0.5))
            
            Text("暂无历史记录")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Text("开始一段新对话吧")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Actions
    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: "conversationHistory"),
           let saved = try? JSONDecoder().decode([Conversation].self, from: data) {
            conversations = saved
        }
    }
    
    private func saveHistory() {
        if let data = try? JSONEncoder().encode(conversations) {
            UserDefaults.standard.set(data, forKey: "conversationHistory")
        }
    }
    
    private func clearHistory() {
        conversations.removeAll()
        UserDefaults.standard.removeObject(forKey: "conversationHistory")
    }
}

// MARK: - Conversation Row View
struct ConversationRowView: View {
    let conversation: Conversation
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(conversation.title)
                .font(.headline)
                .lineLimit(1)
            
            Text(conversation.preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            
            Text(formatDate(conversation.date))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        #if os(macOS)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        #else
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "今天 HH:mm"
        } else if Calendar.current.isDateInYesterday(date) {
            formatter.dateFormat = "昨天 HH:mm"
        } else {
            formatter.dateFormat = "MM月dd日 HH:mm"
        }
        #endif
        return formatter.string(from: date)
    }
}

// MARK: - Conversation Detail View
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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Conversation Model
struct Conversation: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let preview: String
    let date: Date
    let messages: [ChatMessage]
}

#Preview {
    HistoryView()
}
