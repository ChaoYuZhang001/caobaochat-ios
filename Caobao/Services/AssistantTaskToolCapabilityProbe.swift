import Foundation

/// Stateless facade: each invocation owns its request, stream and deadline.
/// The injected transport allocates an independent operation for each stream.
/// No key, response, capability proof or current task is retained by this object.
final class AssistantTaskToolCapabilityProbe: @unchecked Sendable {
    private let transport: AssistantStreamTransport
    private let timeoutNanoseconds: UInt64

    init(transport: AssistantStreamTransport = AssistantStreamTransport(), timeout: TimeInterval = 20) {
        self.transport = transport
        let boundedTimeout = timeout.isFinite ? min(max(timeout, 0.001), 20) : 20
        timeoutNanoseconds = UInt64(boundedTimeout * 1_000_000_000)
    }

    func check(configuration: BYOKConfiguration,
               beforeStart: (@MainActor @Sendable () throws -> Void)? = nil,
               beforeStartWait: (@MainActor @Sendable () async throws -> Void)? = nil) async throws -> String {
        try Task.checkCancellation()
        let fingerprint = try configuration.consentIdentifier()
        let fixedText = "This is a capability check. Call caobao_task_probe with ok=true. Do not create a task."
        var request = try configuration.request(turns: [AssistantTurn(id: UUID().uuidString, role: "user", text: fixedText)],
            instructions: "Only call the supplied harmless capability function. This check has no side effects.",
            requestId: UUID().uuidString, toolMode: .capabilityProbe)
        guard let data = request.httpBody,
              var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AssistantTaskToolError.capabilityRequired }
        switch configuration.protocolKind {
        case .responses: body["max_output_tokens"] = 128
        case .chatCompletions, .anthropic: body["max_tokens"] = 128
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        let fixedRequest = request
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [transport] in
                var calls = 0, completed = false
                for try await event in transport.events(for: fixedRequest, toolMode: .capabilityProbe,
                    beforeStart: beforeStart, beforeStartWait: beforeStartWait) {
                    try Task.checkCancellation()
                    switch event {
                    case .taskTool(let call):
                        try call.validate(for: .capabilityProbe); calls += 1
                        guard calls == 1 else { throw AssistantTaskToolError.capabilityRequired }
                    case .completed: completed = true
                    case .cancelled: throw AssistantTransportError.interrupted
                    case .text, .generation, .usage: break
                    case .toolCall: throw AssistantTaskToolError.capabilityRequired
                    }
                }
                try Task.checkCancellation()
                guard calls == 1, completed else { throw AssistantTaskToolError.capabilityRequired }
                return fingerprint
            }
            group.addTask { [timeoutNanoseconds] in
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw AssistantTransportError.configuration(AssistantLocalization.string("待办工具验证超时，未启用该能力。请稍后重试。"))
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw AssistantTaskToolError.capabilityRequired }
            return result
        }
    }
}
