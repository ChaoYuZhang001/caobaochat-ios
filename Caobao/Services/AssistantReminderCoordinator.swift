import Foundation

enum AssistantReminderError: LocalizedError, Equatable {
    case invalidIdentity, foreignOwner, inactiveSession, missingDueDate, pastDueDate, invalidTimeZone
    case recurrenceUnsupported, permissionDenied, authorizationRequired, pendingLimit, operationInProgress
    case schedulingFailed(String), persistenceFailed(String), restorationFailed(String)
    case reactivationRequired(AssistantTask)
    case multiplePlans

    var errorDescription: String? {
        switch self {
        case .invalidIdentity: return AssistantLocalization.string("提醒需要有效的账号和任务标识。")
        case .foreignOwner: return AssistantLocalization.string("不能修改其他账号的任务提醒。")
        case .inactiveSession: return AssistantLocalization.string("当前账号已变化，请重新打开任务页面。")
        case .missingDueDate: return AssistantLocalization.string("请先设置到期时间，再开启提醒。")
        case .pastDueDate: return AssistantLocalization.string("提醒时间必须晚于现在；本次修改未保存。")
        case .reactivationRequired: return AssistantLocalization.string("原提醒时间已过，请选择仅恢复待办或修改提醒时间后恢复。")
        case .invalidTimeZone: return AssistantLocalization.string("任务时区无效，请重新选择到期时间。")
        case .recurrenceUnsupported: return AssistantLocalization.string("重复规则无效或暂不支持，请重新选择。")
        case .multiplePlans: return AssistantLocalization.string("此任务包含多个提醒计划，请使用完整提醒列表。")
        case .permissionDenied: return AssistantLocalization.string("系统未允许提醒通知。本次修改未保存，你可以关闭提醒后保存，或在系统设置中允许通知。")
        case .authorizationRequired: return AssistantLocalization.string("需要先在任务编辑页开启提醒并点击保存，以允许系统通知。")
        case .pendingLimit: return AssistantLocalization.string("待发送提醒已达本应用上限，请先关闭或完成部分提醒；本次修改未保存。")
        case .operationInProgress: return AssistantLocalization.string("这个任务正在保存，请稍后再试。")
        case .schedulingFailed: return AssistantLocalization.string("系统未能安排提醒，本次修改未保存，请稍后重试。")
        case .persistenceFailed(let message): return message
        case .restorationFailed: return AssistantLocalization.string("任务未保存，旧提醒也未能恢复。请打开任务重新检查提醒状态。")
        }
    }
}

struct AssistantReminderCalendarPattern: Equatable {
    let hour: Int
    let minute: Int
    let isoWeekday: Int?
}

struct AssistantReminderPlan: Equatable {
    let identifier: String
    let ownerId: String
    let taskId: String
    let fireAt: Date
    let timeZoneIdentifier: String
    var calendarPattern: AssistantReminderCalendarPattern? = nil
    var recurrenceIdentity: String? = nil
    var repeats: Bool { calendarPattern != nil }

    var dateComponents: DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        let recordedZone = TimeZone(identifier: timeZoneIdentifier)!
        if let pattern = calendarPattern {
            calendar.timeZone = recordedZone
            var values = DateComponents(calendar: calendar, timeZone: recordedZone, hour: pattern.hour, minute: pattern.minute, second: 0)
            if let day = pattern.isoWeekday { values.weekday = day % 7 + 1 }
            return values
        }
        // Absolute one-shots keep the selected occurrence unambiguous in a fold.
        calendar.timeZone = TimeZone(secondsFromGMT: recordedZone.secondsFromGMT(for: fireAt))!
        var values = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireAt)
        values.calendar = calendar; values.timeZone = calendar.timeZone
        return values
    }
}

/// Pure local schedule projection. Limits below are application budgets, not a
/// claim about the OS's hard limits. No permissions or notifications are touched.
enum AssistantReminderPolicy {
    static let namespace = "caobao.task-reminder.v1."
    static let maximumOwnPending = 32
    static let maximumAppPending = 64
    static let rollingCount = 7

    static func ownerPrefix(_ ownerId: String) -> String { namespace + encoded(ownerId) + "." }
    static func identifier(ownerId: String, taskId: String) -> String { ownerPrefix(ownerId) + encoded(taskId) }
    static func owns(_ identifier: String, ownerId: String) -> Bool {
        !ownerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && identifier.hasPrefix(ownerPrefix(ownerId))
    }

    static func ownsTaskIdentifier(_ value: String, ownerId: String, taskId: String) -> Bool {
        let base = identifier(ownerId: ownerId, taskId: taskId)
        guard !ownerId.isEmpty, !taskId.isEmpty else { return false }
        if value == base { return true }
        guard value.hasPrefix(base + ".") else { return false }
        let suffix = String(value.dropFirst(base.count + 1))
        if suffix == "daily" { return true }
        if suffix.hasPrefix("weekday.") {
            let raw = String(suffix.dropFirst(8))
            return Int(raw).map { (1...7).contains($0) && String($0) == raw } ?? false
        }
        if suffix.hasPrefix("occurrence.") {
            let raw = String(suffix.dropFirst(11))
            return Int64(raw).map { String($0) == raw } ?? false
        }
        return false
    }

