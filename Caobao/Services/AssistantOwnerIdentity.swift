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
