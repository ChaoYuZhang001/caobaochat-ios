import SwiftUI

enum AssistantProactiveMode: String, Codable, CaseIterable, Identifiable {
    case off
    case important
    case daily
    case normal
    case frequent

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .off: return "关闭"
        case .important: return "仅重要"
        case .daily: return "每日一次"
        case .normal: return "正常"
        case .frequent: return "频繁"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .off: return "不主动发送更新。"
        case .important: return "只发送你明确设置的任务和重要跟进。"
        case .daily: return "每天最多生成一次主动更新。"
        case .normal: return "按已启用规则正常运行。"
        case .frequent: return "允许更频繁的提醒，仍受每日上限约束。"
        }
    }
}

struct AssistantProactiveProfile: Codable, Equatable, Sendable {
    var enabled = false
    var mode: AssistantProactiveMode = .important
    var quietHours = AssistantQuietHours.disabled
    var dailyLimit = 3
    var companionEnabled = false

    static let `default` = AssistantProactiveProfile()
}

/// Owner-scoped local preferences for proactive updates. The server remains
/// authoritative for cloud rules and delivery; these preferences are safe to
/// edit offline and are intentionally stored separately from BYOK credentials.
@MainActor
final class AssistantProactiveStore: ObservableObject {
    static let shared = AssistantProactiveStore()

    @Published private(set) var revision: UInt = 0
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func profile(for ownerId: String) -> AssistantProactiveProfile {
        guard let data = defaults.data(forKey: key(for: ownerId)),
              let profile = try? decoder.decode(AssistantProactiveProfile.self, from: data),
              (0...30).contains(profile.dailyLimit),
              profile.quietHours.validatedOrDisabled != nil else {
            return .default
        }
        return profile
    }

    func hasProfile(for ownerId: String) -> Bool {
        defaults.data(forKey: key(for: ownerId)) != nil
    }

    @discardableResult
    func save(_ profile: AssistantProactiveProfile, for ownerId: String) -> Bool {
        guard !ownerId.isEmpty,
              (0...30).contains(profile.dailyLimit),
              profile.quietHours.validatedOrDisabled != nil,
              let data = try? encoder.encode(profile) else { return false }
        defaults.set(data, forKey: key(for: ownerId))
        revision &+= 1
        NotificationCenter.default.post(name: .assistantProactiveChanged, object: ownerId)
        return true
    }

    private func key(for ownerId: String) -> String {
        let encoded = Data(ownerId.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return "caobao.assistant.proactive.\(encoded)"
    }
}

private extension AssistantQuietHours {
    var validatedOrDisabled: AssistantQuietHours? {
        guard !enabled else { return try? validated() }
        return try? validated()
    }
}

/// Per-device presentation state for proactive runs. The server currently
/// exposes execution history but not a read/snooze cursor, so this store is
/// deliberately owner-scoped and never presented as cross-device state.
@MainActor
final class AssistantProactiveInboxStore: ObservableObject {
    static let shared = AssistantProactiveInboxStore()

    private struct State: Codable {
        var readRunIds: Set<String> = []
        var snoozedUntil: [String: Date] = [:]
    }

    @Published private(set) var revision: UInt = 0
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func unreadCount(ownerId: String, runs: [CloudProactiveRun], now: Date = Date()) -> Int {
        runs.filter { run in
            !isRead(ownerId: ownerId, runId: run.id) && !isSnoozed(ownerId: ownerId, runId: run.id, now: now)
        }.count
    }

    func isRead(ownerId: String, runId: String) -> Bool {
        state(for: ownerId).readRunIds.contains(runId)
    }

    func isSnoozed(ownerId: String, runId: String, now: Date = Date()) -> Bool {
        guard let until = state(for: ownerId).snoozedUntil[runId] else { return false }
        return until > now
    }

    func markRead(ownerId: String, runId: String) {
        guard !ownerId.isEmpty, !runId.isEmpty else { return }
        var current = state(for: ownerId)
        current.readRunIds.insert(runId)
        current.snoozedUntil.removeValue(forKey: runId)
        save(current, ownerId: ownerId)
    }

    func snooze(ownerId: String, runId: String, for interval: TimeInterval = 3600) {
        guard !ownerId.isEmpty, !runId.isEmpty, interval > 0 else { return }
        var current = state(for: ownerId)
        current.snoozedUntil[runId] = Date().addingTimeInterval(interval)
        save(current, ownerId: ownerId)
    }

    private func state(for ownerId: String) -> State {
        guard !ownerId.isEmpty,
              let data = defaults.data(forKey: key(for: ownerId)),
              let decoded = try? decoder.decode(State.self, from: data) else {
            return State()
        }
        return decoded
    }

    private func save(_ state: State, ownerId: String) {
        guard let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: key(for: ownerId))
        revision &+= 1
    }

    private func key(for ownerId: String) -> String {
        let encoded = Data(ownerId.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return "caobao.assistant.proactive.inbox.\(encoded)"
    }
}

enum AssistantProactiveDate {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
    }
}

@MainActor
struct AssistantProactiveView: View {
    let userId: String
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var store = AssistantProactiveStore.shared
    @ObservedObject private var inboxStore = AssistantProactiveInboxStore.shared
    @ObservedObject private var chat = ChatViewModel.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var profile = AssistantProactiveProfile.default
    @State private var pausedAll = false
    @State private var loadedOwner: String?
    @State private var savedMessage: String?
    @State private var isSyncing = false
    @State private var runs: [CloudProactiveRun] = []
    @State private var isLoadingRuns = false
    @State private var runsError: String?
    @State private var rules: [CloudProactiveRule] = []
    @State private var isLoadingRules = false
    @State private var rulesError: String?
    @State private var ruleEditor: ProactiveRuleEditorDestination?
    @State private var pendingRuleDelete: CloudProactiveRule?

    private struct ProactiveRuleEditorDestination: Identifiable {
        let id = UUID()
        let rule: CloudProactiveRule?
    }

    private var isCurrentOwner: Bool {
        AssistantOwnerIdentity.matches(userId, auth.user?.id ?? "local-device")
    }

    private var unreadRunCount: Int {
        inboxStore.unreadCount(ownerId: userId, runs: runs)
    }

    private var nextRunAt: Date? {
        rules.compactMap { AssistantProactiveDate.parse($0.nextRunAt) }.min()
    }

