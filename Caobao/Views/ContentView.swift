import SwiftUI
import AVKit
import AVFoundation
import Speech
import PhotosUI

#if os(iOS)
private struct AssistantSidebarActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var assistantShowSidebar: (() -> Void)? {
        get { self[AssistantSidebarActionKey.self] }
        set { self[AssistantSidebarActionKey.self] = newValue }
    }
}

private struct AssistantSidebarRootModifier: ViewModifier {
    @Environment(\.assistantShowSidebar) private var showSidebar
    let isAtRoot: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isAtRoot, let showSidebar {
            content
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: showSidebar) {
                            Image(systemName: "sidebar.left").frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("显示侧栏")
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    func assistantSidebarRoot(isAtRoot: Bool = true) -> some View {
        modifier(AssistantSidebarRootModifier(isAtRoot: isAtRoot))
    }

    /// A pushed page keeps its normal Back action instead of a root column action.
    func assistantSidebarChild() -> some View { environment(\.assistantShowSidebar, nil) }
}
#endif

/// One success signal also updates a split shell when its selected tab is already Chat.
@MainActor
enum AssistantConversationNavigation {
    static let didActivateChat = Notification.Name("assistant.conversationNavigation.didActivateChat")

    static func activateChat(appState: AppState, ownerId: String) {
        guard AssistantOwnerIdentity.matches(ownerId, AuthService.shared.user?.id ?? "local-device"),
              AssistantOwnerIdentity.matches(ChatViewModel.shared.activeOwner, ownerId) else { return }
        #if os(iOS)
        AssistantSpeechController.shared.cancel()
        #endif
        appState.selectedTab = .chat
        NotificationCenter.default.post(name: didActivateChat, object: ownerId)
    }
}

/// Kept outside ChatView so Home, history and split-sidebar requests share one presenter.
@MainActor
private struct AssistantConversationSwitchPresenter: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var chat = ChatViewModel.shared
    @ObservedObject private var auth = AuthService.shared
    @State private var promptOwnerId: String?
    @State private var presentedSwitch: AssistantConversationSwitchRequest?
    @State private var showsSwitchConfirmation = false
    @State private var navigationTask: Task<Void, Never>?
    @State private var navigationRun: UUID?
    @State private var confirmingTicketId: UUID?
    private var liveOwner: String { auth.user?.id ?? "local-device" }

    func body(content: Content) -> some View {
        content
            .confirmationDialog("切换对话？", isPresented: $showsSwitchConfirmation,
                                titleVisibility: .visible, presenting: presentedSwitch) { source in
                Button("取消", role: .cancel) {
                    if chat.pendingConversationSwitch?.id == source.id { chat.rejectConversationSwitch() }
                }
                .disabled(confirmingTicketId != nil)
                Button(switchAction(source)) {
                    confirmSwitch(source)
                }
                .disabled(!archiveAllowsNavigation || navigationRun != nil)
            } message: { source in
                Text(switchMessage(source))
            }
            .alert("无法切换对话", isPresented: switchErrorIsPresented) {
                Button("关闭", role: .cancel) { chat.conversationSwitchError = nil }
            } message: {
                Text(verbatim: chat.conversationSwitchError ?? "")
            }
            .onChange(of: chat.requiresConversationSwitchConfirmation) { presented in
                if !presented, chat.pendingConversationSwitch == nil { showsSwitchConfirmation = false }
                presentSwitchIfNeeded()
            }
            .onChange(of: chat.pendingConversationSwitch?.id) { pendingId in
                if pendingId == nil { showsSwitchConfirmation = false }
                presentSwitchIfNeeded()
            }
            .onChange(of: showsSwitchConfirmation) { presented in
                guard !presented, let source = presentedSwitch else { return }
                // Freeze the ticket actually displayed. Dismissal of an old dialog
                // cannot reject a replacement request, and button actions get their turn.
                Task { @MainActor in
                    await Task.yield()
                    guard !showsSwitchConfirmation, presentedSwitch?.id == source.id else { return }
                    guard confirmingTicketId != source.id else { return }
                    if chat.pendingConversationSwitch?.id == source.id { chat.rejectConversationSwitch() }
                    presentedSwitch = nil
                    presentSwitchIfNeeded()
                }
            }
            .onChange(of: chat.conversationSwitchError) { message in
                if message == nil { presentSwitchIfNeeded() }
            }
            .onChange(of: chat.archiveIsReady) { ready in if ready { presentSwitchIfNeeded() } }
            .onChange(of: chat.isArchiveBusy) { busy in if !busy { presentSwitchIfNeeded() } }
            .onReceive(NotificationCenter.default.publisher(for: .newChat)) { notification in
                requestNew(ownerId: notification.userInfo?["ownerId"] as? String ?? chat.activeOwner)
            }
            .onReceive(NotificationCenter.default.publisher(for: .clearChat)) { notification in
                requestNew(ownerId: notification.userInfo?["ownerId"] as? String ?? chat.activeOwner)
            }
            .onReceive(NotificationCenter.default.publisher(for: .assistantPrompt)) { notification in
                guard let prompt = notification.object as? String else { return }
                guard let ownerId = notification.userInfo?["ownerId"] as? String else {
                    chat.conversationSwitchError = AssistantLocalization.string("快捷指令缺少账号信息，请重新选择快捷操作。")
                    return
                }
                requestNew(ownerId: ownerId, initialText: prompt)
            }
            .onAppear {
                chat.activateOwner()
                if let previous = promptOwnerId, !AssistantOwnerIdentity.matches(previous, liveOwner) { appState.pendingAssistantPrompt = nil }
                promptOwnerId = liveOwner
                consumePendingPrompt()
                presentSwitchIfNeeded()
            }
            .onChange(of: appState.pendingAssistantPrompt) { _ in consumePendingPrompt() }
            .onChange(of: AssistantOwnerIdentity.ownerKey(liveOwner)) { _ in resetPromptScope() }
            .onChange(of: AssistantOwnerIdentity.ownerKey(chat.activeOwner)) { _ in
                if !AssistantOwnerIdentity.matches(promptOwnerId, chat.activeOwner) { resetPromptScope() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .loginSuccess)) { _ in resetPromptScope() }
            .onReceive(NotificationCenter.default.publisher(for: .logoutSuccess)) { _ in resetPromptScope() }
            .onDisappear { resetPromptScope() }
    }

    private var archiveAllowsNavigation: Bool { (chat.archiveIsReady || chat.archiveRequiresRecovery) && !chat.archiveIsLoading && !chat.isArchiveBusy }
    private func presentSwitchIfNeeded() {
        guard !showsSwitchConfirmation, presentedSwitch == nil, chat.conversationSwitchError == nil,
              navigationRun == nil, archiveAllowsNavigation,
              chat.requiresConversationSwitchConfirmation, let source = chat.pendingConversationSwitch,
              AssistantOwnerIdentity.matches(source.ownerId, liveOwner), AssistantOwnerIdentity.matches(source.ownerId, chat.activeOwner) else { return }
        presentedSwitch = source
        showsSwitchConfirmation = true
    }
    private func switchAction(_ source: AssistantConversationSwitchRequest) -> LocalizedStringKey {
        if source.isRecoveringDeletedConversation { return "重试清理并新建" }
        return source.willStopGeneration ? "停止生成并切换" : "保存草稿并切换"
    }
    private func switchMessage(_ source: AssistantConversationSwitchRequest) -> LocalizedStringKey {
        if source.isRecoveringDeletedConversation {
            return "此会话的清理尚未完成。将先重试清理已删除会话的草稿，再新建对话；已删除内容不会恢复。若清理或保存失败，将保留当前页面供你重试。"
        }
        if source.willStopGeneration {
            return "将停止当前生成并保存已收到的部分回复。源会话的文字和图片草稿会被保留；切换后不会自动发送消息。"
        }
        return "源会话的文字和图片草稿会被保留；切换后不会自动发送消息。"
    }
    private var switchErrorIsPresented: Binding<Bool> {
        Binding(get: { chat.conversationSwitchError != nil }, set: { if !$0 { chat.conversationSwitchError = nil } })
    }
    private func requestNew(ownerId: String, initialText: String = "") {
        guard navigationRun == nil else { return }
        guard archiveAllowsNavigation else {
            chat.conversationSwitchError = chat.archiveOperationError ?? AssistantLocalization.string("本地对话正在准备或保存，请稍后重试。")
            return
        }
        let run = UUID(); navigationRun = run
        navigationTask = Task {
            defer {
                if navigationRun == run {
                    navigationRun = nil; navigationTask = nil
                    presentSwitchIfNeeded()
                }
            }
            guard isCurrentNavigation(run, ownerId: ownerId) else { return }
            let success = await chat.requestNewConversation(ownerId: ownerId, initialText: initialText)
            guard success, isCurrentNavigation(run, ownerId: ownerId) else { return }
            AssistantConversationNavigation.activateChat(appState: appState, ownerId: ownerId)
        }
    }
    private func confirmSwitch(_ source: AssistantConversationSwitchRequest) {
        guard navigationRun == nil, archiveAllowsNavigation, presentedSwitch?.id == source.id else { return }
        let run = UUID(); navigationRun = run; confirmingTicketId = source.id
        navigationTask = Task {
            defer {
                if navigationRun == run {
                    navigationRun = nil; navigationTask = nil; confirmingTicketId = nil
                    if !showsSwitchConfirmation, presentedSwitch?.id == source.id { presentedSwitch = nil }
                    presentSwitchIfNeeded()
                }
            }
            guard isCurrentNavigation(run, ownerId: source.ownerId) else { return }
            let success = await chat.confirmConversationSwitch(source)
            guard success, isCurrentNavigation(run, ownerId: source.ownerId) else { return }
            AssistantConversationNavigation.activateChat(appState: appState, ownerId: source.ownerId)
        }
    }
    private func isCurrentNavigation(_ run: UUID, ownerId: String) -> Bool {
        !Task.isCancelled && navigationRun == run && AssistantOwnerIdentity.matches(ownerId, liveOwner) && AssistantOwnerIdentity.matches(ownerId, chat.activeOwner)
    }
    private func consumePendingPrompt() {
        guard let prompt = appState.pendingAssistantPrompt else { return }
        // Clear before requesting: a pending confirmation owns the prompt from here on.
        appState.pendingAssistantPrompt = nil
        guard let ownerId = promptOwnerId, AssistantOwnerIdentity.matches(ownerId, liveOwner), AssistantOwnerIdentity.matches(ownerId, chat.activeOwner) else {
            chat.conversationSwitchError = AssistantLocalization.string("快捷指令所属账号已变化，请重新选择快捷操作。")
            return
        }
        requestNew(ownerId: ownerId, initialText: prompt)
    }
    private func resetPromptScope() {
        navigationTask?.cancel(); navigationTask = nil; navigationRun = nil; confirmingTicketId = nil
        appState.pendingAssistantPrompt = nil
        promptOwnerId = liveOwner
        showsSwitchConfirmation = false
        presentedSwitch = nil
    }
}

