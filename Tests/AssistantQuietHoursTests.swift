import Foundation

private struct QuietTestFailure: Error, CustomStringConvertible { let description: String }
private final class QuietFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var first: String? { lock.lock(); defer { lock.unlock() }; return values.first }
}

@main private enum AssistantQuietHoursTests {
    private static var count = 0
    private static func date(_ value: String) -> Date {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: value) ?? ISO8601DateFormatter().date(from: value)!
    }
    private static func policy(_ start: Int, _ end: Int, zone: String = "UTC", enabled: Bool = true) -> AssistantQuietHours {
        AssistantQuietHours(enabled: enabled, startMinute: start, endMinute: end, timeZoneIdentifier: zone)
    }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw QuietTestFailure(description: message) }
    }
    private static func equals(_ value: AssistantQuietHours, _ input: String, _ expected: String) throws {
        let actual = try value.deliveryDate(for: date(input)), target = date(expected)
        try expect(abs(actual.timeIntervalSince(target)) < 0.001, "Expected \(expected) for \(input), received unix=\(actual.timeIntervalSince1970)")
    }
    private static func rejects(_ value: AssistantQuietHours, _ expected: AssistantQuietHoursError) throws {
        do { _ = try value.validated(); throw QuietTestFailure(description: "Expected validation failure \(expected)") }
        catch let error as AssistantQuietHoursError { try expect(error == expected, "Wrong validation failure") }
    }
    private static func run(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { throw QuietTestFailure(description: name + ": \(error)") }
        count += 1; print("PASS " + name)
    }
    static func main() {
        do { try runAll(); print("PASS \(count) quiet-hours test groups; Foundation dates only, no permissions or notifications") }
        catch { print("FAIL \(error)"); exit(1) }
    }
    private static func runAll() throws {
        try run("default-disabled-explicit-time-zone-and-22-to-08") {
            let value = AssistantQuietHours.disabled
            try expect(!value.enabled && value.startMinute == 1320 && value.endMinute == 480, "Default must be disabled 22:00-08:00")
            try expect(!value.timeZoneIdentifier.isEmpty && TimeZone(identifier: value.timeZoneIdentifier) != nil, "A default always records an actual explicit time zone")
            try expect(value.validated() == value, "Default must validate")
        }
        try run("disabled-preserves-original-date-exactly") {
            let value = policy(1320, 480, enabled: false)
            for input in ["2026-10-29T23:18:37.125Z", "2026-10-29T01:00:00Z", "2026-10-29T12:00:00Z"] {
                let due = date(input); try expect(value.deliveryDate(for: due) == due, "Disabled policy must be exact identity")
            }
        }
        try run("daytime-start-inclusive-end-exclusive") {
            let value = policy(9 * 60, 17 * 60)
            try equals(value, "2026-10-29T09:00:00Z", "2026-10-29T17:00:00Z")
            try equals(value, "2026-10-29T16:59:59.999Z", "2026-10-29T17:00:00Z")
            try equals(value, "2026-10-29T17:00:00Z", "2026-10-29T17:00:00Z")
            try equals(value, "2026-10-29T08:59:59.999Z", "2026-10-29T08:59:59.999Z")
        }
        try run("daytime-outside-window-is-unchanged") {
            let value = policy(9 * 60, 17 * 60)
            for input in ["2026-10-29T00:00:00Z", "2026-10-29T08:00:00Z", "2026-10-29T20:00:00Z"] { try equals(value, input, input) }
        }
        try run("overnight-late-evening-ends-next-day") {
            let value = policy(1320, 480)
            try equals(value, "2026-10-29T22:00:00Z", "2026-10-30T08:00:00Z")
            try equals(value, "2026-10-29T23:59:59.999Z", "2026-10-30T08:00:00Z")
        }
        try run("overnight-early-morning-uses-previous-anchor") {
            let value = policy(1320, 480)
            try equals(value, "2026-10-29T00:00:00Z", "2026-10-29T08:00:00Z")
            try equals(value, "2026-10-29T07:59:59.999Z", "2026-10-29T08:00:00Z")
        }
        try run("overnight-end-and-before-start-are-not-deferred") {
            let value = policy(1320, 480)
            for input in ["2026-10-29T08:00:00Z", "2026-10-29T21:59:59.999Z"] { try equals(value, input, input) }
        }
        try run("midnight-start-is-included") {
            try equals(policy(0, 480), "2026-10-29T00:00:00Z", "2026-10-29T08:00:00Z")
        }
        try run("midnight-end-is-excluded") {
            let value = policy(1320, 0)
            try equals(value, "2026-10-29T23:00:00Z", "2026-10-30T00:00:00Z")
            try equals(value, "2026-10-30T00:00:00Z", "2026-10-30T00:00:00Z")
        }
        try run("quarter-hour-zone-kathmandu") {
            let zone = AssistantQuietHours.supportedTimeZoneIdentifiers.contains("Asia/Kathmandu") ? "Asia/Kathmandu" : "Asia/Katmandu"
            try equals(policy(1320, 480, zone: zone), "2026-10-29T17:00:00Z", "2026-10-30T02:15:00Z")
        }
        try run("quarter-hour-zone-chatham-daylight-time") {
            try equals(policy(1320, 480, zone: "Pacific/Chatham"), "2026-01-01T09:00:00Z", "2026-01-01T18:15:00Z")
        }
        try run("new-york-spring-gap-spanning-window") {
            try equals(policy(90, 210, zone: "America/New_York"), "2026-03-08T06:45:00Z", "2026-03-08T07:30:00Z")
        }
        try run("new-york-spring-nonexistent-end-uses-next-real-time") {
            try equals(policy(60, 150, zone: "America/New_York"), "2026-03-08T06:45:00Z", "2026-03-08T07:00:00Z")
        }
        try run("new-york-spring-nonexistent-start-uses-next-real-time") {
            let value = policy(150, 240, zone: "America/New_York")
            try equals(value, "2026-03-08T07:10:00Z", "2026-03-08T08:00:00Z")
            try equals(value, "2026-03-08T06:50:00Z", "2026-03-08T06:50:00Z")
        }
        try run("window-wholly-inside-dst-gap-is-empty") {
            let value = policy(135, 165, zone: "America/New_York")
            for input in ["2026-03-08T06:59:59Z", "2026-03-08T07:00:00Z", "2026-03-08T07:15:00Z"] { try equals(value, input, input) }
        }
        try run("first-0145-is-before-second-0130-quiet-end") {
            try equals(policy(30, 90, zone: "America/New_York"), "2026-11-01T05:45:00Z", "2026-11-01T06:30:00Z")
        }
        try run("fold-start-first-end-last-spans-repeated-instants") {
            let value = policy(75, 90, zone: "America/New_York")
            try equals(value, "2026-11-01T05:20:00Z", "2026-11-01T06:30:00Z")
            try equals(value, "2026-11-01T06:10:00Z", "2026-11-01T06:30:00Z")
            try equals(value, "2026-11-01T05:10:00Z", "2026-11-01T05:10:00Z")
        }
        try run("fold-final-end-is-exclusive") {
            let value = policy(30, 90, zone: "America/New_York")
            try equals(value, "2026-11-01T06:30:00Z", "2026-11-01T06:30:00Z")
            try equals(value, "2026-11-01T06:30:00.001Z", "2026-11-01T06:30:00.001Z")
        }
        try run("overnight-window-spans-new-york-fold") {
            try equals(policy(1320, 90, zone: "America/New_York"), "2026-11-01T05:45:00Z", "2026-11-01T06:30:00Z")
        }
        try run("lord-howe-half-hour-fold-uses-last-end") {
            try equals(policy(60, 105, zone: "Australia/Lord_Howe"), "2026-04-04T14:50:00Z", "2026-04-04T15:15:00Z")
        }
        try run("lord-howe-unambiguous-end-stays-on-same-day") {
            try equals(policy(0, 60, zone: "Australia/Lord_Howe"), "2026-04-04T13:45:00Z", "2026-04-04T14:00:00Z")
        }
        try run("lord-howe-half-hour-gap-uses-next-real-time") {
            try equals(policy(90, 135, zone: "Australia/Lord_Howe"), "2026-10-03T15:25:00Z", "2026-10-03T15:30:00Z")
        }
        try run("original-due-date-never-reanchors-to-now") {
            let value = policy(1320, 480)
            try equals(value, "2020-12-31T23:30:00Z", "2021-01-01T08:00:00Z")
            try equals(value, "2020-02-28T23:30:00Z", "2020-02-29T08:00:00Z")
        }
        try run("invalid-minutes-including-integer-extremes") {
            for invalid in [Int.min, -1, 1440, Int.max] {
                try rejects(policy(invalid, 480), .invalidMinutes)
                try rejects(policy(1320, invalid), .invalidMinutes)
            }
        }
        try run("equal-boundaries-invalid-even-disabled") {
            for minute in [0, 1, 480, 1439] {
                try rejects(policy(minute, minute), .equalBoundaries)
                try rejects(policy(minute, minute, enabled: false), .equalBoundaries)
            }
        }
        try run("invalid-time-zones-never-fallback-silently") {
            for zone in ["", "No/Such_Zone", "../UTC", " UTC", "UTC ", String(repeating: "x", count: 129)] {
                try rejects(policy(1320, 480, zone: zone), .invalidTimeZone)
            }
            try expect(policy(1320, 480, zone: "GMT").validated().timeZoneIdentifier == "GMT", "GMT is an explicit supported zone")
        }
        try run("json-round-trip-preserves-exact-public-contract") {
            let value = policy(135, 825, zone: "Australia/Lord_Howe")
            let data = try JSONEncoder().encode(value)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try expect(Set(object.keys) == Set(["enabled", "startMinute", "endMinute", "timeZoneIdentifier"]), "JSON contract changed")
            try expect(JSONDecoder().decode(AssistantQuietHours.self, from: data).validated() == value, "JSON must round trip")
        }
        try run("malformed-json-types-and-decoded-invalid-settings") {
            for raw in ["{}", "{\"enabled\":\"true\",\"startMinute\":1320,\"endMinute\":480,\"timeZoneIdentifier\":\"UTC\"}"] {
                do { _ = try JSONDecoder().decode(AssistantQuietHours.self, from: Data(raw.utf8)); throw QuietTestFailure(description: "Malformed JSON must fail decoding") }
                catch is DecodingError { }
            }
            let invalid = try JSONEncoder().encode(policy(1500, 480))
            try rejects(JSONDecoder().decode(AssistantQuietHours.self, from: invalid), .invalidMinutes)
        }
        try run("nonfinite-and-pathological-finite-dates-are-rejected") {
            for seconds in [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, 1e100, -1e100] {
                for enabled in [false, true] {
                    do { _ = try policy(1320, 480, enabled: enabled).deliveryDate(for: Date(timeIntervalSince1970: seconds)); throw QuietTestFailure(description: "Extreme date must fail") }
                    catch AssistantQuietHoursError.invalidDate { }
                }
            }
        }
        try run("supported-range-does-not-wrap-or-overflow") {
            let unchanged = policy(1320, 480, enabled: false)
            for input in ["0001-01-01T00:00:00Z", "9999-12-31T23:59:59Z", "4001-01-01T12:00:00Z"] {
                let due = date(input)
                try expect(unchanged.deliveryDate(for: due) == due, "Supported disabled date must not wrap")
            }
            do { _ = try policy(1320, 480).deliveryDate(for: date("9999-12-31T23:00:00Z")); throw QuietTestFailure(description: "Deferral outside supported range must fail") }
            catch AssistantQuietHoursError.invalidDate { }
        }
        try run("concurrent-policy-use-is-deterministic") {
            let value = policy(30, 90, zone: "America/New_York")
            let due = date("2026-11-01T05:45:00Z"), expected = date("2026-11-01T06:30:00Z")
            let failures = QuietFailures()
            DispatchQueue.concurrentPerform(iterations: 500) { _ in
                do {
                    let output = try value.deliveryDate(for: due)
                    if output != expected { failures.add("Concurrent date calculation changed output") }
                    if !AssistantQuietHours.supportedTimeZoneIdentifiers.contains("UTC") { failures.add("Time zone cache changed") }
                } catch { failures.add(String(describing: error)) }
            }
            if let failure = failures.first { throw QuietTestFailure(description: failure) }
        }
    }
}
