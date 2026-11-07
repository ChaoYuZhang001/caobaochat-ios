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
                        Text(proactiveStore.profile(for: ownerId).enabled
                             ? "已开启 · \(proactiveStore.profile(for: ownerId).mode.rawValue)"
                             : "默认关闭，可在主动规则中开启")
                            .foregroundStyle(.secondary)
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

struct MacSubscriptionPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "creditcard").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("订阅").font(.title3.bold())
            Text("订阅状态将在账号服务可用后显示。").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .navigationTitle("订阅")
    }
}

struct MacProfilePlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("我的").font(.title3.bold())
            Text("账号、隐私和数据管理请从工作区设置进入。").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .navigationTitle("我的")
    }
}

struct MacHistoryPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("历史").font(.title3.bold())
            Text("最近对话已常驻左侧栏。").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .navigationTitle("历史")
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
                ForEach([MacFeature.memories, .proactive, .subscription, .settings]) { feature in
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
            
            Text(feature.rawValue)
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
    private let tools: [MacFeature] = [
        .analyze, .quote, .roast, .nickname, .rate, .decision,
        .morningReport, .eveningReport, .favorites
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("这些功能作为工具模板提供，不会打断首页、对话和任务工作流。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }

                Section("工具模板") {
                    ForEach(tools, id: \.self) { feature in
                        NavigationLink(value: feature) {
                            MacFeatureRow(feature: feature, isSelected: false)
                        }
                    }
                }
            }
            .navigationTitle("工具模板")
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
                MacSubscriptionPlaceholder()
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
                MacHistoryPlaceholder()
            case .profile:
                MacProfilePlaceholder()
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
