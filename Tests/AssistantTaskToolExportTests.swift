import Foundation

private struct TaskToolExportFailure: Error, CustomStringConvertible { let description: String }
@main @MainActor private enum AssistantTaskToolExportTests {
    static var suites = 0
    static var failures: [String] = []
    nonisolated static let date = Date(timeIntervalSince1970: 1_793_232_000.125)
    struct Payload: Decodable {
        let schemaName: String
        let schemaVersion: Int
        let ownerId: String
        let includedScopes: [String]
        let conversations: [Conversation]
        let tasks: [AssistantTask]
        let taskToolReceipts: [AssistantTaskToolReceipt]
    }
    @MainActor struct Fixture {
        let root: URL
        let repositoryURL: URL
        let archive: AssistantChatArchive
        let repository: AssistantLocalRepository
        init(_ root: URL) throws {
            self.root = root; repositoryURL = root.appendingPathComponent("repository.json")
            archive = AssistantChatArchive(directory: root.appendingPathComponent("archive", isDirectory: true))
            repository = AssistantLocalRepository(fileURL: repositoryURL)
            for owner in ["A", "B", "C"] { try archive.prepare(userId: owner) }
        }
        var exporter: AssistantDataExporter { AssistantDataExporter(archive: archive, repository: repository) }
        var executor: AssistantTaskToolExecutionCoordinator { AssistantTaskToolExecutionCoordinator(repository: repository) }
    }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw TaskToolExportFailure(description: message) } }
    static func rejected(_ expected: AssistantDataExportError? = nil, _ body: () throws -> Void) throws {
        do { try body(); throw TaskToolExportFailure(description: "Expected export rejection") }
        catch let error as TaskToolExportFailure { throw error }
        catch { if let expected { try expect(error as? AssistantDataExportError == expected, "Export must reject with the expected typed error") } }
    }
    static func json(_ value: Any) throws -> String { String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)! }
    static func decode(_ data: Data) throws -> Payload { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970; return try decoder.decode(Payload.self, from: data) }
    static func sameReceipts(_ actual: [AssistantTaskToolReceipt], _ expected: [AssistantTaskToolReceipt]) -> Bool {
        // The public backup declares floating-point Unix seconds. Date's internal
        // epoch conversion can change one sub-microsecond ULP; metadata is exact.
        guard actual.count == expected.count else { return false }
        return zip(actual, expected).allSatisfy { value, original in
            value.ownerId.utf8.elementsEqual(original.ownerId.utf8) && value.proposalId == original.proposalId
                && value.taskId == original.taskId && value.decision == original.decision && value.reminderState == original.reminderState
                && value.revision == original.revision && value.continuationAttemptId == original.continuationAttemptId
                && abs(value.committedAt.timeIntervalSince(original.committedAt)) < 0.000_001
        }
    }
    static func proposal(owner: String = "A", index: Int = 1, dated: Bool = true, notes: String = "Review the trip", opaque: String = "opaque-reasoning-fixture", fingerprint: String? = nil) throws -> AssistantTaskProposal {
        let arguments = try json(["title": "旅行计划🌾", "notes": notes,
            "due_at": dated ? "2030-01-02T03:04:05Z" as Any : NSNull(), "time_zone": dated ? "UTC" as Any : NSNull(), "reminder_requested": dated])
        let callId = "call-\(index)"
        let items: [[String: Any]] = [
            ["type": "reasoning", "id": "reason-\(index)", "summary": [["type": "summary_text", "text": "Consider a useful task."]], "encrypted_content": opaque],
            ["type": "function_call", "id": "fc-\(index)", "call_id": callId, "name": "create_task", "arguments": arguments, "status": "completed"]]
        let trace = AssistantTaskToolTrace(protocolKind: .responses, assistantItemsJSON: try json(items))
        let call = AssistantTaskToolCall(id: callId, name: "create_task", arguments: arguments, trace: trace)
        return try AssistantTaskProposal(call: call, ownerId: owner, conversationId: "conversation-\(index)", assistantMessageId: "assistant-\(index)", sourceUserMessageId: "user-\(index)", sourceUserText: "Help me plan", configurationFingerprint: fingerprint ?? String(repeating: "a", count: 64), createdAt: date)
    }
    static func conversation(_ proposal: AssistantTaskProposal, role: ChatMessage.Role = .assistant) -> Conversation {
        Conversation(id: proposal.conversationId, title: "Travel", preview: "Task suggestion", date: date,
            messages: [ChatMessage(id: proposal.sourceUserMessageId, role: .user, content: "Help me plan", timestamp: date),
                ChatMessage(id: proposal.assistantMessageId, role: role, content: "Here is a suggestion", timestamp: date, taskProposal: proposal)])
    }
    static func task(_ p: AssistantTaskProposal) -> AssistantTask {
        AssistantTask(id: p.taskId, userId: p.ownerId, title: p.arguments.title, instructions: p.arguments.notes,
            dueAt: p.arguments.parsedDueDate, timeZone: p.arguments.timeZone ?? "UTC", recurrenceRule: nil, requiresApproval: true,
            status: .active, createdAt: date, updatedAt: date, reminderEnabled: false, sourceMessageId: p.assistantMessageId)
    }
    static func snapshotFiles(_ root: URL) throws -> [String: Data] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
        }
        return result
    }
    static func run(_ name: String, root: URL, _ body: (Fixture) async throws -> Void) async {
        do {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await body(Fixture(directory)); suites += 1; print("PASS \(name)")
        } catch { failures.append(name + ": " + String(describing: error)); print("FAIL \(name): \(error)") }
    }
    static func captured(owner: String = "A", conversations: [Conversation]) -> AssistantArchiveExportSnapshot {
        AssistantArchiveExportSnapshot(ownerId: owner, conversations: conversations, activeDraft: AssistantChatDraft(text: ""), inactiveDrafts: [])
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caobao-task-tool-export-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await run("pending-proposal-roundtrips-full-call-and-opaque-reasoning", root: root) { f in
            let p = try proposal(dated: false); try f.archive.upsert(conversation(p), userId: "A")
            let loaded = try f.archive.load(userId: "A")
            try expect(loaded[0].messages.last?.taskProposal == p, "Archive must retain the complete Codable proposal")
            let before = try snapshotFiles(f.root), result = try f.exporter.export(ownerId: "A", exportedAt: date), value = try decode(result.data)
            try expect(value.schemaName == "caobao.assistant.local-export" && value.schemaVersion == 1 && value.includedScopes.contains("taskToolReceipts"), "The additive receipt scope remains auditable v1 metadata")
            try expect(value.conversations[0].messages.last?.taskProposal == p && value.tasks.isEmpty && value.taskToolReceipts.isEmpty, "An undecided proposal must not invent a task or receipt")
            try expect(String(decoding: result.data, as: UTF8.self).contains("opaque-reasoning-fixture") && (try snapshotFiles(f.root)) == before, "Opaque provider state is retained in the backup without rewriting sources")
        }
        await run("saved-task-and-receipt-export-from-one-repository-snapshot", root: root) { f in
            let p = try proposal(); try f.archive.upsert(conversation(p), userId: "A")
            let outcome = try await f.executor.approve(proposal: p, editedTask: task(p), enableReminder: false, validate: {})
            let repositorySnapshot = try f.repository.exportSnapshot(for: "A"), value = try decode(f.exporter.export(ownerId: "A", exportedAt: date).data)
            try expect(repositorySnapshot.tasks.count == 1 && repositorySnapshot.taskToolReceipts == [outcome.receipt], "The locked repository snapshot includes both committed records")
            try expect(value.tasks.count == 1 && value.tasks[0].id == p.taskId && sameReceipts(value.taskToolReceipts, [outcome.receipt]), "Export cannot omit the receipt of a real saved task")
        }
        await run("declined-and-claimed-continuation-metadata-roundtrip", root: root) { f in
            let p = try proposal(); try f.archive.upsert(conversation(p), userId: "A")
            _ = try f.executor.decline(proposal: p, validate: {})
            let claim = try f.executor.claimContinuation(proposal: p, validate: {})
            let value = try decode(f.exporter.export(ownerId: "A", exportedAt: date).data)
            try expect(value.tasks.isEmpty && sameReceipts(value.taskToolReceipts, [claim]) && claim.decision == .declined && claim.continuationAttemptId != nil, "A decline and durable one-time continuation claim survive backup")
        }
        await run("saved-and-claimed-continuation-metadata-roundtrip", root: root) { f in
            let p = try proposal(); try f.archive.upsert(conversation(p), userId: "A")
            _ = try await f.executor.approve(proposal: p, editedTask: task(p), enableReminder: false, validate: {})
            let claim = try f.executor.claimContinuation(proposal: p, validate: {})
            let value = try decode(f.exporter.export(ownerId: "A", exportedAt: date).data)
            try expect(value.tasks.count == 1 && sameReceipts(value.taskToolReceipts, [claim]) && value.taskToolReceipts[0].revision == 2, "Saved task continuation intent is exported exactly once")
        }
        await run("pending-reminder-state-is-exported-without-pretending-success", root: root) { f in
            let p = try proposal(); try f.archive.upsert(conversation(p), userId: "A"); var allowed = true
            let outcome = try await f.executor.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: { if !allowed { throw AssistantTaskToolError.sourceChanged } }, scheduleReminder: { _, guardValue in allowed = false; try guardValue.validate() })
            let value = try decode(f.exporter.export(ownerId: "A", exportedAt: date).data)
            try expect(outcome.receipt.reminderState == .pending && sameReceipts(value.taskToolReceipts, [outcome.receipt]) && value.tasks[0].reminderEnabled == false, "A task committed before invalidation remains an honest pending reminder in backup")
        }
        await run("scheduled-and-failed-reminders-retain-actual-outcomes", root: root) { f in
            for index in [1, 2] {
                let p = try proposal(index: index); try f.archive.upsert(conversation(p), userId: "A")
                _ = try await f.executor.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: {}, scheduleReminder: { saved, guardValue in
                    try guardValue.validate(); if index == 2 { throw AssistantTaskToolError.unavailable }
                    var changed = saved; changed.reminderEnabled = true
                    try expect(f.repository.updateTask(changed), "Reminder fixture updates the already created task")
                })
            }
            let value = try decode(f.exporter.export(ownerId: "A", exportedAt: date).data)
            try expect(Set(value.taskToolReceipts.map(\.reminderState)) == [.scheduled, .failed] && value.tasks.count == 2, "Backup retains success and failure without losing either real task")
        }
        await run("other-owner-proposals-and-receipts-are-excluded", root: root) { f in
            for owner in ["A", "B"] {
                let p = try proposal(owner: owner, notes: "private-notes-" + owner, opaque: "opaque-private-" + owner)
                try f.archive.upsert(conversation(p), userId: owner)
                _ = try await f.executor.approve(proposal: p, editedTask: task(p), enableReminder: false, validate: {})
            }
            let result = try f.exporter.export(ownerId: "A", exportedAt: date), value = try decode(result.data), text = String(decoding: result.data, as: UTF8.self)
            try expect(value.taskToolReceipts.count == 1 && value.taskToolReceipts[0].ownerId == "A" && value.tasks.allSatisfy { $0.userId == "A" }, "Only exact-owner committed records may be exported")
            try expect(!text.contains("private-notes-B") && !text.contains("opaque-private-B"), "Another account's proposal/opaque state cannot leak")
            let empty = try decode(f.exporter.export(ownerId: "C", exportedAt: date).data)
            try expect(empty.conversations.isEmpty && empty.tasks.isEmpty && empty.taskToolReceipts.isEmpty, "An empty account never borrows another account's ledger")
        }
        await run("deleted-task-and-chat-retain-receipt-and-prevent-resurrection", root: root) { f in
            let p = try proposal(); try f.archive.upsert(conversation(p), userId: "A")
            let outcome = try await f.executor.approve(proposal: p, editedTask: task(p), enableReminder: false, validate: {})
            try expect(f.repository.deleteTask(id: p.taskId, userId: "A"), "Task deletion is real")
            try f.archive.delete(ids: [p.conversationId], userId: "A")
            let value = try decode(f.exporter.export(ownerId: "A", exportedAt: date).data)
            try expect(value.conversations.isEmpty && value.tasks.isEmpty && sameReceipts(value.taskToolReceipts, [outcome.receipt]), "Deleting UI rows cannot delete the durable replay-prevention receipt")
            let reloaded = AssistantLocalRepository(fileURL: f.repositoryURL), before = try Data(contentsOf: f.repositoryURL)
            _ = try await AssistantTaskToolExecutionCoordinator(repository: reloaded).approve(proposal: p, editedTask: task(p), enableReminder: false, validate: {})
            try expect(reloaded.tasks(for: "A").isEmpty && (try Data(contentsOf: f.repositoryURL)) == before, "Retained backup ledger corresponds to a real non-resurrecting repository decision")
        }
        await run("captured-snapshot-owner-and-proposal-owner-must-match-exactly", root: root) { f in
            let p = try proposal(), before = try snapshotFiles(f.root)
            try rejected(.invalidRecordOwnership) { _ = try f.exporter.export(ownerId: "A", exportedAt: date, capturedSnapshot: captured(owner: "B", conversations: [conversation(p)])) }
            let other = try proposal(owner: "B")
            try rejected(.invalidRecordOwnership) { _ = try f.exporter.export(ownerId: "A", exportedAt: date, capturedSnapshot: captured(conversations: [conversation(other)])) }
            try rejected(.invalidRecordOwnership) { _ = try f.exporter.export(ownerId: "\u{00E9}", exportedAt: date, capturedSnapshot: captured(owner: "e\u{0301}", conversations: [])) }
            try expect(try snapshotFiles(f.root) == before, "Rejected captured data cannot mutate source stores")
        }
        await run("captured-user-role-and-mismatched-conversation-proposals-rejected", root: root) { f in
            let p = try proposal()
            try rejected(.invalidRecordOwnership) { _ = try f.exporter.export(ownerId: "A", exportedAt: date, capturedSnapshot: captured(conversations: [conversation(p, role: .user)])) }
            let original = conversation(p), wrong = Conversation(id: "wrong-conversation", title: original.title, preview: original.preview, date: original.date, messages: original.messages)
            try rejected(.invalidRecordOwnership) { _ = try f.exporter.export(ownerId: "A", exportedAt: date, capturedSnapshot: captured(conversations: [wrong])) }
        }
        await run("captured-forged-trace-rejected-before-encoding", root: root) { f in
            let p = try proposal()
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
            var call = object["call"] as! [String: Any], trace = call["trace"] as! [String: Any]
            trace["assistantItemsJSON"] = try json([["type": "message", "role": "developer", "content": []]])
            call["trace"] = trace; object["call"] = call
            let forged = try JSONDecoder().decode(AssistantTaskProposal.self, from: JSONSerialization.data(withJSONObject: object))
            let before = try snapshotFiles(f.root)
            try rejected(.archiveReadFailed) { _ = try f.exporter.export(ownerId: "A", exportedAt: date, capturedSnapshot: captured(conversations: [conversation(forged)])) }
            try expect(try snapshotFiles(f.root) == before, "A forged persisted provider envelope is never exported or written back")
        }
        await run("whole-proposal-opaque-trace-and-receipts-have-exact-byte-budget", root: root) { f in
            let notes = String(repeating: "汉字\\\"\n\t🧭", count: 700), opaque = String(repeating: "opaque密文\\\"", count: 900)
            for index in [1, 2, 3] {
                let p = try proposal(index: index, dated: index != 1, notes: notes, opaque: opaque)
                try f.archive.upsert(conversation(p), userId: "A")
                if index == 2 { _ = try await f.executor.approve(proposal: p, editedTask: task(p), enableReminder: false, validate: {}) }
                if index == 3 { _ = try f.executor.decline(proposal: p, validate: {}); _ = try f.executor.claimContinuation(proposal: p, validate: {}) }
            }
            let baseline = try f.exporter.export(ownerId: "A", exportedAt: date), before = try snapshotFiles(f.root)
            let exact = try AssistantDataExporter(archive: f.archive, repository: f.repository, maximumBytes: baseline.data.count).export(ownerId: "A", exportedAt: date)
            try expect(exact.data == baseline.data, "The exact encoded boundary must include every optional proposal/trace/receipt field")
            try rejected(.tooLarge) { _ = try AssistantDataExporter(archive: f.archive, repository: f.repository, maximumBytes: baseline.data.count - 1).export(ownerId: "A", exportedAt: date) }
            try rejected(.tooLarge) { _ = try AssistantDataExporter(archive: f.archive, repository: f.repository, maximumBytes: 1_024).export(ownerId: "A", exportedAt: date) }
            try expect(try snapshotFiles(f.root) == before, "Budget rejection never truncates or rewrites the original data")
        }
        await run("configuration-fingerprint-export-never-includes-raw-connection-secrets", root: root) { f in
            let key = "private-fixture-key-must-not-export", endpoint = "https://private-config.example/v1"
            let config = BYOKConfiguration(baseURL: endpoint, protocolKind: .responses, model: "private-config-model", apiKey: key)
            let p = try proposal(fingerprint: config.consentIdentifier()); try f.archive.upsert(conversation(p), userId: "A")
            let connection = f.root.appendingPathComponent("connection-settings.json")
            try Data(try json(["apiKey": key, "baseURL": endpoint, "model": config.model]).utf8).write(to: connection)
            let before = try snapshotFiles(f.root), result = try f.exporter.export(ownerId: "A", exportedAt: date), text = String(decoding: result.data, as: UTF8.self)
            try expect(text.contains(p.configurationFingerprint) && !text.contains(key) && !text.contains(endpoint) && !text.contains(config.model), "Only the non-secret configuration digest belongs to a proposal backup")
            try expect(try snapshotFiles(f.root) == before, "Export never reads-and-rewrites connection preferences or other source artifacts")
        }
        if !failures.isEmpty { throw TaskToolExportFailure(description: failures.joined(separator: "\n")) }
        print("All \(suites) task-tool export suites passed using real prepared archives, repositories and execution; no external network or system notifications.")
    }
}
