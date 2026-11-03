import Foundation

enum AssistantDeletionServerStatus: String, Codable, Sendable {
    case queued, accepted, pending, processing, running, needsRetry = "needs_retry", completed
}

enum AssistantDeletionCleanupComponent: String, Codable, CaseIterable, Sendable {
    case reminders, memoriesAndTasks, conversationsAndDraft, apiKey, preferences
}

/// Metadata only: never persist tokens, keys, messages, or arbitrary error text.
struct AssistantDeletionCleanupJob: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let ownerId: String
    let origin: String
    let serverRequestId: String
    var serverStatus: AssistantDeletionServerStatus
    let acceptedAt: Date
    var pendingComponents: [AssistantDeletionCleanupComponent]
    var noticeDismissed: Bool
}

struct AssistantDeletionNotice: Equatable, Identifiable, Sendable {
    let id: String
    let serverStatus: AssistantDeletionServerStatus?
    let pendingJobCount: Int
    let pendingComponents: [AssistantDeletionCleanupComponent]
    let storageIssue: Bool
    var hasPendingLocalCleanup: Bool { pendingJobCount > 0 || storageIssue }
    var canRetry: Bool { pendingJobCount > 0 && !storageIssue }

    static let unreadableStorage = AssistantDeletionNotice(id: "deletion-metadata-error", serverStatus: nil,
        pendingJobCount: 0, pendingComponents: [], storageIssue: true)
}

enum AssistantDeletionMetadataError: Error { case invalidMetadata, tooLarge, persistenceFailed }

/// Main-actor ownership makes read-modify-write operations serial. A malformed
/// value is left intact: it is never treated as an empty queue or overwritten.
@MainActor
final class AssistantDeletionNoticeStore {
    private struct Envelope: Codable { let version: Int; var jobs: [AssistantDeletionCleanupJob] }
    private let defaults: UserDefaults
    private let key: String
    private let maximumBytes = 1_048_576

    init(defaults: UserDefaults = .standard, key: String = "caobao.accepted-deletion-jobs.v1") {
        self.defaults = defaults; self.key = key
    }

    func jobs() throws -> [AssistantDeletionCleanupJob] {
        guard let value = defaults.object(forKey: key) else { return [] }
        guard let data = value as? Data, data.count <= maximumBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1 else {
            throw AssistantDeletionMetadataError.invalidMetadata
        }
        try validate(envelope.jobs)
        return envelope.jobs
    }

    @discardableResult
    func recordAccepted(ownerId: String, origin: String, serverRequestId: String,
                        status: AssistantDeletionServerStatus, now: Date = Date()) throws -> AssistantDeletionCleanupJob {
        var values = try jobs()
        if let index = values.firstIndex(where: { $0.ownerId == ownerId && $0.origin == origin && $0.serverRequestId == serverRequestId }) {
            if values[index].serverStatus != .completed { values[index].serverStatus = status }
            values[index].noticeDismissed = false
            try write(values)
            return values[index]
        }
        let job = AssistantDeletionCleanupJob(id: UUID(), ownerId: ownerId, origin: origin,
            serverRequestId: serverRequestId, serverStatus: status, acceptedAt: now,
            pendingComponents: AssistantDeletionCleanupComponent.allCases, noticeDismissed: false)
        values.append(job)
        try write(values)
        return job
    }

    func updatePending(jobId: UUID, components: [AssistantDeletionCleanupComponent]) throws {
        var values = try jobs()
        guard let index = values.firstIndex(where: { $0.id == jobId }) else { throw AssistantDeletionMetadataError.invalidMetadata }
        values[index].pendingComponents = components
        values[index].noticeDismissed = false
        try write(values)
    }

    func updateServerStatus(jobId: UUID, status: AssistantDeletionServerStatus) throws {
        var values = try jobs()
        guard let index = values.firstIndex(where: { $0.id == jobId }) else { throw AssistantDeletionMetadataError.invalidMetadata }
        // A terminal server result is monotonic. A late retry response must not
        // make a completed deletion appear active again.
        if values[index].serverStatus != .completed { values[index].serverStatus = status }
        try write(values)
    }

