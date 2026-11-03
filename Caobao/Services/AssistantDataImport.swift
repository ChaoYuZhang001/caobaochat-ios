import Foundation
import CryptoKit
import Darwin

/// Validate the actual opened descriptor, never a pre-open path snapshot.
/// NONBLOCK prevents a substituted FIFO from blocking before fstat can reject it.
enum AssistantBackupFileReader {
    static func openRegularFile(url: URL) throws -> FileHandle {
        guard url.isFileURL else { throw AssistantDataImportError.invalidFormat }
        let descriptor = try url.withUnsafeFileSystemRepresentation { path throws -> Int32 in
            guard let path else { throw AssistantDataImportError.invalidFormat }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP || code == ENOTDIR { throw AssistantDataImportError.invalidFormat }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        var transferred = false
        defer { if !transferred { Darwin.close(descriptor) } }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw AssistantDataImportError.invalidFormat }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        transferred = true
        return handle
    }
}

enum AssistantDataImportError: LocalizedError, Equatable {
    case invalidConfiguration, invalidOwner, tooLarge, invalidFormat, unsupportedVersion
    case ownerMismatch, invalidRecord, invalidImage, busy

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return AssistantLocalization.string("无法恢复：备份大小配置无效。")
        case .invalidOwner: return AssistantLocalization.string("无法恢复：用户标识无效。")
        case .tooLarge: return AssistantLocalization.string("备份超过恢复限制，未写入任何记录。")
        case .invalidFormat: return AssistantLocalization.string("备份格式无效或包含重复字段，未写入任何记录。")
        case .unsupportedVersion: return AssistantLocalization.string("暂不支持此备份版本，请使用兼容版本导出的文件。")
        case .ownerMismatch: return AssistantLocalization.string("此备份不属于当前用户，未恢复任何记录。")
        case .invalidRecord: return AssistantLocalization.string("备份包含无效、重复或归属不一致的记录，未写入任何记录。")
        case .invalidImage: return AssistantLocalization.string("备份包含无效或过大的图片，未写入任何记录。")
        case .busy: return AssistantLocalization.string("请先停止当前回复并等待图片处理完成，再恢复备份。")
        }
    }
}

/// Immutable, validated values only. Neither raw JSON nor a file URL is retained.
/// Preparing this plan cannot write stores, read credentials, or execute a tool.
struct AssistantDataImportPlan: @unchecked Sendable {
    let ownerId: String
    let backupDigest: String
    let exportedAt: Date
    let conversations: [Conversation]
    let drafts: [AssistantChatDraft]
    let memories: [AssistantMemory]
    let tasks: [AssistantTask]
    let omittedImageCount: Int
    let neutralizedProposalCount: Int
    let ignoredReceiptCount: Int

    fileprivate init(ownerId: String, backupDigest: String, exportedAt: Date,
                     conversations: [Conversation], drafts: [AssistantChatDraft],
                     memories: [AssistantMemory], tasks: [AssistantTask], omittedImageCount: Int,
                     neutralizedProposalCount: Int, ignoredReceiptCount: Int) {
        self.ownerId = ownerId; self.backupDigest = backupDigest; self.exportedAt = exportedAt
        self.conversations = conversations; self.drafts = drafts; self.memories = memories; self.tasks = tasks
        self.omittedImageCount = omittedImageCount; self.neutralizedProposalCount = neutralizedProposalCount
        self.ignoredReceiptCount = ignoredReceiptCount
    }
}

/// Each backing store commits atomically. A later workspace failure is an
/// explicit partial result, never a claim that SQLite was rolled back. Selecting
/// the same file and confirming again safely resumes via per-store digest marks.
struct AssistantDataImportResult {
    let archive: AssistantArchiveRestoreResult
    let workspace: AssistantRepositoryRestoreResult?
    let workspaceError: String?
    var isComplete: Bool { workspace != nil && workspaceError == nil }
    var insertedConversationCount: Int { archive.insertedConversations }
    var insertedDraftCount: Int { archive.insertedDrafts }
    var insertedMemoryCount: Int { workspace?.insertedMemories ?? 0 }
    var insertedTaskCount: Int { workspace?.insertedTasks ?? 0 }
    var conflictCount: Int {
        archive.conflictingConversations + archive.conflictingDrafts
            + (workspace?.conflictingMemories ?? 0) + (workspace?.conflictingTasks ?? 0)
    }
    var alreadyApplied: Bool { archive.alreadyApplied && workspace?.alreadyApplied == true }
}

