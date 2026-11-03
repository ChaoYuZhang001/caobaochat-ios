import Foundation

enum AssistantConversationClientError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidInput
    case invalidResponse
    case unexpectedContentType
    case responseTooLarge
    case networkUnavailable
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return AssistantLocalization.string("会话服务配置无效，请稍后重试。")
        case .invalidInput: return AssistantLocalization.string("会话请求参数无效，请重新操作。")
        case .invalidResponse: return AssistantLocalization.string("会话服务响应无效，未开始发送消息。")
        case .unexpectedContentType: return AssistantLocalization.string("会话服务未返回预期的数据格式。")
        case .responseTooLarge: return AssistantLocalization.string("会话服务返回的数据超过安全大小限制。")
        case .networkUnavailable: return AssistantLocalization.string("会话服务暂不可用，请检查网络后重试。")
        case .httpStatus(let status):
            switch status {
            case 401, 403: return AssistantLocalization.string("账号认证失败，请重新登录。")
            case 429: return AssistantLocalization.string("操作过于频繁，请稍后重试。")
            default: return AssistantLocalization.string("创建会话未成功，请稍后重试。")
            }
        }
    }
}

/// Creates a server conversation before any platform generation starts. This
/// stateless client never infers account ownership or retries a paid generation.
final class AssistantConversationClient {
    private struct CreateRequest: Encodable {
        let clientConversationId: String
        let title: String
        let locale: String
    }
    private struct Created: Decodable { let id: String }
    private let baseURL: URL
    private let maximumResponseBytes: Int
    private let configuration: URLSessionConfiguration
    private let responseAcceptedForTesting: (@Sendable () -> Void)?

    init(baseURL: URL, sessionConfiguration: URLSessionConfiguration = .ephemeral,
         maximumResponseBytes: Int = 65_536, responseAcceptedForTesting: (@Sendable () -> Void)? = nil) {
        self.baseURL = baseURL
        self.maximumResponseBytes = min(maximumResponseBytes, 1_048_576)
        self.responseAcceptedForTesting = responseAcceptedForTesting
        let configuration = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.configuration = configuration
    }

    func create(accessToken: String, clientConversationId: String, title: String, locale: String,
                beforeStart: (@MainActor @Sendable () throws -> Void)? = nil,
                beforeStartWait: (@MainActor @Sendable () async throws -> Void)? = nil) async throws -> String {
        try Task.checkCancellation()
        guard maximumResponseBytes > 0, baseURL.scheme?.lowercased() == "https",
              let host = baseURL.host, !host.isEmpty, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else { throw AssistantConversationClientError.invalidConfiguration }
        guard validIdentifier(clientConversationId), !accessToken.isEmpty, accessToken.utf8.count <= 16_384,
              accessToken.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
              title.utf8.count <= 1_024, !title.contains("\0"), !locale.isEmpty, locale.utf8.count <= 128,
              locale.unicodeScalars.allSatisfy({ asciiIdentifier($0) }) else { throw AssistantConversationClientError.invalidInput }
        var request = URLRequest(url: baseURL.appendingPathComponent("conversations"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("conversation." + clientConversationId, forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try JSONEncoder().encode(CreateRequest(clientConversationId: clientConversationId, title: title, locale: locale))
        let operation = AssistantConversationRequest(configuration: configuration, maximumResponseBytes: maximumResponseBytes,
            responseAcceptedForTesting: responseAcceptedForTesting)
        do {
            let data = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    operation.registerContinuation(continuation)
                    let startup = Task { @MainActor in
                        guard !Task.isCancelled else { operation.cancel(); return }
                        do { try await beforeStartWait?() }
                        catch { operation.failStartup(error); return }
                        guard !Task.isCancelled else { operation.cancel(); return }
                        operation.start(request, beforeStart: beforeStart)
                    }
                    operation.registerStartup(startup)
                }
            }, onCancel: { operation.cancel() })
            try Task.checkCancellation()
            guard let result = try? JSONDecoder().decode(Created.self, from: data), validIdentifier(result.id) else {
                throw AssistantConversationClientError.invalidResponse
            }
            return result.id
        } catch let failure as AssistantConversationStartupFailure {
            // Authorization belongs to the caller; never disguise its original
            // owner/scope/revocation error as an upstream network failure.
            throw failure.underlying
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as AssistantConversationClientError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AssistantConversationClientError.networkUnavailable
        }
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy(asciiIdentifier)
    }
    private func asciiIdentifier(_ value: Unicode.Scalar) -> Bool {
        (65...90).contains(value.value) || (97...122).contains(value.value)
            || (48...57).contains(value.value) || value == "-" || value == "_"
    }
}

