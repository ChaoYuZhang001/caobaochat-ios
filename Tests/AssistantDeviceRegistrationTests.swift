import Foundation

private final class DeviceRegistrationFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response { let status: Int; let headers: [String: String]; let body: Data }
    private static let lock = NSLock()
    private static var responses: [String: Response] = [:]
    private static var requests: [URLRequest] = []

    static func reset(_ response: Response, path: String = "/api/v2/devices") {
        lock.lock(); defer { lock.unlock() }
        responses = [path: response]; requests = []
    }
    static var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock(); Self.requests.append(request); let value = Self.responses[url.path]; Self.lock.unlock()
        guard let value else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let response = HTTPURLResponse(url: url, statusCode: value.status, httpVersion: nil, headerFields: value.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: value.body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private enum DeviceRegistrationTestFailure: Error { case failed(String) }

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw DeviceRegistrationTestFailure.failed(message) }
}

private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }

private func bodyData(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }; data.append(buffer, count: count)
    }
    return data
}

@main
struct AssistantDeviceRegistrationTests {
    static func main() async throws {
        try await validRequestUsesAuthenticatedHTTPSContract()
        try await unregisterUsesOwnerScopedDeleteContract()
        try await malformedInputsFailBeforeTransport()
        try await redirectsAreRejected()
        try await serverErrorsAreNotReportedAsSuccess()
        print("All device registration suites passed")
    }

    private static func client() -> AssistantDeviceRegistrationClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeviceRegistrationFixtureURLProtocol.self]
        return AssistantDeviceRegistrationClient(baseURL: URL(string: "https://fixture.invalid/api/v2")!, sessionConfiguration: config)
    }

    private static func validRequestUsesAuthenticatedHTTPSContract() async throws {
        DeviceRegistrationFixtureURLProtocol.reset(.init(status: 200, headers: ["Content-Type": "application/json"], body: try json(["status": "registered"])))
        try await client().register(deviceId: "device-uuid", pushToken: String(repeating: "ab", count: 32),
            environment: "sandbox", topic: "chat.caobao.assistant", accessToken: "access-token")
        let requests = DeviceRegistrationFixtureURLProtocol.captured
        try expect(requests.count == 1, "registration did not issue exactly one request")
        let request = requests[0]
        try expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token", "missing authenticated POST contract")
        try expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "missing JSON content type")
        let body = try JSONSerialization.jsonObject(with: bodyData(request)) as? [String: String]
        try expect(body?["deviceId"] == "device-uuid" && body?["platform"] == "ios" && body?["environment"] == "sandbox" && body?["topic"] == "chat.caobao.assistant", "registration fields were not encoded")
        try expect(body?["pushToken"] == String(repeating: "ab", count: 32), "push token was not encoded")
    }

    private static func malformedInputsFailBeforeTransport() async throws {
        DeviceRegistrationFixtureURLProtocol.reset(.init(status: 200, headers: [:], body: Data()))
        do {
            try await client().register(deviceId: "", pushToken: "ab", environment: "sandbox", topic: "topic", accessToken: "access")
            throw DeviceRegistrationTestFailure.failed("empty device id was accepted")
        } catch let error as AssistantDeviceRegistrationError {
            try expect(error == .invalidInput, "empty device id returned the wrong error")
        }
        try expect(DeviceRegistrationFixtureURLProtocol.captured.isEmpty, "invalid input reached transport")
    }

    private static func unregisterUsesOwnerScopedDeleteContract() async throws {
        let path = "/api/v2/devices/device-uuid"
        DeviceRegistrationFixtureURLProtocol.reset(.init(status: 200, headers: ["Content-Type": "application/json"], body: try json(["status": "unregistered"])), path: path)
        try await client().unregister(deviceId: "device-uuid", accessToken: "access-token")
        let requests = DeviceRegistrationFixtureURLProtocol.captured
        try expect(requests.count == 1, "unregistration did not issue exactly one request")
        let request = requests[0]
        try expect(request.httpMethod == "DELETE" && request.url?.path == path, "missing owner-scoped DELETE contract")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token", "unregistration did not authenticate")
        try expect(request.value(forHTTPHeaderField: "Content-Type") == nil, "unregistration sent an unnecessary request body")
    }

    private static func redirectsAreRejected() async throws {
        DeviceRegistrationFixtureURLProtocol.reset(.init(status: 302, headers: ["Location": "https://other.invalid/api/v2/devices"], body: Data()))
        do {
            try await client().register(deviceId: "device-uuid", pushToken: "ab", environment: "sandbox", topic: "topic", accessToken: "access")
            throw DeviceRegistrationTestFailure.failed("redirect was reported as success")
        } catch let error as AssistantDeviceRegistrationError {
            try expect(error == .httpStatus(302), "redirect returned the wrong error")
        }
        try expect(DeviceRegistrationFixtureURLProtocol.captured.count == 1, "redirect opened a second credential-bearing request")
    }

    private static func serverErrorsAreNotReportedAsSuccess() async throws {
        DeviceRegistrationFixtureURLProtocol.reset(.init(status: 200, headers: [:], body: try json(["status": "other"])))
        do {
            try await client().register(deviceId: "device-uuid", pushToken: "ab", environment: "sandbox", topic: "topic", accessToken: "access")
            throw DeviceRegistrationTestFailure.failed("unexpected response status was accepted")
        } catch let error as AssistantDeviceRegistrationError {
            try expect(error == .invalidResponse, "unexpected response status returned the wrong error")
        }
    }
}
