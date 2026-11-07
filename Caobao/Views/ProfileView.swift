import SwiftUI
#if os(macOS)
import AppKit
#endif

#if !os(iOS)
// ProfileView belongs to the macOS target, whose sources omit ContentView.
// Keep the shared root-page call sites available without iOS column APIs.
extension View {
    func assistantSidebarRoot(isAtRoot: Bool = true) -> some View { self }
    func assistantSidebarChild() -> some View { self }
}
#endif

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var authService = AuthService.shared
    @State private var showAvatarPicker = false
    @State private var showNicknameEditor = false
    @State private var showLogoutConfirm = false
    @State private var newNickname = ""
    @State private var usageStats = AssistantUsageStats()
    @State private var profileOwnerEpoch = UUID()
    @State private var avatarOwnerSource: ProfileOwnerSource?
    @State private var nicknameOwnerSource: ProfileOwnerSource?
    @State private var logoutOwnerSource: ProfileOwnerSource?
    private struct ProfileOwnerSource { let ownerId: String; let epoch: UUID }
    private var liveOwnerId: String { authService.user?.id ?? "local-device" }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 渐变背景 - 蓝色系渐变（代表专业与信任）
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(hex: "3b82f6").opacity(0.08),
                        Color(hex: "60a5fa").opacity(0.05),
                        Color.caobaoGroupedBackground
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                List {
                    // Profile Header
                    Section {
                        HStack(spacing: 16) {
                            // Avatar
                            Button {
                                avatarOwnerSource = ProfileOwnerSource(ownerId: liveOwnerId, epoch: profileOwnerEpoch)
                                showAvatarPicker = true
                            } label: {
                                avatarView
                                    .frame(width: 70, height: 70)
                            }
                            .buttonStyle(.plain)
                            
                            // Info
                            VStack(alignment: .leading, spacing: 4) {
                                Text(appState.userSettings.nickname)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                
                                if let user = authService.user {
                                    Text(user.isGuest == true ? "游客账号" : "\(user.authProvider.capitalized) 登录")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Text("毒舌等级: \(toxicLevelText)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            nicknameOwnerSource = ProfileOwnerSource(ownerId: liveOwnerId, epoch: profileOwnerEpoch)
                            newNickname = appState.userSettings.nickname
                            showNicknameEditor = true
                        }
                    }
                
                // Stats
                Section {
                    StatRow(icon: "message.fill", title: "对话次数", value: "\(usageStats.userMessages)")
                    StatRow(icon: "calendar", title: "使用天数", value: "\(usageStats.usageDays)")
                    StatRow(icon: "flame.fill", title: "连续打卡", value: "\(usageStats.currentStreak)天")
                } header: {
                    Text("使用统计")
                }
                
                // 功能入口
                Section {
                    NavigationLink {
                        StatsView()
                    } label: {
                        Label("数据统计", systemImage: "chart.bar.fill")
                    }
                    
                    NavigationLink {
                        LocalQuoteFavoritesView()
                    } label: {
                        Label("本机金句收藏", systemImage: "heart.fill")
                    }
                    
                    NavigationLink {
                        FeedbackView()
                    } label: {
                        Label("意见反馈", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    }
                } header: {
                    Text("功能")
                }
                
                // Settings
                Section {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("更多设置", systemImage: "gearshape.fill")
                    }
                    
                    Picker("毒舌程度", selection: $appState.userSettings.toxicLevel) {
                        Text("温和").tag("light")
                        Text("标准").tag("normal")
                        Text("爆辣").tag("fierce")
                    }
                    .onChange(of: appState.userSettings.toxicLevel) { _ in
                        appState.saveUserSettings()
                    }
                    
                    // 账号设置 - 符合《个人信息保护法》
                    NavigationLink {
                        AccountSettingsView()
                    } label: {
                        Label("账号与数据", systemImage: "gearshape.circle")
                    }
                } header: {
                    Text("设置")
                }
                
                // 关于
                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("关于草包", systemImage: "info.circle")
                    }
                    
                    NavigationLink {
                        OfficialView()
                    } label: {
                        Label("草台班子", systemImage: "building.2")
                    }
                } header: {
                    Text("关于")
                }
                
                // 法律信息 - 符合 Apple App Store 审核指南 5.1.1
                Section {
                    NavigationLink {
                        LegalView(type: .privacy)
                    } label: {
                        Label("隐私政策", systemImage: "hand.raised.fill")
                    }
                    
                    NavigationLink {
                        LegalView(type: .agreement)
                    } label: {
                        Label("用户协议", systemImage: "doc.text.fill")
                    }
                    
                    NavigationLink {
                        LegalView(type: .children)
                    } label: {
                        Label("未成年人保护", systemImage: "figure.and.child.holdinghands")
                    }
                } header: {
                    Text("法律信息")
                }
                
                // Account Actions
                Section {
                    Button(role: .destructive) {
                        logoutOwnerSource = ProfileOwnerSource(ownerId: liveOwnerId, epoch: profileOwnerEpoch)
                        showLogoutConfirm = true
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .assistantNavigationTitle("我的")
            .assistantSidebarRoot()
            #if os(iOS)
            .sheet(isPresented: Binding(get: { showAvatarPicker && profileSourceIsCurrent(avatarOwnerSource) }, set: { showAvatarPicker = $0 })) {
                if let source = avatarOwnerSource, profileSourceIsCurrent(source) {
                AvatarPickerView(selectedSettings: avatarSettings(for: source))
                    .presentationDetents([.medium])
                    .id(AssistantOwnerIdentity.ownerKey(source.ownerId))
                }
            }
            #else
            .sheet(isPresented: Binding(get: { showAvatarPicker && profileSourceIsCurrent(avatarOwnerSource) }, set: { showAvatarPicker = $0 })) {
                if let source = avatarOwnerSource, profileSourceIsCurrent(source) {
                AvatarPickerView(selectedSettings: avatarSettings(for: source))
                    .frame(width: 400, height: 500)
                    .id(AssistantOwnerIdentity.ownerKey(source.ownerId))
                }
            }
            #endif
            .alert("修改昵称", isPresented: Binding(get: { showNicknameEditor && profileSourceIsCurrent(nicknameOwnerSource) }, set: { showNicknameEditor = $0 }),
                   presenting: nicknameOwnerSource) { source in
                TextField("昵称", text: $newNickname)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    guard profileSourceIsCurrent(source) else { return }
                    if !newNickname.trimmingCharacters(in: .whitespaces).isEmpty {
                        appState.userSettings.nickname = newNickname
                        appState.saveUserSettings()
                    }
                }
            } message: { _ in
                Text("请输入新昵称")
            }
            .alert("确认退出", isPresented: Binding(get: { showLogoutConfirm && profileSourceIsCurrent(logoutOwnerSource) }, set: { showLogoutConfirm = $0 }),
                   presenting: logoutOwnerSource) { source in
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) {
                    guard profileSourceIsCurrent(source) else { return }
                    authService.logout()
                }
            } message: { _ in
                Text("确定要退出登录吗？")
            }
            .onAppear {
                newNickname = appState.userSettings.nickname
                loadUsageStats()
            }
            .onChange(of: AssistantOwnerIdentity.ownerKey(liveOwnerId)) { _ in
                resetProfileOwnerScope()
                loadUsageStats()
            }
            .onReceive(NotificationCenter.default.publisher(for: .loginSuccess)) { _ in
                resetProfileOwnerScope()
                loadUsageStats()
            }
            .onReceive(NotificationCenter.default.publisher(for: .logoutSuccess)) { _ in
                resetProfileOwnerScope()
                loadUsageStats()
            }
            }
        }
    }
    
    private func profileSourceIsCurrent(_ source: ProfileOwnerSource?) -> Bool {
        guard let source else { return false }
        return source.epoch == profileOwnerEpoch && AssistantOwnerIdentity.matches(source.ownerId, liveOwnerId)
    }
    private func avatarSettings(for source: ProfileOwnerSource) -> Binding<UserSettings> {
        Binding(get: { appState.userSettings }, set: { value in
            guard profileSourceIsCurrent(source) else { return }
            appState.userSettings = value
        })
    }
    private func resetProfileOwnerScope() {
        profileOwnerEpoch = UUID()
        showAvatarPicker = false; showNicknameEditor = false; showLogoutConfirm = false
        avatarOwnerSource = nil; nicknameOwnerSource = nil; logoutOwnerSource = nil
        newNickname = ""
    }

    private func loadUsageStats() {
        usageStats = AssistantUsageStatsStore.shared.snapshot(ownerId: liveOwnerId)
    }

    // MARK: - Avatar View
    @ViewBuilder
    private var avatarView: some View {
        if let emoji = appState.userSettings.avatarEmoji {
            Text(emoji)
                .font(.system(size: 36))
                .frame(width: 70, height: 70)
                .background(Color.caobaoGroupedBackground)
                .clipShape(Circle())
        } else if let url = appState.userSettings.avatarUrl, !url.isEmpty {
            AsyncImage(url: URL(string: url)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure(_):
                    Text(String(appState.userSettings.nickname.prefix(1)))
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.blue)
                case .empty:
                    ProgressView()
                @unknown default:
                    ProgressView()
                }
            }
            .frame(width: 70, height: 70)
            .clipShape(Circle())
        } else {
            Text(String(appState.userSettings.nickname.prefix(1)))
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 70, height: 70)
                .background(Color.blue)
                .clipShape(Circle())
        }
    }
    
    // MARK: - Toxic Level Text
    private var toxicLevelText: String {
        switch appState.userSettings.toxicLevel {
        case "light": return AssistantLocalization.string("温和")
        case "normal": return AssistantLocalization.string("标准")
        case "fierce": return AssistantLocalization.string("爆辣")
        default: return AssistantLocalization.string("标准")
        }
    }
}

