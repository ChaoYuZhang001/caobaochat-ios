import Foundation
import CryptoKit
import CoreFoundation

/// Wire protocols are explicit; a failed BYOK call never falls back to a platform key.
enum AssistantWireProtocol: String, Codable, CaseIterable, Hashable, Sendable {
    case chatCompletions = "openai-chat"
    case responses = "openai-responses"
    case anthropic = "anthropic"
}

struct AssistantTurn: Codable, Equatable {
    let id: String
    let role: String
    let text: String
    var images: [AssistantImage]? = nil
    var toolExchange: AssistantTaskToolExchange? = nil
}

struct AssistantUsage: Codable, Hashable {
    var inputTokens: Int?
    var outputTokens: Int?
}

enum AssistantTransportError: LocalizedError {
    case configuration(String)
    case http(Int)
    case remote(String)
    case malformedEvent
    case interrupted
    case emptyResult
    case eventTooLarge
    case toolExecutionUnavailable

    var errorDescription: String? {
        switch self {
        case .configuration(let message): return message
        case .http(let code): return String(format: AssistantLocalization.string("服务请求失败（HTTP %d）"), code)
        case .remote(let code):
            switch code.uppercased() {
            case "PLATFORM_FUNDING_UNAVAILABLE":
                return AssistantLocalization.string("平台额度暂时不可用，请稍后重试")
            case "UPSTREAM_UNAVAILABLE":
                return AssistantLocalization.string("上游模型暂时不可用，请稍后重试")
            case "QUOTA_EXCEEDED":
                return AssistantLocalization.string("今日额度已用完，请稍后再试或升级订阅")
            default:
                return String(format: AssistantLocalization.string("服务返回错误：%@"), code)
            }
        case .malformedEvent: return AssistantLocalization.string("无法识别服务的响应格式")
        case .interrupted: return AssistantLocalization.string("连接提前结束，已保存收到的内容。请检查网络后重试。")
        case .emptyResult: return AssistantLocalization.string("模型未返回有效正文")
        case .eventTooLarge: return AssistantLocalization.string("服务返回的数据超过安全限制")
        case .toolExecutionUnavailable: return AssistantLocalization.string("该请求需要尚未启用的工具执行能力")
        }
    }
}

struct BYOKConfiguration {
    let baseURL: String
    let protocolKind: AssistantWireProtocol
    let model: String
    let apiKey: String

