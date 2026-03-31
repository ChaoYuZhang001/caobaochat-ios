import SwiftUI
import AVKit
import AVFoundation
import Speech
import PhotosUI

// MARK: - Image Picker (iOS)
#if os(iOS)
struct ImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImagePicked: (UIImage) -> Void
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImagePicked: (UIImage) -> Void
        
        init(onImagePicked: @escaping (UIImage) -> Void) {
            self.onImagePicked = onImagePicked
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                onImagePicked(image)
            }
            picker.dismiss(animated: true)
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}



#endif

// MARK: - Media Type
enum MediaType {
    case image
    case video
    case audio
}

// MARK: - Media Link
struct MediaLink: Identifiable {
    let id = UUID()
    let url: URL
    let type: MediaType
    let label: String?
}

// MARK: - Media Link Detector
struct MediaLinkDetector {
    
    /// 检测消息中的所有媒体链接
    static func extractMediaLinks(from text: String) -> [MediaLink] {
        var results: [MediaLink] = []
        
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg"]
        let videoExtensions = ["mp4", "mov", "avi", "webm", "mkv", "m4v"]
        let audioExtensions = ["mp3", "m4a", "wav", "aac", "ogg", "opus"]
        
        // 先处理文本，修复可能被换行的 URL
        let normalizedText = fixBrokenURLs(in: text)
        
        // 更宽松的 URL 正则：匹配 http 开头到遇到空格或结束
        let urlPattern = #"https?://[^\s]*"#
        guard let urlRegex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) else {
            return results
        }
        
        let range = NSRange(normalizedText.startIndex..., in: normalizedText)
        let matches = urlRegex.matches(in: normalizedText, options: [], range: range)
        
        for match in matches {
            guard let urlRange = Range(match.range, in: normalizedText) else { continue }
            let urlString = String(normalizedText[urlRange])
            let lowercased = urlString.lowercased()
            
            // 检测媒体类型
            let mediaType: MediaType?
            
            // 检查 URL 是否包含图片扩展名（可能后面有 ? 参数）
            if imageExtensions.contains(where: { ext in
                lowercased.contains(".\(ext)?") || 
                lowercased.contains(".\(ext)") ||
                lowercased.hasSuffix(".\(ext)")
            }) {
                mediaType = .image
            } else if videoExtensions.contains(where: { ext in
                lowercased.contains(".\(ext)?") || 
                lowercased.contains(".\(ext)") ||
                lowercased.hasSuffix(".\(ext)")
            }) {
                mediaType = .video
            } else if audioExtensions.contains(where: { ext in
                lowercased.contains(".\(ext)?") || 
                lowercased.contains(".\(ext)") ||
                lowercased.hasSuffix(".\(ext)")
            }) {
                mediaType = .audio
            } else {
                mediaType = nil
            }
            
            guard let type = mediaType else { continue }
            
            // 清理 URL（移除末尾可能的多余字符）
            let cleanUrlString = cleanURL(urlString)
            guard let url = URL(string: cleanUrlString) else { continue }
            
            // 尝试从原始文本中提取标签
            let label = extractLabelBeforeURL(in: text, urlStart: urlString.components(separatedBy: "/").prefix(4).joined(separator: "/"))
            
            results.append(MediaLink(url: url, type: type, label: label))
        }
        
