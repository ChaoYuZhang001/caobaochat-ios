import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private struct ImportTestFailure: Error, CustomStringConvertible { let description: String }

@main
private enum AssistantDataImportTests {
    private static let date = Date(timeIntervalSince1970: 1_793_232_000)
    private static var groups = 0
    private final class Fixture {
        let directory: URL
        let archive: AssistantChatArchive
        let repository: AssistantLocalRepository
        init(empty: Bool = false, owner: String = "A") throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("caobao-import-" + UUID().uuidString)
            archive = AssistantChatArchive(directory: directory.appendingPathComponent("archive"))
            repository = AssistantLocalRepository(fileURL: directory.appendingPathComponent("repository.json"))
            try archive.prepare(userId: owner)
            if !empty {
                try archive.upsert(Conversation(id: "conversation-1", title: "Original title", preview: "Visible answer", date: date,
                    messages: [ChatMessage(id: "user-1", role: .user, content: "hello", timestamp: date),
                        ChatMessage(id: "assistant-1", role: .assistant, content: "Visible answer", timestamp: date)],
                    serverConversationId: "server-original"), userId: owner)
                _ = try archive.selectDraft(conversationId: "conversation-1", preserving: nil,
                    initialDraft: AssistantChatDraft(text: "Unsent original draft", conversationId: "conversation-1"), userId: owner)
                repository.addMemory(AssistantMemory(id: "memory-1", userId: owner, category: .preference,
                    text: "Keep answers concise", sourceMessageId: "user-1", consent: "explicit", status: .active, createdAt: date, updatedAt: date))
                repository.addTask(AssistantTask(id: "task-1", userId: owner, title: "Plan trip", instructions: "Pack a bag", dueAt: date,
                    timeZone: "UTC", recurrenceRule: nil, requiresApproval: false, status: .active,
                    createdAt: date, updatedAt: date, reminderEnabled: true))
                guard repository.lastError == nil else { throw ImportTestFailure(description: "Production fixture did not save") }
            }
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func export(owner: String = "A", images: Bool = true) throws -> Data {
            try AssistantDataExporter(archive: archive, repository: repository).export(ownerId: owner, includeImages: images, exportedAt: date).data
        }
    }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw ImportTestFailure(description: message) }
    }
    private static func run(_ name: String, _ body: () throws -> Void) throws {
        try body(); groups += 1; print("PASS import: " + name)
    }
    private static func rejected(_ data: Data, owner: String = "A", importer: AssistantDataImporter = .init(), _ expected: AssistantDataImportError? = nil) throws {
        do { _ = try importer.prepare(data: data, ownerId: owner) }
        catch {
            if let expected { try expect((error as? AssistantDataImportError) == expected, "Wrong rejection: " + String(describing: error)) }
            return
        }
        throw ImportTestFailure(description: "Expected fail-closed rejection")
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    private static func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func changed(_ data: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var value = try object(data); edit(&value); return try encoded(value)
    }
    private static func image() throws -> AssistantImage {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let data = NSMutableData(), destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImportTestFailure(description: "JPEG fixture failed") }
        return try AssistantImagePreprocessor.prepare(data as Data)
    }
    static func main() throws {
        let fixture = try Fixture(), data = try fixture.export(), importer = AssistantDataImporter()
        try run("real export roundtrip and permission neutralization") {
            let plan = try importer.prepare(data: data, ownerId: "A")
            try expect(plan.conversations.count == 1 && plan.drafts.count == 1 && plan.memories.count == 1 && plan.tasks.count == 1, "All exported categories preserved")
            try expect(plan.tasks[0].reminderEnabled == false && plan.tasks[0].requiresApproval, "Imported tasks must require fresh authorization")
            try expect(plan.memories[0].consent == "unconfirmed", "Imported memory is not silently authorized")
            try expect(plan.conversations[0].serverConversationId == nil, "Server authority must not survive")
            try expect(plan.drafts[0].text == "Unsent original draft", "Unsent text preserved")
        }
        try run("stable content digest") {
            try expect(importer.prepare(data: data, ownerId: "A").backupDigest == importer.prepare(data: data, ownerId: "A").backupDigest, "Repeated bytes must have stable identity")
        }
        try run("old v1 additive fields may be absent") {
            let old = try changed(data) { for key in ["conversationDrafts", "taskPreferences", "taskToolReceipts"] { $0.removeValue(forKey: key) } }
            let plan = try importer.prepare(data: old, ownerId: "A")
            try expect(plan.conversations.count == 1 && plan.ignoredReceiptCount == 0, "Old supported v1 still readable")
        }
        try run("explicit null additive fields rejected") {
            for key in ["conversationDrafts", "taskPreferences", "taskToolReceipts"] { try rejected(changed(data) { $0[key] = NSNull() }) }
        }
        try run("unsupported schema version and encoding") {
            for (key, value) in [("schemaName", "other" as Any), ("schemaVersion", 2 as Any), ("dateEncoding", "reference-date" as Any)] {
                try rejected(changed(data) { $0[key] = value }, .unsupportedVersion)
            }
        }
        try run("wrong owner and nested ownership rejected") {
            try rejected(data, owner: "B", .ownerMismatch)
            try rejected(changed(data) { var rows = $0["memories"] as! [[String: Any]]; rows[0]["userId"] = "B"; $0["memories"] = rows }, .invalidRecord)
            try rejected(changed(data) { var rows = $0["tasks"] as! [[String: Any]]; rows[0]["userId"] = "B"; $0["tasks"] = rows }, .invalidRecord)
        }
        try run("Unicode equivalent owners remain distinct") {
            let source = try Fixture(owner: "é"), bytes = try source.export(owner: "é")
            try rejected(bytes, owner: "e\u{301}", .ownerMismatch)
            try expect(importer.prepare(data: bytes, ownerId: "é").ownerId.utf8.elementsEqual("é".utf8), "Same raw owner accepted")
        }
        try run("duplicate object keys and escaped duplicates") {
            for text in [#"{"ownerId":"A","ownerId":"A"}"#, #"{"ownerId":"A","\u006fwnerId":"A"}"#, #"{"nested":{"title":1,"title":2}}"#] {
                try rejected(Data(text.utf8), .invalidFormat)
            }
        }
        try run("unexpected root and record fields rejected") {
            try rejected(changed(data) { $0["apiKey"] = "not-a-credential" }, .invalidFormat)
            try rejected(changed(data) { var rows = $0["tasks"] as! [[String: Any]]; rows[0]["endpoint"] = "https://example.com"; $0["tasks"] = rows }, .invalidFormat)
        }
        try run("non-object malformed and wrong scalar types") {
            for text in ["[]", "null", "{", "{\"a\":NaN}", "{\"a\":1} trailing"] { try rejected(Data(text.utf8)) }
            try rejected(changed(data) { $0["schemaVersion"] = true }, .invalidFormat)
            try rejected(changed(data) { $0["imagesIncluded"] = "false" }, .invalidFormat)
        }
        try run("byte limit and configuration bounds") {
            try rejected(data, importer: .init(maximumBytes: data.count - 1), .tooLarge)
            try rejected(data, importer: .init(maximumBytes: 0), .invalidConfiguration)
            try rejected(data, importer: .init(maximumBytes: 64 * 1024 * 1024 + 1), .invalidConfiguration)
        }
        try run("bounded nesting") {
            let nested = String(repeating: "[", count: 35) + "0" + String(repeating: "]", count: 35)
            try rejected(Data(nested.utf8), .tooLarge)
        }
        try run("duplicate conversation and message identities") {
            try rejected(changed(data) { var rows = $0["conversations"] as! [[String: Any]]; rows.append(rows[0]); $0["conversations"] = rows }, .invalidRecord)
            try rejected(changed(data) { var rows = $0["conversations"] as! [[String: Any]]; var messages = rows[0]["messages"] as! [[String: Any]]; messages[1]["id"] = messages[0]["id"]; rows[0]["messages"] = messages; $0["conversations"] = rows }, .invalidRecord)
        }
        try run("control identifiers fail before storage") {
            for key in ["memories", "tasks"] {
                try rejected(changed(data) { var rows = $0[key] as! [[String: Any]]; rows[0]["id"] = "invalid\u{85}identifier"; $0[key] = rows }, .invalidRecord)
            }
        }
        try run("duplicate memory and task records") {
            for key in ["memories", "tasks"] { try rejected(changed(data) { var rows = $0[key] as! [[String: Any]]; rows.append(rows[0]); $0[key] = rows }, .invalidRecord) }
        }
        try run("pending and streaming are interrupted history") {
            for status in ["pending", "streaming"] {
                let changed = try changed(data) { var rows = $0["conversations"] as! [[String: Any]]; var messages = rows[0]["messages"] as! [[String: Any]]; messages[1]["status"] = status; messages[1]["requestId"] = "old-request"; messages[1]["generationId"] = "old-generation"; messages[1]["replacesMessageId"] = "old-message"; rows[0]["messages"] = messages; $0["conversations"] = rows }
                let message = try importer.prepare(data: changed, ownerId: "A").conversations[0].messages[1]
                try expect(message.status == .failed && message.requestId == nil && message.generationId == nil && message.replacesMessageId == nil, "No imported live generation")
            }
        }
        try run("draft-only real production export remains recoverable") {
            let source = try Fixture(empty: true)
            _ = try source.archive.selectDraft(conversationId: "new-without-header", preserving: nil,
                initialDraft: AssistantChatDraft(text: "Only an unsent draft", conversationId: "new-without-header"), userId: "A")
            let plan = try importer.prepare(data: source.export(), ownerId: "A")
            try expect(plan.conversations.count == 1 && plan.conversations[0].messages.isEmpty && plan.drafts[0].text == "Only an unsent draft", "Orphan draft must have a readable restored route")
            try expect(plan.conversations[0].id == "new-without-header" && plan.drafts[0].conversationId == "new-without-header", "Original draft ID preserved")
        }
        try run("empty new-chat export is valid without phantom content") {
            let source = try Fixture(empty: true)
            _ = try source.archive.selectDraft(conversationId: "new-empty", preserving: nil, initialDraft: AssistantChatDraft(text: "", conversationId: "new-empty"), userId: "A")
            let plan = try importer.prepare(data: source.export(), ownerId: "A")
            try expect(plan.conversations.isEmpty && plan.drafts.isEmpty, "Empty orphan need not invent a history conversation")
        }
        try run("legacy unassigned draft gets deterministic independent route") {
            let source = try Fixture(empty: true)
            try source.archive.saveDraft("Unassigned saved text", userId: "A")
            let bytes = try source.export(), first = try importer.prepare(data: bytes, ownerId: "A"), second = try importer.prepare(data: bytes, ownerId: "A")
            try expect(first.drafts.count == 1 && first.drafts[0].conversationId != nil && first.drafts == second.drafts, "Unassigned draft must be stable and not overwrite live slot")
        }
        try run("duplicate draft slots rejected") {
            try rejected(changed(data) { $0["conversationDrafts"] = [$0["draft"]!] }, .invalidRecord)
        }
        try run("pre1970 and post2200 tasks roundtrip") {
            for seconds in [-31_536_000.0, 7_289_654_400.0] {
                let source = try Fixture(empty: true)
                source.repository.addTask(AssistantTask(id: "old-task", userId: "A", title: "Calendar boundary", dueAt: Date(timeIntervalSince1970: seconds), timeZone: "UTC", requiresApproval: false, status: .active, createdAt: date, updatedAt: date))
                try expect(source.repository.lastError == nil, "Existing repository supports date")
                try expect(importer.prepare(data: source.export(), ownerId: "A").tasks[0].dueAt?.timeIntervalSince1970 == seconds, "Supported old date must not reject entire backup")
            }
        }
        try run("pathological finite dates rejected") {
            try rejected(changed(data) { $0["exportedAt"] = 1e100 }, .invalidRecord)
        }
        try run("task shape recurrence and memory limits") {
            try rejected(changed(data) { var rows = $0["tasks"] as! [[String: Any]]; rows[0]["recurrenceRule"] = "FREQ=MINUTELY"; $0["tasks"] = rows }, .invalidRecord)
            try rejected(changed(data) { var rows = $0["memories"] as! [[String: Any]]; rows[0]["text"] = String(repeating: "m", count: 20_001); $0["memories"] = rows }, .invalidRecord)
        }
        try run("deleted memory never recovers erased body or consent") {
            let bytes = try changed(data) { var rows = $0["memories"] as! [[String: Any]]; rows[0]["status"] = "deleted"; rows[0]["text"] = "Should be erased"; $0["memories"] = rows }
            let memory = try importer.prepare(data: bytes, ownerId: "A").memories[0]
            try expect(memory.text.isEmpty && memory.sourceMessageId == nil && memory.status == .deleted && memory.consent == "unconfirmed", "Deleted body remains erased")
        }
        try run("valid JPEG preserved and malformed image rejected") {
            let picture = try image()
            try fixture.archive.saveDraft("Draft with image", images: [picture], conversationId: "conversation-1", userId: "A")
            let bytes = try fixture.export(), plan = try importer.prepare(data: bytes, ownerId: "A")
            try expect(plan.drafts.first?.images?.first == picture, "Valid image bytes preserved")
            try rejected(changed(bytes) { var draft = $0["draft"] as! [String: Any]; var images = draft["images"] as! [[String: Any]]; images[0]["base64Data"] = "not-base64"; draft["images"] = images; $0["draft"] = draft }, .invalidImage)
        }
        try run("image omission contract enforced") {
            let bytes = try fixture.export(images: false), plan = try importer.prepare(data: bytes, ownerId: "A")
            try expect(plan.omittedImageCount == 1 && (plan.drafts.first?.images?.isEmpty ?? true), "Omitted count preserved, no image invented")
            try rejected(changed(data) { $0["omittedImageCount"] = -1 }, .invalidRecord)
        }
        try run("regular file bounded read and unsafe paths") {
            let file = fixture.directory.appendingPathComponent("backup.json"), link = fixture.directory.appendingPathComponent("link.json")
            try data.write(to: file)
            try expect(importer.prepare(url: file, ownerId: "A").conversations.count == 1, "Selected regular file supported")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            do { _ = try importer.prepare(url: link, ownerId: "A"); throw ImportTestFailure(description: "Symlink accepted") } catch is ImportTestFailure { throw ImportTestFailure(description: "Symlink accepted") } catch { }
            do { _ = try importer.prepare(url: fixture.directory, ownerId: "A"); throw ImportTestFailure(description: "Directory accepted") } catch is ImportTestFailure { throw ImportTestFailure(description: "Directory accepted") } catch { }
            try rejected(data, importer: .init(maximumBytes: 4), .tooLarge)
        }
        try run("tool proposals become inert visible text and receipts not authority") {
            let arguments = #"{"title":"A restored tool task","notes":"Keep this note","due_at":null,"time_zone":null,"reminder_requested":true}"#
            let trace: [[String: Any]] = [["role": "assistant", "content": "Visible answer", "tool_calls": [["id": "call-1", "type": "function", "function": ["name": "create_task", "arguments": arguments]]]]]
            let traceJSON = String(data: try JSONSerialization.data(withJSONObject: trace, options: [.sortedKeys]), encoding: .utf8)!
            let call = AssistantTaskToolCall(id: "call-1", name: "create_task", arguments: arguments, trace: AssistantTaskToolTrace(protocolKind: .chatCompletions, assistantItemsJSON: traceJSON))
            let proposal = try AssistantTaskProposal(call: call, ownerId: "A", conversationId: "conversation-1", assistantMessageId: "assistant-1", sourceUserMessageId: "user-1", sourceUserText: "hello", configurationFingerprint: String(repeating: "a", count: 64), createdAt: date)
            try fixture.archive.upsert(Conversation(id: "conversation-1", title: "Task audit", preview: "Visible answer", date: date,
                messages: [ChatMessage(id: "user-1", role: .user, content: "hello", timestamp: date), ChatMessage(id: "assistant-1", role: .assistant, content: "Visible answer", timestamp: date, requestId: "remote-request", generationId: "remote-generation", taskProposal: proposal)], serverConversationId: "remote-conversation"), userId: "A")
            let receipt = AssistantTaskToolReceipt(ownerId: "A", proposalId: proposal.id, taskId: nil, decision: .declined, reminderState: .notRequested, committedAt: date, revision: 1)
            _ = try fixture.repository.commitTaskToolDecline(receipt)
            let plan = try importer.prepare(data: fixture.export(), ownerId: "A"), message = plan.conversations[0].messages[1]
            try expect(plan.neutralizedProposalCount == 1 && plan.ignoredReceiptCount == 1, "Audit conversion counted")
            try expect(message.taskProposal == nil && message.requestId == nil && message.generationId == nil && message.content.contains("A restored tool task") && message.content.contains("declined"), "Visible history retained without execution tickets")
        }
        try run("proposal source digest tampering rejected") {
            let bytes = try fixture.export()
            try rejected(changed(bytes) { var rows = $0["conversations"] as! [[String: Any]]; var messages = rows[0]["messages"] as! [[String: Any]]; messages[0]["content"] = "tampered"; rows[0]["messages"] = messages; $0["conversations"] = rows }, .invalidRecord)
        }
        print("Assistant data-import checks passed: \(groups) independent groups")
    }
}
