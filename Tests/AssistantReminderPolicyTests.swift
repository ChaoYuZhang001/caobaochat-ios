import Foundation

private enum ReminderTestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { switch self { case .assertion(let text): return text } }
}

@main
private struct AssistantReminderPolicyTests {
    static let now = Date(timeIntervalSince1970: 1_793_232_000)
    private static var suiteCount = 0
    static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try value() == false { throw ReminderTestFailure.assertion(message) }
    }

    static func expectError(_ expected: AssistantReminderError, _ operation: () throws -> Void) throws {
        do {
            try operation()
            throw ReminderTestFailure.assertion("Expected error \(expected)")
        } catch let error as AssistantReminderError {
            try expect(error == expected, "Unexpected policy error: \(error)")
        }
    }

    static func task(owner: String = "A", id: String = "task-1", enabled: Bool? = true,
                     status: AssistantTaskStatus = .active, due: Date? = now.addingTimeInterval(3600),
                     zone: String = "Asia/Shanghai", created: Date = now) -> AssistantTask {
        AssistantTask(id: id, userId: owner, title: "Private task title", instructions: "Private notes",
                      dueAt: due, timeZone: zone, recurrenceRule: nil, requiresApproval: false,
                      status: status, createdAt: created, updatedAt: now, reminderEnabled: enabled)
    }

    static func run(_ name: String, _ operation: () throws -> Void) throws {
        try operation()
        suiteCount += 1
        print("PASS \(name)")
    }

    static func main() throws {
        try run("due-date-is-not-consent") {
            try expect(try AssistantReminderPolicy.plan(for: task(enabled: nil), ownerId: "A", now: now) == nil,
                       "Legacy tasks with dates must not schedule")
            try expect(try AssistantReminderPolicy.plan(for: task(enabled: false), ownerId: "A", now: now) == nil,
                       "An explicit opt-out must not schedule")
            let plan = try AssistantReminderPolicy.plan(for: task(), ownerId: "A", now: now)
            try expect(plan?.taskId == "task-1", "Explicit opt-in must produce a plan")
        }
        try run("status-controls-scheduling") {
            for status in AssistantTaskStatus.allCases where status != .active {
                try expect(try AssistantReminderPolicy.plan(for: task(status: status), ownerId: "A", now: now) == nil,
                           "Paused, completed and cancelled tasks must never schedule")
            }
        }
        try run("past-date-and-missing-date") {
            try expectError(.missingDueDate) { _ = try AssistantReminderPolicy.plan(for: task(due: nil), ownerId: "A", now: now) }
            for date in [now.addingTimeInterval(-1), now, now.addingTimeInterval(0.5)] {
                try expectError(.pastDueDate) { _ = try AssistantReminderPolicy.plan(for: task(due: date), ownerId: "A", now: now) }
            }
            try expect(try AssistantReminderPolicy.plan(for: task(due: now.addingTimeInterval(1)), ownerId: "A", now: now) != nil,
                       "A future date outside the safety boundary is accepted")
        }
        try run("recorded-timezone-preserves-instant") {
            for zone in ["Asia/Shanghai", "America/Los_Angeles", "Pacific/Auckland", "UTC"] {
                let plan = try AssistantReminderPolicy.plan(for: task(zone: zone), ownerId: "A", now: now)!
                let calendar = plan.dateComponents.calendar!
                let restored = calendar.date(from: plan.dateComponents)!
                try expect(plan.timeZoneIdentifier == zone, "Recorded zone must be preserved")
                try expect(plan.dateComponents.timeZone?.secondsFromGMT(for: plan.fireAt) == TimeZone(identifier: zone)?.secondsFromGMT(for: plan.fireAt), "Trigger must carry recorded zone's offset at dueAt")
                try expect(abs(restored.timeIntervalSince(plan.fireAt)) < 1, "Changing zone must not move the due instant")
            }
            try expectError(.invalidTimeZone) { _ = try AssistantReminderPolicy.plan(for: task(zone: "No/SuchZone"), ownerId: "A", now: now) }
        }
        try run("dst-boundary-roundtrip") {
            // Both occurrences of 01:30 during the 2026 fall-back, then spring-forward.
            let parser = ISO8601DateFormatter()
            for value in ["2026-11-01T08:30:00Z", "2026-11-01T09:30:00Z", "2027-03-14T10:30:00Z"] {
                let due = parser.date(from: value)!
                let plan = try AssistantReminderPolicy.plan(for: task(due: due, zone: "America/Los_Angeles"), ownerId: "A", now: now)!
                let restored = plan.dateComponents.calendar!.date(from: plan.dateComponents)!
                try expect(abs(restored.timeIntervalSince(due)) < 1, "Trigger must remain bound to the stored instant")
            }
        }
        try run("account-isolation-and-collision-free-identifiers") {
            try expectError(.foreignOwner) { _ = try AssistantReminderPolicy.plan(for: task(owner: "B"), ownerId: "A", now: now) }
            try expectError(.invalidIdentity) { _ = try AssistantReminderPolicy.plan(for: task(), ownerId: " ", now: now) }
            try expectError(.invalidIdentity) { _ = try AssistantReminderPolicy.plan(for: task(id: ""), ownerId: "A", now: now) }
            let a = AssistantReminderPolicy.identifier(ownerId: "A", taskId: "same")
            let b = AssistantReminderPolicy.identifier(ownerId: "B", taskId: "same")
            try expect(a != b && AssistantReminderPolicy.owns(a, ownerId: "A"), "Same task IDs must stay owner scoped")
            try expect(!AssistantReminderPolicy.owns(a, ownerId: "B"), "Another owner must not cancel A")
            try expect(!AssistantReminderPolicy.owns("external." + a, ownerId: "A"), "Unrelated app requests must never match")
            try expect(!AssistantReminderPolicy.owns(a, ownerId: ""), "Empty identities must never match")
            let joined1 = AssistantReminderPolicy.identifier(ownerId: "A.B", taskId: "C")
            let joined2 = AssistantReminderPolicy.identifier(ownerId: "A", taskId: "B.C")
            try expect(joined1 != joined2, "Separators inside IDs must not create collisions")
            try expect(AssistantReminderPolicy.identifier(ownerId: "用户/账号", taskId: "事项+1") ==
                       AssistantReminderPolicy.identifier(ownerId: "用户/账号", taskId: "事项+1"), "Unicode IDs must be deterministic")
        }
        try run("unsupported-recurrence-rejected") {
            var value = task()
            value.recurrenceRule = "FREQ=MONTHLY"
            try expectError(.recurrenceUnsupported) { _ = try AssistantReminderPolicy.plan(for: value, ownerId: "A", now: now) }
            value.recurrenceRule = " "
            try expect(try AssistantReminderPolicy.plan(for: value, ownerId: "A", now: now) != nil, "An empty repeat rule is one-shot")
        }
        try run("pending-capacity-does-not-steal-other-notifications") {
            let id = AssistantReminderPolicy.identifier(ownerId: "A", taskId: "new")
            let own = (0..<AssistantReminderPolicy.maximumOwnPending).map {
                AssistantReminderPolicy.identifier(ownerId: "A", taskId: "t-\($0)")
            }
            try expectError(.pendingLimit) { try AssistantReminderPolicy.checkCapacity(for: id, pendingIdentifiers: own) }
            try AssistantReminderPolicy.checkCapacity(for: own[0], pendingIdentifiers: own)
            try AssistantReminderPolicy.checkCapacity(for: id, pendingIdentifiers: Array(own.dropFirst()))
            let external = (0..<AssistantReminderPolicy.maximumAppPending).map { "another-feature.\($0)" }
            try expectError(.pendingLimit) { try AssistantReminderPolicy.checkCapacity(for: id, pendingIdentifiers: external) }
            try AssistantReminderPolicy.checkCapacity(for: id, pendingIdentifiers: Array(external.dropFirst()))
        }
        try run("legacy-codable-without-reminder-consent") {
            let old = task(enabled: nil)
            let data = try JSONEncoder().encode(old)
            let decoded = try JSONDecoder().decode(AssistantTask.self, from: data)
            try expect(decoded.reminderEnabled == nil, "Old records remain opted out without migration")
            try expect(try AssistantReminderPolicy.plan(for: decoded, ownerId: "A", now: now) == nil,
                       "Decoding must not invent consent")
        }
        try run("reminder-consent-persistence-and-state-changes") {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("caobao-reminder-policy-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("store.json")
            let repository = AssistantLocalRepository(fileURL: url)
            repository.addTask(task())
            try expect(repository.lastError == nil, "Fixture must save")
            try expect(repository.updateTaskStatus(id: "task-1", userId: "A", status: .paused), "Pause must persist")
            let paused = AssistantLocalRepository(fileURL: url).tasks(for: "A").first!
            try expect(paused.reminderEnabled == true, "Pausing preserves explicit opt-in for future resume")
            try expect(try AssistantReminderPolicy.plan(for: paused, ownerId: "A", now: now) == nil, "Paused reminders must be removed")
            try expect(repository.tasks(for: "B").isEmpty, "Reminders must not expose tasks across owners")
        }
        try run("quiet-hours-keeps-past-due-deferred-delivery") {
            let parser = ISO8601DateFormatter()
            let due = parser.date(from: "2026-10-29T23:00:00Z")!
            let afterMidnight = parser.date(from: "2026-10-30T00:30:00Z")!
            let quiet = AssistantQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60, timeZoneIdentifier: "UTC")
            let value = task(due: due)
            let plan = try AssistantReminderPolicy.plan(for: value, ownerId: "A", now: afterMidnight, quietHours: quiet)!
            try expect(plan.fireAt == parser.date(from: "2026-10-30T08:00:00Z")!, "A deferred notification remains valid after its due time")
            try expect(value.dueAt == due, "Quiet hours cannot mutate the task due date")
        }
        try run("quiet-hours-does-not-revive-an-old-one-shot") {
            let parser = ISO8601DateFormatter()
            let quiet = AssistantQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60, timeZoneIdentifier: "UTC")
            let due = parser.date(from: "2026-10-28T23:00:00Z")!
            let laterWindow = parser.date(from: "2026-10-29T23:30:00Z")!
            try expectError(.pastDueDate) {
                _ = try AssistantReminderPolicy.plan(for: task(due: due), ownerId: "A", now: laterWindow, quietHours: quiet)
            }
        }
        try run("quiet-hours-zone-is-independent-from-task-zone") {
            let parser = ISO8601DateFormatter()
            let due = parser.date(from: "2026-10-29T15:00:00Z")!
            let quiet = AssistantQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60, timeZoneIdentifier: "Asia/Shanghai")
            let plan = try AssistantReminderPolicy.plan(for: task(due: due, zone: "America/Los_Angeles"), ownerId: "A", now: due.addingTimeInterval(-60), quietHours: quiet)!
            let expected = parser.date(from: "2026-10-30T00:00:00Z")!
            try expect(plan.fireAt == expected, "Deferral uses the preference's explicit zone")
            try expect(plan.timeZoneIdentifier == "America/Los_Angeles", "Task display zone remains independently recorded")
            try expect(plan.dateComponents.calendar!.date(from: plan.dateComponents) == expected, "The calendar trigger preserves the adjusted instant")
        }
        try run("quiet-hours-does-not-invent-opt-in") {
            let quiet = AssistantQuietHours(enabled: true, startMinute: 0, endMinute: 23 * 60, timeZoneIdentifier: "UTC")
            for enabled in [false, nil] as [Bool?] {
                try expect(try AssistantReminderPolicy.plan(for: task(enabled: enabled), ownerId: "A", now: now, quietHours: quiet) == nil, "Quiet hours do not enable any task reminder")
            }
        }
        try run("quiet-hours-disabled-preserves-old-api") {
            let original = try AssistantReminderPolicy.plan(for: task(), ownerId: "A", now: now)
            let explicit = try AssistantReminderPolicy.plan(for: task(), ownerId: "A", now: now, quietHours: .disabled)
            try expect(original == explicit, "Default-disabled policy preserves existing call sites")
        }
        try run("native-daily-is-local-clock-without-template-date-gate") {
            let current = date("2026-10-30T07:30:00Z")
            var value = task(due: date("2030-01-01T23:00:45Z"), zone: "UTC")
            value.recurrenceRule = "FREQ=DAILY"
            let plans = try AssistantReminderPolicy.plans(for: value, ownerId: "A", now: current)
            try expect(plans.count == 1 && plans[0].identifier.hasSuffix(".daily") && plans[0].repeats, "Daily is one native ongoing child")
            try expect(plans[0].fireAt == date("2026-10-30T23:00:00Z"), "Template date and seconds never delay the repeating clock")
            try expect(plans[0].dateComponents.year == nil && plans[0].dateComponents.second == 0, "Native patterns cannot contain a calendar date")
        }
        try run("weekly-iso-mapping-and-singular-api-rejects-batch") {
            var value = task(due: date("2026-10-30T15:00:00Z"), zone: "UTC")
            value.recurrenceRule = "FREQ=WEEKLY;BYDAY=MO,WE,SU"
            let plans = try AssistantReminderPolicy.plans(for: value, ownerId: "A", now: date("2026-10-30T07:30:00Z"))
            try expect(plans.map { $0.calendarPattern!.isoWeekday! } == [1, 3, 7], "ISO weekdays remain canonical")
            try expect(plans.map { $0.dateComponents.weekday! } == [2, 4, 1], "Foundation uses Sunday=1")
            try expectError(.multiplePlans) { _ = try AssistantReminderPolicy.plan(for: value, ownerId: "A", now: date("2026-10-30T07:30:00Z")) }
        }
        try run("native-pattern-retains-iana-zone-across-dst") {
            var value = task(due: date("2026-10-31T08:30:00Z"), zone: "America/Los_Angeles")
            value.recurrenceRule = "FREQ=DAILY"
            let before = try AssistantReminderPolicy.plans(for: value, ownerId: "A", now: date("2026-10-31T20:00:00Z"))[0]
            let after = try AssistantReminderPolicy.plans(for: value, ownerId: "A", now: date("2026-11-01T10:00:00Z"))[0]
            try expect(before.dateComponents.timeZone?.identifier == "America/Los_Angeles" && before.calendarPattern?.hour == 1, "Repeating trigger carries IANA time zone and wall clock")
            try expect(before.fireAt == date("2026-11-01T08:30:00Z") && after.fireAt == date("2026-11-02T09:30:00Z"), "Clock remains 01:30 as DST offset changes")
        }
        try run("new-repeat-does-not-backfill-before-activation") {
            let current = date("2026-10-29T23:30:00Z") // Shanghai Oct 30 07:30
            var value = task(due: date("2030-01-01T15:00:00Z"), zone: "Asia/Shanghai", created: current.addingTimeInterval(-30 * 86_400))
            value.recurrenceRule = "FREQ=DAILY"
            value.recurrenceStartsAt = current
            let quiet = AssistantQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60, timeZoneIdentifier: "Asia/Shanghai")
            let plans = try AssistantReminderPolicy.plans(for: value, ownerId: "A", now: current, quietHours: quiet)
            try expect(plans.count == 7 && Set(plans.map(\.fireAt)).count == 7 && plans.allSatisfy { !$0.repeats }, "Quiet mode creates seven unique future one-shots")
            try expect(plans[0].fireAt == date("2026-10-31T00:00:00Z"), "A new 23:00 repeat starts Oct31 08:00, never Oct30 08:00")
            try expect(AssistantReminderPolicy.occurrenceOrigin(identifier: plans[0].identifier, ownerId: "A", taskId: value.id) == date("2026-10-30T15:00:00Z"), "Child ID keys the original 23:00 occurrence")
        }
        try run("quiet-edit-does-not-replay-matured-origin") {
            let current = date("2026-10-30T01:00:00Z") // Shanghai 09:00
            var value = task(due: date("2026-10-29T15:00:00Z"), zone: "Asia/Shanghai")
            value.recurrenceRule = "FREQ=DAILY"; value.recurrenceStartsAt = date("2026-10-28T00:00:00Z")
            let quiet = AssistantQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 10 * 60, timeZoneIdentifier: "Asia/Shanghai")
            let plans = try AssistantReminderPolicy.plans(for: value, ownerId: "A", now: current, quietHours: quiet, notBefore: current)
            try expect(plans.first?.fireAt == date("2026-10-31T02:00:00Z"), "Changing 08:00 to10:00 at09:00 cannot replay yesterday's matured origin")
        }
        try run("quiet-edit-inherits-only-valid-unmatured-origins") {
            let current = date("2026-10-29T23:30:00Z")
            var value = task(due: date("2026-10-29T15:00:00Z"), zone: "Asia/Shanghai")
            value.recurrenceRule = "FREQ=DAILY"; value.recurrenceStartsAt = date("2026-10-28T00:00:00Z")
            let quiet = AssistantQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 10 * 60, timeZoneIdentifier: "Asia/Shanghai")
            let valid = date("2026-10-29T15:00:00Z"), invalid = date("2026-10-29T14:00:00Z")
            let plans = try AssistantReminderPolicy.plans(for: value, ownerId: "A", now: current, quietHours: quiet, notBefore: current, inheritedOrigins: [valid, invalid, valid])
            try expect(plans.count == 7 && plans[0].fireAt == date("2026-10-30T02:00:00Z"), "A still-pending08:00 origin may move to10:00 before maturing")
            try expect(AssistantReminderPolicy.occurrenceOrigin(identifier: plans[0].identifier, ownerId: "A", taskId: value.id) == valid, "Invalid or duplicate inherited clocks cannot create children")
            value.recurrenceStartsAt = current
            let restarted = try AssistantReminderPolicy.plans(for: value, ownerId: "A", now: current, quietHours: quiet, notBefore: current, inheritedOrigins: [valid])
            try expect(restarted[0].fireAt == date("2026-10-31T02:00:00Z"), "A restart rejects the previous activation's origin")
        }
        try run("legacy-repeat-without-start-never-uses-created-date") {
            let current = date("2026-10-29T23:30:00Z")
            var value = task(due: date("2026-10-29T15:00:00Z"), zone: "Asia/Shanghai", created: date("2020-01-01T00:00:00Z"))
            value.recurrenceRule = "FREQ=DAILY"; value.recurrenceStartsAt = nil
            let quiet = AssistantQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60, timeZoneIdentifier: "Asia/Shanghai")
            let plans = try AssistantReminderPolicy.plans(for: value, ownerId: "A", now: current, quietHours: quiet)
            try expect(plans[0].fireAt == date("2026-10-31T00:00:00Z"), "Missing activation metadata defaults to this activation, never old creation date")
            let inherited = try AssistantReminderPolicy.plans(for: value, ownerId: "A", now: current, quietHours: quiet, inheritedOrigins: [date("2026-10-29T15:00:00Z")])
            try expect(inherited[0].fireAt == date("2026-10-30T00:00:00Z"), "Explicit valid pending origin remains recoverable for legacy data")
        }
        try run("exact-child-ownership-rejects-arbitrary-suffixes") {
            let base = AssistantReminderPolicy.identifier(ownerId: "A", taskId: "task-1")
            for suffix in ["", ".daily", ".weekday.1", ".weekday.7", ".occurrence.1793232000"] {
                try expect(AssistantReminderPolicy.ownsTaskIdentifier(base + suffix, ownerId: "A", taskId: "task-1"), "Documented exact children are owned")
            }
            for suffix in [".foo", ".weekday.0", ".weekday.8", ".weekday.01", ".weekday.1.extra", ".occurrence.+123", ".occurrence.01", ".occurrence.NaN"] {
                try expect(!AssistantReminderPolicy.ownsTaskIdentifier(base + suffix, ownerId: "A", taskId: "task-1"), "Arbitrary and malformed suffixes are never owned")
            }
        }
        try run("batch-capacity-excludes-whole-replaced-group") {
            let base = AssistantReminderPolicy.identifier(ownerId: "A", taskId: "task-1")
            let replacement = Set((1...7).map { base + ".weekday." + String($0) })
            let others = (0..<25).map { AssistantReminderPolicy.identifier(ownerId: "A", taskId: "other-" + String($0)) }
            try AssistantReminderPolicy.checkCapacity(for: replacement, replacingTaskId: "task-1", ownerId: "A", pendingIdentifiers: others + [base + ".daily"])
            try expectError(.pendingLimit) { try AssistantReminderPolicy.checkCapacity(for: replacement, replacingTaskId: "task-1", ownerId: "A", pendingIdentifiers: others + [AssistantReminderPolicy.identifier(ownerId: "A", taskId: "overflow")]) }
            let external = (0..<58).map { "external." + String($0) }
            try expectError(.pendingLimit) { try AssistantReminderPolicy.checkCapacity(for: replacement, replacingTaskId: "task-1", ownerId: "A", pendingIdentifiers: external) }
        }
        print("All \(suiteCount) AssistantReminderPolicy suites passed.")
    }
}