private struct AssistantConversationStartupFailure: Error {
    let underlying: Error
}

/// Each creation owns its session and bounded response. Only delegate callbacks
/// touch the body; the lock arbitrates their completion against startup/cancel.
private final class AssistantConversationRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let maximumResponseBytes: Int
    private let responseAcceptedForTesting: (@Sendable () -> Void)?
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var startupTask: Task<Void, Never>?
    private var started = false
    private var responseAccepted = false
    private var body = Data()

    init(configuration: URLSessionConfiguration, maximumResponseBytes: Int, responseAcceptedForTesting: (@Sendable () -> Void)?) {
        self.configuration = configuration; self.maximumResponseBytes = maximumResponseBytes
        self.responseAcceptedForTesting = responseAcceptedForTesting
    }

    func registerContinuation(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        let completed = result
        if completed == nil { self.continuation = continuation }
        lock.unlock()
        if let completed { continuation.resume(with: completed) }
    }

    func registerStartup(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = result != nil
        if !shouldCancel && !started { startupTask = task }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    /// The last authorization check and actual resume share one MainActor job.
    /// There is no suspension or already-started URLSession API between them.
    @MainActor
    func start(_ request: URLRequest, beforeStart: (@MainActor @Sendable () throws -> Void)?) {
        lock.lock(); let waiting = result == nil && !started; lock.unlock()
        guard waiting, !Task.isCancelled else { cancel(); return }
        do { try beforeStart?() } catch { failStartup(error); return }
        guard !Task.isCancelled else { cancel(); return }
        lock.lock()
        guard result == nil && !started else { lock.unlock(); return }
        started = true; startupTask = nil
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        self.session = session; dataTask = task
        task.resume()
        lock.unlock()
    }

    func cancel() { finish(.failure(CancellationError())) }
    func failStartup(_ error: Error) { finish(.failure(AssistantConversationStartupFailure(underlying: error))) }

    private func finish(_ completed: Result<Data, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = completed
        let continuation = self.continuation; self.continuation = nil
        let task = dataTask; dataTask = nil
        let session = self.session; self.session = nil
        let startup = startupTask; startupTask = nil
        body = Data()
        lock.unlock()
        // Native completion and continuation resumption may reenter cancellation.
        startup?.cancel(); task?.cancel(); session?.invalidateAndCancel()
        continuation?.resume(with: completed)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(AssistantConversationClientError.httpStatus(response.statusCode)))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse else { throw AssistantConversationClientError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw AssistantConversationClientError.httpStatus(http.statusCode) }
            guard http.statusCode == 200 || http.statusCode == 201 else { throw AssistantConversationClientError.invalidResponse }
            guard let mime = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                mime == "application/json" || (mime.hasPrefix("application/") && mime.hasSuffix("+json")) else {
                throw AssistantConversationClientError.unexpectedContentType
            }
            if let length = http.value(forHTTPHeaderField: "Content-Length") {
                guard let declared = Int64(length), declared >= 0 else { throw AssistantConversationClientError.invalidResponse }
                guard declared <= Int64(maximumResponseBytes) else { throw AssistantConversationClientError.responseTooLarge }
            }
        } catch { completionHandler(.cancel); finish(.failure(error)); return }
        lock.lock()
        let accept = result == nil && started
        if accept { responseAccepted = true }
        lock.unlock()
        completionHandler(accept ? .allow : .cancel)
        if accept { responseAcceptedForTesting?() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var failure: Error?
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        if !responseAccepted { failure = AssistantConversationClientError.invalidResponse }
        else if data.count > maximumResponseBytes - body.count { failure = AssistantConversationClientError.responseTooLarge }
        else { body.append(data) }
        lock.unlock()
        if let failure { finish(.failure(failure)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let accept = result == nil && responseAccepted
        let data = body
        lock.unlock()
        if accept { finish(.success(data)) }
        else { finish(.failure(AssistantConversationClientError.invalidResponse)) }
    }
}

final class AssistantConversationRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A redirect must never forward the session token to another route/origin.
        completionHandler(nil)
    }
}
