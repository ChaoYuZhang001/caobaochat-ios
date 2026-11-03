import Foundation
import CryptoKit

struct ChatMessage: Identifiable, Hashable, Codable {
    enum Role: String, Hashable, Codable { case user, assistant }
    enum Status: String, Codable { case pending, streaming, completed, cancelled, failed }
    let id: String
    let role: Role
    var content: String
    let timestamp: Date
    var liked = false
    var disliked = false
    var status: Status = .completed
    var requestId: String?
    var generationId: String?
    var model: String?
    var usage: AssistantUsage?
    var images: [AssistantImage]?
    /// Candidate lineage only; the view model removes this target after success.
    var replacesMessageId: String? = nil
    /// Durable suggestion data; this is never a retained execution permission.
    var taskProposal: AssistantTaskProposal? = nil

    init(id: String, role: Role, content: String, timestamp: Date, liked: Bool = false,
         disliked: Bool = false, status: Status = .completed, requestId: String? = nil,
         generationId: String? = nil, model: String? = nil, usage: AssistantUsage? = nil, images: [AssistantImage]? = nil,
         replacesMessageId: String? = nil, taskProposal: AssistantTaskProposal? = nil) {
        self.id = id; self.role = role; self.content = content; self.timestamp = timestamp
        self.liked = liked; self.disliked = disliked; self.status = status
        self.requestId = requestId; self.generationId = generationId; self.model = model; self.usage = usage
        self.images = images; self.replacesMessageId = replacesMessageId
        self.taskProposal = taskProposal
    }

    static func recoverInterrupted(_ values: [ChatMessage]) -> [ChatMessage] {
        values.map { value in
            var message = value
            if message.status == .pending || message.status == .streaming { message.status = .failed }
            return message
        }
    }

    /// Pure presentation key; callers choose their own localization environment.
    /// Historical pending/streaming records are interrupted, never live requests.
    func statusDescriptionKey(isHistorical: Bool) -> String? {
        switch status {
        case .completed: return nil
        case .pending:
            if !isHistorical { return "正在连接…" }
            return content.isEmpty ? "生成已中断，尚未收到回复" : "生成已中断，已保留部分内容"
        case .streaming:
            if !isHistorical { return "正在生成…" }
            return content.isEmpty ? "生成已中断，尚未收到回复" : "生成已中断，已保留部分内容"
        case .failed:
            return content.isEmpty ? "请求失败，尚未收到回复" : "请求失败，部分结果已保存"
        case .cancelled:
            return content.isEmpty ? "已停止，尚未收到回复" : "已停止，部分结果已保存"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, liked, disliked, status, requestId, generationId, model, usage, images, replacesMessageId, taskProposal
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        liked = try c.decodeIfPresent(Bool.self, forKey: .liked) ?? false
        disliked = try c.decodeIfPresent(Bool.self, forKey: .disliked) ?? false
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .completed
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        generationId = try c.decodeIfPresent(String.self, forKey: .generationId)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        usage = try c.decodeIfPresent(AssistantUsage.self, forKey: .usage)
        images = try c.decodeIfPresent([AssistantImage].self, forKey: .images)
        replacesMessageId = try c.decodeIfPresent(String.self, forKey: .replacesMessageId)
        taskProposal = try c.decodeIfPresent(AssistantTaskProposal.self, forKey: .taskProposal)
    }
}

struct Conversation: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let preview: String
    let date: Date
    let messages: [ChatMessage]
    var serverConversationId: String? = nil
}

struct AssistantChatDraft: Codable, Equatable {
    let text: String
    var images: [AssistantImage]? = nil
    var conversationId: String? = nil
}

struct AssistantArchiveRestoreResult: Codable, Equatable, Sendable {
    var insertedConversations = 0
    var skippedConversations = 0
    var conflictingConversations = 0
    var tombstonedConversations = 0
    var insertedDrafts = 0
    var skippedDrafts = 0
    var conflictingDrafts = 0
    var alreadyApplied = false
}

enum AssistantChatDraftError: Error {
    case invalidOwner, invalidConversation, invalidEnvelope, unsupportedVersion
    case deletedConversation, accountDeletionInProgress
}