extension View {
    @MainActor
    func assistantConversationSwitching() -> some View { modifier(AssistantConversationSwitchPresenter()) }
}

// MARK: - Content View (iOS/iPadOS)
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    var body: some View {
        Group {
        #if os(iOS)
        GeometryReader { proxy in
            Group {
                if #available(iOS 17.0, *), shouldUseSplitLayout(for: proxy.size.width) {
                    iPadContentView()
                } else {
                    // iOS 16 retains every feature through the complete tab shell;
                    // reliable compact-column control requires the iOS 17 API.
                    iPhoneContentView()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .sheet(isPresented: $appState.isShowingAssistantSettings) {
            AssistantSettingsSheet().environmentObject(appState)
        }
        .onChange(of: appState.selectedTab) { tab in
            if tab != .chat { AssistantSpeechController.shared.cancel() }
        }
        #else
        iPhoneContentView()
        #endif
        }
        .assistantConversationSwitching()
    }

    #if os(iOS)
    private func shouldUseSplitLayout(for width: CGFloat) -> Bool {
        // Use available window width rather than device identity so expanded/foldable
        // layouts and iPhone landscape can adopt the same navigation model.
        width >= 700 || (horizontalSizeClass == .regular && width >= 600)
    }
    #endif
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
            
            NavigationStack {
                AssistantTasksView(userId: AuthService.shared.user?.id ?? "local-device")
                    .assistantSidebarRoot()
            }
                .tabItem {
                    Label("任务", systemImage: "checklist")
                }
                .tag(AppTab.fortune)
            
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
@available(iOS 17.0, *)
struct iPadContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedConversation: AssistantConversationSummary?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @ObservedObject private var chatModel = ChatViewModel.shared
    @ObservedObject private var auth = AuthService.shared
    @State private var selectedTab: AppTab? = .home
    @State private var requestTask: Task<Void, Never>?
    @State private var requestRun: UUID?
    @State private var requestEpoch = UUID()
    @State private var recentTask: Task<Void, Never>?
    @State private var recentError: String?
    private var liveOwner: String { auth.user?.id ?? "local-device" }
    private var canNavigate: Bool {
        AssistantOwnerIdentity.matches(chatModel.activeOwner, liveOwner) && chatModel.archiveIsReady && !chatModel.archiveIsLoading
            && !chatModel.isArchiveBusy && requestRun == nil
    }
    private var canCreateConversation: Bool {
        AssistantOwnerIdentity.matches(chatModel.activeOwner, liveOwner) && (chatModel.archiveIsReady || chatModel.archiveRequiresRecovery)
            && !chatModel.archiveIsLoading && !chatModel.isArchiveBusy && requestRun == nil
    }
    
    var body: some View {
        let displayedOwner = chatModel.activeOwner
        let taskOwner = liveOwner
        return NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            // 左侧边栏 - 带渐变背景
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(hex: "fbbf24").opacity(0.1),
                        Color(hex: "f59e0b").opacity(0.05),
                        Color.caobaoGroupedBackground
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                List {
                    Section("功能") {
                        ForEach(AppTab.allCases, id: \.self) { tab in
                            Button {
                                selectedConversation = nil
                                selectedTab = tab
                                // The selected tab may already equal this row:
                                // explicit column control still opens its content.
                                preferredCompactColumn = .detail
                            } label: {
                                Label(LocalizedStringKey(tab.rawValue), systemImage: tab.icon)
                                    .foregroundStyle(selectedTab == tab ? Color.caobaoPrimary : Color.primary)
                            }
                            .listRowBackground(selectedTab == tab ? Color.caobaoPrimary.opacity(0.12) : Color.clear)
                        }
                    }

                    Section("工作区") {
                        workspaceLink("记忆", icon: "brain.head.profile", route: .memories)
                        workspaceLink("主动规则", icon: "bell.badge.fill", route: .proactive)
                        workspaceLink("订阅", icon: "creditcard.fill", route: .subscription)
                        workspaceLink("设置与隐私", icon: "gearshape.fill", route: .dataManagement)
                    }
                    
                    Section("最近对话") {
                        if chatModel.archiveIsLoading { ProgressView("正在准备本地对话…") }
                        if let error = recentError ?? chatModel.archiveOperationError {
                            Text(verbatim: error).font(.caption).foregroundStyle(.red)
                            if chatModel.archiveRequiresRecovery {
                                Button("重试清理并新建") {
                                    NotificationCenter.default.post(name: .newChat, object: nil, userInfo: ["ownerId": displayedOwner])
                                }.disabled(!canCreateConversation)
                            } else { Button("重试读取会话", action: scheduleRecentReload) }
                        }
                        ForEach(AssistantOwnerIdentity.matches(chatModel.activeOwner, liveOwner) ? Array(chatModel.conversations.prefix(10)) : []) { conv in
                            Button {
                                requestConversation(id: conv.id, ownerId: displayedOwner)
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
                                        if conv.messageCount == 0 { Text("尚无已发送消息").font(.caption2).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                            .disabled(!canNavigate)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .assistantNavigationTitle("草包")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        NotificationCenter.default.post(name: .newChat, object: nil, userInfo: ["ownerId": displayedOwner])
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新建对话")
                    .disabled(!canCreateConversation)
                }
            }
            .onChange(of: selectedTab) { newValue in
                #if DEBUG
                logSplitLayoutState("selectedTab.changed")
                #endif
                if let tab = newValue {
                    appState.selectedTab = tab
                    selectedConversation = nil
                    preferredCompactColumn = .detail
                }
            }
            .onChange(of: appState.selectedTab) { newTab in
                #if DEBUG
                logSplitLayoutState("appStateTab.changed")
                #endif
                // 同步 appState.selectedTab 的变化到本地状态
                if newTab != selectedTab {
                    selectedTab = newTab
                    selectedConversation = nil
                }
                preferredCompactColumn = .detail
            }
        } detail: {
            // 右侧内容
            detailView
                .environment(\.assistantShowSidebar, showSidebarAction)
        }
        .tint(.green)
        .task(id: AssistantOwnerIdentity.ownerKey(taskOwner)) {
            guard !Task.isCancelled, AssistantOwnerIdentity.matches(taskOwner, liveOwner) else { return }
            #if DEBUG
            logSplitLayoutState("split.task")
            #endif
            selectedTab = appState.selectedTab
            chatModel.activateOwner()
            await loadConversations(ownerId: taskOwner)
        }
        #if DEBUG
        .onChange(of: preferredCompactColumn) { _ in logSplitLayoutState("preferredCompactColumn.changed") }
        .onChange(of: columnVisibility) { _ in logSplitLayoutState("columnVisibility.changed") }
        .onChange(of: appState.assistantHomePath.count) { _ in logSplitLayoutState("homePathDepth.changed") }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .conversationHistoryChanged)) { notification in
            if let ownerId = notification.object as? String, !AssistantOwnerIdentity.matches(ownerId, liveOwner) { return }
            // 监听历史记录变化，同步更新侧边栏
            scheduleRecentReload()
        }
        .onChange(of: AssistantOwnerIdentity.ownerKey(liveOwner)) { _ in resetRequestScope() }
        .onReceive(NotificationCenter.default.publisher(for: .loginSuccess)) { _ in resetRequestScope() }
        .onReceive(NotificationCenter.default.publisher(for: .logoutSuccess)) { _ in resetRequestScope() }
        .onDisappear { resetRequestScope() }
        .onReceive(NotificationCenter.default.publisher(for: AssistantConversationNavigation.didActivateChat)) { notification in
            guard let ownerId = notification.object as? String, AssistantOwnerIdentity.matches(ownerId, chatModel.activeOwner),
                  AssistantOwnerIdentity.matches(ownerId, AuthService.shared.user?.id ?? "local-device") else { return }
            selectedConversation = nil
            selectedTab = .chat
            preferredCompactColumn = .detail
        }
    }
    
    private func loadConversations(ownerId: String) async {
        guard !Task.isCancelled, AssistantOwnerIdentity.matches(ownerId, liveOwner) else { return }
        let epoch = requestEpoch
        do {
            try await chatModel.waitForArchiveReady(ownerId: ownerId)
            guard !Task.isCancelled, AssistantOwnerIdentity.matches(ownerId, liveOwner), epoch == requestEpoch else { return }
            await chatModel.loadConversationsFromHistory()
            guard !Task.isCancelled, AssistantOwnerIdentity.matches(ownerId, liveOwner), epoch == requestEpoch else { return }
            recentError = nil
        } catch {
            guard !Task.isCancelled, AssistantOwnerIdentity.matches(ownerId, liveOwner), epoch == requestEpoch else { return }
            recentError = error.localizedDescription
        }
    }
    private func scheduleRecentReload() {
        recentTask?.cancel()
        let ownerId = liveOwner
        recentTask = Task { await loadConversations(ownerId: ownerId) }
    }
    private func requestConversation(id: String, ownerId: String) {
        guard canNavigate else { return }
        let run = UUID(), epoch = requestEpoch
        requestRun = run
        requestTask = Task {
            defer { if requestRun == run { requestRun = nil; requestTask = nil } }
            guard !Task.isCancelled, requestRun == run, requestEpoch == epoch,
                  AssistantOwnerIdentity.matches(ownerId, liveOwner), AssistantOwnerIdentity.matches(ownerId, chatModel.activeOwner) else { return }
            let success = await chatModel.requestOpenConversation(id: id, ownerId: ownerId)
            guard success, !Task.isCancelled, requestRun == run, requestEpoch == epoch,
                  AssistantOwnerIdentity.matches(ownerId, liveOwner), AssistantOwnerIdentity.matches(ownerId, chatModel.activeOwner) else { return }
            AssistantConversationNavigation.activateChat(appState: appState, ownerId: ownerId)
        }
    }
    private func resetRequestScope() {
        requestTask?.cancel(); requestTask = nil; requestRun = nil; requestEpoch = UUID()
        recentTask?.cancel(); recentTask = nil; recentError = nil; selectedConversation = nil
    }

    private var showSidebarAction: (() -> Void)? {
        guard horizontalSizeClass == .compact,
              !(selectedTab == .home && !appState.assistantHomePath.isEmpty) else { return nil }
        return {
            preferredCompactColumn = .sidebar
            #if DEBUG
            logSplitLayoutState("sidebar.requested")
            #endif
        }
    }

    private func workspaceLink(_ title: LocalizedStringKey, icon: String, route: AssistantHomeRoute) -> some View {
        Button {
            selectedConversation = nil
            selectedTab = .home
            appState.assistantHomePath = [route]
            preferredCompactColumn = .detail
        } label: {
            Label(title, systemImage: icon)
                .foregroundStyle(selectedTab == .home && appState.assistantHomePath.last == route ? Color.caobaoPrimary : Color.primary)
        }
    }

    #if DEBUG
    /// Enum labels and path depth only: never log route payloads or private data.
    private func logSplitLayoutState(_ event: String) {
        let compact: String
        if preferredCompactColumn == .sidebar { compact = "sidebar" }
        else if preferredCompactColumn == .content { compact = "content" }
        else if preferredCompactColumn == .detail { compact = "detail" }
        else { compact = "unknown" }
        let visibility: String
        if columnVisibility == .all { visibility = "all" }
        else if columnVisibility == .doubleColumn { visibility = "doubleColumn" }
        else if columnVisibility == .detailOnly { visibility = "detailOnly" }
        else if columnVisibility == .automatic { visibility = "automatic" }
        else { visibility = "unknown" }
        NSLog("[CaoBaoLayout] %@ selected=%@ app=%@ compact=%@ visibility=%@ homeDepth=%ld",
              event, selectedTab.map { String(describing: $0) } ?? "nil",
              String(describing: appState.selectedTab), compact, visibility, appState.assistantHomePath.count)
    }
    #endif

    @ViewBuilder
    private var detailView: some View {
        Group {
            if selectedTab == .chat, let conv = selectedConversation {
                NavigationStack {
                    ConversationDetailView(conversationId: conv.id, ownerId: chatModel.activeOwner)
                        .assistantSidebarRoot()
                }
            } else {
                switch selectedTab ?? .home {
                case .home:
                    HomeView()
                case .chat:
                    ChatView()
                case .fortune:
                    NavigationStack {
                        AssistantTasksView(userId: AuthService.shared.user?.id ?? "local-device")
                            .assistantSidebarRoot()
                    }
                case .profile:
                    ProfileView()
                }
            }
        }
    }
}
#endif

// MARK: - Chat View
@MainActor
struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var viewModel = ChatViewModel.shared
    @ObservedObject private var auth = AuthService.shared
    @FocusState private var isInputFocused: Bool
    @State private var generationAction: AssistantGenerationActionSource?
    @State private var showGenerationConfirmation = false
    @State private var messageAction: MessageActionDestination?
    @State private var pendingTaskToolContinuation: AssistantTaskProposalActionSource?
    @State private var showsTaskToolContinuation = false
    @State private var taskToolActionTask: Task<Void, Never>?
    @State private var taskToolActionRun: UUID?
    @State private var taskToolErrorMessageId: String?
    @State private var taskToolActionError: String?
    @State private var clipboardViewEpoch = UUID()
    private var hasCurrentChatOwner: Bool {
        AssistantOwnerIdentity.matches(viewModel.activeOwner, auth.user?.id ?? "local-device")
    }
    private struct ClipboardSource {
        let ownerId: String
        let conversationId: String
        let conversationScopeId: UUID
        let viewEpoch: UUID
    }

    private enum MessageActionKind { case memory, task }
    private enum MessageActionDestination: Identifiable {
        case message(MessageActionKind, AssistantChatActionSource)
        case taskProposal(AssistantTaskProposalActionSource)
        var id: UUID {
            switch self {
            case .message(_, let source): return source.id
            case .taskProposal(let source): return source.id
            }
        }
    }

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedPhotoSource: ClipboardSource?
    @ObservedObject private var speech = AssistantSpeechController.shared
    
    var body: some View {
        let clipboardSource = ClipboardSource(ownerId: viewModel.activeOwner, conversationId: viewModel.conversationId,
            conversationScopeId: viewModel.conversationScopeId, viewEpoch: clipboardViewEpoch)
        return NavigationStack {
            ZStack {
                // 渐变背景 - 温暖的橙色渐变
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(hex: "f97316").opacity(0.08),
                        Color(hex: "fb923c").opacity(0.05),
                        Color.caobaoGroupedBackground
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Stable, owner-bound reading state survives width shell changes.
                    AssistantChatViewportScroll(ownerId: clipboardSource.ownerId, conversationId: clipboardSource.conversationId,
                        scopeId: clipboardSource.conversationScopeId, viewEpoch: clipboardSource.viewEpoch,
                        messages: viewModel.messages.map { AssistantChatViewportMessage(id: $0.id, isUser: $0.role == .user) },
                        isGenerating: viewModel.isLoading, scrollTrigger: viewModel.scrollToBottomTrigger,
                        isCurrent: { isCurrentChatSource(clipboardSource) }) {
                            LazyVStack(spacing: 12) {
                                if !hasCurrentChatOwner {
                                    ProgressView("正在准备本地对话…")
                                } else if viewModel.messages.isEmpty {
                                    emptyView
                                } else {
                                    ForEach(viewModel.messages, id: \.id) { message in
                                        VStack(spacing: 12) {
                                        if let images = message.images, !images.isEmpty {
                                            AssistantImagesView(images: images)
                                                .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                                        }
                                        if !message.content.isEmpty || message.taskProposal == nil { MessageBubble(
                                            message: message,
                                            userSettings: appState.userSettings,
                                            allowsRegeneration: false,
                                            onCopy: {
                                                copyCurrentMessage(id: message.id, source: clipboardSource)
                                            },
                                            onCopyCode: { blockId, payload in
                                                await copyCurrentCode(id: message.id, source: clipboardSource, blockId: blockId, expectedText: payload)
                                            },
                                            onLike: {
                                                guard isCurrentChatSource(clipboardSource) else { return }
                                                viewModel.toggleLike(message.id)
                                            },
                                            onDislike: {
                                                guard isCurrentChatSource(clipboardSource) else { return }
                                                viewModel.toggleDislike(message.id)
                                            },
                                            onRegenerate: {
                                                guard isCurrentChatSource(clipboardSource) else { return }
                                                beginGenerationAction(messageId: message.id)
                                            },
                                            onDelete: {
                                                guard isCurrentChatSource(clipboardSource) else { return }
                                                viewModel.deleteMessage(message.id)
                                            }
                                        ) }
                                        if let proposal = message.taskProposal {
                                            taskProposalCard(messageId: message.id, proposal: proposal, isComplete: message.status == .completed)
                                        }
                                        if viewModel.canDeriveAction(from: message) {
                                            HStack {
                                                if message.role == .assistant {
                                                    Button {
                                                        if speech.isSpeaking { speech.stopSpeaking() }
                                                        else { speech.speak(text: message.content, localeIdentifier: viewModel.preferredLocaleIdentifier) }
                                                    } label: {
                                                        Label(speech.isSpeaking ? "停止朗读" : "朗读", systemImage: speech.isSpeaking ? "stop.circle" : "speaker.wave.2")
                                                            .font(.caption).frame(minHeight: 44)
                                                    }
                                                    .disabled(speech.isRecording || speech.isRequestingPermission)
                                                }
                                                Spacer()
                                                Menu {
                                                    if message.role == .assistant, viewModel.canPerformGenerationAction(from: message) {
                                                        Button { if isCurrentChatSource(clipboardSource) { beginGenerationAction(messageId: message.id) } } label: {
                                                            Label("重新生成最新回复", systemImage: "arrow.counterclockwise")
                                                        }
                                                    }
                                                    Button { if isCurrentChatSource(clipboardSource) { beginMessageAction(.memory, messageId: message.id) } } label: {
                                                        Label("保存为记忆", systemImage: "brain.head.profile")
                                                    }
                                                    if message.taskProposal == nil {
                                                        Button { if isCurrentChatSource(clipboardSource) { beginMessageAction(.task, messageId: message.id) } } label: {
                                                            Label("创建待办", systemImage: "checklist")
                                                        }
                                                    }
                                                } label: {
                                                    Label("更多消息操作", systemImage: "ellipsis.circle")
                                                        .font(.caption).frame(minWidth: 44, minHeight: 44)
                                                }
                                                .accessibilityLabel("更多消息操作")
                                            }
                                        }
                                        if message.role == .assistant, message.status != .completed {
                                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                                Text(statusTitle(message))
                                                    .font(.caption)
                                                    .foregroundStyle(message.status == .failed ? Color.red : Color.secondary)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                if viewModel.canPerformGenerationAction(from: message) {
                                                    Button { if isCurrentChatSource(clipboardSource) { beginGenerationAction(messageId: message.id) } } label: {
                                                        Label("重试", systemImage: "arrow.clockwise")
                                                            .font(.caption).frame(minWidth: 44, minHeight: 44)
                                                    }
                                                    .accessibilityLabel("使用原问题和图片重试")
                                                }
                                            }
                                        }
                                        }
                                        .id(message.id)
                                        .modifier(AssistantChatMessageViewportFrame(messageId: message.id))
                                    }
                                }
                            }  // 使用 refreshId 强制刷新整个列表
                            .padding()
                    }

                    if hasCurrentChatOwner {
                    if let error = viewModel.error {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(error).font(.caption).textSelection(.enabled)
                            Spacer()
                            Button { viewModel.error = nil } label: { Image(systemName: "xmark.circle") }
                                .accessibilityLabel("关闭错误提示")
                        }
                        .foregroundStyle(Color.red)
                        .padding(12)
                        .background(Color.red.opacity(0.08))
                    }
                    if viewModel.archiveIsLoading { ProgressView("正在准备本地对话…").padding(8) }
                    if let archiveError = viewModel.archiveOperationError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: archiveError).font(.caption).foregroundStyle(.red)
                            if viewModel.archiveRequiresRecovery {
                                Button("重试清理并新建") { requestNewConversation(ownerId: viewModel.activeOwner) }
                                    .disabled(!archiveCanCreateConversation)
                            } else {
                                Button("重试读取会话") {
                                    let ownerId = viewModel.activeOwner
                                    Task { try? await viewModel.waitForArchiveReady(ownerId: ownerId) }
                                }
                            }
                        }.padding(12)
                    }
                    if !viewModel.pendingImages.isEmpty {
                        AssistantImagesView(images: viewModel.pendingImages, onRemove: { id in
                            guard isCurrentChatSource(clipboardSource) else { return }
                            viewModel.removePendingImage(id)
                        })
                            .padding(.horizontal)
                            .disabled(!archiveCanInteract)
                    }
                    if viewModel.isPreparingImage { ProgressView("正在处理图片…").padding(8) }
                    inputArea
                    }
                }
            }
            .assistantNavigationTitle("草包")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .assistantSidebarRoot()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { requestNewConversation(ownerId: viewModel.activeOwner) } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("新建对话")
                        .disabled(!archiveCanCreateConversation)
                }
            }
        }
        .sheet(item: $messageAction) { destination in
            switch destination {
            case .message(.memory, let source):
                AssistantMemoryEditor(userId: source.ownerId, memory: nil,
                    initialText: source.content, sourceMessageId: source.messageId) { record, isNew in
                    do {
                        guard isNew else { throw AssistantRepositoryError.invalidRecord }
                        try viewModel.saveMemoryFromMessage(record, source: source)
                        return nil
                    } catch { return error.localizedDescription }
                }
            case .message(.task, let source):
                AssistantTaskEditor(userId: source.ownerId, task: nil,
                    initialNotes: source.content, sourceMessageId: source.messageId,
                    requiresApprovalForNewTask: true) { record, isNew in
                    do {
                        guard isNew, AssistantOwnerIdentity.matches(record.userId, source.ownerId),
                              record.sourceMessageId == source.messageId, record.requiresApproval else {
                            throw AssistantRepositoryError.invalidRecord
                        }
                        try validateManualTaskSource(source)
                        try await AssistantReminderCoordinator.shared.saveTask(record, isNew: true,
                            ownerId: source.ownerId, requestAuthorization: record.reminderEnabled == true,
                            validateBeforeCommit: { try validateManualTaskSource(source) })
                        return nil
                    } catch { return error.localizedDescription }
                }
            case .taskProposal(let source):
                taskProposalEditor(source)
            }
        }
        .alert("向自定义 API 发送上下文？", isPresented: $viewModel.requiresBYOKConfirmation) {
            Button("取消", role: .cancel) { viewModel.rejectBYOKContext() }
            Button("确认发送") { viewModel.confirmBYOKContext() }
        } message: {
            Text("当前会话历史、已启用的相关记忆和活动任务将发送到：\(viewModel.pendingDestination)。API Key 仅保存在设备 Keychain。")
        }
        .confirmationDialog(generationConfirmationTitle, isPresented: $showGenerationConfirmation, titleVisibility: .visible) {
            Button(generationConfirmationAction) { confirmGenerationAction() }
            Button("取消", role: .cancel) { generationAction = nil }
        } message: {
            Text(generationConfirmationMessage)
        }
        .onAppear {
            viewModel.activateOwner()
        }
        .onChange(of: viewModel.conversationId) { _ in
            clipboardViewEpoch = UUID()
            invalidateTaskToolPresentation()
            speech.cancel()
            selectedPhoto = nil; selectedPhotoSource = nil
            generationAction = nil; showGenerationConfirmation = false
            messageAction = nil
        }
        .onChange(of: AssistantOwnerIdentity.ownerKey(viewModel.activeOwner)) { _ in
            clipboardViewEpoch = UUID()
            invalidateTaskToolPresentation()
            messageAction = nil; generationAction = nil; showGenerationConfirmation = false
        }
        .onChange(of: AssistantOwnerIdentity.ownerKey(auth.user?.id ?? "local-device")) { _ in
            clipboardViewEpoch = UUID(); invalidateTaskToolPresentation()
            messageAction = nil; generationAction = nil; showGenerationConfirmation = false
            speech.cancel(); selectedPhoto = nil; selectedPhotoSource = nil
            viewModel.activateOwner()
        }
        .onReceive(NotificationCenter.default.publisher(for: .loginSuccess)) { _ in clipboardViewEpoch = UUID(); invalidateTaskToolPresentation(); speech.cancel(); selectedPhoto = nil; selectedPhotoSource = nil }
        .onReceive(NotificationCenter.default.publisher(for: .logoutSuccess)) { _ in clipboardViewEpoch = UUID(); invalidateTaskToolPresentation(); speech.cancel(); selectedPhoto = nil; selectedPhotoSource = nil }
        .onDisappear { clipboardViewEpoch = UUID(); invalidateTaskToolPresentation(); selectedPhoto = nil; selectedPhotoSource = nil }
        .onChange(of: speech.errorMessage) { message in
            if let message { viewModel.error = message }
        }
        .onChange(of: selectedPhoto) { item in
            guard let source = selectedPhotoSource, isCurrentChatSource(source) else { return }
            Task {
                do {
                    guard isCurrentChatSource(source) else { return }
                    guard let data = try await item?.loadTransferable(type: Data.self) else { return }
                    guard isCurrentChatSource(source) else { return }
                    await viewModel.addImageData(data, ownerId: source.ownerId, conversationId: source.conversationId)
                } catch {
                    if isCurrentChatSource(source) {
                        viewModel.error = error.localizedDescription
                    }
                }
                if isCurrentChatSource(source), selectedPhoto == item { selectedPhoto = nil; selectedPhotoSource = nil }
            }
        }
        .onChange(of: viewModel.isLoading) { loading in
            guard !loading else { return }
            Task { await appState.refreshAssistantState(force: true) }
        }
    }

    @ViewBuilder
    private func taskProposalCard(messageId: String, proposal: AssistantTaskProposal, isComplete: Bool) -> some View {
        if AssistantOwnerIdentity.matches(proposal.ownerId, viewModel.activeOwner), AssistantOwnerIdentity.matches(proposal.ownerId, AuthService.shared.user?.id ?? "local-device") {
            let source = ClipboardSource(ownerId: viewModel.activeOwner, conversationId: viewModel.conversationId,
                conversationScopeId: viewModel.conversationScopeId, viewEpoch: clipboardViewEpoch)
            let read = taskProposalReceipt(messageId: messageId)
            AssistantTaskToolProposalView(proposal: proposal, receipt: read.receipt, isHistorical: false,
                isBusy: viewModel.taskToolOperationMessageId != nil || taskToolActionRun != nil,
                canReview: viewModel.canApproveTaskProposal(messageId: messageId),
                canDecline: viewModel.canReviewTaskProposal(messageId: messageId),
                canContinue: viewModel.canContinueTaskProposal(messageId: messageId), proposalIsComplete: isComplete, receiptReadFailed: read.failed,
                operationError: read.failed ? AssistantLocalization.string("无法读取待办处理结果，请稍后重试。")
                    : (taskToolErrorMessageId == messageId ? taskToolActionError : nil),
                onReview: { if isCurrentChatSource(source) { reviewTaskProposal(messageId: messageId) } },
                onDecline: { if isCurrentChatSource(source) { declineTaskProposal(messageId: messageId) } },
                onContinue: { if isCurrentChatSource(source) { requestTaskProposalContinuation(messageId: messageId) } }, onOpenCurrentChat: {})
                .confirmationDialog("让助理继续？", isPresented: Binding(
                    get: { showsTaskToolContinuation && pendingTaskToolContinuation?.messageId == messageId },
                    set: { showsTaskToolContinuation = $0 }), titleVisibility: .visible, presenting: pendingTaskToolContinuation) { source in
                    Button("继续请求") { confirmTaskProposalContinuation(source) }
                    Button("取消", role: .cancel) {
                        if pendingTaskToolContinuation?.id == source.id { pendingTaskToolContinuation = nil; showsTaskToolContinuation = false }
                    }
                } message: { _ in
                    Text("将尝试发送本次真实处理结果，最多新增一次 API 请求，服务商可能收费；失败也不会再次创建待办。")
                }
        }
    }

    private func taskProposalReceipt(messageId: String) -> (receipt: AssistantTaskToolReceipt?, failed: Bool) {
        do { return (try viewModel.taskProposalReceipt(messageId: messageId), false) }
        catch { return (nil, true) }
    }

    private func reviewTaskProposal(messageId: String) {
        guard taskToolActionRun == nil, viewModel.taskToolOperationMessageId == nil,
              viewModel.canApproveTaskProposal(messageId: messageId) else { return }
        do {
            let source = try viewModel.makeTaskProposalSource(messageId: messageId)
            taskToolErrorMessageId = nil; taskToolActionError = nil
            messageAction = .taskProposal(source)
        } catch { taskToolErrorMessageId = messageId; taskToolActionError = error.localizedDescription }
    }

    private func taskProposalEditor(_ source: AssistantTaskProposalActionSource) -> some View {
        AssistantTaskEditor(userId: source.ownerId, task: nil, initialTitle: source.proposal.arguments.title,
            initialNotes: source.proposal.arguments.notes, initialDueAt: source.proposal.arguments.parsedDueDate,
            initialTimeZone: source.proposal.arguments.timeZone, initialTaskId: source.proposal.taskId,
            sourceMessageId: source.messageId, requiresApprovalForNewTask: true, allowsRecurrenceEditing: false) { record, isNew in
            do {
                guard isNew, AssistantOwnerIdentity.matches(record.userId, source.ownerId), record.id == source.proposal.taskId, record.requiresApproval else {
                    throw AssistantTaskToolError.invalidArguments
                }
                _ = try await viewModel.approveTaskProposal(source, editedTask: record, enableReminder: record.reminderEnabled == true,
                    scheduleReminder: { baseTask, commitGuard in
                        try commitGuard.validate()
                        var enabled = baseTask; enabled.reminderEnabled = true
                        try await AssistantReminderCoordinator.shared.saveTask(enabled, isNew: false, ownerId: baseTask.userId,
                            requestAuthorization: true, expectedTask: baseTask, validateBeforeCommit: { try commitGuard.validate() })
                    })
                return nil
            } catch {
                // A committed receipt is authoritative even if later notification
                // work or UI publication fails; never offer a second creation.
                if let receipt = try? viewModel.taskProposalReceipt(proposal: source.proposal),
                   receipt.decision == .saved, receipt.taskId == source.proposal.taskId { return nil }
                return error.localizedDescription
            }
        }
    }

    private func declineTaskProposal(messageId: String) {
        guard taskToolActionRun == nil, viewModel.taskToolOperationMessageId == nil,
              viewModel.canReviewTaskProposal(messageId: messageId) else { return }
        do {
            let source = try viewModel.makeTaskProposalSource(messageId: messageId)
            performTaskToolAction(source) { _ = try await viewModel.declineTaskProposal(source) }
        } catch { taskToolErrorMessageId = messageId; taskToolActionError = error.localizedDescription }
    }

    private func requestTaskProposalContinuation(messageId: String) {
        guard taskToolActionRun == nil, viewModel.taskToolOperationMessageId == nil,
              viewModel.canContinueTaskProposal(messageId: messageId) else { return }
        do {
            pendingTaskToolContinuation = try viewModel.makeTaskProposalSource(messageId: messageId)
            showsTaskToolContinuation = true
        } catch { taskToolErrorMessageId = messageId; taskToolActionError = error.localizedDescription }
    }

    private func confirmTaskProposalContinuation(_ source: AssistantTaskProposalActionSource) {
        guard pendingTaskToolContinuation?.id == source.id, taskToolActionRun == nil, viewModel.taskToolOperationMessageId == nil else { return }
        pendingTaskToolContinuation = nil; showsTaskToolContinuation = false
        performTaskToolAction(source) { _ = try await viewModel.continueTaskProposal(source) }
    }

    private func taskToolSourceIsCurrent(_ source: AssistantTaskProposalActionSource, epoch: UUID) -> Bool {
        !Task.isCancelled && epoch == clipboardViewEpoch && AssistantOwnerIdentity.matches(source.ownerId, viewModel.activeOwner)
            && AssistantOwnerIdentity.matches(source.ownerId, AuthService.shared.user?.id ?? "local-device")
            && source.conversationId == viewModel.conversationId
            && viewModel.messages.first(where: { $0.id == source.messageId })?.taskProposal == source.proposal
    }

    private func performTaskToolAction(_ source: AssistantTaskProposalActionSource, operation: @escaping @MainActor () async throws -> Void) {
        guard taskToolActionRun == nil else { return }
        let run = UUID(), epoch = clipboardViewEpoch
        taskToolActionRun = run; taskToolErrorMessageId = source.messageId; taskToolActionError = nil
        taskToolActionTask = Task { @MainActor in
            defer { if taskToolActionRun == run { taskToolActionRun = nil; taskToolActionTask = nil } }
            guard taskToolActionRun == run, taskToolSourceIsCurrent(source, epoch: epoch) else { return }
            do {
                try await operation()
                guard taskToolActionRun == run, taskToolSourceIsCurrent(source, epoch: epoch) else { return }
                taskToolActionError = nil
            } catch {
                guard taskToolActionRun == run, taskToolSourceIsCurrent(source, epoch: epoch) else { return }
                taskToolActionError = error.localizedDescription
            }
        }
    }

    private func invalidateTaskToolPresentation() {
        taskToolActionTask?.cancel(); taskToolActionTask = nil; taskToolActionRun = nil
        pendingTaskToolContinuation = nil; showsTaskToolContinuation = false
        taskToolErrorMessageId = nil; taskToolActionError = nil
        if case .some(.taskProposal(_)) = messageAction { messageAction = nil }
    }

    private func currentClipboardMessage(id: String, source: ClipboardSource) -> ChatMessage? {
        guard !Task.isCancelled, AssistantOwnerIdentity.matches(source.ownerId, viewModel.activeOwner),
              AssistantOwnerIdentity.matches(source.ownerId, AuthService.shared.user?.id ?? "local-device"),
              source.conversationId == viewModel.conversationId, source.conversationScopeId == viewModel.conversationScopeId,
              source.viewEpoch == clipboardViewEpoch else { return nil }
        return viewModel.messages.first { $0.id == id }
    }
    private func copyCurrentMessage(id: String, source: ClipboardSource) {
        guard let message = currentClipboardMessage(id: id, source: source) else { return }
        viewModel.copyMessage(message)
    }
    private func copyCurrentCode(id: String, source: ClipboardSource, blockId: Int, expectedText: String) async -> Bool {
        guard let message = currentClipboardMessage(id: id, source: source), message.role == .assistant else { return false }
        guard let payload = AssistantMarkdown.codeCopyText(in: message.content, blockId: blockId, expectedText: expectedText) else {
            viewModel.error = AssistantLocalization.string("代码内容已变化，请重新选择后复制。")
            return false
        }
        guard currentClipboardMessage(id: id, source: source) != nil else { return false }
        MarkdownTextView.writeCodeToClipboard(payload)
        return true
    }

    private func beginMessageAction(_ kind: MessageActionKind, messageId: String) {
        do {
            if case .task = kind { try validateManualTaskMessage(messageId: messageId) }
            let source = try viewModel.makeActionSource(messageId: messageId)
            isInputFocused = false
            messageAction = .message(kind, source)
        } catch { viewModel.error = error.localizedDescription }
    }
    private func validateManualTaskMessage(messageId: String) throws {
        guard let message = viewModel.messages.first(where: { $0.id == messageId }), message.taskProposal == nil else {
            throw AssistantChatActionError.sourceChanged
        }
    }
    private func validateManualTaskSource(_ source: AssistantChatActionSource) throws {
        try validateManualTaskMessage(messageId: source.messageId)
        try viewModel.validateActionSource(source)
    }
    
    // MARK: - Empty View
    private var emptyView: some View {
        let displayedOwner = viewModel.activeOwner
        return VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green.opacity(0.5))
            
            Text("我是草包，你的个人 AI 助理")
                .font(.headline)
            
            Text("告诉我你想完成什么，我们一起把它做好。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            // Quick Actions
            VStack(spacing: 10) {
                QuickActionButton(title: "制定计划", icon: "checklist") { requestNewConversation(ownerId: displayedOwner, initialText: AssistantLocalization.string("帮我制定今天的计划")) }
                QuickActionButton(title: "总结内容", icon: "text.alignleft") { requestNewConversation(ownerId: displayedOwner, initialText: AssistantLocalization.string("帮我总结这段内容")) }
                QuickActionButton(title: "整理思路", icon: "lightbulb") { requestNewConversation(ownerId: displayedOwner, initialText: AssistantLocalization.string("帮我整理一下思路")) }
            }
            .padding(.top, 8)
            .disabled(!archiveCanCreateConversation)
        }
        .padding(.top, 60)
    }
    
    // MARK: - Input Area
    private var inputArea: some View {
        let source = ClipboardSource(ownerId: viewModel.activeOwner, conversationId: viewModel.conversationId,
            conversationScopeId: viewModel.conversationScopeId, viewEpoch: clipboardViewEpoch)
        return HStack(alignment: .bottom, spacing: 8) {
            PhotosPicker(selection: photoSelection(source: source), matching: .images, preferredItemEncoding: .current) {
                Image(systemName: "photo.badge.plus").frame(width: 44, height: 44)
            }
            .accessibilityLabel("添加图片")
            .disabled(!archiveCanInteract || viewModel.isLoading || viewModel.isPreparingImage || viewModel.pendingImages.count >= 3)
            TextField("说点什么...", text: chatInput(source: source), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .disabled(!archiveCanInteract || speech.isRecording || speech.isRequestingPermission)
                .lineLimit(1...5)
                .onSubmit {
                    if isCurrentChatSource(source) { sendMessage() }
                }
            
            if !viewModel.isLoading {
                Button {
                    guard isCurrentChatSource(source) else { return }
                    if speech.isRecording || speech.isRequestingPermission { speech.stopDictation() }
                    else {
                        let prefix = viewModel.inputText
                        Task {
                            guard isCurrentChatSource(source), appState.selectedTab == .chat else { return }
                            await speech.startDictation(localeIdentifier: viewModel.preferredLocaleIdentifier, ownerId: source.ownerId) { text in
                                guard isCurrentChatSource(source) else { return }
                                viewModel.inputText = prefix.isEmpty ? text : prefix + " " + text
                            }
                        }
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "mic.fill" : "mic")
                        .foregroundStyle(speech.isRecording ? Color.red : Color.caobaoPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(speech.isRecording ? "停止语音输入" : "语音输入")
                .disabled((!archiveCanInteract || viewModel.isPreparingImage) && !speech.isRecording)
            }
            if viewModel.isLoading {
                Button { if isCurrentChatSource(source) { viewModel.cancel() } } label: {
                    Image(systemName: "stop.fill").foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(Color.caobaoPrimary, in: Circle())
                }
                .accessibilityLabel("停止生成")
            } else {
                Button { if isCurrentChatSource(source) { sendMessage() } } label: {
                    Image(systemName: "arrow.up").font(.headline).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.pendingImages.isEmpty ? Color.gray : Color.caobaoPrimary, in: Circle())
                }
                .disabled(!archiveCanInteract || viewModel.isPreparingImage || (viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && viewModel.pendingImages.isEmpty))
                .accessibilityLabel("发送")
            }
        }
        .padding()
        .background(Color.caobaoSystemBackground)
        #if os(iOS)
        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: -5)
        #else
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: -1)
        #endif
    }

    private func isCurrentChatSource(_ source: ClipboardSource) -> Bool {
        !Task.isCancelled && source.viewEpoch == clipboardViewEpoch
            && AssistantOwnerIdentity.matches(source.ownerId, viewModel.activeOwner)
            && AssistantOwnerIdentity.matches(source.ownerId, auth.user?.id ?? "local-device")
            && source.conversationId == viewModel.conversationId && source.conversationScopeId == viewModel.conversationScopeId
    }
    private func photoSelection(source: ClipboardSource) -> Binding<PhotosPickerItem?> {
        Binding(get: { isCurrentChatSource(source) ? selectedPhoto : nil }, set: { item in
            guard isCurrentChatSource(source) else { return }
            selectedPhotoSource = item == nil ? nil : source; selectedPhoto = item
        })
    }
    private func chatInput(source: ClipboardSource) -> Binding<String> {
        Binding(get: { isCurrentChatSource(source) ? viewModel.inputText : "" }, set: { value in
            guard isCurrentChatSource(source) else { return }
            viewModel.inputText = value
        })
    }
    
    private func requestNewConversation(ownerId: String, initialText: String = "") {
        guard archiveCanCreateConversation else { return }
        if initialText.isEmpty { NotificationCenter.default.post(name: .newChat, object: nil, userInfo: ["ownerId": ownerId]) }
        else { NotificationCenter.default.post(name: .assistantPrompt, object: initialText, userInfo: ["ownerId": ownerId]) }
    }
    private var archiveCanInteract: Bool { hasCurrentChatOwner && viewModel.archiveIsReady && !viewModel.archiveIsLoading && !viewModel.isArchiveBusy }
    private var archiveCanCreateConversation: Bool { hasCurrentChatOwner && (viewModel.archiveIsReady || viewModel.archiveRequiresRecovery) && !viewModel.archiveIsLoading && !viewModel.isArchiveBusy }

    private var generationConfirmationTitle: LocalizedStringKey {
        if let source = generationAction, case .retry = source.kind { return "重试此请求？" }
        return "重新生成最新回复？"
    }

    private var generationConfirmationAction: LocalizedStringKey {
        if let source = generationAction, case .retry = source.kind { return "重试" }
        return "重新生成"
    }

    /// System confirmation dialogs display one message Text reliably.
    private var generationConfirmationMessage: LocalizedStringKey {
        if let source = generationAction, case .retry = source.kind {
            if source.willReplaceResponse {
                return source.mode == "byok"
                    ? "重试会发送原问题和图片，保留当前草稿；API 服务商可能收费，不消耗 CaoBao 平台次数。仅成功后替换原回复，失败或停止时保留。"
                    : "重试会发送原问题和图片，保留当前草稿；可能按当前模型和套餐扣除平台次数。仅成功后替换原回复，失败或停止时保留。"
            }
            return source.mode == "byok"
                ? "重试会使用原问题和图片发起新的请求，可能产生 API 服务商费用，不消耗 CaoBao 平台次数。当前输入草稿不会发送。"
                : "重试会使用原问题和图片发起新的平台请求，可能消耗对话额度，具体以当前模型和套餐规则为准。当前输入草稿不会发送。"
        }
        return generationAction?.mode == "byok"
            ? "重新生成会使用原问题和图片发起新的请求，可能产生 API 服务商费用，不消耗 CaoBao 平台次数。成功后替换最新回复；失败或停止时保留原回复。"
            : "重新生成会使用原问题和图片发起新的平台请求，可能消耗对话额度，具体以当前模型和套餐规则为准。成功后替换最新回复；失败或停止时保留原回复。"
    }

    private func beginGenerationAction(messageId: String) {
        do {
            generationAction = try viewModel.makeGenerationActionSource(messageId: messageId)
            isInputFocused = false
            showGenerationConfirmation = true
        } catch { viewModel.error = error.localizedDescription }
    }

    private func confirmGenerationAction() {
        guard let source = generationAction else { return }
        generationAction = nil
        viewModel.performGenerationAction(source)
    }

    private func statusTitle(_ message: ChatMessage) -> String {
        message.statusDescriptionKey(isHistorical: false).map { AssistantLocalization.string($0) } ?? ""
    }

    private func sendMessage() {
        // 收缩键盘
        isInputFocused = false
        speech.stopDictation()
        speech.stopSpeaking()
        let userId = viewModel.ownerUserId
        viewModel.sendMessage(userId: userId)
    }
}

