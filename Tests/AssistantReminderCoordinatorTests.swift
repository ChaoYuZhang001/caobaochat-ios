import Foundation
import UserNotifications

private enum CoordinatorTestFailure: Error, CustomStringConvertible {
    case assertion(String), injected
    var description: String {
        switch self { case .assertion(let text): return text; case .injected: return "Injected test failure" }
    }
}

/// Only used to hold a fake OS add in-flight while account state changes.
private final class AddGate {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private final class FakeNotificationBackend: AssistantReminderNotificationBackend {
    enum AddEffect { case succeed, fail, hold(AddGate), holdThenFail(AddGate), holdAfterStore(AddGate) }
    private struct State {
        var settings: AssistantReminderNotificationSettings
        var requestGranted = true
        var authorizationRequests = 0
        var lastAuthorizationOptions: UNAuthorizationOptions = []
        var addAttempts = 0
        var appliedAddAttempts = 0
        var settingsRequests = 0
        var settingsGates: [AddGate] = []
        var authorizationGates: [AddGate] = []
        var pendingReadHolds = 0
        var pendingReadGates: [(minimumAddAttempts: Int?, gate: AddGate)] = []
        var appliedObserver: ((UNNotificationRequest) -> Void)?
        var pending: [String: UNNotificationRequest] = [:]
        var delivered: Set<String> = []
        var effects: [AddEffect] = []
    }
    private let lock = NSLock()
    private var state: State

    init(status: AssistantReminderAuthorizationStatus = .authorized, alertsEnabled: Bool = true) {
        state = State(settings: AssistantReminderNotificationSettings(authorizationStatus: status, alertsEnabled: alertsEnabled))
    }

    private func access<T>(_ operation: (inout State) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return operation(&state)
    }

    var pendingSnapshot: [UNNotificationRequest] { access { Array($0.pending.values) } }
    var deliveredSnapshot: Set<String> { access { $0.delivered } }
    var authorizationRequests: Int { access { $0.authorizationRequests } }
    var lastAuthorizationOptions: UNAuthorizationOptions { access { $0.lastAuthorizationOptions } }
    var addAttempts: Int { access { $0.addAttempts } }
    var appliedAddAttempts: Int { access { $0.appliedAddAttempts } }
    var settingsRequests: Int { access { $0.settingsRequests } }
    var pendingReadHolds: Int { access { $0.pendingReadHolds } }

    func allowAuthorizationRequest(_ allowed: Bool) { access { $0.requestGranted = allowed } }
    func enqueue(_ effect: AddEffect) { access { $0.effects.append(effect) } }
    func holdNextSettingsRead(_ gate: AddGate) { access { $0.settingsGates.append(gate) } }
    func holdNextAuthorization(_ gate: AddGate) { access { $0.authorizationGates.append(gate) } }
    func holdNextPendingRead(_ gate: AddGate, afterAddAttempts: Int? = nil) { access { $0.pendingReadGates.append((afterAddAttempts, gate)) } }
    func observeAppliedAdds(_ observer: ((UNNotificationRequest) -> Void)?) { access { $0.appliedObserver = observer } }
    func seed(_ request: UNNotificationRequest, delivered: Bool = false) {
        access { state in
            state.pending[request.identifier] = request
            if delivered { state.delivered.insert(request.identifier) }
        }
    }

