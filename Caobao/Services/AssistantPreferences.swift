import Foundation

struct AssistantPreferencesSnapshot: Codable {
    let assistantMode: String
    let regionConfirmed: Bool
    let locale: String
    let personaLevel: String
    let proactiveLevel: String
    let serviceRegion: String
    let regionSource: String
    let timeZone: String
    let timeZoneLocked: Bool
}

struct AssistantPreferencesResponse: Codable {
    let success: Bool
    let preferences: AssistantPreferencesSnapshot
    let error: String?
}

enum AssistantPreferencesClientError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidToken
    case invalidResponse
    case responseTooLarge
    case unexpectedContentType
    case httpStatus(Int)
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return AssistantLocalization.string("账号偏好服务配置无效。")
        case .invalidToken: return AssistantLocalization.string("登录状态已失效，请重新登录。")
        case .invalidResponse, .responseTooLarge, .unexpectedContentType:
            return AssistantLocalization.string("账号偏好服务返回了无效数据。")
        case .httpStatus(let status): return String(format: AssistantLocalization.string("读取账号偏好失败（HTTP %d）。"), status)
        case .networkUnavailable: return AssistantLocalization.string("暂时无法读取账号偏好，请稍后重试。")
        }
    }
}

/// Reads server-owned preferences without forwarding a bearer token through a redirect.
final class AssistantPreferencesClient {
    private let baseURL: URL
    private let session: URLSession
    private let maximumResponseBytes: Int

    init(baseURL: URL = URL(string: "https://caobao.chat/api/v2")!,
         sessionConfiguration: URLSessionConfiguration = .ephemeral,
         maximumResponseBytes: Int = 128 * 1024) {
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
        session = URLSession(configuration: configuration, delegate: AssistantPreferencesRedirectGuard(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func fetch(accessToken: String) async throws -> AssistantPreferencesResponse {
        try Task.checkCancellation()
        guard maximumResponseBytes > 0,
              baseURL.scheme?.lowercased() == "https",
              let host = baseURL.host, !host.isEmpty,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw AssistantPreferencesClientError.invalidConfiguration
        }
        guard validToken(accessToken) else { throw AssistantPreferencesClientError.invalidToken }
        let url = baseURL.appendingPathComponent("profile/preferences")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw AssistantPreferencesClientError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw AssistantPreferencesClientError.httpStatus(http.statusCode) }
            guard http.statusCode == 200 else { throw AssistantPreferencesClientError.invalidResponse }
            guard let mime = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  mime == "application/json" || (mime.hasPrefix("application/") && mime.hasSuffix("+json")) else {
                throw AssistantPreferencesClientError.unexpectedContentType
            }
            if let length = http.value(forHTTPHeaderField: "Content-Length") {
                guard let declared = Int64(length), declared >= 0 else { throw AssistantPreferencesClientError.invalidResponse }
                guard declared <= Int64(maximumResponseBytes) else { throw AssistantPreferencesClientError.responseTooLarge }
            }
            let task = bytes.task
            let data = try await withTaskCancellationHandler(operation: {
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < maximumResponseBytes else { throw AssistantPreferencesClientError.responseTooLarge }
                    data.append(byte)
                }
                return data
            }, onCancel: { task.cancel() })
            guard let result = try? JSONDecoder().decode(AssistantPreferencesResponse.self, from: data), result.success else {
                throw AssistantPreferencesClientError.invalidResponse
            }
            try validate(result.preferences)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as AssistantPreferencesClientError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AssistantPreferencesClientError.networkUnavailable
        }
    }

    private func validate(_ preferences: AssistantPreferencesSnapshot) throws {
        guard preferences.assistantMode == "platform",
              preferences.locale.utf8.count <= 128,
              preferences.personaLevel.utf8.count <= 128,
              preferences.proactiveLevel.utf8.count <= 128,
              preferences.serviceRegion.isEmpty || ["CN", "INTL"].contains(preferences.serviceRegion),
              preferences.regionSource.utf8.count <= 32,
              preferences.timeZone.utf8.count <= 128,
              preferences.timeZone.isEmpty || TimeZone.knownTimeZoneIdentifiers.contains(preferences.timeZone),
              preferences.timeZoneLocked == !preferences.timeZone.isEmpty else {
            throw AssistantPreferencesClientError.invalidResponse
        }
    }

    private func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384
            && value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }
}

final class AssistantPreferencesRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
