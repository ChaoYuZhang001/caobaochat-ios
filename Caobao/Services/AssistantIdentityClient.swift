import Foundation

struct AssistantIdentityUser: Codable, Equatable {
    let id: String
    let displayName: String?
    let locale: String?
    let timeZone: String?

    init(id: String, displayName: String? = nil, locale: String? = nil, timeZone: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.locale = locale
        self.timeZone = timeZone
    }
}

struct AssistantIdentitySession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

struct AssistantIdentityRegionSuggestion: Codable, Equatable {
    let code: String
    let source: String
    let requiresConfirmation: Bool
}

struct AssistantIdentityResponse: Codable, Equatable {
    let user: AssistantIdentityUser
    let session: AssistantIdentitySession
    /// Login-only metadata. Refresh responses may omit these fields.
    let regionSuggestion: AssistantIdentityRegionSuggestion?
    let timeZoneRequired: Bool?

    init(user: AssistantIdentityUser, session: AssistantIdentitySession,
         regionSuggestion: AssistantIdentityRegionSuggestion? = nil, timeZoneRequired: Bool? = nil) {
        self.user = user
        self.session = session
        self.regionSuggestion = regionSuggestion
        self.timeZoneRequired = timeZoneRequired
    }
}

struct AssistantDeletionServerStatusResponse: Codable, Equatable, Sendable {
    let deletionRequestId: String
    let status: AssistantDeletionServerStatus
    let updatedAt: Date
    let completedAt: Date?
}

/// An accepted deletion job is not evidence that account data has been erased.
struct AssistantIdentityDeletionRequest: Codable, Equatable {
    enum Status: String, Codable {
        case queued, accepted, pending, processing, running, needsRetry = "needs_retry", completed
    }
    let deletionRequestId: String
    let status: Status
}

enum AssistantIdentityClientError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidInput
    case invalidResponse
    case unexpectedContentType
    case responseTooLarge
    case expiredSession
    case identityMismatch
    case networkUnavailable
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return AssistantLocalization.string("身份服务配置无效，请稍后重试。")
        case .invalidInput: return AssistantLocalization.string("登录凭据或请求参数无效，请重新操作。")
        case .invalidResponse: return AssistantLocalization.string("身份服务响应无效，未更新登录状态。")
        case .unexpectedContentType: return AssistantLocalization.string("身份服务未返回预期的数据格式。")
        case .responseTooLarge: return AssistantLocalization.string("身份服务返回的数据超过安全大小限制。")
        case .expiredSession: return AssistantLocalization.string("服务器返回的会话已过期，请重新登录。")
        case .identityMismatch: return AssistantLocalization.string("刷新结果与当前账号不一致，未更新登录状态。")
        case .networkUnavailable: return AssistantLocalization.string("身份服务暂不可用，请检查网络后重试。")
        case .httpStatus(let status):
            switch status {
            case 401, 403: return AssistantLocalization.string("账号认证失败，请重新登录。")
            case 409: return AssistantLocalization.string("账号状态冲突，请重新登录后重试。")
            case 429: return AssistantLocalization.string("操作过于频繁，请稍后重试。")
            default: return AssistantLocalization.string("身份服务请求未成功，请稍后重试。")
            }
        }
    }
}

/// Stateless v2 identity transport. Callers own account state, refresh-token storage
/// and owner guards. Construction never contacts an endpoint. Even an injected
/// URLSessionConfiguration keeps redirect rejection, cookie/cache isolation and bounds.
final class AssistantIdentityClient {
    private struct AppleRequest: Encodable {
        let identityToken: String
        let authorizationCode: String
        let nonce: String
        let locale: String
        let storefront: String?
        let timeZone: String?

        enum CodingKeys: String, CodingKey {
            case identityToken, authorizationCode, nonce, locale, storefront, timeZone
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(identityToken, forKey: .identityToken)
            try values.encode(authorizationCode, forKey: .authorizationCode)
            try values.encode(nonce, forKey: .nonce)
            try values.encode(locale, forKey: .locale)
            try values.encodeIfPresent(storefront, forKey: .storefront)
            try values.encodeIfPresent(timeZone, forKey: .timeZone)
        }
    }
    private struct RefreshRequest: Encodable { let refreshToken: String }
    private struct Payload { let data: Data; let status: Int }

    private let baseURL: URL
    private let session: URLSession
    private let redirectGuard: AssistantIdentityRedirectGuard
    private let now: () -> Date
    private let maximumExportBytes: Int
    private let maximumControlBytes = 1_048_576
    private static let hardMaximumExportBytes = 8 * 1024 * 1024

