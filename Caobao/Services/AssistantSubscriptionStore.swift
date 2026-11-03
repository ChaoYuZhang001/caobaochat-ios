import Foundation
import Combine
import StoreKit

/// The server supplies product identifiers and the stable StoreKit account UUID.
/// Loading this store does not purchase, restore, or infer a paid entitlement.
@MainActor
final class AssistantSubscriptionStore: ObservableObject {
    static let shared = AssistantSubscriptionStore()

    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published private(set) var purchasingProductId: String?
    @Published private(set) var unavailableMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastVerifiedSubscription: VerifiedSubscription?
    /// Latest account snapshot returned by GET /entitlements. This is shown
    /// when this device has not verified a local StoreKit transaction.
    @Published private(set) var serverSubscription: AssistantSubscriptionStatus?
    /// Changes only after the authenticated server accepted a transaction.
    @Published private(set) var entitlementRevision = 0
    /// Lets a visible subscription page reload after login, logout or token rotation.
    @Published private(set) var accountRevision = 0

    struct Configuration: Decodable {
        let userId: String
        let appAccountToken: UUID
        let productIds: [String]
    }

    struct VerifiedSubscription: Decodable, Equatable {
        let status: String
        let productId: String
        let originalTransactionId: String
        let expiresAt: String?
    }

    private struct VerificationResponse: Decodable {
        let verified: Bool
        let userId: String
        let subscription: VerifiedSubscription
    }

    private struct VerificationRequest: Encodable {
        let signedTransaction: String
        let transactionId: String
        let productId: String
        let appAccountToken: UUID
    }

    private struct AccountSession: Equatable {
        let userId: String
        let accessToken: String
    }

    private struct PendingVerification {
        let id: UUID
        let task: Task<VerifiedSubscription, Error>
    }

    private let auth: AuthService
    private let session: URLSession
    private let redirectDelegate: SubscriptionRedirectGuard
    private let baseURL: URL
    private var account: AccountSession?
    private var configuration: Configuration?
    private var configurationGeneration = UUID()
    private var loadTask: Task<Void, Never>?
    private var serverEntitlementTask: Task<Void, Never>?
    private var serverEntitlementGeneration: UUID?
    private var updatesTask: Task<Void, Never>?
    /// StoreKit may deliver an unfinished transaction before the account-bound
    /// server configuration has loaded. Keep it until a current configuration
    /// can validate ownership; never finish it while unbound.
    private var pendingUpdates: [UInt64: VerificationResult<Transaction>] = [:]
    private var authObservation: AnyCancellable?
    private var pendingVerifications: [UInt64: PendingVerification] = [:]
    private var purchaseOperationId: UUID?
    private var restoreOperationId: UUID?

    var isBusy: Bool { isLoading || isPurchasing || isRestoring }
    var canPurchase: Bool { configuration != nil && !products.isEmpty && account != nil && !isBusy && AppStore.canMakePayments }
    var canRestore: Bool { configuration != nil && account != nil && !isBusy }

