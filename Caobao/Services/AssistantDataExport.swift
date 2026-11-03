import Foundation

struct AssistantDataExportResult: Sendable {
    let data: Data
    let conversationCount: Int
    let memoryCount: Int
    let taskCount: Int
    /// Counts attachment occurrences, including draft images, rather than unique image IDs.
    let omittedImageCount: Int
}

enum AssistantDataExportError: LocalizedError, Equatable {
    case invalidOwner
    case invalidConfiguration
    case invalidRecordOwnership
    case archiveReadFailed
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidOwner: return AssistantLocalization.string("无法导出：用户标识无效。")
        case .invalidConfiguration: return AssistantLocalization.string("无法导出：备份大小或时间配置无效。")
        case .invalidRecordOwnership: return AssistantLocalization.string("无法导出：检测到不属于当前用户的记录。")
        case .archiveReadFailed: return AssistantLocalization.string("无法读取本地会话或草稿，未生成备份。")
        case .tooLarge: return AssistantLocalization.string("备份超过大小限制，请关闭图片导出后重试。")
        }
    }
}

/// A local-only, synchronous snapshot. There is deliberately no identity client,
/// preferences dictionary, Keychain, URLSession or server-export input here.
/// Known records are the export field allowlist; user-authored content is retained
/// verbatim, rather than altered by a credential-looking-text regular expression.
// Immutable dependencies serialize their own reads with locks; every export's
// copied records, budget and encoders are local to that invocation. This does not
// promise a cross-store transaction or bound the source archive's decoded memory.
final class AssistantDataExporter: @unchecked Sendable {
    private let archive: AssistantChatArchive
    private let repository: AssistantLocalRepository
    private let maximumBytes: Int

    init(archive: AssistantChatArchive = .shared, repository: AssistantLocalRepository = .shared,
         maximumBytes: Int = 32 * 1024 * 1024) {
        self.archive = archive
        self.repository = repository
        self.maximumBytes = maximumBytes
    }

