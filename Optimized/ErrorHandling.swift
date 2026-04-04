import SwiftUI

// MARK: - 增强型错误处理系统
// 统一的错误类型、处理和展示

// MARK: - 错误类型
public enum AppError: LocalizedError, Equatable {
    case network(Error)
    case server(code: Int, message: String)
    case parsing
    case unauthorized
    case notFound
    case timeout
    case cancelled
    case unknown(message: String = "未知错误")

    public var errorDescription: String? {
        switch self {
        case .network:
            return "网络连接失败，请检查网络设置"
        case .server(let code, let message):
            return "服务器错误(\(code)): \(message)"
        case .parsing:
            return "数据解析失败，请稍后重试"
        case .unauthorized:
            return "登录已过期，请重新登录"
        case .notFound:
            return "未找到相关内容"
        case .timeout:
            return "请求超时，请检查网络连接"
        case .cancelled:
            return "操作已取消"
        case .unknown(let message):
            return message
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .network:
            return "请检查网络连接后重试"
        case .server:
            return "服务器暂时不可用，请稍后再试"
        case .parsing:
            return "请刷新页面重试"
        case .unauthorized:
            return "请重新登录"
        case .timeout:
            return "请检查网络连接或稍后重试"
        default:
            return nil
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .network, .server, .parsing, .timeout, .unknown:
            return true
        case .unauthorized, .notFound, .cancelled:
            return false
        }
    }

    public static func == (lhs: AppError, rhs: AppError) -> Bool {
        switch (lhs, rhs) {
        case (.network, .network),
             (.parsing, .parsing),
             (.unauthorized, .unauthorized),
             (.notFound, .notFound),
             (.timeout, .timeout),
             (.cancelled, .cancelled):
            return true
        case (.server(let code1, _), .server(let code2, _)):
            return code1 == code2
        case (.unknown(let msg1), .unknown(let msg2)):
            return msg1 == msg2
        default:
            return false
        }
    }
}

// MARK: - 错误处理策略
public enum ErrorHandlingStrategy {
    case alert          // 显示警告对话框
    case toast          // 显示提示消息
    case inline         // 在行内显示错误
    case silent         // 静默处理
    case custom((AppError) -> Void)  // 自定义处理
}

// MARK: - 错误管理器
public class ErrorManager: ObservableObject {
    @Published public var currentError: AppError?
    @Published public var showToast: Bool = false

    public static let shared = ErrorManager()

    private init() {}

    // 处理错误
    public func handle(_ error: Error, strategy: ErrorHandlingStrategy = .alert) {
        let appError = convertToAppError(error)

        switch strategy {
        case .alert:
            currentError = appError
        case .toast:
            currentError = appError
            withAnimation {
                showToast = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    showToast = false
                }
            }
        case .inline:
            currentError = appError
        case .silent:
            print("Error handled silently: \(appError.localizedDescription)")
        case .custom(let handler):
            handler(appError)
        }
    }

    // 清除错误
    public func clearError() {
        currentError = nil
        showToast = false
    }

    // 转换错误
    private func convertToAppError(_ error: Error) -> AppError {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return .network(urlError)
            case .timedOut:
                return .timeout
            default:
                return .network(urlError)
            }
        }

        if let appError = error as? AppError {
            return appError
        }

        return .unknown(message: error.localizedDescription)
    }
}

// MARK: - 重试处理器
public class RetryHandler {
    /// 重试操作
    public static func retry<T>(
        _ operation: @escaping () async throws -> T,
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 1.0,
        backoffMultiplier: Double = 2.0
    ) async throws -> T {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error

                // 如果不可重试，直接抛出
                if let appError = error as? AppError, !appError.isRetryable {
                    throw error
                }

                // 如果还有重试次数，延迟后重试
                if attempt < maxRetries - 1 {
                    let delay = baseDelay * pow(backoffMultiplier, Double(attempt))
                    print("Retry attempt \(attempt + 1)/\(maxRetries), delay: \(delay)s")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }

        throw lastError ?? AppError.unknown()
    }

    /// 带指数退避的重试
    public static func retryWithExponentialBackoff<T>(
        _ operation: @escaping () async throws -> T,
        maxRetries: Int = 3,
        initialDelay: TimeInterval = 1.0
    ) async throws -> T {
        try await retry(
            operation,
            maxRetries: maxRetries,
            baseDelay: initialDelay,
            backoffMultiplier: 2.0
        )
    }
}

// MARK: - 错误提示视图
public struct ErrorAlert: View {
    let error: AppError
    let onDismiss: () -> Void
    let onRetry: (() -> Void)?

    public init(error: AppError, onDismiss: @escaping () -> Void, onRetry: (() -> Void)? = nil) {
        self.error = error
        self.onDismiss = onDismiss
        self.onRetry = onRetry
    }

