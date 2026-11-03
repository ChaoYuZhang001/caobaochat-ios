import Foundation

private struct RestoreTestFailure: Error, CustomStringConvertible { let description: String }

private final class RestoreRejectingFileManager: FileManager, @unchecked Sendable {
    var rejectsWrites = false
    var beforeDirectory: (() -> Void)?
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if rejectsWrites { throw RestoreTestFailure(description: "Injected atomic write failure") }
        beforeDirectory?()
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

private final class RestoreConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [AssistantRepositoryRestoreResult] = []
    private(set) var failures = 0
    func append(_ value: AssistantRepositoryRestoreResult) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func fail() { lock.lock(); defer { lock.unlock() }; failures += 1 }
}

@main
private enum AssistantRepositoryRestoreTests {
    private static let date = Date(timeIntervalSince1970: 1_793_232_000)
    private static var suites = 0

    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw RestoreTestFailure(description: message) }
    }
    @discardableResult
    private static func rejected(_ operation: () throws -> Void) throws -> Error {
        do { try operation() } catch { return error }
        throw RestoreTestFailure(description: "Expected restoration rejection")
    }
    private static func digest(_ value: Int) -> String { String(repeating: "0", count: 60) + String(format: "%04x", value) }
    private static func memory(_ id: String = "memory-1", owner: String = "A", text: String = "Prefers tea",
                               consent: String = "confirmed", status: AssistantMemoryStatus = .active,
                               createdAt: Date = date, updatedAt: Date = date) -> AssistantMemory {
        AssistantMemory(id: id, userId: owner, category: .preference, text: text, sourceMessageId: "message-1",
            consent: consent, status: status, createdAt: createdAt, updatedAt: updatedAt)
    }
    private static func task(_ id: String = "task-1", owner: String = "A", title: String = "Review the plan") -> AssistantTask {
        AssistantTask(id: id, userId: owner, title: title, instructions: "Ask me before acting", dueAt: date.addingTimeInterval(3_600),
            timeZone: "UTC", recurrenceRule: nil, requiresApproval: false, status: .active, createdAt: date, updatedAt: date,
            reminderEnabled: true, sourceMessageId: "message-1")
    }
    private static func json(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw RestoreTestFailure(description: "Expected repository object")
        }
        return value
    }
    private static func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: url, options: .atomic)
    }
    private static func run(_ name: String, root: URL, _ body: (URL) throws -> Void) throws {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try body(directory.appendingPathComponent("store.json"))
        suites += 1
        print("PASS \(name)")
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caobao-repository-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try run("result-defaults-and-codable", root: root) { _ in
            let result = AssistantRepositoryRestoreResult()
            try expect(result.insertedMemories == 0 && result.skippedMemories == 0 && result.conflictingMemories == 0
                && result.insertedTasks == 0 && result.skippedTasks == 0 && result.conflictingTasks == 0 && !result.alreadyApplied,
                "Every result field must default to zero or false")
            try expect(try JSONDecoder().decode(AssistantRepositoryRestoreResult.self, from: JSONEncoder().encode(result)) == result,
                "The result contract must round-trip independently")
        }
        try run("insert-normalizes-memory-task-and-reloads", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            var importedTask = task(); importedTask.recurrenceRule = "freq=daily"; importedTask.recurrenceStartsAt = date.addingTimeInterval(0.125)
            let result = try repository.restoreBackup(memories: [memory()], tasks: [importedTask], backupDigest: digest(1), for: "A")
            try expect(result == AssistantRepositoryRestoreResult(insertedMemories: 1, insertedTasks: 1), "Insert counts must describe the actual atomic write")
            let restored = AssistantLocalRepository(fileURL: url), snapshot = try restored.exportSnapshot(for: "A")
            try expect(snapshot.memories.count == 1 && snapshot.memories[0].consent == "unconfirmed"
                && !AssistantMemoryAuthorizationPolicy.allowsUse(of: snapshot.memories[0]), "Imported explicit consent must not authorize memory use")
            try expect(snapshot.memories[0].sourceMessageId == "message-1" && snapshot.tasks[0].sourceMessageId == "message-1", "Safe source metadata must survive")
            try expect(snapshot.tasks.count == 1 && snapshot.tasks[0].reminderEnabled == false && snapshot.tasks[0].requiresApproval
                && snapshot.tasks[0].recurrenceRule == "FREQ=DAILY" && snapshot.tasks[0].recurrenceStartsAt == importedTask.recurrenceStartsAt,
                "Imported recurring tasks retain metadata without granting reminder or execution authority")
        }
        try run("imported-tombstone-scrubs-deleted-content", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            _ = try repository.restoreBackup(memories: [memory(text: "Deleted private text", status: .deleted)], tasks: [], backupDigest: digest(1), for: "A")
            let value = try AssistantLocalRepository(fileURL: url).exportSnapshot(for: "A").memories
            try expect(value.count == 1 && value[0].status == .deleted && value[0].text.isEmpty && value[0].sourceMessageId == nil,
                "A restored tombstone must never retain the deleted body or source")
            try expect(!String(decoding: Data(contentsOf: url), as: UTF8.self).contains("Deleted private text"), "Scrubbed text must not reach disk")
        }
        try run("repeat-after-reload-is-zero-count-and-byte-stable", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            _ = try repository.restoreBackup(memories: [memory()], tasks: [task()], backupDigest: digest(1), for: "A")
            let before = try Data(contentsOf: url), reloaded = AssistantLocalRepository(fileURL: url)
            let result = try reloaded.restoreBackup(memories: [memory()], tasks: [task()], backupDigest: digest(1), for: "A")
            try expect(result == AssistantRepositoryRestoreResult(alreadyApplied: true), "A durable marker must return no new counts")
            try expect(try Data(contentsOf: url) == before, "An already-applied retry must not rewrite the store")
        }
        try run("normalized-equal-skips-preserve-local-authorization", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            repository.addMemory(memory()); repository.addTask(task())
            let originalMemory = repository.memories(for: "A")[0], originalTask = repository.tasks(for: "A")[0]
            let result = try repository.restoreBackup(memories: [memory()], tasks: [task()], backupDigest: digest(1), for: "A")
            try expect(result == AssistantRepositoryRestoreResult(skippedMemories: 1, skippedTasks: 1), "Normalized identity must skip existing equivalent business records")
            try expect(repository.memories(for: "A")[0] == originalMemory && repository.tasks(for: "A")[0] == originalTask,
                "Import may not revoke, replace or expand current record-level choices")
        }
        try run("changed-content-conflicts-keep-local", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            repository.addMemory(memory()); repository.addTask(task())
            let result = try repository.restoreBackup(memories: [memory(text: "Different preference")], tasks: [task(title: "Different plan")], backupDigest: digest(1), for: "A")
            try expect(result == AssistantRepositoryRestoreResult(conflictingMemories: 1, conflictingTasks: 1), "Changed records must be reported as conflicts")
            try expect(repository.memories(for: "A")[0].text == "Prefers tea" && repository.tasks(for: "A")[0].title == "Review the plan", "Local content must win conflicts")
        }
        try run("existing-memory-tombstone-never-resurrects", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url); repository.addMemory(memory())
            try expect(repository.deleteMemory(id: "memory-1", userId: "A"), "Fixture tombstone must persist")
            let before = try repository.exportSnapshot(for: "A").memories
            let result = try repository.restoreBackup(memories: [memory()], tasks: [], backupDigest: digest(1), for: "A")
            try expect(result.conflictingMemories == 1 && repository.memories(for: "A").isEmpty
                && (try repository.exportSnapshot(for: "A").memories) == before, "A backup active record cannot defeat the current deletion tombstone")
        }
        try run("incoming-tombstone-cannot-delete-live-local-record", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url); repository.addMemory(memory())
            let result = try repository.restoreBackup(memories: [memory(status: .deleted)], tasks: [], backupDigest: digest(1), for: "A")
            try expect(result.conflictingMemories == 1 && repository.memories(for: "A").count == 1, "Insert-only import cannot turn a local active memory into a deletion")
        }
        try run("unicode-content-and-id-aliases-are-conflicts", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            repository.addMemory(memory("caf\u{00E9}", text: "caf\u{00E9}"))
            let first = try repository.restoreBackup(memories: [memory("cafe\u{0301}", text: "caf\u{00E9}")], tasks: [], backupDigest: digest(1), for: "A")
            let second = try repository.restoreBackup(memories: [memory("caf\u{00E9}", text: "cafe\u{0301}")], tasks: [], backupDigest: digest(2), for: "A")
            try expect(first.conflictingMemories == 1 && second.conflictingMemories == 1 && repository.memories(for: "A").count == 1,
                "Canonical String equivalence cannot label byte-different IDs or content as unchanged")
        }
        try run("foreign-owner-record-rejects-whole-batch", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url); repository.addMemory(memory("local"))
            let before = try Data(contentsOf: url)
            try rejected { _ = try repository.restoreBackup(memories: [memory("new")], tasks: [task(owner: "B")], backupDigest: digest(1), for: "A") }
            try expect(try Data(contentsOf: url) == before && repository.memories(for: "A").count == 1 && repository.tasks(for: "B").isEmpty,
                "A late invalid record cannot partially commit earlier records or a marker")
        }
        try run("canonical-owner-alias-rejects-legacy-bucket-collision", root: root) { url in
            let ownerA = "caf\u{00E9}", ownerB = "cafe\u{0301}"
            let repository = AssistantLocalRepository(fileURL: url); repository.addMemory(memory(owner: ownerA))
            let before = try Data(contentsOf: url)
            try rejected { _ = try repository.restoreBackup(memories: [memory("new", owner: ownerB)], tasks: [], backupDigest: digest(1), for: ownerB) }
            try expect(try Data(contentsOf: url) == before && repository.memories(for: ownerA).count == 1, "Legacy canonical owner collision must fail before any write")
            _ = try repository.restoreBackup(memories: [memory("new", owner: ownerA)], tasks: [], backupDigest: digest(1), for: ownerA)
            try expect(repository.memories(for: ownerA).count == 2, "The identical raw owner remains usable")
        }
        try run("empty-import-markers-use-byte-exact-owner-keys", root: root) { url in
            let owners = ["caf\u{00E9}", "cafe\u{0301}"]
            let repository = AssistantLocalRepository(fileURL: url)
            for owner in owners { _ = try repository.restoreBackup(memories: [], tasks: [], backupDigest: digest(1), for: owner) }
            let markers = try json(url)["restoreBackupDigests"] as? [String: [String]]
            try expect(markers?.count == 2 && owners.allSatisfy { markers?[Data($0.utf8).base64EncodedString()] == [digest(1)] }, "Marker ownership must use raw UTF-8 Base64 instead of normalized String keys")
        }
        try run("duplicate-and-canonical-alias-input-ids-reject", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            for values in [[memory(), memory()], [memory("caf\u{00E9}"), memory("cafe\u{0301}")]] {
                try rejected { _ = try repository.restoreBackup(memories: values, tasks: [], backupDigest: digest(1), for: "A") }
            }
            try rejected { _ = try repository.restoreBackup(memories: [], tasks: [task(), task()], backupDigest: digest(1), for: "A") }
            try expect(!FileManager.default.fileExists(atPath: url.path), "Ambiguous input must not create a repository or marker")
        }
        try run("strict-lowercase-digest-and-bounded-identities", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            for value in ["", "a", String(repeating: "A", count: 64), String(repeating: "0", count: 63), String(repeating: "0", count: 65), String(repeating: "g", count: 64)] {
                try rejected { _ = try repository.restoreBackup(memories: [], tasks: [], backupDigest: value, for: "A") }
            }
            for owner in ["", " ", String(repeating: "a", count: 1_025), "owner\n"] {
                try rejected { _ = try repository.restoreBackup(memories: [], tasks: [], backupDigest: digest(1), for: owner) }
            }
            for id in ["", " ", String(repeating: "a", count: 1_025), "record\0"] {
                try rejected { _ = try repository.restoreBackup(memories: [memory(id)], tasks: [], backupDigest: digest(1), for: "A") }
            }
            try expect(!FileManager.default.fileExists(atPath: url.path), "Invalid identities and digests must fail before persistence")
        }
        try run("invalid-business-and-activation-dates-reject", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            for value in [Double.nan, Double.infinity, -Double.infinity, 253_402_300_801, Date.distantPast.timeIntervalSince1970 - 1] {
                let badDate = Date(timeIntervalSince1970: value)
                try rejected { _ = try repository.restoreBackup(memories: [memory(createdAt: badDate)], tasks: [], backupDigest: digest(1), for: "A") }
                try rejected { _ = try repository.restoreBackup(memories: [memory(updatedAt: badDate)], tasks: [], backupDigest: digest(1), for: "A") }
                var badTask = task(); badTask.dueAt = badDate
                try rejected { _ = try repository.restoreBackup(memories: [], tasks: [badTask], backupDigest: digest(1), for: "A") }
                badTask = task(); badTask.recurrenceStartsAt = badDate
                try rejected { _ = try repository.restoreBackup(memories: [], tasks: [badTask], backupDigest: digest(1), for: "A") }
            }
            try expect(!FileManager.default.fileExists(atPath: url.path), "Nonfinite and unsupported dates must never reach the encoder")
        }
        try run("workspace-and-recurrence-limits-reject", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            for value in [" ", String(repeating: "x", count: 20_001)] {
                try rejected { _ = try repository.restoreBackup(memories: [memory(text: value)], tasks: [], backupDigest: digest(1), for: "A") }
            }
            var badTasks: [AssistantTask] = [task(title: " "), task(title: String(repeating: "x", count: 201))]
            var value = task(); value.instructions = String(repeating: "x", count: 20_001); badTasks.append(value)
            value = task(); value.timeZone = "Not/AZone"; badTasks.append(value)
            value = task(); value.recurrenceRule = "FREQ=HOURLY"; badTasks.append(value)
            value = task(); value.recurrenceRule = "FREQ=DAILY"; value.dueAt = nil; badTasks.append(value)
            value = task(); value.sourceMessageId = String(repeating: "x", count: 1_025); badTasks.append(value)
            for task in badTasks { try rejected { _ = try repository.restoreBackup(memories: [], tasks: [task], backupDigest: digest(1), for: "A") } }
            try expect(!FileManager.default.fileExists(atPath: url.path), "Existing workspace limits must be enforced again by the repository")
        }
        try run("record-count-and-total-string-budget-reject", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            try rejected { _ = try repository.restoreBackup(memories: Array(repeating: memory(), count: 10_001), tasks: [], backupDigest: digest(1), for: "A") }
            try rejected { _ = try repository.restoreBackup(memories: [], tasks: Array(repeating: task(), count: 10_001), backupDigest: digest(1), for: "A") }
            let oversized = (0..<1_800).map { memory("memory-\($0)", text: String(repeating: "x", count: 20_000)) }
            try rejected { _ = try repository.restoreBackup(memories: oversized, tasks: [], backupDigest: digest(1), for: "A") }
            try expect(!FileManager.default.fileExists(atPath: url.path), "Oversized imports cannot create partial records or markers")
        }
        try run("marker-cap-rejects-without-eviction-or-record-write", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            for value in 0..<256 { _ = try repository.restoreBackup(memories: [], tasks: [], backupDigest: digest(value), for: "A") }
            let before = try Data(contentsOf: url)
            let error = try rejected { _ = try repository.restoreBackup(memories: [memory()], tasks: [task()], backupDigest: digest(256), for: "A") }
            guard case AssistantRepositoryError.restoreMarkerLimitReached = error else { throw RestoreTestFailure(description: "Marker capacity needs an explicit typed failure") }
            try expect(try Data(contentsOf: url) == before && repository.memories(for: "A").isEmpty && repository.tasks(for: "A").isEmpty, "Capacity cannot evict markers or partially merge records")
            let repeated = try AssistantLocalRepository(fileURL: url).restoreBackup(memories: [], tasks: [], backupDigest: digest(0), for: "A")
            try expect(repeated.alreadyApplied, "Even at capacity an existing marker remains retryable")
        }
        try run("normal-deletes-retain-marker-authorized-cleanup-removes-it", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            _ = try repository.restoreBackup(memories: [memory()], tasks: [task()], backupDigest: digest(1), for: "A")
            try expect(repository.deleteMemory(id: "memory-1", userId: "A") && repository.deleteTask(id: "task-1", userId: "A"), "Normal deletes must succeed")
            let retry = try AssistantLocalRepository(fileURL: url).restoreBackup(memories: [memory()], tasks: [task()], backupDigest: digest(1), for: "A")
            try expect(retry.alreadyApplied && repository.tasks(for: "A").isEmpty, "Normal deletion must not permit restoration replay")
            try expect(repository.deleteUserData(for: "A"), "Authorized owner cleanup must succeed")
            let fresh = try AssistantLocalRepository(fileURL: url).restoreBackup(memories: [memory()], tasks: [task()], backupDigest: digest(1), for: "A")
            try expect(fresh.insertedMemories == 1 && fresh.insertedTasks == 1 && !fresh.alreadyApplied, "Authorized cleanup alone removes owner restore markers")
        }
        try run("old-store-missing-marker-field-remains-readable", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url); repository.addMemory(memory("local"))
            var object = try json(url); object.removeValue(forKey: "restoreBackupDigests"); try write(object, to: url)
            let legacy = AssistantLocalRepository(fileURL: url)
            let result = try legacy.restoreBackup(memories: [memory("new")], tasks: [], backupDigest: digest(1), for: "A")
            try expect(result.insertedMemories == 1 && legacy.memories(for: "A").count == 2, "The additive field must not invalidate an older store")
        }
        try run("null-and-malformed-marker-metadata-fail-closed", root: root) { url in
            let seed = AssistantLocalRepository(fileURL: url); seed.addMemory(memory("local"))
            let baseline = try json(url), ownerKey = Data("A".utf8).base64EncodedString()
            let malformed: [Any] = [NSNull(), [], ["A": [digest(1)]], [ownerKey: NSNull()], [ownerKey: ["bad"]],
                [ownerKey: [digest(1), digest(1)]], [ownerKey: (0..<257).map(digest)]]
            for field in malformed {
                var object = baseline; object["restoreBackupDigests"] = field; try write(object, to: url)
                let before = try Data(contentsOf: url), invalid = AssistantLocalRepository(fileURL: url)
                try expect(invalid.lastError != nil, "Malformed present marker metadata cannot become an empty successful load")
                try rejected { _ = try invalid.restoreBackup(memories: [memory("new")], tasks: [], backupDigest: digest(2), for: "A") }
                try expect(try Data(contentsOf: url) == before, "A failed store load must preserve the exact original file")
            }
        }
        try run("atomic-write-failure-preserves-records-and-no-marker", root: root) { url in
            let manager = RestoreRejectingFileManager(), repository = AssistantLocalRepository(fileURL: url, fileManager: manager)
            repository.addMemory(memory("local")); let before = try Data(contentsOf: url)
            manager.rejectsWrites = true
            try rejected { _ = try repository.restoreBackup(memories: [memory("new")], tasks: [task()], backupDigest: digest(1), for: "A") }
            try expect(try Data(contentsOf: url) == before && repository.memories(for: "A").count == 1 && repository.tasks(for: "A").isEmpty,
                "A failed persistence must not publish candidate records in memory or disk")
            manager.rejectsWrites = false
            let result = try repository.restoreBackup(memories: [memory("new")], tasks: [task()], backupDigest: digest(1), for: "A")
            try expect(!result.alreadyApplied && result.insertedMemories == 1 && result.insertedTasks == 1, "A failed atomic write must not leave an applied marker")
            try expect(try AssistantLocalRepository(fileURL: url).exportSnapshot(for: "A").memories.count == 2, "The successful retry must survive reload")
        }
        try run("caller-commit-guard-rejection-preserves-file-and-marker", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url); repository.addMemory(memory("local"))
            let before = try Data(contentsOf: url)
            var validations = 0
            let error = try rejected {
                _ = try repository.restoreBackup(memories: [memory("new")], tasks: [task()], backupDigest: digest(1), for: "A", validateBeforePersist: {
                    validations += 1
                    throw RestoreTestFailure(description: "Fixture owner permit expired")
                })
            }
            try expect((error as? RestoreTestFailure)?.description == "Fixture owner permit expired" && validations == 1,
                "The exact caller guard error must propagate without becoming a persistence failure")
            try expect(try Data(contentsOf: url) == before && repository.memories(for: "A").count == 1 && repository.tasks(for: "A").isEmpty,
                "Guard rejection must publish no record or marker in memory or disk")
            let retry = try repository.restoreBackup(memories: [memory("new")], tasks: [task()], backupDigest: digest(1), for: "A")
            try expect(!retry.alreadyApplied && retry.insertedMemories == 1 && retry.insertedTasks == 1, "A failed caller permit must leave the backup retryable")
        }
        try run("late-permit-invalidation-before-data-write-is-rechecked", root: root) { url in
            let manager = RestoreRejectingFileManager(), repository = AssistantLocalRepository(fileURL: url, fileManager: manager)
            repository.addMemory(memory("local")); let before = try Data(contentsOf: url)
            var isCurrent = true, validations = 0
            manager.beforeDirectory = { isCurrent = false }
            let error = try rejected {
                _ = try repository.restoreBackup(memories: [memory("new")], tasks: [task()], backupDigest: digest(1), for: "A", validateBeforePersist: {
                    validations += 1
                    if !isCurrent { throw RestoreTestFailure(description: "Fixture final permit expired") }
                })
            }
            try expect((error as? RestoreTestFailure)?.description == "Fixture final permit expired" && validations == 2,
                "A source invalidated after encoding/preflight must be rejected at the final write boundary")
            try expect(try Data(contentsOf: url) == before && repository.memories(for: "A").count == 1 && repository.tasks(for: "A").isEmpty,
                "The final guard cannot leave a record or an applied marker")
            manager.beforeDirectory = nil
            let retry = try repository.restoreBackup(memories: [memory("new")], tasks: [task()], backupDigest: digest(1), for: "A")
            try expect(!retry.alreadyApplied, "Late invalidation must preserve a real retry")
        }
        try run("saved-tool-receipt-and-continuation-prevent-task-resurrection", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url), suffix = digest(42)
            var original = task("tool-task-" + suffix); original.requiresApproval = true; original.reminderEnabled = false
            let receipt = AssistantTaskToolReceipt(ownerId: "A", proposalId: "proposal-" + suffix, taskId: original.id,
                decision: .saved, reminderState: .notRequested, committedAt: date, revision: 1)
            _ = try repository.commitTaskToolTask(original, receipt: receipt)
            let claimed = try repository.claimTaskToolContinuation(proposalId: receipt.proposalId, ownerId: "A", expectedRevision: 1, attemptId: UUID().uuidString)
            try expect(repository.deleteTask(id: original.id, userId: "A"), "The approved task fixture must really be deleted")
            let result = try repository.restoreBackup(memories: [], tasks: [original], backupDigest: digest(1), for: "A")
            try expect(result.conflictingTasks == 1 && repository.tasks(for: "A").isEmpty, "A retained saved receipt protects even a missing task ID")
            try expect(try repository.taskToolReceipt(proposalId: receipt.proposalId, ownerId: "A") == claimed
                && AssistantLocalRepository(fileURL: url).taskToolReceipt(proposalId: receipt.proposalId, ownerId: "A") == claimed,
                "Restoration cannot erase or replace the durable tool decision or continuation claim")
        }
        try run("owner-preferences-and-other-owner-data-stay-unchanged", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            repository.setMemoryEnabled(false, for: "A")
            try expect(repository.setMemoryCategoryEnabled(false, category: .importantDate, for: "A"), "Category fixture must persist")
            let quiet = AssistantQuietHours(enabled: true, startMinute: 1_320, endMinute: 480, timeZoneIdentifier: "UTC")
            try expect(repository.setQuietHours(quiet, for: "A"), "Quiet-hours fixture must persist")
            repository.addMemory(memory(owner: "B")); repository.addTask(task(owner: "B"))
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let beforeB = try encoder.encode(repository.exportSnapshot(for: "B"))
            _ = try repository.restoreBackup(memories: [memory()], tasks: [task()], backupDigest: digest(1), for: "A")
            let snapshot = try repository.exportSnapshot(for: "A")
            try expect(!snapshot.memoryEnabled && snapshot.excludedMemoryCategories == [.importantDate] && snapshot.quietHours == quiet,
                "Restoration may not change global/category memory or quiet-hours preferences")
            try expect(try encoder.encode(repository.exportSnapshot(for: "B")) == beforeB, "Other owners must remain byte-equivalent value snapshots")
        }
        try run("fractional-business-dates-compare-stably-after-reload", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url), fractional = date.addingTimeInterval(0.875)
            let imported = memory(createdAt: fractional, updatedAt: fractional)
            _ = try repository.restoreBackup(memories: [imported], tasks: [], backupDigest: digest(1), for: "A")
            let reloaded = AssistantLocalRepository(fileURL: url)
            let result = try reloaded.restoreBackup(memories: [imported], tasks: [], backupDigest: digest(2), for: "A")
            try expect(result.skippedMemories == 1 && result.conflictingMemories == 0, "Established whole-second storage cannot turn an unchanged import into a reload conflict")
        }
        try run("concurrent-same-digest-has-one-real-merge", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url), results = RestoreConcurrentResults()
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                do { results.append(try repository.restoreBackup(memories: [memory()], tasks: [task()], backupDigest: digest(1), for: "A")) }
                catch { results.fail() }
            }
            try expect(results.failures == 0 && results.values.count == 16
                && results.values.reduce(0, { $0 + $1.insertedMemories }) == 1
                && results.values.reduce(0, { $0 + $1.insertedTasks }) == 1
                && results.values.filter(\.alreadyApplied).count == 15, "The repository lock must serialize marker and record commits")
            let snapshot = try AssistantLocalRepository(fileURL: url).exportSnapshot(for: "A")
            try expect(snapshot.memories.count == 1 && snapshot.tasks.count == 1, "Concurrent retries cannot duplicate persisted data")
        }
        print("All \(suites) AssistantRepository restore suites passed; temporary files only, no network, credentials, notifications, or tool execution.")
    }
}