    func export(ownerId: String, includeImages: Bool = true, exportedAt: Date = Date(),
                capturedSnapshot: AssistantArchiveExportSnapshot? = nil) throws -> AssistantDataExportResult {
        try Task.checkCancellation()
        guard !ownerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ownerId.utf8.count <= 1_024 else { throw AssistantDataExportError.invalidOwner }
        guard maximumBytes > 0, maximumBytes <= 64 * 1024 * 1024,
              exportedAt.timeIntervalSince1970.isFinite else { throw AssistantDataExportError.invalidConfiguration }
        if let capturedSnapshot, !capturedSnapshot.ownerId.utf8.elementsEqual(ownerId.utf8) {
            throw AssistantDataExportError.invalidRecordOwnership
        }

        // The repository's throwing snapshot distinguishes a failed store load
        // from a recoverable last mutation error and includes deletion tombstones.
        let records = try repository.exportSnapshot(for: ownerId)
        guard records.memories.allSatisfy({ $0.userId.utf8.elementsEqual(ownerId.utf8) }),
              records.tasks.allSatisfy({ $0.userId.utf8.elementsEqual(ownerId.utf8) }),
              records.taskToolReceipts.allSatisfy({ $0.isValid(ownerId: ownerId, proposalId: $0.proposalId) }) else {
            throw AssistantDataExportError.invalidRecordOwnership
        }
        var conversations: [Conversation]
        var draft: AssistantChatDraft
        var conversationDrafts: [AssistantChatDraft]
        do {
            if let capturedSnapshot {
                conversations = capturedSnapshot.conversations
                draft = capturedSnapshot.activeDraft; conversationDrafts = capturedSnapshot.inactiveDrafts
            } else {
                let snapshot = try archive.loadExportSnapshot(userId: ownerId)
                conversations = snapshot.conversations
                draft = snapshot.activeDraft; conversationDrafts = snapshot.inactiveDrafts
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw AssistantDataExportError.archiveReadFailed }
        for conversation in conversations {
            for message in conversation.messages {
                if let proposal = message.taskProposal {
                    guard message.role == .assistant, proposal.ownerId.utf8.elementsEqual(ownerId.utf8),
                          proposal.conversationId.utf8.elementsEqual(conversation.id.utf8),
                          proposal.assistantMessageId.utf8.elementsEqual(message.id.utf8) else { throw AssistantDataExportError.invalidRecordOwnership }
                    do { try proposal.validate(ownerId: ownerId, conversationId: conversation.id, messageId: message.id) }
                    catch { throw AssistantDataExportError.archiveReadFailed }
                }
            }
        }
        try Task.checkCancellation()
        var omitted = 0
        if !includeImages {
            conversations = try conversations.map { conversation in
                try Task.checkCancellation()
                let messages = try conversation.messages.map { message -> ChatMessage in
                    try Task.checkCancellation()
                    var value = message
                    omitted += value.images?.count ?? 0
                    value.images = nil
                    return value
                }
                return Conversation(id: conversation.id, title: conversation.title, preview: conversation.preview,
                    date: conversation.date, messages: messages, serverConversationId: conversation.serverConversationId)
            }
            omitted += draft.images?.count ?? 0
            draft.images = nil
            conversationDrafts = try conversationDrafts.map { draft in
                try Task.checkCancellation()
                var value = draft; omitted += value.images?.count ?? 0; value.images = nil
                return value
            }
        }
        let memories = try records.memories.map { memory -> AssistantMemory in
            try Task.checkCancellation()
            var value = memory
            if value.status == .deleted { value.text = ""; value.sourceMessageId = nil }
            return value
        }
        let payload = AssistantDataExportPayload(ownerId: ownerId, exportedAt: exportedAt,
            imagesIncluded: includeImages, omittedImageCount: omitted,
            conversations: conversations, draft: draft, conversationDrafts: conversationDrafts, memories: memories, tasks: records.tasks,
            memoryPreferences: AssistantDataExportMemoryPreferences(memoryEnabled: records.memoryEnabled,
                excludedMemoryCategories: records.excludedMemoryCategories),
            taskPreferences: AssistantDataExportTaskPreferences(quietHours: records.quietHours), taskToolReceipts: records.taskToolReceipts)

        // Count the encoded field tree before allocating its JSON Data. In
        // particular a known oversized base64 attachment never gets encoded first.
        var budget = AssistantDataExportBudget(maximumBytes: maximumBytes)
        try budget.measure(payload)
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        // The exact encoded byte count remains authoritative if Foundation changes
        // an escaping/number representation; never return a partial/truncated file.
        guard data.count <= maximumBytes else { throw AssistantDataExportError.tooLarge }
        try Task.checkCancellation()
        return AssistantDataExportResult(data: data, conversationCount: conversations.count,
            memoryCount: memories.count, taskCount: records.tasks.count, omittedImageCount: omitted)
    }
}

private struct AssistantDataExportMemoryPreferences: Encodable {
    let memoryEnabled: Bool
    let excludedMemoryCategories: [AssistantMemoryCategory]
}

/// Additive v1 metadata; older v1 backups may lack this object and must default off.
private struct AssistantDataExportTaskPreferences: Encodable {
    let quietHours: AssistantQuietHours
}

private struct AssistantDataExportPayload: Encodable {
    let schemaName = "caobao.assistant.local-export"
    let schemaVersion = 1
    let dateEncoding = "unix-seconds"
    let ownerId: String
    let exportedAt: Date
    let includedScopes = ["conversations", "draft", "conversationDrafts", "memories", "tasks", "memoryPreferences", "reminder-preferences", "taskToolReceipts"]
    let imagesIncluded: Bool
    let omittedImageCount: Int
    let conversations: [Conversation]
    let draft: AssistantChatDraft
    /// Additive v1 field: inactive drafts only; the active draft stays in the draft field.
    /// Legacy unassociated data can appear here with a nil conversationId.
    let conversationDrafts: [AssistantChatDraft]
    let memories: [AssistantMemory]
    let tasks: [AssistantTask]
    let memoryPreferences: AssistantDataExportMemoryPreferences
    let taskPreferences: AssistantDataExportTaskPreferences
    let taskToolReceipts: [AssistantTaskToolReceipt]
}

/// JSON tree budgeting is intentionally independent of the byte buffer. Only
/// tiny scalar dates are encoded while sizing; strings/base64 are counted in situ.
private struct AssistantDataExportBudget {
    let maximumBytes: Int
    private var used = 0
    private let scalarEncoder: JSONEncoder = {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .secondsSince1970
        return value
    }()

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    mutating func measure(_ value: AssistantDataExportPayload) throws {
        try object(["schemaName", "schemaVersion", "dateEncoding", "ownerId", "exportedAt", "includedScopes",
            "imagesIncluded", "omittedImageCount", "conversations", "draft", "conversationDrafts", "memories", "tasks", "memoryPreferences", "taskPreferences", "taskToolReceipts"])
        try string(value.schemaName); try integer(value.schemaVersion); try string(value.dateEncoding)
        try string(value.ownerId); try date(value.exportedAt)
        try array(value.includedScopes.count); for scope in value.includedScopes { try string(scope) }
        try boolean(value.imagesIncluded); try integer(value.omittedImageCount)
        try array(value.conversations.count)
        for conversation in value.conversations {
            try Task.checkCancellation()
            var keys = ["id", "title", "preview", "date", "messages"]
            if conversation.serverConversationId != nil { keys.append("serverConversationId") }
            try object(keys); try string(conversation.id); try string(conversation.title); try string(conversation.preview)
            try date(conversation.date); try array(conversation.messages.count)
            for item in conversation.messages { try message(item) }
            if let id = conversation.serverConversationId { try string(id) }
        }
        try draft(value.draft)
        try array(value.conversationDrafts.count)
        for item in value.conversationDrafts { try Task.checkCancellation(); try draft(item) }
        try array(value.memories.count)
        for memory in value.memories {
            try Task.checkCancellation()
            var keys = ["id", "userId", "category", "text", "consent", "status", "createdAt", "updatedAt"]
            if memory.sourceMessageId != nil { keys.append("sourceMessageId") }
            try object(keys); try string(memory.id); try string(memory.userId); try string(memory.category.rawValue)
            try string(memory.text); try string(memory.consent); try string(memory.status.rawValue)
            try date(memory.createdAt); try date(memory.updatedAt)
            if let id = memory.sourceMessageId { try string(id) }
        }
        try array(value.tasks.count)
        for task in value.tasks {
            try Task.checkCancellation()
            var keys = ["id", "userId", "title", "timeZone", "requiresApproval", "status", "createdAt", "updatedAt"]
            if task.instructions != nil { keys.append("instructions") }
            if task.dueAt != nil { keys.append("dueAt") }
            if task.recurrenceRule != nil { keys.append("recurrenceRule") }
            if task.reminderEnabled != nil { keys.append("reminderEnabled") }
            if task.sourceMessageId != nil { keys.append("sourceMessageId") }
            if task.recurrenceStartsAt != nil { keys.append("recurrenceStartsAt") }
            try object(keys); try string(task.id); try string(task.userId); try string(task.title)
            try string(task.timeZone); try boolean(task.requiresApproval); try string(task.status.rawValue)
            try date(task.createdAt); try date(task.updatedAt)
            if let text = task.instructions { try string(text) }
            if let due = task.dueAt { try date(due) }
            if let rule = task.recurrenceRule { try string(rule) }
            if let enabled = task.reminderEnabled { try boolean(enabled) }
            if let id = task.sourceMessageId { try string(id) }
            if let starts = task.recurrenceStartsAt { try date(starts) }
        }
        try array(value.taskToolReceipts.count)
        for receipt in value.taskToolReceipts { try toolReceipt(receipt) }
        try object(["memoryEnabled", "excludedMemoryCategories"])
        try boolean(value.memoryPreferences.memoryEnabled)
        try array(value.memoryPreferences.excludedMemoryCategories.count)
        for category in value.memoryPreferences.excludedMemoryCategories { try string(category.rawValue) }
        try object(["quietHours"])
        try object(["enabled", "startMinute", "endMinute", "timeZoneIdentifier"])
        let quiet = value.taskPreferences.quietHours
        try boolean(quiet.enabled); try integer(quiet.startMinute); try integer(quiet.endMinute)
        try string(quiet.timeZoneIdentifier)
    }

