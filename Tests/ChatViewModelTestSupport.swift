import Foundation

// Test-only replacements for the iOS identity/preferences/keychain shell.
// The production view model, transport, archive, media and repository compile unchanged.
struct UserSettings: Codable { var toxicLevel: String = "normal" }
struct ChatFixtureUser { let id: String }
@MainActor final class ChatFixtureAsyncGate {
    private var isOpen = false
    private(set) var enteredCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        enteredCount += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters; waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
@MainActor final class ChatFixtureNextStartupGate {
    private var next: ChatFixtureAsyncGate?
    func holdNext(_ gate: ChatFixtureAsyncGate) { next = gate }
    func wait() async {
        guard let gate = next else { return }
        next = nil
        await gate.wait()
    }
}
@MainActor final class AuthService {
    static let shared = AuthService()
    var user: ChatFixtureUser?
    var token: String?
    private var nextAccessTokenGate: ChatFixtureAsyncGate?
    private(set) var accessTokenRequests = 0
    func holdNextAccessToken(_ gate: ChatFixtureAsyncGate) { nextAccessTokenGate = gate }
    /// Test-only equivalent of accepting a raw identity change and publishing login/logout.
    /// Direct user assignments remain notification-free for existing final-hook fixtures.
    func applyFixtureIdentity(_ next: ChatFixtureUser?) {
        let changed: Bool
        switch (user?.id, next?.id) {
        case (nil, nil): changed = false
        case (.some(let old), .some(let new)): changed = !old.utf8.elementsEqual(new.utf8)
        default: changed = true
        }
        user = next
        if changed { NotificationCenter.default.post(name: next == nil ? .logoutSuccess : .loginSuccess, object: nil) }
    }

    func validAccessToken() async throws -> String {
        accessTokenRequests += 1
        if let gate = nextAccessTokenGate { nextAccessTokenGate = nil; await gate.wait() }
        guard let token else { throw URLError(.userAuthenticationRequired) }
        return token
    }
}
enum APIConfig {
    static let assistantBaseURL = URL(string: "https://platform.fixtures.invalid/api/v2")!
}
enum KeychainStore {
    private static let lock = NSLock()
    private static var values: [String: String] = [:]
    static func read(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }; return values[account]
    }
    static func set(_ value: String, account: String) {
        lock.lock(); defer { lock.unlock() }; values[account] = value
    }
}
extension Notification.Name {
    static let loginSuccess = Self("chat-test-login")
    static let logoutSuccess = Self("chat-test-logout")
    static let conversationHistoryChanged = Self("chat-test-history")
}