    static func plans(for task: AssistantTask, ownerId: String, now: Date = Date(),
                      quietHours: AssistantQuietHours = .disabled, notBefore: Date? = nil,
                      inheritedOrigins: [Date] = []) throws -> [AssistantReminderPlan] {
        guard !ownerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !task.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantReminderError.invalidIdentity }
        guard AssistantOwnerIdentity.matches(task.userId, ownerId) else { throw AssistantReminderError.foreignOwner }
        guard task.reminderEnabled == true, task.status == .active else { return [] }
        guard let due = task.dueAt else { throw AssistantReminderError.missingDueDate }
        guard let zone = TimeZone(identifier: task.timeZone) else { throw AssistantReminderError.invalidTimeZone }
        let recurrence: AssistantTaskRecurrence
        do { recurrence = try .parse(task.recurrenceRule) } catch { throw AssistantReminderError.recurrenceUnsupported }
        let base = identifier(ownerId: ownerId, taskId: task.id)
        guard recurrence.isRepeating else {
            let fire = try quietHours.deliveryDate(for: due)
            guard fire.timeIntervalSince(now) >= 1 else { throw AssistantReminderError.pastDueDate }
            return [AssistantReminderPlan(identifier: base, ownerId: ownerId, taskId: task.id, fireAt: fire, timeZoneIdentifier: task.timeZone)]
        }
        try quietHours.validated()
        let identity = try recurrenceIdentity(for: task)
        // New origins never predate activation or a new quiet policy. A caller may
        // separately inherit an exact, still-unmatured pending origin from the old
        // policy; changing the quiet end cannot replay already matured delivery.
        let activation = task.recurrenceStartsAt ?? now
        let lowerBound = max(activation, notBefore ?? activation)
        if quietHours.enabled {
            let lookback = now.addingTimeInterval(-8 * 86_400)
            let generated = try recurrence.nextOccurrences(after: max(lookback, lowerBound), time: due, timeZoneIdentifier: task.timeZone, limit: 32)
            let inherited = try inheritedOrigins.filter { original in
                guard original >= lookback, task.recurrenceStartsAt.map({ original > $0 }) ?? true else { return false }
                return try recurrence.nextOccurrences(after: original.addingTimeInterval(-1), time: due, timeZoneIdentifier: task.timeZone, limit: 1).first == original
            }
            let originals = Array(Set(generated + inherited).sorted().prefix(32))
            var seen = Set<Date>(), values: [AssistantReminderPlan] = []
            for original in originals {
                let fire = try quietHours.deliveryDate(for: original)
                guard fire.timeIntervalSince(now) >= 1, seen.insert(fire).inserted else { continue }
                let stamp = String(Int64(original.timeIntervalSince1970.rounded()))
                values.append(AssistantReminderPlan(identifier: base + ".occurrence." + stamp, ownerId: ownerId, taskId: task.id, fireAt: fire, timeZoneIdentifier: task.timeZone,
                    recurrenceIdentity: identity))
            }
            return Array(values.sorted { $0.fireAt < $1.fireAt }.prefix(rollingCount))
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let clock = calendar.dateComponents([.hour, .minute], from: due)
        guard let hour = clock.hour, let minute = clock.minute else { throw AssistantReminderError.invalidTimeZone }
        let days: [Int?]
        switch recurrence {
        case .daily: days = [nil]
        case .weekly(let selected): days = selected.sorted().map(Optional.some)
        case .none: days = []
        }
        return try days.map { day in
            let rule: AssistantTaskRecurrence = day.map { .weekly(Set([$0])) } ?? .daily
            guard let fire = try rule.nextOccurrences(after: max(now, lowerBound), time: due, timeZoneIdentifier: task.timeZone, limit: 1).first else { throw AssistantReminderError.pastDueDate }
            let suffix = day.map { ".weekday." + String($0) } ?? ".daily"
            return AssistantReminderPlan(identifier: base + suffix, ownerId: ownerId, taskId: task.id, fireAt: fire, timeZoneIdentifier: task.timeZone,
                calendarPattern: AssistantReminderCalendarPattern(hour: hour, minute: minute, isoWeekday: day), recurrenceIdentity: identity)
        }
    }

    static func recurrenceIdentity(for task: AssistantTask) throws -> String? {
        let recurrence: AssistantTaskRecurrence
        do { recurrence = try .parse(task.recurrenceRule) } catch { throw AssistantReminderError.recurrenceUnsupported }
        guard recurrence.isRepeating else { return nil }
        guard let due = task.dueAt else { throw AssistantReminderError.missingDueDate }
        guard let zone = TimeZone(identifier: task.timeZone) else { throw AssistantReminderError.invalidTimeZone }
        _ = try recurrence.nextOccurrences(after: due, time: due, timeZoneIdentifier: task.timeZone, limit: 0)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let values = calendar.dateComponents([.hour, .minute], from: due)
        guard let rule = recurrence.canonicalRule, let hour = values.hour, let minute = values.minute else { throw AssistantReminderError.invalidTimeZone }
        return [rule, task.timeZone, String(hour), String(minute)].joined(separator: "|")
    }

    static func occurrenceOrigin(identifier value: String, ownerId: String, taskId: String) -> Date? {
        let prefix = identifier(ownerId: ownerId, taskId: taskId) + ".occurrence."
        guard value.hasPrefix(prefix), ownsTaskIdentifier(value, ownerId: ownerId, taskId: taskId),
              let stamp = Int64(value.dropFirst(prefix.count)) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(stamp))
    }

    static func plan(for task: AssistantTask, ownerId: String, now: Date = Date(),
                     quietHours: AssistantQuietHours = .disabled) throws -> AssistantReminderPlan? {
        let values = try plans(for: task, ownerId: ownerId, now: now, quietHours: quietHours)
        guard values.count <= 1 else { throw AssistantReminderError.multiplePlans }
        return values.first
    }

    static func checkCapacity(for identifier: String, pendingIdentifiers: [String]) throws {
        let other = Set(pendingIdentifiers).subtracting([identifier])
        guard other.count + 1 <= maximumAppPending, other.filter({ $0.hasPrefix(namespace) }).count + 1 <= maximumOwnPending else { throw AssistantReminderError.pendingLimit }
    }

    static func checkCapacity(for identifiers: Set<String>, replacingTaskId: String, ownerId: String, pendingIdentifiers: [String]) throws {
        let other = Set(pendingIdentifiers).filter { !ownsTaskIdentifier($0, ownerId: ownerId, taskId: replacingTaskId) }
        let total = other.union(identifiers)
        guard total.count <= maximumAppPending, total.filter({ $0.hasPrefix(namespace) }).count <= maximumOwnPending else { throw AssistantReminderError.pendingLimit }
    }

    private static func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
}

enum AssistantReminderState: Equatable {
    case notEnabled, inactive, pastDue, scheduled, notScheduled, permissionRequired
    case failed(String)

    var localizedDescription: String {
        switch self {
        case .notEnabled: return AssistantLocalization.string("未开启提醒")
        case .inactive: return AssistantLocalization.string("任务未在处理，提醒已停用")
        case .pastDue: return AssistantLocalization.string("提醒时间已过；请在系统通知中心查看，无法保证送达")
        case .scheduled: return AssistantLocalization.string("已交给系统安排提醒，送达取决于系统设置")
        case .notScheduled: return AssistantLocalization.string("已开启但尚未安排提醒")
        case .permissionRequired: return AssistantLocalization.string("已开启提醒，但系统通知权限未允许")
        case .failed(let text): return text
        }
    }
}

struct AssistantReminderCoverage: Equatable {
    let nextFireAt: Date
    let through: Date?
    let scheduledCount: Int
    let repeating: Bool
}

struct AssistantReminderReconciliationReport {
    var statesByTaskId: [String: AssistantReminderState] = [:]
    var coverageByTaskId: [String: AssistantReminderCoverage] = [:]
    var errors: [String] = []
    var schedulingFailedTaskIds: Set<String> = []
}

#if canImport(UserNotifications) && !ASSISTANT_REMINDER_POLICY_ONLY
import UserNotifications

enum AssistantReminderAuthorizationStatus {
    case notDetermined, denied, authorized, provisional, ephemeral, unknown
}

struct AssistantReminderNotificationSettings {
    let authorizationStatus: AssistantReminderAuthorizationStatus
    let alertsEnabled: Bool
}