private struct AssistantImportMemoryPreferences: Decodable {
    let memoryEnabled: Bool
    let excludedMemoryCategories: [AssistantMemoryCategory]
}
private struct AssistantImportTaskPreferences: Decodable { let quietHours: AssistantQuietHours }
private struct AssistantImportPayload: Decodable {
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
    let conversationDrafts: [AssistantChatDraft]?
    let memories: [AssistantMemory]
    let tasks: [AssistantTask]
    let memoryPreferences: AssistantImportMemoryPreferences
    let taskPreferences: AssistantImportTaskPreferences?
    let taskToolReceipts: [AssistantTaskToolReceipt]?
}

final class AssistantDataImporter: @unchecked Sendable {
    private let maximumBytes: Int
    init(maximumBytes: Int = 32 * 1024 * 1024) { self.maximumBytes = maximumBytes }

    /// Read a bounded regular file with a bounded streaming loop. File size may
    /// change after selection; the read limit, not metadata, is authoritative.
    func prepare(url: URL, ownerId: String) throws -> AssistantDataImportPlan {
        try validateConfiguration(ownerId)
        guard url.isFileURL else { throw AssistantDataImportError.invalidFormat }
        let handle = try AssistantBackupFileReader.openRegularFile(url: url)
        defer { try? handle.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(65_536, maximumBytes - data.count + 1)) ?? Data()
            guard !chunk.isEmpty else { break }
            guard chunk.count <= maximumBytes - data.count else { throw AssistantDataImportError.tooLarge }
            data.append(chunk)
        }
        return try prepare(data: data, ownerId: ownerId)
    }

    func prepare(data: Data, ownerId: String) throws -> AssistantDataImportPlan {
        try validateConfiguration(ownerId)
        guard data.count <= maximumBytes else { throw AssistantDataImportError.tooLarge }
        try Task.checkCancellation()
        // JSONDecoder/JSONSerialization silently accept duplicate object keys.
        // Scan first, including escaped-key aliases and bounded nesting/nodes.
        var syntax = AssistantBackupJSONScanner(data: data)
        try syntax.validate()
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AssistantDataImportError.invalidFormat
            }
            object = value
            try validateShape(value)
        } catch is CancellationError { throw CancellationError() }
        catch { throw AssistantDataImportError.invalidFormat }
        let payload: AssistantImportPayload
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
            payload = try decoder.decode(AssistantImportPayload.self, from: data)
        } catch { throw AssistantDataImportError.invalidFormat }
        guard payload.schemaName == "caobao.assistant.local-export", payload.schemaVersion == 1,
              payload.dateEncoding == "unix-seconds" else { throw AssistantDataImportError.unsupportedVersion }
        guard payload.ownerId.utf8.elementsEqual(ownerId.utf8) else { throw AssistantDataImportError.ownerMismatch }
        let backupDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try validDate(payload.exportedAt)
        let allowedScopes: Set<String> = ["conversations", "draft", "conversationDrafts", "memories", "tasks", "memoryPreferences", "reminder-preferences", "taskToolReceipts"]
        let scopes = Set(payload.includedScopes)
        guard scopes.count == payload.includedScopes.count, scopes.isSubset(of: allowedScopes),
              Set(["conversations", "draft", "memories", "tasks", "memoryPreferences"]).isSubset(of: scopes),
              payload.omittedImageCount >= 0, payload.omittedImageCount <= 100_000,
              !payload.imagesIncluded || payload.omittedImageCount == 0,
              payload.conversations.count <= 1_000, payload.memories.count <= 10_000,
              payload.tasks.count <= 10_000, (payload.conversationDrafts?.count ?? 0) <= 1_000,
              (payload.taskToolReceipts?.count ?? 0) <= 10_000 else { throw AssistantDataImportError.invalidRecord }
        // Optional additive v1 fields may be absent, but explicit null is not an
        // old export and must not be silently converted into an empty value.
        for key in ["conversationDrafts", "taskPreferences", "taskToolReceipts"] where object[key] is NSNull {
            throw AssistantDataImportError.invalidFormat
        }
        if let preferences = payload.taskPreferences { _ = try preferences.quietHours.validated() }
        guard Set(payload.memoryPreferences.excludedMemoryCategories).count == payload.memoryPreferences.excludedMemoryCategories.count else {
            throw AssistantDataImportError.invalidRecord
        }

        var receiptMap: [String: AssistantTaskToolReceipt] = [:]
        for receipt in payload.taskToolReceipts ?? [] {
            guard receipt.isValid(ownerId: ownerId, proposalId: receipt.proposalId), receiptMap[receipt.proposalId] == nil else {
                throw AssistantDataImportError.invalidRecord
            }
            try validDate(receipt.committedAt); receiptMap[receipt.proposalId] = receipt
        }
        var conversationIDs = Set<String>(), messageIDs = Set<String>(), totalMessages = 0, neutralized = 0
        var conversations: [Conversation] = []
        for conversation in payload.conversations {
            try Task.checkCancellation(); try validIdentity(conversation.id)
            guard conversationIDs.insert(conversation.id).inserted, conversation.messages.count <= 10_000,
                  conversation.title.utf8.count <= 1_048_576, conversation.preview.utf8.count <= 1_048_576 else {
                throw AssistantDataImportError.invalidRecord
            }
            totalMessages += conversation.messages.count
            guard totalMessages <= 10_000 else { throw AssistantDataImportError.tooLarge }
            try validDate(conversation.date)
            var messages: [ChatMessage] = []
            for (index, raw) in conversation.messages.enumerated() {
                try Task.checkCancellation(); try validIdentity(raw.id); try validDate(raw.timestamp)
                guard messageIDs.insert(raw.id).inserted, raw.content.utf8.count <= 1_048_576 else { throw AssistantDataImportError.invalidRecord }
                try validateImages(raw.images, included: payload.imagesIncluded)
                if let model = raw.model { guard model.utf8.count <= 1_024 else { throw AssistantDataImportError.invalidRecord } }
                if let usage = raw.usage { guard (usage.inputTokens ?? 0) >= 0, (usage.outputTokens ?? 0) >= 0 else { throw AssistantDataImportError.invalidRecord } }
                var message = raw
                if let proposal = raw.taskProposal {
                    guard raw.role == .assistant else { throw AssistantDataImportError.invalidRecord }
                    do { try proposal.validate(ownerId: ownerId, conversationId: conversation.id, messageId: raw.id) }
                    catch { throw AssistantDataImportError.invalidRecord }
                    guard let sourceIndex = conversation.messages.firstIndex(where: { $0.id.utf8.elementsEqual(proposal.sourceUserMessageId.utf8) }),
                          sourceIndex < index, conversation.messages[sourceIndex].role == .user,
                          AssistantTaskProposal.digest([conversation.messages[sourceIndex].content]) == proposal.sourceUserContentDigest else {
                        throw AssistantDataImportError.invalidRecord
                    }
                    message.content += auditText(proposal, receipt: receiptMap[proposal.id])
                    neutralized += 1
                }
                // Imported history can be read and deliberately reused as text,
                // but cannot recover a tool capability or server generation ID.
                message.taskProposal = nil; message.requestId = nil; message.generationId = nil
                message.replacesMessageId = nil
                if message.status == .pending || message.status == .streaming { message.status = .failed }
                guard message.content.utf8.count <= 1_048_576 else { throw AssistantDataImportError.tooLarge }
                messages.append(message)
            }
            conversations.append(Conversation(id: conversation.id, title: conversation.title, preview: conversation.preview,
                date: conversation.date, messages: messages, serverConversationId: nil))
        }

        var drafts = [payload.draft] + (payload.conversationDrafts ?? [])
        var slots = Set<String>()
        for draft in drafts {
            try Task.checkCancellation()
            guard draft.text.utf8.count <= 1_048_576 else { throw AssistantDataImportError.tooLarge }
            if let id = draft.conversationId {
                try validIdentity(id)
                if conversationIDs.contains(id), !conversations.contains(where: { $0.id.utf8.elementsEqual(id.utf8) }) {
                    throw AssistantDataImportError.invalidRecord
                }
            }
            let slot = draft.conversationId.map { "c:" + Data($0.utf8).base64EncodedString() } ?? "unassigned"
            guard slots.insert(slot).inserted else { throw AssistantDataImportError.invalidRecord }
            try validateImages(draft.images, included: payload.imagesIncluded)
        }
        // A real new-chat backup can contain a draft without a conversation
        // header. Give nonempty orphan/unassigned drafts a readable history route
        // instead of rejecting a legitimate export or overwriting the live slot.
        drafts.removeAll { draft in
            draft.text.isEmpty && (draft.images?.isEmpty ?? true)
                && !conversations.contains(where: { conversation in
                    draft.conversationId.map { $0.utf8.elementsEqual(conversation.id.utf8) } ?? false
                })
        }
        for index in drafts.indices {
            let id = drafts[index].conversationId ?? "restored-draft-" + backupDigest
            if drafts[index].conversationId == nil {
                guard !conversationIDs.contains(id) else { throw AssistantDataImportError.invalidRecord }
                drafts[index].conversationId = id
            }
            if !conversationIDs.contains(id) {
                guard conversations.count < 1_000 else { throw AssistantDataImportError.tooLarge }
                conversationIDs.insert(id)
                conversations.append(Conversation(id: id, title: "Restored draft / 已恢复的草稿",
                    preview: String(drafts[index].text.prefix(100)), date: payload.exportedAt, messages: []))
            }
        }
        var memoryIDs = Set<String>(), taskIDs = Set<String>()
        let memories = try payload.memories.map { raw -> AssistantMemory in
            try Task.checkCancellation(); try validIdentity(raw.id); try validDate(raw.createdAt); try validDate(raw.updatedAt)
            guard raw.userId.utf8.elementsEqual(ownerId.utf8), memoryIDs.insert(raw.id).inserted,
                  raw.consent.utf8.count <= 1_024 else { throw AssistantDataImportError.invalidRecord }
            var memory = raw
            if memory.status == .deleted { memory.text = ""; memory.sourceMessageId = nil }
            else { do { try AssistantWorkspaceValidation.validateMemoryText(memory.text) } catch { throw AssistantDataImportError.invalidRecord } }
            if let source = memory.sourceMessageId { try validIdentity(source) }
            memory.consent = "unconfirmed"
            return memory
        }
        let tasks = try payload.tasks.map { raw -> AssistantTask in
            try Task.checkCancellation(); try validIdentity(raw.id); try validDate(raw.createdAt); try validDate(raw.updatedAt)
            guard raw.userId.utf8.elementsEqual(ownerId.utf8), taskIDs.insert(raw.id).inserted else { throw AssistantDataImportError.invalidRecord }
            do {
                try AssistantWorkspaceValidation.validateTask(title: raw.title, instructions: raw.instructions)
                _ = try AssistantTaskTimeZonePolicy.validatedIdentifier(raw.timeZone)
                let recurrence = try AssistantTaskRecurrence.parse(raw.recurrenceRule)
                if recurrence != .none { guard raw.dueAt != nil else { throw AssistantDataImportError.invalidRecord } }
            } catch { throw AssistantDataImportError.invalidRecord }
            if let dueAt = raw.dueAt { try validDate(dueAt) }
            if let start = raw.recurrenceStartsAt { try validDate(start) }
            if let source = raw.sourceMessageId { try validIdentity(source) }
            var task = raw; task.reminderEnabled = false; task.requiresApproval = true
            return task
        }
        try Task.checkCancellation()
        return AssistantDataImportPlan(ownerId: ownerId, backupDigest: backupDigest,
            exportedAt: payload.exportedAt, conversations: conversations, drafts: drafts, memories: memories, tasks: tasks,
            omittedImageCount: payload.omittedImageCount, neutralizedProposalCount: neutralized, ignoredReceiptCount: receiptMap.count)
    }

    private func validateConfiguration(_ owner: String) throws {
        guard maximumBytes > 0, maximumBytes <= 64 * 1024 * 1024 else { throw AssistantDataImportError.invalidConfiguration }
        do { try validIdentity(owner) } catch { throw AssistantDataImportError.invalidOwner }
    }
    private func validIdentity(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 1_024,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AssistantDataImportError.invalidRecord }
    }
    private func validDate(_ value: Date) throws {
        let seconds = value.timeIntervalSince1970
        guard seconds.isFinite, seconds >= Date.distantPast.timeIntervalSince1970,
              seconds <= 253_402_300_799.999 else { throw AssistantDataImportError.invalidRecord }
    }
    private func validateImages(_ images: [AssistantImage]?, included: Bool) throws {
        guard (images?.count ?? 0) <= AssistantImagePreprocessor.maximumImagesPerMessage,
              included || (images?.isEmpty ?? true) else { throw AssistantDataImportError.invalidImage }
        var ids = Set<String>()
        for image in images ?? [] {
            do { try validIdentity(image.id); guard ids.insert(image.id).inserted else { throw AssistantDataImportError.invalidImage }; try image.validate() }
            catch { throw AssistantDataImportError.invalidImage }
        }
    }
    private func auditText(_ proposal: AssistantTaskProposal, receipt: AssistantTaskToolReceipt?) -> String {
        var result = "\n\n[Restored task suggestion / 已恢复的待办提案 · read-only / 只读]\n" + proposal.arguments.title
        if !proposal.arguments.notes.isEmpty { result += "\n" + proposal.arguments.notes }
        if let due = proposal.arguments.dueAt { result += "\n" + due + " · " + (proposal.arguments.timeZone ?? "UTC") }
        if let receipt { result += "\nDecision / 处理结果: " + receipt.decision.rawValue }
        return result + "\nThis restored text cannot execute tools or enable reminders. / 恢复的文字不能执行工具或开启提醒。"
    }

    private func validateShape(_ value: [String: Any]) throws {
        func keys(_ object: Any, _ allowed: Set<String>) throws -> [String: Any] {
            guard let object = object as? [String: Any], Set(object.keys).isSubset(of: allowed) else { throw AssistantDataImportError.invalidFormat }
            return object
        }
        func images(_ object: Any?) throws {
            guard let object, !(object is NSNull) else { return }
            guard let array = object as? [Any] else { throw AssistantDataImportError.invalidFormat }
            for image in array { _ = try keys(image, ["id", "mimeType", "base64Data", "width", "height"]) }
        }
        func draft(_ object: Any) throws { let item = try keys(object, ["text", "images", "conversationId"]); try images(item["images"]) }
        _ = try keys(value, ["schemaName", "schemaVersion", "dateEncoding", "ownerId", "exportedAt", "includedScopes", "imagesIncluded", "omittedImageCount", "conversations", "draft", "conversationDrafts", "memories", "tasks", "memoryPreferences", "taskPreferences", "taskToolReceipts"])
        if let array = value["conversations"] as? [Any] {
            for object in array {
                let conversation = try keys(object, ["id", "title", "preview", "date", "messages", "serverConversationId"])
                if let messages = conversation["messages"] as? [Any] {
                    for object in messages {
                        let message = try keys(object, ["id", "role", "content", "timestamp", "liked", "disliked", "status", "requestId", "generationId", "model", "usage", "images", "replacesMessageId", "taskProposal"])
                        try images(message["images"])
                        if let usage = message["usage"], !(usage is NSNull) { _ = try keys(usage, ["inputTokens", "outputTokens"]) }
                        // Proposal/trace has its own strict production decoder and
                        // validator, and is neutralized before reaching storage.
                    }
                }
            }
        }
        if let item = value["draft"] { try draft(item) }
        if let array = value["conversationDrafts"] as? [Any] { for item in array { try draft(item) } }
        if let array = value["memories"] as? [Any] { for item in array { _ = try keys(item, ["id", "userId", "category", "text", "sourceMessageId", "consent", "status", "createdAt", "updatedAt"]) } }
        if let array = value["tasks"] as? [Any] { for item in array { _ = try keys(item, ["id", "userId", "title", "instructions", "dueAt", "timeZone", "recurrenceRule", "requiresApproval", "status", "createdAt", "updatedAt", "reminderEnabled", "sourceMessageId", "recurrenceStartsAt"]) } }
        if let item = value["memoryPreferences"] { _ = try keys(item, ["memoryEnabled", "excludedMemoryCategories"]) }
        if let item = value["taskPreferences"], !(item is NSNull) {
            let preferences = try keys(item, ["quietHours"])
            if let quiet = preferences["quietHours"] { _ = try keys(quiet, ["enabled", "startMinute", "endMinute", "timeZoneIdentifier"]) }
        }
        if let array = value["taskToolReceipts"] as? [Any] { for item in array { _ = try keys(item, ["ownerId", "proposalId", "taskId", "decision", "reminderState", "committedAt", "revision", "continuationAttemptId"]) } }
    }
}

