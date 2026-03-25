import SwiftUI
import AuthenticationServices

@main
struct CaobaoApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var authService = AuthService.shared
    
    var body: some Scene {
        #if os(macOS)
        // macOS 使用 WindowGroup + Sidebar
        WindowGroup {
            Group {
                if authService.isLoggedIn {
                    MacContentView()
                        .environmentObject(appState)
                        .frame(minWidth: 900, minHeight: 600)
                } else {
                    LoginView()
                }
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建对话") {
                    NotificationCenter.default.post(name: .newChat, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            
            CommandGroup(replacing: .sidebar) {
                Button("显示边栏") {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        
        #else
        // iOS/iPadOS 使用 TabView
        WindowGroup {
            Group {
                if authService.isLoggedIn {
                    ContentView()
                        .environmentObject(appState)
                        .tint(.green)
                } else {
                    LoginView()
                }
            }
            .onAppear {
                // 监听 Apple 登录状态变化
                NotificationCenter.default.addObserver(
                    forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
                    object: nil,
                    queue: .main
                ) { _ in
                    authService.logout()
                }
            }
        }
        #endif
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let newChat = Notification.Name("newChat")
    static let clearChat = Notification.Name("clearChat")
}

// MARK: - App State
class AppState: ObservableObject {
    @Published var isLoggedIn: Bool = false
    @Published var user: User?
    @Published var userSettings: UserSettings = UserSettings()
    @Published var selectedTab: AppTab = .home
    @Published var userStats: UserStats = UserStats()
    
    init() {
        loadUserSettings()
        loadUserStats()
    }
    
    func loadUserSettings() {
        if let data = UserDefaults.standard.data(forKey: "userSettings"),
           let settings = try? JSONDecoder().decode(UserSettings.self, from: data) {
            self.userSettings = settings
        }
    }
    
    func saveUserSettings() {
        if let data = try? JSONEncoder().encode(userSettings) {
            UserDefaults.standard.set(data, forKey: "userSettings")
        }
    }
    
    func loadUserStats() {
        if let data = UserDefaults.standard.data(forKey: "userStats"),
           let stats = try? JSONDecoder().decode(UserStats.self, from: data) {
            self.userStats = stats
        }
    }
    
    func saveUserStats() {
        if let data = try? JSONEncoder().encode(userStats) {
            UserDefaults.standard.set(data, forKey: "userStats")
        }
    }
    
    /// 增加对话次数
    func incrementChatCount() {
        userStats.totalChats += 1
        userStats.lastActiveDate = Date()
        checkStreak()
        saveUserStats()
    }
    
    /// 检查连续打卡
    private func checkStreak() {
        let calendar = Calendar.current
        if let lastDate = userStats.lastActiveDate {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastDate), to: calendar.startOfDay(for: Date())).day ?? 0
            if days == 1 {
                userStats.streak += 1
            } else if days > 1 {
                userStats.streak = 1
            }
            // 同一天不改变 streak
        } else {
            userStats.streak = 1
        }
    }
    
    /// 从 API 响应更新统计数据
    func updateStats(from response: UserInfoResponse) {
        if let stats = response.usageStats {
            userStats.totalChats = stats["chat"]?.count ?? userStats.totalChats
        }
        if let user = response.user, let createdAt = user.createdAt {
            let createdDate = Date(timeIntervalSince1970: Double(createdAt) / 1000)
            let calendar = Calendar.current
            userStats.usageDays = max(1, calendar.dateComponents([.day], from: createdDate, to: Date()).day ?? 1)
        }
        saveUserStats()
    }
}

// MARK: - User Stats
struct UserStats: Codable {
    var totalChats: Int = 0
    var usageDays: Int = 1
    var streak: Int = 0
    var lastActiveDate: Date?
}

// MARK: - App Tab
enum AppTab: String, CaseIterable {
    case home = "首页"
    case chat = "对话"
    case fortune = "运势"
    case features = "更多"
    case profile = "我的"
    
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .chat: return "message.fill"
        case .fortune: return "star.fill"
        case .features: return "square.grid.2x2.fill"
        case .profile: return "person.fill"
        }
    }
}

// MARK: - User Settings
struct UserSettings: Codable {
    var nickname: String = "草包用户"
    var avatarType: String = "preset"
    var avatarValue: String = "logo"
    var toxicLevel: String = "normal"
    
    var avatarEmoji: String? {
        avatarType == "emoji" ? avatarValue : nil
    }
    
    var avatarUrl: String? {
        // preset 类型使用 logo 时返回 nil，显示默认头像
        if avatarType == "preset" {
            if avatarValue == "logo" {
                return nil
            }
            return "https://caobao.coze.site/avatars/\(avatarValue).png"
        } else if avatarType == "custom" {
            return avatarValue
        }
        return nil
    }
}
