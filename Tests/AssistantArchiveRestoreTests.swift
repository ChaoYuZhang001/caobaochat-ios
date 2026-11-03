import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private enum RestoreFailure: Error, CustomStringConvertible {
    case assertion(String), injected
    var description: String { switch self { case .assertion(let value): return value; case .injected: return "Injected restore failure" } }
}
private final class RestoreSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func arm() { lock.lock(); value = true; lock.unlock() }
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; let result = value; value = false; return result }
}
private final class RestoreCommitGate: @unchecked Sendable {
    private let lock = NSLock(); private var armed = false; private var waiting = false
    private let release = DispatchSemaphore(value: 0)
    func arm() { lock.lock(); armed = true; lock.unlock() }
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return waiting }
    func hold() throws {
        lock.lock(); let enabled = armed; armed = false; if enabled { waiting = true }; lock.unlock()
        if enabled, release.wait(timeout: .now() + 3) != .success { throw RestoreFailure.assertion("Commit gate timed out") }
    }
    func open() { release.signal() }
}

@main private enum AssistantArchiveRestoreTests {
    static let date = Date(timeIntervalSince1970: 1_793_232_000.125)
    static let digest = String(repeating: "a", count: 64)
    static var count = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ text: String) throws { if try !condition() { throw RestoreFailure.assertion(text) } }
    static func rejects(_ body: () throws -> Void) throws {
        do { try body(); throw RestoreFailure.assertion("Expected restore rejection") }
        catch let error as RestoreFailure { if case .assertion = error { throw error } }
        catch {}
    }
    static func conversation(_ id: String, text: String = "Restored body", images: [AssistantImage]? = nil) -> Conversation {
        Conversation(id: id, title: "Title " + id, preview: text, date: date, messages: [ChatMessage(id: id + "-user", role: .user, content: text, timestamp: date, images: images), ChatMessage(id: id + "-assistant", role: .assistant, content: "Answer", timestamp: date)])
    }
    static func sql<T>(_ archive: AssistantChatArchive, owner: String = "A", _ body: (AssistantChatDatabase) throws -> T) throws -> T {
        let db = try AssistantChatDatabase(url: archive.databaseURL(userId: owner), create: false); defer { try? db.close() }; return try body(db)
    }
    static func marker(_ archive: AssistantChatArchive, owner: String = "A", digest: String = digest) throws -> String? {
        try sql(archive, owner: owner) { try $0.rows("SELECT value FROM meta WHERE key=?", [.text("restore.v1." + digest)]).first?.first?.string }
    }
    static func image() throws -> AssistantImage {
        let bytes = Data([UInt8](repeating: 160, count: 12))
        let provider = CGDataProvider(data: bytes as CFData)!
        let value = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 6, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let bytesOut = NSMutableData(), destination = CGImageDestinationCreateWithData(bytesOut, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, value, nil); try expect(CGImageDestinationFinalize(destination), "Fixture JPEG must encode")
        return try AssistantImagePreprocessor.prepare(bytesOut as Data)
    }
    static func proposal(_ conversation: Conversation) throws -> AssistantTaskProposal {
        let arguments = #"{"title":"Forbidden imported authority","notes":"","due_at":null,"time_zone":null,"reminder_requested":false}"#
        let items: [[String: Any]] = [["role": "assistant", "content": "", "tool_calls": [["id": "call", "type": "function", "function": ["name": "create_task", "arguments": arguments]]]]]
        let trace = AssistantTaskToolTrace(protocolKind: .chatCompletions, assistantItemsJSON: String(data: try JSONSerialization.data(withJSONObject: items), encoding: .utf8)!)
        return try AssistantTaskProposal(call: AssistantTaskToolCall(id: "call", name: "create_task", arguments: arguments, trace: trace), ownerId: "A", conversationId: conversation.id, assistantMessageId: conversation.messages[1].id, sourceUserMessageId: conversation.messages[0].id, sourceUserText: conversation.messages[0].content, configurationFingerprint: String(repeating: "b", count: 64))
    }
    static func run(_ name: String, root: URL, _ body: (URL) async throws -> Void) async throws {
        let path = root.appendingPathComponent(name, isDirectory: true); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try await body(path); count += 1; print("PASS \(name)")
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caobao-archive-restore-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await run("standalone-atomic-insert-and-durable-marker", root: root) { path in
            let archive = AssistantChatArchive(directory: path); try archive.prepare(userId: "A")
            let value = conversation("one")
            let result = try archive.restoreBackup(conversations: [value], drafts: [AssistantChatDraft(text: "draft", conversationId: "one")], backupDigest: digest, userId: "A")
            try expect(result.insertedConversations == 1 && result.insertedDrafts == 1 && !result.alreadyApplied, "Standalone restoration must insert both rows")
            try expect(try archive.load(userId: "A") == [value] && marker(archive) == "1", "Conversation and marker must both commit")
            try expect(try archive.loadDraft(userId: "A").isEmpty, "Restored draft is inactive")
        }
        try await run("repeat-and-reload-have-zero-new-counts", root: root) { path in
            let archive = AssistantChatArchive(directory: path); try archive.prepare(userId: "A")
            _ = try archive.restoreBackup(conversations: [conversation("one")], drafts: [], backupDigest: digest, userId: "A")
            let reloaded = AssistantChatArchive(directory: path); try reloaded.prepare(userId: "A")
            let result = try reloaded.restoreBackup(conversations: [conversation("one")], drafts: [], backupDigest: digest, userId: "A")
            try expect(result == AssistantArchiveRestoreResult(alreadyApplied: true), "A durable repeated file produces no insertion or conflict work")
        }
        try await run("same-public-unix-date-content-skips-without-local-rewrite", root: root) { path in
            let archive = AssistantChatArchive(directory: path); try archive.prepare(userId: "A")
            let instant = Date(timeIntervalSinceReferenceDate: 800_000_000 + 0.000_000_119_209_289_550_781_25)
            let local = Conversation(id: "precision", title: "Keep exact local date", preview: "same", date: instant, messages: [ChatMessage(id: "u", role: .user, content: "same", timestamp: instant)])
            try archive.upsert(local, userId: "A")
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
            let backup = try decoder.decode(Conversation.self, from: encoder.encode(local))
            try expect(backup.date != local.date, "Fixture must exercise a real epoch conversion precision boundary")
            let result = try archive.restoreBackup(conversations: [backup], drafts: [], backupDigest: digest, userId: "A")
            try expect(result.skippedConversations == 1 && result.conflictingConversations == 0 && (try archive.conversation(id: local.id, userId: "A")) == local, "Identical public backup timestamps must skip while preserving the exact original Date value")
        }
        try await run("local-content-conflict-and-tombstone-win", root: root) { path in
            let archive = AssistantChatArchive(directory: path); try archive.prepare(userId: "A")
            let same = conversation("same"), local = conversation("conflict", text: "Local exact body")
            try archive.upsert(same, userId: "A"); try archive.upsert(local, userId: "A"); try archive.delete(ids: ["deleted"], userId: "A")
            let result = try archive.restoreBackup(conversations: [same, conversation("conflict", text: "Different backup"), conversation("new"), conversation("deleted")], drafts: [AssistantChatDraft(text: "deleted draft", conversationId: "deleted")], backupDigest: digest, userId: "A")
            try expect(result.insertedConversations == 1 && result.skippedConversations == 1 && result.conflictingConversations == 1 && result.tombstonedConversations == 1 && result.skippedDrafts == 1, "Every merge outcome must be counted separately")
            try expect(try archive.conversation(id: "conflict", userId: "A") == local && archive.conversation(id: "deleted", userId: "A") == nil, "Local conflict and deletion cannot be overwritten")
        }
        try await run("normal-delete-retains-marker-preventing-file-resurrection", root: root) { path in
            let archive = AssistantChatArchive(directory: path); try archive.prepare(userId: "A")
            _ = try archive.restoreBackup(conversations: [conversation("one")], drafts: [], backupDigest: digest, userId: "A")
            try archive.delete(ids: ["one"], userId: "A")
            let result = try archive.restoreBackup(conversations: [conversation("one")], drafts: [], backupDigest: digest, userId: "A")
            try expect(result.alreadyApplied && result.insertedConversations == 0 && (try archive.load(userId: "A")).isEmpty && marker(archive) == "1", "Message deletion cannot erase the backup replay marker")
        }
        try await run("active-nonempty-empty-and-unassigned-draft-preservation", root: root) { path in
            let archive = AssistantChatArchive(directory: path); try archive.prepare(userId: "A")
            try archive.saveDraft("inactive local", conversationId: "inactive", userId: "A")
            try archive.saveDraft("", conversationId: "empty-local", userId: "A")
            try archive.saveDraft("active local", conversationId: "active", userId: "A")
            let result = try archive.restoreBackup(conversations: [], drafts: [AssistantChatDraft(text: "backup active", conversationId: "active"), AssistantChatDraft(text: "backup inactive", conversationId: "inactive"), AssistantChatDraft(text: "", conversationId: "empty-local"), AssistantChatDraft(text: "new", conversationId: "new"), AssistantChatDraft(text: "unassigned")], backupDigest: digest, userId: "A")
            try expect(result.conflictingDrafts == 2 && result.skippedDrafts == 1 && result.insertedDrafts == 2, "Existing slots remain insert-only; nil draft is one deterministic inactive slot")
            let snapshot = try archive.loadDraftSnapshot(userId: "A")
            try expect(snapshot.active.text == "active local" && snapshot.active.conversationId == "active" && snapshot.inactive.count == 4, "Restoration cannot activate a new draft or replace local drafts")
        }
        try await run("sql-failure-rolls-back-rows-and-marker", root: root) { path in
            let archive = AssistantChatArchive(directory: path); try archive.prepare(userId: "A")
            try sql(archive) { try $0.execute("CREATE TRIGGER reject_bad BEFORE INSERT ON headers WHEN NEW.id='bad' BEGIN SELECT RAISE(ABORT,'injected'); END") }
            try rejects { _ = try archive.restoreBackup(conversations: [conversation("first"), conversation("bad")], drafts: [], backupDigest: digest, userId: "A") }
            try expect(try archive.load(userId: "A").isEmpty && marker(archive) == nil, "A failure after the first insert cannot publish any partial rows or marker")
            try sql(archive) { try $0.execute("DROP TRIGGER reject_bad") }
            try expect(try archive.restoreBackup(conversations: [conversation("first"), conversation("bad")], drafts: [], backupDigest: digest, userId: "A").insertedConversations == 2, "The failed file remains retryable")
        }
        try await run("nested-caught-sql-failure-is-savepoint-atomic", root: root) { path in
            let archive = AssistantChatArchive(directory: path); try archive.prepare(userId: "A")
            try sql(archive) { try $0.execute("CREATE TRIGGER reject_bad BEFORE INSERT ON headers WHEN NEW.id='bad' BEGIN SELECT RAISE(ABORT,'injected'); END") }
            try await archive.backgroundTransaction(userId: "A", operation: { value in
                do { _ = try value.restoreBackup(conversations: [conversation("first"), conversation("bad")], drafts: [], backupDigest: digest, userId: "A") } catch {}
                try value.upsert(conversation("outer-kept"), userId: "A")
            })
            try expect(try archive.load(userId: "A").map(\.id) == ["outer-kept"] && marker(archive) == nil, "Catching restore failure inside an outer transaction cannot commit its first row")
        }
        try await run("outer-before-commit-failure-rolls-back-restore-marker", root: root) { path in
            let archive = AssistantChatArchive(directory: path); try archive.prepare(userId: "A")
            do {
                _ = try await archive.backgroundTransaction(userId: "A", operation: { try $0.restoreBackup(conversations: [conversation("one")], drafts: [], backupDigest: digest, userId: "A") }, beforeCommit: { throw RestoreFailure.injected })
                throw RestoreFailure.assertion("Outer commit must fail")
            } catch RestoreFailure.injected {}
            try expect(try archive.load(userId: "A").isEmpty && marker(archive) == nil, "An outer transaction owns final durability of both data and marker")
        }
        try await run("standalone-before-commit-fault-is-atomic-and-retryable", root: root) { path in
            let failure = RestoreSwitch(), archive = AssistantChatArchive(directory: path, fault: { phase, _ in if phase == .beforeCommit && failure.take() { throw RestoreFailure.injected } })
            try archive.prepare(userId: "A"); failure.arm()
            try rejects { _ = try archive.restoreBackup(conversations: [conversation("one")], drafts: [AssistantChatDraft(text: "new")], backupDigest: digest, userId: "A") }
            try expect(try archive.load(userId: "A").isEmpty && archive.loadDraftRecords(userId: "A").isEmpty && marker(archive) == nil, "A real before-commit fault rolls back both restored record kinds and marker")
            _ = try archive.restoreBackup(conversations: [conversation("one")], drafts: [], backupDigest: digest, userId: "A")
        }
        try await run("remote-ids-tool-authority-and-live-statuses-rejected", root: root) { path in
            let archive = AssistantChatArchive(directory: path); try archive.prepare(userId: "A")
            for kind in ["server", "request", "generation", "lineage", "proposal", "pending", "streaming"] {
                let value = conversation("one"); var messages = value.messages; var remote: String?
                switch kind { case "server": remote = "foreign"; case "request": messages[1].requestId = "remote"; case "generation": messages[1].generationId = "remote"; case "lineage": messages[1].replacesMessageId = "local-message"; case "proposal": messages[1].taskProposal = try proposal(value); case "pending": messages[1].status = .pending; default: messages[1].status = .streaming }
                let invalid = Conversation(id: value.id, title: value.title, preview: value.preview, date: value.date, messages: messages, serverConversationId: remote)
                try rejects { _ = try archive.restoreBackup(conversations: [invalid], drafts: [], backupDigest: digest, userId: "A") }
            }
            try expect(try archive.load(userId: "A").isEmpty && marker(archive) == nil, "Restoration never manufactures remote generation or tool execution authority")
        }
        try await run("strict-digest-and-duplicate-input-rejected", root: root) { path in
            let archive = AssistantChatArchive(directory: path); try archive.prepare(userId: "A")
            for value in ["", String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "a", count: 63)] { try rejects { _ = try archive.restoreBackup(conversations: [], drafts: [], backupDigest: value, userId: "A") } }
            try rejects { _ = try archive.restoreBackup(conversations: [conversation("same"), conversation("same")], drafts: [], backupDigest: digest, userId: "A") }
            for drafts in [[AssistantChatDraft(text: "one"), AssistantChatDraft(text: "two")], [AssistantChatDraft(text: "one", conversationId: "same"), AssistantChatDraft(text: "two", conversationId: "same")]] { try rejects { _ = try archive.restoreBackup(conversations: [], drafts: drafts, backupDigest: digest, userId: "A") } }
            var duplicate = conversation("messages"); duplicate = Conversation(id: duplicate.id, title: duplicate.title, preview: duplicate.preview, date: duplicate.date, messages: [duplicate.messages[0], duplicate.messages[0]])
            try rejects { _ = try archive.restoreBackup(conversations: [duplicate], drafts: [], backupDigest: digest, userId: "A") }
            try expect(try marker(archive) == nil, "Invalid and ambiguous inputs never consume a backup digest")
        }
        try await run("raw-unicode-owners-have-independent-stores-and-markers", root: root) { path in
            let first = "\u{00E9}", second = "e\u{0301}", archive = AssistantChatArchive(directory: path)
            try archive.prepare(userId: first); try archive.prepare(userId: second)
            _ = try archive.restoreBackup(conversations: [conversation("same", text: "First owner")], drafts: [], backupDigest: digest, userId: first)
            _ = try archive.restoreBackup(conversations: [conversation("same", text: "Second owner")], drafts: [], backupDigest: digest, userId: second)
            try expect(try archive.load(userId: first)[0].messages[0].content == "First owner" && archive.load(userId: second)[0].messages[0].content == "Second owner", "Canonical owner aliases cannot share archives")
            try expect(try marker(archive, owner: first) == "1" && marker(archive, owner: second) == "1", "One account's file marker cannot prevent another account's independent restoration")
            do {
                _ = try await archive.backgroundTransaction(userId: first, operation: { try $0.restoreBackup(conversations: [], drafts: [], backupDigest: digest, userId: second) })
                throw RestoreFailure.assertion("Cross-owner transaction must reject")
            } catch AssistantChatStorageError.transactionBoundary {}
        }
        try await run("unprepared-and-purged-store-never-auto-restore", root: root) { path in
            let archive = AssistantChatArchive(directory: path)
            try rejects { _ = try archive.restoreBackup(conversations: [conversation("one")], drafts: [], backupDigest: digest, userId: "A") }
            try expect(!archive.isPrepared(userId: "A"), "No implicit preparation is allowed")
            try archive.prepare(userId: "A"); try archive.deleteAll(userId: "A")
            try rejects { _ = try archive.restoreBackup(conversations: [conversation("one")], drafts: [], backupDigest: digest, userId: "A") }
            try expect(try archive.load(userId: "A").isEmpty && !FileManager.default.fileExists(atPath: archive.databaseURL(userId: "A").path), "Purged account data must not be recreated")
        }
        try await run("media-text-and-aggregate-limits-validate-before-write", root: root) { path in
            let archive = AssistantChatArchive(directory: path); try archive.prepare(userId: "A"); let picture = try image()
            try rejects { _ = try archive.restoreBackup(conversations: [conversation("bad-media", images: Array(repeating: picture, count: 4))], drafts: [], backupDigest: digest, userId: "A") }
            try rejects { _ = try archive.restoreBackup(conversations: [conversation("bad-text", text: String(repeating: "x", count: 1_048_577))], drafts: [], backupDigest: digest, userId: "A") }
            let large = String(repeating: "x", count: 1_048_576)
            try rejects { _ = try archive.restoreBackup(conversations: (0..<17).map { conversation("large-\($0)", text: large) }, drafts: [], backupDigest: digest, userId: "A") }
            try expect(try archive.load(userId: "A").isEmpty && marker(archive) == nil, "Oversized import cannot leave an initial prefix or marker")
            let result = try archive.restoreBackup(conversations: [conversation("valid-media", images: [picture])], drafts: [AssistantChatDraft(text: "valid", images: [picture], conversationId: "valid-media")], backupDigest: digest, userId: "A")
            try expect(result.insertedConversations == 1 && result.insertedDrafts == 1 && (try archive.load(userId: "A"))[0].messages[0].images == [picture], "Existing valid attachment semantics remain supported")
        }
        try await run("queued-delete-fence-cancels-outer-restore-before-commit", root: root) { path in
            let gate = RestoreCommitGate(), archive = AssistantChatArchive(directory: path, fault: { phase, _ in if phase == .beforeCommit { try gate.hold() } })
            try archive.prepare(userId: "A"); gate.arm(); defer { gate.open() }
            let restoration = Task { try await archive.backgroundTransaction(userId: "A", operation: { try $0.restoreBackup(conversations: [conversation("one")], drafts: [], backupDigest: digest, userId: "A") }) }
            for _ in 0..<200 { if gate.entered { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            try expect(gate.entered, "Actual SQLite outer commit must reach the controlled boundary")
            let deletion = Task.detached { try archive.delete(ids: ["one"], userId: "A") }
            for _ in 0..<200 { if archive.authorizationSnapshot(userId: "A").inFlightDestructive { break }; try await Task.sleep(nanoseconds: 5_000_000) }
            try expect(archive.authorizationSnapshot(userId: "A").inFlightDestructive, "The real queued deletion must publish its fence")
            gate.open()
            do { _ = try await restoration.value; throw RestoreFailure.assertion("Destructive fence must reject restore commit") } catch AssistantChatStorageError.revisionConflict {}
            try await deletion.value
            try expect(try archive.load(userId: "A").isEmpty && marker(archive) == nil && archive.deletedConversationIds(userId: "A").contains("one"), "Deletion wins without consuming the restore marker or resurrecting the conversation")
        }
        try await run("corrupt-restore-marker-is-never-overwritten", root: root) { path in
            let archive = AssistantChatArchive(directory: path); try archive.prepare(userId: "A")
            try sql(archive) { try $0.execute("INSERT INTO meta(key,value) VALUES(?,?)", [.text("restore.v1." + digest), .text("invalid")]) }
            try rejects { _ = try archive.restoreBackup(conversations: [conversation("one")], drafts: [], backupDigest: digest, userId: "A") }
            try expect(try marker(archive) == "invalid" && archive.load(userId: "A").isEmpty, "A malformed existing replay marker must fail closed without replacement")
        }
        try await run("pre-cancelled-restore-publishes-no-rows-or-marker", root: root) { path in
            let archive = AssistantChatArchive(directory: path); try archive.prepare(userId: "A")
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try archive.restoreBackup(conversations: [conversation("one")], drafts: [], backupDigest: digest, userId: "A")
            }
            do { _ = try await task.value; throw RestoreFailure.assertion("Cancelled restoration must throw") } catch is CancellationError {}
            try expect(try archive.load(userId: "A").isEmpty && marker(archive) == nil, "Cancellation precedes the import transaction")
        }
        try await run("malformed-local-unassigned-slot-cannot-create-duplicates", root: root) { path in
            let archive = AssistantChatArchive(directory: path); try archive.prepare(userId: "A")
            let payload = try JSONEncoder().encode(AssistantChatDraft(text: "local unassigned"))
            try sql(archive) { try $0.execute("INSERT INTO drafts(slot,conversation_id,payload,revision) VALUES('bad-local-slot',NULL,?,1)", [.blob(payload)]) }
            try rejects { _ = try archive.restoreBackup(conversations: [], drafts: [AssistantChatDraft(text: "new unassigned")], backupDigest: digest, userId: "A") }
            try expect(try sql(archive) { try $0.rows("SELECT slot FROM drafts WHERE conversation_id IS NULL").count } == 1 && marker(archive) == nil, "An invalid existing nil slot cannot be silently duplicated by restoration")
        }
        print("All \(count) archive restore suites passed using temporary real SQLite stores; no SDK, simulator, provider or notification operations.")
    }
}