        return results
    }
    
    /// 修复被换行打断的 URL
    private static func fixBrokenURLs(in text: String) -> String {
        var result = text
        
        // 找到所有 https:// 或 http:// 开头的位置
        let httpsPattern = #"https?://"#
        guard let httpsRegex = try? NSRegularExpression(pattern: httpsPattern, options: .caseInsensitive) else {
            return result
        }
        
        let range = NSRange(result.startIndex..., in: result)
        let matches = httpsRegex.matches(in: result, options: [], range: range)
        
        // 从后往前处理，避免索引偏移
        var processedRanges: [Range<String.Index>] = []
        
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result) else { continue }
            
            // 检查这个范围是否已经被处理过
            var alreadyProcessed = false
            for processed in processedRanges {
                if processed.contains(matchRange.lowerBound) {
                    alreadyProcessed = true
                    break
                }
            }
            if alreadyProcessed { continue }
            
            // 从 URL 开始位置向后查找，直到遇到真正的结束
            var urlEnd = result.endIndex
            var currentIndex = matchRange.upperBound
            
            while currentIndex < result.endIndex {
                let char = result[currentIndex]
                
                // 检查是否是 URL 的结束字符
                if char == " " || char == "\t" {
                    // 空格和制表符是真正的结束
                    urlEnd = currentIndex
                    break
                } else if char == "\n" || char == "\r" {
                    // 换行符可能不是结束，检查下一行是否是 URL 的延续
                    let nextIndex = result.index(after: currentIndex)
                    if nextIndex < result.endIndex {
                        let nextChar = result[nextIndex]
                        // 如果下一行以 / 或其他 URL 字符开头，说明是延续
                        if nextChar == "/" || nextChar.isLetter || nextChar.isNumber || nextChar == "_" || nextChar == "-" || nextChar == "?" || nextChar == "=" || nextChar == "&" || nextChar == "." {
                            // 这是 URL 的延续，移除换行符
                            result.remove(at: currentIndex)
                            // 继续处理
                            continue
                        }
                    }
                    // 否则，换行是结束
                    urlEnd = currentIndex
                    break
                }
                
                currentIndex = result.index(after: currentIndex)
            }
            
            processedRanges.append(matchRange.lowerBound..<urlEnd)
        }
        
        return result
    }
    
    /// 清理 URL 字符串
    private static func cleanURL(_ urlString: String) -> String {
        var result = urlString
        
        // 移除末尾的非 URL 字符（如标点符号）
        while let lastChar = result.last {
            if lastChar == "." || lastChar == "," || lastChar == "!" || lastChar == "?" || lastChar == "。"
               || lastChar == "，" || lastChar == "！" || lastChar == "？" || lastChar == "）" || lastChar == ")"
               || lastChar == "\"" || lastChar == "'" || lastChar == "」" || lastChar == "\"" {
                result.removeLast()
            } else {
                break
            }
        }
        
        return result
    }
    
    /// 从 URL 前面的文本中提取标签
    private static func extractLabelBeforeURL(in text: String, urlStart: String) -> String? {
        // 在原始文本中查找 URL 的位置
        guard let range = text.range(of: urlStart) else {
            // 尝试查找域名
            if let domainRange = text.range(of: "coze.site") {
                let beforeText = String(text[text.startIndex..<domainRange.lowerBound])
                return extractLabel(from: beforeText)
            }
            return nil
        }
        
        let beforeText = String(text[text.startIndex..<range.lowerBound])
        return extractLabel(from: beforeText)
    }
    
    /// 从 URL 前面的文本中提取标签
    private static func extractLabel(from text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 排除太短、包含 http、或看起来像 URL 一部分的文本
            if !trimmed.isEmpty && 
               !trimmed.contains("http") && 
               !trimmed.contains("://") &&
               trimmed.count > 2 && 
               trimmed.count <= 30 &&
               !trimmed.hasSuffix("/") &&
               !trimmed.hasPrefix("/") {
                return trimmed
            }
        }
        return nil
    }
    
    /// 移除文本中的所有媒体链接
    static func removeMediaLinks(from text: String) -> String {
        var result = text
        
        // 先修复被换行的 URL
        result = fixBrokenURLs(in: result)
        
        let allExtensions = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg",
                            "mp4", "mov", "avi", "webm", "mkv", "m4v",
                            "mp3", "m4a", "wav", "aac", "ogg", "opus"]
        
        let urlPattern = #"https?://[^\s]*"#
        guard let urlRegex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) else {
            return result
        }
        
        let range = NSRange(result.startIndex..., in: result)
        let matches = urlRegex.matches(in: result, options: [], range: range)
        
        // 从后往前替换，避免索引偏移
        for match in matches.reversed() {
            guard let urlRange = Range(match.range, in: result) else { continue }
            let urlString = String(result[urlRange])
            let lowercased = urlString.lowercased()
            
            let isMedia = allExtensions.contains { ext in
                lowercased.contains(".\(ext)?") || 
                lowercased.contains(".\(ext)") ||
                lowercased.hasSuffix(".\(ext)")
            }
            
            if isMedia {
                result.removeSubrange(urlRange)
            }
        }
        
        // 清理多余的空行和孤立的标签
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[ \t]+$"#, with: "", options: .regularExpression)
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Content View (iOS/iPadOS)
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad 使用分栏布局
            iPadContentView()
        } else {
            // iPhone 使用 TabView
            iPhoneContentView()
        }
        #else
        iPhoneContentView()
        #endif
    }
}

// MARK: - iPhone Content View (TabView)
struct iPhoneContentView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        TabView(selection: $appState.selectedTab) {
            HomeView()
                .tabItem {
                    Label("首页", systemImage: "house.fill")
                }
                .tag(AppTab.home)
            