/// A separate file per account. Legacy unowned UserDefaults history is never
/// assigned automatically to the next account that happens to log in.
private final class AssistantLegacyChatArchive {
    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private struct DraftEnvelope: Codable {
        let version: Int
        let ownerId: String
        var activeConversationId: String?
        var activeUnassigned: Bool
        var unassignedDraft: AssistantChatDraft?
        var conversationDrafts: [String: AssistantChatDraft]
        var deletedConversationIds: Set<String>
        var isPurgingAll: Bool

        init(ownerId: String) {
            version = 1; self.ownerId = ownerId
            activeConversationId = nil; activeUnassigned = false
            unassignedDraft = nil; conversationDrafts = [:]
            deletedConversationIds = []; isPurgingAll = false
        }
        private enum CodingKeys: String, CodingKey {
            case version, ownerId, activeConversationId, activeUnassigned, unassignedDraft, conversationDrafts
            case deletedConversationIds, isPurgingAll
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            ownerId = try values.decode(String.self, forKey: .ownerId)
            activeConversationId = try values.decodeIfPresent(String.self, forKey: .activeConversationId)
            activeUnassigned = try values.decode(Bool.self, forKey: .activeUnassigned)
            unassignedDraft = try values.decodeIfPresent(AssistantChatDraft.self, forKey: .unassignedDraft)
            conversationDrafts = try values.decode([String: AssistantChatDraft].self, forKey: .conversationDrafts)
            deletedConversationIds = try values.decodeIfPresent(Set<String>.self, forKey: .deletedConversationIds) ?? []
            isPurgingAll = try values.decodeIfPresent(Bool.self, forKey: .isPurgingAll) ?? false
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(version, forKey: .version); try values.encode(ownerId, forKey: .ownerId)
            try values.encodeIfPresent(activeConversationId, forKey: .activeConversationId)
            try values.encode(activeUnassigned, forKey: .activeUnassigned)
            try values.encodeIfPresent(unassignedDraft, forKey: .unassignedDraft)
            try values.encode(conversationDrafts, forKey: .conversationDrafts)
            try values.encode(deletedConversationIds.sorted(), forKey: .deletedConversationIds)
            try values.encode(isPurgingAll, forKey: .isPurgingAll)
        }
        var active: AssistantChatDraft {
            if let id = activeConversationId, let draft = conversationDrafts[id] { return draft }
            return activeUnassigned ? (unassignedDraft ?? AssistantChatDraft(text: "")) : AssistantChatDraft(text: "")
        }
        var records: [AssistantChatDraft] {
            (unassignedDraft.map { [$0] } ?? []) + conversationDrafts.keys.sorted().compactMap { conversationDrafts[$0] }
        }
        var inactive: [AssistantChatDraft] {
            var result = conversationDrafts.keys.sorted().filter { $0 != activeConversationId }.compactMap { conversationDrafts[$0] }
            if !activeUnassigned, let unassignedDraft { result.insert(unassignedDraft, at: 0) }
            return result
        }
        mutating func preserve(_ draft: AssistantChatDraft) {
            if let id = draft.conversationId { conversationDrafts[id] = draft }
            else { unassignedDraft = draft }
        }
    }
    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaoBao/Conversations", isDirectory: true)
    }

    func load(userId: String) throws -> [Conversation] {
        lock.lock(); defer { lock.unlock() }
        let envelope = try readDrafts(userId: userId)
        if envelope.isPurgingAll { return [] }
        return try read(userId: userId).filter { !envelope.deletedConversationIds.contains($0.id) }
    }
    func upsert(_ conversation: Conversation, userId: String) throws {
        lock.lock(); defer { lock.unlock() }
        let envelope = try readDrafts(userId: userId)
        guard !envelope.isPurgingAll else { throw AssistantChatDraftError.accountDeletionInProgress }
        guard !envelope.deletedConversationIds.contains(conversation.id) else { throw AssistantChatDraftError.deletedConversation }
        var items = try read(userId: userId).filter { !envelope.deletedConversationIds.contains($0.id) }
        items.removeAll { $0.id == conversation.id }
        items.insert(conversation, at: 0)
        try write(items, userId: userId)
    }
    /// The protective draft transaction commits first. A later message-write error
    /// propagates, but its durable tombstones prevent recovery after a cold restart.
    func delete(ids: Set<String>, userId: String, purgeUnassignedDraft: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        let items = try read(userId: userId)
        var envelope = try readDrafts(userId: userId)
        guard !envelope.isPurgingAll else { throw AssistantChatDraftError.accountDeletionInProgress }
        for id in ids { try Self.validateConversationId(id) }
        guard !ids.isEmpty || purgeUnassignedDraft else { return }
        envelope.deletedConversationIds.formUnion(ids)
        for id in ids { envelope.conversationDrafts.removeValue(forKey: id) }
        if let active = envelope.activeConversationId, ids.contains(active) { envelope.activeConversationId = nil }
        if purgeUnassignedDraft { envelope.unassignedDraft = nil; envelope.activeUnassigned = false }
        try writeDrafts(envelope, userId: userId)
        try write(items.filter { !envelope.deletedConversationIds.contains($0.id) }, userId: userId)
    }
    func deletedConversationIds(userId: String) throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return try readDrafts(userId: userId).deletedConversationIds
    }
    /// Recovery UI may inspect this state, but only explicit deletion calls mutate it.
    func isPurgingAll(userId: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try readDrafts(userId: userId).isPurgingAll
    }
    func deleteAll(userId: String) throws {
        lock.lock(); defer { lock.unlock() }
        try Self.validateOwner(userId)
        // Explicit account erasure also accepts corrupt legacy sources. The global
        // purge marker protects unknown IDs before either source file is replaced.
        let items = (try? read(userId: userId)) ?? []
        var envelope = (try? readDrafts(userId: userId)) ?? DraftEnvelope(ownerId: userId)
        let known = items.map(\.id) + Array(envelope.conversationDrafts.keys)
        envelope.deletedConversationIds.formUnion(known.filter { (try? Self.validateConversationId($0)) != nil })
        envelope.activeConversationId = nil; envelope.activeUnassigned = false
        envelope.unassignedDraft = nil; envelope.conversationDrafts = [:]; envelope.isPurgingAll = true
        try writeDrafts(envelope, userId: userId)
        try write([], userId: userId)
        let url = location(userId: userId)
        try removeDataIfPresent(at: url)
        let draft = url.appendingPathExtension("draft")
        try removeDataIfPresent(at: draft)
    }
    func loadDraft(userId: String) throws -> String { try loadDraftRecord(userId: userId).text }

    func loadDraftRecord(userId: String) throws -> AssistantChatDraft {
        lock.lock(); defer { lock.unlock() }
        return try readDrafts(userId: userId).active
    }
    /// Reads never select, migrate, or assign a legacy unassociated draft to a conversation.
    func loadDraftRecord(conversationId: String, userId: String) throws -> AssistantChatDraft {
        lock.lock(); defer { lock.unlock() }
        try Self.validateConversationId(conversationId)
        let envelope = try readDrafts(userId: userId)
        guard !envelope.isPurgingAll else { throw AssistantChatDraftError.accountDeletionInProgress }
        guard !envelope.deletedConversationIds.contains(conversationId) else { throw AssistantChatDraftError.deletedConversation }
        return envelope.conversationDrafts[conversationId] ?? AssistantChatDraft(text: "", conversationId: conversationId)
    }
    func loadDraftRecords(userId: String) throws -> [AssistantChatDraft] {
        lock.lock(); defer { lock.unlock() }
        return try readDrafts(userId: userId).records
    }
    /// Export obtains the active pointer and inactive records from one locked disk read.
    func loadDraftSnapshot(userId: String) throws -> (active: AssistantChatDraft, inactive: [AssistantChatDraft]) {
        lock.lock(); defer { lock.unlock() }
        let envelope = try readDrafts(userId: userId)
        return (envelope.active, envelope.inactive)
    }
    func activeDraftForMigration(userId: String) throws -> AssistantChatDraft? {
        lock.lock(); defer { lock.unlock() }
        let envelope = try readDrafts(userId: userId)
        return envelope.activeConversationId != nil || envelope.activeUnassigned ? envelope.active : nil
    }
    func sourceFingerprint(userId: String) throws -> [Data?] {
        lock.lock(); defer { lock.unlock() }
        let source = location(userId: userId)
        return try [source, source.appendingPathExtension("draft")].map { url in try readDataIfPresent(at: url).map { Data(SHA256.hash(data: $0)) } }
    }
    func saveDraft(_ text: String, images: [AssistantImage] = [], conversationId: String? = nil, userId: String) throws {
        lock.lock(); defer { lock.unlock() }
        let draft = AssistantChatDraft(text: text, images: images.isEmpty ? nil : images, conversationId: conversationId)
        try Self.validateDraft(draft)
        var envelope = try readDrafts(userId: userId)
        guard !envelope.isPurgingAll else { throw AssistantChatDraftError.accountDeletionInProgress }
        if let id = conversationId, envelope.deletedConversationIds.contains(id) { throw AssistantChatDraftError.deletedConversation }
        envelope.preserve(draft)
        envelope.activeConversationId = conversationId; envelope.activeUnassigned = conversationId == nil
        try writeDrafts(envelope, userId: userId)
    }
    /// One lock and one atomic file replacement preserve the source and select the
    /// freshly-read target. Initial content is applied only if that target is absent.
    @discardableResult
    func selectDraft(conversationId: String, preserving: AssistantChatDraft?, initialDraft: AssistantChatDraft? = nil,
                     userId: String) throws -> AssistantChatDraft {
        lock.lock(); defer { lock.unlock() }
        try Self.validateConversationId(conversationId)
        var envelope = try readDrafts(userId: userId)
        guard !envelope.isPurgingAll else { throw AssistantChatDraftError.accountDeletionInProgress }
        guard !envelope.deletedConversationIds.contains(conversationId) else { throw AssistantChatDraftError.deletedConversation }
        if let preserving {
            try Self.validateDraft(preserving)
            if let id = preserving.conversationId, envelope.deletedConversationIds.contains(id) { throw AssistantChatDraftError.deletedConversation }
            envelope.preserve(preserving)
        }
        if envelope.conversationDrafts[conversationId] == nil {
            var initial = initialDraft ?? AssistantChatDraft(text: "")
            guard initial.conversationId == nil || initial.conversationId == conversationId else { throw AssistantChatDraftError.invalidConversation }
            initial.conversationId = conversationId
            try Self.validateDraft(initial)
            envelope.conversationDrafts[conversationId] = initial
        }
        guard let selected = envelope.conversationDrafts[conversationId] else { throw AssistantChatDraftError.invalidEnvelope }
        try Self.validateDraft(selected)
        envelope.activeConversationId = conversationId; envelope.activeUnassigned = false
        try writeDrafts(envelope, userId: userId)
        return envelope.active
    }
    func deleteDrafts(conversationIds: Set<String>, userId: String) throws {
        lock.lock(); defer { lock.unlock() }
        var envelope = try readDrafts(userId: userId)
        for id in conversationIds { try Self.validateConversationId(id) }
        guard conversationIds.contains(where: { envelope.conversationDrafts[$0] != nil }) else { return }
        for id in conversationIds { envelope.conversationDrafts.removeValue(forKey: id) }
        if let active = envelope.activeConversationId, conversationIds.contains(active) { envelope.activeConversationId = nil }
        try writeDrafts(envelope, userId: userId)
    }
    private func readDrafts(userId: String) throws -> DraftEnvelope {
        try Self.validateOwner(userId)
        let url = location(userId: userId).appendingPathExtension("draft")
        guard let data = try readDataIfPresent(at: url) else { return DraftEnvelope(ownerId: userId) }
        let decoder = JSONDecoder()
        var result: DraftEnvelope
        if let text = try? decoder.decode(String.self, from: data) {
            result = DraftEnvelope(ownerId: userId)
            result.unassignedDraft = AssistantChatDraft(text: text); result.activeUnassigned = true
        } else {
            let object = try JSONSerialization.jsonObject(with: data)
            if let fields = object as? [String: Any], ["version", "ownerId", "activeConversationId", "activeUnassigned", "unassignedDraft", "conversationDrafts", "deletedConversationIds", "isPurgingAll"].contains(where: { fields[$0] != nil }) {
                result = try decoder.decode(DraftEnvelope.self, from: data)
            } else {
                let legacy = try decoder.decode(AssistantChatDraft.self, from: data)
                result = DraftEnvelope(ownerId: userId); result.preserve(legacy)
                result.activeConversationId = legacy.conversationId; result.activeUnassigned = legacy.conversationId == nil
            }
        }
        try Self.validateEnvelope(result, ownerId: userId)
        // Return a projected copy only. Residual legacy content under a durable
        // tombstone is never exposed, and reads/export never rewrite source bytes.
        if result.isPurgingAll {
            result.activeConversationId = nil; result.activeUnassigned = false
            result.unassignedDraft = nil; result.conversationDrafts = [:]
        } else {
            result.conversationDrafts = result.conversationDrafts.filter { !result.deletedConversationIds.contains($0.key) }
            if let active = result.activeConversationId, result.deletedConversationIds.contains(active) { result.activeConversationId = nil }
        }
        return result
    }
    private static func validateOwner(_ id: String) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf8.count <= 1_024 else { throw AssistantChatDraftError.invalidOwner }
    }
    private static func validateConversationId(_ id: String) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf8.count <= 1_024 else { throw AssistantChatDraftError.invalidConversation }
    }
    private static func validateDraft(_ draft: AssistantChatDraft) throws {
        if let id = draft.conversationId { try validateConversationId(id) }
        guard (draft.images?.count ?? 0) <= AssistantImagePreprocessor.maximumImagesPerMessage,
              draft.text.utf8.count <= 1_048_576 else { throw AssistantMediaError.outputTooLarge }
        for image in draft.images ?? [] { try image.validate() }
    }
    private static func validateEnvelope(_ envelope: DraftEnvelope, ownerId: String) throws {
        guard envelope.version == 1 else { throw AssistantChatDraftError.unsupportedVersion }
        guard envelope.ownerId.utf8.elementsEqual(ownerId.utf8) else { throw AssistantChatDraftError.invalidOwner }
        guard !(envelope.activeConversationId != nil && envelope.activeUnassigned),
              !envelope.activeUnassigned || envelope.unassignedDraft != nil,
              envelope.unassignedDraft?.conversationId == nil else { throw AssistantChatDraftError.invalidEnvelope }
        if let id = envelope.activeConversationId {
            try validateConversationId(id)
            guard envelope.conversationDrafts[id] != nil else { throw AssistantChatDraftError.invalidEnvelope }
        }
        for (id, draft) in envelope.conversationDrafts {
            try validateConversationId(id)
            guard draft.conversationId == id else { throw AssistantChatDraftError.invalidEnvelope }
        }
        for id in envelope.deletedConversationIds { try validateConversationId(id) }
    }
    private func writeDrafts(_ envelope: DraftEnvelope, userId: String) throws {
        try Self.validateEnvelope(envelope, ownerId: userId)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(envelope)
        let draftURL = location(userId: userId).appendingPathExtension("draft")
        #if os(iOS)
        try data.write(to: draftURL, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: draftURL, options: .atomic)
        #endif
    }
    private func location(userId: String) -> URL {
        let name = SHA256.hash(data: Data(userId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }
    private func read(userId: String) throws -> [Conversation] {
        let url = location(userId: userId)
        guard let data = try readDataIfPresent(at: url) else { return [] }
        // Decode failure propagates; subsequent saves cannot erase a corrupt archive.
        return try JSONDecoder().decode([Conversation].self, from: data)
    }
    private func readDataIfPresent(at url: URL) throws -> Data? {
        do { return try Data(contentsOf: url, options: .mappedIfSafe) }
        catch {
            let failure = error as NSError
            let missing = Int(POSIXErrorCode.ENOENT.rawValue)
            if failure.domain == NSPOSIXErrorDomain, failure.code == missing { return nil }
            if failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoSuchFileError,
               let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain, underlying.code == missing { return nil }
            // Cocoa may report ENOTDIR as "not found" too. Never classify it,
            // permission failures or unknown errors as an empty user archive.
            throw error
        }
    }
    private func removeDataIfPresent(at url: URL) throws {
        do { try fileManager.removeItem(at: url) }
        catch {
            let failure = error as NSError
            let missing = Int(POSIXErrorCode.ENOENT.rawValue)
            if failure.domain == NSPOSIXErrorDomain, failure.code == missing { return }
            if failure.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code),
               let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain, underlying.code == missing { return }
            throw error
        }
    }
    private func write(_ values: [Conversation], userId: String) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(values)
        #if os(iOS)
        try data.write(to: location(userId: userId), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: location(userId: userId), options: .atomic)
        #endif
    }
}

