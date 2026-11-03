import Foundation

private struct ConversationTestFailure: Error, CustomStringConvertible { let description: String }
private enum ConversationAuthorizationFailure: Error, Equatable { case revoked, waitDenied }

@main private enum AssistantConversationClientTests {
    private static var suites = 0
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw ConversationTestFailure(description: message) }
    }
    private static func run(_ name: String, _ operation: () async throws -> Void) async throws {
        try await operation(); suites += 1; print("PASS \(name)")
    }
    private static func expectError(_ expected: AssistantConversationClientError, _ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch {
            guard error as? AssistantConversationClientError == expected else {
                throw ConversationTestFailure(description: "Expected \(expected), received \(error)")
            }
            return
        }
        throw ConversationTestFailure(description: "Expected failure \(expected)")
    }
    private static func setup(status: Int = 201, headers: [String: String] = ["Content-Type": "application/json; charset=utf-8"],
                              body: Data = Data(#"{"id":"server-id_1"}"#.utf8), hold: Bool = false, holdBeforeHeaders: Bool = false,
                              failure: URLError.Code? = nil, redirect: Bool = false, maximumResponseBytes: Int = 65_536,
                              responseAcceptedForTesting: (@Sendable () -> Void)? = nil) -> (AssistantConversationClient, String) {
        let id = ConversationFixtureURLProtocol.register(status: status, headers: headers, body: body,
            hold: hold, holdBeforeHeaders: holdBeforeHeaders, failure: failure, redirect: redirect)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConversationFixtureURLProtocol.self]
        let client = AssistantConversationClient(baseURL: URL(string: "https://conversation-fixtures.invalid/\(id)/api/v2")!,
            sessionConfiguration: configuration, maximumResponseBytes: maximumResponseBytes,
            responseAcceptedForTesting: responseAcceptedForTesting)
        return (client, id)
    }
    private static func create(_ client: AssistantConversationClient,
                               beforeStart: (@MainActor @Sendable () throws -> Void)? = nil,
                               beforeStartWait: (@MainActor @Sendable () async throws -> Void)? = nil) async throws -> String {
        try await client.create(accessToken: "fixture-access", clientConversationId: "local-id_1", title: "今天的计划 🌱", locale: "zh-Hans",
            beforeStart: beforeStart, beforeStartWait: beforeStartWait)
    }
    private static func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { throw ConversationTestFailure(description: "Timed out: " + label) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    static func main() async throws {
        try await run("conversation-raw-payload-idempotency-and-access-token") {
            let (client, id) = setup()
            let result = try await create(client)
            try expect(result == "server-id_1", "Return the actual server-assigned ID")
            let capture = ConversationFixtureURLProtocol.captured(id)!
            let request = capture.request
            try expect(request.httpMethod == "POST" && request.url?.path == "/\(id)/api/v2/conversations", "Creation route must preserve the configured API prefix")
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access", "Access token must be a single raw Bearer token")
            try expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "conversation.local-id_1", "Retries of the same client conversation must retain a stable key")
            try expect(request.value(forHTTPHeaderField: "Accept") == "application/json" && request.value(forHTTPHeaderField: "Content-Type") == "application/json", "Creation contract must use JSON")
            let body = try JSONSerialization.jsonObject(with: capture.body) as! [String: String]
            try expect(body == ["clientConversationId": "local-id_1", "title": "今天的计划 🌱", "locale": "zh-Hans"], "JSON must contain the unaltered explicit title, locale and client ID only")
            try expect(request.value(forHTTPHeaderField: "Cookie") == nil, "Creation must not send browser cookies")
        }
        try await run("conversation-200-201-and-application-json-suffix") {
            for status in [200, 201] {
                let (client, _) = setup(status: status, headers: ["Content-Type": "Application/Problem+JSON; charset=UTF-8"])
                let result = try await create(client)
                try expect(result == "server-id_1", "Valid JSON success must decode")
            }
        }
        try await run("conversation-invalid-input-never-starts-network") {
            let cases: [(String, String, String, String)] = [
                ("", "local-id", "title", "en"), ("token with spaces", "local-id", "title", "en"),
                ("token\r\nInjected:header", "local-id", "title", "en"), (String(repeating: "x", count: 16_385), "local-id", "title", "en"),
                ("fixture", "", "title", "en"), ("fixture", "../other", "title", "en"),
                ("fixture", "id?query", "title", "en"), ("fixture", "用户", "title", "en"),
                ("fixture", String(repeating: "x", count: 129), "title", "en"),
                ("fixture", "local-id", "bad\0title", "en"), ("fixture", "local-id", String(repeating: "x", count: 1_025), "en"),
                ("fixture", "local-id", "title", ""), ("fixture", "local-id", "title", " en"),
                ("fixture", "local-id", "title", "en\nUS"), ("fixture", "local-id", "title", "中文")
            ]
            for value in cases {
                let (client, id) = setup()
                try await expectError(.invalidInput) {
                    _ = try await client.create(accessToken: value.0, clientConversationId: value.1, title: value.2, locale: value.3)
                }
                try expect(ConversationFixtureURLProtocol.captured(id) == nil, "Invalid arguments must fail before transport")
            }
        }
        try await run("conversation-invalid-configuration-never-starts-network") {
            for base in ["http://conversation-fixtures.invalid/api/v2", "https://user:secret@conversation-fixtures.invalid/api/v2",
                         "https://conversation-fixtures.invalid/api/v2?key=secret", "https://conversation-fixtures.invalid/api/v2#fragment"] {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [ConversationFixtureURLProtocol.self]
                let client = AssistantConversationClient(baseURL: URL(string: base)!, sessionConfiguration: configuration)
                try await expectError(.invalidConfiguration) { _ = try await create(client) }
            }
            let (client, id) = setup(maximumResponseBytes: 0)
            try await expectError(.invalidConfiguration) { _ = try await create(client) }
            try expect(ConversationFixtureURLProtocol.captured(id) == nil, "An invalid response limit must not open a request")
        }
        try await run("conversation-strict-http-statuses") {
            for status in [301, 302, 307, 308, 400, 401, 403, 409, 429, 500] {
                let (client, _) = setup(status: status, body: Data("private upstream response".utf8))
                try await expectError(.httpStatus(status)) { _ = try await create(client) }
            }
            for status in [202, 204, 206] {
                let (client, _) = setup(status: status)
                try await expectError(.invalidResponse) { _ = try await create(client) }
            }
        }
        try await run("conversation-json-mime-required") {
            for headers in [[:], ["Content-Type": "text/html"], ["Content-Type": "text/json"], ["Content-Type": "text/event-stream"]] {
                let (client, _) = setup(headers: headers)
                try await expectError(.unexpectedContentType) { _ = try await create(client) }
            }
        }
        try await run("conversation-server-id-and-json-validation") {
            let ids = ["", " ", "server/id", "../other", "id?query", "id#fragment", "id.with.dot", "用户", "line\nbreak", String(repeating: "a", count: 129)]
            for id in ids {
                let body = try JSONSerialization.data(withJSONObject: ["id": id])
                let (client, _) = setup(body: body)
                try await expectError(.invalidResponse) { _ = try await create(client) }
            }
            for json in ["", "{bad-json", "[]", "{}", "{\"id\":123}", "null"] {
                let (client, _) = setup(body: Data(json.utf8))
                try await expectError(.invalidResponse) { _ = try await create(client) }
            }
            let longest = String(repeating: "z", count: 128)
            let (valid, _) = setup(body: try JSONSerialization.data(withJSONObject: ["id": longest]))
            let result = try await create(valid)
            try expect(result == longest, "The documented 128-byte identifier boundary must be supported")
        }
        try await run("conversation-declared-and-streaming-response-limits") {
            let (declared, _) = setup(headers: ["Content-Type": "application/json", "Content-Length": "65537"])
            try await expectError(.responseTooLarge) { _ = try await create(declared) }
            let (streamed, _) = setup(body: Data(repeating: 32, count: 65_537))
            try await expectError(.responseTooLarge) { _ = try await create(streamed) }
            for length in ["-1", "invalid", "99999999999999999999999999"] {
                let (client, _) = setup(headers: ["Content-Type": "application/json", "Content-Length": length])
                try await expectError(.invalidResponse) { _ = try await create(client) }
            }
            let (hardCap, _) = setup(headers: ["Content-Type": "application/json", "Content-Length": "1048577"], maximumResponseBytes: 4_194_304)
            try await expectError(.responseTooLarge) { _ = try await create(hardCap) }
            let json = Data(#"{"id":"a"}"#.utf8)
            let (exact, _) = setup(body: json, maximumResponseBytes: json.count)
            let result = try await create(exact)
            try expect(result == "a", "Exactly-at-limit valid response must remain accepted")
            let (oneOver, _) = setup(body: json + Data(" ".utf8), maximumResponseBytes: json.count)
            try await expectError(.responseTooLarge) { _ = try await create(oneOver) }
        }
        try await run("conversation-network-errors-do-not-expose-response-or-token") {
            let (client, _) = setup(failure: .notConnectedToInternet)
            try await expectError(.networkUnavailable) { _ = try await create(client) }
            let message = AssistantConversationClientError.httpStatus(500).localizedDescription
            try expect(!message.contains("fixture-access") && !message.contains("private upstream"), "Errors must remain safe and not echo transport data")
        }
        try await run("conversation-cancel-after-response-headers-closes-request") {
            try await cancellation(beforeHeaders: false)
        }
        try await run("conversation-cancel-before-response-headers-closes-request") {
            try await cancellation(beforeHeaders: true)
        }
        try await run("conversation-redirect-does-not-forward-access-token") {
            let (client, id) = setup(status: 307, redirect: true)
            do {
                _ = try await create(client)
                throw ConversationTestFailure(description: "Redirect must not produce a created conversation")
            } catch let error as AssistantConversationClientError {
                // Darwin URLProtocol may finish an explicitly refused custom redirect
                // as a URL loading error instead of returning the original 307 body.
                try expect(error == .httpStatus(307) || error == .networkUnavailable, "Refused redirect must return a safe transport failure")
            }
            try expect(ConversationFixtureURLProtocol.requestCount(id) == 1, "No redirect target may receive another request or access token")
        }
        try await run("conversation-redirect-policy-rejects-same-origin-and-cross-origin") {
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let original = URL(string: "https://conversation-fixtures.invalid/api/v2/conversations")!
            let response = HTTPURLResponse(url: original, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: nil)!
            let task = session.dataTask(with: original) // Never resumed; no network access.
            for target in ["https://conversation-fixtures.invalid/other-route", "https://other-fixtures.invalid/stolen-token"] {
                var redirected = URLRequest(url: URL(string: target)!)
                redirected.setValue("Bearer fixture-access", forHTTPHeaderField: "Authorization")
                var called = false, approved = false
                AssistantConversationRedirectGuard().urlSession(session, task: task, willPerformHTTPRedirection: response,
                    newRequest: redirected, completionHandler: { request in called = true; approved = request != nil })
                try expect(called && !approved, "The actual session delegate policy must explicitly deny both redirect classes")
            }
            task.cancel()
        }
        try await run("conversation-pre-cancelled-task-never-starts-request") {
            let (client, id) = setup()
            let task = Task { () -> Error? in
                withUnsafeCurrentTask { $0?.cancel() }
                do { _ = try await create(client); return nil } catch { return error }
            }
            let error = await task.value
            try expect(error is CancellationError && ConversationFixtureURLProtocol.captured(id) == nil, "An already-cancelled task must not open a request")
        }
        try await run("conversation-wait-gate-holds-title-and-token-before-http") {
            let (client, id) = setup(), gate = ConversationStartGate()
            let task = Task { try await create(client, beforeStart: { try gate.checkAuthorization() }, beforeStartWait: { await gate.wait() }) }
            defer { gate.release(); task.cancel() }
            try await wait("creation waiting before HTTP") { gate.isWaiting }
            try expect(gate.checkCount == 0 && ConversationFixtureURLProtocol.requestCount(id) == 0, "Waiting must not run the final check or disclose the title/token")
            gate.release()
            let result = try await task.value
            try expect(result == "server-id_1" && gate.checkCount == 1 && ConversationFixtureURLProtocol.requestCount(id) == 1, "Only released and finally authorized creation may start once")
        }
        try await run("conversation-wait-failure-preserves-original-error-with-zero-http") {
            let (client, id) = setup(), gate = ConversationStartGate()
            do {
                _ = try await create(client, beforeStart: { try gate.checkAuthorization() },
                    beforeStartWait: { throw ConversationAuthorizationFailure.waitDenied })
                throw ConversationTestFailure(description: "Expected the caller's wait failure")
            } catch let error as ConversationAuthorizationFailure {
                try expect(error == .waitDenied, "Wait authorization errors must remain unchanged")
            }
            try expect(gate.checkCount == 0 && ConversationFixtureURLProtocol.requestCount(id) == 0, "A failed wait must never reach final authorization or HTTP")
        }
        try await run("conversation-revocation-during-wait-is-checked-at-actual-start") {
            let (client, id) = setup(), gate = ConversationStartGate()
            let task = Task { () -> Error? in
                do { _ = try await create(client, beforeStart: { try gate.checkAuthorization() }, beforeStartWait: { await gate.wait() }); return nil }
                catch { return error }
            }
            defer { gate.release(); task.cancel() }
            try await wait("creation awaiting revocation gate") { gate.isWaiting }
            gate.revoke(); gate.release()
            let error = await task.value
            try expect(error as? ConversationAuthorizationFailure == .revoked, "The caller's exact revocation error must escape")
            try expect(gate.checkCount == 1 && ConversationFixtureURLProtocol.requestCount(id) == 0, "Revoked title/token must not reach even one HTTP request")
        }
        try await run("conversation-final-hook-url-error-is-not-remapped") {
            let (client, id) = setup()
            do {
                _ = try await create(client, beforeStart: { throw URLError(.cancelled) })
                throw ConversationTestFailure(description: "Expected the caller's URLError")
            } catch let error as URLError {
                try expect(error.code == .cancelled, "A caller hook's URLError must not become generic network failure or CancellationError")
            }
            try expect(ConversationFixtureURLProtocol.requestCount(id) == 0, "A throwing final check must start zero HTTP")
        }
        try await run("conversation-cancel-while-queued-in-wait-starts-zero-http") {
            let (client, id) = setup(), gate = ConversationStartGate()
            let task = Task { () -> Error? in
                do { _ = try await create(client, beforeStart: { try gate.checkAuthorization() }, beforeStartWait: { await gate.wait() }); return nil }
                catch { return error }
            }
            defer { gate.release(); task.cancel() }
            try await wait("queued creation wait") { gate.isWaiting }
            task.cancel()
            let error = await task.value
            try expect(error is CancellationError, "Cancellation must finish even when a wait ignores cancellation")
            gate.release()
            try await wait("cancelled wait continuation released") { gate.didReturnFromWait }
            await MainActor.run {}
            try expect(gate.checkCount == 0 && ConversationFixtureURLProtocol.requestCount(id) == 0, "Releasing a cancelled queued start must not run its check or HTTP")
        }
        try await run("conversation-cancel-inside-final-check-starts-zero-http") {
            let (client, id) = setup()
            do {
                _ = try await create(client, beforeStart: { withUnsafeCurrentTask { $0?.cancel() } })
                throw ConversationTestFailure(description: "Expected cancellation from final startup task")
            } catch is CancellationError {}
            try expect(ConversationFixtureURLProtocol.requestCount(id) == 0, "Cancellation between the synchronous check and resume must win")
        }
        print("All \(suites) AssistantConversationClient suites passed; every URL intercepted, no real network or credentials.")
    }

    private static func cancellation(beforeHeaders: Bool) async throws {
        let gate = ConversationStartGate()
        let (client, id) = setup(body: Data("{".utf8), hold: true, holdBeforeHeaders: beforeHeaders,
            responseAcceptedForTesting: { gate.markResponseAccepted() })
        let operation = Task { () -> Error? in
            do { _ = try await create(client); return nil } catch { return error }
        }
        try await wait("started creation") { ConversationFixtureURLProtocol.captured(id) != nil }
        if !beforeHeaders { try await wait("native response headers accepted") { gate.responseWasAccepted } }
        operation.cancel()
        let error = await operation.value
        try expect(error is CancellationError, "Creation cancellation must return CancellationError")
        try await wait("URLProtocol stopLoading") { ConversationFixtureURLProtocol.stopped(id) }
    }
}

