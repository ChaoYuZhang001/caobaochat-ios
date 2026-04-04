//
//  ThemeManager.swift
//  草包 - 主题管理器
//
//  管理应用的主题、配色和深色模式
//

import SwiftUI

/// 主题模式
enum ThemeMode: String, CaseIterable, Identifiable {
    case light = "浅色"
    case dark = "深色"
    case system = "跟随系统"
    
    var id: String { rawValue }
}

/// 主题色
enum ThemeColor: String, CaseIterable, Identifiable {
    case green = "草包绿"
    case blue = "天空蓝"
    case purple = "梦幻紫"
    case orange = "活力橙"
    case pink = "浪漫粉"
    case red = "热情红"
    case custom = "自定义"
    
    var id: String { rawValue }
    
    var color: Color {
        switch self {
        case .green: return Color(hex: "#10B981")
        case .blue: return Color(hex: "#3B82F6")
        case .purple: return Color(hex: "#8B5CF6")
        case .orange: return Color(hex: "#F59E0B")
        case .pink: return Color(hex: "#EC4899")
        case .red: return Color(hex: "#EF4444")
        case .custom: return Color(hex: "#10B981")
        }
    }
}

// MARK: - 主题管理器

/// 主题管理器
class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    
    // MARK: - Published Properties
    
    @Published var themeMode: ThemeMode {
        didSet {
            savePreferences()
        }
    }
    
    @Published var themeColor: ThemeColor {
        didSet {
            savePreferences()
            updateAccentColor()
        }
    }
    
    @Published var isDarkMode: Bool {
        didSet {
            updateAppearance()
        }
    }
    
    // MARK: - Initialization
    
    private init() {
        // 从UserDefaults加载偏好设置
        let savedMode = UserDefaults.standard.string(forKey: "themeMode") ?? ThemeMode.system.rawValue
        let savedColor = UserDefaults.standard.string(forKey: "themeColor") ?? ThemeColor.green.rawValue
        
        self.themeMode = ThemeMode(rawValue: savedMode) ?? .system
        self.themeColor = ThemeColor(rawValue: savedColor) ?? .green
        self.isDarkMode = calculateDarkMode()
        
        updateAppearance()
        updateAccentColor()
    }
    
    // MARK: - Dark Mode Calculation
    
    private func calculateDarkMode() -> Bool {
        switch themeMode {
        case .light:
            return false
        case .dark:
            return true
        case .system:
            return UITraitCollection.current.userInterfaceStyle == .dark
        }
    }
    
    // MARK: - Update Appearance
    
    private func updateAppearance() {
        DispatchQueue.main.async {
            if self.isDarkMode {
                UIApplication.shared.windows.forEach { window in
                    window.overrideUserInterfaceStyle = .dark
                }
            } else {
                UIApplication.shared.windows.forEach { window in
                    window.overrideUserInterfaceStyle = .light
                }
            }
        }
    }
    
    // MARK: - Update Accent Color
    
    private func updateAccentColor() {
        // 更新全局强调色
        let color = themeColor.color
        
        // 更新DesignSystem
        DesignSystem.shared.accentColor = color
        
        // 通知所有视图更新
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
    }
    
    // MARK: - Save Preferences
    
    private func savePreferences() {
        UserDefaults.standard.set(themeMode.rawValue, forKey: "themeMode")
        UserDefaults.standard.set(themeColor.rawValue, forKey: "themeColor")
    }
    
    // MARK: - Toggle Dark Mode
    
    func toggleDarkMode() {
        isDarkMode.toggle()
        
        // 自动切换主题模式
        if isDarkMode {
            themeMode = .dark
        } else {
            themeMode = .light
        }
    }
    
    // MARK: - Handle System Appearance Change
    
    func handleSystemAppearanceChange() {
        if themeMode == .system {
            isDarkMode = calculateDarkMode()
            updateAppearance()
        }
    }
}

// MARK: - Color Extension

extension Color {
    /// 从十六进制字符串创建颜色
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
    
    /// 草包主题色
    static let caobaoPrimary = Color(hex: "#10B981")
    static let caobaoSecondary = Color(hex: "#059669")
    static let caobaoAccent = Color(hex: "#34D399")
    
    /// 适配深色模式
    func adaptive(for darkMode: Bool) -> Color {
        if darkMode {
            return self.opacity(0.8)
        }
        return self
    }
}

// MARK: - Theme View Modifier

/// 主题修饰器
struct ThemeModifier: ViewModifier {
    @EnvironmentObject var themeManager: ThemeManager
    
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(themeManager.isDarkMode ? .dark : .light)
            .tint(themeManager.themeColor.color)
    }
}

extension View {
    /// 应用主题
    func themed() -> some View {
        self.modifier(ThemeModifier())
    }
    
    /// 条件颜色 - 根据主题模式返回不同的颜色
    func adaptiveColor(light: Color, dark: Color) -> Color {
        ThemeManager.shared.isDarkMode ? dark : light
    }
    
    /// 自适应背景色
    func adaptiveBackground() -> Color {
        ThemeManager.shared.isDarkMode ? Color(hex: "#1C1C1E") : Color(hex: "#F2F2F7")
    }
    
    /// 自适应卡片背景
    func adaptiveCardBackground() -> Color {
        ThemeManager.shared.isDarkMode ? Color(hex: "#2C2C2E") : Color.white
    }
    
    /// 自适应文本颜色
    func adaptiveText() -> Color {
        ThemeManager.shared.isDarkMode ? .white : .black
    }
    
    /// 自适应次要文本颜色
    func adaptiveSecondaryText() -> Color {
        ThemeManager.shared.isDarkMode ? Color(hex: "#98989D") : Color(hex: "#8E8E93")
    }
}

// MARK: - Notification

extension Notification.Name {
    static let themeDidChange = Notification.Name("themeDidChange")
}

// MARK: - 使用示例

/*
// 在App入口注入
@main
struct CaobaoApp: App {
    @StateObject private var themeManager = ThemeManager.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeManager)
                .themed()
        }
    }
}

// 在设置页面使用主题切换器
struct ThemeSettingsView: View {
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        Form {
            Section("主题模式") {
                Picker("主题模式", selection: $themeManager.themeMode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                
                Toggle("深色模式", isOn: Binding(
                    get: { themeManager.isDarkMode },
                    set: { _ in themeManager.toggleDarkMode() }
                ))
                .disabled(themeManager.themeMode == .system)
            }
            
            Section("主题颜色") {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    ForEach(ThemeColor.allCases) { color in
                        Button {
                            themeManager.themeColor = color
                            HapticManager.light()
                        } label: {
                            Circle()
                                .fill(color.color)
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            themeManager.themeColor == color ? 
                                            Color.primary : Color.clear,
                                            lineWidth: 3
                                        )
                                )
                                .shadow(color: color.color.opacity(0.3), radius: 8, x: 0, y: 4)
                        }
                    }
                }
            }
        }
        .navigationTitle("主题设置")
    }
}

// 在视图中使用自适应颜色
struct MyView: View {
    var body: some View {
        VStack {
            Text("标题")
                .foregroundColor(.adaptiveText())
            
            Text("副标题")
                .foregroundColor(.adaptiveSecondaryText())
            
            VStack {
                // 内容
            }
            .background(.adaptiveCardBackground())
        }
        .background(.adaptiveBackground())
    }
}
*/