    func endpoint() throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let rawHost = components.host, !rawHost.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw AssistantTransportError.configuration(AssistantLocalization.string("请输入不含账号、查询参数的 HTTPS Base URL"))
        }
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        let parts = host.split(separator: ".").compactMap { Int($0) }
        let privateIPv4 = parts.count == 4 && (parts[0] == 10 || parts[0] == 127 || parts[0] == 0 ||
            parts[0] >= 224 || (parts[0] == 169 && parts[1] == 254) ||
            (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168) ||
            (parts[0] == 100 && (64...127).contains(parts[1])))
        guard !privateIPv4, !host.contains(":"), host.contains("."),
              host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"), !host.hasSuffix(".test"),
              !host.allSatisfy({ $0.isNumber || $0 == "." }) else {
            throw AssistantTransportError.configuration(AssistantLocalization.string("自定义 API 必须使用公开的 HTTPS 域名"))
        }
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantTransportError.configuration(AssistantLocalization.string("请填写模型名称和 API Key"))
        }
        let suffix: String
        switch protocolKind {
        case .chatCompletions: suffix = "/chat/completions"
        case .responses: suffix = "/responses"
        case .anthropic: suffix = "/messages"
        }
        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty { path = "v1" }
        let fullSuffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.hasSuffix(fullSuffix) { path += suffix }
        components.path = "/" + path
        guard let url = components.url else { throw AssistantTransportError.malformedEvent }
        return url
    }

    func consentIdentifier() throws -> String {
        let endpoint = try self.endpoint().absoluteString
        let keyDigest = SHA256.hash(data: Data(apiKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let scope = "\(protocolKind.rawValue)|\(endpoint)|\(model)|\(keyDigest)"
        return SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func request(turns: [AssistantTurn], instructions: String, requestId: String, toolMode: AssistantTaskToolMode = .disabled) throws -> URLRequest {
        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(requestId, forHTTPHeaderField: "X-Request-ID")
        let fingerprint = try consentIdentifier()
        var hasExchange = false
        let history: [[String: Any]] = try turns.flatMap { turn -> [[String: Any]] in
            if let exchange = turn.toolExchange, turn.role == "assistant",
               exchange.configurationFingerprint == fingerprint,
               exchange.call.trace.protocolKind == protocolKind {
                try exchange.call.validate(for: .taskProposal)
                try exchange.call.trace.validateStructure(callId: exchange.call.id, name: exchange.call.name, arguments: exchange.call.arguments)
                guard exchange.resultJSON.utf8.count <= AssistantTaskToolCall.maximumArgumentBytes,
                      let resultData = exchange.resultJSON.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: resultData)) is [String: Any] else { throw AssistantTaskToolError.invalidTrace }
                hasExchange = true
                let items = try exchange.call.trace.jsonItems()
                switch protocolKind {
                case .chatCompletions:
                    return items + [["role": "tool", "tool_call_id": exchange.call.id, "content": exchange.resultJSON]]
                case .responses:
                    return items + [["type": "function_call_output", "call_id": exchange.call.id, "output": exchange.resultJSON]]
                case .anthropic:
                    return items + [["role": "user", "content": [["type": "tool_result", "tool_use_id": exchange.call.id, "content": exchange.resultJSON]]]]
                }
            }
            guard (turn.images?.count ?? 0) <= AssistantImagePreprocessor.maximumImagesPerMessage else {
                throw AssistantMediaError.tooManyImages
            }
            guard let images = turn.images, !images.isEmpty else { return [["role": turn.role, "content": turn.text]] }
            for image in images { try image.validate() }
            guard turn.role == "user" else { throw AssistantMediaError.invalidImage }
            var blocks: [[String: Any]]
            switch protocolKind {
            case .chatCompletions:
                blocks = [["type": "text", "text": turn.text]]
                blocks += images.map { ["type": "image_url", "image_url": ["url": $0.dataURL, "detail": "auto"]] }
            case .responses:
                blocks = [["type": "input_text", "text": turn.text]]
                blocks += images.map { ["type": "input_image", "image_url": $0.dataURL, "detail": "auto"] }
            case .anthropic:
                blocks = [["type": "text", "text": turn.text]]
                blocks += images.map { ["type": "image", "source": ["type": "base64", "media_type": $0.mimeType, "data": $0.base64Data]] }
            }
            return [["role": turn.role, "content": blocks]]
        }
        var body: [String: Any]
        switch protocolKind {
        case .chatCompletions:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = ["model": model, "messages": [["role": "system", "content": instructions]] + history,
                    "stream": true, "max_tokens": 2048]
        case .responses:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = ["model": model, "instructions": instructions, "input": history,
                    "stream": true, "store": false, "max_output_tokens": 2048]
            if toolMode != .disabled { body["include"] = ["reasoning.encrypted_content"] }
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": model, "system": instructions, "messages": history,
                    "stream": true, "max_tokens": 2048]
        }
        let declarationMode: AssistantTaskToolMode = toolMode == .disabled && hasExchange ? .taskProposal : toolMode
        if let name = declarationMode.functionName {
            let parameters: [String: Any]
            if declarationMode == .capabilityProbe {
                parameters = ["type": "object", "properties": ["ok": ["type": "boolean", "enum": [true]]], "required": ["ok"], "additionalProperties": false]
            } else {
                parameters = ["type": "object", "properties": [
                    "title": ["type": "string"], "notes": ["type": "string"],
                    "due_at": ["type": ["string", "null"]], "time_zone": ["type": ["string", "null"]],
                    "reminder_requested": ["type": "boolean"]],
                    "required": ["title", "notes", "due_at", "time_zone", "reminder_requested"], "additionalProperties": false]
            }
            let description = declarationMode == .capabilityProbe ? "Return ok=true to verify tool protocol support. Never creates a task." : "Propose one local task for the user to review. No task is saved until explicit user confirmation."
            switch protocolKind {
            case .chatCompletions:
                body["tools"] = [["type": "function", "function": ["name": name, "description": description, "parameters": parameters, "strict": true]]]
                body["parallel_tool_calls"] = false
                body["tool_choice"] = toolMode == .disabled ? "none" : (toolMode == .capabilityProbe ? ["type": "function", "function": ["name": name]] : "auto")
            case .responses:
                body["tools"] = [["type": "function", "name": name, "description": description, "parameters": parameters, "strict": true]]
                body["parallel_tool_calls"] = false
                body["tool_choice"] = toolMode == .disabled ? "none" : (toolMode == .capabilityProbe ? ["type": "function", "name": name] : "auto")
            case .anthropic:
                body["tools"] = [["name": name, "description": description, "input_schema": parameters]]
                body["tool_choice"] = toolMode == .disabled ? ["type": "none"] : (toolMode == .capabilityProbe ? ["type": "tool", "name": name, "disable_parallel_tool_use": true] : ["type": "auto", "disable_parallel_tool_use": true])
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard (request.httpBody?.count ?? 0) <= 6 * 1024 * 1024 else { throw AssistantMediaError.outputTooLarge }
        return request
    }
}

struct AssistantSSEFrame: Equatable {
    let event: String?
    let id: String?
    let data: String
}

extension AssistantTaskToolTrace {
    /// A persisted provider envelope is untrusted until its active roles, single
    /// function and exact arguments have been checked again at the send boundary.
    func validateStructure(callId: String, name: String, arguments: String) throws {
        let items = try jsonItems()
        func require(_ condition: Bool) throws { if !condition { throw AssistantTaskToolError.invalidTrace } }
        func keys(_ item: [String: Any], _ allowed: Set<String>) -> Bool { Set(item.keys).isSubset(of: allowed) }
        var calls = 0
        switch protocolKind {
        case .chatCompletions:
            try require(items.count == 1)
            let item = items[0]
            try require(keys(item, ["role", "content", "tool_calls"]) && item["role"] as? String == "assistant")
            try require(item["content"] == nil || item["content"] is NSNull || item["content"] is String)
            guard let tools = item["tool_calls"] as? [[String: Any]], tools.count == 1,
                  let call = tools.first, let function = call["function"] as? [String: Any] else { throw AssistantTaskToolError.invalidTrace }
            try require(keys(call, ["id", "type", "function"]) && call["type"] as? String == "function" && call["id"] as? String == callId)
            try require(keys(function, ["name", "arguments"]) && function["name"] as? String == name && function["arguments"] as? String == arguments)
            calls = 1
        case .responses:
            for item in items {
                switch item["type"] as? String {
                case "function_call":
                    calls += 1
                    try require(keys(item, ["type", "id", "call_id", "name", "arguments", "status"]) && item["call_id"] as? String == callId && item["name"] as? String == name && item["arguments"] as? String == arguments)
                    try require(item["status"] == nil || item["status"] as? String == "completed")
                case "message":
                    try require(keys(item, ["type", "id", "role", "content", "status"]) && item["role"] as? String == "assistant")
                    try require(item["status"] == nil || item["status"] as? String == "completed")
                    guard let parts = item["content"] as? [[String: Any]] else { throw AssistantTaskToolError.invalidTrace }
                    for part in parts {
                        switch part["type"] as? String {
                        case "output_text": try require(keys(part, ["type", "text", "annotations", "logprobs"]) && part["text"] is String)
                        case "refusal": try require(keys(part, ["type", "refusal"]) && part["refusal"] is String)
                        default: throw AssistantTaskToolError.invalidTrace
                        }
                    }
                case "reasoning":
                    try require(keys(item, ["type", "id", "summary", "content", "encrypted_content", "status"]))
                    if let content = item["content"] {
                        guard let parts = content as? [[String: Any]] else { throw AssistantTaskToolError.invalidTrace }
                        for part in parts { try require(keys(part, ["type", "text"]) && part["type"] as? String == "reasoning_text" && part["text"] is String) }
                    }
                    if let encrypted = item["encrypted_content"] { try require(encrypted is String || encrypted is NSNull) }
                    if let summary = item["summary"] {
                        guard let parts = summary as? [[String: Any]] else { throw AssistantTaskToolError.invalidTrace }
                        for part in parts { try require(keys(part, ["type", "text"]) && part["type"] as? String == "summary_text" && part["text"] is String) }
                    }
                default: throw AssistantTaskToolError.invalidTrace
                }
            }
        case .anthropic:
            try require(items.count == 1 && items[0]["role"] as? String == "assistant" && keys(items[0], ["role", "content"]))
            guard let blocks = items[0]["content"] as? [[String: Any]], blocks.count <= 32 else { throw AssistantTaskToolError.invalidTrace }
            for block in blocks {
                switch block["type"] as? String {
                case "tool_use":
                    calls += 1
                    try require(keys(block, ["type", "id", "name", "input"]) && block["id"] as? String == callId && block["name"] as? String == name)
                    guard let input = block["input"] as? [String: Any], let expectedData = arguments.data(using: .utf8),
                          let expected = try? JSONSerialization.jsonObject(with: expectedData) as? [String: Any] else { throw AssistantTaskToolError.invalidTrace }
                    let inputData = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
                    let argumentData = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
                    try require(inputData == argumentData)
                case "text": try require(keys(block, ["type", "text", "citations"]) && block["text"] is String)
                case "thinking": try require(keys(block, ["type", "thinking", "signature"]) && block["thinking"] is String && !(block["signature"] as? String ?? "").isEmpty)
                case "redacted_thinking": try require(keys(block, ["type", "data"]) && block["data"] is String)
                default: throw AssistantTaskToolError.invalidTrace
                }
            }
        }
        try require(calls == 1)
    }
}

/// An SSE record ends at a blank line, not at every data line. CRLF, comments,
/// multi-line data, and a final unterminated record are handled explicitly.
struct AssistantSSEParser {
    private var event: String?
    private var id: String?
    private var dataLines: [String] = []
    private var size = 0
    let maximumEventBytes = 262_144

    mutating func consume(line rawLine: String) throws -> AssistantSSEFrame? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return nil }
        size += line.utf8.count
        guard size <= maximumEventBytes else { throw AssistantTransportError.eventTooLarge }
        let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = fields.count > 1 ? String(fields[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch fields.first.map(String.init) {
        case "data": dataLines.append(value)
        case "event": event = value
        case "id": if !value.contains("\0") { id = value }
        default: break
        }
        return nil
    }

    mutating func flush() -> AssistantSSEFrame? {
        defer { event = nil; id = nil; dataLines.removeAll(keepingCapacity: true); size = 0 }
        guard !dataLines.isEmpty else { return nil }
        return AssistantSSEFrame(event: event, id: id, data: dataLines.joined(separator: "\n"))
    }
}

enum AssistantTransportEvent: Equatable {
    case text(String)
    case usage(AssistantUsage)
    case generation(String)
    case completed
    case cancelled
    case toolCall
    case taskTool(AssistantTaskToolCall)
}

struct AssistantEventDecoder {
    static func decode(_ frame: AssistantSSEFrame) throws -> [AssistantTransportEvent] {
        if frame.data == "[DONE]" { return [.completed] }
        guard let data = frame.data.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantTransportError.malformedEvent
        }
        let type = root["type"] as? String ?? frame.event ?? ""
        if let error = root["error"] as? [String: Any] {
            throw AssistantTransportError.remote(safeErrorCode(error["type"] ?? error["code"]))
        }
        if ["error", "response.failed", "response.incomplete", "failed"].contains(type) {
            let response = root["response"] as? [String: Any]
            let error = response?["error"] as? [String: Any]
            throw AssistantTransportError.remote(safeErrorCode(error?["code"] ?? type))
        }
        if type == "cancelled" { return [.cancelled] }
        if let choices = root["choices"] as? [[String: Any]] {
            var events: [AssistantTransportEvent] = []
            if let first = choices.first {
                let delta = first["delta"] as? [String: Any]
                if let text = delta?["content"] as? String, !text.isEmpty { events.append(.text(text)) }
                if delta?["tool_calls"] != nil { events.append(.toolCall) }
                if let reason = first["finish_reason"] as? String {
                    if ["length", "content_filter"].contains(reason) { throw AssistantTransportError.remote(reason) }
                    events.append(reason == "tool_calls" ? .toolCall : .completed)
                }
            }
            if let usage = root["usage"] as? [String: Any] { events.append(.usage(decodeUsage(usage))) }
            return events
        }
        switch type {
        case "response.output_text.delta": return (root["delta"] as? String).map { [.text($0)] } ?? []
        case "content_block_delta":
            let delta = root["delta"] as? [String: Any]
            if delta?["type"] as? String == "input_json_delta" { return [.toolCall] }
            return (delta?["text"] as? String).map { [.text($0)] } ?? []
        case "content_block_start":
            return (root["content_block"] as? [String: Any])?["type"] as? String == "tool_use" ? [.toolCall] : []
        case "message_delta":
            let delta = root["delta"] as? [String: Any]
            if delta?["stop_reason"] as? String == "max_tokens" { throw AssistantTransportError.remote("max_tokens") }
            return (root["usage"] as? [String: Any]).map { [.usage(decodeUsage($0))] } ?? []
        case "message_start":
            let message = root["message"] as? [String: Any]
            return (message?["usage"] as? [String: Any]).map { [.usage(decodeUsage($0))] } ?? []
        case "response.completed":
            let response = root["response"] as? [String: Any]
            if (response?["output"] as? [[String: Any]])?.contains(where: { $0["type"] as? String == "function_call" }) == true {
                return (response?["usage"] as? [String: Any]).map { [.toolCall, .usage(decodeUsage($0))] } ?? [.toolCall]
            }
            return (response?["usage"] as? [String: Any]).map { [.usage(decodeUsage($0)), .completed] } ?? [.completed]
        case "response.output_item.added", "response.output_item.done":
            return (root["item"] as? [String: Any])?["type"] as? String == "function_call" ? [.toolCall] : []
        case "completed", "message_stop", "done": return [.completed]
        case "usage": return (root["usage"] as? [String: Any]).map { [.usage(decodeUsage($0))] } ?? []
        case "started", "generation", "metadata":
            return (root["generationId"] as? String).map { [.generation($0)] } ?? []
        case "tool_call", "response.function_call_arguments.delta": return [.toolCall]
        case "delta", "content":
            if let text = root["content"] as? String { return [.text(text)] }
            if let parts = root["content"] as? [[String: Any]] { return parts.compactMap { ($0["text"] as? String).map(AssistantTransportEvent.text) } }
            if let text = root["delta"] as? String { return [.text(text)] }
            return []
        default: return [] // Unknown lifecycle/ping events cannot masquerade as text.
        }
    }

    private static func decodeUsage(_ value: [String: Any]) -> AssistantUsage {
        // Platform v2 emits the unified camelCase contract; BYOK providers
        // still use their native snake_case spellings. Keep both forms here so
        // usage survives the protocol normalization boundary.
        AssistantUsage(inputTokens: value["inputTokens"] as? Int
                           ?? value["promptTokens"] as? Int
                           ?? value["input_tokens"] as? Int
                           ?? value["prompt_tokens"] as? Int,
                       outputTokens: value["outputTokens"] as? Int
                           ?? value["completionTokens"] as? Int
                           ?? value["output_tokens"] as? Int
                           ?? value["completion_tokens"] as? Int)
    }

    private static func safeErrorCode(_ value: Any?) -> String {
        let code = value as? String ?? "UPSTREAM_ERROR"
        return String(code.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }.prefix(80))
    }
}

