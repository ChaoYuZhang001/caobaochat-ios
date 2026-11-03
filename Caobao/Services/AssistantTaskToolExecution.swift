import Foundation

@MainActor
final class AssistantTaskToolCommitGuard {
    private let check: @MainActor () throws -> Void
    init(_ check: @escaping @MainActor () throws -> Void) { self.check = check }
    func validate() throws { try Task.checkCancellation(); try check() }
}

typealias AssistantTaskToolReminderOperation = @MainActor (AssistantTask, AssistantTaskToolCommitGuard) async throws -> Void

struct AssistantTaskToolExecutionOutcome {
    let receipt: AssistantTaskToolReceipt
    let task: AssistantTask?
    let reminderFailureMessage: String?
}

/// Approval creates one real task and its receipt in one repository write.
/// Notification scheduling is a separate, explicitly requested operation on the
/// already saved task; an error must never cause another task to be inserted.
@MainActor
final class AssistantTaskToolExecutionCoordinator {
    private let repository: AssistantLocalRepositoryProtocol
    private var inFlight: [String: UUID] = [:]
    init(repository: AssistantLocalRepositoryProtocol) { self.repository = repository }

    func receipt(for proposal: AssistantTaskProposal) throws -> AssistantTaskToolReceipt? {
        try validateProposal(proposal)
        do { return try repository.taskToolReceipt(proposalId: proposal.id, ownerId: proposal.ownerId) }
        catch { throw AssistantTaskToolError.persistenceFailed }
    }

    func approve(proposal: AssistantTaskProposal, editedTask: AssistantTask, enableReminder: Bool,
                 validate: @escaping @MainActor () throws -> Void,
                 scheduleReminder: AssistantTaskToolReminderOperation? = nil) async throws -> AssistantTaskToolExecutionOutcome {
        try Task.checkCancellation(); try validateProposal(proposal); try validate()
        let key = executionKey(proposal)
        guard inFlight[key] == nil else { throw AssistantTaskToolError.alreadyResolved }
        let operation = UUID(); inFlight[key] = operation
        defer { if inFlight[key] == operation { inFlight.removeValue(forKey: key) } }
        if let existing = try receipt(for: proposal) {
            guard existing.decision == .saved else { throw AssistantTaskToolError.alreadyResolved }
            return outcome(existing, proposal: proposal)
        }
        guard editedTask.id == proposal.taskId,
              editedTask.userId.utf8.elementsEqual(proposal.ownerId.utf8),
              editedTask.sourceMessageId?.utf8.elementsEqual(proposal.assistantMessageId.utf8) == true,
              editedTask.requiresApproval, editedTask.status == .active, editedTask.recurrenceRule == nil,
              !enableReminder || editedTask.dueAt != nil,
              editedTask.dueAt?.timeIntervalSince1970.isFinite ?? true else { throw AssistantTaskToolError.invalidArguments }
        try AssistantWorkspaceValidation.validateTask(title: editedTask.title, instructions: editedTask.instructions)
        _ = try AssistantTaskTimeZonePolicy.validatedIdentifier(editedTask.timeZone)
        guard !repository.tasks(for: proposal.ownerId).contains(where: { $0.id == proposal.taskId }) else { throw AssistantTaskToolError.taskConflict }
        var base = editedTask
        base.reminderEnabled = false
        let initial = AssistantTaskToolReceipt(ownerId: proposal.ownerId, proposalId: proposal.id, taskId: proposal.taskId,
            decision: .saved, reminderState: enableReminder ? .pending : .notRequested, committedAt: Date(), revision: 1)
        // No suspension between this final source check and the atomic write.
        try validate(); try Task.checkCancellation()
        let committed: AssistantTaskToolReceipt
        do { committed = try repository.commitTaskToolTask(base, receipt: initial) }
        catch { throw AssistantTaskToolError.persistenceFailed }
        guard committed.decision == .saved else { throw AssistantTaskToolError.alreadyResolved }
        guard enableReminder, committed.reminderState == .pending else { return outcome(committed, proposal: proposal) }
        let savedTask = repository.tasks(for: proposal.ownerId).first { $0.id == proposal.taskId }
        guard let savedTask else { return outcome(committed, proposal: proposal, uncertain: true) }
        let commitGuard = AssistantTaskToolCommitGuard { [weak self] in
            guard let self, self.inFlight[key] == operation else { throw AssistantTaskToolError.sourceChanged }
            try validate()
            guard let current = try self.repository.taskToolReceipt(proposalId: proposal.id, ownerId: proposal.ownerId),
                  current.decision == .saved, current.taskId == proposal.taskId,
                  current.reminderState == .pending, current.continuationAttemptId == nil else { throw AssistantTaskToolError.sourceChanged }
        }
        do {
            try commitGuard.validate()
            guard let scheduleReminder else { throw AssistantTaskToolError.unavailable }
            try await scheduleReminder(savedTask, commitGuard)
            try commitGuard.validate()
            guard repository.tasks(for: proposal.ownerId).contains(where: { $0.id == proposal.taskId && $0.reminderEnabled == true }) else {
                throw AssistantTaskToolError.persistenceFailed
            }
        } catch {
            // A source change or cancellation after task commit does not undo a
            // real task, and must not write metadata into a now inactive owner.
            var sourceIsCurrent = true
            do { try commitGuard.validate() } catch { sourceIsCurrent = false }
            if Task.isCancelled || !sourceIsCurrent {
                return outcome(committed, proposal: proposal, uncertain: true)
            }
            if let failed = try? completeReminder(proposal: proposal, state: .failed, validate: validate) {
                return outcome(failed, proposal: proposal)
            }
            return outcome(committed, proposal: proposal, uncertain: true)
        }
        // Scheduling already succeeded. A receipt write failure is unknown,
        // not a scheduling failure, and must not trigger a second metadata write.
        do { return outcome(try completeReminder(proposal: proposal, state: .scheduled, validate: validate), proposal: proposal) }
        catch { return outcome(committed, proposal: proposal, uncertain: true) }
    }