    var body: some View {
        Form {
            proactiveProfileSection
            proactiveSummarySection
            proactiveCompanionSection
            proactiveNotificationSection
            proactiveRulesSection
            proactiveRunsSection
            proactiveFooterSection
        }
        .tint(.caobaoPrimary)
        .assistantNavigationTitle("主动更新")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(!isCurrentOwner || loadedOwner == nil || isSyncing)
            }
        }
        .sheet(item: $ruleEditor) { destination in
            AssistantProactiveRuleEditor(rule: destination.rule) { request in
                try await saveRule(request)
            }
            .frame(minWidth: 460, minHeight: 520)
        }
        .confirmationDialog("删除这条主动规则？", isPresented: pendingRuleDeletePresented,
                            titleVisibility: .visible, presenting: pendingRuleDelete) { rule in
            Button("删除规则", role: .destructive) {
                pendingRuleDelete = nil
                Task { await deleteRule(rule) }
            }
            Button("取消", role: .cancel) { pendingRuleDelete = nil }
        } message: { _ in
            Text("删除后保留执行历史，离线设备也不会重新激活这条规则。")
        }
        .onAppear {
            reload()
            Task { await loadRuns() }
            Task { await loadRules() }
        }
        .onChange(of: AssistantOwnerIdentity.ownerKey(userId)) { _ in
            reload()
            Task { await loadRuns() }
            Task { await loadRules() }
        }
        .onChange(of: AssistantOwnerIdentity.ownerKey(auth.user?.id ?? "local-device")) { _ in
            reload()
            Task { await loadRuns() }
            Task { await loadRules() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantProactiveChanged)) { notification in
            guard let owner = notification.object as? String,
                  AssistantOwnerIdentity.matches(owner, userId),
                  !isEditing else { return }
            reload()
        }
    }

    @ViewBuilder
    private var proactiveProfileSection: some View {
        Section("主动更新") {
            Toggle("允许主动更新", isOn: $profile.enabled)
                .disabled(!isCurrentOwner)
            Picker("主动频率", selection: $profile.mode) {
                ForEach(AssistantProactiveMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .disabled(!profile.enabled || !isCurrentOwner)
            Text(profile.enabled ? profile.mode.detail : AssistantProactiveMode.off.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await togglePauseAll() }
            } label: {
                HStack {
                    Label(pausedAll ? "恢复全部主动任务" : "暂停全部主动任务",
                          systemImage: pausedAll ? "play.circle" : "pause.circle")
                    Spacer()
                    if isSyncing { ProgressView().controlSize(.small) }
                }
            }
            .disabled(!isCurrentOwner || loadedOwner == nil || isSyncing)
            Text(pausedAll ? "全部主动任务已暂停；规则和执行记录会保留。" : "可临时暂停全部主动任务，不会删除已创建的规则。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var proactiveCompanionSection: some View {
        Section("陪伴模式") {
            Toggle("允许陪伴式主动问候", isOn: $profile.companionEnabled)
                .disabled(!profile.enabled || !isCurrentOwner)
            Text("陪伴消息与任务提醒分开控制。默认关闭，不会使用情绪施压促使你回复。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var proactiveSummarySection: some View {
        Section("主动更新摘要") {
            HStack {
                Label("未读更新", systemImage: unreadRunCount == 0 ? "checkmark.circle" : "bell.badge")
                Spacer()
                Text(verbatim: "\(unreadRunCount) 条")
                    .foregroundStyle(unreadRunCount == 0 ? .secondary : Color.caobaoPrimary)
            }
            if let nextRunAt {
                Label {
                    Text("下一次运行：\(nextRunAt.formatted(date: .abbreviated, time: .shortened))")
                } icon: {
                    Image(systemName: "calendar.badge.clock")
                }
            } else {
                Text("暂无已排程的下一次运行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("未读和稍后状态保存在本设备；多设备同步需要服务端提供阅读状态字段。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var proactiveNotificationSection: some View {
        Section("通知控制") {
            Stepper(value: $profile.dailyLimit, in: 0...30) {
                HStack {
                    Text("每日最多主动消息")
                    Spacer()
                    Text(verbatim: "\(profile.dailyLimit) 条")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!profile.enabled || !isCurrentOwner)
            NavigationLink("安静时段") {
                AssistantQuietHoursSettingsView(ownerId: userId)
            }
            Text("锁屏通知只显示通用标题；打开应用后才能查看更新内容。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var proactiveRulesSection: some View {
        Section("主动规则") {
            if isLoadingRules {
                ProgressView("正在读取规则…")
            } else if let rulesError {
                Text(verbatim: rulesError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if rules.isEmpty {
                Text("还没有规则。先创建一条规则，再开启主动更新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    proactiveRuleRow(rule)
                }
            }
            Button {
                ruleEditor = ProactiveRuleEditorDestination(rule: nil)
            } label: {
                Label("添加主动规则", systemImage: "plus")
            }
            .disabled(!isCurrentOwner || isSyncing)
        }
    }

    @ViewBuilder
    private var proactiveRunsSection: some View {
        Section("最近主动更新") {
            if isLoadingRuns {
                ProgressView("正在读取执行记录…")
            } else if let runsError {
                Text(verbatim: runsError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if runs.isEmpty {
                Text("还没有主动执行记录。创建规则后，执行结果会显示在这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(runs) { run in
                    proactiveRunRow(run)
                }
            }
            Button("刷新执行记录") {
                Task { await loadRuns() }
            }
            .disabled(isLoadingRuns || !isCurrentOwner)
        }
    }

    @ViewBuilder
    private var proactiveFooterSection: some View {
        Section {
            Text("主动更新只使用你已启用的任务、记忆和规则。外部发送、修改数据或其他高风险动作仍需你确认。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let savedMessage {
                Text(verbatim: savedMessage)
                    .font(.caption)
                    .foregroundStyle(.caobaoPrimary)
            }
        }
    }

    private var isEditing: Bool { loadedOwner != nil && profile != store.profile(for: userId) }

    private var pendingRuleDeletePresented: Binding<Bool> {
        Binding(
            get: { pendingRuleDelete != nil },
            set: { if !$0 { pendingRuleDelete = nil } }
        )
    }

    @ViewBuilder
    private func proactiveRunRow(_ run: CloudProactiveRun) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(proactiveTriggerTitle(run.triggerReason))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(run.status).font(.caption).foregroundStyle(.secondary)
            }
            Text("创建于 \(run.createdAt)").font(.caption).foregroundStyle(.secondary)
            if let refs = run.sourceRefs, !refs.isEmpty {
                Text("来源：\(refs.joined(separator: "、"))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if appState.pendingAssistantProactiveRunId == run.id {
                Label("由通知打开", systemImage: "bell.badge")
                    .font(.caption2).foregroundStyle(.caobaoPrimary)
            }
            HStack(spacing: 8) {
                Button("查看") { openRun(run) }
                    .buttonStyle(.bordered)
                Button("稍后") {
                    inboxStore.snooze(ownerId: userId, runId: run.id)
                    savedMessage = "已将这条主动更新延后 1 小时（仅本设备）。"
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func proactiveTriggerTitle(_ reason: String) -> String {
        switch reason {
        case "scheduled", "schedule": return "按计划运行"
        case "task_due", "due": return "任务即将到期"
        case "task_overdue", "overdue": return "任务已逾期"
        case "follow_up", "conversation_follow_up": return "对话后续跟进"
        case "inactivity": return "一段时间未互动"
        case "manual", "": return "手动运行"
        default: return "主动事件：\(reason)"
        }
    }

    private func openRun(_ run: CloudProactiveRun) {
        guard isCurrentOwner else { return }
        inboxStore.markRead(ownerId: userId, runId: run.id)
        appState.pendingAssistantProactiveRunId = nil
        guard let conversationId = run.conversationId, !conversationId.isEmpty else {
            savedMessage = "已标记为已查看。此执行记录还没有关联对话。"
            return
        }
        let owner = userId
        Task { @MainActor in
            do {
                let localId = try await chat.localConversationId(
                    forServerConversationId: conversationId, ownerId: owner) ?? conversationId
                guard isCurrentOwner else { return }
                appState.assistantHomePath.append(.historyConversation(id: localId, ownerId: owner))
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentOwner else { return }
                savedMessage = "无法打开关联对话，请刷新后重试。"
            }
        }
    }

    private func reload() {
        guard isCurrentOwner else { loadedOwner = nil; return }
        profile = store.profile(for: userId)
        if !store.hasProfile(for: userId),
           let serverMode = AssistantProactiveMode(rawValue: appState.proactiveLevel) {
            profile.mode = serverMode
            profile.enabled = serverMode != .off
        }
        loadedOwner = userId
        savedMessage = nil
    }

    private func save() {
        guard isCurrentOwner, loadedOwner != nil else { return }
        if profile.mode == .off { profile.enabled = false }
        if profile.enabled, profile.mode == .off { profile.mode = .important }
        guard store.save(profile, for: userId) else {
            savedMessage = "保存失败，请检查提醒设置。"
            return
        }
        let level = profile.enabled ? profile.mode.rawValue : AssistantProactiveMode.off.rawValue
        appState.proactiveLevel = level
        appState.saveAssistantPreferences()
        savedMessage = "已保存。主动消息仍取决于已启用的规则和系统通知权限。"
        syncServer(level: level)
    }

    private func togglePauseAll() async {
        guard isCurrentOwner, loadedOwner != nil, AuthService.shared.isLoggedIn, !isSyncing else { return }
        let owner = userId
        let target = !pausedAll
        isSyncing = true
        defer { isSyncing = false }
        do {
            let token = try await AuthService.shared.validAccessToken()
            guard AssistantOwnerIdentity.matches(owner, AuthService.shared.user?.id ?? "local-device") else { return }
            let response = try await APIService.shared.pauseAllProactive(token: token, paused: target)
            guard AssistantOwnerIdentity.matches(owner, AuthService.shared.user?.id ?? "local-device") else { return }
            pausedAll = response.profile.pausedAll
            savedMessage = pausedAll ? "已暂停全部主动任务，规则仍保留。" : "已恢复全部主动任务。"
        } catch is CancellationError {
            return
        } catch {
            savedMessage = "暂停状态同步失败，请稍后重试。"
        }
    }

    private func syncServer(level: String) {
        guard AuthService.shared.isLoggedIn else { return }
        isSyncing = true
        let owner = userId
        Task { @MainActor in
            defer { isSyncing = false }
            do {
                let token = try await AuthService.shared.validAccessToken()
                guard AssistantOwnerIdentity.matches(owner, AuthService.shared.user?.id ?? "local-device") else { return }
                let request = AssistantPreferencesRequest(
                    locale: appState.assistantLanguage == "system" ? Locale.preferredLanguages.first ?? "en" : appState.assistantLanguage,
                    personaLevel: appState.userSettings.toxicLevel,
                    serviceRegion: appState.serviceRegion,
                    regionConfirmed: appState.regionConfirmed,
                    assistantMode: appState.assistantMode,
                    proactiveLevel: level
                )
                _ = try await APIService.shared.updateAssistantPreferences(token: token, request: request)
                let quiet = CloudProactiveQuietHours(enabled: profile.quietHours.enabled,
                                                     startMinute: profile.quietHours.startMinute,
                                                     endMinute: profile.quietHours.endMinute)
                _ = try await APIService.shared.updateProactiveProfile(token: token,
                    request: CloudProactiveProfileUpdateRequest(enabled: profile.enabled, mode: profile.mode.rawValue,
                        quietHours: quiet, timeZone: nil, dailyLimit: profile.dailyLimit,
                        companionEnabled: profile.companionEnabled, pausedAll: nil, expectedVersion: nil))
                savedMessage = "已保存，已同步到账号。"
            } catch is CancellationError {
                return
            } catch {
                savedMessage = "已保存在设备，账号同步暂时失败，可稍后重试。"
            }
        }
    }

    private func loadRuns() async {
        guard isCurrentOwner, AuthService.shared.isLoggedIn else {
            runs = []
            runsError = nil
            return
        }
        isLoadingRuns = true
        defer { isLoadingRuns = false }
        do {
            let token = try await AuthService.shared.validAccessToken()
            let remote = try await APIService.shared.fetchProactiveProfile(token: token).profile
            guard isCurrentOwner else { return }
            pausedAll = remote.pausedAll
            if !store.hasProfile(for: userId) {
                if let mode = AssistantProactiveMode(rawValue: remote.mode) {
                    let zone = AssistantQuietHours.supportedTimeZoneIdentifiers.contains(remote.timeZone)
                        ? remote.timeZone : AssistantQuietHours.disabled.timeZoneIdentifier
                    let local = AssistantProactiveProfile(
                        enabled: remote.enabled,
                        mode: mode,
                        quietHours: AssistantQuietHours(enabled: remote.quietHours.enabled,
                            startMinute: remote.quietHours.startMinute, endMinute: remote.quietHours.endMinute,
                            timeZoneIdentifier: zone),
                        dailyLimit: min(max(remote.dailyLimit, 0), 30),
                        companionEnabled: remote.companionEnabled
                    )
                    profile = local
                    _ = store.save(local, for: userId)
                }
            }
            let response = try await APIService.shared.listProactiveRuns(token: token, limit: 20)
            guard isCurrentOwner else { return }
            runs = response.items
            runsError = nil
            if let pending = appState.pendingAssistantProactiveRunId,
               let run = runs.first(where: { $0.id == pending }) {
                openRun(run)
            }
        } catch is CancellationError {
            return
        } catch {
            runsError = "暂时无法读取执行记录，可稍后重试。"
        }
    }

    @ViewBuilder
    private func proactiveRuleRow(_ rule: CloudProactiveRule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Button {
                    ruleEditor = ProactiveRuleEditorDestination(rule: rule)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.prompt).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(rule.kind == "schedule" ? "计划 · \(rule.cadence ?? "一次")" : rule.kind)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Text(rule.status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("立即运行") { Task { await runRule(rule) } }
                    .buttonStyle(.bordered)
                    .disabled(!isCurrentOwner || !profile.enabled || isSyncing)
                Button("删除", role: .destructive) { pendingRuleDelete = rule }
                    .buttonStyle(.bordered)
                    .disabled(!isCurrentOwner || isSyncing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadRules() async {
        guard isCurrentOwner, AuthService.shared.isLoggedIn else {
            rules = []; rulesError = nil; return
        }
        isLoadingRules = true
        defer { isLoadingRules = false }
        do {
            let token = try await AuthService.shared.validAccessToken()
            let response = try await APIService.shared.listProactiveRules(token: token, limit: 100)
            guard isCurrentOwner else { return }
            rules = response.items
            rulesError = nil
        } catch is CancellationError {
            return
        } catch {
            rulesError = "暂时无法读取主动规则，可稍后重试。"
        }
    }

    private func saveRule(_ request: CloudProactiveRuleUpsertRequest) async throws {
        let token = try await AuthService.shared.validAccessToken()
        guard isCurrentOwner else { throw CancellationError() }
        _ = try await APIService.shared.upsertProactiveRule(token: token, request: request)
        await loadRules()
    }

    private func deleteRule(_ rule: CloudProactiveRule) async {
        do {
            let token = try await AuthService.shared.validAccessToken()
            guard isCurrentOwner else { return }
            try await APIService.shared.deleteProactiveRule(token: token, id: rule.id, expectedVersion: rule.version)
            await loadRules()
        } catch {
            rulesError = "删除规则失败，请刷新后重试。"
        }
    }

    private func runRule(_ rule: CloudProactiveRule) async {
        do {
            let token = try await AuthService.shared.validAccessToken()
            guard isCurrentOwner else { return }
            _ = try await APIService.shared.runProactiveRule(token: token, ruleId: rule.id, idempotencyKey: UUID().uuidString)
            await loadRuns()
        } catch {
            runsError = "主动规则暂时无法运行，请检查开启状态和每日上限。"
        }
    }
}

@MainActor
struct AssistantProactiveRuleEditor: View {
    let rule: CloudProactiveRule?
    let onSave: (CloudProactiveRuleUpsertRequest) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: String
    @State private var prompt: String
    @State private var cadence: String
    @State private var sourceScopes: String
    @State private var nextRunAt: Date
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(rule: CloudProactiveRule?, onSave: @escaping (CloudProactiveRuleUpsertRequest) async throws -> Void) {
        self.rule = rule
        self.onSave = onSave
        _kind = State(initialValue: rule?.kind ?? "schedule")
        _prompt = State(initialValue: rule?.prompt ?? "")
        _cadence = State(initialValue: rule?.cadence ?? "FREQ=DAILY;INTERVAL=1")
        _sourceScopes = State(initialValue: rule?.sourceScopes?.joined(separator: ", ") ?? "")
        let date = ISO8601DateFormatter().date(from: rule?.nextRunAt ?? "") ?? Date().addingTimeInterval(3600)
        _nextRunAt = State(initialValue: date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("规则") {
                    Picker("类型", selection: $kind) {
                        Text("按计划").tag("schedule")
                        Text("内部事件").tag("internal_event")
                        Text("不活跃跟进").tag("inactivity")
                    }
                    TextField("提示内容", text: $prompt, axis: .vertical)
                        .lineLimit(3...8)
                    if kind == "schedule" {
                        TextField("重复规则", text: $cadence)
                            .autocorrectionDisabled()
                        DatePicker("下一次运行", selection: $nextRunAt, in: Date()...)
                    }
                    TextField("来源范围（逗号分隔）", text: $sourceScopes)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("保存前会校验时间、频率和账号权限。外部写操作仍需要用户确认。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(rule == nil ? "添加主动规则" : "编辑主动规则")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(isSaving || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let scopes = sourceScopes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let next = kind == "schedule" ? ISO8601DateFormatter().string(from: nextRunAt) : nil
        let request = CloudProactiveRuleUpsertRequest(id: rule?.id ?? "", kind: kind,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines), cadence: kind == "schedule" ? cadence : nil,
            sourceScopes: scopes, nextRunAt: next, expectedVersion: rule?.version)
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do { try await onSave(request); dismiss() }
            catch is CancellationError { return }
            catch { errorMessage = "保存失败，请检查规则内容后重试。" }
        }
    }
}

/// User-scoped memory controls. A disabled memory store remains editable and exportable.
@MainActor
struct AssistantMemoriesView: View {
    let userId: String
    @ObservedObject private var auth = AuthService.shared
    @State private var memories: [AssistantMemory] = []
    @State private var memoryEnabled = false
    @State private var excludedMemoryCategories: Set<AssistantMemoryCategory> = []
    @State private var searchText = ""
    @State private var editor: MemoryEditorDestination?
    @State private var pendingDeletion: AssistantMemory?
    @State private var operationError: String?
    @State private var exportText = ""
    @State private var loadedOwner: String?
    @State private var loadFailed = false
    @State private var pageEpoch = UUID()

    private let repository = AssistantLocalRepository.shared

    private var hasLiveOwner: Bool {
        !userId.isEmpty && AssistantOwnerIdentity.matches(userId, auth.user?.id ?? "local-device")
    }
    private var isCurrentPage: Bool { hasLiveOwner && AssistantOwnerIdentity.matches(loadedOwner, userId) && !loadFailed }

    var body: some View {
        let deletionEpoch = pageEpoch
        return List {
            if !hasLiveOwner {
                Text("当前账号已变化，请重新打开记忆页面。")
            } else if loadFailed {
                Section {
                    Text("无法读取本地记忆。原始数据已保留，请稍后重试。")
                    Button("重新读取记忆", action: reload).frame(minHeight: 44)
                }
            } else if !AssistantOwnerIdentity.matches(loadedOwner, userId) {
                ProgressView()
            } else {
            Section {
                Toggle(isOn: Binding(get: { memoryEnabled }, set: setMemoryEnabled)) {
                    Label("允许助理使用长期记忆", systemImage: "brain.head.profile")
                }
                .frame(minHeight: 44)
                .disabled(!isCurrentPage)
                Text("关闭后，已保存的记忆仍可管理，但不会加入新的对话上下文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(AssistantMemoryCategory.allCases, id: \.rawValue) { category in
                    Toggle(isOn: Binding(
                        get: { !excludedMemoryCategories.contains(category) },
                        set: { setMemoryCategoryEnabled($0, category: category) }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(category.workspaceTitle)
                            Text(categoryUsageStatus(category))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 44)
                    .disabled(!isCurrentPage || !memoryEnabled)
                }
            } header: {
                Text("记忆类别")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("关闭类别只会停止将该类记忆加入新的对话，已保存内容仍可管理或删除。全局开关关闭时，所有类别都不会加入新的对话。")
                    Text("全局或类别重新开启不会自动授予单条授权；尚未确认或已停用的记忆仍不会作为长期记忆附加。")
                }
            }

            Section {
                if filteredMemories.isEmpty {
                    WorkspaceEmptyState(
                        icon: "brain",
                        title: memories.isEmpty ? "暂无已保存记忆" : "没有匹配的记忆",
                        detail: "只保存你明确确认的信息，并可随时修改或删除。"
                    )
                } else {
                    ForEach(filteredMemories) { memory in
                        Button { openEditor(memory) } label: {
                            memoryRow(memory)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("编辑记忆：\(memory.text)"))
                        .accessibilityValue(Text(memoryAccessibilityValue(memory)))
                        .swipeActions {
                            Button(role: .destructive) { pendingDeletion = memory } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button { openEditor(memory) } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.caobaoPrimary)
                        }
                    }
                }
            } header: {
                Text("已保存的记忆")
            }
            }
        }
        .tint(.caobaoPrimary)
        .searchable(text: $searchText, prompt: "搜索记忆")
        .assistantNavigationTitle("我的记忆")
        .onReceive(NotificationCenter.default.publisher(for: .assistantMemorySyncApplied)) { notification in
            guard let owner = notification.object as? String,
                  AssistantOwnerIdentity.matches(owner, userId) else { return }
            reload()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ShareLink(item: exportText, subject: Text("CaoBao 记忆导出")) {
                    Label("导出记忆", systemImage: "square.and.arrow.up")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(exportText.isEmpty || !isCurrentPage)
                .accessibilityLabel("导出当前账号的全部记忆")
                Button { if isCurrentPage { editor = MemoryEditorDestination(memory: nil) } } label: {
                    Label("添加记忆", systemImage: "plus")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(!isCurrentPage)
                .accessibilityLabel("添加记忆")
            }
        }
        .sheet(item: $editor, onDismiss: reload) { destination in
            memoryEditor(destination)
        }
        .confirmationDialog("删除这条记忆？", isPresented: hasPendingDeletion, titleVisibility: .visible, presenting: pendingDeletion) { memory in
            Button("删除记忆", role: .destructive) { deleteMemory(memory, expectedPageEpoch: deletionEpoch) }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("删除后，这条记忆将不再用于新的对话。")
        }
        .assistantWorkspaceError($operationError)
        .onAppear(perform: reload)
        .onChange(of: AssistantOwnerIdentity.ownerKey(userId)) { _ in resetForOwnerChange() }
        .onChange(of: AssistantOwnerIdentity.ownerKey(auth.user?.id ?? "local-device")) { _ in resetForOwnerChange() }
        .onReceive(NotificationCenter.default.publisher(for: .loginSuccess)) { _ in resetForOwnerChange() }
        .onReceive(NotificationCenter.default.publisher(for: .logoutSuccess)) { _ in resetForOwnerChange() }
        .refreshable { reload() }
    }

    private var filteredMemories: [AssistantMemory] {
        guard isCurrentPage else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? memories : memories.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var hasPendingDeletion: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private func memoryRow(_ memory: AssistantMemory) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(memory.text).foregroundStyle(.primary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            Label(memory.category.workspaceTitle, systemImage: "tag")
                .font(.caption).foregroundStyle(Color.caobaoPrimary)
            Text(memoryAuthorizationTitle(memory))
                .font(.caption).foregroundStyle(AssistantMemoryAuthorizationPolicy.allowsUse(of: memory) ? Color.caobaoPrimary : Color.secondary)
            Text(LocalizedStringKey(memoryUsageKey(memory)))
                .font(.caption2).foregroundStyle(.secondary)
            if let source = memory.sourceMessageId, !source.isEmpty {
                Text("来源消息：\(source)").font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("未关联来源消息").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("创建于")
                Text(memory.createdAt, format: .dateTime.year().month().day().hour().minute())
            }.font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text("更新于")
                Text(memory.updatedAt, format: .dateTime.year().month().day().hour().minute())
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func memoryEditor(_ destination: MemoryEditorDestination) -> some View {
        if isCurrentPage, destination.memory == nil || AssistantOwnerIdentity.matches(destination.memory?.userId, userId) {
            AssistantMemoryEditor(userId: userId, memory: destination.memory) { record, isNew in
                saveMemory(record, isNew: isNew, expected: destination.memory, destinationId: destination.id)
            }
        } else {
            Text("当前账号或记忆已变化，请重新打开页面。").padding()
        }
    }

    private func openEditor(_ memory: AssistantMemory) {
        guard isCurrentPage, AssistantOwnerIdentity.matches(memory.userId, userId) else { return }
        editor = MemoryEditorDestination(memory: memory)
    }

    private func memoryUsageKey(_ memory: AssistantMemory) -> String {
        guard AssistantMemoryAuthorizationPolicy.allowsUse(of: memory) else { return "未授权，不作为长期记忆附加" }
        guard !memory.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "正文为空，不会作为长期记忆附加" }
        guard memoryEnabled else { return "全局记忆已关闭" }
        guard !excludedMemoryCategories.contains(memory.category) else { return "此类别不用于新对话" }
        return "可供新请求选择，不保证每次使用"
    }

    private func memoryAccessibilityValue(_ memory: AssistantMemory) -> String {
        AssistantLocalization.string(memoryAuthorizationKey(memory)) + "; "
            + AssistantLocalization.string(memoryUsageKey(memory))
    }

    private func resetForOwnerChange() {
        memories = []; memoryEnabled = false; excludedMemoryCategories = []
        editor = nil; pendingDeletion = nil; searchText = ""; exportText = ""
        operationError = nil; loadedOwner = nil; loadFailed = false; pageEpoch = UUID()
        reload()
    }

    private func reload() {
        guard hasLiveOwner else {
            memories = []; memoryEnabled = false; excludedMemoryCategories = []; exportText = ""
            loadedOwner = nil; loadFailed = false
            operationError = AssistantLocalization.string("当前账号已变化，请重新打开记忆页面。")
            return
        }
        do {
            let repositorySnapshot = try repository.exportSnapshot(for: userId)
            memories = repositorySnapshot.memories.filter { $0.status == .active }.sorted {
                $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
            }
            memoryEnabled = repositorySnapshot.memoryEnabled
            excludedMemoryCategories = Set(repositorySnapshot.excludedMemoryCategories)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let snapshot = MemoryExportSnapshot(
                formatVersion: 1, userId: userId, exportedAt: Date(),
                memoryEnabled: memoryEnabled,
                excludedMemoryCategories: repositorySnapshot.excludedMemoryCategories, memories: memories
            )
            exportText = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
            loadedOwner = userId; loadFailed = false; operationError = nil
        } catch {
            memories = []; memoryEnabled = false; excludedMemoryCategories = []; exportText = ""
            loadedOwner = userId; loadFailed = true
            operationError = error.localizedDescription
        }
    }

    private func setMemoryEnabled(_ enabled: Bool) {
        guard isCurrentPage else { return }
        repository.setMemoryEnabled(enabled, for: userId)
        let error = repository.lastError?.localizedDescription
        reload()
        if let error { operationError = error }
    }

    private func categoryUsageStatus(_ category: AssistantMemoryCategory) -> String {
        let key: String
        if !memoryEnabled { key = "全局记忆已关闭" }
        else if excludedMemoryCategories.contains(category) { key = "此类别不用于新对话" }
        else { key = "此类别可用于新对话" }
        return AssistantLocalization.string(key)
    }

    private func setMemoryCategoryEnabled(_ enabled: Bool, category: AssistantMemoryCategory) {
        guard isCurrentPage, memoryEnabled else { return }
        let succeeded = repository.setMemoryCategoryEnabled(enabled, category: category, for: userId)
        let error = repository.lastError?.localizedDescription
        reload()
        operationError = error ?? (succeeded ? nil : AssistantLocalization.string("记忆类别设置保存失败，请刷新后重试。"))
    }

    private func saveMemory(_ memory: AssistantMemory, isNew: Bool, expected: AssistantMemory?, destinationId: UUID) -> String? {
        guard isCurrentPage, AssistantOwnerIdentity.matches(memory.userId, userId), editor?.id == destinationId else {
            return AssistantLocalization.string("当前账号已变化，请重新打开页面。")
        }
        let succeeded: Bool
        if isNew { succeeded = repository.insertMemory(memory) }
        else if let expected { succeeded = repository.updateMemory(memory, expecting: expected) }
        else { return AssistantRepositoryError.staleMemory.localizedDescription }
        let error = succeeded ? nil : repository.lastError?.localizedDescription
        reload()
        if succeeded { NotificationCenter.default.post(name: .assistantMemoryStoreChanged, object: userId) }
        return error ?? (succeeded ? nil : AssistantLocalization.string("记忆保存失败，请刷新后重试。"))
    }

    private func deleteMemory(_ memory: AssistantMemory, expectedPageEpoch: UUID) {
        guard isCurrentPage, AssistantOwnerIdentity.matches(memory.userId, userId), pageEpoch == expectedPageEpoch else { return }
        if pendingDeletion?.id == memory.id { pendingDeletion = nil }
        let succeeded = repository.deleteMemory(memory)
        let error = succeeded ? nil : repository.lastError?.localizedDescription
        reload()
        if succeeded { NotificationCenter.default.post(name: .assistantMemoryStoreChanged, object: userId) }
        operationError = error ?? (succeeded ? nil : AssistantLocalization.string("记忆删除失败，请刷新后重试。"))
    }
}

/// Lists actual repository states; a due date alone does not schedule a notification.
@MainActor
struct AssistantTasksView: View {
    let userId: String
    @ObservedObject private var auth = AuthService.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @State private var tasks: [AssistantTask] = []
    @State private var searchText = ""
    @State private var editor: TaskEditorDestination?
    @State private var pendingDeletion: AssistantTask?
    @State private var reactivationTarget: AssistantTask?
    @State private var endingPlan: AssistantTask?
    @State private var operationError: String?
    @State private var reminderStates: [String: AssistantReminderState] = [:]
    @State private var reminderCoverage: [String: AssistantReminderCoverage] = [:]
    @State private var reminderSnapshots: [String: AssistantTask] = [:]
    @State private var loadedOwner: String?
    @State private var activeOperation: OperationIdentity?
    @State private var refreshRunId: UUID?
    private let repository = AssistantLocalRepository.shared

    private struct OperationIdentity: Equatable {
        let ownerId: String
        let id = UUID()
    }
    private var isOperating: Bool { activeOperation != nil }
    private var isCurrentPage: Bool {
        !userId.isEmpty && AssistantOwnerIdentity.matches(loadedOwner, userId)
            && AssistantOwnerIdentity.matches(userId, auth.user?.id ?? "local-device")
    }

    private var taskSurface: some View {
        taskList
        .tint(.caobaoPrimary)
        .searchable(text: $searchText, prompt: "搜索任务")
        .assistantNavigationTitle("我的任务")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editor = TaskEditorDestination(task: nil) } label: {
                    Label("添加任务", systemImage: "plus").frame(minWidth: 44, minHeight: 44)
                }
                .disabled(!isCurrentPage || isOperating)
                .accessibilityLabel("添加任务")
            }
        }
        .sheet(item: $editor) { destination in
            taskEditor(destination)
        }
    }

    private var taskDialogs: some View {
        taskSurface
        .confirmationDialog("永久删除这个任务？", isPresented: hasPendingDeletion, titleVisibility: .visible, presenting: pendingDeletion) { task in
            Button("删除任务", role: .destructive) { deleteTask(task) }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { _ in Text("删除后无法恢复；若只是暂时不处理，可以暂停或取消。") }
        .confirmationDialog("结束整个重复计划？", isPresented: hasEndingPlan,
                            titleVisibility: .visible, presenting: endingPlan) { snapshot in
            Button("结束整个计划") {
                endingPlan = nil
                setStatus(snapshot, to: .completed, confirmedEnd: true)
            }
            Button("取消", role: .cancel) { endingPlan = nil }
        } message: { _ in
            Text("这会将整个任务标记完成并移除后续本地提醒，不是只完成本次。若只是暂时停止，请选择暂停。")
        }
        .confirmationDialog("这个提醒已过期，如何恢复任务？", isPresented: hasReactivationTarget,
                            titleVisibility: .visible, presenting: reactivationTarget) { snapshot in
            Button("仅恢复待办并关闭旧提醒") {
                reactivationTarget = nil
                reopenWithoutReminder(snapshot)
            }
            Button("修改提醒时间并恢复") {
                reactivationTarget = nil
                editor = TaskEditorDestination(task: snapshot, isReactivation: true)
            }
            Button("取消", role: .cancel) { reactivationTarget = nil }
        } message: { _ in
            Text("仅恢复待办会保留原到期时间并关闭旧提醒；若需要再次提醒，请修改时间并保存。不会自动推迟到明天。")
        }
    }

    var body: some View {
        taskDialogs
        .assistantWorkspaceError($operationError)
        .onAppear(perform: reload)
        .onChange(of: AssistantOwnerIdentity.ownerKey(userId)) { _ in resetForOwnerChange() }
        .onChange(of: AssistantOwnerIdentity.ownerKey(auth.user?.id ?? "local-device")) { _ in resetForOwnerChange() }
        .onReceive(NotificationCenter.default.publisher(for: .loginSuccess)) { _ in resetForOwnerChange() }
        .onReceive(NotificationCenter.default.publisher(for: .logoutSuccess)) { _ in resetForOwnerChange() }
        .task(id: AssistantOwnerIdentity.ownerKey(userId)) {
            await syncTasksFromCloud()
            reload()
            await refreshReminderStates()
            consumeTaskDeepLink()
        }
        .onChange(of: appState.pendingAssistantTaskId) { _ in consumeTaskDeepLink() }
        .onChange(of: isPresentingTaskDetails) { presented in
            if !presented { consumeTaskDeepLink() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("assistant.reminders.changed"))) { _ in
            Task { await refreshReminderStates() }
        }
        .refreshable { reload(); await refreshReminderStates() }
    }

    private var taskList: some View {
        List {
            if !AssistantOwnerIdentity.matches(userId, auth.user?.id ?? "local-device") {
                Text("当前账号已变化，请重新打开任务页面。")
            } else if !AssistantOwnerIdentity.matches(loadedOwner, userId) {
                ProgressView()
            } else {
                Section {
                    Label("到期时间不会自动提醒。请在编辑任务时主动开启本地提醒，送达取决于系统设置。", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if filteredTasks.isEmpty {
                    WorkspaceEmptyState(icon: "checklist", title: tasks.isEmpty ? "暂无任务" : "没有匹配的任务",
                        detail: "添加一件需要完成的事，随时编辑或调整状态。")
                } else {
                    taskSections
                }
            }
        }.disabled(isOperating)
    }

    private var taskSections: some View {
        ForEach(AssistantTaskStatus.allCases, id: \.rawValue) { status in
            taskSection(status)
        }
    }

    @ViewBuilder
    private func taskSection(_ status: AssistantTaskStatus) -> some View {
        let items = filteredTasks.filter { $0.status == status }
        if !items.isEmpty {
            Section {
                ForEach(items, id: \.id) { item in taskRow(item) }
            } header: { Text(status.workspaceTitle) }
        }
    }

    @ViewBuilder
    private func taskEditor(_ destination: TaskEditorDestination) -> some View {
        if isCurrentPage, destination.task == nil || AssistantOwnerIdentity.matches(destination.task?.userId, userId) {
            AssistantTaskEditor(userId: userId, task: destination.task, reactivatingTask: destination.isReactivation) { record, isNew in
                await saveTask(record, isNew: isNew, expectedTask: destination.task)
            }
        } else {
            Text("当前账号已变化，请重新打开任务页面。")
                .padding()
        }
    }

    private func resetForOwnerChange() {
        activeOperation = nil; refreshRunId = nil; loadedOwner = nil
        tasks = []; reminderStates = [:]; reminderCoverage = [:]; reminderSnapshots = [:]; operationError = nil
        editor = nil; pendingDeletion = nil; reactivationTarget = nil; endingPlan = nil; searchText = ""
        reload()
    }

    private func beginOperation() -> OperationIdentity? {
        guard isCurrentPage, !isOperating else { return nil }
        let value = OperationIdentity(ownerId: userId)
        activeOperation = value; operationError = nil
        return value
    }

    private func isCurrent(_ operation: OperationIdentity) -> Bool {
        activeOperation == operation && AssistantOwnerIdentity.matches(operation.ownerId, userId) && isCurrentPage
    }

    private func finishOperation(_ operation: OperationIdentity) {
        guard isCurrent(operation) else { return }
        activeOperation = nil
        consumeTaskDeepLink()
    }

    private var isPresentingTaskDetails: Bool {
        editor != nil || pendingDeletion != nil || reactivationTarget != nil || endingPlan != nil
    }

    private var filteredTasks: [AssistantTask] {
        guard isCurrentPage else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? tasks : tasks.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            ($0.instructions?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var hasPendingDeletion: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    private var hasReactivationTarget: Binding<Bool> {
        Binding(get: { reactivationTarget != nil }, set: { if !$0 { reactivationTarget = nil } })
    }

    private var hasEndingPlan: Binding<Bool> {
        Binding(get: { endingPlan != nil }, set: { if !$0 { endingPlan = nil } })
    }

    private func isRepeatingPlan(_ task: AssistantTask) -> Bool {
        // Unknown legacy rules may also repeat; never imply completion is per occurrence.
        guard let raw = task.recurrenceRule else { return false }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func taskRow(_ task: AssistantTask) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                setStatus(task, to: task.status == .completed ? .active : .completed)
            } label: {
                Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3).frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(task.status == .completed ? Color.caobaoPrimary : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(task.status == .completed ? Text("重新打开任务：\(task.title)") :
                (isRepeatingPlan(task) ? Text("结束重复计划：\(task.title)") : Text("完成任务：\(task.title)")))

            Button { editor = TaskEditorDestination(task: task) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                        .strikethrough(task.status == .completed)
                    if let notes = task.instructions, !notes.isEmpty {
                        Text(notes).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                    }
                    taskTiming(task)
                    TimelineView(.periodic(from: Date(), by: 60)) { context in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(effectiveReminderState(task, now: context.date).localizedDescription)
                                .font(.caption2).foregroundStyle(.secondary)
                            taskCoverage(task, now: context.date)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("编辑任务：\(task.title)"))
            .accessibilityValue(Text(taskAccessibilityValue(task)))

            Menu {
                Button { editor = TaskEditorDestination(task: task) } label: { Label("编辑", systemImage: "pencil") }
                Button { setStatus(task, to: task.status == .completed ? .active : .completed) } label: {
                    Label(task.status == .completed ? LocalizedStringKey("重新打开") :
                        (isRepeatingPlan(task) ? LocalizedStringKey("结束整个重复计划") : LocalizedStringKey("标记完成")), systemImage: "checkmark.circle")
                }
                if task.status == .active {
                    Button { setStatus(task, to: .paused) } label: { Label("暂停", systemImage: "pause.circle") }
                } else if task.status == .paused || task.status == .cancelled {
                    Button { setStatus(task, to: .active) } label: { Label("恢复处理", systemImage: "play.circle") }
                }
                if task.status != .cancelled {
                    Button { setStatus(task, to: .cancelled) } label: { Label("取消任务", systemImage: "xmark.circle") }
                }
                Divider()
                Button(role: .destructive) { pendingDeletion = task } label: { Label("删除", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("任务操作：\(task.title)"))
        }
        .swipeActions {
            Button(role: .destructive) { pendingDeletion = task } label: { Label("删除", systemImage: "trash") }
            Button { editor = TaskEditorDestination(task: task) } label: { Label("编辑", systemImage: "pencil") }.tint(.caobaoPrimary)
        }
    }

    @ViewBuilder
    private func taskTiming(_ task: AssistantTask) -> some View {
        let recurrence = try? AssistantTaskRecurrence.parse(task.recurrenceRule)
        let repeats = recurrence?.isRepeating == true
        if repeats {
            if case .some(.weekly(let days)) = recurrence {
                Text("每周：\(days.sorted().map { AssistantLocalization.string(weekdayKey($0)) }.joined(separator: " · "))")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("每天").font(.caption).foregroundStyle(.secondary) }
        } else if recurrence == nil {
            Text("旧重复规则暂不支持；请编辑后明确保留或替换。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let due = task.dueAt {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: repeats ? "repeat" : "calendar")
                if repeats {
                    Text(due, format: .dateTime.hour().minute())
                        .environment(\.timeZone, (try? AssistantTaskTimeZonePolicy.timeZone(for: task.timeZone)) ?? TimeZone(secondsFromGMT: 0)!)
                } else {
                    if recurrence == nil { Text("保存的参考日期") }
                    Text(due, format: .dateTime.year().month().day().hour().minute())
                        .environment(\.timeZone, (try? AssistantTaskTimeZonePolicy.timeZone(for: task.timeZone)) ?? TimeZone(secondsFromGMT: 0)!)
                }
            }.font(.caption).foregroundStyle(.secondary)
        } else {
            Text(repeats ? LocalizedStringKey("未设置重复时间") : LocalizedStringKey("未设置到期时间"))
                .font(.caption).foregroundStyle(.secondary)
        }
        if (try? AssistantTaskTimeZonePolicy.validatedIdentifier(task.timeZone)) != nil {
            Text("任务时区：\(task.timeZone)").font(.caption2).foregroundStyle(.secondary)
        } else {
            if task.dueAt != nil {
                Text("任务时区无效；到期时刻按 UTC 显示，请编辑任务修复时区。")
                    .font(.caption2).foregroundStyle(.red)
            } else {
                Text("任务时区无效，请选择有效的地区时区后保存。")
                    .font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private func weekdayKey(_ day: Int) -> String {
        ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"][day - 1]
    }

    private func taskAccessibilityValue(_ task: AssistantTask) -> String {
        let rule = try? AssistantTaskRecurrence.parse(task.recurrenceRule)
        var values: [String] = []
        if case .some(.daily) = rule { values.append(AssistantLocalization.string("每天")) }
        if case .some(.weekly(let days)) = rule {
            let names = days.sorted().map { AssistantLocalization.string(weekdayKey($0)) }.joined(separator: " · ")
            values.append(String(format: AssistantLocalization.string("每周：%@"), names))
        }
        if rule == nil { values.append(AssistantLocalization.string("旧重复规则暂不支持；请编辑后明确保留或替换。")) }
        if let due = task.dueAt {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = (try? AssistantTaskTimeZonePolicy.timeZone(for: task.timeZone)) ?? TimeZone(secondsFromGMT: 0)!
            formatter.dateStyle = rule?.isRepeating == true ? .none : .medium
            formatter.timeStyle = .short
            if rule == nil { values.append(AssistantLocalization.string("保存的参考日期")) }
            values.append(formatter.string(from: due))
        }
        values.append(String(format: AssistantLocalization.string("任务时区：%@"), task.timeZone))
        values.append(effectiveReminderState(task).localizedDescription)
        return values.joined(separator: "; ")
    }

    private func effectiveReminderState(_ task: AssistantTask, now: Date = Date()) -> AssistantReminderState {
        guard task.reminderEnabled == true else { return .notEnabled }
        guard task.status == .active else { return .inactive }
        guard reminderSnapshots[task.id] == task else { return .notScheduled }
        if let value = reminderCoverage[task.id], value.repeating, let through = value.through, through <= now {
            return .notScheduled
        }
        return reminderStates[task.id] ?? .notScheduled
    }

    @ViewBuilder
    private func taskCoverage(_ task: AssistantTask, now: Date) -> some View {
        if task.status == .active, task.reminderEnabled == true, reminderSnapshots[task.id] == task,
           reminderStates[task.id] == .scheduled, let value = reminderCoverage[task.id], value.repeating {
            VStack(alignment: .leading, spacing: 4) {
                if let through = value.through {
                    if through > now {
                        Text("已预排 \(value.scheduledCount) 次重复提醒")
                        Text("当前覆盖截止")
                        Text(through, format: .dateTime.year().month().day().hour().minute())
                            .environment(\.timeZone, (try? AssistantTaskTimeZonePolicy.timeZone(for: task.timeZone)) ?? TimeZone(secondsFromGMT: 0)!)
                        Text("安静时段开启时只预排有限次数，请打开应用补排后续提醒。")
                    } else {
                        Text("已过提醒覆盖截止，请打开应用并刷新任务；后续提醒尚未确认安排。")
                            .foregroundStyle(.orange)
                    }
                } else { Text("系统日历重复提醒已安排，实际送达取决于系统设置。") }
                if value.nextFireAt > now {
                    Text("系统预计下次提醒")
                    Text(value.nextFireAt, format: .dateTime.year().month().day().hour().minute())
                        .environment(\.timeZone, (try? AssistantTaskTimeZonePolicy.timeZone(for: task.timeZone)) ?? TimeZone(secondsFromGMT: 0)!)
                }
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func reload() {
        guard AssistantOwnerIdentity.matches(userId, auth.user?.id ?? "local-device") else { return }
        guard !userId.isEmpty else {
            tasks = []
            operationError = AssistantLocalization.string("请登录后管理个人数据。")
            return
        }
        tasks = repository.tasks(for: userId)
        loadedOwner = userId
        if let error = repository.lastError?.localizedDescription { operationError = error }
        else { consumeTaskDeepLink() }
    }

    /// Pulls owner-scoped task mutations into the local task store while leaving
    /// reminder consent and scheduling entirely local. The cursor advances only
    /// after every change has been applied successfully.
    private func syncTasksFromCloud() async {
        guard isCurrentPage, let token = try? await AuthService.shared.validAccessToken(),
              !token.isEmpty else { return }
        do {
            let cursor = loadCloudTaskCursor()
            let changes = try await APIService.shared.syncCloudTaskChanges(token: token, cursor: cursor, limit: 200)
            guard changes.items.allSatisfy({ validCloudTaskCursorFields($0) }) else { throw CloudTaskSyncError.invalidResponse }
            if let next = changes.nextCursor, !next.isEmpty {
                guard isCloudTaskCursor(next), isCloudTaskCursorAtLeast(next, asLargeAs: cursor) else {
                    throw CloudTaskSyncError.invalidResponse
                }
            }
            if let head = changes.headCursor, !head.isEmpty {
                guard isCloudTaskCursor(head), isCloudTaskCursorAtLeast(head, asLargeAs: changes.nextCursor ?? cursor) else {
                    throw CloudTaskSyncError.invalidResponse
                }
            }
            var local = repository.tasks(for: userId)
            var pendingDeletes = loadCloudTaskDeletionIDs()
            for remote in changes.items {
                if remote.deletedAt?.isEmpty == false {
                    if local.contains(where: { $0.id == remote.id }) {
                        try await AssistantReminderCoordinator.shared.deleteTask(id: remote.id, ownerId: userId)
                        local.removeAll { $0.id == remote.id }
                    }
                    pendingDeletes.remove(remote.id)
                    continue
                }
                // A local deletion remains authoritative until the server has
                // accepted its tombstone, so an older active row cannot revive
                // the task while the device is offline.
                if pendingDeletes.contains(remote.id) { continue }
                guard let normalized = cloudTaskToLocal(remote, existing: local.first(where: { $0.id == remote.id })) else {
                    throw CloudTaskSyncError.invalidResponse
                }
                if let existing = local.first(where: { $0.id == remote.id }) {
                    guard repository.updateTask(normalized) else { throw CloudTaskSyncError.invalidResponse }
                    if let index = local.firstIndex(of: existing) { local[index] = normalized }
                } else {
                    repository.addTask(normalized)
                    guard repository.lastError == nil else { throw CloudTaskSyncError.invalidResponse }
                    local.append(normalized)
                }
            }

            let nextCursor = changes.nextCursor?.isEmpty == false ? changes.nextCursor : changes.headCursor
            if let nextCursor, !nextCursor.isEmpty {
                guard isValidCloudTaskCursor(nextCursor) else { throw CloudTaskSyncError.invalidResponse }
                saveCloudTaskCursor(nextCursor)
            }

            for id in Array(pendingDeletes).sorted() {
                do {
                    try await APIService.shared.deleteCloudTask(token: token, id: id)
                    pendingDeletes.remove(id)
                } catch {
                    // Retry on the next foreground/task-page sync. The local
                    // deletion stays durable and cannot be resurrected above.
                }
            }
            saveCloudTaskDeletionIDs(pendingDeletes)

            // Keep the existing local-only upload behavior, but derive the
            // remote identity set from active rows so a tombstone cannot be
            // mistaken for a missing task and recreated.
            let active = try await APIService.shared.listCloudTasks(token: token, limit: 200)
            let remoteIDs = Set(active.items.map(\.id))

            for task in local where !remoteIDs.contains(task.id) {
                let request = CloudTaskUpsertRequest(id: task.id, title: task.title,
                    instructions: task.instructions, timeZone: task.timeZone,
                    recurrenceRule: task.recurrenceRule, requiresApproval: task.requiresApproval,
                    dueAt: cloudTimestamp(task.dueAt), expectedVersion: nil)
                _ = try? await APIService.shared.upsertCloudTask(token: token, request: request)
            }
        } catch {
            // Network errors are intentionally silent here. The local reminder
            // database is the source of truth for this screen's behavior.
        }
    }

    private enum CloudTaskSyncError: Error { case invalidResponse }

    private func taskCursorKey() -> String {
        "caobao.assistant.cloudTaskSync." + Data(userId.utf8).base64EncodedString()
    }

    private func loadCloudTaskCursor() -> String? {
        let value = UserDefaults.standard.string(forKey: taskCursorKey())?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty, isValidCloudTaskCursor(value) else { return nil }
        return value
    }

    private func saveCloudTaskCursor(_ value: String) {
        UserDefaults.standard.set(value, forKey: taskCursorKey())
    }

    private func taskDeletionKey() -> String {
        "caobao.assistant.cloudTaskDeletes." + Data(userId.utf8).base64EncodedString()
    }

    private func loadCloudTaskDeletionIDs() -> Set<String> {
        Set((UserDefaults.standard.array(forKey: taskDeletionKey()) as? [String] ?? []).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256
        })
    }

    private func saveCloudTaskDeletionIDs(_ values: Set<String>) {
        UserDefaults.standard.set(Array(values.sorted().prefix(256)), forKey: taskDeletionKey())
    }

    private func isValidCloudTaskCursor(_ value: String) -> Bool { isCloudTaskCursor(value) }

    private func isCloudTaskCursor(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let timestamp = Int64(parts[0]), let id = Int64(parts[1]) else { return false }
        return timestamp >= 0 && id > 0
    }

    private func isCloudTaskCursorAtLeast(_ value: String, asLargeAs other: String?) -> Bool {
        guard isCloudTaskCursor(value) else { return false }
        guard let other, !other.isEmpty else { return true }
        guard isCloudTaskCursor(other) else { return false }
        let lhs = value.split(separator: ":").compactMap { Int64($0) }
        let rhs = other.split(separator: ":").compactMap { Int64($0) }
        guard lhs.count == 2, rhs.count == 2 else { return false }
        return lhs[0] > rhs[0] || (lhs[0] == rhs[0] && lhs[1] >= rhs[1])
    }

    private func validCloudTaskCursorFields(_ task: CloudTask) -> Bool {
        !task.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !task.updatedAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            cloudDate(task.updatedAt) != nil
    }

    private func cloudTaskToLocal(_ remote: CloudTask, existing: AssistantTask?) -> AssistantTask? {
        guard !remote.id.isEmpty, !remote.title.isEmpty,
              let zone = try? AssistantTaskTimeZonePolicy.validatedIdentifier(remote.timeZone) else { return nil }
        let status: AssistantTaskStatus
        switch remote.status.lowercased() {
        case "completed": status = .completed
        case "cancelled": status = .cancelled
        case "paused": status = .paused
        default: status = .active
        }
        let created = cloudDate(remote.createdAt) ?? existing?.createdAt ?? Date()
        let updated = cloudDate(remote.updatedAt) ?? existing?.updatedAt ?? created
        return AssistantTask(id: remote.id, userId: userId, title: remote.title,
            instructions: remote.instructions, dueAt: cloudDate(remote.dueAt), timeZone: zone,
            recurrenceRule: remote.recurrenceRule, requiresApproval: remote.requiresApproval,
            status: status, createdAt: created, updatedAt: updated,
            reminderEnabled: existing?.reminderEnabled ?? false,
            sourceMessageId: existing?.sourceMessageId,
            recurrenceStartsAt: existing?.recurrenceStartsAt)
    }

    private func cloudDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
    }

    private func cloudTimestamp(_ value: Date?) -> String? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }

    private func saveTask(_ task: AssistantTask, isNew: Bool, expectedTask: AssistantTask?) async -> String? {
        guard !userId.isEmpty, AssistantOwnerIdentity.matches(task.userId, userId),
              AssistantOwnerIdentity.matches(userId, auth.user?.id ?? "local-device") else {
            return AssistantLocalization.string("当前账号已变化，请重新打开页面。")
        }
        guard let operation = beginOperation() else { return AssistantReminderError.operationInProgress.localizedDescription }
        defer { finishOperation(operation) }
        do {
            try await AssistantReminderCoordinator.shared.saveTask(
                task, isNew: isNew, ownerId: userId, requestAuthorization: task.reminderEnabled == true,
                expectedTask: expectedTask,
                validateBeforeCommit: {
                    guard isCurrent(operation) else { throw AssistantReminderError.inactiveSession }
                }
            )
            guard isCurrent(operation) else { return AssistantReminderError.inactiveSession.localizedDescription }
            reload()
            await refreshReminderStates()
            guard isCurrent(operation) else { return AssistantReminderError.inactiveSession.localizedDescription }
            return nil
        } catch AssistantReminderError.reactivationRequired {
            guard isCurrent(operation) else { return AssistantReminderError.inactiveSession.localizedDescription }
            return AssistantLocalization.string("提醒时间仍已过期，请改为未来，或关闭提醒后保存。")
        } catch {
            return isCurrent(operation) ? error.localizedDescription : AssistantReminderError.inactiveSession.localizedDescription
        }
    }

    private func setStatus(_ task: AssistantTask, to status: AssistantTaskStatus, confirmedEnd: Bool = false) {
        guard isCurrentPage, !isOperating else { return }
        if status == .completed, isRepeatingPlan(task), !confirmedEnd {
            endingPlan = task
            return
        }
        guard AssistantOwnerIdentity.matches(task.userId, userId), let operation = beginOperation() else { return }
        Task {
            defer { finishOperation(operation) }
            do {
                try await AssistantReminderCoordinator.shared.updateTaskStatus(id: task.id, ownerId: userId, status: status, expectedTask: task)
                guard isCurrent(operation) else { return }
                reload()
                await refreshReminderStates()
            } catch AssistantReminderError.reactivationRequired(let snapshot) {
                if isCurrent(operation), AssistantOwnerIdentity.matches(snapshot.userId, userId) {
                    reactivationTarget = snapshot
                }
            } catch { if isCurrent(operation) { operationError = error.localizedDescription } }
        }
    }

    private func reopenWithoutReminder(_ snapshot: AssistantTask) {
        guard AssistantOwnerIdentity.matches(snapshot.userId, userId), let operation = beginOperation() else { return }
        Task {
            defer { finishOperation(operation) }
            do {
                try await AssistantReminderCoordinator.shared.reopenTaskWithoutReminder(snapshot, ownerId: userId)
                guard isCurrent(operation) else { return }
                reload()
                await refreshReminderStates()
            } catch { if isCurrent(operation) { operationError = error.localizedDescription } }
        }
    }

    private func deleteTask(_ task: AssistantTask) {
        guard AssistantOwnerIdentity.matches(task.userId, userId), let operation = beginOperation() else { return }
        pendingDeletion = nil
        Task {
            defer { finishOperation(operation) }
            do {
                try await AssistantReminderCoordinator.shared.deleteTask(id: task.id, ownerId: userId)
                guard isCurrent(operation) else { return }
                var pending = loadCloudTaskDeletionIDs()
                pending.insert(task.id)
                saveCloudTaskDeletionIDs(pending)
                reload()
                await refreshReminderStates()
            } catch { if isCurrent(operation) { operationError = error.localizedDescription } }
        }
    }

    private func consumeTaskDeepLink() {
        guard isCurrentPage, !isOperating, !isPresentingTaskDetails, repository.lastError == nil else { return }
        guard let id = appState.pendingAssistantTaskId else { return }
        appState.pendingAssistantTaskId = nil
        guard AssistantOwnerIdentity.matches(userId, auth.user?.id ?? "local-device"),
              let task = repository.tasks(for: userId).first(where: { $0.id == id }) else {
            operationError = AssistantLocalization.string("该任务已删除或不属于当前账号。")
            return
        }
        editor = TaskEditorDestination(task: task)
    }

    private func refreshReminderStates() async {
        guard isCurrentPage else { return }
        let run = UUID(), snapshot = repository.tasks(for: userId)
        refreshRunId = run
        let report = await AssistantReminderCoordinator.shared.reconcile(ownerId: userId)
        guard !Task.isCancelled, isCurrentPage, refreshRunId == run, repository.tasks(for: userId) == snapshot else { return }
        reminderStates = report.statesByTaskId
        reminderCoverage = report.coverageByTaskId
        reminderSnapshots = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        if !report.errors.isEmpty { operationError = report.errors.joined(separator: "\n") }
    }
}

@MainActor
struct AssistantMemoryEditor: View {
    let userId: String
    @ObservedObject private var auth = AuthService.shared
    let memory: AssistantMemory?
    let sourceMessageId: String?
    let onSave: (AssistantMemory, Bool) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var category: AssistantMemoryCategory
    @State private var allowsUse: Bool
    @State private var operationError: String?
    @State private var recordId = UUID().uuidString
    @State private var didSave = false
    @State private var editorOwnerId: String

    init(userId: String, memory: AssistantMemory?, initialText: String = "", sourceMessageId: String? = nil,
         onSave: @escaping (AssistantMemory, Bool) -> String?) {
        self.userId = userId; self.memory = memory; self.onSave = onSave
        _editorOwnerId = State(initialValue: userId)
        self.sourceMessageId = memory?.sourceMessageId ?? sourceMessageId
        _text = State(initialValue: memory?.text ?? initialText)
        _category = State(initialValue: memory?.category ?? .fact)
        _allowsUse = State(initialValue: memory.map { AssistantMemoryAuthorizationPolicy.allowsUse(of: $0) } ?? true)
    }

    var body: some View {
        NavigationStack {
            Group {
            if hasEditorOwner { Form {
                Section("内容") {
                    TextEditor(text: $text).frame(minHeight: 130).accessibilityLabel("记忆内容")
                    if hasBodyChanges, text.count > AssistantWorkspaceLimits.memoryText {
                        Text("记忆内容不能超过 20000 个字符，请编辑后保存。").font(.caption).foregroundStyle(.red)
                    }
                    if !hasBodyChanges, text.count > AssistantWorkspaceLimits.memoryText {
                        Text("旧正文超过当前输入上限；未修改正文时仍可保存授权或分类设置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("分类", selection: $category) {
                        ForEach(AssistantMemoryCategory.allCases, id: \.rawValue) { value in
                            Text(value.workspaceTitle).tag(value)
                        }
                    }
                    .frame(minHeight: 44)
                }
                Section("来源与授权") {
                    if let source = sourceMessageId, !source.isEmpty {
                        Text("来源消息：\(source)").textSelection(.enabled)
                    } else { Text("未关联来源消息") }
                    if let memory {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("已保存的授权状态").font(.caption2)
                            Text(memoryAuthorizationTitle(memory)).font(.caption)
                        }.foregroundStyle(.secondary)
                        HStack {
                            Text("创建于")
                            Text(memory.createdAt, format: .dateTime.year().month().day().hour().minute())
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("允许将此条作为长期记忆", isOn: $allowsUse).frame(minHeight: 44)
                    if allowsUse, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("空白记忆不能授权；可关闭授权后保存旧记录，或先补充正文。")
                            .font(.caption).foregroundStyle(.red)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("单条授权只表示允许被选择；全局和类别开关仍需开启，自定义 API 仍受目的地确认控制。")
                        Text("停用只会停止将此条作为长期记忆附加到后续请求，已发送的内容无法撤回。相同信息若已在会话历史中，仍可能随历史发送；可按需要删除相关会话或新建对话。")
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(saveTitle, action: save).frame(minHeight: 44)
                        .disabled(!canSave)
                }
            } } else { Text("当前账号或记忆已变化，请重新打开页面。").padding() }
            }
            .assistantNavigationTitle(memory == nil ? "添加记忆" : "编辑记忆")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.frame(minHeight: 44) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle, action: save).frame(minHeight: 44)
                        .disabled(!canSave)
                }
            }
            .tint(.caobaoPrimary)
            .assistantWorkspaceError($operationError)
        }
    }

    private func save() {
        guard isCurrentEditor else {
            operationError = AssistantLocalization.string("当前账号或记忆已变化，请重新打开页面。")
            return
        }
        guard canSave else { return }
        if let memory, !hasBodyChanges, category == memory.category,
           AssistantMemoryAuthorizationPolicy.consentForSave(original: memory, allowsUse: allowsUse) == memory.consent {
            dismiss()
            return
        }
        let value = text
        if hasBodyChanges {
            do { try AssistantWorkspaceValidation.validateMemoryText(value) }
            catch { operationError = error.localizedDescription; return }
        }
        let record = AssistantMemory(
            id: memory?.id ?? recordId, userId: userId, category: category, text: value,
            sourceMessageId: sourceMessageId,
            consent: AssistantMemoryAuthorizationPolicy.consentForSave(original: memory, allowsUse: allowsUse),
            status: memory?.status ?? .active, createdAt: memory?.createdAt ?? Date(), updatedAt: Date()
        )
        if let error = onSave(record, memory == nil) { operationError = error }
        else { didSave = true; dismiss() }
    }

    private var isCurrentEditor: Bool {
        hasEditorOwner && (memory == nil || memory?.status == .active)
    }
    private var hasEditorOwner: Bool {
        !userId.isEmpty && AssistantOwnerIdentity.matches(userId, editorOwnerId)
            && AssistantOwnerIdentity.matches(userId, auth.user?.id ?? "local-device")
            && (memory == nil || AssistantOwnerIdentity.matches(memory?.userId, userId))
    }

    private var hasBodyChanges: Bool {
        guard let memory else { return true }
        return !text.utf8.elementsEqual(memory.text.utf8)
    }

    private var canSave: Bool {
        guard isCurrentEditor, !didSave else { return false }
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !(blank && (hasBodyChanges || allowsUse))
    }

    private var saveTitle: LocalizedStringKey {
        guard let memory else { return allowsUse ? "保存并授权" : "保存但不授权" }
        let original = AssistantMemoryAuthorizationPolicy.allowsUse(of: memory)
        if !original, allowsUse { return "确认并授权" }
        if original, !allowsUse { return "保存并停用授权" }
        return "保存修改"
    }
}

private func memoryAuthorizationTitle(_ memory: AssistantMemory) -> LocalizedStringKey {
    LocalizedStringKey(memoryAuthorizationKey(memory))
}

private func memoryAuthorizationKey(_ memory: AssistantMemory) -> String {
    switch AssistantMemoryAuthorizationPolicy.state(for: memory) {
    case .authorized: return "已授权"
    case .unconfirmed: return "尚未确认授权"
    case .revoked: return "已停用授权"
    case .deleted: return "已删除，不再用于对话"
    }
}

struct AssistantTaskEditor: View {
    private enum RecurrenceKind: String { case once, daily, weekly, legacy }
    let userId: String
    @ObservedObject private var auth = AuthService.shared
    let task: AssistantTask?
    let sourceMessageId: String?
    let requiresApprovalForNewTask: Bool
    let allowsRecurrenceEditing: Bool
    let reactivatingTask: Bool
    let onSave: (AssistantTask, Bool) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var notes: String
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var timeZoneIdentifier: String
    @State private var reminderEnabled: Bool
    @State private var recurrenceKind: RecurrenceKind
    @State private var recurrenceWeekdays: Set<Int>
    @State private var editorEpoch = UUID()
    @State private var editorOwnerId: String
    @State private var isSaving = false
    @State private var operationError: String?
    @State private var recordId = UUID().uuidString

    init(userId: String, task: AssistantTask?, initialTitle: String = "", initialNotes: String = "",
         initialDueAt: Date? = nil, initialTimeZone: String? = nil, initialTaskId: String? = nil, sourceMessageId: String? = nil,
         requiresApprovalForNewTask: Bool = false, allowsRecurrenceEditing: Bool = true, reactivatingTask: Bool = false,
         onSave: @escaping (AssistantTask, Bool) async -> String?) {
        self.userId = userId; self.task = task; self.onSave = onSave
        _editorOwnerId = State(initialValue: userId)
        self.sourceMessageId = task?.sourceMessageId ?? sourceMessageId
        self.requiresApprovalForNewTask = requiresApprovalForNewTask
        self.allowsRecurrenceEditing = allowsRecurrenceEditing
        self.reactivatingTask = reactivatingTask
        _recordId = State(initialValue: initialTaskId ?? UUID().uuidString)
        _title = State(initialValue: task?.title ?? initialTitle)
        _notes = State(initialValue: task?.instructions ?? initialNotes)
        let proposedDueAt = task == nil ? initialDueAt : nil
        _hasDueDate = State(initialValue: (task?.dueAt ?? proposedDueAt) != nil)
        let initialDate = task?.dueAt ?? proposedDueAt ?? Date()
        _dueDate = State(initialValue: initialDate)
        let displayedTimeZone = task?.timeZone ?? initialTimeZone ?? AssistantTaskTimeZonePolicy.defaultIdentifier
        _timeZoneIdentifier = State(initialValue: displayedTimeZone)
        _reminderEnabled = State(initialValue: task?.reminderEnabled == true)
        let parsed = try? AssistantTaskRecurrence.parse(task?.recurrenceRule)
        let initialKind: RecurrenceKind
        switch parsed {
        case .some(.none): initialKind = .once
        case .some(.daily): initialKind = .daily
        case .some(.weekly): initialKind = .weekly
        case nil: initialKind = .legacy
        }
        _recurrenceKind = State(initialValue: initialKind)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = (try? AssistantTaskTimeZonePolicy.timeZone(for: displayedTimeZone)) ?? TimeZone(secondsFromGMT: 0)!
        let isoDay = (calendar.component(.weekday, from: initialDate) + 5) % 7 + 1
        if case .some(.weekly(let days)) = parsed { _recurrenceWeekdays = State(initialValue: days) }
        else { _recurrenceWeekdays = State(initialValue: [isoDay]) }
    }

    var body: some View {
        NavigationStack {
            Group {
            if hasEditorOwner { Form {
                if reactivatingTask {
                    Section {
                        Text("保存后将恢复为待处理。请将提醒时间改为未来，或关闭旧提醒；取消不会修改任务。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("任务内容") {
                    TextField("任务标题", text: $title, axis: .vertical).frame(minHeight: 44)
                        .accessibilityLabel("任务标题")
                    TextEditor(text: $notes).frame(minHeight: 110).accessibilityLabel("任务说明")
                    if hasContentChanges, title.count > AssistantWorkspaceLimits.taskTitle {
                        Text("任务标题不能超过 200 个字符，请编辑后保存。").font(.caption).foregroundStyle(.red)
                    }
                    if hasContentChanges, notes.count > AssistantWorkspaceLimits.taskNotes {
                        Text("任务说明不能超过 20000 个字符，请编辑后保存。").font(.caption).foregroundStyle(.red)
                    }
                    if !hasContentChanges, title.count > AssistantWorkspaceLimits.taskTitle || notes.count > AssistantWorkspaceLimits.taskNotes {
                        Text("旧正文超过当前输入上限；未修改正文时仍可保存时区或提醒设置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let source = sourceMessageId {
                    Section("来源与授权") {
                        Text("来源消息：\(source)").textSelection(.enabled)
                        Text("请确认任务标题和说明。保存仅创建待办，不会执行消息中的操作；日期和提醒由你自行设置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if allowsRecurrenceEditing { recurrenceSection }
                timingSection
                if let task {
                    Section("当前状态") { Label(task.status.workspaceTitle, systemImage: task.status.workspaceIcon) }
                }
                Section {
                    Button("保存待办", action: save).frame(minHeight: 44)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || userId.isEmpty || isSaving)
                }
            } } else { Text("当前账号已变化，请重新打开页面。").padding() }
            }
            .disabled(isSaving || !hasEditorOwner)
            .assistantNavigationTitle(reactivatingTask ? "修改提醒并恢复任务" : (task == nil ? "添加任务" : "编辑任务"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.frame(minHeight: 44).disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).frame(minHeight: 44)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasEditorOwner || isSaving)
                }
            }
            .tint(.caobaoPrimary)
            .assistantWorkspaceError($operationError)
            .interactiveDismissDisabled(isSaving)
            .onDisappear { editorEpoch = UUID() }
            .onChange(of: AssistantOwnerIdentity.ownerKey(auth.user?.id ?? "local-device")) { _ in editorEpoch = UUID() }
            .onChange(of: AssistantOwnerIdentity.ownerKey(userId)) { _ in editorEpoch = UUID() }
            .onChange(of: hasDueDate) { enabled in if !enabled { reminderEnabled = false } }
            .onChange(of: recurrenceKind) { kind in
                if kind == .daily || kind == .weekly { hasDueDate = true }
            }
            .overlay { if isSaving { ProgressView("正在保存任务…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        }
    }

    private var timingSection: some View {
        Section {
            NavigationLink {
                AssistantTimeZonePicker(selection: $timeZoneIdentifier, title: "任务时区",
                    supportedIdentifiers: AssistantTaskTimeZonePolicy.supportedTimeZoneIdentifiers)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("任务时区")
                    Text(timeZoneIdentifier.isEmpty ? AssistantLocalization.string("请选择有效时区") : timeZoneIdentifier)
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(minHeight: 44)
            }
            .accessibilityLabel("选择任务时区")
            .accessibilityValue(timeZoneIdentifier)
            if editorTimeZone == nil {
                Text("任务时区无效，请选择有效的地区时区后保存。")
                    .font(.caption).foregroundStyle(.red)
            }
            if !hasRepeatingSelection || !hasDueDate {
                Toggle(hasRepeatingSelection ? LocalizedStringKey("设置重复时间") : LocalizedStringKey("设置到期时间"), isOn: $hasDueDate)
                    .frame(minHeight: 44)
            }
            if hasDueDate {
                if let zone = editorTimeZone {
                    DatePicker(selection: $dueDate, displayedComponents: hasRepeatingSelection ? [.hourAndMinute] : [.date, .hourAndMinute]) {
                        Text(hasRepeatingSelection ? LocalizedStringKey("重复时间") :
                            (recurrenceKind == .legacy ? LocalizedStringKey("保存的参考日期") : LocalizedStringKey("到期时间")))
                    }
                        .environment(\.timeZone, zone)
                        .frame(minHeight: 44)
                    .accessibilityLabel(hasRepeatingSelection ? Text("所选时区的重复时分") :
                        (recurrenceKind == .legacy ? Text("保存的参考日期") : Text("任务到期日期和时间")))
                    Text("显示时区：\(timeZoneIdentifier)").font(.caption).foregroundStyle(.secondary)
                }
                Toggle(hasRepeatingSelection ? LocalizedStringKey("开启重复本地提醒") :
                    (recurrenceKind == .legacy ? LocalizedStringKey("开启本地提醒") : LocalizedStringKey("开启一次性本地提醒")), isOn: $reminderEnabled)
                    .frame(minHeight: 44)
                    .accessibilityLabel(hasRepeatingSelection ? Text("开启此计划的重复本地提醒") :
                        (recurrenceKind == .legacy ? Text("开启本地提醒") : Text("开启此任务的一次性本地提醒")))
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if recurrenceKind == .legacy {
                    Text("旧规则未被解释，下方日期仅是保存的参考值。请明确选择支持的重复方式后再安排提醒。")
                } else if hasRepeatingSelection {
                    Text("切换时区会重新显示保存时间的当地时分，并改变后续重复安排；请检查重复时间再保存。")
                } else {
                    Text("切换时区只改变日期的显示方式，到期时刻保持不变；请直接编辑日期来调整到期时间。")
                }
                Text("只有开启提醒并点击保存才会请求通知权限。锁屏默认只显示通用提示，提醒可能受系统设置影响，不保证送达。普通到期时间不触发提醒，也不执行后台任务。")
            }
        }
    }

    private func save() {
        guard hasEditorOwner else { return }
        let value = titleForSave
        let details = instructionsForSave
        if hasContentChanges {
            do { try AssistantWorkspaceValidation.validateTask(title: value, instructions: details) }
            catch { operationError = error.localizedDescription; return }
        }
        let zone: String
        do { zone = try AssistantTaskTimeZonePolicy.validatedIdentifier(timeZoneIdentifier) }
        catch { operationError = error.localizedDescription; return }
        let rule: String?
        do {
            rule = try recurrenceRuleForSave()
            if let parsed = try? AssistantTaskRecurrence.parse(rule), parsed.isRepeating {
                guard hasDueDate else {
                    operationError = AssistantLocalization.string("请先设置任务时间，再启用重复。"); return
                }
                _ = try parsed.nextOccurrences(after: Date(), time: dueDate, timeZoneIdentifier: zone, limit: 1)
            }
        } catch { operationError = error.localizedDescription; return }
        let record = AssistantTask(
            id: task?.id ?? recordId, userId: userId, title: value,
            instructions: details, dueAt: hasDueDate ? dueDate : nil,
            timeZone: zone,
            recurrenceRule: rule, requiresApproval: task?.requiresApproval ?? requiresApprovalForNewTask,
            status: reactivatingTask ? .active : (task?.status ?? .active), createdAt: task?.createdAt ?? Date(), updatedAt: Date(),
            reminderEnabled: hasDueDate && reminderEnabled, sourceMessageId: sourceMessageId
        )
        guard !isSaving else { return }
        isSaving = true
        let sourceEpoch = editorEpoch
        Task {
            defer { if editorEpoch == sourceEpoch { isSaving = false } }
            let failure = await onSave(record, task == nil)
            guard editorEpoch == sourceEpoch, hasEditorOwner else { return }
            if let failure { operationError = failure }
            else { dismiss() }
        }
    }

    private var hasEditorOwner: Bool {
        !userId.isEmpty && AssistantOwnerIdentity.matches(userId, editorOwnerId)
            && AssistantOwnerIdentity.matches(userId, auth.user?.id ?? "local-device")
            && (task == nil || AssistantOwnerIdentity.matches(task?.userId, userId))
    }

    private var titleForSave: String {
        if let task, title == task.title { return task.title }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasRepeatingSelection: Bool { recurrenceKind == .daily || recurrenceKind == .weekly }

    private var canPreserveLegacyRule: Bool {
        guard let raw = task?.recurrenceRule else { return false }
        return (try? AssistantTaskRecurrence.parse(raw)) == nil
    }

    private func recurrenceRuleForSave() throws -> String? {
        if recurrenceKind == .legacy { return task?.recurrenceRule }
        let value: AssistantTaskRecurrence
        switch recurrenceKind {
        case .once: value = .none
        case .daily: value = .daily
        case .weekly: value = .weekly(recurrenceWeekdays)
        case .legacy: return task?.recurrenceRule
        }
        let canonical = try value.validatedCanonicalRule()
        if let task, let original = try? AssistantTaskRecurrence.parse(task.recurrenceRule), original == value {
            return task.recurrenceRule
        }
        return canonical
    }

    private var recurrenceSection: some View {
        Section {
            Picker("重复方式", selection: $recurrenceKind) {
                Text("不重复").tag(RecurrenceKind.once)
                Text("每天").tag(RecurrenceKind.daily)
                Text("每周").tag(RecurrenceKind.weekly)
                if canPreserveLegacyRule { Text("保留旧规则（暂不支持）").tag(RecurrenceKind.legacy) }
            }.frame(minHeight: 44)
            if recurrenceKind == .weekly {
                ForEach(1...7, id: \.self) { day in
                    Toggle(isOn: Binding(get: { recurrenceWeekdays.contains(day) }, set: { selected in
                        if selected { recurrenceWeekdays.insert(day) } else { recurrenceWeekdays.remove(day) }
                    })) { Text(weekdayTitle(day)) }.frame(minHeight: 44)
                }
                if recurrenceWeekdays.isEmpty {
                    Text("每周重复至少选择一天，且星期必须有效。").font(.caption).foregroundStyle(.red)
                }
            }
            if recurrenceKind == .legacy, let raw = task?.recurrenceRule {
                Text(raw).font(.caption.monospaced()).textSelection(.enabled).lineLimit(4)
                Text("旧重复规则暂不支持。选择不重复可移除，或明确选择新的重复方式；保存前不会修改原规则。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("重复计划") } footer: {
            if hasRepeatingSelection {
                VStack(alignment: .leading, spacing: 8) {
                    Text("重复计划只使用所选时区的时分，从下一次匹配开始；日期不是未来起始门槛。结束任务会结束整个重复计划。")
                    Text("未开启提醒不会发送通知。安静时段关闭时交给系统持续重复；开启时逐次延后并预排后续 7 次，需要打开应用补排，列表会显示实际覆盖截止。系统设置可能影响送达。")
                }
            } else if recurrenceKind == .legacy {
                Text("旧规则未被解释，下方日期仅是保存的参考值。请明确选择支持的重复方式后再安排提醒。")
            } else {
                Text("一次性任务使用完整到期日期。由重复改为不重复时，请重新检查日期和提醒开关。")
            }
        }
    }

    private func weekdayTitle(_ day: Int) -> LocalizedStringKey {
        switch day {
        case 1: return "星期一"
        case 2: return "星期二"
        case 3: return "星期三"
        case 4: return "星期四"
        case 5: return "星期五"
        case 6: return "星期六"
        default: return "星期日"
        }
    }

    private var instructionsForSave: String? {
        if let task, notes == (task.instructions ?? "") { return task.instructions }
        return notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes
    }

    private var hasContentChanges: Bool {
        guard let task else { return true }
        return titleForSave != task.title || instructionsForSave != task.instructions
    }

    private var editorTimeZone: TimeZone? {
        try? AssistantTaskTimeZonePolicy.timeZone(for: timeZoneIdentifier)
    }
}

private struct WorkspaceEmptyState: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Color.caobaoPrimary)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .accessibilityElement(children: .combine)
    }
}

private struct MemoryEditorDestination: Identifiable { let id = UUID(); let memory: AssistantMemory? }
private struct TaskEditorDestination: Identifiable {
    let id = UUID()
    let task: AssistantTask?
    var isReactivation = false
}
private struct MemoryExportSnapshot: Encodable {
    let formatVersion: Int
    let userId: String
    let exportedAt: Date
    let memoryEnabled: Bool
    let excludedMemoryCategories: [AssistantMemoryCategory]
    let memories: [AssistantMemory]
}

private extension AssistantMemoryCategory {
    var workspaceTitle: LocalizedStringKey {
        switch self {
        case .fact: return "个人事实"
        case .preference: return "偏好"
        case .importantDate: return "重要日期"
        case .followUp: return "待跟进事项"
        case .sharedContext: return "共同上下文"
        }
    }
}

private extension AssistantTaskStatus {
    var workspaceTitle: LocalizedStringKey {
        switch self {
        case .active: return "待处理"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        }
    }
    var workspaceIcon: String {
        switch self {
        case .active: return "circle"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }
}

private extension View {
    func assistantWorkspaceError(_ error: Binding<String?>) -> some View {
        alert("操作未完成", isPresented: Binding(
            get: { error.wrappedValue != nil },
            set: { if !$0 { error.wrappedValue = nil } }
        )) {
            Button("知道了", role: .cancel) { error.wrappedValue = nil }
        } message: { Text(error.wrappedValue ?? "") }
    }
}

// MARK: - Custom characters

/// Owner-scoped custom role management. The server remains authoritative for
/// versions and tombstones; the view never sends an owner id in the request.
@MainActor
struct AssistantCharactersView: View {
    let ownerId: String
    @ObservedObject private var auth = AuthService.shared
    @State private var characters: [CloudCharacter] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var editor: CharacterEditorDestination?
    @State private var pendingDelete: CloudCharacter?

    private struct CharacterEditorDestination: Identifiable {
        let id = UUID()
        let character: CloudCharacter?
    }

    private var isCurrentOwner: Bool {
        AssistantOwnerIdentity.matches(ownerId, auth.user?.id ?? "local-device")
    }

    var body: some View {
        List {
            if !auth.isLoggedIn {
                WorkspaceEmptyState(icon: "person.crop.circle.badge.xmark", title: "请先登录", detail: "登录后才能管理云端自定义角色。")
            } else if isLoading && characters.isEmpty {
                ProgressView("正在读取角色…")
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if characters.isEmpty {
                WorkspaceEmptyState(icon: "person.2.wave.2", title: "还没有自定义角色", detail: "创建角色后，可以在后续角色对话功能中使用。")
            } else {
                ForEach(characters) { character in
                    characterRow(character)
                }
            }

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if auth.isLoggedIn {
                Button {
                    editor = CharacterEditorDestination(character: nil)
                } label: {
                    Label("新建角色", systemImage: "plus")
                }
                .disabled(!isCurrentOwner || isLoading)
            }
        }
        .assistantNavigationTitle("自定义角色")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("刷新") { Task { await loadCharacters() } }
                    .disabled(!isCurrentOwner || isLoading)
            }
        }
        .sheet(item: $editor) { destination in
            AssistantCharacterEditor(character: destination.character) { request in
                try await saveCharacter(request)
            }
        }
        .confirmationDialog("删除这个自定义角色？", isPresented: pendingDeletePresented,
                            titleVisibility: .visible, presenting: pendingDelete) { character in
            Button("删除角色", role: .destructive) {
                pendingDelete = nil
                Task { await deleteCharacter(character) }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("删除会写入服务端墓碑，并阻止旧设备重新激活这个角色。")
        }
        .onAppear { Task { await loadCharacters() } }
        .onChange(of: AssistantOwnerIdentity.ownerKey(auth.user?.id ?? "local-device")) { _ in
            characters = []
            Task { await loadCharacters() }
        }
    }

    private var pendingDeletePresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    @ViewBuilder
    private func characterRow(_ character: CloudCharacter) -> some View {
        HStack(spacing: 12) {
            Text(character.avatar?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? character.avatar! : "✨")
                .font(.title2)
                .frame(width: 34, height: 34)
                .background(Color.caobaoPrimary.opacity(0.12), in: Circle())

            Button {
                editor = CharacterEditorDestination(character: character)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(character.name).font(.headline)
                        if !character.enabled {
                            Text("已停用").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if let description = character.description, !description.isEmpty {
                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        Text("角色提示词已保存").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                pendingDelete = character
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!isCurrentOwner || isLoading)
        }
        .contentShape(Rectangle())
    }

    private func loadCharacters() async {
        guard isCurrentOwner, auth.isLoggedIn else {
            characters = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let token = try await auth.validAccessToken()
            guard isCurrentOwner else { return }
            let response = try await APIService.shared.listCloudCharacters(token: token, limit: 100)
            guard isCurrentOwner else { return }
            characters = response.items.filter { $0.deletedAt == nil }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "暂时无法读取角色，请登录后重试。"
        }
    }

    private func saveCharacter(_ request: CloudCharacterUpsertRequest) async throws {
        guard isCurrentOwner else { throw CancellationError() }
        let token = try await auth.validAccessToken()
        guard isCurrentOwner else { throw CancellationError() }
        let saved = try await APIService.shared.upsertCloudCharacter(token: token, request: request)
        guard isCurrentOwner else { return }
        if let index = characters.firstIndex(where: { $0.id == saved.id }) {
            characters[index] = saved
        } else {
            characters.append(saved)
        }
        errorMessage = nil
    }

    private func deleteCharacter(_ character: CloudCharacter) async {
        do {
            guard isCurrentOwner else { return }
            let token = try await auth.validAccessToken()
            guard isCurrentOwner else { return }
            _ = try await APIService.shared.deleteCloudCharacter(token: token, id: character.id, expectedVersion: character.version)
            guard isCurrentOwner else { return }
            characters.removeAll { $0.id == character.id }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "删除失败，角色版本可能已变化；请刷新后重试。"
            await loadCharacters()
        }
    }
}

@MainActor
struct AssistantCharacterEditor: View {
    let character: CloudCharacter?
    let onSave: (CloudCharacterUpsertRequest) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var avatar: String
    @State private var description: String
    @State private var systemPrompt: String
    @State private var greeting: String
    @State private var language: String
    @State private var memoryScope: String
    @State private var allowGlobalMemory: Bool
    @State private var enabled: Bool
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(character: CloudCharacter?, onSave: @escaping (CloudCharacterUpsertRequest) async throws -> Void) {
        self.character = character
        self.onSave = onSave
        _name = State(initialValue: character?.name ?? "")
        _avatar = State(initialValue: character?.avatar ?? "✨")
        _description = State(initialValue: character?.description ?? "")
        _systemPrompt = State(initialValue: character?.systemPrompt ?? "")
        _greeting = State(initialValue: character?.greeting ?? "")
        _language = State(initialValue: character?.language ?? "zh-Hans")
        _memoryScope = State(initialValue: character?.memoryScope ?? "private")
        _allowGlobalMemory = State(initialValue: character?.allowGlobalMemory ?? false)
        _enabled = State(initialValue: character?.enabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $name)
                    TextField("头像（emoji）", text: $avatar)
                    TextField("简介", text: $description, axis: .vertical)
                    Picker("语言", selection: $language) {
                        Text("简体中文").tag("zh-Hans")
                        Text("English").tag("en")
                        Text("跟随系统").tag("system")
                    }
                    Toggle("启用角色", isOn: $enabled)
                }
                Section("角色行为") {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 140)
                        .overlay(alignment: .topLeading) {
                            if systemPrompt.isEmpty {
                                Text("写下角色的身份、语气和边界…")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                    TextField("首次问候（可选）", text: $greeting, axis: .vertical)
                }
                Section("记忆范围") {
                    Picker("范围", selection: $memoryScope) {
                        Text("仅角色记忆").tag("private")
                        Text("当前工作区").tag("workspace")
                    }
                    Toggle("允许使用全局记忆", isOn: $allowGlobalMemory)
                    Text("默认隔离角色记忆；只有明确开启后才允许注入全局记忆。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section { Text(verbatim: errorMessage).foregroundStyle(.red).font(.caption) }
                }
            }
            .assistantNavigationTitle(character == nil ? "新建角色" : "编辑角色")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 80 else {
            errorMessage = "角色名称不能为空，且不能超过 80 个字符。"
            return
        }
        guard !trimmedPrompt.isEmpty, trimmedPrompt.count <= 12_000 else {
            errorMessage = "角色提示词不能为空，且不能超过 12,000 个字符。"
            return
        }
        isSaving = true
        defer { isSaving = false }
        let request = CloudCharacterUpsertRequest(
            id: character?.id ?? UUID().uuidString,
            name: trimmedName,
            avatar: avatar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : avatar.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: trimmedPrompt,
            greeting: greeting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : greeting.trimmingCharacters(in: .whitespacesAndNewlines),
            language: language.isEmpty ? nil : language,
            memoryScope: memoryScope,
            allowGlobalMemory: allowGlobalMemory,
            enabled: enabled,
            expectedVersion: character?.version
        )
        do {
            try await onSave(request)
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "保存失败，请检查登录状态或稍后重试。"
        }
    }
}
