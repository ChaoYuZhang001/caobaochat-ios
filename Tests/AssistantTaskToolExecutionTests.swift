import Foundation

private struct TaskExecutionFailure: Error, CustomStringConvertible { let description: String }
private final class TaskExecutionFileManager: FileManager, @unchecked Sendable {
    var rejectsWrites = false
    var directoryWriteAttempts = 0
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {
        directoryWriteAttempts += 1
        if rejectsWrites { throw TaskExecutionFailure(description: "Injected atomic-store failure") }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}
@MainActor private final class TaskExecutionGate {
    var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func open() { waiter?.resume(); waiter = nil }
}
@MainActor private final class TaskExecutionAuthorization {
    var allowed = true
    var checks = 0
    func validate() throws { checks += 1; if !allowed { throw AssistantTaskToolError.sourceChanged } }
}

@main @MainActor private enum AssistantTaskToolExecutionTests {
    static var suites = 0
    static var failures: [String] = []
    nonisolated static let date = Date(timeIntervalSince1970: 1_793_232_000.125)
    nonisolated static let args = #"{"title":"Plan a trip","notes":"Compare flights","due_at":"2030-01-02T03:04:05Z","time_zone":"UTC","reminder_requested":true}"#
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TaskExecutionFailure(description: message) }
    }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body(); throw TaskExecutionFailure(description: "Expected operation to be rejected") }
        catch is TaskExecutionFailure { throw TaskExecutionFailure(description: "Expected domain/repository rejection") }
        catch {}
    }
    static func rejectsAsync(_ body: () async throws -> Void) async throws {
        do { try await body(); throw TaskExecutionFailure(description: "Expected async operation to be rejected") }
        catch is TaskExecutionFailure { throw TaskExecutionFailure(description: "Expected domain/repository rejection") }
        catch {}
    }
    static func json(_ object: Any) throws -> String { String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)! }
    static func proposal(owner: String = "A", message: String = "assistant-1", raw: String = args) throws -> AssistantTaskProposal {
        let trace = AssistantTaskToolTrace(protocolKind: .chatCompletions, assistantItemsJSON: try json([["role": "assistant", "content": "A useful task", "tool_calls": [["id": "call-1", "type": "function", "function": ["name": "create_task", "arguments": raw]]]]]))
        let call = AssistantTaskToolCall(id: "call-1", name: "create_task", arguments: raw, trace: trace)
        return try AssistantTaskProposal(call: call, ownerId: owner, conversationId: "conversation-1", assistantMessageId: message, sourceUserMessageId: "user-1", sourceUserText: "Help plan the trip", configurationFingerprint: String(repeating: "a", count: 64), createdAt: date)
    }
    static func task(_ p: AssistantTaskProposal, title: String = "Edited trip task") -> AssistantTask {
        AssistantTask(id: p.taskId, userId: p.ownerId, title: title, instructions: "User reviewed notes", dueAt: p.arguments.parsedDueDate, timeZone: "UTC", recurrenceRule: nil, requiresApproval: true, status: .active, createdAt: date, updatedAt: date, reminderEnabled: false, sourceMessageId: p.assistantMessageId)
    }
    static func receipt(_ p: AssistantTaskProposal, decision: AssistantTaskToolDecision = .saved, state: AssistantTaskToolReminderState = .notRequested) -> AssistantTaskToolReceipt {
        AssistantTaskToolReceipt(ownerId: p.ownerId, proposalId: p.id, taskId: decision == .saved ? p.taskId : nil, decision: decision, reminderState: state, committedAt: date, revision: 1)
    }
    static func run(_ name: String, root: URL, _ test: (URL) async throws -> Void) async throws {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try await test(folder.appendingPathComponent("store.json")); suites += 1; print("PASS \(name)") }
        catch { failures.append(name + ": " + String(describing: error)); print("FAIL \(name): \(error)") }
    }
    static func mutateStore(_ url: URL, _ mutation: (inout [String: Any]) -> Void) throws {
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        mutation(&object); try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
    }
    static func domainTests(root: URL) async throws {
        try await run("strict-task-arguments-accept-valid-iso-z-offset-fraction", root: root) { _ in
            for value in [args, args.replacingOccurrences(of: "03:04:05Z", with: "03:04:05.123Z"), args.replacingOccurrences(of: "03:04:05Z", with: "11:04:05+08:00").replacingOccurrences(of: "UTC", with: "Asia/Shanghai")] {
                let parsed = try AssistantTaskToolArguments(json: value)
                try expect(parsed.parsedDueDate != nil && parsed.title == "Plan a trip" && parsed.reminderRequested, "Valid dated arguments must retain their meaning")
            }
            let undated = #"{"title":"Hello","notes":"","due_at":null,"time_zone":null,"reminder_requested":false}"#
            let parsed = try AssistantTaskToolArguments(json: undated)
            try expect(parsed.parsedDueDate == nil && parsed.timeZone == nil, "Undated task fields must be jointly null")
        }
        try await run("strict-task-arguments-reject-duplicate-and-escaped-duplicate-keys", root: root) { _ in
            for key in ["title", #"\u0074itle"#] {
                let duplicate = args.dropLast() + ",\"" + key + "\":\"forged\"}"
                try rejects { _ = try AssistantTaskToolArguments(json: duplicate) }
                try rejects { _ = try proposal(raw: duplicate) }
            }
        }
        try await run("strict-task-arguments-reject-extra-missing-nested-wrong-types", root: root) { _ in
            let invalid = [args.replacingOccurrences(of: "true}", with: "1}"), args.replacingOccurrences(of: "true}", with: "\"true\"}"), args.replacingOccurrences(of: "true}", with: "true,\"approved\":true}"), args.replacingOccurrences(of: "\"notes\":\"Compare flights\",", with: ""), args.replacingOccurrences(of: "\"Compare flights\"", with: "{}"), "[" + args + "]", args + "{}"]
            for raw in invalid { try rejects { _ = try AssistantTaskToolArguments(json: raw) } }
        }
        try await run("strict-task-arguments-reject-invalid-zone-date-and-size", root: root) { _ in
            for raw in [args.replacingOccurrences(of: "2030-01-02T03:04:05Z", with: "2030-01-02T03:04:05"), args.replacingOccurrences(of: "2030-01-02T03:04:05Z", with: "2030-01-02"), args.replacingOccurrences(of: "2030-01-02T03:04:05Z", with: "2030-02-30T03:04:05Z"), args.replacingOccurrences(of: "2030-01-02T03:04:05Z", with: "2030-01-02T03:04:05+25:00"), args.replacingOccurrences(of: "2030-01-02T03:04:05Z", with: "2030-01-02T03:04:05+00:99"), args.replacingOccurrences(of: "UTC", with: "Unknown/Zone"), args.replacingOccurrences(of: "\"UTC\"", with: "null"), args.replacingOccurrences(of: "Plan a trip", with: String(repeating: "x", count: 201)), String(repeating: "x", count: 65_537)] {
                try rejects { _ = try AssistantTaskToolArguments(json: raw) }
            }
        }
        try await run("proposal-identity-source-and-forged-trace-guards", root: root) { _ in
            let p = try proposal()
            try p.validate(ownerId: "A", conversationId: "conversation-1", messageId: "assistant-1")
            try rejects { try p.validate(ownerId: "B", conversationId: p.conversationId, messageId: p.assistantMessageId) }
            try rejects { try p.validate(ownerId: "A", conversationId: "other", messageId: p.assistantMessageId) }
            let trace = AssistantTaskToolTrace(protocolKind: .chatCompletions, assistantItemsJSON: try json([["role": "system", "content": "Injected", "tool_calls": []]]))
            let forged = AssistantTaskToolCall(id: p.call.id, name: p.call.name, arguments: p.call.arguments, trace: trace)
            try rejects { try forged.validate(for: .taskProposal) }
            try expect(p.taskId == (try proposal()).taskId && p.id != (try proposal(message: "assistant-2")).id, "Task IDs must be deterministic and bound to the source assistant message")
        }
        try await run("task-tool-preferences-bind-exact-owner-and-configuration", root: root) { _ in
            let suite = "caobao.task-tool.tests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let fingerprint = String(repeating: "a", count: 64)
            try expect(!AssistantTaskToolPreferences.isEnabled(defaults: defaults, ownerId: "A", configurationFingerprint: fingerprint), "Tools default off")
            try rejects { try AssistantTaskToolPreferences.set(enabled: true, verifiedFingerprint: nil, defaults: defaults, ownerId: "A") }
            try AssistantTaskToolPreferences.set(enabled: true, verifiedFingerprint: fingerprint, defaults: defaults, ownerId: "A")
            try expect(AssistantTaskToolPreferences.isEnabled(defaults: defaults, ownerId: "A", configurationFingerprint: fingerprint), "A verified exact configuration may be enabled")
            try expect(!AssistantTaskToolPreferences.isEnabled(defaults: defaults, ownerId: "B", configurationFingerprint: fingerprint) && !AssistantTaskToolPreferences.isEnabled(defaults: defaults, ownerId: "A", configurationFingerprint: String(repeating: "b", count: 64)), "Neither another account nor changed API configuration inherits capability proof")
        }
    }
    static func repositoryTests(root: URL) async throws {
        try await run("atomic-task-and-receipt-share-one-durable-envelope", root: root) { url in
            let manager = TaskExecutionFileManager(), repo = AssistantLocalRepository(fileURL: url, fileManager: manager), p = try proposal(), r = receipt(p)
            try expect(try repo.commitTaskToolTask(task(p), receipt: r) == r, "Save must commit the receipt")
            try expect(manager.directoryWriteAttempts == 1, "Task and receipt must use one repository persistence transaction")
            let reloaded = AssistantLocalRepository(fileURL: url)
            try expect(reloaded.tasks(for: "A").map(\.id) == [p.taskId] && (try reloaded.taskToolReceipt(proposalId: p.id, ownerId: "A")) == r, "Both task and receipt must survive reopening")
            try expect(reloaded.tasks(for: "A")[0].reminderEnabled == false, "Saving a task never implies notification consent")
        }
        try await run("failed-atomic-save-publishes-neither-task-nor-receipt", root: root) { url in
            let manager = TaskExecutionFileManager(), repo = AssistantLocalRepository(fileURL: url, fileManager: manager), p = try proposal()
            manager.rejectsWrites = true
            try rejects { _ = try repo.commitTaskToolTask(task(p), receipt: receipt(p)) }
            try expect(repo.tasks(for: "A").isEmpty && (try repo.taskToolReceipt(proposalId: p.id, ownerId: "A")) == nil, "Failed disk write must not publish in-memory half state")
            try expect(!FileManager.default.fileExists(atPath: url.path), "Failed first transaction must not leave a store")
            manager.rejectsWrites = false
            _ = try repo.commitTaskToolTask(task(p), receipt: receipt(p))
            try expect(AssistantLocalRepository(fileURL: url).tasks(for: "A").count == 1, "A retry after atomic failure may commit exactly once")
            let bytes = try Data(contentsOf: url), next = try proposal(message: "assistant-2")
            manager.rejectsWrites = true
            try rejects { _ = try repo.commitTaskToolTask(task(next), receipt: receipt(next)) }
            try expect(repo.tasks(for: "A").count == 1 && (try repo.taskToolReceipt(proposalId: next.id, ownerId: "A")) == nil && (try Data(contentsOf: url)) == bytes, "A failed later transaction must preserve the existing envelope and publish no second receipt")
        }
        try await run("duplicate-approve-preserves-bytes-and-original-task", root: root) { url in
            let repo = AssistantLocalRepository(fileURL: url), p = try proposal(), r = receipt(p)
            _ = try repo.commitTaskToolTask(task(p), receipt: r); let bytes = try Data(contentsOf: url)
            _ = try repo.commitTaskToolTask(task(p, title: "Changed duplicate"), receipt: r)
            try expect(try Data(contentsOf: url) == bytes, "Duplicate approval must perform no persistence write")
            try expect(repo.tasks(for: "A")[0].title == "Edited trip task", "A duplicate must not edit the committed task")
        }
        try await run("declined-decision-cannot-be-reversed-into-save", root: root) { url in
            let repo = AssistantLocalRepository(fileURL: url), p = try proposal(), declined = receipt(p, decision: .declined)
            _ = try repo.commitTaskToolDecline(declined); let bytes = try Data(contentsOf: url)
            let replay = try repo.commitTaskToolTask(task(p), receipt: receipt(p))
            try expect(replay.decision == .declined && repo.tasks(for: "A").isEmpty && (try Data(contentsOf: url)) == bytes, "A saved replay cannot replace a durable decline")
        }
        try await run("restart-and-deleted-task-receipt-prevent-resurrection", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url)
            _ = try repo.commitTaskToolTask(task(p), receipt: receipt(p))
            try expect(repo.deleteTask(id: p.taskId, userId: "A"), "Owner may delete a created task")
            let reloaded = AssistantLocalRepository(fileURL: url), bytes = try Data(contentsOf: url)
            _ = try reloaded.commitTaskToolTask(task(p), receipt: receipt(p))
            try expect(reloaded.tasks(for: "A").isEmpty && (try Data(contentsOf: url)) == bytes, "Retained saved receipt must prevent resurrection after restart")
        }
        try await run("receipt-owner-and-unicode-exact-isolation", root: root) { url in
            let firstOwner = "\u{00E9}", secondOwner = "e\u{0301}", repo = AssistantLocalRepository(fileURL: url)
            let p = try proposal(owner: firstOwner); _ = try repo.commitTaskToolTask(task(p), receipt: receipt(p))
            do { try expect(try repo.taskToolReceipt(proposalId: p.id, ownerId: secondOwner) == nil, "Canonical-equivalent owners must not share receipts") }
            catch let error as AssistantRepositoryError {
                guard case .invalidUserId = error else { throw error }
            }
            try expect(repo.tasks(for: secondOwner).isEmpty && repo.tasks(for: "B").isEmpty, "Canonical-equivalent owners must not read another owner's task")
            let bytes = try Data(contentsOf: url), secondProposal = try proposal(owner: secondOwner)
            try rejects { _ = try repo.commitTaskToolTask(task(secondProposal), receipt: receipt(secondProposal)) }
            try expect(!repo.deleteUserData(for: secondOwner) && (try Data(contentsOf: url)) == bytes, "An ambiguous owner cannot overwrite or delete another exact owner's data")
            try rejects { _ = try repo.commitTaskToolTask(task(p), receipt: receipt(try proposal(owner: "B"))) }
        }
        try await run("legacy-json-loads-without-receipt-schema", root: root) { url in
            try Data(#"{"memories":{},"tasks":{},"memoryEnabled":{}}"#.utf8).write(to: url)
            let repo = AssistantLocalRepository(fileURL: url), p = try proposal()
            try expect(repo.lastError == nil && (try repo.taskToolReceipt(proposalId: p.id, ownerId: "A")) == nil, "Missing additive receipt field is a valid legacy store")
            _ = try repo.commitTaskToolTask(task(p), receipt: receipt(p))
            try expect(AssistantLocalRepository(fileURL: url).lastError == nil, "Upgraded envelope must remain readable")
        }
        try await run("corrupt-receipt-blocks-load-and-overwrite", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url)
            _ = try repo.commitTaskToolTask(task(p), receipt: receipt(p))
            try mutateStore(url) { object in
                var owners = object["taskToolReceipts"] as! [String: [String: [String: Any]]]
                owners[Data("A".utf8).base64EncodedString()]![p.id]!["ownerId"] = "B"; object["taskToolReceipts"] = owners
            }
            let bytes = try Data(contentsOf: url), reloaded = AssistantLocalRepository(fileURL: url)
            try expect(reloaded.lastError != nil, "Ownership-corrupt receipt must fail store loading")
            try rejects { _ = try reloaded.commitTaskToolTask(task(p), receipt: receipt(p)) }
            try expect(try Data(contentsOf: url) == bytes, "Corrupt private data must be retained exactly")
        }
        try await run("receipt-cas-prevents-stale-reminder-state-writes", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), initial = receipt(p, state: .pending)
            _ = try repo.commitTaskToolTask(task(p), receipt: initial)
            var changed = initial; changed.reminderState = .scheduled; changed.revision = 2
            _ = try repo.updateTaskToolReceipt(changed, expectedRevision: 1); let bytes = try Data(contentsOf: url)
            var stale = initial; stale.reminderState = .failed; stale.revision = 2
            try rejects { _ = try repo.updateTaskToolReceipt(stale, expectedRevision: 1) }
            try expect(try Data(contentsOf: url) == bytes, "Stale metadata update cannot overwrite a newer result")
        }
        try await run("explicit-null-receipt-ledger-is-corrupt-not-legacy", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url)
            _ = try repo.commitTaskToolTask(task(p), receipt: receipt(p))
            try mutateStore(url) { $0["taskToolReceipts"] = NSNull() }
            let bytes = try Data(contentsOf: url), reloaded = AssistantLocalRepository(fileURL: url)
            try expect(reloaded.lastError != nil, "An explicitly null ledger cannot be treated as a missing legacy field")
            try rejects { _ = try reloaded.commitTaskToolDecline(receipt(p, decision: .declined)) }
            try expect(try Data(contentsOf: url) == bytes, "A corrupt null ledger must never be overwritten")
        }
        try await run("continuation-claim-is-durable-and-at-most-once", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url)
            _ = try repo.commitTaskToolTask(task(p), receipt: receipt(p))
            let attempt = UUID().uuidString, claimed = try repo.claimTaskToolContinuation(proposalId: p.id, ownerId: "A", expectedRevision: 1, attemptId: attempt)
            try expect(claimed.continuationAttemptId == attempt && claimed.revision == 2, "Claim must durably precede network execution")
            let reloaded = AssistantLocalRepository(fileURL: url), bytes = try Data(contentsOf: url)
            try rejects { _ = try reloaded.claimTaskToolContinuation(proposalId: p.id, ownerId: "A", expectedRevision: 2, attemptId: UUID().uuidString) }
            try expect(try Data(contentsOf: url) == bytes, "Restart cannot release a second continuation intent")
            try expect(reloaded.deleteTask(id: p.taskId, userId: "A"), "Deleting UI task is allowed")
            let deletedBytes = try Data(contentsOf: url)
            try rejects { _ = try reloaded.claimTaskToolContinuation(proposalId: p.id, ownerId: "A", expectedRevision: 2, attemptId: UUID().uuidString) }
            try expect(try Data(contentsOf: url) == deletedBytes, "Deleting task or conversation UI cannot reset the receipt claim")
        }
        try await run("pending-reminder-and-failed-claim-start-no-new-intent", root: root) { url in
            let p = try proposal(), manager = TaskExecutionFileManager(), repo = AssistantLocalRepository(fileURL: url, fileManager: manager)
            _ = try repo.commitTaskToolTask(task(p), receipt: receipt(p, state: .pending)); let bytes = try Data(contentsOf: url)
            try rejects { _ = try repo.claimTaskToolContinuation(proposalId: p.id, ownerId: "A", expectedRevision: 1, attemptId: UUID().uuidString) }
            try expect(try Data(contentsOf: url) == bytes, "Pending notification state cannot be reported as a settled tool result")
        }
        try await run("extreme-receipt-revision-is-corrupt-and-cannot-overwrite", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url)
            var extreme = receipt(p); extreme.revision = Int.max
            try expect(!extreme.isValid(ownerId: "A", proposalId: p.id), "Int.max receipt revision is invalid before any arithmetic")
            _ = try repo.commitTaskToolTask(task(p), receipt: receipt(p))
            try mutateStore(url) { object in
                var owners = object["taskToolReceipts"] as! [String: [String: [String: Any]]]
                owners[Data("A".utf8).base64EncodedString()]![p.id]!["revision"] = Int.max; object["taskToolReceipts"] = owners
            }
            let bytes = try Data(contentsOf: url), reloaded = AssistantLocalRepository(fileURL: url)
            try expect(reloaded.lastError != nil, "An overflow-capable revision must fail store loading")
            try rejects { _ = try reloaded.taskToolReceipt(proposalId: p.id, ownerId: "A") }
            try rejects { _ = try reloaded.claimTaskToolContinuation(proposalId: p.id, ownerId: "A", expectedRevision: Int.max, attemptId: UUID().uuidString) }
            try expect(try Data(contentsOf: url) == bytes, "Invalid extreme receipt is retained exactly and never rewritten")
        }
        try await run("extreme-claim-and-update-revisions-reject-before-increment", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url)
            _ = try repo.commitTaskToolTask(task(p), receipt: receipt(p))
            try mutateStore(url) { object in
                var owners = object["taskToolReceipts"] as! [String: [String: [String: Any]]]
                owners[Data("A".utf8).base64EncodedString()]![p.id]!["revision"] = Int.max - 1; object["taskToolReceipts"] = owners
            }
            let reloaded = AssistantLocalRepository(fileURL: url), bytes = try Data(contentsOf: url)
            try expect(reloaded.lastError == nil, "Upper finite valid revision may load for a rejection-only boundary check")
            try rejects { _ = try reloaded.claimTaskToolContinuation(proposalId: p.id, ownerId: "A", expectedRevision: Int.max - 1, attemptId: UUID().uuidString) }
            var metadata = receipt(p); metadata.revision = Int.max - 1; metadata.reminderState = .failed
            try rejects { _ = try reloaded.updateTaskToolReceipt(metadata, expectedRevision: Int.max - 1) }
            try rejects { _ = try reloaded.updateTaskToolReceipt(metadata, expectedRevision: Int.max) }
            try expect(try Data(contentsOf: url) == bytes, "Extreme CAS and continuation operations must reject without arithmetic traps or disk writes")
        }
        try await run("receipt-date-is-exact-across-first-commit-restart-and-cas", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url)
            let rawDate = Date(timeIntervalSinceReferenceDate: 800_000_000 + 0.000_000_119_209_289_550_781_25)
            let canonical = Date(timeIntervalSince1970: rawDate.timeIntervalSince1970)
            try expect(rawDate != canonical, "Fixture must actually exercise the epoch conversion precision boundary")
            let raw = AssistantTaskToolReceipt(ownerId: "A", proposalId: p.id, taskId: p.taskId, decision: .saved, reminderState: .pending, committedAt: rawDate, revision: 1)
            let committed = try repo.commitTaskToolTask(task(p), receipt: raw)
            try expect(committed.committedAt == canonical && committed == repo.taskToolReceipt(proposalId: p.id, ownerId: "A"), "First publication must return exactly the same canonical receipt held in memory")
            let reloaded = AssistantLocalRepository(fileURL: url)
            try expect(try reloaded.taskToolReceipt(proposalId: p.id, ownerId: "A") == committed, "Restart must retain receipt equality exactly, without a timestamp tolerance")
            var metadata = committed; metadata.reminderState = .scheduled; metadata.revision = 2
            let updated = try reloaded.updateTaskToolReceipt(metadata, expectedRevision: 1)
            try expect(updated == metadata && (try AssistantLocalRepository(fileURL: url).taskToolReceipt(proposalId: p.id, ownerId: "A")) == metadata, "Exact committedAt CAS must succeed after restart and stay exact on the next restart")
            let declinedProposal = try proposal(message: "assistant-declined")
            let decline = AssistantTaskToolReceipt(ownerId: "A", proposalId: declinedProposal.id, taskId: nil, decision: .declined, reminderState: .notRequested, committedAt: rawDate, revision: 1)
            let declined = try reloaded.commitTaskToolDecline(decline)
            let afterDecline = AssistantLocalRepository(fileURL: url)
            try expect(declined.committedAt == canonical && declined == afterDecline.taskToolReceipt(proposalId: declinedProposal.id, ownerId: "A"), "Initial decline publication must use the same exact persistent date representation")
            let claim = try afterDecline.claimTaskToolContinuation(proposalId: declinedProposal.id, ownerId: "A", expectedRevision: 1, attemptId: UUID().uuidString)
            try expect(claim.committedAt == declined.committedAt && claim == AssistantLocalRepository(fileURL: url).taskToolReceipt(proposalId: declinedProposal.id, ownerId: "A"), "Continuation claim must retain the canonical committedAt exactly")
        }
    }
    static func coordinatorTests(root: URL) async throws {
        try await run("coordinator-edited-task-saves-once-without-reminder", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), auth = TaskExecutionAuthorization()
            let coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            var notificationCalls = 0
            let outcome = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: false, validate: { try auth.validate() }, scheduleReminder: { _, _ in notificationCalls += 1 })
            try expect(outcome.receipt.decision == .saved && outcome.receipt.reminderState == .notRequested && notificationCalls == 0, "Saving without explicit reminder consent never schedules")
            try expect(outcome.task?.title == "Edited trip task" && auth.checks >= 2 && outcome.reminderFailureMessage == nil, "User edits and final validation must take effect")
            let bytes = try Data(contentsOf: url)
            _ = try await coordinator.approve(proposal: p, editedTask: task(p, title: "Replay must not edit"), enableReminder: true, validate: { try auth.validate() }, scheduleReminder: { _, _ in notificationCalls += 1 })
            try expect(try Data(contentsOf: url) == bytes, "Repeated approve is a durable no-op")
            try expect(notificationCalls == 0 && repo.tasks(for: "A").count == 1, "Approval replay cannot schedule a previously unrequested reminder")
        }
        try await run("coordinator-initial-persistence-failure-does-not-schedule", root: root) { url in
            let p = try proposal(), manager = TaskExecutionFileManager(), repo = AssistantLocalRepository(fileURL: url, fileManager: manager)
            let coordinator = AssistantTaskToolExecutionCoordinator(repository: repo); manager.rejectsWrites = true
            var notificationCalls = 0
            try await rejectsAsync { _ = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: {}, scheduleReminder: { _, _ in notificationCalls += 1 }) }
            try expect(notificationCalls == 0 && repo.tasks(for: "A").isEmpty && (try repo.taskToolReceipt(proposalId: p.id, ownerId: "A")) == nil, "No task, receipt or notification may escape a failed atomic commit")
        }
        try await run("coordinator-pre-cancelled-approval-performs-zero-writes", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            var reminderCalls = 0
            let operation = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: {}, scheduleReminder: { _, _ in reminderCalls += 1 })
            }
            try await rejectsAsync { _ = try await operation.value }
            try expect(reminderCalls == 0 && repo.tasks(for: "A").isEmpty && !FileManager.default.fileExists(atPath: url.path), "Cancellation before approval cannot save or notify")
        }
        try await run("coordinator-rechecks-source-synchronously-before-commit", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), auth = TaskExecutionAuthorization()
            let coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            try await rejectsAsync {
                _ = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: false, validate: {
                    auth.checks += 1; if auth.checks == 2 { throw AssistantTaskToolError.sourceChanged }
                })
            }
            try expect(auth.checks == 2 && repo.tasks(for: "A").isEmpty && !FileManager.default.fileExists(atPath: url.path), "The final source check must reject before any disk write")
        }
        try await run("coordinator-forged-owner-and-source-task-cannot-save", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            for owner in ["B", "A"] {
                let invalid = AssistantTask(id: p.taskId, userId: owner, title: "Forged", instructions: nil, dueAt: nil, timeZone: "UTC", recurrenceRule: nil, requiresApproval: true, status: .active, createdAt: date, updatedAt: date, reminderEnabled: true, sourceMessageId: owner == "A" ? "different-source" : p.assistantMessageId)
                try await rejectsAsync { _ = try await coordinator.approve(proposal: p, editedTask: invalid, enableReminder: false, validate: {}) }
            }
            try expect(repo.tasks(for: "A").isEmpty && repo.tasks(for: "B").isEmpty, "Forged task owner/source cannot be normalized into an approved task")
        }
        try await run("coordinator-reminder-without-edited-due-date-is-rejected-before-save", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            var undated = task(p); undated.dueAt = nil
            var reminders = 0
            try await rejectsAsync { _ = try await coordinator.approve(proposal: p, editedTask: undated, enableReminder: true, validate: {}, scheduleReminder: { _, _ in reminders += 1 }) }
            try expect(reminders == 0 && repo.tasks(for: "A").isEmpty && (try repo.taskToolReceipt(proposalId: p.id, ownerId: "A")) == nil && !FileManager.default.fileExists(atPath: url.path), "An undated reminder cannot save a task, receipt or notification side effect")
        }
        try await run("coordinator-model-proposed-recurrence-is-rejected-before-save", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            var repeating = task(p); repeating.recurrenceRule = "FREQ=DAILY"
            try await rejectsAsync { _ = try await coordinator.approve(proposal: p, editedTask: repeating, enableReminder: false, validate: {}) }
            try expect(repo.tasks(for: "A").isEmpty && (try repo.taskToolReceipt(proposalId: p.id, ownerId: "A")) == nil && !FileManager.default.fileExists(atPath: url.path), "A nonnil recurrence rule cannot escape the single-task approval contract")
        }
        try await run("coordinator-reminder-success-updates-existing-task-and-receipt", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            var notificationCalls = 0
            let outcome = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: {}, scheduleReminder: { saved, guardValue in
                notificationCalls += 1; try guardValue.validate()
                try expect(repo.tasks(for: "A").count == 1 && saved.reminderEnabled == false, "The task must already exist exactly once before scheduling")
                try expect(try repo.taskToolReceipt(proposalId: p.id, ownerId: "A")?.reminderState == .pending, "A durable pending receipt must precede notification work")
                var changed = saved; changed.reminderEnabled = true; changed.updatedAt = Date()
                try guardValue.validate(); try expect(repo.updateTask(changed), "Fixture notification operation must update the existing task")
            })
            let reloaded = AssistantLocalRepository(fileURL: url)
            try expect(notificationCalls == 1 && outcome.receipt.reminderState == .scheduled && outcome.reminderFailureMessage == nil, "Only verified reminder success may report scheduled")
            try expect(reloaded.tasks(for: "A").count == 1 && reloaded.tasks(for: "A")[0].reminderEnabled == true && (try reloaded.taskToolReceipt(proposalId: p.id, ownerId: "A"))?.reminderState == .scheduled, "Task and reminder outcome must survive reopening")
        }
        try await run("coordinator-concurrent-decisions-cannot-race-pending-reminder", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo), gate = TaskExecutionGate()
            let first = Task { @MainActor in
                try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: {}, scheduleReminder: { saved, guardValue in
                    await gate.wait(); try guardValue.validate(); var changed = saved; changed.reminderEnabled = true
                    try expect(repo.updateTask(changed), "Original reminder operation updates the existing task")
                })
            }
            for _ in 0..<200 { if gate.entered { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            try expect(gate.entered, "First approval must reach the controlled async reminder boundary")
            let bytes = try Data(contentsOf: url)
            try await rejectsAsync { _ = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: false, validate: {}) }
            try rejects { _ = try coordinator.decline(proposal: p, validate: {}) }
            try rejects { _ = try coordinator.claimContinuation(proposal: p, validate: {}) }
            try expect(repo.tasks(for: "A").count == 1 && (try Data(contentsOf: url)) == bytes, "Competing decisions cannot rewrite an in-flight committed proposal")
            gate.open(); let outcome = try await first.value
            try expect(outcome.receipt.reminderState == .scheduled && repo.tasks(for: "A").count == 1, "The one original operation may finish successfully")
        }
        try await run("coordinator-reminder-failure-keeps-task-and-does-not-retry", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            var notificationCalls = 0
            let operation: AssistantTaskToolReminderOperation = { _, guardValue in notificationCalls += 1; try guardValue.validate(); throw AssistantTaskToolError.unavailable }
            let outcome = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: {}, scheduleReminder: operation)
            try expect(outcome.task != nil && outcome.receipt.reminderState == .failed && outcome.reminderFailureMessage != nil, "Notification failure keeps the real task and reports failure")
            let bytes = try Data(contentsOf: url)
            _ = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: {}, scheduleReminder: operation)
            try expect(notificationCalls == 1 && repo.tasks(for: "A").count == 1 && (try Data(contentsOf: url)) == bytes, "Approval replay cannot retry a failed notification or create another task")
        }
        try await run("coordinator-missing-reminder-operation-is-failed-not-scheduled", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            let outcome = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: {})
            try expect(outcome.receipt.reminderState == .failed && outcome.task?.reminderEnabled == false && outcome.reminderFailureMessage != nil, "Missing implementation cannot pretend notification scheduling succeeded")
        }
        try await run("coordinator-reminder-callback-without-persisted-task-update-is-not-success", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            let outcome = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: {}, scheduleReminder: { _, guardValue in try guardValue.validate() })
            try expect(outcome.receipt.reminderState == .failed && outcome.task?.reminderEnabled == false && outcome.reminderFailureMessage != nil, "A returned callback cannot claim success unless existing task reminder consent was actually persisted")
        }
        try await run("coordinator-source-change-after-save-keeps-pending-and-stops-metadata", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo), auth = TaskExecutionAuthorization()
            var committedBytes: Data?
            let outcome = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: { try auth.validate() }, scheduleReminder: { _, guardValue in
                committedBytes = try Data(contentsOf: url); auth.allowed = false; try guardValue.validate()
            })
            try expect(outcome.receipt.reminderState == .pending && outcome.reminderFailureMessage != nil && repo.tasks(for: "A").count == 1, "Owner/source invalidation cannot undo the real task or claim notification success")
            try expect(try Data(contentsOf: url) == committedBytes, "Inactive owner must receive no subsequent metadata write")
            try rejects { _ = try coordinator.claimContinuation(proposal: p, validate: {}) }
        }
        try await run("coordinator-cancelled-after-save-keeps-task-with-uncertain-reminder", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            let operation = Task { @MainActor in
                try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: {}, scheduleReminder: { _, guardValue in
                    withUnsafeCurrentTask { $0?.cancel() }; try guardValue.validate()
                })
            }
            let outcome = try await operation.value
            try expect(outcome.receipt.reminderState == .pending && outcome.reminderFailureMessage != nil && outcome.task?.reminderEnabled == false, "Cancellation after commit preserves a task and unconfirmed reminder")
            try expect(try AssistantLocalRepository(fileURL: url).taskToolReceipt(proposalId: p.id, ownerId: "A")?.reminderState == .pending, "Cancellation must not rewrite the durable receipt as scheduled")
        }
        try await run("coordinator-owner-data-deletion-during-reminder-does-not-resurrect", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo), auth = TaskExecutionAuthorization()
            var deletedBytes: Data?
            let outcome = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: { try auth.validate() }, scheduleReminder: { _, guardValue in
                try guardValue.validate(); try expect(repo.deleteUserData(for: "A"), "Account data deletion is a real repository operation")
                auth.allowed = false; deletedBytes = try Data(contentsOf: url); try guardValue.validate()
            })
            try expect(outcome.task == nil && repo.tasks(for: "A").isEmpty && (try repo.taskToolReceipt(proposalId: p.id, ownerId: "A")) == nil, "Invalidated account data must stay deleted")
            try expect(try Data(contentsOf: url) == deletedBytes, "No post-deletion metadata may resurrect the old account")
        }
        try await run("coordinator-source-change-after-real-reminder-update-stays-honest", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo), auth = TaskExecutionAuthorization()
            var afterScheduling: Data?
            let outcome = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: { try auth.validate() }, scheduleReminder: { saved, guardValue in
                try guardValue.validate(); var changed = saved; changed.reminderEnabled = true
                try expect(repo.updateTask(changed), "Fixture reminder was persisted before invalidation")
                afterScheduling = try Data(contentsOf: url); auth.allowed = false
            })
            try expect(outcome.task?.reminderEnabled == true && outcome.receipt.reminderState == .pending && outcome.reminderFailureMessage != nil, "A completed reminder side effect plus source change is uncertain, never falsely failed or scheduled")
            try expect(try Data(contentsOf: url) == afterScheduling, "No old-owner receipt write occurs after invalidation")
        }
        try await run("coordinator-reminder-metadata-write-failure-remains-pending", root: root) { url in
            let p = try proposal(), manager = TaskExecutionFileManager(), repo = AssistantLocalRepository(fileURL: url, fileManager: manager), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            defer { manager.rejectsWrites = false }
            let outcome = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: {}, scheduleReminder: { saved, guardValue in
                try guardValue.validate(); var changed = saved; changed.reminderEnabled = true
                try expect(repo.updateTask(changed), "Fixture reminder side effect must be real persisted state")
                manager.rejectsWrites = true
            })
            let reloaded = AssistantLocalRepository(fileURL: url)
            try expect(outcome.receipt.reminderState == .pending && outcome.reminderFailureMessage != nil && reloaded.tasks(for: "A")[0].reminderEnabled == true, "Failed metadata persistence cannot claim confirmed success or erase the task")
            try expect(try reloaded.taskToolReceipt(proposalId: p.id, ownerId: "A")?.reminderState == .pending, "Durable pending remains the truthful result")
        }
        try await run("coordinator-decline-is-durable-and-irreversible", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            let declined = try coordinator.decline(proposal: p, validate: {}), bytes = try Data(contentsOf: url)
            try expect(declined.decision == .declined && repo.tasks(for: "A").isEmpty, "Declining never creates a task")
            _ = try coordinator.decline(proposal: p, validate: {})
            try await rejectsAsync { _ = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: false, validate: {}) }
            try expect(try Data(contentsOf: url) == bytes, "Duplicate decline and later approval cannot rewrite the decision")
        }
        try await run("coordinator-output-reflects-edits-deletion-and-real-reminder-state", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            try rejects { _ = try coordinator.outputJSON(for: p) }
            _ = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: false, validate: {})
            var stored = repo.tasks(for: "A")[0]; stored.title = "Later user edit"; stored.status = .completed
            try expect(repo.updateTask(stored), "Later user edit persists")
            let result = try JSONSerialization.jsonObject(with: Data(coordinator.outputJSON(for: p).utf8)) as! [String: Any]
            try expect(result["title"] as? String == "Later user edit" && result["task_status"] as? String == "completed" && result["reminder_status"] as? String == "notRequested", "Tool output must describe real current local state")
            try expect(repo.deleteTask(id: p.taskId, userId: "A"), "Task deletion persists")
            let deleted = try JSONSerialization.jsonObject(with: Data(coordinator.outputJSON(for: p).utf8)) as! [String: Any]
            try expect(deleted["status"] as? String == "task_no_longer_available" && repo.tasks(for: "A").isEmpty, "Deleted task must not be recreated or reported as available")
        }
        try await run("coordinator-continuation-claim-survives-restart-and-chat-deletion", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            _ = try coordinator.decline(proposal: p, validate: {})
            let claim = try coordinator.claimContinuation(proposal: p, validate: {})
            try expect(claim.continuationAttemptId != nil, "An explicit continuation must durably claim before sending")
            let chat = url.deletingLastPathComponent().appendingPathComponent("chat.json")
            try Data("temporary chat rows".utf8).write(to: chat); try FileManager.default.removeItem(at: chat)
            let reloaded = AssistantTaskToolExecutionCoordinator(repository: AssistantLocalRepository(fileURL: url))
            let bytes = try Data(contentsOf: url)
            try rejects { _ = try reloaded.claimContinuation(proposal: p, validate: {}) }
            try expect(try Data(contentsOf: url) == bytes, "Deleting chat rows or restarting cannot replay the continuation")
        }
        try await run("coordinator-failed-continuation-claim-issues-no-send-intent", root: root) { url in
            let p = try proposal(), manager = TaskExecutionFileManager(), repo = AssistantLocalRepository(fileURL: url, fileManager: manager), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            _ = try coordinator.decline(proposal: p, validate: {}); let bytes = try Data(contentsOf: url)
            manager.rejectsWrites = true; var sendIntents = 0
            try rejects { _ = try coordinator.claimContinuation(proposal: p, validate: {}); sendIntents += 1 }
            try expect(sendIntents == 0 && (try Data(contentsOf: url)) == bytes && (try coordinator.receipt(for: p))?.continuationAttemptId == nil, "Without a persisted claim the caller receives no intent and must start zero HTTP")
        }
    }
    static func outputSemanticsTests(root: URL) async throws {
        try await run("output-saved-reminder-off-separates-current-preference-from-creation", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            _ = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: false, validate: {})
            let value = try JSONSerialization.jsonObject(with: Data(coordinator.outputJSON(for: p).utf8)) as! [String: Any]
            try expect(value["status"] as? String == "task_saved" && value["reminder_status"] as? String == "notRequested"
                && value["reminder_status_scope"] as? String == "creation" && value["current_reminder_enabled"] as? Bool == false,
                "A saved task with reminders off needs both historical receipt scope and the actual current boolean preference")
            try expect(repo.tasks(for: "A")[0].reminderEnabled == false, "Reading output must not enable the preference")
        }
        try await run("output-creation-scheduled-then-user-off-reports-current-false", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            var simulatedReminderUpdates = 0
            let outcome = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: true, validate: {},
                scheduleReminder: { saved, guardValue in
                    try guardValue.validate()
                    var enabled = saved; enabled.reminderEnabled = true
                    try expect(repo.updateTask(enabled), "The isolated reminder callback must update the real stored preference")
                    simulatedReminderUpdates += 1
                })
            try expect(outcome.receipt.reminderState == .scheduled && simulatedReminderUpdates == 1,
                "The fixture must contain a real creation receipt from the injected reminder callback, without OS notification calls")
            var current = repo.tasks(for: "A")[0]; current.reminderEnabled = false
            try expect(repo.updateTask(current), "A later user edit must really disable the stored preference")
            let value = try JSONSerialization.jsonObject(with: Data(coordinator.outputJSON(for: p).utf8)) as! [String: Any]
            try expect(value["reminder_status"] as? String == "scheduled" && value["reminder_status_scope"] as? String == "creation"
                && value["current_reminder_enabled"] as? Bool == false,
                "A creation-time scheduled receipt must not conceal that the user subsequently turned the preference off")
            try expect(try coordinator.receipt(for: p) == outcome.receipt && simulatedReminderUpdates == 1,
                "Output may neither rewrite history nor reschedule the reminder")
        }
        try await run("output-creation-not-requested-then-user-on-reports-current-true", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            let outcome = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: false, validate: {})
            var current = repo.tasks(for: "A")[0]; current.reminderEnabled = true
            try expect(repo.updateTask(current), "A later explicit preference edit must persist without any scheduling API")
            let value = try JSONSerialization.jsonObject(with: Data(coordinator.outputJSON(for: p).utf8)) as! [String: Any]
            try expect(value["reminder_status"] as? String == "notRequested" && value["reminder_status_scope"] as? String == "creation"
                && value["current_reminder_enabled"] as? Bool == true,
                "A true current preference does not change the historical creation receipt or prove notification delivery")
            try expect(try coordinator.receipt(for: p) == outcome.receipt, "Reading a changed preference must leave the receipt untouched")
        }
        try await run("output-deleted-task-reports-null-current-preference", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            let outcome = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: false, validate: {})
            try expect(repo.deleteTask(id: p.taskId, userId: "A"), "The task must actually be deleted before output is read")
            let value = try JSONSerialization.jsonObject(with: Data(coordinator.outputJSON(for: p).utf8)) as! [String: Any]
            try expect(value["status"] as? String == "task_no_longer_available" && value["current_reminder_enabled"] is NSNull
                && value["reminder_status"] as? String == "notRequested" && value["reminder_status_scope"] as? String == "creation",
                "An absent task has an unknown current preference, not a guessed false value")
            try expect(repo.tasks(for: "A").isEmpty && (try coordinator.receipt(for: p)) == outcome.receipt,
                "Reading deleted-task output cannot resurrect the task or change its retained decision")
        }
        try await run("output-declined-proposal-reports-null-current-preference", root: root) { url in
            let p = try proposal(), repo = AssistantLocalRepository(fileURL: url), coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            let declined = try coordinator.decline(proposal: p, validate: {})
            let value = try JSONSerialization.jsonObject(with: Data(coordinator.outputJSON(for: p).utf8)) as! [String: Any]
            try expect(value["status"] as? String == "declined" && value["current_reminder_enabled"] is NSNull
                && value["reminder_status_scope"] as? String == "creation" && value["reminder_status"] as? String == "notRequested",
                "Declining never creates a task whose current preference could be reported")
            try expect(repo.tasks(for: "A").isEmpty && (try coordinator.receipt(for: p)) == declined,
                "Declined output must remain a read-only account-scoped result")
        }
        try await run("output-read-preserves-repository-receipt-and-claimed-attempt-bytes", root: root) { url in
            let manager = TaskExecutionFileManager(), p = try proposal(), repo = AssistantLocalRepository(fileURL: url, fileManager: manager)
            let coordinator = AssistantTaskToolExecutionCoordinator(repository: repo)
            _ = try await coordinator.approve(proposal: p, editedTask: task(p), enableReminder: false, validate: {})
            let claimed = try coordinator.claimContinuation(proposal: p, validate: {})
            let bytes = try Data(contentsOf: url), tasks = repo.tasks(for: "A"), writes = manager.directoryWriteAttempts
            for _ in 0..<3 {
                let value = try JSONSerialization.jsonObject(with: Data(coordinator.outputJSON(for: p).utf8)) as! [String: Any]
                try expect(value["current_reminder_enabled"] as? Bool == false && value["reminder_status_scope"] as? String == "creation",
                    "Repeated reads must still derive the real stored preference")
            }
            let reloadedRepo = AssistantLocalRepository(fileURL: url), reloaded = AssistantTaskToolExecutionCoordinator(repository: reloadedRepo)
            _ = try reloaded.outputJSON(for: p)
            try expect(try Data(contentsOf: url) == bytes && manager.directoryWriteAttempts == writes && repo.tasks(for: "A") == tasks,
                "Output reads must not issue persistence writes or change any task bytes")
            try expect(try coordinator.receipt(for: p) == claimed && reloaded.receipt(for: p) == claimed
                && reloadedRepo.taskToolReceipt(proposalId: p.id, ownerId: "A")?.continuationAttemptId == claimed.continuationAttemptId,
                "Output cannot reset the claim, advance revision, or rewrite the committed receipt")
        }
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caobao-task-execution-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await domainTests(root: root)
        try await repositoryTests(root: root)
        try await coordinatorTests(root: root)
        try await outputSemanticsTests(root: root)
        if !failures.isEmpty { throw TaskExecutionFailure(description: failures.joined(separator: "\n")) }
        print("All \(suites) task-tool execution suites passed using temporary real disk stores; no external network or notifications.")
    }
}