    init(auth: AuthService? = nil, baseURL: URL = APIConfig.assistantBaseURL, session: URLSession? = nil) {
        let auth = auth ?? AuthService.shared
        self.auth = auth
        self.baseURL = baseURL
        let guardDelegate = SubscriptionRedirectGuard()
        redirectDelegate = guardDelegate
        if let session { self.session = session }
        else {
            let settings = URLSessionConfiguration.ephemeral
            settings.timeoutIntervalForRequest = 20
            settings.timeoutIntervalForResource = 40
            settings.urlCache = nil
            settings.httpCookieStorage = nil
            self.session = URLSession(configuration: settings, delegate: guardDelegate, delegateQueue: nil)
        }
        account = Self.currentAccount(auth)
        unavailableMessage = account == nil ? AssistantLocalization.string("登录后可查看订阅方案。") : nil
        authObservation = auth.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.synchronizeAccount() }
        }
        startUpdatesListenerIfNeeded()
    }

    deinit {
        loadTask?.cancel()
        serverEntitlementTask?.cancel()
        updatesTask?.cancel()
        pendingVerifications.values.forEach { $0.task.cancel() }
    }

    /// Safe to call from a page task. No StoreKit purchase or AppStore.sync occurs here.
    func loadConfiguration(force: Bool = false) async {
        if auth.isLoggedIn {
            do { try await auth.refreshIfNeeded() }
            catch { unavailableMessage = error.localizedDescription; return }
        }
        synchronizeAccount()
        guard let account else {
            unavailableMessage = AssistantLocalization.string("登录后可查看订阅方案。")
            return
        }
        if let loadTask { await loadTask.value; return }
        guard !isPurchasing, !isRestoring else { return }
        if configuration != nil && !force {
            await refreshServerEntitlement(account: account, generation: configurationGeneration)
            return
        }
        let generation = UUID()
        configurationGeneration = generation
        pendingVerifications.values.forEach { $0.task.cancel() }
        pendingVerifications.removeAll()
        configuration = nil; products = []
        errorMessage = nil; statusMessage = nil; unavailableMessage = nil
        isLoading = true
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshServerEntitlement(account: account, generation: generation)
            do {
                let config: Configuration = try await self.request(
                    path: "subscriptions/apple/config", method: "GET", body: nil, account: account
                )
                try self.requireCurrent(account, generation: generation)
                guard config.userId == account.userId, !config.productIds.isEmpty,
                      config.productIds.count <= 50,
                      Set(config.productIds).count == config.productIds.count,
                      config.productIds.allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else {
                    throw SubscriptionError.configurationUnavailable
                }
                let loaded = try await Product.products(for: config.productIds)
                try self.requireCurrent(account, generation: generation)
                let eligible = loaded.filter {
                    config.productIds.contains($0.id) && $0.type == .autoRenewable && $0.subscription != nil
                }
                guard !eligible.isEmpty else { throw SubscriptionError.productsUnavailable }
                let order = Dictionary(uniqueKeysWithValues: config.productIds.enumerated().map { ($0.element, $0.offset) })
                self.products = eligible.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
                self.configuration = config
                self.startUpdatesListenerIfNeeded()
                await self.drainPendingUpdates(account: account, config: config, generation: generation)
            } catch {
                guard self.matches(account, generation: generation) else { return }
                self.configuration = nil; self.products = []
                self.unavailableMessage = AssistantLocalization.string("订阅暂不可用。商品配置或 App Store 商品尚未就绪，请稍后重试。")
                self.errorMessage = self.safeMessage(for: error)
            }
        }
        loadTask = operation
        await operation.value
        guard matches(account, generation: generation) else { return }
        loadTask = nil; isLoading = false
    }

    /// Must be called only by an explicit user purchase action.
    func purchase(_ product: Product) async {
        synchronizeAccount()
        guard AppStore.canMakePayments else {
            errorMessage = AssistantLocalization.string("这台设备暂不允许 App Store 购买。你仍可以恢复或管理已有订阅。")
            return
        }
        guard canPurchase, let account, let config = configuration,
              config.productIds.contains(product.id), products.contains(where: { $0.id == product.id }),
              product.type == .autoRenewable else {
            errorMessage = AssistantLocalization.string("请先登录并加载可用订阅商品。")
            return
        }
        let generation = configurationGeneration
        let operationId = UUID()
        purchaseOperationId = operationId
        isPurchasing = true; purchasingProductId = product.id
        errorMessage = nil; statusMessage = nil
        defer {
            if purchaseOperationId == operationId {
                isPurchasing = false; purchasingProductId = nil; purchaseOperationId = nil
            }
        }
        do {
            try requireCurrent(account, generation: generation)
            let result = try await product.purchase(options: [.appAccountToken(config.appAccountToken)])
            try requireCurrent(account, generation: generation)
            switch result {
            case .success(let verification):
                let transaction = try checkedTransaction(verification, config: config)
                _ = try await verify(verification, transaction: transaction, account: account,
                                     config: config, generation: generation)
                try requireCurrent(account, generation: generation)
                statusMessage = AssistantLocalization.string("购买已由服务器验证，正在刷新账号权益。")
            case .userCancelled:
                statusMessage = AssistantLocalization.string("已取消购买，未更改订阅权益。")
            case .pending:
                statusMessage = AssistantLocalization.string("购买正在等待批准。批准后会由服务器验证权益。")
            @unknown default:
                throw SubscriptionError.unrecognizedResult
            }
        } catch {
            if matches(account, generation: generation) { errorMessage = safeMessage(for: error) }
        }
    }

    /// AppStore.sync is invoked only from the user's restore button.
    func restorePurchases() async {
        synchronizeAccount()
        guard canRestore, let account, let config = configuration else {
            errorMessage = AssistantLocalization.string("请先登录并加载订阅配置后恢复购买。")
            return
        }
        let generation = configurationGeneration
        let operationId = UUID()
        restoreOperationId = operationId; isRestoring = true
        errorMessage = nil; statusMessage = nil
        defer {
            if restoreOperationId == operationId { isRestoring = false; restoreOperationId = nil }
        }
        do {
            try await AppStore.sync()
            try requireCurrent(account, generation: generation)
            var accepted = 0
            var failure: Error?
            for await result in Transaction.currentEntitlements {
                try requireCurrent(account, generation: generation)
                do {
                    let transaction = try checkedTransaction(result, config: config)
                    _ = try await verify(result, transaction: transaction, account: account,
                                         config: config, generation: generation)
                    accepted += 1
                } catch SubscriptionError.productNotConfigured {
                    continue
                } catch { failure = error }
            }
            try requireCurrent(account, generation: generation)
            if accepted > 0 {
                statusMessage = AssistantLocalization.string("已恢复并通过服务器验证，正在刷新账号权益。")
            } else if let failure { throw failure }
            else { statusMessage = AssistantLocalization.string("未找到可恢复到当前 CaoBao 账号的订阅。") }
            if accepted > 0, let failure { errorMessage = safeMessage(for: failure) }
        } catch {
            if matches(account, generation: generation) { errorMessage = safeMessage(for: error) }
        }
    }

    func clearError() { errorMessage = nil }

    /// Clears all account-bound data and cancels listeners/in-flight verification.
    func stop() {
        configurationGeneration = UUID()
        loadTask?.cancel(); loadTask = nil
        serverEntitlementTask?.cancel(); serverEntitlementTask = nil
        serverEntitlementGeneration = nil
        pendingVerifications.values.forEach { $0.task.cancel() }
        pendingVerifications.removeAll()
        configuration = nil; products = []; lastVerifiedSubscription = nil; serverSubscription = nil
        purchaseOperationId = nil; restoreOperationId = nil
        isLoading = false; isPurchasing = false; isRestoring = false; purchasingProductId = nil
        errorMessage = nil; statusMessage = nil
        unavailableMessage = account == nil ? AssistantLocalization.string("登录后可查看订阅方案。") : nil
    }

    private static func currentAccount(_ auth: AuthService) -> AccountSession? {
        guard auth.isLoggedIn, let owner = auth.user?.id, !owner.isEmpty,
              let token = auth.token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AccountSession(userId: owner, accessToken: token)
    }

    private func synchronizeAccount() {
        let current = Self.currentAccount(auth)
        guard current != account else { return }
        account = current
        stop()
        startUpdatesListenerIfNeeded()
        accountRevision += 1
    }

    private func matches(_ account: AccountSession, generation: UUID) -> Bool {
        !Task.isCancelled && configurationGeneration == generation
            && Self.currentAccount(auth) == account && self.account == account
    }

    private func requireCurrent(_ account: AccountSession, generation: UUID) throws {
        guard matches(account, generation: generation) else { throw SubscriptionError.accountChanged }
    }

    /// Reads the account-owned entitlement snapshot independently from
    /// StoreKit. A missing or malformed response is discarded and never
    /// treated as a paid entitlement.
    private func refreshServerEntitlement(account: AccountSession, generation: UUID) async {
        if let task = serverEntitlementTask {
            if serverEntitlementGeneration == generation {
                await task.value
                return
            }
            task.cancel()
            await task.value
        }
        guard matches(account, generation: generation) else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.serverEntitlementGeneration == generation {
                    self.serverEntitlementTask = nil
                    self.serverEntitlementGeneration = nil
                }
            }
            do {
                let response: AssistantEntitlementResponse = try await self.request(
                    path: "entitlements", method: "GET", body: nil, account: account)
                try self.requireCurrent(account, generation: generation)
                self.serverSubscription = try response.subscription?.validatedServerSnapshot()
            } catch {
                // A transient read failure must not turn a previously
                // server-accepted snapshot into a false "no subscription".
                // Account changes still clear the snapshot through stop().
            }
        }
        serverEntitlementTask = task
        serverEntitlementGeneration = generation
        await task.value
    }

    /// Starts once for the lifetime of this store. The listener is deliberately
    /// independent of a page load and of one configuration generation so an
    /// unfinished StoreKit transaction cannot be lost during account/token
    /// rotation or a temporary config failure.
    private func startUpdatesListenerIfNeeded() {
        guard updatesTask == nil else { return }
        updatesTask = Task { @MainActor [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handleUpdate(result)
            }
            self?.updatesTask = nil
        }
    }

    private func handleUpdate(_ result: VerificationResult<Transaction>) async {
        guard let account, let config = configuration else {
            cachePendingUpdate(result)
            return
        }
        let generation = configurationGeneration
        do {
            let transaction = try checkedTransaction(result, config: config)
            _ = try await verify(result, transaction: transaction, account: account,
                                 config: config, generation: generation)
        } catch SubscriptionError.productNotConfigured {
            // Do not finish an Apple transaction for a product that is not
            // currently configured by this server deployment. Keep it so a
            // later config refresh can make the ownership decision.
            cachePendingUpdate(result)
        } catch {
            // Verification failures are retryable until the server confirms
            // the transaction. Keep the StoreKit result for the next config
            // refresh instead of relying on Apple to redeliver an already
            // consumed stream element.
            cachePendingUpdate(result)
            if matches(account, generation: generation) { errorMessage = safeMessage(for: error) }
        }
    }

    private func cachePendingUpdate(_ result: VerificationResult<Transaction>) {
        let id: UInt64
        switch result {
        case .verified(let transaction), .unverified(let transaction, _): id = transaction.id
        }
        pendingUpdates[id] = result
    }

    private func drainPendingUpdates(account: AccountSession, config: Configuration, generation: UUID) async {
        guard matches(account, generation: generation), !pendingUpdates.isEmpty else { return }
        let pending = pendingUpdates
        pendingUpdates.removeAll()
        for (id, result) in pending {
            guard matches(account, generation: generation) else {
                pendingUpdates[id] = result
                return
            }
            do {
                let transaction = try checkedTransaction(result, config: config)
                _ = try await verify(result, transaction: transaction, account: account,
                                     config: config, generation: generation)
            } catch SubscriptionError.productNotConfigured {
                // Keep it unfinished; a later server configuration may include
                // the product explicitly.
                pendingUpdates[id] = result
            } catch {
                pendingUpdates[id] = result
                if matches(account, generation: generation) { errorMessage = safeMessage(for: error) }
            }
        }
    }

    private func checkedTransaction(_ result: VerificationResult<Transaction>, config: Configuration) throws -> Transaction {
        switch result {
        case .verified(let transaction):
            guard config.productIds.contains(transaction.productID), transaction.productType == .autoRenewable else {
                throw SubscriptionError.productNotConfigured
            }
            guard transaction.appAccountToken == config.appAccountToken else { throw SubscriptionError.ownershipConflict }
            return transaction
        case .unverified:
            throw SubscriptionError.unverifiedTransaction
        }
    }

    private func verify(_ result: VerificationResult<Transaction>, transaction: Transaction,
                        account: AccountSession, config: Configuration, generation: UUID) async throws -> VerifiedSubscription {
        try requireCurrent(account, generation: generation)
        if let pending = pendingVerifications[transaction.id] { return try await pending.task.value }
        let id = UUID()
        let task = Task { @MainActor [weak self] () throws -> VerifiedSubscription in
            guard let self else { throw CancellationError() }
            try self.requireCurrent(account, generation: generation)
            let body = VerificationRequest(signedTransaction: result.jwsRepresentation,
                transactionId: String(transaction.id), productId: transaction.productID, appAccountToken: config.appAccountToken)
            let response: VerificationResponse = try await self.request(path: "subscriptions/apple/verify",
                method: "POST", body: try JSONEncoder().encode(body), account: account,
                idempotencyKey: "apple-transaction-\(transaction.id)")
            try self.requireCurrent(account, generation: generation)
            let subscription = response.subscription
            let allowedStatuses = ["active", "trialing", "grace_period", "expired", "refunded", "revoked"]
            guard response.verified, response.userId == account.userId,
                  subscription.productId == transaction.productID,
                  subscription.originalTransactionId == String(transaction.originalID),
                  allowedStatuses.contains(subscription.status) else { throw SubscriptionError.serverRejected }
            if ["active", "trialing", "grace_period"].contains(subscription.status) {
                guard let value = subscription.expiresAt, let expiry = Self.serverDate(value), expiry > Date() else {
                    throw SubscriptionError.serverRejected
                }
            }
            // This is a server-accepted snapshot, not a StoreKit-derived entitlement Boolean.
            self.lastVerifiedSubscription = subscription
            self.serverSubscription = AssistantSubscriptionStatus(productId: subscription.productId,
                plan: nil, status: subscription.status, expiresAt: subscription.expiresAt, quota: nil)
            self.entitlementRevision += 1
            // Never finish an unverified, conflicted or server-rejected transaction.
            await transaction.finish()
            return subscription
        }
        pendingVerifications[transaction.id] = PendingVerification(id: id, task: task)
        defer {
            if pendingVerifications[transaction.id]?.id == id { pendingVerifications.removeValue(forKey: transaction.id) }
        }
        return try await task.value
    }

    private func request<T: Decodable>(path: String, method: String, body: Data?,
                                       account: AccountSession, idempotencyKey: String? = nil) async throws -> T {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw SubscriptionError.configurationUnavailable
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw SubscriptionError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 409 { throw SubscriptionError.ownershipConflict }
            if response.statusCode == 401 || response.statusCode == 403 { throw SubscriptionError.notAuthenticated }
            throw SubscriptionError.serviceUnavailable
        }
        guard data.count <= 1_048_576 else { throw SubscriptionError.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw SubscriptionError.invalidResponse }
    }

    private static func serverDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func safeMessage(for error: Error) -> String {
        if let error = error as? SubscriptionError { return error.localizedDescription }
        if error is CancellationError { return AssistantLocalization.string("操作已取消。") }
        return AssistantLocalization.string("订阅操作未完成，请检查网络后重试。未获得服务器确认前不会启用订阅权益。")
    }
}