            ChatView()
                .tabItem {
                    Label("对话", systemImage: "message.fill")
                }
                .tag(AppTab.chat)
            
            FortuneView()
                .tabItem {
                    Label("运势", systemImage: "star.fill")
                }
                .tag(AppTab.fortune)
            
            FeaturesView()
                .tabItem {
                    Label("更多", systemImage: "square.grid.2x2.fill")
                }
                .tag(AppTab.features)
            
            ProfileView()
                .tabItem {
                    Label("我的", systemImage: "person.fill")
                }
                .tag(AppTab.profile)
        }
        .tint(.caobaoPrimary)
    }
}

// MARK: - iPad Content View (分栏布局)
#if os(iOS)
struct iPadContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedConversation: Conversation?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var conversations: [Conversation] = []
    @State private var selectedTab: AppTab? = .home
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 左侧边栏
            List(selection: $selectedTab) {
                Section("功能") {
                    ForEach(AppTab.allCases, id: \.self) { tab in
                        NavigationLink(value: tab) {
                            Label(tab.rawValue, systemImage: tab.icon)
                        }
                    }
                }
                
                Section("最近对话") {
                    ForEach(conversations.prefix(10)) { conv in
                        Button {
                            selectedConversation = conv
                            selectedTab = .chat
                        } label: {
                            HStack {
                                Image(systemName: "message")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(conv.title)
                                        .font(.headline)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Text(conv.preview)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("草包")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        selectedConversation = nil
                        selectedTab = .chat
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .onChange(of: selectedTab) { newValue in
                if let tab = newValue {
                    appState.selectedTab = tab
                    selectedConversation = nil
                }
            }
        } detail: {
            // 右侧内容
            detailView
        }
        .tint(.green)
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
    
    @ViewBuilder
    private var detailView: some View {
        if selectedTab == .chat, let conv = selectedConversation {
            ConversationDetailView(conversation: conv)
        } else {
            switch selectedTab ?? .home {
            case .home:
                HomeView()
            case .chat:
                ChatView()
            case .fortune:
                FortuneView()
            case .features:
                FeaturesView()
            case .profile:
                ProfileView()
            }
        }
    }
}
#endif

// MARK: - Chat View
struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()
    @FocusState private var isInputFocused: Bool
    @State private var showImagePicker = false
    @State private var showCamera = false
    @State private var selectedImage: UIImage?
    @State private var isRecording = false
    @State private var showAttachmentMenu = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Messages
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                if viewModel.messages.isEmpty {
                                    emptyView
                                } else {
                                    ForEach(viewModel.messages, id: \.id) { message in
                                        MessageBubble(
                                            message: message,
                                            userSettings: appState.userSettings,
                                            onCopy: {
                                                viewModel.copyMessage(message)
                                            },
                                            onLike: {
                                                viewModel.toggleLike(message.id)
                                            },
                                            onDislike: {
                                                viewModel.toggleDislike(message.id)
                                            },
                                            onRegenerate: {
                                                let userId = appState.user?.id ?? UUID().uuidString
                                                viewModel.regenerate(message.id, userId: userId)
                                            },
                                            onDelete: {
                                                viewModel.deleteMessage(message.id)
                                            }
                                        )
                                    }
                                }
                            }
                            .id(viewModel.refreshId)  // 使用 refreshId 强制刷新整个列表
                            .padding()
                        }
                        // 监听滚动触发器 - 流式更新时自动滚动
                        .onChange(of: viewModel.scrollToBottomTrigger) { _ in
                            if let lastMessage = viewModel.messages.last {
                                withAnimation(.easeOut(duration: 0.1)) {
                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            }
                        }
                        // 监听消息数量变化 - 新消息时滚动
                        .onChange(of: viewModel.messages.count) { _ in
                            if let lastMessage = viewModel.messages.last {
                                withAnimation {
                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            }
                        }
                    }
                    
                    // Input Area
                    inputArea
                }
            }
            .navigationTitle("草包")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.clearChat()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.gray)
                    }
                }
                #else
                ToolbarItem(placement: .automatic) {
                    Button {
                        viewModel.clearChat()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                #endif
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChat)) { _ in
            viewModel.clearChat()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearChat)) { _ in
            viewModel.clearChat()
        }
        .onAppear {
            // 加载历史记录
            if viewModel.messages.isEmpty {
                viewModel.loadFromLocal()
            }
        }
    }
    
    // MARK: - Empty View
    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green.opacity(0.5))
            
            Text("我是草包，你的毒舌AI助手")
                .font(.headline)
            
            Text("直接说话就行，我懂你想要什么")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            // Quick Actions
            VStack(spacing: 10) {
                QuickActionButton(title: "今日运势", icon: "sparkles") {
                    viewModel.inputText = "今日运势"
                }
                QuickActionButton(title: "给我一句毒舌金句", icon: "lightbulb") {
                    viewModel.inputText = "给我一句毒舌金句"
                }
                QuickActionButton(title: "吐槽我一下", icon: "flame") {
                    viewModel.inputText = "吐槽我一下"
                }
            }
            .padding(.top, 8)
        }
        .padding(.top, 60)
    }
    
    // MARK: - Input Area
    private var inputArea: some View {
        HStack(spacing: 12) {
            #if os(iOS)
            // 附件按钮（仅 iOS）
            Button {
                showAttachmentMenu = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .confirmationDialog("选择附件", isPresented: $showAttachmentMenu) {
                Button("拍照") {
                    showCamera = true
                }
                Button("从相册选择") {
                    showImagePicker = true
                }
                Button("取消", role: .cancel) {}
            }
            #endif
            
            TextField("说点什么...", text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .lineLimit(1...5)
                .onSubmit {
                    sendMessage()
                }
            
            #if os(iOS)
            // 语音按钮（仅 iOS）
            if viewModel.isLoading {
                ProgressView()
            } else if isRecording {
                Button {
                    stopRecording()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
            } else {
                Button {
                    startRecording()
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            #endif
            
            Button {
                sendMessage()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    #if os(iOS)
                    .frame(width: 44, height: 44)
                    #else
                    .frame(width: 32, height: 32)
                    #endif
                    .background(viewModel.inputText.isEmpty ? Color.gray : Color.green)
                    .clipShape(Circle())
            }
            .disabled(viewModel.inputText.isEmpty || viewModel.isLoading)
        }
        .padding()
        .background(Color(.systemBackground))
        #if os(iOS)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: -5)
        #else
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: -1)
        #endif
        #if os(iOS)
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(sourceType: .photoLibrary) { image in
                handleSelectedImage(image)
            }
        }
        .sheet(isPresented: $showCamera) {
            ImagePicker(sourceType: .camera) { image in
                handleSelectedImage(image)
            }
        }
        #endif
    }
    
    #if os(iOS)
    private func handleSelectedImage(_ image: UIImage) {
        selectedImage = image
        // 将图片转为 base64 并添加到输入
        if let imageData = image.jpegData(compressionQuality: 0.8) {
            let base64String = imageData.base64EncodedString()
            let dataURI = "data:image/jpeg;base64,\(base64String)"
            // 发送带图片的消息
            let userId = appState.user?.id ?? UUID().uuidString
            viewModel.sendMessageWithImage(userId: userId, imageURI: dataURI)
            appState.incrementChatCount()
        }
    }
    
    private func startRecording() {
        isRecording = true
        SpeechManager.shared.startRecording { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    viewModel.inputText = text
                case .failure(let error):
                    print("语音识别失败: \(error)")
                }
                isRecording = false
            }
        }
    }
    
    private func stopRecording() {
        SpeechManager.shared.stopRecording()
        isRecording = false
    }
    #endif
    
    private func sendMessage() {
        // 收缩键盘
        isInputFocused = false
        let userId = appState.user?.id ?? UUID().uuidString
        viewModel.sendMessage(userId: userId)
        // 增加对话统计
        appState.incrementChatCount()
    }
}

