import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

private struct ChatTestFailure: Error, CustomStringConvertible { let description: String }
private struct ChatFixtureTaskStore: Encodable {
    let memories: [String: [AssistantMemory]] = [:]
    let tasks: [String: [AssistantTask]]
    let memoryEnabled: [String: Bool] = [:]
}

@MainActor private final class ChatHarness {
    private static var closing: [ChatHarness] = []
    let directory: URL
    let suite = "caobao-chat-tests." + UUID().uuidString
    let defaults: UserDefaults
    let archive: AssistantChatArchive
    let repository: AssistantLocalRepository
    let transport: AssistantStreamTransport
    let conversationClient: AssistantConversationClient
    let vm: ChatViewModel
    let owner: String
    var prefix: String { "caobao.assistant.\(Data(owner.utf8).base64EncodedString())." }
    var byokPrefix: String { "assistant.byok.\(owner)." }

    init(owner: String = "fixture-owner", persistedTasks: [AssistantTask] = [],
         startupBarrier: (@Sendable () async -> Void)? = nil, archiveFileManager: FileManager = .default,
         imagePreparationBarrier: (@Sendable () async -> Void)? = nil,
         beforeArchiveCommit: (@Sendable () throws -> Void)? = nil, afterArchiveCommit: (@Sendable () async -> Void)? = nil,
         archiveFault: (@Sendable (AssistantArchiveFaultPoint, String) throws -> Void)? = nil,
         prepareArchive: Bool = true, beforePrepare: ((AssistantChatArchive) throws -> Void)? = nil) async throws {
        self.owner = owner
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("caobao-chat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
        let archiveStore = AssistantChatArchive(directory: directory.appendingPathComponent("conversations"), fileManager: archiveFileManager, fault: archiveFault)
        archive = archiveStore
        try beforePrepare?(archiveStore)
        if prepareArchive { try await archiveStore.prepareAsync(userId: owner) }
        if !persistedTasks.isEmpty {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(ChatFixtureTaskStore(tasks: [owner: persistedTasks]))
                .write(to: directory.appendingPathComponent("repository.json"), options: .atomic)
        }
        repository = AssistantLocalRepository(fileURL: directory.appendingPathComponent("repository.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatFixtureURLProtocol.self]
        transport = AssistantStreamTransport(configuration: configuration, startupBarrier: startupBarrier)
        conversationClient = AssistantConversationClient(baseURL: APIConfig.assistantBaseURL, sessionConfiguration: configuration)
        AuthService.shared.user = ChatFixtureUser(id: owner)
        AuthService.shared.token = "fixture-token"
        defaults.set("byok", forKey: "caobao.assistant.\(Data(owner.utf8).base64EncodedString()).assistantMode")
        defaults.set("en", forKey: "caobao.assistant.\(Data(owner.utf8).base64EncodedString()).language")
        defaults.set("CN", forKey: "caobao.assistant.\(Data(owner.utf8).base64EncodedString()).serviceRegion")
        defaults.set("https://api.example.com/tenant-a/v1", forKey: "assistant.byok.\(owner).url")
        defaults.set("fixture-model", forKey: "assistant.byok.\(owner).model")
        defaults.set("openai-chat", forKey: "assistant.byok.\(owner).protocol")
        KeychainStore.set("fixture-key", account: "byok-api-key.\(owner)")
        ChatFixtureURLProtocol.reset()
        vm = ChatViewModel(archive: archive, transport: transport, conversationClient: conversationClient, repository: repository, defaults: defaults, imagePreparationBarrier: imagePreparationBarrier, beforeArchiveCommit: beforeArchiveCommit, afterArchiveCommit: afterArchiveCommit)
        try await vm.waitForArchiveReady(ownerId: owner)
    }
    func configure(owner id: String) async throws {
        try await archive.prepareAsync(userId: id)
        let prefix = "caobao.assistant.\(Data(id.utf8).base64EncodedString())."
        defaults.set("byok", forKey: prefix + "assistantMode")
        defaults.set("en", forKey: prefix + "language")
        defaults.set("CN", forKey: prefix + "serviceRegion")
        defaults.set("https://api.example.com/tenant-a/v1", forKey: "assistant.byok.\(id).url")
        defaults.set("fixture-model", forKey: "assistant.byok.\(id).model")
        KeychainStore.set("fixture-key", account: "byok-api-key.\(id)")
    }
    func addMemory(text: String, consent: String = "explicit", userId: String? = nil) {
        let now = Date()
        repository.addMemory(AssistantMemory(id: UUID().uuidString, userId: userId ?? owner, category: .preference,
            text: text, consent: consent, status: .active, createdAt: now, updatedAt: now))
    }
    func close() {
        vm.cancel()
        Self.closing.append(self)
    }
    static func drainClosures() async {
        let pending = closing; closing.removeAll()
        for harness in pending {
            await harness.vm.waitForPendingArchiveWrites()
            _ = try? await harness.archive.background { _ in () }
            harness.defaults.removePersistentDomain(forName: harness.suite)
            try? FileManager.default.removeItem(at: harness.directory)
        }
    }
}

@main @MainActor private enum ChatViewModelTests {
    private static var suites = 0
    private static var failures: [String] = []
    private static func expect(_ value: @autoclosure () async throws -> Bool, _ description: String) async throws {
        if try await !value() { throw ChatTestFailure(description: description) }
    }
    private static func wait(_ description: String, until condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() {
            guard Date() < deadline else { throw ChatTestFailure(description: "Timed out: " + description) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private static func run(_ name: String, _ body: @MainActor () async throws -> Void) async throws {
        print("RUN \(name)"); fflush(stdout)
        do { try await body() } catch {
            await ChatHarness.drainClosures(); failures.append(name + ": " + String(describing: error))
            print("FAIL \(name): \(error)"); fflush(stdout); return
        }
        await ChatHarness.drainClosures()
        suites += 1; print("PASS \(name)"); fflush(stdout)
    }
    private static func finished(_ vm: ChatViewModel) async throws {
        try await wait("generation completion") { !vm.isLoading }
        await vm.waitForPendingArchiveWrites()
        try await expect(vm.messages.last?.status == .completed, "Generation must complete; error=\(vm.error ?? "none")")
    }
    private static func newConversation(_ vm: ChatViewModel) async throws {
        if await vm.requestNewConversation(ownerId: vm.ownerUserId) { return }
        guard let ticket = vm.pendingConversationSwitch, await vm.confirmConversationSwitch(ticket) else {
            throw ChatTestFailure(description: "Protected new conversation must commit: " + (vm.conversationSwitchError ?? "none"))
        }
    }
    private static func send(_ h: ChatHarness, _ text: String) async throws {
        try await h.vm.waitForArchiveReady(ownerId: h.vm.ownerUserId)
        h.vm.inputText = text
        h.vm.sendMessage(userId: "ignored-untrusted-caller-id")
        try await expect(h.vm.isLoading, "A configured send must start the actual producer")
        try await finished(h.vm)
    }
    private static func body(_ index: Int = 0) throws -> [String: Any] {
        let request = ChatFixtureURLProtocol.captured[index]
        var bytes = request.httpBody
        if bytes == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }; result.append(contentsOf: buffer.prefix(count))
            }
            bytes = result
        }
        guard let bytes, let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw ChatTestFailure(description: "Actual URLProtocol request must retain a JSON body")
        }
        return json
    }
    private static func conversation(id: String = UUID().uuidString, messages: [ChatMessage]) -> Conversation {
        Conversation(id: id, title: "fixture history", preview: "fixture preview", date: Date(), messages: messages)
    }
    private static func message(_ role: ChatMessage.Role, _ text: String, status: ChatMessage.Status = .completed) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, role: role, content: text, timestamp: Date(), status: status)
    }
    private static func failure(_ operation: () async throws -> Void) async throws -> Error {
        do { try await operation() } catch { return error }
        throw ChatTestFailure(description: "Expected the operation to throw")
    }
    private static func actionMemory(owner: String, id: String = UUID().uuidString, text: String = "User edited memory") -> AssistantMemory {
        AssistantMemory(id: id, userId: owner, category: .preference, text: text, sourceMessageId: "untrusted-source",
            consent: "explicit", status: .active, createdAt: .distantPast, updatedAt: .distantPast)
    }
    private static func changeMemoryAuthorization(_ change: String, harness h: ChatHarness) async throws {
        let original = h.repository.memories(for: h.owner).first!
        switch change {
        case "revoke":
            var record = original; record.consent = "revoked"
            try await expect(h.repository.updateMemory(record, expecting: original), "A real record revocation must persist")
        case "delete":
            try await expect(h.repository.deleteMemory(id: original.id, userId: h.owner), "A real deletion must persist")
        case "global":
            h.repository.setMemoryEnabled(false, for: h.owner)
            try await expect(!h.repository.isMemoryEnabled(for: h.owner), "The global memory switch must persist")
        case "category":
            try await expect(h.repository.setMemoryCategoryEnabled(false, category: original.category, for: h.owner), "The category switch must persist")
        default: throw ChatTestFailure(description: "Unknown authorization mutation fixture")
        }
    }
    private static func pendingSwitch(_ h: ChatHarness) throws -> AssistantConversationSwitchRequest {
        guard let source = h.vm.pendingConversationSwitch else { throw ChatTestFailure(description: "Expected a public conversation-switch ticket") }
        return source
    }
    private static func targetHistory(_ h: ChatHarness, id: String = UUID().uuidString, text: String = "Target history") throws -> Conversation {
        let target = conversation(id: id, messages: [message(.user, text), message(.assistant, "Saved answer")])
        try h.archive.upsert(target, userId: h.owner)
        return target
    }
    private static func archiveFiles(_ h: ChatHarness) throws -> [String: Data] {
        let directory = h.directory.appendingPathComponent("conversations")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: urls.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
    private static func sql(_ h: ChatHarness, _ statement: String, _ values: [AssistantSQLValue] = []) throws {
        let db = try AssistantChatDatabase(url: h.archive.databaseURL(userId: h.owner), create: false)
        defer { try? db.close() }
        try db.execute(statement, values)
    }
    private static func archiveFile(_ h: ChatHarness, extension suffix: String) throws -> URL {
        let urls = try FileManager.default.contentsOfDirectory(at: h.directory.appendingPathComponent("conversations"), includingPropertiesForKeys: nil)
        guard let url = urls.first(where: { $0.pathExtension == suffix }) else {
            throw ChatTestFailure(description: "Expected a real archive file with extension " + suffix)
        }
        return url
    }
    private static func image(red: CGFloat = 0.3) throws -> AssistantImage {
        let context = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.5, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw ChatTestFailure(description: "Fixture image creation failed") }
        return try AssistantImagePreprocessor.prepare(output as Data)
    }

    private static func generationFixture(_ h: ChatHarness, status: ChatMessage.Status = .failed,
                                          text: String = "", images: [AssistantImage] = []) -> (user: ChatMessage, answer: ChatMessage) {
        var user = message(.user, "Original question"); user.images = images.isEmpty ? nil : images
        let answer = ChatMessage(id: UUID().uuidString, role: .assistant, content: text, timestamp: Date(),
            status: status, requestId: "original-request")
        h.vm.messages = [user, answer]
        return (user, answer)
    }
    private static func jsonStrings(_ value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let values = value as? [Any] { return values.flatMap(jsonStrings) }
        if let values = value as? [String: Any] { return values.values.flatMap(jsonStrings) }
        return []
    }
    private static func contextTask(owner: String, id: String, rule: String?, zone: String, reminder: Bool?) -> AssistantTask {
        let recorded = Date(timeIntervalSince1970: 1_800_000_000)
        return AssistantTask(id: id, userId: owner, title: id, instructions: "Keep the recorded schedule",
            dueAt: Date(timeIntervalSince1970: 2_300_000_000), timeZone: zone, recurrenceRule: rule,
            requiresApproval: true, status: .active, createdAt: recorded, updatedAt: recorded, reminderEnabled: reminder)
    }
    private static func systemInstructions(_ payload: [String: Any], protocol kind: AssistantWireProtocol) throws -> String {
        let text: String?
        switch kind {
        case .chatCompletions: text = (payload["messages"] as? [[String: Any]])?.first?["content"] as? String
        case .responses: text = payload["instructions"] as? String
        case .anthropic: text = payload["system"] as? String
        }
        guard let text else { throw ChatTestFailure(description: "Actual BYOK request must carry its protocol's system instructions") }
        return text
    }
    private static func contextTasks(_ instructions: String) throws -> [[String: Any]] {
        guard let start = instructions.range(of: "<caobao_untrusted_context>\n"),
              let end = instructions.range(of: "\n</caobao_untrusted_context>", range: start.upperBound..<instructions.endIndex),
              let data = String(instructions[start.upperBound..<end.lowerBound]).data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = json["tasks"] as? [[String: Any]] else {
            throw ChatTestFailure(description: "Actual BYOK request must contain parseable bounded task reference data")
        }
        return tasks
    }
    private static func checkContextTask(_ value: [String: Any], matches task: AssistantTask, meaning: String?) async throws {
        try await expect(value["id"] as? String == task.id && value["timeZone"] as? String == task.timeZone,
            "Context must preserve task identity and its recorded zone instead of the device zone")
        try await expect(value["recurrenceRule"] as? String == task.recurrenceRule && value["timeMeaning"] as? String == meaning,
            "Context must preserve the raw recurrence rule with the correct time meaning")
        try await expect(value["dueAt"] as? String == ISO8601DateFormatter().string(from: task.dueAt!),
            "Context must preserve the exact due instant; recurring template dates cannot be rewritten as next occurrences")
        try await expect(value["reminderEnabled"] as? Bool == task.reminderEnabled && value["requiresApproval"] as? Bool == true,
            "A task's reminder preference and required approval must remain distinct from authorization or delivery")
        let proofKeys: Set<String> = ["scheduled", "delivered", "scheduledAt", "deliveredAt", "nextReminderAt", "nextOccurrenceAt", "notificationId", "coverageUntil"]
        try await expect(proofKeys.isDisjoint(with: Set(value.keys)), "Reminder preference cannot synthesize evidence of notification scheduling, delivery or coverage")
    }

