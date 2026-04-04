//
//  HapticManager.swift
//  草包 - 触觉反馈管理器
//
//  提供统一的Haptic反馈接口，提升交互体验
//

import UIKit

/// Haptic反馈管理器
class HapticManager: ObservableObject {
    static let shared = HapticManager()
    
    private init() {}
    
    // MARK: - 轻度反馈
    
    /// 轻度触觉反馈 - 用于选择、切换等轻量交互
    static func light() {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }
    
    // MARK: - 中度反馈
    
    /// 中度触觉反馈 - 用于按钮点击、确认等常规交互
    static func medium() {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        #endif
    }
    
    // MARK: - 重度反馈
    
    /// 重度触觉反馈 - 用于重要操作、成功反馈
    static func heavy() {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()
        #endif
    }
    
    // MARK: - 选择反馈
    
    /// 选择反馈 - 用于滚动选择、滑动等
    static func selection() {
        #if os(iOS)
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
        #endif
    }
    
    // MARK: - 成功反馈
    
    /// 成功反馈 - 用于操作成功、任务完成
    static func success() {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #endif
    }
    
    // MARK: - 警告反馈
    
    /// 警告反馈 - 用于需要提醒的操作
    static func warning() {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
        #endif
    }
    
    // MARK: - 错误反馈
    
    /// 错误反馈 - 用于操作失败、错误提示
    static func error() {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
        #endif
    }
    
    // MARK: - 自定义强度反馈
    
    /// 自定义强度反馈
    /// - Parameters:
    ///   - intensity: 强度 (0.0 - 1.0)
    static func custom(intensity: CGFloat) {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            generator.impactOccurred(intensity: intensity)
        }
        #endif
    }
    
    // MARK: - 连续反馈
    
    /// 连续触觉反馈 - 用于长按、拖动等持续交互
    /// - Parameters:
    ///   - duration: 持续时间（秒）
    ///   - intensity: 强度 (0.0 - 1.0)
    static func continuous(duration: TimeInterval, intensity: CGFloat = 0.5) {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        
        let interval = 0.05
        let count = Int(duration / interval)
        
        for i in 0..<count {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(i)) {
                generator.impactOccurred(intensity: intensity)
            }
        }
        #endif
    }
    
    // MARK: - 通知反馈
    
    /// 通知反馈 - 用于重要通知
    /// - Parameters:
    ///   - type: 通知类型
    enum NotificationType {
        case success
        case warning
        case error
    }
    
    static func notification(type: NotificationType) {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        
        switch type {
        case .success:
            generator.notificationOccurred(.success)
        case .warning:
            generator.notificationOccurred(.warning)
        case .error:
            generator.notificationOccurred(.error)
        }
        #endif
    }
}

// MARK: - Haptic反馈修饰器

/// 为View添加Haptic反馈的修饰器
struct HapticFeedbackModifier: ViewModifier {
    let feedback: () -> Void
    let trigger: () -> Bool
    
    func body(content: Content) -> some View {
        content
            .onChange(of: trigger()) { _ in
                feedback()
            }
    }
}

extension View {
    /// 添加轻度Haptic反馈
    func hapticLight(trigger: @escaping () -> Bool) -> some View {
        self.modifier(HapticFeedbackModifier(
            feedback: HapticManager.light,
            trigger: trigger
        ))
    }
    
    /// 添加中度Haptic反馈
    func hapticMedium(trigger: @escaping () -> Bool) -> some View {
        self.modifier(HapticFeedbackModifier(
            feedback: HapticManager.medium,
            trigger: trigger
        ))
    }
    
    /// 添加重度Haptic反馈
    func hapticHeavy(trigger: @escaping () -> Bool) -> some View {
        self.modifier(HapticFeedbackModifier(
            feedback: HapticManager.heavy,
            trigger: trigger
        ))
    }
    
    /// 添加成功Haptic反馈
    func hapticSuccess(trigger: @escaping () -> Bool) -> some View {
        self.modifier(HapticFeedbackModifier(
            feedback: HapticManager.success,
            trigger: trigger
        ))
    }
    
    /// 添加错误Haptic反馈
    func hapticError(trigger: @escaping () -> Bool) -> some View {
        self.modifier(HapticFeedbackModifier(
            feedback: HapticManager.error,
            trigger: trigger
        ))
    }
    
    /// 添加选择Haptic反馈
    func hapticSelection(trigger: @escaping () -> Bool) -> some View {
        self.modifier(HapticFeedbackModifier(
            feedback: HapticManager.selection,
            trigger: trigger
        ))
    }
}

// MARK: - 使用示例

/*
// 在按钮点击时触发Haptic反馈
Button("点击我") {
    // 你的操作代码
}
.hapticMedium(trigger: { false }) // 使用时将false改为触发条件

// 或者直接调用
Button("点击我") {
    HapticManager.medium()
    // 你的操作代码
}

// 成功操作
HapticManager.success()

// 错误提示
HapticManager.error()

// 滚动选择
ScrollView {
    // 内容
}
.onChange(of: selectedItem) { _ in
    HapticManager.selection()
}
*/
