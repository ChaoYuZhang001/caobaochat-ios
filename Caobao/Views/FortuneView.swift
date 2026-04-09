import SwiftUI

// MARK: - 颜色名称映射
extension Color {
    /// 将中文颜色名称转换为 Hex 颜色代码
    static func fromChineseName(_ name: String) -> Color {
        let colorMap: [String: String] = [
            // 红色系
            "红色": "#EF4444",
            "深红": "#DC2626",
            "朱红": "#FF4D00",
            "樱桃红": "#DE3163",
            "珊瑚红": "#FF7F50",
            "玫瑰红": "#E11D48",
            "粉红": "#EC4899",
            "浅粉": "#FBCFE8",
            
            // 橙色系
            "橙色": "#F97316",
            "深橙": "#EA580C",
            "橘红": "#FF4500",
            "杏色": "#FFCDB2",
            
            // 黄色系
            "黄色": "#EAB308",
            "金黄": "#F59E0B",
            "金色": "#F59E0B",
            "柠檬黄": "#FDE047",
            "米黄": "#FEF3C7",
            "卡其": "#D4A574",
            
            // 绿色系
            "绿色": "#22C55E",
            "深绿": "#16A34A",
            "草绿": "#84CC16",
            "橄榄绿": "#65A30D",
            "薄荷绿": "#6EE7B7",
            "墨绿": "#166534",
            "翠绿": "#10B981",
            
            // 青色系
            "青色": "#06B6D4",
            "深青": "#0891B2",
            "天青": "#38BDF8",
            
            // 蓝色系
            "蓝色": "#3B82F6",
            "深蓝": "#2563EB",
            "天蓝": "#38BDF8",
            "宝蓝": "#2563EB",
            "蔚蓝": "#0EA5E9",
            "孔雀蓝": "#06B6D4",
            "雾霾蓝": "#6B7280",
            "午夜蓝": "#1E3A8A",
            "海军蓝": "#1E40AF",
            
            // 紫色系
            "紫色": "#A855F7",
            "深紫": "#9333EA",
            "薰衣草": "#C4B5FD",
            "紫罗兰": "#A78BFA",
            "紫罗兰色": "#A78BFA",
            
            // 粉色系
            "粉色": "#EC4899",
            "深粉": "#DB2777",
            
            // 棕色系
            "棕色": "#A16207",
            "浅棕": "#D97706",
            "咖啡": "#78350F",
            
            // 灰色系
            "灰色": "#6B7280",
            "深灰": "#4B5563",
            "浅灰": "#9CA3AF",
            "银灰": "#D1D5DB",
            "雾霾灰": "#6B7280",
            
            // 黑白系
            "黑色": "#1F2937",
            "白色": "#F8FAFC",
            "象牙白": "#FFFBEB",
            "雪白": "#F8FAFC",
            
            // 特色颜色
            "彩虹": "#FF6B6B",
            "银色": "#C0C0C0",
            "铜色": "#B87333",
            "五彩斑斓的黑": "#1F2937",
        ]
        
        // 模糊匹配
        let lowerName = name.lowercased()
        for (key, hex) in colorMap {
            if lowerName.contains(key.lowercased()) || key.lowercased().contains(lowerName) {
                return Color(hex: hex)
            }
        }
        
        // 关键词匹配
        if lowerName.contains("红") { return Color(hex: "#EF4444") }
        if lowerName.contains("橙") || lowerName.contains("橘") { return Color(hex: "#F97316") }
        if lowerName.contains("黄") || lowerName.contains("金") { return Color(hex: "#EAB308") }
        if lowerName.contains("绿") { return Color(hex: "#22C55E") }
        if lowerName.contains("青") || lowerName.contains("蓝") { return Color(hex: "#3B82F6") }
        if lowerName.contains("紫") { return Color(hex: "#A855F7") }
        if lowerName.contains("粉") || lowerName.contains("玫") { return Color(hex: "#EC4899") }
        if lowerName.contains("白") { return Color(hex: "#F8FAFC") }
        if lowerName.contains("黑") { return Color(hex: "#1F2937") }
        if lowerName.contains("灰") { return Color(hex: "#6B7280") }
        if lowerName.contains("棕") || lowerName.contains("咖") { return Color(hex: "#A16207") }
        
        // 默认返回绿色
        return Color.caobaoPrimary
    }
}

// MARK: - 运势类型
enum FortuneType: String, CaseIterable, Identifiable {
    case general = "general"
    case love = "love"
    case work = "work"
    case wealth = "wealth"
    
