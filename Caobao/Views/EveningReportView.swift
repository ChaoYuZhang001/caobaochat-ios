import SwiftUI

// MARK: - Evening Report View (晚报)
// 基于今日聊天生成总结，回顾一天

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
    
    // MARK: - Not Available View (无聊天时的兜底内容)
    private func notAvailableView(_ info: NotAvailableInfo) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "moon.fill")
                .font(.system(size: 48))
                .foregroundStyle(.purple)
            
            Text(info.message)
                .font(.headline)
                .multilineTextAlignment(.center)
            
            // 提供一些有趣的内容
            VStack(spacing: 16) {
                Text("开始对话，获取个性化晚报总结")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                // 快捷入口
                VStack(spacing: 12) {
                    quickActionRow(icon: "quote.bubble", title: "毒舌金句", subtitle: "睡前一句") {
                        // 导航到金句
                    }
                    
                    quickActionRow(icon: "sparkles", title: "今日运势", subtitle: "看看今天怎么样") {
                        // 导航到运势
                    }
                    
                    quickActionRow(icon: "flame", title: "吐槽大会", subtitle: "发泄一下") {
                        // 导航到吐槽
                    }
                }
            }
            .padding(.top, 8)
            
            // 睡前小贴士
            VStack(spacing: 12) {
                Text("💡 睡前小贴士")
                    .font(.headline)
                    .foregroundStyle(.primary)
                
                Text(getRandomSleepTip())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.purple.opacity(0.1))
            )
            
            NavigationLink(destination: ChatView()) {
                Text("睡前聊一会儿")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient.caobaoEvening)
                    )
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding()
    }
    
    // MARK: - Quick Action Row
    private func quickActionRow(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.purple)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Report Content
    private func reportContent(_ report: EveningReportData) -> some View {
        VStack(spacing: 16) {
            // 晚安问候
            if let greeting = report.greeting, !greeting.isEmpty {
                greetingCard(greeting)
            }
            
            // 今日对话总结（从聊天提取）
            if let chatSummary = report.chatSummary, !chatSummary.isEmpty {
                summaryCard(chatSummary)
            }
            
            // 今日关键词
            if let keywords = report.keywords, !keywords.isEmpty {
                keywordsCard(keywords)
            }
            
            // 今日心情
            if let mood = report.mood {
                moodCard(mood)
            }
            
            // 今日成就
            if let achievements = report.achievements, !achievements.isEmpty {
                achievementsCard(achievements)
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
    
    // MARK: - Greeting Card
    private func greetingCard(_ greeting: String) -> some View {
        VStack(spacing: 8) {
            Text(greeting)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            
            Text(formatDate(Date()))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
    }
    
    // MARK: - Summary Card (从聊天提取的总结)
    private func summaryCard(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.purple)
                Text("今日对话总结")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("(AI 生成)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.purple.opacity(0.1))
        )
    }
    
    // MARK: - Keywords Card
    private func keywordsCard(_ keywords: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "tag.fill")
                    .foregroundStyle(.blue)
                Text("今日关键词")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            
            FlowLayout(spacing: 8) {
                ForEach(keywords, id: \.self) { keyword in
                    Text(keyword)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
    }
    
    // MARK: - Achievements Card
    private func achievementsCard(_ achievements: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "trophy.fill")
                    .foregroundStyle(.yellow)
                Text("今日成就")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            
            ForEach(achievements, id: \.self) { achievement in
                HStack(spacing: 8) {
                    Text("🏆")
                    Text(achievement)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.yellow.opacity(0.1))
        )
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
    
    // MARK: - Helper
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: date)
    }
    
    private func getRandomSleepTip() -> String {
        let tips = [
            "睡前一小时放下手机，让眼睛和大脑休息",
            "保持规律的作息时间，有助于提高睡眠质量",
            "睡前可以做一些轻度拉伸，放松身体",
            "保持卧室温度适宜，通常18-22度最舒适",
            "睡前避免饮用咖啡、茶等含咖啡因的饮品"
        ]
        return tips.randomElement() ?? tips[0]
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
                            message: data.message ?? "暂无今日对话记录",
                            nextUpdate: data.nextUpdate ?? ""
                        )
                    } else {
                        report = EveningReportData(
                            date: data.date,
                            greeting: data.greeting,
                            chatSummary: data.chatSummary,
                            keywords: data.keywords,
                            achievements: data.achievements,
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

// MARK: - Flow Layout
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height + spacing } - spacing
        return CGSize(width: proposal.width ?? 0, height: height > 0 ? height : 0)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                item.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += item.dimensions(in: .unspecified).width + spacing
            }
            y += row.height + spacing
        }
    }
    
    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var currentRowItems: [LayoutSubview] = []
        var currentX: CGFloat = 0
        let maxWidth = proposal.width ?? 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if currentX + size.width > maxWidth && !currentRowItems.isEmpty {
                rows.append(Row(items: currentRowItems, height: currentRowItems.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0))
                currentRowItems = []
                currentX = 0
            }
            
            currentRowItems.append(subview)
            currentX += size.width + spacing
        }
        
        if !currentRowItems.isEmpty {
            rows.append(Row(items: currentRowItems, height: currentRowItems.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0))
        }
        
        return rows
    }
    
    struct Row {
        let items: [LayoutSubview]
        let height: CGFloat
    }
}

// MARK: - Models
struct EveningReportData {
    let date: String?
    let greeting: String?
    let chatSummary: String?
    let keywords: [String]?
    let achievements: [String]?
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
