//
//  StatsView.swift
//  Caobao
//
//  数据统计页面
//

import SwiftUI

struct StatsData {
    var totalMessages: Int = 0
    var userMessages: Int = 0
    var aiMessages: Int = 0
    var usageDays: Int = 1
    var todayMessages: Int = 0
    var weekMessages: Int = 0
    var monthMessages: Int = 0
    var avgMessagesPerDay: Int = 0
    var longestStreak: Int = 1
    var currentStreak: Int = 1
}

struct AchievementBadge {
    let name: String
    let desc: String
    let unlocked: Bool
    let icon: String
}

struct StatsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var stats = StatsData()
    @State private var isLoading = true
    
    private var achievementBadges: [AchievementBadge] {
        [
            AchievementBadge(name: "初次见面", desc: "第一次使用草包", unlocked: stats.usageDays >= 1, icon: "👋"),
            AchievementBadge(name: "话痨", desc: "累计发送100条消息", unlocked: stats.userMessages >= 100, icon: "💬"),
            AchievementBadge(name: "坚持者", desc: "连续使用7天", unlocked: stats.currentStreak >= 7, icon: "🔥"),
            AchievementBadge(name: "老用户", desc: "使用超过30天", unlocked: stats.usageDays >= 30, icon: "⭐")
        ]
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 总览卡片
                    overviewCard
                    
                    // 时间段统计
                    timeStatsCard
                    
                    // 对话详情
                    messageDetailsCard
                    
                    // 成就徽章
                    achievementsCard
                    
                    // 使用建议
                    suggestionsCard
                }
                .padding()
            }
            .background(Color.caobaoGroupedBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("数据统计")
                        .font(.headline)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("返回") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadStats()
            }
        }
    }
    
    private var overviewCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(stats.userMessages)")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("累计发送消息")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }
                
                Spacer()
            }
            
            Divider()
                .background(Color.white.opacity(0.3))
            
            HStack(spacing: 0) {
                statItem(value: "\(stats.usageDays)", label: "使用天数")
                Divider()
                    .frame(height: 40)
                    .background(Color.white.opacity(0.3))
                statItem(value: "\(stats.currentStreak)", label: "连续天数")
                Divider()
                    .frame(height: 40)
                    .background(Color.white.opacity(0.3))
                statItem(value: "\(stats.avgMessagesPerDay)", label: "日均消息")
            }
        }
        .padding()
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.green, Color.green.opacity(0.8)]),
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .cornerRadius(16)
        .shadow(color: Color.green.opacity(0.3), radius: 8, x: 0, y: 4)
    }
    
    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            Text(label)
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
    }
    
    private var timeStatsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(.green)
                Text("时间段统计")
                    .font(.headline)
            }
            
            VStack(spacing: 16) {
                progressBar(label: "今日消息", value: stats.todayMessages, max: 50)
                progressBar(label: "本周消息", value: stats.weekMessages, max: 200)
                progressBar(label: "本月消息", value: stats.monthMessages, max: 500)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 4)
    }
    
    private func progressBar(label: String, value: Int, max: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(value) 条")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray5))
                        .frame(height: 8)
                    
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.green)
                        .frame(width: min(CGFloat(value) / CGFloat(max), 1) * geometry.size.width, height: 8)
                }
            }
            .frame(height: 8)
        }
    }
    
    private var messageDetailsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundColor(.green)
                Text("对话详情")
                    .font(.headline)
            }
            
            HStack(spacing: 16) {
                detailItem(value: stats.userMessages, label: "我的消息", color: .green)
                detailItem(value: stats.aiMessages, label: "AI回复", color: .blue)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 4)
    }
    
    private func detailItem(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Text("\(value)")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    private var achievementsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "trophy")
                    .foregroundColor(.yellow)
                Text("成就徽章")
                    .font(.headline)
            }
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(achievementBadges, id: \.name) { badge in
                    VStack(spacing: 8) {
                        Text(badge.icon)
                            .font(.title)
                        
                        Text(badge.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(badge.unlocked ? .primary : .secondary)
                        
                        Text(badge.desc)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(badge.unlocked ? Color.yellow.opacity(0.1) : Color(.systemGray6))
                    .cornerRadius(12)
                    .opacity(badge.unlocked ? 1 : 0.5)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 4)
    }
    
    private var suggestionsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "target")
                    .foregroundColor(.green)
                Text("使用建议")
                    .font(.headline)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                suggestionRow(
                    icon: "bolt",
                    color: .yellow,
                    text: stats.avgMessagesPerDay < 5
                        ? "多和草包聊聊，每天至少5条消息才能有效提升哦！"
                        : "继续保持！你的使用频率很棒！"
                )
                
                suggestionRow(
                    icon: "chart.line.uptrend.xyaxis",
                    color: .green,
                    text: stats.currentStreak < 7
                        ? "尝试连续使用7天，解锁\"坚持者\"成就！"
                        : "你已经养成了使用草包的好习惯！"
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 4)
    }
    
    private func suggestionRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    private func loadStats() {
        let defaults = UserDefaults.standard
        
        // 从 UserDefaults 加载统计数据
        let totalMessages = defaults.integer(forKey: "caobao_total_messages")
        let userMessages = defaults.integer(forKey: "caobao_user_messages")
        
        // 计算使用天数
        var usageDays = 1
        if let firstVisit = defaults.object(forKey: "caobao_first_visit") as? Date {
            usageDays = Calendar.current.dateComponents([.day], from: firstVisit, to: Date()).day ?? 1 + 1
        }
        
        // 获取今日消息数
        let todayMessages = defaults.integer(forKey: "caobao_today_messages")
        let weekMessages = defaults.integer(forKey: "caobao_week_messages")
        let monthMessages = defaults.integer(forKey: "caobao_month_messages")
        
        stats = StatsData(
            totalMessages: totalMessages,
            userMessages: userMessages,
            aiMessages: totalMessages - userMessages,
            usageDays: usageDays,
            todayMessages: todayMessages,
            weekMessages: weekMessages,
            monthMessages: monthMessages,
            avgMessagesPerDay: usageDays > 0 ? userMessages / usageDays : 0,
            longestStreak: usageDays,
            currentStreak: usageDays
        )
        
        isLoading = false
    }
}

#Preview {
    StatsView()
}