/// Enabled only for an explicitly authorized BYOK request. Tool bytes remain
/// private until the provider's successful terminal event AND native HTTP EOF.
private struct AssistantTaskToolStreamDecoder {
    let mode: AssistantTaskToolMode
    let protocolKind: AssistantWireProtocol?
    private var terminal = false
    private var sawTool = false
    private var callId = ""
    private var callName = ""
    private var arguments = ""
    private var chatText = ""
    private var toolTerminal = false
    private var responseItems: [Int: [String: Any]] = [:]
    private var responseArguments: [Int: String] = [:]
    private var responseDeltas = Set<Int>()
    private var responseArgumentDones = Set<Int>()
    private var responseDoneItems = Set<Int>()
    private var finalResponseItems: [[String: Any]]?
    private var blocks: [Int: [String: Any]] = [:]
    private var blockArguments: [Int: String] = [:]
    private var stoppedBlocks = Set<Int>()
    private var anthropicStarted = false

    init(mode: AssistantTaskToolMode, request: URLRequest) {
        self.mode = mode
        let path = request.url?.path ?? ""
        if path.hasSuffix("/chat/completions") { protocolKind = .chatCompletions }
        else if path.hasSuffix("/responses") { protocolKind = .responses }
        else if path.hasSuffix("/messages") { protocolKind = .anthropic }
        else { protocolKind = nil }
    }

