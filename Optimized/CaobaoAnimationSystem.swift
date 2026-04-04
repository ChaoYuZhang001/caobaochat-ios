import SwiftUI

// MARK: - 草包动画系统
// 提供统一的动画效果和过渡效果

// MARK: - 动画扩展
public extension Animation {
    // 主动画 - 弹簧动画
    static let caobaoSpring = Animation.spring(
        response: 0.4,
        dampingFraction: 0.75
    )

    // 缓出动画
    static let caobaoEaseOut = Animation.easeOut(duration: 0.3)

    // 快速弹跳
    static let caobaoBounce = Animation.spring(
        response: 0.3,
        dampingFraction: 0.6
    )

    // 淡入动画
    static let caobaoFadeIn = Animation.easeIn(duration: 0.2)

    // 淡出动画
    static let caobaoFadeOut = Animation.easeOut(duration: 0.2)

    // 滑入动画
    static let caobaoSlideIn = Animation.easeOut(duration: 0.4)

    // 缩放动画
    static let caobaoScale = Animation.spring(
        response: 0.3,
        dampingFraction: 0.8
    )
}

// MARK: - 页面过渡效果
public struct CaobaoTransition {
    // 从左侧滑入
    static var slideFromLeading: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        )
    }

    // 从右侧滑入
    static var slideFromTrailing: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    // 从顶部滑入
    static var slideFromTop: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }

    // 从底部滑入
    static var slideFromBottom: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity)
        )
    }

    // 缩放淡入
    static var scaleFade: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .scale(scale: 1.1).combined(with: .opacity)
        )
    }

    // 淡入淡出
    static var fade: AnyTransition {
        .opacity
    }
}

// MARK: - 卡片动画修饰符
public struct CardAppearAnimation: ViewModifier {
    let delay: Double
    @State private var isAppeared = false

    public func body(content: Content) -> some View {
        content
            .offset(y: isAppeared ? 0 : 20)
            .opacity(isAppeared ? 1 : 0)
            .animation(
                .caobaoSpring.delay(delay),
                value: isAppeared
            )
            .onAppear {
                withAnimation {
                    isAppeared = true
                }
            }
    }
}

public extension View {
    // 卡片出现动画
    func cardAppear(delay: Double = 0) -> some View {
        modifier(CardAppearAnimation(delay: delay))
    }

    // 序列动画 - 用于列表项
    func staggeredAppear(index: Int, baseDelay: Double = 0.1) -> some View {
        cardAppear(delay: baseDelay * Double(index))
    }
}

// MARK: - 按钮点击动画
public struct PressEffect: ViewModifier {
    @State private var isPressed = false

    public func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(.caobaoSpring, value: isPressed)
            .onLongPressGesture(
                minimumDuration: 0,
                maximumDistance: .infinity,
                pressing: { pressing in
                    withAnimation {
                        isPressed = pressing
                    }
                },
                perform: {}
            )
    }
}

public extension View {
    // 按钮点击效果
    func pressEffect() -> some View {
        modifier(PressEffect())
    }
}

// MARK: - 闪烁动画（加载状态）
public struct ShimmerEffect: ViewModifier {
    @State private var phase = 0.0

    public func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.3),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width)
                    .offset(x: phase * geometry.size.width * 2 - geometry.size.width)
                }
            )
            .mask(content)
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

public extension View {
    // 骨架屏闪烁效果
    func shimmer() -> some View {
        modifier(ShimmerEffect())
    }
}

// MARK: - 脉冲动画（加载/活跃状态）
public struct PulseEffect: ViewModifier {
    @State private var isAnimating = false

    public init(isActive: Bool = true) {
        _isAnimating = State(initialValue: isActive)
    }

    public func body(content: Content) -> some View {
        content
            .scaleEffect(isAnimating ? 1.1 : 1.0)
            .opacity(isAnimating ? 0.8 : 1.0)
            .animation(
                .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                value: isAnimating
            )
            .onAppear {
                isAnimating = true
            }
    }
}

public extension View {
    // 脉冲动画
    func pulse() -> some View {
        modifier(PulseEffect())
    }
}

// MARK: - 旋转动画（加载状态）
public struct RotatingEffect: ViewModifier {
    @State private var isRotating = false

