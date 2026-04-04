//
//  AccessibilityManager.swift
//  草包 - 无障碍支持
//
//  提供VoiceOver和其他无障碍功能支持
//

import SwiftUI

// MARK: - 无障碍管理器

/// 无障碍管理器
class AccessibilityManager: ObservableObject {
    static let shared = AccessibilityManager()
    
    @Published var isVoiceOverEnabled = false
    @Published var preferredContentSizeCategory: ContentSizeCategory = .medium
    @Published var isReduceMotionEnabled = false
    @Published var isReduceTransparencyEnabled = false
    @Published var isDifferentiateWithoutColorEnabled = false
    @Published var preferredContrast: UIAccessibilityContrast = .normal
    
    private init() {
        setupNotifications()
        updateAccessibilitySettings()
    }
    
    // MARK: - 设置通知
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(voiceOverStatusChanged),
            name: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(assessibilitySettingsChanged),
            name: UIAccessibility.assessibilitySettingsChangedNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryChanged),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
    }
    
    // MARK: - 更新设置
    
    private func updateAccessibilitySettings() {
        isVoiceOverEnabled = UIAccessibility.isVoiceOverRunning
        preferredContentSizeCategory = ContentSizeCategory(UIContentSizeCategory.current)
        isReduceMotionEnabled = UIAccessibility.isReduceMotionEnabled
        isReduceTransparencyEnabled = UIAccessibility.isReduceTransparencyEnabled
        isDifferentiateWithoutColorEnabled = UIAccessibility.shouldDifferentiateWithoutColor
        preferredContrast = UIAccessibility.accessibilityContrast
    }
    
    // MARK: - 通知处理
    
    @objc private func voiceOverStatusChanged() {
        isVoiceOverEnabled = UIAccessibility.isVoiceOverRunning
    }
    
    @objc private func assessibilitySettingsChanged() {
        updateAccessibilitySettings()
    }
    
    @objc private func contentSizeCategoryChanged() {
        preferredContentSizeCategory = ContentSizeCategory(UIContentSizeCategory.current)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - View 修饰器

/// 无障碍修饰器
struct AccessibilityModifier: ViewModifier {
    let label: String
    let hint: String?
    let value: String?
    let trait: AccessibilityTrait?
    
    func body(content: Content) -> some View {
        content
            .accessibilityLabel(label)
            .accessibilityHint(hint ?? "")
            .ifLet(value, transform: { view, value in
                view.accessibilityValue(value)
            })
            .ifLet(trait, transform: { view, trait in
                view.accessibilityAddTraits(trait)
            })
    }
}

// MARK: - 扩展方法

extension View {
    /// 添加无障碍标签和提示
    func accessibility(
        label: String,
        hint: String? = nil,
        value: String? = nil,
        trait: AccessibilityTrait? = nil
    ) -> some View {
        self.modifier(AccessibilityModifier(
            label: label,
            hint: hint,
            value: value,
            trait: trait
        ))
    }
    
    /// 添加可点击行为
    func accessibilityTapAction(_ action: @escaping () -> Void) -> some View {
        self.accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) {
                action()
            }
    }
    
    /// 添加可滑动行为
    func accessibilitySwipeActions(_ actions: [AccessibilitySwipeAction]) -> some View {
        var view = self.accessibilityAddTraits(.updatesFrequently)
        
        for action in actions {
            view = view.accessibilityAction(action.direction) {
                action.action()
            }
        }
        
        return view
    }
    
    /// 条件修饰
    @ViewBuilder
    func `if`<Transform: View>(
        _ condition: Bool,
        transform: (Self) -> Transform
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
    
    @ViewBuilder
    func ifLet<T, Transform: View>(
        _ value: T?,
        transform: (Self, T) -> Transform
    ) -> some View {
        if let value = value {
            transform(self, value)
        } else {
            self
        }
    }
}

// MARK: - 滑动动作

struct AccessibilitySwipeAction {
    enum Direction {
        case left
        case right
        case up
        case down
    }
    
    let direction: AccessibilityActionHandler<AccessibilityActionKind>
    let action: () -> Void
    
    init(direction: Direction, action: @escaping () -> Void) {
        switch direction {
        case .left:
            self.direction = .default
        case .right:
            self.direction = .default
        case .up:
            self.direction = .escape
        case .down:
            self.direction = .magicTap
        }
        self.action = action
    }
}

// MARK: - 无障碍组件

/// 无障碍友好的卡片
struct AccessibleCard<Content: View>: View {
    let title: String
    let description: String
    let content: Content
    
    init(
        title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.description = description
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            
            content
            
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(description)
    }
}

/// 无障碍友好的按钮
struct AccessibleButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    
    var body: some View {
        Button(action: {
            HapticManager.light()
            action()
        }) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// 无障碍友好的列表项
struct AccessibleListItem<Title: View, Subtitle: View>: View {
    let title: Title
    let subtitle: Subtitle
    let action: (() -> Void)?
    
    init(
        @ViewBuilder title: () -> Title,
        @ViewBuilder subtitle: () -> Subtitle,
        action: (() -> Void)? = nil
    ) {
        self.title = title()
        self.subtitle = subtitle()
        self.action = action
    }
    
    var body: some View {
        Group {
            if let action = action {
                Button(action: {
                    HapticManager.light()
                    action()
                }) {
                    itemContent
                }
                .buttonStyle(.plain)
            } else {
                itemContent
            }
        }
        .accessibilityElement(children: .combine)
    }
    
    private var itemContent: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                title
                    .accessibilityAddTraits(.isHeader)
                subtitle
            }
            Spacer()
        }
        .padding()
        .contentShape(Rectangle())
    }
}