    private func malformed() -> AssistantTaskToolError { .invalidTrace }
    private func bounded(_ value: String, maximum: Int = AssistantTaskToolCall.maximumArgumentBytes) throws {
        guard value.utf8.count <= maximum else { throw AssistantTaskToolError.tooLarge }
    }
    private func integer(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue,
              number.intValue >= 0, number.intValue < 32 else { throw malformed() }
        return number.intValue
    }
    private mutating func identity(id: String?, name: String?) throws {
        if let id {
            guard callId.isEmpty || callId == id else { throw malformed() }
            callId = id; try bounded(id, maximum: 256)
        }
        if let name {
            guard callName.isEmpty || callName == name else { throw malformed() }
            callName = name
            guard name == mode.functionName else { throw AssistantTransportError.toolExecutionUnavailable }
        }
    }
    mutating func decode(_ frame: AssistantSSEFrame) throws -> [AssistantTransportEvent] {
        let decoded = try AssistantEventDecoder.decode(frame)
        guard let protocolKind else { throw malformed() }
        if frame.data == "[DONE]" {
            guard protocolKind == .chatCompletions else { throw malformed() }
            terminal = true
            return decoded.filter { if case .completed = $0 { return false }; return true }
        }
        guard let data = frame.data.data(using: .utf8), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw malformed() }
        switch protocolKind {
        case .chatCompletions: try consumeChat(root)
        case .responses: try consumeResponses(root)
        case .anthropic: try consumeAnthropic(root)
        }
        for event in decoded {
            if case .toolCall = event, !sawTool { throw malformed() }
        }
        return decoded.filter {
            switch $0 { case .toolCall, .completed: return false; default: return true }
        }
    }

    private mutating func consumeChat(_ root: [String: Any]) throws {
        guard let choices = root["choices"] as? [[String: Any]], choices.count <= 1 else { throw malformed() }
        guard let first = choices.first else { return }
        if let index = first["index"] { guard try integer(index) == 0 else { throw malformed() } }
        let delta = first["delta"] as? [String: Any] ?? [:]
        guard !terminal || delta.isEmpty else { throw malformed() }
        if let role = delta["role"] as? String, role != "assistant" { throw malformed() }
        if delta["function_call"] != nil { throw AssistantTransportError.toolExecutionUnavailable }
        if let text = delta["content"] as? String { chatText += text; try bounded(chatText, maximum: AssistantTaskToolTrace.maximumBytes) }
        if let rawCalls = delta["tool_calls"] {
            guard let calls = rawCalls as? [[String: Any]], calls.count == 1, let call = calls.first,
                  try integer(call["index"]) == 0 else { throw malformed() }
            sawTool = true
            guard !toolTerminal else { throw malformed() }
            if let type = call["type"] as? String, type != "function" { throw malformed() }
            let function = call["function"] as? [String: Any] ?? [:]
            try identity(id: call["id"] as? String, name: function["name"] as? String)
            if let chunk = function["arguments"] as? String { arguments += chunk; try bounded(arguments) }
        }
        if let reason = first["finish_reason"] as? String {
            guard !terminal else { throw malformed() }
            if reason == "tool_calls" { guard sawTool else { throw malformed() }; toolTerminal = true }
            else {
                guard reason == "stop" else { throw malformed() }
                // Compatible gateways may use stop for a complete structured
                // call. Identity/schema validation still occurs only at native
                // EOF, and disabled mode never acquires tool authority.
                if sawTool {
                    guard mode != .disabled else { throw AssistantTransportError.toolExecutionUnavailable }
                    toolTerminal = true
                }
            }
            terminal = true
        }
    }

    private mutating func consumeResponses(_ root: [String: Any]) throws {
        let type = root["type"] as? String ?? ""
        guard !terminal else { throw malformed() }
        switch type {
        case "response.output_item.added":
            let index = try integer(root["output_index"])
            guard responseItems[index] == nil, let item = root["item"] as? [String: Any] else { throw malformed() }
            responseItems[index] = item
            if item["type"] as? String == "function_call" {
                guard !sawTool else { throw malformed() }; sawTool = true
                try identity(id: item["call_id"] as? String, name: item["name"] as? String)
                responseArguments[index] = item["arguments"] as? String ?? ""
            }
        case "response.function_call_arguments.delta", "response.function_call_arguments.done":
            let index = try integer(root["output_index"])
            guard let item = responseItems[index], item["type"] as? String == "function_call",
                  let itemId = item["id"] as? String, root["item_id"] as? String == itemId else { throw malformed() }
            if type.hasSuffix(".delta") {
                guard !responseArgumentDones.contains(index), !responseDoneItems.contains(index) else { throw malformed() }
                guard let delta = root["delta"] as? String else { throw malformed() }
                responseArguments[index, default: ""] += delta; responseDeltas.insert(index)
                try bounded(responseArguments[index] ?? "")
            } else {
                guard !responseArgumentDones.contains(index), !responseDoneItems.contains(index) else { throw malformed() }
                guard let complete = root["arguments"] as? String else { throw malformed() }
                if responseDeltas.contains(index) { guard complete == responseArguments[index] else { throw malformed() } }
                responseArguments[index] = complete
                responseArgumentDones.insert(index)
            }
        case "response.output_item.done":
            let index = try integer(root["output_index"])
            guard !responseDoneItems.contains(index), let existing = responseItems[index], let item = root["item"] as? [String: Any], item["id"] as? String == existing["id"] as? String,
                  item["type"] as? String == existing["type"] as? String else { throw malformed() }
            if item["type"] as? String == "function_call" {
                try identity(id: item["call_id"] as? String, name: item["name"] as? String)
                guard let complete = item["arguments"] as? String else { throw malformed() }
                if responseDeltas.contains(index) { guard complete == responseArguments[index] else { throw malformed() } }
                responseArguments[index] = complete
            }
            responseItems[index] = item
            responseDoneItems.insert(index)
        case "response.completed":
            guard let response = root["response"] as? [String: Any] else { throw malformed() }
            if let status = response["status"] as? String, status != "completed" { throw malformed() }
            let output = response["output"] as? [[String: Any]] ?? []
            for (index, item) in responseItems {
                guard output.indices.contains(index), output[index]["id"] as? String == item["id"] as? String,
                      output[index]["type"] as? String == item["type"] as? String else { throw malformed() }
                if responseDoneItems.contains(index) {
                    let tracked = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
                    let final = try JSONSerialization.data(withJSONObject: output[index], options: [.sortedKeys])
                    guard tracked == final else { throw malformed() }
                }
            }
            let calls = output.filter { $0["type"] as? String == "function_call" }
            guard calls.count <= 1 else { throw malformed() }
            if let call = calls.first {
                try identity(id: call["call_id"] as? String, name: call["name"] as? String)
                guard let complete = call["arguments"] as? String else { throw malformed() }
                for (index, item) in responseItems where item["type"] as? String == "function_call" {
                    guard call["id"] as? String == item["id"] as? String else { throw malformed() }
                    if let tracked = responseArguments[index], !tracked.isEmpty { guard tracked == complete else { throw malformed() } }
                }
                sawTool = true; toolTerminal = true; arguments = complete; try bounded(arguments)
                finalResponseItems = output
            } else if sawTool { throw malformed() }
            terminal = true
        case "response.function_call_arguments.failed": throw malformed()
        default:
            if type.contains("function_call") { throw malformed() }
        }
    }

    private mutating func consumeAnthropic(_ root: [String: Any]) throws {
        let type = root["type"] as? String ?? ""
        guard !terminal else { throw malformed() }
        switch type {
        case "message_start":
            guard !anthropicStarted, let message = root["message"] as? [String: Any], message["role"] as? String == "assistant" else { throw malformed() }
            anthropicStarted = true
        case "content_block_start":
            guard anthropicStarted else { throw malformed() }
            let index = try integer(root["index"])
            guard blocks[index] == nil, let block = root["content_block"] as? [String: Any] else { throw malformed() }
            blocks[index] = block
            if block["type"] as? String == "tool_use" {
                guard !sawTool else { throw malformed() }; sawTool = true
                try identity(id: block["id"] as? String, name: block["name"] as? String)
            }
        case "content_block_delta":
            let index = try integer(root["index"])
            guard var block = blocks[index], !stoppedBlocks.contains(index), let delta = root["delta"] as? [String: Any] else { throw malformed() }
            switch delta["type"] as? String {
            case "input_json_delta":
                guard block["type"] as? String == "tool_use", let partial = delta["partial_json"] as? String else { throw malformed() }
                if blockArguments[index] == nil { guard (block["input"] as? [String: Any])?.isEmpty == true else { throw malformed() } }
                blockArguments[index, default: ""] += partial; try bounded(blockArguments[index] ?? "")
            case "text_delta":
                guard block["type"] as? String == "text", let chunk = delta["text"] as? String else { throw malformed() }
                let value = (block["text"] as? String ?? "") + chunk; try bounded(value, maximum: AssistantTaskToolTrace.maximumBytes); block["text"] = value
            case "thinking_delta":
                guard block["type"] as? String == "thinking", let chunk = delta["thinking"] as? String else { throw malformed() }
                let value = (block["thinking"] as? String ?? "") + chunk; try bounded(value, maximum: AssistantTaskToolTrace.maximumBytes); block["thinking"] = value
            case "signature_delta":
                guard block["type"] as? String == "thinking", let chunk = delta["signature"] as? String else { throw malformed() }
                let value = (block["signature"] as? String ?? "") + chunk; try bounded(value, maximum: AssistantTaskToolTrace.maximumBytes); block["signature"] = value
            case "citations_delta": throw malformed()
            default: throw malformed()
            }
            blocks[index] = block
        case "content_block_stop":
            let index = try integer(root["index"])
            guard var block = blocks[index], !stoppedBlocks.contains(index) else { throw malformed() }
            if block["type"] as? String == "tool_use" {
                if let value = blockArguments[index] { arguments = value }
                else {
                    guard let input = block["input"] as? [String: Any], let raw = String(data: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), encoding: .utf8) else { throw malformed() }
                    arguments = raw
                }
                try bounded(arguments)
                guard let bytes = arguments.data(using: .utf8), let input = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw malformed() }
                block["input"] = input; blocks[index] = block
            }
            stoppedBlocks.insert(index)
        case "message_delta":
            if let reason = (root["delta"] as? [String: Any])?["stop_reason"] as? String {
                if sawTool { guard reason == "tool_use" else { throw malformed() }; toolTerminal = true }
                else { guard ["end_turn", "stop_sequence"].contains(reason) else { throw malformed() } }
            }
        case "message_stop":
            guard anthropicStarted, stoppedBlocks.count == blocks.count, !sawTool || toolTerminal else { throw malformed() }
            terminal = true
        case "ping": break
        default: if type.contains("tool") { throw malformed() }
        }
    }

    func finish() throws -> AssistantTaskToolCall? {
        guard terminal else { throw AssistantTransportError.interrupted }
        guard sawTool else { return nil }
        guard toolTerminal, let protocolKind else { throw malformed() }
        let items: [[String: Any]]
        switch protocolKind {
        case .chatCompletions:
            items = [["role": "assistant", "content": chatText, "tool_calls": [["id": callId, "type": "function", "function": ["name": callName, "arguments": arguments]]]]]
        case .responses:
            guard let output = finalResponseItems else { throw malformed() }; items = output
        case .anthropic:
            guard blocks.keys.sorted() == Array(0..<blocks.count) else { throw malformed() }
            items = [["role": "assistant", "content": blocks.keys.sorted().compactMap { blocks[$0] }]]
        }
        let data = try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
        guard data.count <= AssistantTaskToolTrace.maximumBytes, let json = String(data: data, encoding: .utf8) else { throw AssistantTaskToolError.tooLarge }
        let trace = AssistantTaskToolTrace(protocolKind: protocolKind, assistantItemsJSON: json)
        try trace.validateStructure(callId: callId, name: callName, arguments: arguments)
        let call = AssistantTaskToolCall(id: callId, name: callName, arguments: arguments, trace: trace)
        try call.validate(for: mode)
        return call
    }
}

