import SwiftUI

// MARK: - Quote View (毒舌金句)
struct QuoteView: View {
    @State private var currentQuote: QuoteItem?
    @State private var loading = false
    @State private var copied = false
    @State private var favorites: [QuoteItem] = []
    @State private var showFavorites = false
    @State private var category = "random"
    @State private var errorMessage: String?
    
    private let categories = [
        ("random", "随机", "🎲"),
        ("life", "生活", "🌅"),
        ("work", "工作", "💼"),
        ("love", "感情", "💔"),
        ("social", "社交", "👥"),
    ]
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 背景
                Color.caobaoGroupedBackground
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // 分类选择
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(categories, id: \.0) { cat in
                                    CategoryButton(
                                        title: cat.1,
                                        emoji: cat.2,
                                        isSelected: category == cat.0
                                    ) {
                                        category = cat.0
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        
                        // 金句卡片
                        if let quote = currentQuote {
                            QuoteCard(
                                quote: quote,
                                copied: copied,
                                onCopy: copyQuote,
                                onFavorite: toggleFavorite
                            )
                        } else {
                            EmptyQuoteView()
                        }
                        
                        // 操作按钮
                        HStack(spacing: 20) {
                            ActionButton(
                                title: "换一句",
                                icon: "arrow.clockwise",
                                color: .green,
                                action: {
                                    generateQuote()
                                }
                            )
                            
                            ActionButton(
                                title: "收藏",
                                icon: favorites.contains { $0.content == currentQuote?.content } ? "heart.fill" : "heart",
                                color: .red,
                                action: {
                                    toggleFavorite()
                                }
                            )
                            
                            ActionButton(
                                title: "我的收藏",
                                icon: "bookmark.fill",
                                color: .blue,
                                action: {
                                    showFavorites = true
                                }
                            )
                        }
                        .padding(.top)

                        // 错误提示
                        if let error = errorMessage {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(error)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(Color.orange.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("毒舌金句")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFavorites = true
                    } label: {
                        Image(systemName: "bookmark.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .sheet(isPresented: $showFavorites) {
                FavoritesSheet(favorites: favorites) { quote in
                    currentQuote = quote
                    showFavorites = false
                }
            }
        }
        .onAppear {
            if currentQuote == nil {
                generateQuote()
            }
            loadFavorites()
        }
    }
    
    // MARK: - Actions
    private func generateQuote() {
        loading = true
        errorMessage = nil
        Task {
            do {
                let response = try await APIService.shared.getQuote(category: category)
                await MainActor.run {
                    if response.success, let quote = response.quote {
                        currentQuote = QuoteItem(
                            id: UUID().uuidString,
                            content: quote,
                            category: response.category ?? category,
                            timestamp: response.timestamp ?? ISO8601DateFormatter().string(from: Date())
                        )
                    } else {
                        errorMessage = response.error ?? "获取金句失败"
                    }
                    loading = false
                }
            } catch {
                await MainActor.run {
                    loading = false
                    errorMessage = "网络错误: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func copyQuote() {
        guard let quote = currentQuote else { return }
        #if os(iOS)
        UIPasteboard.general.string = quote.content
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(quote.content, forType: .string)
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
    
    private func toggleFavorite() {
        guard let quote = currentQuote else { return }
        if let index = favorites.firstIndex(where: { $0.content == quote.content }) {
            favorites.remove(at: index)
        } else {
            favorites.append(quote)
        }
        saveFavorites()
    }
    
    private func loadFavorites() {
        if let data = UserDefaults.standard.data(forKey: "quote_favorites"),
           let decoded = try? JSONDecoder().decode([QuoteItem].self, from: data) {
            favorites = decoded
        }
    }
    
    private func saveFavorites() {
        if let encoded = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(encoded, forKey: "quote_favorites")
        }
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
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
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

struct FavoritesSheet: View {
    let favorites: [QuoteItem]
    let onSelect: (QuoteItem) -> Void
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            List {
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
