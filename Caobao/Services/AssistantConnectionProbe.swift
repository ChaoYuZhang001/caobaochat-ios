import Foundation

struct AssistantConnectionProbeResult: Equatable {
    let protocolKind: AssistantWireProtocol
    let model: String
    let elapsedSeconds: TimeInterval
}

enum AssistantConnectionProbeError: LocalizedError, Equatable {
    case invalidTimeout
    case timedOut
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidTimeout: return AssistantLocalization.string("连接检测超时设置无效。")
        case .timedOut: return AssistantLocalization.string("连接检测超时，请检查地址、模型和网络后重试。")
        case .responseTooLarge: return AssistantLocalization.string("连接检测返回内容过多，未视为检测成功。")
        }
    }
}

/// An explicit, potentially billable test. It never accepts conversation context,
/// writes an archive, or switches to the CaoBao platform. Success requires the
/// existing transport's effective text and normal terminal/EOF validation.
final class AssistantConnectionProbe {
    private let transport: AssistantStreamTransport
    private let timeout: TimeInterval

    init(transport: AssistantStreamTransport = AssistantStreamTransport(), timeout: TimeInterval = 20) {
        self.transport = transport
        self.timeout = timeout
    }

    func check(configuration: BYOKConfiguration) async throws -> AssistantConnectionProbeResult {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw AssistantConnectionProbeError.invalidTimeout }
        var request = try configuration.request(
            turns: [AssistantTurn(id: "connection-check", role: "user", text: "Reply with the single word OK.")],
            instructions: "This is a connectivity check. Reply with OK only.",
            requestId: "probe." + UUID().uuidString)
        guard let body = request.httpBody,
              var json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw AssistantTransportError.malformedEvent
        }
        switch configuration.protocolKind {
        case .chatCompletions, .anthropic: json["max_tokens"] = 16
        case .responses: json["max_output_tokens"] = 16
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        request.timeoutInterval = timeout
        let outgoingRequest = request
        let started = ProcessInfo.processInfo.systemUptime
        let transport = self.transport
        let nanoseconds = UInt64(timeout * 1_000_000_000)
        return try await withThrowingTaskGroup(of: AssistantConnectionProbeResult.self) { group in
            group.addTask {
                var hasText = false
                var hasCompletion = false
                var receivedBytes = 0
                for try await event in transport.events(for: outgoingRequest) {
                    try Task.checkCancellation()
                    switch event {
                    case .text(let text):
                        receivedBytes += text.utf8.count
                        guard receivedBytes <= 4_096 else { throw AssistantConnectionProbeError.responseTooLarge }
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasText = true }
                    case .completed: hasCompletion = true
                    case .cancelled: throw AssistantTransportError.interrupted
                    case .toolCall, .taskTool(_): throw AssistantTransportError.toolExecutionUnavailable
                    case .usage, .generation: break
                    }
                }
                try Task.checkCancellation()
                guard hasCompletion else { throw AssistantTransportError.interrupted }
                guard hasText else { throw AssistantTransportError.emptyResult }
                return AssistantConnectionProbeResult(protocolKind: configuration.protocolKind, model: configuration.model,
                    elapsedSeconds: max(0, ProcessInfo.processInfo.systemUptime - started))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                try Task.checkCancellation()
                throw AssistantConnectionProbeError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}
