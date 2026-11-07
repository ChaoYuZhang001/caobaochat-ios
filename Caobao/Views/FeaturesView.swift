import SwiftUI

// MARK: - Features View (功能入口)
// 与 Web 端保持一致的设计风格

struct FeaturesView: View {
    @EnvironmentObject var appState: AppState
    @State private var unavailableToolTitle = ""
    @State private var showingUnavailableTool = false
    
    // 旧工具只在“更多功能”二级入口保留；核心工作流在首页、对话和任务中完成。
    private let mainFeatures: [(icon: String, title: String, subtitle: String)] = [
        ("message.fill", "找人聊聊", "进入对话工作区"),
    ]

    private let moreFeatures: [(icon: String, title: String, subtitle: String)] = [
        ("chart.line.uptrend.xyaxis", "犀利点评", "二级工具 · 接口待迁移"),
        ("wand.and.stars", "个性昵称", "二级工具 · 接口待迁移"),
        ("flame", "吐槽大会", "二级工具 · 接口待迁移"),
        ("target", "选择困难", "二级工具 · 接口待迁移"),
    ]
    
    private let quickActions: [(icon: String, title: String, subtitle: String)] = [
        ("sun.max.fill", "早报", "二级工具 · 接口待迁移"),
        ("moon.fill", "晚报", "二级工具 · 接口待迁移"),
    ]
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 渐变背景 - 多彩渐变（代表丰富功能）
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(hex: "8b5cf6").opacity(0.08),
                        Color(hex: "a855f7").opacity(0.05),
                        Color.caobaoGroupedBackground
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("工具模板")
                                .font(.title3.bold())
                            Text("这里是二级能力入口，不占用首页、对话和任务的核心导航。部分旧工具仍等待服务端 v2 接口迁移，遇到不可用提示时请使用对话工作区。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // 主功能区
                        VStack(alignment: .leading, spacing: 12) {
                            Text("对话工具")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                            ], spacing: 12) {
                                ForEach(mainFeatures, id: \.title) { feature in
                                    NavigationLink {
                                        destinationView(for: feature.title).assistantSidebarChild()
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
                                    Button { showUnavailableTool(feature.title) } label: {
                                        CaobaoFeatureCard(
                                            icon: feature.icon,
                                            title: feature.title,
                                            subtitle: feature.subtitle,
                                            color: .featureColor(for: feature.title),
                                            iconSize: 26
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("服务端接口待迁移")
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
                                    Button { showUnavailableTool(action.title) } label: {
                                        CaobaoQuickActionRow(
                                            icon: action.icon,
                                            title: action.title,
                                            subtitle: action.subtitle,
                                            color: .featureColor(for: action.title)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("服务端接口待迁移")
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("更多功能")
            .assistantSidebarRoot()
            .alert("功能暂未启用", isPresented: $showingUnavailableTool) {
                Button("知道了", role: .cancel) { }
            } message: {
                Text(verbatim: "\(unavailableToolTitle) 当前调用的旧接口尚未在生产服务端提供，请使用对话工作区。")
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
    
    // MARK: - Helper
    private func showUnavailableTool(_ title: String) {
        unavailableToolTitle = title
        showingUnavailableTool = true
    }

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
