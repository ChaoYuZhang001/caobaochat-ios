import Foundation
import SwiftUI
import AuthenticationServices
import Security
import CryptoKit
#if os(iOS)
import StoreKit
#endif

extension Notification.Name {
    static let loginSuccess = Notification.Name("loginSuccess")
    static let logoutSuccess = Notification.Name("logoutSuccess")
}

@MainActor
final class AuthService: ObservableObject {
    static let shared = AuthService()
    @Published private(set) var isLoggedIn = false
    @Published private(set) var user: User?
    @Published private(set) var token: String?
    @Published private(set) var sessionPersistenceError: String?
    @Published private(set) var isRefreshingSession = false
    @Published private(set) var deletionNotice: AssistantDeletionNotice?
    @Published private(set) var isRetryingLocalCleanup = false

    private struct StoredSession: Codable {
        let identity: AssistantIdentityResponse
        let origin: String
    }
    private let secureAccount = "assistant-session-v2"
    private var storedSession: StoredSession?
    private var refreshTask: Task<Void, Error>?
    private var refreshId: UUID?
    private var identityEpoch = UUID()
    private var pendingNonce: String?
    private var pendingState: String?
    private let api = AssistantIdentityClient(baseURL: APIConfig.assistantBaseURL)
    private let deletionStore = AssistantDeletionNoticeStore()
    private lazy var deletionCleanup = AssistantDeletionCleanupCoordinator(store: deletionStore)
    private var localCleanupOperationId: UUID?
    private var deletionMetadataIssue = false
    private var dismissedMetadataIssue = false
    private var origin: String { APIConfig.assistantBaseURL.absoluteString }

    private init() { loadSession(); refreshDeletionNotice() }

    func loadSession() {
        guard !UserDefaults.standard.bool(forKey: "assistant.local-signout-pending") else { return }
        guard let encoded = KeychainStore.read(account: secureAccount) else {
            if KeychainStore.read(account: "auth-access-token") != nil || UserDefaults.standard.string(forKey: "caobao_token") != nil {
                sessionPersistenceError = AssistantLocalization.string("旧版登录需要重新验证，请使用 Apple 登录；本地数据不会自动归入其他账号。")
            }
            return
        }
        guard encoded.utf8.count <= 131_072, let data = encoded.data(using: .utf8),
              let record = try? JSONDecoder().decode(StoredSession.self, from: data),
              record.origin == origin, !record.identity.user.id.isEmpty,
              !record.identity.session.accessToken.isEmpty, !record.identity.session.refreshToken.isEmpty else {
            sessionPersistenceError = AssistantLocalization.string("无法读取适用于当前服务的安全会话，请重新登录。")
            return
        }
        apply(record)
    }

    private func apply(_ record: StoredSession) {
        storedSession = record
        token = record.identity.session.accessToken
        let value = record.identity.user
        user = User(id: value.id, authProvider: "apple", isGuest: false, createdAt: nil, updatedAt: nil,
            lastLoginAt: nil, settings: nil, stats: nil, name: value.displayName, email: nil, avatar: nil, guestExpiresAt: nil)
        isLoggedIn = true
        sessionPersistenceError = nil
        refreshDeletionNotice()
    }