/// The actor owns policy and persistence; this boundary only performs OS effects.
/// Tests inject a fake without instantiating a system notification center.
protocol AssistantReminderNotificationBackend: AnyObject {
    func notificationSettings() async -> AssistantReminderNotificationSettings
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func deliveredNotificationIdentifiers() async -> [String]
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

final class AssistantNativeReminderNotificationBackend: AssistantReminderNotificationBackend {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter) { self.center = center }

    func notificationSettings() async -> AssistantReminderNotificationSettings {
        let settings = await center.notificationSettings()
        let status: AssistantReminderAuthorizationStatus
        switch settings.authorizationStatus {
        case .notDetermined: status = .notDetermined
        case .denied: status = .denied
        case .authorized: status = .authorized
        case .provisional: status = .provisional
        case .ephemeral: status = .ephemeral
        @unknown default: status = .unknown
        }
        return AssistantReminderNotificationSettings(authorizationStatus: status, alertsEnabled: settings.alertSetting == .enabled)
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await center.pendingNotificationRequests()
    }

    func deliveredNotificationIdentifiers() async -> [String] {
        await center.deliveredNotifications().map { $0.request.identifier }
    }

    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Serializes app-owned reminder operations. Reconciliation never requests permission.
actor AssistantReminderCoordinator {
    static let shared = AssistantReminderCoordinator()
    private let center: AssistantReminderNotificationBackend
    private let repository: AssistantLocalRepository
    private var activeOwnerId: String?
    private var sessionVersion = 0
    private var inFlightTaskIds: [String: UUID] = [:]
    private var schedulingIdentifiers: [String: UUID] = [:]
    private var quietHoursVersions: [String: UInt64] = [:]
    private var inFlightSchedules: [String: InFlightSchedule] = [:]
    private var sourceCommitPermits: [UUID: SourceCommitPermit] = [:]
    private var legacyRecurrenceStarts: [String: (identity: String, date: Date)] = [:]
    private var legacyQuietStarts: [String: (policy: AssistantQuietHours, date: Date)] = [:]

    private final class SourceCommitPermit: @unchecked Sendable {
        let ownerId: String
        private let lock = NSLock()
        private var failure: AssistantReminderError?
        init(ownerId: String) { self.ownerId = ownerId }
        func invalidate(_ reason: AssistantReminderError) { lock.lock(); defer { lock.unlock() }; if failure == nil { failure = reason } }
        func commit(_ body: () throws -> Void) throws { lock.lock(); defer { lock.unlock() }; if let failure { throw failure }; try body() }
    }
    private final class CommitState: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: AssistantTask?
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func record(_ task: AssistantTask) { lock.lock(); snapshot = task; lock.unlock() }
        func matches(_ task: AssistantTask?) -> Bool { lock.lock(); defer { lock.unlock() }; return snapshot != nil && snapshot == task }
    }
    private struct QuietHoursSnapshot: Equatable { let policy: AssistantQuietHours; let version: UInt64; let effectiveAt: Date? }
    private struct Batch {
        let ownerId: String; let taskId: String; let operationId: UUID; let version: Int
        let quiet: QuietHoursSnapshot; let baseTask: AssistantTask?; let plans: [AssistantReminderPlan]
        let state: CommitState; let repairingCancelledOperation: Bool
        var key: String { AssistantReminderPolicy.identifier(ownerId: ownerId, taskId: taskId) }
    }
    private struct InFlightSchedule { let batch: Batch; let plan: AssistantReminderPlan }

    init(center: UNUserNotificationCenter = .current(), repository: AssistantLocalRepository = .shared) {
        self.center = AssistantNativeReminderNotificationBackend(center: center); self.repository = repository
    }
    init(backend: AssistantReminderNotificationBackend, repository: AssistantLocalRepository) { self.center = backend; self.repository = repository }

