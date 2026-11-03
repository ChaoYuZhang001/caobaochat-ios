import Foundation

private struct TaskWireTestFailure: Error, CustomStringConvertible { let description: String }

/// Real URLSession/URLProtocol callbacks are used here. No model, DNS or network
/// is involved, and holding native EOF is independent of parsing an SSE marker.
private final class TaskWireURLProtocol: URLProtocol, @unchecked Sendable {
    struct Fixture { let body: Data; let holdEOF: Bool; let nativeError: Bool }
    private static let lock = NSLock()
    private static var fixtures: [String: Fixture] = [:]
    private static var instances: [String: TaskWireURLProtocol] = [:]
    private static var delivered = Set<String>()
    private let queue = DispatchQueue(label: "caobao.task-wire.fixture")
    private var stopped = false
    static func install(_ path: String, body: String, holdEOF: Bool = false, nativeError: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        fixtures[path] = Fixture(body: Data(body.utf8), holdEOF: holdEOF, nativeError: nativeError)
    }
    static func bodyWasDelivered(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return delivered.contains(path) }
    static func release(_ path: String) {
        lock.lock(); let instance = instances[path]; lock.unlock()
        instance?.queue.async { [weak instance] in
            guard let instance, !instance.stopped else { return }
            instance.client?.urlProtocolDidFinishLoading(instance)
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "task-wire.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock(); let fixture = Self.fixtures[path]; Self.instances[path] = self; Self.lock.unlock()
        queue.async { [weak self] in
            guard let self, !self.stopped, let fixture else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Split UTF-8 and SSE framing across arbitrary native callbacks.
            var offset = 0
            while offset < fixture.body.count, !self.stopped {
                let end = min(offset + 29, fixture.body.count)
                self.client?.urlProtocol(self, didLoad: fixture.body.subdata(in: offset..<end)); offset = end
            }
            Self.lock.lock(); Self.delivered.insert(path); Self.lock.unlock()
            if fixture.nativeError { self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
            else if !fixture.holdEOF { self.client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() { queue.async { [weak self] in self?.stopped = true } }
}

private final class TaskWireCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AssistantTransportEvent] = []
    func append(_ event: AssistantTransportEvent) { lock.lock(); values.append(event); lock.unlock() }
    func snapshot() -> [AssistantTransportEvent] { lock.lock(); defer { lock.unlock() }; return values }
}

@main private enum AssistantTaskToolProtocolTests {
    static let arguments = #"{"title":"Plan the trip","notes":"Review options","due_at":null,"time_zone":null,"reminder_requested":false}"#
    // Sanitized native gateway capture; provider reasoning was replaced before capture storage.
    // No credential or real provider reasoning is embedded in this fixture.
    static let sanitizedGatewayProbeStop = "data: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"reasoning_content\":\"[provider reasoning omitted]\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"reasoning_content\":\"[provider reasoning omitted]\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"reasoning_content\":\"[provider reasoning omitted]\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"reasoning_content\":\"[provider reasoning omitted]\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"reasoning_content\":\"[provider reasoning omitted]\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"reasoning_content\":\"[provider reasoning omitted]\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"reasoning_content\":\"[provider reasoning omitted]\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"reasoning_content\":\"[provider reasoning omitted]\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"reasoning_content\":\"[provider reasoning omitted]\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"reasoning_content\":\"[provider reasoning omitted]\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"reasoning_content\":\"[provider reasoning omitted]\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"reasoning_content\":\"[provider reasoning omitted]\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"reasoning_content\":\"[provider reasoning omitted]\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"reasoning_content\":\"[provider reasoning omitted]\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"reasoning_content\":\"[provider reasoning omitted]\"},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_7ca3a0562f4a4b4584b8a63a\",\"type\":\"function\",\"function\":{\"name\":\"caobao_task_probe\",\"arguments\":\"\"}}]},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"type\":\"function\",\"function\":{\"arguments\":\"{\"}}]},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"type\":\"function\",\"function\":{\"arguments\":\"\\\"ok\\\": tru\"}}]},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"type\":\"function\",\"function\":{\"arguments\":\"e}\"}}]},\"logprobs\":null,\"finish_reason\":null,\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[{\"delta\":{},\"logprobs\":null,\"finish_reason\":\"stop\",\"index\":0}],\"usage\":null}\n\ndata: {\"id\":\"chatcmpl-1793340438953280457\",\"object\":\"chat.completion.chunk\",\"created\":1793340438,\"model\":\"qwen3.8-max\",\"system_fingerprint\":null,\"choices\":[],\"usage\":{\"prompt_tokens\":412,\"completion_tokens\":75,\"total_tokens\":487,\"prompt_tokens_details\":{\"cached_tokens\":0,\"text_tokens\":0,\"audio_tokens\":0,\"image_tokens\":0},\"completion_tokens_details\":{\"text_tokens\":0,\"audio_tokens\":0,\"image_tokens\":0,\"reasoning_tokens\":28},\"input_tokens\":0,\"output_tokens\":0,\"input_tokens_details\":null,\"claude_cache_creation_5_m_tokens\":0,\"claude_cache_creation_1_h_tokens\":0}}\n\ndata: [DONE]\n\n"
    static var suites = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw TaskWireTestFailure(description: message) }
    }
    static func run(_ name: String, _ body: () async throws -> Void) async throws { try await body(); suites += 1; print("PASS \(name)") }
    static func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)! }
    static func frame(_ value: [String: Any]) -> String { "data: " + json(value) + "\n\n" }
    static func config(_ kind: AssistantWireProtocol, path: String = UUID().uuidString, key: String = "fixture-key", model: String = "fixture-model") -> BYOKConfiguration {
        BYOKConfiguration(baseURL: "https://task-wire.invalid/" + path + "/v1", protocolKind: kind, model: model, apiKey: key)
    }
    static func request(_ kind: AssistantWireProtocol, body: String, mode: AssistantTaskToolMode = .taskProposal, holdEOF: Bool = false, nativeError: Bool = false) throws -> URLRequest {
        let request = try config(kind).request(turns: [AssistantTurn(id: "u", role: "user", text: "Suggest a task")], instructions: "Be helpful", requestId: "fixture-request", toolMode: mode)
        TaskWireURLProtocol.install(request.url!.path, body: body, holdEOF: holdEOF, nativeError: nativeError)
        return request
    }
    static func transport() -> AssistantStreamTransport {
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [TaskWireURLProtocol.self]
        return AssistantStreamTransport(configuration: session)
    }
    static func collect(_ request: URLRequest, mode: AssistantTaskToolMode = .taskProposal, capture: TaskWireCapture? = nil) async -> (events: [AssistantTransportEvent], error: Error?) {
        var events: [AssistantTransportEvent] = []
        do {
            for try await event in transport().events(for: request, toolMode: mode) { events.append(event); capture?.append(event) }
            return (events, nil)
        } catch { return (events, error) }
    }
    static func calls(_ events: [AssistantTransportEvent]) -> [AssistantTaskToolCall] { events.compactMap { if case .taskTool(let call) = $0 { return call }; return nil } }
    static func waitForBody(_ path: String) async throws {
        for _ in 0..<300 {
            if TaskWireURLProtocol.bodyWasDelivered(path) { try await Task.sleep(nanoseconds: 20_000_000); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw TaskWireTestFailure(description: "Fixture HTTP body did not reach native callbacks")
    }
    static func chat(_ args: String = arguments, name: String = "create_task", finish: String = "tool_calls", done: Bool = true) -> String {
        let cut = args.index(args.startIndex, offsetBy: args.count / 2)
        let first = String(args[..<cut]), second = String(args[cut...])
        return frame(["choices": [["index": 0, "delta": ["role": "assistant", "tool_calls": [["index": 0, "id": "call_chat", "type": "function", "function": ["name": name, "arguments": first]]]]]]])
            + frame(["choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "function": ["arguments": second]]]]]]])
            + frame(["choices": [["index": 0, "delta": [:], "finish_reason": finish]], "usage": ["prompt_tokens": 8, "completion_tokens": 5]])
            + (done ? "data: [DONE]\n\n" : "")
    }
    static func responseOutput(_ args: String = arguments, name: String = "create_task") -> [[String: Any]] {
        [["type": "reasoning", "id": "reason_1", "summary": [["type": "summary_text", "text": "A task may help."]], "encrypted_content": "opaque-reasoning-fixture"],
         ["type": "function_call", "id": "fc_1", "call_id": "call_response", "name": name, "arguments": args, "status": "completed"]]
    }
    static func responses(_ args: String = arguments, name: String = "create_task", deltaId: String = "fc_1", completedArgs: String? = nil) -> String {
        let output = responseOutput(completedArgs ?? args, name: name)
        return frame(["type": "response.output_item.added", "output_index": 0, "item": output[0]])
            + frame(["type": "response.output_item.added", "output_index": 1, "item": ["type": "function_call", "id": "fc_1", "call_id": "call_response", "name": name, "arguments": "", "status": "in_progress"]])
            + frame(["type": "response.function_call_arguments.delta", "output_index": 1, "item_id": deltaId, "delta": args])
            + frame(["type": "response.function_call_arguments.done", "output_index": 1, "item_id": "fc_1", "arguments": args])
            + frame(["type": "response.output_item.done", "output_index": 1, "item": output[1]])
            + frame(["type": "response.completed", "response": ["status": "completed", "output": output, "usage": ["input_tokens": 8, "output_tokens": 5]]])
    }
    static func anthropic(_ args: String = arguments, name: String = "create_task", stopBlock: Bool = true, reason: String = "tool_use", messageStop: Bool = true) -> String {
        frame(["type": "message_start", "message": ["id": "a1", "role": "assistant", "usage": ["input_tokens": 8]]])
            + frame(["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]])
            + frame(["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Consider a task."]])
            + frame(["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "opaque-signature-fixture"]])
            + frame(["type": "content_block_stop", "index": 0])
            + frame(["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "call_anthropic", "name": name, "input": [:]]])
            + frame(["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": args]])
            + (stopBlock ? frame(["type": "content_block_stop", "index": 1]) : "")
            + frame(["type": "message_delta", "delta": ["stop_reason": reason], "usage": ["output_tokens": 5]])
            + (messageStop ? frame(["type": "message_stop"]) : "")
    }
    static func payload(_ kind: AssistantWireProtocol, args: String = arguments, name: String = "create_task") -> String {
        switch kind { case .chatCompletions: return chat(args, name: name); case .responses: return responses(args, name: name); case .anthropic: return anthropic(args, name: name) }
    }
    static func object(_ request: URLRequest) throws -> [String: Any] { try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any] }
    static func stopChat(_ mode: AssistantTaskToolMode, args: String? = nil, name: String? = nil,
                         finish: String = "stop", done: Bool = true) -> String {
        chat(args ?? (mode == .capabilityProbe ? #"{"ok":true}"# : arguments),
            name: name ?? (mode == .capabilityProbe ? "caobao_task_probe" : "create_task"), finish: finish, done: done)
    }
    static func main() async throws {
        try await run("chat-gateway-stop-valid-probe-native-capture") {
            let result = await collect(try request(.chatCompletions, body: sanitizedGatewayProbeStop, mode: .capabilityProbe), mode: .capabilityProbe)
            try expect(result.error == nil && calls(result.events).count == 1, "Captured valid single probe call with stop and actual native EOF must succeed; got \(String(describing: result.error))")
            let call = calls(result.events)[0]
            try expect(call.name == "caobao_task_probe" && call.arguments == #"{"ok": true}"#, "Captured chunked identity and arguments must survive exactly")
            try call.validate(for: .capabilityProbe)
            try expect(result.events.last == .completed && result.events.contains { if case .usage = $0 { return true }; return false }, "The captured post-terminal usage frame and completion remain observable")
        }
        try await run("chat-stop-valid-task-proposal-uses-same-structured-validation") {
            let result = await collect(try request(.chatCompletions, body: stopChat(.taskProposal)))
            try expect(result.error == nil && calls(result.events).count == 1 && result.events.last == .completed,
                "A complete advertised task proposal may use the same successful stop terminal as the capability probe")
            let call = calls(result.events)[0]
            try expect(call.name == "create_task" && call.arguments == arguments, "Task identity and full arguments must remain unchanged")
            try call.validate(for: .taskProposal)
        }
        try await run("chat-stop-needs-native-eof-and-discards-native-error-or-cancel") {
            for mode in [AssistantTaskToolMode.capabilityProbe, .taskProposal] {
                let req = try request(.chatCompletions, body: stopChat(mode), mode: mode, holdEOF: true), capture = TaskWireCapture()
                let consumer = Task { await collect(req, mode: mode, capture: capture) }
                try await waitForBody(req.url!.path)
                try expect(calls(capture.snapshot()).isEmpty && !capture.snapshot().contains(.completed),
                    "Even complete stop plus DONE cannot publish a call before native EOF")
                TaskWireURLProtocol.release(req.url!.path)
                let result = await consumer.value
                try expect(result.error == nil && calls(result.events).count == 1, "One call is released only after successful native EOF")
                let failed = await collect(try request(.chatCompletions, body: stopChat(mode), mode: mode, nativeError: true), mode: mode)
                try expect(failed.error != nil && calls(failed.events).isEmpty, "Native transport failure discards the complete stop call")
                let cancelledReq = try request(.chatCompletions, body: stopChat(mode), mode: mode, holdEOF: true), cancelledCapture = TaskWireCapture()
                let cancelledConsumer = Task { await collect(cancelledReq, mode: mode, capture: cancelledCapture) }
                try await waitForBody(cancelledReq.url!.path); cancelledConsumer.cancel()
                let cancelled = await cancelledConsumer.value
                try expect(cancelled.error != nil && calls(cancelled.events).isEmpty && calls(cancelledCapture.snapshot()).isEmpty,
                    "Cancellation before EOF cannot release stop-terminated tool authority")
                TaskWireURLProtocol.release(cancelledReq.url!.path)
            }
        }
        try await run("chat-stop-explicit-finish-and-native-eof-do-not-require-done-marker") {
            for mode in [AssistantTaskToolMode.capabilityProbe, .taskProposal] {
                // Preserve the existing Chat contract: a successful explicit
                // finish plus native EOF is sufficient, with or without DONE.
                for finish in ["tool_calls", "stop"] {
                    let result = await collect(try request(.chatCompletions, body: stopChat(mode, finish: finish, done: false), mode: mode), mode: mode)
                    try expect(result.error == nil && calls(result.events).count == 1,
                        "Missing optional DONE cannot invalidate an explicit successful terminal followed by real EOF")
                }
                let incomplete = stopChat(mode).components(separatedBy: "\n\n").prefix(2).joined(separator: "\n\n") + "\n\n"
                for tail in ["", "data: [DONE]\n\n"] {
                    let result = await collect(try request(.chatCompletions, body: incomplete + tail, mode: mode), mode: mode)
                    try expect(result.error != nil && calls(result.events).isEmpty,
                        "EOF or DONE without an explicit successful finish cannot authorize even complete argument bytes")
                }
            }
        }
        try await run("chat-stop-truncated-wrong-schema-and-missing-call-identity-refused") {
            for mode in [AssistantTaskToolMode.capabilityProbe, .taskProposal] {
                let validArgs = mode == .capabilityProbe ? #"{"ok":true}"# : arguments
                let name = mode == .capabilityProbe ? "caobao_task_probe" : "create_task"
                let invalidArgs = [String(validArgs.dropLast()), validArgs.dropLast() + #", "approved":true}"#,
                    mode == .capabilityProbe ? #"{"ok":false}"# : arguments.replacingOccurrences(of: "false}", with: "1}")]
                for args in invalidArgs {
                    let result = await collect(try request(.chatCompletions, body: stopChat(mode, args: args), mode: mode), mode: mode)
                    try expect(result.error != nil && calls(result.events).isEmpty, "Stop does not waive complete strict argument validation")
                }
                for function in [["name": name, "arguments": validArgs], ["arguments": validArgs]] {
                    let body = frame(["choices": [["delta": ["tool_calls": [["index": 0, "type": "function", "function": function]]]]]])
                        + frame(["choices": [["delta": [:], "finish_reason": "stop"]]]) + "data: [DONE]\n\n"
                    let result = await collect(try request(.chatCompletions, body: body, mode: mode), mode: mode)
                    try expect(result.error != nil && calls(result.events).isEmpty, "A complete id and name remain mandatory at native EOF")
                }
            }
        }
        try await run("chat-stop-multiple-conflicting-and-unknown-tools-refused") {
            for mode in [AssistantTaskToolMode.capabilityProbe, .taskProposal] {
                let args = mode == .capabilityProbe ? #"{"ok":true}"# : arguments
                let name = mode == .capabilityProbe ? "caobao_task_probe" : "create_task"
                let call: [String: Any] = ["index": 0, "id": "one", "type": "function", "function": ["name": name, "arguments": args]]
                var other = call; other["index"] = 1; other["id"] = "two"
                let multiple = frame(["choices": [["delta": ["tool_calls": [call, other]], "finish_reason": "stop"]]]) + "data: [DONE]\n\n"
                let changedID = frame(["choices": [["delta": ["tool_calls": [call]]]]])
                    + frame(["choices": [["delta": ["tool_calls": [["index": 0, "id": "different"]]], "finish_reason": "stop"]]]) + "data: [DONE]\n\n"
                let changedIndex = frame(["choices": [["delta": ["tool_calls": [call]]]]])
                    + frame(["choices": [["delta": ["tool_calls": [other]], "finish_reason": "stop"]]]) + "data: [DONE]\n\n"
                for body in [multiple, changedID, changedIndex, stopChat(mode, name: "delete_everything") ] {
                    let result = await collect(try request(.chatCompletions, body: body, mode: mode), mode: mode)
                    try expect(result.error != nil && calls(result.events).isEmpty, "Successful stop cannot bypass one-call identity or function allowlisting")
                }
            }
        }
        try await run("chat-stop-compatibility-does-not-accept-length-content-filter-or-error") {
            for mode in [AssistantTaskToolMode.capabilityProbe, .taskProposal] {
                for reason in ["length", "content_filter", "error", "function_call", ""] {
                    let result = await collect(try request(.chatCompletions, body: stopChat(mode, finish: reason), mode: mode), mode: mode)
                    try expect(result.error != nil && calls(result.events).isEmpty,
                        "Only successful stop/tool_calls terminals may finalize a validated structured call")
                }
            }
        }
        try await run("chat-stop-disabled-and-postterminal-tool-deltas-still-refused") {
            for mode in [AssistantTaskToolMode.capabilityProbe, .taskProposal] {
                let disabled = await collect(try request(.chatCompletions, body: stopChat(mode), mode: .disabled), mode: .disabled)
                try expect(disabled.error != nil && calls(disabled.events).isEmpty, "A normal disabled request cannot inherit probe or task tool authority")
                let lateTool = frame(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "extra"]]]]]]])
                let body = stopChat(mode, done: false) + lateTool + "data: [DONE]\n\n"
                let late = await collect(try request(.chatCompletions, body: body, mode: mode), mode: mode)
                try expect(late.error != nil && calls(late.events).isEmpty, "No function bytes may arrive after the terminal stop")
            }
        }
        for kind in AssistantWireProtocol.allCases {
            try await run("\(kind.rawValue)-schema-single-required-proposal") {
                let body = try object(config(kind).request(turns: [], instructions: "", requestId: "schema", toolMode: .taskProposal))
                let tools = body["tools"] as! [[String: Any]]
                try expect(tools.count == 1, "Only one tool may be declared")
                let function = kind == .chatCompletions ? tools[0]["function"] as! [String: Any] : tools[0]
                let parameters = function[kind == .anthropic ? "input_schema" : "parameters"] as! [String: Any]
                try expect(function["name"] as? String == "create_task", "Only create_task is exposed")
                try expect(Set(parameters["required"] as! [String]) == ["title", "notes", "due_at", "time_zone", "reminder_requested"], "Every schema property must be required")
                try expect(parameters["additionalProperties"] as? Bool == false, "Model-owned approval or task IDs are disallowed")
                if kind != .anthropic { try expect(body["parallel_tool_calls"] as? Bool == false, "Parallel calls must be disabled") }
                else { try expect((body["tool_choice"] as? [String: Any])?["disable_parallel_tool_use"] as? Bool == true, "Anthropic parallel calls must be disabled") }
            }
            try await run("\(kind.rawValue)-single-tool-only-success-at-eof") {
                let result = await collect(try request(kind, body: payload(kind)))
                try expect(result.error == nil && calls(result.events).count == 1, "A complete tool-only stream must succeed once")
                let call = calls(result.events)[0]
                try expect(call.name == "create_task" && call.arguments == arguments, "Raw arguments and tool identity must survive")
                try expect(call.trace.protocolKind == kind && result.events.last == .completed, "Protocol and final completion must survive")
                try expect(result.events.contains { if case .usage(let usage) = $0 { return usage.outputTokens == 5 }; return false }, "Tool-only replies must retain billable token usage")
                try call.validate(for: .taskProposal)
            }
            try await run("\(kind.rawValue)-waits-for-native-http-eof") {
                let req = try request(kind, body: payload(kind), holdEOF: true), capture = TaskWireCapture()
                let consumer = Task { await collect(req, capture: capture) }
                try await waitForBody(req.url!.path)
                try expect(calls(capture.snapshot()).isEmpty && !capture.snapshot().contains(.completed), "An SSE terminal marker is insufficient without native EOF")
                TaskWireURLProtocol.release(req.url!.path)
                let result = await consumer.value
                try expect(result.error == nil && calls(result.events).count == 1, "One proposal may appear after EOF")
            }
            try await run("\(kind.rawValue)-native-failure-never-releases-tool") {
                let result = await collect(try request(kind, body: payload(kind), nativeError: true))
                try expect(result.error != nil && calls(result.events).isEmpty, "A failed HTTP stream cannot release executable state")
            }
            try await run("\(kind.rawValue)-cancelled-before-eof-never-releases-tool") {
                let req = try request(kind, body: payload(kind), holdEOF: true), capture = TaskWireCapture()
                let consumer = Task { await collect(req, capture: capture) }
                try await waitForBody(req.url!.path); consumer.cancel()
                let result = await consumer.value
                try expect(calls(result.events).isEmpty && calls(capture.snapshot()).isEmpty, "Cancellation must discard the complete but uncommitted tool")
                TaskWireURLProtocol.release(req.url!.path)
            }
            try await run("\(kind.rawValue)-default-disabled-refuses-tools") {
                let result = await collect(try request(kind, body: payload(kind)), mode: .disabled)
                try expect(result.error != nil && calls(result.events).isEmpty, "Default mode must retain fail-closed tool refusal")
            }
            try await run("\(kind.rawValue)-unknown-tools-and-malformed-arguments-refused") {
                for body in [payload(kind, name: "delete_all"), payload(kind, args: "{\"title\":"), payload(kind, args: arguments.replacingOccurrences(of: "false}", with: "false,\"approved\":true}"))] {
                    let result = await collect(try request(kind, body: body))
                    try expect(result.error != nil && calls(result.events).isEmpty, "Unknown tools or invalid JSON may not become a proposal")
                }
            }
            try await run("\(kind.rawValue)-forced-probe-only-parses-ok") {
                let cfg = config(kind)
                let body = try object(cfg.request(turns: [], instructions: "Probe", requestId: "probe", toolMode: .capabilityProbe))
                let choice = body["tool_choice"] as! [String: Any]
                let forced = kind == .chatCompletions ? (choice["function"] as? [String: String])?["name"] : choice["name"] as? String
                try expect(forced == "caobao_task_probe", "Probe must force its isolated function")
                let success = await collect(try request(kind, body: payload(kind, args: #"{"ok":true}"#, name: "caobao_task_probe"), mode: .capabilityProbe), mode: .capabilityProbe)
                try expect(success.error == nil && calls(success.events).first?.name == "caobao_task_probe", "Probe may produce a typed validation result only")
                let failure = await collect(try request(kind, body: payload(kind, args: #"{"ok":false}"#, name: "caobao_task_probe"), mode: .capabilityProbe), mode: .capabilityProbe)
                try expect(failure.error != nil && calls(failure.events).isEmpty, "Probe ok=false must fail")
            }
            try await run("\(kind.rawValue)-continue-pairs-result-and-isolates-fingerprint") {
                let cfg = config(kind, path: "continuation-" + kind.rawValue)
                let first = await collect(try request(kind, body: payload(kind)))
                let call = calls(first.events)[0]
                var turn = AssistantTurn(id: "a", role: "assistant", text: "Visible task summary")
                turn.toolExchange = AssistantTaskToolExchange(call: call, configurationFingerprint: try cfg.consentIdentifier(), resultJSON: #"{"status":"saved","task_id":"local-task"}"#)
                let continuation = try cfg.request(turns: [turn], instructions: "Helpful", requestId: "continue")
                let body = try object(continuation)
                let history = body[kind == .responses ? "input" : "messages"] as! [[String: Any]]
                let encoded = String(data: continuation.httpBody!, encoding: .utf8)!
                try expect(encoded.contains(call.id) && encoded.contains("local-task"), "The original call and paired local result must remain together")
                if kind == .responses { try expect(encoded.contains("opaque-reasoning-fixture"), "Responses encrypted reasoning must survive continuation") }
                if kind == .anthropic { try expect(encoded.contains("opaque-signature-fixture"), "Anthropic thinking signature must survive continuation") }
                try expect(history.count >= 2, "Assistant call and tool result must both be present")
                if kind == .anthropic { try expect((body["tool_choice"] as? [String: String])?["type"] == "none", "Continue must forbid additional tools") }
                else { try expect(body["tool_choice"] as? String == "none", "Continue must forbid additional tools") }
                let changed = config(kind, path: "continuation-" + kind.rawValue, key: "changed-key")
                let isolated = try changed.request(turns: [turn], instructions: "Helpful", requestId: "isolated")
                let isolatedText = String(data: isolated.httpBody!, encoding: .utf8)!
                try expect(isolatedText.contains("Visible task summary") && !isolatedText.contains(call.id) && !isolatedText.contains("local-task") && !isolatedText.contains("opaque-"), "A changed API key must send visible text only")
                try expect(try object(isolated)["tools"] == nil, "Ordinary disabled requests should not declare any tools")
                let otherProtocol: AssistantWireProtocol = kind == .responses ? .anthropic : .responses
                for changed in [config(kind, path: "different-endpoint"), config(kind, path: "continuation-" + kind.rawValue, model: "different-model"), config(otherProtocol, path: "continuation-" + kind.rawValue)] {
                    let isolated = try changed.request(turns: [turn], instructions: "Helpful", requestId: "changed-destination")
                    let text = String(data: isolated.httpBody!, encoding: .utf8)!
                    try expect(text.contains("Visible task summary") && !text.contains(call.id) && !text.contains("local-task") && !text.contains("opaque-"), "Changing endpoint, model or protocol must never replay provider-owned state")
                }
            }
        }
        try await run("chat-completions-multiple-tools-refused") {
            let call: [String: Any] = ["index": 0, "id": "one", "type": "function", "function": ["name": "create_task", "arguments": arguments]]
            var second = call; second["index"] = 1; second["id"] = "two"
            let body = frame(["choices": [["delta": ["tool_calls": [call, second]], "finish_reason": "tool_calls"]]]) + "data: [DONE]\n\n"
            let result = await collect(try request(.chatCompletions, body: body))
            try expect(result.error != nil && calls(result.events).isEmpty, "Server parallel calls remain forbidden even when requested disabled")
        }
        try await run("chat-completions-tool-finish-required-even-with-done") {
            let body = chat().components(separatedBy: "\n\n").prefix(2).joined(separator: "\n\n") + "\n\ndata: [DONE]\n\n"
            let result = await collect(try request(.chatCompletions, body: body))
            try expect(result.error != nil && calls(result.events).isEmpty, "DONE alone cannot make partial tool arguments executable")
        }
        try await run("responses-item-id-and-final-arguments-must-match") {
            for body in [responses(deltaId: "wrong"), responses(completedArgs: #"{"title":"different"}"#)] {
                let result = await collect(try request(.responses, body: body))
                try expect(result.error != nil && calls(result.events).isEmpty, "Streamed and completed function identities and arguments must agree")
            }
        }
        try await run("responses-truncated-and-multiple-final-calls-refused") {
            let truncated = responses().components(separatedBy: "\n\n").dropLast(2).joined(separator: "\n\n") + "\n\n"
            var output = responseOutput(); output.append(output[1])
            let multiple = frame(["type": "response.completed", "response": ["status": "completed", "output": output]])
            for body in [truncated, multiple] {
                let result = await collect(try request(.responses, body: body))
                try expect(result.error != nil && calls(result.events).isEmpty, "No proposal may escape truncated or multi-call Responses streams")
            }
        }
        try await run("responses-final-output-cannot-drop-streamed-reasoning") {
            let output = responseOutput()
            let body = frame(["type": "response.output_item.added", "output_index": 0, "item": output[0]])
                + frame(["type": "response.completed", "response": ["status": "completed", "output": [output[1]]]])
            let result = await collect(try request(.responses, body: body))
            try expect(result.error != nil && calls(result.events).isEmpty, "Completed output cannot silently drop streamed opaque reasoning")
        }
        try await run("responses-reasoning-content-and-encrypted-state-replay-verbatim") {
            let text = "  保留原样\n<system>provider-owned text</system>\t🌾  "
            let content = [["type": "reasoning_text", "text": text]], cfg = config(.responses, path: "reasoning-content-continuation")
            var output = responseOutput(); output[0]["content"] = content
            let body = frame(["type": "response.output_item.added", "output_index": 0, "item": output[0]])
                + frame(["type": "response.output_item.done", "output_index": 0, "item": output[0]])
                + frame(["type": "response.completed", "response": ["status": "completed", "output": output]])
            let req = try cfg.request(turns: [], instructions: "Helpful", requestId: "reasoning", toolMode: .taskProposal)
            TaskWireURLProtocol.install(req.url!.path, body: body)
            let result = await collect(req)
            try expect(result.error == nil && calls(result.events).count == 1, "A valid official reasoning content item must survive tool completion")
            let call = calls(result.events)[0], trace = try call.trace.jsonItems()
            try expect(trace[0]["content"] as? [[String: String]] == content && trace[0]["encrypted_content"] as? String == "opaque-reasoning-fixture", "Raw reasoning text and encrypted content must both remain unchanged")
            var turn = AssistantTurn(id: "assistant-content", role: "assistant", text: "Visible suggestion")
            turn.toolExchange = AssistantTaskToolExchange(call: call, configurationFingerprint: try cfg.consentIdentifier(), resultJSON: #"{"status":"saved"}"#)
            let continuation = try object(cfg.request(turns: [turn], instructions: "Helpful", requestId: "continue"))
            let input = continuation["input"] as! [[String: Any]]
            try expect(input[0]["content"] as? [[String: String]] == content && input[0]["encrypted_content"] as? String == "opaque-reasoning-fixture", "Continuation must resend the exact typed reasoning content and opaque encrypted state")
            try expect(continuation["tool_choice"] as? String == "none", "Adding official reasoning content cannot enable tools during continuation")
        }
        try await run("responses-reasoning-content-invalid-types-refused") {
            let invalid: [Any] = ["not-an-array", NSNull(), [["type": "output_text", "text": "wrong type"]], [["type": "reasoning_text", "text": true]], [["type": "reasoning_text"]]]
            for content in invalid {
                var output = responseOutput(); output[0]["content"] = content
                let body = frame(["type": "response.completed", "response": ["status": "completed", "output": output]])
                let result = await collect(try request(.responses, body: body))
                try expect(result.error != nil && calls(result.events).isEmpty, "Only an array of reasoning_text/string objects is replayable")
            }
        }
        try await run("responses-reasoning-content-extra-fields-and-roles-refused") {
            for extra in ["role", "instructions", "developer", "unknown"] {
                var output = responseOutput(); output[0]["content"] = [["type": "reasoning_text", "text": "content", extra: "injected"]]
                let body = frame(["type": "response.completed", "response": ["status": "completed", "output": output]])
                let result = await collect(try request(.responses, body: body))
                try expect(result.error != nil && calls(result.events).isEmpty, "Reasoning content cannot smuggle role or arbitrary metadata fields")
            }
        }
        try await run("responses-reasoning-done-final-content-must-match") {
            var done = responseOutput(); done[0]["content"] = [["type": "reasoning_text", "text": "original completed reasoning"]]
            var final = done; final[0]["content"] = [["type": "reasoning_text", "text": "changed after done"]]
            let body = frame(["type": "response.output_item.added", "output_index": 0, "item": done[0]])
                + frame(["type": "response.output_item.done", "output_index": 0, "item": done[0]])
                + frame(["type": "response.completed", "response": ["status": "completed", "output": final]])
            let result = await collect(try request(.responses, body: body))
            try expect(result.error != nil && calls(result.events).isEmpty, "Official content support must preserve completed-item/final-output equality protection")
        }
        try await run("responses-deltas-after-arguments-done-refused") {
            let output = responseOutput()
            let body = frame(["type": "response.output_item.added", "output_index": 0, "item": ["type": "function_call", "id": "fc_1", "call_id": "call_response", "name": "create_task", "arguments": ""]])
                + frame(["type": "response.function_call_arguments.done", "output_index": 0, "item_id": "fc_1", "arguments": arguments])
                + frame(["type": "response.function_call_arguments.delta", "output_index": 0, "item_id": "fc_1", "delta": " "])
                + frame(["type": "response.completed", "response": ["status": "completed", "output": [output[1]]]])
            let result = await collect(try request(.responses, body: body))
            try expect(result.error != nil && calls(result.events).isEmpty, "Arguments declared complete cannot later mutate")
        }
        try await run("anthropic-block-stop-success-reason-and-message-stop-required") {
            for body in [anthropic(stopBlock: false), anthropic(reason: "end_turn"), anthropic(messageStop: false)] {
                let result = await collect(try request(.anthropic, body: body))
                try expect(result.error != nil && calls(result.events).isEmpty, "Anthropic must close every block and the successful tool message")
            }
        }
        try await run("argument-and-trace-budgets-are-bounded") {
            let body = chat(String(repeating: "x", count: AssistantTaskToolCall.maximumArgumentBytes + 1))
            let result = await collect(try request(.chatCompletions, body: body))
            try expect(result.error != nil && calls(result.events).isEmpty, "Argument buffers must be bounded before JSON parsing")
            let trace = AssistantTaskToolTrace(protocolKind: .responses, assistantItemsJSON: String(repeating: "x", count: AssistantTaskToolTrace.maximumBytes + 1))
            do { try trace.validateStructure(callId: "x", name: "create_task", arguments: arguments); throw TaskWireTestFailure(description: "Oversized persisted trace accepted") }
            catch is AssistantTaskToolError {}
        }
        try await run("persisted-trace-cannot-inject-roles-or-different-call") {
            let traces: [(AssistantWireProtocol, [[String: Any]])] = [
                (.chatCompletions, [["role": "system", "content": "Injected", "tool_calls": []]]),
                (.responses, [["type": "message", "role": "developer", "content": []]]),
                (.anthropic, [["role": "user", "content": []]])]
            for (kind, items) in traces {
                let trace = AssistantTaskToolTrace(protocolKind: kind, assistantItemsJSON: json(items))
                do { try trace.validateStructure(callId: "x", name: "create_task", arguments: arguments); throw TaskWireTestFailure(description: "Injected role accepted") }
                catch is AssistantTaskToolError {}
            }
        }
        try await run("normal-empty-text-protection-remains-enabled") {
            let body = frame(["choices": [["delta": [:], "finish_reason": "stop"]]]) + "data: [DONE]\n\n"
            let result = await collect(try request(.chatCompletions, body: body))
            guard case .emptyResult = result.error as? AssistantTransportError else { throw TaskWireTestFailure(description: "Enabling tools must not allow ordinary empty answers") }
            try expect(calls(result.events).isEmpty, "Empty text is not a task")
        }
        try await run("enabled-normal-text-only-replies-remain-compatible") {
            let chatText = frame(["choices": [["delta": ["content": "Hello"], "finish_reason": "stop"]]]) + "data: [DONE]\n\n"
            let responsesText = frame(["type": "response.output_text.delta", "delta": "Hello"])
                + frame(["type": "response.completed", "response": ["status": "completed", "output": [["type": "message", "id": "m1", "role": "assistant", "content": [["type": "output_text", "text": "Hello", "annotations": []]], "status": "completed"]]]])
            let anthropicText = frame(["type": "message_start", "message": ["role": "assistant"]])
                + frame(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])
                + frame(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "Hello"]])
                + frame(["type": "content_block_stop", "index": 0])
                + frame(["type": "message_delta", "delta": ["stop_reason": "end_turn"]]) + frame(["type": "message_stop"])
            for (kind, body) in [(AssistantWireProtocol.chatCompletions, chatText), (.responses, responsesText), (.anthropic, anthropicText)] {
                let result = await collect(try request(kind, body: body))
                try expect(result.error == nil && result.events.contains(.text("Hello")) && calls(result.events).isEmpty && result.events.last == .completed, "Tool permission must preserve ordinary streamed text")
            }
        }
        print("All \(suites) task-tool protocol suites passed using isolated native HTTP callbacks; no model or external network calls.")
    }
}
