import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private struct ExportTestFailure: Error, CustomStringConvertible { let description: String }

@main
@MainActor
private enum AssistantDataExportTests {
    private static let date = Date(timeIntervalSince1970: 1_793_232_000.125)
    private static var suites = 0

    private struct MemoryPreferences: Decodable {
        let memoryEnabled: Bool
        let excludedMemoryCategories: [AssistantMemoryCategory]
    }
    private struct TaskPreferences: Decodable { let quietHours: AssistantQuietHours }
    private struct Payload: Decodable {
        let schemaName: String
        let schemaVersion: Int
        let dateEncoding: String
        let ownerId: String
        let exportedAt: Date
        let includedScopes: [String]
        let imagesIncluded: Bool
        let omittedImageCount: Int
        let conversations: [Conversation]
        let draft: AssistantChatDraft
        // Additive v1 field; earlier exports did not contain inactive drafts.
        let conversationDrafts: [AssistantChatDraft]?
        let memories: [AssistantMemory]
        let tasks: [AssistantTask]
        let memoryPreferences: MemoryPreferences
        // Earlier schemaVersion 1 exports did not include reminder preferences.
        let taskPreferences: TaskPreferences?
    }
    private struct Fixture {
        let directory: URL
        let archiveDirectory: URL
        let repositoryURL: URL
        let archive: AssistantChatArchive
        let repository: AssistantLocalRepository
        init(_ directory: URL) throws {
            self.directory = directory
            archiveDirectory = directory.appendingPathComponent("archive", isDirectory: true)
            repositoryURL = directory.appendingPathComponent("repository.json")
            archive = AssistantChatArchive(directory: archiveDirectory)
            repository = AssistantLocalRepository(fileURL: repositoryURL)
            for owner in ["A", "B", "C"] { try archive.prepare(userId: owner) }
        }
        var exporter: AssistantDataExporter { AssistantDataExporter(archive: archive, repository: repository) }
    }

