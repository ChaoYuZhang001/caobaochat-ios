import Foundation

private struct ModelTestFailure: Error, CustomStringConvertible { let description: String }

@main private enum AssistantModelCatalogTests {
    private static var suites = 0
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw ModelTestFailure(description: message) }
    }
    private static func run(_ name: String, _ operation: () async throws -> Void) async throws {
        try await operation(); suites += 1; print("PASS \(name)")
    }
    private static func fails(_ expected: AssistantModelCatalogError, _ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch {
            guard error as? AssistantModelCatalogError == expected else {
                throw ModelTestFailure(description: "Expected \(expected), received \(error)")
            }
            return
        }
        throw ModelTestFailure(description: "Expected failure \(expected)")
    }
    private static func model(id: String = "vendor/model-v1:stable.1", name: String = "测试模型 🌱",
                              vision: Bool = true, tools: Bool = false, streaming: Bool = true) -> [String: Any] {
        ["id": id, "displayName": name, "provider": "Fixture vendor",
         "capabilities": ["vision": vision, "tools": tools, "streaming": streaming]]
    }
    private static func catalog(region: String = "CN", defaultId: String? = "vendor/model-v1:stable.1",
                                models: [[String: Any]]? = nil) throws -> Data {
        var object: [String: Any] = ["serviceRegion": region, "models": models ?? [model()]]
        object["defaultModelId"] = defaultId.map { $0 as Any } ?? NSNull()
        return try JSONSerialization.data(withJSONObject: object)
    }
    private static func setup(status: Int = 200, headers: [String: String] = ["Content-Type": "application/json; charset=utf-8"],
                              body: Data? = nil, hold: Bool = false, beforeHeaders: Bool = false,
                              failure: URLError.Code? = nil, redirect: Bool = false, limit: Int = 524_288) -> (AssistantModelCatalogClient, String) {
        let id = ModelFixtureURLProtocol.register(status: status, headers: headers, body: body ?? (try! catalog()),
            hold: hold, beforeHeaders: beforeHeaders, failure: failure, redirect: redirect)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelFixtureURLProtocol.self]
        configuration.httpAdditionalHeaders = ["Cookie": "foreign-session=fixture", "X-Foreign-Secret": "fixture-secret"]
        return (AssistantModelCatalogClient(baseURL: URL(string: "https://model-fixtures.invalid/\(id)/api/v2")!,
            sessionConfiguration: configuration, maximumResponseBytes: limit), id)
    }
    private static func fetch(_ client: AssistantModelCatalogClient, region: String = "CN") async throws -> AssistantModelCatalogResponse {
        try await client.fetch(accessToken: "fixture-access", region: region)
    }
    private static func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { throw ModelTestFailure(description: "Timed out: " + label) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    static func main() async throws {
        try await run("models-region-query-bearer-and-safe-get") {
            for region in ["CN", "INTL"] {
                let (client, id) = setup(body: try catalog(region: region))
                let result = try await fetch(client, region: region)
                try expect(result.serviceRegion == region, "Return the requested server region")
                let request = ModelFixtureURLProtocol.captured(id)!
                try expect(request.httpMethod == "GET" && request.url?.path == "/\(id)/api/v2/models", "Preserve the configured API prefix")
                try expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "region", value: region)], "Only the explicit region belongs in the query")
                try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access", "Use one raw account access token")
                try expect(request.value(forHTTPHeaderField: "Accept") == "application/json", "Catalog requires JSON")
                try expect(request.httpBody == nil && request.httpBodyStream == nil, "GET must not send chat data or model keys")
                try expect(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "X-Foreign-Secret") == nil, "Do not inherit foreign credentials")
            }
        }
        try await run("models-server-capabilities-are-not-inferred") {
            let records = [model(), model(id: "text-only", vision: false, tools: true, streaming: false)]
            let (client, _) = setup(body: try catalog(models: records))
            let result = try await fetch(client)
            try expect(result.models.count == 2 && result.defaultModelId == "vendor/model-v1:stable.1", "Return server records and default")
            try expect(result.models[0].displayName == "测试模型 🌱" && result.models[0].provider == "Fixture vendor", "Preserve Unicode labels")
            try expect(result.models[0].capabilities == AssistantModelCapabilities(vision: true, tools: false, streaming: true), "Keep actual first-model flags")
            try expect(result.models[1].capabilities == AssistantModelCapabilities(vision: false, tools: true, streaming: false), "False streaming must remain false")
        }
        try await run("models-empty-and-optional-fields-do-not-grant-access") {
            let (empty, _) = setup(body: try catalog(defaultId: nil, models: []))
            let result = try await fetch(empty)
            try expect(result.models.isEmpty && result.defaultModelId == nil, "No access must stay empty")
            var value = model(); value.removeValue(forKey: "provider")
            let (optional, _) = setup(body: try catalog(defaultId: nil, models: [value]))
            let optionalResult = try await fetch(optional)
            try expect(optionalResult.defaultModelId == nil && optionalResult.models[0].provider == nil, "Do not invent optional fields")
        }
        try await run("models-invalid-input-never-starts-network") {
            for region in ["", "cn", "HK", "CN ", "../INTL", "CN&region=INTL", "中国大陆"] {
                let (client, id) = setup()
                try await fails(.invalidInput) { _ = try await client.fetch(accessToken: "fixture", region: region) }
                try expect(ModelFixtureURLProtocol.captured(id) == nil, "Reject invalid region before opening a request")
            }
            for token in ["", "with space", "line\r\nheader", "bad\0token", "令牌", String(repeating: "x", count: 16_385)] {
                let (client, id) = setup()
                try await fails(.invalidInput) { _ = try await client.fetch(accessToken: token, region: "CN") }
                try expect(ModelFixtureURLProtocol.captured(id) == nil, "Reject invalid token before opening a request")
            }
        }
        try await run("models-invalid-configuration-never-starts-network") {
            for base in ["http://model-fixtures.invalid/api/v2", "https://user:secret@model-fixtures.invalid/api/v2",
                         "https://model-fixtures.invalid/api/v2?private=secret", "https://model-fixtures.invalid/api/v2#fragment"] {
                let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ModelFixtureURLProtocol.self]
                let client = AssistantModelCatalogClient(baseURL: URL(string: base)!, sessionConfiguration: configuration)
                try await fails(.invalidConfiguration) { _ = try await fetch(client) }
            }
            let (client, id) = setup(limit: 0)
            try await fails(.invalidConfiguration) { _ = try await fetch(client) }
            try expect(ModelFixtureURLProtocol.captured(id) == nil, "Invalid response limit must not open transport")
        }
        try await run("models-region-mismatch-is-rejected") {
            for region in ["INTL", "", "CN ", "unknown"] {
                let (client, _) = setup(body: try catalog(region: region))
                try await fails(.regionMismatch) { _ = try await fetch(client) }
            }
        }
        try await run("models-required-json-fields-and-capabilities") {
            for json in ["", "not JSON", "[]", "null", "{}", #"{"serviceRegion":"CN","models":null}"#] {
                let (client, _) = setup(body: Data(json.utf8)); try await fails(.invalidResponse) { _ = try await fetch(client) }
            }
            for flag in ["vision", "tools", "streaming"] {
                for malformed: Any in [NSNull(), "true", 1] {
                    var value = model(); var flags = value["capabilities"] as! [String: Any]
                    flags[flag] = malformed; value["capabilities"] = flags
                    let (client, _) = setup(body: try catalog(models: [value])); try await fails(.invalidResponse) { _ = try await fetch(client) }
                }
                var value = model(); var flags = value["capabilities"] as! [String: Any]
                flags.removeValue(forKey: flag); value["capabilities"] = flags
                let (client, _) = setup(body: try catalog(models: [value])); try await fails(.invalidResponse) { _ = try await fetch(client) }
            }
            for key in ["id", "displayName", "capabilities"] {
                var value = model(); value.removeValue(forKey: key)
                let (client, _) = setup(body: try catalog(models: [value])); try await fails(.invalidResponse) { _ = try await fetch(client) }
            }
        }
        try await run("models-safe-identifiers-and-label-boundaries") {
            for id in ["", "model space", "model?query", "model#fragment", "model@private", "模型", "model\n", String(repeating: "m", count: 129)] {
                let (client, _) = setup(body: try catalog(defaultId: id, models: [model(id: id)])); try await fails(.invalidResponse) { _ = try await fetch(client) }
            }
            for name in ["", " \n", "line\nbreak", "bad\0label", String(repeating: "x", count: 257)] {
                let (client, _) = setup(body: try catalog(models: [model(name: name)])); try await fails(.invalidResponse) { _ = try await fetch(client) }
            }
            let id = String(repeating: "m", count: 128), name = String(repeating: "字", count: 256)
            let (valid, _) = setup(body: try catalog(defaultId: id, models: [model(id: id, name: name)]))
            let result = try await fetch(valid)
            try expect(result.models[0].id == id && result.models[0].displayName == name, "Support exact ID and label boundaries")
        }
        try await run("models-duplicate-ids-and-model-count-boundaries") {
            let (duplicate, _) = setup(body: try catalog(models: [model(), model()])); try await fails(.invalidResponse) { _ = try await fetch(duplicate) }
            let records = (0..<200).map { model(id: "model-\($0)") }
            let (exact, _) = setup(body: try catalog(defaultId: "model-0", models: records)); let result = try await fetch(exact)
            try expect(result.models.count == 200, "Support exactly 200 actual models")
            let (over, _) = setup(body: try catalog(defaultId: "model-0", models: records + [model(id: "model-200")]))
            try await fails(.invalidResponse) { _ = try await fetch(over) }
        }
        try await run("models-default-must-exist-and-stream") {
            let (unknown, _) = setup(body: try catalog(defaultId: "missing")); try await fails(.invalidResponse) { _ = try await fetch(unknown) }
            let (noStream, _) = setup(body: try catalog(models: [model(streaming: false)])); try await fails(.invalidResponse) { _ = try await fetch(noStream) }
            let (empty, _) = setup(body: try catalog(defaultId: "missing", models: [])); try await fails(.invalidResponse) { _ = try await fetch(empty) }
        }
        try await run("models-http-status-and-json-mime") {
            for status in [301, 302, 307, 308, 400, 401, 403, 404, 409, 429, 500] {
                let (client, _) = setup(status: status); try await fails(.httpStatus(status)) { _ = try await fetch(client) }
            }
            for status in [201, 202, 204, 206] {
                let (client, _) = setup(status: status); try await fails(.invalidResponse) { _ = try await fetch(client) }
            }
            for headers in [[:], ["Content-Type": "text/html"], ["Content-Type": "text/json"], ["Content-Type": "text/event-stream"]] {
                let (client, _) = setup(headers: headers); try await fails(.unexpectedContentType) { _ = try await fetch(client) }
            }
            let (valid, _) = setup(headers: ["Content-Type": "Application/Catalog+JSON; charset=UTF-8"]); _ = try await fetch(valid)
        }
        try await run("models-bounded-declared-and-streamed-response") {
            let (declared, _) = setup(headers: ["Content-Type": "application/json", "Content-Length": "524289"])
            try await fails(.responseTooLarge) { _ = try await fetch(declared) }
            let (streamed, _) = setup(body: Data(repeating: 32, count: 1_025), limit: 1_024)
            try await fails(.responseTooLarge) { _ = try await fetch(streamed) }
            for length in ["-1", "invalid", "99999999999999999999999999"] {
                let (client, _) = setup(headers: ["Content-Type": "application/json", "Content-Length": length])
                try await fails(.invalidResponse) { _ = try await fetch(client) }
            }
            let (hardCap, _) = setup(headers: ["Content-Type": "application/json", "Content-Length": "1048577"], limit: 4_194_304)
            try await fails(.responseTooLarge) { _ = try await fetch(hardCap) }
            let data = try catalog(); let (exact, _) = setup(body: data, limit: data.count); _ = try await fetch(exact)
            let (over, _) = setup(body: data + Data(" ".utf8), limit: data.count); try await fails(.responseTooLarge) { _ = try await fetch(over) }
        }
        try await run("models-network-errors-remain-safe") {
            let (client, _) = setup(failure: .notConnectedToInternet); try await fails(.networkUnavailable) { _ = try await fetch(client) }
            let message = AssistantModelCatalogError.httpStatus(500).localizedDescription
            try expect(!message.contains("fixture-access") && !message.contains("foreign-session"), "Never echo private transport data")
        }
        try await run("models-cancel-after-headers-closes-request") { try await cancellation(beforeHeaders: false) }
        try await run("models-cancel-before-headers-closes-request") { try await cancellation(beforeHeaders: true) }
        try await run("models-pre-cancelled-task-does-not-start") {
            let (client, id) = setup()
            let task = Task { () -> Error? in
                withUnsafeCurrentTask { $0?.cancel() }
                do { _ = try await fetch(client); return nil } catch { return error }
            }
            let error = await task.value
            try expect(error is CancellationError && ModelFixtureURLProtocol.captured(id) == nil, "Do not start pre-cancelled transport")
        }
        try await run("models-redirect-callback-does-not-forward-token") {
            let (client, id) = setup(status: 307, redirect: true)
            do { _ = try await fetch(client); throw ModelTestFailure(description: "Redirect must not produce a catalog") }
            catch let error as AssistantModelCatalogError {
                try expect(error == .httpStatus(307) || error == .networkUnavailable, "Refused custom redirects remain a safe loading failure")
            }
            try expect(ModelFixtureURLProtocol.requestCount(id) == 1, "Do not open a redirected token-bearing request")
        }
        try await run("models-delegate-rejects-same-and-cross-origin-redirects") {
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ModelFixtureURLProtocol.self]
            let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
            let original = URL(string: "https://model-fixtures.invalid/api/v2/models?region=CN")!
            let response = HTTPURLResponse(url: original, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: nil)!
            let task = session.dataTask(with: original) // Never resumed; every session is also intercepted.
            for target in ["https://model-fixtures.invalid/other", "https://other-model-fixtures.invalid/token"] {
                var redirected = URLRequest(url: URL(string: target)!); redirected.setValue("Bearer fixture-access", forHTTPHeaderField: "Authorization")
                var called = false, approved = false
                AssistantModelCatalogRedirectGuard().urlSession(session, task: task, willPerformHTTPRedirection: response,
                    newRequest: redirected, completionHandler: { request in called = true; approved = request != nil })
                try expect(called && !approved, "The production delegate must deny both redirect classes")
            }
            task.cancel()
        }
        print("All \(suites) AssistantModelCatalog suites passed; every URL intercepted, no real network, model or credentials.")
    }

    private static func cancellation(beforeHeaders: Bool) async throws {
        let (client, id) = setup(hold: true, beforeHeaders: beforeHeaders)
        let task = Task { () -> Error? in do { _ = try await fetch(client); return nil } catch { return error } }
        try await wait("request started") { ModelFixtureURLProtocol.captured(id) != nil }
        task.cancel(); let error = await task.value
        try expect(error is CancellationError, "Cancellation must remain CancellationError")
        try await wait("stopLoading") { ModelFixtureURLProtocol.stopped(id) }
    }
}

