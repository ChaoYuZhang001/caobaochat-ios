import SwiftUI

// MARK: - 下拉刷新增强
// 支持自定义刷新动画和状态

// MARK: - 刷新状态
public enum RefreshState: Equatable {
    case idle
    case pulling(progress: Double)
    case refreshing
    case succeeded
    case failed

    public static func == (lhs: RefreshState, rhs: RefreshState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.refreshing, .refreshing),
             (.succeeded, .succeeded),
             (.failed, .failed):
            return true
        case (.pulling(let p1), .pulling(let p2)):
            return p1 == p2
        default:
            return false
        }
    }
}

// MARK: - 自定义刷新视图
public struct CustomRefreshView: View {
    let state: RefreshState

    public init(state: RefreshState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 12) {
            switch state {
            case .idle:
                Image(systemName: "arrow.clockwise")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(0))

            case .pulling(let progress):
                Image(systemName: "arrow.down")
                    .font(.title3)
                    .foregroundStyle(.caobaoPrimary)
                    .rotationEffect(.degrees(progress * 180))

            case .refreshing:
                ZStack {
                    Circle()
                        .stroke(Color.caobaoPrimary.opacity(0.2), lineWidth: 3)
                        .frame(width: 24, height: 24)

                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(
                            Color.caobaoPrimary,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 24, height: 24)
                        .rotationEffect(.degrees(360))
                        .animation(
                            .linear(duration: 1).repeatForever(autoreverses: false),
                            value: true
                        )
                }

            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .scaleEffect(1.0)
                    .animation(.caobaoSpring, value: true)

            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
            }

            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(height: 50)
    }

    private var statusText: String {
        switch state {
        case .idle:
            return "下拉刷新"
        case .pulling:
            return "释放刷新"
        case .refreshing:
            return "正在刷新..."
        case .succeeded:
            return "刷新成功"
        case .failed:
            return "刷新失败"
        }
    }
}

// MARK: - 刷新容器
public struct RefreshContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content
    let onRefresh: () async -> Void

    @State private var state: RefreshState = .idle
    @State private var offset: CGFloat = 0
    @State private var showSuccess = false

    public init(onRefresh: @escaping () async -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.onRefresh = onRefresh
        self.content = content
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // 内容
                ScrollView {
                    VStack(spacing: 0) {
                        // 占位空间用于刷新视图
                        Color.clear
                            .frame(height: 0)
                            .offset(y: -offset)

                        content()
                    }
                    .offset(y: offset > 0 ? offset : 0)
                }
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard state == .idle else { return }

                            let newOffset = -value.translation.height
                            offset = min(max(newOffset, 0), 80)
                        }
                        .onEnded { value in
                            guard state == .idle else { return }

                            if offset > 50 {
                                startRefreshing()
                            } else {
                                withAnimation(.caobaoSpring) {
                                    offset = 0
                                }
                            }
                        }
                )

                // 刷新指示器
                VStack {
                    CustomRefreshView(state: state)
                        .frame(height: offset)
                        .opacity(min(offset / 50, 1))
                        .animation(.linear, value: offset)

                    Spacer()
                }
            }
            .onChange(of: state) { newState in
                if newState == .succeeded {
                    showSuccess = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        withAnimation(.caobaoSpring) {
                            offset = 0
                            showSuccess = false
                            state = .idle
                        }
                    }
                } else if newState == .failed {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(.caobaoSpring) {
                            offset = 0
                            state = .idle
                        }
                    }
                }
            }
        }
    }

    private func startRefreshing() {
        withAnimation(.caobaoSpring) {
            state = .refreshing
            offset = 50
        }

        Task {
            do {
                await onRefresh()

                await MainActor.run {
                    withAnimation(.caobaoSpring) {
                        state = .succeeded
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation(.caobaoSpring) {
                        state = .failed
                    }
                }
            }
        }
    }
}

// MARK: - 智能刷新容器（带自动检测）
public struct SmartRefreshContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content
    let onRefresh: () async -> Void

    @State private var state: RefreshState = .idle
    @State private var offset: CGFloat = 0
    @State private var lastRefreshTime: Date?

    public init(onRefresh: @escaping () async -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.onRefresh = onRefresh
        self.content = content
    }

    public var body: some View {
        RefreshContainer(onRefresh: performRefresh) {
            content()
        }
    }

    private func performRefresh() async {
        // 检查是否需要刷新（防止频繁刷新）
        if let lastTime = lastRefreshTime,
           Date().timeIntervalSince(lastTime) < 2 {
            // 距离上次刷新不到2秒，跳过
            return
        }

        lastRefreshTime = Date()
        await onRefresh()
    }
}

// MARK: - 下拉刷新修饰符
public extension View {
    /// 添加下拉刷新功能
    func refreshable(_ action: @escaping () async -> Void) -> some View {
        RefreshContainer(onRefresh: action) {
            self
        }
    }

    /// 添加智能下拉刷新（带频率限制）
    func smartRefreshable(_ action: @escaping () async -> Void) -> some View {
        SmartRefreshContainer(onRefresh: action) {
            self
        }
    }
}

// MARK: - 使用示例
struct RefreshExampleView: View {
    @State private var items = (1...10).map { "Item \($0)" }
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            RefreshContainer {
                VStack(spacing: 12) {
                    ForEach(items, id: \.self) { item in
                        HStack {
                            Text(item)
                                .font(.subheadline)
                            Spacer()
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.ultraThinMaterial)
                        )
                    }
                }
                .padding()
            } onRefresh: {
                await refreshData()
            }
            .navigationTitle("下拉刷新示例")
        }
    }

    private func refreshData() async {
        isLoading = true

        // 模拟网络请求
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // 更新数据
        items = (1...10).map { "刷新后的 Item \($0) - \(Int.random(in: 100...999))" }

        isLoading = false
    }
}

