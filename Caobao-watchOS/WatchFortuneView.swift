import SwiftUI

// MARK: - Watch Fortune View
struct WatchFortuneView: View {
    @EnvironmentObject var appState: WatchAppState
    @State private var fortune: WatchFortune?
    @State private var isLoading = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let fortune = fortune {
                    fortuneContent(fortune)
                } else {
                    placeholder
                }
            }
            .padding()
        }
        .navigationTitle("今日运势")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    loadFortune()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task {
            if fortune == nil {
                loadFortune()
            }
        }
    }
    
    @ViewBuilder
    private func fortuneContent(_ fortune: WatchFortune) -> some View {
        // 运势指数
        HStack {
            Text("运势")
                .font(.caption)
            Spacer()
            Text("\(fortune.fortuneIndex)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(fortuneColor(fortune.fortuneIndex))
        }
        
        // 运势描述
        Text(fortune.fortuneSummary)
            .font(.caption)
            .multilineTextAlignment(.center)
        
        Divider()
        
        // 评分
        VStack(alignment: .leading, spacing: 6) {
            fortuneItem("爱情", score: fortune.loveScore, icon: "heart.fill", color: .pink)
            fortuneItem("事业", score: fortune.careerScore, icon: "briefcase.fill", color: .blue)
            fortuneItem("财运", score: fortune.wealthScore, icon: "yensign.circle.fill", color: .yellow)
            fortuneItem("健康", score: fortune.healthScore, icon: "heart.fill", color: .green)
        }
        
        Divider()
        
        // 毒舌建议
        VStack(alignment: .leading, spacing: 4) {
            Text("毒舌建议")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(fortune.advice)
                .font(.caption2)
        }
    }
    
    private func fortuneItem(_ title: String, score: Int, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
            Spacer()
            Text("\(score)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(fortuneColor(score))
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
                Image(systemName: "sparkles")
                    .font(.system(size: 32))
                    .foregroundStyle(.green.opacity(0.5))
                
                Text("点击右上角刷新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Button {
                    loadFortune()
                } label: {
                    Text("查看今日运势")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func fortuneColor(_ score: Int) -> Color {
        if score >= 80 { return .green }
        if score >= 60 { return .blue }
        if score >= 40 { return .orange }
        return .red
    }
    
    private func loadFortune() {
        isLoading = true
        
        Task {
            do {
                let response = try await WatchAPIService.shared.getFortune()
                await MainActor.run {
                    self.fortune = WatchFortune(
                        fortuneIndex: response.fortuneIndex,
                        fortuneSummary: response.fortuneSummary,
                        loveScore: response.loveScore,
                        careerScore: response.careerScore,
                        wealthScore: response.wealthScore,
                        healthScore: response.healthScore,
                        advice: response.advice
                    )
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

// MARK: - Watch Fortune Model
struct WatchFortune {
    let fortuneIndex: Int
    let fortuneSummary: String
    let loveScore: Int
    let careerScore: Int
    let wealthScore: Int
    let healthScore: Int
    let advice: String
}

#Preview {
    NavigationStack {
        WatchFortuneView()
            .environmentObject(WatchAppState())
    }
}
