import SwiftUI

@main
struct CaobaoWatchApp: App {
    @StateObject private var appState = WatchAppState()
    
    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(appState)
        }
    }
}

// MARK: - Watch App State
class WatchAppState: ObservableObject {
    @Published var isLoading = false
    @Published var error: String?
    
    // 简化的用户设置
    @Published var userName: String = ""
    
    init() {
        loadUserName()
    }
    
    func loadUserName() {
        self.userName = UserDefaults.standard.string(forKey: "userName") ?? ""
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let refreshContent = Notification.Name("refreshContent")
}
