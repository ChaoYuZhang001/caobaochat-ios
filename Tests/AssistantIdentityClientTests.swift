import Foundation

private struct IdentityTestFailure: Error, CustomStringConvertible { let description: String }

@main
private enum AssistantIdentityClientTests {
    private static let fixedNow = Date(timeIntervalSince1970: 1_793_232_000)
    private static let fixtureJWT = "fixture_header.fixture_payload.fixture_signature"
    private static let fixtureNonce = "0123456789abcdef0123456789abcdef"
    private static var suites = 0

    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try value() == false { throw IdentityTestFailure(description: message) }
    }
    private static func expectError(_ expected: AssistantIdentityClientError, _ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch {
            guard error as? AssistantIdentityClientError == expected else {
                throw IdentityTestFailure(description: "Expected \(expected), received \(error)")
            }
            return
        }
        throw IdentityTestFailure(description: "Expected operation to fail with \(expected)")
    }
    private static func run(_ name: String, _ body: () async throws -> Void) async throws {
        try await body(); suites += 1; print("PASS \(name)")
    }
    private static func iso(_ date: Date, fractional: Bool = true) -> String {
        let formatter = ISO8601DateFormatter()
        if fractional { formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
        return formatter.string(from: date)
    }
    private static func identity(userId: String = "account-A", access: String = "fixture-access",
                                 refresh: String = "fixture-refresh", expiration: String? = nil) -> [String: Any] {
        ["user": ["id": userId, "displayName": "Fixture User"],
         "session": ["accessToken": access, "refreshToken": refresh,
                     "expiresAt": expiration ?? iso(fixedNow.addingTimeInterval(3_600))]]
    }
    private static func encoded(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private static func setup(status: Int = 200, headers: [String: String] = ["Content-Type": "application/json; charset=utf-8"],
                              body: Data? = nil, hold: Bool = false, failure: URLError.Code? = nil,
                              maximumExportBytes: Int = 8 * 1024 * 1024) throws -> (AssistantIdentityClient, String) {
        let id = IdentityFixtureURLProtocol.register(status: status, headers: headers,
            body: try body ?? encoded(identity()), hold: hold, failure: failure)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IdentityFixtureURLProtocol.self]
        let client = AssistantIdentityClient(baseURL: URL(string: "https://identity-fixtures.invalid/\(id)/api/v2")!,
            sessionConfiguration: config, now: { fixedNow }, maximumExportBytes: maximumExportBytes)
        return (client, id)
    }
    private static func signIn(_ client: AssistantIdentityClient, storefront: String? = nil, timeZone: String? = nil) async throws -> AssistantIdentityResponse {
        try await client.signInApple(identityToken: fixtureJWT, authorizationCode: "fixture-code+raw/=",
            nonce: fixtureNonce, locale: "zh-Hans", storefront: storefront, timeZone: timeZone)
    }
    private static func captured(_ id: String) throws -> IdentityFixtureURLProtocol.Captured {
        guard let request = IdentityFixtureURLProtocol.captured(id) else {
            throw IdentityTestFailure(description: "Fixture request did not execute")
        }
        return request
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IdentityTestFailure(description: "Expected JSON object")
        }
        return object
    }

    static func main() async throws {
        try await run("raw-owner-helper-preserves-absence-and-opaque-unicode") {
            let pairs = [
                ("caf\u{00E9}", "cafe\u{0301}"),
                ("a\u{0301}\u{0327}", "a\u{0327}\u{0301}"),
                ("\u{212B}", "\u{00C5}")
            ]
            try expect(AssistantOwnerIdentity.matches(nil, nil), "Both absent owners retain absence semantics")
            try expect(!AssistantOwnerIdentity.matches(nil, "") && !AssistantOwnerIdentity.matches("", nil), "Absent owner must differ from an empty owner")
            try expect(AssistantOwnerIdentity.matches("", "") && AssistantOwnerIdentity.matches("account-A", "account-A"), "Identical raw owners must match")
            try expect(!AssistantOwnerIdentity.matches("account-A", "account-a"), "Owner matching must remain case-sensitive")
            for (left, right) in pairs {
                try expect(left == right && !left.utf8.elementsEqual(right.utf8), "Fixture must exercise Swift canonical equivalence with distinct bytes")
                try expect(!AssistantOwnerIdentity.matches(left, right) && !AssistantOwnerIdentity.matches(right, left), "Canonical aliases must remain different owners in both directions")
                try expect(AssistantOwnerIdentity.matches(left, left) && AssistantOwnerIdentity.matches(right, right), "Each raw identity must match itself")
                try expect(AssistantOwnerIdentity.ownerKey(left) != AssistantOwnerIdentity.ownerKey(right), "Canonical aliases must have separate runtime keys")
                try expect(Data(base64Encoded: AssistantOwnerIdentity.ownerKey(left)) == Data(left.utf8)
                    && Data(base64Encoded: AssistantOwnerIdentity.ownerKey(right)) == Data(right.utf8), "Runtime keys must preserve exact original identity bytes")
            }
        }
        try await run("refresh-rejects-canonically-equivalent-byte-different-owner") {
            let composed = "caf\u{00E9}", decomposed = "cafe\u{0301}"
            for (expected, received) in [(composed, decomposed), (decomposed, composed)] {
                let (client, id) = try setup(body: encoded(identity(userId: received)))
                try await expectError(.identityMismatch) {
                    _ = try await client.refresh(refreshToken: "fixture-refresh", expectedUserId: expected)
                }
                try expect(IdentityFixtureURLProtocol.captured(id) != nil, "Identity mismatch must validate the actual intercepted response")
            }
        }
        try await run("refresh-accepts-identical-raw-unicode-owner") {
            for owner in ["caf\u{00E9}", "cafe\u{0301}", "\u{212B}", "\u{00C5}"] {
                let (client, id) = try setup(body: encoded(identity(userId: owner)))
                let result = try await client.refresh(refreshToken: "fixture-refresh", expectedUserId: owner)
                try expect(result.user.id.utf8.elementsEqual(owner.utf8), "Refresh must retain identical raw Unicode owner bytes")
                try expect(IdentityFixtureURLProtocol.captured(id) != nil, "Same-owner allowance must exercise the real response decoder")
            }
        }
        try await run("apple-raw-credentials-payload-and-headers") {
            let (client, id) = try setup()
            let result = try await signIn(client, storefront: "chn")
            try expect(result.user.id == "account-A" && result.user.displayName == "Fixture User", "Identity must decode")
            try expect(result.session.expiresAt == fixedNow.addingTimeInterval(3_600), "Fractional ISO expiry must decode")
            let capture = try captured(id)
            try expect(capture.request.url?.path.hasSuffix("/api/v2/auth/apple") == true && capture.request.httpMethod == "POST", "Apple route and method must match v2")
            try expect(capture.request.value(forHTTPHeaderField: "Accept") == "application/json", "Apple must accept JSON")
            try expect(capture.request.value(forHTTPHeaderField: "Content-Type") == "application/json", "Apple payload must be JSON")
            try expect(capture.request.value(forHTTPHeaderField: "Authorization") == nil, "Apple exchange must not receive an unrelated Bearer token")
            let body = try object(capture.body)
            try expect(body["identityToken"] as? String == fixtureJWT, "JWT must remain raw UTF-8, not Base64 encoded again")
            try expect(body["authorizationCode"] as? String == "fixture-code+raw/=", "Authorization code must remain raw")
            try expect(body["nonce"] as? String == fixtureNonce, "Original nonce must reach server for binding verification")
            try expect(body["storefront"] as? String == "CHN" && body["locale"] as? String == "zh-Hans", "Storefront must normalize and locale must remain explicit")
            try expect(Set(body.keys) == ["identityToken", "authorizationCode", "nonce", "storefront", "locale"], "Exchange must not append local user/profile/secrets")
        }
        try await run("apple-time-zone-is-explicit-and-validated") {
            let (client, id) = try setup()
            _ = try await signIn(client, timeZone: "Asia/Shanghai")
            let body = try object(captured(id).body)
            try expect(body["timeZone"] as? String == "Asia/Shanghai", "Apple login must bind the account's IANA timezone")
            let (invalid, invalidId) = try setup()
            try await expectError(.invalidInput) {
                _ = try await invalid.signInApple(identityToken: fixtureJWT, authorizationCode: "code", nonce: fixtureNonce,
                    locale: "en", timeZone: "GMT+8")
            }
            try expect(IdentityFixtureURLProtocol.captured(invalidId) == nil, "Fixed-offset timezone must be rejected before transport")
        }
        try await run("apple-nil-storefront-and-created-status") {
            let (client, id) = try setup(status: 201)
            _ = try await signIn(client)
            try expect(try object(captured(id).body)["storefront"] == nil, "Unknown storefront must be omitted rather than invented")
            let nonFractional = identity(expiration: iso(fixedNow.addingTimeInterval(60), fractional: false))
            let (second, _) = try setup(body: encoded(nonFractional))
            let nonFractionalResult = try await signIn(second)
            try expect(nonFractionalResult.session.expiresAt == fixedNow.addingTimeInterval(60), "Nonfractional ISO expiry must decode")
        }
        try await run("invalid-apple-input-never-starts-request") {
            let values: [(String, String, String, String, String?)] = [
                ("", "code", fixtureNonce, "en", nil),
                (Data(fixtureJWT.utf8).base64EncodedString(), "code", fixtureNonce, "en", nil),
                ("header..signature", "code", fixtureNonce, "en", nil),
                ("header.payload.signature.overflow", "code", fixtureNonce, "en", nil),
                ("head/er.payload.signature", "code", fixtureNonce, "en", nil),
                (fixtureJWT, "code with spaces", fixtureNonce, "en", nil),
                (fixtureJWT, String(repeating: "x", count: 8_193), fixtureNonce, "en", nil),
                (fixtureJWT, "code", "short", "en", nil),
                (fixtureJWT, "code", String(repeating: "x", count: 257), "en", nil),
                (fixtureJWT, "code", fixtureNonce, " en", nil),
                (fixtureJWT, "code", fixtureNonce, "en\nUS", nil),
                (fixtureJWT, "code", fixtureNonce, "en", "CN"),
                (fixtureJWT, "code", fixtureNonce, "en", "1US")
            ]
            for value in values {
                let (client, id) = try setup()
                try await expectError(.invalidInput) {
                    _ = try await client.signInApple(identityToken: value.0, authorizationCode: value.1, nonce: value.2, locale: value.3, storefront: value.4)
                }
                try expect(IdentityFixtureURLProtocol.captured(id) == nil, "Invalid input must be rejected before any network transport")
            }
        }
        try await run("identity-response-fields-are-strict") {
            var responses: [[String: Any]] = [
                identity(userId: ""), identity(userId: " account-A"),
                identity(access: ""), identity(access: "contains whitespace"),
                identity(refresh: ""), identity(refresh: String(repeating: "x", count: 16_385)),
                identity(expiration: "not-a-date")
            ]
            var missingSession = identity(); missingSession.removeValue(forKey: "session"); responses.append(missingSession)
            var missingUserId = identity(); missingUserId["user"] = ["displayName": "Fixture"]; responses.append(missingUserId)
            var badName = identity(); badName["user"] = ["id": "A", "displayName": "bad\0name"]; responses.append(badName)
            for response in responses {
                let (client, _) = try setup(body: encoded(response))
                try await expectError(.invalidResponse) { _ = try await signIn(client) }
            }
            for value in [Data("[]".utf8), Data("{bad-json".utf8), Data()] {
                let (client, _) = try setup(body: value)
                try await expectError(.invalidResponse) { _ = try await signIn(client) }
            }
        }
        try await run("expiry-boundary-and-refresh-owner") {
            for expiration in [fixedNow.addingTimeInterval(-1), fixedNow] {
                let (client, _) = try setup(body: encoded(identity(expiration: iso(expiration))))
                try await expectError(.expiredSession) { _ = try await signIn(client) }
            }
            let (mismatch, _) = try setup(body: encoded(identity(userId: "account-B")))
            try await expectError(.identityMismatch) { _ = try await mismatch.refresh(refreshToken: "fixture-refresh", expectedUserId: "account-A") }
            let (client, id) = try setup()
            let refreshed = try await client.refresh(refreshToken: "fixture-refresh-old", expectedUserId: "account-A")
            try expect(refreshed.user.id == "account-A", "Same owner refresh must succeed")
            let capture = try captured(id)
            try expect(capture.request.httpMethod == "POST" && capture.request.url?.path.hasSuffix("/auth/refresh") == true, "Refresh route must match")
            try expect(capture.request.value(forHTTPHeaderField: "Authorization") == nil, "Refresh must use its body, not leak unrelated access token")
            let body = try object(capture.body)
            try expect(Set(body.keys) == ["refreshToken"] && body["refreshToken"] as? String == "fixture-refresh-old", "Refresh request must contain only the original refresh token")
        }
        try await run("http-status-and-content-type-contracts") {
            for status in [302, 400, 401, 403, 409, 429, 500] {
                let (client, _) = try setup(status: status, body: Data("private failure detail".utf8))
                try await expectError(.httpStatus(status)) { _ = try await signIn(client) }
            }
            for status in [202, 204, 206] {
                let (client, _) = try setup(status: status)
                try await expectError(.invalidResponse) { _ = try await signIn(client) }
            }
            for headers in [[:], ["Content-Type": "text/html"], ["Content-Type": "text/json"]] {
                let (client, _) = try setup(headers: headers)
                try await expectError(.unexpectedContentType) { _ = try await signIn(client) }
            }
            let (problemJSON, _) = try setup(headers: ["Content-Type": "Application/Problem+JSON; charset=UTF-8"])
            _ = try await signIn(problemJSON)
            let (refreshCreated, _) = try setup(status: 201)
            try await expectError(.invalidResponse) { _ = try await refreshCreated.refresh(refreshToken: "fixture-refresh") }
        }
        try await run("response-byte-limits-declared-and-streamed") {
            let (declared, _) = try setup(headers: ["Content-Type": "application/json", "Content-Length": "1048577"])
            try await expectError(.responseTooLarge) { _ = try await signIn(declared) }
            let oversized = try encoded(identity()) + Data(repeating: 32, count: 1_048_577)
            let (streamed, _) = try setup(body: oversized)
            try await expectError(.responseTooLarge) { _ = try await signIn(streamed) }
            for value in ["-1", "invalid"] {
                let (client, _) = try setup(headers: ["Content-Type": "application/json", "Content-Length": value])
                try await expectError(.invalidResponse) { _ = try await signIn(client) }
            }
        }
        try await run("revoke-authentication-and-json-acknowledgement") {
            let (client, id) = try setup(status: 204, headers: [:], body: Data())
            try await client.revoke(accessToken: "fixture-access")
            let request = try captured(id).request
            try expect(request.httpMethod == "POST" && request.url?.path.hasSuffix("/auth/logout") == true, "Revoke route and method must match")
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access", "Revoke must be authenticated")
            try expect(try captured(id).body.isEmpty, "Revoke must not resend refresh tokens or profile data")
            let (acknowledgement, _) = try setup(body: Data("{\"revoked\":true}".utf8))
            try await acknowledgement.revoke(accessToken: "fixture-access")
            let (invalidAck, _) = try setup(body: Data("123".utf8))
            try await expectError(.invalidResponse) { try await invalidAck.revoke(accessToken: "fixture-access") }
            let (emptyToken, noRequest) = try setup()
            try await expectError(.invalidInput) { try await emptyToken.revoke(accessToken: "") }
            try expect(IdentityFixtureURLProtocol.captured(noRequest) == nil, "Empty token must not start a request")
        }
        try await run("deletion-accepted-is-not-completed") {
            for status in ["queued", "accepted", "pending", "processing"] {
                let (client, id) = try setup(status: 202, body: encoded(["deletionRequestId": "delete-job", "status": status]))
                let result = try await client.requestDeletion(accessToken: "fixture-access")
                try expect(result.status.rawValue == status && result.deletionRequestId == "delete-job", "Accepted deletion must keep actual job state")
                let request = try captured(id).request
                try expect(request.httpMethod == "DELETE" && request.url?.path.hasSuffix("/api/v2/me") == true, "Deletion route must match v2")
                try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access", "Deletion must be authenticated")
            }
            let (dishonest, _) = try setup(status: 202, body: encoded(["deletionRequestId": "delete-job", "status": "completed"]))
            try await expectError(.invalidResponse) { _ = try await dishonest.requestDeletion(accessToken: "fixture-access") }
            let (completed, _) = try setup(status: 200, body: encoded(["deletionRequestId": "delete-job", "status": "completed"]))
            let deletionResult = try await completed.requestDeletion(accessToken: "fixture-access")
            try expect(deletionResult.status == .completed, "Only a completed response status may report completed")
            for data in [try encoded(["deletionRequestId": "", "status": "accepted"]), try encoded(["deletionRequestId": "job", "status": "deleted"])] {
                let (client, _) = try setup(status: 202, body: data)
                try await expectError(.invalidResponse) { _ = try await client.requestDeletion(accessToken: "fixture-access") }
            }
        }
        try await run("deletion-status-uses-status-only-capability") {
            let updated = iso(fixedNow)
            let completed = iso(fixedNow.addingTimeInterval(60))
            let (client, id) = try setup(body: encoded([
                "deletionRequestId": "del_status-job",
                "status": "completed",
                "updatedAt": updated,
                "completedAt": completed
            ]))
            let result = try await client.deletionStatus(requestId: "del_status-job")
            try expect(result.deletionRequestId == "del_status-job" && result.status == .completed,
                       "Status endpoint must return the server result")
            try expect(result.updatedAt == fixedNow && result.completedAt == fixedNow.addingTimeInterval(60),
                       "Status dates must decode")
            let request = try captured(id).request
            try expect(request.httpMethod == "GET" && request.url?.path.hasSuffix("/api/v2/deletions/del_status-job") == true,
                       "Status route must match v2")
            try expect(request.value(forHTTPHeaderField: "Authorization") == nil,
                       "Status capability must not forward a revoked account token")
            for invalid in ["", "job", "del_/escape", "del_\nstatus"] {
                let (invalidClient, invalidId) = try setup()
                try await expectError(.invalidInput) { _ = try await invalidClient.deletionStatus(requestId: invalid) }
                try expect(IdentityFixtureURLProtocol.captured(invalidId) == nil,
                           "Invalid status capability must not start a request")
            }
            let (mismatch, _) = try setup(body: encoded([
                "deletionRequestId": "del_other", "status": "pending", "updatedAt": updated
            ]))
            try await expectError(.invalidResponse) { _ = try await mismatch.deletionStatus(requestId: "del_status-job") }
        }
        try await run("export-retains-original-json-and-is-bounded") {
            let raw = Data(" { \"data\": [1,2], \"text\": \"你好\" } \n".utf8)
            let (client, id) = try setup(body: raw, maximumExportBytes: 256)
            let exportResult = try await client.export(accessToken: "fixture-access")
            try expect(exportResult == raw, "Export must retain original JSON bytes")
            let request = try captured(id).request
            try expect(request.httpMethod == "GET" && request.url?.path.hasSuffix("/me/export") == true, "Export route and method must match")
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access" && request.value(forHTTPHeaderField: "Accept") == "application/json", "Export must be authenticated and accept JSON")
            let (array, _) = try setup(body: Data("[1,2,3]".utf8))
            _ = try await array.export(accessToken: "fixture-access")
            let (scalar, _) = try setup(body: Data("true".utf8))
            try await expectError(.invalidResponse) { _ = try await scalar.export(accessToken: "fixture-access") }
            let (oversized, _) = try setup(body: Data(repeating: 32, count: 129), maximumExportBytes: 128)
            try await expectError(.responseTooLarge) { _ = try await oversized.export(accessToken: "fixture-access") }
            let (hardCap, _) = try setup(headers: ["Content-Type": "application/json", "Content-Length": "8388609"], maximumExportBytes: 20 * 1024 * 1024)
            try await expectError(.responseTooLarge) { _ = try await hardCap.export(accessToken: "fixture-access") }
            let (disabled, noRequest) = try setup(maximumExportBytes: 0)
            try await expectError(.invalidConfiguration) { _ = try await disabled.export(accessToken: "fixture-access") }
            try expect(IdentityFixtureURLProtocol.captured(noRequest) == nil, "Invalid export cap must not start a request")
        }
        try await run("invalid-base-url-and-safe-network-errors") {
            for base in ["http://identity-fixtures.invalid/api/v2", "https://user:password@identity-fixtures.invalid/api/v2",
                         "https://identity-fixtures.invalid/api/v2?q=secret", "https://identity-fixtures.invalid/api/v2#fragment"] {
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IdentityFixtureURLProtocol.self]
                let client = AssistantIdentityClient(baseURL: URL(string: base)!, sessionConfiguration: config, now: { fixedNow })
                try await expectError(.invalidConfiguration) { _ = try await signIn(client) }
            }
            let (client, _) = try setup(failure: .notConnectedToInternet)
            try await expectError(.networkUnavailable) { _ = try await signIn(client) }
            let message = AssistantIdentityClientError.httpStatus(500).localizedDescription
            try expect(!message.contains("fixture-access") && !message.contains("private response"), "Errors must not echo transport secrets")
        }
        try await run("cancellation-closes-underlying-request") {
            let (client, id) = try setup(hold: true)
            let operation = Task { () -> Error? in
                do { _ = try await client.export(accessToken: "fixture-access"); return nil }
                catch { return error }
            }
            for _ in 0..<100 {
                if IdentityFixtureURLProtocol.captured(id) != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try expect(IdentityFixtureURLProtocol.captured(id) != nil, "Cancellation must exercise a started request")
            operation.cancel()
            let result = await operation.value
            try expect(result is CancellationError, "Cancelled identity request must return CancellationError")
            for _ in 0..<100 {
                if IdentityFixtureURLProtocol.stopped(id) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try expect(IdentityFixtureURLProtocol.stopped(id), "Cancellation must invoke URLProtocol.stopLoading")
        }
        print("All \(suites) AssistantIdentityClient suites passed; all requests intercepted, no network or credentials used.")
    }
}

