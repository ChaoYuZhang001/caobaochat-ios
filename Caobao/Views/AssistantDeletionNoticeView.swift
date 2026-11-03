import SwiftUI

/// Place outside the authenticated/BYOK/login branches so logout cannot hide it.
struct AssistantDeletionNoticeView: View {
    let notice: AssistantDeletionNotice
    let isRetrying: Bool
    let onDismiss: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("账号删除处理结果", systemImage: notice.hasPendingLocalCleanup ? "exclamationmark.shield" : "checkmark.shield")
                .font(.headline)
            if notice.storageIssue {
                Text("无法读取或保存删除处理记录，原记录已保留。未能确认本机数据已清理，请联系支持。")
            } else {
                if notice.serverStatus == .completed { Text("服务器确认账号删除已完成。") }
                else { Text("服务器已受理账号删除，尚未收到删除完成确认。") }
                if notice.hasPendingLocalCleanup {
                    Text("部分本机数据尚未清理完成。你可以在退出登录后重试本地清理，重试不会再次请求服务器删除。")
                } else { Text("本机数据已清理。") }
            }
            HStack {
                if isRetrying { ProgressView(); Text("正在重试本地清理…") }
                else if notice.canRetry { Button("重试本地清理", action: onRetry).buttonStyle(.borderedProminent) }
                Spacer()
                Button("关闭", action: onDismiss).disabled(isRetrying)
            }
        }
        .font(.subheadline)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }
}
