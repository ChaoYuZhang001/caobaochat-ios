import SwiftUI

// MARK: - Home View (首页概览)
// 与 Web 端保持一致的设计风格

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var fortune: FortuneData?
    @State private var loading = false
    
    // 与 Web 端对齐的快捷功能
    private let mainFeatures: [(icon: String, title: String, subtitle: String)] = [
        ("message.fill", "找人聊聊", "随时待命"),
        ("sun.max.fill", "阳光明媚", "算一卦"),
        ("doc.text.magnifyingglass", "图片分析", "扔进来我看看"),
        ("quote.bubble", "扎心金句", "发朋友圈专用"),
    ]

    private let moreFeatures: [(icon: String, title: String, subtitle: String)] = [
        ("flame", "吐槽大会", "专治各种不服"),
        ("wand.and.stars", "个性昵称", "给你起个名"),
        ("chart.line.uptrend.xyaxis", "犀利点评", "来评评理"),
        ("target", "选择困难", "帮你决定"),
    ]
    
    private let quickActions: [(icon: String, title: String, subtitle: String)] = [
        ("sun.max.fill", "早报", "开启元气满满的一天"),
        ("moon.fill", "晚报", "总结今日收获"),
    ]
    
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "早上好"
        case 12..<14: return "中午好"
        case 14..<18: return "下午好"
        case 18..<22: return "晚上好"
        default: return "夜深了"
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 背景色 - 与 Web 端一致
                Color.caobaoGroupedBackground
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Hero 区域
                        CaobaoHeroSection(
                            greeting: greeting,
                            nickname: appState.userSettings.nickname
                        )
                        
                        // 今日运势摘要
                        if let fortune = fortune {
                            CaobaoFortuneCard(fortune: fortune)
                        }
                        
                        // 主功能入口 - 4列网格
                        VStack(alignment: .leading, spacing: 12) {
                            Text("核心功能")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                            ], spacing: 12) {
                                ForEach(mainFeatures, id: \.title) { feature in
                                    if feature.title == "找人聊聊" {
                                        // 找人聊聊 - 切换 TabBar
                                        Button(action: {
                                            withAnimation {
                                                appState.selectedTab = .chat
                                            }
                                        }) {
                                            CaobaoFeatureCard(
                                                icon: feature.icon,
                                                title: feature.title,
                                                subtitle: feature.subtitle,
                                                color: .featureColor(for: feature.title),
                                                iconSize: 22
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        NavigationLink {
                                            destinationView(for: feature.title)
                                        } label: {
                                            CaobaoFeatureCard(
                                                icon: feature.icon,
                                                title: feature.title,
                                                subtitle: feature.subtitle,
                                                color: .featureColor(for: feature.title),
                                                iconSize: 22
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        
                        // 早晚报入口
                        VStack(alignment: .leading, spacing: 12) {
                            Text("每日报告")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            
                            VStack(spacing: 10) {
                                ForEach(quickActions, id: \.title) { action in
                                    NavigationLink {
                                        destinationView(for: action.title)
                                    } label: {
                                        CaobaoQuickActionRow(
                                            icon: action.icon,
                                            title: action.title,
                                            subtitle: action.subtitle,
                                            color: .featureColor(for: action.title)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        // 更多功能 - 4列网格
                        VStack(alignment: .leading, spacing: 12) {
                            Text("特色功能")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                            ], spacing: 12) {
                                ForEach(moreFeatures, id: \.title) { feature in
                                    NavigationLink {
                                        destinationView(for: feature.title)
                                    } label: {
                                        CaobaoFeatureCard(
                                            icon: feature.icon,
                                            title: feature.title,
                                            subtitle: feature.subtitle,
                                            color: .featureColor(for: feature.title),
                                            iconSize: 22
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        // 使用统计
                        VStack(alignment: .leading, spacing: 12) {
                            Text("使用统计")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            
                            HStack(spacing: 12) {
                                CaobaoStatCard(title: "对话次数", value: "\(appState.userStats.totalChats)", icon: "message.fill", color: .caobaoPrimary)
                                CaobaoStatCard(title: "使用天数", value: "\(appState.userStats.usageDays)", icon: "calendar", color: .blue)
                                CaobaoStatCard(title: "连续打卡", value: "\(appState.userStats.streak)天", icon: "flame.fill", color: .orange)
                            }
                        }
                        
                        // 快捷入口
                        VStack(spacing: 10) {
                            NavigationLink {
                                HistoryView()
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "clock.fill")
                                        .font(.title3)
                                        .foregroundStyle(.purple)
                                        .frame(width: 42, height: 42)
                                        .background(
                                            Circle()
                                                .fill(Color.purple.opacity(0.15))
                                        )
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("历史记录")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.primary)
                                        
                                        Text("查看所有对话记录")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(.ultraThinMaterial)
                                        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                                )
                            }
                            .buttonStyle(.plain)
                            
                            NavigationLink {
                                ProfileView()
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "person.fill")
                                        .font(.title3)
                                        .foregroundStyle(.blue)
                                        .frame(width: 42, height: 42)
                                        .background(
                                            Circle()
                                                .fill(Color.blue.opacity(0.15))
                                        )
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("个人中心")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.primary)
                                        
                                        Text("管理你的账户信息")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(.ultraThinMaterial)
                                        .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image("Logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        
                        Text("草包")
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundStyle(.primary)
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        ProfileView()
                    } label: {
                        Image(systemName: "person.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.caobaoPrimary)
                    }
                }
            }
        }
        .onAppear {
            // 只在没有运势数据时加载，且设置超时保护
            if fortune == nil {
                loadFortuneWithTimeout()
            }
        }
    }
    
    // MARK: - Helper
    private func loadFortuneWithTimeout() {
        loading = true
        Task {
            do {
                let response = try await APIService.shared.getFortune(userId: appState.user?.id ?? "guest")
                await MainActor.run {
                    if response.success {
                        fortune = response.toFortuneData()
                    }
                    loading = false
                }
            } catch {
                await MainActor.run {
                    // 加载失败不阻塞
                    loading = false
                    print("运势加载失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    @ViewBuilder
    private func destinationView(for title: String) -> some View {
        switch title {
        case "找人聊聊":
            // 不使用 NavigationLink，而是切换 TabBar
            EmptyView()
        case "阳光明媚": FortuneView()
        case "今日运势": FortuneView()
        case "图片分析": AnalyzeView()
        case "扎心金句": QuoteView()
        case "吐槽大会": RoastView()
        case "个性昵称": NicknameView()
        case "犀利点评": RateView()
        case "选择困难": DecisionView()
        case "早报": MorningReportView()
        case "晚报": EveningReportView()
        default: Text("功能开发中")
        }
    }
    
    // 处理功能点击
    private func handleFeatureTap(for title: String) {
        switch title {
        case "找人聊聊":
            // 切换到对话 Tab
            appState.selectedTab = .chat
        default:
            break
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
}
