import SwiftUI

struct RateView: View {
    @State private var content: String = ""
    @State private var selectedType: String = "text"
    @State private var result: RateResult?
    @State private var isLoading = false
    @State private var error: String?
    @State private var showingShareSheet = false
    
    private let types = [
        ("text", "文字/想法", "📝", "评价你的想法"),
        ("behavior", "行为/做法", "🎭", "评价你的行为"),
        ("work", "工作表现", "💼", "评价工作成果"),
        ("life", "生活状态", "🌈", "评价生活方式")
    ]
    
    private let quickExamples = [
        "我今天又在想明天要开始减肥了",
        "买了一堆书但从来没看完过",
        "每次说早睡结果都熬到凌晨",
        "计划周末学习结果躺了一天",
        "明明很困却还在刷手机"
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 类型选择
                    typeSelector
                    
                    // 快速示例
                    quickExamplesSection
                    
                    // 输入区
                    inputSection
                    
                    // 结果展示
                    if let result = result {
                        resultSection(result)
                    }
                }
                .padding()
            }
            .navigationTitle("毒舌打分")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if result != nil {
                        Button(action: { showingShareSheet = true }) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let result = result {
                    ShareSheet(items: [shareText(result)])
                }
            }
        }
    }
    
    // MARK: - Type Selector
    private var typeSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("评分类型")
                .font(.headline)
            
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 10) {
                ForEach(types, id: \.0) { type in
                    Button {
                        selectedType = type.0
                    } label: {
                        HStack(spacing: 8) {
                            Text(type.2)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.1)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(type.3)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(selectedType == type.0 ? Color.pink.opacity(0.15) : Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selectedType == type.0 ? Color.pink : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    // MARK: - Quick Examples
    private var quickExamplesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.pink)
                Text("快速选择")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickExamples, id: \.self) { example in
                        Button {
                            content = example
                        } label: {
                            Text(example.count > 12 ? String(example.prefix(12)) + "..." : example)
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(content == example ? Color.pink : Color(.secondarySystemBackground))
                                .foregroundStyle(content == example ? .white : .primary)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Input Section
    private var inputSection: some View {
        VStack(spacing: 12) {
            TextEditor(text: $content)
                .frame(minHeight: 100)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
                .overlay(alignment: .topLeading) {
                    if content.isEmpty {
                        Text("输入你想要评分的内容...")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(12)
                    }
                }
            
            Button {
                Task { await submitRate() }
            } label: {
                HStack {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "star.fill")
                    }
                    Text(isLoading ? "评分中..." : "开始评分")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(content.isEmpty ? Color.gray : Color.pink)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(content.isEmpty || isLoading)
        }
    }
    
    // MARK: - Result Section
    private func resultSection(_ result: RateResult) -> some View {
        VStack(spacing: 16) {
            // 分数展示
            ZStack {
                Circle()
                    .stroke(scoreColor(result.score).opacity(0.2), lineWidth: 12)
                    .frame(width: 140, height: 140)
                
                Circle()
                    .trim(from: 0, to: CGFloat(result.score) / 100)
                    .stroke(scoreColor(result.score), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .frame(width: 140, height: 140)
                    .rotationEffect(.degrees(-90))
                    .animation(.spring, value: result.score)
                
                VStack {
                    Text("\(result.score)")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(scoreColor(result.score))
                    Text(scoreLabel(result.score))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 20)
            
            // 扣分项
            if let deductions = result.deductions, !deductions.isEmpty {
                resultCard(
                    title: "扣分项",
                    icon: "hand.thumbsdown.fill",
                    color: .red,
                    items: deductions,
                    prefix: "−"
                )
            }
            
            // 加分项
            if let additions = result.additions, !additions.isEmpty {
                resultCard(
                    title: "加分项",
                    icon: "hand.thumbsup.fill",
                    color: .green,
                    items: additions,
                    prefix: "+"
                )
            }
            
            // 毒舌点评
            if let comment = result.comment {
                commentCard(title: "毒舌点评", icon: "bubble.left.and.bubble.right.fill", color: .purple, content: comment)
            }
            
            // 改进建议
            if let suggestion = result.suggestion {
                commentCard(title: "改进建议", icon: "lightbulb.fill", color: .orange, content: suggestion)
            }
            
            // 操作按钮
            HStack(spacing: 12) {
                Button {
                    self.result = nil
                    content = ""
                } label: {
                    Label("再评一个", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                
                Button {
                    showingShareSheet = true
                } label: {
                    Label("分享结果", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.pink)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(.top)
    }
    
    // MARK: - Result Card
    private func resultCard(title: String, icon: String, color: Color, items: [String], prefix: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
            }
            
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text(prefix)
                        .foregroundStyle(color)
                    Text(item)
                        .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Comment Card
    private func commentCard(title: String, icon: String, color: Color, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
            }
            
            Text(content)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Helper Methods
    private func scoreColor(_ score: Int) -> Color {
        if score >= 80 { return .green }
        if score >= 60 { return .orange }
        return .red
    }
    
    private func scoreLabel(_ score: Int) -> String {
        if score >= 90 { return "优秀" }
        if score >= 80 { return "良好" }
        if score >= 70 { return "中等" }
        if score >= 60 { return "及格" }
        return "不及格"
    }
    
    private func shareText(_ result: RateResult) -> String {
        var text = "【毒舌评分】\(result.score)分\n\n"
        if let comment = result.comment {
            text += "💬 点评：\(comment)\n\n"
        }
        if let suggestion = result.suggestion {
            text += "💡 建议：\(suggestion)\n\n"
        }
        text += "—— 草包评分，公正无情"
        return text
    }
    
    // MARK: - Submit Rate
    private func submitRate() async {
        guard !content.isEmpty else { return }
        
        isLoading = true
        error = nil
        
        do {
            let response = try await APIService.shared.rate(content: content, type: selectedType)
            if response.success {
                result = RateResult(
                    score: response.score,
                    deductions: response.deductions,
                    additions: response.additions,
                    comment: response.comment,
                    suggestion: response.suggestion
                )
            } else {
                error = response.error ?? "评分失败"
            }
        } catch {
            self.error = error.localizedDescription
        }
        
        isLoading = false
    }
}

// MARK: - Rate Result Model
struct RateResult {
    let score: Int
    let deductions: [String]?
    let additions: [String]?
    let comment: String?
    let suggestion: String?
}

// MARK: - Share Sheet
#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
struct ShareSheet: NSViewRepresentable {
    let items: [Any]
    
    func makeNSView(context: Context) -> NSShareView {
        NSShareView(sharingItems: items)
    }
    
    func updateNSView(_ nsView: NSShareView, context: Context) {}
}
#endif

#Preview {
    RateView()
}