#if os(iOS)
struct AssistantImagesView: View {
    let images: [AssistantImage]
    var onRemove: ((String) -> Void)? = nil
    @State private var previewImage: AssistantImage?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(images) { image in
                    if let data = image.data, let thumbnail = UIImage(data: data) {
                        Button { previewImage = image } label: {
                            Image(uiImage: thumbnail).resizable().scaledToFill()
                                .frame(width: 100, height: 100)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("预览附加图片")
                        .overlay(alignment: .topTrailing) {
                            if let onRemove {
                                Button { onRemove(image.id) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.7))
                                        .frame(width: 44, height: 44)
                                }.accessibilityLabel("移除图片")
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .sheet(item: $previewImage) { image in
            NavigationStack {
                if let data = image.data, let value = UIImage(data: data) {
                    Image(uiImage: value).resizable().scaledToFit().padding()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("关闭") { previewImage = nil } }
                        }
                }
            }
        }
    }
}
#else
/// macOS keeps the shared ChatView source available for the common target;
/// image attachments are rendered by the desktop composer when supported.
struct AssistantImagesView: View {
    let images: [AssistantImage]
    var onRemove: ((String) -> Void)? = nil

    var body: some View {
        if images.isEmpty {
            EmptyView()
        } else {
            Text("已附加 \(images.count) 张图片")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
#endif

// MARK: - Owner-bound chat viewport (iOS 16 / macOS 13 compatible)
private struct AssistantChatViewportMeasurement: Equatable {
    let sourceKey: String
    let sessionId: UUID
    let coordinateSpace: UUID
    let messageEpoch: UUID
}

private struct AssistantChatViewportMeasurementKey: EnvironmentKey {
    static let defaultValue: AssistantChatViewportMeasurement? = nil
}

private extension EnvironmentValues {
    var assistantChatViewportMeasurement: AssistantChatViewportMeasurement? {
        get { self[AssistantChatViewportMeasurementKey.self] }
        set { self[AssistantChatViewportMeasurementKey.self] = newValue }
    }
}

private struct AssistantChatViewportPreference: Equatable {
    var source: AssistantChatViewportMeasurement?
    var viewportSize: CGSize?
    var contentFrame: CGRect?
    var frames: [AssistantChatViewportFrame] = []
}

private struct AssistantChatViewportPreferenceKey: PreferenceKey {
    static var defaultValue = AssistantChatViewportPreference()
    static func reduce(value: inout AssistantChatViewportPreference, nextValue: () -> AssistantChatViewportPreference) {
        let next = nextValue()
        guard next.source != nil else { return }
        guard value.source == next.source else { value = next; return }
        if let size = next.viewportSize { value.viewportSize = size }
        if let frame = next.contentFrame { value.contentFrame = frame }
        value.frames.append(contentsOf: next.frames)
    }
}

private struct AssistantChatMessageViewportFrame: ViewModifier {
    let messageId: String
    @Environment(\.assistantChatViewportMeasurement) private var measurement
    func body(content: Content) -> some View {
        content.background(GeometryReader { proxy in
            if let measurement {
                let frame = proxy.frame(in: .named(measurement.coordinateSpace))
                Color.clear.preference(key: AssistantChatViewportPreferenceKey.self, value: AssistantChatViewportPreference(
                    source: measurement, frames: [AssistantChatViewportFrame(messageId: messageId, minY: Double(frame.minY), maxY: Double(frame.maxY))]))
            } else { Color.clear }
        })
    }
}

@MainActor
private struct AssistantChatViewportScroll<Content: View>: View {
    let ownerId: String
    let conversationId: String
    let scopeId: UUID
    let viewEpoch: UUID
    let messages: [AssistantChatViewportMessage]
    let isGenerating: Bool
    let scrollTrigger: UUID
    let isCurrent: () -> Bool
    let content: Content
    @State private var session: AssistantChatViewportSession?
    @State private var sessionSourceKey: String?
    @State private var coordinateSpace = UUID()
    @State private var followingLatest = true
    @State private var lastGeometry: AssistantChatViewportPreference?
    @State private var lastWidth: CGFloat?
    @State private var dragging = false
    @State private var userScrolling = false
    @State private var settleTask: Task<Void, Never>?
    @State private var settleRunId: UUID?
    @State private var scrollTask: Task<Void, Never>?
    @State private var restorationTarget: AssistantChatViewportTarget?
    @State private var restorationIssued = false
    @State private var observedMessages: [AssistantChatViewportMessage] = []
    @State private var geometryMessageEpoch = UUID()
    private let store = AssistantChatViewportStore.shared

    init(ownerId: String, conversationId: String, scopeId: UUID, viewEpoch: UUID,
         messages: [AssistantChatViewportMessage], isGenerating: Bool, scrollTrigger: UUID,
         isCurrent: @escaping () -> Bool, @ViewBuilder content: () -> Content) {
        self.ownerId = ownerId; self.conversationId = conversationId; self.scopeId = scopeId; self.viewEpoch = viewEpoch
        self.messages = messages; self.isGenerating = isGenerating; self.scrollTrigger = scrollTrigger
        self.isCurrent = isCurrent; self.content = content()
    }
    private var sourceKey: String {
        Data(ownerId.utf8).base64EncodedString() + "." + Data(conversationId.utf8).base64EncodedString()
            + "." + scopeId.uuidString + "." + viewEpoch.uuidString
    }
    private var measurement: AssistantChatViewportMeasurement? {
        guard let session, sessionSourceKey == sourceKey, observedMessages == messages, isCurrent() else { return nil }
        return AssistantChatViewportMeasurement(sourceKey: sourceKey, sessionId: session.id, coordinateSpace: coordinateSpace, messageEpoch: geometryMessageEpoch)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                measuredScroll(proxy: proxy)
                if !followingLatest, !messages.isEmpty, measurement != nil {
                    Button { resumeLatest(proxy: proxy) } label: {
                        Label("回到最新消息", systemImage: "arrow.down.to.line")
                            .font(.callout).padding(.horizontal, 12).frame(minHeight: 44)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain).padding(12)
                    .accessibilityLabel("回到最新消息")
                }
            }
            .task(id: sourceKey) { start(proxy: proxy) }
            .onChange(of: messages) { _ in reconcileMessages(proxy: proxy) }
            .onChange(of: scrollTrigger) { _ in followLatestIfAllowed(proxy: proxy) }
            .onDisappear { finish() }
        }
    }

    private func measuredScroll(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            content.background(GeometryReader { geometry in
                Color.clear.preference(key: AssistantChatViewportPreferenceKey.self,
                    value: AssistantChatViewportPreference(source: measurement, contentFrame: geometry.frame(in: .named(coordinateSpace))))
            })
        }
        .environment(\.assistantChatViewportMeasurement, measurement)
        .coordinateSpace(name: coordinateSpace)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: AssistantChatViewportPreferenceKey.self,
                value: AssistantChatViewportPreference(source: measurement, viewportSize: geometry.size))
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.chat.messages")
        .onPreferenceChange(AssistantChatViewportPreferenceKey.self) { value in observe(value, proxy: proxy) }
        .simultaneousGesture(DragGesture(minimumDistance: 2).onChanged { value in
            guard abs(value.translation.height) > abs(value.translation.width) else { return }
            beginUserScroll()
        }.onEnded { _ in
            guard userScrolling else { return }
            dragging = false; scheduleSettle(proxy: proxy)
        })
    }

    private func active(_ session: AssistantChatViewportSession, key: String) -> Bool {
        isCurrent() && key == sourceKey && sessionSourceKey == key && self.session?.id == session.id && store.state(for: session) != nil
    }
    private func start(proxy: ScrollViewProxy) {
        finish()
        guard isCurrent(), let context = AssistantChatViewportContext(ownerId: ownerId, conversationId: conversationId),
              let start = store.begin(context: context, messages: messages) else { return }
        session = start.session; sessionSourceKey = sourceKey; followingLatest = start.update.state.followingLatest
        observedMessages = messages; geometryMessageEpoch = UUID()
        if let target = start.update.target { requestScroll(target, proxy: proxy, restoring: true) }
    }
    private func finish() {
        cancelSettle(); scrollTask?.cancel(); scrollTask = nil
        if let session { store.finish(session: session) }
        session = nil; sessionSourceKey = nil; lastGeometry = nil; lastWidth = nil
        observedMessages = []; geometryMessageEpoch = UUID()
        restorationTarget = nil; restorationIssued = false; dragging = false; userScrolling = false
    }
    private func modelGeometry(_ value: AssistantChatViewportPreference) -> AssistantChatViewportGeometry? {
        guard let session, active(session, key: sourceKey), let source = value.source,
              source.sourceKey == sourceKey, source.sessionId == session.id, source.coordinateSpace == coordinateSpace,
              source.messageEpoch == geometryMessageEpoch, observedMessages == messages,
              let size = value.viewportSize, let content = value.contentFrame,
              size.width.isFinite, size.width > 0, size.height.isFinite, size.height > 0,
              content.minY.isFinite, content.maxY.isFinite else { return nil }
        return AssistantChatViewportGeometry(viewportHeight: Double(size.height), contentMinY: Double(content.minY),
            bottomY: Double(content.maxY), frames: value.frames)
    }
    private func observe(_ value: AssistantChatViewportPreference, proxy: ScrollViewProxy) {
        guard let session, let geometry = modelGeometry(value), let width = value.viewportSize?.width else { return }
        let previous = lastGeometry
        lastGeometry = value
        let changedWidth = lastWidth.map { abs($0 - width) > 1 } ?? false
        lastWidth = width
        if changedWidth, !userScrolling, let update = store.restore(session: session, messages: messages), let target = update.target {
            followingLatest = update.state.followingLatest
            requestScroll(target, proxy: proxy, restoring: true); return
        }
        if let target = restorationTarget {
            guard restorationIssued, reached(target, geometry: geometry) else { return }
            restorationTarget = nil; restorationIssued = false
        }
        let moved = previous?.contentFrame.map { abs($0.minY - CGFloat(geometry.contentMinY)) > 0.5 } ?? false
        guard let state = store.observe(session: session, messages: messages, geometry: geometry, userIsScrolling: userScrolling && moved) else { return }
        followingLatest = state.followingLatest
        if userScrolling, !dragging, moved || previous?.source?.messageEpoch != value.source?.messageEpoch || settleTask == nil {
            scheduleSettle(proxy: proxy)
        }
        if !userScrolling, state.followingLatest, let oldHeight = previous?.viewportSize?.height,
           abs(oldHeight - CGFloat(geometry.viewportHeight)) > 1 { followLatestIfAllowed(proxy: proxy) }
    }
    private func reached(_ target: AssistantChatViewportTarget, geometry: AssistantChatViewportGeometry) -> Bool {
        AssistantChatViewportStore.hasReached(target, geometry: geometry, firstMessageId: messages.first?.id)
    }
    private func requestScroll(_ target: AssistantChatViewportTarget, proxy: ScrollViewProxy, restoring: Bool) {
        guard let session, active(session, key: sourceKey), observedMessages == messages, store.canApply(session: session, target: target) else { return }
        let key = sourceKey
        scrollTask?.cancel()
        if restoring { restorationTarget = target; restorationIssued = false }
        scrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, active(session, key: key), observedMessages == messages, !userScrolling, store.canApply(session: session, target: target) else { return }
            proxy.scrollTo(target.messageId, anchor: target.isLatest ? .bottom : .top)
            if restoring { restorationIssued = true }
            await Task.yield()
            guard !Task.isCancelled, active(session, key: key) else { return }
            if restoring, let value = lastGeometry, let geometry = modelGeometry(value), reached(target, geometry: geometry) {
                restorationTarget = nil; restorationIssued = false
                if let state = store.observe(session: session, messages: messages, geometry: geometry, userIsScrolling: false) { followingLatest = state.followingLatest }
            }
        }
    }
    private func beginUserScroll() {
        guard let session, active(session, key: sourceKey) else { return }
        dragging = true; userScrolling = true; cancelSettle(); scrollTask?.cancel()
        restorationTarget = nil; restorationIssued = false
        if let value = lastGeometry, let geometry = modelGeometry(value),
           let state = store.observe(session: session, messages: messages, geometry: geometry, userIsScrolling: false) { followingLatest = state.followingLatest }
    }
    private func scheduleSettle(proxy: ScrollViewProxy) {
        guard let session, active(session, key: sourceKey), userScrolling, !dragging else { return }
        let key = sourceKey, runId = UUID()
        cancelSettle(); settleRunId = runId
        settleTask = Task { @MainActor in
            defer { if settleRunId == runId { settleRunId = nil; settleTask = nil } }
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            guard !Task.isCancelled, settleRunId == runId, active(session, key: key), !dragging, let value = lastGeometry, let geometry = modelGeometry(value) else { return }
            if let state = store.observe(session: session, messages: messages, geometry: geometry, userIsScrolling: false) { followingLatest = state.followingLatest }
            userScrolling = false
            followLatestIfAllowed(proxy: proxy)
        }
    }
    private func cancelSettle() {
        settleRunId = nil; settleTask?.cancel(); settleTask = nil
    }
    private func reconcileMessages(proxy: ScrollViewProxy) {
        guard let session, active(session, key: sourceKey) else { return }
        observedMessages = messages; geometryMessageEpoch = UUID()
        let visible = lastGeometry?.frames.filter { frame in
            frame.maxY > 0 && frame.minY < Double(lastGeometry?.viewportSize?.height ?? 0)
        }.sorted { $0.minY < $1.minY }.map(\.messageId) ?? []
        guard let update = store.messagesChanged(session: session, messages: messages, isGenerating: isGenerating, visibleMessageIds: visible) else { return }
        followingLatest = update.state.followingLatest
        if update.resumedByUserMessage {
            dragging = false; userScrolling = false; cancelSettle()
            restorationTarget = nil; restorationIssued = false
        }
        if let target = update.target, !userScrolling { requestScroll(target, proxy: proxy, restoring: !target.isLatest) }
    }
    private func followLatestIfAllowed(proxy: ScrollViewProxy) {
        guard let session, active(session, key: sourceKey), !userScrolling,
              store.state(for: session)?.followingLatest == true, let last = messages.last else { return }
        if let target = restorationTarget, !target.isLatest { return }
        requestScroll(.latest(last.id), proxy: proxy, restoring: restorationTarget != nil)
    }
    private func resumeLatest(proxy: ScrollViewProxy) {
        guard let session, active(session, key: sourceKey), let update = store.resumeLatest(session: session, messages: messages) else { return }
        dragging = false; userScrolling = false; cancelSettle(); restorationTarget = nil; restorationIssued = false
        followingLatest = update.state.followingLatest
        if let target = update.target { requestScroll(target, proxy: proxy, restoring: false) }
    }
}

// MARK: - Preview
#Preview {
    ContentView()
        .environmentObject(AppState())
}
