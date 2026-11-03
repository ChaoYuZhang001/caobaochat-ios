import Foundation

private struct ProbeTestFailure: Error, CustomStringConvertible { let description: String }

@main
private enum AssistantConnectionProbeTests {
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw ProbeTestFailure(description: message) }
    }
    static func run(_ name: String, _ body: () async throws -> Void) async throws {
        try await body(); print("PASS \(name)")
    }
    static func config(_ scenario: String, _ kind: AssistantWireProtocol = .chatCompletions) -> BYOKConfiguration {
        BYOKConfiguration(baseURL: "https://api.example.com/probe/\(scenario)/v1", protocolKind: kind,
                          model: "fixture-model", apiKey: "fixture-secret-key")
    }
    static func probe(timeout: TimeInterval = 2) -> AssistantConnectionProbe {
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [ProbeFixture.self]
        return AssistantConnectionProbe(transport: AssistantStreamTransport(configuration: settings), timeout: timeout)
    }
    static func fail(_ scenario: String) async throws -> Error {
        do { _ = try await probe().check(configuration: config(scenario)) }
        catch { return error }
        throw ProbeTestFailure(description: "Expected a failure for \(scenario)")
    }
    static func awaitState(_ scenario: String, stopped: Bool = false) async throws {
        for _ in 0..<200 {
            if stopped ? ProbeFixture.stopped(scenario) : ProbeFixture.count(scenario) > 0 { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ProbeTestFailure(description: stopped ? "Underlying request was not stopped" : "Request never started")
    }
    static func main() async throws {
        for kind in AssistantWireProtocol.allCases {
            try await run("connection-\(kind.rawValue)-actual-payload-and-success") {
                let scenario = "success-\(kind.rawValue)"
                let result = try await probe().check(configuration: config(scenario, kind))
                try expect(result.protocolKind == kind && result.model == "fixture-model", "Result must identify the tested protocol/model")
                try expect(result.elapsedSeconds >= 0 && result.elapsedSeconds < 2, "Elapsed duration must be bounded")
                guard let record = ProbeFixture.record(scenario),
                      let json = try JSONSerialization.jsonObject(with: record.body) as? [String: Any] else {
                    throw ProbeTestFailure(description: "Missing actual captured request")
                }
                try expect(record.request.httpMethod == "POST", "Probe must send protocol POST")
                try expect(record.request.value(forHTTPHeaderField: "Accept") == "text/event-stream", "SSE response must be requested")
                try expect(record.request.value(forHTTPHeaderField: "X-Request-ID")?.hasPrefix("probe.") == true, "Probe request has independent identity")
                try expect(record.request.timeoutInterval > 0 && record.request.timeoutInterval <= 2, "Request timeout must be finite")
                try expect(json["model"] as? String == "fixture-model" && json["stream"] as? Bool == true, "Model and streaming must be explicit")
                try expect(json["context"] == nil && json["conversationId"] == nil && json["memoryIds"] == nil && json["taskIds"] == nil, "No application context may enter the request")
                let encoded = String(decoding: record.body, as: UTF8.self)
                try expect(!encoded.contains("fixture-secret-key") && !encoded.contains("image_url") && !encoded.contains("base64Data"), "Body must not contain API key or images")
                switch kind {
                case .chatCompletions:
                    try expect(record.request.url?.path.hasSuffix("/chat/completions") == true, "Chat endpoint must be correct")
                    try expect(record.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret-key", "Chat authorization must be preserved")
                    try expect(json["max_tokens"] as? Int == 16 && json["max_output_tokens"] == nil, "Chat uses the short output limit")
                    let turns = json["messages"] as? [[String: Any]]
                    try expect(turns?.count == 2 && turns?.first?["role"] as? String == "system", "Only fixed instructions and a test turn may be sent")
                    try expect(turns?.last?["content"] as? String == "Reply with the single word OK.", "The user input must be fixed")
                case .responses:
                    try expect(record.request.url?.path.hasSuffix("/responses") == true, "Responses endpoint must be correct")
                    try expect(json["max_output_tokens"] as? Int == 16 && json["max_tokens"] == nil, "Responses uses its own short output limit")
                    try expect(json["store"] as? Bool == false, "Responses must disable storage")
                    let turns = json["input"] as? [[String: Any]]
                    try expect(turns?.count == 1 && turns?.first?["content"] as? String == "Reply with the single word OK.", "Responses has no local history")
                case .anthropic:
                    try expect(record.request.url?.path.hasSuffix("/messages") == true, "Anthropic endpoint must be correct")
                    try expect(record.request.value(forHTTPHeaderField: "x-api-key") == "fixture-secret-key" && record.request.value(forHTTPHeaderField: "Authorization") == nil, "Anthropic must use its own authentication")
                    try expect(record.request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Anthropic header must be preserved")
                    try expect(json["max_tokens"] as? Int == 16, "Anthropic uses the short output limit")
                    let turns = json["messages"] as? [[String: Any]]
                    try expect(turns?.count == 1 && turns?.first?["content"] as? String == "Reply with the single word OK.", "Anthropic has only one fixed user turn")
                }
                try expect(ProbeFixture.count(scenario) == 1, "Probe must not retry or fall back")
            }
        }
        try await run("connection-empty-and-whitespace-fail") {
            for name in ["empty", "whitespace"] {
                guard case .emptyResult = try await fail(name) as? AssistantTransportError else { throw ProbeTestFailure(description: "Textless terminal is not success") }
            }
        }
        try await run("connection-http-error-preserved-without-secrets") {
            let error = try await fail("http-error")
            guard case .http(401) = error as? AssistantTransportError else { throw ProbeTestFailure(description: "HTTP error must survive") }
            try expect(!error.localizedDescription.contains("private-upstream-body") && !error.localizedDescription.contains("fixture-secret-key"), "HTTP failure must not disclose response/key")
            try expect(ProbeFixture.count("http-error") == 1, "Failures must not retry")
        }
        try await run("connection-premature-eof-and-tool-refusal") {
            guard case .interrupted = try await fail("interrupted") as? AssistantTransportError else { throw ProbeTestFailure(description: "EOF must fail") }
            guard case .toolExecutionUnavailable = try await fail("tool") as? AssistantTransportError else { throw ProbeTestFailure(description: "Tool request must fail explicitly") }
        }
        try await run("connection-content-type-and-invalid-json-fail") {
            guard case .malformedEvent = try await fail("wrong-type") as? AssistantTransportError else {
                throw ProbeTestFailure(description: "Unexpected content type must fail explicitly")
            }
            let parsingError = try await fail("malformed")
            try expect(!parsingError.localizedDescription.isEmpty && !parsingError.localizedDescription.contains("fixture-secret-key"),
                       "Malformed JSON must fail without exposing the API key")
        }
        try await run("connection-later-error-is-not-hidden-by-terminal") {
            guard case .remote("late_error") = try await fail("late-error") as? AssistantTransportError else { throw ProbeTestFailure(description: "Must wait for actual transport completion") }
        }
        try await run("connection-provider-output-is-bounded") {
            guard case .responseTooLarge = try await fail("oversize") as? AssistantConnectionProbeError else { throw ProbeTestFailure(description: "Ignoring requested limit must still be bounded") }
        }
        for scenario in ["hold-before", "hold-after"] {
            try await run("connection-\(scenario)-cancel-stops-network") {
                let task = Task { try await probe().check(configuration: config(scenario)) }
                try await awaitState(scenario); task.cancel()
                do { _ = try await task.value; throw ProbeTestFailure(description: "Cancelled test must not succeed") }
                catch is CancellationError { }
                try await awaitState(scenario, stopped: true)
            }
        }
        try await run("connection-total-timeout-stops-terminal-but-open-stream") {
            let start = ProcessInfo.processInfo.systemUptime
            do { _ = try await probe(timeout: 0.15).check(configuration: config("hold-terminal")); throw ProbeTestFailure(description: "Missing EOF cannot pass") }
            catch AssistantConnectionProbeError.timedOut { }
            try expect(ProbeFixture.count("hold-terminal") == 1, "Timeout fixture must actually start")
            try await awaitState("hold-terminal", stopped: true)
            try expect(ProcessInfo.processInfo.systemUptime - start < 1.5, "Total stream duration must be bounded")
        }
        try await run("connection-invalid-input-does-not-start-network") {
            let count = ProbeFixture.totalCount
            let invalid = BYOKConfiguration(baseURL: "http://localhost", protocolKind: .chatCompletions, model: "model", apiKey: "key")
            do { _ = try await probe().check(configuration: invalid); throw ProbeTestFailure(description: "Invalid address must fail") }
            catch AssistantTransportError.configuration { }
            for timeout in [0.0, -1, 61, .infinity, .nan] {
                do { _ = try await probe(timeout: timeout).check(configuration: config("invalid-timeout")); throw ProbeTestFailure(description: "Invalid timeout must fail") }
                catch AssistantConnectionProbeError.invalidTimeout { }
            }
            try expect(ProbeFixture.totalCount == count, "Validation failures cannot start networking")
        }
        try await run("connection-pre-cancelled-task-does-not-start-network") {
            let count = ProbeFixture.totalCount
            let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await probe().check(configuration: config("pre-cancelled")) }
            do { _ = try await task.value; throw ProbeTestFailure(description: "Pre-cancelled task cannot succeed") }
            catch is CancellationError { }
            try expect(ProbeFixture.totalCount == count, "Pre-cancelled request must not be sent")
        }
    }
}

private final class ProbeFixture: URLProtocol {
    struct Record { let request: URLRequest; let body: Data }
    private static let lock = NSLock()
    private static var records: [String: [Record]] = [:]
    private static var stoppedScenarios: Set<String> = []
    private let instanceLock = NSLock()
    private var isStopped = false
    private var scenario: String { request.url?.pathComponents.dropFirst(2).first ?? "unknown" }
    static var totalCount: Int { lock.lock(); defer { lock.unlock() }; return records.values.reduce(0) { $0 + $1.count } }
    static func count(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return records[name]?.count ?? 0 }
    static func record(_ name: String) -> Record? { lock.lock(); defer { lock.unlock() }; return records[name]?.first }
    static func stopped(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return stoppedScenarios.contains(name) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func frame(_ object: [String: Any]) -> String {
        "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n"
    }
    private func body() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var output = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }
    override func startLoading() {
        let selected = scenario
        let value = Record(request: request, body: body())
        Self.lock.lock(); Self.records[selected, default: []].append(value); Self.lock.unlock()
        if selected == "hold-before" { failsafe(); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: selected == "http-error" ? 401 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": selected == "wrong-type" ? "application/json" : "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if selected == "hold-after" { failsafe(); return }
        let body: String
        switch selected {
        case "empty": body = Self.frame(["type": "completed"])
        case "whitespace": body = Self.frame(["type": "delta", "content": "   "]) + Self.frame(["type": "completed"])
        case "interrupted": body = Self.frame(["type": "delta", "content": "OK"])
        case "tool": body = Self.frame(["type": "tool_call"])
        case "http-error": body = "private-upstream-body fixture-secret-key"
        case "wrong-type": body = "{}"
        case "malformed": body = "data: invalid-json\n\n"
        case "late-error": body = Self.normal + Self.frame(["type": "error", "error": ["code": "late_error"]])
        case "oversize": body = Self.frame(["type": "delta", "content": String(repeating: "x", count: 4097)]) + Self.frame(["type": "completed"])
        default:
            if request.url?.lastPathComponent == "responses" {
                body = Self.frame(["type": "response.output_text.delta", "delta": "OK"]) + Self.frame(["type": "response.completed", "response": [:]])
            } else if request.url?.lastPathComponent == "messages" {
                body = Self.frame(["type": "content_block_delta", "delta": ["type": "text_delta", "text": "OK"]]) + Self.frame(["type": "message_stop"])
            } else { body = Self.normal }
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        if selected == "hold-terminal" { failsafe(); return }
        client?.urlProtocolDidFinishLoading(self)
    }
    private static var normal: String {
        frame(["choices": [["delta": ["content": "OK"]]]]) + frame(["choices": [["delta": [:], "finish_reason": "stop"]]])
    }
    private func failsafe() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.instanceLock.lock(); let stopped = self.isStopped; self.instanceLock.unlock()
            if !stopped { self.client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() {
        instanceLock.lock(); isStopped = true; instanceLock.unlock()
        Self.lock.lock(); Self.stoppedScenarios.insert(scenario); Self.lock.unlock()
    }
}
