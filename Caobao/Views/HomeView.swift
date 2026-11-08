import SwiftUI

// Presentation adapters keep known app-localized error semantics while the
// standalone localization helper rejects unknown OS/provider descriptions.
extension AssistantTransportError: AssistantLocalizedNetworkFailure {}
extension AssistantConnectionProbeError: AssistantLocalizedNetworkFailure {}
extension AssistantTaskToolError: AssistantLocalizedNetworkFailure {}

@MainActor
struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var chat = ChatViewModel.shared
    @ObservedObject private var proactiveStore = AssistantProactiveStore.shared
    @ObservedObject private var proactiveInboxStore = AssistantProactiveInboxStore.shared
    @State private var tasks: [AssistantTask] = []
    @State private var cloudTaskSummary: [AssistantTask] = []
    @State private var proactiveRules: [CloudProactiveRule] = []
    @State private var proactiveRuns: [CloudProactiveRun] = []
    private struct ProactiveSummaryLoadState: Equatable {
        let ownerId: String
        let error: String?
    }
    @State private var proactiveSummaryLoadState: ProactiveSummaryLoadState?
    @State private var recentReloadId = UUID()
    @State private var navigationEpoch = UUID()
    @State private var navigationRun: UUID?
    @State private var navigationTask: Task<Void, Never>?
    @State private var preparationError: String?
    private var owner: String { auth.user?.id ?? "local-device" }
    private var currentTasks: [AssistantTask] {
        var seen = Set<String>()
        return (tasks + cloudTaskSummary).filter {
            AssistantOwnerIdentity.matches($0.userId, owner) && $0.status == .active && seen.insert($0.id).inserted
        }
    }
    private var canNavigate: Bool {
        AssistantOwnerIdentity.matches(owner, chat.activeOwner) && chat.archiveIsReady && !chat.archiveIsLoading && !chat.isArchiveBusy && navigationRun == nil
    }
    private var canCreateConversation: Bool {
        AssistantOwnerIdentity.matches(owner, chat.activeOwner) && (chat.archiveIsReady || chat.archiveRequiresRecovery)
            && !chat.archiveIsLoading && !chat.isArchiveBusy && navigationRun == nil
    }

    var body: some View {
        let displayedOwner = chat.activeOwner
        let loadIdentity = HomeConversationLoad(ownerId: owner, reloadId: recentReloadId)
        return NavigationStack(path: $appState.assistantHomePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    proactiveCard
                    if chat.archiveIsLoading { ProgressView("正在准备本地对话…") }
                    if let error = preparationError ?? chat.archiveOperationError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: error).font(.caption).foregroundStyle(.red)
                            if chat.archiveRequiresRecovery {
                                Button("重试清理并新建") { beginNavigation(ownerId: displayedOwner) }
                                    .frame(minHeight: 44).disabled(!canCreateConversation)
                            } else { Button("重试读取会话") { recentReloadId = UUID() }.frame(minHeight: 44) }
                        }.caobaoCard()
                    }
                    if let syncError = chat.memorySyncError {
                        Text("记忆同步暂未完成：\(syncError)")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    sectionHeader(title: "今天要处理", actionTitle: "查看全部") { appState.selectedTab = .fortune }
                    if currentTasks.isEmpty {
                        Button { appState.selectedTab = .fortune } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.caobaoPrimary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("添加第一项任务").font(.subheadline.weight(.semibold))
                                    Text("把想做的事交给我，随时可以继续")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .caobaoCard(padding: 14, cornerRadius: 18, hasShadow: false)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(currentTasks.prefix(3)) { task in
                                Label(task.title, systemImage: "circle").font(.subheadline)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .caobaoCard(padding: 14, cornerRadius: 18, hasShadow: false)
                    }
                    welcomeCard
                    Text("快速开始").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        quickAction("制定计划", icon: "checklist", prompt: "帮我制定今天的计划")
                        quickAction("总结内容", icon: "doc.text.magnifyingglass", prompt: "帮我总结这段内容")
                        quickAction("整理思路", icon: "lightbulb", prompt: "帮我整理一下思路")
                        Button { appState.selectedTab = .fortune } label: {
                            actionTile(title: "添加待办", subtitle: "记录并提醒", icon: "plus.circle.fill", tint: .orange)
                        }
                        .buttonStyle(.plain)
                    }
                    if AssistantOwnerIdentity.matches(chat.activeOwner, owner), !chat.conversations.isEmpty {
                        sectionHeader(title: "最近对话", actionTitle: "全部历史") { appState.assistantHomePath.append(.history) }
                        ForEach(chat.conversations.prefix(3)) { conversation in
                            Button {
                                beginNavigation(ownerId: displayedOwner, conversationId: conversation.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(conversation.title).font(.subheadline.bold()).lineLimit(1)
                                    Text(conversation.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    if conversation.messageCount == 0 { Text("尚无已发送消息").font(.caption2).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.buttonStyle(.plain).caobaoCard().disabled(!canNavigate)
                        }
                    }
                    // Keep the home feed focused on the work the user can do
                    // now. Quota and secondary tools stay available below the
                    // primary start-conversation and template actions.
                    quotaCard
                    sectionHeader(title: "继续使用")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        NavigationLink(value: AssistantHomeRoute.memories) {
                            actionTile(title: "我的记忆", subtitle: "查看与管理", icon: "brain.head.profile", tint: .purple)
                        }
                        NavigationLink(value: AssistantHomeRoute.tools) {
                            actionTile(title: "更多工具", subtitle: "探索能力", icon: "square.grid.2x2.fill", tint: .blue)
                        }
                    }
                    NavigationLink(value: AssistantHomeRoute.dataManagement) {
                        Label("数据与隐私", systemImage: "externaldrive")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            .background(Color.caobaoGroupedBackground)
            .assistantNavigationTitle("今日助理")
            .assistantSidebarRoot(isAtRoot: appState.assistantHomePath.isEmpty)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { appState.isShowingAssistantSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("助理设置")
                }
            }
            .navigationDestination(for: AssistantHomeRoute.self) { route in
                switch route {
                case .memories: AssistantMemoriesView(userId: owner)
                case .history: HistoryView(embeddedInHome: true)
                case .historyConversation(let id, let ownerId):
                    ConversationDetailView(conversationId: id, ownerId: ownerId)
                case .tools: FeaturesView()
                case .proactive: AssistantProactiveView(userId: owner)
                case .subscription: SubscriptionView()
                case .dataManagement: AssistantDataManagementView(ownerId: owner)
                }
            }
            .task(id: loadIdentity) {
                guard !Task.isCancelled, AssistantOwnerIdentity.matches(loadIdentity.ownerId, owner), loadIdentity.reloadId == recentReloadId else { return }
                let sourceOwner = loadIdentity.ownerId
                let epoch = navigationEpoch
                preparationError = nil
                tasks = AssistantLocalRepository.shared.tasks(for: sourceOwner).filter { $0.status == .active }
                cloudTaskSummary = []
                chat.activateOwner()
                do {
                    try await chat.waitForArchiveReady(ownerId: sourceOwner)
                    guard !Task.isCancelled, AssistantOwnerIdentity.matches(owner, sourceOwner), navigationEpoch == epoch, loadIdentity.reloadId == recentReloadId else { return }
                    await chat.syncFromCloud()
                    guard !Task.isCancelled, AssistantOwnerIdentity.matches(owner, sourceOwner), navigationEpoch == epoch, loadIdentity.reloadId == recentReloadId else { return }
                    await loadCloudTaskSummary(ownerId: sourceOwner)
                    guard !Task.isCancelled, AssistantOwnerIdentity.matches(owner, sourceOwner), navigationEpoch == epoch, loadIdentity.reloadId == recentReloadId else { return }
                    await appState.refreshAssistantState()
                    await loadProactiveSummary(ownerId: sourceOwner)
                } catch {
                    guard !Task.isCancelled, AssistantOwnerIdentity.matches(owner, sourceOwner), navigationEpoch == epoch, loadIdentity.reloadId == recentReloadId else { return }
                    preparationError = error.localizedDescription
                }
            }
            .onAppear {
                tasks = AssistantLocalRepository.shared.tasks(for: owner).filter { $0.status == .active }
            }
            .onChange(of: AssistantOwnerIdentity.ownerKey(owner)) { _ in resetNavigation() }
            .onChange(of: scenePhase) { phase in
                guard phase == .active, !chat.isSyncing else { return }
                Task { @MainActor in
                    await chat.syncFromCloud()
                    await loadCloudTaskSummary(ownerId: owner)
                    await loadProactiveSummary(ownerId: owner)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .loginSuccess)) { _ in resetNavigation() }
            .onReceive(NotificationCenter.default.publisher(for: .logoutSuccess)) { _ in resetNavigation() }
            .onDisappear { resetNavigation(reload: false) }
            .refreshable {
                recentReloadId = UUID()
                await chat.syncFromCloud()
                await loadCloudTaskSummary(ownerId: owner)
                await appState.refreshAssistantState(force: true)
            }
        }
    }

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("草包")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Text("少点空话，把事情做好。")
                        .font(.title3.weight(.semibold))
                    Text("规划、总结、记忆与任务，都可以从这里开始。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.caobaoPrimary)
                    .padding(12)
                    .background(.caobaoPrimary.opacity(0.12), in: Circle())
            }
            Button {
                let displayedOwner = chat.activeOwner
                beginNavigation(ownerId: displayedOwner)
            } label: {
                HStack {
                    Image(systemName: "message.fill")
                    Text("开始一段对话").fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(.white)
                .background(LinearGradient.caobaoPrimary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canCreateConversation)
            .opacity(canCreateConversation ? 1 : 0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            LinearGradient(
                colors: [.caobaoPrimary.opacity(0.16), .caobaoAccent.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.caobaoPrimary.opacity(0.12), lineWidth: 1)
        }
    }

    private func sectionHeader(title: LocalizedStringKey, actionTitle: LocalizedStringKey? = nil, action: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.caobaoPrimary)
            }
        }
    }

    private func actionTile(title: LocalizedStringKey, subtitle: LocalizedStringKey, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title).font(.subheadline.weight(.semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .caobaoCard(padding: 14, cornerRadius: 18, hasShadow: false)
    }

    private var quotaCard: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in quotaContents }
    }

    private var quotaContents: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("助理额度", systemImage: "bolt.fill").font(.headline)
                Spacer()
                NavigationLink("订阅", value: AssistantHomeRoute.subscription)
            }
            if appState.assistantMode == "byok" {
                Text("自定义 API 不消耗平台次数").font(.subheadline)
            } else if let remaining = appState.dailyQuotaRemaining, !appState.isQuotaStale {
                Text("剩余 \(remaining) / 8 次").font(.title3.bold())
            } else {
                Text("额度尚未验证").font(.title3.bold())
            }
            if appState.assistantMode == "platform",
               let balance = appState.subscriptionBalance, !appState.isSubscriptionQuotaStale {
                VStack(alignment: .leading, spacing: 4) {
                    Text("订阅周期额度").font(.subheadline.bold())
                    Text("剩余 \(balance.remaining) / \(balance.included) 次").font(.subheadline)
                    (Text("本周期截止：") + Text(balance.periodEndsAt, style: .date))
                        .font(.caption).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
            }
            (Text("区域：") + Text(LocalizedStringKey(appState.serviceRegionLabel)) + Text(" · ")
                + Text("模式：") + Text(LocalizedStringKey(appState.assistantModeLabel)))
                .font(.caption).foregroundStyle(.secondary)
            (Text("模型：") + Text(appState.currentModelLabel))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let message = appState.quotaStatusMessage {
                Text(LocalizedStringKey(message)).font(.caption).foregroundStyle(.secondary)
            }
            if appState.isRefreshingEntitlements { ProgressView() }
            else {
                Button("刷新权益") { Task { await appState.refreshAssistantState(force: true) } }
                    .font(.caption).frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .caobaoCard()
    }

    private var proactiveCard: some View {
        let profile = proactiveStore.profile(for: owner)
        let unread = proactiveInboxStore.unreadCount(ownerId: owner, runs: proactiveRuns)
        let nextRun = proactiveRules.compactMap { AssistantProactiveDate.parse($0.nextRunAt) }.min()
        let summaryError = proactiveSummaryLoadState.flatMap {
            AssistantOwnerIdentity.matches($0.ownerId, owner) ? $0.error : nil
        }
        let summaryReady = proactiveSummaryLoadState.map {
            AssistantOwnerIdentity.matches($0.ownerId, owner)
        } ?? false
        return NavigationLink(value: AssistantHomeRoute.proactive) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: profile.enabled ? "bell.badge.fill" : "bell.slash")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(profile.enabled ? Color.caobaoPrimary : .secondary)
                    .frame(width: 38, height: 38)
                    .background((profile.enabled ? Color.caobaoPrimary : Color.secondary).opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("主动更新").font(.headline)
                        Spacer()
                        Text(profile.enabled ? profile.mode.title : "未开启")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(profile.enabled ? Color.caobaoPrimary : .secondary)
                    }
                    Text(profile.enabled ? "按你的规则提醒、跟进和生成更新" : "开启后，草包会按你的规则主动提醒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let summaryError {
                        Label {
                            Text(LocalizedStringKey(summaryError))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        Text("进入主动规则管理重试")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else if auth.isLoggedIn && !summaryReady {
                        Label("正在读取主动更新…", systemImage: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        HStack(spacing: 10) {
                            if unread > 0 {
                                Label("未读 \(unread)", systemImage: "bell.badge")
                                    .foregroundStyle(Color.caobaoPrimary)
                            } else {
                                Label("暂无未读", systemImage: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            if let nextRun {
                                Text("下次：\(nextRun.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    Text("消息来源、安静时段和频率都由你控制")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .caobaoCard(padding: 14, cornerRadius: 18, hasShadow: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("主动更新")
        .accessibilityValue(summaryError.map { Text(LocalizedStringKey($0)) }
            ?? (auth.isLoggedIn && !summaryReady
                ? Text("正在读取主动更新…")
                : (profile.enabled
                   ? Text(profile.mode.title) + Text(verbatim: "，未读 \(unread)")
                   : Text("未开启"))))
    }

    private func loadProactiveSummary(ownerId: String) async {
        guard AuthService.shared.isLoggedIn,
              AssistantOwnerIdentity.matches(ownerId, auth.user?.id ?? "local-device"),
              !Task.isCancelled else { return }
        proactiveSummaryLoadState = ProactiveSummaryLoadState(ownerId: ownerId, error: nil)
        do {
            let token = try await AuthService.shared.validAccessToken()
            async let ruleResponse = APIService.shared.listProactiveRules(token: token, limit: 100)
            async let runResponse = APIService.shared.listProactiveRuns(token: token, limit: 20)
            let (rules, runs) = try await (ruleResponse.items, runResponse.items)
            guard !Task.isCancelled,
                  AssistantOwnerIdentity.matches(ownerId, owner),
                  AssistantOwnerIdentity.matches(ownerId, auth.user?.id ?? "local-device") else { return }
            proactiveRules = rules
            proactiveRuns = runs
            proactiveSummaryLoadState = ProactiveSummaryLoadState(ownerId: ownerId, error: nil)
        } catch is CancellationError {
            return
        } catch {
            guard AssistantOwnerIdentity.matches(ownerId, auth.user?.id ?? "local-device") else { return }
            // Preserve the last owner-scoped snapshot, but never present it as
            // a fresh zero count when the summary request failed.
            proactiveSummaryLoadState = ProactiveSummaryLoadState(ownerId: ownerId, error: "暂时无法读取主动更新")
        }
    }

    /// Home only needs a read-only summary. Full task change-feed, version,
    /// tombstone, and approval handling remains in AssistantTasksView.
    private func loadCloudTaskSummary(ownerId: String) async {
        guard AuthService.shared.isLoggedIn,
              AssistantOwnerIdentity.matches(ownerId, auth.user?.id ?? "local-device"),
              !Task.isCancelled else { return }
        do {
            let token = try await AuthService.shared.validAccessToken()
            let response = try await APIService.shared.listCloudTasks(token: token, limit: 200)
            guard !Task.isCancelled,
                  AssistantOwnerIdentity.matches(ownerId, owner),
                  AssistantOwnerIdentity.matches(ownerId, auth.user?.id ?? "local-device") else { return }
            let summary = response.items.compactMap { cloudTask in
                homeTask(from: cloudTask, ownerId: ownerId)
            }
            cloudTaskSummary = summary
        } catch is CancellationError {
            return
        } catch {
            // A summary failure must never clear local tasks or show a false
            // empty state. The task page remains the authoritative retry path.
        }
    }

    private func homeTask(from remote: CloudTask, ownerId: String) -> AssistantTask? {
        guard !remote.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !remote.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let zone = try? AssistantTaskTimeZonePolicy.validatedIdentifier(remote.timeZone) else { return nil }
        let status = AssistantCloudTaskStatusPolicy.localStatus(for: remote.status)
        let created = homeCloudDate(remote.createdAt) ?? Date()
        return AssistantTask(id: remote.id, userId: ownerId, title: remote.title,
            instructions: remote.instructions, dueAt: homeCloudDate(remote.dueAt), timeZone: zone,
            recurrenceRule: remote.recurrenceRule, requiresApproval: remote.requiresApproval,
            status: status, createdAt: created,
            updatedAt: homeCloudDate(remote.updatedAt) ?? created, reminderEnabled: false)
    }

    private func homeCloudDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func quickAction(_ title: LocalizedStringKey, icon: String, prompt: String) -> some View {
        let displayedOwner = chat.activeOwner
        return Button {
            let preferred = appState.assistantLanguage == "system" ? Locale.preferredLanguages.first ?? "en" : appState.assistantLanguage
            let resource = preferred.hasPrefix("zh") ? "zh-Hans" : "en"
            let bundle = Bundle.main.path(forResource: resource, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
            let initialText = bundle.localizedString(forKey: prompt, value: prompt, table: nil)
            beginNavigation(ownerId: displayedOwner, initialText: initialText)
        } label: {
            actionTile(title: title, subtitle: "点击开始", icon: icon, tint: .caobaoPrimary)
        }
        .buttonStyle(.plain)
        .disabled(!canCreateConversation)
        .opacity(canCreateConversation ? 1 : 0.55)
    }

    private func beginNavigation(ownerId: String, conversationId: String? = nil, initialText: String = "") {
        guard conversationId == nil ? canCreateConversation : canNavigate else { return }
        let run = UUID(), epoch = navigationEpoch
        navigationRun = run
        navigationTask = Task {
            defer { if navigationRun == run { navigationRun = nil; navigationTask = nil } }
            guard !Task.isCancelled, navigationRun == run, navigationEpoch == epoch,
                  AssistantOwnerIdentity.matches(owner, ownerId), AssistantOwnerIdentity.matches(chat.activeOwner, ownerId) else { return }
            let succeeded: Bool
            if let conversationId { succeeded = await chat.requestOpenConversation(id: conversationId, ownerId: ownerId) }
            else { succeeded = await chat.requestNewConversation(ownerId: ownerId, initialText: initialText) }
            guard succeeded, !Task.isCancelled, navigationRun == run, navigationEpoch == epoch,
                  AssistantOwnerIdentity.matches(owner, ownerId), AssistantOwnerIdentity.matches(chat.activeOwner, ownerId) else { return }
            AssistantConversationNavigation.activateChat(appState: appState, ownerId: ownerId)
        }
    }
    private func resetNavigation(reload: Bool = true) {
        navigationTask?.cancel(); navigationTask = nil; navigationRun = nil; navigationEpoch = UUID()
        preparationError = nil
        if reload {
            proactiveRules = []
            proactiveRuns = []
            proactiveSummaryLoadState = nil
            recentReloadId = UUID()
        }
    }
}

private struct HomeConversationLoad: Hashable {
    let ownerId: String
    let ownerIdentityKey: String
    let reloadId: UUID
    init(ownerId: String, reloadId: UUID) {
        self.ownerId = ownerId; ownerIdentityKey = AssistantOwnerIdentity.ownerKey(ownerId); self.reloadId = reloadId
    }
}

@MainActor
struct AssistantSettingsSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = AuthService.shared
    @State private var baseURL = ""
    @State private var protocolKind = AssistantWireProtocol.chatCompletions
    @State private var model = ""
    @State private var apiKey = ""
    @State private var language = "system"
    @State private var mode = "platform"
    @State private var persona = "normal"
    @State private var region = ""
    @State private var platformModel = ""
    @State private var probeTask: Task<Void, Never>?
    @State private var probeRunId: UUID?
    @State private var probeStatus: String?
    @State private var showProbeConfirmation = false
    @State private var taskToolsEnabled = false
    @State private var verifiedToolFingerprint: String?
    @State private var toolProbeTask: Task<Void, Never>?
    @State private var toolProbeRunId: UUID?
    @State private var toolProbeStatus: String?
    @State private var showToolProbeConfirmation = false
    @State private var settingsEpoch = UUID()
    @State private var observedToolConnection: ToolConnectionIdentity?
    @State private var observedToolMode: String?
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var loadedOwnerId: String?
    private var owner: String { auth.user?.id ?? "local-device" }
    private var prefix: String { "assistant.byok.\(owner)." }
    private var languageKey: String { "caobao.assistant.\(Data(owner.utf8).base64EncodedString()).language" }
    private struct ToolConnectionIdentity: Equatable, Sendable {
        let baseURL: String
        let protocolKind: AssistantWireProtocol
        let model: String
        let apiKey: String
    }
    private struct ToolProbeSource: Sendable {
        let ownerId: String
        let epoch: UUID
        let runId: UUID
        let connection: ToolConnectionIdentity
        let fingerprint: String
    }
    private var toolConnection: ToolConnectionIdentity {
        .init(baseURL: baseURL, protocolKind: protocolKind, model: model, apiKey: apiKey)
    }
    private var toolConfiguration: BYOKConfiguration {
        .init(baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), protocolKind: protocolKind,
              model: model.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: apiKey)
    }
    private var toolFingerprint: String? { try? toolConfiguration.consentIdentifier() }
    private var hasCurrentToolProof: Bool {
        guard let verifiedToolFingerprint else { return false }
        return AssistantOwnerIdentity.matches(loadedOwnerId, owner) && toolFingerprint == verifiedToolFingerprint
    }

    var body: some View {
        NavigationStack { settingsConfirmations }
    }

    private var settingsForm: some View {
        Group {
            if AssistantOwnerIdentity.matches(loadedOwnerId, owner) {
                Form {
                    basicSettingsSections
                    if mode == "byok" { byokConfigurationSection }
                    else { platformModelSection }
                    if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red).font(.caption) } }
                }
            } else if let errorMessage { Text(verbatim: errorMessage).padding() }
            else { ProgressView() }
        }
        .disabled(isSaving || !AssistantOwnerIdentity.matches(loadedOwnerId, owner))
    }

    private var settingsNavigation: some View {
        settingsForm
            .assistantNavigationTitle("助理设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(isSaving || probeTask != nil || toolProbeTask != nil || !AssistantOwnerIdentity.matches(loadedOwnerId, owner))
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { cancelProbe(); cancelToolProbe(); settingsEpoch = UUID(); dismiss() }.disabled(isSaving)
                }
            }
    }

    private var settingsConnectionObservers: some View {
        settingsNavigation
            .onAppear(perform: loadSettings)
            .task(id: mode + "." + region + "." + AssistantOwnerIdentity.ownerKey(owner)) {
                if mode == "platform" { await appState.refreshModelCatalog(region: region) }
            }
            .onChange(of: region) { (value: String) in platformModel = appState.savedPlatformModel(for: value) }
            .onChange(of: toolConnection) { (value: ToolConnectionIdentity) in
                guard observedToolConnection != value else { return }
                observedToolConnection = value; invalidateProbe(); invalidateToolVerification()
            }
            .onChange(of: mode) { (value: String) in
                guard observedToolMode != value else { return }
                observedToolMode = value; invalidateProbe(); invalidateToolVerification()
            }
    }

    private var settingsLifecycle: some View {
        settingsConnectionObservers
            .onChange(of: AssistantOwnerIdentity.ownerKey(owner)) { _ in invalidateSettingsIdentity() }
            .onReceive(NotificationCenter.default.publisher(for: .loginSuccess)) { _ in invalidateSettingsIdentity() }
            .onReceive(NotificationCenter.default.publisher(for: .logoutSuccess)) { _ in invalidateSettingsIdentity() }
            .onDisappear { cancelProbe(); cancelToolProbe(); settingsEpoch = UUID() }
            .interactiveDismissDisabled(isSaving || probeTask != nil || toolProbeTask != nil)
    }

    private var settingsConfirmations: some View {
        settingsLifecycle
            .alert("测试自定义 API 连接？", isPresented: $showProbeConfirmation) {
                Button("取消", role: .cancel) { }
                Button("继续测试") { startProbe() }
            } message: {
                Text("将使用填写的 API Key 向 \(probeDestination) 发送固定测试消息，服务商可能收费。不会发送会话历史、记忆或任务，也不会扣除 CaoBao 平台次数。")
            }
            .confirmationDialog("验证待办工具能力？", isPresented: $showToolProbeConfirmation, titleVisibility: .visible) {
                Button("取消", role: .cancel) { }
                Button("继续验证") { startToolProbe() }
            } message: {
                Text("将使用填写的 API Key 向当前自定义服务发送固定的 caobao_task_probe 测试，服务商可能收费。不会发送历史、记忆或任务，也不会创建待办或申请通知权限。")
            }
    }

    private func loadSettings() {
        guard !AssistantOwnerIdentity.matches(loadedOwnerId, owner) else { return }
        loadedOwnerId = owner
        let defaults = UserDefaults.standard
        mode = appState.assistantMode
        persona = appState.userSettings.toxicLevel
        region = appState.serviceRegion
        platformModel = appState.savedPlatformModel(for: region)
        baseURL = defaults.string(forKey: prefix + "url") ?? ""
        model = defaults.string(forKey: prefix + "model") ?? ""
        protocolKind = AssistantWireProtocol(rawValue: defaults.string(forKey: prefix + "protocol") ?? "") ?? .chatCompletions
        apiKey = KeychainStore.read(account: "byok-api-key.\(owner)") ?? ""
        language = defaults.string(forKey: languageKey) ?? "system"
        observedToolConnection = toolConnection; observedToolMode = mode
        let fingerprint = toolFingerprint
        verifiedToolFingerprint = AssistantTaskToolPreferences.verifiedFingerprint(defaults: defaults, ownerId: owner)
        taskToolsEnabled = fingerprint.map { AssistantTaskToolPreferences.isEnabled(defaults: defaults, ownerId: owner, configurationFingerprint: $0) } ?? false
        if verifiedToolFingerprint != fingerprint { verifiedToolFingerprint = nil; taskToolsEnabled = false }
    }

    @ViewBuilder
    private var basicSettingsSections: some View {
        Section("语言") {
            Picker("助理语言", selection: $language) {
                Text("跟随系统").tag("system")
                Text("简体中文").tag("zh-Hans")
                Text("English").tag("en")
            }
        }
        Section("表达风格") {
            Picker("草包风格", selection: $persona) {
                Text("温和").tag("gentle")
                Text("标准").tag("normal")
                Text("犀利").tag("sharp")
            }
        }
        Section("服务区域") {
            Picker("默认模型区域", selection: $region) {
                Text("未选择").tag("")
                Text("中国大陆模型").tag("CN")
                Text("海外模型").tag("INTL")
            }
            Text("App Store 地区仅提供默认建议。保存后以你的选择为准。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("语音与隐私") {
            Text("语音识别优先在设备上进行；当前语言不支持离线识别时，可能由 Apple 处理。只有点击麦克风后才开始。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("通知与提醒") {
            NavigationLink("主动更新") { AssistantProactiveView(userId: owner) }
            NavigationLink("安静时段") { AssistantQuietHoursSettingsView(ownerId: owner) }
                .disabled(isSaving || probeTask != nil)
        }
        Section("角色") {
            NavigationLink("自定义角色") {
                AssistantCharactersView(ownerId: owner)
            }
            Text("角色提示词和记忆范围按账号隔离；删除会保留服务端墓碑，避免其他设备复活。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("接入方式") {
            Picker("当前模式", selection: $mode) {
                Text("CaoBao 平台").tag("platform")
                Text("自定义 API（BYOK）").tag("byok")
            }
            Text("平台使用新版助理接口；服务未开通时会显示错误，不自动调用旧接口。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("数据管理") {
            NavigationLink("数据与隐私") { AssistantDataManagementView(ownerId: owner) }
                .disabled(isSaving || probeTask != nil)
        }
    }

    private var byokConfigurationSection: some View {
        Section("自定义 API") {
            Picker("协议", selection: $protocolKind) {
                Text("OpenAI Chat Completions").tag(AssistantWireProtocol.chatCompletions)
                Text("OpenAI Responses").tag(AssistantWireProtocol.responses)
                Text("Anthropic Messages").tag(AssistantWireProtocol.anthropic)
            }
            TextField("Base URL（HTTPS）", text: $baseURL)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            TextField("模型名称", text: $model)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            SecureField("API Key（仅存 Keychain）", text: $apiKey)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            Text("会话历史与相关记忆可能发送到此地址。首次发送前需要确认。不会自动切回平台。")
                .font(.caption).foregroundStyle(.secondary)
            Button("清除 API Key", role: .destructive) {
                KeychainStore.delete(account: "byok-api-key.\(owner)"); apiKey = ""
                NotificationCenter.default.post(name: Notification.Name("assistant.generationConfigurationChanged"), object: owner)
            }
            connectionTestControls
            taskToolControls
        }
    }

    @ViewBuilder
    private var connectionTestControls: some View {
        if probeTask != nil {
            HStack {
                ProgressView()
                Text("正在测试连接…")
                Spacer()
                Button("停止") { cancelProbe() }
            }
        } else {
            Button("测试连接") { showProbeConfirmation = true }
                .disabled(baseURL.isEmpty || model.isEmpty || apiKey.isEmpty || isSaving || toolProbeTask != nil)
        }
        if let probeStatus { Text(probeStatus).font(.caption).textSelection(.enabled) }
        Text("连接测试可能产生 API 费用，只发送固定测试消息，不包含历史、记忆或任务。")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var taskToolControls: some View {
        Toggle("启用 AI 待办建议", isOn: $taskToolsEnabled)
            .disabled(!hasCurrentToolProof || toolProbeTask != nil || probeTask != nil || isSaving)
        Text("工具默认关闭。请先验证当前 API 的工具能力，再明确启用并保存；每条待办仍需你确认。")
            .font(.caption).foregroundStyle(.secondary)
        if toolProbeTask != nil {
            HStack {
                ProgressView(); Text("正在验证待办工具…"); Spacer()
                Button("停止") { cancelToolProbe() }
            }
        } else {
            Button("验证待办工具") { showToolProbeConfirmation = true }
                .disabled(baseURL.isEmpty || model.isEmpty || apiKey.isEmpty || probeTask != nil || isSaving)
        }
        if let toolProbeStatus { Text(verbatim: toolProbeStatus).font(.caption) }
        else if hasCurrentToolProof { Text("当前配置的待办工具能力已验证。").font(.caption).foregroundStyle(.secondary) }
        else { Text("尚未验证当前配置的待办工具能力。").font(.caption).foregroundStyle(.secondary) }
        Text("修改地址、协议、模型或 API Key 后需重新验证。平台模式当前不启用工具执行。")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var platformModelSection: some View {
        Section("平台模型") {
            Picker("当前模型", selection: $platformModel) {
                Text("自动（区域默认）").tag("")
                ForEach(availableModels) { item in Text(item.displayName).tag(item.id) }
                if !platformModel.isEmpty, !availableModels.contains(where: { $0.id == platformModel }) {
                    Text(platformModel).tag(platformModel)
                }
            }
            if let selected = selectedModel {
                Label(LocalizedStringKey(selected.capabilities.vision ? "支持图片输入" : "仅文字输入"),
                      systemImage: selected.capabilities.vision ? "photo" : "text.bubble")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if appState.isRefreshingModels { ProgressView("正在读取模型列表…") }
            if let message = appState.modelCatalogStatusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if appState.modelCatalog?.serviceRegion == region, availableModels.isEmpty {
                Text("当前账号暂无可用的平台模型").font(.caption).foregroundStyle(.secondary)
            }
            Button("刷新模型列表") { Task { await appState.refreshModelCatalog(region: region, force: true) } }
                .disabled(appState.isRefreshingModels || !["CN", "INTL"].contains(region))
            Text("模型列表由当前账号和服务区域决定。自动模式使用该区域的默认模型，不会静默切换到自定义 API。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var availableModels: [AssistantModelDescriptor] {
        guard !appState.isModelCatalogStale, appState.modelCatalog?.serviceRegion == region else { return [] }
        return appState.modelCatalog?.models.filter { $0.capabilities.streaming } ?? []
    }

    private var probeDestination: String {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host
            ?? AssistantLocalization.string("配置的服务")
    }

    private var selectedModel: AssistantModelDescriptor? {
        let id = platformModel.isEmpty ? appState.modelCatalog?.defaultModelId : platformModel
        return availableModels.first { $0.id == id }
    }

    private func cancelProbe() {
        probeRunId = nil; probeTask?.cancel(); probeTask = nil
    }

    private func invalidateProbe() { cancelProbe(); probeStatus = nil }

    private func cancelToolProbe() {
        toolProbeRunId = nil; toolProbeTask?.cancel(); toolProbeTask = nil
    }
    private func invalidateToolVerification() {
        cancelToolProbe(); verifiedToolFingerprint = nil; taskToolsEnabled = false
        toolProbeStatus = nil; showToolProbeConfirmation = false
    }
    private func invalidateSettingsIdentity() {
        settingsEpoch = UUID(); cancelProbe(); invalidateToolVerification()
        loadedOwnerId = nil; observedToolConnection = nil; observedToolMode = nil
        showProbeConfirmation = false
        apiKey = ""; baseURL = ""; model = ""
        errorMessage = AssistantLocalization.string("账号已变化，请关闭并重新打开设置。")
    }
    private func validateToolProbe(_ source: ToolProbeSource) throws {
        try Task.checkCancellation()
        guard AssistantOwnerIdentity.matches(owner, source.ownerId), AssistantOwnerIdentity.matches(loadedOwnerId, source.ownerId), settingsEpoch == source.epoch,
              toolProbeRunId == source.runId, mode == "byok", toolConnection == source.connection,
              toolFingerprint == source.fingerprint else { throw CancellationError() }
    }
    private func startToolProbe() {
        guard AssistantOwnerIdentity.matches(loadedOwnerId, owner), mode == "byok", !isSaving, probeTask == nil else { return }
        invalidateToolVerification()
        do {
            let configuration = toolConfiguration, fingerprint = try configuration.consentIdentifier()
            let source = ToolProbeSource(ownerId: owner, epoch: settingsEpoch, runId: UUID(), connection: toolConnection, fingerprint: fingerprint)
            toolProbeRunId = source.runId
            toolProbeTask = Task { @MainActor in
                defer { if toolProbeRunId == source.runId { toolProbeRunId = nil; toolProbeTask = nil } }
                do {
                    let proof = try await AssistantTaskToolCapabilityProbe().check(configuration: configuration,
                        beforeStart: { try validateToolProbe(source) }, beforeStartWait: { try validateToolProbe(source) })
                    try validateToolProbe(source)
                    guard proof == source.fingerprint else { throw AssistantTaskToolError.capabilityRequired }
                    verifiedToolFingerprint = proof
                    toolProbeStatus = AssistantLocalization.string("待办工具验证通过；请明确启用并保存设置。")
                } catch {
                    guard !Task.isCancelled, toolProbeRunId == source.runId, AssistantOwnerIdentity.matches(owner, source.ownerId), settingsEpoch == source.epoch else { return }
                    verifiedToolFingerprint = nil; taskToolsEnabled = false; toolProbeStatus = AssistantLocalization.networkErrorDescription(error)
                }
            }
        } catch { toolProbeStatus = AssistantLocalization.networkErrorDescription(error) }
    }

    private func startProbe() {
        cancelProbe()
        let runId = UUID(); probeRunId = runId
        let savedOwner = owner
        let configuration = BYOKConfiguration(baseURL: baseURL, protocolKind: protocolKind, model: model, apiKey: apiKey)
        probeStatus = nil
        probeTask = Task { @MainActor in
            do {
                let result = try await AssistantConnectionProbe().check(configuration: configuration)
                guard !Task.isCancelled, probeRunId == runId, AssistantOwnerIdentity.matches(owner, savedOwner) else { return }
                probeStatus = String(format: AssistantLocalization.string("连接成功（%.1f 秒），仅验证文字响应。"), result.elapsedSeconds)
            } catch {
                guard !Task.isCancelled, probeRunId == runId, AssistantOwnerIdentity.matches(owner, savedOwner) else { return }
                probeStatus = AssistantLocalization.networkErrorDescription(error)
            }
            guard probeRunId == runId else { return }
            probeRunId = nil; probeTask = nil
        }
    }

    @MainActor private func save() async {
        let savedOwner = owner
        guard AssistantOwnerIdentity.matches(loadedOwnerId, savedOwner) else { return }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            if mode == "platform", !["CN", "INTL"].contains(region) {
                throw AssistantTransportError.configuration(AssistantLocalization.string("请先确认服务区域"))
            }
            if mode == "platform", !platformModel.isEmpty,
               !availableModels.contains(where: { $0.id == platformModel }),
               platformModel != appState.savedPlatformModel(for: region) || (appState.modelCatalog?.serviceRegion == region && !appState.isModelCatalogStale) {
                throw AssistantTransportError.configuration(AssistantLocalization.string("所选模型当前不可用，请刷新列表或选择自动模式"))
            }
            let storedDefaults = UserDefaults.standard
            let verifiedProof = mode == "byok" && hasCurrentToolProof ? verifiedToolFingerprint : nil
            guard !taskToolsEnabled || (mode == "byok" && verifiedProof != nil) else { throw AssistantTaskToolError.capabilityRequired }
            let hasStoredConnection = !(storedDefaults.string(forKey: prefix + "url") ?? "").isEmpty
                || !(storedDefaults.string(forKey: prefix + "model") ?? "").isEmpty
            let connectionIsBlank = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && apiKey.isEmpty
            if mode == "byok", !connectionIsBlank || hasStoredConnection {
                let configuration = toolConfiguration
                _ = try configuration.endpoint()
                try KeychainStore.save(apiKey, account: "byok-api-key.\(savedOwner)")
                let defaults = UserDefaults.standard
                defaults.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: prefix + "url")
                defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: prefix + "model")
                defaults.set(protocolKind.rawValue, forKey: prefix + "protocol")
                NotificationCenter.default.post(name: Notification.Name("assistant.generationConfigurationChanged"), object: savedOwner)
            }
            try AssistantTaskToolPreferences.set(enabled: mode == "byok" && taskToolsEnabled, verifiedFingerprint: verifiedProof,
                defaults: storedDefaults, ownerId: savedOwner)
            UserDefaults.standard.set(language, forKey: languageKey)
            NotificationCenter.default.post(name: Notification.Name("assistant.generationConfigurationChanged"), object: savedOwner)
            appState.assistantLanguage = language
            appState.userSettings.toxicLevel = persona
            appState.serviceRegion = region
            if ["CN", "INTL"].contains(region) { try appState.savePlatformModel(platformModel, for: region) }
            appState.assistantMode = mode
            appState.regionConfirmed = ["CN", "INTL"].contains(region)
            appState.saveUserSettings(); appState.saveAssistantPreferences()
            if appState.assistantMode == "platform", AuthService.shared.isLoggedIn {
                let request = AssistantPreferencesRequest(locale: language == "system" ? Locale.preferredLanguages.first ?? "en" : language,
                    personaLevel: appState.userSettings.toxicLevel, serviceRegion: appState.serviceRegion,
                    regionConfirmed: appState.regionConfirmed, assistantMode: appState.assistantMode,
                    // The account timezone is established by identity/first-claim
                    // flows and is immutable afterwards. A settings save must
                    // never fail merely because the device moved to another zone.
                    timeZone: nil, proactiveLevel: appState.proactiveLevel)
                do {
                    let token = try await AuthService.shared.validAccessToken()
                    guard AssistantOwnerIdentity.matches(owner, savedOwner) else { return }
                    _ = try await APIService.shared.updateAssistantPreferences(token: token, request: request)
                }
                catch { errorMessage = AssistantLocalization.string("设置已保存在设备，服务器暂时无法同步。可稍后重试。"); return }
            }
            guard AssistantOwnerIdentity.matches(owner, savedOwner) else { return }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct SubscriptionView: View {
    @EnvironmentObject private var appState: AppState
    var body: some View {
        AssistantSubscriptionView {
            Task { await appState.refreshAssistantState(force: true) }
        }
    }
}
