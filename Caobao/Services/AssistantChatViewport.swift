import Foundation

/// Ephemeral UI position only. Raw account/conversation bytes are never normalized.
struct AssistantChatViewportContext: Hashable, Sendable {
    let ownerId: String
    let conversationId: String
    let key: String

    init?(ownerId: String, conversationId: String) {
        guard Self.validIdentifier(ownerId), Self.validIdentifier(conversationId) else { return nil }
        self.ownerId = ownerId; self.conversationId = conversationId
        key = Data(ownerId.utf8).base64EncodedString() + "." + Data(conversationId.utf8).base64EncodedString()
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
    static func validIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 1_024
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

struct AssistantChatViewportMessage: Equatable, Sendable {
    let id: String
    let isUser: Bool
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id.utf8.elementsEqual(rhs.id.utf8) && lhs.isUser == rhs.isUser
    }
}

struct AssistantChatViewportSession: Equatable, Sendable {
    let id: UUID
    let context: AssistantChatViewportContext
}

struct AssistantChatViewportFrame: Equatable, Sendable {
    let messageId: String
    let minY: Double
    let maxY: Double
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.messageId.utf8.elementsEqual(rhs.messageId.utf8) && lhs.minY == rhs.minY && lhs.maxY == rhs.maxY
    }
}

struct AssistantChatViewportGeometry: Equatable, Sendable {
    let viewportHeight: Double
    let contentMinY: Double
    let bottomY: Double
    let frames: [AssistantChatViewportFrame]
}

enum AssistantChatViewportTarget: Equatable, Sendable {
    case latest(String)
    case anchor(String)
    var messageId: String { switch self { case .latest(let id), .anchor(let id): return id } }
    var isLatest: Bool { if case .latest = self { return true }; return false }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isLatest == rhs.isLatest && lhs.messageId.utf8.elementsEqual(rhs.messageId.utf8)
    }
}

struct AssistantChatViewportState: Equatable, Sendable {
    let followingLatest: Bool
    let anchorMessageId: String?
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.followingLatest == rhs.followingLatest else { return false }
        switch (lhs.anchorMessageId, rhs.anchorMessageId) {
        case (nil, nil): return true
        case let (a?, b?): return a.utf8.elementsEqual(b.utf8)
        default: return false
        }
    }
}

struct AssistantChatViewportUpdate: Sendable {
    let state: AssistantChatViewportState
    let target: AssistantChatViewportTarget?
    let resumedByUserMessage: Bool
}

struct AssistantChatViewportStart: Sendable {
    let session: AssistantChatViewportSession
    let update: AssistantChatViewportUpdate
}

/// No message bodies, persistence, timers, network, keyboard or UI framework.
/// At most 32 default contexts and five bounded message IDs per entry are kept.
/// New mounts replace the active ticket for that context; late old frames cannot
/// change the restored position. The caller also validates its live owner/scope.
final class AssistantChatViewportStore: @unchecked Sendable {
    static let shared = AssistantChatViewportStore()
    static let maximumMessages = 20_000
    static let bottomTolerance = 48.0
    private struct Entry {
        var activeSession: UUID?
        var following = true
        var anchor: String?
        var before: String?
        var after: String?
        var ordinal = 0
        var lastUser: String?
        var lastMessage: String?
        var userCount = 0
        var awaitingMessages = false
        var tick: UInt64 = 0
    }
    private let lock = NSLock()
    private let capacity: Int
    private var clock: UInt64 = 0
    private var entries: [String: Entry] = [:]

    init(capacity: Int = 32) { self.capacity = min(max(capacity, 1), 128) }
    var contextCount: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    func begin(context: AssistantChatViewportContext, messages: [AssistantChatViewportMessage]) -> AssistantChatViewportStart? {
        guard Self.validMessages(messages) else { return nil }
        lock.lock(); defer { lock.unlock() }
        var entry = entries[context.key] ?? Entry()
        let session = AssistantChatViewportSession(id: UUID(), context: context)
        entry.activeSession = session.id
        baseline(&entry, messages)
        entry.awaitingMessages = messages.isEmpty
        if !messages.isEmpty { resolveAnchor(&entry, messages) }
        save(entry, key: context.key)
        return AssistantChatViewportStart(session: session, update: update(entry, target: target(entry, messages)))
    }