    @discardableResult
    func activate(ownerId: String) async -> AssistantReminderReconciliationReport {
        guard !Task.isCancelled, !ownerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AssistantReminderReconciliationReport(errors: [AssistantReminderError.invalidIdentity.localizedDescription])
        }
        if !AssistantOwnerIdentity.matches(activeOwnerId, ownerId) {
            let previous = activeOwnerId
            if let previous { invalidateSourceCommits(ownerId: previous, reason: .inactiveSession) }
            sessionVersion += 1; activeOwnerId = ownerId
            legacyQuietStarts.removeValue(forKey: AssistantOwnerIdentity.ownerKey(ownerId))
            legacyRecurrenceStarts = legacyRecurrenceStarts.filter { !AssistantReminderPolicy.owns($0.key, ownerId: ownerId) }
            if let previous { await removeRequests(for: previous) }
        }
        return await reconcile(ownerId: ownerId)
    }
    @discardableResult
    func reconcile(ownerId: String) async -> AssistantReminderReconciliationReport { await reconcile(ownerId: ownerId, repairingCancelledOperation: false) }

    @discardableResult
    func saveQuietHours(_ policy: AssistantQuietHours, ownerId: String) async throws -> AssistantReminderReconciliationReport {
        try requireCurrent(ownerId, sessionVersion); try policy.validated()
        if try repository.quietHours(for: ownerId) == policy {
            return await reconcile(ownerId: ownerId)
        }
        invalidateSourceCommits(ownerId: ownerId, reason: .operationInProgress)
        guard repository.setQuietHours(policy, for: ownerId) else { throw persistenceError() }
        quietHoursVersions[AssistantOwnerIdentity.ownerKey(ownerId), default: 0] &+= 1
        var report = await reconcile(ownerId: ownerId, repairingCancelledOperation: true)
        if Task.isCancelled { report.errors.append(CancellationError().localizedDescription) }
        return report
    }

    private func reconcile(ownerId: String, repairingCancelledOperation: Bool, remainingRepairs: Int = 2) async -> AssistantReminderReconciliationReport {
        var report = AssistantReminderReconciliationReport()
        let version = sessionVersion
        guard isCurrent(ownerId, version), repairingCancelledOperation || !Task.isCancelled else { report.errors = [AssistantReminderError.inactiveSession.localizedDescription]; return report }
        let quiet: QuietHoursSnapshot
        do { quiet = try quietSnapshot(for: ownerId) } catch { report.errors.append(error.localizedDescription); return report }
        let settings = await center.notificationSettings()
        var pending = await center.pendingNotificationRequests()
        guard isCurrent(ownerId, version, quiet: quiet), repairingCancelledOperation || !Task.isCancelled else { report.errors.append(AssistantReminderError.operationInProgress.localizedDescription); return report }
        let tasks = repository.tasks(for: ownerId)
        if let error = repository.lastError { report.errors.append(error.localizedDescription) }
        let permitted = allowsAlerts(settings)
        var groups: [String: [AssistantReminderPlan]] = [:]
        for task in tasks {
            do {
                let values = try projectedPlans(for: task, ownerId: ownerId, quiet: quiet, pending: pending)
                groups[task.id] = values
                report.statesByTaskId[task.id] = values.isEmpty ? (task.reminderEnabled == true ? .inactive : .notEnabled) : (permitted ? .notScheduled : .permissionRequired)
            } catch AssistantReminderError.pastDueDate { report.statesByTaskId[task.id] = .pastDue }
            catch { report.statesByTaskId[task.id] = .failed(error.localizedDescription); report.errors.append(error.localizedDescription) }
        }
        let desired = Dictionary(uniqueKeysWithValues: (permitted ? groups.values.flatMap { $0 } : []).map { ($0.identifier, $0) })
        let stale = pending.filter { request in
            guard recognizedRequest(request, ownerId: ownerId) else { return false }
            if registeredSchedule(request, ownerId: ownerId) != nil, !validInFlight(request, ownerId: ownerId, quiet: quiet) { return true }
            if let plan = desired[request.identifier], matches(request, plan: plan) { return false }
            return !(permitted && validInFlight(request, ownerId: ownerId, quiet: quiet))
        }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: stale); pending.removeAll { stale.contains($0.identifier) }
        guard permitted else { return report }
        let ordered = tasks.sorted { (groups[$0.id]?.first?.fireAt ?? .distantFuture) < (groups[$1.id]?.first?.fireAt ?? .distantFuture) }
        for task in ordered {
            guard isCurrent(ownerId, version, quiet: quiet), repairingCancelledOperation || !Task.isCancelled else { report.errors.append(AssistantReminderError.operationInProgress.localizedDescription); break }
            guard let plans = groups[task.id], !plans.isEmpty else { continue }
            let key = AssistantReminderPolicy.identifier(ownerId: ownerId, taskId: task.id)
            if inFlightTaskIds[key] != nil {
                report.statesByTaskId[task.id] = .failed(AssistantReminderError.operationInProgress.localizedDescription); report.errors.append(AssistantReminderError.operationInProgress.localizedDescription); continue
            }
            guard repository.tasks(for: ownerId).first(where: { $0.id == task.id }) == task else {
                report.statesByTaskId[task.id] = .notScheduled; report.errors.append(AssistantRepositoryError.staleTask.localizedDescription); continue
            }
            if let value = coverage(task: task, plans: plans, pending: pending) { report.statesByTaskId[task.id] = .scheduled; report.coverageByTaskId[task.id] = value; continue }
            let operation = UUID(); inFlightTaskIds[key] = operation
            let batch = Batch(ownerId: ownerId, taskId: task.id, operationId: operation, version: version, quiet: quiet, baseTask: task, plans: plans, state: CommitState(), repairingCancelledOperation: repairingCancelledOperation)
            defer { release(ownerId: ownerId, taskId: task.id, operationId: operation) }
            do {
                pending = try await addBatch(batch, pending: pending)
                guard let value = coverage(task: task, plans: plans, pending: pending) else { throw AssistantReminderError.schedulingFailed("Incomplete batch") }
                report.statesByTaskId[task.id] = .scheduled; report.coverageByTaskId[task.id] = value
            } catch {
                let changed = !batchIsCurrent(batch) || (!repairingCancelledOperation && Task.isCancelled)
                if case AssistantReminderError.schedulingFailed = error { report.schedulingFailedTaskIds.insert(task.id) }
                _ = await cleanupOperation(batch)
                if changed { _ = await repair(batch, remainingRepairs: remainingRepairs) }
                report.statesByTaskId[task.id] = .failed(error.localizedDescription); report.coverageByTaskId.removeValue(forKey: task.id); report.errors.append(error.localizedDescription)
                pending = await center.pendingNotificationRequests()
            }
        }
        if !isCurrent(ownerId, version, quiet: quiet) {
            report.coverageByTaskId.removeAll()
            for id in report.statesByTaskId.keys where report.statesByTaskId[id] == .scheduled { report.statesByTaskId[id] = .notScheduled }
        }
        return report
    }

    func saveTask(_ task: AssistantTask, isNew: Bool, ownerId: String, requestAuthorization: Bool,
                  expectedTask: AssistantTask? = nil, validateBeforeCommit: (@MainActor () throws -> Void)? = nil) async throws {
        let version = sessionVersion
        let saveStartedAt = Date()
        try requireCurrent(ownerId, version)
        guard AssistantOwnerIdentity.matches(task.userId, ownerId) else { throw AssistantReminderError.foreignOwner }
        let key = AssistantReminderPolicy.identifier(ownerId: ownerId, taskId: task.id)
        guard inFlightTaskIds[key] == nil else { throw AssistantReminderError.operationInProgress }
        let operation = UUID(); inFlightTaskIds[key] = operation
        defer { release(ownerId: ownerId, taskId: task.id, operationId: operation) }
        let previous = repository.tasks(for: ownerId).first { $0.id == task.id }
        guard isNew ? previous == nil : previous != nil else { throw AssistantReminderError.persistenceFailed(AssistantRepositoryError.recordNotFound.localizedDescription) }
        if let expectedTask { guard !isNew else { throw AssistantRepositoryError.invalidRecord }; try Self.validateExpectedTask(expectedTask, candidate: task, repository: repository) }
        if isNew || previous?.title != task.title || previous?.instructions != task.instructions { try AssistantWorkspaceValidation.validateTask(title: task.title, instructions: task.instructions) }
        if let validateBeforeCommit { try await MainActor.run { try validateBeforeCommit() }; try requireCurrent(ownerId, version) }
        var quiet = try quietSnapshot(for: ownerId)
        var plans = try Self.plansForSave(task, quietHours: quiet.policy, expectedTask: expectedTask, repository: repository)
        let state = CommitState()
        if plans.isEmpty {
            let pending = isNew ? [] : await center.pendingNotificationRequests()
            let delivered = isNew ? [] : await center.deliveredNotificationIdentifiers()
            let batch = Batch(ownerId: ownerId, taskId: task.id, operationId: operation, version: version, quiet: quiet, baseTask: previous, plans: [], state: state, repairingCancelledOperation: false)
            try validate(batch)
            try await commit(task, isNew: isNew, expectedTask: expectedTask, batch: batch, validator: validateBeforeCommit)
            let ids = Set(pending.map(\.identifier) + delivered).filter { AssistantReminderPolicy.ownsTaskIdentifier($0, ownerId: ownerId, taskId: task.id) }
            center.removePendingNotificationRequests(withIdentifiers: Array(ids)); center.removeDeliveredNotifications(withIdentifiers: Array(ids))
            return
        }
        var settings = await center.notificationSettings()
        try requireCurrent(ownerId, version)
        _ = try Self.plansForSave(task, quietHours: quietSnapshot(for: ownerId).policy, expectedTask: expectedTask, repository: repository)
        let preliminaryPending = await center.pendingNotificationRequests()
        try requireCurrent(ownerId, version)
        quiet = try quietSnapshot(for: ownerId)
        let preliminaryPlans = try projectedPlans(for: task, ownerId: ownerId, quiet: quiet, pending: preliminaryPending,
            restartingAt: Self.restartsRecurrence(task, previous: previous) ? saveStartedAt : nil)
        try AssistantReminderPolicy.checkCapacity(for: Set(preliminaryPlans.map(\.identifier)), replacingTaskId: task.id, ownerId: ownerId,
            pendingIdentifiers: preliminaryPending.map(\.identifier) + Array(schedulingIdentifiers.keys))
        if settings.authorizationStatus == .notDetermined {
            if let validateBeforeCommit { try await MainActor.run { try validateBeforeCommit() }; try requireCurrent(ownerId, version) }
            _ = try Self.plansForSave(task, quietHours: quietSnapshot(for: ownerId).policy, expectedTask: expectedTask, repository: repository)
            guard requestAuthorization else { throw AssistantReminderError.authorizationRequired }
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) } catch { throw AssistantReminderError.permissionDenied }
            settings = await center.notificationSettings()
        }
        try requireCurrent(ownerId, version)
        guard allowsAlerts(settings) else { throw AssistantReminderError.permissionDenied }
