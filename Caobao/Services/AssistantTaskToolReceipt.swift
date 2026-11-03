import Foundation

enum AssistantTaskToolDecision: String, Codable, Hashable, Sendable { case saved, declined }
enum AssistantTaskToolReminderState: String, Codable, Hashable, Sendable {
    case notRequested, pending, scheduled, failed, unknown
}

/// Metadata only: the task and this receipt share one repository commit.
/// A retained saved receipt prevents a deleted task from being recreated.
struct AssistantTaskToolReceipt: Codable, Hashable, Sendable {
    let ownerId: String
    let proposalId: String
    let taskId: String?
    let decision: AssistantTaskToolDecision
    var reminderState: AssistantTaskToolReminderState
    let committedAt: Date
    var revision: Int
    /// A durable attempt claim, independent of editable/deletable chat rows.
    var continuationAttemptId: String? = nil

    /// The store explicitly writes Unix seconds. Choose that representation
    /// before publishing a receipt so a restart cannot change CAS equality.
    func canonicalizedForStorage() -> AssistantTaskToolReceipt {
        AssistantTaskToolReceipt(ownerId: ownerId, proposalId: proposalId, taskId: taskId, decision: decision,
            reminderState: reminderState, committedAt: Date(timeIntervalSince1970: committedAt.timeIntervalSince1970),
            revision: revision, continuationAttemptId: continuationAttemptId)
    }

    func isValid(ownerId: String, proposalId: String) -> Bool {
        guard self.ownerId.utf8.elementsEqual(ownerId.utf8), self.proposalId.utf8.elementsEqual(proposalId.utf8),
              !ownerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ownerId.utf8.count <= 1_024,
              proposalId.hasPrefix("proposal-"), Self.isDigest(String(proposalId.dropFirst(9))),
              committedAt.timeIntervalSince1970.isFinite, revision > 0, revision < Int.max,
              continuationAttemptId.map({ UUID(uuidString: $0) != nil }) ?? true else { return false }
        switch decision {
        case .declined: return taskId == nil && reminderState == .notRequested
        case .saved:
            guard let taskId, taskId.hasPrefix("tool-task-") else { return false }
            return Self.isDigest(String(taskId.dropFirst(10)))
        }
    }
    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