private final class ModelFixtureURLProtocol: URLProtocol {
    private struct Fixture {
        let status: Int; let headers: [String: String]; let body: Data
        let hold: Bool; let beforeHeaders: Bool; let failure: URLError.Code?; let redirect: Bool
    }
    private static let lock = NSLock()
    private static var fixtures: [String: Fixture] = [:]
    private static var captures: [String: URLRequest] = [:]
    private static var counts: [String: Int] = [:]
    private static var stops: Set<String> = []
    static func register(status: Int, headers: [String: String], body: Data, hold: Bool, beforeHeaders: Bool,
                         failure: URLError.Code?, redirect: Bool) -> String {
        let id = UUID().uuidString; lock.lock(); defer { lock.unlock() }
        fixtures[id] = Fixture(status: status, headers: headers, body: body, hold: hold,
            beforeHeaders: beforeHeaders, failure: failure, redirect: redirect)
        return id
    }
    static func captured(_ id: String) -> URLRequest? { lock.lock(); defer { lock.unlock() }; return captures[id] }
    static func requestCount(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[id] ?? 0 }
    static func stopped(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return stops.contains(id) }
    private var fixtureId: String? { request.url?.pathComponents.dropFirst().first }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = fixtureId else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        Self.lock.lock(); let fixture = Self.fixtures[id]; Self.lock.unlock()
        guard let fixture else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        Self.lock.lock(); Self.captures[id] = request; Self.counts[id, default: 0] += 1; Self.lock.unlock()
        if let failure = fixture.failure { client?.urlProtocol(self, didFailWithError: URLError(failure)); return }
        if fixture.beforeHeaders { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
        if fixture.redirect {
            var target = request; target.url = URL(string: "https://redirected-model-fixtures.invalid/\(id)/no-token")!
            client?.urlProtocol(self, wasRedirectedTo: target, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if fixture.hold { return }
        for offset in stride(from: 0, to: fixture.body.count, by: 257) {
            client?.urlProtocol(self, didLoad: fixture.body.subdata(in: offset..<min(offset + 257, fixture.body.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        if let id = fixtureId { Self.lock.lock(); Self.stops.insert(id); Self.lock.unlock() }
    }
}