/// Per-request lifecycle and SSE decoder. Delegate callbacks are serialized, while
/// the lock arbitrates cancellation against the synchronous MainActor start.
private final class AssistantStreamRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<AssistantTransportEvent, Error>.Continuation
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private var continuation: Continuation?
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var startupTask: Task<Void, Never>?
    private var started = false
    private var finished = false
    private var responseAccepted = false
    private var parser = AssistantSSEParser()
    private var lineBytes = Data()
    private var responseBytes = 0
    private var sawCompletion = false
    private var sawCancellation = false
    private var receivedText = false
    private var taskTools: AssistantTaskToolStreamDecoder?

    init(configuration: URLSessionConfiguration, continuation: Continuation, request: URLRequest, toolMode: AssistantTaskToolMode) {
        self.configuration = configuration; self.continuation = continuation
        if toolMode != .disabled { taskTools = AssistantTaskToolStreamDecoder(mode: toolMode, request: request) }
    }

    func registerStartup(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = finished
        if !finished && !started { startupTask = task }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    /// No suspension is permitted between the authorization hook and resume.
    /// MainActor-owned identity/preferences cannot change in this synchronous turn.
    @MainActor
    func start(_ request: URLRequest, beforeStart: (@MainActor @Sendable () throws -> Void)?) {
        lock.lock(); let waiting = !finished && !started; lock.unlock()
        guard waiting, !Task.isCancelled else { cancel(); return }
        do { try beforeStart?() } catch { finish(error); return }
        guard !Task.isCancelled else { cancel(); return }
        lock.lock()
        guard !finished && !started else { lock.unlock(); return }
        started = true; startupTask = nil
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        self.session = session; self.dataTask = task
        task.resume()
        lock.unlock()
    }

    func cancel() { finish(CancellationError()) }
    func failStartup(_ error: Error) { finish(error) }

    /// Finish and invalidate outside the lock: finish synchronously invokes the
    /// stream termination handler, which is allowed to call cancel again.
    private func finish(_ error: Error? = nil) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation; self.continuation = nil
        let task = dataTask; dataTask = nil
        let session = self.session; self.session = nil
        let startup = startupTask; startupTask = nil
        lock.unlock()
        startup?.cancel(); task?.cancel(); session?.invalidateAndCancel()
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a credential or personal context across any redirect.
        completionHandler(nil)
        finish(AssistantTransportError.http(response.statusCode))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(AssistantTransportError.malformedEvent); return
        }
        guard (200..<300).contains(response.statusCode) else {
            completionHandler(.cancel); finish(AssistantTransportError.http(response.statusCode)); return
        }
        guard response.mimeType?.lowercased() == "text/event-stream" else {
            completionHandler(.cancel); finish(AssistantTransportError.malformedEvent); return
        }
        lock.lock()
        let accept = !finished && started
        if accept { responseAccepted = true }
        lock.unlock()
        completionHandler(accept ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var events: [AssistantTransportEvent] = [], failure: Error?
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let continuation = self.continuation
        do {
            guard responseAccepted else { throw AssistantTransportError.malformedEvent }
            guard data.count <= 8_388_608 - responseBytes else { throw AssistantTransportError.eventTooLarge }
            responseBytes += data.count
            for byte in data {
                if byte == 10 { try consumeLine(into: &events) }
                else {
                    lineBytes.append(byte)
                    guard lineBytes.count <= 262_144 else { throw AssistantTransportError.eventTooLarge }
                }
            }
        } catch { failure = error }
        lock.unlock()
        for event in events { continuation?.yield(event) }
        if let failure { finish(failure) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error); return }
        var events: [AssistantTransportEvent] = [], failure: Error?
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let continuation = self.continuation
        do {
            guard responseAccepted else { throw AssistantTransportError.malformedEvent }
            if !lineBytes.isEmpty { try consumeLine(into: &events) }
            if let frame = parser.flush() { try decode(frame, into: &events) }
            if let taskTools {
                if let call = try taskTools.finish() { events.append(.taskTool(call)) }
                else { guard receivedText else { throw AssistantTransportError.emptyResult } }
                events.append(.completed)
            } else {
                guard sawCompletion || sawCancellation else { throw AssistantTransportError.interrupted }
                guard receivedText || sawCancellation else { throw AssistantTransportError.emptyResult }
            }
        } catch { failure = error }
        lock.unlock()
        for event in events { continuation?.yield(event) }
        finish(failure)
    }

    /// Parser and byte state are accessed only while holding the lifecycle lock.
    private func consumeLine(into events: inout [AssistantTransportEvent]) throws {
        guard let line = String(data: lineBytes, encoding: .utf8) else { throw AssistantTransportError.malformedEvent }
        lineBytes.removeAll(keepingCapacity: true)
        if let frame = try parser.consume(line: line) { try decode(frame, into: &events) }
    }
    private func decode(_ frame: AssistantSSEFrame, into events: inout [AssistantTransportEvent]) throws {
        let decoded: [AssistantTransportEvent]
        if taskTools != nil { decoded = try taskTools!.decode(frame) }
        else { decoded = try AssistantEventDecoder.decode(frame) }
        for event in decoded {
            if case .completed = event { sawCompletion = true }
            if case .cancelled = event { sawCancellation = true }
            if case .text(let text) = event, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { receivedText = true }
            if case .toolCall = event { throw AssistantTransportError.toolExecutionUnavailable }
            events.append(event)
        }
    }
}