/// The session explicitly uses this protocol. Unexpected URLs fail locally too,
/// so a typo cannot escape the hermetic test process.
private final class IdentityFixtureURLProtocol: URLProtocol {
    struct Captured { let request: URLRequest; let body: Data }
    private struct Fixture {
        let status: Int
        let headers: [String: String]
        let body: Data
        let hold: Bool
        let failure: URLError.Code?
    }
    private static let lock = NSLock()
    private static var fixtures: [String: Fixture] = [:]
    private static var captures: [String: Captured] = [:]
    private static var stoppedIds: Set<String> = []
    private let instanceLock = NSLock()
    private var hasStopped = false

    static func register(status: Int, headers: [String: String], body: Data, hold: Bool, failure: URLError.Code?) -> String {
        let id = UUID().uuidString
        lock.lock(); defer { lock.unlock() }
        fixtures[id] = Fixture(status: status, headers: headers, body: body, hold: hold, failure: failure)
        return id
    }
    static func captured(_ id: String) -> Captured? { lock.lock(); defer { lock.unlock() }; return captures[id] }
    static func stopped(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return stoppedIds.contains(id) }
    private var fixtureId: String? { request.url?.pathComponents.dropFirst().first }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = fixtureId else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        Self.lock.lock(); let fixture = Self.fixtures[id]; Self.lock.unlock()
        guard let fixture else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        let body = request.httpBody ?? readBodyStream()
        Self.lock.lock(); Self.captures[id] = Captured(request: request, body: body); Self.lock.unlock()
        if let failure = fixture.failure { client?.urlProtocol(self, didFailWithError: URLError(failure)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if fixture.hold {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                self.instanceLock.lock(); let stopped = self.hasStopped; self.instanceLock.unlock()
                if !stopped { self.client?.urlProtocolDidFinishLoading(self) }
            }
            return
        }
        // Split UTF-8 scalars and exercise the client's streaming byte limit.
        for offset in stride(from: 0, to: fixture.body.count, by: 257) {
            client?.urlProtocol(self, didLoad: fixture.body.subdata(in: offset..<min(offset + 257, fixture.body.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        instanceLock.lock(); hasStopped = true; instanceLock.unlock()
        if let id = fixtureId { Self.lock.lock(); Self.stoppedIds.insert(id); Self.lock.unlock() }
    }
    private func readBodyStream() -> Data {
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { return data }
            data.append(buffer, count: count)
            if data.count > 1_048_576 { return data }
        }
    }
}
