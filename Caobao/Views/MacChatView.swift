#if os(macOS)
import SwiftUI
import AppKit

/// Lightweight macOS chat surface backed by the shared archive/view model.
/// ContentView.swift contains the richer iOS-only ChatView and is not part of
/// the macOS target, so this view keeps the desktop target self-contained.
struct MacChatView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var chatViewModel: ChatViewModel
    let selectedConversationId: String?
    @FocusState private var inputFocused: Bool
    @State private var showSwitchConfirmation = false
    @ObservedObject private var speech = AssistantSpeechController.shared

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
            if let speechError = speech.errorMessage {
                HStack {
                    Image(systemName: "waveform.badge.exclamationmark").foregroundStyle(.orange)
                    Text(speechError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("关闭") { speech.clearError() }
                }
                .padding(.horizontal, 14).padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("输入消息…", text: $chatViewModel.inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .lineLimit(1...6)
                    .onSubmit { send() }
                Button {
                    if speech.isRecording || speech.isRequestingPermission {
                        speech.stopDictation()
                    } else {
                        let prefix = chatViewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { @MainActor in
                            await speech.startDictation(localeIdentifier: chatViewModel.preferredLocaleIdentifier, ownerId: ownerId) { text in
                                guard AuthService.shared.user?.id ?? "local-device" == ownerId else { return }
                                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !value.isEmpty else { return }
                                chatViewModel.inputText = prefix.isEmpty ? value : prefix + " " + value
                            }
                        }
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                        .foregroundStyle(speech.isRecording ? .red : Color.caobaoPrimary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .help(speech.isRecording ? "停止语音输入" : "语音输入")
                .accessibilityLabel(speech.isRecording ? "停止语音输入" : "语音输入")
                .disabled(chatViewModel.isLoading || speech.isRequestingPermission)
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
        .task {
            try? await chatViewModel.waitForArchiveReady(ownerId: ownerId)
            await openSelectedConversation()
        }
        .onChange(of: selectedConversationId) { _ in
            Task { await openSelectedConversation() }
        }
        .onChange(of: chatViewModel.requiresConversationSwitchConfirmation) { required in
            showSwitchConfirmation = required
        }
        .alert("切换对话", isPresented: $showSwitchConfirmation) {
            Button("切换", role: .destructive) {
                guard let source = chatViewModel.pendingConversationSwitch else { return }
                Task { _ = await chatViewModel.confirmConversationSwitch(source) }
            }
            Button("取消", role: .cancel) {
                chatViewModel.rejectConversationSwitch()
            }
        } message: {
            Text("当前对话有未保存内容或正在生成，切换后将停止当前生成并保留已保存内容。")
        }
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            if let images = message.images, !images.isEmpty {
                MacAssistantImagesView(images: images)
            }
            MessageBubble(
                message: message,
                userSettings: appState.userSettings,
                autoPlayAudio: false,
                allowsMutatingActions: false,
                allowsReporting: false,
                allowsRegeneration: false,
                allowsRemoteMedia: false,
                onCopy: { copy(message.content) }
            )
            if message.role == .assistant,
               !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    if speech.isSpeaking { speech.stopSpeaking() }
                    else { speech.speak(text: message.content, localeIdentifier: chatViewModel.preferredLocaleIdentifier) }
                } label: {
                    Label(speech.isSpeaking ? "停止朗读" : "朗读", systemImage: speech.isSpeaking ? "stop.fill" : "speaker.wave.2")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(speech.isRecording || speech.isRequestingPermission)
            }
            if let proposal = message.taskProposal {
                MacTaskProposalSummary(proposal: proposal)
            }
        }
        .frame(maxWidth: 620, alignment: message.role == .user ? .trailing : .leading)
    }

    private func copy(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func send() {
        guard !chatViewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !chatViewModel.isLoading, chatViewModel.archiveIsReady else { return }
        chatViewModel.sendMessage(userId: ownerId)
        inputFocused = true
    }

    private func openSelectedConversation() async {
        guard let id = selectedConversationId,
              id != chatViewModel.conversationId,
              chatViewModel.archiveIsReady else { return }
        _ = await chatViewModel.requestOpenConversation(id: id, ownerId: ownerId)
    }
}

private struct MacTaskProposalSummary: View {
    let proposal: AssistantTaskProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("待办提案", systemImage: "checklist")
                .font(.headline)
            Text(proposal.arguments.title)
                .font(.subheadline.weight(.semibold))
            if !proposal.arguments.notes.isEmpty {
                Text(proposal.arguments.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let dueAt = proposal.arguments.dueAt {
                Text("截止：\(dueAt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("请在任务页确认、编辑或拒绝此提案。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("待办提案：\(proposal.arguments.title)")
    }
}

private struct MacAssistantImagesView: View {
    let images: [AssistantImage]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(images) { image in
                if let data = image.data, let value = NSImage(data: data) {
                    Image(nsImage: value)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("已附加 \(images.count) 张图片")
    }
}
#endif
