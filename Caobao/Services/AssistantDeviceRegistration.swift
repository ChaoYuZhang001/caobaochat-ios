import Foundation

enum AssistantDeviceRegistrationError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidInput
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return AssistantLocalization.string("设备通知服务配置无效。")
        case .invalidInput: return AssistantLocalization.string("设备通知注册参数无效。")
        case .invalidResponse, .responseTooLarge: return AssistantLocalization.string("设备通知服务返回了无效数据。")
        case .httpStatus(let status): return String(format: AssistantLocalization.string("设备通知注册失败（HTTP %d）。"), status)
        case .networkUnavailable: return AssistantLocalization.string("暂时无法注册设备通知，请稍后重试。")
        }
    }
}

private struct AssistantDeviceRegistrationRequest: Encodable {
    let deviceId: String
    let platform: String
    let pushToken: String
    let environment: String
    let topic: String
}

private struct AssistantDeviceRegistrationResponse: Decodable {
    let status: String
}

/// Authenticated APNs registration. The raw device identifier and push token
/// are sent only over the configured HTTPS endpoint and are never logged.
final class AssistantDeviceRegistrationClient {
    private let baseURL: URL
    private let session: URLSession
    private let maximumResponseBytes: Int

    init(baseURL: URL = URL(string: "https://ciyuan2api.com/api/v2")!,
         sessionConfiguration: URLSessionConfiguration = .ephemeral,
         maximumResponseBytes: Int = 64 * 1024) {
        self.baseURL = baseURL
        self.maximumResponseBytes = min(maximumResponseBytes, 1 * 1024 * 1024)
        let configuration = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        session = URLSession(configuration: configuration, delegate: AssistantDeviceRegistrationRedirectGuard(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func register(deviceId: String, pushToken: String, platform: String = "ios",
                   environment: String, topic: String, accessToken: String) async throws {
        try Task.checkCancellation()
        guard maximumResponseBytes > 0,
              baseURL.scheme?.lowercased() == "https",
              let host = baseURL.host, !host.isEmpty,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw AssistantDeviceRegistrationError.invalidConfiguration
        }
        guard validField(deviceId, maximum: 256), validPushToken(pushToken),
              platform == "ios", ["sandbox", "production"].contains(environment),
              validTopic(topic), validToken(accessToken) else {
            throw AssistantDeviceRegistrationError.invalidInput
        }
        let url = baseURL.appendingPathComponent("devices")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(AssistantDeviceRegistrationRequest(
            deviceId: deviceId, platform: platform, pushToken: pushToken,
            environment: environment, topic: topic))

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw AssistantDeviceRegistrationError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw AssistantDeviceRegistrationError.httpStatus(http.statusCode) }
            guard data.count <= maximumResponseBytes else { throw AssistantDeviceRegistrationError.responseTooLarge }
            guard let value = try? JSONDecoder().decode(AssistantDeviceRegistrationResponse.self, from: data),
                  value.status == "registered" else { throw AssistantDeviceRegistrationError.invalidResponse }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as AssistantDeviceRegistrationError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AssistantDeviceRegistrationError.networkUnavailable
        }
    }

    /// Disables one owner-scoped push target. This is intentionally best-effort
    /// at the call site so account logout never waits for a network response.
    func unregister(deviceId: String, accessToken: String) async throws {
        try Task.checkCancellation()
        guard maximumResponseBytes > 0,
              baseURL.scheme?.lowercased() == "https",
              let host = baseURL.host, !host.isEmpty,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw AssistantDeviceRegistrationError.invalidConfiguration
        }
        guard validField(deviceId, maximum: 256), validToken(accessToken) else {
            throw AssistantDeviceRegistrationError.invalidInput
        }
        let url = baseURL.appendingPathComponent("devices").appendingPathComponent(deviceId)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw AssistantDeviceRegistrationError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw AssistantDeviceRegistrationError.httpStatus(http.statusCode) }
            guard data.count <= maximumResponseBytes else { throw AssistantDeviceRegistrationError.responseTooLarge }
            guard let value = try? JSONDecoder().decode(AssistantDeviceRegistrationResponse.self, from: data),
                  value.status == "unregistered" else { throw AssistantDeviceRegistrationError.invalidResponse }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as AssistantDeviceRegistrationError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AssistantDeviceRegistrationError.networkUnavailable
        }
    }

    private func validField(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func validTopic(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 33 && scalar.value <= 126) && scalar != "\\" && scalar != "\""
            }
    }

    private func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384
            && value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }

    private func validPushToken(_ value: String) -> Bool {
        value.count >= 2 && value.count.isMultiple(of: 2) && value.utf8.count <= 255
            && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
            }
    }
}

final class AssistantDeviceRegistrationRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

#if os(iOS)
import UIKit
import UserNotifications

/// Owns the APNs token observed by the app and retries after login/token refresh.
@MainActor
final class AssistantRemoteNotificationCoordinator {
    static let shared = AssistantRemoteNotificationCoordinator()

    private let client = AssistantDeviceRegistrationClient(baseURL: APIConfig.assistantBaseURL)
    private var tokenHex: String?
    private var registrationTask: Task<Void, Never>?
    private var deviceUnregistrationTask: Task<Void, Never>?
    private var deviceUnregistrationOperation: UUID?
    private var generation = UUID()
    private let deviceKeychainAccount = "assistant-apns-device-id"

    func didRegister(deviceToken: Data) {
        guard !deviceToken.isEmpty else { return }
        tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        scheduleRegistration()
    }

    func appDidBecomeActive() { scheduleRegistration() }

    func invalidate(accessToken: String? = nil) {
        generation = UUID()
        registrationTask?.cancel(); registrationTask = nil
        guard let accessToken, let deviceId = existingDeviceId() else { return }
        let operation = UUID()
        deviceUnregistrationOperation = operation
        deviceUnregistrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.deviceUnregistrationOperation == operation {
                    self.deviceUnregistrationTask = nil
                    self.deviceUnregistrationOperation = nil
                }
            }
            do {
                try await self.client.unregister(deviceId: deviceId, accessToken: accessToken)
            } catch is CancellationError {
                return
            } catch {
                // Logout must complete even when the old owner's device cannot
                // be revoked. The server retries/cleanup path remains authoritative.
            }
        }
    }

    private func scheduleRegistration() {
        registrationTask?.cancel()
        guard tokenHex != nil, AuthService.shared.isLoggedIn else { return }
        let operation = UUID(); generation = operation
        registrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == operation { self.registrationTask = nil } }
            do {
                // A logout unregisters the previous owner's device
                // asynchronously. Serialize the next registration behind that
                // request so a slow DELETE cannot arrive after a new owner's
                // POST and disable the newly registered target.
                let previousUnregistration = self.deviceUnregistrationTask
                await previousUnregistration?.value
                try Task.checkCancellation()
                let access = try await AuthService.shared.validAccessToken()
                guard self.generation == operation, let token = self.tokenHex,
                      let deviceId = self.stableDeviceId() else { return }
                try await self.client.register(deviceId: deviceId, pushToken: token,
                    environment: Self.apnsEnvironment, topic: Self.bundleIdentifier, accessToken: access)
            } catch is CancellationError {
                return
            } catch {
                // Registration retries on the next active scene or token refresh.
            }
        }
    }

    private func stableDeviceId() -> String? {
        if let value = KeychainStore.read(account: deviceKeychainAccount), validDeviceId(value) { return value }
        let value = UUID().uuidString.lowercased()
        do { try KeychainStore.save(value, account: deviceKeychainAccount); return value }
        catch { return nil }
    }

    private func existingDeviceId() -> String? {
        guard let value = KeychainStore.read(account: deviceKeychainAccount), validDeviceId(value) else { return nil }
        return value
    }

    private func validDeviceId(_ value: String) -> Bool {
        value.count == 36 && UUID(uuidString: value) != nil
    }

    private static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    private static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "caobao.chat"
    }
}

final class AssistantApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AssistantNotificationRouter.shared.install()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in AssistantRemoteNotificationCoordinator.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // APNs registration is retried when the app becomes active; never log the token or error details.
    }
}
#endif