    func dismiss(origin: String) throws {
        var values = try jobs()
        for index in values.indices where values[index].origin == origin && values[index].pendingComponents.isEmpty { values[index].noticeDismissed = true }
        try write(values) // Dismissal never removes pending work.
    }

    func notice(currentOwnerId: String?, origin: String) throws -> AssistantDeletionNotice? {
        guard currentOwnerId == nil else { return nil }
        let values = try jobs().filter { $0.origin == origin }
        guard let latest = values.last(where: { !$0.noticeDismissed }) else { return nil }
        let pending = values.filter { !$0.pendingComponents.isEmpty }
        let components = AssistantDeletionCleanupComponent.allCases.filter { component in
            pending.contains { $0.pendingComponents.contains(component) }
        }
        let visibleServerStatus = values.last(where: { $0.serverStatus != .completed })?.serverStatus ?? .completed
        return AssistantDeletionNotice(id: latest.id.uuidString, serverStatus: visibleServerStatus,
            pendingJobCount: pending.count, pendingComponents: components, storageIssue: false)
    }

    private func validate(_ values: [AssistantDeletionCleanupJob]) throws {
        guard values.count <= 500, Set(values.map(\.id)).count == values.count else { throw AssistantDeletionMetadataError.invalidMetadata }
        for job in values {
            guard !job.ownerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, job.ownerId.utf8.count <= 1_024,
                  !job.serverRequestId.isEmpty, job.serverRequestId.utf8.count <= 256,
                  job.acceptedAt.timeIntervalSince1970.isFinite,
                  let url = URLComponents(string: job.origin), url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  Set(job.pendingComponents).count == job.pendingComponents.count else {
                throw AssistantDeletionMetadataError.invalidMetadata
            }
        }
    }

    private func write(_ values: [AssistantDeletionCleanupJob]) throws {
        try validate(values)
        let data = try JSONEncoder().encode(Envelope(version: 1, jobs: values))
        guard data.count <= maximumBytes else { throw AssistantDeletionMetadataError.tooLarge }
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else { throw AssistantDeletionMetadataError.persistenceFailed }
    }
}

/// Only accepted, persisted jobs can authorize cleanup. The caller supplies
/// current identity checks before and after each component's potentially async work.
@MainActor
final class AssistantDeletionCleanupCoordinator {
    typealias Cleaner = (AssistantDeletionCleanupComponent, String) async throws -> Void
    private let store: AssistantDeletionNoticeStore
    init(store: AssistantDeletionNoticeStore) { self.store = store }

    func perform(jobId: UUID, origin: String, mayClean: () -> Bool, cleaner: Cleaner) async throws {
        guard mayClean(), let job = try store.jobs().first(where: { $0.id == jobId && $0.origin == origin }) else { return }
        var pending = job.pendingComponents
        for component in job.pendingComponents {
            try Task.checkCancellation()
            guard mayClean() else { return }
            do { try await cleaner(component, job.ownerId) }
            catch is CancellationError { throw CancellationError() }
            catch { continue } // A failed component stays pending; no raw error data is persisted.
            try Task.checkCancellation()
            guard mayClean() else { return }
            pending.removeAll { $0 == component }
            try store.updatePending(jobId: job.id, components: pending)
        }
    }

    func retry(origin: String, currentOwnerId: () -> String?, cleaner: Cleaner) async throws {
        guard currentOwnerId() == nil else { return }
        let pending = try store.jobs().filter { $0.origin == origin && !$0.pendingComponents.isEmpty }
        for job in pending {
            try Task.checkCancellation()
            guard currentOwnerId() == nil else { return }
            try await perform(jobId: job.id, origin: origin, mayClean: { currentOwnerId() == nil }, cleaner: cleaner)
        }
    }
}