    private static func taskArguments(title: String = "Review the report", notes: String = "Original proposed notes",
                                      dueAt: Date? = nil, reminderRequested: Bool = false) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var value: [String: Any] = ["title": title, "notes": notes, "due_at": NSNull(),
            "time_zone": NSNull(), "reminder_requested": reminderRequested]
        if let dueAt { value["due_at"] = formatter.string(from: dueAt); value["time_zone"] = "UTC" }
        return String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    private static func taskFrame(_ value: [String: Any]) -> String {
        "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) + "\n\n"
    }
    private static func taskStream(_ kind: AssistantWireProtocol, arguments: String, name: String = "create_task") -> String {
        switch kind {
        case .chatCompletions:
            let cut = arguments.index(arguments.startIndex, offsetBy: arguments.count / 2)
            return taskFrame(["choices": [["index": 0, "delta": ["role": "assistant", "tool_calls": [["index": 0, "id": "task-chat-call", "type": "function", "function": ["name": name, "arguments": String(arguments[..<cut])]]]]]]])
                + taskFrame(["choices": [["index": 0, "delta": ["tool_calls": [["index": 0, "function": ["arguments": String(arguments[cut...])]]]]]]])
                + taskFrame(["choices": [["index": 0, "delta": [:], "finish_reason": "tool_calls"]], "usage": ["prompt_tokens": 8, "completion_tokens": 5]])
                + "data: [DONE]\n\n"
        case .responses:
            let reasoning: [String: Any] = ["type": "reasoning", "id": "task-reason", "summary": [["type": "summary_text", "text": "Consider a useful task."]], "encrypted_content": "opaque-task-reasoning"]
            let complete: [String: Any] = ["type": "function_call", "id": "task-fc", "call_id": "task-response-call", "name": name, "arguments": arguments, "status": "completed"]
            return taskFrame(["type": "response.output_item.added", "output_index": 0, "item": reasoning])
                + taskFrame(["type": "response.output_item.added", "output_index": 1, "item": ["type": "function_call", "id": "task-fc", "call_id": "task-response-call", "name": name, "arguments": "", "status": "in_progress"]])
                + taskFrame(["type": "response.function_call_arguments.delta", "output_index": 1, "item_id": "task-fc", "delta": arguments])
                + taskFrame(["type": "response.function_call_arguments.done", "output_index": 1, "item_id": "task-fc", "arguments": arguments])
                + taskFrame(["type": "response.output_item.done", "output_index": 1, "item": complete])
                + taskFrame(["type": "response.completed", "response": ["status": "completed", "output": [reasoning, complete], "usage": ["input_tokens": 8, "output_tokens": 5]]])
        case .anthropic:
            return taskFrame(["type": "message_start", "message": ["id": "task-a", "role": "assistant", "usage": ["input_tokens": 8]]])
                + taskFrame(["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]])
                + taskFrame(["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Consider a useful task."]])
                + taskFrame(["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "opaque-task-signature"]])
                + taskFrame(["type": "content_block_stop", "index": 0])
                + taskFrame(["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "task-anthropic-call", "name": name, "input": [:]]])
                + taskFrame(["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": arguments]])
                + taskFrame(["type": "content_block_stop", "index": 1])
                + taskFrame(["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 5]])
                + taskFrame(["type": "message_stop"])
        }
    }
    private static func taskPlainReply(_ kind: AssistantWireProtocol, _ text: String) -> String {
        switch kind {
        case .chatCompletions:
            return taskFrame(["choices": [["delta": ["content": text]]]]) + taskFrame(["choices": [["delta": [:], "finish_reason": "stop"]]]) + "data: [DONE]\n\n"
        case .responses:
            return taskFrame(["type": "response.output_text.delta", "delta": text]) + taskFrame(["type": "response.completed", "response": ["status": "completed", "output": [], "usage": ["input_tokens": 1, "output_tokens": 1]]])
        case .anthropic:
            return taskFrame(["type": "message_start", "message": ["id": "plain-a", "role": "assistant", "usage": ["input_tokens": 1]]])
                + taskFrame(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])
                + taskFrame(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]])
                + taskFrame(["type": "content_block_stop", "index": 0])
                + taskFrame(["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 1]])
                + taskFrame(["type": "message_stop"])
        }
    }
    private static func taskConfiguration(_ h: ChatHarness, kind: AssistantWireProtocol) -> BYOKConfiguration {
        BYOKConfiguration(baseURL: h.defaults.string(forKey: h.byokPrefix + "url")!, protocolKind: kind,
            model: h.defaults.string(forKey: h.byokPrefix + "model")!, apiKey: KeychainStore.read(account: "byok-api-key." + h.owner)!)
    }
    @discardableResult private static func enableTaskTools(_ h: ChatHarness, kind: AssistantWireProtocol) async throws -> String {
        h.defaults.set(kind.rawValue, forKey: h.byokPrefix + "protocol")
        let configuration = taskConfiguration(h, kind: kind)
        ChatFixtureURLProtocol.enqueue(.stream(taskStream(kind, arguments: "{\"ok\":true}", name: "caobao_task_probe")))
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [ChatFixtureURLProtocol.self]
        let probe = AssistantTaskToolCapabilityProbe(transport: AssistantStreamTransport(configuration: session))
        let fingerprint = try await probe.check(configuration: configuration)
        let expected = try configuration.consentIdentifier()
        try await expect(fingerprint == expected && ChatFixtureURLProtocol.captured.count == 1,
            "Tool permission is established by the real harmless capability probe over URLProtocol, never a fabricated success flag")
        try AssistantTaskToolPreferences.set(enabled: true, verifiedFingerprint: fingerprint, defaults: h.defaults, ownerId: h.owner)
        h.vm.generationConfigurationDidChange()
        ChatFixtureURLProtocol.reset()
        return fingerprint
    }
    private static func completedTaskProposal(_ h: ChatHarness, kind: AssistantWireProtocol = .chatCompletions,
                                              prompt: String = "Please propose a task for reviewing the report",
                                              arguments: String? = nil) async throws -> AssistantTaskProposal {
        try await enableTaskTools(h, kind: kind)
        ChatFixtureURLProtocol.enqueue(.stream(taskStream(kind, arguments: arguments ?? taskArguments())))
        h.vm.inputText = prompt; h.vm.sendMessage(userId: h.owner)
        if h.vm.requiresBYOKConfirmation { h.vm.confirmBYOKContext() }
        try await finished(h.vm)
        guard let proposal = h.vm.messages.last?.taskProposal else { throw ChatTestFailure(description: "A complete real tool stream must bind one persisted task proposal") }
        return proposal
    }
    private static func editedTask(_ proposal: AssistantTaskProposal, title: String? = nil, reminder: Bool = false) -> AssistantTask {
        AssistantTask(id: proposal.taskId, userId: proposal.ownerId, title: title ?? proposal.arguments.title,
            instructions: proposal.arguments.notes, dueAt: proposal.arguments.parsedDueDate,
            timeZone: proposal.arguments.timeZone ?? "UTC", recurrenceRule: nil, requiresApproval: true, status: .active,
            createdAt: Date(), updatedAt: Date(), reminderEnabled: reminder, sourceMessageId: proposal.assistantMessageId)
    }

    static func main() async throws {
        try await run("viewmodel-send-stream-metadata-and-persist") {
            let h = try await ChatHarness(); defer { h.close() }
            ChatFixtureURLProtocol.enqueue(.complete("Hello 世界"))
            try await send(h, "Plan my day")
            try await expect(h.vm.messages.count == 2 && h.vm.inputText.isEmpty, "Send must create one user/assistant pair and clear draft")
            let answer = h.vm.messages[1]
            try await expect(answer.content == "Hello 世界" && answer.generationId == "fixture-generation", "Actual stream text and metadata must reach the view model")
            try await expect(answer.usage?.inputTokens == 17 && answer.usage?.outputTokens == 5 && answer.model == "fixture-model", "Actual usage/model must survive")
            try await expect(!(answer.requestId ?? "").isEmpty, "A generation must retain its request identity")
            let usage = AssistantUsageStatsStore(defaults: h.defaults).snapshot(ownerId: h.owner)
            try await expect(usage.userMessages == 1 && usage.assistantMessages == 1 && usage.totalMessages == 2,
                             "A completed turn must update owner-scoped usage statistics")
            let saved = try h.archive.load(userId: h.owner)
            try await expect(saved.first?.messages == h.vm.messages, "Completed messages must be written to the injected archive")
            try await expect(!h.archive.isPrepared(userId: "ignored-untrusted-caller-id"), "Caller userId must never select a different archive owner")
            try await expect(ChatFixtureURLProtocol.captured[0].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key", "Injected test key must populate the real request header")
        }
        try await run("viewmodel-history-memory-task-require-consent-and-send-real-content") {
            let h = try await ChatHarness(); defer { h.close() }
            h.addMemory(text: "I prefer quiet morning planning")
            h.addMemory(text: "unconfirmed secret", consent: "inferred")
            h.addMemory(text: "other user secret", userId: "someone-else")
            let now = Date()
            h.repository.addTask(AssistantTask(id: "task-active", userId: h.owner, title: "Draft morning itinerary", instructions: "Use the park route",
                timeZone: "UTC", requiresApproval: true, status: .active, createdAt: now, updatedAt: now))
            h.repository.addTask(AssistantTask(id: "task-finished", userId: h.owner, title: "completed secret", timeZone: "UTC",
                requiresApproval: true, status: .completed, createdAt: now, updatedAt: now))
            let history = conversation(messages: [message(.user, "earlier question"), message(.assistant, "earlier answer"),
                message(.assistant, "failed secret", status: .failed)])
            try h.archive.upsert(history, userId: h.owner)
            (await h.vm.openConversation(history))
            h.vm.inputText = "Plan my morning"
            h.vm.sendMessage(userId: h.owner)
            try await expect(h.vm.requiresBYOKConfirmation && !h.vm.isLoading && ChatFixtureURLProtocol.captured.isEmpty, "No context may leave before explicit confirmation")
            try await expect(h.vm.messages.count == 3 && h.vm.inputText == "Plan my morning", "Consent prompt must leave the draft/history untouched")
            h.vm.confirmBYOKContext(); try await finished(h.vm)
            let payload = try body(), messages = payload["messages"] as! [[String: Any]]
            let instructions = messages[0]["content"] as! String
            try await expect(instructions.contains("quiet morning planning") && instructions.contains("Draft morning itinerary") && instructions.contains("Use the park route"), "Request must contain actual authorized memory/task text, not unresolved IDs")
            try await expect(!instructions.contains("unconfirmed secret") && !instructions.contains("other user secret") && !instructions.contains("completed secret"), "Unconfirmed, foreign and completed data must be excluded")
            try await expect(instructions.contains("<caobao_untrusted_context>") && instructions.contains("preferred locale: en"), "Reference boundary and injected locale must be present")
            let contents = messages.compactMap { $0["content"] as? String }
            try await expect(contents.suffix(3) == ["earlier question", "earlier answer", "Plan my morning"], "Completed history and current prompt must preserve order")
            try await expect(!contents.contains("failed secret"), "Failed assistant output must not be reused as completed context")
        }
        try await run("viewmodel-byok-recurring-task-context-preserves-wall-clock-and-preference-in-three-protocols") {
            for kind in AssistantWireProtocol.allCases {
                let h = try await ChatHarness(); defer { h.close() }
                h.defaults.set(kind.rawValue, forKey: h.byokPrefix + "protocol")
                let tasks = [contextTask(owner: h.owner, id: "daily-plan", rule: "FREQ=DAILY", zone: "Asia/Shanghai", reminder: true),
                    contextTask(owner: h.owner, id: "weekly-plan", rule: "FREQ=WEEKLY;BYDAY=MO,FR", zone: "America/Los_Angeles", reminder: false)]
                tasks.forEach(h.repository.addTask)
                let saved = h.repository.tasks(for: h.owner)
                try await expect(saved.count == 2 && h.repository.lastError == nil, "Both valid recurrence fixtures must persist through the real repository")
                h.vm.inputText = "Review my plans"; h.vm.sendMessage(userId: h.owner)
                try await expect(h.vm.requiresBYOKConfirmation && ChatFixtureURLProtocol.captured.isEmpty, "Recurring personal context cannot leave before BYOK confirmation")
                h.vm.confirmBYOKContext(); try await finished(h.vm)
                let instructions = try systemInstructions(body(), protocol: kind), values = try contextTasks(instructions)
                try await expect(values.count == tasks.count, "Both daily and weekly records must reach the actual BYOK request")
                for task in tasks {
                    guard let value = values.first(where: { $0["id"] as? String == task.id }) else { throw ChatTestFailure(description: "Missing recurring BYOK task") }
                    try await checkContextTask(value, matches: task, meaning: "wall-clock-template")
                }
                try await expect(instructions.contains("date is not a future start gate") && instructions.contains("Unsupported recurrence rules must not be guessed"),
                    "Actual BYOK instructions must explain recurring wall-clock semantics and reject guessing")
                try await expect(instructions.contains("reminderEnabled is only the user's preference, not proof of system scheduling or delivery")
                    && instructions.contains("unless a real tool confirmed success"), "The real model instructions cannot equate reminder preference with scheduled or delivered notifications")
                try await expect(h.repository.tasks(for: h.owner) == saved, "Sending context must not mutate schedules or reminder consent")
            }
        }
        try await run("viewmodel-platform-recurring-task-context-preserves-wall-clock-and-reminder-preference") {
            let h = try await ChatHarness(); defer { h.close() }
            h.defaults.set("platform", forKey: h.prefix + "assistantMode"); h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
            let tasks = [contextTask(owner: h.owner, id: "platform-daily", rule: "FREQ=DAILY", zone: "Asia/Shanghai", reminder: true),
                contextTask(owner: h.owner, id: "platform-weekly", rule: "FREQ=WEEKLY;BYDAY=TU,SU", zone: "Europe/Berlin", reminder: false)]
            tasks.forEach(h.repository.addTask)
            let saved = h.repository.tasks(for: h.owner)
            ChatFixtureURLProtocol.enqueue(.conversation("task-context-server")); ChatFixtureURLProtocol.enqueue(.complete("Review complete"))
            try await send(h, "Review my plans")
            let context = try body(1)["context"] as! [String: Any], values = context["tasks"] as! [[String: Any]]
            try await expect(values.count == tasks.count && Set(context["taskIds"] as! [String]) == Set(tasks.map(\.id)),
                "Platform context IDs and snapshots must refer to the same actual daily and weekly records")
            for task in tasks {
                guard let value = values.first(where: { $0["id"] as? String == task.id }) else { throw ChatTestFailure(description: "Missing recurring platform task") }
                try await checkContextTask(value, matches: task, meaning: "wall-clock-template")
            }
            try await expect(h.repository.tasks(for: h.owner) == saved, "Platform context construction must not change notification consent or execute tasks")
        }
        try await run("viewmodel-byok-legacy-unknown-rule-is-unsupported-and-one-shot-retains-absolute-due") {
            for kind in AssistantWireProtocol.allCases {
                let owner = "legacy-context-owner"
                let tasks = [contextTask(owner: owner, id: "legacy-monthly", rule: "FREQ=MONTHLY;BYMONTHDAY=1", zone: "Pacific/Auckland", reminder: true),
                    contextTask(owner: owner, id: "legacy-once", rule: nil, zone: "Asia/Tokyo", reminder: nil)]
                let h = try await ChatHarness(owner: owner, persistedTasks: tasks); defer { h.close() }
                h.defaults.set(kind.rawValue, forKey: h.byokPrefix + "protocol")
                try await expect(h.repository.tasks(for: owner).count == 2 && h.repository.lastError == nil, "Legacy fixtures must load from disk without being normalized through new-rule validation")
                h.vm.inputText = "Review existing plans"; h.vm.sendMessage(userId: owner)
                try await expect(h.vm.requiresBYOKConfirmation && ChatFixtureURLProtocol.captured.isEmpty, "Legacy task context also requires real BYOK consent")
                h.vm.confirmBYOKContext(); try await finished(h.vm)
                let values = try contextTasks(systemInstructions(body(), protocol: kind))
                try await expect(values.count == tasks.count, "Unsupported legacy rules cannot silently discard their task record")
                for task in tasks {
                    guard let value = values.first(where: { $0["id"] as? String == task.id }) else { throw ChatTestFailure(description: "Missing legacy BYOK task") }
                    // Older one-shot context omits timeMeaning; its exact due instant remains absolute.
                    try await checkContextTask(value, matches: task, meaning: task.recurrenceRule == nil ? nil : "unsupported-rule")
                }
            }
        }
        try await run("viewmodel-platform-legacy-unknown-rule-is-unsupported-and-one-shot-is-absolute-due") {
            let owner = "platform-legacy-owner"
            let tasks = [contextTask(owner: owner, id: "platform-legacy", rule: "FREQ=MONTHLY;BYMONTHDAY=1", zone: "Pacific/Auckland", reminder: true),
                contextTask(owner: owner, id: "platform-once", rule: nil, zone: "Asia/Tokyo", reminder: false)]
            let h = try await ChatHarness(owner: owner, persistedTasks: tasks); defer { h.close() }
            h.defaults.set("platform", forKey: h.prefix + "assistantMode"); h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
            ChatFixtureURLProtocol.enqueue(.conversation("legacy-context-server")); ChatFixtureURLProtocol.enqueue(.complete("Review complete"))
            try await send(h, "Review existing plans")
            let context = try body(1)["context"] as! [String: Any], values = context["tasks"] as! [[String: Any]]
            try await expect(values.count == tasks.count, "Platform must include both unsupported legacy and one-shot records")
            for task in tasks {
                guard let value = values.first(where: { $0["id"] as? String == task.id }) else { throw ChatTestFailure(description: "Missing legacy platform task") }
                try await checkContextTask(value, matches: task, meaning: task.recurrenceRule == nil ? "absolute-due" : "unsupported-rule")
            }
        }
        try await run("viewmodel-consent-reuse-and-endpoint-port-key-changes") {
            let h = try await ChatHarness(); defer { h.close() }
            h.addMemory(text: "consented personal context")
            h.vm.inputText = "first"; h.vm.sendMessage(userId: h.owner)
            try await expect(h.vm.requiresBYOKConfirmation, "Personal memory must require consent even with empty history")
            h.vm.confirmBYOKContext(); try await finished(h.vm)
            try await send(h, "same destination")
            let variants = [("https://api.example.com/tenant-b/v1", "fixture-key"),
                ("https://api.example.com:8443/tenant-b/v1", "fixture-key"),
                ("https://api.example.com:8443/tenant-b/v1", "second-fixture-key")]
            for (url, key) in variants {
                h.defaults.set(url, forKey: h.byokPrefix + "url")
                KeychainStore.set(key, account: "byok-api-key.\(h.owner)")
                let before = ChatFixtureURLProtocol.captured.count
                h.vm.inputText = "changed destination"; h.vm.sendMessage(userId: h.owner)
                try await expect(h.vm.requiresBYOKConfirmation && !h.vm.isLoading && ChatFixtureURLProtocol.captured.count == before, "Path, port and key changes must each block a new request")
                h.vm.confirmBYOKContext(); try await finished(h.vm)
                try await expect(ChatFixtureURLProtocol.captured.count == before + 1, "Confirmation must release exactly one request")
            }
        }
        try await run("viewmodel-reject-consent-preserves-user-draft") {
            let h = try await ChatHarness(); defer { h.close() }
            h.addMemory(text: "private preference")
            h.vm.inputText = "keep this draft"; h.vm.pendingImages = [try image()]
            h.vm.sendMessage(userId: h.owner); h.vm.rejectBYOKContext()
            try await expect(!h.vm.requiresBYOKConfirmation && h.vm.pendingDestination.isEmpty, "Reject must dismiss and clear pending destination")
            try await expect(h.vm.inputText == "keep this draft" && h.vm.pendingImages.count == 1 && h.vm.messages.isEmpty, "Rejection must retain draft and image without creating a conversation turn")
            h.vm.sendMessage(userId: h.owner)
            try await expect(h.vm.requiresBYOKConfirmation && ChatFixtureURLProtocol.captured.isEmpty, "Rejected consent must not silently become approval")
        }
        try await run("viewmodel-cancel-closes-network-and-keeps-partial-output") {
            let h = try await ChatHarness(); defer { h.close() }
            ChatFixtureURLProtocol.enqueue(.hold("partial reply"))
            h.vm.inputText = "long reply"; h.vm.sendMessage(userId: h.owner)
            try await wait("partial stream") { h.vm.messages.last?.content == "partial reply" }
            h.vm.cancel(); await h.vm.waitForPendingArchiveWrites()
            try await wait("underlying URLSession cancellation") { ChatFixtureURLProtocol.stoppedCount == 1 }
            try await expect(!h.vm.isLoading && h.vm.messages.last?.status == .cancelled && h.vm.messages.last?.content == "partial reply", "Stop must preserve partial content and reflect cancellation")
            try await expect(try h.archive.load(userId: h.owner).first?.messages.last?.status == .cancelled, "Cancellation status must be durably archived")
        }
        try await run("viewmodel-new-conversation-rejects-queued-old-stream") {
            let h = try await ChatHarness(); defer { h.close() }
            ChatFixtureURLProtocol.enqueue(.hold("old partial"))
            h.vm.inputText = "old request"; h.vm.sendMessage(userId: h.owner)
            try await wait("old stream") { h.vm.messages.last?.content == "old partial" }
            let oldId = h.vm.conversationId
            ChatFixtureURLProtocol.enqueueDelta(" old queued event")
            try await newConversation(h.vm)
            try await send(h, "new request")
            try await expect(h.vm.conversationId != oldId && h.vm.messages.count == 2, "New chat must isolate its conversation and messages")
            try await expect(h.vm.messages.last?.content == "fixture answer" && h.vm.error == nil, "An already-queued old event must not append or fail the new generation")
            try await wait("old request stopped") { ChatFixtureURLProtocol.stoppedCount >= 1 }
            let old = try h.archive.load(userId: h.owner).first { $0.id == oldId }
            try await expect(old?.messages.last?.status == .cancelled, "Old conversation retains its own cancelled generation")
        }
        try await run("viewmodel-account-switch-isolates-queued-stream-and-archive") {
            let h = try await ChatHarness(owner: "owner-a"); defer { h.close() }
            ChatFixtureURLProtocol.enqueue(.hold("account A partial"))
            h.vm.inputText = "private A question"; h.vm.sendMessage(userId: h.owner)
            try await wait("account A stream") { h.vm.messages.last?.content == "account A partial" }
            ChatFixtureURLProtocol.enqueueDelta(" queued A secret")
            try await h.configure(owner: "owner-b")
            AuthService.shared.user = ChatFixtureUser(id: "owner-b")
            h.vm.activateOwner()
            try await expect(h.vm.activeOwner == "owner-b" && h.vm.messages.isEmpty && h.vm.pendingImages.isEmpty, "Owner change must clear visible private state")
            try await send(h, "public B question")
            let b = try h.archive.load(userId: "owner-b")
            try await expect(b.first?.messages.map(\.content) == ["public B question", "fixture answer"], "Account B archive must contain only B turns")
            let a = try h.archive.load(userId: "owner-a")
            try await expect(a.first?.messages.first?.content == "private A question", "Switching accounts must preserve account A's archive")
            let payload = try body(1), wire = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
            try await expect(!wire.contains("private A") && !wire.contains("account A"), "Account B request must never transmit account A history")
        }
        try await run("viewmodel-open-history-recovers-interrupted-states-and-clears-images") {
            let h = try await ChatHarness(); defer { h.close() }
            h.vm.pendingImages = [try image()]
            let archived = conversation(messages: [message(.user, "question"), message(.assistant, "partial", status: .streaming),
                message(.assistant, "", status: .pending), message(.assistant, "finished")])
            try h.archive.upsert(archived, userId: h.owner)
            try await expect(!(await h.vm.openConversation(archived)), "An existing image draft requires explicit switching confirmation")
            guard let switchTicket = h.vm.pendingConversationSwitch else { throw ChatTestFailure(description: "Missing image-draft switch ticket") }
            try await expect((await h.vm.confirmConversationSwitch(switchTicket)), "Confirmed history opening must save the old image draft")
            try await expect(h.vm.messages.map(\.status) == [.completed, .failed, .failed, .completed] && !h.vm.isLoading, "Reopening history must not display a producer that no longer exists")
            try await expect(h.vm.messages[1].content == "partial" && h.vm.pendingImages.isEmpty, "Recover partial text and discard images belonging to the previous chat")
        }
        try await run("viewmodel-draft-and-interrupted-launch-restore") {
            let h = try await ChatHarness(); defer { h.close() }
            let interrupted = conversation(messages: [message(.user, "saved question"), message(.assistant, "saved partial", status: .streaming)])
            try h.archive.upsert(interrupted, userId: h.owner)
            let image = try image()
            try h.archive.saveDraft("restored input", images: [image], conversationId: interrupted.id, userId: h.owner)
            let restored = ChatViewModel(archive: h.archive, transport: h.transport, conversationClient: h.conversationClient, repository: h.repository, defaults: h.defaults)
            try await restored.waitForArchiveReady(ownerId: h.owner)
            defer { restored.cancel() }
            try await expect(restored.conversationId == interrupted.id && restored.messages.last?.status == .failed, "Fresh production view model must normalize interrupted archived generation")
            try await expect(restored.inputText == "restored input" && restored.pendingImages == [image], "Text/image draft must restore for the same conversation and owner")
        }
        try await run("viewmodel-queued-image-selection-cannot-cross-conversation") {
            let h = try await ChatHarness(); defer { h.close() }
            let staleConversation = h.vm.conversationId
            let bytes = try image().data!
            try await newConversation(h.vm)
            await h.vm.addImageData(bytes, ownerId: h.owner, conversationId: staleConversation)
            try await expect(h.vm.pendingImages.isEmpty && !h.vm.isPreparingImage, "A delayed picker callback must not attach old-chat images to a new chat")
            await h.vm.addImageData(bytes, ownerId: "another-user", conversationId: h.vm.conversationId)
            try await expect(h.vm.pendingImages.isEmpty, "A delayed old-owner selection must not attach to the current account")
        }
        try await run("viewmodel-valid-image-sends-structured-inline-content") {
            let h = try await ChatHarness(); defer { h.close() }
            let picture = try image()
            await h.vm.addImageData(picture.data!, ownerId: h.owner, conversationId: h.vm.conversationId)
            try await expect(h.vm.pendingImages.count == 1 && !h.vm.isPreparingImage, "Actual image preparation must finish before send")
            h.vm.inputText = ""; h.vm.sendMessage(userId: h.owner); try await finished(h.vm)
            let payload = try body(), messages = payload["messages"] as! [[String: Any]]
            let parts = messages.last?["content"] as! [[String: Any]]
            let imagePart = parts.first { $0["type"] as? String == "image_url" }
            let url = (imagePart?["image_url"] as? [String: String])?["url"]
            try await expect(url?.hasPrefix("data:image/jpeg;base64,") == true, "The actual media must be inline with no public-upload fallback")
            try await expect(h.vm.messages.first?.images?.count == 1 && h.vm.pendingImages.isEmpty, "Image belongs to the persisted user turn after sending")
            try await expect(h.vm.messages.first?.content == "Please analyze this image.", "Image-only prompt must respect injected preferred locale")
        }
        try await run("viewmodel-validation-and-http-errors-are-visible") {
            let h = try await ChatHarness(); defer { h.close() }
            h.vm.inputText = String(repeating: "x", count: 20_001); h.vm.sendMessage(userId: h.owner)
            try await expect(h.vm.error != nil && h.vm.messages.isEmpty && ChatFixtureURLProtocol.captured.isEmpty, "Overlong prompts must fail before creating a turn or network request")
            ChatFixtureURLProtocol.enqueue(.httpError)
            h.vm.inputText = "server unavailable"; h.vm.sendMessage(userId: h.owner)
            try await wait("HTTP failure") { !h.vm.isLoading }
            try await expect(h.vm.messages.last?.status == .failed && h.vm.error != nil, "HTTP failures must end loading and mark the assistant turn failed")
            try await expect(!(h.vm.error ?? "").contains("private upstream detail"), "Upstream details must not be exposed as user-visible errors")
        }
        try await run("viewmodel-regeneration-uses-new-request-and-single-user-turn") {
            let h = try await ChatHarness(); defer { h.close() }
            try await send(h, "regenerate me")
            let first = h.vm.messages.last!
            ChatFixtureURLProtocol.enqueue(.complete("replacement"))
            h.vm.regenerate(first.id, userId: h.owner); try await finished(h.vm)
            try await expect(h.vm.messages.count == 2 && h.vm.messages.last?.content == "replacement", "Regeneration must replace the assistant turn without duplicating the question")
            try await expect(h.vm.messages.last?.requestId != first.requestId, "Explicit regeneration must create a new idempotency identity")
            let messages = try body(1)["messages"] as! [[String: Any]]
            try await expect(messages.count == 2 && messages.last?["content"] as? String == "regenerate me", "Regeneration context must omit the answer being replaced")
        }
        try await run("viewmodel-three-protocol-request-paths-and-schemas") {
            for kind in AssistantWireProtocol.allCases {
                let h = try await ChatHarness(); defer { h.close() }
                h.defaults.set(kind.rawValue, forKey: h.byokPrefix + "protocol")
                try await send(h, "protocol question")
                let request = ChatFixtureURLProtocol.captured[0], payload = try body()
                switch kind {
                case .chatCompletions:
                    try await expect(request.url?.path.hasSuffix("/chat/completions") == true && payload["messages"] != nil, "Chat must use its own path and messages schema")
                case .responses:
                    try await expect(request.url?.path.hasSuffix("/responses") == true && payload["input"] != nil && payload["store"] as? Bool == false, "Responses must use its path/input and disable storage")
                case .anthropic:
                    try await expect(request.url?.path.hasSuffix("/messages") == true && payload["system"] != nil && request.value(forHTTPHeaderField: "x-api-key") == "fixture-key", "Anthropic must use its path/system and x-api-key header")
                }
            }
        }
        try await run("viewmodel-platform-creates-server-conversation-with-preferred-locale-and-reuses-id") {
            let h = try await ChatHarness(); defer { h.close() }
            h.defaults.set("platform", forKey: h.prefix + "assistantMode")
            h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
            h.defaults.set("zh-Hans", forKey: h.prefix + "language")
            h.addMemory(text: "platform context preference")
            let localId = h.vm.conversationId
            ChatFixtureURLProtocol.enqueue(.conversation("server-conversation_1"))
            ChatFixtureURLProtocol.enqueue(.complete("platform answer"))
            let prompt = String(repeating: "用", count: 50)
            try await send(h, prompt)
            let requests = ChatFixtureURLProtocol.captured
            try await expect(requests.count == 2 && requests[0].url?.path == "/api/v2/conversations", "Platform mode must create a real server conversation before streaming")
            try await expect(requests[0].value(forHTTPHeaderField: "Idempotency-Key") == "conversation." + localId, "Conversation creation idempotency must bind to the local conversation")
            try await expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token", "Creation must receive the refreshed access token")
            let creation = try body(0)
            try await expect(creation["clientConversationId"] as? String == localId && creation["title"] as? String == String(prompt.prefix(40)), "Creation must send its own local ID and bounded actual title")
            try await expect(creation["locale"] as? String == "zh-Hans", "Creation must use the app's selected language rather than the device language")
            try await expect(requests[1].url?.path == "/api/v2/conversations/server-conversation_1/messages", "Generation must route by the server-assigned ID")
            let generation = try body(1), context = generation["context"] as! [String: Any]
            try await expect(generation["conversationId"] as? String == "server-conversation_1" && generation["clientConversationId"] as? String == localId,
                "Generation URL/body must share the server ID while retaining the local conversation association")
            try await expect((context["memories"] as? [[String: String]])?.first?["text"] == "platform context preference", "Platform requests must include authorized local memory snapshots")
            try await expect(try h.archive.load(userId: h.owner).first?.serverConversationId == "server-conversation_1", "The server ID must persist with the local conversation")
            ChatFixtureURLProtocol.enqueue(.complete("second platform answer"))
            try await send(h, "follow up")
            try await expect(ChatFixtureURLProtocol.captured.count == 3 && ChatFixtureURLProtocol.captured.last?.url?.path == "/api/v2/conversations/server-conversation_1/messages", "Follow-up messages must reuse the server conversation without another creation")
            let followUp = try body(2)
            try await expect(followUp["conversationId"] as? String == "server-conversation_1" && followUp["clientConversationId"] as? String == localId,
                "Follow-up JSON must preserve the same verified server/local ID association")
        }
        try await run("viewmodel-platform-invalid-server-id-blocks-generation") {
            let h = try await ChatHarness(); defer { h.close() }
            h.defaults.set("platform", forKey: h.prefix + "assistantMode")
            h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
            ChatFixtureURLProtocol.enqueue(.conversation("unsafe/id"))
            h.vm.inputText = "must not stream"; h.vm.sendMessage(userId: h.owner)
            try await wait("invalid creation failure") { !h.vm.isLoading }
            try await expect(h.vm.messages.last?.status == .failed && h.vm.error != nil, "An invalid creation response must leave a visible failed generation")
            try await expect(ChatFixtureURLProtocol.captured.count == 1, "Invalid server identifiers must never be appended to a generation URL")
        }
        try await run("viewmodel-platform-cancel-during-creation-cannot-route-new-chat") {
            let h = try await ChatHarness(); defer { h.close() }
            h.defaults.set("platform", forKey: h.prefix + "assistantMode")
            h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
            ChatFixtureURLProtocol.enqueue(.holdConversation)
            h.vm.inputText = "old platform request"; h.vm.sendMessage(userId: h.owner)
            try await wait("creation started") { ChatFixtureURLProtocol.captured.count == 1 }
            try await newConversation(h.vm)
            try await wait("creation cancellation") { ChatFixtureURLProtocol.stoppedCount >= 1 }
            ChatFixtureURLProtocol.enqueue(.conversation("new-server-id"))
            ChatFixtureURLProtocol.enqueue(.complete("new platform answer"))
            try await send(h, "new platform request")
            try await expect(h.vm.messages.map(\.content) == ["new platform request", "new platform answer"], "A cancelled old creation must not mutate a new chat")
            try await expect(ChatFixtureURLProtocol.captured.count == 3 && ChatFixtureURLProtocol.captured.last?.url?.path == "/api/v2/conversations/new-server-id/messages", "Only the new conversation may start a generation")
        }
        try await run("viewmodel-platform-owner-switch-during-creation-isolates-server-id") {
            let h = try await ChatHarness(owner: "platform-owner-a"); defer { h.close() }
            h.defaults.set("platform", forKey: h.prefix + "assistantMode")
            h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
            ChatFixtureURLProtocol.enqueue(.holdConversation)
            h.vm.inputText = "A pending creation"; h.vm.sendMessage(userId: h.owner)
            try await wait("A creation started") { ChatFixtureURLProtocol.captured.count == 1 }
            let ownerB = "platform-owner-b"
            try await h.configure(owner: ownerB)
            let prefixB = "caobao.assistant.\(Data(ownerB.utf8).base64EncodedString())."
            h.defaults.set("platform", forKey: prefixB + "assistantMode")
            h.defaults.set(true, forKey: prefixB + "regionConfirmed")
            AuthService.shared.user = ChatFixtureUser(id: ownerB)
            h.vm.activateOwner()
            try await wait("A creation cancelled on owner change") { ChatFixtureURLProtocol.stoppedCount >= 1 }
            ChatFixtureURLProtocol.enqueue(.conversation("owner-b-server-id"))
            ChatFixtureURLProtocol.enqueue(.complete("B answer"))
            try await send(h, "B question")
            try await expect(try h.archive.load(userId: ownerB).first?.serverConversationId == "owner-b-server-id", "Only B's successful creation may bind to B's local archive")
            try await expect(h.vm.messages.map(\.content) == ["B question", "B answer"] && ChatFixtureURLProtocol.captured.count == 3, "Old owner creation must not start a request or insert a turn for the new owner")
        }
        try await run("viewmodel-platform-cn-intl-manual-models-reach-wire-and-archive") {
            for (region, model) in [("CN", "provider/cn-model:version.1"), ("INTL", "provider/intl-model:version.2")] {
                let h = try await ChatHarness(); defer { h.close() }
                h.defaults.set("platform", forKey: h.prefix + "assistantMode")
                h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
                h.defaults.set(region, forKey: h.prefix + "serviceRegion")
                try AssistantModelPreferences.save(model, ownerId: h.owner, region: region, defaults: h.defaults)
                ChatFixtureURLProtocol.enqueue(.conversation("server-" + region))
                ChatFixtureURLProtocol.enqueue(.complete("regional model answer"))
                try await send(h, "Choose the selected regional model")
                let payload = try body(1)
                try await expect(payload["serviceRegion"] as? String == region && payload["model"] as? String == model,
                    "Confirmed CN/INTL and the full provider/model:version identifier must reach the actual request")
                try await expect(h.vm.messages.last?.model == model,
                    "The selected regional model must be retained on the assistant turn")
                try await expect(try h.archive.load(userId: h.owner).first?.messages.last?.model == model,
                    "The selected model must persist in the actual conversation archive")
            }
        }
        try await run("viewmodel-platform-automatic-selection-omits-model-from-wire-and-archive") {
            for region in ["CN", "INTL"] {
                let h = try await ChatHarness(); defer { h.close() }
                h.defaults.set("platform", forKey: h.prefix + "assistantMode")
                h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
                h.defaults.set(region, forKey: h.prefix + "serviceRegion")
                try AssistantModelPreferences.save("selected-then-cleared", ownerId: h.owner, region: region, defaults: h.defaults)
                try AssistantModelPreferences.save("", ownerId: h.owner, region: region, defaults: h.defaults)
                ChatFixtureURLProtocol.enqueue(.conversation("automatic-" + region))
                ChatFixtureURLProtocol.enqueue(.complete("server chooses model"))
                try await send(h, "Use the regional default")
                let payload = try body(1)
                try await expect(payload["serviceRegion"] as? String == region && !payload.keys.contains("model"),
                    "Automatic mode must send the confirmed region and omit the model field entirely")
                try await expect(h.vm.messages.last?.model == nil && (try h.archive.load(userId: h.owner)).first?.messages.last?.model == nil,
                    "Automatic mode must not invent a selected model in memory or on disk")
                try await expect(h.defaults.object(forKey: AssistantModelPreferences.key(ownerId: h.owner, region: region)) == nil,
                    "Saving automatic must remove the persisted selection rather than storing an empty model")
            }
        }
        try await run("viewmodel-platform-unconfirmed-or-invalid-region-blocks-all-network") {
            let h = try await ChatHarness(); defer { h.close() }
            h.defaults.set("platform", forKey: h.prefix + "assistantMode")
            let cases: [(Bool, String?)] = [(false, "CN"), (false, "INTL"), (true, nil), (true, ""),
                (true, "cn"), (true, "US"), (true, "CN "), (true, "INTL\n")]
            for (confirmed, region) in cases {
                h.defaults.set(confirmed, forKey: h.prefix + "regionConfirmed")
                if let region { h.defaults.set(region, forKey: h.prefix + "serviceRegion") }
                else { h.defaults.removeObject(forKey: h.prefix + "serviceRegion") }
                h.vm.inputText = "Keep this pending regional request"
                h.vm.sendMessage(userId: h.owner)
                try await expect(!h.vm.isLoading && h.vm.messages.isEmpty && h.vm.error != nil,
                    "Unconfirmed, absent or invalid regions must fail before a generation is started")
                try await expect(h.vm.inputText == "Keep this pending regional request" && ChatFixtureURLProtocol.captured.isEmpty,
                    "Region validation must preserve the user's draft and prevent both creation and generation requests")
            }
        }
        try await run("viewmodel-platform-model-preferences-isolate-region-and-owner") {
            let h = try await ChatHarness(owner: "regional-owner-a"); defer { h.close() }
            h.defaults.set("platform", forKey: h.prefix + "assistantMode")
            h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
            try AssistantModelPreferences.save("provider/a-cn:v1", ownerId: h.owner, region: "CN", defaults: h.defaults)
            try AssistantModelPreferences.save("provider/a-intl:v2", ownerId: h.owner, region: "INTL", defaults: h.defaults)
            ChatFixtureURLProtocol.enqueue(.conversation("server-owner-a"))
            ChatFixtureURLProtocol.enqueue(.complete("A CN answer"))
            try await send(h, "A CN question")
            let aCN = try body(1)
            try await expect(aCN["serviceRegion"] as? String == "CN" && aCN["model"] as? String == "provider/a-cn:v1",
                "Owner A CN must use only the CN selection")
            h.defaults.set("INTL", forKey: h.prefix + "serviceRegion")
            ChatFixtureURLProtocol.enqueue(.complete("A INTL answer"))
            try await send(h, "A INTL question")
            let aIntl = try body(2)
            try await expect(aIntl["serviceRegion"] as? String == "INTL" && aIntl["model"] as? String == "provider/a-intl:v2",
                "Switching region must select that region's model while reusing the existing server conversation")

            let ownerB = "regional-owner-b"
            try await h.configure(owner: ownerB)
            let prefixB = "caobao.assistant.\(Data(ownerB.utf8).base64EncodedString())."
            h.defaults.set("platform", forKey: prefixB + "assistantMode")
            h.defaults.set(true, forKey: prefixB + "regionConfirmed")
            AuthService.shared.user = ChatFixtureUser(id: ownerB)
            h.vm.activateOwner()
            ChatFixtureURLProtocol.enqueue(.conversation("server-owner-b"))
            ChatFixtureURLProtocol.enqueue(.complete("B automatic CN answer"))
            try await send(h, "B CN question")
            let bCN = try body(4)
            try await expect(bCN["serviceRegion"] as? String == "CN" && !bCN.keys.contains("model") && h.vm.messages.last?.model == nil,
                "Owner B without a selection must use automatic mode, never owner A's saved CN model")
            try AssistantModelPreferences.save("provider/b-intl:v3", ownerId: ownerB, region: "INTL", defaults: h.defaults)
            h.defaults.set("INTL", forKey: prefixB + "serviceRegion")
            ChatFixtureURLProtocol.enqueue(.complete("B INTL answer"))
            try await send(h, "B INTL question")
            let bIntl = try body(5)
            try await expect(bIntl["model"] as? String == "provider/b-intl:v3", "Owner B's INTL request must use B's own selection")

            h.defaults.set("CN", forKey: h.prefix + "serviceRegion")
            AuthService.shared.user = ChatFixtureUser(id: h.owner)
            h.vm.activateOwner()
            ChatFixtureURLProtocol.enqueue(.complete("A restored CN answer"))
            try await send(h, "A returns")
            let restored = try body(6)
            try await expect(restored["model"] as? String == "provider/a-cn:v1" && restored["serviceRegion"] as? String == "CN",
                "Returning to owner A must restore A's CN selection without inheriting B's INTL model")
            try await expect(ChatFixtureURLProtocol.captured.count == 7, "Only the two owners' initial conversations may be created")
        }
        try await run("model-preferences-save-remove-invalid-and-owner-region-isolation") {
            let h = try await ChatHarness(); defer { h.close() }
            let a = "preference-owner-a", b = "preference-owner-b"
            let values = [(a, "CN", "provider/model:version.1"), (a, "INTL", "a-intl/model:v2"),
                (b, "CN", "b-cn/model:v3"), (b, "INTL", "b-intl/model:v4")]
            for (owner, region, model) in values {
                try AssistantModelPreferences.save(model, ownerId: owner, region: region, defaults: h.defaults)
            }
            for (owner, region, model) in values {
                try await expect(AssistantModelPreferences.selectedModel(ownerId: owner, region: region, defaults: h.defaults) == model,
                    "Every owner/region pair must independently retain its own model")
            }
            for invalid in ["contains space", "model\nheader", "模型", "model?key=secret", String(repeating: "x", count: 129)] {
                do {
                    try AssistantModelPreferences.save(invalid, ownerId: a, region: "CN", defaults: h.defaults)
                    throw ChatTestFailure(description: "Invalid model identifier must be rejected")
                } catch is AssistantModelPreferences.InvalidSelection { }
                try await expect(AssistantModelPreferences.selectedModel(ownerId: a, region: "CN", defaults: h.defaults) == "provider/model:version.1",
                    "Invalid save must leave the previous valid selection intact")
            }
            for (owner, region) in [("", "CN"), (a, "US"), (a, "cn")] {
                do {
                    try AssistantModelPreferences.save("valid/model:v1", ownerId: owner, region: region, defaults: h.defaults)
                    throw ChatTestFailure(description: "Empty owner or invalid region must be rejected")
                } catch is AssistantModelPreferences.InvalidSelection { }
                try await expect(AssistantModelPreferences.selectedModel(ownerId: owner, region: region, defaults: h.defaults).isEmpty,
                    "Invalid preference scopes must not return an unrelated model")
            }
            try AssistantModelPreferences.save("", ownerId: a, region: "CN", defaults: h.defaults)
            try await expect(h.defaults.object(forKey: AssistantModelPreferences.key(ownerId: a, region: "CN")) == nil,
                "Automatic selection must remove its exact scoped key")
            try await expect(AssistantModelPreferences.selectedModel(ownerId: a, region: "INTL", defaults: h.defaults) == "a-intl/model:v2"
                && AssistantModelPreferences.selectedModel(ownerId: b, region: "CN", defaults: h.defaults) == "b-cn/model:v3",
                "Removing one selection must preserve other regions and owners")
            let boundary = String(repeating: "a", count: 128)
            try AssistantModelPreferences.save(boundary, ownerId: a, region: "CN", defaults: h.defaults)
            try await expect(AssistantModelPreferences.selectedModel(ownerId: a, region: "CN", defaults: h.defaults) == boundary,
                "The valid 128-byte model identifier boundary must round trip")
            h.defaults.set("corrupted model value", forKey: AssistantModelPreferences.key(ownerId: a, region: "CN"))
            try await expect(AssistantModelPreferences.selectedModel(ownerId: a, region: "CN", defaults: h.defaults).isEmpty,
                "An externally corrupted persisted selection must fall back to automatic instead of reaching the wire")
        }
        try await run("viewmodel-export-flush-persists-latest-unsaved-draft-and-images") {
            let h = try await ChatHarness(); defer { h.close() }
            let picture = try image()
            let selectedConversation = h.vm.conversationId
            h.vm.inputText = "  Latest unsaved export draft\n"
            h.vm.pendingImages = [picture]
            try await expect(try h.archive.loadDraftRecord(userId: h.owner).text.isEmpty,
                "Fixture must exercise draft state that has not yet reached the archive")
            try await h.vm.flushForDataExport(ownerId: h.owner)
            let draft = try h.archive.loadDraftRecord(userId: h.owner)
            try await expect(draft.text == "  Latest unsaved export draft\n" && draft.images == [picture] && draft.conversationId == selectedConversation,
                "Export flush must persist exact latest text, attachment and conversation association")
            try await expect(h.vm.inputText == draft.text && h.vm.pendingImages == [picture] && h.vm.conversationId == selectedConversation && h.vm.messages.isEmpty,
                "Export flush must not alter draft, attachments, selected conversation or messages")
            try await expect(try h.archive.load(userId: h.owner).isEmpty, "An empty conversation must not be invented solely for export")
            try await expect(ChatFixtureURLProtocol.captured.isEmpty && !h.vm.isLoading, "Export flush must not start any network request")
        }
        try await run("viewmodel-export-flush-persists-unsaved-stream-without-stopping-generation") {
            let h = try await ChatHarness(); defer { h.close() }
            h.defaults.set("platform", forKey: h.prefix + "assistantMode")
            h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
            ChatFixtureURLProtocol.enqueue(.conversation("export-server-id"))
            ChatFixtureURLProtocol.enqueue(.hold("first partial"))
            h.vm.inputText = "Stream while exporting"; h.vm.sendMessage(userId: h.owner)
            try await wait("initial export stream") { h.vm.messages.last?.content == "first partial" }
            await h.vm.waitForPendingArchiveWrites()
            guard let initialArchive = try h.archive.load(userId: h.owner).first else {
                throw ChatTestFailure(description: "The initial live stream must really be persisted before testing a newer unsaved delta")
            }
            try await expect(initialArchive.messages.last?.content == "first partial" && initialArchive.serverConversationId == "export-server-id",
                "The unsaved-delta fixture starts from the actual persisted partial and verified server identity")
            // Do not drain inside this loop: it deliberately observes a later, genuinely unsaved delta.
            var hasUnsavedDelta = false
            for index in 0..<5 {
                let previous = h.vm.messages.last!.content
                ChatFixtureURLProtocol.enqueueDelta(" latest-\(index)", requestIndex: 1)
                try await wait("new unsaved stream delta") { h.vm.messages.last?.content != previous }
                if try h.archive.load(userId: h.owner).first?.messages.last?.content != h.vm.messages.last?.content {
                    hasUnsavedDelta = true; break
                }
            }
            try await expect(hasUnsavedDelta, "Fixture must observe a real delta newer than the automatic archive throttle")
            h.vm.inputText = "Unsent follow-up draft"
            let expectedMessages = h.vm.messages, selectedConversation = h.vm.conversationId
            let requests = ChatFixtureURLProtocol.captured.count, stopped = ChatFixtureURLProtocol.stoppedCount
            try await h.vm.flushForDataExport(ownerId: h.owner)
            let saved = try h.archive.load(userId: h.owner).first
            try await expect(saved?.messages == expectedMessages && saved?.serverConversationId == "export-server-id",
                "Flush must capture exact latest partial text, statuses, metadata and server conversation ID")
            try await expect(try h.archive.loadDraftRecord(userId: h.owner).text == "Unsent follow-up draft",
                "The latest next-message draft must also reach disk during streaming")
            try await expect(h.vm.isLoading && h.vm.messages.last?.status == .streaming && h.vm.messages == expectedMessages
                && h.vm.conversationId == selectedConversation && h.vm.inputText == "Unsent follow-up draft",
                "Flush must not cancel or mutate the live generation or selected UI state")
            try await expect(ChatFixtureURLProtocol.captured.count == requests && ChatFixtureURLProtocol.stoppedCount == stopped,
                "Flush must neither make a new request nor close the existing stream")
            ChatFixtureURLProtocol.enqueueDelta(" after-export", requestIndex: 1)
            try await wait("generation continues after export") { h.vm.messages.last?.content.hasSuffix(" after-export") == true }
            try await expect(h.vm.isLoading, "The same producer must remain active after an export flush")
        }
        try await run("viewmodel-export-flush-rejects-wrong-owner-without-any-file-write") {
            let h = try await ChatHarness(owner: "export-owner-a")
            defer { AuthService.shared.user = ChatFixtureUser(id: h.owner); h.close() }
            try h.archive.upsert(conversation(messages: [message(.user, "A existing source")]), userId: h.owner)
            try h.archive.saveDraft("A original draft", userId: h.owner)
            try await h.archive.prepareAsync(userId: "export-owner-b")
            try h.archive.upsert(conversation(messages: [message(.user, "B existing source")]), userId: "export-owner-b")
            try h.archive.saveDraft("B original draft", userId: "export-owner-b")
            h.vm.messages = [message(.user, "A unsaved private input")]
            h.vm.inputText = "A unsaved draft"; h.vm.pendingImages = [try image()]
            let before = try archiveFiles(h), selectedConversation = h.vm.conversationId, expectedMessages = h.vm.messages
            for owner in ["", "export-owner-b", "unknown-owner"] {
                let error = try await failure { try await h.vm.flushForDataExport(ownerId: owner) }
                guard case .ownerChanged = error as? AssistantHistoryOperationError else {
                    throw ChatTestFailure(description: "Wrong export owner must receive a visible configuration error")
                }
            }
            AuthService.shared.user = ChatFixtureUser(id: "export-owner-b") // Deliberately before activateOwner().
            for owner in [h.owner, "export-owner-b"] {
                _ = try await failure { try await h.vm.flushForDataExport(ownerId: owner) }
            }
            try await expect(try archiveFiles(h) == before, "Wrong owner or stale activeOwner must leave both users' source files byte-for-byte intact")
            try await expect(h.vm.messages == expectedMessages && h.vm.inputText == "A unsaved draft"
                && h.vm.pendingImages.count == 1 && h.vm.conversationId == selectedConversation,
                "Owner rejection must not mutate the current private UI state")
            try await expect(ChatFixtureURLProtocol.captured.isEmpty, "Owner rejection must never fall back to a server export or chat request")
        }
        try await run("viewmodel-export-flush-throws-on-corrupt-conversation-and-preserves-source") {
            let h = try await ChatHarness(); defer { h.close() }
            let selected = h.vm.conversationId
            try h.archive.upsert(conversation(id: selected, messages: [message(.user, "previous source")]), userId: h.owner)
            try h.archive.saveDraft("previous draft source", conversationId: selected, userId: h.owner)
            try sql(h, "UPDATE bodies SET payload=? WHERE id=?", [.blob(Data("corrupt body".utf8)), .text(selected)])
            let before = try archiveFiles(h)
            h.vm.messages = [message(.user, "current unsaved question"), message(.assistant, "current answer")]
            h.vm.inputText = "new draft must not hide corruption"
            let visible = h.vm.messages
            _ = try await failure { try await h.vm.flushForDataExport(ownerId: h.owner) }
            try await expect(try archiveFiles(h) == before && h.archive.loadDraft(userId: h.owner) == "previous draft source", "Corrupt existing body must fail closed and roll back the complete export flush")
            try await expect(h.vm.messages == visible && h.vm.conversationId == selected && h.vm.inputText == "new draft must not hide corruption", "Flush failure preserves unsaved UI state")
        }
        try await run("viewmodel-export-flush-throws-on-corrupt-draft-and-preserves-source") {
            let h = try await ChatHarness(); defer { h.close() }
            let selected = h.vm.conversationId
            try h.archive.saveDraft("previous draft", conversationId: selected, userId: h.owner)
            try sql(h, "UPDATE drafts SET payload=? WHERE conversation_id=?", [.blob(Data("corrupt draft".utf8)), .text(selected)])
            let before = try archiveFiles(h)
            h.vm.messages = [message(.user, "snapshot question"), message(.assistant, "snapshot answer")]
            h.vm.inputText = "latest unsaved draft"; h.vm.pendingImages = [try image()]
            let visible = h.vm.messages
            _ = try await failure { try await h.vm.flushForDataExport(ownerId: h.owner) }
            try await expect(try archiveFiles(h) == before, "A later corrupt draft failure rolls back the preceding conversation upsert in the same SQL transaction")
            try await expect(h.vm.messages == visible && h.vm.inputText == "latest unsaved draft" && h.vm.pendingImages.count == 1 && h.vm.conversationId == selected, "A later failure preserves complete visible recovery state")
        }
        try await run("viewmodel-export-flush-propagates-filesystem-write-failure") {
            let fault = ChatFixtureArchiveFault()
            let h = try await ChatHarness(archiveFault: { try fault.check($0, owner: $1) }); defer { h.close(); fault.arm(nil) }
            h.vm.messages = [message(.user, "unsaved filesystem failure question")]; h.vm.inputText = "retain this draft"
            let before = try archiveFiles(h)
            fault.arm(.beforeCommit)
            _ = try await failure { try await h.vm.flushForDataExport(ownerId: h.owner) }
            fault.arm(nil)
            try await expect(try archiveFiles(h) == before && h.archive.load(userId: h.owner).isEmpty, "Actual SQLite transaction write failure rolls back all writes")
            try await expect(h.vm.inputText == "retain this draft" && h.vm.messages.first?.content == "unsaved filesystem failure question" && ChatFixtureURLProtocol.captured.isEmpty, "Local failure retains the unsaved state without network fallback")
        }
        try await run("viewmodel-delete-current-completed-history-does-not-resurrect") {
            let h = try await ChatHarness(); defer { h.close() }
            try await send(h, "completed source to delete")
            let deleted = h.vm.conversationId
            h.vm.inputText = "pending current draft"; h.vm.pendingImages = [try image()]
            h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            try await h.vm.deleteConversations(ids: [deleted], ownerId: h.owner)
            try await expect(h.vm.conversationId != deleted && h.vm.messages.isEmpty && h.vm.inputText.isEmpty
                && h.vm.pendingImages.isEmpty, "Deleting the selected conversation must reset only its selected state after disk success")
            h.vm.cancel(); await h.vm.waitForPendingArchiveWrites(); await h.vm.loadConversationsFromHistory()
            try await expect(try h.archive.load(userId: h.owner).isEmpty && h.vm.conversations.isEmpty,
                "Subsequent cancellation/reload must not recreate the deleted completed conversation")
            let draft = try h.archive.loadDraftRecord(userId: h.owner)
            try await expect(draft.text.isEmpty && draft.conversationId == h.vm.conversationId && (draft.images ?? []).isEmpty,
                "The old selected draft must not restore the deleted ID on restart")
        }
        try await run("viewmodel-delete-current-live-stream-rejects-late-delta-and-cancels-producer") {
            let h = try await ChatHarness(); defer { h.close() }
            ChatFixtureURLProtocol.enqueue(.hold("deleted partial"))
            h.vm.inputText = "delete this active request"; h.vm.sendMessage(userId: h.owner)
            try await wait("current deletion partial") { h.vm.messages.last?.content == "deleted partial" }
            let deleted = h.vm.conversationId
            h.vm.inputText = "unsent current draft"; h.vm.pendingImages = [try image()]; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            ChatFixtureURLProtocol.enqueueDelta(" queued after deletion")
            try await h.vm.deleteConversations(ids: [deleted], ownerId: h.owner)
            try await wait("deleted stream producer stopped") { ChatFixtureURLProtocol.stoppedCount >= 1 }
            try await Task.sleep(nanoseconds: 20_000_000)
            try await expect(!h.vm.isLoading && h.vm.messages.isEmpty && h.vm.conversationId != deleted,
                "A late already-buffered delta must not repopulate the newly selected conversation")
            try await expect(try h.archive.load(userId: h.owner).allSatisfy { $0.id != deleted },
                "A cancelled old producer must not write the deleted conversation back to disk")
            try await expect(ChatFixtureURLProtocol.captured.count == 1, "Deletion must never create another model request")
        }
        try await run("viewmodel-delete-unrelated-history-preserves-live-draft-images-and-approved-destination") {
            let h = try await ChatHarness(); defer { h.close() }
            h.addMemory(text: "approved private reference")
            h.vm.inputText = "approve destination"; h.vm.sendMessage(userId: h.owner)
            try await expect(h.vm.requiresBYOKConfirmation, "Fixture must require real context approval")
            h.vm.confirmBYOKContext(); try await finished(h.vm)
            ChatFixtureURLProtocol.enqueue(.hold("current remains live"))
            h.vm.inputText = "keep this producer"; h.vm.sendMessage(userId: h.owner)
            try await wait("unrelated deletion partial") { h.vm.messages.last?.content == "current remains live" }
            let other = conversation(messages: [message(.user, "unrelated archive")])
            try h.archive.upsert(other, userId: h.owner)
            let picture = try image()
            h.vm.inputText = "untouched live draft"; h.vm.pendingImages = [picture]; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            let selected = h.vm.conversationId, messages = h.vm.messages
            let requests = ChatFixtureURLProtocol.captured.count, stopped = ChatFixtureURLProtocol.stoppedCount
            try await h.vm.deleteConversations(ids: [other.id], ownerId: h.owner)
            try await expect(h.vm.isLoading && h.vm.messages == messages && h.vm.conversationId == selected
                && h.vm.inputText == "untouched live draft" && h.vm.pendingImages == [picture],
                "Deleting another history row must not cancel the selected producer or clear its private draft/images")
            try await expect(ChatFixtureURLProtocol.captured.count == requests && ChatFixtureURLProtocol.stoppedCount == stopped,
                "Unrelated deletion must neither start nor cancel any network producer")
            let draft = try h.archive.loadDraftRecord(userId: h.owner)
            try await expect(draft.text == "untouched live draft" && draft.images == [picture] && draft.conversationId == selected,
                "An unrelated deletion must preserve the current persisted draft exactly")
            ChatFixtureURLProtocol.enqueueDelta(" continued", requestIndex: 1)
            try await wait("producer remains usable") { h.vm.messages.last?.content.hasSuffix(" continued") == true }
            h.vm.cancel(); await h.vm.waitForPendingArchiveWrites()
            try await send(h, "approved destination still works")
            try await expect(!h.vm.requiresBYOKConfirmation, "Deleting unrelated history must preserve previously approved BYOK destination consent")
        }
        try await run("viewmodel-delete-unrelated-history-preserves-pending-byok-confirmation") {
            let h = try await ChatHarness(); defer { h.close() }
            h.addMemory(text: "pending personal context")
            let other = conversation(messages: [message(.user, "delete only this unrelated history")])
            try h.archive.upsert(other, userId: h.owner)
            let picture = try image()
            h.vm.inputText = "retain pending consent input"; h.vm.pendingImages = [picture]
            h.vm.sendMessage(userId: h.owner)
            let destination = h.vm.pendingDestination, selected = h.vm.conversationId
            try await expect(h.vm.requiresBYOKConfirmation && !destination.isEmpty, "Fixture must retain an unapproved destination")
            try await h.vm.deleteConversations(ids: [other.id], ownerId: h.owner)
            try await expect(h.vm.requiresBYOKConfirmation && h.vm.pendingDestination == destination
                && h.vm.conversationId == selected && h.vm.inputText == "retain pending consent input"
                && h.vm.pendingImages == [picture] && ChatFixtureURLProtocol.captured.isEmpty,
                "Deleting unrelated records must not approve, reject or clear pending BYOK authorization")
            h.vm.confirmBYOKContext(); try await finished(h.vm)
            try await expect(ChatFixtureURLProtocol.captured.count == 1, "The preserved consent must release exactly one request on explicit approval")
        }
        try await run("viewmodel-delete-all-live-history-clears-owned-files-without-writeback") {
            let h = try await ChatHarness(); defer { h.close() }
            ChatFixtureURLProtocol.enqueue(.hold("all history partial"))
            h.vm.inputText = "clear all active data"; h.vm.sendMessage(userId: h.owner)
            try await wait("all clear partial") { h.vm.messages.last?.content == "all history partial" }
            let deleted = h.vm.conversationId
            h.vm.inputText = "owned draft to remove"; h.vm.pendingImages = [try image()]; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            let other = conversation(messages: [message(.user, "second owned history")])
            try h.archive.upsert(other, userId: h.owner)
            let foreign = conversation(messages: [message(.user, "foreign account remains")])
            try await h.archive.prepareAsync(userId: "foreign-owner")
            try h.archive.upsert(foreign, userId: "foreign-owner")
            try h.archive.saveDraft("foreign draft remains", userId: "foreign-owner")
            ChatFixtureURLProtocol.enqueueDelta(" stale all-clear callback")
            try await h.vm.deleteAllConversations(ownerId: h.owner)
            try await wait("all clear network stopped") { ChatFixtureURLProtocol.stoppedCount >= 1 }
            try await Task.sleep(nanoseconds: 20_000_000)
            h.vm.cancel(); await h.vm.waitForPendingArchiveWrites()
            try await expect(try h.archive.load(userId: h.owner).isEmpty && h.archive.loadDraft(userId: h.owner).isEmpty,
                "Clear all must leave neither owned conversations nor the old input draft")
            try await expect(h.vm.messages.isEmpty && h.vm.conversations.isEmpty && h.vm.pendingImages.isEmpty
                && h.vm.inputText.isEmpty && !h.vm.isLoading && h.vm.conversationId != deleted,
                "Clear all must reset the selected UI only after archive/draft deletion succeeds")
            try await expect(try h.archive.load(userId: "foreign-owner") == [foreign]
                && h.archive.loadDraft(userId: "foreign-owner") == "foreign draft remains",
                "Clearing one account must leave another account's archive and draft intact")
            try await expect(try h.archive.loadDraftRecords(userId: h.owner).allSatisfy { $0.conversationId == h.vm.conversationId && $0.text.isEmpty && ($0.images ?? []).isEmpty }, "Clear all persists only the replacement empty draft and no old source")
        }
        try await run("viewmodel-history-deletion-rejects-owner-changes-before-any-mutation") {
            let h = try await ChatHarness(owner: "delete-owner-a")
            defer { AuthService.shared.user = ChatFixtureUser(id: h.owner); h.close() }
            try await send(h, "account A archive")
            h.vm.inputText = "A private unsaved draft"; h.vm.pendingImages = [try image()]; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            let foreign = conversation(messages: [message(.user, "B source")])
            try await h.archive.prepareAsync(userId: "delete-owner-b")
            try h.archive.upsert(foreign, userId: "delete-owner-b")
            try h.archive.saveDraft("B source draft", userId: "delete-owner-b")
            let originalFiles = try archiveFiles(h), originalMessages = h.vm.messages, selected = h.vm.conversationId
            AuthService.shared.user = ChatFixtureUser(id: "delete-owner-b") // Before activateOwner().
            for owner in [h.owner, "delete-owner-b", ""] {
                _ = try await failure { try await h.vm.deleteConversations(ids: [selected, foreign.id], ownerId: owner) }
                _ = try await failure { try await h.vm.deleteAllConversations(ownerId: owner) }
                _ = try await failure { _ = try await h.vm.loadHistory(ownerId: owner) }
            }
            try await expect(try archiveFiles(h) == originalFiles, "Owner rejection must preserve both accounts' actual files byte-for-byte")
            try await expect(h.vm.messages == originalMessages && h.vm.conversationId == selected
                && h.vm.inputText == "A private unsaved draft" && h.vm.pendingImages.count == 1,
                "A stale confirmation must not clear or rewrite either account's current visible state")
            try await expect(ChatFixtureURLProtocol.captured.count == 1, "History rejection must never fall back to a model request")
        }
        try await run("viewmodel-open-history-reloads-current-owner-instead-of-caller-snapshot") {
            let h = try await ChatHarness(); defer { h.close() }
            let actual = conversation(id: "colliding-history-id", messages: [message(.user, "actual current-owner contents")])
            try h.archive.upsert(actual, userId: h.owner)
            let forged = conversation(id: actual.id, messages: [message(.user, "stale other-owner secret")])
            (await h.vm.openConversation(forged))
            try await expect(h.vm.messages == actual.messages, "Opening a retained snapshot must resolve the current owner's stored contents by ID")
            let selected = h.vm.conversationId, original = h.vm.messages
            (await h.vm.openConversation(conversation(messages: [message(.user, "unknown old-owner private data")])))
            try await expect(h.vm.conversationId == selected && h.vm.messages == original && h.vm.error != nil,
                "An ID absent from the current owner archive must not replace current messages with a supplied snapshot")
        }
        try await run("viewmodel-reopen-current-live-history-preserves-unsaved-state") {
            let h = try await ChatHarness(); defer { h.close() }
            ChatFixtureURLProtocol.enqueue(.hold("initial selected partial"))
            h.vm.inputText = "keep selected chat"; h.vm.sendMessage(userId: h.owner)
            try await wait("selected live archive") { h.vm.messages.last?.content == "initial selected partial" }
            await h.vm.waitForPendingArchiveWrites()
            guard let archived = try h.archive.load(userId: h.owner).first else {
                throw ChatTestFailure(description: "The selected live conversation must really be persisted before testing an unsaved delta")
            }
            ChatFixtureURLProtocol.enqueueDelta(" newer than disk")
            try await wait("selected unsaved delta") { h.vm.messages.last?.content.hasSuffix(" newer than disk") == true }
            let picture = try image()
            h.vm.inputText = "selected unsaved draft"; h.vm.pendingImages = [picture]
            let original = h.vm.messages, requests = ChatFixtureURLProtocol.captured.count, stopped = ChatFixtureURLProtocol.stoppedCount
            (await h.vm.openConversation(archived))
            try await expect(h.vm.isLoading && h.vm.messages == original && h.vm.conversationId == archived.id
                && h.vm.inputText == "selected unsaved draft" && h.vm.pendingImages == [picture],
                "Tapping the selected conversation must not reload older throttled output or discard unsaved input/images")
            try await expect(ChatFixtureURLProtocol.captured.count == requests && ChatFixtureURLProtocol.stoppedCount == stopped,
                "Reopening current history is navigation only, not a request cancellation or restart")
        }
        try await run("viewmodel-delete-other-history-removes-its-persistent-draft-and-restart-reference") {
            let h = try await ChatHarness(); defer { h.close() }
            let historyB = conversation(id: "history-B", messages: [message(.user, "B source to delete")])
            try h.archive.upsert(historyB, userId: h.owner)
            try h.archive.saveDraft("private unsent B draft", conversationId: historyB.id, userId: h.owner)
            let historyA = conversation(id: "history-A", messages: [message(.user, "A selected source")])
            try h.archive.upsert(historyA, userId: h.owner)
            (await h.vm.openConversation(historyA))
            let picture = try image()
            h.vm.inputText = "current A input stays"; h.vm.pendingImages = [picture]
            try await expect(try h.archive.loadDraftRecord(conversationId: historyB.id, userId: h.owner).text == "private unsent B draft",
                "Opening A must preserve B's previously active draft as an inactive conversation draft")
            try await h.vm.deleteConversations(ids: [historyB.id], ownerId: h.owner)
            let storedDraft = try h.archive.loadDraftRecord(userId: h.owner)
            try await expect(storedDraft.conversationId == historyA.id && storedDraft.text == "current A input stays"
                && storedDraft.images == [picture], "Successful deletion must replace the deleted disk draft with the exact current A draft")
            try await expect(h.vm.conversationId == historyA.id && h.vm.inputText == "current A input stays"
                && h.vm.pendingImages == [picture], "Disk draft cleanup must preserve the unselected target's unrelated current UI state")
            let restored = ChatViewModel(archive: h.archive, transport: h.transport, conversationClient: h.conversationClient,
                repository: h.repository, defaults: h.defaults)
            try await restored.waitForArchiveReady(ownerId: h.owner)
            defer { restored.cancel() }
            try await expect(restored.conversationId == historyA.id && restored.inputText == "current A input stays",
                "Restart must not recover a deleted conversation ID or its private input")
            restored.inputText = "send after restart"; restored.sendMessage(userId: h.owner)
            if restored.requiresBYOKConfirmation { restored.confirmBYOKContext() }
            try await finished(restored)
            try await expect(try h.archive.load(userId: h.owner).allSatisfy { $0.id != historyB.id },
                "A new send after restart must not resurrect history B from its former draft reference")
        }
        try await run("viewmodel-delete-write-failure-preserves-current-producer-and-all-source-files") {
            let h = try await ChatHarness(); defer { h.close() }
            ChatFixtureURLProtocol.enqueue(.hold("permission failure current partial"))
            h.vm.inputText = "do not stop this producer"; h.vm.sendMessage(userId: h.owner)
            try await wait("write failure producer") { h.vm.messages.last?.content == "permission failure current partial" }
            let other = conversation(messages: [message(.user, "unrelated record to delete")])
            try h.archive.upsert(other, userId: h.owner)
            let picture = try image()
            h.vm.inputText = "permission failure unsaved input"; h.vm.pendingImages = [picture]; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            let originalFiles = try archiveFiles(h), originalMessages = h.vm.messages, selected = h.vm.conversationId
            let stopped = ChatFixtureURLProtocol.stoppedCount
            let directory = h.directory.appendingPathComponent("conversations")
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
            _ = try await failure { try await h.vm.deleteConversations(ids: [other.id], ownerId: h.owner) }
            try await expect(try archiveFiles(h) == originalFiles, "Actual atomic write permission failure must leave every source file byte-for-byte intact")
            try await expect(h.vm.isLoading && h.vm.messages == originalMessages && h.vm.conversationId == selected
                && h.vm.inputText == "permission failure unsaved input" && h.vm.pendingImages == [picture],
                "A failed archive write must not clear or cancel any live UI state")
            try await expect(ChatFixtureURLProtocol.stoppedCount == stopped, "Write failure before deletion commit must leave the underlying producer live")
        }
        try await run("viewmodel-delete-current-draft-failure-is-explicit-and-blocks-resurrection") {
            let fault = ChatFixtureArchiveFault()
            let h = try await ChatHarness(archiveFault: { try fault.check($0, owner: $1) }); defer { h.close(); fault.arm(nil) }
            ChatFixtureURLProtocol.enqueue(.hold("transaction rollback partial"))
            h.vm.inputText = "current deletion request"; h.vm.sendMessage(userId: h.owner)
            try await wait("rollback producer") { h.vm.messages.last?.content == "transaction rollback partial" }
            let selected = h.vm.conversationId, picture = try image()
            h.vm.inputText = "keep exact draft"; h.vm.pendingImages = [picture]
            h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            let before = try archiveFiles(h), visible = h.vm.messages, stopped = ChatFixtureURLProtocol.stoppedCount
            fault.arm(.beforeMutation, after: 1)
            _ = try await failure { try await h.vm.deleteConversations(ids: [selected], ownerId: h.owner) }
            fault.arm(nil)
            try await expect(try archiveFiles(h) == before && !h.archive.deletedConversationIds(userId: h.owner).contains(selected), "Failure selecting replacement draft rolls back messages, tombstone and draft deletion together")
            try await expect(h.vm.isLoading && h.vm.messages == visible && h.vm.conversationId == selected && h.vm.inputText == "keep exact draft" && h.vm.pendingImages == [picture] && ChatFixtureURLProtocol.stoppedCount == stopped, "A rolled-back deletion must preserve the real producer and exact visible source")
            try await h.vm.deleteConversations(ids: [selected], ownerId: h.owner)
            try await expect(h.vm.messages.isEmpty && h.vm.conversationId != selected && h.archive.load(userId: h.owner).isEmpty, "An explicit successful retry commits deletion without resurrection")
        }
        try await run("viewmodel-clear-all-partial-file-deletion-preserves-recovery-state-and-no-writeback") {
            let fault = ChatFixtureArchiveFault()
            let h = try await ChatHarness(archiveFault: { try fault.check($0, owner: $1) }); defer { h.close(); fault.arm(nil) }
            ChatFixtureURLProtocol.enqueue(.hold("purge recovery partial"))
            h.vm.inputText = "clear all"; h.vm.sendMessage(userId: h.owner)
            try await wait("purge partial") { h.vm.messages.last?.content == "purge recovery partial" }
            let selected = h.vm.conversationId, picture = try image()
            h.vm.inputText = "keep recovery draft"; h.vm.pendingImages = [picture]
            h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            let contents = h.vm.messages.map(\.content)
            fault.arm(.purgeDatabaseRemoval)
            let error = try await failure { try await h.vm.deleteAllConversations(ownerId: h.owner) }
            try await expect(error as? AssistantChatStorageError == .publicationCommittedCleanupPending, "Physical cleanup failure must report that deletion already committed")
            try await expect(try h.archive.isPurgingAll(userId: h.owner) && h.archive.load(userId: h.owner).isEmpty, "Committed purge masks every old body while cleanup is pending")
            try await expect(!h.vm.isLoading && h.vm.messages.map(\.content) == contents && h.vm.conversationId == selected && h.vm.inputText == "keep recovery draft" && h.vm.pendingImages == [picture] && h.vm.archiveRequiresRecovery, "Only post-commit cleanup failure stops the producer while retaining visible recovery content")
            h.vm.toggleLike(h.vm.messages.last!.id); h.vm.cancel(); await h.vm.waitForPendingArchiveWrites()
            try await expect(try h.archive.load(userId: h.owner).isEmpty, "Recovery content cannot write deleted data back")
            fault.arm(nil)
            try await h.vm.deleteAllConversations(ownerId: h.owner)
            try await expect(h.vm.messages.isEmpty && h.vm.archiveIsReady && !h.vm.archiveRequiresRecovery && h.vm.conversationId != selected, "Explicit cleanup retry returns to a ready clean conversation")
        }
        try await run("viewmodel-clear-all-first-file-failure-preserves-live-request") {
            let fault = ChatFixtureArchiveFault()
            let h = try await ChatHarness(archiveFault: { try fault.check($0, owner: $1) }); defer { h.close(); fault.arm(nil) }
            ChatFixtureURLProtocol.enqueue(.hold("precommit purge producer"))
            h.vm.inputText = "block before purge commit"; h.vm.sendMessage(userId: h.owner)
            try await wait("precommit purge stream") { h.vm.messages.last?.content == "precommit purge producer" }
            h.vm.inputText = "first failure input"; h.vm.pendingImages = [try image()]
            h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            let before = try archiveFiles(h), visible = h.vm.messages, stopped = ChatFixtureURLProtocol.stoppedCount
            fault.arm(.beforeCommit)
            _ = try await failure { try await h.vm.deleteAllConversations(ownerId: h.owner) }
            fault.arm(nil)
            try await expect(try archiveFiles(h) == before && !h.archive.isPurgingAll(userId: h.owner), "Precommit failure rolls back the purge flag and every old row")
            try await expect(h.vm.messages == visible && h.vm.isLoading && h.vm.inputText == "first failure input" && h.vm.pendingImages.count == 1 && ChatFixtureURLProtocol.stoppedCount == stopped, "No committed deletion means no producer cancellation or visible state loss")
        }
        try await run("viewmodel-delete-corrupt-draft-preflight-preserves-archive-and-live-state") {
            let h = try await ChatHarness(); defer { h.close() }
            ChatFixtureURLProtocol.enqueue(.hold("corrupt draft producer"))
            h.vm.inputText = "preserve unreadable source"; h.vm.sendMessage(userId: h.owner)
            try await wait("corrupt draft stream") { h.vm.messages.last?.content == "corrupt draft producer" }
            h.vm.inputText = "untouched unsaved draft"; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            let other = try targetHistory(h), selected = h.vm.conversationId
            try sql(h, "UPDATE drafts SET payload=? WHERE conversation_id=?", [.blob(Data("unreadable source".utf8)), .text(selected)])
            let before = try archiveFiles(h), visible = h.vm.messages, stopped = ChatFixtureURLProtocol.stoppedCount
            _ = try await failure { try await h.vm.deleteConversations(ids: [other.id], ownerId: h.owner) }
            try await expect(try archiveFiles(h) == before && h.archive.conversation(id: other.id, userId: h.owner) != nil, "Corrupt current draft prevents overwrite and rolls back unrelated deletion")
            try await expect(h.vm.messages == visible && h.vm.isLoading && h.vm.inputText == "untouched unsaved draft" && h.vm.conversationId == selected && ChatFixtureURLProtocol.stoppedCount == stopped, "Unreadable source failure preserves the still-live selected producer")
        }
        try await run("viewmodel-action-source-only-completed-current-nonempty-text") {
            let h = try await ChatHarness(); defer { h.close() }
            for role in [ChatMessage.Role.user, .assistant] {
                for status in [ChatMessage.Status.pending, .streaming, .completed, .cancelled, .failed] {
                    let value = message(role, "Source text", status: status); h.vm.messages = [value]
                    try await expect(h.vm.canDeriveAction(from: value) == (status == .completed), "Only completed user/assistant messages offer actions")
                    if status == .completed { _ = try h.vm.makeActionSource(messageId: value.id) }
                    else { _ = try await failure { _ = try h.vm.makeActionSource(messageId: value.id) } }
                }
            }
            for text in ["", " \n\t "] {
                let empty = message(.assistant, text); h.vm.messages = [empty]
                try await expect(!h.vm.canDeriveAction(from: empty), "Whitespace-only source cannot create actions")
            }
            let valid = message(.assistant, "Present"); h.vm.messages = [valid, valid]
            try await expect(!h.vm.canDeriveAction(from: valid), "Duplicate message identifiers are ambiguous and rejected")
            h.vm.messages = [valid]
            var stale = valid; stale.content = "Stale captured text"
            try await expect(!h.vm.canDeriveAction(from: stale), "A detached UI snapshot cannot authorize current content")
            try await expect(ChatFixtureURLProtocol.captured.isEmpty, "Source eligibility never calls a model")
        }
        try await run("viewmodel-action-source-capture-and-cancel-do-not-write") {
            let h = try await ChatHarness(); defer { h.close() }
            let value = message(.assistant, "  Tomorrow 08:00, send this to someone.\n  "); h.vm.messages = [value]
            h.vm.inputText = "Unsaved draft"; h.vm.pendingImages = [try image()]
            let before = try archiveFiles(h), draft = h.vm.inputText, pictures = h.vm.pendingImages
            let source = try h.vm.makeActionSource(messageId: value.id)
            try h.vm.validateActionSource(source)
            try await expect(source.ownerId == h.owner && source.conversationId == h.vm.conversationId && source.messageId == value.id
                && source.content == value.content && source.role == value.role && source.status == .completed, "Ticket preserves the exact editable text and source scope")
            try await expect(h.repository.memories(for: h.owner).isEmpty && h.repository.tasks(for: h.owner).isEmpty
                && !FileManager.default.fileExists(atPath: h.directory.appendingPathComponent("repository.json").path), "Opening or abandoning confirmation cannot persist a record or infer a task")
            try await expect(try archiveFiles(h) == before && h.vm.inputText == draft && h.vm.pendingImages == pictures, "Confirmation preparation preserves chat state and archives")
            try await expect(ChatFixtureURLProtocol.captured.isEmpty, "Source preparation neither parses dates nor makes external/model requests")
        }
        try await run("viewmodel-action-memory-explicit-edited-text-and-authoritative-provenance") {
            let h = try await ChatHarness(); defer { h.close() }
            let value = message(.assistant, "Untrusted model suggestion to execute an action"); h.vm.messages = [value]
            h.repository.setMemoryEnabled(false, for: h.owner)
            let source = try h.vm.makeActionSource(messageId: value.id)
            let requested = actionMemory(owner: h.owner, text: "  User deliberately edited this fact.\n")
            try h.vm.saveMemoryFromMessage(requested, source: source)
            let saved = h.repository.memories(for: h.owner).first!
            try await expect(saved.id == requested.id && saved.userId == h.owner && saved.text == requested.text
                && saved.category == requested.category && saved.sourceMessageId == value.id
                && saved.consent == "explicit" && saved.status == .active && saved.createdAt != .distantPast, "Only user-confirmed edited text is saved with forced owner/source/consent/status")
            let reloaded = AssistantLocalRepository(fileURL: h.directory.appendingPathComponent("repository.json")).memories(for: h.owner)
            try await expect(reloaded.count == 1 && reloaded.first?.id == saved.id && reloaded.first?.text == saved.text
                && reloaded.first?.sourceMessageId == value.id && reloaded.first?.consent == "explicit"
                && reloaded.first?.status == .active && abs(reloaded.first!.createdAt.timeIntervalSince(saved.createdAt)) < 1, "Success must survive the repository's ISO8601 second-precision reload")
            try await expect(!h.repository.isMemoryEnabled(for: h.owner) && h.repository.tasks(for: h.owner).isEmpty, "Saving a memory cannot silently enable use or execute/create a task")
            try await expect(ChatFixtureURLProtocol.captured.isEmpty && h.vm.messages == [value], "Memory save leaves chat and network untouched")
        }
        try await run("viewmodel-action-source-content-change-and-revert-stay-invalid") {
            let h = try await ChatHarness(); defer { h.close() }
            let value = message(.assistant, "Original source"); h.vm.messages = [value]
            let source = try h.vm.makeActionSource(messageId: value.id)
            h.vm.messages[0].content = "Changed source"
            _ = try await failure { try h.vm.validateActionSource(source) }
            h.vm.messages[0].content = value.content
            _ = try await failure { try h.vm.saveMemoryFromMessage(actionMemory(owner: h.owner), source: source) }
            try await expect(h.repository.memories(for: h.owner).isEmpty && ChatFixtureURLProtocol.captured.isEmpty, "Reverting text cannot revive an obsolete confirmation ticket")
        }
        try await run("viewmodel-action-source-role-and-status-changes-invalidate") {
            let h = try await ChatHarness(); defer { h.close() }
            let value = message(.assistant, "Completed source"); h.vm.messages = [value]
            let statusSource = try h.vm.makeActionSource(messageId: value.id)
            h.vm.messages[0].status = .failed; h.vm.messages[0].status = .completed
            _ = try await failure { try h.vm.validateActionSource(statusSource) }
            let roleSource = try h.vm.makeActionSource(messageId: value.id)
            h.vm.messages = [ChatMessage(id: value.id, role: .user, content: value.content, timestamp: value.timestamp)]
            _ = try await failure { try h.vm.validateActionSource(roleSource) }
            try await expect(h.repository.memories(for: h.owner).isEmpty && ChatFixtureURLProtocol.captured.isEmpty, "Status/role changes cannot authorize stale saves")
        }
        try await run("viewmodel-action-source-delete-message-refuses-late-save") {
            let h = try await ChatHarness(); defer { h.close() }
            let value = message(.assistant, "Delete this source"); h.vm.messages = [value]
            let source = try h.vm.makeActionSource(messageId: value.id)
            h.vm.deleteMessage(value.id)
            _ = try await failure { try h.vm.saveMemoryFromMessage(actionMemory(owner: h.owner), source: source) }
            try await expect(h.vm.messages.isEmpty && h.repository.memories(for: h.owner).isEmpty && ChatFixtureURLProtocol.captured.isEmpty, "Deleted message cannot be saved through a delayed confirmation")
        }
        try await run("viewmodel-action-source-conversation-roundtrip-does-not-revive") {
            let h = try await ChatHarness(); defer { h.close() }
            let value = message(.assistant, "Conversation A source"); h.vm.messages = [value]
            try await h.vm.flushForDataExport(ownerId: h.owner)
            guard let original = try h.archive.load(userId: h.owner).first else {
                throw ChatTestFailure(description: "Explicit export flush must really persist the original conversation before a scope roundtrip")
            }
            let source = try h.vm.makeActionSource(messageId: value.id)
            let other = conversation(messages: [message(.assistant, "Conversation B")])
            try h.archive.upsert(other, userId: h.owner)
            (await h.vm.openConversation(other))
            _ = try await failure { try h.vm.validateActionSource(source) }
            (await h.vm.openConversation(original))
            try await expect(h.vm.conversationId == source.conversationId && h.vm.messages.first?.content == source.content, "Fixture really returns to the same original content")
            _ = try await failure { try h.vm.validateActionSource(source) }
            try await expect(h.repository.memories(for: h.owner).isEmpty && ChatFixtureURLProtocol.captured.isEmpty, "A conversation roundtrip cannot revive an old sheet")
        }
        try await run("viewmodel-action-source-account-roundtrip-does-not-revive") {
            let h = try await ChatHarness(); defer { h.close() }
            let value = message(.assistant, "Private A source"); h.vm.messages = [value]
            try await h.vm.flushForDataExport(ownerId: h.owner)
            let source = try h.vm.makeActionSource(messageId: value.id)
            AuthService.shared.user = ChatFixtureUser(id: "owner-B")
            _ = try await failure { try h.vm.validateActionSource(source) }
            h.vm.activateOwner()
            AuthService.shared.user = ChatFixtureUser(id: h.owner); h.vm.activateOwner(); try await h.vm.waitForArchiveReady(ownerId: h.owner)
            try await expect(h.vm.conversationId == source.conversationId, "Fixture reopens A's persisted conversation")
            _ = try await failure { try h.vm.saveMemoryFromMessage(actionMemory(owner: h.owner), source: source) }
            try await expect(h.repository.memories(for: h.owner).isEmpty && h.repository.memories(for: "owner-B").isEmpty
                && ChatFixtureURLProtocol.captured.isEmpty, "No account can consume the obsolete source ticket")
        }
        try await run("viewmodel-action-source-likes-do-not-invalidate-content") {
            let h = try await ChatHarness(); defer { h.close() }
            let value = message(.assistant, "A stable completed fact"); h.vm.messages = [value]
            let source = try h.vm.makeActionSource(messageId: value.id)
            h.vm.toggleLike(value.id); h.vm.toggleDislike(value.id)
            try h.vm.validateActionSource(source)
            try h.vm.saveMemoryFromMessage(actionMemory(owner: h.owner), source: source)
            try await expect(h.repository.memories(for: h.owner).count == 1 && ChatFixtureURLProtocol.captured.isEmpty, "Presentation feedback does not change the text being confirmed")
        }
        try await run("viewmodel-action-source-real-regeneration-refuses-old-answer") {
            let h = try await ChatHarness(); defer { h.close() }
            let answer = message(.assistant, "Old answer"); h.vm.messages = [message(.user, "Question"), answer]
            let source = try h.vm.makeActionSource(messageId: answer.id)
            ChatFixtureURLProtocol.enqueue(.hold("Replacement answer"))
            h.vm.regenerate(answer.id, userId: h.owner)
            try await wait("real regeneration producer") { h.vm.messages.last?.content == "Replacement answer" }
            let requests = ChatFixtureURLProtocol.captured.count
            _ = try await failure { try h.vm.saveMemoryFromMessage(actionMemory(owner: h.owner), source: source) }
            try await expect(requests == 1 && ChatFixtureURLProtocol.captured.count == requests && h.repository.memories(for: h.owner).isEmpty, "Only explicitly requested mocked regeneration runs; derived save adds no request")
        }
        try await run("viewmodel-action-source-partial-history-cleanup-blocks-save") {
            let fault = ChatFixtureArchiveFault()
            let h = try await ChatHarness(archiveFault: { try fault.check($0, owner: $1) }); defer { h.close(); fault.arm(nil) }
            let value = message(.assistant, "Recovery-only source"); h.vm.messages = [value]; h.vm.inputText = "Recovery draft"
            try await h.vm.flushForDataExport(ownerId: h.owner)
            let source = try h.vm.makeActionSource(messageId: value.id)
            fault.arm(.purgeDatabaseRemoval)
            _ = try await failure { try await h.vm.deleteAllConversations(ownerId: h.owner) }
            try await expect(!h.vm.canDeriveAction(from: value), "Committed purge recovery text is unavailable for derived actions")
            _ = try await failure { try h.vm.saveMemoryFromMessage(actionMemory(owner: h.owner), source: source) }
            try await expect(h.repository.memories(for: h.owner).isEmpty && ChatFixtureURLProtocol.captured.isEmpty, "Recovery-only text cannot create memory or send a model request")
        }
        try await run("viewmodel-action-memory-character-boundary-keeps-unicode-untruncated") {
            let h = try await ChatHarness(); defer { h.close() }
            let value = message(.assistant, String(repeating: "x", count: AssistantWorkspaceLimits.memoryText + 1)); h.vm.messages = [value]
            let source = try h.vm.makeActionSource(messageId: value.id)
            try await expect(source.content == value.content, "Oversize original opens an editable confirmation without truncation")
            _ = try await failure { try h.vm.saveMemoryFromMessage(actionMemory(owner: h.owner, text: value.content), source: source) }
            let unicode = String(repeating: "👩🏽‍💻", count: AssistantWorkspaceLimits.memoryText)
            try await expect(unicode.count == 20_000 && unicode.utf8.count > unicode.count, "Fixture uses user-perceived character counting")
            let requested = actionMemory(owner: h.owner, text: unicode)
            try h.vm.saveMemoryFromMessage(requested, source: source)
            try await expect(h.repository.memories(for: h.owner).first?.text == unicode && ChatFixtureURLProtocol.captured.isEmpty, "Exactly the edited boundary text is saved without truncation or model summarization")
        }
        try await run("viewmodel-action-memory-foreign-owner-empty-id-and-blank-text-rejected") {
            let h = try await ChatHarness(); defer { h.close() }
            let value = message(.user, "User-authored source"); h.vm.messages = [value]
            let source = try h.vm.makeActionSource(messageId: value.id)
            for record in [actionMemory(owner: "foreign"), actionMemory(owner: h.owner, id: " "), actionMemory(owner: h.owner, text: " \n ")] {
                _ = try await failure { try h.vm.saveMemoryFromMessage(record, source: source) }
            }
            try await expect(h.repository.memories(for: h.owner).isEmpty && h.repository.memories(for: "foreign").isEmpty
                && ChatFixtureURLProtocol.captured.isEmpty, "Invalid edited payloads cannot write under any owner")
        }
        try await run("viewmodel-action-memory-ticket-and-record-id-block-duplicate-save") {
            let h = try await ChatHarness(); defer { h.close() }
            let value = message(.assistant, "Stable source"); h.vm.messages = [value]
            let source = try h.vm.makeActionSource(messageId: value.id), record = actionMemory(owner: h.owner)
            try h.vm.saveMemoryFromMessage(record, source: source)
            let saved = h.repository.memories(for: h.owner)
            _ = try await failure { try h.vm.saveMemoryFromMessage(record, source: source) }
            let fresh = try h.vm.makeActionSource(messageId: value.id)
            _ = try await failure { try h.vm.saveMemoryFromMessage(actionMemory(owner: h.owner, id: record.id, text: "Overwrite attempt"), source: fresh) }
            try await expect(h.repository.memories(for: h.owner) == saved && ChatFixtureURLProtocol.captured.isEmpty, "Neither double tap nor a fresh ticket may upsert an existing ID")
        }
        try await run("viewmodel-action-memory-insert-cannot-revive-deleted-tombstone") {
            let h = try await ChatHarness(); defer { h.close() }
            let value = message(.assistant, "Cannot revive removed memory"); h.vm.messages = [value]
            let original = actionMemory(owner: h.owner)
            var active = original; active.status = .active; active.consent = "explicit"
            h.repository.addMemory(active)
            try await expect(h.repository.deleteMemory(id: active.id, userId: h.owner), "Fixture tombstone must persist")
            let before = try h.repository.exportSnapshot(for: h.owner).memories
            let source = try h.vm.makeActionSource(messageId: value.id)
            _ = try await failure { try h.vm.saveMemoryFromMessage(original, source: source) }
            try await expect(try h.repository.exportSnapshot(for: h.owner).memories == before && h.repository.memories(for: h.owner).isEmpty, "Atomic insert rejects IDs hidden behind deletion tombstones")
        }
        try await run("viewmodel-action-memory-real-disk-failure-retains-source-for-retry") {
            for consent in ["explicit", "unconfirmed"] {
                let h = try await ChatHarness(); defer { h.close() }
                let value = message(.assistant, "Retryable source"); h.vm.messages = [value]
                let source = try h.vm.makeActionSource(messageId: value.id)
                var record = actionMemory(owner: h.owner); record.consent = consent
                let url = h.directory.appendingPathComponent("repository.json")
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                _ = try await failure { try h.vm.saveMemoryFromMessage(record, source: source) }
                try await expect(h.repository.memories(for: h.owner).isEmpty && h.repository.lastError != nil, "Failed atomic write cannot become in-memory success")
                try h.vm.validateActionSource(source)
                try FileManager.default.removeItem(at: url)
                try h.vm.saveMemoryFromMessage(record, source: source)
                try await expect(h.repository.memories(for: h.owner).map(\.id) == [record.id]
                    && h.repository.memories(for: h.owner).first?.consent == consent && ChatFixtureURLProtocol.captured.isEmpty,
                    "Failed authorized or unconfirmed saves retain the ticket, stable ID and exact chosen consent")
            }
        }
        try await run("viewmodel-action-memory-corrupt-repository-does-not-fake-success") {
            let h = try await ChatHarness(); defer { h.close() }
            let url = h.directory.appendingPathComponent("corrupt-repository.json"), original = Data("private damaged storage".utf8)
            try original.write(to: url, options: .atomic)
            let broken = AssistantLocalRepository(fileURL: url)
            let vm = ChatViewModel(archive: h.archive, transport: h.transport, conversationClient: h.conversationClient, repository: broken, defaults: h.defaults)
            try await vm.waitForArchiveReady(ownerId: h.owner)
            let value = message(.assistant, "No write through corruption"); vm.messages = [value]
            let source = try vm.makeActionSource(messageId: value.id)
            _ = try await failure { try vm.saveMemoryFromMessage(actionMemory(owner: h.owner), source: source) }
            try await expect(try Data(contentsOf: url) == original && broken.memories(for: h.owner).isEmpty && ChatFixtureURLProtocol.captured.isEmpty, "Corrupt storage survives unchanged and is reported as failure")
        }
        try await run("viewmodel-action-memory-failed-or-unconfirmed-generic-insert-is-not-success") {
            let h = try await ChatHarness(); defer { h.close() }
            let fake = ChatFixtureMemoryRepository(base: h.repository)
            let vm = ChatViewModel(archive: h.archive, transport: h.transport, conversationClient: h.conversationClient, repository: fake, defaults: h.defaults)
            try await vm.waitForArchiveReady(ownerId: h.owner)
            let value = message(.assistant, "Verify the repository result"); vm.messages = [value]
            let source = try vm.makeActionSource(messageId: value.id), record = actionMemory(owner: h.owner)
            _ = try await failure { try vm.saveMemoryFromMessage(record, source: source) }
            fake.insertionResult = true
            _ = try await failure { try vm.saveMemoryFromMessage(record, source: source) }
            try await expect(fake.insertAttempts == 2 && fake.legacyAddAttempts == 0 && h.repository.memories(for: h.owner).isEmpty, "False insert or missing readback cannot fall back to legacy upsert or report saved")
            try vm.validateActionSource(source)
            try await expect(ChatFixtureURLProtocol.captured.isEmpty, "Insert failure cannot invoke an alternative remote path")
        }
        try await run("viewmodel-action-memory-pre-cancelled-save-does-not-write") {
            let h = try await ChatHarness(); defer { h.close() }
            let value = message(.assistant, "Cancellation is not consent"); h.vm.messages = [value]
            let source = try h.vm.makeActionSource(messageId: value.id), record = actionMemory(owner: h.owner)
            let cancelled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                try h.vm.saveMemoryFromMessage(record, source: source)
            }
            do { try await cancelled.value; throw ChatTestFailure(description: "Expected cancelled save to fail") }
            catch is CancellationError { }
            try h.vm.validateActionSource(source)
            try await expect(h.repository.memories(for: h.owner).isEmpty && ChatFixtureURLProtocol.captured.isEmpty, "Cancellation cannot consume the ticket or persist data")
        }
        try await run("viewmodel-generation-actions-terminal-latest-and-capture-has-no-effects") {
            let h = try await ChatHarness(); defer { h.close() }
            let archiveBeforeConfirmation = try archiveFiles(h)
            for status in [ChatMessage.Status.pending, .streaming, .completed, .failed, .cancelled] {
                let fixture = generationFixture(h, status: status)
                let permitted = [.completed, .failed, .cancelled].contains(status)
                try await expect(h.vm.canPerformGenerationAction(from: fixture.answer) == permitted, "Only a terminal latest assistant can start an explicit new attempt")
                if permitted {
                    let source = try h.vm.makeGenerationActionSource(messageId: fixture.answer.id)
                    try await expect(source.kind == (status == .completed ? .regenerate : .retry) && source.willReplaceResponse == (status == .completed), "Action kind and replacement disclosure follow the real terminal state")
                } else { _ = try await failure { _ = try h.vm.makeGenerationActionSource(messageId: fixture.answer.id) } }
            }
            let fixture = generationFixture(h)
            h.vm.isLoading = true
            try await expect(!h.vm.canPerformGenerationAction(from: fixture.answer), "Loading disables duplicate attempts")
            h.vm.isLoading = false; h.vm.messages = [fixture.answer]
            try await expect(!h.vm.canPerformGenerationAction(from: fixture.answer), "A reply without its original user turn cannot be replayed")
            try await expect(ChatFixtureURLProtocol.captured.isEmpty && (try archiveFiles(h)) == archiveBeforeConfirmation, "Opening or abandoning fee confirmation makes no request or archive write")
        }
        try await run("viewmodel-retry-empty-http-failure-keeps-user-draft-and-new-request-id") {
            let h = try await ChatHarness(); defer { h.close() }
            ChatFixtureURLProtocol.enqueue(.httpError)
            h.vm.inputText = "Original network question"; h.vm.sendMessage(userId: h.owner)
            try await wait("original empty HTTP failure") { !h.vm.isLoading }
            let user = h.vm.messages[0], failed = h.vm.messages[1]
            try await expect(failed.status == .failed && failed.content.isEmpty, "Fixture must fail before any output")
            h.vm.inputText = "Keep this new draft"; let draftImage = try image(red: 0.8); h.vm.pendingImages = [draftImage]
            let source = try h.vm.makeGenerationActionSource(messageId: failed.id)
            ChatFixtureURLProtocol.enqueue(.complete("Retried answer")); h.vm.performGenerationAction(source); try await finished(h.vm)
            try await expect(h.vm.messages.count == 3 && h.vm.messages.filter({ $0.role == .user }).map(\.id) == [user.id]
                && h.vm.messages.contains(failed), "Retry appends one assistant and retains the failed record without duplicating its user")
            try await expect(h.vm.messages.last?.requestId != failed.requestId && h.vm.messages.last?.requestId == ChatFixtureURLProtocol.captured.last?.value(forHTTPHeaderField: "X-Request-ID"), "Explicit retry has a fresh request identity carried to the wire")
            try await expect(h.vm.inputText == "Keep this new draft" && h.vm.pendingImages == [draftImage]
                && jsonStrings(try body(1)).contains(user.content) && !jsonStrings(try body(1)).contains(h.vm.inputText), "Retry resends the original question rather than the new draft")
        }
        try await run("viewmodel-retry-cancelled-image-turn-uses-original-images-in-all-protocols") {
            for kind in AssistantWireProtocol.allCases {
                let h = try await ChatHarness(); defer { h.close() }
                h.defaults.set(kind.rawValue, forKey: h.byokPrefix + "protocol")
                let originalImage = try image(red: 0.2), newImage = try image(red: 0.8)
                let fixture = generationFixture(h, status: .cancelled, text: "Stopped partial", images: [originalImage])
                h.vm.inputText = "Different unsent question"; h.vm.pendingImages = [newImage]
                let source = try h.vm.makeGenerationActionSource(messageId: fixture.answer.id)
                ChatFixtureURLProtocol.enqueue(.complete("Image retry answer")); h.vm.performGenerationAction(source); try await finished(h.vm)
                let strings = jsonStrings(try body())
                try await expect(strings.contains(fixture.user.content) && (strings.contains(originalImage.dataURL) || strings.contains(originalImage.base64Data))
                    && !strings.contains(newImage.dataURL) && !strings.contains(newImage.base64Data), "Wire images and text belong only to the original user turn in every protocol")
                try await expect(h.vm.messages.contains(fixture.answer) && h.vm.messages.filter({ $0.role == .user }).count == 1
                    && h.vm.inputText == "Different unsent question" && h.vm.pendingImages == [newImage], "Cancelled partial output and new draft remain unchanged")
            }
        }
        try await run("viewmodel-retry-real-stream-failure-retains-original-partial-and-archive") {
            let h = try await ChatHarness(); defer { h.close() }
            ChatFixtureURLProtocol.enqueue(.hold("Network failed after this partial"))
            h.vm.inputText = "Original partial failure question"; h.vm.sendMessage(userId: h.owner)
            try await wait("partial delivered before failure") { h.vm.messages.last?.content == "Network failed after this partial" }
            ChatFixtureURLProtocol.failHeld()
            try await wait("partial network failure") { !h.vm.isLoading }
            let old = h.vm.messages.last!
            try await expect(old.status == .failed && old.content == "Network failed after this partial", "Actual stream/transport must retain the failed partial")
            ChatFixtureURLProtocol.enqueue(.complete("Fresh successful attempt"))
            h.vm.performGenerationAction(try h.vm.makeGenerationActionSource(messageId: old.id)); try await finished(h.vm)
            guard let saved = try h.archive.load(userId: h.owner).first?.messages else {
                throw ChatTestFailure(description: "The completed retry must really persist its conversation and lineage")
            }
            try await expect(saved.contains(old) && saved.last?.content == "Fresh successful attempt"
                && saved.last?.requestId != old.requestId, "Retry preserves the old failed partial in durable history")
        }
        try await run("viewmodel-regeneration-failure-retains-completed-answer-and-lineage") {
            let h = try await ChatHarness(); defer { h.close() }
            let fixture = generationFixture(h, status: .completed, text: "Keep the original completed answer")
            ChatFixtureURLProtocol.enqueue(.httpError)
            h.vm.performGenerationAction(try h.vm.makeGenerationActionSource(messageId: fixture.answer.id))
            try await wait("failed regeneration") { !h.vm.isLoading }
            await h.vm.waitForPendingArchiveWrites()
            try await expect(h.vm.messages.count == 3 && h.vm.messages.contains(fixture.answer) && h.vm.messages.last?.status == .failed
                && h.vm.messages.last?.replacesMessageId == fixture.answer.id, "Failed candidate must retain its completed predecessor and replacement lineage")
            let retry = try h.vm.makeGenerationActionSource(messageId: h.vm.messages.last!.id)
            try await expect(retry.kind == .retry && retry.willReplaceResponse, "Retry after failed regeneration discloses eventual replacement")
            try await expect(try h.archive.load(userId: h.owner).first?.messages.contains(fixture.answer) == true, "Original answer survives on disk before a later success")
        }
        try await run("viewmodel-regeneration-stop-and-retry-success-removes-only-completed-predecessor") {
            let h = try await ChatHarness(); defer { h.close() }
            let fixture = generationFixture(h, status: .completed, text: "Original completed reply")
            ChatFixtureURLProtocol.enqueue(.hold("Replacement partial"))
            h.vm.performGenerationAction(try h.vm.makeGenerationActionSource(messageId: fixture.answer.id))
            try await wait("replacement partial") { h.vm.messages.last?.content == "Replacement partial" }
            try await expect(h.vm.messages.contains(fixture.answer), "Original answer remains visible throughout generation")
            h.vm.cancel(); await h.vm.waitForPendingArchiveWrites(); let stopped = h.vm.messages.last!
            try await expect(stopped.status == .cancelled && stopped.replacesMessageId == fixture.answer.id, "Stopping preserves candidate text and lineage")
            ChatFixtureURLProtocol.enqueue(.complete("Final replacement"))
            h.vm.performGenerationAction(try h.vm.makeGenerationActionSource(messageId: stopped.id)); try await finished(h.vm)
            try await expect(!h.vm.messages.contains(where: { $0.id == fixture.answer.id }) && h.vm.messages.contains(stopped)
                && h.vm.messages.filter({ $0.role == .user }).map(\.id) == [fixture.user.id] && h.vm.messages.last?.content == "Final replacement", "Success replaces only the explicitly designated completed answer, preserving stopped attempts and original user")
        }
        try await run("viewmodel-retry-lineage-survives-new-viewmodel-and-real-archive") {
            let h = try await ChatHarness(); defer { h.close() }
            let fixture = generationFixture(h, status: .completed, text: "Original before restart")
            ChatFixtureURLProtocol.enqueue(.httpError)
            h.vm.performGenerationAction(try h.vm.makeGenerationActionSource(messageId: fixture.answer.id))
            try await wait("pre-restart regeneration failure") { !h.vm.isLoading }
            await h.vm.waitForPendingArchiveWrites()
            let failed = h.vm.messages.last!
            let restarted = ChatViewModel(archive: h.archive, transport: h.transport, conversationClient: h.conversationClient, repository: h.repository, defaults: h.defaults)
            try await restarted.waitForArchiveReady(ownerId: h.owner)
            let source = try restarted.makeGenerationActionSource(messageId: failed.id)
            try await expect(source.kind == .retry && source.willReplaceResponse, "Persisted metadata restores the intended replacement behavior")
            ChatFixtureURLProtocol.enqueue(.complete("Replacement after restart")); restarted.performGenerationAction(source); try await finished(restarted)
            guard let saved = try h.archive.load(userId: h.owner).first?.messages else {
                throw ChatTestFailure(description: "The completed retry must really persist its conversation and lineage")
            }
            try await expect(!saved.contains(where: { $0.id == fixture.answer.id }) && saved.contains(failed)
                && saved.last?.content == "Replacement after restart" && saved.filter({ $0.role == .user }).count == 1, "Post-restart success follows only the same-user persisted lineage")
        }
        try await run("viewmodel-generation-rejects-old-turns-and-foreign-wrapper-owner-without-truncation") {
            let h = try await ChatHarness(); defer { h.close() }
            let turns = [message(.user, "One"), message(.assistant, "Answer one"), message(.user, "Two"),
                message(.assistant, "Answer two"), message(.user, "Three"), message(.assistant, "Answer three")]
            h.vm.messages = turns; try await h.vm.flushForDataExport(ownerId: h.owner); let files = try archiveFiles(h)
            try await expect(!h.vm.canPerformGenerationAction(from: turns[1]) && h.vm.canPerformGenerationAction(from: turns[5]), "Only the current final assistant offers a generation action")
            _ = try await failure { _ = try h.vm.makeGenerationActionSource(messageId: turns[1].id) }
            h.vm.regenerate(turns[1].id, userId: h.owner)
            h.vm.regenerate(turns[5].id, userId: "foreign-owner")
            try await expect(h.vm.messages == turns && (try archiveFiles(h)) == files && ChatFixtureURLProtocol.captured.isEmpty, "Old/foreign actions never truncate later turns or start a request")
        }
        try await run("viewmodel-generation-message-user-image-and-status-revisions-cannot-revive") {
            let h = try await ChatHarness(); defer { h.close() }
            for variant in 0..<5 {
                let fixture = generationFixture(h, text: "Partial", images: [try image(red: 0.2)])
                let source = try h.vm.makeGenerationActionSource(messageId: fixture.answer.id)
                switch variant {
                case 0: h.vm.messages[1].content = "Edited"; h.vm.messages[1].content = fixture.answer.content
                case 1: h.vm.messages[0].content = "Edited question"; h.vm.messages[0].content = fixture.user.content
                case 2: h.vm.messages[0].images = [try image(red: 0.8)]; h.vm.messages[0].images = fixture.user.images
                case 3: h.vm.messages[1].status = .completed; h.vm.messages[1].status = .failed
                default: h.vm.messages.removeLast(); h.vm.messages.append(fixture.answer)
                }
                h.vm.performGenerationAction(source)
                try await expect(h.vm.error != nil && ChatFixtureURLProtocol.captured.isEmpty, "An old confirmation cannot revive after a source edit, restoration or deletion")
            }
        }
        try await run("viewmodel-generation-like-feedback-keeps-ticket-valid") {
            let h = try await ChatHarness(); defer { h.close() }
            let fixture = generationFixture(h)
            let source = try h.vm.makeGenerationActionSource(messageId: fixture.answer.id)
            h.vm.toggleLike(fixture.answer.id)
            ChatFixtureURLProtocol.enqueue(.complete("After feedback")); h.vm.performGenerationAction(source); try await finished(h.vm)
            try await expect(ChatFixtureURLProtocol.captured.count == 1 && h.vm.messages.last?.content == "After feedback", "Like/dislike presentation does not alter original content consent")
        }
        try await run("viewmodel-generation-full-configuration-fingerprint-and-rejected-ticket-cannot-revive") {
            for variant in 0..<11 {
                let h = try await ChatHarness(); defer { h.close() }
                let fixture = generationFixture(h)
                let original = h.defaults.dictionaryRepresentation()
                let source = try h.vm.makeGenerationActionSource(messageId: fixture.answer.id)
                switch variant {
                case 0: h.defaults.set("https://api.example.com/changed/v1", forKey: h.byokPrefix + "url")
                case 1: h.defaults.set("https://api.example.com:8443/tenant-a/v1", forKey: h.byokPrefix + "url")
                case 2: h.defaults.set("openai-responses", forKey: h.byokPrefix + "protocol")
                case 3: h.defaults.set("changed-model", forKey: h.byokPrefix + "model")
                case 4: KeychainStore.set("changed-fixture-key", account: "byok-api-key.\(h.owner)")
                case 5: h.defaults.set("platform", forKey: h.prefix + "assistantMode")
                case 6: h.defaults.set("zh-Hans", forKey: h.prefix + "language")
                case 7: h.defaults.set(try JSONEncoder().encode(UserSettings(toxicLevel: "sharp")), forKey: h.prefix + "userSettings")
                case 8: h.defaults.set("INTL", forKey: h.prefix + "serviceRegion")
                case 9: h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
                default: h.defaults.set("platform/model:new", forKey: AssistantModelPreferences.key(ownerId: h.owner, region: "CN"))
                }
                h.vm.performGenerationAction(source)
                try await expect(ChatFixtureURLProtocol.captured.isEmpty && h.vm.error != nil && h.vm.messages == [fixture.user, fixture.answer], "Every effective configuration field is bound before confirmation")
                h.defaults.removePersistentDomain(forName: h.suite)
                for (key, value) in original { h.defaults.set(value, forKey: key) }
                KeychainStore.set("fixture-key", account: "byok-api-key.\(h.owner)")
                h.vm.performGenerationAction(source)
                try await expect(ChatFixtureURLProtocol.captured.isEmpty, "A ticket already rejected for changed configuration stays invalid after restoration")
            }
        }
        try await run("viewmodel-generation-actual-model-preference-save-and-restore-invalidates-old-ticket") {
            let h = try await ChatHarness(); defer { h.close() }
            h.defaults.set("platform", forKey: h.prefix + "assistantMode"); h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
            let fixture = generationFixture(h), source = try h.vm.makeGenerationActionSource(messageId: h.vm.messages.last!.id)
            try AssistantModelPreferences.save("provider/model:new", ownerId: h.owner, region: "CN", defaults: h.defaults)
            try AssistantModelPreferences.save("", ownerId: h.owner, region: "CN", defaults: h.defaults)
            h.vm.performGenerationAction(source)
            try await expect(h.vm.messages == [fixture.user, fixture.answer] && ChatFixtureURLProtocol.captured.isEmpty && h.vm.error != nil, "Actual owner-scoped preference notifications invalidate a restored configuration, without manual VM invalidation")
        }
        try await run("viewmodel-generation-other-owner-model-event-does-not-invalidate-current-ticket") {
            let h = try await ChatHarness(); defer { h.close() }
            let fixture = generationFixture(h), source = try h.vm.makeGenerationActionSource(messageId: h.vm.messages.last!.id)
            try AssistantModelPreferences.save("other/model:new", ownerId: "other-owner", region: "CN", defaults: h.defaults)
            ChatFixtureURLProtocol.enqueue(.complete("Still authorized for A")); h.vm.performGenerationAction(source); try await finished(h.vm)
            try await expect(h.vm.messages.contains(fixture.answer) && ChatFixtureURLProtocol.captured.count == 1, "Another account's real preference save cannot dismiss or invalidate A's action")
        }
        try await run("viewmodel-generation-nil-owner-configuration-event-invalidates-test-ticket") {
            let h = try await ChatHarness(); defer { h.close() }
            _ = generationFixture(h); let source = try h.vm.makeGenerationActionSource(messageId: h.vm.messages.last!.id)
            NotificationCenter.default.post(name: Notification.Name("assistant.generationConfigurationChanged"), object: nil)
            h.vm.performGenerationAction(source)
            try await expect(ChatFixtureURLProtocol.captured.isEmpty && h.vm.error != nil, "Explicit nil-owner configuration events invalidate the active confirmation")
        }
        try await run("viewmodel-generation-owner-and-conversation-roundtrips-refuse-old-confirmation") {
            for changeOwner in [false, true] {
                let h = try await ChatHarness(); defer { h.close() }
                let fixture = generationFixture(h); try await h.vm.flushForDataExport(ownerId: h.owner)
                guard let original = try h.archive.load(userId: h.owner).first else {
                    throw ChatTestFailure(description: "Explicit export flush must really persist the original generation before an owner or conversation roundtrip")
                }
                let source = try h.vm.makeGenerationActionSource(messageId: fixture.answer.id)
                if changeOwner {
                    AuthService.shared.user = ChatFixtureUser(id: "owner-B"); h.vm.activateOwner()
                    AuthService.shared.user = ChatFixtureUser(id: h.owner); h.vm.activateOwner(); try await h.vm.waitForArchiveReady(ownerId: h.owner)
                } else { try await newConversation(h.vm); (await h.vm.openConversation(original)) }
                try await expect(h.vm.conversationId == source.conversationId, "Fixture returns to the exact prior conversation")
                h.vm.performGenerationAction(source)
                try await expect(ChatFixtureURLProtocol.captured.isEmpty && !h.vm.isLoading && h.vm.messages == original.messages, "Returning to the same IDs cannot revive an expired scope")
            }
        }
        try await run("viewmodel-generation-byok-confirmation-resumes-retry-not-the-current-draft") {
            let h = try await ChatHarness(); defer { h.close() }
            h.addMemory(text: "A private contextual preference")
            let originalImage = try image(red: 0.2), draftImage = try image(red: 0.8)
            let fixture = generationFixture(h, images: [originalImage])
            h.vm.inputText = "Never send this current draft"; h.vm.pendingImages = [draftImage]
            let source = try h.vm.makeGenerationActionSource(messageId: fixture.answer.id)
            h.vm.performGenerationAction(source)
            try await expect(h.vm.requiresBYOKConfirmation && h.vm.pendingDestination.contains("/tenant-a/v1/chat/completions")
                && ChatFixtureURLProtocol.captured.isEmpty && h.vm.messages.count == 2, "History/memory consent queues a generation intent and exposes its complete target without sending")
            ChatFixtureURLProtocol.enqueue(.complete("Confirmed retry")); h.vm.confirmBYOKContext(); try await finished(h.vm)
            let strings = jsonStrings(try body())
            try await expect(strings.contains(fixture.user.content) && strings.contains(originalImage.dataURL)
                && !strings.contains("Never send this current draft") && !strings.contains(draftImage.dataURL), "Confirmation sends only the captured original prompt and attachments")
            try await expect(h.vm.inputText == "Never send this current draft" && h.vm.pendingImages == [draftImage]
                && h.vm.messages.filter({ $0.role == .user }).map(\.id) == [fixture.user.id], "A generation intent never consumes or appends the unrelated draft")
        }
        try await run("viewmodel-generation-rejecting-byok-confirmation-leaves-zero-requests") {
            let h = try await ChatHarness(); defer { h.close() }
            h.addMemory(text: "Private context"); let fixture = generationFixture(h)
            h.vm.performGenerationAction(try h.vm.makeGenerationActionSource(messageId: fixture.answer.id))
            try await expect(h.vm.requiresBYOKConfirmation, "Fixture queues confirmation")
            h.vm.rejectBYOKContext(); h.vm.confirmBYOKContext()
            try await expect(!h.vm.requiresBYOKConfirmation && h.vm.pendingDestination.isEmpty && h.vm.messages == [fixture.user, fixture.answer]
                && ChatFixtureURLProtocol.captured.isEmpty, "Rejecting a pending retry cannot become approval or send an unrelated draft")
        }
        try await run("viewmodel-generation-pending-byok-source-config-owner-and-conversation-changes-refuse") {
            for variant in 0..<5 {
                let h = try await ChatHarness(); defer { h.close() }
                h.addMemory(text: "Private pending context"); let fixture = generationFixture(h, images: [try image(red: 0.2)])
                h.vm.performGenerationAction(try h.vm.makeGenerationActionSource(messageId: fixture.answer.id))
                try await expect(h.vm.requiresBYOKConfirmation, "Fixture must pause before network")
                switch variant {
                case 0: h.vm.messages[0].content = "New original question"
                case 1: h.vm.messages[0].images = [try image(red: 0.8)]
                case 2: h.defaults.set("another-model", forKey: h.byokPrefix + "model")
                case 3: AuthService.shared.user = ChatFixtureUser(id: "owner-B"); h.vm.activateOwner()
                default: h.vm.rejectBYOKContext(); try await newConversation(h.vm)
                }
                let messages = h.vm.messages
                h.vm.confirmBYOKContext()
                try await expect(ChatFixtureURLProtocol.captured.isEmpty && h.vm.messages == messages && !h.vm.requiresBYOKConfirmation, "Delayed BYOK approval revalidates generation source rather than sending old or current input")
            }
        }
        try await run("viewmodel-normal-byok-confirmation-binds-draft-and-images-even-after-revert") {
            let h = try await ChatHarness(); defer { h.close() }
            h.addMemory(text: "Private preference"); let originalImage = try image(red: 0.2)
            h.vm.inputText = "Captured normal-send draft"; h.vm.pendingImages = [originalImage]
            h.vm.sendMessage(userId: h.owner)
            h.vm.inputText = "Edited after confirmation"; h.vm.inputText = "Captured normal-send draft"
            h.vm.confirmBYOKContext()
            try await expect(ChatFixtureURLProtocol.captured.isEmpty && h.vm.messages.isEmpty && h.vm.pendingImages == [originalImage], "Restoring old draft text cannot revive a previously displayed approval")
            h.vm.sendMessage(userId: h.owner)
            h.vm.pendingImages = [try image(red: 0.8)]; h.vm.pendingImages = [originalImage]
            h.vm.confirmBYOKContext()
            try await expect(ChatFixtureURLProtocol.captured.isEmpty && h.vm.messages.isEmpty && h.vm.inputText == "Captured normal-send draft", "Attachment changes also invalidate ordinary-send confirmation without losing the draft")
        }
        try await run("viewmodel-platform-retry-reuses-server-conversation-and-original-client-message") {
            let h = try await ChatHarness(); defer { h.close() }
            h.defaults.set("platform", forKey: h.prefix + "assistantMode"); h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
            ChatFixtureURLProtocol.enqueue(.conversation("retry-server-id")); ChatFixtureURLProtocol.enqueue(.httpError)
            h.vm.inputText = "Platform original"; h.vm.sendMessage(userId: h.owner)
            try await wait("platform original failure") { !h.vm.isLoading }
            let user = h.vm.messages[0], failed = h.vm.messages[1]
            h.vm.inputText = "Do not send this platform draft"
            let source = try h.vm.makeGenerationActionSource(messageId: failed.id)
            ChatFixtureURLProtocol.enqueue(.complete("Platform retried")); h.vm.performGenerationAction(source); try await finished(h.vm)
            let payload = try body(2)
            try await expect(ChatFixtureURLProtocol.captured.count == 3
                && ChatFixtureURLProtocol.captured[2].url?.path == "/api/v2/conversations/retry-server-id/messages"
                && payload["conversationId"] as? String == "retry-server-id" && payload["clientMessageId"] as? String == user.id, "Platform retries reuse the validated server route and original client user identity")
            try await expect(payload["requestId"] as? String != failed.requestId
                && payload["requestId"] as? String == ChatFixtureURLProtocol.captured[2].value(forHTTPHeaderField: "Idempotency-Key")
                && h.vm.inputText == "Do not send this platform draft" && h.vm.messages.filter({ $0.role == .user }).count == 1, "Each explicit attempt gets a new idempotency identity without a duplicate user or draft loss")
        }
        try await run("viewmodel-platform-generation-retry-uses-server-generation-route") {
            let h = try await ChatHarness(); defer { h.close() }
            h.defaults.set("platform", forKey: h.prefix + "assistantMode"); h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
            ChatFixtureURLProtocol.enqueue(.conversation("generation-retry-server-id")); ChatFixtureURLProtocol.enqueue(.complete("Original answer"))
            h.vm.inputText = "Retry the platform generation"; h.vm.sendMessage(userId: h.owner)
            try await finished(h.vm)
            let original = h.vm.messages[1]
            h.vm.messages[1].status = .failed
            let source = try h.vm.makeGenerationActionSource(messageId: original.id)
            ChatFixtureURLProtocol.enqueue(.complete("Retried through generation")); h.vm.performGenerationAction(source); try await finished(h.vm)
            let request = ChatFixtureURLProtocol.captured[2]
            let payload = try body(2)
            try await expect(request.url?.path == "/api/v2/generations/fixture-generation/retry"
                && payload["conversationId"] as? String == "generation-retry-server-id"
                && payload["clientMessageId"] as? String == h.vm.messages[0].id,
                "A bound generation retry must use the server generation route while retaining the original conversation and client message")
        }
        try await run("viewmodel-generation-lineage-cannot-delete-another-user-turn") {
            let h = try await ChatHarness(); defer { h.close() }
            let old = message(.assistant, "Unrelated earlier completed reply")
            var failed = message(.assistant, "Failure", status: .failed); failed.replacesMessageId = old.id
            let values = [message(.user, "Earlier question"), old, message(.user, "Current question"), failed]
            h.vm.messages = values
            _ = try await failure { _ = try h.vm.makeGenerationActionSource(messageId: failed.id) }
            try await expect(h.vm.messages == values && ChatFixtureURLProtocol.captured.isEmpty, "Persisted foreign lineage cannot be used to replace a different user turn")
        }
        try await run("viewmodel-generation-success-does-not-remove-predecessor-edited-during-stream") {
            let h = try await ChatHarness(); defer { h.close() }
            let fixture = generationFixture(h, status: .completed, text: "Original before explicit edit")
            ChatFixtureURLProtocol.enqueue(.hold("New candidate text"))
            h.vm.performGenerationAction(try h.vm.makeGenerationActionSource(messageId: fixture.answer.id))
            try await wait("new candidate stream") { h.vm.messages.last?.content == "New candidate text" }
            h.vm.messages[1].content = "User-modified predecessor while generating"
            ChatFixtureURLProtocol.completeHeld(); try await finished(h.vm)
            try await expect(h.vm.messages.contains(where: { $0.id == fixture.answer.id && $0.content == "User-modified predecessor while generating" })
                && h.vm.messages.last?.content == "New candidate text", "A late successful replacement cannot erase a changed predecessor snapshot")
        }
        try await run("viewmodel-generation-pre-cancelled-ticket-creation-and-performance-have-no-request") {
            let h = try await ChatHarness(); defer { h.close() }
            let fixture = generationFixture(h), source = try h.vm.makeGenerationActionSource(messageId: h.vm.messages.last!.id)
            let cancelled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try await failure { _ = try h.vm.makeGenerationActionSource(messageId: fixture.answer.id) }
                h.vm.performGenerationAction(source)
            }
            try await cancelled.value
            try await expect(ChatFixtureURLProtocol.captured.isEmpty && h.vm.messages == [fixture.user, fixture.answer], "Cancellation cannot authorize a new attempt or mutate history")
        }
        try await run("viewmodel-action-memory-save-without-authorization-keeps-context-empty") {
            let h = try await ChatHarness(); defer { h.close() }
            let value = message(.assistant, "Source suggestion"); h.vm.messages = [value]
            let source = try h.vm.makeActionSource(messageId: value.id)
            var requested = actionMemory(owner: h.owner, text: "Distinct locally edited private fact")
            requested.consent = "unconfirmed"
            try h.vm.saveMemoryFromMessage(requested, source: source)
            let stored = h.repository.memories(for: h.owner).first!
            try await expect(stored.consent == "unconfirmed" && stored.status == .active
                && stored.sourceMessageId == value.id && stored.text == requested.text && !AssistantMemoryAuthorizationPolicy.allowsUse(of: stored),
                "Save without authorization preserves the real edited record and authoritative provenance")
            let reloaded = AssistantLocalRepository(fileURL: h.directory.appendingPathComponent("repository.json")).memories(for: h.owner).first!
            try await expect(reloaded.consent == "unconfirmed" && reloaded.text == requested.text, "Unconfirmed state survives a real disk reload")
            try await expect(AssistantContextBuilder.build(userId: h.owner, query: "private fact", repository: h.repository).memories.isEmpty,
                "Saved unconfirmed records cannot enter personal context")
            do { try h.vm.validateActionSource(source); throw ChatTestFailure(description: "Unconfirmed success must consume its source ticket") }
            catch AssistantChatActionError.alreadySaved { }
            h.vm.inputText = "New question"; h.vm.sendMessage(userId: h.owner)
            try await expect(h.vm.requiresBYOKConfirmation, "Existing conversation history retains the normal BYOK confirmation")
            h.vm.confirmBYOKContext(); try await finished(h.vm)
            let payload = try body(), messages = payload["messages"] as! [[String: Any]]
            try await expect(!(messages.first?["content"] as? String ?? "").contains(requested.text), "Actual model instructions exclude saved unconfirmed text")
        }
        try await run("viewmodel-action-memory-rejects-forged-consent-without-consuming-ticket") {
            let h = try await ChatHarness(); defer { h.close() }
            let value = message(.assistant, "Only the user's chosen consent is valid"); h.vm.messages = [value]
            let source = try h.vm.makeActionSource(messageId: value.id)
            for consent in ["automatic", "inferred", "unknown", "confirmed", "EXPLICIT", " explicit ", "revoked", ""] {
                var record = actionMemory(owner: h.owner); record.consent = consent
                do { try h.vm.saveMemoryFromMessage(record, source: source); throw ChatTestFailure(description: "Forged consent unexpectedly saved") }
                catch AssistantRepositoryError.invalidRecord { }
                try h.vm.validateActionSource(source)
            }
            var inactive = actionMemory(owner: h.owner); inactive.status = .deleted
            do { try h.vm.saveMemoryFromMessage(inactive, source: source); throw ChatTestFailure(description: "A deleted candidate cannot create active authorization") }
            catch AssistantRepositoryError.invalidRecord { }
            try h.vm.validateActionSource(source)
            try await expect(h.repository.memories(for: h.owner).isEmpty && ChatFixtureURLProtocol.captured.isEmpty, "Rejected records never insert, authorize, or call the model")
            var valid = actionMemory(owner: h.owner); valid.consent = "unconfirmed"
            try h.vm.saveMemoryFromMessage(valid, source: source)
            do { try h.vm.validateActionSource(source); throw ChatTestFailure(description: "Successful save did not consume ticket") }
            catch AssistantChatActionError.alreadySaved { }
        }
        try await run("viewmodel-platform-auth-wait-rechecks-all-memory-authorizations") {
            for change in ["revoke", "delete", "global", "category"] {
                let h = try await ChatHarness(); defer { h.close() }
                h.defaults.set("platform", forKey: h.prefix + "assistantMode")
                h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
                h.addMemory(text: "Private authorized memory before auth wait")
                let gate = ChatFixtureAsyncGate(); defer { gate.open() }
                let before = AuthService.shared.accessTokenRequests
                AuthService.shared.holdNextAccessToken(gate)
                h.vm.inputText = "Original platform question"; h.vm.sendMessage(userId: h.owner)
                try await wait("auth refresh gate entered") { AuthService.shared.accessTokenRequests == before + 1 }
                try await changeMemoryAuthorization(change, harness: h)
                h.vm.inputText = "Keep my newer unsent draft"; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
                gate.open()
                try await wait("context rejection after auth") { !h.vm.isLoading }
                await h.vm.waitForPendingArchiveWrites()
                try await expect(ChatFixtureURLProtocol.captured.isEmpty, "Auth-wait revocation must stop before conversation creation or model POST")
                try await expect(h.vm.messages.first?.content == "Original platform question" && h.vm.messages.last?.status == .failed
                    && h.vm.error == AssistantContextAuthorizationError.changed.localizedDescription,
                    "The original question remains with a visible retry-required context failure")
                try await expect(h.vm.inputText == "Keep my newer unsent draft" && h.archive.loadDraft(userId: h.owner) == h.vm.inputText,
                    "An authorization failure preserves both current and persisted unsent drafts")
            }
        }
        try await run("viewmodel-platform-create-wait-rechecks-all-memory-authorizations") {
            for change in ["revoke", "delete", "global", "category"] {
                let h = try await ChatHarness(); defer { h.close() }
                h.defaults.set("platform", forKey: h.prefix + "assistantMode")
                h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
                h.addMemory(text: "Private authorized memory before create wait")
                ChatFixtureURLProtocol.enqueue(.holdConversation)
                h.vm.inputText = "Original platform question"; h.vm.sendMessage(userId: h.owner)
                try await wait("server conversation creation held") { ChatFixtureURLProtocol.captured.count == 1 }
                try await expect(ChatFixtureURLProtocol.captured[0].url?.path == "/api/v2/conversations", "The gate holds a real server creation request, not a model request")
                try await changeMemoryAuthorization(change, harness: h)
                h.vm.inputText = "Draft typed while creating"; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
                ChatFixtureURLProtocol.completeHeldConversation(id: "held-server-id")
                try await wait("context rejection after creation") { !h.vm.isLoading }
                await h.vm.waitForPendingArchiveWrites()
                try await expect(ChatFixtureURLProtocol.captured.count == 1 && h.vm.messages.last?.status == .failed
                    && h.vm.error == AssistantContextAuthorizationError.changed.localizedDescription,
                    "A valid creation response cannot release a model POST containing stale authorized context")
                try await expect(h.vm.messages.first?.content == "Original platform question" && h.vm.inputText == "Draft typed while creating"
                    && h.archive.loadDraft(userId: h.owner) == h.vm.inputText, "Refusal preserves the original turn and both drafts without automatic resend")
            }
        }
        try await run("viewmodel-platform-create-wait-does-not-silently-add-new-memory") {
            let h = try await ChatHarness(); defer { h.close() }
            h.defaults.set("platform", forKey: h.prefix + "assistantMode")
            h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
            h.addMemory(text: "Newly authorized content requires a fresh attempt", consent: "unconfirmed")
            ChatFixtureURLProtocol.enqueue(.holdConversation)
            h.vm.inputText = "Original question"; h.vm.sendMessage(userId: h.owner)
            try await wait("creation before new authorization") { ChatFixtureURLProtocol.captured.count == 1 }
            let original = h.repository.memories(for: h.owner).first!
            var authorized = original; authorized.consent = "confirmed"
            try await expect(h.repository.updateMemory(authorized, expecting: original), "The new explicit authorization must persist")
            ChatFixtureURLProtocol.completeHeldConversation(id: "new-grant-server")
            try await wait("new authorization context refusal") { !h.vm.isLoading }
            try await expect(ChatFixtureURLProtocol.captured.count == 1 && h.vm.error == AssistantContextAuthorizationError.changed.localizedDescription,
                "Prepared empty context is rejected rather than silently enriched or automatically resent")
        }
        try await run("viewmodel-byok-confirmation-reprepares-current-memory-context") {
            let h = try await ChatHarness(); defer { h.close() }
            let privateText = "Private memory revoked before BYOK confirmation"
            h.addMemory(text: privateText)
            h.vm.inputText = "Question awaiting confirmation"; h.vm.sendMessage(userId: h.owner)
            try await expect(h.vm.requiresBYOKConfirmation && ChatFixtureURLProtocol.captured.isEmpty, "Personal context requires normal destination confirmation")
            try await changeMemoryAuthorization("revoke", harness: h)
            h.vm.confirmBYOKContext(); try await finished(h.vm)
            let payload = try body(), messages = payload["messages"] as! [[String: Any]]
            try await expect(ChatFixtureURLProtocol.captured.count == 1 && !(messages.first?["content"] as? String ?? "").contains(privateText),
                "BYOK confirmation preserves its existing fresh preparation and never sends the earlier revoked snapshot")
        }
        try await run("viewmodel-revocation-does-not-claim-an-inflight-request-was-unsent") {
            let h = try await ChatHarness(); defer { h.close() }
            let privateText = "Authorized when the model request began"
            h.addMemory(text: privateText)
            ChatFixtureURLProtocol.enqueue(.hold("Already emitted response"))
            h.vm.inputText = "Already sent question"; h.vm.sendMessage(userId: h.owner)
            h.vm.confirmBYOKContext()
            try await wait("actual model request already streaming") { ChatFixtureURLProtocol.captured.count == 1 && h.vm.messages.last?.content == "Already emitted response" }
            try await changeMemoryAuthorization("revoke", harness: h)
            ChatFixtureURLProtocol.completeHeld(); try await finished(h.vm)
            let payload = try body(), messages = payload["messages"] as! [[String: Any]]
            try await expect((messages.first?["content"] as? String ?? "").contains(privateText) && ChatFixtureURLProtocol.captured.count == 1,
                "Already-transmitted context cannot be retracted or misrepresented as a new unsent request")
            try await expect(h.vm.messages.last?.content == "Already emitted response" && h.vm.error == nil, "Future authorization changes do not fabricate a failed past send or automatic retry")
        }
        try await run("viewmodel-actual-startup-queue-rechecks-memory-before-any-http-start") {
            for change in ["revoke", "delete", "global", "category"] {
                let gate = ChatFixtureAsyncGate(); defer { gate.open() }
                let h = try await ChatHarness(startupBarrier: { await gate.wait() }); defer { h.close() }
                h.addMemory(text: "Private context authorized when this request was prepared")
                h.vm.inputText = "Held model startup question"; h.vm.sendMessage(userId: h.owner)
                try await expect(h.vm.requiresBYOKConfirmation, "Authorized context keeps the normal complete-destination confirmation")
                h.vm.confirmBYOKContext()
                try await wait("transport startup queue entered after VM checks") { gate.enteredCount == 1 }
                try await expect(h.vm.isLoading && ChatFixtureURLProtocol.captured.isEmpty, "The transport producer is queued before URLSession starts any HTTP request")
                try await changeMemoryAuthorization(change, harness: h)
                h.vm.inputText = "Draft preserved across queued startup rejection"; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
                gate.open()
                try await wait("startup hook rejects revoked context") { !h.vm.isLoading }
                await h.vm.waitForPendingArchiveWrites()
                try await expect(ChatFixtureURLProtocol.captured.isEmpty && h.vm.messages.last?.status == .failed
                    && h.vm.error == AssistantContextAuthorizationError.changed.localizedDescription,
                    "Revoking record/global/category or deleting while transport is queued must produce zero HTTP starts")
                try await expect(h.vm.messages.first?.content == "Held model startup question"
                    && h.vm.inputText == "Draft preserved across queued startup rejection"
                    && h.archive.loadDraft(userId: h.owner) == h.vm.inputText, "Strict startup refusal preserves the original turn and live/disk drafts")
            }
        }
        try await run("viewmodel-actual-startup-queue-owner-switch-never-sends-old-owner") {
            let gate = ChatFixtureAsyncGate(); defer { gate.open() }
            let h = try await ChatHarness(owner: "queued-owner-a", startupBarrier: { await gate.wait() }); defer { h.close() }
            h.addMemory(text: "Owner A private memory")
            h.vm.inputText = "Owner A queued question"; h.vm.sendMessage(userId: h.owner)
            h.vm.confirmBYOKContext()
            try await wait("owner A transport queued") { gate.enteredCount == 1 }
            try await expect(ChatFixtureURLProtocol.captured.isEmpty, "A has not started an HTTP task before account transition")
            let ownerB = "queued-owner-b"; try await h.configure(owner: ownerB)
            KeychainStore.set("owner-b-fixture-key", account: "byok-api-key." + ownerB)
            AuthService.shared.user = ChatFixtureUser(id: ownerB); h.vm.activateOwner()
            gate.open()
            try await expect(h.vm.activeOwner == ownerB && !h.vm.isLoading && h.vm.messages.isEmpty, "The real owner transition cancels A and isolates B's visible state")
            try await send(h, "Owner B fresh question")
            let requests = ChatFixtureURLProtocol.captured
            try await expect(requests.count == 1 && requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer owner-b-fixture-key",
                "Only B's fresh producer may start HTTP after A's queued operation is released")
            let payload = try body(), messages = payload["messages"] as! [[String: Any]]
            try await expect(!(messages.first?["content"] as? String ?? "").contains("Owner A private memory")
                && h.vm.messages.first?.content == "Owner B fresh question", "A's prepared body never crosses to B or revives after release")
        }
        try await run("viewmodel-actual-startup-queue-binds-full-configuration-and-epoch") {
            for change in ["destination", "key", "protocol-model", "change-and-revert"] {
                let gate = ChatFixtureAsyncGate(); defer { gate.open() }
                let h = try await ChatHarness(startupBarrier: { await gate.wait() }); defer { h.close() }
                h.vm.inputText = "Prepared using the original complete configuration"; h.vm.sendMessage(userId: h.owner)
                try await wait("configuration-bound model startup queued") { gate.enteredCount == 1 }
                try await expect(ChatFixtureURLProtocol.captured.isEmpty, "Configuration mutation occurs after producer queuing and before HTTP start")
                switch change {
                case "destination": h.defaults.set("https://api.example.com/tenant-b/v1", forKey: h.byokPrefix + "url")
                case "key": KeychainStore.set("new-key-must-not-use-old-destination", account: "byok-api-key." + h.owner)
                case "protocol-model":
                    h.defaults.set(AssistantWireProtocol.anthropic.rawValue, forKey: h.byokPrefix + "protocol")
                    h.defaults.set("changed-model", forKey: h.byokPrefix + "model")
                default:
                    let originalURL = h.defaults.string(forKey: h.byokPrefix + "url")!
                    h.defaults.set("https://api.example.com/temporary/v1", forKey: h.byokPrefix + "url")
                    h.vm.generationConfigurationDidChange()
                    h.defaults.set(originalURL, forKey: h.byokPrefix + "url")
                    h.vm.generationConfigurationDidChange()
                }
                h.vm.inputText = "Keep configuration-change draft"; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
                gate.open()
                try await wait("startup configuration refusal") { !h.vm.isLoading }
                await h.vm.waitForPendingArchiveWrites()
                try await expect(ChatFixtureURLProtocol.captured.isEmpty && h.vm.messages.last?.status == .failed
                    && h.vm.error == AssistantGenerationActionError.changed.localizedDescription,
                    "The startup guard rejects changed destination/key/protocol/model and configuration ABA with zero HTTP starts")
                try await expect(h.vm.messages.first?.content == "Prepared using the original complete configuration"
                    && h.vm.inputText == "Keep configuration-change draft"
                    && h.archive.loadDraft(userId: h.owner) == h.vm.inputText, "A refused stale request never clears history or current drafts")
            }
        }
        try await run("viewmodel-switch-request-and-cancel-preserve-all-current-state") {
            let h = try await ChatHarness(); defer { h.close() }
            h.vm.messages = [message(.user, "Current history"), message(.assistant, "Current answer")]
            let picture = try image(); h.vm.inputText = "  Exact unsent source\n"; h.vm.pendingImages = [picture]
            try await h.vm.flushForDataExport(ownerId: h.owner)
            let target = try targetHistory(h), before = try archiveFiles(h), selected = h.vm.conversationId, messages = h.vm.messages
            try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "A nonempty draft must request explicit confirmation")
            let ticket = try pendingSwitch(h)
            try await expect(ticket.ownerId == h.owner && ticket.sourceConversationId == selected && ticket.targetConversationId == target.id
                && ticket.hasDraft && !ticket.willStopGeneration && !ticket.isNewConversation && !ticket.isRecoveringDeletedConversation, "The public ticket describes the actual protected transition")
            try await expect(try archiveFiles(h) == before && h.vm.messages == messages && h.vm.inputText == "  Exact unsent source\n"
                && h.vm.pendingImages == [picture] && ChatFixtureURLProtocol.captured.isEmpty, "Opening confirmation does not write, clear, or call the model")
            h.vm.rejectConversationSwitch()
            try await expect(!h.vm.requiresConversationSwitchConfirmation && h.vm.pendingConversationSwitch == nil
                && h.vm.conversationId == selected && h.vm.messages == messages && h.vm.pendingImages == [picture], "Default cancellation preserves exact UI state")
            try await expect(!(await h.vm.confirmConversationSwitch(ticket)) && h.vm.conversationSwitchError != nil, "A cancelled ticket cannot later authorize a switch")
            try await expect(try archiveFiles(h) == before, "A stale cancelled callback cannot write the archive")
        }
        try await run("viewmodel-confirmed-switch-saves-source-and-restores-latest-target-draft") {
            let h = try await ChatHarness(); defer { h.close() }
            let sourceId = h.vm.conversationId, sourcePicture = try image(red: 0.1), targetPicture = try image(red: 0.8)
            h.vm.messages = [message(.user, "Current question"), message(.assistant, "Current answer")]
            try h.archive.saveDraft("Stale source disk draft", conversationId: sourceId, userId: h.owner)
            h.vm.inputText = "  Latest source draft\n"; h.vm.pendingImages = [sourcePicture]
            let target = try targetHistory(h), unrelatedId = "unrelated-draft"
            try h.archive.saveDraft("First target draft", conversationId: target.id, userId: h.owner)
            try h.archive.saveDraft("Unrelated private draft", images: [sourcePicture], conversationId: unrelatedId, userId: h.owner)
            try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "Source draft requires confirmation")
            let ticket = try pendingSwitch(h)
            let latest = Conversation(id: target.id, title: "Latest target title", preview: "Latest target preview", date: Date(),
                messages: [message(.user, "Updated after request")], serverConversationId: "verified-target-server")
            try h.archive.upsert(latest, userId: h.owner)
            try h.archive.saveDraft("Latest target draft", images: [targetPicture], conversationId: target.id, userId: h.owner)
            h.vm.requiresConversationSwitchConfirmation = false // SwiftUI dismisses before invoking the button callback.
            try await expect((await h.vm.confirmConversationSwitch(ticket)), "Confirmation must depend on the pending ticket, not presentation Bool")
            try await expect(h.vm.conversationId == target.id && h.vm.messages == latest.messages && h.vm.inputText == "Latest target draft"
                && h.vm.pendingImages == [targetPicture], "Commit re-reads target history and restores its newest complete draft")
            let savedSource = try h.archive.loadDraftRecord(conversationId: sourceId, userId: h.owner)
            try await expect(savedSource.text == "  Latest source draft\n" && savedSource.images == [sourcePicture], "The exact visible source draft is saved instead of stale disk text")
            try await expect(try h.archive.loadDraftRecord(conversationId: unrelatedId, userId: h.owner).text == "Unrelated private draft", "Unrelated inactive drafts survive switching")
            try await h.vm.flushForDataExport(ownerId: h.owner)
            try await expect(try h.archive.load(userId: h.owner).first(where: { $0.id == target.id })?.serverConversationId == "verified-target-server", "Verified server/local association remains attached to the target")
            try await expect(ChatFixtureURLProtocol.captured.isEmpty, "Continuation navigation never sends or restores generation automatically")
        }
        try await run("viewmodel-draft-only-source-is-reachable-with-text-images-and-restart") {
            for sourceText in ["Unsent source text\n", ""] {
                let h = try await ChatHarness(); defer { h.close() }
                let sourceId = h.vm.conversationId, picture = try image()
                h.vm.inputText = sourceText; h.vm.pendingImages = [picture]
                let target = try targetHistory(h)
                try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "A draft-only source still needs confirmation")
                try await expect((await h.vm.confirmConversationSwitch(try pendingSwitch(h))), "Draft-only source switching must commit")
                let source = try h.archive.load(userId: h.owner).first(where: { $0.id == sourceId })
                try await expect(source?.messages.isEmpty == true && !(source?.title.isEmpty ?? true), "The unsent source gets a discoverable history row without fake sent messages")
                try await expect((await h.vm.requestOpenConversation(id: sourceId, ownerId: h.owner)), "An empty target draft permits an immediate safe return to the saved source")
                try await expect(h.vm.messages.isEmpty && h.vm.inputText == sourceText && h.vm.pendingImages == [picture], "Returning restores complete text/image source draft")
                let restarted = ChatViewModel(archive: h.archive, transport: h.transport, conversationClient: h.conversationClient, repository: h.repository, defaults: h.defaults)
                try await restarted.waitForArchiveReady(ownerId: h.owner)
                defer { restarted.cancel() }
                try await expect(restarted.conversationId == sourceId && restarted.messages.isEmpty && restarted.inputText == sourceText
                    && restarted.pendingImages == [picture] && restarted.pendingConversationSwitch == nil, "Cold restoration does not accidentally enter a switch confirmation")
                try await expect(ChatFixtureURLProtocol.captured.isEmpty, "Draft-only reachability never calls the model")
            }
        }
        try await run("viewmodel-new-conversation-prefill-preserves-source-and-never-sends") {
            let h = try await ChatHarness(); defer { h.close() }
            let sourceId = h.vm.conversationId, picture = try image()
            h.vm.inputText = "Keep source text"; h.vm.pendingImages = [picture]
            let prompt = "  Explicit new prefill\n"
            try await expect(!(await h.vm.requestNewConversation(ownerId: h.owner, initialText: prompt)), "A shortcut cannot overwrite a live draft without confirmation")
            let cancelled = try pendingSwitch(h); h.vm.rejectConversationSwitch()
            try await expect(h.vm.inputText == "Keep source text" && h.vm.pendingImages == [picture], "Cancelling a shortcut keeps source draft intact")
            try await expect(!(await h.vm.requestNewConversation(ownerId: h.owner, initialText: prompt)), "A new request needs a fresh confirmation")
            let ticket = try pendingSwitch(h)
            try await expect(ticket.id != cancelled.id && ticket.isNewConversation, "Each new-conversation intent gets a fresh ticket")
            try await expect((await h.vm.confirmConversationSwitch(ticket)), "An explicit new conversation can commit after saving its source")
            try await expect(h.vm.messages.isEmpty && h.vm.inputText == prompt && h.vm.pendingImages.isEmpty
                && h.vm.conversationId == ticket.targetConversationId, "Prefill is a new draft, never a sent user turn or copied old image")
            let old = try h.archive.loadDraftRecord(conversationId: sourceId, userId: h.owner)
            try await expect(old.text == "Keep source text" && old.images == [picture], "Shortcut commit retains the old draft under its own conversation")
            let restarted = ChatViewModel(archive: h.archive, transport: h.transport, conversationClient: h.conversationClient, repository: h.repository, defaults: h.defaults)
            try await restarted.waitForArchiveReady(ownerId: h.owner)
            defer { restarted.cancel() }
            try await expect(restarted.conversationId == ticket.targetConversationId && restarted.inputText == prompt && restarted.messages.isEmpty, "An unarchived new draft restores by its active pointer")
            try await expect(ChatFixtureURLProtocol.captured.isEmpty, "Prefill never auto-sends")
        }
        try await run("viewmodel-empty-new-switch-does-not-create-phantom-history") {
            let h = try await ChatHarness(); defer { h.close() }
            let sourceId = h.vm.conversationId
            try await expect((await h.vm.requestNewConversation(ownerId: h.owner)), "A completely empty source does not need confirmation")
            try await expect(!h.vm.requiresConversationSwitchConfirmation && h.vm.messages.isEmpty && h.vm.inputText.isEmpty, "The new target remains an empty local session")
            try await expect(try h.archive.load(userId: h.owner).allSatisfy { $0.id != sourceId }, "An empty source must not manufacture a history row")
            let before = try archiveFiles(h)
            try await expect((await h.vm.requestOpenConversation(id: h.vm.conversationId, ownerId: h.owner)), "Opening the already-selected session is a no-op")
            try await expect(try archiveFiles(h) == before && ChatFixtureURLProtocol.captured.isEmpty, "Same-conversation navigation does not rewrite or send")
        }
        try await run("viewmodel-pending-byok-confirmation-blocks-switch-and-shortcut") {
            let h = try await ChatHarness(); defer { h.close() }
            h.addMemory(text: "Requires complete destination consent")
            let target = try targetHistory(h)
            h.vm.inputText = "Question awaiting BYOK confirmation"; h.vm.sendMessage(userId: h.owner)
            try await expect(h.vm.requiresBYOKConfirmation, "Fixture must own a real pending BYOK intent")
            try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner))
                && h.vm.conversationSwitchError == AssistantConversationSwitchError.pendingBYOK.localizedDescription, "History navigation cannot silently discard a pending send confirmation")
            try await expect(!(await h.vm.requestNewConversation(ownerId: h.owner, initialText: "Shortcut")) && h.vm.requiresBYOKConfirmation
                && h.vm.inputText == "Question awaiting BYOK confirmation" && h.vm.pendingConversationSwitch == nil, "Shortcut must leave the old pending intent and draft unchanged")
            h.vm.rejectBYOKContext()
            try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)) && h.vm.pendingConversationSwitch != nil, "After explicit BYOK rejection, normal draft protection applies")
            h.vm.rejectConversationSwitch()
            try await expect(ChatFixtureURLProtocol.captured.isEmpty, "No switch or confirmation rejection sends requests")
        }
        try await run("viewmodel-image-preparation-gate-blocks-switch-without-cancelling-import") {
            let gate = ChatFixtureAsyncGate(); defer { gate.open() }
            let h = try await ChatHarness(imagePreparationBarrier: { await gate.wait() }); defer { h.close() }
            let target = try targetHistory(h), sourceId = h.vm.conversationId, bytes = try image().data!
            let importing = Task { await h.vm.addImageData(bytes, ownerId: h.owner, conversationId: sourceId) }
            try await wait("image preparation entered") { gate.enteredCount == 1 }
            let preparingImage = h.vm.isPreparingImage
            let openedDuringImageImport = await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)
            try await expect(preparingImage && !openedDuringImageImport
                && h.vm.conversationSwitchError == AssistantConversationSwitchError.imageInProgress.localizedDescription, "Switching refuses while the actual image import is pending")
            try await expect(!(await h.vm.requestNewConversation(ownerId: h.owner)) && h.vm.conversationId == sourceId && h.vm.pendingConversationSwitch == nil, "A new-chat button cannot cancel or reroute image preparation")
            gate.open(); await importing.value
            try await expect(!h.vm.isPreparingImage && h.vm.pendingImages.count == 1 && h.vm.conversationId == sourceId, "The original import can complete for its original conversation")
            try await expect(ChatFixtureURLProtocol.captured.isEmpty, "Image preparation and navigation do not call a model")
        }
        try await run("viewmodel-switch-tickets-reject-draft-owner-and-session-roundtrips") {
            for change in ["text", "images", "owner", "session"] {
                let h = try await ChatHarness(); defer { h.close() }
                let sourceId = h.vm.conversationId
                h.vm.inputText = "Exact original draft"; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
                let target = try targetHistory(h)
                try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "Fixture needs a protected source ticket")
                let old = try pendingSwitch(h)
                switch change {
                case "text": h.vm.inputText = "Changed"; h.vm.inputText = "Exact original draft"
                case "images": h.vm.pendingImages = [try image()]; h.vm.pendingImages = []
                case "owner":
                    try await h.configure(owner: "switch-owner-b"); AuthService.shared.user = ChatFixtureUser(id: "switch-owner-b"); h.vm.activateOwner()
                    AuthService.shared.user = ChatFixtureUser(id: h.owner); h.vm.activateOwner(); try await h.vm.waitForArchiveReady(ownerId: h.owner)
                default:
                    try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "A second intent replaces the first")
                    try await expect((await h.vm.confirmConversationSwitch(try pendingSwitch(h))), "Explicit second intent can switch")
                    try await expect((await h.vm.requestOpenConversation(id: sourceId, ownerId: h.owner)), "Returning restores the prior source draft")
                }
                try await expect(h.vm.conversationId == sourceId && h.vm.inputText == "Exact original draft", "Fixture restores the same visible contents")
                let before = try archiveFiles(h)
                try await expect(!(await h.vm.confirmConversationSwitch(old)) && h.vm.conversationSwitchError != nil, "An ABA roundtrip cannot revive an old switch ticket")
                try await expect(try archiveFiles(h) == before && h.vm.conversationId == sourceId && ChatFixtureURLProtocol.captured.isEmpty, "Rejected tickets cannot write, navigate or send")
            }
        }
        try await run("viewmodel-live-switch-rejection-preserves-producer-and-confirmed-stop-is-final") {
            let h = try await ChatHarness(); defer { h.close() }
            let target = try targetHistory(h), sourceId = h.vm.conversationId
            ChatFixtureURLProtocol.enqueue(.hold("Streaming source partial"))
            h.vm.inputText = "Source request"; h.vm.sendMessage(userId: h.owner)
            try await wait("source stream starts") { h.vm.messages.last?.content == "Streaming source partial" }
            try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "A real producer requires explicit stopping confirmation")
            let cancelled = try pendingSwitch(h), stopped = ChatFixtureURLProtocol.stoppedCount
            try await expect(cancelled.willStopGeneration && !cancelled.hasDraft, "The ticket describes live generation rather than inventing a draft")
            h.vm.rejectConversationSwitch()
            ChatFixtureURLProtocol.enqueueDelta(" continues")
            try await wait("rejected switch retains live stream") { h.vm.messages.last?.content.hasSuffix(" continues") == true }
            try await expect(h.vm.isLoading && ChatFixtureURLProtocol.stoppedCount == stopped && h.vm.conversationId == sourceId, "Cancellation does not stop or replace the actual producer")
            try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "A fresh explicit confirmation is required")
            try await expect((await h.vm.confirmConversationSwitch(try pendingSwitch(h))), "Successful persistence permits stop and switch")
            try await wait("confirmed switch cancels old HTTP task") { ChatFixtureURLProtocol.stoppedCount > stopped }
            let saved = try h.archive.load(userId: h.owner).first(where: { $0.id == sourceId })
            try await expect(saved?.messages.last?.status == .cancelled && saved?.messages.last?.content == "Streaming source partial continues", "The source's latest partial text is saved as stopped before leaving")
            ChatFixtureURLProtocol.enqueueDelta(" late old data"); ChatFixtureURLProtocol.completeHeld()
            try await expect(h.vm.conversationId == target.id && h.vm.messages == target.messages && !h.vm.isLoading
                && ChatFixtureURLProtocol.captured.count == 1, "Late callbacks cannot mutate target history or restart a model request")
        }
        try await run("viewmodel-switch-ticket-expires-when-generation-ends") {
            let h = try await ChatHarness(); defer { h.close() }
            let target = try targetHistory(h), sourceId = h.vm.conversationId
            ChatFixtureURLProtocol.enqueue(.hold("Generation is active"))
            h.vm.inputText = "Question"; h.vm.sendMessage(userId: h.owner)
            try await wait("generation active before switch intent") { h.vm.messages.last?.content == "Generation is active" }
            try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "Live generation produces a stop ticket")
            let ticket = try pendingSwitch(h)
            ChatFixtureURLProtocol.completeHeld(); try await finished(h.vm)
            let before = try archiveFiles(h)
            try await expect(!(await h.vm.confirmConversationSwitch(ticket)) && h.vm.conversationId == sourceId, "A completed generation changes the bound run revision")
            try await expect(try archiveFiles(h) == before && ChatFixtureURLProtocol.captured.count == 1, "Old stop confirmation cannot navigate, write or resend after completion")
        }
        try await run("viewmodel-switch-target-deletion-and-foreign-owner-fail-before-source-write") {
            let h = try await ChatHarness(); defer { h.close() }
            h.vm.inputText = "Preserve source draft"
            let target = try targetHistory(h), sourceId = h.vm.conversationId
            let beforeForeign = try archiveFiles(h)
            try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: "foreign-owner")) && h.vm.pendingConversationSwitch == nil, "Caller-supplied foreign ownership cannot open history")
            try await expect(try archiveFiles(h) == beforeForeign && h.vm.inputText == "Preserve source draft", "Foreign requests are nondestructive")
            try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "Create a valid bound ticket")
            let ticket = try pendingSwitch(h)
            try h.archive.delete(ids: [target.id], userId: h.owner)
            let beforeConfirm = try archiveFiles(h)
            try await expect(!(await h.vm.confirmConversationSwitch(ticket)) && h.vm.conversationId == sourceId
                && h.vm.conversationSwitchError == AssistantHistoryOperationError.conversationUnavailable.localizedDescription, "Confirmation re-reads ownership/existence rather than opening a retained snapshot")
            try await expect(try archiveFiles(h) == beforeConfirm && h.vm.inputText == "Preserve source draft" && ChatFixtureURLProtocol.captured.isEmpty, "Deleted target refusal cannot save or clear source state")
        }
        try await run("viewmodel-switch-write-failures-preserve-live-producer-and-retry") {
            for successfulMutations in [0, 1] {
                let fault = ChatFixtureArchiveFault()
                let h = try await ChatHarness(archiveFault: { try fault.check($0, owner: $1) }); defer { h.close(); fault.arm(nil) }
                let target = try targetHistory(h), sourceId = h.vm.conversationId, picture = try image()
                ChatFixtureURLProtocol.enqueue(.hold("Partial before SQL failure"))
                h.vm.inputText = "Source request"; h.vm.sendMessage(userId: h.owner)
                try await wait("producer before switch SQL failure") { h.vm.messages.last?.content == "Partial before SQL failure" }
                h.vm.inputText = "Keep exact unsent draft"; h.vm.pendingImages = [picture]
                h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
                try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "Live source switching requires confirmation")
                let ticket = try pendingSwitch(h), visible = h.vm.messages, stopped = ChatFixtureURLProtocol.stoppedCount, before = try archiveFiles(h)
                fault.arm(.beforeMutation, after: successfulMutations)
                try await expect(!(await h.vm.confirmConversationSwitch(ticket)), "A failed source upsert or target draft selection cannot report success")
                fault.arm(nil)
                try await expect(try archiveFiles(h) == before && h.vm.conversationSwitchError != nil, "Every earlier SQL mutation rolls back with the failing later mutation")
                try await expect(h.vm.isLoading && h.vm.messages == visible && h.vm.conversationId == sourceId && h.vm.inputText == "Keep exact unsent draft" && h.vm.pendingImages == [picture] && ChatFixtureURLProtocol.stoppedCount == stopped, "Rollback retains the exact source and actual producer")
                ChatFixtureURLProtocol.enqueueDelta(" and continues")
                try await wait("producer continues after rollback") { h.vm.messages.last?.content.hasSuffix(" and continues") == true }
                try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "Retry requires a fresh ticket")
                try await expect((await h.vm.confirmConversationSwitch(try pendingSwitch(h))), "Storage recovery permits an explicit retry")
                try await expect(h.vm.conversationId == target.id && ChatFixtureURLProtocol.captured.count == 1, "Successful retry navigates without another model request")
            }
        }
        try await run("viewmodel-switch-invalid-disk-draft-is-rejected-with-original-bytes") {
            for corrupt in [false, true] {
                let h = try await ChatHarness(); defer { h.close() }
                let target = try targetHistory(h), sourceId = h.vm.conversationId
                try h.archive.saveDraft("Placeholder", conversationId: target.id, userId: h.owner)
                let payload = corrupt ? Data("{broken draft".utf8) : try JSONEncoder().encode(AssistantChatDraft(text: String(repeating: "x", count: 1_048_577), conversationId: target.id))
                try sql(h, "UPDATE drafts SET payload=? WHERE conversation_id=?", [.blob(payload), .text(target.id)])
                let before = try archiveFiles(h)
                h.vm.inputText = "Keep source despite unreadable target"
                try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)) && h.vm.pendingConversationSwitch == nil, "Corrupt or oversized target SQL draft cannot be selected")
                try await expect(try archiveFiles(h) == before && h.vm.conversationId == sourceId && h.vm.inputText == "Keep source despite unreadable target" && ChatFixtureURLProtocol.captured.isEmpty, "Invalid target payload stays byte-for-byte intact")
            }
        }
        try await run("viewmodel-switch-restores-owner-scoped-legacy-unassigned-draft-safely") {
            let legacy = "  Exact owner-scoped legacy draft  "
            let target = conversation(id: "legacy-target", messages: [message(.user, "Target")])
            let source = Conversation(id: "legacy-source", title: "Recent source", preview: "Source", date: Date().addingTimeInterval(60), messages: [message(.user, "Source")])
            let h = try await ChatHarness(beforePrepare: { archive in
                let url = archive.databaseURL(userId: "fixture-owner").deletingPathExtension().appendingPathExtension("json")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                try encoder.encode([target, source]).write(to: url)
                try JSONEncoder().encode(legacy).write(to: url.appendingPathExtension("draft"))
            }); defer { h.close() }
            try await expect(h.vm.conversationId == source.id && h.vm.inputText == legacy, "A real pre-SQLite unassigned draft restores with the recent owner-scoped source")
            try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "Leaving restored legacy input requires confirmation")
            try await expect((await h.vm.confirmConversationSwitch(try pendingSwitch(h))) && h.vm.conversationId == target.id && h.vm.inputText.isEmpty, "Legacy text cannot silently attach to a destination")
            let records = try h.archive.loadDraftRecords(userId: h.owner)
            try await expect(records.contains { $0.conversationId == nil && $0.text == legacy } && records.contains { $0.conversationId == source.id && $0.text == legacy }, "Both owner-scoped unassigned input and explicitly saved source remain recoverable after migration")
            try await expect(ChatFixtureURLProtocol.captured.isEmpty, "Migration and switching do not send content")
        }
        try await run("viewmodel-switch-deletion-clears-all-target-drafts-only") {
            let h = try await ChatHarness(); defer { h.close() }
            let sourceId = h.vm.conversationId, picture = try image()
            h.vm.messages = [message(.user, "Current source")]
            h.vm.inputText = "Current A draft"; h.vm.pendingImages = [picture]
            try await h.vm.flushForDataExport(ownerId: h.owner)
            let target = try targetHistory(h, id: "delete-inactive-B"), other = try targetHistory(h, id: "keep-C")
            try h.archive.saveDraft("Delete B draft", images: [picture], conversationId: target.id, userId: h.owner)
            try h.archive.saveDraft("Keep C draft", images: [picture], conversationId: other.id, userId: h.owner)
            h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            try await h.vm.deleteConversations(ids: [target.id], ownerId: h.owner)
            var drafts = try h.archive.loadDraftRecords(userId: h.owner)
            try await expect(!drafts.contains { $0.conversationId == target.id } && drafts.contains { $0.conversationId == other.id && $0.text == "Keep C draft" },
                "Deleting an inactive target removes its draft but preserves unrelated drafts")
            try await expect(h.vm.conversationId == sourceId && h.vm.inputText == "Current A draft" && h.vm.pendingImages == [picture], "Unrelated deletion does not mutate the current UI")
            try await h.vm.deleteConversations(ids: [sourceId], ownerId: h.owner)
            drafts = try h.archive.loadDraftRecords(userId: h.owner)
            try await expect(!drafts.contains { $0.conversationId == sourceId || $0.conversationId == target.id }
                && drafts.contains { $0.conversationId == other.id && $0.text == "Keep C draft" }, "Current-target deletion also removes all associated drafts without touching C")
            try await h.vm.deleteAllConversations(ownerId: h.owner)
            try await expect(try h.archive.loadDraftRecords(userId: h.owner).allSatisfy { $0.conversationId == h.vm.conversationId && $0.text.isEmpty } && h.archive.load(userId: h.owner).isEmpty, "Clear-all includes every inactive draft and keeps only the clean replacement slot")
        }
        try await run("viewmodel-recovery-new-conversation-fails-safely-and-never-resurrects") {
            for successfulMutations in [0, 1] {
                let fault = ChatFixtureArchiveFault()
                let h = try await ChatHarness(archiveFault: { try fault.check($0, owner: $1) }); defer { h.close(); fault.arm(nil) }
                let unrelated = try targetHistory(h, id: "keep-recovery-history"), picture = try image(), deleted = h.vm.conversationId
                h.vm.messages = [message(.user, "Deleted source request"), message(.assistant, "Deleted source answer")]
                h.vm.inputText = "Deleted source unsent text"; h.vm.pendingImages = [picture]
                try await h.vm.flushForDataExport(ownerId: h.owner)
                try h.archive.saveDraft("Keep unrelated draft", conversationId: unrelated.id, userId: h.owner)
                try h.archive.delete(ids: [deleted], userId: h.owner, purgeUnassignedDraft: true)
                _ = await h.vm.requestOpenConversation(id: unrelated.id, ownerId: h.owner)
                try await expect(!(await h.vm.requestNewConversation(ownerId: h.owner, initialText: "Explicit fresh prefill")), "A durably deleted source needs explicit recovery confirmation")
                let cancelled = try pendingSwitch(h), visible = h.vm.messages, beforeCancel = try archiveFiles(h)
                h.vm.rejectConversationSwitch()
                try await expect(try archiveFiles(h) == beforeCancel && h.vm.messages == visible && cancelled.isRecoveringDeletedConversation, "Recovery cancellation changes no private content")
                _ = await h.vm.requestNewConversation(ownerId: h.owner, initialText: "Explicit fresh prefill")
                let failing = try pendingSwitch(h)
                fault.arm(.beforeMutation, after: successfulMutations)
                try await expect(!(await h.vm.confirmConversationSwitch(failing)), "Cleanup or target draft fault cannot report a new conversation")
                fault.arm(nil)
                try await expect(h.vm.conversationId == deleted && h.vm.messages == visible && h.vm.inputText == "Deleted source unsent text" && h.vm.pendingImages == [picture], "Failed recovery retains exact temporary source state")
                try await expect(try h.archive.deletedConversationIds(userId: h.owner).contains(deleted) && !h.archive.load(userId: h.owner).contains { $0.id == deleted }, "Recovery rollback preserves the already committed tombstone")
                _ = await h.vm.requestNewConversation(ownerId: h.owner, initialText: "Explicit fresh prefill")
                try await expect((await h.vm.confirmConversationSwitch(try pendingSwitch(h))), "Explicit retry selects only the new initial draft")
                try await expect(h.vm.inputText == "Explicit fresh prefill" && h.vm.messages.isEmpty && h.vm.pendingImages.isEmpty, "Deleted messages and private draft never migrate into the new source")
                try await expect(try h.archive.conversation(id: unrelated.id, userId: h.owner) != nil && h.archive.loadDraftRecord(conversationId: unrelated.id, userId: h.owner).text == "Keep unrelated draft" && ChatFixtureURLProtocol.captured.isEmpty, "Unrelated data remains and recovery sends no automatic request")
            }
        }
        try await run("viewmodel-switch-auth-notification-aba-invalidates-ticket-synchronously") {
            let h = try await ChatHarness(); defer { h.close() }
            h.vm.inputText = "Exact draft before auth ABA"
            let target = try targetHistory(h)
            try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "Create a pending owner-bound ticket")
            let ticket = try pendingSwitch(h), before = try archiveFiles(h), selected = h.vm.conversationId
            AuthService.shared.user = nil
            NotificationCenter.default.post(name: .logoutSuccess, object: nil)
            AuthService.shared.user = ChatFixtureUser(id: h.owner)
            NotificationCenter.default.post(name: .loginSuccess, object: nil)
            // Deliberately no await: both delayed activateOwner tasks still see final A.
            try await expect(!(await h.vm.confirmConversationSwitch(ticket)), "Synchronous notification invalidation must defeat an actor-local logout/login ABA")
            try await expect(h.vm.conversationId == selected && h.vm.inputText == "Exact draft before auth ABA" && archiveFiles(h) == before
                && ChatFixtureURLProtocol.captured.isEmpty, "An auth roundtrip cannot revive a stale switch or write current data")
        }
        try await run("viewmodel-switch-raw-unicode-draft-revision-cannot-revive") {
            let h = try await ChatHarness(); defer { h.close() }
            let original = "é", equivalent = "e" + String(UnicodeScalar(0x301)!)
            try await expect(original == equivalent && !original.utf8.elementsEqual(equivalent.utf8), "Fixture needs canonically equal but byte-distinct text")
            h.vm.inputText = original
            let target = try targetHistory(h)
            try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "Create a draft-bound ticket")
            let ticket = try pendingSwitch(h)
            h.vm.inputText = equivalent; h.vm.inputText = original
            try await expect(!(await h.vm.confirmConversationSwitch(ticket)) && h.vm.inputText.utf8.elementsEqual(original.utf8), "Raw Unicode edits and restoration must still advance the draft revision")
        }
        try await run("viewmodel-switch-before-model-start-cancels-queued-old-producer") {
            let gate = ChatFixtureAsyncGate(); defer { gate.open() }
            let h = try await ChatHarness(startupBarrier: { await gate.wait() }); defer { h.close() }
            let target = try targetHistory(h), sourceId = h.vm.conversationId
            h.vm.inputText = "Private old queued prompt"; h.vm.sendMessage(userId: h.owner)
            try await wait("old transport producer queued") { gate.enteredCount == 1 }
            try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "Queued generation is still a real stop-confirmation boundary")
            try await expect((await h.vm.confirmConversationSwitch(try pendingSwitch(h))), "Confirmed source persistence can cancel queued startup before HTTP")
            gate.open()
            h.vm.inputText = "New target request"; h.vm.sendMessage(userId: h.owner)
            try await expect(h.vm.requiresBYOKConfirmation, "Target history retains full destination/history confirmation")
            h.vm.confirmBYOKContext(); try await finished(h.vm)
            try await expect(ChatFixtureURLProtocol.captured.count == 1 && h.vm.conversationId == target.id, "Only the new target request may start HTTP")
            let wire = String(decoding: try JSONSerialization.data(withJSONObject: body()), as: UTF8.self)
            try await expect(!wire.contains("Private old queued prompt"), "Queued source prompt cannot leak into the target request")
            try await expect(try h.archive.load(userId: h.owner).first(where: { $0.id == sourceId })?.messages.last?.status == .cancelled, "The unsent old candidate remains honestly stopped in its own history")
        }
        try await run("viewmodel-pre-cancelled-switch-does-not-mutate-files-or-source") {
            let h = try await ChatHarness(); defer { h.close() }
            h.vm.inputText = "Keep before cancelled task"
            let target = try targetHistory(h), selected = h.vm.conversationId, before = try archiveFiles(h)
            let cancelled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "Pre-cancelled open must refuse")
                try await expect(!(await h.vm.requestNewConversation(ownerId: h.owner, initialText: "Must not replace")), "Pre-cancelled shortcut must refuse")
            }
            try await cancelled.value
            try await expect(h.vm.conversationId == selected && h.vm.inputText == "Keep before cancelled task" && archiveFiles(h) == before
                && ChatFixtureURLProtocol.captured.isEmpty, "Cancellation cannot write, clear or send")
        }
        try await run("viewmodel-durable-delete-failure-does-not-restore-across-owner-or-cold-start") {
            let fault = ChatFixtureArchiveFault()
            let h = try await ChatHarness(archiveFault: { try fault.check($0, owner: $1) }); defer { h.close(); fault.arm(nil) }
            let deleted = h.vm.conversationId
            h.vm.messages = [message(.user, "Deleted private history"), message(.assistant, "Deleted answer")]
            h.vm.inputText = "Deleted private unsent draft"; h.vm.pendingImages = [try image()]
            try await h.vm.flushForDataExport(ownerId: h.owner)
            let kept = try targetHistory(h, id: "kept-durable-history")
            try h.archive.saveDraft("Unrelated kept draft", conversationId: kept.id, userId: h.owner)
            fault.arm(.beforeCommit)
            _ = try await failure { try await h.vm.deleteConversations(ids: [deleted], ownerId: h.owner) }
            fault.arm(nil)
            try await expect(try h.archive.conversation(id: deleted, userId: h.owner) != nil && !h.archive.deletedConversationIds(userId: h.owner).contains(deleted), "A precommit delete failure honestly retains all original data without a partial tombstone")
            try await h.vm.deleteConversations(ids: [deleted], ownerId: h.owner)
            let restarted = ChatViewModel(archive: h.archive, transport: h.transport, conversationClient: h.conversationClient, repository: h.repository, defaults: h.defaults)
            defer { restarted.cancel() }
            try await restarted.waitForArchiveReady(ownerId: h.owner)
            try await expect(restarted.conversationId != deleted && restarted.messages.isEmpty && restarted.inputText.isEmpty && restarted.pendingImages.isEmpty, "A committed deletion cannot restore on cold VM startup")
            try await expect(!(await restarted.requestOpenConversation(id: deleted, ownerId: h.owner)), "A tombstoned ID cannot become ordinary history")
            try await h.configure(owner: "durable-owner-b"); AuthService.shared.user = ChatFixtureUser(id: "durable-owner-b"); h.vm.activateOwner()
            AuthService.shared.user = ChatFixtureUser(id: h.owner); h.vm.activateOwner(); try await h.vm.waitForArchiveReady(ownerId: h.owner)
            try await expect(h.vm.conversationId != deleted && h.vm.inputText.isEmpty && h.vm.pendingImages.isEmpty, "Owner ABA does not erase deletion protection")
            try await expect(try h.archive.loadDraftRecord(conversationId: kept.id, userId: h.owner).text == "Unrelated kept draft" && ChatFixtureURLProtocol.captured.isEmpty, "Unrelated drafts stay recoverable without a network request")
        }
        try await run("viewmodel-global-purge-cold-start-new-request-requires-and-completes-recovery") {
            let fault = ChatFixtureArchiveFault()
            let h = try await ChatHarness(archiveFault: { try fault.check($0, owner: $1) }); defer { h.close(); fault.arm(nil) }
            let deleted = h.vm.conversationId
            h.vm.messages = [message(.user, "Old purge private history"), message(.assistant, "Old purge answer")]
            h.vm.inputText = "Old purge private draft"; h.vm.pendingImages = [try image()]
            try await h.vm.flushForDataExport(ownerId: h.owner)
            try await h.archive.prepareAsync(userId: "other-owner")
            try h.archive.upsert(conversation(id: "other-owner-history", messages: [message(.user, "Other owner stays")]), userId: "other-owner")
            try h.archive.saveDraft("Other owner draft stays", conversationId: "other-owner-history", userId: "other-owner")
            fault.arm(.purgeDatabaseRemoval)
            _ = try await failure { try await h.vm.deleteAllConversations(ownerId: h.owner) }
            fault.arm(nil)
            try await expect(try h.archive.isPurgingAll(userId: h.owner), "Cleanup interruption leaves a durable purge intent")
            let restarted = ChatViewModel(archive: h.archive, transport: h.transport, conversationClient: h.conversationClient, repository: h.repository, defaults: h.defaults)
            defer { restarted.cancel() }
            let preparationError = try await failure { try await restarted.waitForArchiveReady(ownerId: h.owner) }
            try await expect(preparationError as? AssistantChatStorageError == .purgeRecoveryRequired && restarted.archiveRequiresRecovery && !restarted.archiveIsReady, "Cold preparation surfaces recovery instead of silently deleting or restoring old data")
            try await expect(restarted.conversationId != deleted && restarted.messages.isEmpty && restarted.inputText.isEmpty && restarted.pendingImages.isEmpty, "A purging owner cannot expose deleted source content on cold startup")
            let prompt = "Explicit clean new prefill"
            _ = await restarted.requestNewConversation(ownerId: h.owner, initialText: prompt)
            guard let cancelled = restarted.pendingConversationSwitch else { throw ChatTestFailure(description: "Missing public purge recovery ticket") }
            let before = try archiveFiles(h); restarted.rejectConversationSwitch()
            try await expect(try archiveFiles(h) == before && h.archive.isPurgingAll(userId: h.owner) && cancelled.isRecoveringDeletedConversation, "Default recovery cancellation preserves purge intent")
            _ = await restarted.requestNewConversation(ownerId: h.owner, initialText: prompt)
            guard let success = restarted.pendingConversationSwitch else { throw ChatTestFailure(description: "Missing fresh recovery ticket") }
            try await expect((await restarted.confirmConversationSwitch(success)), "Explicit recovery performs physical cleanup then selects a clean initial draft")
            try await expect(try !h.archive.isPurgingAll(userId: h.owner) && h.archive.load(userId: h.owner).isEmpty && restarted.inputText == prompt && restarted.messages.isEmpty && restarted.pendingImages.isEmpty && restarted.archiveIsReady, "Only the explicit new prefill survives cleanup")
            try await expect(try h.archive.loadDraftRecords(userId: h.owner).allSatisfy { $0.conversationId == success.targetConversationId } && h.archive.load(userId: "other-owner").first?.messages.first?.content == "Other owner stays" && h.archive.loadDraftRecord(conversationId: "other-owner-history", userId: "other-owner").text == "Other owner draft stays", "Recovery preserves every other owner's data")
            try await expect(ChatFixtureURLProtocol.captured.isEmpty, "Purge recovery does not send the prefill")
        }
        try await run("viewmodel-identity-notification-aba-stops-real-stream-and-rejects-late-delta") {
            let h = try await ChatHarness(); defer { h.close() }
            let target = try targetHistory(h), picture = try image()
            ChatFixtureURLProtocol.enqueue(.hold("Visible partial before auth ABA"))
            h.vm.inputText = "Actual streaming source"; h.vm.sendMessage(userId: h.owner)
            try await wait("actual producer before identity ABA") { h.vm.messages.last?.content == "Visible partial before auth ABA" }
            h.vm.inputText = "Keep same-owner unsent draft"; h.vm.pendingImages = [picture]; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            try await expect(!(await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)), "A stop ticket exists before identity transition")
            let ticket = try pendingSwitch(h), selected = h.vm.conversationId, stopped = ChatFixtureURLProtocol.stoppedCount
            AuthService.shared.user = nil; NotificationCenter.default.post(name: .logoutSuccess, object: nil)
            AuthService.shared.user = ChatFixtureUser(id: h.owner); NotificationCenter.default.post(name: .loginSuccess, object: nil)
            // No await between the two identity notifications or this assertion.
            try await expect(!h.vm.isLoading && h.vm.messages.last?.status == .cancelled
                && h.vm.messages.last?.content == "Visible partial before auth ABA", "Synchronous identity invalidation must stop the active old producer, not merely its ticket")
            try await expect(!(await h.vm.confirmConversationSwitch(ticket)) && h.vm.conversationId == selected, "The old stop/switch ticket cannot revive")
            ChatFixtureURLProtocol.enqueueDelta(" forbidden late auth delta"); ChatFixtureURLProtocol.completeHeld()
            try await wait("old auth ABA HTTP producer actually cancelled") { ChatFixtureURLProtocol.stoppedCount > stopped }
            await h.vm.waitForPendingArchiveWrites()
            try await expect(h.vm.messages.last?.content == "Visible partial before auth ABA" && h.vm.inputText == "Keep same-owner unsent draft"
                && h.vm.pendingImages == [picture] && ChatFixtureURLProtocol.captured.count == 1, "Late frames cannot modify retained partial or restart HTTP")
            try await expect(try h.archive.load(userId: h.owner).first(where: { $0.id == selected })?.messages.last?.content == "Visible partial before auth ABA",
                "Same-owner login may safely persist the stopped latest partial without cross-owner writes")
        }
        try await run("viewmodel-identity-notification-aba-invalidates-byok-and-image-jobs") {
            do {
                let h = try await ChatHarness(); defer { h.close() }
                h.addMemory(text: "Requires pending BYOK destination consent")
                h.vm.inputText = "Original pending BYOK draft"; h.vm.sendMessage(userId: h.owner)
                try await expect(h.vm.requiresBYOKConfirmation, "Fixture holds an actual unsent BYOK intent")
                AuthService.shared.user = nil; NotificationCenter.default.post(name: .logoutSuccess, object: nil)
                AuthService.shared.user = ChatFixtureUser(id: h.owner); NotificationCenter.default.post(name: .loginSuccess, object: nil)
                h.vm.confirmBYOKContext()
                try await expect(!h.vm.requiresBYOKConfirmation && h.vm.inputText == "Original pending BYOK draft" && ChatFixtureURLProtocol.captured.isEmpty, "An identity ABA cannot authorize an old queued BYOK intent")
            }
            do {
                let gate = ChatFixtureAsyncGate(); defer { gate.open() }
                let h = try await ChatHarness(imagePreparationBarrier: { await gate.wait() }); defer { h.close() }
                let original = h.vm.conversationId, data = try image().data!
                let importing = Task { await h.vm.addImageData(data, ownerId: h.owner, conversationId: original) }
                try await wait("old image job held before identity ABA") { gate.enteredCount == 1 }
                AuthService.shared.user = nil; NotificationCenter.default.post(name: .logoutSuccess, object: nil)
                AuthService.shared.user = ChatFixtureUser(id: h.owner); NotificationCenter.default.post(name: .loginSuccess, object: nil)
                gate.open(); await importing.value
                try await expect(!h.vm.isPreparingImage && h.vm.pendingImages.isEmpty && ChatFixtureURLProtocol.captured.isEmpty, "A late pre-identity image job cannot attach after owner restoration")
            }
        }
        try await run("viewmodel-durable-tombstone-at-startup-rejects-ordinary-model-source") {
            let gate = ChatFixtureAsyncGate(); defer { gate.open() }
            let h = try await ChatHarness(startupBarrier: { await gate.wait() }); defer { h.close() }
            let deleted = h.vm.conversationId
            h.vm.inputText = "Queued source externally deleted"; h.vm.sendMessage(userId: h.owner)
            try await wait("source queued before external durable deletion") { gate.enteredCount == 1 }
            try h.archive.delete(ids: [deleted], userId: h.owner, purgeUnassignedDraft: true)
            gate.open()
            try await wait("durable deletion rejected at model startup") { !h.vm.isLoading }
            await h.vm.waitForPendingArchiveWrites()
            try await expect(ChatFixtureURLProtocol.captured.isEmpty && h.vm.error == AssistantHistoryOperationError.recoveryRequired.localizedDescription, "Final synchronous startup validation must consult durable tombstones even from another archive caller")
            try await expect(try !h.archive.load(userId: h.owner).contains { $0.id == deleted }, "Rejected model attempt cannot rewrite the protected source")
            try await expect(!(await h.vm.requestNewConversation(ownerId: h.owner, initialText: "Safe explicit replacement"))
                && h.vm.pendingConversationSwitch?.isRecoveringDeletedConversation == true, "The deleted source has an explicit recovery route instead of becoming ordinary history")
            h.vm.rejectConversationSwitch()
        }
        try await run("viewmodel-default-prepare-runs-off-main-and-keeps-new-draft") {
            let h = try await ChatHarness(); defer { h.close() }
            let gate = ChatFixtureWorkerGate(); gate.arm(); defer { gate.open() }
            let archive = AssistantChatArchive(directory: h.directory.appendingPathComponent("default-async"), fault: { point, _ in if point == .beforePublish { gate.wait() } })
            let vm = ChatViewModel(archive: archive, transport: h.transport, conversationClient: h.conversationClient, repository: h.repository, defaults: h.defaults)
            defer { vm.cancel() }
            try await expect(vm.archiveIsLoading && !vm.archiveIsReady && !archive.isPrepared(userId: h.owner), "Default init starts asynchronous preparation without claiming an empty ready archive")
            try await wait("real default prepare worker") { gate.enteredCount > 0 }
            vm.inputText = "Typed while storage prepares"
            var heartbeat = false
            let pulse = Task { @MainActor in heartbeat = true }; await pulse.value
            try await expect(heartbeat && vm.archiveIsLoading, "Blocking the actual worker must leave MainActor responsive")
            gate.open(); try await vm.waitForArchiveReady(ownerId: h.owner)
            try await expect(vm.archiveIsReady && !vm.archiveIsLoading && vm.inputText == "Typed while storage prepares" && vm.messages.isEmpty, "A late bootstrap cannot overwrite a newer live draft")
            vm.cancel(); await vm.waitForPendingArchiveWrites()
        }
        try await run("viewmodel-default-prepare-failure-is-visible-and-same-owner-retry-works") {
            let h = try await ChatHarness(); defer { h.close() }
            let fault = ChatFixtureArchiveFault(); fault.arm(.beforePublish); defer { fault.arm(nil) }
            let archive = AssistantChatArchive(directory: h.directory.appendingPathComponent("retry-async"), fault: { try fault.check($0, owner: $1) })
            let vm = ChatViewModel(archive: archive, transport: h.transport, conversationClient: h.conversationClient, repository: h.repository, defaults: h.defaults)
            defer { vm.cancel() }
            _ = try await failure { try await vm.waitForArchiveReady(ownerId: h.owner) }
            try await expect(!vm.archiveIsReady && !vm.archiveIsLoading && vm.archiveOperationError != nil, "Preparation failure remains visibly unavailable instead of looking like a new empty account")
            fault.arm(nil); try await vm.waitForArchiveReady(ownerId: h.owner)
            try await expect(vm.archiveIsReady && vm.archiveOperationError == nil, "Retry on the same owner must start a new bootstrap rather than early-return forever")
            vm.cancel(); await vm.waitForPendingArchiveWrites()
        }
        try await run("viewmodel-bootstrap-read-owner-aba-cannot-overwrite-new-owner-draft") {
            let h = try await ChatHarness(); defer { h.close() }
            h.vm.messages = [message(.user, "Old A private body")]; h.vm.inputText = "Old A private draft"
            try await h.vm.flushForDataExport(ownerId: h.owner)
            try await h.configure(owner: "bootstrap-owner-b")
            let gate = ChatFixtureWorkerGate(); gate.arm(); defer { gate.open() }
            let archive = AssistantChatArchive(directory: h.directory.appendingPathComponent("conversations"), fault: { point, _ in if point == .beforeCommit { gate.wait() } })
            let vm = ChatViewModel(archive: archive, transport: h.transport, conversationClient: h.conversationClient, repository: h.repository, defaults: h.defaults)
            defer { vm.cancel() }
            let originalScope = vm.conversationScopeId
            try await wait("bootstrap transaction read held") { gate.enteredCount > 0 }
            AuthService.shared.user = ChatFixtureUser(id: "bootstrap-owner-b"); vm.activateOwner()
            AuthService.shared.user = ChatFixtureUser(id: h.owner); vm.activateOwner()
            vm.inputText = "New A draft after owner ABA"
            gate.open(); try await vm.waitForArchiveReady(ownerId: h.owner)
            try await expect(vm.activeOwner == h.owner && vm.conversationScopeId != originalScope && vm.inputText == "New A draft after owner ABA" && vm.messages.isEmpty, "Late old-epoch reads cannot revive their draft or body even after A returns")
            vm.cancel(); await vm.waitForPendingArchiveWrites()
        }
        try await run("viewmodel-before-commit-draft-edit-rolls-back-switch-and-keeps-producer") {
            let gate = ChatFixtureWorkerGate(); defer { gate.open() }
            let h = try await ChatHarness(beforeArchiveCommit: { gate.wait() }); defer { h.close() }
            let target = try targetHistory(h), selected = h.vm.conversationId
            h.vm.messages = [message(.user, "Source body"), message(.assistant, "Source answer")]
            h.vm.inputText = "Before worker draft"; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            _ = await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)
            let ticket = try pendingSwitch(h), before = try archiveFiles(h)
            gate.arm()
            let switching = Task { await h.vm.confirmConversationSwitch(ticket) }
            try await wait("switch at before commit") { gate.enteredCount > 0 && h.vm.isArchiveBusy }
            h.vm.inputText = "Newer typed draft"
            gate.open(); let committed = await switching.value
            try await expect(!committed && h.vm.conversationId == selected && h.vm.inputText == "Newer typed draft" && !h.vm.isArchiveBusy, "A MainActor edit invalidates a pending commit instead of being overwritten")
            try await expect(try archiveFiles(h) == before && h.archive.loadDraft(userId: h.owner) == "Before worker draft" && ChatFixtureURLProtocol.captured.isEmpty, "Invalidation before COMMIT rolls back every tentative SQL write")
        }
        try await run("viewmodel-before-commit-task-cancel-rolls-back-real-export-transaction") {
            let gate = ChatFixtureWorkerGate(); defer { gate.open() }
            let h = try await ChatHarness(beforeArchiveCommit: { gate.wait() }); defer { h.close() }
            h.vm.messages = [message(.user, "Uncommitted export")]; h.vm.inputText = "Uncommitted draft"
            let before = try archiveFiles(h)
            gate.arm()
            let flushing = Task { @MainActor () -> Error? in do { try await h.vm.flushForDataExport(ownerId: h.owner); return nil } catch { return error } }
            try await wait("export at before commit") { gate.enteredCount > 0 && h.vm.isArchiveBusy }
            flushing.cancel(); gate.open(); let error = await flushing.value
            try await expect(error != nil && !h.vm.isArchiveBusy && h.vm.inputText == "Uncommitted draft", "Cancellation before commit rejects publication and releases only its own gate")
            try await expect(try archiveFiles(h) == before && h.archive.load(userId: h.owner).isEmpty && h.archive.loadDraft(userId: h.owner).isEmpty, "The real SQLite transaction rolls back both body and draft on cancellation")
        }
        try await run("viewmodel-after-commit-cancel-reports-saved-change-without-overwriting-ui") {
            let gate = ChatFixtureAsyncGate(); defer { gate.open() }
            let h = try await ChatHarness(afterArchiveCommit: { await gate.wait() }); defer { h.close() }
            let target = try targetHistory(h), selected = h.vm.conversationId
            h.vm.messages = [message(.user, "Source saved before cancellation")]; h.vm.inputText = "Private source draft"
            h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            _ = await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)
            let ticket = try pendingSwitch(h), visible = h.vm.messages
            let switching = Task { await h.vm.confirmConversationSwitch(ticket) }
            try await wait("real commit completed before UI publication") { gate.enteredCount > 0 }
            try await expect(try h.archive.loadDraftRecord(userId: h.owner).conversationId == target.id && h.archive.conversation(id: selected, userId: h.owner) != nil, "The test barrier is after an actual durable SQLite commit")
            switching.cancel(); gate.open(); let navigated = await switching.value
            try await expect(!navigated && h.vm.conversationId == selected && h.vm.messages == visible && h.vm.inputText == "Private source draft", "Postcommit cancellation does not navigate or replace the visible source")
            try await expect(h.vm.conversationSwitchError == AssistantArchiveStateError.committedChanged.localizedDescription && !h.vm.isArchiveBusy, "A saved transaction must never be reported as rolled back or unsaved")
        }
        try await run("viewmodel-after-commit-owner-aba-never-publishes-old-epoch-ui") {
            let gate = ChatFixtureAsyncGate(); defer { gate.open() }
            let h = try await ChatHarness(afterArchiveCommit: { await gate.wait() }); defer { h.close() }
            try await h.configure(owner: "commit-owner-b")
            let target = try targetHistory(h), selected = h.vm.conversationId
            h.vm.messages = [message(.user, "Saved A source")]; h.vm.inputText = "Saved A draft"
            h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            _ = await h.vm.requestOpenConversation(id: target.id, ownerId: h.owner)
            let ticket = try pendingSwitch(h)
            let switching = Task { await h.vm.confirmConversationSwitch(ticket) }
            try await wait("after commit before owner ABA") { gate.enteredCount > 0 }
            AuthService.shared.user = ChatFixtureUser(id: "commit-owner-b"); h.vm.activateOwner()
            AuthService.shared.user = ChatFixtureUser(id: h.owner); h.vm.activateOwner()
            h.vm.inputText = "New A UI draft after commit"
            let freshScope = h.vm.conversationScopeId
            gate.open(); let navigated = await switching.value
            try await h.vm.waitForArchiveReady(ownerId: h.owner)
            try await expect(!navigated && h.vm.conversationScopeId == freshScope && h.vm.inputText == "New A UI draft after commit" && h.vm.messages.isEmpty, "Old committed operation cannot overwrite a new owner epoch even when identity returns to A")
            try await expect(try h.archive.conversation(id: selected, userId: h.owner) != nil && h.archive.loadDraftRecord(userId: h.owner).conversationId == target.id, "Owner ABA does not lie about the committed source and selected draft")
        }
        try await run("viewmodel-delete-gate-holds-queued-http-until-commit-then-starts-zero-requests") {
            let startup = ChatFixtureAsyncGate(); defer { startup.open() }
            let worker = ChatFixtureWorkerGate(); defer { worker.open() }
            let h = try await ChatHarness(startupBarrier: { await startup.wait() }, beforeArchiveCommit: { worker.wait() }); defer { h.close() }
            h.vm.inputText = "Queued deleted source"; h.vm.sendMessage(userId: h.owner)
            try await wait("queued HTTP startup barrier") { startup.enteredCount == 1 }
            await h.vm.waitForPendingArchiveWrites()
            let selected = h.vm.conversationId
            worker.arm()
            let deletion = Task { try await h.vm.deleteConversations(ids: [selected], ownerId: h.owner) }
            try await wait("delete gate before commit") { worker.enteredCount > 0 && h.vm.isArchiveBusy }
            startup.open(); try await Task.sleep(nanoseconds: 20_000_000)
            try await expect(ChatFixtureURLProtocol.captured.isEmpty && h.vm.isLoading, "Queued transport must wait while deletion owns the exclusive gate")
            worker.open(); try await deletion.value
            try await wait("deleted queued producer stopped") { !h.vm.isLoading }
            try await expect(ChatFixtureURLProtocol.captured.isEmpty && h.vm.messages.isEmpty && h.vm.conversationId != selected, "Successful deletion rejects the old final no-await startup hook with zero actual HTTP requests")
        }
        try await run("viewmodel-delete-rollback-releases-queued-http-and-original-producer-continues") {
            let startup = ChatFixtureAsyncGate(); defer { startup.open() }
            let worker = ChatFixtureWorkerGate(); defer { worker.open() }
            let fault = ChatFixtureArchiveFault(); defer { fault.arm(nil) }
            let h = try await ChatHarness(startupBarrier: { await startup.wait() }, beforeArchiveCommit: { worker.wait(); try fault.check(.beforeCommit, owner: "fixture-owner") }); defer { h.close() }
            ChatFixtureURLProtocol.enqueue(.hold("Producer survives rolled-back deletion"))
            h.vm.inputText = "Queued source remains"; h.vm.sendMessage(userId: h.owner)
            try await wait("rollback queued startup") { startup.enteredCount == 1 }
            await h.vm.waitForPendingArchiveWrites()
            let selected = h.vm.conversationId
            worker.arm(); fault.arm(.beforeCommit)
            let deletion = Task { @MainActor () -> Error? in do { try await h.vm.deleteConversations(ids: [selected], ownerId: h.owner); return nil } catch { return error } }
            try await wait("rollback deletion gate") { worker.enteredCount > 0 && h.vm.isArchiveBusy }
            startup.open(); try await Task.sleep(nanoseconds: 20_000_000)
            try await expect(ChatFixtureURLProtocol.captured.isEmpty, "The queued request cannot bypass an uncommitted deletion")
            worker.open(); let failure = await deletion.value; fault.arm(nil)
            try await wait("original queued request resumes after rollback") { h.vm.messages.last?.content == "Producer survives rolled-back deletion" }
            try await expect(failure != nil && h.vm.conversationId == selected && h.vm.isLoading && ChatFixtureURLProtocol.captured.count == 1, "Rollback releases the existing producer without cancellation or a replacement request")
            ChatFixtureURLProtocol.completeHeld(); try await finished(h.vm)
        }
        try await run("viewmodel-exclusive-export-buffers-stream-text-and-terminal-error-without-cancelling") {
            for failsStream in [false, true] {
                let worker = ChatFixtureWorkerGate(); defer { worker.open() }
                let fault = ChatFixtureArchiveFault(); defer { fault.arm(nil) }
                let h = try await ChatHarness(beforeArchiveCommit: { worker.wait(); try fault.check(.beforeCommit, owner: "fixture-owner") }); defer { h.close() }
                ChatFixtureURLProtocol.enqueue(.hold("Live source"))
                h.vm.inputText = "Keep actual producer"; h.vm.sendMessage(userId: h.owner)
                try await wait("export live stream") { h.vm.messages.last?.content == "Live source" }
                await h.vm.waitForPendingArchiveWrites()
                let visible = h.vm.messages, selected = h.vm.conversationId
                worker.arm(); fault.arm(.beforeCommit)
                let export = Task { @MainActor () -> Error? in do { try await h.vm.flushForDataExport(ownerId: h.owner); return nil } catch { return error } }
                try await wait("export exclusive gate") { worker.enteredCount > 0 && h.vm.isArchiveBusy }
                if failsStream { ChatFixtureURLProtocol.failHeld() }
                else { ChatFixtureURLProtocol.enqueueDelta(" buffered text"); ChatFixtureURLProtocol.completeHeld() }
                try await Task.sleep(nanoseconds: 30_000_000)
                try await expect(h.vm.messages == visible && h.vm.isLoading && h.vm.conversationId == selected, "Neither buffered deltas nor the error catch may mutate a frozen snapshot")
                worker.open(); let exportError = await export.value; fault.arm(nil)
                try await wait("terminal stream publishes after gate release") { !h.vm.isLoading }
                await h.vm.waitForPendingArchiveWrites()
                try await expect(exportError != nil && h.vm.messages.last?.status == (failsStream ? .failed : .completed) && h.vm.conversationId == selected && ChatFixtureURLProtocol.captured.count == 1, "An export rollback releases the same producer and publishes its honest terminal status")
                if !failsStream { try await expect(h.vm.messages.last?.content == "Live source buffered text", "Buffered real transport text is retained after the failed exclusive operation") }
            }
        }
        try await run("viewmodel-history-queries-real-pages-without-decoding-unselected-bodies") {
            let h = try await ChatHarness(); defer { h.close() }
            let records = (0..<123).map { index in Conversation(id: String(format: "page-%03d", index), title: index == 42 ? "Café计划" : "Record \(index)", preview: "Preview \(index)", date: Date(timeIntervalSince1970: Double(1_800_000_000 + index)), messages: [message(.user, "Private body \(index)")]) }
            try await h.archive.backgroundTransaction(userId: h.owner, operation: { store in for record in records { try store.upsert(record, userId: h.owner) } })
            let before = try h.archive.diagnostics(userId: h.owner)
            let first = try await h.vm.historyPage(ownerId: h.owner, limit: 50)
            let second = try await h.vm.historyPage(ownerId: h.owner, cursor: first.nextCursor, limit: 50)
            let third = try await h.vm.historyPage(ownerId: h.owner, cursor: second.nextCursor, limit: 50)
            await h.vm.loadConversationsFromHistory()
            let afterPages = try h.archive.diagnostics(userId: h.owner)
            try await expect(first.items.count == 50 && second.items.count == 50 && third.items.count == 23 && third.nextCursor == nil && Set((first.items + second.items + third.items).map(\.id)).count == 123 && h.vm.conversations.count == 10, "History uses actual keyset pages while Home holds only ten headers")
            try await expect(afterPages.bodyDecodes == before.bodyDecodes && afterPages.headerQueries >= before.headerQueries + 4, "Paging and Home refresh must never decode all conversation bodies")
            let search = try await h.vm.historyPage(ownerId: h.owner, query: "CAFE计划", limit: 50)
            try await expect(search.items.map(\.id) == ["page-042"], "Database search uses Unicode-aware normalized stored text")
            let detail = try await h.vm.conversation(withId: "page-042", ownerId: h.owner)
            let afterDetail = try h.archive.diagnostics(userId: h.owner)
            try await expect(detail?.messages.first?.content == "Private body 42" && afterDetail.bodyDecodes == afterPages.bodyDecodes + 1, "Opening one owner/id detail decodes exactly one selected body")
            try h.archive.upsert(conversation(id: "new-page-record", messages: [message(.user, "New generation")]), userId: h.owner)
            let cursorError = try await failure { _ = try await h.vm.historyPage(ownerId: h.owner, cursor: first.nextCursor, limit: 50) }
            try await expect(cursorError as? AssistantChatStorageError == .cursorInvalidated, "A changed generation cannot silently continue an obsolete page cursor")
        }
        try await run("viewmodel-authorized-purge-clears-unprepared-bad-owner-without-touching-live-owner") {
            let h = try await ChatHarness(owner: "live-owner-b"); defer { h.close() }
            ChatFixtureURLProtocol.enqueue(.hold("B keeps its live producer"))
            h.vm.inputText = "B private question"; h.vm.sendMessage(userId: h.owner)
            try await wait("live B before authorized A purge") { h.vm.messages.last?.content == "B keeps its live producer" }
            h.vm.inputText = "B private draft"; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            let removedOwner = "authorized-removed-owner-a", db = h.archive.databaseURL(userId: "authorized-removed-owner-a")
            let legacy = db.deletingPathExtension().appendingPathExtension("json")
            try Data("bad sqlite source".utf8).write(to: db)
            try Data("bad legacy source".utf8).write(to: legacy)
            try Data("bad legacy draft source".utf8).write(to: legacy.appendingPathExtension("draft"))
            let selected = h.vm.conversationId, visible = h.vm.messages, scope = h.vm.conversationScopeId
            try await expect(!h.archive.isPrepared(userId: removedOwner), "Authorized owner fixture is genuinely unprepared and corrupt")
            try await h.vm.purgeAuthorizedOwner(ownerId: removedOwner)
            try await expect(!FileManager.default.fileExists(atPath: db.path) && !FileManager.default.fileExists(atPath: legacy.path) && !FileManager.default.fileExists(atPath: legacy.appendingPathExtension("draft").path), "Explicit authorized purge can clear bad SQLite and legacy sources without preparing them")
            try await expect(h.vm.activeOwner == h.owner && h.vm.archiveIsReady && h.vm.conversationId == selected && h.vm.conversationScopeId == scope && h.vm.messages == visible && h.vm.inputText == "B private draft" && h.vm.isLoading && ChatFixtureURLProtocol.captured.count == 1, "A server-authorized deletion for A never navigates, cancels, clears or writes live B")
            ChatFixtureURLProtocol.enqueueDelta(" continues safely")
            try await wait("B continues after A purge") { h.vm.messages.last?.content.hasSuffix(" continues safely") == true }
        }
        try await run("viewmodel-cancelled-gate-waiter-cannot-release-another-operation") {
            let gate = AssistantArchiveOperationGate()
            let ticket = try gate.begin(ownerId: "owner-a", scopeId: UUID())
            let cancelledWaiter = Task { @MainActor () -> Error? in do { try await gate.waitUntilIdle(); return nil } catch { return error } }
            await Task.yield(); cancelledWaiter.cancel()
            let error = await cancelledWaiter.value
            try await expect(error is CancellationError && gate.isBusy && gate.isCurrent(ticket), "Cancelling a queued waiter removes only that continuation, never the operation lease")
            var resumed = false
            let survivingWaiter = Task { @MainActor in try await gate.waitUntilIdle(); resumed = true }
            await Task.yield()
            try await expect(!resumed && gate.isBusy, "Other waiters remain blocked until the real owner releases")
            gate.finish(ticket); try await survivingWaiter.value
            try await expect(resumed && !gate.isBusy, "Actual owner completion releases its surviving waiters exactly once")
        }
        try await run("viewmodel-ordered-background-saves-coalesce-complete-latest-draft-and-body") {
            let gate = ChatFixtureWorkerGate(); defer { gate.open() }
            let h = try await ChatHarness(beforeArchiveCommit: { gate.wait() }); defer { h.close() }
            h.vm.messages = [message(.user, "Complete body"), message(.assistant, "Complete answer")]
            h.vm.inputText = "Baseline draft"; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            gate.arm()
            h.vm.inputText = "Older pending draft"; h.vm.persistDraft()
            try await wait("old background save at commit gate") { gate.enteredCount > 0 }
            h.vm.inputText = "Latest complete draft"; h.vm.persistDraft()
            var mainActorResponsive = false
            let pulse = Task { @MainActor in mainActorResponsive = true }; await pulse.value
            try await expect(mainActorResponsive && !h.vm.isArchiveBusy, "Background autosave must not block typing or masquerade as an exclusive UI operation")
            gate.open(); await h.vm.waitForPendingArchiveWrites()
            try await expect(try h.archive.loadDraftRecord(userId: h.owner).text == "Latest complete draft" && h.archive.conversation(id: h.vm.conversationId, userId: h.owner)?.messages == h.vm.messages, "An invalidated queued save rolls back and the newest ordered full snapshot stores both body and draft")
        }
        try await run("viewmodel-mainactor-preflight-does-not-wait-for-busy-sqlite-worker") {
            let startup = ChatFixtureAsyncGate(); defer { startup.open() }
            let worker = ChatFixtureWorkerGate(); worker.arm(); defer { worker.open() }
            let h = try await ChatHarness(startupBarrier: { await startup.wait() }); defer { h.close() }
            let held = Task { try await h.archive.background { _ in worker.wait() } }
            try await wait("actual storage worker held for responsiveness") { worker.enteredCount > 0 }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { worker.open() }
            let started = Date()
            h.vm.inputText = "Send while a full read holds the worker"; h.vm.sendMessage(userId: h.owner)
            let duration = Date().timeIntervalSince(started)
            try await expect(duration < 0.25 && h.vm.isLoading, "Synchronous send and final metadata checks use only short memory locks, never queue.sync or disk I/O")
            worker.open(); try await held.value
            startup.open(); try await finished(h.vm)
        }
        try await run("viewmodel-platform-create-http-waits-for-delete-result-before-start") {
            for commitsDeletion in [false, true] {
                let token = ChatFixtureAsyncGate(); defer { token.open() }
                let worker = ChatFixtureWorkerGate(); defer { worker.open() }
                let fault = ChatFixtureArchiveFault(); defer { fault.arm(nil) }
                let h = try await ChatHarness(beforeArchiveCommit: { worker.wait(); try fault.check(.beforeCommit, owner: "fixture-owner") }); defer { h.close() }
                h.defaults.set("platform", forKey: h.prefix + "assistantMode"); h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
                AuthService.shared.holdNextAccessToken(token)
                ChatFixtureURLProtocol.enqueue(.conversation("server-after-rollback")); ChatFixtureURLProtocol.enqueue(.complete("Platform producer remains valid"))
                h.vm.inputText = "Queued platform source"; h.vm.sendMessage(userId: h.owner)
                try await wait("platform token pending") { token.enteredCount == 1 }
                await h.vm.waitForPendingArchiveWrites()
                let selected = h.vm.conversationId
                worker.arm(); if !commitsDeletion { fault.arm(.beforeCommit) }
                let deletion = Task { @MainActor () -> Error? in do { try await h.vm.deleteConversations(ids: [selected], ownerId: h.owner); return nil } catch { return error } }
                try await wait("platform deletion transaction owns gate") { worker.enteredCount > 0 && h.vm.isArchiveBusy }
                token.open(); try await Task.sleep(nanoseconds: 20_000_000)
                try await expect(ChatFixtureURLProtocol.captured.isEmpty, "Even conversation-creation HTTP waits while storage owns the source snapshot")
                worker.open(); let deletionError = await deletion.value; fault.arm(nil)
                if commitsDeletion {
                    try await wait("platform deleted source stopped") { !h.vm.isLoading }
                    try await expect(deletionError == nil && ChatFixtureURLProtocol.captured.isEmpty && h.vm.conversationId != selected, "Committed deletion starts neither create HTTP nor model HTTP")
                } else {
                    try await finished(h.vm)
                    try await expect(deletionError != nil && ChatFixtureURLProtocol.captured.count == 2 && h.vm.conversationId == selected && h.vm.messages.last?.content == "Platform producer remains valid", "Rollback resumes the existing platform source through one creation and one generation")
                }
            }
        }
        try await run("viewmodel-export-captures-snapshot-before-late-server-id-and-never-rereads") {
            let worker = ChatFixtureWorkerGate(); defer { worker.open() }
            let h = try await ChatHarness(beforeArchiveCommit: { worker.wait() }); defer { h.close() }
            h.defaults.set("platform", forKey: h.prefix + "assistantMode"); h.defaults.set(true, forKey: h.prefix + "regionConfirmed")
            ChatFixtureURLProtocol.enqueue(.holdConversation); ChatFixtureURLProtocol.enqueue(.complete("Late platform response"))
            h.vm.inputText = "Platform source during export"; h.vm.sendMessage(userId: h.owner)
            try await wait("platform create request held") { ChatFixtureURLProtocol.captured.count == 1 }
            await h.vm.waitForPendingArchiveWrites()
            let selected = h.vm.conversationId
            worker.arm()
            let export = Task { try await h.vm.flushForDataExport(ownerId: h.owner) }
            try await wait("capture export gate before commit") { worker.enteredCount > 0 && h.vm.isArchiveBusy }
            ChatFixtureURLProtocol.completeHeldConversation(id: "late-server-id")
            try await Task.sleep(nanoseconds: 25_000_000)
            try await expect(ChatFixtureURLProtocol.captured.count == 1 && h.vm.isLoading, "A late create response cannot publish server identity or start model HTTP inside the export gate")
            worker.open(); let captured = try await export.value
            try await finished(h.vm)
            try await expect(captured.ownerId == h.owner && captured.conversations.first(where: { $0.id == selected })?.serverConversationId == nil, "Export contains the immutable owner-bound snapshot captured in the same flush transaction")
            try await expect(try h.archive.conversation(id: selected, userId: h.owner)?.serverConversationId == "late-server-id" && ChatFixtureURLProtocol.captured.count == 2, "After gate release the same producer may publish its verified server ID and continue normally")
            try await expect(captured.conversations.first(where: { $0.id == selected })?.messages.last?.status == .pending, "Later streaming and persistence cannot mutate the previously captured export snapshot")
        }
        try await run("viewmodel-owner-departure-preserves-source-before-first-autosave-can-commit") {
            let startup = ChatFixtureAsyncGate(); defer { startup.open() }
            let worker = ChatFixtureWorkerGate(); defer { worker.open() }
            let h = try await ChatHarness(startupBarrier: { await startup.wait() }, beforeArchiveCommit: { worker.wait() }); defer { h.close() }
            try await h.configure(owner: "departure-owner-b")
            let originalId = h.vm.conversationId, originalScope = h.vm.conversationScopeId
            worker.arm()
            h.vm.inputText = "A question not yet committed"; h.vm.sendMessage(userId: h.owner)
            try await wait("first actual autosave blocked before COMMIT") { worker.enteredCount > 0 && startup.enteredCount == 1 }
            h.vm.inputText = "A unsent draft at departure"
            AuthService.shared.user = ChatFixtureUser(id: "departure-owner-b"); h.vm.activateOwner()
            try await expect(h.vm.activeOwner == "departure-owner-b" && h.vm.messages.isEmpty && h.vm.inputText.isEmpty, "Account departure clears private UI synchronously without waiting for blocked SQLite")
            AuthService.shared.user = ChatFixtureUser(id: h.owner); h.vm.activateOwner()
            worker.open(); try await h.vm.waitForArchiveReady(ownerId: h.owner)
            await h.vm.waitForPendingArchiveWrites()
            try await expect(h.vm.conversationId == originalId && h.vm.conversationScopeId != originalScope && h.vm.inputText == "A unsent draft at departure" && h.vm.messages.first?.content == "A question not yet committed" && h.vm.messages.last?.status == .cancelled && !h.vm.isLoading, "Returning A waits for its explicit departure save rather than reviving a producer or losing its first turn")
            try await expect(try h.archive.conversation(id: originalId, userId: h.owner)?.messages == h.vm.messages && h.archive.loadDraft(userId: h.owner) == h.vm.inputText, "The original pending autosave was invalidated, but the owner-bound final snapshot durably stores body and draft")
            startup.open(); try await Task.sleep(nanoseconds: 20_000_000)
            try await expect(ChatFixtureURLProtocol.captured.isEmpty, "The old queued producer stays cancelled across the owner ABA")
        }
        try await run("viewmodel-cold-durable-purge-intent-publishes-before-explicit-new-recovery") {
            let removedOwner = "cold-purge-owner-a", liveOwner = "cold-live-owner-b"
            let fault = ChatFixtureArchiveFault()
            let h = try await ChatHarness(owner: liveOwner, archiveFault: { point, owner in
                if owner == removedOwner { try fault.check(point, owner: owner) }
            })
            defer { AuthService.shared.user = ChatFixtureUser(id: liveOwner); fault.arm(nil); h.close() }
            let sourceDirectory = h.directory.appendingPathComponent("conversations")
            let seedArchive = AssistantChatArchive(directory: sourceDirectory)
            try await seedArchive.prepareAsync(userId: removedOwner)
            let originalId = "cold-purge-private-history", picture = try image()
            let oldMessages = (0..<260).map { index in
                message(index.isMultiple(of: 2) ? .user : .assistant, "Old private body \(index)")
            }
            let original = Conversation(id: originalId, title: "Old private title", preview: "Old private preview", date: Date(), messages: oldMessages)
            try await seedArchive.backgroundTransaction(userId: removedOwner, operation: { store in
                try store.upsert(original, userId: removedOwner)
                try store.saveDraft("Old private draft must never restore", images: [picture], conversationId: originalId, userId: removedOwner)
            })
            let originalDatabase = seedArchive.databaseURL(userId: removedOwner)
            let originalDatabaseBytes = try Data(contentsOf: originalDatabase)
            try await expect(!h.archive.isPrepared(userId: removedOwner), "The authorized deletion caller has genuinely never prepared A's database handle")
            fault.arm(.purgeDatabaseRemoval)
            let purgeError = try await failure { try await h.vm.purgeAuthorizedOwner(ownerId: removedOwner) }
            fault.arm(nil)
            try await expect(purgeError as? AssistantChatStorageError == .publicationCommittedCleanupPending, "The fixture comes from the actual authorized unprepared purge path and real physical cleanup failure")
            try await expect(try Data(contentsOf: originalDatabase) == originalDatabaseBytes && h.vm.activeOwner == liveOwner && h.vm.archiveIsReady,
                "A's old 260-message SQLite bytes remain while the live unrelated B account is preserved")
            let markerData = try Data(contentsOf: h.archive.authorityURL(userId: removedOwner))
            let marker = try JSONSerialization.jsonObject(with: markerData) as? [String: Any]
            try await expect(marker?["state"] as? String == "purging", "The fixture retains the real durable purge intent rather than an invented cache state")

            // A new directory gives a new authorization namespace, just as a fresh process
            // starts without the previous process's published in-memory purge metadata.
            let coldDirectory = h.directory.appendingPathComponent("cold-pending-independent")
            try FileManager.default.copyItem(at: sourceDirectory, to: coldDirectory)
            func coldBytes() throws -> [String: Data] {
                let urls = try FileManager.default.contentsOfDirectory(at: coldDirectory, includingPropertiesForKeys: nil)
                return try Dictionary(uniqueKeysWithValues: urls.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
            }
            let pendingBytes = try coldBytes()
            let coldArchive = AssistantChatArchive(directory: coldDirectory)
            let initialAuthorization = coldArchive.authorizationSnapshot(userId: removedOwner)
            try await expect(initialAuthorization.unknown && !initialAuthorization.prepared && !initialAuthorization.purging && !initialAuthorization.inFlightDestructive,
                "The copied durable fixture starts with a truly cold shared registry and cannot inherit the seed archive's purge publication")
            AuthService.shared.user = ChatFixtureUser(id: removedOwner)
            let prefix = "caobao.assistant.\(Data(removedOwner.utf8).base64EncodedString())."
            h.defaults.set("en", forKey: prefix + "language")
            let cold = ChatViewModel(archive: coldArchive, transport: h.transport, conversationClient: h.conversationClient, repository: h.repository, defaults: h.defaults)
            defer { cold.cancel() }
            let preparationError = try await failure { try await cold.waitForArchiveReady(ownerId: removedOwner) }
            let published = coldArchive.authorizationSnapshot(userId: removedOwner)
            try await expect(preparationError as? AssistantChatStorageError == .purgeRecoveryRequired && published.purging && !published.canWrite(),
                "prepare must publish the durable purge intent before returning its recovery error to a cold VM")
            try await expect(cold.archiveRequiresRecovery && !cold.archiveIsReady && !cold.archiveIsLoading && cold.messages.isEmpty && cold.conversations.isEmpty && cold.inputText.isEmpty && cold.pendingImages.isEmpty && cold.conversationId != originalId,
                "Cold bootstrap hides every old message, draft, image and selected source while exposing explicit cleanup recovery")
            await cold.loadFromLocal()
            try await expect(cold.archiveOperationError == AssistantArchiveStateError.unavailable.localizedDescription,
                "The public retry loader retains the existing localized storage-unavailable message instead of displaying an opaque Swift error domain and code")
            try await expect(try coldBytes() == pendingBytes, "Bootstrap and read retries publish only metadata and never automatically purge or rewrite the original durable bytes")

            let prompt = "  Only this explicit clean draft\n"
            try await expect(!(await cold.requestNewConversation(ownerId: removedOwner, initialText: prompt)), "Retry cleanup must offer a confirmation ticket instead of returning the bootstrap read failure")
            guard let cancelled = cold.pendingConversationSwitch else { throw ChatTestFailure(description: "Cold durable purge must expose a public cleanup confirmation ticket") }
            try await expect(cancelled.isRecoveringDeletedConversation && cancelled.isNewConversation && cold.requiresConversationSwitchConfirmation,
                "The public ticket explicitly distinguishes cleanup recovery from ordinary navigation")
            cold.rejectConversationSwitch()
            try await expect(try coldBytes() == pendingBytes && coldArchive.authorizationSnapshot(userId: removedOwner).purging && cold.messages.isEmpty && cold.inputText.isEmpty,
                "Default cancellation preserves every original byte and the durable purge intent without reviving hidden content")
            try await expect(!(await cold.requestNewConversation(ownerId: removedOwner, initialText: prompt)), "A cancelled cleanup requires a fresh explicit recovery confirmation")
            guard let confirmed = cold.pendingConversationSwitch else { throw ChatTestFailure(description: "Missing fresh cold cleanup confirmation") }
            try await expect((await cold.confirmConversationSwitch(confirmed)), "Only explicit confirmation performs physical cleanup, prepares a fresh store and selects the new initial draft")
            await cold.loadConversationsFromHistory()
            let drafts = try coldArchive.loadDraftRecords(userId: removedOwner)
            let finalAuthorization = coldArchive.authorizationSnapshot(userId: removedOwner)
            try await expect(cold.archiveIsReady && !cold.archiveRequiresRecovery && !cold.isArchiveBusy && cold.conversationId == confirmed.targetConversationId && cold.messages.isEmpty && cold.conversations.isEmpty && cold.inputText == prompt && cold.pendingImages.isEmpty,
                "Confirmed cold recovery publishes only the deliberately supplied new text with no old messages, image or draft resurrection")
            try await expect(try coldArchive.load(userId: removedOwner).isEmpty && drafts.count == 1 && drafts[0].conversationId == confirmed.targetConversationId && drafts[0].text == prompt && (drafts[0].images ?? []).isEmpty && finalAuthorization.canWrite(conversationId: confirmed.targetConversationId) && !finalAuthorization.purging,
                "The fresh authoritative SQLite store contains only the explicit replacement draft and is actually writable")
            try await expect(try Data(contentsOf: originalDatabase) == originalDatabaseBytes && Data(contentsOf: h.archive.authorityURL(userId: removedOwner)) == markerData && ChatFixtureURLProtocol.captured.isEmpty,
                "Recovery is confined to the independent cold namespace, leaves the source fixture intact and starts zero HTTP requests")
            cold.cancel(); await cold.waitForPendingArchiveWrites()
        }
        try await run("viewmodel-task-tools-three-protocols-propose-only-after-real-verified-stream") {
            for kind in AssistantWireProtocol.allCases {
                let h = try await ChatHarness(); defer { h.close() }
                let proposal = try await completedTaskProposal(h, kind: kind)
                try await expect(proposal.ownerId == h.owner && proposal.conversationId == h.vm.conversationId && proposal.assistantMessageId == h.vm.messages.last?.id
                    && proposal.sourceUserMessageId == h.vm.messages.first?.id && proposal.sourceUserContentDigest == AssistantTaskProposal.digest([h.vm.messages.first!.content])
                    && proposal.call.trace.protocolKind == kind, "Only the completed real tool stream binds an immutable owner/conversation/message/user/config proposal")
                try await expect(h.repository.tasks(for: h.owner).isEmpty && h.vm.canReviewTaskProposal(messageId: proposal.assistantMessageId)
                    && h.vm.canApproveTaskProposal(messageId: proposal.assistantMessageId), "A model proposal alone must never create or schedule a real task")
                try await expect(try h.vm.taskProposalReceipt(messageId: proposal.assistantMessageId) == nil && h.archive.conversation(id: proposal.conversationId, userId: h.owner)?.messages.last?.taskProposal == proposal,
                    "The proposal really persists before an independent task decision exists")
                try await expect(try body()["tools"] != nil && ChatFixtureURLProtocol.captured.count == 1, "Verified user-enabled BYOK requests really include the task tool schema")
                h.vm.inputText = "Keep this unsent next prompt"; h.vm.sendMessage(userId: h.owner)
                try await expect(h.vm.messages.count == 2 && h.vm.inputText == "Keep this unsent next prompt" && ChatFixtureURLProtocol.captured.count == 1
                    && h.vm.error == AssistantTaskToolError.decisionRequired.localizedDescription, "An unresolved completed proposal blocks a new generation without dropping the draft")
                _ = try await failure { _ = try h.vm.makeGenerationActionSource(messageId: proposal.assistantMessageId) }
                try await expect(!h.vm.canPerformGenerationAction(from: h.vm.messages.last!), "A tool proposal cannot regenerate and repeat its create-task instruction")
            }
        }
        try await run("viewmodel-task-tools-before-http-eof-and-cancellation-never-authorize") {
            for kind in AssistantWireProtocol.allCases {
                let h = try await ChatHarness(); defer { h.close() }
                try await enableTaskTools(h, kind: kind)
                ChatFixtureURLProtocol.enqueue(.holdStream(taskStream(kind, arguments: taskArguments())))
                h.vm.inputText = "Do not execute a partial stream"; h.vm.sendMessage(userId: h.owner)
                try await wait("real tool terminal bytes parsed before HTTP EOF") { h.vm.messages.last?.usage?.outputTokens == 5 }
                try await expect(h.vm.isLoading && h.vm.messages.last?.taskProposal == nil && h.repository.tasks(for: h.owner).isEmpty,
                    "Even parsed complete arguments and a provider terminal event remain non-actionable until actual HTTP EOF")
                _ = try await failure { _ = try h.vm.makeTaskProposalSource(messageId: h.vm.messages.last!.id) }
                h.vm.cancel(); await h.vm.waitForPendingArchiveWrites(); ChatFixtureURLProtocol.finishHeld()
                try await expect(h.vm.messages.last?.status == .cancelled && h.vm.messages.last?.taskProposal == nil && h.repository.tasks(for: h.owner).isEmpty
                    && ChatFixtureURLProtocol.captured.count == 1, "Cancelling the real producer cannot publish, approve or execute a half tool")
            }
        }
        try await run("viewmodel-task-tools-invalid-or-unknown-call-creates-no-proposal-or-task") {
            for variant in 0..<3 {
                let h = try await ChatHarness(); defer { h.close() }
                try await enableTaskTools(h, kind: .chatCompletions)
                let args = variant == 0 ? "{broken" : (variant == 1 ? String(taskArguments().dropLast()) + ",\"unapproved\":true}" : taskArguments())
                ChatFixtureURLProtocol.enqueue(.stream(taskStream(.chatCompletions, arguments: args, name: variant == 2 ? "delete_everything" : "create_task")))
                h.vm.inputText = "Reject unsafe tool parameters"; h.vm.sendMessage(userId: h.owner)
                try await wait("invalid tool stream fails") { !h.vm.isLoading }; await h.vm.waitForPendingArchiveWrites()
                try await expect(h.vm.messages.last?.status == .failed && h.vm.messages.last?.taskProposal == nil && h.repository.tasks(for: h.owner).isEmpty
                    && ChatFixtureURLProtocol.captured.count == 1, "Malformed, extra-key or non-allowlisted real tool calls never become executable proposals")
            }
        }
        try await run("viewmodel-task-tools-disabled-stale-and-unversioned-proof-fail-closed") {
            for variant in 0..<3 {
                let h = try await ChatHarness(); defer { h.close() }
                try await enableTaskTools(h, kind: .chatCompletions)
                if variant == 0 { try AssistantTaskToolPreferences.set(enabled: false, verifiedFingerprint: nil, defaults: h.defaults, ownerId: h.owner) }
                else if variant == 1 { h.defaults.set("changed-model", forKey: h.byokPrefix + "model") }
                else { h.defaults.set(0, forKey: h.prefix + "taskToolsSchemaVersion") }
                h.vm.generationConfigurationDidChange()
                ChatFixtureURLProtocol.enqueue(.stream(taskStream(.chatCompletions, arguments: taskArguments())))
                h.vm.inputText = "No verified task capability here"; h.vm.sendMessage(userId: h.owner)
                try await wait("unavailable capability rejects unexpected tool") { !h.vm.isLoading }; await h.vm.waitForPendingArchiveWrites()
                try await expect(try body()["tools"] == nil && h.vm.messages.last?.taskProposal == nil && h.repository.tasks(for: h.owner).isEmpty,
                    "A toggle alone, another configuration or an old schema proof must never enable task tools")
            }
        }
        try await run("viewmodel-task-tools-platform-cannot-borrow-byok-proof-or-execute") {
            let h = try await ChatHarness(); defer { h.close() }
            try await enableTaskTools(h, kind: .chatCompletions)
            h.defaults.set("platform", forKey: h.prefix + "assistantMode"); h.defaults.set(true, forKey: h.prefix + "regionConfirmed"); h.vm.generationConfigurationDidChange()
            ChatFixtureURLProtocol.enqueue(.conversation("platform-tool-rejected")); ChatFixtureURLProtocol.enqueue(.stream(taskStream(.chatCompletions, arguments: taskArguments())))
            h.vm.inputText = "Platform tool execution is not enabled"; h.vm.sendMessage(userId: h.owner)
            try await wait("platform tool reply rejected") { !h.vm.isLoading }; await h.vm.waitForPendingArchiveWrites()
            try await expect(try body(1)["tools"] == nil && body(1)["mode"] as? String == "platform" && ChatFixtureURLProtocol.captured[1].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token",
                "Platform traffic uses only its real platform contract and never the BYOK key or capability declaration")
            try await expect(h.vm.messages.last?.status == .failed && h.vm.messages.last?.taskProposal == nil && h.repository.tasks(for: h.owner).isEmpty,
                "An unexpected platform tool call never creates a local task or approval source")
        }
        try await run("viewmodel-task-tools-approval-commits-real-edited-task-and-no-model-reminder-consent") {
            let h = try await ChatHarness(); defer { h.close() }
            let proposal = try await completedTaskProposal(h, arguments: taskArguments(dueAt: Date().addingTimeInterval(86_400), reminderRequested: true))
            let source = try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId)
            var schedulingCalls = 0
            let outcome = try await h.vm.approveTaskProposal(source, editedTask: editedTask(proposal, title: "User-approved edited title"), enableReminder: false,
                scheduleReminder: { _, _ in schedulingCalls += 1 })
            let tasks = h.repository.tasks(for: h.owner)
            let reloaded = AssistantLocalRepository(fileURL: h.directory.appendingPathComponent("repository.json"))
            try await expect(tasks.count == 1 && tasks[0].id == proposal.taskId && tasks[0].title == "User-approved edited title" && tasks[0].reminderEnabled == false
                && tasks[0].sourceMessageId == proposal.assistantMessageId && schedulingCalls == 0, "User editing really creates one stable task; a model reminder suggestion never grants notification permission")
            try await expect(try outcome.receipt.decision == .saved && outcome.receipt.reminderState == .notRequested && reloaded.tasks(for: h.owner).count == 1
                && reloaded.taskToolReceipt(proposalId: proposal.id, ownerId: h.owner) == outcome.receipt && ChatFixtureURLProtocol.captured.count == 1,
                "Task and authoritative saved receipt survive a real repository reload without any automatic model follow-up")
        }
        try await run("viewmodel-task-tools-repeat-and-deleted-task-never-create-again") {
            let h = try await ChatHarness(); defer { h.close() }
            let proposal = try await completedTaskProposal(h), source = try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId)
            let original = try await h.vm.approveTaskProposal(source, editedTask: editedTask(proposal), enableReminder: false)
            _ = try await failure { _ = try await h.vm.approveTaskProposal(source, editedTask: editedTask(proposal), enableReminder: false) }
            let fresh = try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId)
            let duplicate = try await h.vm.approveTaskProposal(fresh, editedTask: editedTask(proposal), enableReminder: false)
            try await expect(duplicate.receipt == original.receipt && h.repository.tasks(for: h.owner).count == 1, "A fresh repeated approval reads the original atomic receipt instead of inserting another task")
            try await expect(h.repository.deleteTask(id: proposal.taskId, userId: h.owner), "The real created task can be explicitly deleted")
            let afterDelete = try await h.vm.approveTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId), editedTask: editedTask(proposal), enableReminder: false)
            try await expect(afterDelete.receipt == original.receipt && afterDelete.task == nil && h.repository.tasks(for: h.owner).isEmpty,
                "A retained saved receipt prevents a deleted task from resurrecting on repeated approval")
        }
        try await run("viewmodel-task-tools-decline-persists-real-result-and-unblocks-normal-new-user-round") {
            let h = try await ChatHarness(); defer { h.close() }
            let proposal = try await completedTaskProposal(h)
            let receipt = try await h.vm.declineTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId))
            try await expect(receipt.decision == .declined && receipt.taskId == nil && h.repository.tasks(for: h.owner).isEmpty && ChatFixtureURLProtocol.captured.count == 1,
                "Explicit rejection records a real terminal outcome with no task, notification or automatic HTTP")
            ChatFixtureURLProtocol.enqueue(.stream(taskPlainReply(.chatCompletions, "A normal new round works")))
            h.vm.inputText = "Ask a different ordinary question"; h.vm.sendMessage(userId: h.owner)
            if h.vm.requiresBYOKConfirmation { h.vm.confirmBYOKContext() }; try await finished(h.vm)
            try await expect(ChatFixtureURLProtocol.captured.count == 2 && h.vm.messages.last?.content == "A normal new round works" && h.vm.canPerformGenerationAction(from: h.vm.messages.last!),
                "A resolved tool proposal does not disable ordinary retry/regeneration on a later real user round")
        }
        try await run("viewmodel-task-tools-restart-requires-fresh-ticket-and-preserves-receipt") {
            let h = try await ChatHarness(); defer { h.close() }
            let proposal = try await completedTaskProposal(h), old = try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId)
            let restarted = ChatViewModel(archive: h.archive, transport: h.transport, conversationClient: h.conversationClient, repository: h.repository, defaults: h.defaults)
            try await restarted.waitForArchiveReady(ownerId: h.owner); defer { restarted.cancel() }
            _ = try await failure { _ = try await restarted.approveTaskProposal(old, editedTask: editedTask(proposal), enableReminder: false) }
            try await expect(h.repository.tasks(for: h.owner).isEmpty, "A persisted proposal cannot replay an approval ticket issued by a prior VM instance")
            let outcome = try await restarted.approveTaskProposal(try restarted.makeTaskProposalSource(messageId: proposal.assistantMessageId), editedTask: editedTask(proposal), enableReminder: false)
            let reloaded = AssistantLocalRepository(fileURL: h.directory.appendingPathComponent("repository.json"))
            try await expect(try reloaded.taskToolReceipt(proposalId: proposal.id, ownerId: h.owner) == outcome.receipt && reloaded.tasks(for: h.owner).count == 1
                && restarted.canContinueTaskProposal(messageId: proposal.assistantMessageId), "A newly signed review after restart creates once and recovers the authoritative decision")
        }
        try await run("viewmodel-task-tools-source-config-unicode-and-owner-aba-expire-approval") {
            for change in ["text", "unicode", "proposal", "config", "owner"] {
                let h = try await ChatHarness(); defer { AuthService.shared.user = ChatFixtureUser(id: h.owner); h.close() }
                let prompt = change == "unicode" ? "é" : "Original tool question"
                let proposal = try await completedTaskProposal(h, prompt: prompt), source = try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId)
                switch change {
                case "text": h.vm.messages[0].content = "Changed"; h.vm.messages[0].content = prompt
                case "unicode": h.vm.messages[0].content = "e" + String(UnicodeScalar(0x301)!); h.vm.messages[0].content = prompt
                case "proposal": h.vm.messages[h.vm.messages.count - 1].taskProposal = nil
                case "config":
                    let originalURL = h.defaults.string(forKey: h.byokPrefix + "url")!
                    h.defaults.set("https://api.example.com/temporary/v1", forKey: h.byokPrefix + "url"); h.vm.generationConfigurationDidChange()
                    h.defaults.set(originalURL, forKey: h.byokPrefix + "url"); h.vm.generationConfigurationDidChange()
                default:
                    try await h.configure(owner: "tool-owner-b"); AuthService.shared.user = ChatFixtureUser(id: "tool-owner-b"); h.vm.activateOwner()
                    AuthService.shared.user = ChatFixtureUser(id: h.owner); h.vm.activateOwner(); try await h.vm.waitForArchiveReady(ownerId: h.owner)
                }
                _ = try await failure { _ = try await h.vm.approveTaskProposal(source, editedTask: editedTask(proposal), enableReminder: false) }
                try await expect(h.repository.tasks(for: h.owner).isEmpty && ChatFixtureURLProtocol.captured.count == 1,
                    "Text, raw Unicode ABA, proposal changes, configuration ABA and account ABA cannot revive old task authority")
            }
        }
        try await run("viewmodel-task-tools-deleted-source-still-allows-fresh-safe-decline") {
            let h = try await ChatHarness(); defer { h.close() }
            let proposal = try await completedTaskProposal(h), old = try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId)
            h.vm.deleteMessage(proposal.sourceUserMessageId); await h.vm.waitForPendingArchiveWrites()
            try await expect(!h.vm.messages.contains(where: { $0.id == proposal.sourceUserMessageId }) && h.vm.canReviewTaskProposal(messageId: proposal.assistantMessageId)
                && !h.vm.canApproveTaskProposal(messageId: proposal.assistantMessageId), "Deleting the old user source cannot execute the proposal but must leave a fresh local rejection route")
            _ = try await failure { _ = try await h.vm.approveTaskProposal(old, editedTask: editedTask(proposal), enableReminder: false) }
            let declined = try await h.vm.declineTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId))
            try await expect(declined.decision == .declined && h.repository.tasks(for: h.owner).isEmpty, "A fresh reject records the real no-side-effect result without requiring deleted private source text")
            ChatFixtureURLProtocol.enqueue(.stream(taskPlainReply(.chatCompletions, "The deleted source did not lock the chat")))
            h.vm.inputText = "Continue an ordinary new conversation turn"; h.vm.sendMessage(userId: h.owner)
            if h.vm.requiresBYOKConfirmation { h.vm.confirmBYOKContext() }; try await finished(h.vm)
            try await expect(!String(decoding: try JSONSerialization.data(withJSONObject: body(1)), as: UTF8.self).contains(proposal.call.id),
                "An absent source uses visible outcome text rather than replaying hidden provider tool trace")
        }
        try await run("viewmodel-task-tools-pre-cancelled-approval-commits-nothing") {
            let h = try await ChatHarness(); defer { h.close() }
            let proposal = try await completedTaskProposal(h), source = try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId)
            let cancelled = Task { try await h.vm.approveTaskProposal(source, editedTask: editedTask(proposal), enableReminder: false) }
            cancelled.cancel(); _ = try await failure { _ = try await cancelled.value }
            try await expect(try h.repository.tasks(for: h.owner).isEmpty && h.repository.taskToolReceipt(proposalId: proposal.id, ownerId: h.owner) == nil,
                "A cancelled pre-commit approval cannot create either the task or its receipt")
        }
        try await run("viewmodel-task-tools-notification-failure-retains-one-real-task-and-failed-receipt") {
            let h = try await ChatHarness(); defer { h.close() }
            let proposal = try await completedTaskProposal(h, arguments: taskArguments(dueAt: Date().addingTimeInterval(86_400), reminderRequested: true))
            var calls = 0, sawCommittedTask = false
            let action: AssistantTaskToolReminderOperation = { saved, commitGuard in
                calls += 1; try commitGuard.validate()
                sawCommittedTask = h.repository.tasks(for: h.owner).contains(saved) && saved.reminderEnabled == false
                throw URLError(.notConnectedToInternet)
            }
            let outcome = try await h.vm.approveTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId), editedTask: editedTask(proposal, reminder: true), enableReminder: true, scheduleReminder: action)
            try await expect(sawCommittedTask && calls == 1 && outcome.receipt.decision == .saved && outcome.receipt.reminderState == .failed
                && outcome.reminderFailureMessage != nil && h.repository.tasks(for: h.owner).count == 1 && h.repository.tasks(for: h.owner)[0].reminderEnabled == false,
                "The optional second stage runs only after a real saved task; a reminder failure never rolls it back or claims delivery")
            let repeated = try await h.vm.approveTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId), editedTask: editedTask(proposal, reminder: true), enableReminder: true, scheduleReminder: action)
            try await expect(repeated.receipt == outcome.receipt && calls == 1 && h.repository.tasks(for: h.owner).count == 1,
                "Retrying an already saved decision cannot create another task or retry a notification implicitly")
        }
        try await run("viewmodel-task-tools-postcommit-cancellation-and-owner-change-never-claim-rollback") {
            for changesOwner in [false, true] {
                let h = try await ChatHarness(); defer { AuthService.shared.user = ChatFixtureUser(id: h.owner); h.close() }
                try await h.configure(owner: "notification-owner-b")
                let proposal = try await completedTaskProposal(h, arguments: taskArguments(dueAt: Date().addingTimeInterval(86_400), reminderRequested: true))
                let gate = ChatFixtureAsyncGate(); defer { gate.open() }
                let approving = Task { try await h.vm.approveTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId), editedTask: editedTask(proposal, reminder: true), enableReminder: true,
                    scheduleReminder: { _, commitGuard in await gate.wait(); try commitGuard.validate() }) }
                try await wait("task committed before reminder await") { gate.enteredCount == 1 }
                try await expect(h.repository.tasks(for: h.owner).count == 1, "The cancellation fixture is deterministically after actual task commit")
                if changesOwner { AuthService.shared.user = ChatFixtureUser(id: "notification-owner-b"); h.vm.activateOwner() }
                else { approving.cancel() }
                let newOwnerScope = h.vm.conversationScopeId, newOwnerMessages = h.vm.messages
                gate.open(); let outcome = try await approving.value
                try await expect(outcome.receipt.decision == .saved && outcome.reminderFailureMessage != nil && h.repository.tasks(for: h.owner).count == 1
                    && h.repository.tasks(for: h.owner)[0].reminderEnabled == false, "Cancellation or owner change after commit returns a real saved-task/uncertain-reminder outcome, never a fictitious rollback")
                if changesOwner {
                    try await expect(h.vm.activeOwner == "notification-owner-b" && h.vm.conversationScopeId == newOwnerScope && h.vm.messages == newOwnerMessages && h.repository.tasks(for: "notification-owner-b").isEmpty,
                        "Finishing the departed owner's reminder cannot publish or create into the new account")
                    AuthService.shared.user = ChatFixtureUser(id: h.owner); h.vm.activateOwner(); try await h.vm.waitForArchiveReady(ownerId: h.owner)
                }
            }
        }
        try await run("viewmodel-task-tools-three-protocols-explicit-continue-sends-real-paired-result-once") {
            for kind in AssistantWireProtocol.allCases {
                let h = try await ChatHarness(); defer { h.close() }
                let proposal = try await completedTaskProposal(h, kind: kind)
                _ = try await h.vm.approveTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId), editedTask: editedTask(proposal), enableReminder: false)
                try await expect(h.vm.canContinueTaskProposal(messageId: proposal.assistantMessageId), "A terminal actual task result exposes one explicit continuation")
                let awaitingConsent = try await h.vm.continueTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId))
                try await expect(!awaitingConsent && h.vm.requiresBYOKConfirmation && ChatFixtureURLProtocol.captured.count == 1, "Every continuation re-prepares and asks destination consent before any claim or HTTP")
                ChatFixtureURLProtocol.enqueue(.stream(taskPlainReply(kind, "The real local task has been saved"))); h.vm.confirmBYOKContext(); try await finished(h.vm)
                let payload = try body(1), strings = jsonStrings(payload), encoded = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
                try await expect(strings.contains(where: { $0.contains("task_saved") && $0.contains(proposal.taskId) }) && encoded.contains(proposal.call.id),
                    "The actual task receipt, never model arguments claiming success, is paired with its provider call in the follow-up")
                switch kind {
                case .chatCompletions: try await expect(payload["tool_choice"] as? String == "none" && encoded.contains("tool_call_id"), "Chat continuation disables new tools and pairs the result")
                case .responses: try await expect(payload["tool_choice"] as? String == "none" && strings.contains("opaque-task-reasoning") && encoded.contains("function_call_output"), "Responses continuation retains required encrypted reasoning plus the call/result pair")
                case .anthropic: try await expect((payload["tool_choice"] as? [String: Any])?["type"] as? String == "none" && strings.contains("opaque-task-signature") && encoded.contains("tool_result"), "Anthropic continuation retains signed thinking plus its tool use/result pair")
                }
                try await expect(try h.repository.taskToolReceipt(proposalId: proposal.id, ownerId: h.owner)?.continuationAttemptId != nil
                    && h.repository.tasks(for: h.owner).count == 1 && ChatFixtureURLProtocol.captured.count == 2 && !h.vm.canContinueTaskProposal(messageId: proposal.assistantMessageId),
                    "One persistent attempt is claimed before the single actual follow-up; it never executes create_task again")
                _ = try await failure { _ = try h.vm.makeGenerationActionSource(messageId: h.vm.messages.last!.id) }
            }
        }
        try await run("viewmodel-task-tools-continue-consent-and-startup-cancel-before-claim-consume-no-attempt") {
            let controller = ChatFixtureNextStartupGate()
            let h = try await ChatHarness(startupBarrier: { await controller.wait() }); defer { h.close() }
            let proposal = try await completedTaskProposal(h)
            _ = try await h.vm.approveTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId), editedTask: editedTask(proposal), enableReminder: false)
            _ = try await h.vm.continueTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId)); h.vm.rejectBYOKContext()
            try await expect(try h.repository.taskToolReceipt(proposalId: proposal.id, ownerId: h.owner)?.continuationAttemptId == nil && ChatFixtureURLProtocol.captured.count == 1,
                "Cancelling destination consent neither claims an attempt nor sends a hidden request")
            let gate = ChatFixtureAsyncGate(); defer { gate.open() }; controller.holdNext(gate)
            _ = try await h.vm.continueTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId)); h.vm.confirmBYOKContext()
            try await wait("continuation held before final claim") { gate.enteredCount == 1 }
            h.vm.cancel(); await h.vm.waitForPendingArchiveWrites(); gate.open()
            try await expect(try h.repository.taskToolReceipt(proposalId: proposal.id, ownerId: h.owner)?.continuationAttemptId == nil && h.repository.tasks(for: h.owner).count == 1
                && ChatFixtureURLProtocol.captured.count == 1, "Cancelling queued startup before the claim does not consume an attempt or undo the already saved task")
        }
        try await run("viewmodel-task-tools-claimed-continue-survives-cancel-delete-marker-and-restart") {
            let h = try await ChatHarness(); defer { h.close() }
            let proposal = try await completedTaskProposal(h)
            _ = try await h.vm.approveTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId), editedTask: editedTask(proposal), enableReminder: false)
            _ = try await h.vm.continueTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId))
            ChatFixtureURLProtocol.enqueue(.hold("Partial explicit continuation")); h.vm.confirmBYOKContext()
            try await wait("claimed continuation actually streaming") { h.vm.messages.last?.content == "Partial explicit continuation" }
            let marker = h.vm.messages.last!.id
            h.vm.cancel(); await h.vm.waitForPendingArchiveWrites(); h.vm.deleteMessage(marker); await h.vm.waitForPendingArchiveWrites()
            try await expect(try h.vm.messages.last?.id == proposal.assistantMessageId && h.repository.taskToolReceipt(proposalId: proposal.id, ownerId: h.owner)?.continuationAttemptId != nil
                && !h.vm.canContinueTaskProposal(messageId: proposal.assistantMessageId), "Deleting a visible failed/ cancelled marker cannot erase the repository's authoritative attempt claim")
            let restarted = ChatViewModel(archive: h.archive, transport: h.transport, conversationClient: h.conversationClient, repository: h.repository, defaults: h.defaults)
            try await restarted.waitForArchiveReady(ownerId: h.owner); defer { restarted.cancel() }
            try await expect(!restarted.canContinueTaskProposal(messageId: proposal.assistantMessageId), "A new VM reads the persistent claim rather than replaying continuation authority")
            _ = try await failure { _ = try await restarted.continueTaskProposal(try restarted.makeTaskProposalSource(messageId: proposal.assistantMessageId)) }
            try await expect(h.repository.tasks(for: h.owner).count == 1 && ChatFixtureURLProtocol.captured.count == 2, "A claimed cancelled attempt never recreates a task or silently starts a second follow-up")
        }
        try await run("viewmodel-task-tools-changed-destination-can-fresh-decline-and-only-replays-visible-text") {
            let h = try await ChatHarness(); defer { h.close() }
            let proposal = try await completedTaskProposal(h, kind: .responses), old = try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId)
            h.defaults.set("https://api.example.com/another-tenant/v1", forKey: h.byokPrefix + "url"); h.defaults.set(AssistantWireProtocol.anthropic.rawValue, forKey: h.byokPrefix + "protocol"); h.vm.generationConfigurationDidChange()
            _ = try await failure { _ = try await h.vm.approveTaskProposal(old, editedTask: editedTask(proposal), enableReminder: false) }
            try await expect(h.vm.canReviewTaskProposal(messageId: proposal.assistantMessageId) && !h.vm.canApproveTaskProposal(messageId: proposal.assistantMessageId), "Changing destination cannot execute old authority but must not trap an unresolved proposal")
            _ = try await h.vm.declineTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId))
            ChatFixtureURLProtocol.enqueue(.stream(taskPlainReply(.anthropic, "A safe plain-context answer")))
            h.vm.inputText = "Discuss the declined suggestion"; h.vm.sendMessage(userId: h.owner)
            try await expect(h.vm.requiresBYOKConfirmation, "A changed destination receives no private history without a fresh confirmation")
            h.vm.confirmBYOKContext(); try await finished(h.vm)
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: body(1)), as: UTF8.self)
            try await expect(encoded.contains("declined") && !encoded.contains(proposal.call.id) && !encoded.contains("opaque-task-reasoning") && !encoded.contains("function_call_output") && !encoded.contains("tool_result"),
                "An incompatible destination gets only visible proposal/outcome text, never another provider's active call, encrypted reasoning or tool result envelope")
        }
        try await run("viewmodel-task-tools-await-boundaries-recheck-approval-source-and-continued-result") {
            do {
                let h = try await ChatHarness(); defer { h.close() }
                let proposal = try await completedTaskProposal(h), source = try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId)
                let gate = ChatFixtureWorkerGate(); gate.arm(); defer { gate.open() }
                let blocked = Task { try await h.archive.background { _ in gate.wait() } }
                try await wait("real SQLite read worker held") { gate.enteredCount > 0 }
                let approving = Task { try await h.vm.approveTaskProposal(source, editedTask: editedTask(proposal), enableReminder: false) }
                try await wait("approval waiting on durable source") { h.vm.taskToolOperationMessageId == proposal.assistantMessageId }
                h.vm.messages[0].content = "Edited while the source body was being loaded"
                gate.open(); try await blocked.value
                _ = try await failure { _ = try await approving.value }
                try await expect(try h.repository.tasks(for: h.owner).isEmpty && h.repository.taskToolReceipt(proposalId: proposal.id, ownerId: h.owner) == nil,
                    "An awaited real archive read cannot commit a task after the source changes")
            }
            do {
                let controller = ChatFixtureNextStartupGate()
                let h = try await ChatHarness(startupBarrier: { await controller.wait() }); defer { h.close() }
                let proposal = try await completedTaskProposal(h)
                let saved = try await h.vm.approveTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId), editedTask: editedTask(proposal), enableReminder: false)
                let gate = ChatFixtureAsyncGate(); defer { gate.open() }; controller.holdNext(gate)
                _ = try await h.vm.continueTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId)); h.vm.confirmBYOKContext()
                try await wait("continued result queued before claim") { gate.enteredCount == 1 }
                guard let savedTask = saved.task else { throw ChatTestFailure(description: "A committed task must be available before testing a real post-prepare edit") }
                var changed = savedTask; changed.title = "Task edited after the request was prepared"; changed.updatedAt = Date()
                try await expect(h.repository.updateTask(changed, expecting: savedTask), "The real task edit must persist")
                gate.open(); try await wait("stale result rejected before HTTP") { !h.vm.isLoading }; await h.vm.waitForPendingArchiveWrites()
                try await expect(try ChatFixtureURLProtocol.captured.count == 1 && h.repository.tasks(for: h.owner).first?.title == changed.title
                    && h.repository.taskToolReceipt(proposalId: proposal.id, ownerId: h.owner)?.continuationAttemptId == nil,
                    "Final startup rechecks the real result and context before consuming a continuation attempt or sending stale success details")
            }
        }
        try await run("viewmodel-task-tools-reminder-without-reviewed-due-date-commits-nothing") {
            let h = try await ChatHarness(); defer { h.close() }
            let proposal = try await completedTaskProposal(h, arguments: taskArguments(reminderRequested: true))
            var reminderCalls = 0
            let error = try await failure {
                _ = try await h.vm.approveTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId),
                    editedTask: editedTask(proposal, reminder: true), enableReminder: true,
                    scheduleReminder: { _, _ in reminderCalls += 1 })
            }
            try await expect(try error as? AssistantTaskToolError == .invalidArguments && h.repository.tasks(for: h.owner).isEmpty
                && h.repository.taskToolReceipt(proposalId: proposal.id, ownerId: h.owner) == nil && reminderCalls == 0,
                "An enabled reminder without a user-reviewed due instant fails before task/receipt commit and never claims notification success")
        }
        try await run("viewmodel-raw-owner-alias-change-clears-ui-and-rejects-old-queued-http") {
            let ownerA = "owner-é", ownerB = "owner-e" + String(UnicodeScalar(0x301)!)
            try await expect(ownerA == ownerB && !ownerA.utf8.elementsEqual(ownerB.utf8), "The identity fixture must be canonically equal but byte-distinct")
            let gate = ChatFixtureAsyncGate(); defer { gate.open() }
            let h = try await ChatHarness(owner: ownerA, startupBarrier: { await gate.wait() })
            defer { AuthService.shared.user = ChatFixtureUser(id: ownerA); h.close() }
            try await h.configure(owner: ownerB)
            h.vm.inputText = "Queued A private prompt"; h.vm.sendMessage(userId: ownerA)
            try await wait("raw A producer queued before HTTP") { gate.enteredCount == 1 }
            let sourceConversation = h.vm.conversationId
            h.vm.inputText = "A private unsent draft"; h.vm.persistDraft(); await h.vm.waitForPendingArchiveWrites()
            AuthService.shared.applyFixtureIdentity(ChatFixtureUser(id: ownerB))
            try await expect(!h.vm.isLoading, "Raw identity notification synchronously stops the old queued producer even though Swift String equality says the owners match")
            try await wait("byte-distinct B activates") { h.vm.activeOwner.utf8.elementsEqual(ownerB.utf8) }
            try await h.vm.waitForArchiveReady(ownerId: ownerB); await h.vm.waitForPendingArchiveWrites()
            try await expect(h.vm.messages.isEmpty && h.vm.conversations.isEmpty && h.vm.inputText.isEmpty && h.vm.pendingImages.isEmpty
                && h.vm.conversationId != sourceConversation, "The raw B profile bootstraps its independent empty archive and never displays A's private UI")
            gate.open()
            try await expect(try ChatFixtureURLProtocol.captured.isEmpty && h.archive.load(userId: ownerB).isEmpty
                && h.archive.conversation(id: sourceConversation, userId: ownerA)?.messages.first?.content == "Queued A private prompt",
                "The old request starts zero HTTP while the captured departure snapshot stays confined to A's actual archive")
        }
        try await run("viewmodel-raw-owner-alias-stream-change-cancels-producer-and-isolates-b-wire") {
            let ownerA = "stream-é", ownerB = "stream-e" + String(UnicodeScalar(0x301)!)
            let h = try await ChatHarness(owner: ownerA); defer { AuthService.shared.user = ChatFixtureUser(id: ownerA); h.close() }
            try await h.configure(owner: ownerB)
            ChatFixtureURLProtocol.enqueue(.hold("A private streamed partial"))
            h.vm.inputText = "A private streamed question"; h.vm.sendMessage(userId: ownerA)
            try await wait("A native URLProtocol producer streaming") { h.vm.messages.last?.content == "A private streamed partial" }
            let oldConversation = h.vm.conversationId
            AuthService.shared.applyFixtureIdentity(ChatFixtureUser(id: ownerB))
            try await wait("raw stream owner B activated") { h.vm.activeOwner.utf8.elementsEqual(ownerB.utf8) }
            try await h.vm.waitForArchiveReady(ownerId: ownerB)
            try await wait("actual old A URLSession producer cancelled") { ChatFixtureURLProtocol.stoppedCount >= 1 }
            try await expect(h.vm.messages.isEmpty && h.vm.inputText.isEmpty, "A byte-distinct identity cannot retain canonically equivalent A's streamed contents")
            ChatFixtureURLProtocol.enqueueDelta(" forbidden late A text"); ChatFixtureURLProtocol.completeHeld()
            try await send(h, "Only B's new public question")
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: body(1)), as: UTF8.self)
            try await expect(ChatFixtureURLProtocol.captured.count == 2 && !encoded.contains("A private") && !encoded.contains("forbidden late")
                && h.vm.messages.first?.content == "Only B's new public question", "Only B's independent history reaches its real BYOK request")
            try await expect(try h.archive.conversation(id: oldConversation, userId: ownerA)?.messages.last?.status == .cancelled
                && h.archive.load(userId: ownerB).first?.messages.first?.content == "Only B's new public question", "Both actual archives retain only their raw owner's own records")
        }
        try await run("viewmodel-raw-owner-alias-cannot-read-or-replay-old-task-authority") {
            let ownerA = "task-é", ownerB = "task-e" + String(UnicodeScalar(0x301)!)
            let h = try await ChatHarness(owner: ownerA); defer { AuthService.shared.user = ChatFixtureUser(id: ownerA); h.close() }
            try await h.configure(owner: ownerB)
            let proposal = try await completedTaskProposal(h), old = try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId)
            AuthService.shared.applyFixtureIdentity(ChatFixtureUser(id: ownerB))
            try await wait("raw tool owner B activated") { h.vm.activeOwner.utf8.elementsEqual(ownerB.utf8) }
            try await h.vm.waitForArchiveReady(ownerId: ownerB)
            _ = try await failure { _ = try h.vm.taskProposalReceipt(proposal: proposal) }
            _ = try await failure { _ = try await h.vm.approveTaskProposal(old, editedTask: editedTask(proposal), enableReminder: false) }
            try await expect(h.vm.messages.isEmpty && !h.vm.canReviewTaskProposal(messageId: proposal.assistantMessageId)
                && h.repository.tasks(for: ownerA).isEmpty && h.repository.tasks(for: ownerB).isEmpty, "Canonical owner aliases cannot read a foreign tool receipt, mint its ticket or create under either profile")
            AuthService.shared.applyFixtureIdentity(ChatFixtureUser(id: ownerA))
            try await wait("raw tool A returns") { h.vm.activeOwner.utf8.elementsEqual(ownerA.utf8) }
            try await h.vm.waitForArchiveReady(ownerId: ownerA)
            _ = try await failure { _ = try await h.vm.approveTaskProposal(old, editedTask: editedTask(proposal), enableReminder: false) }
            let receipt = try await h.vm.declineTaskProposal(try h.vm.makeTaskProposalSource(messageId: proposal.assistantMessageId))
            try await expect(try receipt.decision == .declined && h.repository.taskToolReceipt(proposalId: proposal.id, ownerId: ownerB) == nil
                && ChatFixtureURLProtocol.captured.count == 1, "Returning to A requires a fresh explicit local decision; no alias profile receives its receipt or another HTTP request")
        }
        try await run("viewmodel-task-proposal-text-preserves-explicit-memory-action-without-task-bypass") {
            let h = try await ChatHarness(); defer { h.close() }
            try await enableTaskTools(h, kind: .chatCompletions)
            let prefix = taskFrame(["choices": [["index": 0, "delta": ["role": "assistant", "content": "A useful task suggestion for review."]]]])
            ChatFixtureURLProtocol.enqueue(.stream(prefix + taskStream(.chatCompletions, arguments: taskArguments())))
            h.vm.inputText = "Propose a task and explain it"; h.vm.sendMessage(userId: h.owner); try await finished(h.vm)
            guard let message = h.vm.messages.last, let proposal = message.taskProposal else { throw ChatTestFailure(description: "The genuine tool reply must also retain its natural language text") }
            try await expect(h.vm.canDeriveAction(from: message) && !h.vm.canPerformGenerationAction(from: message), "A completed tool reply keeps explicit memory/copy-related source capability while tool regeneration stays forbidden")
            let source = try h.vm.makeActionSource(messageId: message.id)
            try h.vm.saveMemoryFromMessage(actionMemory(owner: h.owner, text: "User-confirmed review preference"), source: source)
            try await expect(try h.repository.memories(for: h.owner).count == 1 && h.repository.tasks(for: h.owner).isEmpty
                && h.repository.taskToolReceipt(proposalId: proposal.id, ownerId: h.owner) == nil && ChatFixtureURLProtocol.captured.count == 1,
                "An explicit memory confirmation remains real local memory storage and does not approve or execute the pending task proposal")
        }
        guard failures.isEmpty else { throw ChatTestFailure(description: failures.joined(separator: "; ")) }
        print("All \(suites) actual ChatViewModel integration suites passed; test-only identity/keychain shell and mocked networking, no real model or platform calls.")
    }
}
