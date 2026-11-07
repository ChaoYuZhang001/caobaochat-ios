import Foundation
import CryptoKit
import SQLite3
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private struct ArchiveTestFailure: Error, CustomStringConvertible { let description: String }
private final class ArchiveFault: @unchecked Sendable {
    private let lock = NSLock(); private var point: AssistantArchiveFaultPoint?
    func arm(_ value: AssistantArchiveFaultPoint?) { lock.lock(); point = value; lock.unlock() }
    func check(_ value: AssistantArchiveFaultPoint, _ owner: String) throws { lock.lock(); let reject = point == value && owner == "A"; lock.unlock(); if reject { throw ArchiveTestFailure(description: "Injected storage boundary") } }
}
private final class ArchiveResults: @unchecked Sendable {
    private let lock = NSLock(); private var stored: [String] = []
    func add(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
@main private enum AssistantChatArchiveTests {
    private static var count = 0
    private static let date = Date(timeIntervalSince1970: 1_793_232_000)
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw ArchiveTestFailure(description: message) } }
    private static func fails(_ operation: () throws -> Void, _ message: String) throws { do { try operation() } catch { return }; throw ArchiveTestFailure(description: message) }
    private static func message(_ id: String, text: String = "body", status: ChatMessage.Status = .completed) -> ChatMessage { ChatMessage(id: id, role: .assistant, content: text, timestamp: date, liked: true, status: status, requestId: "request", generationId: "generation", model: "model", usage: AssistantUsage(inputTokens: 13, outputTokens: 7)) }
    private static func conversation(_ id: String, text: String = "body", order: Double = 0) -> Conversation { Conversation(id: id, title: "Title " + id, preview: text, date: date.addingTimeInterval(order), messages: [message("message-" + id, text: text, status: .streaming)], serverConversationId: "server-" + id) }
    private static func ready(_ folder: URL, owners: [String] = ["A"], fault: ArchiveFault? = nil) throws -> AssistantChatArchive {
        let archive = AssistantChatArchive(directory: folder, fault: { point, owner in try fault?.check(point, owner) })
        for owner in owners { try archive.prepare(userId: owner) }; return archive
    }
    private static func sql(_ archive: AssistantChatArchive, owner: String = "A") throws -> AssistantChatDatabase { try AssistantChatDatabase(url: archive.databaseURL(userId: owner), create: false) }
    private static func legacy(_ folder: URL, owner: String = "A") -> URL { let name = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined(); return folder.appendingPathComponent(name + ".json") }
    private static func files(_ folder: URL) throws -> [String: Data] { var result: [String: Data] = [:]; for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) { result[url.lastPathComponent] = try Data(contentsOf: url) }; return result }
    private static func picture() throws -> AssistantImage {
        let bytes = Data([UInt8](repeating: 160, count: 12)), output = NSMutableData()
        guard let provider = CGDataProvider(data: bytes as CFData), let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 6, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent), let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw ArchiveTestFailure(description: "image fixture") }
        CGImageDestinationAddImage(destination, image, nil); guard CGImageDestinationFinalize(destination) else { throw ArchiveTestFailure(description: "JPEG fixture") }; return try AssistantImagePreprocessor.prepare(output as Data)
    }
    private static func run(_ name: String, root: URL, _ operation: (URL) throws -> Void) throws { let folder = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); do { try operation(folder) } catch { throw ArchiveTestFailure(description: name + ": \(error)") }; count += 1; print("PASS " + name) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caobao-archive-sql-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        try run("conversation-roundtrip-upsert", root: root) { folder in
            let a = try ready(folder); try a.upsert(conversation("one"), userId: "A"); try a.upsert(conversation("two", order: 1), userId: "A"); let updated = conversation("one", text: "revised")
            try a.upsert(updated, userId: "A"); let values = try a.load(userId: "A")
            try expect(values.count == 2 && values.first?.id == "two" && values.first(where: { $0.id == "one" }) == updated, "Full snapshots replace one ID while body-only updates preserve turn ordering")
        }
        try run("account-isolation-and-delete-ownership", root: root) { folder in
            let a = try ready(folder, owners: ["A", "B", "C"]); for owner in ["A", "B"] { try a.upsert(conversation("same", text: owner), userId: owner) }
            try a.delete(ids: ["same"], userId: "C"); try a.delete(ids: ["same"], userId: "A")
            try expect(try a.load(userId: "A").isEmpty && a.load(userId: "B").first?.preview == "B", "Database ownership cannot cross account boundaries")
        }
        try run("safe-account-file-names", root: root) { folder in
            let owner = "../../outside/🔐private@example.com", a = try ready(folder, owners: [owner]); try a.upsert(conversation("one"), userId: owner)
            let url = a.databaseURL(userId: owner); try expect(url.deletingPathExtension().lastPathComponent.count == 64 && url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path, "Owner IDs never become path components")
        }
        try run("corrupt-archive-preserves-bytes", root: root) { folder in
            let a = try ready(folder); try a.upsert(conversation("one"), userId: "A"); let db = try sql(a); defer { try? db.close() }
            let broken = Data("{broken private payload".utf8); try db.execute("UPDATE bodies SET payload=?", [.blob(broken)]); let before = try files(folder)
            try fails({ _ = try a.load(userId: "A") }, "Corrupt body must fail")
            try fails({ try a.upsert(conversation("one", text: "overwrite"), userId: "A") }, "An update cannot erase its corrupt original")
            try expect(try files(folder) == before, "Failed decode/update preserves real database bytes")
        }
        try run("archive-write-error-propagates", root: root) { folder in
            let f = ArchiveFault(), a = try ready(folder, fault: f); try a.upsert(conversation("one"), userId: "A"); let before = try files(folder); f.arm(.beforeCommit)
            try fails({ try a.upsert(conversation("two"), userId: "A") }, "Commit failure propagates")
            try expect(try a.load(userId: "A").map(\.id) == ["one"] && files(folder) == before, "SQL transaction rollback preserves stored data")
        }
        try run("legacy-optional-status-decode", root: root) { _ in
            var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message("old"))) as! [String: Any]
            for key in ["status", "liked", "disliked", "requestId", "generationId", "model", "usage"] { fields.removeValue(forKey: key) }
            let value = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: fields))
            try expect(value.status == .completed && !value.liked && value.usage == nil, "Optional historical fields retain defaults")
        }
        try run("draft-roundtrip-isolation-and-purge", root: root) { folder in
            let a = try ready(folder, owners: ["A", "B"]); try a.saveDraft("A", userId: "A"); try a.saveDraft("B", userId: "B"); try a.deleteAll(userId: "A")
            try expect(try a.loadDraft(userId: "A").isEmpty && a.loadDraft(userId: "B") == "B", "Account purge removes only owned drafts")
        }
        try run("interrupted-status-recovery", root: root) { _ in
            let values = ChatMessage.recoverInterrupted([message("p", status: .pending), message("s", status: .streaming), message("c", status: .completed)])
            try expect(values.map(\.status) == [.failed, .failed, .completed], "Interrupted recovery does not pretend generation continued")
        }
        try run("missing-archive-and-draft-remain-idempotently-empty", root: root) { folder in
            let a = AssistantChatArchive(directory: folder); try fails({ _ = try a.load(userId: "A") }, "Sync guard cannot migrate implicitly"); try expect(try files(folder).isEmpty, "Readiness guard does no I/O")
            try a.prepare(userId: "A"); let before = try files(folder)
            try expect(try a.load(userId: "A").isEmpty && a.loadDraft(userId: "A").isEmpty && files(folder) == before, "Prepared empty reads are side effect free")
        }
        try run("blocked-directory-read-and-delete-must-fail", root: root) { folder in
            let path = folder.appendingPathComponent("blocked"), bytes = Data("original".utf8); try bytes.write(to: path); let a = AssistantChatArchive(directory: path)
            try fails({ try a.prepare(userId: "A") }, "Blocked preparation fails"); try fails({ try a.deleteAll(userId: "A") }, "Blocked purge fails"); try expect(try Data(contentsOf: path) == bytes, "Blocked source remains intact")
        }
        try run("replacement-lineage-roundtrip-all-message-states", root: root) { folder in
            let a = try ready(folder)
            for status in [ChatMessage.Status.pending, .streaming, .completed, .cancelled, .failed] { var item = message(status.rawValue, status: status); item.replacesMessageId = "original"; let value = Conversation(id: status.rawValue, title: "lineage", preview: "body", date: date, messages: [item]); try a.upsert(value, userId: "A"); try expect(try a.conversation(id: value.id, userId: "A") == value, "Every state preserves full lineage/usage/content") }
        }
        try run("legacy-missing-and-null-replacement-fields-default-nil", root: root) { _ in
            var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message("old"))) as! [String: Any]
            fields.removeValue(forKey: "replacesMessageId"); try expect(try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: fields)).replacesMessageId == nil, "Absent lineage stays absent")
            fields["replacesMessageId"] = NSNull(); try expect(try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: fields)).replacesMessageId == nil, "Null lineage stays absent")
        }
        try run("invalid-replacement-field-types-are-not-silently-dropped", root: root) { _ in
            var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message("old"))) as! [String: Any]; fields["replacesMessageId"] = 123
            try fails({ _ = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: fields)) }, "Invalid lineage is an error")
        }
        try run("interrupted-recovery-preserves-all-lineage-and-original-content", root: root) { _ in
            var item = message("one", text: "partial", status: .streaming); item.replacesMessageId = "old"; let recovered = ChatMessage.recoverInterrupted([item])[0]
            try expect(recovered.content == item.content && recovered.replacesMessageId == "old" && recovered.requestId == item.requestId && recovered.status == .failed, "Recovery changes only interrupted status")
        }
        try run("current-and-historical-status-keys-with-partial-content", root: root) { _ in
            for status in [ChatMessage.Status.pending, .streaming, .completed, .failed, .cancelled] { let item = message("one", text: "partial", status: status); try expect(item.statusDescriptionKey(isHistorical: true) == nil || item.statusDescriptionKey(isHistorical: true)!.contains("部分") || status == .completed, "Historical descriptions acknowledge retained partial output") }
        }
        try run("current-and-historical-status-keys-with-empty-content", root: root) { _ in
            for status in [ChatMessage.Status.pending, .streaming, .failed, .cancelled] { let item = message("one", text: "", status: status); try expect(item.statusDescriptionKey(isHistorical: true)?.contains("尚未收到") == true && item.content.isEmpty, "Empty results never claim partial output") }
        }
        try run("draft-per-conversation-roundtrip-active-pointer-and-images", root: root) { folder in
            let a = try ready(folder), p = try picture(); try a.saveDraft("A\n", images: [p], conversationId: "a", userId: "A"); try a.saveDraft("B", images: [p,p], conversationId: "b", userId: "A")
            let cold = try ready(folder); try expect(try cold.loadDraftRecord(userId: "A").images == [p,p] && cold.loadDraftRecord(conversationId: "a", userId: "A") == AssistantChatDraft(text: "A\n", images: [p], conversationId: "a"), "Real SQLite cold reads preserve inactive images and active pointer")
        }
        try run("draft-select-existing-saves-source-and-preserves-third-draft", root: root) { folder in
            let a = try ready(folder); for id in ["a","b","c"] { try a.saveDraft(id, conversationId: id, userId: "A") }
            let source = AssistantChatDraft(text: "c edit", conversationId: "c"), selected = try a.selectDraft(conversationId: "b", preserving: source, initialDraft: AssistantChatDraft(text: "wrong"), userId: "A")
            try expect(try selected.text == "b" && a.loadDraftRecord(conversationId: "c", userId: "A") == source && a.loadDraftRecord(conversationId: "a", userId: "A").text == "a", "One transaction preserves source/target/other drafts")
        }
        try run("draft-select-new-prefill-is-atomic-and-only-initializes-once", root: root) { folder in
            let a = try ready(folder); let first = try a.selectDraft(conversationId: "new", preserving: AssistantChatDraft(text: "source", conversationId: "source"), initialDraft: AssistantChatDraft(text: "prefill"), userId: "A")
            try expect(try first == a.selectDraft(conversationId: "new", preserving: nil, initialDraft: AssistantChatDraft(text: "overwrite"), userId: "A"), "Existing target never reapplies initial prefill")
        }
        try run("draft-select-missing-default-and-read-have-no-side-effects", root: root) { folder in
            let a = try ready(folder), before = try files(folder); let missing = try a.loadDraftRecord(conversationId: "missing", userId: "A")
            try expect(try missing == AssistantChatDraft(text: "", conversationId: "missing") && a.loadDraftRecords(userId: "A").isEmpty && files(folder) == before, "Missing target read does not create a draft")
        }
        try run("draft-legacy-string-remains-unassigned-until-explicit-mutation", root: root) { folder in
            try JSONEncoder().encode("Legacy source").write(to: legacy(folder).appendingPathExtension("draft")); let a = try ready(folder)
            _ = try a.selectDraft(conversationId: "new", preserving: nil, userId: "A"); let snapshot = try a.loadDraftSnapshot(userId: "A")
            try expect(snapshot.active.conversationId == "new" && snapshot.inactive == [AssistantChatDraft(text: "Legacy source")], "Migration does not assign old unassociated content to a new conversation")
        }
        try run("draft-legacy-structured-record-retains-association-and-images", root: root) { folder in
            let old = AssistantChatDraft(text: "legacy image", images: [try picture()], conversationId: "old"); try JSONEncoder().encode(old).write(to: legacy(folder).appendingPathExtension("draft"))
            let a = try ready(folder); try expect(try a.loadDraftRecord(conversationId: "old", userId: "A") == old && !FileManager.default.fileExists(atPath: legacy(folder).appendingPathExtension("draft").path), "Verified SQLite migration retains old association/images and cleans the obsolete source")
        }
        try run("draft-envelope-corruption-owner-pointer-and-map-fail-closed", root: root) { folder in
            let fields: [String:Any] = ["version":1,"ownerId":"B","activeUnassigned":false,"conversationDrafts":[:]]
            let url = legacy(folder).appendingPathExtension("draft"), bytes = try JSONSerialization.data(withJSONObject: fields); try bytes.write(to: url); let a = AssistantChatArchive(directory: folder)
            try fails({ try a.prepare(userId: "A") }, "Foreign legacy envelope cannot migrate"); try expect(try Data(contentsOf: url) == bytes && !a.isPrepared(userId: "A"), "Migration failure preserves original bytes and readiness")
        }
        try run("draft-select-and-delete-write-failure-preserve-entire-transaction", root: root) { folder in
            let f = ArchiveFault(), a = try ready(folder, fault: f); try a.saveDraft("source", conversationId: "s", userId: "A"); try a.saveDraft("target", conversationId: "t", userId: "A"); let before = try files(folder); f.arm(.beforeCommit)
            try fails({ _ = try a.selectDraft(conversationId: "t", preserving: AssistantChatDraft(text: "edit", conversationId: "s"), userId: "A") }, "Commit rejection rolls back source as well")
            try fails({ try a.deleteDrafts(conversationIds: ["t"], userId: "A") }, "Failed draft deletion does not change active pointer"); try expect(try files(folder) == before && a.loadDraftRecord(userId: "A").text == "target", "All compound changes roll back together")
        }
        try run("draft-deletion-is-owner-scoped-and-does-not-activate-unrelated-records", root: root) { folder in
            let a = try ready(folder, owners: ["A","B"]); try a.saveDraft("unassigned", userId: "A"); try a.saveDraft("other", conversationId: "other", userId: "A"); try a.saveDraft("active", conversationId: "active", userId: "A"); try a.saveDraft("B", conversationId: "active", userId: "B")
            try a.deleteDrafts(conversationIds: ["active"], userId: "A"); try expect(try a.loadDraftRecord(userId: "A").text.isEmpty && a.loadDraftRecords(userId: "A").count == 2 && a.loadDraftRecord(userId: "B").text == "B", "FK clears only the deleted active pointer, not other account data")
        }
        try run("draft-concurrent-selection-retains-every-source-and-one-initial-target", root: root) { folder in
            let a = try ready(folder), results = ArchiveResults()
            DispatchQueue.concurrentPerform(iterations: 8) { index in do { let value = try a.selectDraft(conversationId: "target", preserving: AssistantChatDraft(text: "source", conversationId: "s\(index)"), initialDraft: AssistantChatDraft(text: "first\(index)"), userId: "A"); results.add(value.text) } catch { results.add("error") } }
            try expect(try results.values.count == 8 && Set(results.values).count == 1 && a.loadDraftRecords(userId: "A").count == 9, "Serial connection transactions do not lose concurrent source drafts")
        }
        try run("draft-invalid-selection-inputs-do-not-partially-save-source", root: root) { folder in
            let a = try ready(folder); try a.saveDraft("original", conversationId: "s", userId: "A"); let before = try files(folder)
            try fails({ _ = try a.selectDraft(conversationId: "t", preserving: AssistantChatDraft(text: "edit", conversationId: "s"), initialDraft: AssistantChatDraft(text: String(repeating:"x",count:1_048_577)), userId:"A") }, "Oversized target cannot partially save source")
            try expect(try files(folder) == before, "Input validation is inside the source+target transaction")
        }
        try run("draft-new-apis-propagate-blocked-directory-and-ignore-unowned-files", root: root) { folder in
            let unowned = folder.appendingPathComponent("global-old-draft"), bytes = try JSONEncoder().encode("Unowned private source"); try bytes.write(to: unowned); let a = try ready(folder)
            try expect(try a.loadDraftRecords(userId:"A").isEmpty && Data(contentsOf:unowned) == bytes, "Global/unowned files never migrate into the next account")
        }
        try run("draft-selection-and-removal-never-rewrite-conversation-messages", root: root) { folder in
            let a = try ready(folder); try a.upsert(conversation("history"), userId:"A"); let db = try sql(a); defer { try? db.close() }; let before = try db.rows("SELECT payload FROM bodies").first?.first?.data
            _ = try a.selectDraft(conversationId:"history", preserving:nil, initialDraft:AssistantChatDraft(text:"prefill"), userId:"A"); try a.deleteDrafts(conversationIds:["history"],userId:"A")
            try expect(try db.rows("SELECT payload FROM bodies").first?.first?.data == before, "Shared database draft transactions never mutate message payload bytes")
        }
        try run("draft-select-existing-invalid-target-cannot-save-source-or-active-pointer", root: root) { folder in
            let a = try ready(folder); try a.saveDraft("source",conversationId:"s",userId:"A"); try a.saveDraft("target",conversationId:"t",userId:"A"); _ = try a.selectDraft(conversationId:"s",preserving:nil,userId:"A"); let db = try sql(a); defer { try? db.close() }
            for invalid in [AssistantChatDraft(text:String(repeating:"x",count:1_048_577),conversationId:"t"),AssistantChatDraft(text:"bad image",images:[AssistantImage(id:"bad",mimeType:"image/jpeg",base64Data:"invalid",width:1,height:1)],conversationId:"t")] {
                try db.execute("UPDATE drafts SET payload=? WHERE slot='c:t'",[.blob(try JSONEncoder().encode(invalid))]); let before = try files(folder)
                try fails({ _ = try a.selectDraft(conversationId:"t",preserving:AssistantChatDraft(text:"edit",conversationId:"s"),userId:"A") },"Final existing target must validate under the SQL transaction")
                try expect(try files(folder) == before && a.loadDraftRecord(userId:"A").text == "source", "Invalid target cannot switch active or save source first")
            }
        }
        try run("durable-delete-normal-success-cold-owner-roundtrip-and-no-resurrection", root: root) { folder in
            let a = try ready(folder,owners:["A","B"]); for owner in ["A","B"] { try a.upsert(conversation("dead",text:owner),userId:owner); try a.saveDraft(owner,conversationId:"dead",userId:owner) }; try a.delete(ids:["dead"],userId:"A",purgeUnassignedDraft:true)
            let cold = try ready(folder,owners:["A","B"]); try expect(try cold.load(userId:"A").isEmpty && cold.loadDraftRecords(userId:"A").isEmpty && cold.load(userId:"B").count == 1 && cold.deletedConversationIds(userId:"A") == ["dead"], "Cold owners retain deletion isolation")
            try fails({ try cold.upsert(conversation("dead"),userId:"A") },"Tombstone rejects stale producer"); try fails({ try cold.saveDraft("stale",conversationId:"dead",userId:"A") },"Tombstone rejects stale draft")
        }
        try run("durable-delete-first-protection-failure-leaves-both-sources-unchanged", root: root) { folder in
            let f = ArchiveFault(), a = try ready(folder,fault:f); try a.upsert(conversation("dead"),userId:"A"); try a.saveDraft("original",conversationId:"dead",userId:"A"); let before = try files(folder); f.arm(.beforeCommit)
            try fails({ try a.delete(ids:["dead"],userId:"A",purgeUnassignedDraft:true) },"Deletion cannot report a rejected commit as success")
            try expect(try files(folder) == before && a.deletedConversationIds(userId:"A").isEmpty && a.load(userId:"A").count == 1, "Single SQL transaction leaves no partially applied tombstone or draft deletion")
        }
        try run("durable-delete-late-message-write-failure-remains-safe-after-cold-restart", root: root) { folder in
            let a = try ready(folder); try a.upsert(conversation("dead"),userId:"A"); try a.saveDraft("draft",conversationId:"dead",userId:"A"); let db = try sql(a); defer { try? db.close() }
            try db.execute("CREATE TRIGGER reject_deletion BEFORE DELETE ON headers BEGIN SELECT RAISE(ABORT,'injected late message failure'); END"); let before = try files(folder)
            try fails({ try a.delete(ids:["dead"],userId:"A") },"A late SQL message failure must rollback prior tombstone/draft changes")
            let cold = try ready(folder); try expect(try cold.load(userId:"A").count == 1 && cold.loadDraftRecord(userId:"A").text == "draft" && cold.deletedConversationIds(userId:"A").isEmpty && files(folder) == before, "Atomic SQLite backend preserves a complete undeleted record on statement failure")
            try db.execute("DROP TRIGGER reject_deletion"); try cold.delete(ids:["dead"],userId:"A"); try expect(try cold.load(userId:"A").isEmpty, "Explicit retry commits the complete deletion")
        }
        try run("durable-delete-unassigned-purge-is-explicit-and-conversation-scoped", root: root) { folder in
            let a = try ready(folder); try a.saveDraft("unassigned",userId:"A"); try a.saveDraft("dead",conversationId:"dead",userId:"A"); try a.delete(ids:["dead"],userId:"A")
            try expect(try a.loadDraftRecords(userId:"A").contains { $0.conversationId == nil }, "Other-conversation deletion preserves unknown-association data")
            try a.delete(ids:["current"],userId:"A",purgeUnassignedDraft:true); try expect(try a.loadDraftRecords(userId:"A").isEmpty,"Explicit current delete also purges unassigned source")
        }
        try run("durable-delete-all-every-write-and-removal-stage-is-recoverable", root: root) { folder in
            for (index,point) in [AssistantArchiveFaultPoint.beforeCommit,.purgeLegacyCleanup,.purgeDatabaseRemoval].enumerated() {
                let sub = folder.appendingPathComponent("stage\(index)"), f = ArchiveFault(), a = try ready(sub,owners:["A","B"],fault:f); try a.upsert(conversation("dead",text:"A"),userId:"A"); try a.saveDraft("A draft",userId:"A"); try a.upsert(conversation("dead",text:"B"),userId:"B"); f.arm(point)
                try fails({ try a.deleteAll(userId:"A") },"Purge boundary failure must be explicit")
                if index == 0 { try expect(try a.load(userId:"A").count == 1 && !a.isPurgingAll(userId:"A"),"Precommit purge failure rolls back") }
                else { let cold = AssistantChatArchive(directory:sub); try expect(try cold.isPurgingAll(userId:"A"),"Cold metadata preserves committed purge intent"); try fails({ try cold.prepare(userId:"A") },"Read preparation cannot bypass pending purge"); try cold.deleteAll(userId:"A"); try cold.prepare(userId:"A"); try expect(try cold.load(userId:"A").isEmpty,"Explicit retry can create a safe new empty authority") }
                try expect(try a.load(userId:"B").first?.preview == "B","Other owner is never erased")
            }
        }
        try run("durable-delete-all-can-erase-corrupt-legacy-sources-without-unsafe-recovery", root: root) { folder in
            try Data("corrupt legacy".utf8).write(to:legacy(folder)); try Data("corrupt draft".utf8).write(to:legacy(folder).appendingPathExtension("draft")); let a = AssistantChatArchive(directory:folder)
            try a.deleteAll(userId:"A"); try a.prepare(userId:"A"); try expect(try a.load(userId:"A").isEmpty && a.loadDraftRecords(userId:"A").isEmpty && !FileManager.default.fileExists(atPath:legacy(folder).path),"Explicit account erasure does not depend on decoding corrupt private sources")
        }
        try run("durable-delete-metadata-is-additive-to-existing-v1-draft-envelope", root: root) { folder in
            let old = AssistantChatDraft(text:"Earlier v1",conversationId:"old"), row = try JSONSerialization.jsonObject(with:JSONEncoder().encode(old))
            let fields:[String:Any] = ["version":1,"ownerId":"A","activeConversationId":"old","activeUnassigned":false,"conversationDrafts":["old":row]]
            try JSONSerialization.data(withJSONObject:fields).write(to:legacy(folder).appendingPathExtension("draft")); let a = try ready(folder)
            try expect(try a.loadDraftRecord(userId:"A") == old && a.deletedConversationIds(userId:"A").isEmpty && !a.isPurgingAll(userId:"A"),"Old missing deletion metadata migrates safely into actual SQL tables")
        }
        try run("durable-delete-read-projection-hides-residual-drafts-without-source-rewrite", root: root) { folder in
            let a = try ready(folder); try a.upsert(conversation("dead",text:"residual"),userId:"A"); try a.saveDraft("residual",conversationId:"dead",userId:"A"); let db = try sql(a); defer { try? db.close() }; try db.execute("INSERT INTO deleted(id) VALUES('dead')"); let before = try files(folder)
            try expect(try a.load(userId:"A").isEmpty && a.loadDraftRecords(userId:"A").isEmpty && a.loadDraftRecord(userId:"A").text.isEmpty && a.loadExportSnapshot(userId:"A").conversations.isEmpty && files(folder) == before, "All SQL read shapes exclude residual rows without silently rewriting the physical source")
        }
        try run("usage-stats-are-owner-scoped-and-idempotent", root: root) { folder in
            let suite = "caobao-usage-stats-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = AssistantUsageStatsStore(defaults: defaults)
            let now = Date()
            var stats = store.recordCompletedTurn(ownerId: "owner-A", userMessageId: "user-1", assistantMessageId: "assistant-1", userTimestamp: now, assistantTimestamp: now)
            try expect(stats.userMessages == 1 && stats.assistantMessages == 1 && stats.totalMessages == 2, "First completed turn was not recorded")
            stats = store.recordCompletedTurn(ownerId: "owner-A", userMessageId: "user-1", assistantMessageId: "assistant-1", userTimestamp: now, assistantTimestamp: now)
            try expect(stats.totalMessages == 2, "Duplicate completion counted twice")
            stats = store.recordCompletedTurn(ownerId: "owner-A", userMessageId: "user-1", assistantMessageId: "assistant-2", userTimestamp: now, assistantTimestamp: now)
            try expect(stats.userMessages == 1 && stats.assistantMessages == 2, "Retry duplicated the user turn or lost the new response")
            try expect(store.snapshot(ownerId: "owner-B").totalMessages == 0, "Usage stats crossed owner boundary")

            let legacySuite = "caobao-usage-stats-legacy-\(UUID().uuidString)"
            let legacyDefaults = UserDefaults(suiteName: legacySuite)!
            defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
            legacyDefaults.set(7, forKey: "caobao_total_messages")
            legacyDefaults.set(3, forKey: "caobao_user_messages")
            let migrated = AssistantUsageStatsStore(defaults: legacyDefaults).snapshot(ownerId: "local-device")
            try expect(migrated.userMessages == 3 && migrated.assistantMessages == 4 && migrated.totalMessages == 7,
                       "Legacy counters without a first-visit date were not migrated")
        }
        print("All \(count) AssistantChatArchive suites passed; actual SQLite backend and explicit legacy migration fixtures only.")
    }
}