private enum SubscriptionError: LocalizedError {
    case configurationUnavailable, productsUnavailable, productNotConfigured
    case accountChanged, ownershipConflict, unverifiedTransaction, serverRejected
    case unrecognizedResult, invalidResponse, serviceUnavailable, notAuthenticated
    var errorDescription: String? {
        switch self {
        case .configurationUnavailable: return AssistantLocalization.string("服务器尚未提供有效订阅配置。")
        case .productsUnavailable: return AssistantLocalization.string("当前 App Store 地区暂无可购买的订阅商品。")
        case .productNotConfigured: return AssistantLocalization.string("该商品未被配置为 CaoBao 自动续订商品。")
        case .accountChanged: return AssistantLocalization.string("账号已变化，请重新加载订阅页面。")
        case .ownershipConflict: return AssistantLocalization.string("这项购买关联了其他账号，不能恢复到当前 CaoBao 账号。")
        case .unverifiedTransaction: return AssistantLocalization.string("App Store 交易尚未通过验证，未启用任何订阅权益。")
        case .serverRejected: return AssistantLocalization.string("服务器未确认交易归属或订阅权益，请稍后恢复购买。")
        case .unrecognizedResult: return AssistantLocalization.string("购买结果暂无法识别，请稍后恢复购买。")
        case .invalidResponse: return AssistantLocalization.string("订阅服务器响应无效，未启用任何订阅权益。")
        case .serviceUnavailable: return AssistantLocalization.string("订阅服务暂不可用，请稍后重试。")
        case .notAuthenticated: return AssistantLocalization.string("账号认证已失效，请重新登录后重试。")
        }
    }
}

/// Subscription credentials and signed transactions must not follow redirects.
private final class SubscriptionRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
