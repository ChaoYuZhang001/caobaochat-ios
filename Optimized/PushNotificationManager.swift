//
//  PushNotificationManager.swift
//  草包 - 推送通知管理器
//
//  管理晨报、晚报、运势等推送通知
//

import UserNotifications
import Foundation

// MARK: - 通知类型

/// 通知类型
enum NotificationType: String, CaseIterable {
    case morning = "晨报"
    case evening = "晚报"
    case fortune = "运势"
    case quote = "金句"
    case reminder = "提醒"
    
    var identifier: String {
        "caobao.\(rawValue)"
    }
    
    var icon: String {
        switch self {
        case .morning: return "sun.max.fill"
        case .evening: return "moon.fill"
        case .fortune: return "sparkles"
        case .quote: return "quote.bubble.fill"
        case .reminder: return "bell.fill"
        }
    }
}

// MARK: - 推送通知管理器

/// 推送通知管理器
class PushNotificationManager: NSObject, ObservableObject {
    static let shared = PushNotificationManager()
    
    @Published var isAuthorized = false
    @Published var notificationSettings: UNNotificationSettings?
    
    private let center = UNUserNotificationCenter.current()
    
    private override init() {
        super.init()
        center.delegate = self
        checkAuthorizationStatus()
    }
    
    // MARK: - 请求权限
    
    /// 请求通知权限
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        
        center.requestAuthorization(options: options) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
                completion(granted)
                
