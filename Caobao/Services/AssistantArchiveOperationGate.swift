import Foundation

enum AssistantArchiveOperationGateError: Error { case busy, stale }

/// Thread-safe, short-lock commit boundary shared with the SQLite worker.
/// Invalidations before beginCommit reject the transaction. Once commit begins,
/// cancellation only invalidates UI publication; it never claims rollback.
final class AssistantArchiveCommitPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private var commitStarted = false
    private var committed = false

    func invalidate() { lock.lock(); invalidated = true; lock.unlock() }
    func validate() throws {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { throw AssistantArchiveOperationGateError.stale }
    }
    func beginCommit() throws {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { throw AssistantArchiveOperationGateError.stale }
        commitStarted = true
    }
    func didCommit() { lock.lock(); committed = true; lock.unlock() }
    var hasStartedCommit: Bool { lock.lock(); defer { lock.unlock() }; return commitStarted }
    var hasCommitted: Bool { lock.lock(); defer { lock.unlock() }; return committed }
    var isInvalidated: Bool { lock.lock(); defer { lock.unlock() }; return invalidated }
}

/// MainActor serialization for destructive/switch/export operations. Streams may
/// keep receiving bounded transport bytes, but applying their events waits until
/// the exclusive snapshot has either committed or failed.
@MainActor
final class AssistantArchiveOperationGate {
    struct Ticket: Sendable {
        let id: UUID
        let ownerId: String
        let scopeId: UUID
        let permit: AssistantArchiveCommitPermit
    }
    private(set) var active: Ticket?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var publicationWaiters: [CheckedContinuation<Void, Never>] = []
    var isBusy: Bool { active != nil }

    func begin(ownerId: String, scopeId: UUID) throws -> Ticket {
        guard active == nil else { throw AssistantArchiveOperationGateError.busy }
        let ticket = Ticket(id: UUID(), ownerId: ownerId, scopeId: scopeId, permit: AssistantArchiveCommitPermit())
        active = ticket
        return ticket
    }
    func isCurrent(_ ticket: Ticket) -> Bool { active?.id == ticket.id }
    func rearm(_ ticket: Ticket) throws -> Ticket {
        guard active?.id == ticket.id else { throw AssistantArchiveOperationGateError.stale }
        let next = Ticket(id: ticket.id, ownerId: ticket.ownerId, scopeId: ticket.scopeId, permit: AssistantArchiveCommitPermit())
        active = next
        return next
    }
    func invalidate() { active?.permit.invalidate() }
    func finish(_ ticket: Ticket) {
        guard active?.id == ticket.id else { return }
        active = nil
        let ready = Array(waiters.values); waiters.removeAll()
        for continuation in ready { continuation.resume() }
        let publications = publicationWaiters; publicationWaiters.removeAll()
        for continuation in publications { continuation.resume() }
    }
    /// Even a cancelled producer must wait before publishing its terminal state.
    func waitForPublication() async {
        guard active != nil else { return }
        await withCheckedContinuation { publicationWaiters.append($0) }
    }
    func waitUntilIdle() async throws {
        try Task.checkCancellation()
        guard active != nil else { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if active == nil { continuation.resume() }
                else { waiters[id] = continuation }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelWaiter(id) }
        })
        try Task.checkCancellation()
    }
    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