    private mutating func draft(_ value: AssistantChatDraft) throws {
        var keys = ["text"]
        if value.images != nil { keys.append("images") }
        if value.conversationId != nil { keys.append("conversationId") }
        try object(keys); try string(value.text)
        if let images = value.images { try imageArray(images) }
        if let id = value.conversationId { try string(id) }
    }

    private mutating func message(_ value: ChatMessage) throws {
        var keys = ["id", "role", "content", "timestamp", "liked", "disliked", "status"]
        if value.requestId != nil { keys.append("requestId") }
        if value.generationId != nil { keys.append("generationId") }
        if value.model != nil { keys.append("model") }
        if value.usage != nil { keys.append("usage") }
        if value.images != nil { keys.append("images") }
        if value.replacesMessageId != nil { keys.append("replacesMessageId") }
        if value.taskProposal != nil { keys.append("taskProposal") }
        try object(keys); try string(value.id); try string(value.role.rawValue); try string(value.content)
        try date(value.timestamp); try boolean(value.liked); try boolean(value.disliked); try string(value.status.rawValue)
        if let id = value.requestId { try string(id) }
        if let id = value.generationId { try string(id) }
        if let model = value.model { try string(model) }
        if let id = value.replacesMessageId { try string(id) }
        if let proposal = value.taskProposal { try toolProposal(proposal) }
        if let usage = value.usage {
            var usageKeys: [String] = []
            if usage.inputTokens != nil { usageKeys.append("inputTokens") }
            if usage.outputTokens != nil { usageKeys.append("outputTokens") }
            try object(usageKeys)
            if let count = usage.inputTokens { try integer(count) }
            if let count = usage.outputTokens { try integer(count) }
        }
        if let images = value.images { try imageArray(images) }
    }

