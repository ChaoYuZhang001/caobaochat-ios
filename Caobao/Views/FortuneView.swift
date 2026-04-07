import SwiftUI

// MARK: - Fortune View (今日运势)
// 与 Web 端保持一致的设计风格

struct FortuneView: View {
    @State private var fortune: FortuneData?
    @State private var isLoading = false
    @State private var error: String?
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 背景色
                Color.caobaoGroupedBackground
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        if let fortune = fortune {
                            fortuneCard(fortune)
                        } else if isLoading {
                            ProgressView("正在为你算命...")
                                .padding(.top, 100)
                        } else {
                            emptyState
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("阳光明媚")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task {
                            await loadFortune()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.caobaoPrimary)
                    }
                }
            }
        }
        .task {
            await loadFortune()
        }
    }
    
    // MARK: - Fortune Card
    private func fortuneCard(_ fortune: FortuneData) -> some View {
        VStack(spacing: 24) {
            // Overall Score
            ZStack {
                Circle()
                    .stroke(Color.caobaoPrimary.opacity(0.2), lineWidth: 12)
                    .frame(width: 120, height: 120)
                
                Circle()
                    .trim(from: 0, to: CGFloat(fortune.overall) / 100)
                    .stroke(LinearGradient.caobaoPrimary, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.spring, value: fortune.overall)
                
                VStack {
                    Text("\(fortune.overall)")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.caobaoPrimary)
                    Text("综合运势")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 20)
            
            // Detail Scores Grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                CaobaoScoreItem(title: "爱情", score: fortune.love, icon: "heart.fill", color: .pink)
                CaobaoScoreItem(title: "事业", score: fortune.career, icon: "briefcase.fill", color: .blue)
                CaobaoScoreItem(title: "财运", score: fortune.wealth, icon: "yensign.circle.fill", color: .yellow)
                CaobaoScoreItem(title: "健康", score: fortune.health, icon: "heart.circle.fill", color: .red)
            }
            
            // Message & Advice
            VStack(spacing: 12) {
                Text(fortune.message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.ultraThinMaterial)
                            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                    )
                
                Text(fortune.advice)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.caobaoPrimary.opacity(0.1))
                    )
            }
            
            // Lucky Items
            HStack(spacing: 48) {
                VStack {
                    if let colorHex = fortune.luckyColor, !colorHex.isEmpty {
                        Circle()
                            .fill(Color(hex: colorHex))
                            .frame(width: 50, height: 50)
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    } else {
                        // 降级显示：如果没有颜色，显示默认绿色圆圈
                        Circle()
                            .fill(Color.caobaoPrimary)
                            .frame(width: 50, height: 50)
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    }
                    Text("幸运颜色")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                VStack {
                    Text("\(fortune.luckyNumber ?? 7)")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.caobaoPrimary)
                    Text("幸运数字")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        #if os(macOS)
        .frame(maxWidth: 600)
        #endif
    }
    
    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 60))
                .foregroundStyle(.caobaoPrimary.opacity(0.5))
            
            Text("点击查看今日运势")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Button {
                Task {
                    await loadFortune()
                }
            } label: {
                Text("查看运势")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(LinearGradient.caobaoPrimary)
                    .clipShape(Capsule())
            }
        }
        .padding(.top, 100)
    }
    
    // MARK: - Load Fortune
    private func loadFortune() async {
        isLoading = true
        error = nil
        
        do {
            let response = try await APIService.shared.getFortune(userId: UUID().uuidString)
            if response.success {
                fortune = response.toFortuneData()
                // 调试日志
                print("✅ 运势加载成功")
                print("   综合运势: \(fortune.overall)")
                print("   幸运颜色: \(fortune.luckyColor ?? "无")")
                print("   幸运数字: \(fortune.luckyNumber ?? 0)")
            } else {
                error = response.error ?? "获取运势失败"
                print("❌ 获取运势失败: \(error ?? "")")
            }
        } catch {
            self.error = error.localizedDescription
            print("❌ 网络错误: \(error)")
        }
        
        isLoading = false
    }
}

// MARK: - Score Item
struct CaobaoScoreItem: View {
    let title: String
    let score: Int
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(color)
            
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text("\(score)")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        )
    }
}

#Preview {
    FortuneView()
}
