import Foundation
import Combine

@MainActor
final class QuoteViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var currentQuote: QuoteItem?
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var favorites: [QuoteItem] = []
    @Published var showFavorites = false
    @Published var copied = false
    
    // MARK: - Properties
    var category = "random"
    
    private let categories = [
        ("random", "随机", "🎲"),
        ("life", "生活", "🌅"),
        ("work", "工作", "💼"),
        ("love", "感情", "💔"),
        ("social", "社交", "👥"),
    ]
    
    private let apiService: APIService
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    init(apiService: APIService = .shared) {
        self.apiService = apiService
        loadFavorites()
    }
    
    // MARK: - Public Methods
    func generateQuote() async {
        loading = true
        errorMessage = nil
        
        do {
            let response = try await apiService.getQuote(category: category)
            
            if response.success, let quoteText = response.quote {
                currentQuote = QuoteItem(
                    id: UUID().uuidString,
                    content: quoteText,
                    category: response.category ?? category,
                    timestamp: response.timestamp ?? ISO8601DateFormatter().string(from: Date())
                )
                print("✅ 金句生成成功")
            } else if response.fallback == true {
                // 降级响应
                errorMessage = response.error ?? "数据格式错误"
                print("⚠️  使用降级响应: \(errorMessage ?? "")")
            } else {
                errorMessage = response.error ?? "获取金句失败"
                print("❌ 获取金句失败: \(errorMessage ?? "")")
            }
        } catch {
            errorMessage = "网络错误: \(error.localizedDescription)"
            print("❌ 网络请求失败: \(error)")
        }
        
        loading = false
    }
    
    func copyQuote() {
        guard let quote = currentQuote else { return }
        
        #if os(iOS)
        UIPasteboard.general.string = quote.content
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(quote.content, forType: .string)
        #endif
        
        copied = true
        print("✅ 已复制: \(quote.content.prefix(30))...")
        
        // 2秒后重置复制状态
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
    
    func toggleFavorite() {
        guard let quote = currentQuote else { return }
        
        if let index = favorites.firstIndex(where: { $0.content == quote.content }) {
            favorites.remove(at: index)
            print("❌ 已取消收藏: \(quote.content.prefix(30))...")
        } else {
            favorites.append(quote)
            print("❤️ 已收藏: \(quote.content.prefix(30))...")
        }
        
        saveFavorites()
    }
    
    func selectCategory(_ categoryId: String) {
        category = categoryId
        print("📂 切换分类: \(categoryId)")
    }
    
    func selectFavorite(_ quote: QuoteItem) {
        currentQuote = quote
        showFavorites = false
        print("📖 选择收藏: \(quote.content.prefix(30))...")
    }
    
    // MARK: - Private Methods
    private func loadFavorites() {
        if let data = UserDefaults.standard.data(forKey: "quote_favorites"),
           let decoded = try? JSONDecoder().decode([QuoteItem].self, from: data) {
            favorites = decoded
            print("📚 已加载 \(favorites.count) 条收藏")
        } else {
            favorites = []
            print("📚 收藏列表为空")
        }
    }
    
    private func saveFavorites() {
        if let encoded = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(encoded, forKey: "quote_favorites")
            print("💾 已保存 \(favorites.count) 条收藏")
        }
    }
    
    // MARK: - Computed Properties
    var isFavorited: Bool {
        guard let quote = currentQuote else { return false }
        return favorites.contains { $0.content == quote.content }
    }
}