#if os(iOS)
        // A user may grant notification permission inside this save flow while
        // the app stays active; publish the APNs token without another prompt.
        await AssistantNotificationRouter.shared.registerRemoteNotificationsIfAuthorized()
        await AssistantRemoteNotificationCoordinator.shared.appDidBecomeActive()
#endif
        let pending = await center.pendingNotificationRequests()
        try requireCurrent(ownerId, version)
        quiet = try quietSnapshot(for: ownerId)
        _ = try Self.plansForSave(task, quietHours: quiet.policy, expectedTask: expectedTask, repository: repository)
        plans = try projectedPlans(for: task, ownerId: ownerId, quiet: quiet, pending: pending,
            restartingAt: Self.restartsRecurrence(task, previous: previous) ? saveStartedAt : nil)
        let batch = Batch(ownerId: ownerId, taskId: task.id, operationId: operation, version: version, quiet: quiet, baseTask: previous, plans: plans, state: state, repairingCancelledOperation: false)
        do {
            _ = try await addBatch(batch, pending: pending, saveCandidate: task, expectedTask: expectedTask)
            try validate(batch)
            try await commit(task, isNew: isNew, expectedTask: expectedTask, batch: batch, validator: validateBeforeCommit)
        } catch {
            let original = error
            let restored = await repair(batch, remainingRepairs: 2)
            if !restored, !isInterruption(original) { throw AssistantReminderError.restorationFailed(String(describing: original)) }
            throw original
        }
    }

    func updateTaskStatus(id: String, ownerId: String, status: AssistantTaskStatus, expectedTask: AssistantTask? = nil) async throws {
        try requireCurrent(ownerId, sessionVersion)
        guard var task = repository.tasks(for: ownerId).first(where: { $0.id == id }) else { throw AssistantReminderError.persistenceFailed(AssistantRepositoryError.recordNotFound.localizedDescription) }
        if let expectedTask { try Self.validateExpectedTask(expectedTask, candidate: task, repository: repository) }
        let previous = task; task.status = status; task.updatedAt = Date()
        try await saveTask(task, isNew: false, ownerId: ownerId, requestAuthorization: false, expectedTask: previous)
    }
    func reopenTaskWithoutReminder(_ expectedTask: AssistantTask, ownerId: String) async throws {
        try requireCurrent(ownerId, sessionVersion)
        guard AssistantOwnerIdentity.matches(expectedTask.userId, ownerId) else { throw AssistantReminderError.foreignOwner }
        guard expectedTask.status != .active else { throw AssistantRepositoryError.invalidRecord }
        var task = expectedTask; task.status = .active; task.reminderEnabled = false; task.updatedAt = Date()
        try await saveTask(task, isNew: false, ownerId: ownerId, requestAuthorization: false, expectedTask: expectedTask)
    }
    func deleteTask(id: String, ownerId: String) async throws {
        let version = sessionVersion; try requireCurrent(ownerId, version)
        let key = AssistantReminderPolicy.identifier(ownerId: ownerId, taskId: id)
        guard inFlightTaskIds[key] == nil else { throw AssistantReminderError.operationInProgress }
        let operation = UUID(); inFlightTaskIds[key] = operation
        defer { release(ownerId: ownerId, taskId: id, operationId: operation) }
        let pending = await center.pendingNotificationRequests(); let delivered = await center.deliveredNotificationIdentifiers()
        try requireCurrent(ownerId, version)
        guard repository.deleteTask(id: id, userId: ownerId) else { throw persistenceError() }
        let ids = Set(pending.map(\.identifier) + delivered).filter { AssistantReminderPolicy.ownsTaskIdentifier($0, ownerId: ownerId, taskId: id) }
        center.removePendingNotificationRequests(withIdentifiers: Array(ids)); center.removeDeliveredNotifications(withIdentifiers: Array(ids))
    }
    func removeAll(for ownerId: String) async {
        if AssistantOwnerIdentity.matches(activeOwnerId, ownerId) { invalidateSourceCommits(ownerId: ownerId, reason: .inactiveSession); activeOwnerId = nil; sessionVersion += 1 }
        await removeRequests(for: ownerId)
    }

    private func addBatch(_ batch: Batch, pending: [UNNotificationRequest], saveCandidate: AssistantTask? = nil, expectedTask: AssistantTask? = nil) async throws -> [UNNotificationRequest] {
        try validate(batch)
        try AssistantReminderPolicy.checkCapacity(for: Set(batch.plans.map(\.identifier)), replacingTaskId: batch.taskId, ownerId: batch.ownerId,
            pendingIdentifiers: pending.map(\.identifier) + Array(schedulingIdentifiers.keys))
        for plan in batch.plans { schedulingIdentifiers[plan.identifier] = batch.operationId; inFlightSchedules[plan.identifier] = InFlightSchedule(batch: batch, plan: plan) }
        let desired = Set(batch.plans.map(\.identifier))
        let obsolete = pending.filter { AssistantReminderPolicy.ownsTaskIdentifier($0.identifier, ownerId: batch.ownerId, taskId: batch.taskId) && !desired.contains($0.identifier) }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: obsolete)
        return try await withTaskCancellationHandler(operation: {
            for plan in batch.plans {
                try validate(batch)
                if saveCandidate == nil, pending.contains(where: { $0.identifier == plan.identifier && matches($0, plan: plan) }) { continue }
                do { try await center.add(makeRequest(plan, operationId: batch.operationId)) }
                catch { throw AssistantReminderError.schedulingFailed(String(describing: error)) }
                try validate(batch)
            }
            if let saveCandidate { _ = try Self.plansForSave(saveCandidate, quietHours: batch.quiet.policy, expectedTask: expectedTask, repository: repository) }
            let actual = await center.pendingNotificationRequests()
            try validate(batch)
            guard batch.plans.allSatisfy({ plan in actual.contains { $0.identifier == plan.identifier && matches($0, plan: plan) } }) else { throw AssistantReminderError.schedulingFailed("Incomplete batch") }
            return actual
        }, onCancel: { batch.state.cancel() })
    }

    private func repair(_ batch: Batch, remainingRepairs: Int) async -> Bool {
        guard inFlightTaskIds[batch.key] == batch.operationId else { return true }
        _ = await cleanupOperation(batch)
        guard inFlightTaskIds[batch.key] == batch.operationId else { return true }
        release(ownerId: batch.ownerId, taskId: batch.taskId, operationId: batch.operationId)
        if !AssistantOwnerIdentity.matches(activeOwnerId, batch.ownerId) { await removeTaskRequests(taskId: batch.taskId, ownerId: batch.ownerId); return true }
        guard remainingRepairs > 0 else { return false }
        let report = await reconcile(ownerId: batch.ownerId, repairingCancelledOperation: true, remainingRepairs: remainingRepairs - 1)
        if inFlightTaskIds[batch.key] != nil { return true }
        let pending = await center.pendingNotificationRequests()
        if !AssistantOwnerIdentity.matches(activeOwnerId, batch.ownerId) || inFlightTaskIds[batch.key] != nil { return true }
        guard let task = repository.tasks(for: batch.ownerId).first(where: { $0.id == batch.taskId }) else { return true }
        if task.status != .active || task.reminderEnabled != true { return true }
        guard let quiet = try? quietSnapshot(for: batch.ownerId),
              let plans = try? projectedPlans(for: task, ownerId: batch.ownerId, quiet: quiet, pending: pending) else { return false }
        return !report.schedulingFailedTaskIds.contains(task.id)
            && coverage(task: task, plans: plans, pending: pending) != nil
    }
    private func cleanupOperation(_ batch: Batch) async -> [String] {
        guard inFlightTaskIds[batch.key] == batch.operationId else { return [] }
        let pending = await center.pendingNotificationRequests()
        guard inFlightTaskIds[batch.key] == batch.operationId else { return [] }
        let ids = pending.filter { $0.content.userInfo["scheduleOperationId"] as? String == batch.operationId.uuidString
            && AssistantReminderPolicy.ownsTaskIdentifier($0.identifier, ownerId: batch.ownerId, taskId: batch.taskId) }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: ids)
        return ids
    }
    private func release(ownerId: String, taskId: String, operationId: UUID) {
        let key = AssistantReminderPolicy.identifier(ownerId: ownerId, taskId: taskId)
        if inFlightTaskIds[key] == operationId { inFlightTaskIds.removeValue(forKey: key) }
        for id in Array(schedulingIdentifiers.keys) where schedulingIdentifiers[id] == operationId { schedulingIdentifiers.removeValue(forKey: id) }
        for id in Array(inFlightSchedules.keys) where inFlightSchedules[id]?.batch.operationId == operationId { inFlightSchedules.removeValue(forKey: id) }
    }
    private func currentTask(ownerId: String, taskId: String) -> AssistantTask? { repository.tasks(for: ownerId).first { $0.id == taskId } }
    private func baseIsCurrent(_ batch: Batch) -> Bool { let actual = currentTask(ownerId: batch.ownerId, taskId: batch.taskId); return actual == batch.baseTask || batch.state.matches(actual) }
    private func batchIsCurrent(_ batch: Batch) -> Bool {
        isCurrent(batch.ownerId, batch.version, quiet: batch.quiet) && baseIsCurrent(batch)
            && (batch.repairingCancelledOperation || !batch.state.isCancelled)
            && inFlightTaskIds[batch.key] == batch.operationId
    }
    private func validate(_ batch: Batch) throws {
        guard isCurrent(batch.ownerId, batch.version) else { throw AssistantReminderError.inactiveSession }
        guard isCurrent(batch.ownerId, batch.version, quiet: batch.quiet) else { throw AssistantReminderError.operationInProgress }
        guard baseIsCurrent(batch) else { throw AssistantRepositoryError.staleTask }
        guard inFlightTaskIds[batch.key] == batch.operationId else { throw AssistantReminderError.operationInProgress }
        guard batch.repairingCancelledOperation || (!Task.isCancelled && !batch.state.isCancelled) else { throw AssistantReminderError.inactiveSession }
    }
    private func isInterruption(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let value = error as? AssistantReminderError, value == .inactiveSession || value == .operationInProgress { return true }
        if let value = error as? AssistantRepositoryError, case .staleTask = value { return true }
        return false
    }
    private func persistenceError() -> AssistantReminderError { .persistenceFailed(repository.lastError?.localizedDescription ?? AssistantLocalization.string("任务保存失败。")) }

    private func commit(_ task: AssistantTask, isNew: Bool, expectedTask: AssistantTask?, batch: Batch, validator: (@MainActor () throws -> Void)?) async throws {
        if let validator {
            let permit = SourceCommitPermit(ownerId: task.userId); sourceCommitPermits[batch.operationId] = permit
            defer { sourceCommitPermits.removeValue(forKey: batch.operationId) }
            let repository = self.repository
            try await MainActor.run {
                try permit.commit {
                    try Task.checkCancellation()
                    guard try repository.quietHours(for: task.userId) == batch.quiet.policy else { throw AssistantReminderError.operationInProgress }
                    try validator()
                    guard repository.tasks(for: task.userId).first(where: { $0.id == task.id }) == batch.baseTask else { throw AssistantRepositoryError.staleTask }
                    try Self.persistTask(task, isNew: isNew, expectedTask: expectedTask ?? (isNew ? nil : batch.baseTask), repository: repository, plans: batch.plans)
                    Self.recordCommitted(task, repository: repository, state: batch.state)
                }
            }
        } else {
            try validate(batch)
            try Self.persistTask(task, isNew: isNew, expectedTask: expectedTask ?? (isNew ? nil : batch.baseTask), repository: repository, plans: batch.plans)
            Self.recordCommitted(task, repository: repository, state: batch.state)
        }
    }
    private static func recordCommitted(_ task: AssistantTask, repository: AssistantLocalRepository, state: CommitState) {
        guard let stored = repository.tasks(for: task.userId).first(where: { $0.id == task.id }) else { return }
        var candidate = task; candidate.updatedAt = stored.updatedAt; candidate.recurrenceStartsAt = stored.recurrenceStartsAt
        if let recurrence = try? AssistantTaskRecurrence.parse(candidate.recurrenceRule) { candidate.recurrenceRule = recurrence.canonicalRule }
        var actual = stored
        if let recurrence = try? AssistantTaskRecurrence.parse(actual.recurrenceRule) { actual.recurrenceRule = recurrence.canonicalRule }
        if actual == candidate { state.record(stored) }
    }
    private func invalidateSourceCommits(ownerId: String, reason: AssistantReminderError) { for permit in sourceCommitPermits.values where AssistantOwnerIdentity.matches(permit.ownerId, ownerId) { permit.invalidate(reason) } }
    private func requireCurrent(_ ownerId: String, _ version: Int) throws { guard isCurrent(ownerId, version), !Task.isCancelled else { throw AssistantReminderError.inactiveSession } }
    private func isCurrent(_ ownerId: String, _ version: Int) -> Bool { !ownerId.isEmpty && AssistantOwnerIdentity.matches(activeOwnerId, ownerId) && sessionVersion == version }
    private func quietSnapshot(for ownerId: String) throws -> QuietHoursSnapshot {
        let ownerKey = AssistantOwnerIdentity.ownerKey(ownerId)
        let policy = try repository.quietHours(for: ownerId)
        let stored = try repository.quietHoursEffectiveAt(for: ownerId)
        var effective = stored
        if policy.enabled, effective == nil {
            if legacyQuietStarts[ownerKey]?.policy != policy { legacyQuietStarts[ownerKey] = (policy, Date()) }
            effective = legacyQuietStarts[ownerKey]?.date
        }
        return QuietHoursSnapshot(policy: policy, version: quietHoursVersions[ownerKey, default: 0], effectiveAt: effective)
    }
    private func isCurrent(_ ownerId: String, _ version: Int, quiet: QuietHoursSnapshot) -> Bool {
        isCurrent(ownerId, version) && (try? quietSnapshot(for: ownerId)) == quiet
    }
    private static func restartsRecurrence(_ task: AssistantTask, previous: AssistantTask?) -> Bool {
        guard (try? AssistantTaskRecurrence.parse(task.recurrenceRule).isRepeating) == true else { return false }
        guard let previous else { return true }
        return (try? AssistantReminderPolicy.recurrenceIdentity(for: task)) != (try? AssistantReminderPolicy.recurrenceIdentity(for: previous))
            || (previous.status != .active && task.status == .active)
            || (previous.reminderEnabled != true && task.reminderEnabled == true)
    }
    private func projectedPlans(for task: AssistantTask, ownerId: String, quiet: QuietHoursSnapshot,
                                pending: [UNNotificationRequest], now: Date = Date(), restartingAt: Date? = nil) throws -> [AssistantReminderPlan] {
        guard task.reminderEnabled == true, task.status == .active else {
            return try AssistantReminderPolicy.plans(for: task, ownerId: ownerId, now: now, quietHours: quiet.policy)
        }
        guard let identity = try AssistantReminderPolicy.recurrenceIdentity(for: task) else {
            return try AssistantReminderPolicy.plans(for: task, ownerId: ownerId, now: now, quietHours: quiet.policy)
        }
        let key = AssistantReminderPolicy.identifier(ownerId: ownerId, taskId: task.id)
        if task.recurrenceStartsAt == nil, legacyRecurrenceStarts[key]?.identity != identity {
            legacyRecurrenceStarts[key] = (identity, now)
        }
        let starts = restartingAt ?? task.recurrenceStartsAt ?? legacyRecurrenceStarts[key]!.date
        let lowerBound = quiet.policy.enabled ? max(starts, quiet.effectiveAt ?? now) : starts
        // Origin-based IDs survive quiet-hour edits, but only future pending
        // one-shots with this rule/clock/zone identity may cross that edit boundary.
        let inherited: [Date] = restartingAt == nil ? pending.compactMap { request in
            guard AssistantOwnerIdentity.matches(request.content.userInfo["ownerId"] as? String, ownerId),
                  request.content.userInfo["taskId"] as? String == task.id,
                  request.content.userInfo["recurrenceIdentity"] as? String == identity,
                  request.content.userInfo["timeZone"] as? String == task.timeZone,
                  let trigger = request.trigger as? UNCalendarNotificationTrigger, !trigger.repeats,
                  let fire = trigger.nextTriggerDate(), fire.timeIntervalSince(now) >= 1 else { return nil }
            return AssistantReminderPolicy.occurrenceOrigin(identifier: request.identifier, ownerId: ownerId, taskId: task.id)
        } : []
        return try AssistantReminderPolicy.plans(for: task, ownerId: ownerId, now: now, quietHours: quiet.policy,
            notBefore: lowerBound, inheritedOrigins: inherited)
    }
    private func allowsAlerts(_ settings: AssistantReminderNotificationSettings) -> Bool { [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) && settings.alertsEnabled }

    private func recognizedRequest(_ request: UNNotificationRequest, ownerId: String) -> Bool {
        guard AssistantOwnerIdentity.matches(request.content.userInfo["ownerId"] as? String, ownerId), let id = request.content.userInfo["taskId"] as? String else { return false }
        return AssistantReminderPolicy.ownsTaskIdentifier(request.identifier, ownerId: ownerId, taskId: id)
    }
    private func registeredSchedule(_ request: UNNotificationRequest, ownerId: String) -> InFlightSchedule? {
        guard let value = inFlightSchedules[request.identifier], AssistantOwnerIdentity.matches(value.batch.ownerId, ownerId),
              inFlightTaskIds[value.batch.key] == value.batch.operationId, schedulingIdentifiers[request.identifier] == value.batch.operationId, matches(request, plan: value.plan) else { return nil }
        return value
    }
    private func validInFlight(_ request: UNNotificationRequest, ownerId: String, quiet: QuietHoursSnapshot) -> Bool {
        guard let value = registeredSchedule(request, ownerId: ownerId), value.batch.quiet == quiet else { return false }
        return batchIsCurrent(value.batch)
    }
    private func makeRequest(_ plan: AssistantReminderPlan, operationId: UUID) -> UNNotificationRequest {
        let content = UNMutableNotificationContent(); content.title = "CaoBao"
        content.body = AssistantLocalization.string("你有一项待办需要查看。"); content.sound = .default
        content.userInfo = ["taskId": plan.taskId, "ownerId": plan.ownerId, "route": "task", "reminderSchemaVersion": 1,
                            "timeZone": plan.timeZoneIdentifier, "scheduleOperationId": operationId.uuidString]
        if let identity = plan.recurrenceIdentity { content.userInfo["recurrenceIdentity"] = identity }
        return UNNotificationRequest(identifier: plan.identifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: plan.dateComponents, repeats: plan.repeats))
    }
    private func matches(_ request: UNNotificationRequest, plan: AssistantReminderPlan) -> Bool {
        guard AssistantOwnerIdentity.matches(request.content.userInfo["ownerId"] as? String, plan.ownerId), request.content.userInfo["taskId"] as? String == plan.taskId,
              request.content.userInfo["timeZone"] as? String == plan.timeZoneIdentifier, let trigger = request.trigger as? UNCalendarNotificationTrigger, trigger.repeats == plan.repeats else { return false }
        if let identity = plan.recurrenceIdentity, request.content.userInfo["recurrenceIdentity"] as? String != identity { return false }
        if plan.repeats {
            let actual = trigger.dateComponents, expected = plan.dateComponents
            return actual.hour == expected.hour && actual.minute == expected.minute && actual.second == expected.second && actual.weekday == expected.weekday
                && actual.era == nil && actual.year == nil && actual.month == nil && actual.day == nil && actual.weekdayOrdinal == nil
                && actual.weekOfYear == nil && actual.weekOfMonth == nil && actual.yearForWeekOfYear == nil && actual.quarter == nil
                && actual.nanosecond == nil && actual.isLeapMonth != true && actual.calendar?.identifier == .gregorian
                && (actual.timeZone ?? actual.calendar?.timeZone)?.identifier == expected.timeZone?.identifier
        }
        guard let next = trigger.nextTriggerDate() else { return false }
        return abs(next.timeIntervalSince(plan.fireAt)) < 1.1
    }
    private func coverage(task: AssistantTask, plans: [AssistantReminderPlan], pending: [UNNotificationRequest]) -> AssistantReminderCoverage? {
        guard !plans.isEmpty else { return nil }
        var dates: [Date] = []
        for plan in plans {
            guard let request = pending.first(where: { $0.identifier == plan.identifier && matches($0, plan: plan) }),
                  let trigger = request.trigger as? UNCalendarNotificationTrigger, let next = trigger.nextTriggerDate() else { return nil }
            dates.append(next)
        }
        guard let first = dates.min() else { return nil }
        return AssistantReminderCoverage(nextFireAt: first, through: plans.allSatisfy(\.repeats) ? nil : plans.map(\.fireAt).max(), scheduledCount: plans.count,
            repeating: (try? AssistantTaskRecurrence.parse(task.recurrenceRule).isRepeating) ?? false)
    }
    private func removeTaskRequests(taskId: String, ownerId: String) async {
        let pending = await center.pendingNotificationRequests(), delivered = await center.deliveredNotificationIdentifiers()
        let key = AssistantReminderPolicy.identifier(ownerId: ownerId, taskId: taskId)
        guard inFlightTaskIds[key] == nil else { return }
        let ids = Set(pending.map(\.identifier) + delivered).filter { AssistantReminderPolicy.ownsTaskIdentifier($0, ownerId: ownerId, taskId: taskId) }
        center.removePendingNotificationRequests(withIdentifiers: Array(ids)); center.removeDeliveredNotifications(withIdentifiers: Array(ids))
    }
    private func removeRequests(for ownerId: String) async {
        let version = sessionVersion
        let pending = await center.pendingNotificationRequests(), delivered = await center.deliveredNotificationIdentifiers()
        guard !AssistantOwnerIdentity.matches(activeOwnerId, ownerId) || sessionVersion == version else { return }
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { AssistantReminderPolicy.owns($0, ownerId: ownerId) })
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter { AssistantReminderPolicy.owns($0, ownerId: ownerId) })
    }
    private static func validateExpectedTask(_ expected: AssistantTask, candidate: AssistantTask, repository: AssistantLocalRepository) throws {
        guard AssistantOwnerIdentity.matches(expected.userId, candidate.userId), expected.id == candidate.id else { throw AssistantRepositoryError.invalidRecord }
        guard let current = repository.tasks(for: expected.userId).first(where: { $0.id == expected.id }) else {
            throw AssistantRepositoryError.recordNotFound
        }
        guard current == expected else { throw AssistantRepositoryError.staleTask }
    }

    private static func isReminderReactivation(_ task: AssistantTask, expectedTask: AssistantTask?) -> Bool {
        guard let expectedTask else { return false }
        return expectedTask.status != .active && task.status == .active
            && expectedTask.reminderEnabled == true && task.reminderEnabled == true
    }

    private static func plansForSave(_ task: AssistantTask, quietHours: AssistantQuietHours,
                                    expectedTask: AssistantTask?, repository: AssistantLocalRepository) throws -> [AssistantReminderPlan] {
        if let expectedTask { try validateExpectedTask(expectedTask, candidate: task, repository: repository) }
        do { return try AssistantReminderPolicy.plans(for: task, ownerId: task.userId, quietHours: quietHours) }
        catch AssistantReminderError.pastDueDate {
            if isReminderReactivation(task, expectedTask: expectedTask), let expectedTask {
                // Carry the actual inactive snapshot, never the edited active candidate.
                throw AssistantReminderError.reactivationRequired(expectedTask)
            }
            throw AssistantReminderError.pastDueDate
        }
    }

    private static func persistTask(_ task: AssistantTask, isNew: Bool, expectedTask: AssistantTask?, repository: AssistantLocalRepository, plans: [AssistantReminderPlan]) throws {
        if let expectedTask {
            try validateExpectedTask(expectedTask, candidate: task, repository: repository)
            // Re-check at the real commit instant, including the MainActor hop
            // after OS add. Only reactivations gain this additional expiry rule.
            if isReminderReactivation(task, expectedTask: expectedTask) {
                _ = try plansForSave(task, quietHours: repository.quietHours(for: task.userId), expectedTask: expectedTask, repository: repository)
            }
        }
        // The repository supplies the actual activation instant under its lock.
        // Pure validation avoids a race between scheduling and disk commit when
        // an awaited OS add crosses the first recurrence origin.
        let validateOrigins: (AssistantTask) throws -> Void = { normalized in
            guard normalized.status == .active, normalized.reminderEnabled == true,
                  let start = normalized.recurrenceStartsAt else { return }
            for plan in plans where plan.recurrenceIdentity != nil {
                let origin = AssistantReminderPolicy.occurrenceOrigin(identifier: plan.identifier, ownerId: normalized.userId, taskId: normalized.id) ?? plan.fireAt
                guard origin > start else { throw AssistantRepositoryError.recurrenceActivationElapsed }
            }
        }
        if isNew {
            guard expectedTask == nil else { throw AssistantRepositoryError.invalidRecord }
            repository.addTask(task, validateBeforePersist: validateOrigins)
        } else if let expectedTask {
            guard repository.updateTask(task, expecting: expectedTask, validateBeforePersist: validateOrigins) else {
                if let error = repository.lastError {
                    switch error {
                    case .staleTask, .recurrenceActivationElapsed: throw error
                    default: break
                    }
                }
                throw AssistantReminderError.persistenceFailed(repository.lastError?.localizedDescription ?? AssistantLocalization.string("任务保存失败。"))
            }
        } else if !repository.updateTask(task) {
            throw AssistantReminderError.persistenceFailed(repository.lastError?.localizedDescription ?? AssistantLocalization.string("任务保存失败。"))
        }
        if let error = repository.lastError {
            if case .recurrenceActivationElapsed = error { throw error }
            throw AssistantReminderError.persistenceFailed(error.localizedDescription)
        }
    }

}
#endif