enum AssistantArchiveFaultPoint: Equatable {
    case migrationRead, migrationImported, migrationVerified, beforePublish, afterPublish, legacyCleanup
    case beforeMutation, beforeCommit, purgeLegacyCleanup, purgeDatabaseRemoval
}

struct AssistantArchiveDiagnostics {
    let bodyDecodes: Int
    let headerQueries: Int
    let generation: Int64
}

/// Every connection and SQL operation belongs to this serial worker. Sync methods
/// require explicit preparation; none silently migrate an account on MainActor.
final class AssistantChatArchive: @unchecked Sendable {
    static let shared = AssistantChatArchive()
    private struct Authority: Codable { let ownerId: String; let state: String; let version: Int }
    private let directory: URL
    private let authorizationNamespace: String
    private let authorizationRegistry = AssistantArchiveAuthorizationRegistry.shared
    private let authorizationPublishBarrier: (@Sendable () -> Void)?
    private let exportSnapshotBarrier: (@Sendable () -> Void)?
    private let fileManager: FileManager
    private let fault: (@Sendable (AssistantArchiveFaultPoint, String) throws -> Void)?
    private let queue = DispatchQueue(label: "chat.caobao.archive.sqlite", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let cacheLock = NSLock()
    private var preparedOwners: Set<String> = []
    private var databases: [String: AssistantChatDatabase] = [:]
    private var purgedOwners: Set<String> = []
    private var purgePending: Set<String> = []
    private var currentCancellation: AssistantArchiveCancellation?
    private var transactionOwner: String?
    private var postCommitPurges: Set<String> = []
    private var transactionAuthorizationFences: Set<UUID> = []
    private var transactionRestoreAuthorizations: [AssistantArchiveAuthorizationSnapshot] = []

    init(directory: URL? = nil, fileManager: FileManager = .default,
         fault: (@Sendable (AssistantArchiveFaultPoint, String) throws -> Void)? = nil,
         authorizationPublishBarrier: (@Sendable () -> Void)? = nil,
         exportSnapshotBarrier: (@Sendable () -> Void)? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CaoBao/Conversations", isDirectory: true)
        authorizationNamespace = self.directory.standardizedFileURL.resolvingSymlinksInPath().path
        self.authorizationPublishBarrier = authorizationPublishBarrier
        self.exportSnapshotBarrier = exportSnapshotBarrier
        self.fileManager = fileManager; self.fault = fault
        queue.setSpecific(key: queueKey, value: true)
    }
    private func perform<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try operation() }
        return try queue.sync(execute: operation)
    }
    private func cached(_ owner: String, _ prepared: Bool) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if prepared { preparedOwners.insert(name(owner)) } else { preparedOwners.remove(name(owner)) }
    }
    func isPrepared(userId: String) -> Bool { cacheLock.lock(); defer { cacheLock.unlock() }; return preparedOwners.contains(name(userId)) }
    private func authorizationKey(_ owner: String) -> String { authorizationNamespace + "/" + name(owner) + ".sqlite|" + Data(owner.utf8).base64EncodedString() }
    func authorizationSnapshot(userId: String) -> AssistantArchiveAuthorizationSnapshot {
        authorizationRegistry.snapshot(key: authorizationKey(userId), owner: userId)
    }
    private func validateOwner(_ owner: String) throws {
        guard !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, owner.utf8.count <= 1_024 else { throw AssistantChatStorageError.invalidOwner }
    }
    private func name(_ owner: String) -> String { SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined() }
    func databaseURL(userId: String) -> URL { directory.appendingPathComponent(name(userId)).appendingPathExtension("sqlite") }
    func authorityURL(userId: String) -> URL { directory.appendingPathComponent(name(userId)).appendingPathExtension("authority") }
    private func temporaryURL(_ owner: String) -> URL { databaseURL(userId: owner).appendingPathExtension("migrating") }
    private func legacyURL(_ owner: String) -> URL { directory.appendingPathComponent(name(owner)).appendingPathExtension("json") }
    private func atomicWrite(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
    private func protect(_ url: URL) throws {
        #if os(iOS)
        if fileManager.fileExists(atPath: url.path) { try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path) }
        #endif
    }
    private func remove(_ url: URL) throws { if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) } }
    private func writeAuthority(_ owner: String, _ state: String) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        try atomicWrite(encoder.encode(Authority(ownerId: owner, state: state, version: 1)), to: authorityURL(userId: owner))
    }
    private func openComplete(_ owner: String) throws -> AssistantChatDatabase {
        let db = try AssistantChatDatabase(url: databaseURL(userId: owner), create: false)
        guard try db.rows("SELECT value FROM meta WHERE key='owner'").first?.first?.string?.utf8.elementsEqual(owner.utf8) == true,
              try db.rows("SELECT value FROM meta WHERE key='schema'").first?.first?.string == "1",
              try db.rows("SELECT value FROM meta WHERE key='complete'").first?.first?.string == "1" else { throw AssistantChatStorageError.corruptStore }
        try db.ensureAuthorizationMetadata()
        return db
    }
    private func authorizationState(_ db: AssistantChatDatabase) throws -> AssistantArchiveAuthorizationState {
        guard let row = try db.rows("SELECT s.auth_generation,s.purging,m.value FROM state s JOIN meta m ON m.key='auth_identity' WHERE s.singleton=1").first,
              let generation = row[0].int64, generation > 0, let purging = row[1].int64, purging == 0 || purging == 1,
              let rawIdentity = row[2].string, let identity = UUID(uuidString: rawIdentity),
              db.authorizationIdentity == identity else { throw AssistantChatStorageError.corruptStore }
        var deleted: Set<String> = []
        for row in try db.rows("SELECT id FROM deleted") { guard let id = row[0].string else { throw AssistantChatStorageError.corruptStore }; deleted.insert(id) }
        return AssistantArchiveAuthorizationState(identity: identity, sqlGeneration: generation, purging: purging == 1, deletedIDs: deleted)
    }
    private func publishPreparedAuthorization(_ owner: String, db: AssistantChatDatabase, replacingIdentity: Bool = false) throws {
        let key = authorizationKey(owner), ticket = authorizationRegistry.ticket(key)
        db.setCancellation(nil)
        defer { db.setCancellation(currentCancellation) }
        let state = try db.transaction { try authorizationState(db) }
        authorizationPublishBarrier?()
        authorizationRegistry.publish(key, state: state, ticket: ticket, replacingIdentity: replacingIdentity)
    }
    private func dropStaleHandle(_ owner: String) {
        guard let db = databases[name(owner)], let identity = db.authorizationIdentity,
              identity != authorizationSnapshot(userId: owner).identity else { return }
        try? db.close(); databases.removeValue(forKey: name(owner)); cached(owner, false)
    }
    private func cleanupLegacy(_ owner: String) throws {
        try fault?(.legacyCleanup, owner)
        try remove(legacyURL(owner)); try remove(legacyURL(owner).appendingPathExtension("draft"))
        for suffix in ["", "-journal", "-wal", "-shm"] { try remove(URL(fileURLWithPath: temporaryURL(owner).path + suffix)) }
    }
    private func validateStage(_ db: AssistantChatDatabase, owner: String) throws {
        guard try db.rows("SELECT value FROM meta WHERE key='owner'").first?.first?.string?.utf8.elementsEqual(owner.utf8) == true,
              try db.rows("SELECT value FROM meta WHERE key='schema'").first?.first?.string == "1",
              try db.rows("PRAGMA integrity_check").first?.first?.string == "ok",
              try db.rows("PRAGMA foreign_key_check").isEmpty else { throw AssistantChatStorageError.corruptStore }
        for row in try db.rows("SELECT h.id,h.title,h.preview,h.date,h.server_id,h.message_count,b.payload FROM headers h LEFT JOIN bodies b ON b.id=h.id") {
            try db.checkpoint()
            guard let id = row[0].string, let data = row[6].data else { throw AssistantChatStorageError.corruptStore }
            let value = try JSONDecoder().decode(Conversation.self, from: data)
            guard value.id.utf8.elementsEqual(id.utf8), row[1].string?.utf8.elementsEqual(value.title.utf8) == true,
                  row[2].string?.utf8.elementsEqual(value.preview.utf8) == true,
                  row[3].double == value.date.timeIntervalSince1970, row[4].string == value.serverConversationId,
                  row[5].int64 == Int64(value.messages.count) else { throw AssistantChatStorageError.corruptStore }
        }
        for row in try db.rows("SELECT slot,conversation_id,payload FROM drafts") {
            guard let key = row[0].string, let data = row[2].data else { throw AssistantChatStorageError.corruptStore }
            let value = try JSONDecoder().decode(AssistantChatDraft.self, from: data)
            guard slot(value.conversationId) == key, value.conversationId == row[1].string else { throw AssistantChatStorageError.corruptStore }
        }
        _ = try purging(db)
    }
    func prepare(userId owner: String) throws {
        let authorizationTicket = authorizationRegistry.ticket(authorizationKey(owner))
        do { try perform {
            try validateOwner(owner)
            guard transactionOwner == nil else { throw AssistantChatStorageError.transactionBoundary }
            dropStaleHandle(owner)
            if let ready = databases[name(owner)] {
                guard fileManager.fileExists(atPath: databaseURL(userId: owner).path) else {
                    try? ready.close(); databases.removeValue(forKey: name(owner)); cached(owner, false)
                    throw AssistantChatStorageError.authoritativeStoreUnavailable
                }
                try publishPreparedAuthorization(owner, db: ready)
                cached(owner, true)
                if try purging(ready) { return }
                do { try cleanupLegacy(owner) } catch { throw AssistantChatStorageError.publicationCommittedCleanupPending }
                return
            }
            try currentCancellation?.check()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try protect(directory)
            let final = databaseURL(userId: owner), marker = authorityURL(userId: owner), temp = temporaryURL(owner)
            var authority: Authority?
            if fileManager.fileExists(atPath: marker.path) {
                authority = try JSONDecoder().decode(Authority.self, from: Data(contentsOf: marker))
                guard authority?.ownerId.utf8.elementsEqual(owner.utf8) == true, authority?.version == 1,
                      ["publishing", "published", "purging", "purged"].contains(authority?.state ?? "") else { throw AssistantChatStorageError.authoritativeStoreUnavailable }
            }
            if authority?.state == "purging" {
                purgePending.insert(name(owner))
                authorizationRegistry.purgeIntent(authorizationKey(owner))
                throw AssistantChatStorageError.purgeRecoveryRequired
            }
            if fileManager.fileExists(atPath: final.path) {
                let db = try openComplete(owner); databases[name(owner)] = db; cached(owner, true); purgedOwners.remove(name(owner))
                try publishPreparedAuthorization(owner, db: db)
                do { if authority?.state != "published" { try writeAuthority(owner, "published") }; try cleanupLegacy(owner) }
                catch { throw AssistantChatStorageError.publicationCommittedCleanupPending }
                return
            }
            if authority?.state == "publishing", fileManager.fileExists(atPath: temp.path) {
                let staged = try AssistantChatDatabase(url: temp, create: false)
                staged.setCancellation(currentCancellation)
                guard try staged.rows("SELECT value FROM meta WHERE key='owner'").first?.first?.string?.utf8.elementsEqual(owner.utf8) == true,
                      try staged.rows("SELECT value FROM meta WHERE key='complete'").first?.first?.string == "1" else { throw AssistantChatStorageError.authoritativeStoreUnavailable }
                try validateStage(staged, owner: owner); try currentCancellation?.check()
                staged.setCancellation(nil); try staged.close(); try fileManager.moveItem(at: temp, to: final)
                let db = try openComplete(owner); databases[name(owner)] = db; cached(owner, true)
                try publishPreparedAuthorization(owner, db: db, replacingIdentity: true)
                do { try writeAuthority(owner, "published"); try cleanupLegacy(owner) }
                catch { throw AssistantChatStorageError.publicationCommittedCleanupPending }
                return
            }
            if let authority, !["purged", "purging"].contains(authority.state) { throw AssistantChatStorageError.authoritativeStoreUnavailable }
            var published = false
            var staged: AssistantChatDatabase?
            let legacy = AssistantLegacyChatArchive(directory: directory)
            let sourceFingerprint = authority == nil ? try legacy.sourceFingerprint(userId: owner) : nil
            do {
                try remove(temp)
                let db = try AssistantChatDatabase(url: temp, create: true); staged = db; db.setCancellation(currentCancellation)
                try protect(temp)
                try db.transaction {
                    try db.createSchema(ownerId: owner)
                    if authority == nil {
                        try fault?(.migrationRead, owner)
                        let purging = try legacy.isPurgingAll(userId: owner)
                        let deleted = try legacy.deletedConversationIds(userId: owner)
                        for id in deleted { try db.execute("INSERT INTO deleted(id) VALUES(?)", [.text(id)]) }
                        if purging { try db.execute("UPDATE state SET purging=1") }
                        else {
                            for value in try legacy.load(userId: owner) { try putConversation(value, db: db) }
                            let active = try legacy.activeDraftForMigration(userId: owner)
                            let all = try legacy.loadDraftRecords(userId: owner)
                            for draft in all { try putDraft(draft, db: db, validate: false) }
                            let activeSlot = active.flatMap { slot($0.conversationId) }
                            try db.execute("UPDATE state SET active_slot=?", [activeSlot.map(AssistantSQLValue.text) ?? .null])
                        }
                    } else if authority?.state == "purging" { try db.execute("UPDATE state SET purging=1") }
                    try fault?(.migrationImported, owner)
                    try validateStage(db, owner: owner)
                    try fault?(.migrationVerified, owner)
                    try db.execute("INSERT INTO meta(key,value) VALUES('complete','1')")
                }
                try currentCancellation?.check(); db.setCancellation(nil); try db.close(); staged = nil
                try fault?(.beforePublish, owner)
                try currentCancellation?.check()
                if let sourceFingerprint, try legacy.sourceFingerprint(userId: owner) != sourceFingerprint { throw AssistantChatStorageError.corruptStore }
                try writeAuthority(owner, "publishing")
                try fileManager.moveItem(at: temp, to: final); published = true
                let ready = try openComplete(owner); databases[name(owner)] = ready; cached(owner, true); purgedOwners.remove(name(owner))
                try publishPreparedAuthorization(owner, db: ready, replacingIdentity: true)
                try fault?(.afterPublish, owner)
                try writeAuthority(owner, "published"); try protect(final); try cleanupLegacy(owner)
            } catch {
                staged?.setCancellation(nil); try? staged?.close()
                if published { throw AssistantChatStorageError.publicationCommittedCleanupPending }
                if let authority { try? writeAuthority(owner, authority.state); try? remove(temp) }
                else { try? remove(marker); if !fileManager.fileExists(atPath: marker.path) { try? remove(temp) } }
                throw error
            }
        } } catch {
            if (error as? AssistantChatStorageError) != .publicationCommittedCleanupPending {
                authorizationRegistry.invalidate(authorizationKey(owner), ticket: authorizationTicket)
            }
            throw error
        }
    }
    func prepareAsync(userId: String) async throws { try await background { try $0.prepare(userId: userId) } }
    func background<T>(_ operation: @escaping @Sendable (AssistantChatArchive) throws -> T) async throws -> T {
        let token = AssistantArchiveCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.currentCancellation = token
                    defer { self.databases.values.forEach { $0.setCancellation(nil) }; self.currentCancellation = nil }
                    do { try token.check(); continuation.resume(returning: try operation(self)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { token.cancel() })
    }
    func backgroundTransaction<T>(userId: String, operation: @escaping @Sendable (AssistantChatArchive) throws -> T,
                                  beforeCommit: (@Sendable () throws -> Void)? = nil) async throws -> T {
        try await background { archive in
            let db = try archive.database(userId)
            guard archive.transactionOwner == nil else { throw AssistantChatStorageError.transactionBoundary }
            archive.transactionOwner = userId; archive.postCommitPurges = []
            archive.transactionAuthorizationFences = []
            archive.transactionRestoreAuthorizations = []
            let key = archive.authorizationKey(userId), ticket = archive.authorizationRegistry.ticket(key)
            defer {
                archive.authorizationRegistry.finish(key, archive.transactionAuthorizationFences)
                archive.transactionOwner = nil; archive.postCommitPurges = []; archive.transactionAuthorizationFences = []
                archive.transactionRestoreAuthorizations = []
            }
            var committedState: AssistantArchiveAuthorizationState?
            let result = try db.transaction(beforeCommit: {
                try archive.fault?(.beforeCommit, userId); try archive.currentCancellation?.check()
                if archive.authorizationSnapshot(userId: userId).purging, !archive.postCommitPurges.contains(userId) { throw AssistantChatDraftError.accountDeletionInProgress }
                try beforeCommit?()
                for authorization in archive.transactionRestoreAuthorizations { try archive.validateRestoreAuthorization(authorization) }
            }) {
                let result = try operation(archive); committedState = try archive.authorizationState(db); return result
            }
            if let committedState { archive.authorizationPublishBarrier?(); archive.authorizationRegistry.publish(key, state: committedState, ticket: ticket) }
            for owner in archive.postCommitPurges { try archive.finishPurge(owner) }
            return result
        }
    }
    private func database(_ owner: String) throws -> AssistantChatDatabase {
        try validateOwner(owner)
        if let transactionOwner, !transactionOwner.utf8.elementsEqual(owner.utf8) { throw AssistantChatStorageError.transactionBoundary }
        guard let db = databases[name(owner)] else { throw AssistantChatStorageError.notPrepared }
        let authorization = authorizationSnapshot(userId: owner)
        if db.authorizationIdentity != authorization.identity {
            try? db.close(); databases.removeValue(forKey: name(owner)); cached(owner, false)
            throw AssistantChatStorageError.authoritativeStoreUnavailable
        }
        guard fileManager.fileExists(atPath: databaseURL(userId: owner).path) else {
            try? db.close(); databases.removeValue(forKey: name(owner)); cached(owner, false)
            throw AssistantChatStorageError.authoritativeStoreUnavailable
        }
        guard authorization.prepared, !authorization.unknown else { cached(owner, false); throw AssistantChatStorageError.notPrepared }
        db.setCancellation(currentCancellation); return db
    }
    private func mutate<T>(_ owner: String, allowPurging: Bool = false, restoreAuthorization: AssistantArchiveAuthorizationSnapshot? = nil, _ operation: (AssistantChatDatabase) throws -> T) throws -> T {
        let db = try database(owner)
        if !allowPurging, authorizationSnapshot(userId: owner).purging { throw AssistantChatDraftError.accountDeletionInProgress }
        let key = authorizationKey(owner), ticket = authorizationRegistry.ticket(key)
        var committedState: AssistantArchiveAuthorizationState?
        let result = try db.transaction(beforeCommit: {
            try self.fault?(.beforeCommit, owner); try self.currentCancellation?.check()
            if !allowPurging, self.authorizationSnapshot(userId: owner).purging { throw AssistantChatDraftError.accountDeletionInProgress }
            if let restoreAuthorization { try self.validateRestoreAuthorization(restoreAuthorization) }
        }) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fault?(.beforeMutation, owner)
            let result = try operation(db)
            if transactionOwner == nil { committedState = try authorizationState(db) }
            return result
        }
        if let committedState { authorizationPublishBarrier?(); authorizationRegistry.publish(key, state: committedState, ticket: ticket) }
        return result
    }
    private func purging(_ db: AssistantChatDatabase) throws -> Bool {
        guard let value = try db.rows("SELECT purging FROM state WHERE singleton=1").first?.first?.int64, value == 0 || value == 1 else { throw AssistantChatStorageError.corruptStore }
        return value == 1
    }
    private func guardWritable(_ db: AssistantChatDatabase, id: String? = nil) throws {
        guard try !purging(db) else { throw AssistantChatDraftError.accountDeletionInProgress }
        if let id, try !db.rows("SELECT id FROM deleted WHERE id=?", [.text(id)]).isEmpty { throw AssistantChatDraftError.deletedConversation }
    }
    private func normalized(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    private func putConversation(_ value: Conversation, db: AssistantChatDatabase, expectedRevision: Int64? = nil) throws {
        guard !value.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.id.utf8.count <= 1_024,
              value.date.timeIntervalSince1970.isFinite else { throw AssistantChatStorageError.corruptStore }
        try guardWritable(db, id: value.id)
        if value.messages.contains(where: { $0.taskProposal != nil }) {
            guard let owner = try db.rows("SELECT value FROM meta WHERE key='owner'").first?.first?.string else { throw AssistantChatStorageError.corruptStore }
            for message in value.messages {
                if let proposal = message.taskProposal {
                    guard message.role == .assistant else { throw AssistantChatStorageError.corruptStore }
                    try proposal.validate(ownerId: owner, conversationId: value.id, messageId: message.id)
                }
            }
        }
        let old = try db.rows("SELECT sort_at,turn_id,revision,search_text FROM headers WHERE id=?", [.text(value.id)]).first
        if old != nil {
            guard let sort = old?[0].double, sort.isFinite, old?[1].string != nil, let revision = old?[2].int64, revision > 0, old?[3].string != nil else { throw AssistantChatStorageError.corruptStore }
            guard let data = try db.rows("SELECT payload FROM bodies WHERE id=?", [.text(value.id)]).first?.first?.data,
                  try JSONDecoder().decode(Conversation.self, from: data).id == value.id else { throw AssistantChatStorageError.corruptStore }
        }
        if let expectedRevision, old?[2].int64 != expectedRevision { throw AssistantChatStorageError.revisionConflict }
        let turn = value.messages.last(where: { $0.role == .user })?.id ?? value.messages.first?.id ?? ""
        let reordered = old == nil || old?[1].string != turn
        let sort = reordered ? value.date.timeIntervalSince1970 : (old?[0].double ?? value.date.timeIntervalSince1970)
        let search = normalized(value.title + "\n" + value.preview), revision = (old?[2].int64 ?? 0) + 1
        try db.execute("INSERT INTO headers(id,title,preview,date,sort_at,server_id,message_count,revision,search_text,turn_id) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,preview=excluded.preview,date=excluded.date,sort_at=excluded.sort_at,server_id=excluded.server_id,message_count=excluded.message_count,revision=excluded.revision,search_text=excluded.search_text,turn_id=excluded.turn_id", [.text(value.id),.text(value.title),.text(value.preview),.real(value.date.timeIntervalSince1970),.real(sort),value.serverConversationId.map(AssistantSQLValue.text) ?? .null,.integer(Int64(value.messages.count)),.integer(revision),.text(search),.text(turn)])
        try db.execute("INSERT INTO bodies(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [.text(value.id),.blob(try JSONEncoder().encode(value))])
        if reordered { try db.execute("UPDATE state SET list_generation=list_generation+1") }
        if old == nil || old?[3].string != search { try db.execute("UPDATE state SET search_generation=search_generation+1") }
    }
    func upsert(_ value: Conversation, userId: String) throws { try perform { try mutate(userId) { try putConversation(value, db: $0) } } }
    func upsert(_ value: Conversation, expectingRevision: Int64, userId: String) throws { try perform { try mutate(userId) { try putConversation(value, db: $0, expectedRevision: expectingRevision) } } }
    private func fullConversations(_ db: AssistantChatDatabase, id: String? = nil) throws -> [Conversation] {
        if try purging(db) { return [] }
        var sql = "SELECT h.id,b.payload FROM headers h LEFT JOIN bodies b ON b.id=h.id WHERE NOT EXISTS(SELECT 1 FROM deleted d WHERE d.id=h.id)"
        var values: [AssistantSQLValue] = []
        if let id { sql += " AND h.id=?"; values = [.text(id)] }
        sql += " ORDER BY h.sort_at DESC,h.id DESC"
        return try db.rows(sql, values).map { row in
            try db.checkpoint(); guard let id = row[0].string, let data = row[1].data else { throw AssistantChatStorageError.corruptStore }
            db.recordBodyDecode(); let value = try JSONDecoder().decode(Conversation.self, from: data)
            guard value.id == id else { throw AssistantChatStorageError.corruptStore }; return value
        }
    }
    func load(userId: String) throws -> [Conversation] { try perform { if purgedOwners.contains(name(userId)) || authorizationSnapshot(userId: userId).purging { return [] }; let result = try fullConversations(database(userId)); return authorizationSnapshot(userId: userId).purging ? [] : result } }
    func conversation(id: String, userId: String) throws -> Conversation? { try perform { if authorizationSnapshot(userId: userId).purging { return nil }; let result = try fullConversations(database(userId), id: id).first; return authorizationSnapshot(userId: userId).purging ? nil : result } }
    func conversationAsync(id: String, userId: String) async throws -> Conversation? { try await background { try $0.conversation(id: id, userId: userId) } }
    func pageSummaries(userId: String, query: String = "", cursor: AssistantConversationCursor? = nil, limit: Int = 50) throws -> AssistantConversationPage {
        try perform {
            guard (1...200).contains(limit) else { throw AssistantChatStorageError.invalidPageLimit }
            guard query.utf8.count <= 4_096 else { throw AssistantChatStorageError.invalidQuery }
            let db = try database(userId), search = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
            let column = search.isEmpty ? "list_generation" : "search_generation"
            guard let generation = try db.rows("SELECT \(column) FROM state WHERE singleton=1").first?.first?.int64, generation > 0 else { throw AssistantChatStorageError.corruptStore }
            if let cursor, !cursor.ownerId.utf8.elementsEqual(userId.utf8) || cursor.query != search || cursor.generation != generation { throw AssistantChatStorageError.cursorInvalidated }
            if try purging(db) { return AssistantConversationPage(items: [], nextCursor: nil, generation: generation) }
            var sql = "SELECT id,title,preview,date,server_id,message_count,revision,sort_at FROM headers h WHERE NOT EXISTS(SELECT 1 FROM deleted d WHERE d.id=h.id)"
            var values: [AssistantSQLValue] = []
            if !search.isEmpty { sql += " AND instr(search_text,?)>0"; values.append(.text(search)) }
            if let cursor { sql += " AND (sort_at,id)<(?,?)"; values += [.real(cursor.sortAt),.text(cursor.id)] }
            sql += " ORDER BY sort_at DESC,id DESC LIMIT ?"; values.append(.integer(Int64(limit + 1)))
            db.recordHeaderQuery(); let rows = try db.rows(sql, values), shown = Array(rows.prefix(limit))
            let items = try shown.map { row -> AssistantConversationSummary in
                guard let id = row[0].string, let title = row[1].string, let preview = row[2].string, let date = row[3].double, date.isFinite, let sort = row[7].double, sort.isFinite, let count = row[5].int64, count >= 0, let revision = row[6].int64, revision > 0 else { throw AssistantChatStorageError.corruptStore }
                return AssistantConversationSummary(id: id, title: title, preview: preview, date: Date(timeIntervalSince1970: date), serverConversationId: row[4].string, messageCount: Int(count), revision: revision)
            }
            let next = rows.count > limit ? shown.last.flatMap { row in row[7].double.flatMap { sort in row[0].string.map { AssistantConversationCursor(ownerId: userId, query: search, generation: generation, sortAt: sort, id: $0) } } } : nil
            return AssistantConversationPage(items: items, nextCursor: next, generation: generation)
        }
    }
    func pageSummariesAsync(userId: String, query: String = "", cursor: AssistantConversationCursor? = nil, limit: Int = 50) async throws -> AssistantConversationPage {
        try await background { try $0.pageSummaries(userId: userId, query: query, cursor: cursor, limit: limit) }
    }
    private func slot(_ id: String?) -> String? { id.map { "c:" + $0 } ?? "u:" }
    private func validateDraft(_ value: AssistantChatDraft) throws {
        if let id = value.conversationId, id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || id.utf8.count > 1_024 { throw AssistantChatDraftError.invalidConversation }
        guard value.text.utf8.count <= 1_048_576, (value.images?.count ?? 0) <= AssistantImagePreprocessor.maximumImagesPerMessage else { throw AssistantMediaError.outputTooLarge }
        for image in value.images ?? [] { try image.validate() }
    }
    private func putDraft(_ value: AssistantChatDraft, db: AssistantChatDatabase, validate: Bool = true) throws {
        try guardWritable(db, id: value.conversationId); if validate { try validateDraft(value) }
        if let row = try db.rows("SELECT payload,conversation_id FROM drafts WHERE slot=?", [.text(slot(value.conversationId)!)]).first {
            guard let data = row[0].data else { throw AssistantChatStorageError.corruptStore }
            let old = try JSONDecoder().decode(AssistantChatDraft.self, from: data)
            guard slot(old.conversationId) == slot(value.conversationId), old.conversationId == row[1].string else { throw AssistantChatStorageError.corruptStore }
        }
        try db.execute("INSERT INTO drafts(slot,conversation_id,payload,revision) VALUES(?,?,?,1) ON CONFLICT(slot) DO UPDATE SET payload=excluded.payload,revision=drafts.revision+1", [.text(slot(value.conversationId)!),value.conversationId.map(AssistantSQLValue.text) ?? .null,.blob(try JSONEncoder().encode(value))])
    }
    private func draftSnapshot(_ db: AssistantChatDatabase) throws -> (active: AssistantChatDraft, inactive: [AssistantChatDraft], records: [AssistantChatDraft]) {
        if try purging(db) { return (AssistantChatDraft(text: ""), [], []) }
        let activeSlot = try db.rows("SELECT active_slot FROM state").first?.first?.string
        let rows = try db.rows("SELECT slot,payload,conversation_id FROM drafts x WHERE conversation_id IS NULL OR NOT EXISTS(SELECT 1 FROM deleted d WHERE d.id=x.conversation_id) ORDER BY CASE WHEN conversation_id IS NULL THEN 0 ELSE 1 END,conversation_id")
        var active = AssistantChatDraft(text: ""), inactive: [AssistantChatDraft] = [], records: [AssistantChatDraft] = []
        for row in rows {
            guard let key = row[0].string, let data = row[1].data else { throw AssistantChatStorageError.corruptStore }
            let draft = try JSONDecoder().decode(AssistantChatDraft.self, from: data)
            guard slot(draft.conversationId) == key, draft.conversationId == row[2].string else { throw AssistantChatStorageError.corruptStore }
            records.append(draft); if key == activeSlot { active = draft } else { inactive.append(draft) }
        }
        return (active, inactive, records)
    }
    func loadDraft(userId: String) throws -> String { try loadDraftRecord(userId: userId).text }
    func loadDraftRecord(userId: String) throws -> AssistantChatDraft {
        try perform {
            if purgedOwners.contains(name(userId)) || purgePending.contains(name(userId)) || authorizationSnapshot(userId: userId).purging { return AssistantChatDraft(text: "") }
            let db = try database(userId)
            if try purging(db) { return AssistantChatDraft(text: "") }
            let rows = try db.rows("SELECT d.slot,d.payload,d.conversation_id FROM state s JOIN drafts d ON d.slot=s.active_slot WHERE d.conversation_id IS NULL OR NOT EXISTS(SELECT 1 FROM deleted x WHERE x.id=d.conversation_id)")
            guard let row = rows.first else { return AssistantChatDraft(text: "") }
            guard let key = row[0].string, let data = row[1].data else { throw AssistantChatStorageError.corruptStore }
            let value = try JSONDecoder().decode(AssistantChatDraft.self, from: data)
            guard slot(value.conversationId) == key, value.conversationId == row[2].string else { throw AssistantChatStorageError.corruptStore }; return value
        }
    }
    func loadDraftRecord(conversationId: String, userId: String) throws -> AssistantChatDraft {
        try perform {
            let db = try database(userId); try guardWritable(db, id: conversationId)
            guard let row = try db.rows("SELECT payload,conversation_id FROM drafts WHERE slot=?", [.text(slot(conversationId)!)]).first else { return AssistantChatDraft(text: "", conversationId: conversationId) }
            guard let data = row[0].data else { throw AssistantChatStorageError.corruptStore }
            let value = try JSONDecoder().decode(AssistantChatDraft.self, from: data); guard value.conversationId == conversationId, value.conversationId == row[1].string else { throw AssistantChatStorageError.corruptStore }; return value
        }
    }
    func loadDraftRecords(userId: String) throws -> [AssistantChatDraft] { try perform { if purgedOwners.contains(name(userId)) || authorizationSnapshot(userId: userId).purging { return [] }; let result = try draftSnapshot(database(userId)).records; return authorizationSnapshot(userId: userId).purging ? [] : result } }
    func loadDraftSnapshot(userId: String) throws -> (active: AssistantChatDraft, inactive: [AssistantChatDraft]) {
        try perform { if purgedOwners.contains(name(userId)) || authorizationSnapshot(userId: userId).purging { return (AssistantChatDraft(text: ""), []) }; let value = try draftSnapshot(database(userId)); return authorizationSnapshot(userId: userId).purging ? (AssistantChatDraft(text: ""), []) : (value.active, value.inactive) }
    }
    func saveDraft(_ text: String, images: [AssistantImage] = [], conversationId: String? = nil, userId: String) throws {
        try perform { try mutate(userId) { db in
            let value = AssistantChatDraft(text: text, images: images.isEmpty ? nil : images, conversationId: conversationId)
            try putDraft(value, db: db); try db.execute("UPDATE state SET active_slot=?", [.text(slot(conversationId)!)])
        } }
    }

    /// Insert-only, per-archive merge. The digest marker and every inserted row
    /// share the same SQLite commit; this is not a cross-store transaction.
    func restoreBackup(conversations: [Conversation], drafts: [AssistantChatDraft], backupDigest: String, userId: String) throws -> AssistantArchiveRestoreResult {
        try Task.checkCancellation()
        return try perform {
            try validateOwner(userId)
            guard backupDigest.utf8.count == 64, backupDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw AssistantChatStorageError.corruptStore }
            _ = try database(userId)
            let authorization = authorizationSnapshot(userId: userId)
            try validateRestoreAuthorization(authorization)
            let result = try mutate(userId, restoreAuthorization: authorization) { db in
                try guardWritable(db)
                try validateRestoreRecords(conversations: conversations, drafts: drafts)
                let marker = "restore.v1." + backupDigest
                if let value = try db.rows("SELECT value FROM meta WHERE key=?", [.text(marker)]).first?.first?.string {
                    guard value == "1" else { throw AssistantChatStorageError.corruptStore }
                    return AssistantArchiveRestoreResult(alreadyApplied: true)
                }
                let savepoint = "restore_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                try db.execute("SAVEPOINT " + savepoint)
                do {
                    var result = AssistantArchiveRestoreResult()
                    let activeSlot = try db.rows("SELECT active_slot FROM state WHERE singleton=1").first?.first?.string
                    for conversation in conversations {
                        try db.checkpoint(); try validateRestoreAuthorization(authorization)
                        if try !db.rows("SELECT id FROM deleted WHERE id=?", [.text(conversation.id)]).isEmpty { result.tombstonedConversations += 1; continue }
                        if let row = try db.rows("SELECT b.payload FROM headers h LEFT JOIN bodies b ON b.id=h.id WHERE h.id=?", [.text(conversation.id)]).first {
                            guard let data = row.first?.data else { throw AssistantChatStorageError.corruptStore }
                            let existing = try JSONDecoder().decode(Conversation.self, from: data)
                            guard existing.id.utf8.elementsEqual(conversation.id.utf8) else { throw AssistantChatStorageError.corruptStore }
                            if try restoreData(existing, forComparison: true) == restoreData(conversation, forComparison: true) { result.skippedConversations += 1 }
                            else { result.conflictingConversations += 1 }
                        } else { try putConversation(conversation, db: db); result.insertedConversations += 1 }
                    }
                    for draft in drafts {
                        try db.checkpoint(); try validateRestoreAuthorization(authorization)
                        let key = slot(draft.conversationId)!
                        if draft.conversationId == nil {
                            let unassigned = try db.rows("SELECT slot FROM drafts WHERE conversation_id IS NULL")
                            guard unassigned.count <= 1, unassigned.first.map({ $0.first?.string == key }) ?? true else { throw AssistantChatStorageError.corruptStore }
                        }
                        if let id = draft.conversationId, try !db.rows("SELECT id FROM deleted WHERE id=?", [.text(id)]).isEmpty { result.skippedDrafts += 1; continue }
                        if let row = try db.rows("SELECT payload,conversation_id FROM drafts WHERE slot=?", [.text(key)]).first {
                            guard let data = row[0].data else { throw AssistantChatStorageError.corruptStore }
                            let existing = try JSONDecoder().decode(AssistantChatDraft.self, from: data)
                            guard slot(existing.conversationId)?.utf8.elementsEqual(key.utf8) == true,
                                  Self.restoreSameIdentifier(existing.conversationId, row[1].string) else { throw AssistantChatStorageError.corruptStore }
                            if try restoreData(existing) == restoreData(draft) { result.skippedDrafts += 1 }
                            else { result.conflictingDrafts += 1 }
                        } else if activeSlot?.utf8.elementsEqual(key.utf8) == true {
                            // Never turn an existing dangling active pointer into
                            // an implicitly activated restored draft.
                            result.conflictingDrafts += 1
                        } else { try putDraft(draft, db: db); result.insertedDrafts += 1 }
                    }
                    try validateRestoreAuthorization(authorization)
                    try db.execute("INSERT INTO meta(key,value) VALUES(?,?)", [.text(marker), .text("1")])
                    try db.execute("RELEASE SAVEPOINT " + savepoint)
                    return result
                } catch {
                    try? db.execute("ROLLBACK TO SAVEPOINT " + savepoint)
                    try? db.execute("RELEASE SAVEPOINT " + savepoint)
                    throw error
                }
            }
            if transactionOwner != nil { transactionRestoreAuthorizations.append(authorization) }
            return result
        }
    }
    private func validateRestoreAuthorization(_ expected: AssistantArchiveAuthorizationSnapshot) throws {
        let current = authorizationSnapshot(userId: expected.ownerId)
        if current.purging { throw AssistantChatDraftError.accountDeletionInProgress }
        guard current.canWrite(), current.identity == expected.identity, current.version == expected.version,
              current.ownerId.utf8.elementsEqual(expected.ownerId.utf8) else { throw AssistantChatStorageError.revisionConflict }
    }
    private static func restoreSameIdentifier(_ left: String?, _ right: String?) -> Bool {
        switch (left, right) { case (nil, nil): return true; case let (left?, right?): return left.utf8.elementsEqual(right.utf8); default: return false }
    }
    private func restoreData<T: Encodable>(_ value: T, forComparison: Bool = false) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Public backups represent dates as Unix seconds. Compare that exact
        // representation without rewriting the local internal Date precision.
        if forComparison { encoder.dateEncodingStrategy = .secondsSince1970 }
        return try encoder.encode(value)
    }
    private func validateRestoreRecords(conversations: [Conversation], drafts: [AssistantChatDraft]) throws {
        guard conversations.count <= 1_000, drafts.count <= 1_001 else { throw AssistantMediaError.outputTooLarge }
        var conversationIDs = Set<Data>(), draftSlots = Set<Data>(), totalMessages = 0, totalBytes = 0
        func identifier(_ value: String) throws {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 1_024 else { throw AssistantChatStorageError.corruptStore }
        }
        func boundedText(_ value: String) throws { guard value.utf8.count <= 1_048_576 else { throw AssistantMediaError.outputTooLarge } }
        func addBytes(_ value: Int) throws {
            guard value <= 32 * 1_024 * 1_024 - totalBytes else { throw AssistantMediaError.outputTooLarge }; totalBytes += value
        }
        for conversation in conversations {
            try currentCancellation?.check(); try identifier(conversation.id)
            guard conversationIDs.insert(Data(conversation.id.utf8)).inserted, conversation.serverConversationId == nil,
                  conversation.date.timeIntervalSince1970.isFinite, conversation.messages.count <= 10_000 - totalMessages else { throw AssistantChatStorageError.corruptStore }
            totalMessages += conversation.messages.count; try boundedText(conversation.title); try boundedText(conversation.preview)
            var messageIDs = Set<Data>()
            for message in conversation.messages {
                try identifier(message.id); try boundedText(message.content)
                guard messageIDs.insert(Data(message.id.utf8)).inserted, message.timestamp.timeIntervalSince1970.isFinite,
                      message.taskProposal == nil, message.requestId == nil, message.generationId == nil, message.replacesMessageId == nil,
                      message.status != .pending, message.status != .streaming,
                      (message.images?.count ?? 0) <= AssistantImagePreprocessor.maximumImagesPerMessage else { throw AssistantChatStorageError.corruptStore }
                if let model = message.model { try boundedText(model) }
                if let usage = message.usage { guard (usage.inputTokens ?? 0) >= 0, (usage.outputTokens ?? 0) >= 0 else { throw AssistantChatStorageError.corruptStore } }
                for image in message.images ?? [] { try image.validate() }
            }
            try addBytes(restoreData(conversation).count)
        }
        for draft in drafts {
            try currentCancellation?.check(); try validateDraft(draft)
            guard draftSlots.insert(Data(slot(draft.conversationId)!.utf8)).inserted else { throw AssistantChatStorageError.corruptStore }
            try addBytes(restoreData(draft).count)
        }
    }
    @discardableResult
    func selectDraft(conversationId: String, preserving: AssistantChatDraft?, initialDraft: AssistantChatDraft? = nil, userId: String) throws -> AssistantChatDraft {
        try perform { try mutate(userId) { db in
            try guardWritable(db, id: conversationId)
            if let preserving { try putDraft(preserving, db: db) }
            var target: AssistantChatDraft
            if let row = try db.rows("SELECT payload,conversation_id FROM drafts WHERE slot=?", [.text(slot(conversationId)!)]).first { guard let data = row[0].data else { throw AssistantChatStorageError.corruptStore }; target = try JSONDecoder().decode(AssistantChatDraft.self, from: data); guard target.conversationId == row[1].string else { throw AssistantChatStorageError.corruptStore } }
            else { target = initialDraft ?? AssistantChatDraft(text: ""); guard target.conversationId == nil || target.conversationId == conversationId else { throw AssistantChatDraftError.invalidConversation }; target.conversationId = conversationId }
            guard target.conversationId == conversationId else { throw AssistantChatStorageError.corruptStore }; try validateDraft(target)
            try putDraft(target, db: db); try db.execute("UPDATE state SET active_slot=?", [.text(slot(conversationId)!)]); return target
        } }
    }
    func deleteDrafts(conversationIds: Set<String>, userId: String) throws { try perform { try mutate(userId) { db in for id in conversationIds { try db.execute("DELETE FROM drafts WHERE conversation_id=?", [.text(id)]) } } } }
    func deletedConversationIds(userId: String) throws -> Set<String> { try perform { if purgedOwners.contains(name(userId)) { return [] }; return try Set(database(userId).rows("SELECT id FROM deleted ORDER BY id").compactMap { $0.first?.string }) } }
    func isPurgingAll(userId: String) throws -> Bool {
        try perform {
            try validateOwner(userId)
            if purgePending.contains(name(userId)) { return true }; if purgedOwners.contains(name(userId)) { return false }
            if let db = databases[name(userId)] { return try purging(db) }
            let marker = authorityURL(userId: userId)
            if fileManager.fileExists(atPath: marker.path) {
                let authority = try JSONDecoder().decode(Authority.self, from: Data(contentsOf: marker))
                guard authority.ownerId.utf8.elementsEqual(userId.utf8), authority.version == 1, ["published","publishing","purged","purging"].contains(authority.state) else { throw AssistantChatStorageError.authoritativeStoreUnavailable }
                return authority.state == "purging"
            }
            throw AssistantChatStorageError.notPrepared
        }
    }
    func delete(ids: Set<String>, userId: String, purgeUnassignedDraft: Bool = false) throws {
        let key = authorizationKey(userId), fence = authorizationRegistry.begin(key)
        var deferred = false
        defer { if !deferred { authorizationRegistry.finish(key, [fence]) } }
        try perform {
            if let transactionOwner {
                guard transactionOwner.utf8.elementsEqual(userId.utf8) else { throw AssistantChatStorageError.transactionBoundary }
                transactionAuthorizationFences.insert(fence); deferred = true
            }
            try mutate(userId) { db in
            try guardWritable(db)
            for id in ids { try db.execute("INSERT OR IGNORE INTO deleted(id) VALUES(?)", [.text(id)]); try db.execute("DELETE FROM drafts WHERE conversation_id=?", [.text(id)]); try db.execute("DELETE FROM headers WHERE id=?", [.text(id)]) }
            if purgeUnassignedDraft { try db.execute("DELETE FROM drafts WHERE conversation_id IS NULL") }
            try db.execute("UPDATE state SET list_generation=list_generation+1,search_generation=search_generation+1,auth_generation=auth_generation+1")
        } }
    }
    func deleteAll(userId: String) throws {
        let key = authorizationKey(userId), fence = authorizationRegistry.begin(key)
        var deferred = false
        defer { if !deferred { authorizationRegistry.finish(key, [fence]) } }
        try perform {
            try validateOwner(userId)
            if let transactionOwner {
                guard transactionOwner.utf8.elementsEqual(userId.utf8) else { throw AssistantChatStorageError.transactionBoundary }
                transactionAuthorizationFences.insert(fence); deferred = true
            }
            else {
                dropStaleHandle(userId)
                let authorization = authorizationSnapshot(userId: userId)
                if authorization.unknown || !authorization.prepared || authorization.purging {
                    try? databases[name(userId)]?.close()
                    databases.removeValue(forKey: name(userId)); cached(userId, false)
                }
            }
            if databases[name(userId)] == nil {
                guard transactionOwner == nil else { throw AssistantChatStorageError.transactionBoundary }
                try fault?(.beforeMutation, userId); try currentCancellation?.check()
                try writeAuthority(userId, "purging"); purgePending.insert(name(userId))
                authorizationRegistry.purgeIntent(key)
                try finishPurge(userId, intentWritten: true); return
            }
            do { try mutate(userId, allowPurging: true) { db in
                try db.execute("INSERT OR IGNORE INTO deleted(id) SELECT id FROM headers")
                try db.execute("INSERT OR IGNORE INTO deleted(id) SELECT conversation_id FROM drafts WHERE conversation_id IS NOT NULL")
                try db.execute("UPDATE state SET purging=1,active_slot=NULL,list_generation=list_generation+1,search_generation=search_generation+1,auth_generation=auth_generation+1")
                try db.execute("DELETE FROM drafts"); try db.execute("DELETE FROM headers")
            } } catch {
                if transactionOwner == nil, let error = error as? AssistantChatStorageError,
                   error == .corruptStore || error == .sqlite(11) || error == .sqlite(26) {
                    try writeAuthority(userId, "purging"); purgePending.insert(name(userId))
                    authorizationRegistry.purgeIntent(key)
                    try finishPurge(userId, intentWritten: true); return
                }
                throw error
            }
            if transactionOwner != nil { postCommitPurges.insert(userId) } else { try finishPurge(userId) }
        }
    }
    private func finishPurge(_ owner: String, intentWritten: Bool = false) throws {
        purgePending.insert(name(owner))
        authorizationRegistry.purgeIntent(authorizationKey(owner))
        do {
            if !intentWritten { try writeAuthority(owner, "purging") }; try fault?(.purgeLegacyCleanup, owner)
            try cleanupLegacy(owner)
            try fault?(.purgeDatabaseRemoval, owner)
            try databases[name(owner)]?.close(); databases.removeValue(forKey: name(owner)); cached(owner, false)
            for suffix in ["-journal", "-wal", "-shm", ""] { try remove(URL(fileURLWithPath: databaseURL(userId: owner).path + suffix)) }
            try writeAuthority(owner, "purged"); purgePending.remove(name(owner)); purgedOwners.insert(name(owner))
            authorizationRegistry.purged(authorizationKey(owner))
        } catch {
            if databases[name(owner)] == nil, fileManager.fileExists(atPath: databaseURL(userId: owner).path), let reopened = try? openComplete(owner) { databases[name(owner)] = reopened; cached(owner, true) }
            throw AssistantChatStorageError.publicationCommittedCleanupPending
        }
    }
    func loadExportSnapshot(userId: String) throws -> (conversations: [Conversation], activeDraft: AssistantChatDraft, inactiveDrafts: [AssistantChatDraft]) {
        try perform {
            let authorization = authorizationSnapshot(userId: userId)
            guard !authorization.purging else { throw AssistantChatStorageError.purgeRecoveryRequired }
            if purgedOwners.contains(name(userId)), !authorization.prepared, !authorization.unknown { return ([], AssistantChatDraft(text: ""), []) }
            let db = try database(userId)
            let result = try db.transaction {
                guard try !purging(db) else { throw AssistantChatStorageError.purgeRecoveryRequired }
                let conversations = try fullConversations(db), drafts = try draftSnapshot(db); return (conversations, drafts.active, drafts.inactive)
            }
            // Test-only boundary after the SQL read closes; no SQL/cache lock is held.
            exportSnapshotBarrier?()
            guard !authorizationSnapshot(userId: userId).purging else { throw AssistantChatStorageError.purgeRecoveryRequired }
            return result
        }
    }
    func loadExportSnapshotAsync(userId: String) async throws -> (conversations: [Conversation], activeDraft: AssistantChatDraft, inactiveDrafts: [AssistantChatDraft]) { try await background { try $0.loadExportSnapshot(userId: userId) } }
    func exportSnapshot(userId: String) throws -> AssistantArchiveExportSnapshot {
        try perform {
            let authorization = authorizationSnapshot(userId: userId)
            guard !authorization.purging else { throw AssistantChatStorageError.purgeRecoveryRequired }
            if purgedOwners.contains(name(userId)), !authorization.prepared, !authorization.unknown { return AssistantArchiveExportSnapshot(ownerId: userId, conversations: [], activeDraft: AssistantChatDraft(text: ""), inactiveDrafts: []) }
            let db = try database(userId)
            let result = try db.transaction {
                guard try !purging(db) else { throw AssistantChatStorageError.purgeRecoveryRequired }
                let conversations = try fullConversations(db), drafts = try draftSnapshot(db)
                guard let generation = try db.rows("SELECT list_generation FROM state WHERE singleton=1").first?.first?.int64 else { throw AssistantChatStorageError.corruptStore }
                return AssistantArchiveExportSnapshot(ownerId: userId, conversations: conversations, activeDraft: drafts.active, inactiveDrafts: drafts.inactive, generation: generation)
            }
            exportSnapshotBarrier?()
            guard !authorizationSnapshot(userId: userId).purging else { throw AssistantChatStorageError.purgeRecoveryRequired }
            return result
        }
    }
    func exportSnapshotAsync(userId: String) async throws -> AssistantArchiveExportSnapshot { try await background { try $0.exportSnapshot(userId: userId) } }
    func diagnostics(userId: String) throws -> AssistantArchiveDiagnostics { try perform { let db = try database(userId); return AssistantArchiveDiagnostics(bodyDecodes: db.bodyDecodes, headerQueries: db.headerQueries, generation: try db.rows("SELECT list_generation FROM state").first?.first?.int64 ?? 0) } }
}
