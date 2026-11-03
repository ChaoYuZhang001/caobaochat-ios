import Foundation
import SQLite3

struct AssistantConversationSummary: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let preview: String
    let date: Date
    var serverConversationId: String? = nil
    let messageCount: Int
    let revision: Int64
}

struct AssistantConversationCursor: Hashable, Codable, Sendable {
    let ownerId: String
    let query: String
    let generation: Int64
    let sortAt: TimeInterval
    let id: String
}

struct AssistantConversationPage: Equatable, Sendable {
    let items: [AssistantConversationSummary]
    let nextCursor: AssistantConversationCursor?
    let generation: Int64
}

struct AssistantArchiveAuthorizationSnapshot: Equatable, Sendable {
    let ownerId: String
    let prepared: Bool
    let purging: Bool
    let deletedIDs: Set<String>
    let identity: UUID
    let version: UInt64
    let inFlightDestructive: Bool
    let unknown: Bool
    func canWrite(conversationId: String? = nil) -> Bool {
        prepared && !purging && !inFlightDestructive && !unknown && !conversationId.map(deletedIDs.contains, default: false)
    }
}

private extension Optional {
    func map<T>(_ transform: (Wrapped) -> T, default fallback: T) -> T { map(transform) ?? fallback }
}

/// Only copied Codable value records cross the worker boundary; no connection,
/// continuation, mutable reference object, credential or lazy reader is retained.
struct AssistantArchiveExportSnapshot: @unchecked Sendable {
    let ownerId: String
    let conversations: [Conversation]
    let activeDraft: AssistantChatDraft
    let inactiveDrafts: [AssistantChatDraft]
    let generation: Int64?
    init(ownerId: String, conversations: [Conversation], activeDraft: AssistantChatDraft,
         inactiveDrafts: [AssistantChatDraft], generation: Int64? = nil) {
        self.ownerId = ownerId; self.conversations = conversations; self.activeDraft = activeDraft
        self.inactiveDrafts = inactiveDrafts; self.generation = generation
    }
}

struct AssistantArchiveAuthorizationState: Equatable {
    let identity: UUID
    let sqlGeneration: Int64
    let purging: Bool
    let deletedIDs: Set<String>
}