                if let error = error {
                    print("Failed to request authorization: \(error)")
                }
            }
        }
    }
    
    // MARK: - 检查权限状态
    
    /// 检查权限状态
    func checkAuthorizationStatus() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.isAuthorized = settings.authorizationStatus == .authorized
                self?.notificationSettings = settings
            }
        }
    }
    
    // MARK: - 发送通知
    
    /// 发送本地通知
    /// - Parameters:
    ///   - type: 通知类型
    ///   - title: 标题
    ///   - body: 内容
    ///   - delay: 延迟时间（秒）
    func sendNotification(
        type: NotificationType,
        title: String,
        body: String,
        delay: TimeInterval = 0
    ) {
        guard isAuthorized else {
            print("Not authorized to send notifications")
            return
        }
        
        // 创建内容
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.badge = 1
        content.userInfo = ["type": type.rawValue]
        
        // 添加附件图片
        if let attachment = createAttachment(for: type) {
            content.attachments = [attachment]
        }
        
        // 创建触发器
        let trigger: UNNotificationTrigger
        if delay > 0 {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        } else {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        }
        
        // 创建请求
        let request = UNNotificationRequest(
            identifier: "\(type.identifier)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        )
        
        // 添加通知
        center.add(request) { error in
            if let error = error {
                print("Failed to add notification: \(error)")
            }
        }
        
        // 震动反馈
        HapticManager.medium()
    }
    
    // MARK: - 定时通知
    
    /// 设置定时通知（晨报）
    /// - Parameters:
    ///   - hour: 小时 (0-23)
    ///   - minute: 分钟 (0-59)
    func scheduleMorningReport(hour: Int = 7, minute: Int = 0) {
        guard isAuthorized else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "早安日报"
        content.body = "开启元气满满的一天，点击查看今日运势和新闻"
        content.sound = .default
        content.categoryIdentifier = "MORNING_REPORT"
        content.userInfo = ["type": "晨报"]
        
        // 设置触发时间
        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute
        
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: dateComponents,
            repeats: true
        )
        
        let request = UNNotificationRequest(
            identifier: NotificationType.morning.identifier,
            content: content,
            trigger: trigger
        )
        
        center.add(request) { error in
            if let error = error {
                print("Failed to schedule morning report: \(error)")
            }
        }
        
        print("Morning report scheduled at \(hour):\(String(format: "%02d", minute))")
    }
    
    /// 设置定时通知（晚报）
    /// - Parameters:
    ///   - hour: 小时 (0-23)
    ///   - minute: 分钟 (0-59)
    func scheduleEveningReport(hour: Int = 21, minute: Int = 0) {
        guard isAuthorized else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "晚安日报"
        content.body = "总结今日收获，明日可期，点击查看"
        content.sound = .default
        content.categoryIdentifier = "EVENING_REPORT"
        content.userInfo = ["type": "晚报"]
        
        // 设置触发时间
        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute
        
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: dateComponents,
            repeats: true
        )
        
        let request = UNNotificationRequest(
            identifier: NotificationType.evening.identifier,
            content: content,
            trigger: trigger
        )
        
        center.add(request) { error in
            if let error = error {
                print("Failed to schedule evening report: \(error)")
            }
        }
        
        print("Evening report scheduled at \(hour):\(String(format: "%02d", minute))")
    }
    
    /// 设置运势通知
    /// - Parameters:
    ///   - hour: 小时 (0-23)
    ///   - minute: 分钟 (0-59)
    func scheduleFortuneNotification(hour: Int = 9, minute: Int = 0) {
        guard isAuthorized else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "今日运势"
        content.body = "查看你的今日运势，把握机会"
        content.sound = .default
        content.categoryIdentifier = "FORTUNE"
        content.userInfo = ["type": "运势"]
        
        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute
        
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: dateComponents,
            repeats: true
        )
        
        let request = UNNotificationRequest(
            identifier: NotificationType.fortune.identifier,
            content: content,
            trigger: trigger
        )
        
        center.add(request) { error in
            if let error = error {
                print("Failed to schedule fortune: \(error)")
            }
        }
        
        print("Fortune scheduled at \(hour):\(String(format: "%02d", minute))")
    }
    
    // MARK: - 取消通知
    
    /// 取消所有通知
    func cancelAllNotifications() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        print("All notifications cancelled")
    }
    
    /// 取消指定类型的通知
    func cancelNotification(type: NotificationType) {
        center.getPendingNotificationRequests { requests in
            let identifiersToRemove = requests
                .filter { $0.identifier.contains(type.identifier) }
                .map { $0.identifier }
            
            self.center.removePendingNotificationRequests(withIdentifiers: identifiersToRemove)
            print("Cancelled \(identifiersToRemove.count) notifications for \(type.rawValue)")
        }
    }
    
    // MARK: - 清除角标
    
    /// 清除角标
    func clearBadge() {
        UIApplication.shared.applicationIconBadgeNumber = 0
    }
    
    // MARK: - 创建附件
    
    /// 创建通知附件
    private func createAttachment(for type: NotificationType) -> UNNotificationAttachment? {
        // 这里可以创建自定义的图片附件
        // 实际项目中可以从资源中加载
        return nil
    }
    
    // MARK: - 注册通知类别
    
    /// 注册通知类别（支持交互）
    func registerNotificationCategories() {
        // 晨报类别
        let morningCategory = UNNotificationCategory(
            identifier: "MORNING_REPORT",
            actions: [
                UNNotificationAction(
                    identifier: "VIEW_MORNING",
                    title: "查看晨报",
                    options: .foreground
                ),
                UNNotificationAction(
                    identifier: "DISMISS",
                    title: "稍后",
                    options: []
                )
            ],
            intentIdentifiers: [],
            options: []
        )
        
        // 晚报类别
        let eveningCategory = UNNotificationCategory(
            identifier: "EVENING_REPORT",
            actions: [
                UNNotificationAction(
                    identifier: "VIEW_EVENING",
                    title: "查看晚报",
                    options: .foreground
                ),
                UNNotificationAction(
                    identifier: "DISMISS",
                    title: "稍后",
                    options: []
                )
            ],
            intentIdentifiers: [],
            options: []
        )
        
        // 运势类别
        let fortuneCategory = UNNotificationCategory(
            identifier: "FORTUNE",
            actions: [
                UNNotificationAction(
                    identifier: "VIEW_FORTUNE",
                    title: "查看运势",
                    options: .foreground
                ),
                UNNotificationAction(
                    identifier: "DISMISS",
                    title: "稍后",
                    options: []
                )
            ],
            intentIdentifiers: [],
            options: []
        )
        
        center.setNotificationCategories([
            morningCategory,
            eveningCategory,
            fortuneCategory
        ])
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushNotificationManager: UNUserNotificationCenterDelegate {
    /// 应用在前台时收到通知
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 在前台也显示通知
        completionHandler([.banner, .sound, .badge])
        
        // 震动反馈
        HapticManager.medium()
    }
    
    /// 用户点击通知
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        
        // 处理通知点击
        if let type = userInfo["type"] as? String {
            handleNotificationAction(type: type, action: response.actionIdentifier)
        }
        
        completionHandler()
    }
    
    // MARK: - 处理通知动作
    
    private func handleNotificationAction(type: String, action: String) {
        switch action {
        case "VIEW_MORNING":
            // 跳转到晨报页面
            NotificationCenter.default.post(
                name: .navigateToMorningReport,
                object: nil
            )
            
        case "VIEW_EVENING":
            // 跳转到晚报页面
            NotificationCenter.default.post(
                name: .navigateToEveningReport,
                object: nil
            )
            
        case "VIEW_FORTUNE":
            // 跳转到运势页面
            NotificationCenter.default.post(
                name: .navigateToFortune,
                object: nil
            )
            
        default:
            // 默认跳转到首页
            break
        }
    }
}

