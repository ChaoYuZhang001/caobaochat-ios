import SwiftUI

// MARK: - 增强型空状态视图
// 提供更丰富的空状态展示

// MARK: - 上下文化空状态
public struct ContextualEmptyState: View {
    let context: EmptyContext
    let actionTitle: String?
    let action: (() -> Void)?

    public enum EmptyContext {
        case chat            // 对话为空
        case favorites       // 收藏为空
        case history         // 历史记录为空
        case search          // 搜索无结果
        case network         // 网络错误
        case server          // 服务器错误
        case loading         // 加载失败
        case permission      // 权限被拒绝
    }

    public init(
        context: EmptyContext,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.context = context
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 24) {
            // 图标动画
            iconView
                .font(.system(size: 64))
                .foregroundStyle(iconColor)
                .frame(height: 100)
                .transition(.scale.combined(with: .opacity))

            VStack(spacing: 12) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))

            // 操作按钮
            if let actionTitle = actionTitle, let action = action {
                Button(action: action) {
                    HStack {
                        Image(systemName: "arrow.right.circle.fill")
                        Text(actionTitle)
                    }
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.caobaoPrimary)
                    .clipShape(Capsule())
                    .shadow(color: Color.caobaoPrimary.opacity(0.3), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .pressEffect()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(Color.caobaoGroupedBackground)
        .onAppear {
            withAnimation(.caobaoSpring.delay(0.1)) {
                // 触发动画
            }
        }
    }

    private var iconView: some View {
        Group {
            switch context {
            case .chat:
                Image(systemName: "message.bubble.fill")
                    .bounce()
            case .favorites:
                Image(systemName: "heart.slash.fill")
            case .history:
                Image(systemName: "clock.arrow.circlepath")
                    .rotating()
            case .search:
                Image(systemName: "magnifyingglass")
            case .network:
                Image(systemName: "wifi.slash")
            case .server:
                Image(systemName: "server.rack")
            case .loading:
                Image(systemName: "exclamationmark.triangle")
            case .permission:
                Image(systemName: "lock.shield")
            }
        }
    }

    private var iconColor: Color {
        switch context {
        case .chat:
            return .caobaoPrimary
        case .favorites:
            return .red
        case .history:
            return .orange
        case .search:
            return .blue
        case .network:
            return .purple
        case .server:
            return .red
        case .loading:
            return .orange
        case .permission:
            return .yellow
        }
    }

    private var title: String {
        switch context {
        case .chat:
            return "开始和草包对话吧"
        case .favorites:
            return "还没有收藏"
        case .history:
            return "暂无历史记录"
        case .search:
            return "未找到相关内容"
        case .network:
            return "网络连接失败"
        case .server:
            return "服务器暂时无法访问"
        case .loading:
            return "加载失败"
        case .permission:
            return "需要权限"
        }
    }

    private var subtitle: String? {
        switch context {
        case .chat:
            return "犀利毒舌，精准有用\n发送消息开始对话"
        case .favorites:
            return "收藏喜欢的金句和对话\n随时查看和分享"
        case .history:
            return "之前的对话会在这里显示\n开始新的对话吧"
        case .search:
            return "换个关键词试试看"
        case .network:
            return "请检查网络连接后重试"
        case .server:
            return "我们正在努力修复，请稍后再试"
        case .loading:
            return "内容加载失败，请重试"
        case .permission:
            return "请在设置中开启相关权限"
        }
    }
}

// MARK: - 对话空状态（专用）
public struct ChatEmptyState: View {
    @EnvironmentObject var appState: AppState

    public init() {}

    public var body: some View {
        VStack(spacing: 28) {
            // Logo动画
            ZStack {
                Circle()
                    .fill(Color.caobaoPrimary.opacity(0.1))
                    .frame(width: 120, height: 120)

                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                    .shadow(color: Color.caobaoPrimary.opacity(0.3), radius: 12, y: 4)
            }
            .bounce()

            VStack(spacing: 8) {
                Text("开始和草包对话吧")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                Text("犀利毒舌，精准有用")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .cardAppear(delay: 0.1)

            // 快捷提示
            VStack(spacing: 16) {
                QuickTip(
                    icon: "message.fill",
                    title: "直接输入问题",
                    subtitle: "开始智能对话"
                )
                .staggeredAppear(index: 0)

                QuickTip(
                    icon: "mic.fill",
                    title: "使用语音输入",
                    subtitle: "更便捷的对话方式"
                )
                .staggeredAppear(index: 1)

                QuickTip(
                    icon: "photo.fill",
                    title: "上传图片分析",
                    subtitle: "AI智能识别图片内容"
                )
                .staggeredAppear(index: 2)
            }
            .padding(.top, 12)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.caobaoGroupedBackground)
    }
}

// MARK: - 快捷提示组件
public struct QuickTip: View {
    let icon: String
    let title: String
    let subtitle: String