    func state(for session: AssistantChatViewportSession) -> AssistantChatViewportState? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = current(session) else { return nil }
        return state(entry)
    }

    /// Only actual intersecting message frames may establish a reading anchor.
    /// A changing content height alone never turns paused reading into following.
    func observe(session: AssistantChatViewportSession, messages: [AssistantChatViewportMessage],
                 geometry: AssistantChatViewportGeometry, userIsScrolling: Bool) -> AssistantChatViewportState? {
        guard Self.validMessages(messages), Self.validGeometry(geometry, messages: messages) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard var entry = current(session) else { return nil }
        if userIsScrolling { entry.following = Self.isNearBottom(geometry) }
        if let frame = geometry.frames.filter({ $0.maxY > 0 && $0.minY < geometry.viewportHeight })
            .min(by: { $0.minY < $1.minY }), let index = Self.index(frame.messageId, messages) {
            anchor(&entry, index: index, messages: messages)
        }
        save(entry, key: session.context.key)
        return state(entry)
    }

    /// Initial/replaced history is not a new user submission. A new user turn
    /// strictly after the known tail also covers requests failing before a UI
    /// frame observes isGenerating=true. Assistant-only deltas never resume.
    func messagesChanged(session: AssistantChatViewportSession, messages: [AssistantChatViewportMessage],
                         isGenerating: Bool, visibleMessageIds: [String] = []) -> AssistantChatViewportUpdate? {
        guard Self.validMessages(messages), visibleMessageIds.count <= Self.maximumMessages else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard var entry = current(session) else { return nil }
        let userCount = messages.filter(\.isUser).count
        let lastUser = messages.last(where: \.isUser)?.id
        let appendedAfterTail = entry.lastMessage.flatMap { Self.index($0, messages) }.map { tail in
            messages.lastIndex(where: \.isUser).map { $0 > tail } ?? false
        } ?? false
        let submitted = userCount > entry.userCount && !Self.same(lastUser, entry.lastUser)
            && (isGenerating || (!entry.awaitingMessages && appendedAfterTail))
        let wasAwaiting = entry.awaitingMessages
        let deletedAnchor = entry.anchor.map { Self.index($0, messages) == nil } ?? false
        baseline(&entry, messages)
        if !messages.isEmpty { entry.awaitingMessages = false }
        if submitted { entry.following = true }
        var destination: AssistantChatViewportTarget?
        if entry.following { destination = messages.last.map { .latest($0.id) } }
        else if deletedAnchor {
            if let index = visibleMessageIds.lazy.compactMap({ Self.index($0, messages) }).first {
                // Keep the native visible position when there is a valid survivor.
                anchor(&entry, index: index, messages: messages)
            } else {
                resolveAnchor(&entry, messages)
                destination = entry.anchor.map { .anchor($0) }
            }
        } else if wasAwaiting && !messages.isEmpty {
            resolveAnchor(&entry, messages)
            destination = target(entry, messages)
        }
        save(entry, key: session.context.key)
        return update(entry, target: destination, submitted: submitted)
    }

    func restore(session: AssistantChatViewportSession, messages: [AssistantChatViewportMessage]) -> AssistantChatViewportUpdate? {
        guard Self.validMessages(messages) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard var entry = current(session) else { return nil }
        if !messages.isEmpty { resolveAnchor(&entry, messages) }
        save(entry, key: session.context.key)
        return update(entry, target: target(entry, messages))
    }

    func resumeLatest(session: AssistantChatViewportSession, messages: [AssistantChatViewportMessage]) -> AssistantChatViewportUpdate? {
        guard Self.validMessages(messages) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard var entry = current(session) else { return nil }
        entry.following = true
        baseline(&entry, messages)
        save(entry, key: session.context.key)
        return update(entry, target: messages.last.map { .latest($0.id) })
    }

    func finish(session: AssistantChatViewportSession) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = current(session) else { return }
        entry.activeSession = nil
        save(entry, key: session.context.key)
    }

    /// A queued scroll must still match the current validated target when it runs.
    func canApply(session: AssistantChatViewportSession, target: AssistantChatViewportTarget) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = current(session) else { return false }
        switch target {
        case .latest(let id): return entry.following && Self.same(id, entry.lastMessage)
        case .anchor(let id): return !entry.following && Self.same(id, entry.anchor)
        }
    }

    static func isNearBottom(_ geometry: AssistantChatViewportGeometry) -> Bool {
        geometry.viewportHeight.isFinite && geometry.viewportHeight > 0 && geometry.bottomY.isFinite
            && max(0, geometry.bottomY - geometry.viewportHeight) <= bottomTolerance
    }
    static func hasReached(_ target: AssistantChatViewportTarget, geometry: AssistantChatViewportGeometry, firstMessageId: String?) -> Bool {
        guard geometry.viewportHeight.isFinite, geometry.viewportHeight > 0, geometry.contentMinY.isFinite, geometry.bottomY.isFinite,
              let frame = geometry.frames.first(where: { $0.messageId.utf8.elementsEqual(target.messageId.utf8) }),
              frame.minY.isFinite, frame.maxY.isFinite, frame.maxY >= frame.minY,
              frame.maxY > 0, frame.minY < geometry.viewportHeight else { return false }
        if target.isLatest { return isNearBottom(geometry) }
        let clampedAtStart = firstMessageId.map { $0.utf8.elementsEqual(target.messageId.utf8) } == true
            && geometry.contentMinY >= -1 && frame.minY >= 0 && frame.minY <= bottomTolerance
        return abs(frame.minY) <= 4 || isNearBottom(geometry) || clampedAtStart
    }
    private func current(_ session: AssistantChatViewportSession) -> Entry? {
        guard let entry = entries[session.context.key], entry.activeSession == session.id else { return nil }; return entry
    }
    private func save(_ entry: Entry, key: String) {
        clock &+= 1
        var value = entry; value.tick = clock; entries[key] = value
        while entries.count > capacity, let oldest = entries.min(by: { $0.value.tick < $1.value.tick })?.key { entries.removeValue(forKey: oldest) }
    }
    private func baseline(_ entry: inout Entry, _ messages: [AssistantChatViewportMessage]) {
        entry.userCount = messages.filter(\.isUser).count
        entry.lastUser = messages.last(where: \.isUser)?.id
        entry.lastMessage = messages.last?.id
    }
    private func anchor(_ entry: inout Entry, index: Int, messages: [AssistantChatViewportMessage]) {
        entry.anchor = messages[index].id; entry.ordinal = index
        entry.before = index > 0 ? messages[index - 1].id : nil
        entry.after = index + 1 < messages.count ? messages[index + 1].id : nil
    }
    private func resolveAnchor(_ entry: inout Entry, _ messages: [AssistantChatViewportMessage]) {
        guard !messages.isEmpty else { entry.anchor = nil; entry.before = nil; entry.after = nil; entry.ordinal = 0; return }
        let index = entry.anchor.flatMap { Self.index($0, messages) }
            ?? entry.after.flatMap { Self.index($0, messages) }
            ?? entry.before.flatMap { Self.index($0, messages) }
            ?? min(max(entry.ordinal, 0), messages.count - 1)
        anchor(&entry, index: index, messages: messages)
    }
    private func target(_ entry: Entry, _ messages: [AssistantChatViewportMessage]) -> AssistantChatViewportTarget? {
        guard !messages.isEmpty else { return nil }
        return entry.following ? messages.last.map { .latest($0.id) } : entry.anchor.map { .anchor($0) }
    }
    private func state(_ entry: Entry) -> AssistantChatViewportState { AssistantChatViewportState(followingLatest: entry.following, anchorMessageId: entry.anchor) }
    private func update(_ entry: Entry, target: AssistantChatViewportTarget?, submitted: Bool = false) -> AssistantChatViewportUpdate { AssistantChatViewportUpdate(state: state(entry), target: target, resumedByUserMessage: submitted) }
    private static func index(_ id: String, _ messages: [AssistantChatViewportMessage]) -> Int? { messages.firstIndex { $0.id.utf8.elementsEqual(id.utf8) } }
    private static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) { case (nil, nil): return true; case let (a?, b?): return a.utf8.elementsEqual(b.utf8); default: return false }
    }
    private static func validMessages(_ messages: [AssistantChatViewportMessage]) -> Bool {
        guard messages.count <= maximumMessages else { return false }
        var ids = Set<Data>()
        return messages.allSatisfy { AssistantChatViewportContext.validIdentifier($0.id) && ids.insert(Data($0.id.utf8)).inserted }
    }
    private static func validGeometry(_ geometry: AssistantChatViewportGeometry, messages: [AssistantChatViewportMessage]) -> Bool {
        guard geometry.viewportHeight.isFinite, geometry.viewportHeight > 0, geometry.contentMinY.isFinite,
              geometry.bottomY.isFinite, geometry.frames.count <= messages.count else { return false }
        let ids = Set(messages.map { Data($0.id.utf8) }); var observed = Set<Data>()
        return geometry.frames.allSatisfy {
            let id = Data($0.messageId.utf8)
            return ids.contains(id) && observed.insert(id).inserted && $0.minY.isFinite && $0.maxY.isFinite
                && $0.maxY >= $0.minY && abs($0.minY) <= 1_000_000_000 && abs($0.maxY) <= 1_000_000_000
        }
    }
}