/// A bounded preflight grammar, deliberately independent from Foundation's
/// duplicate-key behavior. Object names are decoded before identity checking.
private struct AssistantBackupJSONScanner {
    private let bytes: [UInt8]
    private var offset = 0
    private var nodes = 0
    init(data: Data) { bytes = Array(data) }
    mutating func validate() throws {
        skipWhitespace(); try value(depth: 0); skipWhitespace()
        guard offset == bytes.count else { throw AssistantDataImportError.invalidFormat }
    }
    private mutating func value(depth: Int) throws {
        nodes += 1
        guard depth <= 32, nodes <= 500_000, offset < bytes.count else { throw AssistantDataImportError.tooLarge }
        if nodes % 256 == 0 { try Task.checkCancellation() }
        switch bytes[offset] {
        case 123:
            offset += 1; skipWhitespace(); if consume(125) { return }
            var names = Set<String>()
            while true {
                let name = try string(); guard names.insert(name).inserted, names.count <= 64 else { throw AssistantDataImportError.invalidFormat }
                skipWhitespace(); guard consume(58) else { throw AssistantDataImportError.invalidFormat }; skipWhitespace()
                try value(depth: depth + 1); skipWhitespace(); if consume(125) { break }
                guard consume(44) else { throw AssistantDataImportError.invalidFormat }; skipWhitespace()
            }
        case 91:
            offset += 1; skipWhitespace(); if consume(93) { return }
            while true {
                try value(depth: depth + 1); skipWhitespace(); if consume(93) { break }
                guard consume(44) else { throw AssistantDataImportError.invalidFormat }; skipWhitespace()
            }
        case 34: _ = try string()
        default:
            let start = offset
            while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
            guard offset > start else { throw AssistantDataImportError.invalidFormat }
        }
    }
    private mutating func string() throws -> String {
        guard offset < bytes.count, bytes[offset] == 34 else { throw AssistantDataImportError.invalidFormat }
        let start = offset; offset += 1
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if byte == 34 {
                do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
                catch { throw AssistantDataImportError.invalidFormat }
            }
            if byte == 92 { guard offset < bytes.count else { break }; offset += 1 }
        }
        throw AssistantDataImportError.invalidFormat
    }
    private mutating func skipWhitespace() { while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
    private mutating func consume(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }; offset += 1; return true
    }
}