// MARK: - Message Bubble
struct MessageBubble: View {
    let message: ChatMessage
    let userSettings: UserSettings
    let autoPlayAudio: Bool
    let onCopy: () -> Void
    let onLike: () -> Void
    let onDislike: () -> Void
    let onRegenerate: () -> Void
    let onDelete: () -> Void
    @State private var showActions = false
    @State private var showReportSheet = false
    @State private var reportReason = ""
    @State private var reportSubmitted = false
    
    init(message: ChatMessage, 
         userSettings: UserSettings, 
         autoPlayAudio: Bool = false,
         onCopy: @escaping () -> Void = {},
         onLike: @escaping () -> Void = {},
         onDislike: @escaping () -> Void = {},
         onRegenerate: @escaping () -> Void = {},
         onDelete: @escaping () -> Void = {}) {
        self.message = message
        self.userSettings = userSettings
        self.autoPlayAudio = autoPlayAudio
        self.onCopy = onCopy
        self.onLike = onLike
        self.onDislike = onDislike
        self.onRegenerate = onRegenerate
        self.onDelete = onDelete
    }
    
    // 提取所有媒体链接
    private var mediaLinks: [MediaLink] {
        MediaLinkDetector.extractMediaLinks(from: message.content)
    }
    
    // 移除媒体链接后的文本
    private var displayText: String {
        MediaLinkDetector.removeMediaLinks(from: message.content)
    }
    
