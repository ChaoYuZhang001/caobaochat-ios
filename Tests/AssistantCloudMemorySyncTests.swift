import Foundation

enum APIConfig {
    static let assistantBaseURL = URL(string: "https://cloud-memory.fixture.invalid/api/v2")!
}

final class CloudMemoryFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct ResponsePlan {
        let status: Int
        let body: Data
    }

    private static let lock = NSLock()
    private static var plans: [ResponsePlan] = []
    private static var requests: [URLRequest] = []
    private static var bodies: [Data?] = []

    static var captured: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    static var capturedBodies: [Data?] {
        lock.lock(); defer { lock.unlock() }
        return bodies
    }

    static func reset(_ plans: [ResponsePlan]) {
        lock.lock(); defer { lock.unlock() }
        self.plans = plans
        requests = []
        bodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        if let body = request.httpBody {
            Self.bodies.append(body)
        } else if let stream = request.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
            Self.bodies.append(body)
        } else {
            Self.bodies.append(nil)
        }
        let plan = Self.plans.removeFirst()
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: plan.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: plan.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private struct AssistantCloudMemorySyncTests {
    private let owner = "cloud-owner"
    private let token = "fixture-token"

    private func makeRepository(_ name: String) -> (AssistantLocalRepository, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("caobao-cloud-sync-\(name)-\(UUID().uuidString).json")
        return (AssistantLocalRepository(fileURL: url), url)
    }

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "cloud-memory-sync-\(name)-\(UUID().uuidString)"
        let value = UserDefaults(suiteName: suite)!
        value.removePersistentDomain(forName: suite)
        return value
    }

    private func memory(id: String, text: String, date: Date = Date(timeIntervalSince1970: 1_000), status: AssistantMemoryStatus = .active) -> AssistantMemory {
        AssistantMemory(id: id, userId: owner, category: .fact, text: text,
            sourceMessageId: nil, consent: "explicit", status: status,
            createdAt: date, updatedAt: date)
    }

    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }

    func pullAppliesActiveRowsAndTombstones() async throws {
        let (repository, url) = makeRepository("pull")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = repository.insertMemory(memory(id: "m-deleted", text: "old"))
        let timestamp = "2026-10-30T00:00:00Z"
        CloudMemoryFixtureURLProtocol.reset([.init(status: 200, body: json([
            "memories": [
                ["id": "m-active", "category": "fact", "text": "from cloud", "consent": "explicit", "status": "active", "version": 3, "seq": 7, "updatedAt": timestamp],
                ["id": "m-deleted", "category": "fact", "consent": "explicit", "status": "deleted", "version": 4, "seq": 8, "updatedAt": timestamp]
            ], "nextCursor": 8, "headSeq": 8, "resyncRequired": false
        ]))])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudMemoryFixtureURLProtocol.self]
        let client = AssistantCloudMemorySyncClient(baseURL: APIConfig.assistantBaseURL, sessionConfiguration: configuration)
        try await client.syncFromCloud(ownerId: owner, token: token, repository: repository, defaults: defaults("pull"))
        let records = repository.memoryRecords(for: owner)
        guard records.contains(where: { $0.id == "m-active" && $0.text == "from cloud" && $0.status == .active }) else { throw TestFailure("active row was not applied") }
        guard records.contains(where: { $0.id == "m-deleted" && $0.status == .deleted && $0.text.isEmpty }) else { throw TestFailure("tombstone was not applied") }
        guard CloudMemoryFixtureURLProtocol.captured.count == 1 else { throw TestFailure("pull did not advance cursor") }
        guard CloudMemoryFixtureURLProtocol.captured[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" else { throw TestFailure("missing bearer authorization") }
    }

    func pushUsesExpectedVersionAndPullsServerVersion() async throws {
        let (repository, url) = makeRepository("push")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = repository.insertMemory(memory(id: "m-new", text: "local"))
        let timestamp = "2026-10-30T00:00:00Z"
        let empty = json(["memories": [], "nextCursor": 0, "headSeq": 0, "resyncRequired": false])
        let saved = json(["id": "m-new", "category": "fact", "text": "local", "consent": "explicit", "status": "active", "version": 1, "seq": 1, "updatedAt": timestamp])
        let finalPull = json(["memories": [["id": "m-new", "category": "fact", "text": "local", "consent": "explicit", "status": "active", "version": 1, "seq": 1, "updatedAt": timestamp]], "nextCursor": 1, "headSeq": 1, "resyncRequired": false])
        CloudMemoryFixtureURLProtocol.reset([
            .init(status: 200, body: empty),
            .init(status: 200, body: json(["items": []])),
            .init(status: 200, body: saved),
            .init(status: 200, body: finalPull)
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudMemoryFixtureURLProtocol.self]
        let client = AssistantCloudMemorySyncClient(baseURL: APIConfig.assistantBaseURL, sessionConfiguration: configuration)
        try await client.syncToCloud(ownerId: owner, token: token, repository: repository, defaults: defaults("push"))
        let requests = CloudMemoryFixtureURLProtocol.captured
        guard requests.map({ $0.httpMethod ?? "" }) == ["GET", "GET", "POST", "GET"] else { throw TestFailure("unexpected push request order") }
        guard let body = CloudMemoryFixtureURLProtocol.capturedBodies[2],
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              (object["expectedVersion"] as? NSNumber)?.int64Value == 0 else {
            let bodyText = requests[2].httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "<nil>"
            throw TestFailure("create did not use expectedVersion 0: \(bodyText)")
        }
        guard repository.memories(for: owner).first(where: { $0.id == "m-new" })?.text == "local" else { throw TestFailure("local record changed unexpectedly") }
    }

    func dirtyLocalRecordIsPreservedAndConflicts() async throws {
        let (repository, url) = makeRepository("dirty")
        defer { try? FileManager.default.removeItem(at: url) }
        let base = "2020-01-01T00:00:00Z"
        let initial = json(["memories": [["id": "m-dirty", "category": "fact", "text": "server base", "consent": "explicit", "status": "active", "version": 1, "seq": 1, "updatedAt": base]], "nextCursor": 1, "headSeq": 1, "resyncRequired": false])
        CloudMemoryFixtureURLProtocol.reset([.init(status: 200, body: initial)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudMemoryFixtureURLProtocol.self]
        let client = AssistantCloudMemorySyncClient(baseURL: APIConfig.assistantBaseURL, sessionConfiguration: configuration)
        let suiteDefaults = defaults("dirty")
        try await client.syncFromCloud(ownerId: owner, token: token, repository: repository, defaults: suiteDefaults)
        guard let current = repository.memories(for: owner).first else { throw TestFailure("initial server row missing") }
        var edited = current
        edited.text = "local edit"
        guard repository.updateMemory(edited) else { throw TestFailure("local edit was not saved") }

        let deleted = json(["memories": [["id": "m-dirty", "category": "fact", "consent": "disabled", "status": "deleted", "version": 2, "seq": 2, "updatedAt": "2026-10-30T00:00:00Z"]], "nextCursor": 2, "headSeq": 2, "resyncRequired": false])
        CloudMemoryFixtureURLProtocol.reset([.init(status: 200, body: deleted)])
        try await client.syncFromCloud(ownerId: owner, token: token, repository: repository, defaults: suiteDefaults)
        guard repository.memories(for: owner).first(where: { $0.id == "m-dirty" })?.text == "local edit" else {
            throw TestFailure("dirty local edit was overwritten by a remote tombstone")
        }

        CloudMemoryFixtureURLProtocol.reset([
            .init(status: 200, body: json(["memories": [], "nextCursor": 2, "headSeq": 2, "resyncRequired": false])),
            .init(status: 200, body: json(["items": []])),
            .init(status: 409, body: Data("{}".utf8))
        ])
        do {
            try await client.syncToCloud(ownerId: owner, token: token, repository: repository, defaults: suiteDefaults)
            throw TestFailure("dirty local edit unexpectedly succeeded after server tombstone")
        } catch let error as AssistantCloudMemorySyncError {
            guard error == .conflict else { throw TestFailure("unexpected dirty conflict: \(error)") }
        }
        guard let body = CloudMemoryFixtureURLProtocol.capturedBodies.last.flatMap({ $0 }),
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              (object["expectedVersion"] as? NSNumber)?.int64Value == 2 else {
            throw TestFailure("dirty edit did not carry the server version into the conflict")
        }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

@main
struct AssistantCloudMemorySyncTestRunner {
    static func main() async {
        let tests = AssistantCloudMemorySyncTests()
        let cases: [(String, () async throws -> Void)] = [
            ("pull-applies-active-and-tombstone", { try await tests.pullAppliesActiveRowsAndTombstones() }),
            ("push-uses-expected-version-and-pulls", { try await tests.pushUsesExpectedVersionAndPullsServerVersion() }),
            ("dirty-local-record-is-preserved-and-conflicts", { try await tests.dirtyLocalRecordIsPreservedAndConflicts() })
        ]
        do {
            for (name, test) in cases {
                print("RUN \(name)")
                try await test()
                print("PASS \(name)")
            }
            print("All \(cases.count) AssistantCloudMemorySync suites passed")
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }
}
