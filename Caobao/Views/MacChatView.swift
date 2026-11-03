#if os(macOS)
import SwiftUI

/// Lightweight macOS chat surface backed by the shared archive/view model.
/// ContentView.swift contains the richer iOS-only ChatView and is not part of
/// the macOS target, so this view keeps the desktop target self-contained.
struct MacChatView: View {
    @ObservedObject var chatViewModel: ChatViewModel
    @FocusState private var inputFocused: Bool

    private var ownerId: String { AuthService.shared.user?.id ?? "local-device" }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chatViewModel.messages.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "message").font(.title)
                                Text("开始一个新对话").font(.headline)
                                Text("输入内容后发送给草包。").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 300)
                        } else {
                            ForEach(chatViewModel.messages, id: \.id) { message in
                                HStack {
                                    if message.role == .assistant { messageBubble(message) }
                                    else { Spacer(); messageBubble(message) }
                                }
                                .id(message.id)
                            }
                        }
                    }
                    .padding(20)
                }
                .onChange(of: chatViewModel.messages.count) { _ in
                    if let id = chatViewModel.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            Divider()
            if let error = chatViewModel.error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button("关闭") { chatViewModel.error = nil }
                }
                .padding(.horizontal, 14).padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("输入消息…", text: $chatViewModel.inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .lineLimit(1...6)
                    .onSubmit { send() }
                if chatViewModel.isLoading {
                    Button("停止") { chatViewModel.cancel() }
                } else {
                    Button("发送") { send() }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(chatViewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || !chatViewModel.archiveIsReady)
                }
            }
            .padding(14)
        }
        .navigationTitle("自由对话")
        .task { try? await chatViewModel.waitForArchiveReady(ownerId: ownerId) }
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        Text(message.content.isEmpty ? "…" : message.content)
            .textSelection(.enabled)
            .padding(12)
            .background(message.role == .user ? Color.accentColor.opacity(0.15) : Color.caobaoGroupedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)
    }

    private func send() {
        guard !chatViewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !chatViewModel.isLoading, chatViewModel.archiveIsReady else { return }
        chatViewModel.sendMessage(userId: ownerId)
        inputFocused = true
    }
}
#endif
