import Foundation

/// Daily wall-clock quiet hours in an explicitly recorded time zone.
/// Only notification delivery is deferred; a task's due date is never changed.
struct AssistantQuietHours: Codable, Equatable, Sendable {
    var enabled: Bool
    var startMinute: Int
    var endMinute: Int
    var timeZoneIdentifier: String

    static var disabled: AssistantQuietHours {
        let current = TimeZone.current.identifier
        let zone = supportedTimeZoneIdentifiers.contains(current) ? current : "UTC"
        return AssistantQuietHours(enabled: false, startMinute: 22 * 60, endMinute: 8 * 60, timeZoneIdentifier: zone)
    }

    static let supportedTimeZoneIdentifiers: Set<String> =
        Set(TimeZone.knownTimeZoneIdentifiers).union(["UTC", "GMT"])

    // Keep pathological finite Date values away from Calendar/ICU. The supported
    // Gregorian UTC range is 0001-01-01 through the end of 9999-12-31.
    private static let earliestUnixSecond: TimeInterval = Date.distantPast.timeIntervalSince1970
    private static let latestUnixSecond: TimeInterval = 253_402_300_799.999

    @discardableResult
    func validated() throws -> AssistantQuietHours {
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute) else {
            throw AssistantQuietHoursError.invalidMinutes
        }
        guard startMinute != endMinute else { throw AssistantQuietHoursError.equalBoundaries }
        guard timeZoneIdentifier.utf8.count <= 128,
              Self.supportedTimeZoneIdentifiers.contains(timeZoneIdentifier),
              TimeZone(identifier: timeZoneIdentifier) != nil else { throw AssistantQuietHoursError.invalidTimeZone }
        return self
    }

    /// Anchors the window to the original due date, never to reconciliation time.
    /// Starts include the first repeated clock occurrence; ends use the last.
    func deliveryDate(for dueAt: Date) throws -> Date {
        try validated()
        let unix = dueAt.timeIntervalSince1970
        guard unix.isFinite, unix >= Self.earliestUnixSecond, unix <= Self.latestUnixSecond else {
            throw AssistantQuietHoursError.invalidDate
        }
        guard enabled else { return dueAt }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        let today = calendar.startOfDay(for: dueAt)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            throw AssistantQuietHoursError.calendarFailure
        }
        for anchor in [yesterday, today] {
            let endDay: Date
            if endMinute < startMinute {
                guard let followingDay = calendar.date(byAdding: .day, value: 1, to: anchor) else {
                    throw AssistantQuietHoursError.calendarFailure
                }
                endDay = followingDay
            } else { endDay = anchor }
            let start = try Self.resolveWallClock(on: anchor, minute: startMinute, calendar: calendar, repeatedTimePolicy: .first)
            let end = try Self.resolveWallClock(on: endDay, minute: endMinute, calendar: calendar, repeatedTimePolicy: .last)
            // A window wholly inside a skipped DST gap has no real instants.
            if start < end, dueAt >= start, dueAt < end {
                guard end.timeIntervalSince1970 <= Self.latestUnixSecond else { throw AssistantQuietHoursError.invalidDate }
                return end
            }
        }
        return dueAt
    }

    /// Shared by local recurring tasks; callers validate dates and minute bounds.
    static func resolveWallClock(on day: Date, minute: Int, calendar: Calendar,
                                 repeatedTimePolicy: Calendar.RepeatedTimePolicy) throws -> Date {
        let start = calendar.startOfDay(for: day)
        let fields: Set<Calendar.Component> = [.era, .year, .month, .day, .hour, .minute, .second]
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var clock = calendar.dateComponents(fields, from: start)
        clock.hour = minute / 60; clock.minute = minute % 60; clock.second = 0
        guard let nominal = utc.date(from: clock) else { throw AssistantQuietHoursError.calendarFailure }

        // .nextDate(.last) can select the first occurrence or the following day
        // in Lord Howe's half-hour fold; .nextTime can skip its gap day entirely.
        // Resolve candidate UTC instants using real nearby offsets, then verify
        // the complete requested wall-clock fields instead of assuming a 1h DST.
        var offsets = Set<Int>()
        for seconds in stride(from: -172_800, through: 172_800, by: 21_600) {
            offsets.insert(calendar.timeZone.secondsFromGMT(for: start.addingTimeInterval(TimeInterval(seconds))))
        }
        let candidates = offsets.map { nominal.addingTimeInterval(-TimeInterval($0)) }.sorted()
        let occurrences = candidates.filter { calendar.dateComponents(fields, from: $0) == clock }
        if let value = repeatedTimePolicy == .last ? occurrences.max() : occurrences.min() { return value }

        // A nonexistent clock time is in a forward gap. Candidate offsets bracket
        // the real transition. Find that first real second (.nextTime semantics),
        // including non-hour and historical sub-minute offset changes.
        func wallClock(_ instant: Date) -> Date? {
            utc.date(from: calendar.dateComponents(fields, from: instant))
        }
        for (lower, upper) in zip(candidates, candidates.dropFirst()) {
            let beforeOffset = calendar.timeZone.secondsFromGMT(for: lower)
            guard beforeOffset != calendar.timeZone.secondsFromGMT(for: upper) else { continue }
            var low = Int64(lower.timeIntervalSince1970.rounded(.down))
            var high = Int64(upper.timeIntervalSince1970.rounded(.up))
            while low < high {
                let middle = low + (high - low) / 2
                let offset = calendar.timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(middle)))
                if offset == beforeOffset { low = middle + 1 } else { high = middle }
            }
            let transition = Date(timeIntervalSince1970: TimeInterval(low))
            guard calendar.isDate(transition, inSameDayAs: start),
                  let before = wallClock(transition.addingTimeInterval(-1)), let after = wallClock(transition),
                  before < nominal, nominal < after else { continue }
            return transition
        }
        throw AssistantQuietHoursError.calendarFailure
    }
}

enum AssistantQuietHoursError: LocalizedError, Equatable {
    case invalidMinutes, equalBoundaries, invalidTimeZone, invalidDate, calendarFailure

    var errorDescription: String? {
        switch self {
        case .invalidMinutes: return AssistantLocalization.string("安静时段的时间无效，请重新选择。")
        case .equalBoundaries: return AssistantLocalization.string("安静时段的开始与结束时间不能相同。")
        case .invalidTimeZone: return AssistantLocalization.string("安静时段需要有效的地区时区，请重新选择。")
        case .invalidDate: return AssistantLocalization.string("提醒日期无效，无法应用安静时段。")
        case .calendarFailure: return AssistantLocalization.string("无法计算安静时段结束时间，请检查时区和日期。")
        }
    }
}
