import Foundation

private struct ProtocolTestFailure: Error, CustomStringConvertible {
    let description: String
}

private enum FixtureAuthorizationError: Error { case revoked }

private actor FixtureStartupGate {
    private(set) var entered = false
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let values = waiters; waiters.removeAll()
        values.forEach { $0.resume() }
    }
}

@MainActor private final class FixtureAuthorizationState {
    var allowed = true
    var checks = 0
    func validate() throws {
        checks += 1
        guard allowed else { throw FixtureAuthorizationError.revoked }
    }
}

@main
private enum AssistantProtocolTests {
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try value() == false { throw ProtocolTestFailure(description: message) }
    }
    private static func decode(_ json: String, event: String? = nil) throws -> [AssistantTransportEvent] {
        try AssistantEventDecoder.decode(AssistantSSEFrame(event: event, id: nil, data: json))
    }
    private static func failure(_ operation: () throws -> Void) throws -> Error {
        do { try operation() } catch { return error }
        throw ProtocolTestFailure(description: "Expected operation to fail")
    }
    private static func expectRemote(_ json: String, code expected: String) throws {
        let error = try failure { _ = try decode(json) }
        guard case .remote(let code) = error as? AssistantTransportError, code == expected else {
            throw ProtocolTestFailure(description: "Expected safe remote error \(expected), received \(error)")
        }
    }
    private static func run(_ name: String, _ body: () throws -> Void) throws {
        try body(); print("PASS \(name)")
    }
    static func main() async throws {
        try run("sse-crlf-multiline-comments-id") {
            var parser = AssistantSSEParser()
            try expect(try tryNil(parser: &parser, line: ": keepalive\r"), "Comment must not produce a frame")
            _ = try parser.consume(line: "event: delta\r")
            _ = try parser.consume(line: "id: message-7\r")
            _ = try parser.consume(line: "id: invalid\0id\r")
            _ = try parser.consume(line: "data: {\r")
            _ = try parser.consume(line: "data: \"content\": \"你好\"\r")
            _ = try parser.consume(line: "data: }\r")
            let frame = try parser.consume(line: "\r")
            try expect(frame == AssistantSSEFrame(event: "delta", id: "message-7", data: "{\n\"content\": \"你好\"\n}"), "Blank CRLF line must flush all data lines and preserve event/id")
            try expect(try AssistantEventDecoder.decode(frame!) == [.text("你好")], "SSE event name must select the CaoBao decoder")
            try expect(parser.flush() == nil, "A flushed frame must not repeat")
            _ = try parser.consume(line: "data:second")
            let next = parser.flush()
            try expect(next?.data == "second" && next?.event == nil && next?.id == nil, "Final unterminated frame flush must clear previous fields")
            try expect(try tryNil(parser: &parser, line: "retry: 1000"), "Retry metadata alone must not emit content")
            try expect(parser.flush() == nil, "Metadata-only frame must not become model text")
            _ = try parser.consume(line: "data:")
            try expect(parser.flush()?.data == "", "Empty data value remains a valid SSE record")
        }
        try run("sse-bounded-bytes-and-reset") {
            var parser = AssistantSSEParser()
            let payload = String(repeating: "a", count: parser.maximumEventBytes - 6)
            _ = try parser.consume(line: "data: " + payload)
            let error = try failure { _ = try parser.consume(line: "data: x") }
            guard case .eventTooLarge = error as? AssistantTransportError else { throw ProtocolTestFailure(description: "Cumulative event size must be bounded") }
            _ = parser.flush()
            _ = try parser.consume(line: "data: ok")
            try expect(parser.flush()?.data == "ok", "Flush must reset event byte budget")
            var unicode = AssistantSSEParser()
            let tooLarge = "data: " + String(repeating: "🤖", count: unicode.maximumEventBytes / 4)
            let unicodeError = try failure { _ = try unicode.consume(line: tooLarge) }
            guard case .eventTooLarge = unicodeError as? AssistantTransportError else { throw ProtocolTestFailure(description: "Budget must count UTF-8 bytes rather than character count") }
        }
        try run("chat-completions-delta-finish-usage") {
            try expect(try decode(#"{"choices":[{"delta":{"role":"assistant"}}]}"#).isEmpty, "Role-only delta must not masquerade as text")
            try expect(try decode(#"{"choices":[{"delta":{"content":"hello"}}]}"#) == [.text("hello")], "Chat content must decode")
            let ending = try decode(#"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":8}}"#)
            try expect(ending == [.completed, .usage(AssistantUsage(inputTokens: 12, outputTokens: 8))], "Completion and usage must both survive")
            try expect(try decode(#"{"choices":[],"usage":{"prompt_tokens":9,"completion_tokens":2}}"#) == [.usage(AssistantUsage(inputTokens: 9, outputTokens: 2))], "Final empty-choices usage frame must survive")
            try expect(try decode("[DONE]") == [.completed], "DONE must be a terminal signal")
            try expect(try decode(#"{"choices":[{"delta":{"tool_calls":[{"id":"call_1"}]}}]}"#) == [.toolCall], "Tool deltas must be explicit")
            try expect(try decode(#"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#) == [.toolCall], "Tool finish is not a completed text result")
            try expectRemote(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#, code: "length")
            try expectRemote(#"{"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#, code: "content_filter")
        }
        try run("responses-events-and-incomplete") {
            try expect(try decode(#"{"type":"response.output_text.delta","delta":"你好"}"#) == [.text("你好")], "Responses delta must decode")
            try expect(try decode(#"{"type":"response.completed","response":{"usage":{"input_tokens":20,"output_tokens":5}}}"#) == [.usage(AssistantUsage(inputTokens: 20, outputTokens: 5)), .completed], "Responses usage and completion must decode")
            try expect(try decode(#"{"type":"response.function_call_arguments.delta","delta":"{}"}"#) == [.toolCall], "Responses tool payload must remain a tool event")
            try expectRemote(#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#, code: "response.incomplete")
            try expectRemote(#"{"type":"response.failed","response":{"error":{"code":"quota_exceeded","message":"private upstream detail"}}}"#, code: "quota_exceeded")
        }
        try run("anthropic-text-tools-and-usage") {
            try expect(try decode(#"{"type":"message_start","message":{"usage":{"input_tokens":11,"output_tokens":0}}}"#) == [.usage(AssistantUsage(inputTokens: 11, outputTokens: 0))], "Anthropic initial usage must survive")
            try expect(try decode(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"世界"}}"#) == [.text("世界")], "Anthropic text delta must decode")
            try expect(try decode(#"{"type":"content_block_start","content_block":{"type":"tool_use","id":"tool_1"}}"#) == [.toolCall], "Anthropic tool start must be explicit")
            try expect(try decode(#"{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{}"}}"#) == [.toolCall], "Tool JSON must not render as text")
            try expect(try decode(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":14}}"#) == [.usage(AssistantUsage(inputTokens: nil, outputTokens: 14))], "Anthropic final usage must survive")
            try expect(try decode(#"{"type":"message_stop"}"#) == [.completed], "message_stop must be terminal")
            try expectRemote(#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#, code: "max_tokens")
        }
        try run("errors-malformed-and-caobao-content") {
            try expectRemote(#"{"type":"error","error":{"type":"rate_limit_error","message":"Do not leak the secret"}}"#, code: "rate_limit_error")
            try expectRemote(#"{"error":{"code":"AUTH!@#ERROR","message":"Sensitive upstream text"}}"#, code: "AUTHERROR")
            try expect(try decode(#"{"type":"cancelled"}"#) == [.cancelled], "A server cancellation must remain a terminal cancellation event")
            let malformed = try failure { _ = try decode("[]") }
            guard case .malformedEvent = malformed as? AssistantTransportError else { throw ProtocolTestFailure(description: "Array roots must not decode as empty successes") }
            _ = try failure { _ = try decode("not JSON") }
            try expect(try decode(#"{"type":"ping","content":"must not render"}"#).isEmpty, "Unknown lifecycle events cannot masquerade as text")
            try expect(try decode(#"{"type":"delta","content":[{"type":"text","text":"A"},{"type":"image","url":"https://example.com/a.png"},{"type":"text","text":"B"}]}"#) == [.text("A"), .text("B")], "CaoBao structured content must retain all text blocks")
            try expect(try decode(#"{"type":"metadata","generationId":"gen-123"}"#) == [.generation("gen-123")], "Generation metadata must survive")
            try expect(try decode(#"{"type":"usage","usage":{"input_tokens":7,"output_tokens":9}}"#) == [.usage(AssistantUsage(inputTokens: 7, outputTokens: 9))], "CaoBao usage must decode")
        try expect(try decode(#"{"type":"usage","usage":{"promptTokens":17,"completionTokens":5,"totalTokens":22}}"#) == [.usage(AssistantUsage(inputTokens: 17, outputTokens: 5))], "Unified platform usage must decode camelCase fields")
            try expect(try decode(#"{"type":"completed"}"#) == [.completed], "CaoBao completed must be terminal")
        }
        try run("byok-url-validation-and-paths") {
            let rejected = [
                "http://api.example.com", "ftp://api.example.com", "https://localhost", "https://foo.local", "https://foo.internal", "https://foo.test",
                "https://127.0.0.1", "https://10.0.1.2", "https://172.16.1.2", "https://192.168.1.2", "https://169.254.169.254", "https://100.64.0.1", "https://224.0.0.1", "https://8.8.8.8", "https://[::1]", "https://[2001:4860:4860::8888]",
                "https://user:password@api.example.com", "https://api.example.com?q=key", "https://api.example.com#fragment", "https://2130706433"
            ]
            for value in rejected {
                _ = try failure { _ = try BYOKConfiguration(baseURL: value, protocolKind: .chatCompletions, model: "model", apiKey: "fixture-key").endpoint() }
            }
            for (kind, path) in [(AssistantWireProtocol.chatCompletions, "/v1/chat/completions"), (.responses, "/v1/responses"), (.anthropic, "/v1/messages")] {
                let origin = BYOKConfiguration(baseURL: " https://api.example.com/ ", protocolKind: kind, model: "model", apiKey: "fixture-key")
                try expect(try origin.endpoint().path == path, "Origin URL must get the correct v1 path")
                let v1 = BYOKConfiguration(baseURL: "https://api.example.com/v1/", protocolKind: kind, model: "model", apiKey: "fixture-key")
                try expect(try v1.endpoint().path == path, "v1 URL must not double v1")
                let full = BYOKConfiguration(baseURL: "https://api.example.com" + path, protocolKind: kind, model: "model", apiKey: "fixture-key")
                try expect(try full.endpoint().path == path, "A full endpoint must not get duplicate suffixes")
            }
            _ = try failure { _ = try BYOKConfiguration(baseURL: "https://api.example.com", protocolKind: .responses, model: " ", apiKey: "fixture-key").endpoint() }
            _ = try failure { _ = try BYOKConfiguration(baseURL: "https://api.example.com", protocolKind: .responses, model: "model", apiKey: " ").endpoint() }
        }
        try run("byok-protocol-headers-and-body") {
            let turns = [AssistantTurn(id: "user-1", role: "user", text: "hello"), AssistantTurn(id: "assistant-1", role: "assistant", text: "hi")]
            for kind in AssistantWireProtocol.allCases {
                let config = BYOKConfiguration(baseURL: "https://api.example.com/v1", protocolKind: kind, model: "fixture-model", apiKey: "fixture-key")
                let request = try config.request(turns: turns, instructions: "Be helpful", requestId: "req-fixture")
                try expect(request.httpMethod == "POST", "BYOK must POST")
                try expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "Request body must be JSON")
                try expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream", "Request must request SSE")
                try expect(request.value(forHTTPHeaderField: "X-Request-ID") == "req-fixture", "Request trace ID must survive")
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                try expect(body["model"] as? String == "fixture-model" && body["stream"] as? Bool == true, "Model and streaming flag must survive")
                switch kind {
                case .chatCompletions:
                    try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key", "Chat must use bearer authentication")
                    let messages = body["messages"] as! [[String: String]]
                    try expect(messages.count == 3 && messages[0] == ["role": "system", "content": "Be helpful"], "Chat must prefix the system prompt and preserve full history")
                    try expect(messages.last?["content"] == "hi" && body["max_tokens"] as? Int == 2048, "Chat history and token budget must be present")
                case .responses:
                    try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key", "Responses must use bearer authentication")
                    try expect(body["store"] as? Bool == false, "Responses must explicitly disable provider storage")
                    try expect(body["instructions"] as? String == "Be helpful" && (body["input"] as? [[String: String]])?.count == 2, "Responses must use instructions/input")
                    try expect(body["max_output_tokens"] as? Int == 2048, "Responses must use max_output_tokens")
                case .anthropic:
                    try expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-key", "Anthropic must use x-api-key")
                    try expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Anthropic protocol version must be explicit")
                    try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "Anthropic key must not leak to bearer header")
                    try expect(body["system"] as? String == "Be helpful" && (body["messages"] as? [[String: String]])?.count == 2, "Anthropic system prompt must stay separate from messages")
                    try expect(body["max_tokens"] as? Int == 2048, "Anthropic requires max_tokens")
                }
            }
        }
        try await transportTests()
        try await transportStartBoundaryTests()
        try await transportArchiveWaitTests()
        try run("byok-consent-full-endpoint-and-key") {
            func key(_ url: String, _ secret: String = "fixture-key") throws -> String {
                try BYOKConfiguration(baseURL: url, protocolKind: .chatCompletions, model: "fixture-model", apiKey: secret).consentIdentifier()
            }
            let first = try key("https://api.example.com/tenant-a/v1")
            try expect(first == (try key("https://api.example.com/tenant-a/v1/")), "Equivalent base paths share one consent scope")
            try expect(first != (try key("https://api.example.com/tenant-b/v1")), "Different paths require consent")
            try expect(first != (try key("https://api.example.com:8443/tenant-a/v1")), "Different ports require consent")
            try expect(first != (try key("https://api.example.com/tenant-a/v1", "different-fixture-key")), "Different credentials require consent")
            try expect(!first.contains("fixture-key") && first.count == 64, "Consent scope is a digest, not a stored secret")
        }
        print("All 9 protocol suites and 24 transport suites passed; no network or model calls made.")
    }
    private static func tryNil(parser: inout AssistantSSEParser, line: String) throws -> Bool {
        try parser.consume(line: line) == nil
    }

    private static func transport(startupBarrier: (@Sendable () async -> Void)? = nil) -> AssistantStreamTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return AssistantStreamTransport(configuration: configuration, startupBarrier: startupBarrier)
    }

    private static func collect(_ path: String, using customTransport: AssistantStreamTransport? = nil,
                                beforeStart: (@MainActor @Sendable () throws -> Void)? = nil,
                                beforeStartWait: (@MainActor @Sendable () async throws -> Void)? = nil,
                                onEvent: (@Sendable (AssistantTransportEvent) -> Void)? = nil) async -> (events: [AssistantTransportEvent], error: Error?) {
        var request = URLRequest(url: URL(string: "https://fixtures.invalid/" + path)!)
        request.timeoutInterval = 3
        var values: [AssistantTransportEvent] = []
        do {
            for try await value in (customTransport ?? transport()).events(for: request, beforeStart: beforeStart, beforeStartWait: beforeStartWait) {
                values.append(value)
                onEvent?(value)
            }
            return (values, nil)
        } catch { return (values, error) }
    }

    private static func waitForStartup(_ gate: FixtureStartupGate) async throws {
        for _ in 0..<200 {
            if await gate.entered { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw ProtocolTestFailure(description: "Startup barrier was never entered")
    }

    private static func transportStartBoundaryTests() async throws {
        do {
            let gate = FixtureStartupGate(), state = await MainActor.run { FixtureAuthorizationState() }
            let instance = transport(startupBarrier: { await gate.wait() })
            let consumer = Task { await collect("queued-revoke", using: instance, beforeStart: { try state.validate() }) }
            try await waitForStartup(gate)
            try expect(FixtureURLProtocol.startCount("queued-revoke") == 0, "No model request may start while startup is queued")
            await MainActor.run { state.allowed = false }
            await gate.open()
            let result = await consumer.value
            let checks = await MainActor.run { state.checks }
            try expect(result.error is FixtureAuthorizationError && result.events.isEmpty, "The hook's original rejection must propagate without any output")
            try expect(FixtureURLProtocol.startCount("queued-revoke") == 0 && checks == 1, "The delayed hook must run once after release and reject before URLProtocol starts")
            print("PASS transport-queued-revocation-hook-rejects-before-request")
        }
        do {
            let state = await MainActor.run { FixtureAuthorizationState() }
            let result = await collect("complete", beforeStart: {
                try MainActor.assumeIsolated { try state.validate() }
            })
            let checks = await MainActor.run { state.checks }
            try expect(result.error == nil && result.events.contains(.text("你好🤖")) && checks == 1, "An authorized MainActor hook must run once and permit the native request to complete")
            print("PASS transport-before-start-runs-on-mainactor-and-resumes")
        }
        do {
            let state = await MainActor.run { FixtureAuthorizationState() }
            let consumer = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await collect("pre-cancelled", beforeStart: { try state.validate() })
            }
            let result = await consumer.value
            let checks = await MainActor.run { state.checks }
            try expect(result.events.isEmpty && FixtureURLProtocol.startCount("pre-cancelled") == 0 && checks == 0, "A pre-cancelled producer cannot invoke a hook or start a request")
            print("PASS transport-pre-cancelled-start-has-zero-requests")
        }
        do {
            let gate = FixtureStartupGate(), state = await MainActor.run { FixtureAuthorizationState() }
            let instance = transport(startupBarrier: { await gate.wait() })
            let consumer = Task { await collect("cancelled-queued", using: instance, beforeStart: { try state.validate() }) }
            try await waitForStartup(gate)
            consumer.cancel()
            let result = await consumer.value
            await gate.open()
            try await Task.sleep(nanoseconds: 30_000_000)
            let checks = await MainActor.run { state.checks }
            try expect(result.events.isEmpty && FixtureURLProtocol.startCount("cancelled-queued") == 0 && checks == 0, "Cancelled queued startup cannot invoke a stale hook or start after release")
            print("PASS transport-cancelled-queued-start-has-zero-requests")
        }
        for path in ["redirect-host", "redirect-path", "redirect-scheme"] {
            let result = await collect(path)
            guard case .http(302) = result.error as? AssistantTransportError else { throw ProtocolTestFailure(description: "Every redirect must be rejected as its HTTP status") }
            try expect(result.events.isEmpty && FixtureURLProtocol.startCount("redirected-destination") == 0, "Neither credentials nor context can be forwarded to a redirected destination")
        }
        print("PASS transport-all-host-path-and-scheme-redirects-rejected")
        let invalid = await collect("invalid-utf8")
        guard case .malformedEvent = invalid.error as? AssistantTransportError else { throw ProtocolTestFailure(description: "Invalid UTF8 cannot be replaced silently") }
        try expect(invalid.events.isEmpty, "Invalid bytes must not become model output")
        print("PASS transport-invalid-utf8-rejected")
        let final = await collect("final-flush")
        try expect(final.error == nil && final.events == [.text("tail"), .completed], "A final unterminated SSE line and event must both flush")
        print("PASS transport-final-line-and-event-flush")
        let failed = await collect("network-error", onEvent: { event in
            if event == .text("partial") { FixtureURLProtocol.failNetworkAfterObservedDelta() }
        })
        let nativeFailures = FixtureURLProtocol.acknowledgedNetworkFailures
        let preservesPartial = (failed.error as? URLError)?.code == .networkConnectionLost
            && failed.events == [.text("partial")] && nativeFailures == 1
        if !preservesPartial {
            let error = failed.error as NSError?
            let evidence = "NETWORK_ERROR_FAILURE events=\(failed.events) domain=\(error?.domain ?? "nil") code=\(error?.code ?? 0) acknowledgedFailures=\(nativeFailures)\n"
            FileHandle.standardError.write(Data(evidence.utf8))
        }
        try expect(preservesPartial, "Native network errors must preserve prior deltas without fabricating completion")
        print("PASS transport-native-error-preserves-partial-output")
        let remote = await collect("remote-error")
        guard case .remote("quota_exceeded") = remote.error as? AssistantTransportError else { throw ProtocolTestFailure(description: "Only the safe upstream code can escape") }
        try expect(!(remote.error?.localizedDescription ?? "").contains("private upstream detail") && remote.events.isEmpty, "Upstream bodies cannot leak through transport errors")
        print("PASS transport-upstream-error-body-remains-private")
        let eventLimit = await collect("event-oversize")
        guard case .eventTooLarge = eventLimit.error as? AssistantTransportError else { throw ProtocolTestFailure(description: "Multi-line event budget must remain bounded") }
        print("PASS transport-cumulative-event-byte-limit")
        let responseLimit = await collect("response-oversize")
        guard case .eventTooLarge = responseLimit.error as? AssistantTransportError else { throw ProtocolTestFailure(description: "Ignored comments across chunks still count against the response budget") }
        print("PASS transport-cumulative-eight-mebibyte-response-limit")
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixtureURLProtocol.self]
            configuration.timeoutIntervalForRequest = 7
            configuration.httpShouldSetCookies = true
            let cookie = HTTPCookie(properties: [.domain: "fixtures.invalid", .path: "/", .name: "fixture-cookie", .value: "must-not-send", .secure: "TRUE"])!
            configuration.httpCookieStorage?.setCookie(cookie)
            let result = await collect("privacy", using: AssistantStreamTransport(configuration: configuration))
            try expect(result.error == nil && FixtureURLProtocol.capturedRequest("privacy")?.value(forHTTPHeaderField: "Cookie") == nil, "Per-request sessions cannot send seeded fixture cookies")
            try expect(configuration.timeoutIntervalForRequest == 7 && configuration.httpShouldSetCookies, "The injected configuration must be copied rather than mutated")
            print("PASS transport-cookie-isolation-and-configuration-copy")
        }
    }

    private static func transportTests() async throws {
        let complete = await collect("complete")
        try expect(complete.error == nil, "A complete mocked SSE response must succeed")
        try expect(complete.events.contains(.text("你好🤖")) && complete.events.contains(.completed), "Unicode chunks and completion must survive actual transport")
        try expect(complete.events.contains(.usage(AssistantUsage(inputTokens: 4, outputTokens: 3))), "Usage after finish_reason must not be dropped")
        print("PASS transport-complete-and-final-usage")

        let interrupted = await collect("interrupted")
        guard case .interrupted = interrupted.error as? AssistantTransportError else {
            throw ProtocolTestFailure(description: "EOF without terminal event must fail as interrupted")
        }
        try expect(interrupted.events == [.text("partial")], "Partial output must remain available on interrupted stream")
        print("PASS transport-premature-eof")

        let empty = await collect("empty")
        guard case .emptyResult = empty.error as? AssistantTransportError else {
            throw ProtocolTestFailure(description: "DONE alone must not count as an effective reply")
        }
        print("PASS transport-empty-reply")

        let denied = await collect("http-error")
        guard case .http(403) = denied.error as? AssistantTransportError else {
            throw ProtocolTestFailure(description: "HTTP errors must survive transport")
        }
        try expect(denied.events.isEmpty, "HTTP error bodies must not render as generated text")
        print("PASS transport-http-error")

        let wrongType = await collect("wrong-content-type")
        guard case .malformedEvent = wrongType.error as? AssistantTransportError else {
            throw ProtocolTestFailure(description: "Non-SSE content type must be rejected")
        }
        print("PASS transport-content-type")

        let tool = await collect("tool")
        guard case .toolExecutionUnavailable = tool.error as? AssistantTransportError else {
            throw ProtocolTestFailure(description: "Unsupported tools must not be reported as successful answers")
        }
        try expect(!tool.events.contains(.completed), "Tool rejection must not produce completed")
        print("PASS transport-tool-refusal")

        let oversize = await collect("oversize")
        guard case .eventTooLarge = oversize.error as? AssistantTransportError else {
            throw ProtocolTestFailure(description: "Transport line buffer must have a byte bound")
        }
        print("PASS transport-bounded-line-buffer")

        let consumer = Task { await collect("hold") }
        for _ in 0..<100 {
            if FixtureURLProtocol.hasStartedHold { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(FixtureURLProtocol.hasStartedHold, "Cancellation fixture must actually start")
        consumer.cancel()
        let cancelled = await consumer.value
        for _ in 0..<100 {
            if FixtureURLProtocol.hasStoppedHold { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(FixtureURLProtocol.hasStoppedHold, "Consumer cancellation must cancel URLSession via onTermination")
        try expect(!cancelled.events.contains(.completed), "Cancelled stream must not be marked completed")
        print("PASS transport-cancellation-stops-request")
    }

    private static func transportArchiveWaitTests() async throws {
        do {
            let gate = FixtureStartupGate(), state = await MainActor.run { FixtureAuthorizationState() }
            let consumer = Task {
                await collect("archive-wait-success", beforeStart: { try state.validate() }, beforeStartWait: {
                    await gate.wait()
                    try Task.checkCancellation()
                })
            }
            try await waitForStartup(gate)
            let waitingChecks = await MainActor.run { state.checks }
            try expect(FixtureURLProtocol.startCount("archive-wait-success") == 0 && waitingChecks == 0,
                "Archive waiting must precede both the final authorization hook and any HTTP start")
            await gate.open()
            let result = await consumer.value
            let checks = await MainActor.run { state.checks }
            try expect(result.error == nil && result.events == [.text("ok"), .completed] && checks == 1
                && FixtureURLProtocol.startCount("archive-wait-success") == 1,
                "Releasing an archive wait starts one authorized request without changing its response")
            print("PASS transport-archive-wait-delays-authorization-and-http")
        }
        do {
            let state = await MainActor.run { FixtureAuthorizationState() }
            let result = await collect("archive-wait-rejected", beforeStart: { try state.validate() }, beforeStartWait: {
                throw FixtureAuthorizationError.revoked
            })
            let checks = await MainActor.run { state.checks }
            try expect(result.error is FixtureAuthorizationError && result.events.isEmpty && checks == 0
                && FixtureURLProtocol.startCount("archive-wait-rejected") == 0,
                "An archive wait failure must preserve its error without authorizing or starting HTTP")
            print("PASS transport-archive-wait-failure-starts-zero-http")
        }
        do {
            let gate = FixtureStartupGate(), resumed = FixtureStartupGate()
            let state = await MainActor.run { FixtureAuthorizationState() }
            let consumer = Task {
                await collect("archive-wait-cancelled", beforeStart: { try state.validate() }, beforeStartWait: {
                    await gate.wait()
                    await resumed.open()
                    try Task.checkCancellation()
                })
            }
            try await waitForStartup(gate)
            consumer.cancel()
            let result = await consumer.value
            await gate.open()
            await resumed.wait()
            let checks = await MainActor.run { state.checks }
            try expect(result.events.isEmpty && checks == 0 && FixtureURLProtocol.startCount("archive-wait-cancelled") == 0,
                "Cancelling while an archive wait is held prevents any later authorization or HTTP")
            print("PASS transport-cancelled-archive-wait-never-starts-after-release")
        }
        do {
            let gate = FixtureStartupGate(), state = await MainActor.run { FixtureAuthorizationState() }
            let consumer = Task {
                await collect("archive-wait-final-revoked", beforeStart: { try state.validate() }, beforeStartWait: {
                    await gate.wait()
                    state.allowed = false
                })
            }
            try await waitForStartup(gate)
            await gate.open()
            let result = await consumer.value
            let checks = await MainActor.run { state.checks }
            try expect(result.error is FixtureAuthorizationError && result.events.isEmpty && checks == 1
                && FixtureURLProtocol.startCount("archive-wait-final-revoked") == 0,
                "The synchronous final hook must recheck the state after the asynchronous archive wait")
            print("PASS transport-final-authorization-follows-archive-wait")
        }
    }
}

/// All requests in this test process are intercepted by an explicitly injected
/// session configuration. Even unexpected paths get a local 404 fixture.
private final class FixtureURLProtocol: URLProtocol {
    private static let stateLock = NSLock()
    private static var startedHold = false
    private static var stoppedHold = false
    private static var starts: [String: Int] = [:]
    private static var requests: [String: URLRequest] = [:]
    private static var pendingNetworkError: FixtureURLProtocol?
    private static var nativeFailuresAfterAcknowledgement = 0
    private var isStopped = false
    private var sentNetworkFailure = false
    private let instanceLock = NSLock()

    static var hasStartedHold: Bool { stateLock.lock(); defer { stateLock.unlock() }; return startedHold }
    static var hasStoppedHold: Bool { stateLock.lock(); defer { stateLock.unlock() }; return stoppedHold }
    static func startCount(_ path: String) -> Int { stateLock.lock(); defer { stateLock.unlock() }; return starts[path, default: 0] }
    static func capturedRequest(_ path: String) -> URLRequest? { stateLock.lock(); defer { stateLock.unlock() }; return requests[path] }
    static var acknowledgedNetworkFailures: Int { stateLock.lock(); defer { stateLock.unlock() }; return nativeFailuresAfterAcknowledgement }

    /// didLoad only enqueues bytes inside URLSession; a same-turn didFail can discard
    /// those bytes before any data-delegate callback. Fail only after the real stream
    /// consumer acknowledges a decoded delta, never after an arbitrary sleep.
    static func failNetworkAfterObservedDelta() {
        stateLock.lock(); let target = pendingNetworkError; pendingNetworkError = nil; stateLock.unlock()
        guard let target else { return }
        target.instanceLock.lock()
        let shouldFail = !target.isStopped && !target.sentNetworkFailure
        if shouldFail { target.sentNetworkFailure = true }
        target.instanceLock.unlock()
        guard shouldFail else { return }
        stateLock.lock(); nativeFailuresAfterAcknowledgement += 1; stateLock.unlock()
        target.client?.urlProtocol(target, didFailWithError: URLError(.networkConnectionLost))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.lastPathComponent
        Self.stateLock.lock(); Self.starts[path, default: 0] += 1; Self.requests[path] = request; Self.stateLock.unlock()
        if path.hasPrefix("redirect-") {
            let destination: URL
            switch path {
            case "redirect-host": destination = URL(string: "https://other-fixtures.invalid/redirected-destination")!
            case "redirect-scheme": destination = URL(string: "http://fixtures.invalid/redirected-destination")!
            default: destination = URL(string: "https://fixtures.invalid/redirected-destination")!
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
            var redirected = request; redirected.url = destination
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        let status = path == "http-error" ? 403 : 200
        let contentType = path == "wrong-content-type" ? "application/json" : "text/event-stream; charset=utf-8"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "invalid-utf8" {
            client?.urlProtocol(self, didLoad: Data([100, 97, 116, 97, 58, 32, 255, 10]))
            client?.urlProtocolDidFinishLoading(self); return
        }
        if path == "network-error" {
            Self.stateLock.lock(); Self.pendingNetworkError = self; Self.nativeFailuresAfterAcknowledgement = 0; Self.stateLock.unlock()
            let partial = #"data: {"type":"delta","content":"partial"}"# + "\n\n"
            client?.urlProtocol(self, didLoad: Data(partial.utf8))
            // The request stays open until the test observes this actual delta.
            return
        }
        if path == "response-oversize" {
            let chunk = Data(String(repeating: ":" + String(repeating: "x", count: 1022) + "\n", count: 512).utf8)
            for _ in 0..<17 { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self); return
        }
        let body: String
        switch path {
        case "privacy", "archive-wait-success": body = #"data: {"type":"delta","content":"ok"}"# + "\n\ndata: [DONE]\n\n"
        case "final-flush": body = #"data: {"type":"delta","content":"tail"}"# + "\r\n\r\ndata: [DONE]"
        case "remote-error": body = #"data: {"error":{"code":"quota_exceeded","message":"private upstream detail"}}"# + "\n\n"
        case "event-oversize": body = String(repeating: "data: " + String(repeating: "x", count: 1024) + "\n", count: 256)
        case "complete":
            body = "data: {\"choices\":[{\"delta\":{\"content\":\"你好🤖\"}}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":3}}\n\ndata: [DONE]\n\n"
        case "interrupted": body = "data: {\"type\":\"delta\",\"content\":\"partial\"}"
        case "empty": body = "data: [DONE]\n\n"
        case "http-error": body = "private upstream detail must not appear"
        case "wrong-content-type": body = "{}"
        case "tool": body = "data: {\"type\":\"tool_call\"}\n\n"
        case "oversize": body = "data: " + String(repeating: "x", count: 262_145)
        case "hold":
            Self.stateLock.lock(); Self.startedHold = true; Self.stateLock.unlock()
            // Failsafe completion keeps any cancellation regression bounded.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                self.instanceLock.lock(); let stopped = self.isStopped; self.instanceLock.unlock()
                if !stopped { self.client?.urlProtocolDidFinishLoading(self) }
            }
            return
        default: body = "data: [DONE]\n\n"
        }
        let data = Data(body.utf8)
        if path == "complete" {
            // Deliberately split UTF-8 scalars across URLProtocol chunks.
            for offset in stride(from: 0, to: data.count, by: 7) {
                client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + 7, data.count)))
            }
        } else { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        instanceLock.lock(); isStopped = true; instanceLock.unlock()
        Self.stateLock.lock()
        if Self.pendingNetworkError === self { Self.pendingNetworkError = nil }
        if request.url?.lastPathComponent == "hold" {
            Self.stoppedHold = true
        }
        Self.stateLock.unlock()
    }
}
