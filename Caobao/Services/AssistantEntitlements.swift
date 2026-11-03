import Foundation

struct DailyQuotaResponse: Codable {
    let serviceDay: String
    let granted: Int
    let remaining: Int
    let claimed: Bool
    let nextResetAt: String?
}

struct AssistantSubscriptionStatus: Codable {
    /// Server-owned App Store product identifier. `plan` remains for older
    /// deployments that used the legacy field name.
    let productId: String?
    let plan: String?
    let status: String?
    let expiresAt: String?
    /// Optional until the server supplies a verified quota for this account.
    let quota: AssistantSubscriptionQuota?

    init(productId: String? = nil, plan: String?, status: String?, expiresAt: String?, quota: AssistantSubscriptionQuota?) {
        self.productId = productId
        self.plan = plan
        self.status = status
        self.expiresAt = expiresAt
        self.quota = quota
    }

    func validatedBalance(now: Date = Date()) throws -> AssistantSubscriptionBalance? {
        guard let quota else { return nil }
        guard ["active", "trialing", "grace_period"].contains(status ?? "") else { return nil }
        guard quota.included >= 0, quota.remaining >= 0, quota.remaining <= quota.included,
              let start = AssistantEntitlementDate.parse(quota.periodStartsAt),
              let end = AssistantEntitlementDate.parse(quota.periodEndsAt),
              end > start else { throw AssistantEntitlementValidationError.invalidSubscriptionQuota }
        guard start <= now, now < end else { return nil }
        return AssistantSubscriptionBalance(included: quota.included, remaining: quota.remaining,
                                            periodStartsAt: start, periodEndsAt: end)
    }

    /// Validates the identity and lifecycle fields of the server-owned
    /// entitlement snapshot before a UI presents it. This does not grant any
    /// local entitlement; the server remains the admission authority.
    func validatedServerSnapshot() throws -> AssistantSubscriptionStatus {
        let allowedStatuses = ["none", "active", "trialing", "grace_period", "expired", "refunded", "revoked"]
        guard let status, allowedStatuses.contains(status) else {
            throw AssistantEntitlementValidationError.invalidSubscriptionStatus
        }
        if let productId {
            let value = productId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 200,
                  value.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else {
                throw AssistantEntitlementValidationError.invalidSubscriptionProduct
            }
        }
        if let expiresAt {
            guard AssistantEntitlementDate.parse(expiresAt) != nil else {
                throw AssistantEntitlementValidationError.invalidSubscriptionExpiry
            }
        }
        if status == "none" {
            guard productId == nil || productId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
                  expiresAt == nil || expiresAt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true else {
                throw AssistantEntitlementValidationError.invalidSubscriptionSnapshot
            }
        } else {
            guard let productId, !productId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AssistantEntitlementValidationError.invalidSubscriptionProduct
            }
            if ["active", "trialing", "grace_period"].contains(status), expiresAt == nil {
                throw AssistantEntitlementValidationError.invalidSubscriptionExpiry
            }
        }
        return self
    }
}

struct AssistantSubscriptionQuota: Codable {
    let included: Int
    let remaining: Int
    let periodStartsAt: String
    let periodEndsAt: String
}

struct AssistantSubscriptionBalance: Equatable {
    let included: Int
    let remaining: Int
    let periodStartsAt: Date
    let periodEndsAt: Date

    func isFresh(verifiedAt: Date?, now: Date = Date(), maximumAge: TimeInterval = 300) -> Bool {
        guard let verifiedAt, maximumAge > 0 else { return false }
        let age = now.timeIntervalSince(verifiedAt)
        return age >= 0 && age < maximumAge && periodStartsAt <= now && now < periodEndsAt
    }
}

struct AssistantEntitlementResponse: Codable {
    let dailyRemaining: Int
    let dailyClaimed: Bool
    let serviceRegion: String
    let regionSource: String?
    let allowedModels: [String]
    let subscription: AssistantSubscriptionStatus?
    let nextResetAt: String?
}

enum AssistantEntitlementValidationError: Error {
    case invalidSubscriptionQuota
    case invalidSubscriptionStatus
    case invalidSubscriptionProduct
    case invalidSubscriptionExpiry
    case invalidSubscriptionSnapshot
}

private enum AssistantEntitlementDate {
    private static let shape = try? NSRegularExpression(
        pattern: #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]{1,9})?(Z|[+-]([0-9]{2}):([0-9]{2}))$"#)

    static func parse(_ value: String) -> Date? {
        // ISO8601DateFormatter normalizes e.g. February 30 into March. Check
        // the actual calendar components before accepting a server quota period.
        guard value.utf8.count <= 40,
              let match = shape?.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let text = value as NSString
        func component(_ index: Int) -> Int? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : Int(text.substring(with: range))
        }
        guard let year = component(1), year >= 1, let month = component(2), (1...12).contains(month),
              let day = component(3), let hour = component(4), (0...23).contains(hour),
              let minute = component(5), (0...59).contains(minute),
              let second = component(6), (0...59).contains(second) else { return nil }
        let leap = year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...days[month - 1]).contains(day) else { return nil }
        if let offsetHour = component(8), let offsetMinute = component(9) {
            guard (0...23).contains(offsetHour), (0...59).contains(offsetMinute) else { return nil }
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