// MARK: - Notification.Name Extension

extension Notification.Name {
    static let navigateToMorningReport = Notification.Name("navigateToMorningReport")
    static let navigateToEveningReport = Notification.Name("navigateToEveningReport")
    static let navigateToFortune = Notification.Name("navigateToFortune")
}

// MARK: - 使用示例

/*
// 在App启动时初始化
@main
struct CaobaoApp: App {
    @StateObject private var notificationManager = PushNotificationManager.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(notificationManager)
                .onAppear {
                    // 注册通知类别
                    notificationManager.registerNotificationCategories()
                    
                    // 请求权限
                    notificationManager.requestAuthorization { granted in
                        if granted {
                            // 设置定时通知
                            notificationManager.scheduleMorningReport(hour: 7, minute: 0)
                            notificationManager.scheduleEveningReport(hour: 21, minute: 0)
                            notificationManager.scheduleFortuneNotification(hour: 9, minute: 0)
                        }
                    }
                }
        }
    }
}

// 发送即时通知
Button("发送测试通知") {
    PushNotificationManager.shared.sendNotification(
        type: .fortune,
        title: "测试通知",
        body: "这是一条测试通知"
    )
}

// 在设置页面管理通知
struct NotificationSettingsView: View {
    @EnvironmentObject var notificationManager: PushNotificationManager
    @State private var morningTime = Date()
    @State private var eveningTime = Date()
    
    var body: some View {
        Form {
            Section("通知设置") {
                Toggle("启用通知", isOn: Binding(
                    get: { notificationManager.isAuthorized },
                    set: { enabled in
                        if enabled {
                            notificationManager.requestAuthorization { _ in }
                        } else {
                            notificationManager.cancelAllNotifications()
                        }
                    }
                ))
                .disabled(notificationManager.notificationSettings?.authorizationStatus != .notDetermined)
                
                if notificationManager.isAuthorized {
                    DatePicker("晨报时间", selection: $morningTime, displayedComponents: .hourAndMinute)
                        .onChange(of: morningTime) { newDate in
                            let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                            notificationManager.scheduleMorningReport(
                                hour: components.hour ?? 7,
                                minute: components.minute ?? 0
                            )
                        }
                    
                    DatePicker("晚报时间", selection: $eveningTime, displayedComponents: .hourAndMinute)
                        .onChange(of: eveningTime) { newDate in
                            let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                            notificationManager.scheduleEveningReport(
                                hour: components.hour ?? 21,
                                minute: components.minute ?? 0
                            )
                        }
                }
            }
        }
        .navigationTitle("通知设置")
    }
}

// 监听通知跳转
struct ContentView: View {
    var body: some View {
        TabView {
            // ...
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToMorningReport)) { _ in
            // 跳转到晨报
            appState.selectedTab = .features
        }
    }
}
*/
