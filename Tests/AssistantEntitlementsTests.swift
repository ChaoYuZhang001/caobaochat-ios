import Foundation

private struct EntitlementsTestFailure: Error, CustomStringConvertible { let description: String }

@main
private enum AssistantEntitlementsTests {
    private static let start = date("2026-10-01T00:00:00Z")
    private static let end = date("2026-11-01T00:00:00Z")
    private static let now = date("2026-10-15T12:00:00Z")
    private static var suiteCount = 0

    private static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try value() == false { throw EntitlementsTestFailure(description: message) }
    }
    private static func run(_ name: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch { throw EntitlementsTestFailure(description: "\(name): \(error)") }
        suiteCount += 1; print("PASS \(name)")
    }
    private static func status(_ value: String? = "active", included: Int = 713, remaining: Int = 117,
                               start: String = "2026-10-01T00:00:00Z", end: String = "2026-11-01T00:00:00Z") -> AssistantSubscriptionStatus {
        AssistantSubscriptionStatus(plan: "server-defined-plan", status: value, expiresAt: "2026-11-01T00:00:00Z",
            quota: AssistantSubscriptionQuota(included: included, remaining: remaining, periodStartsAt: start, periodEndsAt: end))
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
    private static func expectInvalidQuota(_ value: AssistantSubscriptionStatus, now: Date = now) throws {
        do { _ = try value.validatedBalance(now: now) }
        catch AssistantEntitlementValidationError.invalidSubscriptionQuota { return }
        catch { throw EntitlementsTestFailure(description: "Unexpected quota failure: \(error)") }
        throw EntitlementsTestFailure(description: "Invalid subscription quota was not rejected")
    }
    private static func expectInvalidSnapshot(_ value: AssistantSubscriptionStatus) throws {
        do { _ = try value.validatedServerSnapshot() }
        catch AssistantEntitlementValidationError.invalidSubscriptionStatus,
              AssistantEntitlementValidationError.invalidSubscriptionProduct,
              AssistantEntitlementValidationError.invalidSubscriptionExpiry,
              AssistantEntitlementValidationError.invalidSubscriptionSnapshot { return }
        catch { throw EntitlementsTestFailure(description: "Unexpected subscription snapshot failure: \(error)") }
        throw EntitlementsTestFailure(description: "Invalid subscription snapshot was not rejected")
    }
    private static func mustFailDecoding(_ json: String) throws {
        do { _ = try decode(AssistantSubscriptionStatus.self, json) }
        catch { return }
        throw EntitlementsTestFailure(description: "Malformed quota fields must fail decoding")
    }

    static func main() {
        do { try runAll() }
        catch { print("FAIL \(error)"); exit(1) }
    }

    private static func runAll() throws {
        try run("legacy-response-without-subscription-quota") {
            let legacy = try decode(AssistantEntitlementResponse.self, #"{"dailyRemaining":5,"dailyClaimed":true,"serviceRegion":"INTL","allowedModels":["server-model"],"subscription":{"plan":"plus","status":"active","expiresAt":"2026-11-01T00:00:00Z"}}"#)
            try expect(legacy.dailyRemaining == 5 && legacy.dailyClaimed, "Daily balance must remain independent of subscription")
            try expect(legacy.subscription?.quota == nil, "Legacy payload must not invent a missing quota")
            try expect(try legacy.subscription?.validatedBalance(now: now) == nil, "Missing monthly quota must remain unknown, never 600 or another fallback")
            let noSubscription = try decode(AssistantEntitlementResponse.self, #"{"dailyRemaining":0,"dailyClaimed":false,"serviceRegion":"CN","allowedModels":[]}"#)
            try expect(noSubscription.subscription == nil && noSubscription.dailyRemaining == 0, "Absent subscription is not an active plan")
            let partialLegacy = try decode(AssistantSubscriptionStatus.self, #"{"plan":"old-plan"}"#)
            try expect(try partialLegacy.validatedBalance(now: now) == nil, "Legacy missing status/quota must remain unknown")
        }
        try run("positive-balance-is-server-defined") {
            guard let balance = try status().validatedBalance(now: now) else { throw EntitlementsTestFailure(description: "Active in-period quota must be available") }
            try expect(balance.included == 713 && balance.remaining == 117, "Use actual server values, not proposed plan literals")
            try expect(balance.periodStartsAt == start && balance.periodEndsAt == end, "Billing boundaries must preserve server timestamps")
            let untouched = try decode(AssistantSubscriptionStatus.self, #"{"plan":"custom","status":"active","quota":{"included":42,"remaining":19,"periodStartsAt":"2026-10-01T00:00:00Z","periodEndsAt":"2026-11-01T00:00:00Z"}}"#)
            try expect(try untouched.validatedBalance(now: now)?.remaining == 19, "An independent plan's quota must not be rewritten")
        }
        try run("zero-and-exhausted-balances-remain-zero") {
            let zero = try status(included: 0, remaining: 0).validatedBalance(now: now)
            try expect(zero?.included == 0 && zero?.remaining == 0, "An explicit zero allocation is valid and must not become unknown or free credits")
            let exhausted = try status(included: 600, remaining: 0).validatedBalance(now: now)
            try expect(exhausted?.included == 600 && exhausted?.remaining == 0, "Exhausted monthly balance must display zero, not the daily allowance")
            let full = try status(included: 9, remaining: 9).validatedBalance(now: now)
            try expect(full?.remaining == 9, "Remaining equal to included is valid")
        }
        try run("negative-and-overallocated-balances-rejected") {
            try expectInvalidQuota(status(included: -1, remaining: 0))
            try expectInvalidQuota(status(included: 600, remaining: -1))
            try expectInvalidQuota(status(included: 8, remaining: 9))
            try expectInvalidQuota(status(included: 0, remaining: 1))
            try expectInvalidQuota(status(included: Int.min, remaining: Int.min))
            let largest = try status(included: Int.max, remaining: Int.max).validatedBalance(now: now)
            try expect(largest?.remaining == Int.max, "Range comparisons must not overflow")
        }
        try run("invalid-period-date-rejected") {
            for invalid in ["", "not-a-date", "2026-13-01T00:00:00Z", "2026-10-01", "2026-10-01T00:00:00"] {
                try expectInvalidQuota(status(start: invalid))
                try expectInvalidQuota(status(end: invalid))
            }
            // A calendar date that never existed must not be normalized into a grant.
            try expectInvalidQuota(status(start: "2026-02-30T00:00:00Z", end: "2026-04-01T00:00:00Z"), now: date("2026-03-10T00:00:00Z"))
            try expectInvalidQuota(status(start: "2026-10-01T25:00:00Z"))
            for year in [2024, 2000] {
                let leap = status(start: "\(year)-02-29T00:00:00Z", end: "\(year)-03-01T00:00:00Z")
                try expect(try leap.validatedBalance(now: date("\(year)-02-29T12:00:00Z")) != nil, "Real leap days, including year 2000, must remain valid")
            }
            for year in [1900, 2100] {
                try expectInvalidQuota(status(start: "\(year)-02-29T00:00:00Z", end: "\(year)-03-02T00:00:00Z"),
                    now: date("\(year)-03-01T12:00:00Z"))
            }
        }
        try run("equal-and-inverted-periods-rejected") {
            try expectInvalidQuota(status(start: "2026-10-01T00:00:00Z", end: "2026-10-01T00:00:00Z"))
            try expectInvalidQuota(status(start: "2026-11-01T00:00:00Z", end: "2026-10-01T00:00:00Z"))
        }
        try run("period-window-is-start-inclusive-end-exclusive") {
            try expect(try status().validatedBalance(now: start.addingTimeInterval(-0.001)) == nil, "Not-yet-started period cannot display a balance")
            try expect(try status().validatedBalance(now: start) != nil, "Period starts inclusively")
            try expect(try status().validatedBalance(now: end.addingTimeInterval(-0.001)) != nil, "Last instant before reset remains in period")
            try expect(try status().validatedBalance(now: end) == nil, "Exact reset boundary must stop displaying old balance")
            try expect(try status().validatedBalance(now: end.addingTimeInterval(1)) == nil, "Expired period cannot display old balance")
        }
        try run("subscription-status-allowlist") {
            for allowed in ["active", "trialing", "grace_period"] {
                try expect(try status(allowed).validatedBalance(now: now)?.remaining == 117, "Approved status must expose its verified in-period balance")
            }
            for rejected: String? in [nil, "", "unknown", "expired", "revoked", "cancelled", "pending", "ACTIVE", " active"] {
                try expect(try status(rejected).validatedBalance(now: now) == nil, "Unknown or inactive status must never enable quota")
            }
        }
        try run("server-entitlement-snapshot-contract") {
            let response = try decode(AssistantEntitlementResponse.self, #"{"dailyRemaining":8,"dailyClaimed":true,"serviceRegion":"CN","allowedModels":[],"subscription":{"status":"active","productId":"com.caobao.monthly","expiresAt":"2026-11-01T00:00:00Z"}}"#)
            let snapshot = try response.subscription?.validatedServerSnapshot()
            try expect(snapshot?.productId == "com.caobao.monthly" && snapshot?.status == "active",
                "Server product and lifecycle fields must survive decoding")
            let none = AssistantSubscriptionStatus(productId: nil, plan: nil, status: "none", expiresAt: nil, quota: nil)
            try expect(try none.validatedServerSnapshot().status == "none", "No-subscription snapshot remains explicit")
            try expectInvalidSnapshot(AssistantSubscriptionStatus(productId: "com.caobao.monthly", plan: nil, status: "unknown", expiresAt: nil, quota: nil))
            try expectInvalidSnapshot(AssistantSubscriptionStatus(productId: nil, plan: nil, status: "active", expiresAt: nil, quota: nil))
            try expectInvalidSnapshot(AssistantSubscriptionStatus(productId: "bad id", plan: nil, status: "expired", expiresAt: "2026-11-01T00:00:00Z", quota: nil))
            try expectInvalidSnapshot(AssistantSubscriptionStatus(productId: "com.caobao.monthly", plan: nil, status: "active", expiresAt: "not-a-date", quota: nil))
        }
        try run("fractional-and-timezone-offset-dates") {
            let quota = status(start: "2026-10-01T08:00:00.125+08:00", end: "2026-11-01T00:00:00.875-04:00")
            guard let balance = try quota.validatedBalance(now: now) else { throw EntitlementsTestFailure(description: "Offset/fractional ISO timestamps must be supported") }
            try expect(abs(balance.periodStartsAt.timeIntervalSince(start) - 0.125) < 0.000_1, "Positive timezone offset must normalize to the same instant")
            let expectedEnd = date("2026-11-01T04:00:00Z").addingTimeInterval(0.875)
            try expect(abs(balance.periodEndsAt.timeIntervalSince(expectedEnd)) < 0.000_1, "Negative timezone offset and fractions must preserve the reset instant")
        }
        try run("verified-time-freshness-and-future-clock") {
            let balance = try status().validatedBalance(now: now)!
            try expect(!balance.isFresh(verifiedAt: nil, now: now), "Missing verification is not fresh")
            try expect(balance.isFresh(verifiedAt: now, now: now), "Verification at now is fresh")
            try expect(balance.isFresh(verifiedAt: now.addingTimeInterval(-299.999), now: now), "Verification younger than default maximum age is fresh")
            try expect(!balance.isFresh(verifiedAt: now.addingTimeInterval(-300), now: now), "Verification exactly at maximum age is stale")
            try expect(!balance.isFresh(verifiedAt: now.addingTimeInterval(-301), now: now), "Older verification is stale")
            try expect(!balance.isFresh(verifiedAt: now.addingTimeInterval(0.001), now: now), "Future verification cannot appear fresh after clock rollback")
        }
        try run("custom-freshness-limits") {
            let balance = try status().validatedBalance(now: now)!
            try expect(!balance.isFresh(verifiedAt: now, now: now, maximumAge: 0), "Zero maximum age disables freshness")
            try expect(!balance.isFresh(verifiedAt: now, now: now, maximumAge: -1), "Negative maximum age cannot enable stale data")
            try expect(!balance.isFresh(verifiedAt: now, now: now, maximumAge: .nan), "NaN maximum age cannot enable freshness")
            try expect(balance.isFresh(verifiedAt: now.addingTimeInterval(-9), now: now, maximumAge: 10), "Custom positive maximum age applies")
            try expect(!balance.isFresh(verifiedAt: now.addingTimeInterval(-10), now: now, maximumAge: 10), "Custom exact age boundary is stale")
        }
        try run("freshness-also-enforces-reset-boundary") {
            let balance = try status().validatedBalance(now: now)!
            try expect(!balance.isFresh(verifiedAt: start.addingTimeInterval(-1), now: start.addingTimeInterval(-0.001)), "Fresh verification cannot expose a future billing period")
            try expect(balance.isFresh(verifiedAt: start, now: start), "Freshness can begin at exact billing start")
            try expect(balance.isFresh(verifiedAt: end.addingTimeInterval(-1), now: end.addingTimeInterval(-0.001)), "Fresh balance remains visible just before reset")
            try expect(!balance.isFresh(verifiedAt: end.addingTimeInterval(-1), now: end), "Even fresh verification cannot cross reset into the next period")
        }
        try run("quota-json-types-must-not-default") {
            for fragment in [
                #"{"included":"600","remaining":8,"periodStartsAt":"2026-10-01T00:00:00Z","periodEndsAt":"2026-11-01T00:00:00Z"}"#,
                #"{"included":600,"remaining":true,"periodStartsAt":"2026-10-01T00:00:00Z","periodEndsAt":"2026-11-01T00:00:00Z"}"#,
                #"{"included":600,"periodStartsAt":"2026-10-01T00:00:00Z","periodEndsAt":"2026-11-01T00:00:00Z"}"#,
                #"{"included":600,"remaining":8,"periodStartsAt":null,"periodEndsAt":"2026-11-01T00:00:00Z"}"#
            ] {
                try mustFailDecoding("{\"status\":\"active\",\"quota\":" + fragment + "}")
            }
            let nullable = try decode(AssistantSubscriptionStatus.self, #"{"status":"active","quota":null}"#)
            try expect(try nullable.validatedBalance(now: now) == nil, "Explicit null quota remains unknown")
        }
        print("All \(suiteCount) AssistantEntitlements suites passed; actual production types compiled, no network or Keychain used.")
    }
}
