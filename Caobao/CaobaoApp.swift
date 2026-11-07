import SwiftUI
import AuthenticationServices
import Combine
#if canImport(StoreKit)
import StoreKit
#endif

@main
struct CaobaoApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(AssistantApplicationDelegate.self) private var applicationDelegate
#endif
    @StateObject private var appState = AppState()
    @StateObject private var authService = AuthService.shared
    @AppStorage("colorScheme") private var colorScheme = "system"
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Start StoreKit's transaction stream at app launch. The store keeps
        // unfinished updates until an authenticated server configuration is
        // available, so this does not depend on opening the subscription page.
        _ = AssistantSubscriptionStore.shared
    }
    
    var body: some Scene {
        #if os(macOS)
        // macOS 使用 WindowGroup + Sidebar
        WindowGroup {
            Group {
                if authService.isLoggedIn || appState.assistantMode == "byok" {
                    MacContentView()
                        .environmentObject(appState)
                        .frame(minWidth: 900, minHeight: 600)
                        .preferredColorScheme(
                            colorScheme == "dark" ? .dark :
                            colorScheme == "light" ? .light : nil
                        )
                } else {
                    LoginView()
                        .environmentObject(appState)
                        .preferredColorScheme(
                            colorScheme == "dark" ? .dark :
                            colorScheme == "light" ? .light : nil
                        )
                }
            }
            .environment(\.locale, assistantLocale)
            .safeAreaInset(edge: .top, spacing: 0) { deletionNoticeBanner }
            .onOpenURL { handleAssistantDeepLink($0) }
            .onReceive(NotificationCenter.default.publisher(for: .loginSuccess)) { _ in
                consumePendingAssistantDeepLink()
            }
            .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
                // Keep macOS in the same Apple credential-revocation path as
                // iOS so a revoked identity cannot leave a trusted session
                // visible in the desktop workspace.
                authService.logout()
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建对话") {
                    NotificationCenter.default.post(name: .newChat, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            
            CommandGroup(replacing: .sidebar) {
                Button("显示边栏") {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        
        #else
        // iOS/iPadOS 使用 TabView
        WindowGroup {
            Group {
                if authService.isLoggedIn || appState.assistantMode == "byok" {
                    ContentView()
                        .environmentObject(appState)
                        .tint(.green)
                        .environment(\.locale, assistantLocale)
                        .preferredColorScheme(
                            colorScheme == "dark" ? .dark :
                            colorScheme == "light" ? .light : nil
                        )
                } else {
                    LoginView()
                        .environmentObject(appState)
                        .preferredColorScheme(
                            colorScheme == "dark" ? .dark :
                            colorScheme == "light" ? .light : nil
                        )
                }
            }
            .environment(\.locale, assistantLocale)
            .safeAreaInset(edge: .top, spacing: 0) { deletionNoticeBanner }
            .onOpenURL { handleAssistantDeepLink($0) }
            .task(id: AssistantOwnerIdentity.ownerKey(appState.assistantOwnerId)) {
                let owner = appState.assistantOwnerId
                guard !Task.isCancelled else { return }
                AssistantNotificationRouter.shared.install()
                if let taskId = AssistantNotificationRouter.shared.takePendingTask() {
                    appState.pendingAssistantTaskId = taskId
                    appState.selectedTab = .fortune
                }
                if let runId = AssistantNotificationRouter.shared.takePendingProactiveRun() {
                    appState.pendingAssistantProactiveRunId = runId
                    appState.selectedTab = .home
                    appState.assistantHomePath = [.proactive]
                }
                _ = await AssistantReminderCoordinator.shared.activate(ownerId: owner)
                await AssistantNotificationRouter.shared.registerRemoteNotificationsIfAuthorized()
                AssistantRemoteNotificationCoordinator.shared.appDidBecomeActive()
                if !Task.isCancelled, AssistantOwnerIdentity.matches(owner, appState.assistantOwnerId), AssistantOwnerIdentity.matches(owner, authService.user?.id ?? "local-device") {
                    NotificationCenter.default.post(name: Notification.Name("assistant.reminders.changed"), object: nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AssistantNotificationRouter.openTaskNotification)) { notification in
                if let taskId = AssistantNotificationRouter.shared.takePendingTask() {
                    appState.pendingAssistantTaskId = taskId
                    appState.selectedTab = .fortune
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AssistantNotificationRouter.openProactiveNotification)) { _ in
                if let runId = AssistantNotificationRouter.shared.takePendingProactiveRun() {
                    appState.pendingAssistantProactiveRunId = runId
                    appState.selectedTab = .home
                    appState.assistantHomePath = [.proactive]
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
                authService.logout()
            }
            .onReceive(NotificationCenter.default.publisher(for: .loginSuccess)) { _ in
                consumePendingAssistantDeepLink()
                Task { @MainActor in
                    await AssistantNotificationRouter.shared.registerRemoteNotificationsIfAuthorized()
                    AssistantRemoteNotificationCoordinator.shared.appDidBecomeActive()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .logoutSuccess)) { _ in
                AssistantRemoteNotificationCoordinator.shared.invalidate()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task {
                        await appState.refreshAssistantState()
                        await authService.refreshDeletionServerStatus()
                        await AssistantNotificationRouter.shared.registerRemoteNotificationsIfAuthorized()
                        AssistantRemoteNotificationCoordinator.shared.appDidBecomeActive()
                        let owner = appState.assistantOwnerId
                        _ = await AssistantReminderCoordinator.shared.reconcile(ownerId: owner)
                        if !Task.isCancelled, AssistantOwnerIdentity.matches(owner, appState.assistantOwnerId), AssistantOwnerIdentity.matches(owner, authService.user?.id ?? "local-device") {
                            NotificationCenter.default.post(name: Notification.Name("assistant.reminders.changed"), object: owner)
                        }
                    }
                }
                else { ChatViewModel.shared.persistDraft() }
            }
        }
        #endif
    }
    @ViewBuilder
    private var deletionNoticeBanner: some View {
        if let notice = authService.deletionNotice {
            AssistantDeletionNoticeView(notice: notice, isRetrying: authService.isRetryingLocalCleanup,
                onDismiss: { authService.dismissDeletionNotice() },
                onRetry: { Task { await authService.retryPendingLocalCleanup() } })
        }
    }

    private var assistantLocale: Locale {
        appState.assistantLanguage == "system" ? .autoupdatingCurrent : Locale(identifier: appState.assistantLanguage)
    }

    @MainActor
    private func handleAssistantDeepLink(_ url: URL) {
        guard let link = AssistantDeepLink(url: url) else { return }
        guard authService.isLoggedIn else {
            appState.pendingAssistantDeepLinkURL = url.absoluteString
            return
        }
        applyAssistantDeepLink(link)
    }

    @MainActor
    private func consumePendingAssistantDeepLink() {
        guard authService.isLoggedIn,
              let raw = appState.pendingAssistantDeepLinkURL,
              let url = URL(string: raw),
              let link = AssistantDeepLink(url: url) else { return }
        appState.pendingAssistantDeepLinkURL = nil
        applyAssistantDeepLink(link)
    }

    @MainActor
    private func applyAssistantDeepLink(_ link: AssistantDeepLink) {
        let owner = appState.assistantOwnerId
        switch link {
        case .conversation(let id):
            #if os(macOS)
            appState.pendingAssistantConversationId = id
            appState.selectedTab = .chat
            NotificationCenter.default.post(name: .macOpenConversation, object: nil,
                                            userInfo: ["conversationId": id])
            #else
            appState.assistantHomePath = [.historyConversation(id: id, ownerId: owner)]
            appState.selectedTab = .home
            #endif
        case .task(let id):
            appState.pendingAssistantTaskId = id
            appState.selectedTab = .fortune
        case .proactive(let id):
            appState.pendingAssistantProactiveRunId = id
            #if os(macOS)
            appState.selectedTab = .home
            NotificationCenter.default.post(name: .macOpenProactive, object: nil)
            #else
            appState.selectedTab = .home
            appState.assistantHomePath = [.proactive]
            #endif
        }
    }

}

private enum AssistantDeepLink: Equatable {
    case conversation(String)
    case task(String)
    case proactive(String)

    init?(url: URL) {
        guard url.scheme?.lowercased() == "https",
              ["caobao.chat", "www.caobao.chat"].contains(url.host?.lowercased() ?? "") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2,
              let rawID = parts.last,
              let id = rawID.removingPercentEncoding,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id.utf8.count <= 256 else { return nil }
        switch parts[0].lowercased() {
        case "conversation": self = .conversation(id)
        case "task": self = .task(id)
        case "proactive": self = .proactive(id)
        default: return nil
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let newChat = Notification.Name("newChat")
    static let clearChat = Notification.Name("clearChat")
    static let conversationHistoryChanged = Notification.Name("conversationHistoryChanged")
    static let macOpenConversation = Notification.Name("macOpenConversation")
    static let macOpenProactive = Notification.Name("macOpenProactive")
    static let assistantPrompt = Notification.Name("assistantPrompt")
    static let assistantProactiveChanged = Notification.Name("assistantProactiveChanged")
}

// MARK: - App State
@MainActor
class AppState: ObservableObject {
    @Published var isLoggedIn = false
    @Published var user: User?
    @Published var userSettings = UserSettings()
    @Published var selectedTab: AppTab = .home
    @Published var userStats = UserStats()
    @Published var pendingAssistantPrompt: String?
    @Published var pendingAssistantDeepLinkURL: String?
    @Published var pendingAssistantConversationId: String?
    @Published var pendingAssistantTaskId: String?
    @Published var pendingAssistantProactiveRunId: String?
    @Published var assistantHomePath: [AssistantHomeRoute] = []
    @Published var isShowingAssistantSettings = false

    // A balance exists only after the server verifies it for this account.
    @Published private(set) var dailyQuotaRemaining: Int?
    @Published private(set) var quotaStatusMessage: String?
    @Published private(set) var quotaVerifiedAt: Date?
    @Published private(set) var quotaServiceDay: String?
    @Published private(set) var quotaNextResetAt: Date?
    @Published private(set) var subscriptionBalance: AssistantSubscriptionBalance?
    @Published private(set) var subscriptionQuotaVerifiedAt: Date?
    @Published private(set) var isRefreshingEntitlements = false
    @Published var serviceRegion = ""
    @Published var assistantMode = "platform"
    /// Server-owned proactive frequency. Per-device quiet hours and companion
    /// switches remain in AssistantProactiveStore, while this value follows
    /// the account across devices.
    @Published var proactiveLevel = "important"
    @Published var regionConfirmed = false
    @Published var assistantLanguage = "system" {
        didSet { AssistantLocalization.setLanguage(assistantLanguage) }
    }
    @Published private(set) var platformModelId = ""
    @Published private(set) var modelCatalog: AssistantModelCatalogResponse?
    @Published private(set) var modelCatalogStatusMessage: String?
    @Published private(set) var isRefreshingModels = false
    private var modelCatalogVerifiedAt: Date?
    private let modelClient = AssistantModelCatalogClient(baseURL: APIConfig.assistantBaseURL)
    private let preferencesClient = AssistantPreferencesClient(baseURL: APIConfig.assistantBaseURL)
    private var modelRefreshTask: Task<Void, Never>?
    private var modelRefreshId: UUID?
    private var modelRefreshRegion: String?
    private var preferencesRefreshTask: Task<Void, Never>?
    private var preferencesRefreshId: UUID?
    private var preferencesVerifiedAt: Date?

    private var boundOwnerId: String
    private var boundToken: String?
    private var authObservation: AnyCancellable?
    private var entitlementRefreshTask: Task<Void, Never>?
    private var entitlementRefreshId: UUID?
    private var lastSuccessfulRefreshAt: Date?
    private var lastFailedRefreshAt: Date?
    private let successRefreshInterval: TimeInterval = 60
    private let failureRefreshInterval: TimeInterval = 15
    private let quotaFreshnessInterval: TimeInterval = 300

    /// Use the authenticated owner, never the independent AppState.user copy.
    var assistantOwnerId: String { AuthService.shared.user?.id ?? "local-device" }

    init() {
        boundOwnerId = AuthService.shared.user?.id ?? "local-device"
        boundToken = AuthService.shared.token
        isLoggedIn = AuthService.shared.isLoggedIn
        user = AuthService.shared.user
        loadUserSettings()
        loadUserStats()
        loadAssistantPreferences()
        quotaStatusMessage = isLoggedIn ? "额度尚未验证" : "登录后领取每日额度"
        authObservation = AuthService.shared.objectWillChange.sink { [weak self] _ in
            // @Published emits before assignment; read the completed identity update.
            DispatchQueue.main.async { [weak self] in self?.synchronizeAuthIdentity() }
        }
    }

    deinit { entitlementRefreshTask?.cancel(); modelRefreshTask?.cancel(); preferencesRefreshTask?.cancel() }

    private func preferenceKey(_ name: String) -> String {
        "caobao.assistant.\(Data(boundOwnerId.utf8).base64EncodedString()).\(name)"
    }

    private func synchronizeAuthIdentity() {
        let auth = AuthService.shared
        let owner = auth.user?.id ?? "local-device"
        let previousOwner = boundOwnerId
        let ownerChanged = !AssistantOwnerIdentity.matches(owner, previousOwner)
        let identityChanged = ownerChanged || auth.token != boundToken
        isLoggedIn = auth.isLoggedIn
        user = auth.user
        guard identityChanged else { return }
#if os(iOS)
        // A refreshed access token must be able to re-register an already
        // observed APNs token without waiting for a new device callback.
        AssistantRemoteNotificationCoordinator.shared.appDidBecomeActive()
#endif
        entitlementRefreshTask?.cancel()
        entitlementRefreshTask = nil
        entitlementRefreshId = nil
        isRefreshingEntitlements = false
        boundOwnerId = owner
        boundToken = auth.token
        modelRefreshTask?.cancel()
        modelRefreshTask = nil
        modelRefreshId = nil
        modelRefreshRegion = nil
        modelCatalog = nil
        modelCatalogVerifiedAt = nil
        modelCatalogStatusMessage = nil
        isRefreshingModels = false
        preferencesRefreshTask?.cancel()
        preferencesRefreshTask = nil
        preferencesRefreshId = nil
        preferencesVerifiedAt = nil
        dailyQuotaRemaining = nil
        quotaVerifiedAt = nil
        quotaServiceDay = nil
        quotaNextResetAt = nil
        subscriptionBalance = nil
        subscriptionQuotaVerifiedAt = nil
        lastSuccessfulRefreshAt = nil
        lastFailedRefreshAt = nil
        quotaStatusMessage = auth.isLoggedIn ? "额度尚未验证" : "登录后领取每日额度"
        if ownerChanged {
            assistantHomePath = []
            isShowingAssistantSettings = false
            pendingAssistantPrompt = nil
            if previousOwner != "local-device" {
                pendingAssistantDeepLinkURL = nil
                pendingAssistantConversationId = nil
            }
            pendingAssistantTaskId = nil
            pendingAssistantProactiveRunId = nil
            selectedTab = .home
            loadUserSettings()
            loadUserStats()
            loadAssistantPreferences()
        }
    }

    func loadUserSettings() {
        let data = UserDefaults.standard.data(forKey: preferenceKey("userSettings"))
        userSettings = data.flatMap { try? JSONDecoder().decode(UserSettings.self, from: $0) }
            ?? UserSettings()
    }

    func saveUserSettings() {
        synchronizeAuthIdentity()
        if let data = try? JSONEncoder().encode(userSettings) {
            let defaults = UserDefaults.standard
            let previous = defaults.data(forKey: preferenceKey("userSettings"))
                .flatMap { try? JSONDecoder().decode(UserSettings.self, from: $0) }?.toxicLevel ?? UserSettings().toxicLevel
            defaults.set(data, forKey: preferenceKey("userSettings"))
            if previous != userSettings.toxicLevel {
                NotificationCenter.default.post(name: Notification.Name("assistant.generationConfigurationChanged"), object: assistantOwnerId)
            }
        }
    }

    func loadUserStats() {
        let data = UserDefaults.standard.data(forKey: preferenceKey("userStats"))
        userStats = data.flatMap { try? JSONDecoder().decode(UserStats.self, from: $0) }
            ?? UserStats()
    }

    func saveUserStats() {
        synchronizeAuthIdentity()
        if let data = try? JSONEncoder().encode(userStats) {
            UserDefaults.standard.set(data, forKey: preferenceKey("userStats"))
        }
    }

    func incrementChatCount() {
        synchronizeAuthIdentity()
        checkStreak()
        userStats.totalChats += 1
        userStats.lastActiveDate = Date()
        saveUserStats()
    }

    private func checkStreak() {
        let calendar = Calendar.current
        guard let lastDate = userStats.lastActiveDate else {
            userStats.streak = 1
            return
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastDate),
                                          to: calendar.startOfDay(for: Date())).day ?? 0
        if days == 1 { userStats.streak += 1 }
        else if days > 1 { userStats.streak = 1 }
    }

    func updateStats(from response: UserInfoResponse) {
        synchronizeAuthIdentity()
        if let chats = response.usageStats?["chat"]?.count { userStats.totalChats = chats }
        if let createdAt = response.user?.createdAt {
            let date = Date(timeIntervalSince1970: Double(createdAt) / 1000)
            userStats.usageDays = max(1, Calendar.current.dateComponents([.day], from: date,
                                                                       to: Date()).day ?? 1)
        }
        saveUserStats()
    }

    var serviceRegionLabel: String {
        switch serviceRegion {
        case "CN": return "中国大陆"
        case "INTL": return "海外"
        default: return "未选择"
        }
    }

    var assistantModeLabel: String { assistantMode == "byok" ? "自定义 API" : "CaoBao 平台" }

    func loadAssistantPreferences() {
        let defaults = UserDefaults.standard
        assistantLanguage = defaults.string(forKey: preferenceKey("language")) ?? "system"
        regionConfirmed = defaults.bool(forKey: preferenceKey("regionConfirmed"))
        let savedRegion = defaults.string(forKey: preferenceKey("serviceRegion")) ?? ""
        serviceRegion = regionConfirmed && ["CN", "INTL"].contains(savedRegion) ? savedRegion : ""
        let savedMode = defaults.string(forKey: preferenceKey("assistantMode")) ?? "platform"
        assistantMode = ["platform", "byok"].contains(savedMode) ? savedMode : "platform"
        let savedProactiveLevel = defaults.string(forKey: preferenceKey("proactiveLevel")) ?? "important"
        proactiveLevel = ["off", "important", "daily", "normal", "frequent"].contains(savedProactiveLevel)
            ? savedProactiveLevel : "important"
        platformModelId = savedPlatformModel(for: serviceRegion)
        // Historical global dailyQuotaRemaining/serviceDay values are not authoritative.
    }

    func saveAssistantPreferences() {
        synchronizeAuthIdentity()
        let defaults = UserDefaults.standard
        let changed = (defaults.string(forKey: preferenceKey("serviceRegion")) ?? "") != serviceRegion
            || (defaults.string(forKey: preferenceKey("assistantMode")) ?? "platform") != assistantMode
            || defaults.bool(forKey: preferenceKey("regionConfirmed")) != regionConfirmed
        defaults.set(serviceRegion, forKey: preferenceKey("serviceRegion"))
        defaults.set(assistantMode, forKey: preferenceKey("assistantMode"))
        defaults.set(proactiveLevel, forKey: preferenceKey("proactiveLevel"))
        defaults.set(regionConfirmed, forKey: preferenceKey("regionConfirmed"))
        platformModelId = savedPlatformModel(for: serviceRegion)
        if changed {
            NotificationCenter.default.post(name: Notification.Name("assistant.generationConfigurationChanged"), object: assistantOwnerId)
        }
    }

    func savedPlatformModel(for region: String) -> String {
        AssistantModelPreferences.selectedModel(ownerId: assistantOwnerId, region: region)
    }

    func savePlatformModel(_ modelId: String, for region: String) throws {
        try AssistantModelPreferences.save(modelId, ownerId: assistantOwnerId, region: region)
        if region == serviceRegion { platformModelId = modelId }
    }

    var isModelCatalogStale: Bool {
        guard let verified = modelCatalogVerifiedAt, modelCatalog != nil else { return true }
        let age = Date().timeIntervalSince(verified)
        return age < 0 || age >= 300
    }

    var currentModelLabel: String {
        if assistantMode == "byok" {
            let value = UserDefaults.standard.string(forKey: "assistant.byok.\(assistantOwnerId).model") ?? ""
            return value.isEmpty ? AssistantLocalization.string("未配置") : value
        }
        let catalog = !isModelCatalogStale && modelCatalog?.serviceRegion == serviceRegion ? modelCatalog : nil
        if !platformModelId.isEmpty {
            return catalog?.models.first(where: { $0.id == platformModelId })?.displayName ?? platformModelId
        }
        return catalog?.models.first(where: { $0.id == catalog?.defaultModelId })?.displayName
            ?? AssistantLocalization.string("自动（区域默认）")
    }

    func refreshModelCatalog(region requestedRegion: String? = nil, force: Bool = false) async {
        guard !Task.isCancelled else { return }
        let ownerAtEntry = assistantOwnerId
        let tokenAtEntry = AuthService.shared.token
        let region = requestedRegion ?? serviceRegion
        guard ["CN", "INTL"].contains(region) else { return }
        do { try await AuthService.shared.refreshIfNeeded() }
        catch {
            guard !(error is CancellationError), !Task.isCancelled, AssistantOwnerIdentity.matches(assistantOwnerId, ownerAtEntry),
                  AuthService.shared.token == tokenAtEntry else { return }
            synchronizeAuthIdentity()
            modelCatalog = nil; modelCatalogVerifiedAt = nil
            modelCatalogStatusMessage = error.localizedDescription
            return
        }
        guard !Task.isCancelled, AssistantOwnerIdentity.matches(assistantOwnerId, ownerAtEntry) else { return }
        synchronizeAuthIdentity()
        if let task = modelRefreshTask, modelRefreshRegion == region { await task.value; return }
        if !force, !isModelCatalogStale, modelCatalog?.serviceRegion == region { return }
        modelRefreshTask?.cancel()
        modelRefreshTask = nil; modelRefreshId = nil
        modelCatalog = nil; modelCatalogVerifiedAt = nil
        guard AuthService.shared.isLoggedIn, let token = AuthService.shared.token else {
            modelCatalogStatusMessage = AssistantLocalization.string("登录后可查看平台模型")
            isRefreshingModels = false
            return
        }
        let owner = assistantOwnerId
        let id = UUID()
        modelRefreshId = id; modelRefreshRegion = region
        isRefreshingModels = true; modelCatalogStatusMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.modelClient.fetch(accessToken: token, region: region)
                guard !Task.isCancelled, self.modelRefreshId == id, AssistantOwnerIdentity.matches(self.assistantOwnerId, owner),
                      AuthService.shared.token == token else { return }
                self.modelCatalog = result; self.modelCatalogVerifiedAt = Date()
            } catch {
                guard !Task.isCancelled, self.modelRefreshId == id, AssistantOwnerIdentity.matches(self.assistantOwnerId, owner),
                      AuthService.shared.token == token else { return }
                self.modelCatalog = nil; self.modelCatalogVerifiedAt = nil
                self.modelCatalogStatusMessage = error.localizedDescription
            }
            guard self.modelRefreshId == id else { return }
            self.isRefreshingModels = false; self.modelRefreshId = nil; self.modelRefreshTask = nil
        }
        modelRefreshTask = task
        await task.value
    }

    var isQuotaStale: Bool {
        guard let verifiedAt = quotaVerifiedAt, dailyQuotaRemaining != nil else { return true }
        return Date().timeIntervalSince(verifiedAt) >= quotaFreshnessInterval
            || quotaNextResetAt.map { $0 <= Date() } == true
    }

    var isSubscriptionQuotaStale: Bool {
        guard let balance = subscriptionBalance else { return true }
        return !balance.isFresh(verifiedAt: subscriptionQuotaVerifiedAt, maximumAge: quotaFreshnessInterval)
    }

    @MainActor
    func refreshAssistantState(force: Bool = false) async {
        let ownerAtEntry = assistantOwnerId
        let tokenAtEntry = AuthService.shared.token
        if AuthService.shared.isLoggedIn {
            do { try await AuthService.shared.refreshIfNeeded() }
            catch {
                guard !(error is CancellationError), !Task.isCancelled, AssistantOwnerIdentity.matches(assistantOwnerId, ownerAtEntry),
                      AuthService.shared.token == tokenAtEntry else { return }
                synchronizeAuthIdentity()
                dailyQuotaRemaining = nil
                subscriptionBalance = nil
                subscriptionQuotaVerifiedAt = nil
                quotaStatusMessage = error.localizedDescription
                return
            }
        }
        guard !Task.isCancelled, AssistantOwnerIdentity.matches(assistantOwnerId, ownerAtEntry) else { return }
        synchronizeAuthIdentity()
        if AuthService.shared.isLoggedIn, let token = AuthService.shared.token {
            await refreshServerPreferences(owner: ownerAtEntry, token: token)
        }
        if isQuotaStale {
            dailyQuotaRemaining = nil
            quotaStatusMessage = quotaVerifiedAt == nil ? "额度尚未验证" : "额度已过期，正在重新验证"
        }
        if isSubscriptionQuotaStale {
            subscriptionBalance = nil
            subscriptionQuotaVerifiedAt = nil
        }
        if let task = entitlementRefreshTask {
            await task.value
            return
        }
        let now = Date()
        if !force {
            if let failed = lastFailedRefreshAt, now.timeIntervalSince(failed) < failureRefreshInterval { return }
            if lastFailedRefreshAt == nil, let success = lastSuccessfulRefreshAt,
               now.timeIntervalSince(success) < successRefreshInterval, !isQuotaStale { return }
        }

        let owner = assistantOwnerId
        guard AuthService.shared.isLoggedIn,
              !AssistantOwnerIdentity.matches(owner, "local-device"), let token = AuthService.shared.token,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dailyQuotaRemaining = nil
            quotaStatusMessage = "登录后领取每日额度"
            subscriptionBalance = nil
            subscriptionQuotaVerifiedAt = nil
            await refreshStorefrontSuggestion(for: owner)
            return
        }

        let jobId = UUID()
        entitlementRefreshId = jobId
        isRefreshingEntitlements = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshStorefrontSuggestion(for: owner)
            await self.performEntitlementRefresh(owner: owner, token: token, jobId: jobId)
        }
        entitlementRefreshTask = task
        await task.value
        guard entitlementRefreshId == jobId else { return }
        entitlementRefreshTask = nil
        entitlementRefreshId = nil
        isRefreshingEntitlements = false
        if assistantMode == "platform" { await refreshModelCatalog() }
    }

    @MainActor
    private func refreshServerPreferences(owner: String, token: String) async {
        guard AuthService.shared.isLoggedIn,
              AssistantOwnerIdentity.matches(assistantOwnerId, owner),
              AuthService.shared.token == token else { return }
        if let task = preferencesRefreshTask { await task.value; return }
        if let verified = preferencesVerifiedAt, Date().timeIntervalSince(verified) < 300 { return }

        let operation = UUID()
        preferencesRefreshId = operation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.preferencesRefreshId == operation {
                    self.preferencesRefreshTask = nil
                    self.preferencesRefreshId = nil
                }
            }
            do {
                let response = try await self.preferencesClient.fetch(accessToken: token)
                guard response.success, self.preferencesRefreshId == operation,
                      AssistantOwnerIdentity.matches(self.assistantOwnerId, owner),
                      AuthService.shared.token == token, !Task.isCancelled else { return }
                let preferences = response.preferences
                self.assistantLanguage = Self.canonicalAssistantLanguage(preferences.locale)
                if !preferences.personaLevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.userSettings.toxicLevel = preferences.personaLevel
                }
                if ["off", "important", "daily", "normal", "frequent"].contains(preferences.proactiveLevel) {
                    self.proactiveLevel = preferences.proactiveLevel
                }
                if ["CN", "INTL"].contains(preferences.serviceRegion), preferences.regionConfirmed {
                    self.serviceRegion = preferences.serviceRegion
                    self.regionConfirmed = true
                    self.platformModelId = self.savedPlatformModel(for: self.serviceRegion)
                } else {
                    self.serviceRegion = ""
                    self.regionConfirmed = false
                    self.platformModelId = ""
                }
                self.saveUserSettings()
                self.saveAssistantPreferences()
                self.preferencesVerifiedAt = Date()
            } catch {
                // Preference sync is best effort; retain the last owner-scoped
                // local snapshot and retry on the next freshness window.
            }
        }
        preferencesRefreshTask = task
        await task.value
    }

    private static func canonicalAssistantLanguage(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("zh") { return "zh-Hans" }
        if normalized.hasPrefix("en") { return "en" }
        return "system"
    }

    @MainActor
    private func refreshStorefrontSuggestion(for owner: String) async {
        #if os(iOS)
        guard !regionConfirmed, serviceRegion.isEmpty else { return }
        let storefront = await Storefront.current
        guard !Task.isCancelled, AssistantOwnerIdentity.matches(assistantOwnerId, owner), !regionConfirmed,
              serviceRegion.isEmpty, let storefront else { return }
        serviceRegion = storefront.countryCode == "CHN" ? "CN" : "INTL"
        #endif
    }

    @MainActor
    private func performEntitlementRefresh(owner: String, token: String, jobId: UUID) async {
        var verified = false
        var incomplete = false
        var unclaimed = false
        do {
            let quota = try await APIService.shared.claimDailyQuota(token: token)
            guard responseBelongsToCurrentSession(owner: owner, token: token, jobId: jobId) else { return }
            guard quota.claimed, quota.granted == 8, (0...8).contains(quota.remaining),
                  !quota.serviceDay.isEmpty else { throw EntitlementStateError.invalidResponse }
            let resetAt = parseServerDate(quota.nextResetAt)
            guard resetAt == nil || resetAt! > Date() else { throw EntitlementStateError.invalidResponse }
            dailyQuotaRemaining = quota.remaining
            quotaServiceDay = quota.serviceDay
            quotaNextResetAt = resetAt
            quotaVerifiedAt = Date()
            verified = true
        } catch {
            guard responseBelongsToCurrentSession(owner: owner, token: token, jobId: jobId) else { return }
            incomplete = true
        }

        do {
            let result = try await APIService.shared.fetchAssistantEntitlements(token: token)
            guard responseBelongsToCurrentSession(owner: owner, token: token, jobId: jobId) else { return }
            guard (0...8).contains(result.dailyRemaining) else { throw EntitlementStateError.invalidResponse }
            let resetAt = parseServerDate(result.nextResetAt) ?? quotaNextResetAt
            guard resetAt == nil || resetAt! > Date() else { throw EntitlementStateError.invalidResponse }
            dailyQuotaRemaining = result.dailyClaimed ? result.dailyRemaining : nil
            unclaimed = !result.dailyClaimed
            quotaNextResetAt = resetAt
            quotaVerifiedAt = Date()
            do {
                subscriptionBalance = try result.subscription?.validatedBalance()
                subscriptionQuotaVerifiedAt = subscriptionBalance == nil ? nil : Date()
            } catch {
                subscriptionBalance = nil
                subscriptionQuotaVerifiedAt = nil
                incomplete = true
            }
            if ["CN", "INTL"].contains(result.serviceRegion) {
                serviceRegion = result.serviceRegion
                if result.regionSource == "user" || result.regionSource == "manual" { regionConfirmed = true }
                saveAssistantPreferences()
            }
            verified = true
        } catch {
            guard responseBelongsToCurrentSession(owner: owner, token: token, jobId: jobId) else { return }
            incomplete = true
        }

        guard responseBelongsToCurrentSession(owner: owner, token: token, jobId: jobId) else { return }
        if verified {
            lastSuccessfulRefreshAt = Date()
            lastFailedRefreshAt = incomplete ? Date() : nil
            quotaStatusMessage = unclaimed ? "今日额度尚未领取，请重试"
                : (incomplete ? "已验证额度，部分权益信息暂不可用" : nil)
        } else {
            lastFailedRefreshAt = Date()
            if isQuotaStale { dailyQuotaRemaining = nil }
            if isSubscriptionQuotaStale {
                subscriptionBalance = nil
                subscriptionQuotaVerifiedAt = nil
            }
            quotaStatusMessage = dailyQuotaRemaining == nil ? "暂时无法验证额度，请稍后重试" : "刷新失败，显示上次已验证额度"
        }
    }

    private func responseBelongsToCurrentSession(owner: String, token: String, jobId: UUID) -> Bool {
        !Task.isCancelled && entitlementRefreshId == jobId
            && AssistantOwnerIdentity.matches(assistantOwnerId, owner) && AuthService.shared.token == token
            && AuthService.shared.isLoggedIn
    }

    private func parseServerDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private enum EntitlementStateError: Error { case invalidResponse }