    private func accept(_ identity: AssistantIdentityResponse) throws {
        guard identity.session.expiresAt > Date(), identity.session.expiresAt.timeIntervalSinceNow <= 86_400 else {
            throw AssistantIdentityClientError.invalidResponse
        }
        let record = StoredSession(identity: identity, origin: origin)
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        do { try KeychainStore.save(encoded, account: secureAccount) }
        catch {
            sessionPersistenceError = AssistantLocalization.string("无法安全保存登录状态；原会话未被替换。请稍后重试。")
            throw AuthError.persistenceFailed(sessionPersistenceError!)
        }
        UserDefaults.standard.set(false, forKey: "assistant.local-signout-pending")
        // Remove legacy data only after the entire v2 access/refresh pair was saved atomically.
        UserDefaults.standard.removeObject(forKey: "caobao_token")
        UserDefaults.standard.removeObject(forKey: "caobao_user")
        KeychainStore.delete(account: "auth-access-token")
        apply(record)
    }

    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) throws {
        let nonce = try randomValue()
        let state = try randomValue()
        identityEpoch = UUID()
        pendingNonce = nonce; pendingState = state
        request.requestedScopes = [.fullName, .email]
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        request.state = state
    }

    func cancelAppleRequest() { pendingNonce = nil; pendingState = nil }

    func handleAppleSignIn(result: ASAuthorization) async throws {
        guard let credential = result.credential as? ASAuthorizationAppleIDCredential,
              let nonce = pendingNonce, let state = pendingState, credential.state == state,
              let identityData = credential.identityToken, let codeData = credential.authorizationCode,
              let identityToken = String(data: identityData, encoding: .utf8),
              let code = String(data: codeData, encoding: .utf8) else { throw AuthError.invalidCredential }
        cancelAppleRequest()
        let epoch = identityEpoch
        var storefront: String?
        #if os(iOS)
        storefront = await Storefront.current?.countryCode
        #endif
        let response = try await api.signInApple(identityToken: identityToken, authorizationCode: code, nonce: nonce,
            locale: Locale.preferredLanguages.first ?? "en", storefront: storefront,
            timeZone: Self.currentAccountTimeZoneIdentifier())
        guard identityEpoch == epoch, !Task.isCancelled else { throw CancellationError() }
        try accept(response)
        NotificationCenter.default.post(name: .loginSuccess, object: nil)
    }

    /// The server uses the account's explicit IANA zone as the daily allowance
    /// boundary. Fixed-offset and device-local identifiers are not stable enough
    /// for that contract, so use UTC when the system only exposes one of them.
    private static func currentAccountTimeZoneIdentifier() -> String {
        let identifier = TimeZone.autoupdatingCurrent.identifier
        if TimeZone.knownTimeZoneIdentifiers.contains(identifier) { return identifier }
        return "UTC"
    }

    func refreshIfNeeded() async throws {
        guard isLoggedIn, let record = storedSession, record.origin == origin else { throw AuthError.notLoggedIn }
        if record.identity.session.expiresAt.timeIntervalSinceNow > 60 { return }
        if let refreshTask { try await refreshTask.value; return }
        let epoch = identityEpoch
        let operation = UUID()
        refreshId = operation; isRefreshingSession = true
        let job = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            do {
                let response = try await self.api.refresh(refreshToken: record.identity.session.refreshToken, expectedUserId: record.identity.user.id)
                guard self.identityEpoch == epoch, AssistantOwnerIdentity.matches(self.user?.id, record.identity.user.id), !Task.isCancelled else { throw CancellationError() }
                try self.accept(response)
            } catch {
                guard self.identityEpoch == epoch else { throw CancellationError() }
                if let error = error as? AssistantIdentityClientError, case .httpStatus(let code) = error, [401, 403].contains(code) {
                    self.logout()
                }
                throw error
            }
        }
        refreshTask = job
        defer {
            if refreshId == operation { refreshTask = nil; refreshId = nil; isRefreshingSession = false }
        }
        try await job.value
    }

    func validAccessToken() async throws -> String {
        let epoch = identityEpoch
        let owner = user?.id
        try await refreshIfNeeded()
        guard identityEpoch == epoch, AssistantOwnerIdentity.matches(user?.id, owner), !Task.isCancelled else { throw CancellationError() }
        guard let token, let record = storedSession, record.identity.session.expiresAt > Date() else { throw AuthError.notLoggedIn }
        return token
    }

    func logout() {
        let previous = token
        let owner = user?.id ?? "local-device"
        identityEpoch = UUID(); cancelAppleRequest()
#if os(iOS)
        AssistantRemoteNotificationCoordinator.shared.invalidate(accessToken: previous)
#endif
        refreshTask?.cancel(); refreshTask = nil; refreshId = nil; isRefreshingSession = false
        UserDefaults.standard.set(true, forKey: "assistant.local-signout-pending")
        KeychainStore.delete(account: secureAccount)
        KeychainStore.delete(account: "auth-access-token")
        UserDefaults.standard.removeObject(forKey: "caobao_token")
        UserDefaults.standard.removeObject(forKey: "caobao_user")
        token = nil; user = nil; isLoggedIn = false; storedSession = nil
        refreshDeletionNotice()
        NotificationCenter.default.post(name: .logoutSuccess, object: nil)
        Task { await AssistantReminderCoordinator.shared.removeAll(for: owner) }
        if let previous { Task { try? await api.revoke(accessToken: previous) } }
    }

    static var accountDeletionConfirmationToken: String { AssistantLocalization.string("账号删除确认词") }

    func deleteAccount(confirmation: String, reason: String? = nil) async throws -> DeleteAccountResult {
        guard confirmation == Self.accountDeletionConfirmationToken, let owner = user?.id else { throw AuthError.notLoggedIn }
        let epoch = identityEpoch
        let access = try await validAccessToken()
        guard identityEpoch == epoch, AssistantOwnerIdentity.matches(user?.id, owner) else { throw CancellationError() }
        let request = try await api.requestDeletion(accessToken: access)
        let serverStatus = AssistantDeletionServerStatus(rawValue: request.status.rawValue) ?? .accepted
        let job: AssistantDeletionCleanupJob
        do {
            // Once accepted, retain a resumable metadata job before touching local records.
            job = try deletionStore.recordAccepted(ownerId: owner, origin: origin,
                serverRequestId: request.deletionRequestId, status: serverStatus)
        } catch {
            deletionMetadataIssue = true; dismissedMetadataIssue = false
            if identityEpoch == epoch, AssistantOwnerIdentity.matches(user?.id, owner) { logout() }
            refreshDeletionNotice()
            throw AuthError.localDataCleanupFailed(AssistantLocalization.string("服务器已受理账号删除，但删除处理记录无法保存；未能确认本机数据已清理。"))
        }

        if identityEpoch == epoch, AssistantOwnerIdentity.matches(user?.id, owner), localCleanupOperationId == nil {
            let operation = UUID(); localCleanupOperationId = operation
            defer { if localCleanupOperationId == operation { localCleanupOperationId = nil } }
            do {
                try await deletionCleanup.perform(jobId: job.id, origin: origin,
                    mayClean: { self.identityEpoch == epoch && AssistantOwnerIdentity.matches(self.user?.id, owner) },
                    cleaner: { component, scopedOwner in try await self.cleanDeletionComponent(component, owner: scopedOwner) })
            } catch {
                if !(error is CancellationError) { deletionMetadataIssue = true; dismissedMetadataIssue = false }
            }
        }
        // A late accepted response may queue the old owner's cleanup, but must not
        // clear or sign out a different account (including a new same-owner session).
        if identityEpoch == epoch, AssistantOwnerIdentity.matches(user?.id, owner) { logout() }
        refreshDeletionNotice()
        let remaining = (try? deletionStore.jobs().first(where: { $0.id == job.id })?.pendingComponents) ?? job.pendingComponents
        if !remaining.isEmpty || deletionMetadataIssue {
            throw AuthError.localDataCleanupFailed(AssistantLocalization.string("服务器已受理账号删除，但部分本机数据尚未清理完成。请查看账号删除处理结果并重试本地清理。"))
        }
        let message = request.status == .completed ? AssistantLocalization.string("账号删除已完成，本机数据已清理。")
            : AssistantLocalization.string("账号删除请求已受理，服务器清理仍在进行；本机数据已清理并退出登录。")
        return DeleteAccountResult(success: true, message: message)
    }

    func dismissDeletionNotice() {
        guard user == nil else { deletionNotice = nil; return }
        do { try deletionStore.dismiss(origin: origin) }
        catch { dismissedMetadataIssue = true }
        deletionNotice = nil
    }

    /// Refreshes accepted deletion jobs after the account session has been
    /// revoked. The request id is a random status-only capability, so this
    /// path never refreshes a token or reads account data.
    func refreshDeletionServerStatus() async {
        guard !isLoggedIn, user == nil, !deletionMetadataIssue else { return }
        let jobs: [AssistantDeletionCleanupJob]
        do {
            jobs = try deletionStore.jobs().filter {
                $0.origin == origin && $0.serverStatus != .completed
            }
        } catch {
            deletionMetadataIssue = true
            refreshDeletionNotice()
            return
        }
        for job in jobs {
            guard !Task.isCancelled, !isLoggedIn, user == nil else { return }
            do {
                let status = try await api.deletionStatus(requestId: job.serverRequestId)
                guard !Task.isCancelled, !isLoggedIn, user == nil,
                      status.deletionRequestId == job.serverRequestId else { return }
                try deletionStore.updateServerStatus(jobId: job.id, status: status.status)
            } catch is CancellationError {
                return
            } catch {
                // The local job remains durable. A transient 404/network error
                // must not turn a known accepted deletion into a false success.
            }
        }
        refreshDeletionNotice()
    }

    /// Explicit local-only recovery. No token refresh, HTTP deletion, model call,
    /// or session mutation is permitted from this retry path.
    func retryPendingLocalCleanup() async {
        guard user == nil, !isLoggedIn, localCleanupOperationId == nil else { return }
        let operation = UUID(), epoch = identityEpoch
        localCleanupOperationId = operation; isRetryingLocalCleanup = true
        defer {
            if localCleanupOperationId == operation { localCleanupOperationId = nil; isRetryingLocalCleanup = false }
            refreshDeletionNotice()
        }
        do {
            try await deletionCleanup.retry(origin: origin,
                currentOwnerId: { self.identityEpoch == epoch && !self.isLoggedIn ? self.user?.id : "session-changed" },
                cleaner: { component, owner in try await self.cleanDeletionComponent(component, owner: owner) })
            deletionMetadataIssue = false; dismissedMetadataIssue = false
        } catch {
            if !(error is CancellationError) { deletionMetadataIssue = true; dismissedMetadataIssue = false }
        }
    }

    private func refreshDeletionNotice() {
        guard user == nil, !isLoggedIn else { deletionNotice = nil; return }
        if deletionMetadataIssue {
            deletionNotice = dismissedMetadataIssue ? nil : .unreadableStorage
            return
        }
        do { deletionNotice = try deletionStore.notice(currentOwnerId: nil, origin: origin) }
        catch {
            deletionMetadataIssue = true
            deletionNotice = dismissedMetadataIssue ? nil : .unreadableStorage
        }
    }

    private enum LocalDeletionCleanupError: Error { case failed }

    private func cleanDeletionComponent(_ component: AssistantDeletionCleanupComponent, owner: String) async throws {
        switch component {
        case .reminders:
            await AssistantReminderCoordinator.shared.removeAll(for: owner)
        case .memoriesAndTasks:
            guard AssistantLocalRepository.shared.deleteUserData(for: owner) else { throw LocalDeletionCleanupError.failed }
        case .conversationsAndDraft:
            try await ChatViewModel.shared.purgeAuthorizedOwner(ownerId: owner)
        case .apiKey:
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "chat.caobao.assistant", kSecAttrAccount as String: "byok-api-key.\(owner)"]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw LocalDeletionCleanupError.failed }
        case .preferences:
            let defaults = UserDefaults.standard
            let encodedOwner = Data(owner.utf8).base64EncodedString()
            let prefix = "caobao.assistant.\(encodedOwner)."
            let byokPrefix = "assistant.byok.\(owner)."
            for key in defaults.dictionaryRepresentation().keys {
                if key.hasPrefix(prefix) || (key.hasPrefix(byokPrefix) && !key.dropFirst(byokPrefix.count).contains(".")) {
                    defaults.removeObject(forKey: key)
                }
            }
            // These stores intentionally live outside the general assistant
            // preference namespace. They are still account-owned and must be
            // removed during an accepted account deletion so a later local
            // session cannot expose the deleted owner's data or sync cursor.
            defaults.removeObject(forKey: "assistant.cloud-memory.\(encodedOwner)")
            // Change-feed cursors and pending cloud tombstones are also
            // account-owned. Keeping either after deletion can cause a later
            // sign-in with the same provider identity to resume from stale
            // state or retry deletes belonging to the deleted account.
            defaults.removeObject(forKey: "caobao.assistant.cloudConversationSync.\(encodedOwner)")
            defaults.removeObject(forKey: "caobao.assistant.cloudConversationDeletes.\(encodedOwner)")
            defaults.removeObject(forKey: "caobao.assistant.cloudTaskSync.\(encodedOwner)")
            defaults.removeObject(forKey: "caobao.assistant.cloudTaskDeletes.\(encodedOwner)")
            let quoteOwner = encodedOwner
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
            defaults.removeObject(forKey: "caobao.quote_favorites.\(quoteOwner)")
            AssistantProactiveStore.shared.clear(ownerId: owner)
            AssistantProactiveInboxStore.shared.clear(ownerId: owner)
        }
    }

    func exportData() async throws -> ExportDataResult {
        guard let owner = user?.id else { throw AuthError.notLoggedIn }
        let access = try await validAccessToken()
        let data = try await api.export(accessToken: access)
        guard AssistantOwnerIdentity.matches(user?.id, owner), !Task.isCancelled else { throw CancellationError() }
        return ExportDataResult(success: true, data: nil, exportedAt: ISO8601DateFormatter().string(from: Date()),
            rawJSON: String(decoding: data, as: UTF8.self))
    }

    private func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw AuthError.invalidCredential }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Auth Error
