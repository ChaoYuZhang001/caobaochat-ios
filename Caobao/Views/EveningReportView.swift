import SwiftUI

// MARK: - Evening Report View (晚安日报)
// 与 Web 端保持一致的设计风格

struct EveningReportView: View {
    @State private var report: EveningReportData?
    @State private var notAvailable: NotAvailableInfo?
    @State private var isLoading = true
    @State private var error: String?
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 背景色
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 16) {
                        if isLoading {
                            loadingView
                        } else if let error = error {
                            errorView(error)
                        } else if let notAvailable = notAvailable {
                            notAvailableView(notAvailable)
                        } else if let report = report {
                            reportContent(report)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("晚报")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadReport() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.caobaoPrimary)
                    }
                }
            }
        }
        .task {
            await loadReport()
        }
    }
    
    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("正在生成今日晚报...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
    
    // MARK: - Error View
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text(error)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task { await loadReport() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.caobaoPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
    
    // MARK: - Not Available View
    private func notAvailableView(_ info: NotAvailableInfo) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.fill")
                .font(.system(size: 48))
                .foregroundStyle(.purple)
            Text(info.message)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("下次更新时间: \(info.nextUpdate)")
                .font(.caption)
                .foregroundStyle(.secondary)
            NavigationLink(destination: ChatView()) {
                Text("先去聊聊")
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(LinearGradient.caobaoEvening)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
    
    // MARK: - Report Content
    private func reportContent(_ report: EveningReportData) -> some View {
        VStack(spacing: 16) {
            // 今日心情
            if let mood = report.mood {
                moodCard(mood)
            }
            
            // 今日回顾
            if let review = report.review, !review.isEmpty {
                infoCard(title: "今日回顾", icon: "heart.fill", color: .pink, content: review)
            }
            
            // 明日计划
            if let plan = report.tomorrowPlan, !plan.isEmpty {
                planCard(plan)
            }
            
            // 今日话题
            if let topic = report.topic, !topic.isEmpty {
                infoCard(title: "今日话题", icon: "bubble.left.and.bubble.right.fill", color: .blue, content: topic)
            }
            
            // 草包说
            if let caobaoSays = report.caobaoSays, !caobaoSays.isEmpty {
                caobaoCard(caobaoSays)
            }
            
            // 趣味知识
            if let funFact = report.funFact, !funFact.isEmpty {
                infoCard(title: "趣味冷知识", icon: "lightbulb.fill", color: .yellow, content: funFact)
            }
            
            // 新闻资讯
            if let news = report.news, !news.isEmpty {
                newsCard(news)
            }
            
            // 晚安语录
            if let quote = report.quote, !quote.isEmpty {
                quoteCard(quote)
            }
            
            // 睡前聊一会儿
            NavigationLink(destination: ChatView()) {
                Text("睡前聊一会儿")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient.caobaoEvening)
                            .shadow(color: .purple.opacity(0.3), radius: 8, y: 4)
                    )
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Mood Card
    private func moodCard(_ mood: MoodInfo) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "moon.fill")
                    .foregroundStyle(.white)
                Text("今日心情")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            
            if let analysis = mood.analysis, !analysis.isEmpty {
                Text(analysis)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
            
            if let suggestion = mood.suggestion, !suggestion.isEmpty {
                HStack(spacing: 4) {
                    Text("💡")
                    Text(suggestion)
                        .font(.caption)
                }
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient.caobaoEvening)
                .shadow(color: .purple.opacity(0.3), radius: 8, y: 4)
        )
    }
    
    // MARK: - Info Card
    private func infoCard(title: String, icon: String, color: Color, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            Text(content)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        )
    }
    
    // MARK: - Plan Card
    private func planCard(_ plans: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "target")
                    .foregroundStyle(.caobaoPrimary)
                Text("明日计划")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            
            ForEach(plans, id: \.self) { plan in
                HStack(alignment: .top, spacing: 8) {
                    Text("→")
                        .foregroundStyle(.caobaoPrimary)
                    Text(plan)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        )
    }
    
    // MARK: - Caobao Card
    private func caobaoCard(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("草包说")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            Text("\"\(content)\"")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .italic()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.purple.opacity(0.1))
        )
    }
    
    // MARK: - News Card
    private func newsCard(_ news: [NewsItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("📰")
                Text("今日要闻")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            
            ForEach(news.prefix(3), id: \.title) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title ?? "")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    if let summary = item.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let comment = item.comment, !comment.isEmpty {
                        Text("\"\(comment)\"")
                            .font(.caption)
                            .foregroundStyle(.purple)
                            .italic()
                    }
                }
                .padding(.vertical, 4)
                if item.title != news.last?.title {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        )
    }
    
    // MARK: - Quote Card
    private func quoteCard(_ quote: String) -> some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "moon.fill")
                    .foregroundStyle(.white)
                Text("晚安语录")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            Text("\"\(quote)\"")
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient.caobaoQuote)
                .shadow(color: .purple.opacity(0.3), radius: 8, y: 4)
        )
    }
    
    // MARK: - Load Report
    private func loadReport() async {
        isLoading = true
        error = nil
        notAvailable = nil
        
        do {
            let response = try await APIService.shared.getEveningReport()
            if response.success {
                if let data = response.data {
                    if data.available == false {
                        notAvailable = NotAvailableInfo(
                            message: data.message ?? "晚报将在 21:00 生成",
                            nextUpdate: data.nextUpdate ?? "21:00"
                        )
                    } else {
                        report = EveningReportData(
                            date: data.date,
                            greeting: data.greeting,
                            mood: data.mood.map { MoodInfo(analysis: $0.analysis, suggestion: $0.suggestion) },
                            review: data.review,
                            tomorrowPlan: data.tomorrowPlan,
                            topic: data.topic,
                            caobaoSays: data.caobaoSays,
                            quote: data.quote,
                            funFact: data.funFact,
                            news: data.news?.map { NewsItem(title: $0.title, summary: $0.summary, url: $0.url, source: $0.source, comment: $0.comment) }
                        )
                    }
                }
            } else {
                error = response.message ?? "获取晚报失败"
            }
        } catch {
            self.error = error.localizedDescription
        }
        
        isLoading = false
    }
}

// MARK: - Models
struct EveningReportData {
    let date: String?
    let greeting: String?
    let mood: MoodInfo?
    let review: String?
    let tomorrowPlan: [String]?
    let topic: String?
    let caobaoSays: String?
    let quote: String?
    let funFact: String?
    let news: [NewsItem]?
}

struct MoodInfo {
    let analysis: String?
    let suggestion: String?
}

#Preview {
    EveningReportView()
}
