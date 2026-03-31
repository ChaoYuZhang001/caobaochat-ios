import SwiftUI
import AuthenticationServices

struct ProfileView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var authService = AuthService.shared
    @State private var showAvatarPicker = false
    @State private var showNicknameEditor = false
    @State private var showLogoutConfirm = false
    @State private var showUpgradeSheet = false
    @State private var isUpgrading = false
    @State private var upgradeError: String?
    @State private var newNickname = ""
    
    var body: some View {
        NavigationStack {
            List {
                // Profile Header
                Section {
                    HStack(spacing: 16) {
                        // Avatar
                        Button {
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
                        showNicknameEditor = true
                    }
                }
                
                // Stats
                Section {
                    StatRow(icon: "message.fill", title: "对话次数", value: "\(appState.userStats.totalChats)")
                    StatRow(icon: "calendar", title: "使用天数", value: "\(appState.userStats.usageDays)")
                    StatRow(icon: "flame.fill", title: "连续打卡", value: "\(appState.userStats.streak)天")
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
                        FavoritesView()
                    } label: {
                        Label("我的收藏", systemImage: "heart.fill")
                    }
                    
                    NavigationLink {
                        FeedbackView()
                    } label: {
                        Label("意见反馈", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                    }
                } header: {
                    Text("功能")
                }
                
                // 游客升级提示 - 仅对游客显示
                if authService.canUpgrade {
                    Section {
                        Button {
                            showUpgradeSheet = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "crown.fill")
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(
                                        LinearGradient(
                                            colors: [.purple, .pink],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("升级账号")
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("升级为正式账号，数据永不丢失")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    } header: {
                        Text("账号升级")
                    } footer: {
                        Text("游客数据会在30天后自动清除，升级后永久保存")
                    }
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
                        Text("正常").tag("normal")
                        Text("暴躁").tag("heavy")
                    }
                    .onChange(of: appState.userSettings.toxicLevel) { _ in
                        appState.saveUserSettings()
                    }
                    
                    // 账号设置 - 符合《个人信息保护法》
                    NavigationLink {
                        AccountSettingsView()
                    } label: {
                        Label("账号与数据", systemImage: "person.crop.circle.badge.gearshape")
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
                        showLogoutConfirm = true
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("我的")
            #if os(iOS)
            .sheet(isPresented: $showAvatarPicker) {
                AvatarPickerView(selectedSettings: $appState.userSettings)
                    .presentationDetents([.medium])
            }
            #else
            .sheet(isPresented: $showAvatarPicker) {
                AvatarPickerView(selectedSettings: $appState.userSettings)
                    .frame(width: 400, height: 500)
            }
            #endif
            .alert("修改昵称", isPresented: $showNicknameEditor) {
                TextField("昵称", text: $newNickname)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    if !newNickname.trimmingCharacters(in: .whitespaces).isEmpty {
                        appState.userSettings.nickname = newNickname
                        appState.saveUserSettings()
                    }
                }
            } message: {
                Text("请输入新昵称")
            }
            .alert("确认退出", isPresented: $showLogoutConfirm) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) {
                    authService.logout()
                }
            } message: {
                Text("确定要退出登录吗？")
            }
            .onAppear {
                newNickname = appState.userSettings.nickname
            }
            #if os(iOS)
            .sheet(isPresented: $showUpgradeSheet) {
                GuestUpgradeSheet(
                    isPresented: $showUpgradeSheet,
                    isUpgrading: $isUpgrading,
                    error: $upgradeError,
                    onSuccess: {
                        // 升级成功后刷新用户状态
                        authService.loadSession()
                    }
                )
                .presentationDetents([.medium])
            }
            #else
            .sheet(isPresented: $showUpgradeSheet) {
                GuestUpgradeSheet(
                    isPresented: $showUpgradeSheet,
                    isUpgrading: $isUpgrading,
                    error: $upgradeError,
                    onSuccess: {
                        authService.loadSession()
                    }
                )
                .frame(width: 400, height: 400)
            }
            #endif
        }
    }
    
    // MARK: - Avatar View
    @ViewBuilder
    private var avatarView: some View {
        if let emoji = appState.userSettings.avatarEmoji {
            Text(emoji)
                .font(.system(size: 36))
                .frame(width: 70, height: 70)
                .background(Color(.systemGray5))
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
        case "light": return "温和"
        case "normal": return "正常"
        case "heavy": return "暴躁"
        default: return "正常"
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
            Label(title, systemImage: icon)
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
    
    private let presetAvatars = ["logo", "avatar1", "avatar2", "avatar3", "avatar4", "avatar5", "avatar6", "avatar7", "avatar8"]
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
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("选择头像")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
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
                    .fill(Color(.systemGray6))
                    .frame(width: 80, height: 80)
                
                // 加载预设头像图片
                AsyncImage(url: URL(string: "https://caobao.coze.site/avatars/\(avatarId).png")) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 76, height: 76)
                            .clipShape(Circle())
                    case .failure(_):
                        // 加载失败时显示默认图标
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.gray)
                    case .empty:
                        // 加载中显示占位符
                        ProgressView()
                            .frame(width: 40, height: 40)
                    @unknown default:
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.gray)
                    }
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
                    .background(Color(.systemGray6))
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

    ProfileView()
        .environmentObject(AppState())
}

// MARK: - Guest Upgrade Sheet
#if os(iOS) || os(macOS)
struct GuestUpgradeSheet: View {
    @Binding var isPresented: Bool
    @Binding var isUpgrading: Bool
    @Binding var error: String?
    let onSuccess: () -> Void
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.purple, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    Text("升级账号")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("升级为正式账号，您的聊天记录将永久保存")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)
                
                // Apple Sign In Button
                SignInWithAppleButton(
                    .signIn,
                    onRequest: { request in
                        request.requestedScopes = [.fullName, .email]
                    },
                    onCompletion: { result in
                        handleAppleSignIn(result: result)
                    }
                )
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
                .disabled(isUpgrading)
                
                // Loading indicator
                if isUpgrading {
                    ProgressView("升级中...")
                        .padding()
                }
                
                // Error message
                if let error = error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                
                Spacer()
                
                // Cancel button
                Button("取消") {
                    isPresented = false
                }
                .padding(.bottom, 20)
            }
            .navigationTitle("账号升级")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        isPresented = false
                    }
                }
            }
        }
    }
    
    private func handleAppleSignIn(result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                error = "无效的凭证"
                return
            }
            
            isUpgrading = true
            error = nil
            
            Task {
                do {
                    let identityToken = appleIDCredential.identityToken?.base64EncodedString() ?? ""
                    let authorizationCode = appleIDCredential.authorizationCode?.base64EncodedString() ?? ""
                    
                    _ = try await AuthService.shared.guestUpgrade(
                        provider: "apple",
                        identityToken: identityToken,
                        authorizationCode: authorizationCode
                    )
                    
                    await MainActor.run {
                        isUpgrading = false
                        isPresented = false
                        onSuccess()
                    }
                } catch {
                    await MainActor.run {
                        isUpgrading = false
                        self.error = error.localizedDescription
                    }
                }
            }
            
        case .failure(let error):
            self.error = error.localizedDescription
        }
    }
}
#endif