    func notificationSettings() async -> AssistantReminderNotificationSettings {
        let gate: AddGate? = access {
            $0.settingsRequests += 1
            return $0.settingsGates.isEmpty ? nil : $0.settingsGates.removeFirst()
        }
        if let gate { await gate.wait() }
        return access { $0.settings }
    }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        let gate: AddGate? = access {
            $0.authorizationRequests += 1
            $0.lastAuthorizationOptions = options
            return $0.authorizationGates.isEmpty ? nil : $0.authorizationGates.removeFirst()
        }
        if let gate { await gate.wait() }
        return access {
            let granted = $0.requestGranted
            $0.settings = AssistantReminderNotificationSettings(authorizationStatus: granted ? .authorized : .denied, alertsEnabled: granted)
            return granted
        }
    }
    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        let gate: AddGate? = access { state in
            guard let first = state.pendingReadGates.first,
                  first.minimumAddAttempts.map({ state.addAttempts >= $0 }) ?? true else { return nil }
            state.pendingReadGates.removeFirst(); state.pendingReadHolds += 1; return first.gate
        }
        if let gate { await gate.wait() }
        return pendingSnapshot
    }
    func deliveredNotificationIdentifiers() async -> [String] { Array(deliveredSnapshot) }
    func add(_ request: UNNotificationRequest) async throws {
        let effect: AddEffect = access {
            $0.addAttempts += 1
            return $0.effects.isEmpty ? .succeed : $0.effects.removeFirst()
        }
        switch effect {
        case .succeed: break
        case .fail: throw CoordinatorTestFailure.injected
        case .hold(let gate): await gate.wait()
        case .holdThenFail(let gate): await gate.wait(); throw CoordinatorTestFailure.injected
        case .holdAfterStore(let gate):
            storeApplied(request)
            await gate.wait()
            return
        }
        storeApplied(request)
    }
    private func storeApplied(_ request: UNNotificationRequest) {
        let observer = access { state -> ((UNNotificationRequest) -> Void)? in
            state.pending[request.identifier] = request; state.appliedAddAttempts += 1
            return state.appliedObserver
        }
        observer?(request)
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        access { state in identifiers.forEach { state.pending.removeValue(forKey: $0) } }
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        access { state in identifiers.forEach { state.delivered.remove($0) } }
    }

    func waitForAddAttempts(_ expected: Int) async throws {
        // A bounded wait for an observable fake operation, never a permission UI.
        for _ in 0..<200 {
            if addAttempts >= expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CoordinatorTestFailure.assertion("Fake notification add did not start")
    }

    func waitForSettingsRequests(_ expected: Int) async throws {
        for _ in 0..<200 {
            if settingsRequests >= expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CoordinatorTestFailure.assertion("Fake notification settings read did not start")
    }

    func waitForAuthorizationRequests(_ expected: Int) async throws {
        for _ in 0..<200 {
            if authorizationRequests >= expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CoordinatorTestFailure.assertion("Fake permission request did not start")
    }

    func waitForAppliedAddAttempts(_ expected: Int) async throws {
        for _ in 0..<200 {
            if appliedAddAttempts >= expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CoordinatorTestFailure.assertion("Fake notification add did not store its request")
    }
    func waitForPendingReadHolds(_ expected: Int) async throws {
        for _ in 0..<200 {
            if pendingReadHolds >= expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CoordinatorTestFailure.assertion("Fake notification pending read did not reach its held callback")
    }
}

private final class RejectingWriteFileManager: FileManager, @unchecked Sendable {
    var rejectsDirectoryCreation = false
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if rejectsDirectoryCreation { throw CoordinatorTestFailure.injected }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

private enum SourceValidationFailure: Error { case invalidated }

@MainActor private final class SourceValidationFixture {
    private(set) var calls = 0
    private var valid = true
    private var successesLeft: Int?
    init(successesAllowed: Int? = nil) { self.successesLeft = successesAllowed }
    func invalidate() { valid = false }
    func validate() throws {
        calls += 1
        guard valid, successesLeft != 0 else { throw SourceValidationFailure.invalidated }
        if let remaining = successesLeft { successesLeft = remaining - 1 }
    }
}

@main
private struct AssistantReminderCoordinatorTests {
    private static var suiteCount = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw CoordinatorTestFailure.assertion(message) }
    }
    static func task(_ id: String = "task", owner: String = "A", reminder: Bool? = true,
                     title: String = "Private task title") -> AssistantTask {
        let now = Date()
        return AssistantTask(id: id, userId: owner, title: title, instructions: "Private task notes",
                             dueAt: now.addingTimeInterval(7_200), timeZone: "Asia/Shanghai",
                             recurrenceRule: nil, requiresApproval: false, status: .active,
                             createdAt: now, updatedAt: now, reminderEnabled: reminder)
    }
    static func externalRequest() -> UNNotificationRequest {
        UNNotificationRequest(identifier: "unrelated.calendar.event", content: UNMutableNotificationContent(),
                              trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false))
    }
    static func quiet(around due: Date, endOffset: Int = 120) -> AssistantQuietHours {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let values = calendar.dateComponents([.hour, .minute], from: due)
        let minute = values.hour! * 60 + values.minute!
        return AssistantQuietHours(enabled: true, startMinute: (minute + 1_439) % 1_440,
                                   endMinute: (minute + endOffset) % 1_440, timeZoneIdentifier: "UTC")
    }
    static func expectDelivery(_ backend: FakeNotificationBackend, task: AssistantTask, policy: AssistantQuietHours) throws {
        let id = AssistantReminderPolicy.identifier(ownerId: task.userId, taskId: task.id)
        guard let request = backend.pendingSnapshot.first(where: { $0.identifier == id }),
              let actual = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() else {
            throw CoordinatorTestFailure.assertion("Expected scheduled notification for \(task.userId)/\(task.id)")
        }
        let expected = try policy.deliveryDate(for: task.dueAt!)
        try expect(abs(actual.timeIntervalSince(expected)) < 1.1, "Notification must use the latest committed policy")
    }
    static func run(_ name: String, root: URL,
                    _ operation: (URL) async throws -> Void) async throws {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await operation(directory.appendingPathComponent("store.json"))
        suiteCount += 1
        print("PASS \(name)")
    }
    static func expectReminderError(_ expected: AssistantReminderError,
                                    _ operation: () async throws -> Void) async throws {
        do { try await operation(); throw CoordinatorTestFailure.assertion("Expected \(expected)") }
        catch let error as AssistantReminderError { try expect(error == expected, "Unexpected reminder error: \(error)") }
    }

    static func ownedPending(_ backend: FakeNotificationBackend, owner: String = "A") -> [UNNotificationRequest] {
        backend.pendingSnapshot.filter { AssistantReminderPolicy.owns($0.identifier, ownerId: owner) }
    }

    static func seedForeignReminder(_ backend: FakeNotificationBackend, repository: AssistantLocalRepository) throws -> AssistantTask {
        let foreign = task(owner: "B")
        repository.addTask(foreign)
        guard let plan = try AssistantReminderPolicy.plan(for: foreign, ownerId: "B") else {
            throw CoordinatorTestFailure.assertion("Foreign fixture plan must exist")
        }
        let content = UNMutableNotificationContent()
        content.userInfo = ["ownerId": "B", "taskId": foreign.id, "timeZone": foreign.timeZone]
        backend.seed(UNNotificationRequest(identifier: plan.identifier, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: plan.dateComponents, repeats: false)))
        return foreign
    }

    static func expectForeignUnchanged(_ backend: FakeNotificationBackend, repository: AssistantLocalRepository, task: AssistantTask) throws {
        try expect(repository.tasks(for: "B").first == task && ownedPending(backend, owner: "B").count == 1, "Repair must not change another owner's record or request")
        try expectDelivery(backend, task: task, policy: .disabled)
        try expect(backend.authorizationRequests == 0, "Recovery never requests notification permission")
    }

    static func waitUntilExpired(_ due: Date) async throws {
        let seconds = max(0, due.timeIntervalSinceNow + 0.05)
        guard seconds < 6 else { throw CoordinatorTestFailure.assertion("Expiry fixture exceeds its bounded wait") }
        if seconds > 0 { try await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded(.up))) }
    }

    static func expectReactivation(_ snapshot: AssistantTask, _ operation: () async throws -> Void) async throws {
        do { try await operation(); throw CoordinatorTestFailure.assertion("Expected an explicit reactivation choice") }
        catch AssistantReminderError.reactivationRequired(let value) {
            try expect(value == snapshot, "The UI must receive the actual unchanged inactive snapshot")
        }
    }

    static func rawOwnerRequest(_ task: AssistantTask) throws -> UNNotificationRequest {
        guard let plan = try AssistantReminderPolicy.plan(for: task, ownerId: task.userId) else { throw CoordinatorTestFailure.assertion("Owner fixture requires a future reminder") }
        let content = UNMutableNotificationContent(); content.userInfo = ["ownerId": task.userId, "taskId": task.id, "timeZone": task.timeZone]
        return UNNotificationRequest(identifier: plan.identifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: plan.dateComponents, repeats: false))
    }
    static func expectIndependentB(_ backend: FakeNotificationBackend, repository: AssistantLocalRepository, original: AssistantTask) throws {
        try expect(repository.tasks(for: "B").first == original && ownedPending(backend, owner: "B").count == 1, "Canonical alias transitions cannot alter independent B data or notification keys")
        try expectDelivery(backend, task: original, policy: .disabled)
    }
    static func rawOwnerTests(root: URL) async throws {
        let first = "\u{00E9}", alias = "e\u{0301}"
        try await run("raw-owner-policy-rejects-canonical-alias-task", root: root) { _ in
            try expect(first == alias && !AssistantOwnerIdentity.matches(first, alias), "Fixture must exercise canonical equality with different identity bytes")
            try expect(AssistantOwnerIdentity.ownerKey(first) != AssistantOwnerIdentity.ownerKey(alias), "Owner state keys cannot normalize canonical aliases")
            try await expectReminderError(.foreignOwner) { _ = try AssistantReminderPolicy.plan(for: task(owner: first), ownerId: alias) }
        }
        try await run("raw-owner-save-reopen-and-expected-record-guards", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url), original = task(owner: first, reminder: false)
            repository.addTask(original)
            let backend = FakeNotificationBackend(), coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: first); let bytes = try Data(contentsOf: url)
            try await expectReminderError(.foreignOwner) { try await coordinator.saveTask(task("new", owner: alias, reminder: false), isNew: true, ownerId: first, requestAuthorization: false) }
            var foreign = task(owner: alias, reminder: false); foreign.status = .paused
            try await expectReminderError(.foreignOwner) { try await coordinator.reopenTaskWithoutReminder(foreign, ownerId: first) }
            do {
                try await coordinator.saveTask(original, isNew: false, ownerId: first, requestAuthorization: false, expectedTask: foreign)
                throw CoordinatorTestFailure.assertion("A canonical-alias expected owner cannot pass record identity validation")
            } catch AssistantRepositoryError.invalidRecord {}
            try expect(repository.tasks(for: first) == [original] && repository.tasks(for: alias).isEmpty && (try Data(contentsOf: url)) == bytes, "Foreign alias records cannot be normalized into a committed task")
            try expect(backend.addAttempts == 0 && backend.authorizationRequests == 0, "Foreign record checks precede every notification side effect")
        }
        try await run("raw-owner-aba-switch-invalidates-held-authorization-version", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url), backend = FakeNotificationBackend(status: .notDetermined)
            let independent = try seedForeignReminder(backend, repository: repository)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: first)
            let gate = AddGate(); backend.holdNextAuthorization(gate); defer { gate.open() }
            let value = task("new-auth", owner: first)
            let save = Task { try await coordinator.saveTask(value, isNew: true, ownerId: first, requestAuthorization: true) }
            try await backend.waitForAuthorizationRequests(1)
            _ = await coordinator.activate(ownerId: alias); _ = await coordinator.activate(ownerId: first)
            gate.open(); try await expectReminderError(.inactiveSession) { try await save.value }
            try expect(repository.tasks(for: first).isEmpty && repository.tasks(for: alias).isEmpty && backend.addAttempts == 0, "Returning to identical owner bytes cannot revive an operation from the previous session version")
            try expect(backend.authorizationRequests == 1, "Only the original explicitly requested fake permission operation occurs")
            try expectIndependentB(backend, repository: repository, original: independent)
        }
        try await run("raw-owner-switch-rejects-held-applied-add-save", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url), original = task(owner: first), backend = FakeNotificationBackend()
            repository.addTask(original); let independent = try seedForeignReminder(backend, repository: repository)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository); _ = await coordinator.activate(ownerId: first)
            let gate = AddGate(); backend.enqueue(.holdAfterStore(gate)); defer { gate.open() }
            var changed = original; changed.title = "Must not commit old owner"; changed.dueAt = original.dueAt!.addingTimeInterval(600)
            let candidate = changed, applied = backend.appliedAddAttempts, bytes = try Data(contentsOf: url)
            let save = Task { try await coordinator.saveTask(candidate, isNew: false, ownerId: first, requestAuthorization: false) }
            try await backend.waitForAppliedAddAttempts(applied + 1)
            _ = await coordinator.activate(ownerId: alias); gate.open()
            try await expectReminderError(.inactiveSession) { try await save.value }
            try expect(repository.tasks(for: first) == [original] && (try Data(contentsOf: url)) == bytes && ownedPending(backend, owner: first).isEmpty, "A late applied add cannot commit old data or leave old-owner notifications")
            try expectIndependentB(backend, repository: repository, original: independent)
        }
        try await run("raw-owner-switch-rejects-held-post-add-readback-save", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url), original = task(owner: first), backend = FakeNotificationBackend()
            repository.addTask(original); let independent = try seedForeignReminder(backend, repository: repository)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository); _ = await coordinator.activate(ownerId: first)
            let gate = AddGate(); backend.holdNextPendingRead(gate, afterAddAttempts: backend.addAttempts + 1); defer { gate.open() }
            var changed = original; changed.title = "Readback cannot commit old owner"; changed.dueAt = original.dueAt!.addingTimeInterval(600)
            let candidate = changed, bytes = try Data(contentsOf: url)
            let save = Task { try await coordinator.saveTask(candidate, isNew: false, ownerId: first, requestAuthorization: false) }
            try await backend.waitForPendingReadHolds(1)
            _ = await coordinator.activate(ownerId: alias); gate.open()
            try await expectReminderError(.inactiveSession) { try await save.value }
            try expect(repository.tasks(for: first) == [original] && (try Data(contentsOf: url)) == bytes && ownedPending(backend, owner: first).isEmpty, "A callback held after real fake-OS apply cannot pass the new raw-owner session")
            try expectIndependentB(backend, repository: repository, original: independent)
        }
        try await run("raw-owner-switch-rejects-held-status-commit", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url), original = task(owner: first), backend = FakeNotificationBackend()
            repository.addTask(original); let independent = try seedForeignReminder(backend, repository: repository)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository); _ = await coordinator.activate(ownerId: first)
            let gate = AddGate(); backend.holdNextPendingRead(gate); defer { gate.open() }
            let bytes = try Data(contentsOf: url)
            let status = Task { try await coordinator.updateTaskStatus(id: original.id, ownerId: first, status: .completed) }
            try await backend.waitForPendingReadHolds(1)
            _ = await coordinator.activate(ownerId: alias); gate.open()
            try await expectReminderError(.inactiveSession) { try await status.value }
            try expect(repository.tasks(for: first) == [original] && (try Data(contentsOf: url)) == bytes, "Held status completion cannot write into the previous exact owner")
            try expectIndependentB(backend, repository: repository, original: independent)
        }
        try await run("raw-owner-switch-rejects-held-delete-commit", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url), original = task(owner: first), backend = FakeNotificationBackend()
            repository.addTask(original); let independent = try seedForeignReminder(backend, repository: repository)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository); _ = await coordinator.activate(ownerId: first)
            let gate = AddGate(); backend.holdNextPendingRead(gate); defer { gate.open() }
            let bytes = try Data(contentsOf: url)
            let deletion = Task { try await coordinator.deleteTask(id: original.id, ownerId: first) }
            try await backend.waitForPendingReadHolds(1)
            _ = await coordinator.activate(ownerId: alias); gate.open()
            try await expectReminderError(.inactiveSession) { try await deletion.value }
            try expect(repository.tasks(for: first) == [original] && (try Data(contentsOf: url)) == bytes, "A held old-owner delete cannot pass a canonical alias switch")
            try expectIndependentB(backend, repository: repository, original: independent)
        }
        try await run("raw-owner-explicit-old-cleanup-keeps-active-alias-and-independent-keys", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url), backend = FakeNotificationBackend(), original = task("same", owner: first, reminder: false)
            repository.addTask(original); let independent = try seedForeignReminder(backend, repository: repository)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: first); _ = await coordinator.activate(ownerId: alias)
            let oldRequest = try rawOwnerRequest(task("same", owner: first)), aliasRequest = try rawOwnerRequest(task("same", owner: alias))
            try expect(oldRequest.identifier != aliasRequest.identifier, "Canonical aliases require independent notification identifier namespaces")
            backend.seed(oldRequest, delivered: true); backend.seed(aliasRequest, delivered: true)
            await coordinator.removeAll(for: first)
            try expect(ownedPending(backend, owner: first).isEmpty && !backend.deliveredSnapshot.contains(oldRequest.identifier), "An explicitly authorized old-owner cleanup must still remove old pending/delivered requests")
            try expect(ownedPending(backend, owner: alias).count == 1 && backend.deliveredSnapshot.contains(aliasRequest.identifier), "Old-owner cleanup must not touch the active raw alias namespace")
            do {
                _ = try await coordinator.saveQuietHours(.disabled, ownerId: alias)
                throw CoordinatorTestFailure.assertion("The repository must reject its ambiguous legacy owner map")
            } catch AssistantRepositoryError.invalidUserId {}
            await coordinator.removeAll(for: alias)
            try await expectReminderError(.inactiveSession) { _ = try await coordinator.saveQuietHours(.disabled, ownerId: alias) }
            try expect(ownedPending(backend, owner: alias).isEmpty && !backend.deliveredSnapshot.contains(aliasRequest.identifier), "Explicit alias cleanup independently ends only its own session and requests")
            try expectIndependentB(backend, repository: repository, original: independent)
        }
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caobao-coordinator-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try await run("only-explicit-opt-in-requests-permission", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            try await coordinator.saveTask(task("plain", reminder: nil), isNew: true, ownerId: "A", requestAuthorization: true)
            try expect(backend.authorizationRequests == 0 && backend.pendingSnapshot.isEmpty, "A due date is not notification consent")
            _ = await coordinator.reconcile(ownerId: "A")
            try expect(backend.authorizationRequests == 0, "Foreground reconciliation must not prompt")
            try await expectReminderError(.authorizationRequired) {
                try await coordinator.saveTask(task("explicit"), isNew: true, ownerId: "A", requestAuthorization: false)
            }
            try expect(repository.tasks(for: "A").count == 1, "An unapproved permission request must not persist")
            try await coordinator.saveTask(task("explicit"), isNew: true, ownerId: "A", requestAuthorization: true)
            try expect(backend.authorizationRequests == 1, "Explicit opt-in Save requests permission once")
            try expect(backend.lastAuthorizationOptions.contains([.alert, .sound]), "Request alert/sound permissions only")
            let request = backend.pendingSnapshot.first!
            let expectedBrand = AssistantLocalization.string("草包")
            try expect(request.content.title == expectedBrand && !request.content.body.contains("Private"), "Lockscreen text must use the localized brand and stay generic")
            try expect(request.content.userInfo["taskId"] as? String == "explicit" && request.content.userInfo["ownerId"] as? String == "A", "Notification must contain scoped deep-link keys")
            try expect((request.trigger as? UNCalendarNotificationTrigger)?.repeats == false, "Reminders must be one-shot")
        }
        try await run("denied-permission-retains-old-record", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let original = task(reminder: false, title: "Original title")
            repository.addTask(original)
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            backend.allowAuthorizationRequest(false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            var changed = original; changed.title = "Edited title"; changed.reminderEnabled = true
            try await expectReminderError(.permissionDenied) {
                try await coordinator.saveTask(changed, isNew: false, ownerId: "A", requestAuthorization: true)
            }
            try expect(repository.tasks(for: "A").first == original, "Permission denial must retain the entire old record")
            try expect(backend.authorizationRequests == 1 && backend.pendingSnapshot.isEmpty, "Denied permission cannot create a notification")
            try await expectReminderError(.permissionDenied) {
                try await coordinator.saveTask(changed, isNew: false, ownerId: "A", requestAuthorization: true)
            }
            try expect(backend.authorizationRequests == 1, "Already denied status must not reprompt")
        }
        try await run("complete-pause-delete-clean-up-only-owned-requests", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            for id in ["complete", "pause", "delete"] { repository.addTask(task(id)) }
            let backend = FakeNotificationBackend()
            backend.seed(externalRequest(), delivered: true)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            try expect(backend.pendingSnapshot.count == 4, "Fixture schedules three opted-in tasks")
            for value in backend.pendingSnapshot where value.identifier != "unrelated.calendar.event" { backend.seed(value, delivered: true) }
            try await coordinator.updateTaskStatus(id: "complete", ownerId: "A", status: .completed)
            try await coordinator.updateTaskStatus(id: "pause", ownerId: "A", status: .paused)
            try await coordinator.deleteTask(id: "delete", ownerId: "A")
            try expect(backend.pendingSnapshot.map(\.identifier) == ["unrelated.calendar.event"], "Task state changes remove only owned pending notifications")
            try expect(backend.deliveredSnapshot == ["unrelated.calendar.event"], "Task state changes remove only owned delivered notifications")
            try expect(repository.tasks(for: "A").first(where: { $0.id == "complete" })?.status == .completed, "Completion persists")
            try expect(repository.tasks(for: "A").first(where: { $0.id == "pause" })?.status == .paused, "Pause persists")
            try expect(!repository.tasks(for: "A").contains(where: { $0.id == "delete" }), "Delete persists")
            try await coordinator.updateTaskStatus(id: "complete", ownerId: "A", status: .active)
            try expect(backend.pendingSnapshot.count == 2 && backend.authorizationRequests == 0, "Reopening reschedules without prompting")
        }
        try await run("scheduling-failure-does-not-commit", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let original = task(reminder: false, title: "Original title")
            repository.addTask(original)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            backend.enqueue(.fail)
            var changed = original; changed.title = "New title"; changed.reminderEnabled = true
            do {
                try await coordinator.saveTask(changed, isNew: false, ownerId: "A", requestAuthorization: true)
                throw CoordinatorTestFailure.assertion("Expected scheduling failure")
            } catch AssistantReminderError.schedulingFailed { }
            try expect(repository.tasks(for: "A").first == original, "Scheduling failure must not overwrite prior data")
            try expect(backend.pendingSnapshot.isEmpty, "Failed scheduling must not create a request")
        }
        try await run("persistence-failure-restores-prior-notification", root: root) { url in
            let fileManager = RejectingWriteFileManager()
            let repository = AssistantLocalRepository(fileURL: url, fileManager: fileManager)
            let original = task(title: "Original title")
            repository.addTask(original)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let initialTriggerDate = (backend.pendingSnapshot.first?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            fileManager.rejectsDirectoryCreation = true
            var changed = original; changed.title = "Uncommitted"; changed.dueAt = original.dueAt!.addingTimeInterval(3_600)
            do {
                try await coordinator.saveTask(changed, isNew: false, ownerId: "A", requestAuthorization: true)
                throw CoordinatorTestFailure.assertion("Expected persistence failure")
            } catch AssistantReminderError.persistenceFailed { }
            try expect(repository.tasks(for: "A").first == original, "Failed disk write must retain old in-memory record")
            try expect(AssistantLocalRepository(fileURL: url).tasks(for: "A").first?.title == original.title, "Failed disk write must retain old disk record")
            try expect(backend.addAttempts == 3, "Initial schedule, attempted edit and restoration must occur")
            let restoredDate = (backend.pendingSnapshot.first?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            try expect(restoredDate == initialTriggerDate, "The prior reminder date must be restored")
        }
        try await run("account-switch-rejects-delayed-old-owner-add", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.enqueue(.hold(gate)); defer { gate.open() }
            let oldSave = Task { try await coordinator.saveTask(task("same", owner: "A"), isNew: true, ownerId: "A", requestAuthorization: true) }
            try await backend.waitForAddAttempts(1)
            _ = await coordinator.activate(ownerId: "B")
            try await coordinator.saveTask(task("same", owner: "B"), isNew: true, ownerId: "B", requestAuthorization: true)
            gate.open()
            do { try await oldSave.value; throw CoordinatorTestFailure.assertion("Old owner Save must fail") }
            catch AssistantReminderError.inactiveSession { }
            try expect(repository.tasks(for: "A").isEmpty && repository.tasks(for: "B").count == 1, "Only the active owner may persist after the await")
            try expect(backend.pendingSnapshot.count == 1 && backend.pendingSnapshot.first?.content.userInfo["ownerId"] as? String == "B", "Delayed OS add cannot resurrect A or remove B")
        }
        try await run("sign-out-cleanup-rejects-delayed-add", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend()
            backend.seed(externalRequest(), delivered: true)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.enqueue(.hold(gate)); defer { gate.open() }
            let pendingSave = Task { try await coordinator.saveTask(task(), isNew: true, ownerId: "A", requestAuthorization: true) }
            try await backend.waitForAddAttempts(1)
            await coordinator.removeAll(for: "A")
            gate.open()
            do { try await pendingSave.value; throw CoordinatorTestFailure.assertion("Logged-out Save must fail") }
            catch AssistantReminderError.inactiveSession { }
            try expect(repository.tasks(for: "A").isEmpty, "Logged-out work cannot commit")
            try expect(backend.pendingSnapshot.map(\.identifier) == ["unrelated.calendar.event"], "Sign-out cleanup cannot remove another feature or resurrect A")
            try expect(backend.deliveredSnapshot == ["unrelated.calendar.event"], "Delivered cleanup is namespace-scoped")
        }
        try await run("cancelled-activation-does-not-switch-account", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await coordinator.activate(ownerId: "B")
            }
            let report = await cancelled.value
            try expect(!report.errors.isEmpty, "Cancelled activation must remain rejected")
            try await coordinator.saveTask(task(reminder: false), isNew: true, ownerId: "A", requestAuthorization: false)
            try expect(repository.tasks(for: "A").count == 1 && repository.tasks(for: "B").isEmpty, "Cancelled activation cannot replace A")
        }
        try await run("quiet-save-replans-without-authorizing-or-enabling-tasks", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let value = task()
            let legacy = task("legacy", reminder: nil)
            repository.addTask(value); repository.addTask(legacy)
            let backend = FakeNotificationBackend()
            backend.seed(externalRequest())
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let policy = quiet(around: value.dueAt!)
            let report = try await coordinator.saveQuietHours(policy, ownerId: "A")
            try expect(report.errors.isEmpty && report.statesByTaskId[value.id] == .scheduled, "Saved quiet hours must replan enabled reminders")
            try expect(report.statesByTaskId[legacy.id] == .notEnabled, "Quiet hours cannot enable legacy reminder consent")
            try expect(repository.tasks(for: "A").contains(value) && repository.tasks(for: "A").contains(legacy), "Quiet preference cannot edit task records or dueAt")
            try expect(try AssistantLocalRepository(fileURL: url).quietHours(for: "A") == policy, "Quiet hours must survive a repository reload")
            try expect(backend.authorizationRequests == 0 && backend.pendingSnapshot.count == 2, "Replan does not prompt or remove unrelated notifications")
            try expectDelivery(backend, task: value, policy: policy)
            let disabled = AssistantQuietHours.disabled
            let disabledReport = try await coordinator.saveQuietHours(disabled, ownerId: "A")
            try expect(disabledReport.errors.isEmpty, "Disabling quiet hours reschedules normally")
            try expectDelivery(backend, task: value, policy: disabled)
        }
        try await run("quiet-save-never-requests-undetermined-permission", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let value = task(); repository.addTask(value)
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let report = try await coordinator.saveQuietHours(quiet(around: value.dueAt!), ownerId: "A")
            try expect(report.statesByTaskId[value.id] == .permissionRequired, "Unapproved permission remains visible")
            try expect(backend.authorizationRequests == 0 && backend.pendingSnapshot.isEmpty, "Saving preferences never prompts for permission")
        }
        try await run("quiet-save-disk-failure-leaves-preference-and-notification", root: root) { url in
            let manager = RejectingWriteFileManager()
            let repository = AssistantLocalRepository(fileURL: url, fileManager: manager)
            let value = task(); repository.addTask(value)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let original = try repository.quietHours(for: "A")
            manager.rejectsDirectoryCreation = true
            do {
                _ = try await coordinator.saveQuietHours(quiet(around: value.dueAt!), ownerId: "A")
                throw CoordinatorTestFailure.assertion("Expected quiet-hours persistence failure")
            } catch AssistantReminderError.persistenceFailed { }
            try expect(try repository.quietHours(for: "A") == original, "Failed disk write cannot change in-memory quiet settings")
            try expect(try AssistantLocalRepository(fileURL: url).quietHours(for: "A") == original, "Failed disk write cannot change on-disk quiet settings")
            try expect(backend.addAttempts == 1 && backend.authorizationRequests == 0, "Failed save cannot begin a notification replan")
            try expectDelivery(backend, task: value, policy: original)
        }
        try await run("quiet-save-invalid-input-and-foreign-owner-are-nondestructive", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let value = task(); repository.addTask(value)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let invalid = AssistantQuietHours(enabled: true, startMinute: 60, endMinute: 60, timeZoneIdentifier: "UTC")
            do {
                _ = try await coordinator.saveQuietHours(invalid, ownerId: "A")
                throw CoordinatorTestFailure.assertion("Expected equal-boundary validation failure")
            } catch AssistantQuietHoursError.equalBoundaries { }
            try await expectReminderError(.inactiveSession) {
                _ = try await coordinator.saveQuietHours(quiet(around: value.dueAt!), ownerId: "B")
            }
            try expect(try !repository.quietHours(for: "A").enabled && !repository.quietHours(for: "B").enabled, "Validation and owner failures cannot save settings")
            try expect(backend.addAttempts == 1, "Rejected preferences cannot touch OS scheduling")
            try expectDelivery(backend, task: value, policy: .disabled)
        }
        try await run("quiet-replan-failure-removes-unsafe-old-request-and-recovers", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let first = task("one"); let second = task("two")
            repository.addTask(first); repository.addTask(second)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            backend.enqueue(.fail)
            let policy = quiet(around: first.dueAt!)
            let report = try await coordinator.saveQuietHours(policy, ownerId: "A")
            try expect(report.errors.count == 1 && backend.pendingSnapshot.count == 1, "A failed replacement removes unsafe old delivery and reports partial failure")
            try expect(report.statesByTaskId.values.filter { $0 == .scheduled }.count == 1, "Other task replacements continue")
            try expect(try repository.quietHours(for: "A") == policy, "Partial scheduling failure must not pretend the preference failed to save")
            for request in backend.pendingSnapshot {
                let value = request.content.userInfo["taskId"] as? String == first.id ? first : second
                try expectDelivery(backend, task: value, policy: policy)
            }
            let recovered = await coordinator.reconcile(ownerId: "A")
            try expect(recovered.errors.isEmpty && backend.pendingSnapshot.count == 2, "Foreground retry restores the missing committed reminder")
            try expectDelivery(backend, task: first, policy: policy)
            try expectDelivery(backend, task: second, policy: policy)
            try expect(backend.authorizationRequests == 0, "Failure recovery cannot request permission")
        }
        try await run("quiet-past-due-stays-deferred-but-old-day-does-not-revive", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            var recent = task("recent"); recent.dueAt = Date().addingTimeInterval(-10)
            var expired = task("expired"); expired.dueAt = recent.dueAt!.addingTimeInterval(-86_400)
            repository.addTask(recent); repository.addTask(expired)
            let policy = quiet(around: recent.dueAt!)
            try expect(repository.setQuietHours(policy, for: "A"), "Fixture must save the policy")
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            let report = await coordinator.activate(ownerId: "A")
            try expect(report.statesByTaskId[recent.id] == .scheduled && report.statesByTaskId[expired.id] == .pastDue, "Only the original due window controls expiry")
            try expect(backend.pendingSnapshot.count == 1, "An expired one-shot cannot be revived in today's quiet window")
            try expectDelivery(backend, task: recent, policy: policy)
            try expect(repository.tasks(for: "A").contains(recent), "Midnight reconciliation cannot move task dueAt")
        }
        try await run("quiet-change-invalidates-delayed-reconciliation-add", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let value = task(); repository.addTask(value)
            let backend = FakeNotificationBackend()
            let gate = AddGate(); backend.enqueue(.hold(gate)); defer { gate.open() }
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            let activation = Task { await coordinator.activate(ownerId: "A") }
            try await backend.waitForAddAttempts(1)
            let policy = quiet(around: value.dueAt!)
            let saved = try await coordinator.saveQuietHours(policy, ownerId: "A")
            try expect(!saved.errors.isEmpty, "An in-flight replan cannot be reported as completed")
            gate.open()
            _ = await activation.value
            try expectDelivery(backend, task: value, policy: policy)
            try expect(backend.pendingSnapshot.count == 1 && backend.authorizationRequests == 0, "Late old plan is replaced exactly once under current policy")
        }
        try await run("quiet-change-invalidates-delayed-task-save", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let original = task(); repository.addTask(original)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.enqueue(.hold(gate)); defer { gate.open() }
            var edited = original; edited.title = "Uncommitted edit"; edited.dueAt = original.dueAt!.addingTimeInterval(600)
            let edit = edited
            let save = Task { try await coordinator.saveTask(edit, isNew: false, ownerId: "A", requestAuthorization: false) }
            try await backend.waitForAddAttempts(2)
            let policy = quiet(around: original.dueAt!)
            _ = try await coordinator.saveQuietHours(policy, ownerId: "A")
            try expect(backend.pendingSnapshot.isEmpty, "New quiet hours remove an unsafe old request even when task Save is suspended")
            gate.open()
            do { try await save.value; throw CoordinatorTestFailure.assertion("Stale task Save cannot commit") }
            catch AssistantReminderError.operationInProgress { }
            try expect(repository.tasks(for: "A").first == original, "Stale task Save must preserve the committed task")
            try expectDelivery(backend, task: original, policy: policy)
        }
        try await run("quiet-change-invalidates-delayed-rollback-restoration", root: root) { url in
            let manager = RejectingWriteFileManager()
            let repository = AssistantLocalRepository(fileURL: url, fileManager: manager)
            let original = task(); repository.addTask(original)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.enqueue(.succeed); backend.enqueue(.hold(gate)); defer { gate.open() }
            manager.rejectsDirectoryCreation = true
            var edited = original; edited.dueAt = original.dueAt!.addingTimeInterval(600)
            let edit = edited
            let save = Task { try await coordinator.saveTask(edit, isNew: false, ownerId: "A", requestAuthorization: false) }
            try await backend.waitForAddAttempts(3)
            manager.rejectsDirectoryCreation = false
            let policy = quiet(around: original.dueAt!)
            _ = try await coordinator.saveQuietHours(policy, ownerId: "A")
            gate.open()
            do { try await save.value; throw CoordinatorTestFailure.assertion("Disk failure must remain a failure") }
            catch AssistantReminderError.persistenceFailed { }
            try expect(repository.tasks(for: "A").first == original, "Failed edit cannot replace the original record")
            try expectDelivery(backend, task: original, policy: policy)
            try expect(backend.authorizationRequests == 0, "Rollback recovery never prompts")
        }
        try await run("same-owner-quiet-saves-keep-newest-policy", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let value = task(); repository.addTask(value)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.enqueue(.hold(gate)); defer { gate.open() }
            let firstPolicy = quiet(around: value.dueAt!, endOffset: 120)
            let latest = quiet(around: value.dueAt!, endOffset: 180)
            let firstSave = Task { try await coordinator.saveQuietHours(firstPolicy, ownerId: "A") }
            try await backend.waitForAddAttempts(2)
            let latestReport = try await coordinator.saveQuietHours(latest, ownerId: "A")
            try expect(!latestReport.errors.isEmpty, "Pending replacement must be reported honestly")
            gate.open()
            let stale = try await firstSave.value
            try expect(!stale.errors.isEmpty, "An older save cannot report a superseded schedule as current")
            try expect(try repository.quietHours(for: "A") == latest, "Last saved quiet preference wins")
            try expectDelivery(backend, task: value, policy: latest)
        }
        try await run("same-owner-quiet-change-recovers-after-delayed-add-failure", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let value = task(); repository.addTask(value)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.enqueue(.holdThenFail(gate)); defer { gate.open() }
            let firstPolicy = quiet(around: value.dueAt!, endOffset: 120)
            let latest = quiet(around: value.dueAt!, endOffset: 180)
            let oldSave = Task { try await coordinator.saveQuietHours(firstPolicy, ownerId: "A") }
            try await backend.waitForAddAttempts(2)
            _ = try await coordinator.saveQuietHours(latest, ownerId: "A")
            gate.open()
            let failed = try await oldSave.value
            try expect(!failed.errors.isEmpty, "Delayed OS failure remains visible")
            try expectDelivery(backend, task: value, policy: latest)
        }
        try await run("quiet-save-owner-switch-cannot-pollute-new-owner", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let a = task(owner: "A"); let b = task(owner: "B")
            repository.addTask(a); repository.addTask(b)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.enqueue(.hold(gate)); defer { gate.open() }
            let policy = quiet(around: a.dueAt!)
            let oldSave = Task { try await coordinator.saveQuietHours(policy, ownerId: "A") }
            try await backend.waitForAddAttempts(2)
            _ = await coordinator.activate(ownerId: "B")
            gate.open()
            let stale = try await oldSave.value
            try expect(!stale.errors.isEmpty, "Owner-switched scheduling result must not appear current")
            try expect(backend.pendingSnapshot.count == 1 && backend.pendingSnapshot.first?.content.userInfo["ownerId"] as? String == "B", "Old owner late add cannot survive or remove B")
            try expect(try repository.quietHours(for: "A") == policy && !repository.quietHours(for: "B").enabled, "Quiet preferences remain owner scoped")
            try expectDelivery(backend, task: b, policy: .disabled)
        }
        try await run("cancelled-quiet-save-repairs-committed-policy-without-authorizing", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let value = task(); repository.addTask(value)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.enqueue(.hold(gate)); defer { gate.open() }
            let policy = quiet(around: value.dueAt!)
            let save = Task { try await coordinator.saveQuietHours(policy, ownerId: "A") }
            try await backend.waitForAddAttempts(2)
            save.cancel(); gate.open()
            let report = try await save.value
            try expect(!report.errors.isEmpty, "Cancellation after commit cannot be reported as an ordinary completed save")
            try expect(try repository.quietHours(for: "A") == policy, "Cancellation cannot pretend a successful commit was rolled back")
            try expectDelivery(backend, task: value, policy: policy)
            try expect(backend.authorizationRequests == 0, "Cancelled-operation recovery cannot request permissions")
            let rejected = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await coordinator.saveQuietHours(.disabled, ownerId: "A")
            }
            do { _ = try await rejected.value; throw CoordinatorTestFailure.assertion("Pre-cancelled save must fail") }
            catch AssistantReminderError.inactiveSession { }
            try expect(try repository.quietHours(for: "A") == policy, "Pre-cancelled save cannot modify committed preferences")
        }
        try await run("cancelled-quiet-save-after-commit-still-removes-old-window", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let value = task(); repository.addTask(value)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.holdNextSettingsRead(gate); defer { gate.open() }
            let policy = quiet(around: value.dueAt!)
            let settingsBefore = backend.settingsRequests
            let save = Task { try await coordinator.saveQuietHours(policy, ownerId: "A") }
            try await backend.waitForSettingsRequests(settingsBefore + 1)
            try expect(try repository.quietHours(for: "A") == policy, "The fixture pauses after the policy commit")
            save.cancel(); gate.open()
            let report = try await save.value
            try expect(!report.errors.isEmpty, "Cancellation after commit remains visible")
            try expectDelivery(backend, task: value, policy: policy)
            try expect(backend.authorizationRequests == 0, "Cancellation cannot turn a preference save into authorization")
        }
        try await run("task-save-uses-quiet-policy-for-recent-past-due", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            var value = task(); value.dueAt = Date().addingTimeInterval(-10)
            let policy = quiet(around: value.dueAt!)
            try expect(repository.setQuietHours(policy, for: "A"), "Fixture policy must save")
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            try await coordinator.saveTask(value, isNew: true, ownerId: "A", requestAuthorization: false)
            try expect(repository.tasks(for: "A").first == value, "Task Save preserves its due time even when notification is deferred")
            try expectDelivery(backend, task: value, policy: policy)
            try expect(backend.authorizationRequests == 0, "Authorized task Save cannot reprompt")
        }
        try await run("cancelled-task-save-restores-committed-quiet-policy", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let original = task(); repository.addTask(original)
            let policy = quiet(around: original.dueAt!)
            try expect(repository.setQuietHours(policy, for: "A"), "Fixture policy must save")
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.enqueue(.hold(gate)); defer { gate.open() }
            var edited = original; edited.title = "Cancelled edit"; edited.dueAt = original.dueAt!.addingTimeInterval(600)
            let edit = edited
            let save = Task { try await coordinator.saveTask(edit, isNew: false, ownerId: "A", requestAuthorization: false) }
            try await backend.waitForAddAttempts(2)
            save.cancel(); gate.open()
            do { try await save.value; throw CoordinatorTestFailure.assertion("Cancelled task Save cannot commit") }
            catch AssistantReminderError.inactiveSession { }
            try expect(repository.tasks(for: "A").first == original, "Cancelled edit must preserve the committed record")
            try expectDelivery(backend, task: original, policy: policy)
            try expect(backend.pendingSnapshot.count == 1 && backend.authorizationRequests == 0, "Cancellation recovery is owner scoped and never prompts")
        }
        try await run("ordinary-reconcile-retains-valid-applied-inflight-task-candidate", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let original = task(); repository.addTask(original)
            let policy = quiet(around: original.dueAt!)
            try expect(repository.setQuietHours(policy, for: "A"), "Fixture quiet policy must save")
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.enqueue(.holdAfterStore(gate)); defer { gate.open() }
            var edited = original; edited.dueAt = original.dueAt!.addingTimeInterval(4 * 3_600)
            let edit = edited
            try expect(try policy.deliveryDate(for: edit.dueAt!) == edit.dueAt!, "Edited due time must fall outside the existing quiet window")
            let save = Task { try await coordinator.saveTask(edit, isNew: false, ownerId: "A", requestAuthorization: false) }
            try await backend.waitForAppliedAddAttempts(2)
            try expect(backend.pendingSnapshot.count == 1, "Candidate is already applied while OS completion is suspended")
            try expectDelivery(backend, task: edit, policy: policy)
            _ = await coordinator.reconcile(ownerId: "A")
            try expect(backend.pendingSnapshot.count == 1, "Ordinary reconciliation must preserve the valid in-flight candidate")
            try expectDelivery(backend, task: edit, policy: policy)
            gate.open(); try await save.value
            let saved = repository.tasks(for: "A").first
            try expect(saved?.id == edit.id && saved?.userId == edit.userId && saved?.dueAt == edit.dueAt, "Task Save commits the edited due date")
            try expect(backend.pendingSnapshot.count == 1, "Successful task Save must retain its scheduled notification")
            try expectDelivery(backend, task: edit, policy: policy)
            try expect(backend.authorizationRequests == 0, "A background reconciliation cannot request permission")
        }
        try await run("new-quiet-policy-removes-applied-inflight-unsafe-candidate", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let original = task(); repository.addTask(original)
            let oldPolicy = quiet(around: original.dueAt!)
            try expect(repository.setQuietHours(oldPolicy, for: "A"), "Fixture quiet policy must save")
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.enqueue(.holdAfterStore(gate)); defer { gate.open() }
            var edited = original; edited.dueAt = original.dueAt!.addingTimeInterval(4 * 3_600)
            let edit = edited
            let save = Task { try await coordinator.saveTask(edit, isNew: false, ownerId: "A", requestAuthorization: false) }
            try await backend.waitForAppliedAddAttempts(2)
            try expectDelivery(backend, task: edit, policy: oldPolicy)
            let newPolicy = quiet(around: edit.dueAt!)
            try expect(try newPolicy.deliveryDate(for: edit.dueAt!) != edit.dueAt!, "Candidate must violate the new quiet window")
            let report = try await coordinator.saveQuietHours(newPolicy, ownerId: "A")
            try expect(!report.errors.isEmpty && backend.pendingSnapshot.isEmpty, "A newly invalid in-flight candidate must be removed immediately")
            gate.open()
            do { try await save.value; throw CoordinatorTestFailure.assertion("Superseded task Save cannot commit") }
            catch AssistantReminderError.operationInProgress { }
            try expect(repository.tasks(for: "A").first == original, "Superseded candidate cannot change the persisted task")
            try expect(try repository.quietHours(for: "A") == newPolicy, "The new quiet policy stays committed")
            try expect(backend.pendingSnapshot.count == 1, "Late completion recovers exactly the current persisted plan")
            try expectDelivery(backend, task: original, policy: newPolicy)
            try expect(backend.authorizationRequests == 0, "Policy replacement and recovery cannot authorize notifications")
        }
        try await run("source-invalid-at-entry-never-prompts-or-schedules", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let settingsBefore = backend.settingsRequests
            let source = SourceValidationFixture(); source.invalidate()
            do {
                try await coordinator.saveTask(task(), isNew: true, ownerId: "A", requestAuthorization: true,
                    validateBeforeCommit: { try source.validate() })
                throw CoordinatorTestFailure.assertion("An invalid source cannot save")
            } catch SourceValidationFailure.invalidated { }
            try expect(repository.tasks(for: "A").isEmpty, "Initial source rejection cannot commit a task")
            try expect(backend.authorizationRequests == 0 && backend.addAttempts == 0 && backend.settingsRequests == settingsBefore,
                "Initial validation precedes every permission query or OS effect")
        }
        try await run("source-invalid-during-settings-does-not-request-permission", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let source = SourceValidationFixture()
            let gate = AddGate(); backend.holdNextSettingsRead(gate); defer { gate.open() }
            let readsBefore = backend.settingsRequests
            let save = Task {
                try await coordinator.saveTask(task(), isNew: true, ownerId: "A", requestAuthorization: true,
                    validateBeforeCommit: { try source.validate() })
            }
            try await backend.waitForSettingsRequests(readsBefore + 1)
            source.invalidate(); gate.open()
            do { try await save.value; throw CoordinatorTestFailure.assertion("A stale source cannot authorize") }
            catch SourceValidationFailure.invalidated { }
            try expect(repository.tasks(for: "A").isEmpty && backend.authorizationRequests == 0 && backend.addAttempts == 0,
                "Source invalidation during a settings await must be rechecked before asking permission")
        }
        try await run("source-invalid-during-permission-never-commits", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let source = SourceValidationFixture()
            let gate = AddGate(); backend.holdNextAuthorization(gate); defer { gate.open() }
            let save = Task {
                try await coordinator.saveTask(task(), isNew: true, ownerId: "A", requestAuthorization: true,
                    validateBeforeCommit: { try source.validate() })
            }
            try await backend.waitForAuthorizationRequests(1)
            source.invalidate(); gate.open()
            do { try await save.value; throw CoordinatorTestFailure.assertion("Invalidated permission-time source cannot commit") }
            catch SourceValidationFailure.invalidated { }
            let calls = source.calls
            try expect(calls >= 3 && repository.tasks(for: "A").isEmpty && backend.pendingSnapshot.isEmpty,
                "Final MainActor validation rejects a source that vanished while permission was suspended")
            try expect(backend.authorizationRequests == 1, "Only the initially explicit permission request is allowed")
        }
        try await run("source-invalid-after-applied-new-candidate-removes-request", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let source = SourceValidationFixture()
            let gate = AddGate(); backend.enqueue(.holdAfterStore(gate)); defer { gate.open() }
            let save = Task {
                try await coordinator.saveTask(task(), isNew: true, ownerId: "A", requestAuthorization: false,
                    validateBeforeCommit: { try source.validate() })
            }
            try await backend.waitForAppliedAddAttempts(1)
            try expect(backend.pendingSnapshot.count == 1, "Exercise an OS-applied candidate before completion")
            source.invalidate(); gate.open()
            do { try await save.value; throw CoordinatorTestFailure.assertion("Final source guard must reject the new candidate") }
            catch SourceValidationFailure.invalidated { }
            try expect(repository.tasks(for: "A").isEmpty && backend.pendingSnapshot.isEmpty,
                "Source rejection removes an applied uncommitted new reminder")
            try expect(backend.authorizationRequests == 0, "Cleanup never requests permission")
        }
        try await run("source-invalid-after-applied-edit-restores-original-quiet-plan", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let original = task(); repository.addTask(original)
            let policy = quiet(around: original.dueAt!)
            try expect(repository.setQuietHours(policy, for: "A"), "Fixture quiet policy must persist")
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let source = SourceValidationFixture()
            let gate = AddGate(); backend.enqueue(.holdAfterStore(gate)); defer { gate.open() }
            var value = original; value.title = "uncommitted source edit"; value.dueAt = original.dueAt!.addingTimeInterval(14_400)
            let edited = value
            let save = Task {
                try await coordinator.saveTask(edited, isNew: false, ownerId: "A", requestAuthorization: false,
                    validateBeforeCommit: { try source.validate() })
            }
            try await backend.waitForAppliedAddAttempts(2)
            source.invalidate(); gate.open()
            do { try await save.value; throw CoordinatorTestFailure.assertion("Invalidated edit cannot commit") }
            catch SourceValidationFailure.invalidated { }
            try expect(repository.tasks(for: "A").first == original && backend.pendingSnapshot.count == 1,
                "Failure leaves the old record and exactly one restored reminder")
            try expectDelivery(backend, task: original, policy: policy)
            try expect(backend.authorizationRequests == 0, "Rollback is authorization free")
        }
        try await run("source-no-reminder-rechecks-synchronously-before-commit", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let readsBefore = backend.settingsRequests
            let source = SourceValidationFixture(successesAllowed: 1)
            do {
                try await coordinator.saveTask(task(reminder: false), isNew: true, ownerId: "A", requestAuthorization: true,
                    validateBeforeCommit: { try source.validate() })
                throw CoordinatorTestFailure.assertion("No-reminder source still needs a final guard")
            } catch SourceValidationFailure.invalidated { }
            let calls = source.calls
            try expect(calls == 2 && repository.tasks(for: "A").isEmpty, "No-reminder path performs initial and final MainActor checks before persisting")
            try expect(backend.authorizationRequests == 0 && backend.addAttempts == 0 && backend.settingsRequests == readsBefore,
                "No-reminder rejection cannot touch notification APIs")
        }
        try await run("source-valid-no-reminder-commits-without-authorizing", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let source = SourceValidationFixture()
            let value = task(reminder: false)
            try await coordinator.saveTask(value, isNew: true, ownerId: "A", requestAuthorization: true,
                validateBeforeCommit: { try source.validate() })
            let calls = source.calls
            try expect(calls == 2 && repository.tasks(for: "A").first == value, "Valid source commits after the final MainActor check")
            try expect(backend.authorizationRequests == 0 && backend.addAttempts == 0, "No-reminder save never prompts")
        }
        try await run("guarded-owner-switch-cannot-commit-or-pollute-new-owner", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let a = task(owner: "A"), b = task(owner: "B")
            repository.addTask(a); repository.addTask(b)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let source = SourceValidationFixture()
            let gate = AddGate(); backend.enqueue(.holdAfterStore(gate)); defer { gate.open() }
            var value = a; value.title = "A uncommitted source edit"; value.dueAt = a.dueAt!.addingTimeInterval(600)
            let edited = value
            let save = Task { try await coordinator.saveTask(edited, isNew: false, ownerId: "A", requestAuthorization: false,
                validateBeforeCommit: { try source.validate() }) }
            try await backend.waitForAppliedAddAttempts(2)
            _ = await coordinator.activate(ownerId: "B")
            gate.open()
            do { try await save.value; throw CoordinatorTestFailure.assertion("A stale owner cannot commit") }
            catch AssistantReminderError.inactiveSession { }
            try expect(repository.tasks(for: "A").first == a && repository.tasks(for: "B").first == b, "Owner switch preserves both committed records")
            try expect(backend.pendingSnapshot.count == 1 && backend.pendingSnapshot.first?.content.userInfo["ownerId"] as? String == "B",
                "Old source cannot remove B's notification")
        }
        try await run("guarded-quiet-change-keeps-newest-policy-and-old-task", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let original = task(); repository.addTask(original)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let source = SourceValidationFixture()
            let gate = AddGate(); backend.enqueue(.holdAfterStore(gate)); defer { gate.open() }
            var value = original; value.title = "uncommitted guarded edit"; value.dueAt = original.dueAt!.addingTimeInterval(600)
            let edited = value
            let save = Task { try await coordinator.saveTask(edited, isNew: false, ownerId: "A", requestAuthorization: false,
                validateBeforeCommit: { try source.validate() }) }
            try await backend.waitForAppliedAddAttempts(2)
            let latest = quiet(around: original.dueAt!)
            _ = try await coordinator.saveQuietHours(latest, ownerId: "A")
            gate.open()
            do { try await save.value; throw CoordinatorTestFailure.assertion("Superseded guarded edit cannot commit") }
            catch AssistantReminderError.operationInProgress { }
            try expect(repository.tasks(for: "A").first == original && repository.quietHours(for: "A") == latest, "Guarded save cannot replace committed task or newest policy")
            try expectDelivery(backend, task: original, policy: latest)
        }
        try await run("task-content-limits-reject-before-permission-or-os-add", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let readsBefore = backend.settingsRequests
            var longTitle = task("long-title"); longTitle.title = String(repeating: "草", count: 201)
            do { try await coordinator.saveTask(longTitle, isNew: true, ownerId: "A", requestAuthorization: true); throw CoordinatorTestFailure.assertion("Long title must fail") }
            catch AssistantWorkspaceValidation.Failure.taskTitleTooLong { }
            var longNotes = task("long-notes"); longNotes.instructions = String(repeating: "🍀", count: 20_001)
            do { try await coordinator.saveTask(longNotes, isNew: true, ownerId: "A", requestAuthorization: true); throw CoordinatorTestFailure.assertion("Long notes must fail") }
            catch AssistantWorkspaceValidation.Failure.taskNotesTooLong { }
            try expect(repository.tasks(for: "A").isEmpty && backend.authorizationRequests == 0 && backend.addAttempts == 0 && backend.settingsRequests == readsBefore,
                "Invalid content never queries or requests permission, schedules, or commits")
        }
        try await run("task-unicode-count-boundaries-save-exact-limits", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            var value = task(reminder: false)
            value.title = String(repeating: "🍀", count: 200); value.instructions = String(repeating: "🍀", count: 20_000)
            try await coordinator.saveTask(value, isNew: true, ownerId: "A", requestAuthorization: false)
            try expect(repository.tasks(for: "A").first == value && backend.authorizationRequests == 0, "Use Swift String.count, not UTF-8 bytes")
        }
        try await run("legacy-long-content-noncontent-status-remains-usable", root: root) { url in
            let originalRepository = AssistantLocalRepository(fileURL: url)
            let original = task(); originalRepository.addTask(original)
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            var owners = json["tasks"] as! [String: [[String: Any]]]
            owners["A"]![0]["title"] = String(repeating: "旧", count: 201)
            owners["A"]![0]["instructions"] = String(repeating: "旧", count: 20_001)
            json["tasks"] = owners
            try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            try await coordinator.updateTaskStatus(id: original.id, ownerId: "A", status: .paused)
            let stored = repository.tasks(for: "A").first!
            try expect(stored.status == .paused && stored.title.count == 201 && stored.instructions?.count == 20_001, "Legacy content must remain intact while pausing the task")
            try expect(backend.pendingSnapshot.isEmpty && backend.authorizationRequests == 0, "Pausing a legacy task still removes its reminder without prompting")
        }
        try await run("expired-inactive-reminders-require-explicit-reactivation-choice", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            var originals: [AssistantTask] = []
            for status in [AssistantTaskStatus.completed, .paused, .cancelled] {
                var value = task("expired-" + status.rawValue); value.status = status; value.dueAt = Date().addingTimeInterval(-600)
                repository.addTask(value); originals.append(repository.tasks(for: "A").first(where: { $0.id == value.id })!)
            }
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let reads = backend.settingsRequests
            for original in originals {
                try await expectReactivation(original) { try await coordinator.updateTaskStatus(id: original.id, ownerId: "A", status: .active) }
                try expect(repository.tasks(for: "A").first(where: { $0.id == original.id }) == original, "A choice prompt cannot commit the active state")
            }
            try expect(backend.authorizationRequests == 0 && backend.addAttempts == 0 && backend.settingsRequests == reads,
                "Already-expired reactivation must fail before notification APIs")
        }
        try await run("future-inactive-reminders-reactivate-normally", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            var originals: [AssistantTask] = []
            for status in [AssistantTaskStatus.completed, .paused, .cancelled] {
                var value = task("future-" + status.rawValue); value.status = status
                repository.addTask(value); originals.append(value)
            }
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            for original in originals {
                try await coordinator.updateTaskStatus(id: original.id, ownerId: "A", status: .active)
                let stored = repository.tasks(for: "A").first(where: { $0.id == original.id })!
                try expect(stored.status == .active && stored.reminderEnabled == true && stored.dueAt == original.dueAt, "A future reminder restores its normal active state")
                try expectDelivery(backend, task: stored, policy: .disabled)
            }
            try expect(backend.pendingSnapshot.count == 3 && backend.authorizationRequests == 0, "Existing authorization never reprompts")
        }
        try await run("reactivation-uses-future-quiet-delivery-not-old-raw-due", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            var original = task(); original.status = .paused; original.dueAt = Date().addingTimeInterval(-10)
            repository.addTask(original)
            let policy = quiet(around: original.dueAt!)
            try expect(repository.setQuietHours(policy, for: "A"), "Quiet fixture must persist")
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            try await coordinator.updateTaskStatus(id: original.id, ownerId: "A", status: .active)
            let stored = repository.tasks(for: "A").first!
            try expect(stored.dueAt == original.dueAt && stored.status == .active, "A past due inside an unfinished quiet window is still schedulable")
            try expectDelivery(backend, task: stored, policy: policy)
        }
        try await run("reopen-without-reminder-preserves-original-task-fields", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            var originals: [AssistantTask] = []
            for status in [AssistantTaskStatus.completed, .paused, .cancelled] {
                var value = task("plain-reopen-" + status.rawValue); value.status = status; value.dueAt = Date().addingTimeInterval(-600)
                value.instructions = "  keep exact notes\nand source  "; value.timeZone = "America/New_York"
                value.recurrenceRule = "FREQ=DAILY"; value.requiresApproval = true; value.sourceMessageId = "source-" + status.rawValue
                repository.addTask(value); originals.append(repository.tasks(for: "A").first(where: { $0.id == value.id })!)
            }
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let reads = backend.settingsRequests
            for original in originals {
                try await coordinator.reopenTaskWithoutReminder(original, ownerId: "A")
                let stored = repository.tasks(for: "A").first(where: { $0.id == original.id })!
                var expected = original; expected.status = .active; expected.reminderEnabled = false; expected.updatedAt = stored.updatedAt; expected.recurrenceStartsAt = stored.recurrenceStartsAt
                try expect(stored == expected, "Plain recovery changes only status, reminder switch and mutation timestamp")
            }
            try expect(backend.authorizationRequests == 0 && backend.addAttempts == 0 && backend.settingsRequests == reads, "Plain recovery never queries permission or schedules")
        }
        try await run("reactivation-stale-confirmation-snapshot-is-rejected", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            var original = task(); original.status = .paused; original.dueAt = Date().addingTimeInterval(-600)
            repository.addTask(original)
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            var changed = original; changed.instructions = "Updated while the confirmation was open"; changed.sourceMessageId = "new-source"
            try expect(repository.updateTask(changed), "Concurrent fixture update must succeed")
            let actual = repository.tasks(for: "A").first!
            do { try await coordinator.reopenTaskWithoutReminder(original, ownerId: "A"); throw CoordinatorTestFailure.assertion("Stale confirmation cannot overwrite newer content") }
            catch AssistantRepositoryError.staleTask { }
            var edited = original; edited.status = .active; edited.dueAt = Date().addingTimeInterval(7200)
            do { try await coordinator.saveTask(edited, isNew: false, ownerId: "A", requestAuthorization: true, expectedTask: original); throw CoordinatorTestFailure.assertion("Stale reschedule cannot overwrite newer content") }
            catch AssistantRepositoryError.staleTask { }
            try expect(repository.tasks(for: "A").first == actual && backend.authorizationRequests == 0 && backend.addAttempts == 0, "Both choices preserve the latest full record and avoid side effects")
        }
        try await run("reactivation-preserves-specific-errors-other-than-past-due", root: root) { url in
            let initial = AssistantLocalRepository(fileURL: url)
            var repeating = task("unsupported-repeat"); repeating.status = .paused; repeating.recurrenceRule = "FREQ=DAILY"; repeating.dueAt = Date().addingTimeInterval(-10)
            var noDue = task("missing-due"); noDue.status = .completed; noDue.dueAt = nil
            var denied = task("denied"); denied.status = .cancelled
            initial.addTask(repeating); initial.addTask(noDue); initial.addTask(denied)
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            var owners = json["tasks"] as! [String: [[String: Any]]]
            let index = owners["A"]!.firstIndex { $0["id"] as? String == repeating.id }!
            owners["A"]![index]["recurrenceRule"] = "FREQ=MONTHLY"
            json["tasks"] = owners
            try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend(status: .denied, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            try await expectReminderError(.recurrenceUnsupported) { try await coordinator.updateTaskStatus(id: repeating.id, ownerId: "A", status: .active) }
            try await expectReminderError(.missingDueDate) { try await coordinator.updateTaskStatus(id: noDue.id, ownerId: "A", status: .active) }
            try await expectReminderError(.permissionDenied) { try await coordinator.updateTaskStatus(id: denied.id, ownerId: "A", status: .active) }
            try expect(repository.tasks(for: "A").allSatisfy { $0.status != .active } && backend.authorizationRequests == 0, "Specific failures cannot commit or become a generic reactivation prompt")
        }
        try await run("reactivation-expiry-during-permission-carries-original-snapshot", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            var original = task(); original.status = .completed; original.dueAt = Date().addingTimeInterval(3)
            repository.addTask(original)
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.holdNextAuthorization(gate); defer { gate.open() }
            var value = original; value.status = .active
            let candidate = value
            let save = Task { try await coordinator.saveTask(candidate, isNew: false, ownerId: "A", requestAuthorization: true, expectedTask: original) }
            try await backend.waitForAuthorizationRequests(1)
            try await waitUntilExpired(original.dueAt!); gate.open()
            try await expectReactivation(original) { try await save.value }
            try expect(repository.tasks(for: "A").first == original && backend.pendingSnapshot.isEmpty && backend.addAttempts == 0, "Permission wait expiry cannot save or schedule an old reminder")
            try expect(backend.authorizationRequests == 1, "Only the initially valid explicit permission request occurred")
        }
        try await run("reactivation-expiry-during-settings-does-not-open-permission", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            var original = task(); original.status = .paused; original.dueAt = Date().addingTimeInterval(3)
            repository.addTask(original)
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.holdNextSettingsRead(gate); defer { gate.open() }
            let reads = backend.settingsRequests
            var value = original; value.status = .active
            let candidate = value
            let save = Task { try await coordinator.saveTask(candidate, isNew: false, ownerId: "A", requestAuthorization: true, expectedTask: original) }
            try await backend.waitForSettingsRequests(reads + 1)
            try await waitUntilExpired(original.dueAt!); gate.open()
            try await expectReactivation(original) { try await save.value }
            try expect(repository.tasks(for: "A").first == original && backend.authorizationRequests == 0 && backend.addAttempts == 0, "An expired plan must be rejected before a new prompt")
        }
        try await run("reactivation-expiry-after-os-apply-removes-uncommitted-candidate", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            var original = task(); original.status = .cancelled; original.dueAt = Date().addingTimeInterval(3)
            repository.addTask(original)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.enqueue(.holdAfterStore(gate)); defer { gate.open() }
            let save = Task { try await coordinator.updateTaskStatus(id: original.id, ownerId: "A", status: .active) }
            try await backend.waitForAppliedAddAttempts(1)
            try expect(backend.pendingSnapshot.count == 1, "The candidate was applied before completion")
            try await waitUntilExpired(original.dueAt!); gate.open()
            try await expectReactivation(original) { try await save.value }
            try expect(repository.tasks(for: "A").first == original && backend.pendingSnapshot.isEmpty && backend.authorizationRequests == 0, "Late OS completion cannot commit a now-expired activation")
        }
        try await run("plain-reactivation-disk-failure-preserves-inactive-record", root: root) { url in
            let manager = RejectingWriteFileManager()
            let repository = AssistantLocalRepository(fileURL: url, fileManager: manager)
            var original = task(); original.status = .paused; original.dueAt = Date().addingTimeInterval(-60)
            repository.addTask(original)
            let bytes = try Data(contentsOf: url)
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            manager.rejectsDirectoryCreation = true
            do { try await coordinator.reopenTaskWithoutReminder(original, ownerId: "A"); throw CoordinatorTestFailure.assertion("Disk failure cannot report a reopened task") }
            catch AssistantReminderError.persistenceFailed { }
            try expect(repository.tasks(for: "A").first == original && Data(contentsOf: url) == bytes, "Failed CAS write preserves memory and original bytes")
            try expect(backend.authorizationRequests == 0 && backend.pendingSnapshot.isEmpty, "Failed plain recovery has no notification effects")
        }
        try await run("cas-edit-disk-failure-restores-previous-notification", root: root) { url in
            let manager = RejectingWriteFileManager()
            let repository = AssistantLocalRepository(fileURL: url, fileManager: manager)
            let original = task(); repository.addTask(original)
            let bytes = try Data(contentsOf: url)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            var edited = original; edited.dueAt = original.dueAt!.addingTimeInterval(600)
            manager.rejectsDirectoryCreation = true
            do { try await coordinator.saveTask(edited, isNew: false, ownerId: "A", requestAuthorization: false, expectedTask: original); throw CoordinatorTestFailure.assertion("Disk failure must propagate") }
            catch AssistantReminderError.persistenceFailed { }
            try expect(repository.tasks(for: "A").first == original && Data(contentsOf: url) == bytes, "CAS disk failure cannot mutate the original record")
            try expect(backend.pendingSnapshot.count == 1 && backend.authorizationRequests == 0, "Only the original notification should remain")
            try expectDelivery(backend, task: original, policy: .disabled)
        }
        try await run("cas-stale-after-applied-candidate-restores-latest-record-plan", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let original = task(); repository.addTask(original)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.enqueue(.holdAfterStore(gate)); defer { gate.open() }
            var value = original; value.dueAt = original.dueAt!.addingTimeInterval(600); value.title = "old confirmation edit"
            let candidate = value
            let save = Task { try await coordinator.saveTask(candidate, isNew: false, ownerId: "A", requestAuthorization: false, expectedTask: original) }
            try await backend.waitForAppliedAddAttempts(2)
            var updated = original; updated.dueAt = original.dueAt!.addingTimeInterval(1800); updated.title = "new committed record"
            try expect(repository.updateTask(updated), "Concurrent fixture write must succeed")
            let latest = repository.tasks(for: "A").first!
            gate.open()
            do { try await save.value; throw CoordinatorTestFailure.assertion("Stale confirmation cannot commit after an OS await") }
            catch AssistantRepositoryError.staleTask { }
            try expect(repository.tasks(for: "A").first == latest && backend.pendingSnapshot.count == 1, "Stale candidate must preserve the latest record and repair exactly its reminder")
            try expectDelivery(backend, task: latest, policy: .disabled)
        }
        try await run("cas-mainactor-final-guard-cannot-hide-snapshot-conflict", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let original = task(); repository.addTask(original)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let source = SourceValidationFixture()
            var candidate = original; candidate.dueAt = original.dueAt!.addingTimeInterval(600)
            do {
                try await coordinator.saveTask(candidate, isNew: false, ownerId: "A", requestAuthorization: false, expectedTask: original,
                    validateBeforeCommit: {
                        try source.validate()
                        if source.calls == 2 {
                            var latest = original; latest.title = "changed immediately before CAS"; latest.dueAt = original.dueAt!.addingTimeInterval(1800)
                            guard repository.updateTask(latest) else { throw CoordinatorTestFailure.injected }
                        }
                    })
                throw CoordinatorTestFailure.assertion("Final MainActor source success cannot bypass CAS")
            } catch AssistantRepositoryError.staleTask { }
            let latest = repository.tasks(for: "A").first!
            try expect(latest.title == "changed immediately before CAS" && latest.dueAt != candidate.dueAt, "The final compare-and-swap preserves concurrent data")
            try expectDelivery(backend, task: latest, policy: .disabled)
        }
        try await run("plain-reactivation-allows-unchanged-legacy-long-content-and-zone", root: root) { url in
            let originalRepository = AssistantLocalRepository(fileURL: url)
            var seed = task(); seed.status = .completed; seed.dueAt = Date().addingTimeInterval(-600); seed.sourceMessageId = "legacy-source"
            originalRepository.addTask(seed)
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            var owners = json["tasks"] as! [String: [[String: Any]]]
            owners["A"]![0]["title"] = String(repeating: "旧", count: 201)
            owners["A"]![0]["instructions"] = String(repeating: "旧", count: 20_001)
            owners["A"]![0]["timeZone"] = "No/SuchLegacyZone"
            json["tasks"] = owners
            try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
            let repository = AssistantLocalRepository(fileURL: url)
            let original = repository.tasks(for: "A").first!
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            try await coordinator.reopenTaskWithoutReminder(original, ownerId: "A")
            let stored = repository.tasks(for: "A").first!
            var expected = original; expected.status = .active; expected.reminderEnabled = false; expected.updatedAt = stored.updatedAt
            try expect(stored == expected && stored.title.count == 201 && stored.instructions?.count == 20_001, "A noncontent recovery must preserve legacy data verbatim")
            try expect(backend.authorizationRequests == 0 && backend.addAttempts == 0, "Legacy plain recovery is authorization free")
        }
        try await run("plain-reactivation-rejects-active-or-foreign-snapshots", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let active = task(); var foreign = task(owner: "B"); foreign.status = .paused
            repository.addTask(active); repository.addTask(foreign)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            do { try await coordinator.reopenTaskWithoutReminder(active, ownerId: "A"); throw CoordinatorTestFailure.assertion("Already-active records cannot use the reactivation shortcut") }
            catch AssistantRepositoryError.invalidRecord { }
            try await expectReminderError(.foreignOwner) { try await coordinator.reopenTaskWithoutReminder(foreign, ownerId: "A") }
            try expect(repository.tasks(for: "A").first == active && repository.tasks(for: "B").first == foreign && backend.pendingSnapshot.count == 1, "Rejected snapshots preserve both owners and their valid reminders")
        }
        for mutation in ["update", "delete"] {
            try await run("rollback-applied-restoration-repairs-later-" + mutation, root: root) { url in
                let repository = AssistantLocalRepository(fileURL: url)
                let original = task(); repository.addTask(original)
                let backend = FakeNotificationBackend()
                let foreign = try seedForeignReminder(backend, repository: repository)
                let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
                _ = await coordinator.activate(ownerId: "A")
                let source = SourceValidationFixture(successesAllowed: 1)
                let gate = AddGate(); backend.enqueue(.succeed); backend.enqueue(.holdAfterStore(gate)); defer { gate.open() }
                var edited = original; edited.title = "uncommitted candidate"; edited.dueAt = original.dueAt!.addingTimeInterval(600)
                let candidate = edited
                let save = Task { try await coordinator.saveTask(candidate, isNew: false, ownerId: "A", requestAuthorization: false, expectedTask: original,
                    validateBeforeCommit: { try source.validate() }) }
                try await backend.waitForAppliedAddAttempts(3)
                var latest: AssistantTask?
                if mutation == "update" {
                    var next = original; next.title = "newest committed task"; next.dueAt = original.dueAt!.addingTimeInterval(1800)
                    try expect(repository.updateTask(next), "Fixture update must succeed while restoration is suspended")
                    latest = repository.tasks(for: "A").first
                } else {
                    try expect(repository.deleteTask(id: original.id, userId: "A"), "Fixture deletion must succeed while restoration is suspended")
                }
                _ = await coordinator.reconcile(ownerId: "A")
                try expect(ownedPending(backend).isEmpty, "A changed restoration base cannot remain exempt while its callback is held")
                gate.open()
                do { try await save.value; throw CoordinatorTestFailure.assertion("Original source rejection must still propagate") }
                catch SourceValidationFailure.invalidated { }
                if let latest {
                    try expect(repository.tasks(for: "A").first == latest && ownedPending(backend).count == 1, "Late restoration must schedule only the latest committed task")
                    try expectDelivery(backend, task: latest, policy: .disabled)
                } else {
                    try expect(repository.tasks(for: "A").isEmpty && ownedPending(backend).isEmpty, "A deleted task cannot be resurrected by restoration")
                }
                try expectForeignUnchanged(backend, repository: repository, task: foreign)
            }
        }
        try await run("failing-restoration-add-repairs-newer-task-snapshot", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let original = task(); repository.addTask(original)
            let backend = FakeNotificationBackend()
            let foreign = try seedForeignReminder(backend, repository: repository)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let source = SourceValidationFixture(successesAllowed: 1)
            let gate = AddGate(); backend.enqueue(.succeed); backend.enqueue(.holdThenFail(gate)); defer { gate.open() }
            var edited = original; edited.dueAt = original.dueAt!.addingTimeInterval(600)
            let candidate = edited
            let save = Task { try await coordinator.saveTask(candidate, isNew: false, ownerId: "A", requestAuthorization: false, expectedTask: original,
                validateBeforeCommit: { try source.validate() }) }
            try await backend.waitForAddAttempts(3)
            var next = original; next.title = "new current task"; next.dueAt = original.dueAt!.addingTimeInterval(1800)
            try expect(repository.updateTask(next), "The newer snapshot must persist")
            let latest = repository.tasks(for: "A").first!
            gate.open()
            do { try await save.value; throw CoordinatorTestFailure.assertion("Restoration failure must stay visible") }
            catch AssistantReminderError.restorationFailed { }
            try expect(repository.tasks(for: "A").first == latest && ownedPending(backend).count == 1, "Even a failing old add must repair the latest snapshot")
            try expectDelivery(backend, task: latest, policy: .disabled)
            try expectForeignUnchanged(backend, repository: repository, task: foreign)
        }
        for mutation in ["update", "same-time-content", "complete", "delete"] {
            try await run("reconcile-applied-add-rechecks-base-after-" + mutation, root: root) { url in
                let repository = AssistantLocalRepository(fileURL: url)
                let original = task(); repository.addTask(original)
                let backend = FakeNotificationBackend()
                let foreign = try seedForeignReminder(backend, repository: repository)
                let gate = AddGate(); backend.enqueue(.holdAfterStore(gate)); defer { gate.open() }
                let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
                let activation = Task { await coordinator.activate(ownerId: "A") }
                try await backend.waitForAppliedAddAttempts(1)
                var latest: AssistantTask?
                if mutation == "delete" {
                    try expect(repository.deleteTask(id: original.id, userId: "A"), "Fixture deletion must succeed")
                } else {
                    var changed = original
                    switch mutation {
                    case "update": changed.title = "changed due"; changed.dueAt = original.dueAt!.addingTimeInterval(1800)
                    case "same-time-content": changed.instructions = "Changed content at the exact same delivery time"
                    default: changed.status = .completed
                    }
                    try expect(repository.updateTask(changed), "Fixture update must succeed")
                    latest = repository.tasks(for: "A").first
                }
                _ = await coordinator.reconcile(ownerId: "A")
                try expect(ownedPending(backend).isEmpty, "Changed/deleted base must revoke the in-flight exemption immediately, even at the same fire time")
                gate.open()
                let report = await activation.value
                try expect(!report.errors.isEmpty, "The stale operation cannot report a successful current schedule")
                if let latest, latest.status == .active {
                    try expect(repository.tasks(for: "A").first == latest && ownedPending(backend).count == 1, "Recovery must preserve and schedule the updated record")
                    try expectDelivery(backend, task: latest, policy: .disabled)
                } else {
                    try expect(repository.tasks(for: "A").first == latest && ownedPending(backend).isEmpty, "Completed/deleted records must have no reminder")
                }
                try expectForeignUnchanged(backend, repository: repository, task: foreign)
            }
        }
        try await run("new-task-applied-candidate-preserves-expected-absent-base", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend()
            let foreign = try seedForeignReminder(backend, repository: repository)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.enqueue(.holdAfterStore(gate)); defer { gate.open() }
            let value = task()
            let save = Task { try await coordinator.saveTask(value, isNew: true, ownerId: "A", requestAuthorization: false) }
            try await backend.waitForAppliedAddAttempts(1)
            _ = await coordinator.reconcile(ownerId: "A")
            try expect(repository.tasks(for: "A").isEmpty && ownedPending(backend).count == 1, "An unchanged expected-absent base remains a valid new-task candidate")
            gate.open(); try await save.value
            try expect(repository.tasks(for: "A").first == value && ownedPending(backend).count == 1, "The new task must commit with its original request intact")
            try expectForeignUnchanged(backend, repository: repository, task: foreign)
        }
        try await run("new-task-base-insertion-revokes-candidate-and-prevents-upsert", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend()
            let foreign = try seedForeignReminder(backend, repository: repository)
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let gate = AddGate(); backend.enqueue(.holdAfterStore(gate)); defer { gate.open() }
            let value = task()
            let save = Task { try await coordinator.saveTask(value, isNew: true, ownerId: "A", requestAuthorization: false) }
            try await backend.waitForAppliedAddAttempts(1)
            var inserted = value; inserted.title = "independently inserted record"; inserted.dueAt = value.dueAt!.addingTimeInterval(1800)
            repository.addTask(inserted)
            _ = await coordinator.reconcile(ownerId: "A")
            try expect(ownedPending(backend).isEmpty, "An absent-to-present transition invalidates the new-task exemption")
            gate.open()
            do { try await save.value; throw CoordinatorTestFailure.assertion("Late creation must not upsert over the new record") }
            catch AssistantRepositoryError.staleTask { }
            try expect(repository.tasks(for: "A").first == inserted && ownedPending(backend).count == 1, "The independently committed record wins")
            try expectDelivery(backend, task: inserted, policy: .disabled)
            try expectForeignUnchanged(backend, repository: repository, task: foreign)
        }
        try await run("continuous-task-mutations-use-bounded-repair-passes", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let original = task(); repository.addTask(original)
            let backend = FakeNotificationBackend()
            let foreign = try seedForeignReminder(backend, repository: repository)
            backend.observeAppliedAdds { request in
                guard request.content.userInfo["ownerId"] as? String == "A" else { return }
                var changed = repository.tasks(for: "A").first!
                changed.title += "!"; changed.dueAt = changed.dueAt!.addingTimeInterval(60)
                precondition(repository.updateTask(changed), "Mutation fixture must persist")
            }
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            let report = await coordinator.activate(ownerId: "A")
            backend.observeAppliedAdds(nil)
            let latest = repository.tasks(for: "A").first!
            try expect(backend.addAttempts == 3 && ownedPending(backend).isEmpty && !report.errors.isEmpty,
                "One original add and at most two extra passes must terminate with the obsolete request removed")
            try expect(latest.title == original.title + "!!!", "Every concurrent record mutation must be preserved")
            _ = await coordinator.reconcile(ownerId: "A")
            try expect(backend.addAttempts == 4 && ownedPending(backend).count == 1, "A later explicit refresh gets a new bounded repair budget and released slot")
            try expectDelivery(backend, task: latest, policy: .disabled)
            try expectForeignUnchanged(backend, repository: repository, task: foreign)
        }
        try await run("stale-repair-cannot-clear-newer-same-task-operation", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let original = task(); repository.addTask(original)
            let backend = FakeNotificationBackend()
            let foreign = try seedForeignReminder(backend, repository: repository)
            let firstGate = AddGate(); backend.enqueue(.holdAfterStore(firstGate)); defer { firstGate.open() }
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            let activation = Task { await coordinator.activate(ownerId: "A") }
            try await backend.waitForAppliedAddAttempts(1)
            var updated = original; updated.title = "current base"; updated.dueAt = original.dueAt!.addingTimeInterval(600)
            try expect(repository.updateTask(updated), "Current base fixture must persist")
            let current = repository.tasks(for: "A").first!
            let repairGate = AddGate(); backend.holdNextSettingsRead(repairGate); defer { repairGate.open() }
            let reads = backend.settingsRequests
            firstGate.open()
            try await backend.waitForSettingsRequests(reads + 1)
            let saveGate = AddGate(); backend.enqueue(.holdAfterStore(saveGate)); defer { saveGate.open() }
            var edited = current; edited.title = "newer valid operation"; edited.dueAt = current.dueAt!.addingTimeInterval(600)
            let next = edited
            let save = Task { try await coordinator.saveTask(next, isNew: false, ownerId: "A", requestAuthorization: false, expectedTask: current) }
            try await backend.waitForAppliedAddAttempts(2)
            repairGate.open(); _ = await activation.value
            _ = await coordinator.reconcile(ownerId: "A")
            try expect(ownedPending(backend).count == 1, "An older operation's defer/recovery cannot release or remove the newer UUID's candidate")
            saveGate.open(); try await save.value
            let latest = repository.tasks(for: "A").first!
            try expect(latest.title == next.title && latest.dueAt == next.dueAt && ownedPending(backend).count == 1, "The newer operation must finish normally")
            try expectDelivery(backend, task: latest, policy: .disabled)
            try expectForeignUnchanged(backend, repository: repository, task: foreign)
        }
        for mutation in ["update", "delete"] {
            try await run("failing-task-candidate-add-repairs-base-" + mutation, root: root) { url in
                let repository = AssistantLocalRepository(fileURL: url)
                let original = task(); repository.addTask(original)
                let backend = FakeNotificationBackend()
                let foreign = try seedForeignReminder(backend, repository: repository)
                let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
                _ = await coordinator.activate(ownerId: "A")
                let gate = AddGate(); backend.enqueue(.holdThenFail(gate)); defer { gate.open() }
                var edited = original; edited.dueAt = original.dueAt!.addingTimeInterval(600)
                let candidate = edited
                let save = Task { try await coordinator.saveTask(candidate, isNew: false, ownerId: "A", requestAuthorization: false, expectedTask: original) }
                try await backend.waitForAddAttempts(2)
                var latest: AssistantTask?
                if mutation == "update" {
                    var changed = original; changed.title = "new base during failing add"; changed.dueAt = original.dueAt!.addingTimeInterval(1800)
                    try expect(repository.updateTask(changed), "New base fixture must persist")
                    latest = repository.tasks(for: "A").first
                } else {
                    try expect(repository.deleteTask(id: original.id, userId: "A"), "Deleting the base fixture must succeed")
                }
                gate.open()
                do { try await save.value; throw CoordinatorTestFailure.assertion("Original OS add failure must propagate") }
                catch AssistantReminderError.schedulingFailed { }
                if let latest {
                    try expect(repository.tasks(for: "A").first == latest && ownedPending(backend).count == 1, "Failed old add still repairs the newest committed base")
                    try expectDelivery(backend, task: latest, policy: .disabled)
                } else {
                    try expect(repository.tasks(for: "A").isEmpty && ownedPending(backend).isEmpty, "A failed edit cannot retain the deleted base's old reminder")
                }
                try expectForeignUnchanged(backend, repository: repository, task: foreign)
            }
        }
        for rule in ["FREQ=DAILY", "FREQ=WEEKLY;BYDAY=MO,WE,SU"] {
            try await run("native-repeat-complete-coverage-" + (rule == "FREQ=DAILY" ? "daily" : "weekly"), root: root) { url in
                let repository = AssistantLocalRepository(fileURL: url)
                let backend = FakeNotificationBackend()
                let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
                _ = await coordinator.activate(ownerId: "A")
                var candidate = task(); candidate.recurrenceRule = rule
                try await coordinator.saveTask(candidate, isNew: true, ownerId: "A", requestAuthorization: false)
                let count = rule == "FREQ=DAILY" ? 1 : 3
                let report = await coordinator.reconcile(ownerId: "A")
                try expect(backend.pendingSnapshot.count == count && backend.pendingSnapshot.allSatisfy { ($0.trigger as? UNCalendarNotificationTrigger)?.repeats == true }, "Daily/weekly save must commit all native children")
                let coverage = report.coverageByTaskId[candidate.id]
                try expect(coverage?.scheduledCount == count && coverage?.through == nil && coverage?.repeating == true, "Native coverage is ongoing only after the full group is confirmed")
                let before = backend.addAttempts
                _ = await coordinator.reconcile(ownerId: "A")
                try expect(backend.addAttempts == before, "Native matching cannot reschedule an unchanged wall-clock plan")
                let stored = repository.tasks(for: "A").first!
                for request in backend.pendingSnapshot { backend.seed(request, delivered: true) }
                try await coordinator.updateTaskStatus(id: stored.id, ownerId: "A", status: .completed, expectedTask: stored)
                try expect(backend.pendingSnapshot.isEmpty && backend.deliveredSnapshot.isEmpty, "Completing ends and clears every child of the repeating plan")
            }
        }
        try await run("weekly-second-child-failure-restores-whole-one-shot", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let original = task(); repository.addTask(original)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let previous = repository.tasks(for: "A").first!
            var candidate = previous; candidate.recurrenceRule = "FREQ=WEEKLY;BYDAY=MO,FR"
            backend.enqueue(.succeed); backend.enqueue(.fail)
            try await expectReminderError(.schedulingFailed("ignored")) {
                do { try await coordinator.saveTask(candidate, isNew: false, ownerId: "A", requestAuthorization: false, expectedTask: previous) }
                catch AssistantReminderError.schedulingFailed { throw AssistantReminderError.schedulingFailed("ignored") }
            }
            try expect(repository.tasks(for: "A").first == previous && backend.pendingSnapshot.count == 1, "Partial weekly replacement cannot persist or retain any child")
            try expectDelivery(backend, task: previous, policy: .disabled)
        }
        try await run("rolling-fourth-child-failure-removes-new-group", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let policy = AssistantQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60, timeZoneIdentifier: "Asia/Shanghai")
            try expect(repository.setQuietHours(policy, for: "A"), "Fixture policy must persist")
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            var candidate = task(); candidate.recurrenceRule = "FREQ=DAILY"
            backend.enqueue(.succeed); backend.enqueue(.succeed); backend.enqueue(.succeed); backend.enqueue(.fail)
            do { try await coordinator.saveTask(candidate, isNew: true, ownerId: "A", requestAuthorization: false); throw CoordinatorTestFailure.assertion("Expected fourth child failure") }
            catch AssistantReminderError.schedulingFailed { }
            try expect(repository.tasks(for: "A").isEmpty && backend.pendingSnapshot.isEmpty && backend.addAttempts == 4, "Failed new batch leaves no task or successful child")
        }
        try await run("rolling-cancel-after-middle-apply-removes-whole-group", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            try expect(repository.setQuietHours(AssistantQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60, timeZoneIdentifier: "Asia/Shanghai"), for: "A"), "Fixture policy must persist")
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            var candidate = task(); candidate.recurrenceRule = "FREQ=DAILY"
            let value = candidate
            let gate = AddGate(); defer { gate.open() }
            backend.enqueue(.succeed); backend.enqueue(.succeed); backend.enqueue(.succeed); backend.enqueue(.holdAfterStore(gate))
            let save = Task { try await coordinator.saveTask(value, isNew: true, ownerId: "A", requestAuthorization: false) }
            try await backend.waitForAppliedAddAttempts(4)
            save.cancel(); gate.open()
            try await expectReminderError(.inactiveSession) { try await save.value }
            try expect(repository.tasks(for: "A").isEmpty && backend.pendingSnapshot.isEmpty, "Cancelled batch removes every successful child and never commits")
        }
        try await run("weekly-late-child-after-delete-cannot-resurrect", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            var original = task(); original.recurrenceRule = "FREQ=WEEKLY;BYDAY=MO,FR"; repository.addTask(original)
            let backend = FakeNotificationBackend()
            let gate = AddGate(); backend.enqueue(.hold(gate)); defer { gate.open() }
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            let activation = Task { await coordinator.activate(ownerId: "A") }
            try await backend.waitForAddAttempts(1)
            try expect(repository.deleteTask(id: original.id, userId: "A"), "Concurrent delete fixture must persist")
            gate.open(); let report = await activation.value
            try expect(repository.tasks(for: "A").isEmpty && backend.pendingSnapshot.isEmpty && report.coverageByTaskId.isEmpty, "Deleted weekly base cannot survive a late child")
        }
        try await run("weekly-continuous-mutations-keep-bounded-repair", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            var original = task(); original.recurrenceRule = "FREQ=WEEKLY;BYDAY=MO,FR"; repository.addTask(original)
            let backend = FakeNotificationBackend()
            backend.observeAppliedAdds { _ in
                var changed = repository.tasks(for: "A").first!; changed.title += "!"
                precondition(repository.updateTask(changed))
            }
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            let report = await coordinator.activate(ownerId: "A")
            backend.observeAppliedAdds(nil)
            try expect(backend.addAttempts == 3 && backend.pendingSnapshot.isEmpty && report.coverageByTaskId.isEmpty && !report.errors.isEmpty, "Original plus at most two repairs cannot falsely claim partial weekly coverage")
        }
        try await run("whole-batch-capacity-precedes-authorization", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let backend = FakeNotificationBackend(status: .notDetermined, alertsEnabled: false)
            for index in 0..<26 {
                backend.seed(UNNotificationRequest(identifier: AssistantReminderPolicy.namespace + "other-feature." + String(index), content: UNMutableNotificationContent(), trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)))
            }
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            var candidate = task(); candidate.recurrenceRule = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR,SA,SU"
            try await expectReminderError(.pendingLimit) { try await coordinator.saveTask(candidate, isNew: true, ownerId: "A", requestAuthorization: true) }
            try expect(backend.addAttempts == 0 && backend.authorizationRequests == 0 && backend.pendingSnapshot.count == 26 && repository.tasks(for: "A").isEmpty, "Seven-child capacity is atomic before any authorization or add")
        }
        try await run("rolling-to-native-migration-and-status-clean-all-children", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let policy = AssistantQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60, timeZoneIdentifier: "Asia/Shanghai")
            try expect(repository.setQuietHours(policy, for: "A"), "Fixture policy must persist")
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            var candidate = task(); candidate.recurrenceRule = "FREQ=DAILY"
            try await coordinator.saveTask(candidate, isNew: true, ownerId: "A", requestAuthorization: false)
            let rolling = await coordinator.reconcile(ownerId: "A")
            try expect(backend.pendingSnapshot.count == 7 && rolling.coverageByTaskId[candidate.id]?.scheduledCount == 7 && rolling.coverageByTaskId[candidate.id]?.through != nil, "Rolling queue has finite complete coverage")
            let migrated = try await coordinator.saveQuietHours(.disabled, ownerId: "A")
            try expect(backend.pendingSnapshot.count == 1 && backend.pendingSnapshot[0].identifier.hasSuffix(".daily") && migrated.coverageByTaskId[candidate.id]?.through == nil, "Disabling quiet removes every old rolling child and installs native ongoing repeat")
            let stored = repository.tasks(for: "A").first!
            try await coordinator.updateTaskStatus(id: stored.id, ownerId: "A", status: .paused, expectedTask: stored)
            try expect(backend.pendingSnapshot.isEmpty, "Pause clears native children")
            let paused = repository.tasks(for: "A").first!
            try await coordinator.updateTaskStatus(id: paused.id, ownerId: "A", status: .active, expectedTask: paused)
            try expect(backend.pendingSnapshot.count == 1, "Resume starts a fresh native group")
            try await coordinator.deleteTask(id: stored.id, ownerId: "A")
            try expect(backend.pendingSnapshot.isEmpty && repository.tasks(for: "A").isEmpty, "Delete clears the complete group")
        }
        try await run("extra-native-calendar-constraint-is-replaced", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            var candidate = task(); candidate.recurrenceRule = "FREQ=DAILY"; repository.addTask(candidate)
            let stored = repository.tasks(for: "A").first!
            let plan = try AssistantReminderPolicy.plans(for: stored, ownerId: "A")[0]
            var components = plan.dateComponents; components.quarter = 1
            let content = UNMutableNotificationContent()
            content.userInfo = ["ownerId": "A", "taskId": stored.id, "timeZone": stored.timeZone, "recurrenceIdentity": plan.recurrenceIdentity!]
            let backend = FakeNotificationBackend()
            backend.seed(UNNotificationRequest(identifier: plan.identifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)))
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            let report = await coordinator.activate(ownerId: "A")
            let actual = (backend.pendingSnapshot.first?.trigger as? UNCalendarNotificationTrigger)?.dateComponents
            try expect(actual?.quarter == nil && backend.addAttempts == 1 && report.coverageByTaskId[stored.id] != nil, "A native request with hidden calendar constraints is never accepted as an ongoing complete group")
        }
        try await run("unrelated-task-add-failure-does-not-mask-target-restoration", root: root) { url in
            let repository = AssistantLocalRepository(fileURL: url)
            let original = task("repair-A"); repository.addTask(original)
            let backend = FakeNotificationBackend()
            let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
            _ = await coordinator.activate(ownerId: "A")
            let previous = repository.tasks(for: "A").first!
            var unrelated = task("repair-B"); unrelated.dueAt = original.dueAt!.addingTimeInterval(3600); repository.addTask(unrelated)
            var candidate = previous; candidate.dueAt = previous.dueAt!.addingTimeInterval(1800)
            backend.enqueue(.fail); backend.enqueue(.fail)
            do { try await coordinator.saveTask(candidate, isNew: false, ownerId: "A", requestAuthorization: false, expectedTask: previous); throw CoordinatorTestFailure.assertion("Expected candidate failure") }
            catch AssistantReminderError.schedulingFailed { }
            try expectDelivery(backend, task: previous, policy: .disabled)
            try expect(repository.tasks(for: "A").first(where: { $0.id == previous.id }) == previous, "Another task's failure cannot claim the target's original reminder was not restored")
        }
        for pendingStillFuture in [true, false] {
            try await run("quiet-edit-origin-" + (pendingStillFuture ? "inherits-unmatured" : "never-replays-matured"), root: root) { url in
                let initial = AssistantLocalRepository(fileURL: url)
                var candidate = task(); candidate.recurrenceRule = "FREQ=DAILY"
                var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
                candidate.dueAt = utc.date(from: utc.dateComponents([.year, .month, .day, .hour, .minute], from: Date().addingTimeInterval(pendingStillFuture ? -600 : -3600)))!
                initial.addTask(candidate)
                let oldPolicy = quiet(around: candidate.dueAt!, endOffset: pendingStillFuture ? 120 : 50)
                try expect(initial.setQuietHours(oldPolicy, for: "A"), "Old quiet fixture must persist")
                var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                var owners = json["tasks"] as! [String: [[String: Any]]]
                owners["A"]![0]["recurrenceStartsAt"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 86_400))
                json["tasks"] = owners
                try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
                let repository = AssistantLocalRepository(fileURL: url)
                let stored = repository.tasks(for: "A").first!
                let origin = stored.dueAt!
                let identifier = AssistantReminderPolicy.identifier(ownerId: "A", taskId: stored.id) + ".occurrence." + String(Int64(origin.timeIntervalSince1970.rounded()))
                let oldPlan = AssistantReminderPlan(identifier: identifier, ownerId: "A", taskId: stored.id, fireAt: try oldPolicy.deliveryDate(for: origin), timeZoneIdentifier: stored.timeZone,
                    recurrenceIdentity: try AssistantReminderPolicy.recurrenceIdentity(for: stored))
                let content = UNMutableNotificationContent()
                content.userInfo = ["ownerId": "A", "taskId": stored.id, "timeZone": stored.timeZone, "recurrenceIdentity": oldPlan.recurrenceIdentity!]
                let request = UNNotificationRequest(identifier: identifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: oldPlan.dateComponents, repeats: false))
                let backend = FakeNotificationBackend(); backend.seed(request)
                let coordinator = AssistantReminderCoordinator(backend: backend, repository: repository)
                _ = await coordinator.activate(ownerId: "A")
                if !pendingStillFuture { backend.seed(request) } // A stale OS pending snapshot must not replay a matured occurrence.
                let newPolicy = quiet(around: origin, endOffset: 180)
                let report = try await coordinator.saveQuietHours(newPolicy, ownerId: "A")
                let inherited = backend.pendingSnapshot.first(where: { $0.identifier == identifier })
                if pendingStillFuture {
                    let actual = (inherited?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                    try expect(actual.map { abs($0.timeIntervalSince(try! newPolicy.deliveryDate(for: origin))) < 1.1 } == true, "Only a still-pending original may move to the new quiet end")
                    let effective = try repository.quietHoursEffectiveAt(for: "A")
                    let count = backend.addAttempts
                    _ = try await coordinator.saveQuietHours(newPolicy, ownerId: "A")
                    try expect(try repository.quietHoursEffectiveAt(for: "A") == effective, "Same-value quiet save preserves the original effective time")
                    try expect(backend.addAttempts == count, "Same-value quiet save does not restart an already complete rolling queue")
                } else {
                    try expect(inherited == nil, "A matured original cannot return merely because the new quiet end lies in the future")
                }
                try expect(backend.pendingSnapshot.count == 7 && report.coverageByTaskId[stored.id]?.scheduledCount == 7, "Both quiet edits retain exactly a complete seven-child queue")
            }
        }
        try await run("recurring-first-origin-crossed-before-commit-is-atomic", root: root) { url in
            let directory = url.deletingLastPathComponent()
            let newRepository = AssistantLocalRepository(fileURL: url)
            let existingRepository = AssistantLocalRepository(fileURL: directory.appendingPathComponent("existing.json"))
            let newBackend = FakeNotificationBackend(), existingBackend = FakeNotificationBackend()
            let origin = Date(timeIntervalSince1970: ceil((Date().timeIntervalSince1970 + 2) / 60) * 60)
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
            let fields = calendar.dateComponents([.hour, .minute], from: origin)
            let minute = fields.hour! * 60 + fields.minute!
            let policy = AssistantQuietHours(enabled: true, startMinute: (minute + 1439) % 1440, endMinute: (minute + 10) % 1440, timeZoneIdentifier: "UTC")
            try expect(newRepository.setQuietHours(policy, for: "A") && existingRepository.setQuietHours(policy, for: "A"), "Quiet fixtures must persist")
            let original = task("existing-one-shot"); existingRepository.addTask(original)
            let previous = existingRepository.tasks(for: "A").first!
            let newCoordinator = AssistantReminderCoordinator(backend: newBackend, repository: newRepository)
            let existingCoordinator = AssistantReminderCoordinator(backend: existingBackend, repository: existingRepository)
            _ = await newCoordinator.activate(ownerId: "A"); _ = await existingCoordinator.activate(ownerId: "A")
            var newCandidate = task("new-daily"); newCandidate.timeZone = "UTC"; newCandidate.dueAt = origin; newCandidate.recurrenceRule = "FREQ=DAILY"
            var converted = previous; converted.timeZone = "UTC"; converted.dueAt = origin; converted.recurrenceRule = "FREQ=DAILY"
            let fresh = newCandidate, replacement = converted
            let gate = AddGate(); defer { gate.open() }
            newBackend.enqueue(.hold(gate)); existingBackend.enqueue(.hold(gate))
            let newSave = Task { try await newCoordinator.saveTask(fresh, isNew: true, ownerId: "A", requestAuthorization: false) }
            let conversion = Task { try await existingCoordinator.saveTask(replacement, isNew: false, ownerId: "A", requestAuthorization: false, expectedTask: previous) }
            try await newBackend.waitForAddAttempts(1); try await existingBackend.waitForAddAttempts(2)
            let wait = max(0, origin.timeIntervalSinceNow + 0.2)
            try expect(wait < 63, "The boundary regression waits at most one minute plus the safety margin")
            print("WAIT recurring atomic boundary \(ISO8601DateFormatter().string(from: origin)) (fake add only)")
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64((wait * 1_000_000_000).rounded(.up))) }
            gate.open()
            do { try await newSave.value; throw CoordinatorTestFailure.assertion("New repeat cannot commit an origin before actual activation") }
            catch AssistantRepositoryError.recurrenceActivationElapsed { }
            do { try await conversion.value; throw CoordinatorTestFailure.assertion("A converted repeat cannot commit an origin before actual activation") }
            catch AssistantRepositoryError.recurrenceActivationElapsed { }
            try expect(newRepository.tasks(for: "A").isEmpty && newBackend.pendingSnapshot.isEmpty, "New creation rolls back the complete candidate group")
            try expect(existingRepository.tasks(for: "A").first == previous && existingBackend.pendingSnapshot.count == 1, "Conversion preserves the full old record and restores its one-shot")
            try expectDelivery(existingBackend, task: previous, policy: policy)
            try expect(newBackend.authorizationRequests == 0 && existingBackend.authorizationRequests == 0, "Atomic boundary repair never authorizes or invokes real notifications")
        }
        try await rawOwnerTests(root: root)
        print("All \(suiteCount) AssistantReminderCoordinator suites passed (fake notification backend; no OS permission requests).")
    }
}
