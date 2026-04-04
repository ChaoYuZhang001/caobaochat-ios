import SwiftUI

// MARK: - Features View (功能入口)
// 与 Web 端保持一致的设计风格

struct FeaturesView: View {
    @EnvironmentObject var appState: AppState
    
    // 与 Web 端对齐的功能入口
    private let mainFeatures: [(icon: String, title: String, subtitle: String)] = [
        ("message.fill", "找人聊聊", "随时待命"),
        ("sparkles", "阳光明媚", "算一卦"),
        ("doc.text.magnifyingglass", "图片分析", "扔进来我看看"),
        ("quote.bubble", "扎心金句", "发朋友圈专用"),
    ]

    private let moreFeatures: [(icon: String, title: String, subtitle: String)] = [
        ("chart.line.uptrend.xyaxis", "犀利点评", "来评评理"),
        ("wand.and.stars", "个性昵称", "给你起个名"),
        ("flame", "吐槽大会", "专治各种不服"),
        ("target", "选择困难", "帮你决定"),
    ]
    
    private let quickActions: [(icon: String, title: String, subtitle: String)] = [
        ("sun.max.fill", "早报", "开启元气满满的一天"),
        ("moon.fill", "晚报", "总结今日收获"),
    ]
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 背景色 - 与 Web 端一致
                Color.caobaoGroupedBackground
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // 主功能区
                        VStack(alignment: .leading, spacing: 12) {
                            Text("核心功能")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                            ], spacing: 12) {
                                ForEach(mainFeatures, id: \.title) { feature in
                                    NavigationLink {
                                        destinationView(for: feature.title)
                                    } label: {
                                        CaobaoFeatureCard(
                                            icon: feature.icon,
                                            title: feature.title,
                                            subtitle: feature.subtitle,
                                            color: .featureColor(for: feature.title),
                                            iconSize: 26
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        // 更多功能
                        VStack(alignment: .leading, spacing: 12) {
                            Text("特色功能")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            
                            LazyVGrid(columns: [
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
                                            iconSize: 26
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        // 早晚报
                        VStack(alignment: .leading, spacing: 12) {
                            Text("每日报告")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            
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
                    }
                    .padding()
                }
            }
            .navigationTitle("更多功能")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
    
    // MARK: - Helper
    @ViewBuilder
    private func destinationView(for title: String) -> some View {
        switch title {
        case "找人聊聊": ChatView()
        case "阳光明媚": FortuneView()
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
}

#Preview {
    FeaturesView()
        .environmentObject(AppState())
}