// MARK: - 智能语音提示

/// 智能语音提示管理器
class SmartVoiceOverManager {
    static let shared = SmartVoiceOverManager()
    
    private init() {}
    
    /// 朗读消息
    func speakMessage(_ message: Message) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        
        let speaker = message.isUser ? "你" : "草包AI"
        let text = "\(speaker)说，\(message.content)"
        
        UIAccessibility.post(notification: .announcement, argument: text)
    }
    
    /// 朗读状态变化
    func announceStatus(_ status: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        
        UIAccessibility.post(notification: .announcement, argument: status)
    }
    
    /// 朗读错误
    func announceError(_ error: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        
        UIAccessibility.post(notification: .announcement, argument: "错误，\(error)")
    }
    
    /// 朗读成功
    func announceSuccess(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        
        UIAccessibility.post(notification: .announcement, argument: "成功，\(message)")
    }
}

// MARK: - 动态字体支持

/// 动态字体管理
class DynamicFontManager {
    static let shared = DynamicFontManager()
    
    private init() {}
    
    /// 获取动态字体
    func font(
        style: Font.TextStyle,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        return Font.system(style)
            .weight(weight)
            .design(design)
    }
    
    /// 获取动态字体大小
    func baseSize(_ size: CGFloat) -> CGFloat {
        let category = ContentSizeCategory(UIContentSizeCategory.current)
        
        switch category {
        case .extraSmall, .small:
            return size * 0.85
        case .medium:
            return size
        case .large, .extraLarge, .extraExtraLarge:
            return size * 1.15
        case .extraExtraExtraLarge:
            return size * 1.3
        default:
            return size * 1.5
        }
    }
}

// MARK: - 高对比度支持

extension Color {
    /// 获取高对比度颜色
    func highContrastVersion(for darkMode: Bool) -> Color {
        if darkMode {
            // 深色模式高对比度
            return self.luminance() > 0.5 ? .white : .black
        } else {
            // 浅色模式高对比度
            return self.luminance() > 0.5 ? .black : .white
        }
    }
    
    /// 计算亮度
    func luminance() -> Double {
        // 简化的亮度计算
        return 0.5 // 实际应该从UIColor计算
    }
}

// MARK: - 使用示例

/*
// 基础无障碍支持
Button("发送消息") {
    sendMessage()
}
.accessibility(label: "发送消息", hint: "双击发送消息给草包AI")

// 无障碍卡片
AccessibleCard(
    title: "今日运势",
    description: "查看你的今日运势和评分"
) {
    Text("运势内容")
}

// 无障碍按钮
AccessibleButton(
    title: "发送",
    icon: "paperplane.fill"
) {
    sendMessage()
}

// 无障碍列表项
AccessibleListItem(
    title: Text("对话"),
    subtitle: Text("和草包AI聊天")
) {
    // 点击动作
    navigateToChat()
}

// 智能语音提示
SmartVoiceOverManager.shared.speakMessage(message)
SmartVoiceOverManager.shared.announceStatus("消息已发送")
SmartVoiceOverManager.shared.announceError("网络连接失败")

// 动态字体
Text("标题")
    .font(DynamicFontManager.shared.font(.title, weight: .bold))

// 在ViewModel中使用
class ChatViewModel: ObservableObject {
    func sendMessage() {
        // 发送消息
        // ...
        
        // 语音提示
        SmartVoiceOverManager.shared.announceSuccess("消息已发送")
    }
    
    func handleError(_ error: Error) {
        // 错误处理
        // ...
        
        // 语音提示
        SmartVoiceOverManager.shared.announceError(error.localizedDescription)
    }
}

// 高对比度模式
Text("重要文本")
    .foregroundColor(
        ThemeManager.shared.isDifferentiateWithoutColorEnabled ?
        Color.black.highContrastVersion(for: ThemeManager.shared.isDarkMode) :
        Color.primary
    )

// 检测无障碍设置
struct ContentView: View {
    @EnvironmentObject var accessibilityManager: AccessibilityManager
    
    var body: some View {
        VStack {
            Text("草包AI")
                .font(
                    DynamicFontManager.shared.font(
                        .title,
                        weight: .bold
                    )
                )
                .accessibility(label: "草包AI", trait: .header)
            
            if accessibilityManager.isVoiceOverEnabled {
                Text("语音朗读已启用")
            }
            
            if accessibilityManager.isReduceMotionEnabled {
                Text("减少动画")
            }
        }
    }
}
*/