    public var body: some View {
        ZStack {
            // 半透明背景
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            // 错误卡片
            VStack(spacing: 20) {
                // 图标
                ZStack {
                    Circle()
                        .fill(errorIconColor.opacity(0.1))
                        .frame(width: 80, height: 80)

                    Image(systemName: errorIconName)
                        .font(.system(size: 36))
                        .foregroundStyle(errorIconColor)
                }
                .bounce()

                VStack(spacing: 8) {
                    Text(errorTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(error.localizedDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // 按钮组
                VStack(spacing: 12) {
                    if let onRetry = onRetry, error.isRetryable {
                        Button(action: {
                            onRetry()
                            onDismiss()
                        }) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("重试")
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
                    }

                    Button(action: onDismiss) {
                        Text("知道了")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .pressEffect()
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 20)
            )
            .padding(.horizontal, 40)
            .transition(.scale.combined(with: .opacity))
        }
    }

    private var errorIconName: String {
        switch error {
        case .network, .timeout:
            return "wifi.exclamationmark"
        case .server:
            return "server.rack"
        case .parsing:
            return "doc.text.magnifyingglass"
        case .unauthorized:
            return "lock.shield"
        case .notFound:
            return "magnifyingglass"
        case .cancelled:
            return "xmark.circle"
        default:
            return "exclamationmark.triangle"
        }
    }

    private var errorIconColor: Color {
        switch error {
        case .network, .timeout:
            return .orange
        case .server:
            return .red
        case .parsing:
            return .blue
        case .unauthorized:
            return .yellow
        case .notFound:
            return .purple
        default:
            return .red
        }
    }

    private var errorTitle: String {
        switch error {
        case .network:
            return "网络连接失败"
        case .server:
            return "服务器错误"
        case .parsing:
            return "数据解析失败"
        case .unauthorized:
            return "登录已过期"
        case .notFound:
            return "未找到内容"
        case .timeout:
            return "请求超时"
        case .cancelled:
            return "操作已取消"
        default:
            return "发生错误"
        }
    }
}

// MARK: - Toast提示
public struct ErrorToast: View {
    let error: AppError
    let isShowing: Binding<Bool>

    public init(error: AppError, isShowing: Binding<Bool>) {
        self.error = error
        self._isShowing = isShowing
    }

    public var body: some View {
        if isShowing.wrappedValue {
            VStack {
                Spacer()

                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.white)

                    Text(error.localizedDescription)
                        .font(.subheadline)
                        .foregroundStyle(.white)

                    Spacer()

                    Button {
                        withAnimation {
                            isShowing.wrappedValue = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.2), radius: 8)
                )
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation {
                        isShowing.wrappedValue = false
                    }
                }
            }
        }
    }
}

// MARK: - 行内错误显示
public struct InlineError: View {
    let error: AppError
    let onRetry: (() -> Void)?

    public init(error: AppError, onRetry: (() -> Void)? = nil) {
        self.error = error
        self.onRetry = onRetry
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(error.localizedDescription)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let onRetry = onRetry, error.isRetryable {
                Button(action: onRetry) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("重试")
                    }
                    .font(.caption)
                    .foregroundStyle(.caobaoPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.caobaoPrimary.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .pressEffect()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.red.opacity(0.05))
        )
    }
}

// MARK: - 错误边界
public struct ErrorBoundary<Content: View>: View {
    let content: () -> Content
    @State private var hasError = false
    @State private var error: Error?

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        if hasError {
            ErrorView(error: error ?? AppError.unknown()) {
                hasError = false
                error = nil
            }
        } else {
            content()
        }
    }

    func catchError(_ error: Error) {
        self.error = error
        self.hasError = true
    }
}

// MARK: - 错误视图（全屏）
public struct ErrorView: View {
    let error: AppError
    let onRetry: (() -> Void)?

    public init(error: AppError, onRetry: (() -> Void)? = nil) {
        self.error = error
        self.onRetry = onRetry
    }

    public var body: some View {
        NetworkErrorState {
            onRetry?()
        }
    }
}

// MARK: - 使用示例
struct ErrorHandlingExamples: View {
    @State private var showAlert = false
    @State private var showToast = false
    @State private var currentError: AppError?

    var body: some View {
        VStack(spacing: 30) {
            // 触发错误按钮
            VStack(spacing: 12) {
                Button("网络错误") {
                    currentError = .network(URLError(.notConnectedToInternet))
                    showAlert = true
                }
                .buttonStyle(.borderedProminent)

                Button("服务器错误") {
                    currentError = .server(code: 500, message: "内部服务器错误")
                    showAlert = true
                }
                .buttonStyle(.borderedProminent)

                Button("超时错误") {
                    currentError = .timeout
                    showToast = true
                }
                .buttonStyle(.borderedProminent)
            }

            // 行内错误示例
            InlineError(
                error: .server(code: 500, message: "API错误"),
                onRetry: { print("重试") }
            )

            Spacer()
        }
        .padding()
        .overlay(
            Group {
                if let error = currentError, showAlert {
                    ErrorAlert(error: error) {
                        showAlert = false
                    }
                }

                if let error = currentError, showToast {
                    ErrorToast(error: error, isShowing: $showToast)
                }
            }
        )
    }
}

#Preview("错误提示") {
    ErrorHandlingExamples()
}
