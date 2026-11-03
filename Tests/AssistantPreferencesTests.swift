import Foundation

private final class PreferencesFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response { let status: Int; let headers: [String: String]; let body: Data }
    private static let lock = NSLock()
    private static var response: Response?
    private static var requests: [URLRequest] = []

    static func reset(_ response: Response) {
        lock.lock(); defer { lock.unlock() }
        self.response = response; requests = []
    }
    static var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock(); Self.requests.append(request); let value = Self.response; Self.lock.unlock()
        guard let value else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let response = HTTPURLResponse(url: url, statusCode: value.status, httpVersion: nil, headerFields: value.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: value.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private enum PreferencesTestFailure: Error { case failed(String) }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PreferencesTestFailure.failed(message) }
}
private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

@main
struct AssistantPreferencesTests {
    static func main() async throws {
        try await validRequestUsesAuthenticatedHTTPSContract()
        try await redirectsAreRejectedWithoutFollowUp()
        try await malformedSnapshotIsRejected()
        try await invalidCredentialsFailBeforeTransport()
        print("All assistant preferences suites passed")
    }

    private static func client() -> AssistantPreferencesClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PreferencesFixtureURLProtocol.self]
        return AssistantPreferencesClient(baseURL: URL(string: "https://fixture.invalid/api/v2")!, sessionConfiguration: config)
    }

    private static func validSnapshot() -> [String: Any] {
        ["success": true, "preferences": [
            "assistantMode": "platform", "regionConfirmed": true, "locale": "zh-CN",
            "personaLevel": "normal", "proactiveLevel": "", "serviceRegion": "CN",
            "regionSource": "user", "timeZone": "Asia/Shanghai", "timeZoneLocked": true
        ], "error": NSNull()]
    }

    private static func validRequestUsesAuthenticatedHTTPSContract() async throws {
        PreferencesFixtureURLProtocol.reset(.init(status: 200, headers: ["Content-Type": "application/json"], body: try json(validSnapshot())))
        let response = try await client().fetch(accessToken: "access-token")
        try expect(response.preferences.serviceRegion == "CN", "valid preference response was not decoded")
        let requests = PreferencesFixtureURLProtocol.captured
        try expect(requests.count == 1, "preference read did not issue exactly one request")
        let request = requests[0]
        try expect(request.httpMethod == "GET" && request.url?.path == "/api/v2/profile/preferences", "wrong preference GET path")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token", "missing bearer token")
    }

    private static func redirectsAreRejectedWithoutFollowUp() async throws {
        PreferencesFixtureURLProtocol.reset(.init(status: 302, headers: ["Location": "https://other.invalid/api/v2/profile/preferences"], body: Data()))
        do {
            _ = try await client().fetch(accessToken: "access-token")
            throw PreferencesTestFailure.failed("redirect was reported as success")
        } catch let error as AssistantPreferencesClientError {
            try expect(error == .httpStatus(302), "redirect returned the wrong error")
        }
        try expect(PreferencesFixtureURLProtocol.captured.count == 1, "redirect opened a second credential-bearing request")
    }

    private static func malformedSnapshotIsRejected() async throws {
        var value = validSnapshot()
        var preferences = value["preferences"] as! [String: Any]
        preferences["serviceRegion"] = "MOON"
        value["preferences"] = preferences
        PreferencesFixtureURLProtocol.reset(.init(status: 200, headers: ["Content-Type": "application/json"], body: try json(value)))
        do {
            _ = try await client().fetch(accessToken: "access-token")
            throw PreferencesTestFailure.failed("malformed snapshot was accepted")
        } catch let error as AssistantPreferencesClientError {
            try expect(error == .invalidResponse, "malformed snapshot returned the wrong error")
        }
    }

    private static func invalidCredentialsFailBeforeTransport() async throws {
        PreferencesFixtureURLProtocol.reset(.init(status: 200, headers: ["Content-Type": "application/json"], body: try json(validSnapshot())))
        do {
            _ = try await client().fetch(accessToken: "bad token")
            throw PreferencesTestFailure.failed("invalid token was accepted")
        } catch let error as AssistantPreferencesClientError {
            try expect(error == .invalidToken, "invalid token returned the wrong error")
        }
        try expect(PreferencesFixtureURLProtocol.captured.isEmpty, "invalid token reached transport")
    }
}
