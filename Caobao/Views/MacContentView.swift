import SwiftUI

#if os(macOS)
import AppKit

// MARK: - Mac Content View (三栏布局)
struct MacContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var chatViewModel = ChatViewModel()
    @State private var selectedFeature: MacFeature = .home
    @State private var selectedConversationId: String?
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var newChatTask: Task<Void, Never>?
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 左侧边栏 - 功能导航
            MacSidebarView(
                selectedFeature: $selectedFeature,
                selectedConversationId: $selectedConversationId,
                conversations: chatViewModel.conversations
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            // 右侧内容区
            MacDetailView(
                selectedFeature: selectedFeature,
                conversationId: selectedConversationId,
                chatViewModel: chatViewModel
            )
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    NotificationCenter.default.post(name: .newChat, object: nil)
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                }
                
                Spacer()
                
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gear")
                }
                .accessibilityLabel("设置")
            }
        }
        .sheet(isPresented: $showSettings) {
            // The assistant settings flow owns the account preference PATCH
            // and uses the server snapshot loaded by AppState. Keep the
            // generic app settings separate so macOS has the same preference
            // contract as iOS instead of silently saving only local values.
            AssistantSettingsSheet()
                .environmentObject(appState)
                .frame(width: 560, height: 700)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChat)) { _ in
            newChatTask?.cancel()
            let ownerId = AuthService.shared.user?.id ?? "local-device"
            newChatTask = Task { @MainActor in
                let opened = await chatViewModel.requestNewConversation(ownerId: ownerId)
                guard !Task.isCancelled else { return }
                selectedConversationId = nil
                selectedFeature = .chat
                if !opened {
                    // ChatView owns the confirmation dialog when the current
                    // conversation has a draft or an active generation.
                    return
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macOpenConversation)) { notification in
            guard let id = notification.userInfo?["conversationId"] as? String, !id.isEmpty else { return }
            selectedConversationId = id
            appState.pendingAssistantConversationId = nil
            selectedFeature = .chat
        }
        .onReceive(NotificationCenter.default.publisher(for: .macOpenProactive)) { _ in
            selectedFeature = .proactive
            selectedConversationId = nil
        }
        .onChange(of: appState.pendingAssistantConversationId) { id in
            guard let id, !id.isEmpty else { return }
            selectedConversationId = id
            selectedFeature = .chat
            appState.pendingAssistantConversationId = nil
        }
        .onChange(of: appState.selectedTab) { tab in
            switch tab {
            case .home: selectedFeature = .home
            case .chat: selectedFeature = .chat
            case .fortune: selectedFeature = .fortune
            case .profile: selectedFeature = .profile
            }
            if tab != .chat { selectedConversationId = nil }
        }
        .onDisappear {
            newChatTask?.cancel()
            newChatTask = nil
        }
        .task {
            if let id = appState.pendingAssistantConversationId, !id.isEmpty {
                selectedConversationId = id
                selectedFeature = .chat
                appState.pendingAssistantConversationId = nil
            }
            // Login/foreground on macOS has no iOS scene task. Refresh the
            // server-authoritative preferences before bootstrapping local
            // cloud data so the settings sheet starts from the account state.
            if AuthService.shared.isLoggedIn {
                await appState.refreshAssistantState()
                do {
                    try await chatViewModel.waitForArchiveReady(ownerId: chatViewModel.ownerUserId)
                    await chatViewModel.syncFromCloud()
                } catch {
                    // The archive bootstrap publishes its own user-visible error.
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, AuthService.shared.isLoggedIn else { return }
            Task { @MainActor in
                await appState.refreshAssistantState()
            }
        }
    }
}

/// Desktop home keeps the same information hierarchy without importing the
/// iPhone-only home shell. Detailed proactive rules and task management remain
/// shared workspace screens.
struct MacHomeView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var proactiveStore = AssistantProactiveStore.shared
    private var ownerId: String { AuthService.shared.user?.id ?? "local-device" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("今天继续做什么？").font(.largeTitle.bold())
                    Text("对话、任务和主动更新都在同一个工作区。")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button {
                        NotificationCenter.default.post(name: .newChat, object: nil)
                    } label: {
                        Label("开始对话", systemImage: "message.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        appState.selectedTab = .fortune
                    } label: {
                        Label("查看任务", systemImage: "checklist")
                    }
                    .buttonStyle(.bordered)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("主动更新", systemImage: "bell.badge.fill")
                            .font(.headline)
                        let currentProfile = proactiveStore.profile(for: ownerId)
                        if currentProfile.enabled {
                            (Text("已开启 · ") + Text(currentProfile.mode.title))
                                .foregroundColor(.secondary)
                        } else {
                            Text("默认关闭，可在主动规则中开启")
                                .foregroundStyle(.secondary)
                        }
                        NavigationLink("管理主动规则") {
                            AssistantProactiveView(userId: ownerId)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(32)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("首页")
    }
}

struct MacProfileView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var auth = AuthService.shared
    @State private var usage = AssistantUsageStats()

    private var ownerId: String { auth.user?.id ?? "local-device" }
    private var displayName: String {
        let name = auth.user?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (auth.isLoggedIn ? "草包用户" : "本机用户") : name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: auth.isLoggedIn ? "person.crop.circle.fill" : "person.crop.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.caobaoPrimary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName).font(.title2.bold())
                        Text(auth.isLoggedIn ? "Apple 账号已登录" : "本机模式")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                GroupBox("使用统计") {
                    HStack(spacing: 24) {
                        MacProfileMetric(title: "对话", value: "\(usage.userMessages)")
                        MacProfileMetric(title: "使用天数", value: "\(usage.usageDays)")
                        MacProfileMetric(title: "连续使用", value: "\(usage.currentStreak) 天")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("更多信息") {
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink {
                            MacDetailedStatsView()
                        } label: {
                            Label("详细统计", systemImage: "chart.bar.xaxis")
                        }
                        NavigationLink {
                            MacAboutView()
                        } label: {
                            Label("关于草包", systemImage: "info.circle")
                        }
                        NavigationLink {
                            MacOfficialView()
                        } label: {
                            Label("官方信息", systemImage: "building.2")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("工作区") {
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink {
                            AssistantMemoriesView(userId: ownerId)
                        } label: {
                            Label("记忆与隐私", systemImage: "brain.head.profile")
                        }
                        NavigationLink {
                            AssistantSubscriptionView()
                        } label: {
                            Label("订阅与额度", systemImage: "creditcard")
                        }
                        NavigationLink {
                            AssistantSettingsSheet().environmentObject(appState)
                        } label: {
                            Label("助理设置", systemImage: "gearshape")
                        }
                        NavigationLink {
                            AssistantCharactersView(ownerId: AuthService.shared.user?.id ?? "local-device")
                        } label: {
                            Label("自定义角色", systemImage: "person.2")
                        }
                        NavigationLink {
                            AccountSettingsView()
                        } label: {
                            Label("账号与数据", systemImage: "person.crop.circle.badge.gearshape")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if auth.isLoggedIn {
                    Button("退出登录", role: .destructive) { auth.logout() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle("我的")
        .task { usage = AssistantUsageStatsStore.shared.snapshot(ownerId: ownerId) }
        .onReceive(auth.$user) { _ in
            usage = AssistantUsageStatsStore.shared.snapshot(ownerId: ownerId)
        }
    }
}

private struct MacProfileMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title3.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MacDetailedStatsView: View {
    @ObservedObject private var auth = AuthService.shared
    @State private var stats = AssistantUsageStats()

    private var ownerId: String { auth.user?.id ?? "local-device" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("数据统计").font(.largeTitle.bold())
                Text("仅统计当前账号在本机完成的对话，不代表服务端额度或账单。")
                    .font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MacStatsMetric(title: "我的消息", value: "\(stats.userMessages)")
                    MacStatsMetric(title: "AI 回复", value: "\(stats.assistantMessages)")
                    MacStatsMetric(title: "今日消息", value: "\(stats.todayMessages)")
                    MacStatsMetric(title: "本月消息", value: "\(stats.monthMessages)")
                    MacStatsMetric(title: "使用天数", value: "\(stats.usageDays)")
                    MacStatsMetric(title: "当前连续", value: "\(stats.currentStreak) 天")
                }
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle("数据统计")
        .task { stats = AssistantUsageStatsStore.shared.snapshot(ownerId: ownerId) }
        .onReceive(auth.$user) { _ in
            stats = AssistantUsageStatsStore.shared.snapshot(ownerId: ownerId)
        }
    }
}

private struct MacStatsMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct MacAboutView: View {
    private let features: [(String, String, String)] = [
        ("bubble.left.and.bubble.right", "对话与任务", "把问题、计划和执行结果放在同一个工作区。"),
        ("brain.head.profile", "记忆与隐私", "记忆按账号隔离，授权、关闭和删除都由你控制。"),
        ("bell.badge", "主动更新", "按你创建的规则提醒，支持安静时段和全局暂停。"),
        ("arrow.triangle.2.circlepath", "跨设备继续", "会话和记忆可以在已登录设备间继续使用。")
    ]

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "版本 \(version)（\(build)）"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Image("logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("关于草包").font(.largeTitle.bold())
                        Text("少点空话，把事情做好。")
                            .font(.title3)
                            .foregroundStyle(Color.caobaoPrimary)
                        Text(versionText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("草包是一个以生产力助理为主、陪伴模式可选的个人 AI 助理。对话、记忆、任务和主动更新由同一个工作区管理。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox("核心能力") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(features, id: \.1) { feature in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: feature.0)
                                    .foregroundStyle(Color.caobaoPrimary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(feature.1).font(.headline)
                                    Text(feature.2)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }

                GroupBox("隐私与控制") {
                    Text("草包不会把本机统计当作服务端额度，也不会在没有用户确认时执行高风险外部操作。你可以在“记忆与隐私”和“主动规则”中查看、暂停或删除相关数据。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GroupBox("法律与支持") {
                    VStack(alignment: .leading, spacing: 9) {
                        NavigationLink("用户协议") { LegalView(type: .agreement) }
                        NavigationLink("隐私政策") { LegalView(type: .privacy) }
                        NavigationLink("AI 使用声明") { LegalView(type: .aiDeclaration) }
                        Link("联系客服：2900814034@qq.com", destination: URL(string: "mailto:2900814034@qq.com")!)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(32)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .navigationTitle("关于草包")
    }
}

private struct MacOfficialView: View {
    private let products: [(String, String, String, Bool)] = [
        ("草包助手", "毒舌但有用的个人 AI 助理", "对话、记忆、任务、主动更新", false),
        ("草根社区", "AI 原生内容与工具社区", "创作分享、提示词和 Agent 工坊", true)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("草台班子", systemImage: "building.2")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Color.caobaoPrimary)
                    Text("世界就是一个巨大的草台班子")
                        .font(.title3.bold())
                    Text("看似严肃的世界，其实每个人都在摸着石头过河。我们做有用、好用、有趣的 AI 产品。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GroupBox("我们的理念") {
                    VStack(alignment: .leading, spacing: 10) {
                        officialPrinciple("有用", "不装高大上，只解决实际问题。", "checkmark.seal")
                        officialPrinciple("好用", "简单直接，上手就会。", "hand.thumbsup")
                        officialPrinciple("有趣", "毒舌但温暖，吐槽但有爱。", "face.smiling")
                    }
                }

                GroupBox("产品矩阵") {
                    VStack(spacing: 10) {
                        ForEach(products, id: \.0) { product in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: product.3 ? "sparkles" : "person.crop.circle")
                                    .foregroundStyle(product.3 ? .purple : Color.caobaoPrimary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(LocalizedStringKey(product.0)).font(.headline)
                                        if product.3 {
                                            Text(LocalizedStringKey("开发中"))
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(.purple.opacity(0.12), in: Capsule())
                                                .foregroundStyle(.purple)
                                        }
                                    }
                                    Text(LocalizedStringKey(product.1)).font(.subheadline)
                                    Text(LocalizedStringKey(product.2)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }

                GroupBox("联系我们") {
                    VStack(alignment: .leading, spacing: 9) {
                        Link("商务合作：2900814034@qq.com", destination: URL(string: "mailto:2900814034@qq.com")!)
                        Text("工作时间：工作日 9:00–18:00")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Link("访问草包官网", destination: URL(string: "https://caobao.chat")!)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(32)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .navigationTitle("官方信息")
    }

    private func officialPrinciple(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.caobaoPrimary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct MacHistoryView: View {
    @ObservedObject var chatViewModel: ChatViewModel
    @State private var searchText = ""

    private var visibleConversations: [AssistantConversationSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return chatViewModel.conversations }
        return chatViewModel.conversations.filter {
            $0.title.lowercased().contains(query) || $0.preview.lowercased().contains(query)
        }
    }

    var body: some View {
        Group {
            if visibleConversations.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 42)).foregroundStyle(.secondary)
                    Text(searchText.isEmpty ? "暂无历史记录" : "没有匹配的对话")
                        .font(.headline)
                    Text("开始一段新对话后，它会出现在这里。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleConversations) { conversation in
                    Button {
                        NotificationCenter.default.post(name: .macOpenConversation, object: nil,
                            userInfo: ["conversationId": conversation.id])
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conversation.title.isEmpty ? "未命名对话" : conversation.title)
                                .font(.headline).lineLimit(1)
                            if !conversation.preview.isEmpty {
                                Text(conversation.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text(conversation.date, style: .date).font(.caption2).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("历史")
        .searchable(text: $searchText, prompt: "搜索对话")
        .task {
            try? await chatViewModel.waitForArchiveReady(ownerId: AuthService.shared.user?.id ?? "local-device")
            await chatViewModel.loadConversationsFromHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .conversationHistoryChanged)) { _ in
            Task { await chatViewModel.loadConversationsFromHistory() }
        }
    }
}

// MARK: - Mac Feature Enum
enum MacFeature: String, CaseIterable, Identifiable, Hashable {
    case home = "首页"
    case chat = "自由对话"
    case memories = "记忆"
    case proactive = "主动规则"
    case subscription = "订阅"
    case settings = "设置与隐私"
    case tools = "工具模板"
    case fortune = "任务"
    case analyze = "文件秒懂"
    case quote = "扎心金句"
    case roast = "毒舌吐槽"
    case nickname = "个性昵称"
    case rate = "犀利评分"
    case decision = "决策助手"
    case morningReport = "早报"
    case eveningReport = "晚报"
    case favorites = "收藏"
    case history = "历史"
    case profile = "我的"
    
    var id: String { rawValue }
    var localizedTitle: LocalizedStringKey { LocalizedStringKey(rawValue) }

    var isLegacyUnavailable: Bool {
        switch self {
        case .analyze, .quote, .roast, .nickname, .rate, .decision, .morningReport, .eveningReport:
            return true
        default:
            return false
        }
    }
    
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .chat: return "message.fill"
        case .memories: return "brain.head.profile"
        case .proactive: return "bell.badge.fill"
        case .subscription: return "creditcard.fill"
        case .settings: return "gearshape.fill"
        case .tools: return "square.grid.2x2.fill"
        case .fortune: return "checklist"
        case .analyze: return "photo.fill"
        case .quote: return "quote.bubble.fill"
        case .roast: return "flame.fill"
        case .nickname: return "person.crop.circle.badge.plus"
        case .rate: return "star.leadinghalf.filled"
        case .decision: return "questionmark.circle.fill"
        case .morningReport: return "sun.max.fill"
        case .eveningReport: return "moon.fill"
        case .favorites: return "heart.fill"
        case .history: return "clock.fill"
        case .profile: return "person.fill"
        }
    }
    
    var iconColor: Color {
        switch self {
        case .home: return .green
        case .chat: return .green
        case .memories: return .purple
        case .proactive: return .orange
        case .subscription: return .blue
        case .settings: return .gray
        case .tools: return .purple
        case .fortune: return .green
        case .analyze: return .blue
        case .quote: return .purple
        case .roast: return .red
        case .nickname: return .pink
        case .rate: return .yellow
        case .decision: return .cyan
        case .morningReport: return .orange
        case .eveningReport: return .indigo
        case .favorites: return .red
        case .history: return .gray
        case .profile: return .green
        }
    }
}

// MARK: - Mac Sidebar View
struct MacSidebarView: View {
    @Binding var selectedFeature: MacFeature
    @Binding var selectedConversationId: String?
    let conversations: [AssistantConversationSummary]
    
    var body: some View {
        ZStack {
            // 渐变背景 - 温暖的橙黄渐变
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
            // 核心功能
            Section("核心功能") {
                ForEach([MacFeature.home, .chat, .fortune]) { feature in
                    Button {
                            selectedFeature = feature
                            selectedConversationId = nil
                        } label: {
                            MacFeatureRow(feature: feature, isSelected: selectedFeature == feature)
                        }
                        .buttonStyle(.plain)
                }
            }

            Section("工作区") {
                ForEach([MacFeature.memories, .proactive, .subscription, .settings, .history, .profile]) { feature in
                    Button {
                            selectedFeature = feature
                            selectedConversationId = nil
                        } label: {
                            MacFeatureRow(feature: feature, isSelected: selectedFeature == feature)
                        }
                        .buttonStyle(.plain)
                }
            }
            
            // Legacy tools stay behind one secondary entry instead of
            // competing with Home, Chat, Tasks and the account workspace.
            Section("发现") {
                ForEach([MacFeature.tools]) { feature in
                    Button {
                            selectedFeature = feature
                            selectedConversationId = nil
                        } label: {
                            MacFeatureRow(feature: feature, isSelected: selectedFeature == feature)
                        }
                        .buttonStyle(.plain)
                }
            }

            // Recent conversations remain visible on desktop so users can
            // continue work without returning to Home first.
            Section("最近对话") {
                if conversations.isEmpty {
                    Text("暂无最近对话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(conversations.prefix(8))) { conversation in
                        Button {
                            selectedFeature = .chat
                            selectedConversationId = conversation.id
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.title.isEmpty ? "未命名对话" : conversation.title)
                                    .lineLimit(1)
                                if !conversation.preview.isEmpty {
                                    Text(conversation.preview)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("草包")
        }
    }
}

// MARK: - Mac Feature Row
struct MacFeatureRow: View {
    let feature: MacFeature
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: feature.icon)
                .foregroundStyle(feature.iconColor)
                .frame(width: 20)
            
            Text(feature.localizedTitle)
                .font(.body)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(6)
        .accessibilityElement(children: .combine)
    }
}

/// Secondary tool catalog for the desktop workspace. The tools remain
/// available without occupying first-level sidebar space.
struct MacToolsView: View {
    @State private var unavailableToolTitle = ""
    @State private var showingUnavailableTool = false

    private let tools: [MacFeature] = [
        .analyze, .quote, .roast, .nickname, .rate, .decision,
        .morningReport, .eveningReport, .favorites
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("这些功能作为工具模板提供，不会打断首页、对话和任务工作流。标记为待迁移的旧工具不会发起已知 404 请求；本机收藏仍可正常打开。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                Section("工具模板") {
                    ForEach(tools, id: \.self) { feature in
                        if feature.isLegacyUnavailable {
                            Button {
                                unavailableToolTitle = feature.rawValue
                                showingUnavailableTool = true
                            } label: {
                                MacFeatureRow(feature: feature, isSelected: false)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("服务端接口待迁移")
                        } else {
                            NavigationLink(value: feature) {
                                MacFeatureRow(feature: feature, isSelected: false)
                            }
                        }
                    }
                }
            }
            .navigationTitle("工具模板")
            .alert("功能暂未启用", isPresented: $showingUnavailableTool) {
                Button("知道了", role: .cancel) { }
            } message: {
                Text(verbatim: String(format: AssistantLocalization.string("%@ 当前调用的旧接口尚未在生产服务端提供，请使用对话工作区。"), unavailableToolTitle))
            }
            .navigationDestination(for: MacFeature.self) { feature in
                MacToolDestination(feature: feature)
            }
        }
    }
}

private struct MacToolDestination: View {
    let feature: MacFeature

    var body: some View {
        Group {
            switch feature {
            case .analyze: AnalyzeView()
            case .quote: QuoteView()
            case .roast: RoastView()
            case .nickname: NicknameView()
            case .rate: RateView()
            case .decision: DecisionView()
            case .morningReport: MorningReportView()
            case .eveningReport: EveningReportView()
            case .favorites: LocalQuoteFavoritesView()
            default: MacHomeView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Mac Detail View
struct MacDetailView: View {
    let selectedFeature: MacFeature
    let conversationId: String?
    @ObservedObject var chatViewModel: ChatViewModel
    
    var body: some View {
        Group {
            switch selectedFeature {
            case .home:
                MacHomeView()
            case .chat:
                MacChatView(chatViewModel: chatViewModel, selectedConversationId: conversationId)
            case .memories:
                AssistantMemoriesView(userId: AuthService.shared.user?.id ?? "local-device")
            case .proactive:
                AssistantProactiveView(userId: AuthService.shared.user?.id ?? "local-device")
            case .subscription:
                AssistantSubscriptionView()
            case .settings:
                AssistantSettingsSheet()
            case .tools:
                MacToolsView()
            case .fortune:
                AssistantTasksView(userId: AuthService.shared.user?.id ?? "local-device")
            case .analyze:
                AnalyzeView()
            case .quote:
                QuoteView()
            case .roast:
                RoastView()
            case .nickname:
                NicknameView()
            case .rate:
                RateView()
            case .decision:
                DecisionView()
            case .morningReport:
                MorningReportView()
            case .eveningReport:
                EveningReportView()
            case .favorites:
                LocalQuoteFavoritesView()
            case .history:
                MacHistoryView(chatViewModel: chatViewModel)
            case .profile:
                MacProfileView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview
#Preview {
    MacContentView()
        .environmentObject(AppState())
        .frame(width: 1000, height: 700)
}
#endif