// MARK: - HomeView 刷新示例
struct HomeViewWithRefresh: View {
    @EnvironmentObject var appState: AppState
    @State private var fortune: FortuneData?
    @State private var loading = false
    @State private var lastRefreshTime: Date?

    var body: some View {
        RefreshContainer {
            ScrollView {
                VStack(spacing: 20) {
                    // Hero 区域
                    HeroSection()

                    // 运势卡片
                    if let fortune = fortune {
                        FortuneCard(fortune: fortune)
                            .cardAppear(delay: 0.2)
                    } else if loading {
                        FortuneCardSkeleton()
                    }

                    // 功能入口
                    FeatureGrid()

                    // 使用统计
                    StatsSection()
                }
                .padding()
            }
        } onRefresh: {
            await refreshContent()
        }
        .navigationTitle("草包")
    }

    private func refreshContent() async {
        // 防止频繁刷新
        if let lastTime = lastRefreshTime,
           Date().timeIntervalSince(lastTime) < 5 {
            return
        }

        loading = true

        do {
            // 加载运势
            let response = try await APIService.shared.getFortune(userId: appState.user?.id ?? "guest")
            if response.success {
                fortune = response.toFortuneData()
            }

            // 可以添加更多刷新内容
            // await loadMorningReport()
            // await loadStats()

            lastRefreshTime = Date()
        } catch {
            ErrorManager.shared.handle(error, strategy: .toast)
        }

        loading = false
    }
}

// MARK: - 对话页面刷新示例
struct ChatViewWithRefresh: View {
    @EnvironmentObject var appState: AppState
    @State private var messages: [Message] = []

    var body: some View {
        RefreshContainer {
            ScrollView {
                VStack(spacing: 12) {
                    if messages.isEmpty {
                        ChatEmptyState()
                    } else {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                        }
                    }
                }
                .padding()
            }
        } onRefresh: {
            await loadHistory()
        }
        .navigationTitle("对话")
    }

    private func loadHistory() async {
        do {
            let history = try await APIService.shared.getChatHistory(userId: appState.user?.id ?? "guest")
            messages = history
        } catch {
            ErrorManager.shared.handle(error, strategy: .inline)
        }
    }
}

// MARK: - 组件定义（示例）
struct HeroSection: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("早上好，用户")
                .font(.title2)
                .fontWeight(.bold)

            Text("今天也要开心地被毒舌哦~")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [Color.caobaoPrimary.opacity(0.1), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
    }
}

struct FortuneCard: View {
    let fortune: FortuneData

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                Text("今日运势")
                    .font(.headline)
                Spacer()
                Text("⭐⭐⭐⭐⭐")
                    .font(.caption)
            }

            HStack(spacing: 12) {
                FortuneItem(title: "综合", value: 5, color: .caobaoPrimary)
                FortuneItem(title: "爱情", value: 4, color: .pink)
                FortuneItem(title: "事业", value: 5, color: .blue)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
    }
}

struct FortuneItem: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.headline)
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct FeatureGrid: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(["自由对话", "今日运势", "图片分析", "毒舌金句"], id: \.self) { feature in
                Text(feature)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.ultraThinMaterial)
                    )
            }
        }
    }
}

struct StatsSection: View {
    var body: some View {
        HStack(spacing: 12) {
            StatCard(title: "对话", value: "128", color: .caobaoPrimary)
            StatCard(title: "天数", value: "7", color: .blue)
            StatCard(title: "连续", value: "3天", color: .orange)
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
    }
}

struct Message: Identifiable {
    let id = UUID()
    let content: String
    let isFromUser: Bool
}

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isFromUser {
                Spacer()

                Text(message.content)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.caobaoPrimary)
                    )
                    .foregroundStyle(.white)
            } else {
                Text(message.content)
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

struct FortuneData {
    let overall: Int
    let love: Int
    let career: Int
    let advice: String
}

// MARK: - APIService 模拟
class APIService {
    static let shared = APIService()

    private init() {}

    func getFortune(userId: String) async throws -> FortuneResponse {
        // 模拟API调用
        try await Task.sleep(nanoseconds: 500_000_000)

        return FortuneResponse(
            success: true,
            overall: 5,
            love: 4,
            career: 5,
            wealth: 3,
            health: 4,
            advice: "今天运势不错，适合做重要决策"
        )
    }

    func getChatHistory(userId: String) async throws -> [Message] {
        // 模拟API调用
        try await Task.sleep(nanoseconds: 300_000_000)

        return [
            Message(content: "你好", isFromUser: true),
            Message(content: "你好！有什么我可以帮助你的吗？", isFromUser: false)
        ]
    }
}

struct FortuneResponse {
    let success: Bool
    let overall: Int
    let love: Int
    let career: Int
    let wealth: Int
    let health: Int
    let advice: String

    func toFortuneData() -> FortuneData {
        FortuneData(
            overall: overall,
            love: love,
            career: career,
            advice: advice
        )
    }
}

// MARK: - AppState 模拟
class AppState: ObservableObject {
    @Published var selectedTab: Tab = .home
    @Published var user: User?
    @Published var userSettings = UserSettings()
    @Published var userStats = UserStats()
}

enum Tab {
    case home, chat, features, favorites, profile
}

struct User {
    let id: String
}

struct UserSettings {
    var nickname = "用户"
}

struct UserStats {
    var totalChats = 128
    var usageDays = 7
    var streak = 3
}

#Preview("刷新示例") {
    RefreshExampleView()
}