    private static func withDatabase<T>(_ archive: AssistantChatArchive, owner: String = "A", _ operation: (AssistantChatDatabase) throws -> T) throws -> T {
        let database = try AssistantChatDatabase(url: archive.databaseURL(userId: owner), create: false)
        defer { try? database.close() }
        return try operation(database)
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ExportTestFailure(description: message) }
    }
    private static func failure(stage: String = "export", _ operation: () throws -> Void) throws -> Error {
        do { try operation() }
        catch { return error }
        throw ExportTestFailure(description: "Expected an explicit failure at stage: " + stage)
    }
    private static func decode(_ data: Data) throws -> Payload {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(Payload.self, from: data)
    }
    private static func pass(_ name: String) { suites += 1; print("PASS " + name) }
    private static func run(_ name: String, root: URL, _ operation: (URL) throws -> Void) throws {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { try operation(directory) }
        catch { throw ExportTestFailure(description: name + ": " + String(describing: error)) }
        pass(name)
    }
    private static func image() throws -> AssistantImage {
        let bytes = Data([UInt8](repeating: 160, count: 12))
        guard let provider = CGDataProvider(data: bytes as CFData),
              let picture = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 6,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ExportTestFailure(description: "Cannot create isolated image fixture")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ExportTestFailure(description: "Cannot create JPEG fixture")
        }
        CGImageDestinationAddImage(destination, picture, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExportTestFailure(description: "Cannot finalize JPEG fixture") }
        return try AssistantImagePreprocessor.prepare(data as Data)
    }
    private static func memory(_ id: String, owner: String, text: String, consent: String = "explicit",
                               status: AssistantMemoryStatus = .active) -> AssistantMemory {
        AssistantMemory(id: id, userId: owner, category: .fact, text: text, sourceMessageId: "source-" + id,
            consent: consent, status: status, createdAt: date, updatedAt: date)
    }
    private static func conversation(_ id: String, text: String, images: [AssistantImage]? = nil) -> Conversation {
        Conversation(id: id, title: "Plan " + id, preview: text, date: date,
            messages: [ChatMessage(id: "user-" + id, role: .user, content: text, timestamp: date, images: images),
                ChatMessage(id: "assistant-" + id, role: .assistant, content: "partial answer", timestamp: date,
                    liked: true, status: .streaming, requestId: "request-" + id, generationId: "generation-" + id,
                    model: "provider/model:version", usage: AssistantUsage(inputTokens: 11, outputTokens: 5))],
            serverConversationId: "server-" + id)
    }
    private static func task(_ id: String, owner: String, status: AssistantTaskStatus = .active) -> AssistantTask {
        AssistantTask(id: id, userId: owner, title: "Task " + id, instructions: "local task details",
            dueAt: date.addingTimeInterval(3_600), timeZone: "Asia/Shanghai", recurrenceRule: "FREQ=DAILY",
            requiresApproval: true, status: status, createdAt: date, updatedAt: date, reminderEnabled: true)
    }
    private static func snapshotFiles(_ directory: URL) throws -> [String: Data] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(directory.path.count))] = try Data(contentsOf: url)
            }
        }
        return result
    }
    private static func json(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExportTestFailure(description: "Export must be a JSON object")
        }
        return result
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caobao-export-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try run("export-versioned-owned-data-roundtrip", root: root) { directory in
            let f = try Fixture(directory), picture = try image()
            try f.archive.upsert(conversation("A", text: "private A", images: [picture]), userId: "A")
            try f.archive.saveDraft("A draft", images: [picture], conversationId: "A", userId: "A")
            f.repository.addMemory(memory("A-memory", owner: "A", text: "A fact"))
            f.repository.addTask(task("A-task", owner: "A"))
            let result = try f.exporter.export(ownerId: "A", exportedAt: date)
            let value = try decode(result.data)
            try expect(value.schemaName == "caobao.assistant.local-export" && value.schemaVersion == 1 && value.dateEncoding == "unix-seconds", "Version/date schema must be explicit")
            try expect(value.ownerId == "A" && value.exportedAt == date, "Metadata is bound to the requested owner and timestamp")
            try expect(Set(value.includedScopes) == ["conversations", "draft", "conversationDrafts", "memories", "tasks", "memoryPreferences", "reminder-preferences", "taskToolReceipts"], "Included data scopes must be auditable")
            try expect(result.conversationCount == 1 && result.memoryCount == 1 && result.taskCount == 1 && result.omittedImageCount == 0, "Result counts describe actual data")
            try expect(value.conversations[0].messages[0].images == [picture] && value.draft.images == [picture], "Images round trip without fetching or transcoding")
            try expect(value.draft.text == "A draft" && value.draft.conversationId == "A", "Draft association remains intact")
            try expect(value.conversations[0].messages[1].status == .streaming && value.conversations[0].messages[1].usage?.outputTokens == 5, "Snapshot must retain partial status and usage without pretending to generate")
            try expect(value.tasks[0].timeZone == "Asia/Shanghai" && value.tasks[0].recurrenceRule == "FREQ=DAILY" && value.tasks[0].reminderEnabled == true, "Task data is preserved, not executed")
            try expect(abs(value.memories[0].createdAt.timeIntervalSince(date)) < 0.000_001, "Subsecond timestamps must survive declared date decoding")
        }
        try run("export-account-isolation-and-empty-account", root: root) { directory in
            let f = try Fixture(directory)
            for owner in ["A", "B"] {
                try f.archive.upsert(conversation("same", text: "private-" + owner), userId: owner)
                try f.archive.saveDraft("draft-" + owner, userId: owner)
                f.repository.addMemory(memory("same", owner: owner, text: "memory-" + owner))
                f.repository.addTask(task("same", owner: owner))
            }
            let a = try decode(f.exporter.export(ownerId: "A", exportedAt: date).data)
            try expect(a.conversations[0].messages[0].content == "private-A" && a.draft.text == "draft-A", "A cannot export B's conversation/draft")
            try expect(a.memories.allSatisfy { $0.userId == "A" } && a.tasks.allSatisfy { $0.userId == "A" }, "A cannot export B's repository records")
            let c = try decode(f.exporter.export(ownerId: "C", exportedAt: date).data)
            try expect(c.conversations.isEmpty && c.draft.text.isEmpty && c.memories.isEmpty && c.tasks.isEmpty, "A genuinely empty account exports empty arrays rather than borrowing another account")
        }
        try run("export-disabled-memories-and-tombstones", root: root) { directory in
            let f = try Fixture(directory)
            f.repository.addMemory(memory("active", owner: "A", text: "retained"))
            f.repository.addMemory(memory("disabled", owner: "A", text: "disabled but manageable", consent: "disabled"))
            f.repository.addMemory(memory("deleted", owner: "A", text: "deleted body must never return"))
            try expect(f.repository.deleteMemory(id: "deleted", userId: "A"), "Fixture deletion must commit")
            f.repository.setMemoryEnabled(false, for: "A")
            try expect(f.repository.setMemoryCategoryEnabled(false, category: .fact, for: "A"), "Category preference must commit")
            try expect(f.repository.setMemoryCategoryEnabled(false, category: .importantDate, for: "A"), "Second category preference must commit")
            let value = try decode(f.exporter.export(ownerId: "A", exportedAt: date).data)
            try expect(value.memories.count == 3 && value.memories.first { $0.id == "disabled" }?.consent == "disabled", "Disabled and deleted records remain part of the backup")
            let tombstone = value.memories.first { $0.id == "deleted" }
            try expect(tombstone?.status == .deleted && tombstone?.text == "" && tombstone?.sourceMessageId == nil, "A tombstone must not restore deleted text/source")
            try expect(!value.memoryPreferences.memoryEnabled && Set(value.memoryPreferences.excludedMemoryCategories) == [.fact, .importantDate], "Global and category privacy choices must be exported")
        }
        try run("export-redacts-residual-tombstone-without-mutating-source", root: root) { directory in
            let f = try Fixture(directory)
            let legacy = memory("legacy-deleted", owner: "A", text: "residual legacy secret")
            try expect(f.repository.insertMemory(legacy), "Active fixture baseline must actually persist")
            // Simulate a historical on-disk defect; current mutation APIs correctly
            // refuse deleted inserts and never recreate residual tombstone content.
            var stored = try json(Data(contentsOf: f.repositoryURL))
            var owners = stored["memories"] as! [String: [[String: Any]]]
            owners["A"]![0]["status"] = AssistantMemoryStatus.deleted.rawValue
            stored["memories"] = owners
            let legacyBytes = try JSONSerialization.data(withJSONObject: stored, options: .sortedKeys)
            try legacyBytes.write(to: f.repositoryURL, options: .atomic)
            let originalRow = (try json(Data(contentsOf: f.repositoryURL))["memories"] as! [String: [[String: Any]]])["A"]![0]
            try expect(originalRow["status"] as? String == "deleted" && originalRow["text"] as? String == legacy.text
                && originalRow["sourceMessageId"] as? String == legacy.sourceMessageId, "Legacy disk fixture must really contain deleted status, private residual body and source")
            let repository = AssistantLocalRepository(fileURL: f.repositoryURL)
            try expect(repository.lastError == nil && repository.memories(for: "A").isEmpty, "Historical tombstone loads but is not an active memory")
            let exporter = AssistantDataExporter(archive: f.archive, repository: repository)
            let before = try snapshotFiles(directory)
            let result = try exporter.export(ownerId: "A", exportedAt: date)
            let value = try decode(result.data)
            try expect(result.memoryCount == 1 && value.memories.count == 1 && value.memories[0].id == legacy.id
                && value.memories[0].status == .deleted && value.memories[0].text.isEmpty && value.memories[0].sourceMessageId == nil, "Even a legacy tombstone with residual content must stay redacted")
            let exportedText = String(decoding: result.data, as: UTF8.self)
            try expect(!exportedText.contains(legacy.text) && !exportedText.contains(legacy.sourceMessageId!), "No residual body or provenance may leak elsewhere in exported JSON")
            try expect(try snapshotFiles(directory) == before, "Export must not rewrite the local store while redacting its returned copy")
        }
        try run("export-images-omitted-explicitly-and-counted", root: root) { directory in
            let f = try Fixture(directory), picture = try image()
            try f.archive.upsert(conversation("A", text: "same text", images: [picture, picture]), userId: "A")
            try f.archive.saveDraft("same draft", images: [picture], conversationId: "A", userId: "A")
            let before = try snapshotFiles(directory)
            let result = try f.exporter.export(ownerId: "A", includeImages: false, exportedAt: date)
            let value = try decode(result.data)
            try expect(result.omittedImageCount == 3 && value.omittedImageCount == 3 && !value.imagesIncluded, "Count every omitted attachment occurrence including the draft")
            try expect(value.conversations.allSatisfy { $0.messages.allSatisfy { $0.images == nil } } && value.draft.images == nil, "No excluded attachment bytes may remain")
            try expect(value.conversations[0].messages[0].content == "same text" && value.draft.text == "same draft", "Image exclusion must not truncate text")
            try expect(try snapshotFiles(directory) == before, "Image exclusion mutates only the export copy")
        }
        try run("export-field-allowlist-retains-user-authored-text", root: root) { directory in
            let f = try Fixture(directory)
            let text = "I wrote apiKey=personal-note, refreshToken and accessToken in my own text; do not censor it."
            try f.archive.upsert(conversation("A", text: text), userId: "A")
            let data = try f.exporter.export(ownerId: "A", exportedAt: date).data
            let object = try json(data)
            let expected: Set<String> = ["schemaName", "schemaVersion", "dateEncoding", "ownerId", "exportedAt", "includedScopes", "imagesIncluded", "omittedImageCount", "conversations", "draft", "conversationDrafts", "memories", "tasks", "memoryPreferences", "taskPreferences", "taskToolReceipts"]
            try expect(Set(object.keys) == expected, "Only known export scopes may appear at the top level")
            let forbidden: Set<String> = ["accessToken", "refreshToken", "apiKey", "authorization", "headers", "baseURL", "session"]
            func checkKeys(_ value: Any) throws {
                if let dictionary = value as? [String: Any] {
                    if !forbidden.isDisjoint(with: dictionary.keys) {
                        throw ExportTestFailure(description: "Credential/configuration fields must never be exported")
                    }
                    for nested in dictionary.values { try checkKeys(nested) }
                } else if let array = value as? [Any] { for nested in array { try checkKeys(nested) } }
            }
            try checkKeys(object)
            try expect(try decode(data).conversations[0].messages[0].content == text, "Arbitrary user text is data, not a credential field to remove by regex")
        }
        try run("export-corrupt-conversation-preserves-original", root: root) { directory in
            let f = try Fixture(directory)
            try f.archive.upsert(conversation("A", text: "private"), userId: "A")
            let broken = Data("{broken original conversation bytes".utf8)
            try withDatabase(f.archive) { try $0.execute("UPDATE bodies SET payload=? WHERE id=?", [.blob(broken), .text("A")]) }
            let before = try snapshotFiles(directory)
            let error = try failure { _ = try f.exporter.export(ownerId: "A") }
            try expect(error as? AssistantDataExportError == .archiveReadFailed, "Corrupt actual SQLite conversation must fail, not produce empty success")
            let stored = try withDatabase(f.archive) { try $0.rows("SELECT payload FROM bodies WHERE id=?", [.text("A")]).first?.first?.data }
            try expect(stored == broken && (try snapshotFiles(directory)) == before, "Failed export preserves the corrupt stored body and every source byte")
        }
        try run("export-corrupt-draft-preserves-original", root: root) { directory in
            let f = try Fixture(directory)
            try f.archive.saveDraft("draft", userId: "A")
            let broken = Data("{broken original draft bytes".utf8)
            try withDatabase(f.archive) { try $0.execute("UPDATE drafts SET payload=? WHERE conversation_id IS NULL", [.blob(broken)]) }
            let before = try snapshotFiles(directory)
            let error = try failure { _ = try f.exporter.export(ownerId: "A") }
            try expect(error as? AssistantDataExportError == .archiveReadFailed, "Corrupt actual SQLite draft cannot become an empty backup")
            let stored = try withDatabase(f.archive) { try $0.rows("SELECT payload FROM drafts WHERE conversation_id IS NULL").first?.first?.data }
            try expect(stored == broken && (try snapshotFiles(directory)) == before, "Failed draft export preserves the corrupt stored payload and source bytes")
        }
        try run("export-repository-load-failure-is-not-empty-success", root: root) { directory in
            let f = try Fixture(directory), broken = Data("{broken original repository bytes".utf8)
            try broken.write(to: f.repositoryURL)
            let repo = AssistantLocalRepository(fileURL: f.repositoryURL)
            let error = try failure { _ = try AssistantDataExporter(archive: f.archive, repository: repo).export(ownerId: "A") }
            guard let error = error as? AssistantRepositoryError else { throw ExportTestFailure(description: "Repository load failure must propagate") }
            guard case .corruptStore = error else { throw ExportTestFailure(description: "Expected explicit corrupt store failure") }
            try expect(try Data(contentsOf: f.repositoryURL) == broken, "Export cannot overwrite a corrupt repository")
        }
        try run("export-unreadable-repository-is-not-empty-success", root: root) { directory in
            let obstruction = directory.appendingPathComponent("store-is-a-directory", isDirectory: true)
            try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: true)
            try Data("preserve directory contents".utf8).write(to: obstruction.appendingPathComponent("original.txt"))
            let before = try snapshotFiles(directory)
            let repo = AssistantLocalRepository(fileURL: obstruction)
            let archive = AssistantChatArchive(directory: directory.appendingPathComponent("archive", isDirectory: true))
            let error = try failure { _ = try AssistantDataExporter(archive: archive, repository: repo).export(ownerId: "A") }
            guard let error = error as? AssistantRepositoryError else { throw ExportTestFailure(description: "Repository read failure must propagate") }
            guard case .unreadableStore = error else { throw ExportTestFailure(description: "Expected explicit unreadable store failure") }
            try expect(try snapshotFiles(directory) == before, "Unreadable source contents must remain untouched")
        }
        try run("export-ordinary-mutation-error-does-not-hide-valid-data", root: root) { directory in
            let f = try Fixture(directory)
            f.repository.addMemory(memory("valid", owner: "A", text: "retained data"))
            try expect(!f.repository.updateTaskStatus(id: "missing", userId: "A", status: .completed) && f.repository.lastError != nil, "Fixture must produce a recoverable mutation error")
            let value = try decode(f.exporter.export(ownerId: "A", exportedAt: date).data)
            try expect(value.memories.first?.text == "retained data", "lastError is not equivalent to a failed store load")
        }
        try run("export-exact-budget-and-json-escaping", root: root) { directory in
            let f = try Fixture(directory)
            let text = "quote\" slash/ backslash\\ newline\n tab\t nul\u{0000} control\u{0001} paragraph\u{2028}\u{2029} 中文 🚀"
            try f.archive.upsert(conversation("A", text: text), userId: "A")
            f.repository.addMemory(memory("escape", owner: "A", text: text))
            let baseline = try f.exporter.export(ownerId: "A", exportedAt: date)
            let exact = try AssistantDataExporter(archive: f.archive, repository: f.repository, maximumBytes: baseline.data.count).export(ownerId: "A", exportedAt: date)
            try expect(exact.data == baseline.data && decode(exact.data).memories[0].text == text, "An exact-fitting valid JSON export must succeed unchanged")
            let error = try failure { _ = try AssistantDataExporter(archive: f.archive, repository: f.repository, maximumBytes: baseline.data.count - 1).export(ownerId: "A", exportedAt: date) }
            try expect(error as? AssistantDataExportError == .tooLarge, "One byte over the configured limit must fail without truncation")
        }
        try run("export-preflights-large-image-and-can-exclude-it", root: root) { directory in
            let f = try Fixture(directory)
            let large = AssistantImage(id: "large", mimeType: "image/jpeg", base64Data: String(repeating: "a/", count: 500_000), width: 1, height: 1)
            try f.archive.upsert(conversation("A", text: "retained", images: [large]), userId: "A")
            let before = try snapshotFiles(directory)
            let exporter = AssistantDataExporter(archive: f.archive, repository: f.repository, maximumBytes: 16_384)
            let error = try failure { _ = try exporter.export(ownerId: "A", exportedAt: date) }
            try expect(error as? AssistantDataExportError == .tooLarge, "Known oversized base64 must fail the budget")
            let small = try exporter.export(ownerId: "A", includeImages: false, exportedAt: date)
            try expect(small.data.count <= 16_384 && small.omittedImageCount == 1, "Explicit image exclusion can produce an honest smaller backup")
            try expect(try snapshotFiles(directory) == before, "Budget failure and exclusion must preserve source bytes")
        }
        try run("export-invalid-owner-and-configuration-create-no-files", root: root) { directory in
            let f = try Fixture(directory)
            let before = try snapshotFiles(directory)
            for owner in ["", " \n\t", String(repeating: "x", count: 1_025)] {
                let error = try failure { _ = try f.exporter.export(ownerId: owner) }
                try expect(error as? AssistantDataExportError == .invalidOwner, "Invalid owners must be rejected before reading")
            }
            for limit in [0, -1, 64 * 1024 * 1024 + 1, Int.max] {
                let error = try failure { _ = try AssistantDataExporter(archive: f.archive, repository: f.repository, maximumBytes: limit).export(ownerId: "A") }
                try expect(error as? AssistantDataExportError == .invalidConfiguration, "Invalid budgets must be rejected")
            }
            let invalidDate = try failure { _ = try f.exporter.export(ownerId: "A", exportedAt: Date(timeIntervalSince1970: .nan)) }
            try expect(invalidDate as? AssistantDataExportError == .invalidConfiguration, "Invalid export timestamps must be rejected")
            try expect(try snapshotFiles(directory) == before, "Invalid requests must not create or overwrite any prepared source files")
        }
        try run("export-archive-path-obstruction-is-not-empty-success", root: root) { directory in
            let file = directory.appendingPathComponent("archive-obstruction")
            let original = Data("not an archive directory".utf8); try original.write(to: file)
            let archive = AssistantChatArchive(directory: file)
            let repo = AssistantLocalRepository(fileURL: directory.appendingPathComponent("repository.json"))
            let error = try failure { _ = try AssistantDataExporter(archive: archive, repository: repo).export(ownerId: "A") }
            try expect(error as? AssistantDataExportError == .archiveReadFailed, "An unreadable archive path cannot masquerade as missing history")
            try expect(try Data(contentsOf: file) == original, "Read failure cannot remove the obstruction")
        }

        try run("export-owned-quiet-hours-preferences", root: root) { directory in
            let f = try Fixture(directory)
            let a = AssistantQuietHours(enabled: true, startMinute: 1_320, endMinute: 480, timeZoneIdentifier: "Asia/Shanghai")
            let b = AssistantQuietHours(enabled: true, startMinute: 720, endMinute: 780, timeZoneIdentifier: "America/Los_Angeles")
            try expect(f.repository.setQuietHours(a, for: "A") && f.repository.setQuietHours(b, for: "B"), "Each owner's quiet hours must commit")
            f.repository.addTask(task("A-task", owner: "A"))
            let before = try snapshotFiles(directory)
            let aExport = try f.exporter.export(ownerId: "A", includeImages: false, exportedAt: date)
            let bExport = try f.exporter.export(ownerId: "B", exportedAt: date)
            let aValue = try decode(aExport.data), bValue = try decode(bExport.data)
            try expect(aValue.taskPreferences?.quietHours == a && bValue.taskPreferences?.quietHours == b, "Backup reminder policies must be owner-isolated and exact")
            try expect(aValue.includedScopes.contains("reminder-preferences") && aValue.schemaVersion == 1, "The explicit scope is additive to schema v1")
            try expect(aValue.tasks[0].dueAt == date.addingTimeInterval(3_600), "Backing up quiet hours must not modify a task's due date")
            let fields = try json(aExport.data)["taskPreferences"] as? [String: Any]
            try expect(Set(fields?.keys.map { $0 } ?? []) == ["quietHours"], "Task preferences must have an explicit field allowlist")
            let policy = fields?["quietHours"] as? [String: Any]
            try expect(Set(policy?.keys.map { $0 } ?? []) == ["enabled", "startMinute", "endMinute", "timeZoneIdentifier"], "No credentials or unrelated preferences may be appended")
            try expect(try snapshotFiles(directory) == before, "Exporting reminder settings cannot mutate source data")
        }
        try run("export-legacy-v1-reminder-metadata-is-optional", root: root) { directory in
            let f = try Fixture(directory)
            f.repository.addMemory(memory("kept", owner: "A", text: "legacy data survives"))
            let current = try f.exporter.export(ownerId: "A", exportedAt: date)
            let value = try decode(current.data)
            try expect(value.taskPreferences?.quietHours.enabled == false, "Legacy stores produce an explicit disabled preference in a current export")
            var oldV1 = try json(current.data)
            oldV1.removeValue(forKey: "taskPreferences")
            oldV1["includedScopes"] = (oldV1["includedScopes"] as? [String] ?? []).filter { $0 != "reminder-preferences" }
            let legacyData = try JSONSerialization.data(withJSONObject: oldV1, options: .sortedKeys)
            let legacy = try decode(legacyData)
            try expect(legacy.schemaVersion == 1 && legacy.taskPreferences == nil && !(legacy.taskPreferences?.quietHours ?? .disabled).enabled, "A reader of additive v1 metadata can default a missing policy off")
            try expect(legacy.memories.first?.text == "legacy data survives", "Optional reminder metadata cannot discard earlier record data")
        }
        try run("export-quiet-hours-count-toward-exact-budget", root: root) { directory in
            let f = try Fixture(directory)
            let quiet = AssistantQuietHours(enabled: true, startMinute: 1_439, endMinute: 720, timeZoneIdentifier: "America/Los_Angeles")
            try expect(f.repository.setQuietHours(quiet, for: "A"), "Reminder preference fixture must persist")
            let baseline = try f.exporter.export(ownerId: "A", exportedAt: date)
            let exact = try AssistantDataExporter(archive: f.archive, repository: f.repository, maximumBytes: baseline.data.count).export(ownerId: "A", exportedAt: date)
            try expect(exact.data == baseline.data && decode(exact.data).taskPreferences?.quietHours == quiet, "Exact-size budgeting must include every reminder preference field")
            let error = try failure { _ = try AssistantDataExporter(archive: f.archive, repository: f.repository, maximumBytes: baseline.data.count - 1).export(ownerId: "A", exportedAt: date) }
            try expect(error as? AssistantDataExportError == .tooLarge, "Reminder metadata cannot bypass the final output budget")
        }
        try run("export-corrupt-quiet-hours-does-not-default-off", root: root) { directory in
            let f = try Fixture(directory)
            f.repository.addMemory(memory("preserved", owner: "A", text: "retained"))
            var object = try json(Data(contentsOf: f.repositoryURL))
            object["quietHours"] = ["A": ["enabled": true, "startMinute": 480, "endMinute": 480, "timeZoneIdentifier": "UTC"]]
            let bytes = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            try bytes.write(to: f.repositoryURL)
            let bad = AssistantLocalRepository(fileURL: f.repositoryURL)
            let error = try failure { _ = try AssistantDataExporter(archive: f.archive, repository: bad).export(ownerId: "A", exportedAt: date) }
            guard let repositoryError = error as? AssistantRepositoryError, case .corruptStore = repositoryError else {
                throw ExportTestFailure(description: "Malformed reminder preferences must fail the backup instead of becoming disabled")
            }
            try expect(try Data(contentsOf: f.repositoryURL) == bytes, "A failed export preserves malformed original bytes")
        }

        try run("export-task-source-is-owned-and-counted", root: root) { directory in
            let f = try Fixture(directory)
            var a = task("A-source", owner: "A")
            a.sourceMessageId = "message-\"quoted\"-草包-👨‍👩‍👧‍👦"
            var b = task("B-source", owner: "B"); b.sourceMessageId = "B-private-source"
            f.repository.addTask(a); f.repository.addTask(b)
            let before = try snapshotFiles(directory)
            let baseline = try f.exporter.export(ownerId: "A", exportedAt: date)
            let value = try decode(baseline.data)
            try expect(value.tasks.count == 1 && value.tasks[0].sourceMessageId == a.sourceMessageId,
                "Task source metadata must export exactly for its owner")
            try expect(!String(decoding: baseline.data, as: UTF8.self).contains("B-private-source"), "Another owner's source cannot leak")
            let exact = try AssistantDataExporter(archive: f.archive, repository: f.repository,
                maximumBytes: baseline.data.count).export(ownerId: "A", exportedAt: date)
            try expect(exact.data == baseline.data, "Escaped provenance must fit its exact byte budget")
            let error = try failure {
                _ = try AssistantDataExporter(archive: f.archive, repository: f.repository,
                    maximumBytes: baseline.data.count - 1).export(ownerId: "A", exportedAt: date)
            }
            try expect(error as? AssistantDataExportError == .tooLarge, "Source metadata cannot bypass the byte limit")
            try expect(try snapshotFiles(directory) == before, "Export must preserve source files")
        }

        try run("export-generation-replacement-lineage-is-preserved-and-budgeted", root: root) { directory in
            let f = try Fixture(directory)
            let oldId = "answer-\"quoted\"-草包"
            let question = ChatMessage(id: "question", role: .user, content: "Original question", timestamp: date)
            let old = ChatMessage(id: oldId, role: .assistant, content: "Original completed answer", timestamp: date)
            let failed = ChatMessage(id: "candidate", role: .assistant, content: "Partial candidate", timestamp: date,
                status: .failed, replacesMessageId: oldId)
            let value = Conversation(id: "generation-history", title: "Generation history", preview: "Partial candidate",
                date: date, messages: [question, old, failed])
            try f.archive.upsert(value, userId: "A")
            let before = try snapshotFiles(directory)
            let baseline = try f.exporter.export(ownerId: "A", exportedAt: date)
            let decoded = try decode(baseline.data).conversations[0]
            try expect(decoded.messages.map(\.content) == value.messages.map(\.content), "Export cannot replace or discard failed candidates")
            try expect(decoded.messages.last?.replacesMessageId == oldId, "Export must preserve the replacement lineage")
            let exact = try AssistantDataExporter(archive: f.archive, repository: f.repository,
                maximumBytes: baseline.data.count).export(ownerId: "A", exportedAt: date)
            try expect(exact.data == baseline.data, "Escaped replacement identifiers must fit their exact byte budget")
            let error = try failure {
                _ = try AssistantDataExporter(archive: f.archive, repository: f.repository,
                    maximumBytes: baseline.data.count - 1).export(ownerId: "A", exportedAt: date)
            }
            try expect(error as? AssistantDataExportError == .tooLarge, "Lineage cannot bypass the export budget")
            try expect(try snapshotFiles(directory) == before, "Export remains read-only")
        }

        try run("export-all-inactive-drafts-including-unassigned-are-owner-scoped", root: root) { directory in
            let f = try Fixture(directory), picture = try image()
            try f.archive.saveDraft("A unassigned", images: [picture], userId: "A")
            try f.archive.saveDraft("A old unsent", images: [picture, picture], conversationId: "old", userId: "A")
            try f.archive.saveDraft("A active unsent", images: [picture], conversationId: "active", userId: "A")
            try f.archive.saveDraft("B old private", conversationId: "old", userId: "B")
            try f.archive.saveDraft("B active private", conversationId: "active", userId: "B")
            let before = try snapshotFiles(directory)
            let result = try f.exporter.export(ownerId: "A", exportedAt: date), value = try decode(result.data)
            try expect(value.schemaVersion == 1 && value.includedScopes.contains("conversationDrafts"), "New inactive-draft scope is explicit and additive to v1")
            try expect(value.draft == AssistantChatDraft(text: "A active unsent", images: [picture], conversationId: "active"), "Backward-compatible draft field remains the active draft")
            try expect(value.conversationDrafts == [AssistantChatDraft(text: "A unassigned", images: [picture]), AssistantChatDraft(text: "A old unsent", images: [picture, picture], conversationId: "old")], "Inactive and unassigned drafts export once with original text/images and associations")
            let all = [value.draft] + (value.conversationDrafts ?? [])
            try expect(all.count == 3 && Set(all.map(\.text)) == ["A unassigned", "A old unsent", "A active unsent"], "Active draft is not duplicated and B's same-ID drafts cannot leak")
            try expect(try snapshotFiles(directory) == before, "Complete export does not select or rewrite any draft")
        }
        try run("export-image-exclusion-counts-active-inactive-and-unassigned-occurrences", root: root) { directory in
            let f = try Fixture(directory), picture = try image()
            try f.archive.saveDraft("unassigned", images: [picture], userId: "A")
            try f.archive.saveDraft("inactive", images: [picture, picture, picture], conversationId: "old", userId: "A")
            try f.archive.saveDraft("active", images: [picture, picture], conversationId: "now", userId: "A")
            try f.archive.upsert(conversation("history", text: "message with image", images: [picture]), userId: "A")
            let before = try snapshotFiles(directory), result = try f.exporter.export(ownerId: "A", includeImages: false, exportedAt: date), value = try decode(result.data)
            try expect(result.omittedImageCount == 7 && value.omittedImageCount == 7, "All seven attachment occurrences count exactly once, even with the same image ID")
            try expect(value.draft.images == nil && value.conversationDrafts?.count == 2 && value.conversationDrafts!.allSatisfy { $0.images == nil }, "Image choice applies to every draft scope")
            try expect(value.conversations[0].messages[0].images == nil && Set(value.conversationDrafts!.map(\.text)) == ["unassigned", "inactive"] && value.draft.text == "active", "Excluding images never removes associated draft text")
            try expect(try snapshotFiles(directory) == before && f.archive.loadDraftRecords(userId: "A").reduce(0, { $0 + ($1.images?.count ?? 0) }) == 6, "Image omission changes export copies only")
        }
        try run("export-inactive-drafts-and-escaped-associations-count-toward-exact-budget", root: root) { directory in
            let f = try Fixture(directory), escaped = "quote\" backslash\\ newline\n control\u{0001} 中文👨‍👩‍👧‍👦"
            try f.archive.saveDraft("unassigned-" + escaped, userId: "A")
            try f.archive.saveDraft("inactive-" + escaped, conversationId: "old-" + escaped, userId: "A")
            try f.archive.saveDraft("active-" + escaped, conversationId: "now", userId: "A")
            let before = try snapshotFiles(directory), baseline = try f.exporter.export(ownerId: "A", exportedAt: date)
            let exact = try AssistantDataExporter(archive: f.archive, repository: f.repository, maximumBytes: baseline.data.count).export(ownerId: "A", exportedAt: date)
            try expect(exact.data == baseline.data && decode(exact.data).conversationDrafts?.last?.conversationId == "old-" + escaped, "Inactive text and escaped association fit the exact full JSON budget")
            let error = try failure { _ = try AssistantDataExporter(archive: f.archive, repository: f.repository, maximumBytes: baseline.data.count - 1).export(ownerId: "A", exportedAt: date) }
            try expect(error as? AssistantDataExportError == .tooLarge && (try snapshotFiles(directory)) == before, "One byte below full multi-draft export rejects without truncation or source changes")
        }
        try run("export-inactive-image-budget-can-be-recovered-by-explicit-omission", root: root) { directory in
            let f = try Fixture(directory), picture = try image()
            try f.archive.saveDraft("inactive images", images: [picture, picture, picture], conversationId: "old", userId: "A")
            try f.archive.saveDraft("active text", conversationId: "now", userId: "A")
            let omitted = try f.exporter.export(ownerId: "A", includeImages: false, exportedAt: date), before = try snapshotFiles(directory)
            let limited = AssistantDataExporter(archive: f.archive, repository: f.repository, maximumBytes: omitted.data.count + 64)
            let error = try failure { _ = try limited.export(ownerId: "A", exportedAt: date) }
            try expect(error as? AssistantDataExportError == .tooLarge, "Inactive images cannot bypass image preflight or the final budget")
            let recovered = try limited.export(ownerId: "A", includeImages: false, exportedAt: date)
            try expect(recovered.omittedImageCount == 3 && decode(recovered.data).conversationDrafts?.first?.text == "inactive images", "Explicit omission returns a complete smaller backup including inactive text")
            try expect(try snapshotFiles(directory) == before, "Budget refusal and recovery do not modify inactive image sources")
        }
        try run("export-old-v1-backups-may-lack-inactive-draft-field", root: root) { directory in
            let f = try Fixture(directory)
            try f.archive.saveDraft("old active backup", conversationId: "old-chat", userId: "A")
            var earlier = try json(f.exporter.export(ownerId: "A", exportedAt: date).data)
            earlier.removeValue(forKey: "conversationDrafts")
            earlier["includedScopes"] = (earlier["includedScopes"] as! [String]).filter { $0 != "conversationDrafts" }
            let decoded = try decode(JSONSerialization.data(withJSONObject: earlier, options: .sortedKeys))
            try expect(decoded.schemaVersion == 1 && decoded.conversationDrafts == nil && decoded.draft == AssistantChatDraft(text: "old active backup", conversationId: "old-chat"), "Optional additive field keeps previous v1 active-draft backups readable")
        }
        try run("export-corrupt-inactive-draft-is-an-error-not-an-incomplete-backup", root: root) { directory in
            let f = try Fixture(directory)
            try f.archive.saveDraft("private inactive", conversationId: "old", userId: "A")
            try f.archive.saveDraft("valid active", conversationId: "now", userId: "A")
            let raw = try withDatabase(f.archive) { try $0.rows("SELECT payload FROM drafts WHERE conversation_id=?", [.text("old")]).first!.first!.data! }
            var fields = try json(raw); fields["text"] = 123
            let bytes = try JSONSerialization.data(withJSONObject: fields, options: .sortedKeys)
            try withDatabase(f.archive) { try $0.execute("UPDATE drafts SET payload=? WHERE conversation_id=?", [.blob(bytes), .text("old")]) }
            let before = try snapshotFiles(directory), error = try failure { _ = try f.exporter.export(ownerId: "A", exportedAt: date) }
            try expect(error as? AssistantDataExportError == .archiveReadFailed, "A corrupt actual SQLite inactive record cannot silently disappear behind a valid active draft")
            let stored = try withDatabase(f.archive) { try $0.rows("SELECT payload FROM drafts WHERE conversation_id=?", [.text("old")]).first!.first!.data! }
            try expect(stored == bytes && (try snapshotFiles(directory)) == before, "Incomplete-export rejection preserves the complete corrupt payload and all source bytes")
        }

        try run("export-failed-sql-delete-rolls-back-complete-source", root: root) { directory in
            let f = try Fixture(directory), picture = try image()
            try f.archive.upsert(conversation("dead", text: "A transaction source history", images: [picture]), userId: "A")
            try f.archive.upsert(conversation("keep", text: "Kept A history", images: [picture]), userId: "A")
            try f.archive.saveDraft("A unassigned transaction source", images: [picture], userId: "A")
            try f.archive.saveDraft("Kept A inactive draft", images: [picture, picture], conversationId: "keep", userId: "A")
            try f.archive.saveDraft("A associated transaction source", images: [picture], conversationId: "dead", userId: "A")
            try f.archive.upsert(conversation("dead", text: "B same-ID private history"), userId: "B")
            // SQLite replaces the former two-file partial write with an atomic
            // transaction. A real late DELETE trigger must roll all changes back.
            try withDatabase(f.archive) { try $0.execute("CREATE TRIGGER deny_export_fixture_delete BEFORE DELETE ON headers WHEN OLD.id='dead' BEGIN SELECT RAISE(ABORT,'fixture-delete-failure'); END") }
            let beforeFailure = try snapshotFiles(directory)
            _ = try failure { try f.archive.delete(ids: ["dead"], userId: "A", purgeUnassignedDraft: true) }
            try expect(try snapshotFiles(directory) == beforeFailure, "Failed SQL deletion must roll back the tombstone, drafts and bodies without changing persisted bytes")
            let cold = AssistantChatArchive(directory: f.archiveDirectory); try cold.prepare(userId: "A")
            let before = try snapshotFiles(directory)
            let result = try AssistantDataExporter(archive: cold, repository: f.repository).export(ownerId: "A", includeImages: false, exportedAt: date), value = try decode(result.data)
            try expect(Set(value.conversations.map(\.id)) == ["dead", "keep"] && value.draft.text == "A associated transaction source"
                && Set(value.conversationDrafts!.map(\.text)) == ["A unassigned transaction source", "Kept A inactive draft"], "A rejected deletion cannot falsely claim success or silently lose any original source record")
            try expect(result.omittedImageCount == 6 && !String(decoding: result.data, as: UTF8.self).contains("B same-ID private history"), "Rollback retains all A attachment occurrences and never borrows the other owner's matching ID")
            try expect(try snapshotFiles(directory) == before, "Export after rollback remains a read-only snapshot")
        }

        try run("export-durable-ledger-redacts-residual-active-draft-copy-only", root: root) { directory in
            let f = try Fixture(directory), picture = try image()
            try f.archive.upsert(conversation("dead", text: "Residual ledger history"), userId: "A")
            try f.archive.saveDraft("Kept inactive source", conversationId: "keep", userId: "A")
            try f.archive.saveDraft("Residual ledger draft", images: [picture], conversationId: "dead", userId: "A")
            try withDatabase(f.archive) { try $0.execute("INSERT INTO deleted(id) VALUES(?)", [.text("dead")]) }
            let raw = try withDatabase(f.archive) { try $0.rows("SELECT payload FROM bodies WHERE id=?", [.text("dead")]).first!.first!.data! }
            try expect(String(decoding: raw, as: UTF8.self).contains("Residual ledger history"), "Fixture must actually retain a residual body underneath the durable tombstone")
            let before = try snapshotFiles(directory), result = try f.exporter.export(ownerId: "A", exportedAt: date), value = try decode(result.data)
            try expect(value.conversations.isEmpty && value.draft.text.isEmpty && value.draft.images == nil
                && value.conversationDrafts == [AssistantChatDraft(text: "Kept inactive source", conversationId: "keep")], "Residual content underneath a persisted SQLite tombstone is absent from every exported scope")
            let output = String(decoding: result.data, as: UTF8.self)
            try expect(!output.contains("Residual ledger history") && !output.contains("Residual ledger draft") && (try snapshotFiles(directory)) == before, "Returned copies redact legacy residue without physically rewriting the source during export")
        }

        try run("export-interrupted-account-purge-cannot-return-old-unidentified-data", root: root) { directory in
            let f = try Fixture(directory)
            try f.archive.upsert(conversation("old", text: "Account purge residual history"), userId: "A")
            try f.archive.saveDraft("Account purge residual unassigned draft", userId: "A")
            let deleting = AssistantChatArchive(directory: f.archiveDirectory, fault: { point, owner in
                if point == .purgeDatabaseRemoval && owner == "A" { throw ExportTestFailure(description: "Injected postcommit database removal failure") }
            })
            try deleting.prepare(userId: "A")
            _ = try failure(stage: "postcommit purge database removal") { try deleting.deleteAll(userId: "A") }
            let before = try snapshotFiles(directory), cold = AssistantChatArchive(directory: f.archiveDirectory)
            _ = try failure(stage: "cold preparation during pending purge") { try cold.prepare(userId: "A") }
            let error = try failure(stage: "export during pending purge") { _ = try AssistantDataExporter(archive: cold, repository: f.repository).export(ownerId: "A", exportedAt: date) }
            try expect(error as? AssistantDataExportError == .archiveReadFailed && (try cold.isPurgingAll(userId: "A")), "A pending authority purge cannot masquerade as an empty successful backup or return old data")
            try expect(try snapshotFiles(directory) == before, "Blocked preparation and export cannot clear pending purge protection or rewrite remaining physical sources")
            try cold.deleteAll(userId: "A"); try cold.prepare(userId: "A")
            let value = try decode(AssistantDataExporter(archive: cold, repository: f.repository).export(ownerId: "A", exportedAt: date).data)
            try expect(value.conversations.isEmpty && value.draft.text.isEmpty && value.conversationDrafts?.isEmpty == true, "Explicit successful cleanup permits a fresh empty backup without resurrecting old source content")
        }

        try run("export-captured-snapshot-is-owner-bound-by-exact-bytes", root: root) { directory in
            let f = try Fixture(directory), before = try snapshotFiles(directory)
            let foreign = AssistantArchiveExportSnapshot(ownerId: "B", conversations: [conversation("foreign", text: "B captured secret")],
                activeDraft: AssistantChatDraft(text: "B captured draft"), inactiveDrafts: [])
            let denied = try failure { _ = try f.exporter.export(ownerId: "A", capturedSnapshot: foreign) }
            try expect(denied as? AssistantDataExportError == .invalidRecordOwnership, "A supplied snapshot cannot override its actual owner")
            let composed = "caf\u{00E9}", decomposed = "cafe\u{301}"
            try expect(composed == decomposed && !composed.utf8.elementsEqual(decomposed.utf8), "Fixture must use canonically equivalent but byte-distinct owners")
            let equivalent = AssistantArchiveExportSnapshot(ownerId: decomposed, conversations: [], activeDraft: AssistantChatDraft(text: "private"), inactiveDrafts: [])
            let mismatch = try failure { _ = try f.exporter.export(ownerId: composed, capturedSnapshot: equivalent) }
            try expect(mismatch as? AssistantDataExportError == .invalidRecordOwnership && (try snapshotFiles(directory)) == before,
                "Owner-bound encoding must reject byte-distinct identities without reading or changing any archive")
        }
        try run("export-captured-snapshot-encodes-without-another-database-read", root: root) { directory in
            let f = try Fixture(directory)
            try f.archive.upsert(conversation("captured", text: "snapshot-time response"), userId: "A")
            try f.archive.saveDraft("snapshot-time draft", conversationId: "captured", userId: "A")
            let captured = try f.archive.exportSnapshot(userId: "A")
            try f.archive.upsert(conversation("captured", text: "newer database response"), userId: "A")
            try f.archive.saveDraft("newer database draft", conversationId: "captured", userId: "A")
            let obstruction = directory.appendingPathComponent("not-a-database-directory")
            try Data("do not overwrite".utf8).write(to: obstruction)
            let unavailable = AssistantChatArchive(directory: obstruction)
            let exporter = AssistantDataExporter(archive: unavailable, repository: f.repository)
            let before = try snapshotFiles(directory)
            let value = try decode(exporter.export(ownerId: "A", exportedAt: date, capturedSnapshot: captured).data)
            try expect(value.conversations.first?.messages.first?.content == "snapshot-time response" && value.draft.text == "snapshot-time draft",
                "Background encoding uses exactly the immutable capture rather than rereading newer rows")
            try expect(try snapshotFiles(directory) == before, "Captured encoding performs no migration, database read or mutation on its unavailable archive dependency")
        }
        try run("export-includes-complete-store-beyond-the-loaded-summary-page", root: root) { directory in
            let f = try Fixture(directory)
            let complete = (0..<85).map { conversation("history-\($0)", text: "Complete message \($0)") }
            for record in complete { try f.archive.upsert(record, userId: "A") }
            try f.archive.saveDraft("parked draft outside page", conversationId: "history-0", userId: "A")
            try f.archive.saveDraft("active input", conversationId: "history-84", userId: "A")
            let page = try f.archive.pageSummaries(userId: "A", query: "", cursor: nil, limit: 7)
            try expect(page.items.count == 7 && page.nextCursor != nil, "Fixture must actually use a partial SQL summary page")
            let before = try snapshotFiles(directory), result = try f.exporter.export(ownerId: "A", exportedAt: date), value = try decode(result.data)
            try expect(result.conversationCount == 85 && value.conversations.count == 85
                && value.conversations.flatMap(\.messages).count == 170 && Set(value.conversations) == Set(complete),
                "Full backup must load complete conversation bodies, never just the current summary page")
            try expect(value.conversationDrafts?.contains(where: { $0.conversationId == "history-0" && $0.text == "parked draft outside page" }) == true
                && (try snapshotFiles(directory)) == before, "Drafts outside the loaded page remain in the read-only backup")
        }
        try run("export-does-not-implicitly-migrate-unprepared-legacy-files", root: root) { directory in
            let archiveDirectory = directory.appendingPathComponent("legacy", isDirectory: true)
            try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
            let archive = AssistantChatArchive(directory: archiveDirectory)
            let legacy = archive.databaseURL(userId: "A").deletingPathExtension().appendingPathExtension("json")
            try JSONEncoder().encode([conversation("legacy", text: "legacy original")]).write(to: legacy)
            try JSONEncoder().encode(AssistantChatDraft(text: "legacy unsent", conversationId: "legacy")).write(to: legacy.appendingPathExtension("draft"))
            let repository = AssistantLocalRepository(fileURL: directory.appendingPathComponent("repository.json"))
            let exporter = AssistantDataExporter(archive: archive, repository: repository), before = try snapshotFiles(directory)
            let denied = try failure { _ = try exporter.export(ownerId: "A", exportedAt: date) }
            try expect(denied as? AssistantDataExportError == .archiveReadFailed && (try snapshotFiles(directory)) == before,
                "A readonly export must not perform hidden legacy migration or create database authority files")
            try archive.prepare(userId: "A")
            let preparedBytes = try snapshotFiles(directory), value = try decode(exporter.export(ownerId: "A", exportedAt: date).data)
            try expect(value.conversations.first?.messages.first?.content == "legacy original" && value.draft.text == "legacy unsent"
                && (try snapshotFiles(directory)) == preparedBytes, "An explicitly prepared migration can then be exported without changing any source bytes")
        }

        let cancellationDirectory = root.appendingPathComponent("cancelled", isDirectory: true)
        try FileManager.default.createDirectory(at: cancellationDirectory, withIntermediateDirectories: true)
        let cancellation = try Fixture(cancellationDirectory)
        try cancellation.archive.upsert(conversation("A", text: "preserved"), userId: "A")
        let beforeCancellation = try snapshotFiles(cancellationDirectory)
        let cancelled = Task { try cancellation.exporter.export(ownerId: "A", exportedAt: date) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw ExportTestFailure(description: "A pre-cancelled export must not return a file") }
        catch is CancellationError { }
        try expect(try snapshotFiles(cancellationDirectory) == beforeCancellation, "Cancellation cannot mutate source records")
        pass("export-cancellation-preserves-source")
        print("All \(suites) local data export test groups passed")
    }
}
