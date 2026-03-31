import Foundation
import SwiftUI

// MARK: - Chat ViewModel
@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var error: String?
    @Published var isSyncing: Bool = false
    @Published var refreshId = UUID()  // 用于强制刷新视图
    @Published var scrollToBottomTrigger = UUID()  // 用于触发自动滚动
    
    // 从 UserDefaults 读取设置
    @AppStorage("selectedModel") private var selectedModel = "doubao-pro-32k"
    @AppStorage("toxicLevel") private var toxicLevel = "normal"
    
    private var currentSessionId: String = UUID().uuidString
    private var currentTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private let authService = AuthService.shared
    
    // MARK: - Sync with Cloud
    /// 从云端同步聊天记录
    func syncFromCloud() async {
        guard authService.isLoggedIn, let token = authService.token else { return }
        
        isSyncing = true
        
        do {
            let response = try await APIService.shared.getCloudChatMessages(token: token)
            
            if response.success, let cloudMessages = response.messages {
                // 合并云端和本地消息
                let localMessages = loadLocalMessages()
                var messageMap = [String: ChatMessage]()
                
                // 先添加本地消息
                for msg in localMessages {
                    messageMap[msg.id] = msg
                }
                
                // 再添加/更新云端消息
                for cloudMsg in cloudMessages {
                    let msg = ChatMessage(
                        id: cloudMsg.id,
                        role: cloudMsg.role == "user" ? .user : .assistant,
                        content: cloudMsg.content,
                        timestamp: Date(timeIntervalSince1970: cloudMsg.timestamp / 1000)
                    )
                    messageMap[cloudMsg.id] = msg
                }
                
                // 按时间排序
                messages = Array(messageMap.values).sorted { $0.timestamp < $1.timestamp }
                
                // 保存合并后的数据到本地
                saveToHistory()
                
                print("✅ 同步完成: \(messages.count) 条消息")
            }
        } catch {
            print("❌ 同步失败: \(error.localizedDescription)")
        }
        
        isSyncing = false
    }
    
    /// 同步聊天记录到云端
    func syncToCloud() async {
        guard authService.isLoggedIn, let token = authService.token else { return }
        
        // 将消息转换为字典数组
        let messagesData = messages.map { msg -> [String: Any] in
            return [
                "id": msg.id,
                "role": msg.role.rawValue,
                "content": msg.content,
                "timestamp": msg.timestamp.timeIntervalSince1970 * 1000
            ]
        }
        
        do {
            _ = try await APIService.shared.syncChatMessages(token: token, messages: messagesData)
            print("✅ 已同步到云端: \(messages.count) 条消息")
        } catch {
            print("❌ 同步到云端失败: \(error.localizedDescription)")
        }
    }
    
    /// 加载本地历史记录到当前对话
    func loadFromLocal() {
        let localMessages = loadRecentConversation()
        if !localMessages.isEmpty {
            messages = localMessages
            refreshId = UUID()
            print("✅ 加载本地历史: \(messages.count) 条消息")
        }
    }
    
    /// 加载最近一次对话的消息
    private func loadRecentConversation() -> [ChatMessage] {
        guard let data = UserDefaults.standard.data(forKey: "conversationHistory"),
              let conversations = try? JSONDecoder().decode([Conversation].self, from: data),
              let recentConversation = conversations.first else {
            return []
        }
        
        // 更新 sessionId 为最近对话的 ID
        currentSessionId = recentConversation.id
        return recentConversation.messages
    }
    
    /// 加载本地消息（所有对话）
    private func loadLocalMessages() -> [ChatMessage] {
        guard let data = UserDefaults.standard.data(forKey: "conversationHistory"),
              let conversations = try? JSONDecoder().decode([Conversation].self, from: data) else {
            return []
        }
        
        // 展开所有对话中的消息
        return conversations.flatMap { $0.messages }
    }
    
    // MARK: - Send Message
    func sendMessage(userId: String) {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        let userMessage = ChatMessage(
            id: UUID().uuidString,
            role: .user,
            content: inputText,
            timestamp: Date()
        )
        messages.append(userMessage)
        
        let prompt = inputText
        inputText = ""
        isLoading = true
        error = nil
        
        // 添加助手消息占位
        let assistantMessage = ChatMessage(
            id: UUID().uuidString,
            role: .assistant,
            content: "",
            timestamp: Date()
        )
        messages.append(assistantMessage)
        
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            
            // 获取认证 token
            let token = self.authService.token
            
            do {
                let stream = APIService.shared.chatStreamV2(
                    userId: userId,
                    message: prompt,
                    sessionId: self.currentSessionId,
                    model: self.selectedModel,
                    toxicLevel: self.toxicLevel,
                    token: token
                )
                
                var fullContent = ""
                let messageIndex = self.messages.count - 1  // 最后一条消息的索引
                
                for try await event in stream {
                    if Task.isCancelled { break }
                    
                    print("🔄 收到事件: type=\(event.type ?? "nil"), content=\(event.content?.prefix(50) ?? "nil")")
                    
                    if let content = event.content {
                        fullContent += content
                        
                        // 更新最后一条消息 - 必须在主线程上更新并触发 UI 刷新
                        await MainActor.run {
                            print("📝 更新消息: \(content.prefix(30))...")
                            let oldMessage = self.messages[messageIndex]
                            self.messages[messageIndex] = ChatMessage(
                                id: oldMessage.id,
                                role: oldMessage.role,
                                content: fullContent,
                                timestamp: oldMessage.timestamp
                            )
                            // 触发 UI 刷新
                            self.refreshId = UUID()
                            // 触发自动滚动
                            self.scrollToBottomTrigger = UUID()
                        }
                    }
                    
                    if let error = event.error {
                        await MainActor.run {
                            self.error = error.msg
                            self.isLoading = false
                        }
                        return
                    }
                }
                
                await MainActor.run {
                    self.isLoading = false
                    self.saveToHistory()
                }
                
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    // MARK: - Send Message with Image
    func sendMessageWithImage(userId: String, imageURI: String) {
        let userMessage = ChatMessage(
            id: UUID().uuidString,
            role: .user,
            content: "[图片]",
            timestamp: Date()
        )
        messages.append(userMessage)
        
        isLoading = true
        error = nil
        
        // 添加助手消息占位
        let assistantMessage = ChatMessage(
            id: UUID().uuidString,
            role: .assistant,
            content: "",
            timestamp: Date()
        )
        messages.append(assistantMessage)
        
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            
            // 获取认证 token
            let token = self.authService.token
            
            do {
                let stream = APIService.shared.chatStreamWithImageV2(
                    userId: userId,
                    prompt: "请分析这张图片",
                    imageURI: imageURI,
                    sessionId: self.currentSessionId,
                    token: token
                )
                
                var fullContent = ""
                let messageIndex = self.messages.count - 1
                
                for try await event in stream {
                    if Task.isCancelled { break }
                    
                    if let content = event.content {
                        fullContent += content
                        
                        await MainActor.run {
                            let oldMessage = self.messages[messageIndex]
                            self.messages[messageIndex] = ChatMessage(
                                id: oldMessage.id,
                                role: oldMessage.role,
                                content: fullContent,
                                timestamp: oldMessage.timestamp
                            )
                            self.refreshId = UUID()
                            self.scrollToBottomTrigger = UUID()
                        }
                    }
                    
                    if let error = event.error {
                        await MainActor.run {
                            self.error = error.msg
                            self.isLoading = false
                        }
                        return
                    }
                }
                
                await MainActor.run {
                    self.isLoading = false
                    self.saveToHistory()
                }
                
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    // MARK: - Message Actions
    
    /// 复制消息内容到剪贴板
    func copyMessage(_ message: ChatMessage) {
        #if os(iOS)
        UIPasteboard.general.string = message.content
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        #endif
    }
    
    /// 点赞消息
    func toggleLike(_ messageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        let message = messages[index]
        messages[index] = ChatMessage(
            id: message.id,
            role: message.role,
            content: message.content,
            timestamp: message.timestamp,
            liked: !message.liked,
            disliked: false  // 点赞时取消踩
        )
        refreshId = UUID()
        saveToHistory()
    }
    
    /// 踩消息
    func toggleDislike(_ messageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        let message = messages[index]
        messages[index] = ChatMessage(
            id: message.id,
            role: message.role,
            content: message.content,
            timestamp: message.timestamp,
            liked: false,  // 踩时取消点赞
            disliked: !message.disliked
        )
        refreshId = UUID()
        saveToHistory()
    }
    
    /// 重新生成消息
    func regenerate(_ messageId: String, userId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        
        // 找到这条消息之前的用户消息
        var userPrompt = ""
        for i in (0..<index).reversed() {
            if messages[i].role == .user {
                userPrompt = messages[i].content
                break
            }
        }
        
        guard !userPrompt.isEmpty else { return }
        
        // 删除从这条消息开始的所有后续消息
        messages = Array(messages.prefix(index))
        
        // 重新发送
        isLoading = true
        error = nil
        
        // 添加助手消息占位
        let assistantMessage = ChatMessage(
            id: UUID().uuidString,
            role: .assistant,
            content: "",
            timestamp: Date()
        )
        messages.append(assistantMessage)
        
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            
            do {
                let stream = APIService.shared.chatStreamV2(
                    userId: userId,
                    message: userPrompt,
                    sessionId: self.currentSessionId
                )
                
                var fullContent = ""
                let messageIndex = self.messages.count - 1
                
                for try await event in stream {
                    if Task.isCancelled { break }
                    
                    if let content = event.content {
                        fullContent += content
                        
                        await MainActor.run {
                            let oldMessage = self.messages[messageIndex]
                            self.messages[messageIndex] = ChatMessage(
                                id: oldMessage.id,
                                role: oldMessage.role,
                                content: fullContent,
                                timestamp: oldMessage.timestamp
                            )
                            self.refreshId = UUID()
                        }
                    }
                    
                    if let error = event.error {
                        await MainActor.run {
                            self.error = error.msg
                            self.isLoading = false
                        }
                        return
                    }
                }
                
                await MainActor.run {
                    self.isLoading = false
                    self.saveToHistory()
                }
                
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
    
    /// 删除消息
    func deleteMessage(_ messageId: String) {
        messages.removeAll { $0.id == messageId }
        refreshId = UUID()
        saveToHistory()
    }
    
    // MARK: - Cancel
    func cancel() {
        currentTask?.cancel()
        isLoading = false
    }
    
    // MARK: - Clear Chat
    func clearChat() {
        messages.removeAll()
        currentSessionId = UUID().uuidString
        error = nil
    }
    
    // MARK: - Save to History
    private func saveToHistory() {
        guard !messages.isEmpty else { return }
        
        let conversation = Conversation(
            id: currentSessionId,
            title: messages.first?.content.prefix(20).description ?? "新对话",
            preview: messages.last?.content.prefix(50).description ?? "",
            date: Date(),
            messages: messages
        )
        
        // 加载现有历史
        var history: [Conversation] = []
        if let data = UserDefaults.standard.data(forKey: "conversationHistory"),
           let saved = try? JSONDecoder().decode([Conversation].self, from: data) {
            history = saved
        }
        
        // 添加新对话（最多保留50条）
        history.insert(conversation, at: 0)
        if history.count > 50 {
            history = Array(history.prefix(50))
        }
        
        // 保存到本地
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "conversationHistory")
        }
        
        // 异步同步到云端
        syncTask = Task {
            await syncToCloud()
        }
    }
}

// MARK: - Chat Message Model
struct ChatMessage: Identifiable, Hashable, Codable {
    let id: String
    let role: Role
    var content: String
    let timestamp: Date
    var liked: Bool = false
    var disliked: Bool = false
    
    enum Role: String, Hashable, Codable {
        case user
        case assistant
    }
    
    // Hashable conformance - 只需要比较 id
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // Memberwise initializer (用于手动创建消息)
    init(id: String, role: Role, content: String, timestamp: Date, liked: Bool = false, disliked: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.liked = liked
        self.disliked = disliked
    }
    
    // Codable conformance
    enum CodingKeys: String, CodingKey {
        case id, content, timestamp, role, liked, disliked
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let roleString = try container.decode(String.self, forKey: .role)
        role = roleString == "user" ? .user : .assistant
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        liked = try container.decodeIfPresent(Bool.self, forKey: .liked) ?? false
        disliked = try container.decodeIfPresent(Bool.self, forKey: .disliked) ?? false
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role.rawValue, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(liked, forKey: .liked)
        try container.encode(disliked, forKey: .disliked)
    }
}
