import SwiftUI

/// A presentation of persisted proposal/receipt state. Callers resolve a fresh
/// VM source before opening an editor or requesting any action. This card never
/// executes task writes, notification requests, or model calls itself.
@MainActor
struct AssistantTaskToolProposalView: View {
    @Environment(\.locale) private var locale
    enum Phase: Equatable { case pending, declined, saved, resultUnconfirmed }
    enum ReminderOutcome { case notEnabled, scheduled, failed, unconfirmed }

    let title: String
    let notes: String?
    let dueAt: Date?
    let timeZone: String
    let reminderSuggested: Bool
    let proposalIsComplete: Bool
    let continuationAttempted: Bool
    let phase: Phase
    let reminderOutcome: ReminderOutcome
    let isHistorical: Bool
    let isBusy: Bool
    let canReview: Bool
    let canDecline: Bool
    let canContinue: Bool
    let operationError: String?
    let onReview: () -> Void
    let onDecline: () -> Void
    let onContinue: () -> Void
    let onOpenCurrentChat: () -> Void

    init(proposal: AssistantTaskProposal, receipt: AssistantTaskToolReceipt?, isHistorical: Bool, isBusy: Bool,
         canReview: Bool, canDecline: Bool, canContinue: Bool, proposalIsComplete: Bool = true,
         receiptReadFailed: Bool = false, operationError: String? = nil,
         onReview: @escaping () -> Void, onDecline: @escaping () -> Void,
         onContinue: @escaping () -> Void, onOpenCurrentChat: @escaping () -> Void) {
        title = proposal.arguments.title; notes = proposal.arguments.notes
        dueAt = proposal.arguments.parsedDueDate
        timeZone = proposal.arguments.timeZone ?? AssistantTaskTimeZonePolicy.defaultIdentifier
        reminderSuggested = proposal.arguments.reminderRequested
        self.proposalIsComplete = proposalIsComplete
        let validReceipt = receipt.flatMap { value -> AssistantTaskToolReceipt? in
            guard value.isValid(ownerId: proposal.ownerId, proposalId: proposal.id),
                  value.decision == .declined ? value.taskId == nil : value.taskId == proposal.taskId else { return nil }
            return value
        }
        if let validReceipt { phase = validReceipt.decision == .saved ? .saved : .declined }
        else { phase = receipt == nil && !receiptReadFailed && proposalIsComplete ? .pending : .resultUnconfirmed }
        continuationAttempted = validReceipt?.continuationAttemptId != nil
        switch validReceipt?.reminderState {
        case .some(.notRequested): reminderOutcome = .notEnabled
        case .some(.scheduled): reminderOutcome = .scheduled
        case .some(.failed): reminderOutcome = .failed
        default: reminderOutcome = .unconfirmed
        }
        self.isHistorical = isHistorical; self.isBusy = isBusy
        self.canReview = canReview && phase == .pending && proposalIsComplete && !receiptReadFailed
        self.canDecline = canDecline && phase == .pending && proposalIsComplete && !receiptReadFailed
        self.canContinue = canContinue && validReceipt != nil && proposalIsComplete && !continuationAttempted
        self.operationError = operationError
        self.onReview = onReview; self.onDecline = onDecline
        self.onContinue = onContinue; self.onOpenCurrentChat = onOpenCurrentChat
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("AI 待办提案", systemImage: "checklist").font(.headline)
                Spacer()
                Text(phaseTitle).font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: title).font(.subheadline.bold()).textSelection(.enabled)
            if let notes, !notes.isEmpty {
                Text(verbatim: notes).font(.subheadline).textSelection(.enabled)
            }
            if let dueAt {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "calendar")
                    Text(verbatim: formattedDueDate(dueAt))
                    Text(verbatim: timeZone).font(.caption).foregroundStyle(.secondary)
                }
            }
            if phase == .saved {
                Text(reminderTitle).font(.caption).foregroundStyle(.secondary)
                Text("卡片保留原始 AI 提案；确认时可能已修改内容。实际待办与提醒状态请在任务列表查看。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if reminderSuggested, phase == .pending {
                Text("模型建议开启提醒；默认关闭，需你明确选择。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !proposalIsComplete {
                Text("这条提案来源未完成，仅供查看，不会创建待办。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if phase == .pending, !canReview, canDecline, !isBusy {
                Text("来源或接入设置已变化，不能保存这条提案；你仍可拒绝它。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if continuationAttempted {
                Text("已使用一次继续尝试；尝试可能失败，不代表请求已发送或回复已完成。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let operationError { Text(verbatim: operationError).font(.caption).foregroundStyle(.red) }
            if isHistorical {
                Text("历史记录仅供查看；如需处理，请进入当前对话重新核验。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(proposalIsComplete ? LocalizedStringKey("在当前对话中处理") : LocalizedStringKey("查看当前对话"), action: onOpenCurrentChat)
                    .frame(minHeight: 44).disabled(isBusy)
            } else {
                if phase == .pending {
                    Button("查看并确认待办", action: onReview)
                        .buttonStyle(.borderedProminent).tint(.caobaoPrimary)
                        .frame(minHeight: 44).disabled(!canReview || isBusy)
                    Button("拒绝提案", role: .destructive, action: onDecline)
                        .frame(minHeight: 44).disabled(!canDecline || isBusy)
                }
                if canContinue {
                    Button("让助理继续", action: onContinue).frame(minHeight: 44).disabled(isBusy)
                    Text("继续仅允许一次尝试，可能新增 API 请求和费用；失败不重复创建待办。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if isBusy { ProgressView().frame(minHeight: 44) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .caobaoCard()
        .accessibilityElement(children: .contain)
    }

    private func formattedDueDate(_ date: Date) -> String {
        let zone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)!
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: zone)
        // Resolve the zone before SwiftUI applies its Text environment.
        return date.formatted(style)
    }

    private var phaseTitle: LocalizedStringKey {
        switch phase {
        case .pending: return "待确认"
        case .declined: return "已拒绝"
        case .saved: return "待办已保存"
        case .resultUnconfirmed: return "结果待确认"
        }
    }
    private var reminderTitle: LocalizedStringKey {
        switch reminderOutcome {
        case .notEnabled: return "创建时未请求提醒"
        case .scheduled: return "保存时已安排提醒（不代表送达）"
        case .failed: return "待办已保存；创建时的提醒安排失败。"
        case .unconfirmed: return "待办已保存；创建时的提醒结果待确认。"
        }
    }
}
