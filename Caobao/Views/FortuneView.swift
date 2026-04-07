import SwiftUI


// MARK: - 颜色名称映射
extension Color {
    /// 将中文颜色名称转换为 Hex 颜色代码
    static func fromChineseName(_ name: String) -> Color {
        let colorMap: [String: String] = [
            // 红色系
            "红色": "#FF0000",
            "深红": "#8B0000",
            "朱红": "#FF4D00",
            "樱桃红": "#DE3163",
            "珊瑚红": "#FF7F50",
            "玫瑰红": "#FF007F",
            "粉红": "#FFC0CB",
            "浅粉": "#FFB6C1",
            
            // 橙色系
            "橙色": "#FFA500",
            "深橙": "#FF8C00",
            "橘红": "#FF4500",
            "杏色": "#FFE4B5",
            
            // 黄色系
            "黄色": "#FFFF00",
            "金黄": "#FFD700",
            "柠檬黄": "#FFF44F",
            "米黄": "#F5F5DC",
            "卡其": "#F0E68C",
            
            // 绿色系
            "绿色": "#00FF00",
            "深绿": "#006400",
            "草绿": "#7CFC00",
            "橄榄绿": "#808000",
            "薄荷绿": "#98FB98",
            "墨绿": "#2E8B57",
            "翠绿": "#00FA9A",
            
            // 青色系
            "青色": "#00FFFF",
            "深青": "#008B8B",
            "孔雀蓝": "#00CED1",
            "天青": "#F0FFFF",
            
            // 蓝色系
            "蓝色": "#0000FF",
            "深蓝": "#00008B",
            "天蓝": "#87CEEB",
            "宝蓝": "#4169E1",
            "蔚蓝": "#007FFF",
            "孔雀蓝": "#00BFFF",
            "雾霾蓝": "#7F8C8D",
            "午夜蓝": "#191970",
            "海军蓝": "#000080",
            
            // 紫色系
            "紫色": "#800080",
            "深紫": "#4B0082",
            "薰衣草": "#E6E6FA",
            "紫罗兰": "#EE82EE",
            "紫罗兰色": "#EE82EE",
            
            // 粉色系
            "粉色": "#FFC0CB",
            "深粉": "#FF1493",
            
            // 棕色系
            "棕色": "#A52A2A",
            "浅棕": "#D2691E",
            "咖啡": "#6F4E37",
            
            // 灰色系
            "灰色": "#808080",
            "深灰": "#A9A9A9",
            "浅灰": "#D3D3D3",
            "银灰": "#C0C0C0",
            "雾霾灰": "#A0A0A0",
            
            // 黑白系
            "黑色": "#000000",
            "白色": "#FFFFFF",
            "象牙白": "#FFFFF0",
            "雪白": "#FFFAFA",
            
            // 特色颜色
            "彩虹": "#FF6B6B",  // 使用彩虹的红色
            "金色": "#FFD700",
            "银色": "#C0C0C0",
            "铜色": "#B87333",
        ]
        
        if let hex = colorMap[name] {
            return Color(hex: hex)
        }
        
        // 尝试解析为 Hex 格式
        if name.hasPrefix("#") {
            return Color(hex: name)
        }
        
        // 默认返回绿色
        return Color.caobaoPrimary
    }
}

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
                    if let colorName = fortune.luckyColor, !colorName.isEmpty {
                        Circle()
                            .fill(Color.fromChineseName(colorName))
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
                let tempFortune = response.toFortuneData()
                fortune = tempFortune
                // 调试日志
                print("✅ 运势加载成功")
                print("   综合运势: \(tempFortune.overall)")
                print("   幸运颜色: \(tempFortune.luckyColor ?? "无")")
                print("   幸运数字: \(tempFortune.luckyNumber ?? 0)")
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