/// Process-wide, byte-exact owner/path keys. Locks protect value metadata only;
/// callers perform SQL, migration, file deletion and testing barriers outside it.
final class AssistantArchiveAuthorizationRegistry: @unchecked Sendable {
    static let shared = AssistantArchiveAuthorizationRegistry()
    struct Ticket { let identity: UUID?; let sqlGeneration: Int64; let version: UInt64 }
    private struct Entry {
        var placeholder = UUID()
        var identity: UUID?
        var sqlGeneration: Int64 = -1
        var prepared = false
        var purging = false
        var deletedIDs: Set<String> = []
        var unknown = true
        var version: UInt64 = 1
        var minimumReadVersion: UInt64 = 0
        var fences: Set<UUID> = []
        var retired: Set<UUID> = []
        var purgeSeal = false
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    func snapshot(key: String, owner: String) -> AssistantArchiveAuthorizationSnapshot {
        lock.lock(); defer { lock.unlock() }
        let entry = entries[key] ?? Entry(); entries[key] = entry
        return AssistantArchiveAuthorizationSnapshot(ownerId: owner, prepared: entry.prepared, purging: entry.purging,
            deletedIDs: entry.deletedIDs, identity: entry.identity ?? entry.placeholder, version: entry.version,
            inFlightDestructive: !entry.fences.isEmpty, unknown: entry.unknown)
    }
    func ticket(_ key: String) -> Ticket {
        lock.lock(); defer { lock.unlock() }; let entry = entries[key] ?? Entry(); entries[key] = entry
        return Ticket(identity: entry.identity, sqlGeneration: entry.sqlGeneration, version: entry.version)
    }
    func begin(_ key: String) -> UUID {
        lock.lock(); defer { lock.unlock() }; var entry = entries[key] ?? Entry(); let id = UUID()
        entry.fences.insert(id); entry.version += 1; entries[key] = entry; return id
    }
    func finish(_ key: String, _ ids: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }; var entry = entries[key] ?? Entry()
        let before = entry.fences.count; entry.fences.subtract(ids)
        if before != entry.fences.count { entry.version += 1 }; entries[key] = entry
    }
    func invalidate(_ key: String, ticket: Ticket) {
        lock.lock(); defer { lock.unlock() }; var entry = entries[key] ?? Entry()
        guard entry.identity == ticket.identity, entry.sqlGeneration <= ticket.sqlGeneration else { return }
        if entry.prepared || !entry.unknown { entry.prepared = false; entry.unknown = true; entry.version += 1 }
        entry.minimumReadVersion = entry.version; entries[key] = entry
    }
    func publish(_ key: String, state: AssistantArchiveAuthorizationState, ticket: Ticket, replacingIdentity: Bool = false) {
        lock.lock(); defer { lock.unlock() }; var entry = entries[key] ?? Entry()
        guard !entry.retired.contains(state.identity) else { return }
        if entry.purgeSeal, !state.purging { return }
        if let identity = entry.identity, identity != state.identity {
            guard replacingIdentity else { return }; entry.retired.insert(identity)
            entry.identity = nil; entry.sqlGeneration = -1
        }
        guard state.sqlGeneration >= entry.sqlGeneration else { return }
        if state.sqlGeneration == entry.sqlGeneration, ticket.version < entry.minimumReadVersion { return }
        let changed = entry.identity != state.identity || entry.sqlGeneration != state.sqlGeneration || !entry.prepared
            || entry.unknown || entry.purging != state.purging
        entry.identity = state.identity; entry.sqlGeneration = state.sqlGeneration; entry.prepared = true
        entry.purging = state.purging; entry.deletedIDs = state.deletedIDs; entry.unknown = false
        if changed { entry.version += 1 }; entries[key] = entry
    }
    func purgeIntent(_ key: String) {
        lock.lock(); defer { lock.unlock() }; var entry = entries[key] ?? Entry()
        if !entry.purging || !entry.purgeSeal { entry.purging = true; entry.purgeSeal = true; entry.version += 1 }
        entry.minimumReadVersion = entry.version; entries[key] = entry
    }
    func purged(_ key: String) {
        lock.lock(); defer { lock.unlock() }; var entry = entries[key] ?? Entry()
        if let identity = entry.identity { entry.retired.insert(identity) }
        entry.identity = nil; entry.placeholder = UUID(); entry.sqlGeneration = -1
        entry.prepared = false; entry.purging = false; entry.deletedIDs = []; entry.unknown = false
        entry.purgeSeal = false
        entry.version += 1; entry.minimumReadVersion = entry.version; entries[key] = entry
    }
}

enum AssistantChatStorageError: LocalizedError, Equatable {
    case notPrepared, cursorInvalidated, invalidPageLimit, invalidOwner
    case authoritativeStoreUnavailable, corruptStore, publicationCommittedCleanupPending
    case transactionBoundary, revisionConflict, invalidQuery, purgeRecoveryRequired
    case sqlite(Int32)

    /// Fixed user-facing resource keys only. SQLite codes and implementation
    /// details stay out of descriptions displayed by any caller of Error.
    var localizationKey: String {
        switch self {
        case .notPrepared: return "本地历史记录尚未准备好，请稍后重试。"
        case .cursorInvalidated: return "历史记录已更新，请从第一页重新加载。"
        case .invalidPageLimit: return "无法加载这页历史记录，请重新加载列表。"
        case .invalidOwner: return "当前账号信息无效，请重新打开页面后重试。"
        case .authoritativeStoreUnavailable: return "无法打开当前账号的本地历史记录，请稍后重试。现有数据不会被自动覆盖。"
        case .corruptStore: return "本地历史记录格式异常，已停止本次操作以保护数据。请稍后重试。"
        case .publicationCommittedCleanupPending: return "本次更改已保存，但本地清理尚未完成。请重试清理。"
        case .transactionBoundary: return "无法在当前状态下完成本次操作，请重新打开页面后重试。"
        case .revisionConflict: return "这条会话已被其他操作更新，请重新打开后再保存。"
        case .invalidQuery: return "搜索内容过长，请缩短后重试。"
        case .purgeRecoveryRequired: return "上次本地清理尚未完成。请先重试清理，再继续使用历史记录。"
        case .sqlite: return "本地历史记录暂时无法读写，请稍后重试。"
        }
    }
    var errorDescription: String? { localizedMessage() }

