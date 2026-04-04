import SwiftUI

// MARK: - 优化的卡片组件
// 增加点击反馈、动画效果

// MARK: - 功能卡片（优化版）
public struct EnhancedFeatureCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    var iconSize: CGFloat = 24
    var action: (() -> Void)? = nil

    @State private var isPressed = false
    @State private var isHovered = false

    public init(
        icon: String,
        title: String,
        subtitle: String,
        color: Color,
        iconSize: CGFloat = 24,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.color = color
        self.iconSize = iconSize
        self.action = action
    }

    public var body: some View {
        Button(action: {
            withAnimation(.caobaoSpring) {
                isPressed = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.caobaoSpring) {
                    isPressed = false
                }
                action?()
            }
        }) {
            VStack(spacing: 10) {
                // 图标背景
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: icon)
                        .font(.system(size: iconSize))
                        .foregroundStyle(color)
                        .frame(width: 44, height: 44)
                        .scaleEffect(isPressed ? 1.1 : 1.0)
                        .animation(.caobaoSpring, value: isPressed)
                }

                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .shadow(
                        color: .black.opacity(isPressed ? 0.02 : 0.05),
                        radius: isPressed ? 2 : 4,
                        y: isPressed ? 1 : 2
                    )
            )
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .opacity(isPressed ? 0.9 : 1.0)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 快捷入口行（优化版）
public struct EnhancedQuickActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    var action: (() -> Void)? = nil

    @State private var isPressed = false

    public init(
        icon: String,
        title: String,
        subtitle: String,
        color: Color,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.color = color
        self.action = action
    }

    public var body: some View {
        Button(action: {
            withAnimation(.caobaoSpring) {
                isPressed = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.caobaoSpring) {
                    isPressed = false
                }
                action?()
            }
        }) {
            HStack(spacing: 14) {
                // 图标
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 42, height: 42)

                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(color)
                        .scaleEffect(isPressed ? 1.1 : 1.0)
                        .animation(.caobaoSpring, value: isPressed)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // 箭头
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .offset(x: isPressed ? 4 : 0)
                    .animation(.caobaoSpring, value: isPressed)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .shadow(
                        color: .black.opacity(isPressed ? 0.02 : 0.05),
                        radius: isPressed ? 2 : 4,
                        y: isPressed ? 1 : 2
                    )
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 统计卡片（优化版）
public struct EnhancedStatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    @State private var isPressed = false
    @State private var animateValue = false

    public init(title: String, value: String, icon: String, color: Color) {
        self.title = title
        self.value = value
        self.icon = icon
        self.color = color
    }

    public var body: some View {
        VStack(spacing: 8) {
            // 图标
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 36, height: 36)

                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .scaleEffect(animateValue ? 1.0 : 0.8)
                    .animation(.caobaoSpring, value: animateValue)
            }

            // 数值
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .scaleEffect(animateValue ? 1.0 : 0.8)
                .animation(.caobaoSpring.delay(0.1), value: animateValue)

            // 标题
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .opacity(animateValue ? 1 : 0)
                .animation(.caobaoFadeIn.delay(0.2), value: animateValue)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(
                    color: .black.opacity(0.05),
                    radius: 4,
                    y: 2
                )
        )
        .pressEffect()
        .onAppear {
            withAnimation {
                animateValue = true
            }
        }
    }
}

// MARK: - 可展开卡片
public struct ExpandableCard<Content: View, ExpandedContent: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: () -> Content
    @ViewBuilder let expandedContent: () -> ExpandedContent

    @State private var isExpanded = false

    public init(
        title: String,
        icon: String,
        iconColor: Color = .caobaoPrimary,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder expandedContent: @escaping () -> ExpandedContent
    ) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
        self.content = content
        self.expandedContent = expandedContent
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 卡片头部
            Button {
                withAnimation(.caobaoSpring) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(iconColor)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(iconColor.opacity(0.15))
                        )

                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding()
                .background(Color.caobaoSystemBackground)
            }
            .buttonStyle(.plain)
            .pressEffect()

            // 展开内容
            if isExpanded {
                expandedContent()
                    .padding()
                    .background(Color.caobaoGroupedBackground)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }
}