enum AuthError: LocalizedError {
    case loginFailed(String)
    case invalidCredential
    case networkError
    case notLoggedIn
    case deleteFailed(String)
    case exportFailed(String)
    case persistenceFailed(String)
    case localDataCleanupFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .loginFailed(let message):
            return message
        case .invalidCredential:
            return AssistantLocalization.string("无效的凭证")
        case .networkError:
            return AssistantLocalization.string("网络错误")
        case .notLoggedIn:
            return AssistantLocalization.string("未登录")
        case .deleteFailed(let message):
            return message
        case .exportFailed(let message):
            return message
        case .persistenceFailed(let message):
            return message
        case .localDataCleanupFailed(let message):
            return message
        }
    }
}

// MARK: - Result Models
struct DeleteAccountResult: Codable {
    let success: Bool
    let message: String?
}

struct ExportDataResult: Codable {
    let success: Bool
    let data: [String: String]?
    let exportedAt: String?
    var rawJSON: String? = nil
}

// MARK: - Apple Sign In Button (iOS/macOS)
#if os(iOS) || os(macOS)
struct AppleSignInButton: View {
    let onSuccess: () -> Void
    let onError: (String) -> Void
    
    var body: some View {
        SignInWithAppleButton(
            .signIn,
            onRequest: { request in
                do { try AuthService.shared.configureAppleRequest(request) }
                catch { onError(error.localizedDescription) }
            },
            onCompletion: { result in
                switch result {
                case .success(let authorization):
                    Task {
                        do {
                            try await AuthService.shared.handleAppleSignIn(result: authorization)
                            await MainActor.run {
                                onSuccess()
                            }
                        } catch {
                            await MainActor.run {
                                onError(error.localizedDescription)
                            }
                        }
                    }
                case .failure(let error):
                    AuthService.shared.cancelAppleRequest()
                    onError(error.localizedDescription)
                }
            }
        )
        .signInWithAppleButtonStyle(.black)
        .frame(height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
#endif