/// Fails a selected real archive write before directory creation; successful
/// earlier calls still use the production atomic file-writing implementation.
final class ChatFixtureArchiveFileManager: FileManager, @unchecked Sendable {
    private let failureLock = NSLock()
    private var remainingSuccessfulCalls: Int?
    func failAfterDirectoryCreations(_ count: Int?) {
        failureLock.lock(); remainingSuccessfulCalls = count; failureLock.unlock()
    }
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        failureLock.lock()
        if let remaining = remainingSuccessfulCalls {
            if remaining <= 0 { failureLock.unlock(); throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
            remainingSuccessfulCalls = remaining - 1
        }
        failureLock.unlock()
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

/// Verifies failed/lying insert implementations cannot be presented as saved.
final class ChatFixtureMemoryRepository: AssistantLocalRepositoryProtocol {
    let base: AssistantLocalRepository
    var insertionResult = false
    private(set) var insertAttempts = 0
    private(set) var legacyAddAttempts = 0
    init(base: AssistantLocalRepository) { self.base = base }
    func memories(for userId: String) -> [AssistantMemory] { base.memories(for: userId) }
    func insertMemory(_ memory: AssistantMemory) -> Bool { insertAttempts += 1; return insertionResult }
    func addMemory(_ memory: AssistantMemory) { legacyAddAttempts += 1; base.addMemory(memory) }
    func updateMemory(_ memory: AssistantMemory) -> Bool { base.updateMemory(memory) }
    func deleteMemory(id: String, userId: String) -> Bool { base.deleteMemory(id: id, userId: userId) }
    func setMemoryEnabled(_ enabled: Bool, for userId: String) { base.setMemoryEnabled(enabled, for: userId) }
    func isMemoryEnabled(for userId: String) -> Bool { base.isMemoryEnabled(for: userId) }
    func tasks(for userId: String) -> [AssistantTask] { base.tasks(for: userId) }
    func addTask(_ task: AssistantTask) { base.addTask(task) }
    func updateTask(_ task: AssistantTask) -> Bool { base.updateTask(task) }
    func updateTaskStatus(id: String, userId: String, status: AssistantTaskStatus) -> Bool { base.updateTaskStatus(id: id, userId: userId, status: status) }
    func deleteTask(id: String, userId: String) -> Bool { base.deleteTask(id: id, userId: userId) }
}

final class ChatFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    enum Plan { case complete(String), hold(String), conversation(String), holdConversation, httpError, stream(String), holdStream(String) }
    private static let lock = NSLock()
    private static var plans: [Plan] = []
    private static var requests: [URLRequest] = []
    private static var instances: [ChatFixtureURLProtocol] = []
    private let instanceLock = NSLock()
    private var stopped = false
    private var finished = false

    static func reset(plans: [Plan] = []) {
        lock.lock(); defer { lock.unlock() }
        self.plans = plans; requests = []; instances = []
    }
    static func enqueue(_ plan: Plan) { lock.lock(); defer { lock.unlock() }; plans.append(plan) }
    static var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static var stoppedCount: Int {
        lock.lock(); let values = instances; lock.unlock()
        return values.filter { $0.hasStopped }.count
    }
    private var hasStopped: Bool { instanceLock.lock(); defer { instanceLock.unlock() }; return stopped }
    static func enqueueDelta(_ text: String, requestIndex: Int = 0) {
        lock.lock(); let target = instances.indices.contains(requestIndex) ? instances[requestIndex] : nil; lock.unlock()
        target?.send(delta(text))
    }
    static func enqueueFrames(_ frames: String, requestIndex: Int = 0) {
        lock.lock(); let target = instances.indices.contains(requestIndex) ? instances[requestIndex] : nil; lock.unlock()
        target?.send(frames)
    }
    static func finishHeld(requestIndex: Int = 0) {
        lock.lock(); let target = instances.indices.contains(requestIndex) ? instances[requestIndex] : nil; lock.unlock()
        target?.finish()
    }
    static func completeHeld(requestIndex: Int = 0) {
        lock.lock(); let target = instances.indices.contains(requestIndex) ? instances[requestIndex] : nil; lock.unlock()
        target?.send("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n")
        target?.finish()
    }
    static func completeHeldConversation(id: String, requestIndex: Int = 0) {
        lock.lock(); let target = instances.indices.contains(requestIndex) ? instances[requestIndex] : nil; lock.unlock()
        // The holdConversation fixture already emitted the opening object brace.
        let encoded = try! JSONSerialization.data(withJSONObject: ["id": id])
        target?.send(String(decoding: encoded.dropFirst(), as: UTF8.self))
        target?.finish()
    }
    static func failHeld(requestIndex: Int = 0) {
        lock.lock(); let target = instances.indices.contains(requestIndex) ? instances[requestIndex] : nil; lock.unlock()
        target?.fail()
    }
    private static func delta(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": text]]]])
        return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request); Self.instances.append(self)
        let plan = Self.plans.isEmpty ? Plan.complete("fixture answer") : Self.plans.removeFirst()
        Self.lock.unlock()
        let status: Int, mime: String
        switch plan {
        case .httpError: status = 503; mime = "text/event-stream"
        case .conversation, .holdConversation: status = 201; mime = "application/json"
        default: status = 200; mime = "text/event-stream"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        switch plan {
        case .hold(let text): send(Self.delta(text))
        case .stream(let frames): send(frames); finish()
        case .holdStream(let frames): send(frames)
        case .conversation(let id):
            send(String(decoding: try! JSONSerialization.data(withJSONObject: ["id": id]), as: UTF8.self)); finish()
        case .holdConversation: send("{")
        case .complete(let text):
            send("data: {\"type\":\"metadata\",\"generationId\":\"fixture-generation\"}\n\n" + Self.delta(text)
                + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":17,\"completion_tokens\":5}}\n\n"
                + "data: [DONE]\n\n")
            finish()
        case .httpError: send("private upstream detail"); finish()
        }
    }
    private func send(_ value: String) {
        instanceLock.lock(); defer { instanceLock.unlock() }
        guard !stopped, !finished else { return }
        client?.urlProtocol(self, didLoad: Data(value.utf8))
    }
    private func finish() {
        instanceLock.lock(); defer { instanceLock.unlock() }
        guard !stopped, !finished else { return }
        finished = true; client?.urlProtocolDidFinishLoading(self)
    }
    private func fail() {
        instanceLock.lock()
        guard !stopped, !finished else { instanceLock.unlock(); return }
        finished = true; instanceLock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }
    override func stopLoading() {
        instanceLock.lock(); defer { instanceLock.unlock() }; stopped = true
    }
}

/// Injects faults at the production SQLite boundaries, never by replacing storage.
final class ChatFixtureArchiveFault: @unchecked Sendable {
    private let lock = NSLock()
    private var selected: AssistantArchiveFaultPoint?
    private var remaining = 0
    func arm(_ point: AssistantArchiveFaultPoint?, after successfulMatches: Int = 0) {
        lock.lock(); selected = point; remaining = successfulMatches; lock.unlock()
    }
    func check(_ point: AssistantArchiveFaultPoint, owner: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard selected == point else { return }
        if remaining > 0 { remaining -= 1; return }
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }
}

/// Blocks only the background SQLite worker; MainActor remains free to invalidate it.
final class ChatFixtureWorkerGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var opened = false
    private var entries = 0
    var enteredCount: Int { condition.lock(); defer { condition.unlock() }; return entries }
    func arm() { condition.lock(); armed = true; opened = false; condition.unlock() }
    func wait() {
        condition.lock(); defer { condition.unlock() }
        guard armed else { return }
        entries += 1
        while !opened { condition.wait() }
    }
    func open() { condition.lock(); opened = true; armed = false; condition.broadcast(); condition.unlock() }
}
