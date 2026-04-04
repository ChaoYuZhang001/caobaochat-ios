import SwiftUI

// MARK: - Watch News View
struct WatchNewsView: View {
    @EnvironmentObject var appState: WatchAppState
    @State private var news: [WatchNewsItem] = []
    @State private var isLoading = false
    @State private var selectedNews: WatchNewsItem?
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if news.isEmpty {
                        placeholder
                    } else {
                        ForEach(news.prefix(5)) { item in
                            WatchNewsCard(news: item)
                                .onTapGesture {
                                    selectedNews = item
                                }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("早报")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        loadNews()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task {
                if news.isEmpty {
                    loadNews()
                }
            }
            .sheet(item: $selectedNews) { item in
                WatchNewsDetailView(news: item)
            }
        }
    }
    
    private var placeholder: some View {
        VStack(spacing: 16) {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.8)
                Text("加载中...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "newspaper.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue.opacity(0.5))
                
                Text("点击右上角刷新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Button {
                    loadNews()
                } label: {
                    Text("获取早报")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func loadNews() {
        isLoading = true
        
        Task {
            do {
                let response = try await WatchAPIService.shared.getMorningReport()
                await MainActor.run {
                    self.news = response.news?.prefix(5).map { WatchNewsItem(from: $0) } ?? []
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Watch News Card
struct WatchNewsCard: View {
    let news: WatchNewsItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(news.source)
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())
                
                Spacer()
            }
            
            Text(news.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(3)
            
            if !news.comment.isEmpty {
                Text(news.comment)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Watch News Detail View
struct WatchNewsDetailView: View {
    let news: WatchNewsItem
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(news.source)
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())
                
                Text(news.title)
                    .font(.headline)
                
                if !news.summary.isEmpty {
                    Text(news.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                if !news.comment.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("毒舌点评")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        
                        Text(news.comment)
                            .font(.caption)
                            .italic()
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
        }
        .navigationTitle("详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Watch News Item Model
struct WatchNewsItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let source: String
    let summary: String
    let comment: String
    
    init(from item: MorningNewsItem) {
        self.title = item.title ?? ""
        self.source = item.source ?? "新闻"
        self.summary = item.summary ?? ""
        self.comment = item.comment ?? ""
    }
}

struct MorningNewsItem {
    let title: String?
    let source: String?
    let summary: String?
    let comment: String?
}

#Preview {
    WatchNewsView()
        .environmentObject(WatchAppState())
}