enum AssistantHomeRoute: Hashable {
    case memories, history, tools, proactive, subscription, dataManagement
    case historyConversation(id: String, ownerId: String)
}

// MARK: - User Stats
struct UserStats: Codable {
    var totalChats: Int = 0
    var usageDays: Int = 1
    var streak: Int = 0
    var lastActiveDate: Date?
}

// MARK: - App Tab
enum AppTab: String, CaseIterable {
    case home = "首页"
    case chat = "对话"
    case fortune = "任务"
    case profile = "我的"
    
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .chat: return "message.fill"
        case .fortune: return "checklist"
        case .profile: return "person.fill"
        }
    }
}

// MARK: - User Settings
struct UserSettings: Codable {
    var nickname: String = "草包用户"
    var avatarType: String = "preset"
    var avatarValue: String = "logo"
    var toxicLevel: String = "normal"
    
    var avatarEmoji: String? {
        avatarType == "emoji" ? avatarValue : nil
    }
    
    var avatarUrl: String? {
        // preset 类型使用 logo 时返回 nil，显示默认头像
        if avatarType == "preset" {
            if avatarValue == "logo" {
                return nil
            }
            return "https://caobao.coze.site/avatars/\(avatarValue).png"
        } else if avatarType == "custom" {
            return avatarValue
        }
        return nil
    }
}
