import Foundation

private struct ProbeFailure: Error, CustomStringConvertible { let description: String }
private final class ProbeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    var isSignalled: Bool { lock.lock(); defer { lock.unlock() }; return signalled }
    func signal() {
        lock.lock(); signalled = true; let pending = Array(waiters.values); waiters.removeAll(); lock.unlock()
        pending.forEach { $0.resume(returning: true) }
    }
    func wait() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if signalled { lock.unlock(); continuation.resume(returning: true) }
                else if Task.isCancelled { lock.unlock(); continuation.resume(returning: false) }
                else { waiters[id] = continuation; lock.unlock() }
            }
        } onCancel: {
            self.lock.lock(); let pending = self.waiters.removeValue(forKey: id); self.lock.unlock()
            pending?.resume(returning: false)
        }
    }
}
private final class ProbeFixture: @unchecked Sendable {
    let body: String
    let hold: Bool
    let status: Int
    let mime: String
    let redirect: URL?
    let started = ProbeSignal(), stopped = ProbeSignal()
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    init(body: String, hold: Bool = false, status: Int = 200, mime: String = "text/event-stream", redirect: URL? = nil) {
        self.body = body; self.hold = hold; self.status = status; self.mime = mime; self.redirect = redirect
    }
    func record(_ request: URLRequest) {
        var observed = request
        if observed.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
            while bytes.count <= 65_536 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
            }
            observed.httpBody = bytes
        }
        lock.lock(); captured.append(observed); lock.unlock(); started.signal()
    }
}
private final class ProbeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: ProbeFixture] = [:]
    private static var allRequests: [URLRequest] = []
    private var fixture: ProbeFixture?
    private let instanceLock = NSLock()
    private var isStopped = false
    static func install(_ fixture: ProbeFixture, path: String) { lock.lock(); fixtures[path] = fixture; lock.unlock() }
    static func starts(to url: URL) -> Int { lock.lock(); defer { lock.unlock() }; return allRequests.filter { $0.url == url }.count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let fixture = Self.fixtures[request.url!.path]; Self.allRequests.append(request); Self.lock.unlock()
        instanceLock.lock(); self.fixture = fixture; let stopped = isStopped; instanceLock.unlock()
        if stopped { fixture?.stopped.signal(); return }
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        fixture.record(request)
        if let destination = fixture.redirect {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
            var redirected = request; redirected.url = destination
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": fixture.mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !fixture.body.isEmpty {
            let data = Data(fixture.body.utf8)
            for start in stride(from: 0, to: data.count, by: 37) { client?.urlProtocol(self, didLoad: data.subdata(in: start..<min(start + 37, data.count))) }
        }
        if !fixture.hold { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { instanceLock.lock(); isStopped = true; let fixture = self.fixture; instanceLock.unlock(); fixture?.stopped.signal() }
}
@MainActor private final class ProbeAuthorization {
    var allowed = true
    var checks = 0
    func validate() throws { checks += 1; if !allowed { throw AssistantTaskToolError.sourceChanged } }
}

@main private enum AssistantTaskToolCapabilityProbeTests {
    static var suites = 0
    static var failures: [String] = []
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw ProbeFailure(description: message) } }
    static func run(_ name: String, _ body: () async throws -> Void) async {
        do { try await body(); suites += 1; print("PASS \(name)") }
        catch { failures.append(name + ": " + String(describing: error)); print("FAIL \(name): \(error)") }
    }
    static func rejected(_ body: () async throws -> String) async throws -> Error {
        do { _ = try await body(); throw ProbeFailure(description: "Invalid capability probe unexpectedly returned proof") }
        catch let error as ProbeFailure { throw error }
        catch { return error }
    }
    static func awaitSignal(_ signal: ProbeSignal) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { guard await signal.wait() else { throw CancellationError() } }
            group.addTask { try await Task.sleep(nanoseconds: 2_000_000_000); throw ProbeFailure(description: "Native fixture handshake did not occur") }
            defer { group.cancelAll() }; _ = try await group.next()
        }
    }
    static func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)! }
    static func frame(_ value: [String: Any]) -> String { "data: " + json(value) + "\n\n" }
    static func config(_ kind: AssistantWireProtocol, path: String = UUID().uuidString, model: String = "fixture-model", key: String = "fixture-secret") -> BYOKConfiguration {
        BYOKConfiguration(baseURL: "https://probe-fixture.invalid/" + path + "/v1", protocolKind: kind, model: model, apiKey: key)
    }
    static func install(_ configuration: BYOKConfiguration, _ fixture: ProbeFixture) throws { ProbeURLProtocol.install(fixture, path: try configuration.endpoint().path) }
    static func transport(startupBarrier: (@Sendable () async -> Void)? = nil) -> AssistantStreamTransport {
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [ProbeURLProtocol.self]
        return AssistantStreamTransport(configuration: session, startupBarrier: startupBarrier)
    }
    static func payload(_ kind: AssistantWireProtocol, args: String = #"{"ok":true}"#, name: String = "caobao_task_probe", multiple: Bool = false, terminal: Bool = true) -> String {
        switch kind {
        case .chatCompletions:
            let call: [String: Any] = ["index": 0, "id": "probe_chat", "type": "function", "function": ["name": name, "arguments": args]]
            var calls = [call]
            if multiple { var second = call; second["index"] = 1; second["id"] = "probe_chat_second"; calls.append(second) }
            return frame(["choices": [["delta": ["role": "assistant", "tool_calls": calls]]]]) + (terminal ? frame(["choices": [["delta": [:], "finish_reason": "tool_calls"]]]) + "data: [DONE]\n\n" : "")
        case .responses:
            let call: [String: Any] = ["type": "function_call", "id": "probe_fc", "call_id": "probe_response", "name": name, "arguments": args, "status": "completed"]
            if !terminal { return frame(["type": "response.output_item.added", "output_index": 0, "item": call]) }
            return frame(["type": "response.completed", "response": ["status": "completed", "output": multiple ? [call, call] : [call]]])
        case .anthropic:
            var result = frame(["type": "message_start", "message": ["role": "assistant"]])
                + frame(["type": "content_block_start", "index": 0, "content_block": ["type": "tool_use", "id": "probe_anthropic", "name": name, "input": [:]]])
                + frame(["type": "content_block_delta", "index": 0, "delta": ["type": "input_json_delta", "partial_json": args]])
                + frame(["type": "content_block_stop", "index": 0])
            if multiple { result += frame(["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "probe_second", "name": name, "input": [:]]]) }
            result += frame(["type": "message_delta", "delta": ["stop_reason": "tool_use"]])
            return result + (terminal ? frame(["type": "message_stop"]) : "")
        }
    }
    static func textPayload(_ kind: AssistantWireProtocol) -> String {
        switch kind {
        case .chatCompletions: return frame(["choices": [["delta": ["content": "I support tools"], "finish_reason": "stop"]]]) + "data: [DONE]\n\n"
        case .responses: return frame(["type": "response.output_text.delta", "delta": "I support tools"]) + frame(["type": "response.completed", "response": ["status": "completed", "output": []]])
        case .anthropic: return frame(["type": "message_start", "message": ["role": "assistant"]]) + frame(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]) + frame(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "I support tools"]]) + frame(["type": "content_block_stop", "index": 0]) + frame(["type": "message_delta", "delta": ["stop_reason": "end_turn"]]) + frame(["type": "message_stop"])
        }
    }
    static func main() async throws {
        setbuf(stdout, nil)
        for kind in AssistantWireProtocol.allCases {
            await run("\(kind.rawValue)-fixed-harmless-request-and-fingerprint-proof") {
                let cfg = config(kind), fixture = ProbeFixture(body: payload(kind)); try install(cfg, fixture)
                let proof = try await AssistantTaskToolCapabilityProbe(transport: transport()).check(configuration: cfg)
                try expect(proof == cfg.consentIdentifier() && proof.count == 64 && !proof.contains(cfg.apiKey), "Only a configuration fingerprint is returned")
                try expect(fixture.requests.count == 1, "A capability probe makes exactly one independent HTTP request")
                let request = fixture.requests[0]
                guard let requestBody = request.httpBody, let body = try JSONSerialization.jsonObject(with: requestBody) as? [String: Any] else { throw ProbeFailure(description: "Native request body was not captured as bounded JSON") }
                try expect(request.timeoutInterval == 20 && body[kind == .responses ? "max_output_tokens" : "max_tokens"] as? Int == 128, "Probe network and output budgets are fixed")
                let history = body[kind == .responses ? "input" : "messages"] as! [[String: Any]]
                let user = history.last!
                try expect(user["role"] as? String == "user" && user["content"] as? String == "This is a capability check. Call caobao_task_probe with ok=true. Do not create a task.", "The isolated fixed input contains no chat history or private workspace data")
                try expect(history.count == (kind == .chatCompletions ? 2 : 1), "Only fixed system/user messages are permitted")
                let system = kind == .chatCompletions ? history.first?["content"] as? String : body[kind == .responses ? "instructions" : "system"] as? String
                try expect(system == "Only call the supplied harmless capability function. This check has no side effects.", "The capability check uses its own fixed system instructions")
                try expect(!String(decoding: requestBody, as: UTF8.self).contains(cfg.apiKey), "API credentials belong in protocol headers and never in model input")
                let tools = body["tools"] as! [[String: Any]], tool = kind == .chatCompletions ? tools[0]["function"] as! [String: Any] : tools[0]
                let schema = tool[kind == .anthropic ? "input_schema" : "parameters"] as! [String: Any]
                try expect(tools.count == 1 && tool["name"] as? String == "caobao_task_probe" && schema["required"] as? [String] == ["ok"] && schema["additionalProperties"] as? Bool == false, "The probe declares only the harmless strict function")
                let choice = body["tool_choice"] as! [String: Any], selected = kind == .chatCompletions ? (choice["function"] as? [String: String])?["name"] : choice["name"] as? String
                try expect(selected == "caobao_task_probe", "The harmless function must be forced")
            }
            await run("\(kind.rawValue)-text-without-call-is-not-capability-proof") {
                let cfg = config(kind); try install(cfg, ProbeFixture(body: textPayload(kind)))
                _ = try await rejected { try await AssistantTaskToolCapabilityProbe(transport: transport()).check(configuration: cfg) }
            }
            await run("\(kind.rawValue)-invalid-schema-name-and-multiple-calls-refused") {
                for body in [payload(kind, args: #"{"ok":false}"#), payload(kind, args: #"{"ok":1}"#), payload(kind, args: #"{"ok":true,"extra":true}"#), payload(kind, args: #"{"ok":false,"\u006fk":true}"#), payload(kind, name: "create_task"), payload(kind, multiple: true)] {
                    let cfg = config(kind); try install(cfg, ProbeFixture(body: body))
                    _ = try await rejected { try await AssistantTaskToolCapabilityProbe(transport: transport()).check(configuration: cfg) }
                }
            }
            await run("\(kind.rawValue)-truncated-tool-stream-does-not-return-proof") {
                let cfg = config(kind); try install(cfg, ProbeFixture(body: payload(kind, terminal: false)))
                _ = try await rejected { try await AssistantTaskToolCapabilityProbe(transport: transport()).check(configuration: cfg) }
            }
        }
        await run("http-mime-and-redirect-fail-with-no-credential-forwarding") {
            for mode in ["http", "mime", "redirect"] {
                let cfg = config(.chatCompletions), destination = URL(string: "https://other-probe.invalid/destination-" + UUID().uuidString)!
                let fixture = ProbeFixture(body: payload(.chatCompletions), status: mode == "http" ? 403 : 200, mime: mode == "mime" ? "application/json" : "text/event-stream", redirect: mode == "redirect" ? destination : nil)
                try install(cfg, fixture)
                _ = try await rejected { try await AssistantTaskToolCapabilityProbe(transport: transport()).check(configuration: cfg) }
                try expect(fixture.requests.count == 1 && ProbeURLProtocol.starts(to: destination) == 0, "Redirect destinations receive no probe, credentials or context")
            }
        }
        await run("before-start-wait-rejection-starts-zero-http") {
            let cfg = config(.chatCompletions), fixture = ProbeFixture(body: payload(.chatCompletions)); try install(cfg, fixture)
            let error = try await rejected { try await AssistantTaskToolCapabilityProbe(transport: transport()).check(configuration: cfg, beforeStartWait: { throw AssistantTaskToolError.sourceChanged }) }
            try expect(error as? AssistantTaskToolError == .sourceChanged && fixture.requests.isEmpty, "An asynchronous preparation rejection must preserve its error and start no HTTP")
        }
        await run("final-mainactor-hook-rejection-starts-zero-http") {
            let cfg = config(.chatCompletions), fixture = ProbeFixture(body: payload(.chatCompletions)); try install(cfg, fixture)
            let auth = await MainActor.run { ProbeAuthorization() }
            let error = try await rejected {
                try await AssistantTaskToolCapabilityProbe(transport: transport()).check(configuration: cfg, beforeStart: { try auth.validate() }, beforeStartWait: { auth.allowed = false })
            }
            let checks = await MainActor.run { auth.checks }
            try expect(error as? AssistantTaskToolError == .sourceChanged && checks == 1 && fixture.requests.isEmpty, "The final synchronous hook rechecks state after preparation and before native resume")
        }
        await run("cancelled-before-start-wait-release-starts-zero-http") {
            let cfg = config(.chatCompletions), fixture = ProbeFixture(body: payload(.chatCompletions)), entered = ProbeSignal(), release = ProbeSignal(); try install(cfg, fixture)
            let auth = await MainActor.run { ProbeAuthorization() }
            let operation = Task { try await AssistantTaskToolCapabilityProbe(transport: transport()).check(configuration: cfg, beforeStart: { try auth.validate() }, beforeStartWait: { entered.signal(); _ = await release.wait() }) }
            try await awaitSignal(entered); operation.cancel(); release.signal()
            _ = try await rejected { try await operation.value }
            let checks = await MainActor.run { auth.checks }
            try expect(fixture.requests.isEmpty && checks == 0, "Cancelling an actual suspended preparation cannot start a later authorization hook or HTTP request")
        }
        await run("pre-cancelled-probe-starts-zero-http") {
            let cfg = config(.chatCompletions), fixture = ProbeFixture(body: payload(.chatCompletions)); try install(cfg, fixture)
            let operation = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await AssistantTaskToolCapabilityProbe(transport: transport()).check(configuration: cfg) }
            _ = try await rejected { try await operation.value }
            try expect(fixture.requests.isEmpty, "A pre-cancelled probe cannot start HTTP")
        }
        await run("cancellation-stops-real-producer-after-handler-handshake") {
            let cfg = config(.chatCompletions), fixture = ProbeFixture(body: "", hold: true); try install(cfg, fixture)
            let operation = Task { try await AssistantTaskToolCapabilityProbe(transport: transport()).check(configuration: cfg) }
            try await awaitSignal(fixture.started); operation.cancel()
            _ = try await rejected { try await operation.value }; try await awaitSignal(fixture.stopped)
            try expect(fixture.requests.count == 1, "Cancellation must stop the one actually started producer")
        }
        await run("short-deadline-stops-held-native-producer-without-proof") {
            let cfg = config(.chatCompletions), fixture = ProbeFixture(body: payload(.chatCompletions), hold: true); try install(cfg, fixture)
            let operation = Task { try await AssistantTaskToolCapabilityProbe(transport: transport(), timeout: 0.1).check(configuration: cfg) }
            try await awaitSignal(fixture.started)
            let error = try await rejected { try await operation.value }; try await awaitSignal(fixture.stopped)
            guard case .configuration = error as? AssistantTransportError else { throw ProbeFailure(description: "A held real stream must fail at the injected deadline") }
            try expect(fixture.requests.count == 1 && fixture.stopped.isSignalled, "Even a complete provider SSE terminal cannot return proof without native EOF; deadline cancels the actual producer")
        }
        await run("same-probe-instance-keeps-concurrent-configurations-independent") {
            let instance = AssistantTaskToolCapabilityProbe(transport: transport()), slow = config(.responses), fast = config(.anthropic)
            let held = ProbeFixture(body: "", hold: true), ready = ProbeFixture(body: payload(.anthropic)); try install(slow, held); try install(fast, ready)
            let first = Task { try await instance.check(configuration: slow) }; try await awaitSignal(held.started)
            let proof = try await instance.check(configuration: fast)
            try expect(proof == fast.consentIdentifier() && !held.stopped.isSignalled, "A later independent success cannot cancel or replace an earlier producer")
            first.cancel(); _ = try await rejected { try await first.value }; try await awaitSignal(held.stopped)
        }
        await run("proof-binds-full-endpoint-protocol-model-and-key-without-persistence") {
            let baseline = config(.responses, path: "fingerprint-baseline"), instance = AssistantTaskToolCapabilityProbe(transport: transport(), timeout: 3_600)
            let defaultsBefore = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("caobao.assistant.") }
            var proofs = Set<String>()
            for cfg in [baseline, config(.responses, path: "different-endpoint"), config(.anthropic, path: "fingerprint-baseline"), config(.responses, path: "fingerprint-baseline", model: "different-model"), config(.responses, path: "fingerprint-baseline", key: "changed-fixture-secret")] {
                let fixture = ProbeFixture(body: payload(cfg.protocolKind)); try install(cfg, fixture)
                let proof = try await instance.check(configuration: cfg)
                try expect(proof == cfg.consentIdentifier() && !proof.contains(cfg.apiKey), "Proof is a non-secret configuration digest")
                try expect(fixture.requests[0].timeoutInterval == 20, "Caller timeout values cannot expand the request's fixed 20-second budget")
                proofs.insert(proof)
            }
            let defaultsAfter = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("caobao.assistant.") }
            try expect(proofs.count == 5 && NSDictionary(dictionary: defaultsBefore).isEqual(to: defaultsAfter), "All destinations require independent proofs and checking never enables or saves account preferences")
        }
        if !failures.isEmpty { throw ProbeFailure(description: failures.joined(separator: "\n")) }
        print("All \(suites) task-tool capability probe suites passed using native URLProtocol handshakes; no external network or system notifications.")
    }
}
