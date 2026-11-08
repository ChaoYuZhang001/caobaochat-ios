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

        // A legacy server can force a full snapshot. The client processes a
        // bounded batch and persists the remaining page cursor, so a retry
        // continues from the pending page instead of silently dropping the
        // 201st conversation.
        var bulkPlans: [CloudConversationFixtureURLProtocol.Plan] = [
            .init(status: 200, body: json(["items": [], "nextCursor": 0, "headSeq": 0, "resyncRequired": true]))
        ]
        for pageIndex in 0..<5 {
            let start = pageIndex * 50 + 1
            let end = min(start + 49, 201)
            var items: [[String: Any]] = []
            for number in start...end {
                items.append(["id": "cnv_\(10_000 + number)",
                              "clientConversationId": "bulk-\(number)",
                              "title": "Bulk \(number)", "locale": "en-US", "status": "active",
                              "createdAt": "2026-10-30T00:00:01Z", "updatedAt": "2026-10-30T00:00:01Z"])
            }
            var page: [String: Any] = ["items": items]
            if end < 201 { page["nextCursor"] = String(end) }
            bulkPlans.append(.init(status: 200, body: json(page)))
            for _ in items {
                bulkPlans.append(.init(status: 200, body: json(["items": []])))
            }
        }
        CloudConversationFixtureURLProtocol.reset(bulkPlans)
        try await sync.sync(ownerId: "owner", token: "fixture-token", archive: archive)
        let firstBulkPassRequests = CloudConversationFixtureURLProtocol.captured.count
        try expect(firstBulkPassRequests == 205, "snapshot did not stop at the bounded 200-conversation batch")
        let resumeConversation: [String: Any] = ["id": "cnv_10201",
                                                   "clientConversationId": "bulk-201",
                                                   "title": "Bulk 201", "locale": "en-US", "status": "active",
                                                   "createdAt": "2026-10-30T00:00:01Z", "updatedAt": "2026-10-30T00:00:01Z"]
        CloudConversationFixtureURLProtocol.reset([
            .init(status: 200, body: json(["items": [resumeConversation]])),
            .init(status: 200, body: json(["items": []]))
        ])
        try await sync.sync(ownerId: "owner", token: "fixture-token", archive: archive)
        try expect(CloudConversationFixtureURLProtocol.captured.count == 2, "snapshot cursor did not resume the pending page")
        let completedBulk = try archive.load(userId: "owner").filter { $0.id.hasPrefix("bulk-") }
        try expect(completedBulk.count == 201, "resumable snapshot did not import every conversation")

        // An oversized incremental change must fall back to a snapshot and
        // only advance the change cursor after that snapshot completes.
        let overflowRoot = root.appendingPathComponent("incremental-overflow", isDirectory: true)
        let overflowArchive = AssistantChatArchive(directory: overflowRoot)
        try overflowArchive.prepare(userId: "overflow-owner")
        let overflowSuite = "conversation-sync-overflow-" + UUID().uuidString
        let overflowDefaults = UserDefaults(suiteName: overflowSuite)!
        let overflowSync = AssistantCloudConversationSync(baseURL: APIConfig.assistantBaseURL,
                                                           sessionConfiguration: configuration,
                                                           defaults: overflowDefaults)
        let overflowConversation: [String: Any] = ["id": "cnv_15001",
                                                      "clientConversationId": "overflow-conversation",
                                                      "title": "Overflow", "locale": "en-US", "status": "active",
                                                      "createdAt": "2026-10-30T00:00:01Z", "updatedAt": "2026-10-30T00:00:01Z"]
        var overflowPlans: [CloudConversationFixtureURLProtocol.Plan] = [
            .init(status: 200, body: json(["items": [["seq": 1, "event": "upsert", "id": "cnv_15001",
                                                       "clientConversationId": "overflow-conversation", "title": "Overflow",
                                                       "locale": "en-US", "status": "active", "updatedAt": "2026-10-30T00:00:01Z"]],
                                           "nextCursor": 1, "headSeq": 1, "resyncRequired": false]))
        ]
        for page in 1...5 {
            overflowPlans.append(.init(status: 200, body: json(["items": [["id": "inc-\(page)",
                                                                                  "conversationId": "cnv_15001",
                                                                                  "clientMessageId": "inc-\(page)",
                                                                                  "role": "assistant", "content": [["type": "text", "text": "incremental \(page)"]],
                                                                                  "status": "completed", "createdAt": "2026-10-30T00:00:0\(page)Z"]],
                                                               "nextCursor": String(page)])))
        }
        overflowPlans.append(.init(status: 200, body: json(["items": [overflowConversation]])))
        for page in 1...5 {
            overflowPlans.append(.init(status: 200, body: json(["items": [["id": "snap-\(page)",
                                                                                  "conversationId": "cnv_15001",
                                                                                  "clientMessageId": "snap-\(page)",
                                                                                  "role": "assistant", "content": [["type": "text", "text": "snapshot \(page)"]],
                                                                                  "status": "completed", "createdAt": "2026-10-30T00:00:1\(page)Z"]],
                                                               "nextCursor": String(page)])))
        }
        CloudConversationFixtureURLProtocol.reset(overflowPlans)
        try await overflowSync.sync(ownerId: "overflow-owner", token: "fixture-token", archive: overflowArchive)
        try expect(CloudConversationFixtureURLProtocol.captured.count == 12, "oversized incremental history did not fall back to a snapshot")
        CloudConversationFixtureURLProtocol.reset([
            .init(status: 200, body: json(["items": [["id": "snap-6", "conversationId": "cnv_15001",
                                                        "clientMessageId": "snap-6", "role": "assistant",
                                                        "content": [["type": "text", "text": "snapshot 6"]],
                                                        "status": "completed", "createdAt": "2026-10-30T00:00:16Z"]]]))
        ])
        try await overflowSync.sync(ownerId: "overflow-owner", token: "fixture-token", archive: overflowArchive)
        let overflowValues = try overflowArchive.load(userId: "overflow-owner")
        try expect(overflowValues.first(where: { $0.id == "overflow-conversation" })?.messages.count == 6,
                   "snapshot did not finish after oversized incremental history")
        CloudConversationFixtureURLProtocol.reset([
            .init(status: 200, body: json(["items": [], "nextCursor": 1, "headSeq": 1, "resyncRequired": false]))
        ])
        try await overflowSync.sync(ownerId: "overflow-owner", token: "fixture-token", archive: overflowArchive)
        try expect(CloudConversationFixtureURLProtocol.captured.count == 1, "snapshot completion did not advance the change cursor")
        overflowDefaults.removePersistentDomain(forName: overflowSuite)

        // Five message pages are the per-request safety budget. With the
        // production page size of 200, page 6 represents a conversation over
        // 1,000 messages and must resume from messageCursor on the next sync.
        var longPlans: [CloudConversationFixtureURLProtocol.Plan] = [
            .init(status: 200, body: json(["items": [], "nextCursor": 0, "headSeq": 0, "resyncRequired": true]))
        ]
        let longConversation: [String: Any] = ["id": "cnv_20001",
                                                "clientConversationId": "long-history",
                                                "title": "Long history", "locale": "en-US", "status": "active",
                                                "createdAt": "2026-10-30T00:00:01Z", "updatedAt": "2026-10-30T00:00:01Z"]
        longPlans.append(.init(status: 200, body: json(["items": [longConversation]])))
        for page in 1...6 {
            var pageItems: [[String: Any]] = []
            for item in 1...(page == 6 ? 1 : 200) {
                let sequence = (page - 1) * 200 + item
                pageItems.append(["id": "msg-long-\(sequence)",
                                  "conversationId": "cnv_20001", "clientMessageId": "long-\(sequence)",
                                  "role": "assistant", "content": [["type": "text", "text": "message \(sequence)" ]],
                                  "status": "completed", "createdAt": "2026-10-30T00:00:\(String(format: "%02d", min(item, 59)))Z"])
            }
            var pageBody: [String: Any] = ["items": pageItems]
            if page < 6 { pageBody["nextCursor"] = String(page) }
            longPlans.append(.init(status: 200, body: json(pageBody)))
        }
        CloudConversationFixtureURLProtocol.reset(longPlans)
        try await sync.sync(ownerId: "owner", token: "fixture-token", archive: archive)
        try expect(CloudConversationFixtureURLProtocol.captured.count == 7, "message page budget did not persist the pending cursor")
        CloudConversationFixtureURLProtocol.reset([
            .init(status: 200, body: json(["items": [["id": "msg-long-1001", "conversationId": "cnv_20001",
                                                        "clientMessageId": "long-1001", "role": "assistant",
                                                        "content": [["type": "text", "text": "message 1001"]],
                                                        "status": "completed", "createdAt": "2026-10-30T00:00:01Z"]]]))
        ])
        try await sync.sync(ownerId: "owner", token: "fixture-token", archive: archive)
        try expect(CloudConversationFixtureURLProtocol.captured.count == 1, "message cursor did not resume the final page")
        let longHistory = try archive.load(userId: "owner").first { $0.id == "long-history" }
        try expect(longHistory?.messages.count == 1001, "resumed message pages were not merged completely")

        // A transient failure after the snapshot page is accepted must retain
        // the active conversation cursor so the next sync resumes safely.
        let retryRoot = root.appendingPathComponent("retry", isDirectory: true)
        let retryArchive = AssistantChatArchive(directory: retryRoot)
        try retryArchive.prepare(userId: "retry-owner")
        let retrySuite = "conversation-sync-retry-" + UUID().uuidString
        let retryDefaults = UserDefaults(suiteName: retrySuite)!
        let retrySync = AssistantCloudConversationSync(baseURL: APIConfig.assistantBaseURL,
                                                        sessionConfiguration: configuration,
                                                        defaults: retryDefaults)
        let retryConversation: [String: Any] = ["id": "cnv_30001",
                                                   "clientConversationId": "retry-conversation",
                                                   "title": "Retry", "locale": "en-US", "status": "active",
                                                   "createdAt": "2026-10-30T00:00:01Z", "updatedAt": "2026-10-30T00:00:01Z"]
        CloudConversationFixtureURLProtocol.reset([
            .init(status: 200, body: json(["items": [], "nextCursor": 0, "headSeq": 0, "resyncRequired": true])),
            .init(status: 200, body: json(["items": [retryConversation]])),
            .init(status: 503, body: Data())
        ])
        do {
            try await retrySync.sync(ownerId: "retry-owner", token: "fixture-token", archive: retryArchive)
            throw ConversationSyncTestFailure.failed("transient snapshot failure was swallowed")
        } catch AssistantCloudConversationSyncError.httpStatus(503) {
            // Expected: the owner-scoped snapshot state is persisted before rethrow.
        }
        CloudConversationFixtureURLProtocol.reset([
            .init(status: 200, body: json(["items": []]))
        ])
        try await retrySync.sync(ownerId: "retry-owner", token: "fixture-token", archive: retryArchive)
        let retryValues = try retryArchive.load(userId: "retry-owner")
        try expect(retryValues.contains(where: { $0.id == "retry-conversation" }), "snapshot state was not resumable after transient failure")
        retryDefaults.removePersistentDomain(forName: retrySuite)
        print("All conversation cloud sync suites passed")
    }
}