    private mutating func toolReceipt(_ value: AssistantTaskToolReceipt) throws {
        try Task.checkCancellation()
        var keys = ["ownerId", "proposalId", "decision", "reminderState", "committedAt", "revision"]
        if value.taskId != nil { keys.append("taskId") }
        if value.continuationAttemptId != nil { keys.append("continuationAttemptId") }
        try object(keys); try string(value.ownerId); try string(value.proposalId)
        try string(value.decision.rawValue); try string(value.reminderState.rawValue)
        try date(value.committedAt); try integer(value.revision)
        if let taskId = value.taskId { try string(taskId) }
        if let attempt = value.continuationAttemptId { try string(attempt) }
    }

    private mutating func toolProposal(_ value: AssistantTaskProposal) throws {
        try Task.checkCancellation()
        try object(["id", "ownerId", "conversationId", "assistantMessageId", "sourceUserMessageId", "sourceUserContentDigest", "configurationFingerprint", "call", "arguments", "createdAt"])
        for text in [value.id, value.ownerId, value.conversationId, value.assistantMessageId, value.sourceUserMessageId,
                     value.sourceUserContentDigest, value.configurationFingerprint] { try string(text) }
        try date(value.createdAt)
        try object(["id", "name", "arguments", "trace"])
        try string(value.call.id); try string(value.call.name); try string(value.call.arguments)
        try object(["protocolKind", "assistantItemsJSON"])
        try string(value.call.trace.protocolKind.rawValue); try string(value.call.trace.assistantItemsJSON)
        var keys = ["title", "notes", "reminder_requested"]
        if value.arguments.dueAt != nil { keys.append("due_at") }
        if value.arguments.timeZone != nil { keys.append("time_zone") }
        try object(keys); try string(value.arguments.title); try string(value.arguments.notes)
        try boolean(value.arguments.reminderRequested)
        if let dueAt = value.arguments.dueAt { try string(dueAt) }
        if let timeZone = value.arguments.timeZone { try string(timeZone) }
    }

    private mutating func imageArray(_ values: [AssistantImage]) throws {
        try array(values.count)
        for image in values {
            try object(["id", "mimeType", "base64Data", "width", "height"])
            try string(image.id); try string(image.mimeType); try string(image.base64Data)
            try integer(image.width); try integer(image.height)
        }
    }

    private mutating func add(_ amount: Int) throws {
        guard amount >= 0, amount <= maximumBytes - used else { throw AssistantDataExportError.tooLarge }
        used += amount
    }
    private mutating func object(_ keys: [String]) throws {
        try add(2 + max(0, keys.count - 1) + keys.count)
        for key in keys { try string(key) }
    }
    private mutating func array(_ count: Int) throws { try add(2 + max(0, count - 1)) }
    private mutating func integer(_ value: Int) throws { try add(String(value).utf8.count) }
    private mutating func boolean(_ value: Bool) throws { try add(value ? 4 : 5) }
    private mutating func date(_ value: Date) throws {
        guard value.timeIntervalSince1970.isFinite else { throw AssistantDataExportError.invalidConfiguration }
        try add(scalarEncoder.encode(value).count)
    }
    private mutating func string(_ value: String) throws {
        try add(2)
        var run = 0
        for byte in value.utf8 {
            switch byte {
            case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D: run += 2
            case 0..<0x20: run += 6
            default: run += 1
            }
            if run >= 4_096 { try add(run); run = 0; try Task.checkCancellation() }
        }
        try add(run)
    }
}