// MARK: - Stat Row
struct StatRow: View {
    let icon: String
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Label(AssistantLocalization.string(title), systemImage: icon)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.green)
        }
    }
}

// MARK: - Avatar Picker View
struct AvatarPickerView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var selectedSettings: UserSettings
    
    private let presetAvatars = ["default", "avatar1", "avatar2", "avatar3", "avatar4", "avatar5", "avatar6", "avatar7", "avatar8"]
    private let emojiAvatars = ["😊", "😎", "🤓", "😴", "🥳", "🤔", "😏", "🤗", "😺", "🦊", "🐼", "🐨"]
    
    @State private var selectedTab = 0
    
    var body: some View {
        NavigationStack {
            VStack {
                Picker("类型", selection: $selectedTab) {
                    Text("预设头像").tag(0)
                    Text("表情头像").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()
                
                TabView(selection: $selectedTab) {
                    // Preset Avatars
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 16) {
                        ForEach(presetAvatars, id: \.self) { avatar in
                            avatarButton(avatarId: avatar, type: "preset")
                        }
                    }
                    .padding()
                    .tag(0)
                    
                    // Emoji Avatars
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
                        ForEach(emojiAvatars, id: \.self) { emoji in
                            emojiButton(emoji)
                        }
                    }
                    .padding()
                    .tag(1)
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #else
                .tabViewStyle(.automatic)
                #endif
            }
            .assistantNavigationTitle("选择头像")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
                #else
                ToolbarItem(placement: .primaryAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
                #endif
            }
        }
    }
    
    private func avatarButton(avatarId: String, type: String) -> some View {
        Button {
            selectedSettings.avatarType = type
            selectedSettings.avatarValue = avatarId
        } label: {
            ZStack {
                Circle()
                    .fill(Color.caobaoGroupedBackground)
                    .frame(width: 80, height: 80)
                
                // 加载预设头像图片
                if avatarId == "default" {
                    // 使用本地默认头像（无需网络请求）
                    Image("DefaultAvatar")
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                } else {
                    // 网络头像 - 支持WebP和PNG，自动缓存
                    AvatarImageView(avatarId: avatarId)
                        .frame(width: 76, height: 76)
                }
                
                if selectedSettings.avatarType == type && selectedSettings.avatarValue == avatarId {
                    Circle()
                        .stroke(Color.green, lineWidth: 3)
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .offset(x: 28, y: 28)
                }
            }
        }
        .buttonStyle(.plain)
    }
    
    private func emojiButton(_ emoji: String) -> some View {
        Button {
            selectedSettings.avatarType = "emoji"
            selectedSettings.avatarValue = emoji
        } label: {
            ZStack {
                Text(emoji)
                    .font(.system(size: 40))
                    .frame(width: 70, height: 70)
                    .background(Color.caobaoGroupedBackground)
                    .clipShape(Circle())
                
                if selectedSettings.avatarType == "emoji" && selectedSettings.avatarValue == emoji {
                    Circle()
                        .stroke(Color.green, lineWidth: 3)
                        .frame(width: 70, height: 70)
                    
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .offset(x: 25, y: 25)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
