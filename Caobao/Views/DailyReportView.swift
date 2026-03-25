import SwiftUI

// MARK: - Daily Report View (每日报告)
// 与 Web 端保持一致的设计风格

struct DailyReportView: View {
    @State private var selectedTab = 0 // 0: 早安, 1: 晚安
    @State private var morningReport: MorningReportResponse.MorningReport?
    @State private var eveningReport: EveningReportResponse.EveningReport?
    @State private var loading = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 背景色
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // 切换标签 - 使用渐变背景
                    HStack(spacing: 0) {
                        Button {
                            selectedTab = 0
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "sun.max.fill")
                                    .font(.title2)
                                Text("早安报告")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(selectedTab == 0 ? LinearGradient.caobaoFortune : nil)
                            .foregroundStyle(selectedTab == 0 ? .white : .secondary)
                        }
                        
                        Button {
                            selectedTab = 1
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "moon.fill")
                                    .font(.title2)
                                Text("晚安报告")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(selectedTab == 1 ? LinearGradient.caobaoEvening : nil)
                            .foregroundStyle(selectedTab == 1 ? .white : .secondary)
                        }
                    }
                    .background(Color(.systemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding()
                    
                    // 内容
                    ScrollView {
                        VStack(spacing: 20) {
                            if selectedTab == 0 {
                                if let report = morningReport {
                                    MorningReportCard(report: report, onRefresh: loadMorningReport)
                                } else if loading {
                                    ProgressView()
                                        .padding(.top, 100)
                                } else {
                                    EmptyReportView(type: "早安") {
                                        loadMorningReport()
                                    }
                                }
                            } else {
                                if let report = eveningReport {
                                    EveningReportCard(report: report, onRefresh: loadEveningReport)
                                } else if loading {
                                    ProgressView()
                                        .padding(.top, 100)
                                } else {
                                    EmptyReportView(type: "晚安") {
                                        loadEveningReport()
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("每日报告")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if selectedTab == 0 {
                            loadMorningReport()
                        } else {
                            loadEveningReport()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.caobaoPrimary)
                    }
                }
            }
        }
    }
    
    // MARK: - Actions
    private func loadMorningReport() {
        loading = true
        Task {
            do {
                let response = try await APIService.shared.getMorningReport()
                await MainActor.run {
                    if response.success {
                        morningReport = response.data
                    }
                    loading = false
                }
            } catch {
                await MainActor.run {
                    loading = false
                }
            }
        }
    }
    
    private func loadEveningReport() {
        loading = true
        Task {
            do {
                let response = try await APIService.shared.getEveningReport()
                await MainActor.run {
                    if response.success {
                        eveningReport = response.data
                    }
                    loading = false
                }
            } catch {
                await MainActor.run {
                    loading = false
                }
            }
        }
    }
}

// MARK: - Morning Report Card
struct MorningReportCard: View {
    let report: MorningReportResponse.MorningReport
    let onRefresh: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            // 问候语
            VStack(spacing: 12) {
                Text("☀️")
                    .font(.system(size: 48))
                Text(report.greeting ?? "早安")
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                Text(report.date ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical)
            
            // 运势
            if let fortune = report.fortune {
                VStack(spacing: 8) {
                    HStack {
                        Text("今日运势")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Spacer()
                        HStack(spacing: 2) {
                            ForEach(0..<5) { i in
                                Image(systemName: i < fortune.stars ? "star.fill" : "star")
                                    .foregroundStyle(i < fortune.stars ? .yellow : .white.opacity(0.3))
                            }
                        }
                    }
                    if let comment = fortune.comment, !comment.isEmpty {
                        Text(comment)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient.caobaoFortune)
                        .shadow(color: .orange.opacity(0.3), radius: 8, y: 4)
                )
            }
            
            // 健康
            CaobaoInfoRow(title: "健康建议", content: report.health, icon: "heart.fill", color: .red)
            
            // 今日行动
            CaobaoInfoRow(title: "今日行动", content: report.action, icon: "bolt.fill", color: .caobaoPrimary)
            
            // 草包毒舌
            CaobaoInfoRow(title: "草包毒舌", content: report.caobaoSays, icon: "flame.fill", color: .purple)
            
            // 每日金句
            if let quote = report.quote, !quote.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "quote.opening")
                        .foregroundStyle(.caobaoPrimary.opacity(0.5))
                    Text(quote)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.caobaoPrimary.opacity(0.1))
                )
            }
            
            // 冷知识
            CaobaoInfoRow(title: "冷知识", content: report.funFact, icon: "lightbulb.fill", color: .yellow)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        )
    }
}

// MARK: - Evening Report Card
struct EveningReportCard: View {
    let report: EveningReportResponse.EveningReport
    let onRefresh: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            // 问候语
            VStack(spacing: 12) {
                Text("🌙")
                    .font(.system(size: 48))
                Text(report.greeting ?? "晚安")
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                Text(report.date ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical)
            
            // 今日总结
            CaobaoInfoRow(title: "今日总结", content: report.review, icon: "checkmark.circle.fill", color: .caobaoPrimary)
            
            // 明日计划 (数组类型)
            CaobaoInfoRowList(title: "明日计划", items: report.tomorrowPlan, icon: "calendar", color: .blue)
            
            // 草包毒舌
            CaobaoInfoRow(title: "睡前毒舌", content: report.caobaoSays, icon: "flame.fill", color: .purple)
            
            // 每日金句
            if let quote = report.quote, !quote.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "quote.opening")
                        .foregroundStyle(.purple.opacity(0.5))
                    Text(quote)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.purple.opacity(0.1))
                )
            }
            
            // 睡眠建议
            CaobaoInfoRow(title: "睡眠建议", content: report.sleepTip, icon: "moon.zzz.fill", color: .indigo)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        )
    }
}

// MARK: - Info Row (字符串类型)
struct CaobaoInfoRow: View {
    let title: String
    let content: String?
    let icon: String
    let color: Color
    
    var body: some View {
        if let content = content, !content.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
                
                Text(content)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.03), radius: 3, y: 2)
            )
        }
    }
}

// MARK: - Info Row List (数组类型)
struct CaobaoInfoRowList: View {
    let title: String
    let items: [String]?
    let icon: String
    let color: Color
    
    var body: some View {
        if let items = items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
                
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(color)
                        Text(item)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.03), radius: 3, y: 2)
            )
        }
    }
}

// MARK: - Empty Report View
struct EmptyReportView: View {
    let type: String
    let action: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: type == "早安" ? "sun.max" : "moon.stars")
                .font(.system(size: 60))
                .foregroundStyle(type == "早安" ? Color.orange : Color.purple)
            
            Text("还没有\(type)报告")
                .font(.headline)
            
            Button(action: action) {
                Text("生成\(type)报告")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(type == "早安" ? LinearGradient.caobaoFortune : LinearGradient.caobaoEvening)
                    .clipShape(Capsule())
            }
        }
        .padding()
        .padding(.top, 50)
    }
}

#Preview {
    DailyReportView()
}