// MARK: - 交互式按钮
public struct InteractiveButton: View {
    let title: String
    let icon: String?
    let isLoading: Bool
    let isDisabled: Bool
    let color: Color
    let action: () -> Void

    @State private var isPressed = false

    public init(
        title: String,
        icon: String? = nil,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        color: Color = .caobaoPrimary,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.color = color
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack {
                if isLoading {
                    CaobaoLoadingIndicator()
                        .scaleEffect(0.7)
                } else {
                    if let icon = icon {
                        Image(systemName: icon)
                            .scaleEffect(isPressed ? 1.1 : 1.0)
                    }
                    Text(title)
                        .fontWeight(.semibold)
                        .scaleEffect(isPressed ? 1.1 : 1.0)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isDisabled ? Color.gray : color)
                    .shadow(
                        color: (isDisabled ? .clear : color).opacity(0.3),
                        radius: isPressed ? 4 : 8,
                        y: isPressed ? 2 : 4
                    )
            )
            .foregroundStyle(.white)
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.caobaoSpring, value: isPressed)
        }
        .buttonStyle(.plain)
        .disabled(isLoading || isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }
}

// MARK: - 喜欢按钮
public struct LikeButton: View {
    @Binding var isLiked: Bool
    let action: () -> Void

    @State private var animate = false

    public init(isLiked: Binding<Bool>, action: @escaping () -> Void) {
        self._isLiked = isLiked
        self.action = action
    }

    public var body: some View {
        Button(action: {
            withAnimation(.caobaoSpring) {
                isLiked.toggle()
                animate = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation {
                    animate = false
                }
            }

            action()
        }) {
            HStack(spacing: 6) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.body)
                    .foregroundStyle(isLiked ? .red : .primary)
                    .scaleEffect(animate ? 1.3 : 1.0)
                    .animation(.caobaoSpring, value: animate)

                Text(isLiked ? "已收藏" : "收藏")
                    .font(.subheadline)
                    .foregroundStyle(isLiked ? .red : .primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isLiked ? Color.red.opacity(0.1) : .ultraThinMaterial)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 切换按钮
public struct ToggleButton: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool
    let color: Color

    public init(title: String, icon: String, isOn: Binding<Bool>, color: Color = .caobaoPrimary) {
        self.title = title
        self.icon = icon
        self._isOn = isOn
        self.color = color
    }

    public var body: some View {
        Button {
            withAnimation(.caobaoSpring) {
                isOn.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isOn ? color.opacity(0.15) : Color.gray.opacity(0.1))
                        .frame(width: 36, height: 36)

                    Image(systemName: icon)
                        .font(.body)
                        .foregroundStyle(isOn ? color : .gray)
                }

                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? color : .gray)
                    .scaleEffect(isOn ? 1.1 : 1.0)
                    .animation(.caobaoSpring, value: isOn)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 20) {
        EnhancedFeatureCard(
            icon: "message.fill",
            title: "自由对话",
            subtitle: "随时待命",
            color: .caobaoPrimary,
            action: { print("点击") }
        )

        EnhancedQuickActionRow(
            icon: "sun.max.fill",
            title: "早报",
            subtitle: "开启元气满满的一天",
            color: .orange,
            action: { print("点击") }
        )

        EnhancedStatCard(
            title: "对话次数",
            value: "128",
            icon: "message.fill",
            color: .caobaoPrimary
        )

        LikeButton(isLiked: .constant(false)) {
            print("收藏")
        }

        ToggleButton(
            title: "语音播报",
            icon: "speaker.wave.2.fill",
            isOn: .constant(false)
        )
    }
    .padding()
}