    var id: String { rawValue }
    
    var name: String {
        switch self {
        case .general: return "综合运势"
        case .love: return "感情运势"
        case .work: return "事业运势"
        case .wealth: return "财富运势"
        }
    }
    
    var icon: String {
        switch self {
        case .general: return "sparkles"
        case .love: return "heart.fill"
        case .work: return "briefcase.fill"
        case .wealth: return "dollarsign.circle.fill"
        }
    }
}

// MARK: - Fortune View (今日运势)
// 与 H5 Web 端保持一致的设计风格
struct FortuneView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var fortune: FortuneData?
    @State private var isLoading = false
    @State private var error: String?
    @State private var selectedFortuneType: FortuneType = .general
    @State private var name: String = ""
    @State private var birthday: String = ""
    @State private var question: String = ""
    
    var body: some View {
        NavigationStack {
            ZStack {
                // H5 风格渐变背景
                LinearGradient(
                    colors: [Color.purple.opacity(0.1), Color.blue.opacity(0.05), Color.white],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        if let fortune = fortune {
                            fortuneCard(fortune)
                        } else if isLoading {
                            loadingView
                        } else {
                            inputView
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    if fortune != nil {
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
        }
    }
    
    // MARK: - 输入界面
    private var inputView: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 50))
                    .foregroundStyle(.caobaoPrimary)
                
                Text("算一卦")
                    .font(.title.bold())
                
                Text("犀利毒舌风格，信不信由你")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 40)
            
            // 一键随机按钮
            Button {
                Task {
                    await loadFortune()
                }
            } label: {
                HStack {
                    Image(systemName: "shuffle")
                    Text("一键随机算卦")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    LinearGradient(
                        colors: [.purple, .blue, .pink],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.vertical)
            
            Text("不填信息？直接算！缘分到了自然准")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            // 可选输入区域
            VStack(alignment: .leading, spacing: 12) {
                Text("详细信息（可选）")
                    .font(.headline)
                
                // 运势类型选择
                VStack(alignment: .leading, spacing: 8) {
                    Text("想算什么")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(FortuneType.allCases) { type in
                                Button {
                                    selectedFortuneType = type
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: type.icon)
                                        Text(type.name)
                                    }
                                    .font(.subheadline)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(
                                        selectedFortuneType == type 
                                            ? Color.caobaoPrimary 
                                            : Color.gray.opacity(0.1)
                                    )
                                    .foregroundStyle(selectedFortuneType == type ? .white : .primary)
                                    .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                
                // 名字
                VStack(alignment: .leading, spacing: 4) {
                    Text("名字")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("你的名字", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                
                // 生日
                VStack(alignment: .leading, spacing: 4) {
                    Text("生日")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("YYYY-MM-DD", text: $birthday)
                        .textFieldStyle(.roundedBorder)
                }
                
                // 详细算卦按钮
                Button {
                    Task {
                        await loadFortune()
                    }
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        Text("详细算卦")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.caobaoPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding()
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
        }
    }
    
    // MARK: - 加载中视图
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("摇卦中...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 150)
    }
    
    // MARK: - 运势结果卡片
    private func fortuneCard(_ fortune: FortuneData) -> some View {
        VStack(spacing: 16) {
            // 综合运势大卡片
            VStack(spacing: 12) {
                // 渐变背景头部
                ZStack {
                    // 渐变背景
                    LinearGradient(
                        colors: getScoreColors(fortune.overall),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    
                    VStack(spacing: 8) {
                        Text("\(fortune.overall)")
                            .font(.system(size: 72, weight: .black))
                            .foregroundStyle(.white)
                        
                        Text("综合运势")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.9))
                        
                        if let date = fortune.date {
                            Text(date)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .padding(.vertical, 30)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                
                // 毒舌评语
                if let comment = fortune.overallComment, !comment.isEmpty {
                    Text(comment)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                        .padding(.horizontal)
                }
            }
            
            // 分项运势卡片
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                FortuneAspectCard(
                    title: "爱情",
                    aspect: fortune.aspects?.love,
                    icon: "heart.fill",
                    color: .pink
                )
                FortuneAspectCard(
                    title: "事业",
                    aspect: fortune.aspects?.work,
                    icon: "briefcase.fill",
                    color: .blue
                )
                FortuneAspectCard(
                    title: "财运",
                    aspect: fortune.aspects?.wealth,
                    icon: "dollarsign.circle.fill",
                    color: .yellow
                )
                FortuneAspectCard(
                    title: "健康",
                    aspect: fortune.aspects?.health,
                    icon: "heart.circle.fill",
                    color: .green
                )
            }
            
            // 幸运物品
            if let luckyItem = fortune.luckyItem, !luckyItem.isEmpty {
                HStack {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                    Text("幸运物品：\(luckyItem)")
                        .font(.subheadline)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.yellow.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            // 幸运颜色和数字
            HStack(spacing: 40) {
                // 幸运颜色
                VStack(spacing: 8) {
                    if let colorName = fortune.luckyColor, !colorName.isEmpty {
                        Circle()
                            .fill(Color.fromChineseName(colorName))
                            .frame(width: 50, height: 50)
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    } else {
                        Circle()
                            .fill(Color.caobaoPrimary)
                            .frame(width: 50, height: 50)
                    }
                    Text("幸运颜色")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // 幸运数字
                VStack(spacing: 8) {
                    Text("\(fortune.luckyNumber ?? 7)")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.caobaoPrimary)
                    Text("幸运数字")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            
            // 今日警示
            if let warning = fortune.warning, !warning.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.title2)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("今日警示")
                            .font(.subheadline.bold())
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            // 毒舌建议
            if let suggestion = fortune.suggestion, !suggestion.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.caobaoPrimary)
                        .font(.title2)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("毒舌建议")
                            .font(.subheadline.bold())
                            .foregroundStyle(.caobaoPrimary)
                        Text(suggestion)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.caobaoPrimary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            // 操作按钮
            HStack(spacing: 16) {
                Button {
                    resetFortune()
                } label: {
                    HStack {
                        Image(systemName: "arrow.uturn.left")
                        Text("重新算")
                    }
                    .font(.headline)
                    .foregroundStyle(.caobaoPrimary)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.caobaoPrimary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                
                Button {
                    shareFortune(fortune)
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("分享")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.caobaoPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
    
    // MARK: - 获取分数对应颜色
    private func getScoreColors(_ score: Int) -> [Color] {
        if score >= 80 {
            return [.green, Color(hex: "#10B981")]  // emerald -> 翠绿
        } else if score >= 60 {
            return [.yellow, .orange]
        } else {
            return [.red, .pink]
        }
    }
    
    // MARK: - 重置运势
    private func resetFortune() {
        fortune = nil
    }
    
    // MARK: - 加载运势
    private func loadFortune() async {
        isLoading = true
        error = nil
        
        do {
            let response = try await APIService.shared.getFortuneWithParams(
                fortuneType: selectedFortuneType.rawValue,
                name: name.isEmpty ? nil : name,
                birthday: birthday.isEmpty ? nil : birthday,
                question: question.isEmpty ? nil : question
            )
            
            if response.success {
                fortune = response.toFortuneData()
                print("✅ 运势加载成功")
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
    
    // MARK: - 分享运势
    private func shareFortune(_ fortune: FortuneData) {
        var shareText = "【今日卦象】\(fortune.date ?? "")\n\n"
        shareText += "综合运势：\(fortune.overall)分\n"
        
        if let comment = fortune.overallComment {
            shareText += "\(comment)\n"
        }
        
        if let luckyItem = fortune.luckyItem, !luckyItem.isEmpty {
            shareText += "\n🍀 幸运物品：\(luckyItem)"
        }
        
        if let luckyColor = fortune.luckyColor, !luckyColor.isEmpty {
            shareText += "\n🎨 幸运颜色：\(luckyColor)"
        }
        
        if let luckyNumber = fortune.luckyNumber {
            shareText += "\n🔢 幸运数字：\(luckyNumber)"
        }
        
        if let warning = fortune.warning, !warning.isEmpty {
            shareText += "\n\n⚠️ 今日警示：\(warning)"
        }
        
        if let suggestion = fortune.suggestion, !suggestion.isEmpty {
            shareText += "\n💡 毒舌建议：\(suggestion)"
        }
        
        shareText += "\n\n—— 草包算卦，信不信由你"
        
        // 调用系统分享
        let activityVC = UIActivityViewController(
            activityItems: [shareText],
            applicationActivities: nil
        )
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }
}

// MARK: - 运势分项卡片
struct FortuneAspectCard: View {
    let title: String
    let aspect: FortuneAspect?
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Text("\(aspect?.score ?? 50)")
                .font(.title.bold())
                .foregroundStyle(.primary)
            
            if let comment = aspect?.comment, !comment.isEmpty {
                Text(comment)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    FortuneView()
}