/// Explicit handshakes keep startup/cancellation tests independent of sleeps or
/// native URL loading callback timing. The wait intentionally ignores cancel.
private final class ConversationStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = false, released = false, revoked = false, waitReturned = false, responseAccepted = false
    private var checks = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try operation()
    }
    var isWaiting: Bool { withLock { waiting } }
    var didReturnFromWait: Bool { withLock { waitReturned } }
    var checkCount: Int { withLock { checks } }
    var responseWasAccepted: Bool { withLock { responseAccepted } }
    func markResponseAccepted() { withLock { responseAccepted = true } }
    func revoke() { withLock { revoked = true } }
    func checkAuthorization() throws {
        try withLock { checks += 1; if revoked { throw ConversationAuthorizationFailure.revoked } }
    }
    func wait() async {
        await withCheckedContinuation { (value: CheckedContinuation<Void, Never>) in
            let resume = withLock { waiting = true; if released { return true }; continuation = value; return false }
            if resume { value.resume() }
        }
        withLock { waitReturned = true }
    }
    func release() {
        let value = withLock { released = true; let value = continuation; continuation = nil; return value }
        value?.resume()
    }
}

private final class ConversationFixtureURLProtocol: URLProtocol {
    struct Captured { let request: URLRequest; let body: Data }
    private struct Fixture {
        let status: Int
        let headers: [String: String]
        let body: Data
        let hold: Bool
        let holdBeforeHeaders: Bool
        let failure: URLError.Code?
        let redirect: Bool
    }
    private static let lock = NSLock()
    private static var fixtures: [String: Fixture] = [:]
    private static var captures: [String: Captured] = [:]
    private static var requestCounts: [String: Int] = [:]
    private static var stoppedIds: Set<String> = []
    static func register(status: Int, headers: [String: String], body: Data, hold: Bool, holdBeforeHeaders: Bool,
                         failure: URLError.Code?, redirect: Bool) -> String {
        let id = UUID().uuidString
        lock.lock(); defer { lock.unlock() }
        fixtures[id] = Fixture(status: status, headers: headers, body: body, hold: hold,
            holdBeforeHeaders: holdBeforeHeaders, failure: failure, redirect: redirect)
        return id
    }
    static func captured(_ id: String) -> Captured? { lock.lock(); defer { lock.unlock() }; return captures[id] }
    static func requestCount(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return requestCounts[id] ?? 0 }
    static func stopped(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return stoppedIds.contains(id) }
    private var fixtureId: String? { request.url?.pathComponents.dropFirst().first }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = fixtureId else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        Self.lock.lock(); let fixture = Self.fixtures[id]; Self.lock.unlock()
        guard let fixture else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        let body = request.httpBody ?? readBodyStream()
        Self.lock.lock()
        Self.captures[id] = Captured(request: request, body: body)
        Self.requestCounts[id, default: 0] += 1
        Self.lock.unlock()
        if let failure = fixture.failure { client?.urlProtocol(self, didFailWithError: URLError(failure)); return }
        if fixture.holdBeforeHeaders { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
        if fixture.redirect {
            // Exercise the real URLSession redirection callback, rather than only returning a 3xx status.
            var target = request
            target.url = URL(string: "https://redirected-fixtures.invalid/\(id)/stolen-token")!
            client?.urlProtocol(self, wasRedirectedTo: target, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if fixture.hold { return }
        for offset in stride(from: 0, to: fixture.body.count, by: 257) {
            client?.urlProtocol(self, didLoad: fixture.body.subdata(in: offset..<min(offset + 257, fixture.body.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        if let id = fixtureId { Self.lock.lock(); Self.stoppedIds.insert(id); Self.lock.unlock() }
    }
    private func readBodyStream() -> Data {
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { return data }
            data.append(buffer, count: count)
            if data.count > 1_048_576 { return data }
        }
    }
}