    func decline(proposal: AssistantTaskProposal, validate: @escaping @MainActor () throws -> Void) throws -> AssistantTaskToolReceipt {
        try Task.checkCancellation(); try validateProposal(proposal); try validate()
        guard inFlight[executionKey(proposal)] == nil else { throw AssistantTaskToolError.alreadyResolved }
        if let existing = try receipt(for: proposal) {
            guard existing.decision == .declined else { throw AssistantTaskToolError.alreadyResolved }
            return existing
        }
        let value = AssistantTaskToolReceipt(ownerId: proposal.ownerId, proposalId: proposal.id, taskId: nil,
            decision: .declined, reminderState: .notRequested, committedAt: Date(), revision: 1)
        try validate(); try Task.checkCancellation()
        do { return try repository.commitTaskToolDecline(value) }
        catch { throw AssistantTaskToolError.persistenceFailed }
    }

    func claimContinuation(proposal: AssistantTaskProposal, validate: @escaping @MainActor () throws -> Void) throws -> AssistantTaskToolReceipt {
        try Task.checkCancellation(); try validateProposal(proposal); try validate()
        guard let existing = try receipt(for: proposal), existing.continuationAttemptId == nil,
              existing.reminderState != .pending, inFlight[executionKey(proposal)] == nil else { throw AssistantTaskToolError.alreadyResolved }
        try validate(); try Task.checkCancellation()
        do {
            return try repository.claimTaskToolContinuation(proposalId: proposal.id, ownerId: proposal.ownerId,
                expectedRevision: existing.revision, attemptId: UUID().uuidString)
        } catch { throw AssistantTaskToolError.persistenceFailed }
    }

    /// Only real local outcomes are sent. Provider arguments never assert success.
    /// Later edits/deletion are reflected without recreating a task or reminder.
    func outputJSON(for proposal: AssistantTaskProposal) throws -> String {
        guard let receipt = try receipt(for: proposal) else { throw AssistantTaskToolError.decisionRequired }
        var result: [String: Any] = ["status": receipt.decision == .declined ? "declined" : "task_saved",
            "reminder_status": receipt.reminderState.rawValue,
            "reminder_status_scope": "creation",
            "current_reminder_enabled": NSNull()]
        if receipt.decision == .saved {
            result["task_id"] = proposal.taskId
            if let task = repository.tasks(for: proposal.ownerId).first(where: { $0.id == proposal.taskId }) {
                guard task.userId.utf8.elementsEqual(proposal.ownerId.utf8) else { throw AssistantTaskToolError.sourceChanged }
                result["title"] = task.title
                result["task_status"] = task.status.rawValue
                result["time_zone"] = task.timeZone
                // This is the current saved preference, not notification
                // authorization, an active system schedule, or delivery proof.
                result["current_reminder_enabled"] = task.reminderEnabled == true
                if let dueAt = task.dueAt {
                    let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    result["due_at"] = format.string(from: dueAt)
                } else { result["due_at"] = NSNull() }
            } else { result["status"] = "task_no_longer_available" }
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= AssistantTaskToolCall.maximumArgumentBytes else { throw AssistantTaskToolError.tooLarge }
        return String(decoding: data, as: UTF8.self)
    }

    private func completeReminder(proposal: AssistantTaskProposal, state: AssistantTaskToolReminderState,
                                  validate: @MainActor () throws -> Void) throws -> AssistantTaskToolReceipt {
        try Task.checkCancellation(); try validate()
        guard var existing = try receipt(for: proposal), existing.decision == .saved,
              existing.reminderState == .pending, existing.continuationAttemptId == nil else { throw AssistantTaskToolError.sourceChanged }
        let revision = existing.revision; existing.reminderState = state; existing.revision += 1
        try validate()
        do { return try repository.updateTaskToolReceipt(existing, expectedRevision: revision) }
        catch { throw AssistantTaskToolError.persistenceFailed }
    }

    private func validateProposal(_ proposal: AssistantTaskProposal) throws {
        try proposal.validate(ownerId: proposal.ownerId, conversationId: proposal.conversationId, messageId: proposal.assistantMessageId)
    }
    private func executionKey(_ proposal: AssistantTaskProposal) -> String { Data(proposal.ownerId.utf8).base64EncodedString() + "|" + proposal.id }
    private func outcome(_ receipt: AssistantTaskToolReceipt, proposal: AssistantTaskProposal, uncertain: Bool = false) -> AssistantTaskToolExecutionOutcome {
        let task = receipt.decision == .saved ? repository.tasks(for: proposal.ownerId).first(where: { $0.id == proposal.taskId }) : nil
        let message: String?
        if uncertain || receipt.reminderState == .pending || receipt.reminderState == .unknown {
            message = AssistantLocalization.string("待办已保存；提醒结果尚未确认，请到任务列表检查。")
        } else if receipt.reminderState == .failed {
            message = AssistantLocalization.string("待办已保存，但提醒未能开启。你可以在任务中再次开启提醒。")
        } else { message = nil }
        return AssistantTaskToolExecutionOutcome(receipt: receipt, task: task, reminderFailureMessage: message)
    }
}