    /// Bundle injection tests the same resource lookup used by production errors.
    func localizedMessage(bundle: Bundle = .main) -> String {
        AssistantLocalization.string(localizationKey, bundle: bundle)
    }
}

final class AssistantArchiveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func check() throws { if isCancelled { throw CancellationError() } }
}

enum AssistantSQLValue {
    case null, text(String), integer(Int64), real(Double), blob(Data)
    var string: String? { if case .text(let value) = self { return value }; return nil }
    var int64: Int64? { if case .integer(let value) = self { return value }; return nil }
    var double: Double? { switch self { case .real(let value): return value; case .integer(let value): return Double(value); default: return nil } }
    var data: Data? { if case .blob(let value) = self { return value }; return nil }
}

/// Its owner serializes every access, including progress handler installation.
final class AssistantChatDatabase {
    private var handle: OpaquePointer?
    private var cancellation: AssistantArchiveCancellation?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private(set) var bodyDecodes = 0
    private(set) var headerQueries = 0
    private(set) var authorizationIdentity: UUID?
    private var transactionDepth = 0

    init(url: URL, create: Bool) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (create ? SQLITE_OPEN_CREATE : 0)
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK else { sqlite3_close(handle); handle = nil; throw AssistantChatStorageError.sqlite(result) }
        do {
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            sqlite3_busy_timeout(handle, 3_000)
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { sqlite3_close(handle) }
    func close() throws {
        setCancellation(nil)
        let result = sqlite3_close(handle)
        guard result == SQLITE_OK else { throw AssistantChatStorageError.sqlite(result) }
        handle = nil
    }
    func setCancellation(_ token: AssistantArchiveCancellation?) {
        cancellation = token
        if let token {
            sqlite3_progress_handler(handle, 1_000, { pointer in
                guard let pointer else { return 0 }
                return Unmanaged<AssistantArchiveCancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled ? 1 : 0
            }, Unmanaged.passUnretained(token).toOpaque())
        } else { sqlite3_progress_handler(handle, 0, nil, nil) }
    }
    func checkpoint() throws { try cancellation?.check() }
    func execute(_ sql: String, _ values: [AssistantSQLValue] = []) throws { _ = try rows(sql, values) }
    func rows(_ sql: String, _ values: [AssistantSQLValue] = []) throws -> [[AssistantSQLValue]] {
        try checkpoint()
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else { throw AssistantChatStorageError.sqlite(prepared) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == Int32(values.count) else { throw AssistantChatStorageError.sqlite(SQLITE_MISUSE) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, position)
            case .integer(let value): result = sqlite3_bind_int64(statement, position, value)
            case .real(let value): result = sqlite3_bind_double(statement, position, value)
            case .text(let value):
                guard value.utf8.count <= Int(Int32.max) else { throw AssistantChatStorageError.sqlite(SQLITE_TOOBIG) }
                result = value.withCString { sqlite3_bind_text(statement, position, $0, Int32(value.utf8.count), transient) }
            case .blob(let value):
                guard value.count <= Int(Int32.max) else { throw AssistantChatStorageError.sqlite(SQLITE_TOOBIG) }
                result = value.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), transient) }
            }
            guard result == SQLITE_OK else { throw AssistantChatStorageError.sqlite(result) }
        }
        var result: [[AssistantSQLValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { if step == SQLITE_INTERRUPT { throw CancellationError() }; throw AssistantChatStorageError.sqlite(step) }
            var row: [AssistantSQLValue] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if let pointer = sqlite3_column_text(statement, column) {
                        guard let value = String(bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8) else { throw AssistantChatStorageError.corruptStore }
                        row.append(.text(value))
                    } else { row.append(.text("")) }
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    row.append(.blob(sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count) } ?? Data()))
                default: row.append(.null)
                }
            }
            result.append(row)
        }
    }
    func transaction<T>(beforeCommit: (() throws -> Void)? = nil, _ operation: () throws -> T) throws -> T {
        if transactionDepth > 0 { return try operation() }
        try execute("BEGIN IMMEDIATE")
        transactionDepth = 1
        defer { transactionDepth = 0 }
        let token = cancellation
        do {
            let value = try operation(); try checkpoint(); try beforeCommit?()
            // Cancellation linearizes before commit; it cannot misreport an already committed write.
            setCancellation(nil)
            try execute("COMMIT"); setCancellation(token)
            return value
        } catch {
            setCancellation(nil); try? execute("ROLLBACK"); setCancellation(token)
            throw error
        }
    }
    func createSchema(ownerId: String) throws {
        try execute("CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
        try execute("CREATE TABLE headers(id TEXT PRIMARY KEY,title TEXT NOT NULL,preview TEXT NOT NULL,date REAL NOT NULL,sort_at REAL NOT NULL,server_id TEXT,message_count INTEGER NOT NULL,revision INTEGER NOT NULL,search_text TEXT NOT NULL,turn_id TEXT NOT NULL)")
        try execute("CREATE INDEX header_order ON headers(sort_at DESC,id DESC)")
        try execute("CREATE TABLE bodies(id TEXT PRIMARY KEY REFERENCES headers(id) ON DELETE CASCADE,payload BLOB NOT NULL)")
        try execute("CREATE TABLE drafts(slot TEXT PRIMARY KEY,conversation_id TEXT UNIQUE,payload BLOB NOT NULL,revision INTEGER NOT NULL)")
        try execute("CREATE TABLE deleted(id TEXT PRIMARY KEY)")
        try execute("CREATE TABLE state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),active_slot TEXT REFERENCES drafts(slot) ON DELETE SET NULL,purging INTEGER NOT NULL DEFAULT 0,list_generation INTEGER NOT NULL DEFAULT 1,search_generation INTEGER NOT NULL DEFAULT 1,auth_generation INTEGER NOT NULL DEFAULT 1)")
        try execute("INSERT INTO state(singleton) VALUES(1)")
        try execute("INSERT INTO meta(key,value) VALUES('owner',?)", [.text(ownerId)])
        try execute("INSERT INTO meta(key,value) VALUES('schema','1')")
        let identity = UUID(); authorizationIdentity = identity
        try execute("INSERT INTO meta(key,value) VALUES('auth_identity',?)", [.text(identity.uuidString)])
    }
    func ensureAuthorizationMetadata() throws {
        let columns = try rows("PRAGMA table_info(state)").compactMap { $0[1].string }
        let identity = try rows("SELECT value FROM meta WHERE key='auth_identity'").first?.first?.string
        if columns.contains("auth_generation"), let identity, let value = UUID(uuidString: identity) { authorizationIdentity = value; return }
        try transaction {
            if try !rows("PRAGMA table_info(state)").contains(where: { $0[1].string == "auth_generation" }) { try execute("ALTER TABLE state ADD COLUMN auth_generation INTEGER NOT NULL DEFAULT 1") }
            try execute("INSERT OR IGNORE INTO meta(key,value) VALUES('auth_identity',?)", [.text(UUID().uuidString)])
        }
        guard let raw = try rows("SELECT value FROM meta WHERE key='auth_identity'").first?.first?.string,
              let value = UUID(uuidString: raw) else { throw AssistantChatStorageError.corruptStore }
        authorizationIdentity = value
    }
    func recordBodyDecode() { bodyDecodes += 1 }
    func recordHeaderQuery() { headerQueries += 1 }
}