    public init(icon: String, title: String, subtitle: String) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.caobaoPrimary)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.caobaoPrimary.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        )
        .pressEffect()
    }
}

// MARK: - 收藏空状态（专用）
public struct FavoritesEmptyState: View {
    @EnvironmentObject var appState: AppState

    public init() {}

    public var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "heart.slash.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red.opacity(0.6))
                .bounce()

            VStack(spacing: 8) {
                Text("还没有收藏")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                Text("收藏喜欢的金句和对话")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                Button {
                    appState.selectedTab = .chat
                } label: {
                    HStack {
                        Image(systemName: "bubble.left.fill")
                        Text("去对话发现")
                    }
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.caobaoPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .pressEffect()

                Button {
                    appState.selectedTab = .home
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        Text("去浏览金句")
                    }
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.caobaoPrimary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.caobaoPrimary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .pressEffect()
            }
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.caobaoGroupedBackground)
    }
}

// MARK: - 搜索无结果
public struct SearchEmptyState: View {
    let searchTerm: String
    let clearAction: () -> Void

    public init(searchTerm: String, clearAction: @escaping () -> Void) {
        self.searchTerm = searchTerm
        self.clearAction = clearAction
    }

    public var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 64))
                .foregroundStyle(.blue.opacity(0.6))

            VStack(spacing: 8) {
                Text("未找到相关内容")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                Text("搜索"\(searchTerm)"无结果")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button(action: clearAction) {
                Text("清除搜索")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .pressEffect()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.caobaoGroupedBackground)
    }
}

// MARK: - 网络错误
public struct NetworkErrorState: View {
    let retryAction: () -> Void

    public init(retryAction: @escaping () -> Void) {
        self.retryAction = retryAction
    }

    public var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
            }

            VStack(spacing: 8) {
                Text("网络连接失败")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                Text("请检查网络连接后重试")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button(action: retryAction) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("重新加载")
                }
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.red)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .pressEffect()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.caobaoGroupedBackground)
    }
}

// MARK: - 加载中状态（骨架屏）
public struct LoadingSkeleton: View {
    let width: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat

    public init(width: CGFloat? = nil, height: CGFloat = 40, cornerRadius: CGFloat = 8) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.gray.opacity(0.2))
            .frame(width: width, height: height)
            .shimmer()
    }
}

// MARK: - 运势卡片骨架屏
public struct FortuneCardSkeleton: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 14) {
            HStack {
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 20, height: 20)
                LoadingSkeleton(height: 20, width: 100)
                Spacer()
            }

            HStack(spacing: 12) {
                ForEach(0..<5) { _ in
                    Circle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 30, height: 30)
                }
            }

            LoadingSkeleton(height: 12, width: nil)
            LoadingSkeleton(height: 12, width: 200)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
    }
}

// MARK: - 消息气泡骨架屏
public struct MessageBubbleSkeleton: View {
    let isFromUser: Bool

    public init(isFromUser: Bool) {
        self.isFromUser = isFromUser
    }

    public var body: some View {
        HStack {
            if isFromUser {
                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    LoadingSkeleton(height: 16, width: 100)
                    LoadingSkeleton(height: 16, width: 150)
                    LoadingSkeleton(height: 16, width: 80)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.caobaoPrimary.opacity(0.2))
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    LoadingSkeleton(height: 16, width: 120)
                    LoadingSkeleton(height: 16, width: 180)
                    LoadingSkeleton(height: 16, width: 100)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                )

                Spacer()
            }
        }
        .padding(.horizontal)
    }
}

#Preview("对话空状态") {
    ChatEmptyState()
        .environmentObject(AppState())
}

#Preview("收藏空状态") {
    FavoritesEmptyState()
        .environmentObject(AppState())
}

#Preview("网络错误") {
    NetworkErrorState {
        print("重试")
    }
}

#Preview("骨架屏") {
    VStack(spacing: 20) {
        FortuneCardSkeleton()
        MessageBubbleSkeleton(isFromUser: true)
        MessageBubbleSkeleton(isFromUser: false)
    }
    .padding()
}