    public func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(
                .linear(duration: 1).repeatForever(autoreverses: false),
                value: isRotating
            )
            .onAppear {
                isRotating = true
            }
    }
}

public extension View {
    // 旋转动画
    func rotating() -> some View {
        modifier(RotatingEffect())
    }
}

// MARK: - 弹跳动画（重要元素）
public struct BounceEffect: ViewModifier {
    @State private var isBouncing = false

    public func body(content: Content) -> some View {
        content
            .scaleEffect(isBouncing ? 1.05 : 1.0)
            .animation(
                .caobaoBounce,
                value: isBouncing
            )
            .onAppear {
                withAnimation {
                    isBouncing = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation {
                        isBouncing = false
                    }
                }
            }
    }
}

public extension View {
    // 弹跳动画
    func bounce() -> some View {
        modifier(BounceEffect())
    }
}

// MARK: - 成功/失败动画
public struct SuccessAnimation: View {
    @State private var isAnimating = false

    public init(isAnimating: Bool = false) {
        _isAnimating = State(initialValue: isAnimating)
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.green.opacity(0.3), lineWidth: 4)

            Circle()
                .trim(from: 0, to: isAnimating ? 1 : 0)
                .stroke(
                    Color.green,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(
                    .easeOut(duration: 0.6),
                    value: isAnimating
                )

            Image(systemName: "checkmark")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.green)
                .scaleEffect(isAnimating ? 1 : 0)
                .animation(
                    .spring(response: 0.4, dampingFraction: 0.6).delay(0.3),
                    value: isAnimating
                )
        }
        .frame(width: 60, height: 60)
        .onAppear {
            isAnimating = true
        }
    }
}

public struct FailureAnimation: View {
    @State private var isAnimating = false

    public init(isAnimating: Bool = false) {
        _isAnimating = State(initialValue: isAnimating)
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.red.opacity(0.3), lineWidth: 4)

            Image(systemName: "xmark")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.red)
                .scaleEffect(isAnimating ? 1 : 0)
                .rotationEffect(.degrees(isAnimating ? 0 : -45))
                .animation(
                    .spring(response: 0.4, dampingFraction: 0.6).delay(0.2),
                    value: isAnimating
                )
        }
        .frame(width: 60, height: 60)
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - 加载动画组件
public struct CaobaoLoadingIndicator: View {
    @State private var isAnimating = false

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.caobaoPrimary.opacity(0.2), lineWidth: 3)

            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(
                    Color.caobaoPrimary,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(isAnimating ? 360 : 0))
                .animation(
                    .linear(duration: 1).repeatForever(autoreverses: false),
                    value: isAnimating
                )
        }
        .frame(width: 40, height: 40)
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - 说话动画（对话时）
public struct TalkingIndicator: View {
    @State private var currentHeight: CGFloat = 6
    private let heights: [CGFloat] = [6, 20, 12, 24, 8, 16, 6]
    @State private var currentIndex = 0

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.caobaoPrimary)
                    .frame(width: 6, height: currentHeight)
                    .animation(
                        .easeInOut(duration: 0.2),
                        value: currentHeight
                    )
            }
        }
        .frame(height: 30)
        .onAppear {
            startAnimation()
        }
    }

    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { timer in
            currentIndex = (currentIndex + 1) % heights.count
            currentHeight = heights[currentIndex]
        }
    }
}

// MARK: - 扫描动画（OCR）
public struct ScanningEffect: View {
    @State private var scanPosition: CGFloat = 0

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                Color.caobaoPrimary.opacity(0.3),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 50)
                    .offset(y: scanPosition)

                Rectangle()
                    .stroke(Color.caobaoPrimary, lineWidth: 2)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .onAppear {
                withAnimation(
                    .linear(duration: 2).repeatForever(autoreverses: true)
                ) {
                    scanPosition = geometry.size.height - 50
                }
            }
        }
        .frame(height: 200)
    }
}

#Preview {
    VStack(spacing: 30) {
        // 加载指示器
        CaobaoLoadingIndicator()

        // 说话指示器
        TalkingIndicator()

        // 成功动画
        SuccessAnimation()

        // 失败动画
        FailureAnimation()

        // 扫描动画
        ScanningEffect()
            .frame(width: 200)
    }
    .padding()
}
