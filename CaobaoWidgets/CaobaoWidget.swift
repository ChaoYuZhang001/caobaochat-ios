//
//  CaobaoWidget.swift
//  草包Widget
//
//  主Widget入口文件
//

import WidgetKit
import SwiftUI

// MARK: - Widget Provider

/// Widget数据提供者
struct CaobaoProvider: TimelineProvider {
    typealias Entry = CaobaoEntry
    
    func placeholder(in context: Context) -> CaobaoEntry {
        CaobaoEntry(
            date: Date(),
            type: .fortune,
            title: "阳光明媚",
            content: "大吉大利",
            subtitle: "万事如意"
        )
    }
    
    func getSnapshot(in context: Context, completion: @escaping (CaobaoEntry) -> ()) {
        let entry = CaobaoEntry(
            date: Date(),
            type: .fortune,
            title: "阳光明媚",
            content: "大吉大利",
            subtitle: "万事如意"
        )
        completion(entry)
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        // 计算下一个更新时间（每小时更新一次）
        let currentDate = Date()
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: currentDate)!
        
        // 根据时间生成不同的内容
        let hour = Calendar.current.component(.hour, from: currentDate)
        
        let entry: CaobaoEntry
        if hour < 12 {
            // 上午 - 显示晨报
            entry = CaobaoEntry(
                date: currentDate,
                type: .morning,
                title: "早安日报",
                content: "开启元气满满的一天",
                subtitle: "今日宜：努力奋斗"
            )
        } else if hour < 18 {
            // 下午 - 显示运势或金句
            entry = CaobaoEntry(
                date: currentDate,
                type: .fortune,
                title: "阳光明媚",
                content: "运势小吉",
                subtitle: "适合思考，不宜冲动"
            )
        } else {
            // 晚上 - 显示晚报
            entry = CaobaoEntry(
                date: currentDate,
                type: .evening,
                title: "晚安日报",
                content: "总结今日收获",
                subtitle: "明日可期，继续加油"
            )
        }
        
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Widget Entry

/// Widget条目数据
struct CaobaoEntry: TimelineEntry {
    let date: Date
    let type: WidgetType
    let title: String
    let content: String
    let subtitle: String
    
    enum WidgetType {
        case fortune    // 运势
        case quote      // 金句
        case morning    // 晨报
        case evening    // 晚报
    }
}

// MARK: - Widget View

/// Widget视图
struct CaobaoWidgetEntryView: View {
    var entry: CaobaoProvider.Entry
    @Environment(\.widgetFamily) var family
    
    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        @unknown default:
            SmallWidgetView(entry: entry)
        }
    }
}

// MARK: - Small Widget

/// 小尺寸Widget
struct SmallWidgetView: View {
    var entry: CaobaoProvider.Entry
    
    var body: some View {
        VStack(spacing: 12) {
            // Logo
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(Color(hex: "#10B981"))
                )
            
            // 标题
            Text(entry.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            
            // 内容
            Text(entry.content)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            
            Spacer()
            
            // 副标题
            Text(entry.subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding()
        .containerBackground(for: .widget) {
            Color(hex: "#F2F2F7")
        }
    }
}

// MARK: - Medium Widget

/// 中等尺寸Widget
struct MediumWidgetView: View {
    var entry: CaobaoProvider.Entry
    
    var body: some View {
        HStack(spacing: 16) {
            // 左侧图标
            VStack {
                Image(systemName: "sparkles")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(
                        Circle()
                            .fill(Color(hex: "#10B981"))
                    )
                
                Spacer()
            }
            
            // 右侧内容
            VStack(alignment: .leading, spacing: 8) {
                // 标题
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                
                // 内容
                Text(entry.content)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                
                Spacer()
                
                // 副标题和日期
                HStack {
                    Text(entry.subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    
                    Spacer()
                    
                    Text(entry.date, style: .time)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
        .containerBackground(for: .widget) {
            Color(hex: "#F2F2F7")
        }
    }
}

// MARK: - Large Widget

/// 大尺寸Widget
struct LargeWidgetView: View {
    var entry: CaobaoProvider.Entry
    
    var body: some View {
        VStack(spacing: 16) {
            // 顶部栏
            HStack {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(Color(hex: "#10B981"))
                    )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("草包AI")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Text("毒舌但有用的AI助手")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Text(entry.date, style: .time)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            
            Divider()
            
            // 主要内容
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.title)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                
                Text(entry.content)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                
                Spacer()
                
                Text(entry.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(hex: "#10B981").opacity(0.1))
                    )
            }
            
            // 底部快捷操作
            HStack(spacing: 12) {
                WidgetButton(icon: "message.fill", title: "对话")
                WidgetButton(icon: "sparkles", title: "运势")
                WidgetButton(icon: "flame", title: "吐槽")
                Spacer()
            }
        }
        .padding()
        .containerBackground(for: .widget) {
            Color(hex: "#F2F2F7")
        }
    }
}

// MARK: - Widget Button

/// Widget按钮
struct WidgetButton: View {
    let icon: String
    let title: String
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color(hex: "#10B981"))
            
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: "#E8E8ED"))
        )
    }
}

