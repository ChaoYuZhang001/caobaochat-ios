import Foundation
import Combine
import SwiftUI

// MARK: - QuoteViewModel
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
    @Published var category = "random"
    
    public let categories = [
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
                    timestamp: String(response.timestamp ?? Int(Date().timeIntervalSince1970))
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
        // 切换分类后自动生成新金句
        Task {
            await generateQuote()
        }
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

// MARK: - Quote View (毒舌金句)
struct QuoteView: View {
    @StateObject private var viewModel = QuoteViewModel()
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 背景
                Color.caobaoGroupedBackground
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // 分类选择
                        categorySection
                        
                        // 金句卡片
                        quoteSection
                        
                        // 操作按钮
                        actionButtons
                        
                        // 错误提示
                        if let error = viewModel.errorMessage {
                            errorBanner(error)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("扎心金句")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.showFavorites = true
                    } label: {
                        Image(systemName: "bookmark.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .sheet(isPresented: $viewModel.showFavorites) {
                FavoritesSheet(favorites: viewModel.favorites) { quote in
                    viewModel.selectFavorite(quote)
                }
            }
        }
        .onAppear {
            if viewModel.currentQuote == nil {
                Task {
                    await viewModel.generateQuote()
                }
            }
        }
    }
    
    // MARK: - View Components
    private var categorySection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(viewModel.categories, id: \.0) { cat in
                    CategoryButton(
                        title: cat.1,
                        emoji: cat.2,
                        isSelected: viewModel.category == cat.0
                    ) {
                        viewModel.selectCategory(cat.0)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
    
    private var quoteSection: some View {
        Group {
            if let quote = viewModel.currentQuote {
                QuoteCard(
                    quote: quote,
                    copied: viewModel.copied,
                    isFavorited: viewModel.isFavorited,
                    onCopy: { viewModel.copyQuote() },
                    onFavorite: { viewModel.toggleFavorite() }
                )
            } else if viewModel.loading {
                loadingView
            } else {
                EmptyQuoteView()
            }
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 20) {
            QuoteActionButton(
                title: "换一句",
                icon: "arrow.clockwise",
                color: .green,
                isLoading: viewModel.loading,
                action: {
                    Task {
                        await viewModel.generateQuote()
                    }
                }
            )
            
            QuoteActionButton(
                title: "收藏",
                icon: viewModel.isFavorited ? "heart.fill" : "heart",
                color: .red,
                action: {
                    viewModel.toggleFavorite()
                }
            )
            
            QuoteActionButton(
                title: "我的收藏",
                icon: "bookmark.fill",
                color: .blue,
                action: {
                    viewModel.showFavorites = true
                }
            )
        }
        .padding(.top)
    }
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("正在生成金句...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(height: 200)
    }
    
    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Models
struct QuoteItem: Codable, Identifiable {
    let id: String
    let content: String
    let category: String
    let timestamp: String
}

// MARK: - Components
struct CategoryButton: View {
    let title: String
    let emoji: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(emoji)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? Color.green : Color(.systemGray5))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
    }
}

struct QuoteCard: View {
    let quote: QuoteItem
    let copied: Bool
    let isFavorited: Bool
    let onCopy: () -> Void
    let onFavorite: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "quote.opening")
                .font(.largeTitle)
                .foregroundStyle(.green.opacity(0.5))
            
            Text(quote.content)
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .padding(.horizontal)
            
            HStack(spacing: 24) {
                Button(action: onCopy) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "已复制" : "复制")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.green)
                }
                
                Button(action: onFavorite) {
                    Image(systemName: isFavorited ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorited ? .red : .gray)
                }
            }
        }
        .padding(32)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.05), radius: 10)
    }
}

struct EmptyQuoteView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.bubble")
                .font(.system(size: 60))
                .foregroundStyle(.green.opacity(0.5))
            
            Text("点击下方按钮生成金句")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(height: 200)
    }
}

struct QuoteActionButton: View {
    let title: String
    let icon: String
    let color: Color
    var isLoading: Bool = false
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(.white)
                } else {
                    Image(systemName: icon)
                }
                Text(title)
                    .fontWeight(.medium)
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(isLoading)
    }
}

struct FavoritesSheet: View {
    let favorites: [QuoteItem]
    let onSelect: (QuoteItem) -> Void
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                if favorites.isEmpty {
                    Text("暂无收藏")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ForEach(favorites) { quote in
                        Button {
                            onSelect(quote)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(quote.content)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(3)
                                Text(quote.category)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("我的收藏")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    QuoteView()
}