    // 格式化 Markdown 文本
    private func formatMarkdown(_ text: String) -> AttributedString {
        // 预处理文本，移除 Markdown 语法标记
        var processedText = text
        
        // 移除标题标记 (# ## ### 等)
        processedText = processedText.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
        
        // 移除粗体标记 (**text** 或 __text__)
        processedText = processedText.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
        processedText = processedText.replacingOccurrences(of: "__([^_]+)__", with: "$1", options: .regularExpression)
        
        // 移除斜体标记 (*text* 或 _text_)
        processedText = processedText.replacingOccurrences(of: "\\*([^*]+)\\*", with: "$1", options: .regularExpression)
        processedText = processedText.replacingOccurrences(of: "_([^_]+)_", with: "$1", options: .regularExpression)
        
        // 移除删除线标记 (~~text~~)
        processedText = processedText.replacingOccurrences(of: "~~([^~]+)~~", with: "$1", options: .regularExpression)
        
        // 移除行内代码标记 (`code`)
        processedText = processedText.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        
        // 移除分隔线 (--- 或 ***)
        processedText = processedText.replacingOccurrences(of: "^[-]{3,}$", with: "————————", options: .regularExpression)
        processedText = processedText.replacingOccurrences(of: "^[*]{3,}$", with: "————————", options: .regularExpression)
        
        // 处理列表项 (- item 或 * item)
        processedText = processedText.replacingOccurrences(of: "^[\\-\\*]\\s+", with: "• ", options: .regularExpression)
        
        // 处理有序列表 (1. item)
        processedText = processedText.replacingOccurrences(of: "^(\\d+)\\.\\s+", with: "$1. ", options: .regularExpression)
        
        // 尝试解析为 AttributedString
        do {
            return try AttributedString(markdown: processedText, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            // 如果解析失败，返回普通文本
            return AttributedString(processedText)
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                avatarView(name: "草包", isAI: true)
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                // 文本内容（如果有）
                if !displayText.isEmpty {
                    Text(formatMarkdown(displayText))
                        .font(.body)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(message.role == .user ? Color.green : Color(.systemBackground))
                        .foregroundStyle(message.role == .user ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
                
                // 媒体内容（图片、视频、音频）
                if !mediaLinks.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(Array(mediaLinks.enumerated()), id: \.element.id) { index, mediaLink in
                            MediaContentView(
                                mediaLink: mediaLink,
                                autoPlayAudio: autoPlayAudio && index == 0
                            )
                        }
                    }
                    .padding(.horizontal, 4)
                }
                
                // 操作栏 - AI 消息显示
                if message.role == .assistant && !message.content.isEmpty {
                    HStack(spacing: 12) {
                        // 时间
                        Text(formatTime(message.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        // 复制
                        Button {
                            onCopy()
                            #if os(iOS)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            #endif
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        // 点赞
                        Button {
                            onLike()
                        } label: {
                            Image(systemName: message.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .font(.caption)
                                .foregroundStyle(message.liked ? .blue : .secondary)
                        }
                        
                        // 踩
                        Button {
                            onDislike()
                        } label: {
                            Image(systemName: message.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                .font(.caption)
                                .foregroundStyle(message.disliked ? .red : .secondary)
                        }
                        
                        // 重新生成
                        Button {
                            onRegenerate()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        // 删除
                        Button {
                            onDelete()
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        // 举报
                        Button {
                            showReportSheet = true
                        } label: {
                            Image(systemName: "flag")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.horizontal, 4)
                }
                
                // 用户消息只显示时间
                if message.role == .user {
                    Text(formatTime(message.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
            }
            
            if message.role == .user {
                userAvatar
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .sheet(isPresented: $showReportSheet) {
            reportSheet
        }
    }
    
    // MARK: - Report Sheet
    @ViewBuilder
    private var reportSheet: some View {
        NavigationStack {
            if reportSubmitted {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.green)
                    
                    Text("感谢您的反馈")
                        .font(.headline)
                    
                    Text("我们会尽快处理您的举报")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Button("关闭") {
                        showReportSheet = false
                        reportSubmitted = false
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            } else {
                Form {
                    Section("举报原因") {
                        Button("内容不当或违规") { submitReport(reason: "内容不当或违规") }
                        Button("虚假或误导性信息") { submitReport(reason: "虚假或误导性信息") }
                        Button("侵犯个人权益") { submitReport(reason: "侵犯个人权益") }
                        Button("其他问题") { submitReport(reason: "其他问题") }
                    }
                }
                .navigationTitle("举报内容")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showReportSheet = false }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
    
    private func submitReport(reason: String) {
        // 提交举报到服务器
        Task {
            do {
                try await APIService.shared.submitFeedback(
                    type: "report",
                    content: "消息举报: \(reason)\n\n消息内容: \(message.content.prefix(200))",
                    contact: nil,
                    rating: 1
                )
                await MainActor.run {
                    reportSubmitted = true
                }
            } catch {
                print("举报提交失败: \(error)")
            }
        }
    }
    
    @ViewBuilder
    private var userAvatar: some View {
        if let emoji = userSettings.avatarEmoji {
            Text(emoji)
                .font(.title2)
                .frame(width: 36, height: 36)
                .background(Color(.systemGray5))
                .clipShape(Circle())
        } else if let url = userSettings.avatarUrl, !url.isEmpty {
            AsyncImage(url: URL(string: url)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                case .failure(_):
                    // 加载失败显示默认头像
                    Text(String(userSettings.nickname.prefix(1)))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.blue)
                case .empty:
                    ProgressView()
                @unknown default:
                    ProgressView()
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
        } else {
            Text(String(userSettings.nickname.prefix(1)))
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.blue)
                .clipShape(Circle())
        }
    }
    
    private func avatarView(name: String, isAI: Bool) -> some View {
        Image("Logo")
            .resizable()
            .scaledToFit()
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.green.opacity(0.3), lineWidth: 2)
            )
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Debug Print for MessageBubble
extension MessageBubble {
    private func debugPrint() {
        #if DEBUG
        print("📝 Message: role=\(message.role.rawValue), content=\(message.content.prefix(20))...")
        #endif
    }
}

// MARK: - Quick Action Button
struct QuickActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.green)
                Text(title)
                    .font(.subheadline)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.05), radius: 2)
        }
    }
}

// MARK: - Media Content View
struct MediaContentView: View {
    let mediaLink: MediaLink
    let autoPlayAudio: Bool
    @State private var isImageLoading = true
    @State private var isVideoPlaying = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 媒体标签
            if let label = mediaLink.label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            
            switch mediaLink.type {
            case .image:
                // 图片显示
                AsyncImage(url: mediaLink.url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 280, maxHeight: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .contextMenu {
                                Button {
                                    // 保存图片
                                    Task {
                                        await saveImage(mediaLink.url)
                                    }
                                } label: {
                                    Label("保存图片", systemImage: "square.and.arrow.down")
                                }
                                ShareLink(item: mediaLink.url)
                            }
                    case .failure(_):
                        // 加载失败显示占位图
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("图片加载失败")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 200, height: 150)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    case .empty:
                        ProgressView()
                            .frame(width: 200, height: 150)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    @unknown default:
                        ProgressView()
                    }
                }
                // 图片水印
                .overlay(alignment: .bottomTrailing) {
                    Text("草包AI生成")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(4)
                        .background(Color.black.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
                
            case .video:
                // 视频播放器
                VideoPlayerView(url: mediaLink.url)
                    .frame(maxWidth: 280, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                
            case .audio:
                // 音频播放器
                AudioPlayerView(url: mediaLink.url, autoPlay: autoPlayAudio)
                    .frame(maxWidth: 280)
            }
        }
    }
    
    private func saveImage(_ url: URL) async {
        #if os(iOS)
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let uiImage = UIImage(data: data) {
                UIImageWriteToSavedPhotosAlbum(uiImage, nil, nil, nil)
            }
        } catch {
            print("保存图片失败: \(error)")
        }
        #endif
    }
}

// MARK: - Video Player View
struct VideoPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    
    var body: some View {
        ZStack {
            Color.black
            
            if let player = player {
                VideoPlayer(player: player)
                    .disabled(true)
            } else {
                ProgressView()
                    .tint(.white)
            }
            
            // 播放/暂停按钮
            Button {
                togglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.3))
        }
        .onAppear {
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
    
    private func togglePlay() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }
}

// MARK: - Preview
#Preview {
    ContentView()
        .environmentObject(AppState())
}