// MARK: - Widget Configuration

/// Widget配置
struct CaobaoWidget: Widget {
    let kind: String = "CaobaoWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CaobaoProvider()) { entry in
            CaobaoWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("草包AI")
        .description("运势、金句、晨报、晚报，毒舌AI助手")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Widget Bundle

@main
struct CaobaoWidgetBundle: WidgetBundle {
    var body: some Widget {
        CaobaoWidget()
        CaobaoFortuneWidget()    // 运势Widget
        CaobaoQuoteWidget()      // 金句Widget
    }
}

// MARK: - 运势Widget

/// 专用运势Widget
struct CaobaoFortuneWidget: Widget {
    let kind: String = "CaobaoFortuneWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CaobaoProvider()) { entry in
            FortuneWidgetView(entry: entry)
        }
        .configurationDisplayName("今日运势")
        .description("查看今日运势")
        .supportedFamilies([.systemSmall])
    }
}

/// 运势Widget视图
struct FortuneWidgetView: View {
    var entry: CaobaoProvider.Entry
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title)
                .foregroundStyle(Color(hex: "#10B981"))
            
            Text("今日运势")
                .font(.headline)
                .foregroundStyle(.primary)
            
            Text(entry.content)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            
            Spacer()
            
            Text(entry.subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color(hex: "#10B981"), Color(hex: "#059669")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .foregroundStyle(.white)
    }
}

// MARK: - 金句Widget

/// 专用金句Widget
struct CaobaoQuoteWidget: Widget {
    let kind: String = "CaobaoQuoteWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CaobaoProvider()) { entry in
            QuoteWidgetView(entry: entry)
        }
        .configurationDisplayName("扎心金句")
        .description("每日扎心金句")
        .supportedFamilies([.systemSmall])
    }
}

/// 金句Widget视图
struct QuoteWidgetView: View {
    var entry: CaobaoProvider.Entry
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "quote.bubble.fill")
                .font(.title)
                .foregroundStyle(Color(hex: "#F59E0B"))
            
            Text("扎心金句")
                .font(.headline)
                .foregroundStyle(.primary)
            
            Text(entry.content)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
            
            Spacer()
            
            Text("— 草包AI")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color(hex: "#F59E0B"), Color(hex: "#D97706")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Preview

#Preview("Small Widget", as: .systemSmall) {
    CaobaoWidget()
} timeline: {
    CaobaoEntry(
        date: Date(),
        type: .fortune,
        title: "今日运势",
        content: "大吉大利",
        subtitle: "万事如意"
    )
}

#Preview("Medium Widget", as: .systemMedium) {
    CaobaoWidget()
} timeline: {
    CaobaoEntry(
        date: Date(),
        type: .morning,
        title: "早安日报",
        content: "开启元气满满的一天",
        subtitle: "今日宜：努力奋斗"
    )
}

#Preview("Large Widget", as: .systemLarge) {
    CaobaoWidget()
} timeline: {
    CaobaoEntry(
        date: Date(),
        type: .evening,
        title: "晚安日报",
        content: "总结今日收获，明日可期",
        subtitle: "继续加油"
    )
}
