import SwiftUI
import StoreKit
#if os(iOS)
import UIKit
#endif

/// Prices and billing periods are always supplied by the configured StoreKit products.
@MainActor
struct AssistantSubscriptionView: View {
    @ObservedObject private var store: AssistantSubscriptionStore
    private let onEntitlementsChanged: () -> Void
    @State private var managementError: String?
    @State private var isShowingManagement = false
    @Environment(\.locale) private var locale
    #if os(iOS)
    @State private var windowScene: UIWindowScene?
    #endif

    init(store: AssistantSubscriptionStore? = nil, onEntitlementsChanged: @escaping () -> Void = {}) {
        self.store = store ?? .shared
        self.onEntitlementsChanged = onEntitlementsChanged
    }

    var body: some View {
        List {
            Section {
                Text("选择适合你的 CaoBao 订阅").font(.title3.bold())
                Text("实际价格和周期由当前 App Store 地区显示。购买后必须通过服务器验证，才能启用账号权益。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            if store.isLoading {
                Section { HStack { ProgressView(); Text("正在读取订阅商品…") } }
            } else if let unavailable = store.unavailableMessage {
                Section("订阅暂不可用") {
                    Text(LocalizedStringKey(unavailable)).font(.subheadline)
                    Button("重新加载") { Task { await store.loadConfiguration(force: true) } }
                        .disabled(store.isBusy)
                }
            } else if !store.products.isEmpty {
                Section("App Store 订阅方案") {
                    ForEach(store.products, id: \.id) { product in productRow(product) }
                }
            }

            if let subscription = store.lastVerifiedSubscription {
                Section("服务器验证状态") {
                    Text(subscriptionStatus(subscription.status))
                    if let date = subscriptionDate(subscription.expiresAt) {
                        LabeledContent { Text(date, style: .date) } label: { Text("权益到期时间") }
                    }
                    Text("用量和可用模型以服务器返回的账号权益为准。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let subscription = store.serverSubscription {
                Section("账号服务器权益") {
                    Text(subscriptionStatus(subscription.status ?? "none"))
                    if let productId = subscription.productId, !productId.isEmpty {
                        LabeledContent { Text(productId).textSelection(.enabled) } label: { Text("订阅商品") }
                    }
                    if let date = subscriptionDate(subscription.expiresAt) {
                        LabeledContent { Text(date, style: .date) } label: { Text("权益到期时间") }
                    }
                    Text("这是当前 CaoBao 账号的服务器快照；本设备尚未提交新的 StoreKit 交易验证。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let message = store.statusMessage {
                Section { Text(LocalizedStringKey(message)).font(.subheadline) }
            }
            if let message = store.errorMessage {
                Section("操作未完成") {
                    Text(LocalizedStringKey(message)).font(.subheadline).foregroundStyle(.red)
                }
            }
            if let managementError {
                Section { Text(LocalizedStringKey(managementError)).font(.caption).foregroundStyle(.red) }
            }

            Section("购买与管理") {
                Button { Task { await store.restorePurchases() } } label: {
                    HStack {
                        Text("恢复购买")
                        if store.isRestoring { Spacer(); ProgressView() }
                    }
                }.disabled(!store.canRestore || isShowingManagement)
                #if os(iOS)
                Button { Task { await manageSubscriptions() } } label: {
                    HStack {
                        Text("管理 App Store 订阅")
                        if isShowingManagement { Spacer(); ProgressView() }
                    }
                }.disabled(store.isBusy || isShowingManagement)
                #else
                Text("你可以在 App Store 账号中管理或取消订阅。")
                    .font(.subheadline).foregroundStyle(.secondary)
                #endif
                Text("订阅会按所选周期自动续订，价格以 App Store 确认页面为准。你可以在 App Store 账号中取消续订。取消续订与退款不同，账号权益以服务器验证的交易状态为准。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("自定义 API（BYOK）不消耗 CaoBao 平台免费次数，模型费用由你的 API 服务商收取。")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink("用户协议") { LegalView(type: .agreement) }
                NavigationLink("隐私政策") { LegalView(type: .privacy) }
            }
        }
        .assistantNavigationTitle("订阅")
        .task(id: store.accountRevision) { await store.loadConfiguration() }
        .onChange(of: store.entitlementRevision) { _ in onEntitlementsChanged() }
        .refreshable { await store.loadConfiguration(force: true) }
        #if os(iOS)
        .background(SubscriptionWindowSceneReader { scene in windowScene = scene })
        #endif
    }

    private func productRow(_ product: Product) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(product.displayName).font(.headline)
            if !product.description.isEmpty { Text(product.description).font(.subheadline).foregroundStyle(.secondary) }
            if let period = product.subscription?.subscriptionPeriod {
                let periodText = localizedPeriod(period)
                Text("\(product.displayPrice) / \(periodText)").font(.title3.bold())
            }
            Button { Task { await store.purchase(product) } } label: {
                HStack {
                    Text("订阅").fontWeight(.semibold)
                    Spacer()
                    if store.purchasingProductId == product.id { ProgressView() }
                    else { Text(product.displayPrice) }
                }.frame(minHeight: 44)
            }.disabled(!store.canPurchase || isShowingManagement)
        }.padding(.vertical, 8)
    }

    private func subscriptionStatus(_ status: String) -> LocalizedStringKey {
        switch status {
        case "active": return "订阅有效"
        case "trialing": return "试用权益有效"
        case "grace_period": return "订阅处于宽限期"
        case "expired": return "订阅已到期"
        case "revoked": return "订阅权益已撤销"
        case "refunded": return "订阅已退款"
        case "none": return "当前账号没有已验证订阅"
        default: return "请刷新账号权益"
        }
    }

    private func localizedPeriod(_ period: Product.SubscriptionPeriod) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        switch period.unit {
        case .day: formatter.allowedUnits = .day
        case .week: formatter.allowedUnits = .weekOfMonth
        case .month: formatter.allowedUnits = .month
        case .year: formatter.allowedUnits = .year
        @unknown default: return AssistantLocalization.string("App Store 订阅周期")
        }
        return formatter.string(from: DateComponents(subscriptionPeriod: period))
            ?? AssistantLocalization.string("App Store 订阅周期")
    }

    private func subscriptionDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    #if os(iOS)
    private func manageSubscriptions() async {
        guard !store.isBusy, !isShowingManagement else { return }
        guard let windowScene, windowScene.activationState == .foregroundActive else {
            managementError = AssistantLocalization.string("请在当前 App 窗口中重试订阅管理。")
            return
        }
        isShowingManagement = true; managementError = nil
        defer { isShowingManagement = false }
        do { try await AppStore.showManageSubscriptions(in: windowScene) }
        catch { managementError = AssistantLocalization.string("暂时无法打开 App Store 订阅管理，请稍后重试。") }
    }
    #endif
}

#if os(iOS)
/// Resolves the scene actually hosting this view instead of another app window.
private struct SubscriptionWindowSceneReader: UIViewRepresentable {
    let onChange: (UIWindowScene?) -> Void
    func makeUIView(context: Context) -> SubscriptionSceneView {
        let view = SubscriptionSceneView()
        view.onSceneChanged = onChange
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: SubscriptionSceneView, context: Context) { uiView.onSceneChanged = onChange }
}

private final class SubscriptionSceneView: UIView {
    var onSceneChanged: ((UIWindowScene?) -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        let scene = window?.windowScene
        DispatchQueue.main.async { [weak self] in self?.onSceneChanged?(scene) }
    }
}
#endif