    init(baseURL: URL, sessionConfiguration: URLSessionConfiguration = .ephemeral,
         now: @escaping () -> Date = Date.init, maximumExportBytes: Int = 8 * 1024 * 1024) {
        self.baseURL = baseURL
        self.now = now
        self.maximumExportBytes = min(maximumExportBytes, Self.hardMaximumExportBytes)
        let configuration = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        let guardDelegate = AssistantIdentityRedirectGuard()
        redirectGuard = guardDelegate
        session = URLSession(configuration: configuration, delegate: guardDelegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// identityToken is the raw UTF-8 JWT from Apple, never Base64 encoded again.
    /// nonce is the original nonce; the server must verify its binding to the JWT.
    func signInApple(identityToken: String, authorizationCode: String, nonce: String,
                     locale: String, storefront: String? = nil, timeZone: String? = nil) async throws -> AssistantIdentityResponse {
        try Task.checkCancellation()
        let segments = identityToken.split(separator: ".", omittingEmptySubsequences: false)
        let jwtCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        guard validCredential(identityToken, maximumBytes: 16_384), segments.count == 3,
              segments.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { jwtCharacters.contains($0) } }),
              validCredential(authorizationCode, maximumBytes: 8_192),
              validCredential(nonce, maximumBytes: 256), nonce.utf8.count >= 16,
              validIdentifier(locale, maximumBytes: 128) else { throw AssistantIdentityClientError.invalidInput }
        let normalizedStorefront = storefront?.uppercased()
        if let code = normalizedStorefront {
            guard code.utf8.count == 3, code.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) else {
                throw AssistantIdentityClientError.invalidInput
            }
        }
        if let timeZone {
            guard timeZone.utf8.count <= 128, !timeZone.isEmpty,
                  timeZone != "Local", TimeZone.knownTimeZoneIdentifiers.contains(timeZone) else {
                throw AssistantIdentityClientError.invalidInput
            }
        }
        let body = try JSONEncoder().encode(AppleRequest(identityToken: identityToken,
            authorizationCode: authorizationCode, nonce: nonce, locale: locale, storefront: normalizedStorefront,
            timeZone: timeZone))
        let result = try await send(path: "auth/apple", method: "POST", body: body, accessToken: nil,
                                    allowedStatuses: [200, 201], maximumBytes: maximumControlBytes)
        return try decodeIdentity(result.data, expectedUserId: nil)
    }

    func refresh(refreshToken: String, expectedUserId: String? = nil) async throws -> AssistantIdentityResponse {
        try Task.checkCancellation()
        guard validCredential(refreshToken, maximumBytes: 16_384) else { throw AssistantIdentityClientError.invalidInput }
        if let expectedUserId, !validIdentifier(expectedUserId, maximumBytes: 256) {
            throw AssistantIdentityClientError.invalidInput
        }
        let result = try await send(path: "auth/refresh", method: "POST",
            body: try JSONEncoder().encode(RefreshRequest(refreshToken: refreshToken)), accessToken: nil,
            allowedStatuses: [200], maximumBytes: maximumControlBytes)
        return try decodeIdentity(result.data, expectedUserId: expectedUserId)
    }

    func revoke(accessToken: String) async throws {
        let result = try await send(path: "auth/logout", method: "POST", body: nil, accessToken: accessToken,
                                    allowedStatuses: [200, 204], maximumBytes: maximumControlBytes)
        if result.status != 204 { _ = try jsonObject(result.data) }
    }

    func requestDeletion(accessToken: String) async throws -> AssistantIdentityDeletionRequest {
        let payload = try await send(path: "me", method: "DELETE", body: nil, accessToken: accessToken,
                                     allowedStatuses: [200, 202], maximumBytes: maximumControlBytes)
        let result: AssistantIdentityDeletionRequest = try decode(payload.data)
        guard validIdentifier(result.deletionRequestId, maximumBytes: 256),
              !(payload.status == 202 && result.status == .completed) else {
            throw AssistantIdentityClientError.invalidResponse
        }
        return result
    }

    /// Reads the status-only capability returned by DELETE /me. The account
    /// session is revoked before cleanup runs, so this endpoint intentionally
    /// does not send a Bearer token or any account data.
    func deletionStatus(requestId: String) async throws -> AssistantDeletionServerStatusResponse {
        try Task.checkCancellation()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard requestId.hasPrefix("del_"), requestId.utf8.count <= 128,
              requestId.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw AssistantIdentityClientError.invalidInput
        }
        guard let escaped = requestId.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw AssistantIdentityClientError.invalidInput
        }
        let payload = try await send(path: "deletions/\(escaped)", method: "GET", body: nil, accessToken: nil,
                                     allowedStatuses: [200], maximumBytes: maximumControlBytes)
        let result: AssistantDeletionServerStatusResponse = try decode(payload.data)
        guard result.deletionRequestId == requestId, result.updatedAt.timeIntervalSince1970 > 0 else {
            throw AssistantIdentityClientError.invalidResponse
        }
        return result
    }

    /// Invoke only for a user-requested export. Returns original bounded JSON bytes;
    /// this transport does not write them to disk, cache them, or log private content.
    func export(accessToken: String) async throws -> Data {
        guard maximumExportBytes > 0 else { throw AssistantIdentityClientError.invalidConfiguration }
        let payload = try await send(path: "me/export", method: "GET", body: nil, accessToken: accessToken,
                                     allowedStatuses: [200], maximumBytes: maximumExportBytes)
        _ = try jsonObject(payload.data)
        return payload.data
    }

    private func decodeIdentity(_ data: Data, expectedUserId: String?) throws -> AssistantIdentityResponse {
        let result: AssistantIdentityResponse = try decode(data)
        guard validIdentifier(result.user.id, maximumBytes: 256),
              validCredential(result.session.accessToken, maximumBytes: 16_384),
              validCredential(result.session.refreshToken, maximumBytes: 16_384),
              result.user.displayName.map({ $0.utf8.count <= 2_048 && !$0.contains("\0") }) ?? true,
              result.user.locale.map({ validIdentifier($0, maximumBytes: 128) }) ?? true,
              result.user.timeZone.map({ TimeZone.knownTimeZoneIdentifiers.contains($0) }) ?? true else {
            throw AssistantIdentityClientError.invalidResponse
        }
        if let suggestion = result.regionSuggestion {
            guard ["CN", "INTL"].contains(suggestion.code),
                  validIdentifier(suggestion.source, maximumBytes: 64) else {
                throw AssistantIdentityClientError.invalidResponse
            }
        }
        guard result.session.expiresAt > now() else { throw AssistantIdentityClientError.expiredSession }
        if let expectedUserId, !AssistantOwnerIdentity.matches(result.user.id, expectedUserId) { throw AssistantIdentityClientError.identityMismatch }
        return result
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
                throw AssistantIdentityClientError.invalidResponse
            }
            return date
        }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw AssistantIdentityClientError.invalidResponse }
    }

    private func send(path: String, method: String, body: Data?, accessToken: String?,
                      allowedStatuses: Set<Int>, maximumBytes: Int) async throws -> Payload {
        try Task.checkCancellation()
        guard baseURL.scheme?.lowercased() == "https", let host = baseURL.host, !host.isEmpty,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw AssistantIdentityClientError.invalidConfiguration
        }
        if let accessToken, !validCredential(accessToken, maximumBytes: 16_384) {
            throw AssistantIdentityClientError.invalidInput
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw AssistantIdentityClientError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw AssistantIdentityClientError.httpStatus(response.statusCode) }
            guard allowedStatuses.contains(response.statusCode) else { throw AssistantIdentityClientError.invalidResponse }
            if response.statusCode == 204 { return Payload(data: Data(), status: 204) }
            guard let contentType = response.value(forHTTPHeaderField: "Content-Type")?
                .split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                contentType == "application/json" || (contentType.hasPrefix("application/") && contentType.hasSuffix("+json")) else {
                throw AssistantIdentityClientError.unexpectedContentType
            }
            if let size = response.value(forHTTPHeaderField: "Content-Length") {
                guard let declared = Int64(size), declared >= 0 else { throw AssistantIdentityClientError.invalidResponse }
                guard declared <= Int64(maximumBytes) else { throw AssistantIdentityClientError.responseTooLarge }
            }
            let task = bytes.task
            let data = try await withTaskCancellationHandler(operation: {
                var data = Data()
                for try await byte in bytes {
                    if data.count.isMultiple(of: 4_096) { try Task.checkCancellation() }
                    guard data.count < maximumBytes else { throw AssistantIdentityClientError.responseTooLarge }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return data
            }, onCancel: { task.cancel() })
            guard !data.isEmpty else { throw AssistantIdentityClientError.invalidResponse }
            return Payload(data: data, status: response.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as AssistantIdentityClientError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AssistantIdentityClientError.networkUnavailable
        }
    }

    private func validCredential(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 }
    }

    private func validIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private func jsonObject(_ data: Data) throws -> Any {
        do {
            let value = try JSONSerialization.jsonObject(with: data)
            guard value is [String: Any] || value is [Any] else { throw AssistantIdentityClientError.invalidResponse }
            return value
        } catch { throw AssistantIdentityClientError.invalidResponse }
    }
}

private final class AssistantIdentityRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