final class AssistantStreamTransport {
    private let injectedConfiguration: URLSessionConfiguration?
    /// Test-only delay before entering the indivisible MainActor authorization/start turn.
    /// It cannot skip the hook, resume a request, or change a request's configuration.
    private let startupBarrier: (@Sendable () async -> Void)?
    init(configuration: URLSessionConfiguration? = nil, startupBarrier: (@Sendable () async -> Void)? = nil) {
        injectedConfiguration = configuration; self.startupBarrier = startupBarrier
    }

    func events(for request: URLRequest, toolMode: AssistantTaskToolMode = .disabled, beforeStart: (@MainActor @Sendable () throws -> Void)? = nil,
                beforeStartWait: (@MainActor @Sendable () async throws -> Void)? = nil) -> AsyncThrowingStream<AssistantTransportEvent, Error> {
        let preCancelled = Task.isCancelled
        let barrier = startupBarrier
        return AsyncThrowingStream { continuation in
            let configuration = (injectedConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 180
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            let operation = AssistantStreamRequest(configuration: configuration, continuation: continuation, request: request, toolMode: toolMode)
            continuation.onTermination = { _ in operation.cancel() }
            guard !preCancelled else { operation.cancel(); return }
            let startup = Task { @MainActor in
                if let barrier { await barrier() }
                guard !Task.isCancelled else { operation.cancel(); return }
                do { try await beforeStartWait?() }
                catch { operation.failStartup(error); return }
                guard !Task.isCancelled else { operation.cancel(); return }
                operation.start(request, beforeStart: beforeStart)
            }
            operation.registerStartup(startup)
        }
    }
}
