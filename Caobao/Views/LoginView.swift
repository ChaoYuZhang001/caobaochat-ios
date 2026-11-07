import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var auth = AuthService.shared
    @State private var error: String?
    @State private var agreed = false
    @State private var showPrivacyPolicy = false
    @State private var showTerms = false
    @State private var showConnectionSettings = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image("Logo").resizable().scaledToFit().frame(width: 80, height: 80)
                    Text("草包").font(.system(.largeTitle, design: .rounded).bold())
                    Text("少点空话，把事情做好。").font(.title3.weight(.semibold))
                    Text("你的个人 AI 助理").foregroundStyle(.secondary)
                }.padding(.top, 36)
                VStack(spacing: 16) {
                    #if os(iOS) || os(macOS)
                    AppleSignInButton(onSuccess: {}, onError: { error = $0 })
                        .disabled(!agreed).opacity(agreed ? 1 : 0.5)
                    #endif
                    Button { showConnectionSettings = true } label: {
                        Label("使用自己的 API", systemImage: "key")
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!agreed)
                    Text("平台服务需要登录；自定义 API 可将数据保存在本机使用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("我已阅读并同意", isOn: $agreed)
                HStack(spacing: 16) {
                    Button("用户协议") { showTerms = true }
                    Button("隐私政策") { showPrivacyPolicy = true }
                }.font(.caption).tint(.caobaoPrimary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if let error = auth.sessionPersistenceError { Text(LocalizedStringKey(error)).font(.caption).foregroundStyle(.secondary) }
                if auth.isRefreshingSession { ProgressView("正在恢复登录状态…") }
                Group {
                    if dynamicTypeSize >= .accessibility1 {
                        VStack(alignment: .leading, spacing: 16) {
                            FeatureItem(icon: "checklist", title: "个人任务", color: .green)
                            FeatureItem(icon: "brain.head.profile", title: "可控记忆", color: .orange)
                            FeatureItem(icon: "globe", title: "多语言", color: .blue)
                        }
                    } else {
                        HStack(spacing: 24) {
                            FeatureItem(icon: "checklist", title: "个人任务", color: .green)
                            FeatureItem(icon: "brain.head.profile", title: "可控记忆", color: .orange)
                            FeatureItem(icon: "globe", title: "多语言", color: .blue)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: dynamicTypeSize >= .accessibility1 ? .leading : .center)
                .padding(.top, 24)
            }
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
            .padding(24)
        }
        .sheet(isPresented: $showConnectionSettings) { AssistantSettingsSheet().environmentObject(appState) }
        .sheet(isPresented: $showPrivacyPolicy) { NavigationStack { LegalView(type: .privacy) } }
        .sheet(isPresented: $showTerms) { NavigationStack { LegalView(type: .agreement) } }
    }
}

struct FeatureItem: View {
    let icon: String
    let title: String
    let color: Color
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            Text(LocalizedStringKey(title))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}
