import SwiftUI
import AVKit
import AVFoundation
import Speech
import PhotosUI

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
                Color.caobaoGroupedBackground
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
                    .background(viewModel.inputText.isEmpty ? Color.gray : Color.blue)
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

// MARK: - Preview
#Preview {
    ContentView()
        .environmentObject(AppState())
}
