import SwiftUI

// MARK: - Morning Report View (早报)
// 基于昨日聊天提取待办，开启新的一天

struct MorningReportView: View {
    @State private var report: MorningReportData?
    @State private var notAvailable: NotAvailableInfo?
    @State private var isLoading = true
    @State private var error: String?
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 暖橙渐变背景（代表清晨阳光）
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(hex: "f59e0b"),
                        Color(hex: "ea580c")
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 16) {
                        if isLoading {
                            LoadingView(message: "正在生成今日早报...")
                        } else if let error = error {
                            ErrorView(message: error) {
                                Task { await loadReport() }
                            }
                        } else if let notAvailable = notAvailable {
                            notAvailableView(notAvailable)
                        } else if let report = report {
                            reportContent(report)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("早报")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadReport() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .task {
            await loadReport()
        }
    }
    
    // MARK: - Not Available View (无聊天时的兜底内容)
    private func notAvailableView(_ info: NotAvailableInfo) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            
            Text(info.message)
                .font(.headline)
                .multilineTextAlignment(.center)
            
            // 提供一些有趣的内容引导用户
            VStack(spacing: 16) {
                Text("开启今日对话，获取个性化早报")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                // 快捷入口
                VStack(spacing: 12) {
                    quickActionRow(icon: "message.fill", title: "自由对话", subtitle: "随便聊聊") {
                        // 切换到对话 Tab
                    }
                    
                    quickActionRow(icon: "sparkles", title: "阳光明媚", subtitle: "看看今天怎么样") {
                        // 导航到运势
                    }
                    
                    quickActionRow(icon: "flame", title: "吐槽大会", subtitle: "发泄一下") {
                        // 导航到吐槽
                    }
                }
            }
            .padding(.top, 8)
            
            NavigationLink(destination: ChatView()) {
                Text("开始对话")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient.caobaoPrimary)
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
                    .foregroundStyle(.caobaoPrimary)
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
    private func reportContent(_ report: MorningReportData) -> some View {
        VStack(spacing: 16) {
            // 问候语
            if let greeting = report.greeting, !greeting.isEmpty {
                greetingCard(greeting)
            }
            
            // 今日待办（从昨日聊天提取）
            if let todos = report.todos, !todos.isEmpty {
                todosCard(todos)
            }
            
            // 今日运势
            if let fortune = report.fortune {
                fortuneCard(fortune)
            }
            
            // 昨日回顾
            if let yesterdayReview = report.yesterdayReview, !yesterdayReview.isEmpty {
                infoCard(title: "昨日回顾", icon: "clock.arrow.circlepath", color: .blue, content: yesterdayReview)
            }
            
            // 健康提示
            if let health = report.health, !health.isEmpty {
                infoCard(title: "健康提示", icon: "heart.fill", color: .red, content: health)
            }
            
            // 行动指南
            if let action = report.action, !action.isEmpty {
                infoCard(title: "行动指南", icon: "target", color: .caobaoPrimary, content: action)
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
                infoCard(title: "趣味知识", icon: "lightbulb.fill", color: .yellow, content: funFact)
            }
            
            // 新闻资讯
            if let news = report.news, !news.isEmpty {
                newsCard(news)
            }
            
            // 每日语录
            if let quote = report.quote, !quote.isEmpty {
                quoteCard(quote)
            }
            
            // 去对话
            NavigationLink(destination: ChatView()) {
                Text("开始今日对话")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient.caobaoPrimary)
                            .shadow(color: .caobaoPrimary.opacity(0.3), radius: 8, y: 4)
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
    
    // MARK: - Todos Card (从聊天提取的待办)
    private func todosCard(_ todos: [TodoItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checklist")
                    .foregroundStyle(.caobaoPrimary)
                Text("今日待办")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("(从昨日对话提取)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            ForEach(todos) { todo in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(todo.isCompleted ? .green : .secondary)
                        .font(.subheadline)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(todo.content)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .strikethrough(todo.isCompleted)
                        
                        if let source = todo.source, !source.isEmpty {
                            Text("来源: \(source)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.caobaoPrimary.opacity(0.1))
        )
    }
    
    // MARK: - Fortune Card
    private func fortuneCard(_ fortune: FortuneInfo) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(.white)
                Text("阳光明媚")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            
            // 星星
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { i in
                    Image(systemName: i <= fortune.stars ? "star.fill" : "star")
                        .foregroundStyle(i <= fortune.stars ? .yellow : .gray.opacity(0.3))
                }
            }
            .font(.title)
            
            if let comment = fortune.comment, !comment.isEmpty {
                Text(comment)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient.caobaoFortune)
                .shadow(color: .orange.opacity(0.3), radius: 8, y: 4)
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
                Text("新闻资讯")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            
            ForEach(news.prefix(3), id: \.title) { item in
                VStack(alignment: .leading, spacing: 4) {
                    // 来源标签
                    if let source = item.source, !source.isEmpty {
                        Text(source)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                    
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
                    
                    // 毒舌点评
                    if let comment = item.comment, !comment.isEmpty {
                        Text("\(comment)")
                            .font(.caption)
                            .foregroundStyle(.orange)
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
                Image(systemName: "sparkles")
                    .foregroundStyle(.white)
                Text("每日语录")
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
    
    // MARK: - Load Report
    private func loadReport() async {
        isLoading = true
        error = nil
        notAvailable = nil
        
        do {
            let response = try await APIService.shared.getMorningReport()
            if response.success {
                if let data = response.data {
                    if data.available == false {
                        notAvailable = NotAvailableInfo(
                            message: data.message ?? "暂无昨日对话记录",
                            nextUpdate: data.nextUpdate ?? ""
                        )
                    } else {
                        report = MorningReportData(
                            date: data.date,
                            greeting: data.greeting,
                            todos: data.todos?.map { TodoItem(content: $0.content, isCompleted: $0.isCompleted ?? false, source: $0.source) },
                            yesterdayReview: data.yesterdayReview,
                            fortune: data.fortune.map { FortuneInfo(stars: $0.stars, comment: $0.comment) },
                            health: data.health,
                            action: data.action,
                            topic: data.topic,
                            caobaoSays: data.caobaoSays,
                            quote: data.quote,
                            funFact: data.funFact,
                            news: data.news?.map { NewsItem(title: $0.title, summary: $0.summary, url: $0.url, source: $0.source, comment: $0.comment) }
                        )
                    }
                }
            } else {
                error = response.message ?? "获取早报失败"
            }
        } catch {
            self.error = error.localizedDescription
        }
        
        isLoading = false
    }
}

// MARK: - Models
struct MorningReportData {
    let date: String?
    let greeting: String?
    let todos: [TodoItem]?
    let yesterdayReview: String?
    let fortune: FortuneInfo?
    let health: String?
    let action: String?
    let topic: String?
    let caobaoSays: String?
    let quote: String?
    let funFact: String?
    let news: [NewsItem]?
}

struct TodoItem: Identifiable {
    let id = UUID()
    let content: String
    let isCompleted: Bool
    let source: String?
}

struct FortuneInfo {
    let stars: Int
    let comment: String?
}

struct NewsItem {
    let title: String?
    let summary: String?
    let url: String?
    let source: String?
    let comment: String?
}

struct NotAvailableInfo {
    let message: String
    let nextUpdate: String
}

#Preview {
    MorningReportView()
}
