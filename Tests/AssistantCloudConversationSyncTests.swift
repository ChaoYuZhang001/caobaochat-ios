import Foundation

enum APIConfig { static let assistantBaseURL = URL(string: "https://conversation.fixture.invalid/api/v2")! }

final class CloudConversationFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Plan { let status: Int; let body: Data }
    private static let lock = NSLock(); private static var plans: [Plan] = []; private static var requests: [URLRequest] = []
    static var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    static func reset(_ plans: [Plan]) { lock.lock(); self.plans = plans; requests = []; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let plan = Self.plans.removeFirst(); Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: plan.body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private enum ConversationSyncTestFailure: Error { case failed(String) }

@main
struct AssistantCloudConversationSyncTests {
    private static func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    private static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw ConversationSyncTestFailure.failed(message) } }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-sync-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "conversation-sync-defaults-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = AssistantChatArchive(directory: root); try archive.prepare(userId: "owner")
        let pending = ChatMessage(id: "pending", role: .assistant, content: "partial", timestamp: date("2026-10-30T00:00:00Z"), status: .pending, requestId: "request-pending")
        let local = Conversation(id: "local", title: "Local", preview: "partial", date: pending.timestamp, messages: [pending], serverConversationId: "cnv_1")
        try archive.upsert(local, userId: "owner")
        let deleted = Conversation(id: "deleted-local", title: "Deleted", preview: "", date: pending.timestamp, messages: [], serverConversationId: nil)
        try archive.upsert(deleted, userId: "owner"); try archive.delete(ids: [deleted.id], userId: "owner")

        CloudConversationFixtureURLProtocol.reset([
            .init(status: 200, body: json(["items":[["seq":1,"event":"upsert","id":"cnv_1","clientConversationId":"remote-1","title":"Remote","locale":"en-US","status":"active","updatedAt":"2026-10-30T00:00:01Z"],["seq":2,"event":"upsert","id":"cnv_2","clientConversationId":"remote-new","title":"New remote","locale":"en-US","status":"active","updatedAt":"2026-10-30T00:00:01Z"],["seq":3,"event":"delete","id":"cnv_3","clientConversationId":"deleted-local","title":"Should stay deleted","locale":"en-US","status":"deleted","updatedAt":"2026-10-30T00:00:01Z"]],"nextCursor":3,"headSeq":3,"resyncRequired":false])),
            .init(status: 200, body: json(["items":[["id":"msg_1","conversationId":"cnv_1","clientMessageId":"user-1","role":"user","content":[["type":"text","text":"from cloud"]],"status":"completed","createdAt":"2026-10-30T00:00:02Z"],["id":"msg_2","conversationId":"cnv_1","clientMessageId":"server-assistant","requestId":"request-pending","role":"assistant","content":[["type":"text","text":"server replacement"]],"status":"completed","createdAt":"2026-10-30T00:00:03Z"]]])),
            .init(status: 200, body: json(["items":[["id":"msg_3","conversationId":"cnv_2","clientMessageId":"new-user","role":"user","content":[["type":"image","text":"must not be imported"],["type":"text","text":"new remote history"]],"status":"completed","createdAt":"2026-10-30T00:00:02Z"]]])),
            .init(status: 200, body: json(["items":[]])),
            .init(status: 200, body: json(["items":[]]))
        ])
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CloudConversationFixtureURLProtocol.self]
        let sync = AssistantCloudConversationSync(baseURL: APIConfig.assistantBaseURL, sessionConfiguration: configuration, defaults: defaults)
        try await sync.sync(ownerId: "owner", token: "fixture-token", archive: archive)
        let values = try archive.load(userId: "owner")
        let merged = values.first { $0.id == "local" }
        let remoteNew = values.first { $0.id == "remote-new" }
        try expect(merged?.serverConversationId == "cnv_1", "server mapping was not retained")
        try expect(merged?.messages.count == 2, "missing cloud message was not imported")
        try expect(merged?.messages.contains(where: { $0.id == "pending" && $0.status == .pending }) == true, "local pending message was overwritten")
        try expect(remoteNew?.serverConversationId == "cnv_2", "new remote conversation was not inserted")
        try expect(remoteNew?.messages.contains(where: { $0.content == "new remote history" }) == true, "new remote conversation message was not imported")
        try expect(remoteNew?.messages.contains(where: { $0.content.contains("must not be imported") }) == false, "non-text content leaked into history")
        try expect(!values.contains(where: { $0.id == "deleted-local" }), "server pull resurrected a local tombstone")
        try expect(CloudConversationFixtureURLProtocol.captured.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token" }, "missing bearer authorization")
        try expect(CloudConversationFixtureURLProtocol.captured.count == 3, "change feed did not fetch the expected pages")

        CloudConversationFixtureURLProtocol.reset([
            .init(status: 200, body: json(["items":[],"nextCursor":3,"headSeq":3,"resyncRequired":false]))
        ])
        try await sync.sync(ownerId: "owner", token: "fixture-token", archive: archive)
        try expect(CloudConversationFixtureURLProtocol.captured.count == 1, "persisted cursor did not avoid a full replay")

        CloudConversationFixtureURLProtocol.reset([
            .init(status: 200, body: json(["items":[],"nextCursor":2,"headSeq":3,"resyncRequired":false]))
        ])
        do {
            try await sync.sync(ownerId: "owner", token: "fixture-token", archive: archive)
            throw ConversationSyncTestFailure.failed("backward cursor was accepted")
        } catch AssistantCloudConversationSyncError.invalidResponse {
            // Expected: a malformed cursor cannot advance or rewind local state.
        }

        CloudConversationFixtureURLProtocol.reset([
            .init(status: 200, body: json(["status": "deleted"]))
        ])
        try await sync.deleteConversation(id: "cnv_9", token: "fixture-token")
        try expect(CloudConversationFixtureURLProtocol.captured.first?.httpMethod == "DELETE", "conversation delete did not use DELETE")
        try expect(CloudConversationFixtureURLProtocol.captured.first?.url?.path.hasSuffix("/conversations/cnv_9") == true, "conversation delete path was not encoded safely")
        try expect(CloudConversationFixtureURLProtocol.captured.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token", "conversation delete lost bearer authorization")
        print("All conversation cloud sync suites passed")
    }
}
