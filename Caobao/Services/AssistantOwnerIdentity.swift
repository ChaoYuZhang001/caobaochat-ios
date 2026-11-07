import Foundation

/// Account identifiers are opaque bytes, not normalized user-facing text.
enum AssistantOwnerIdentity {
    static func matches(_ left: String?, _ right: String?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case let (left?, right?): return left.utf8.elementsEqual(right.utf8)
        default: return false
        }
    }

    /// A reversible, normalization-safe key for owner-scoped runtime state.
    static func ownerKey(_ ownerId: String) -> String {
        Data(ownerId.utf8).base64EncodedString()
    }
}

/// Owner-neutral HTTPS routes used by Universal Links. The caller is still
/// responsible for applying the route only after the authenticated owner is
/// known; this type only parses and validates the URL shape.
enum AssistantDeepLink: Equatable {
    case conversation(String)
    case task(String)
    case proactive(String)

    init?(url: URL) {
        guard url.scheme?.lowercased() == "https",
              ["caobao.chat", "www.caobao.chat"].contains(url.host?.lowercased() ?? "") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2,
              let rawID = parts.last,
              let id = rawID.removingPercentEncoding,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id.utf8.count <= 256 else { return nil }
        switch parts[0].lowercased() {
        case "conversation": self = .conversation(id)
        case "task": self = .task(id)
        case "proactive": self = .proactive(id)
        default: return nil
        }
    }
}
