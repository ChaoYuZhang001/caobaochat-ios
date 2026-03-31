import SwiftUI

// MARK: - 草包设计系统
// 与 Web 端保持一致的设计风格

// MARK: - 颜色系统
public extension Color {
    // 主色 - 绿色系
    static let caobaoPrimary = Color(hex: "22C55E") // green-500
    static let caobaoPrimaryDark = Color(hex: "16A34A") // green-600
    static let caobaoPrimaryLight = Color(hex: "4ADE80") // green-400
    
    // 强调色 - 青绿色系
    static let caobaoAccent = Color(hex: "10B981") // emerald-500
    static let caobaoAccentLight = Color(hex: "34D399") // emerald-400
    
    // 背景色
    static let caobaoBackground = Color(hex: "F8FAFC") // slate-50
    static let caobaoBackgroundDark = Color(hex: "020617") // gray-950
    
    // 卡片背景
    static let caobaoCardLight = Color.white.opacity(0.8)
    static let caobaoCardDark = Color(hex: "1F2937").opacity(0.8) // gray-800
    
    // 渐变色
    static let caobaoGradientStart = Color(hex: "22C55E") // green-500
    static let caobaoGradientEnd = Color(hex: "10B981") // emerald-500
}

// MARK: - ShapeStyle 扩展 (用于 foregroundStyle)
public extension ShapeStyle where Self == Color {
    static var caobaoPrimary: Color { Color.caobaoPrimary }
    static var caobaoPrimaryDark: Color { Color.caobaoPrimaryDark }
    static var caobaoPrimaryLight: Color { Color.caobaoPrimaryLight }
    static var caobaoAccent: Color { Color.caobaoAccent }
}

// MARK: - 渐变背景
public extension LinearGradient {
    // 主渐变 - 绿色到青绿色
    static let caobaoPrimary = LinearGradient(
        colors: [.caobaoGradientStart, .caobaoGradientEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    // 卡片背景渐变
    static let caobaoCard = LinearGradient(
        colors: [.caobaoPrimary.opacity(0.1), .clear],
        startPoint: .top,
        endPoint: .bottom
    )
    
    // 运势卡片渐变 - 橙色到黄色
    static let caobaoFortune = LinearGradient(
        colors: [Color(hex: "F97316"), Color(hex: "EAB308")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    // 语录卡片渐变 - 紫色到靛蓝色
    static let caobaoQuote = LinearGradient(
        colors: [Color(hex: "A855F7"), Color(hex: "6366F1")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    // 晚安卡片渐变 - 紫色到蓝色
    static let caobaoEvening = LinearGradient(
        colors: [Color(hex: "8B5CF6"), Color(hex: "3B82F6")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - 卡片样式
public struct CaobaoCardStyle: ViewModifier {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 16
    var hasShadow: Bool = true
    
    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
                    .shadow(
                        color: hasShadow ? .black.opacity(0.08) : .clear,
                        radius: 8,
                        x: 0,
                        y: 4
                    )
            )
    }
}

public extension View {
    func caobaoCard(padding: CGFloat = 16, cornerRadius: CGFloat = 16, hasShadow: Bool = true) -> some View {
        modifier(CaobaoCardStyle(padding: padding, cornerRadius: cornerRadius, hasShadow: hasShadow))
    }
}

// MARK: - 功能卡片样式
public struct CaobaoFeatureCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    var iconSize: CGFloat = 24
    
    public init(icon: String, title: String, subtitle: String, color: Color, iconSize: CGFloat = 24) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.color = color
        self.iconSize = iconSize
    }
    
    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(color.opacity(0.15))
                )
            
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        )
    }
}

// MARK: - 快捷入口行样式
public struct CaobaoQuickActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    
    public init(icon: String, title: String, subtitle: String, color: Color) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.color = color
    }
    
    public var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(
                    Circle()
                        .fill(color.opacity(0.15))
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                
                Text(subtitle)
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
}

// MARK: - 统计卡片样式
public struct CaobaoStatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    public init(title: String, value: String, icon: String, color: Color) {
        self.title = title
        self.value = value
        self.icon = icon
        self.color = color
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
            
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        )
    }
}

// MARK: - Hero 区域样式
public struct CaobaoHeroSection: View {
    let greeting: String
    let nickname: String
    
    public init(greeting: String, nickname: String) {
        self.greeting = greeting
        self.nickname = nickname
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            Text("\(greeting)，\(nickname)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
            
            Text("今天也要开心地被毒舌哦~")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [.caobaoPrimary.opacity(0.1), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
    }
}

// MARK: - 运势卡片样式
public struct CaobaoFortuneCard: View {
    let fortune: FortuneData
    
    public init(fortune: FortuneData) {
        self.fortune = fortune
    }
    
    public var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                Text("今日运势")
                    .font(.headline)
                    .foregroundStyle(.primary)
                
                Spacer()
                
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        Image(systemName: i < fortune.overall ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundStyle(i < fortune.overall ? .yellow : .gray.opacity(0.3))
                    }
                }
            }
            
            HStack(spacing: 12) {
                CaobaoFortuneItem(title: "综合", value: fortune.overall, color: .caobaoPrimary)
                CaobaoFortuneItem(title: "爱情", value: fortune.love, color: .pink)
                CaobaoFortuneItem(title: "事业", value: fortune.career, color: .blue)
                CaobaoFortuneItem(title: "财运", value: fortune.wealth, color: .yellow)
                CaobaoFortuneItem(title: "健康", value: fortune.health, color: .red)
            }
            
            if !fortune.advice.isEmpty {
                Text(fortune.advice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        )
    }
}

public struct CaobaoFortuneItem: View {
    let title: String
    let value: Int
    let color: Color
    
    public init(title: String, value: Int, color: Color) {
        self.title = title
        self.value = value
        self.color = color
    }
    
    public var body: some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.headline)
                .foregroundStyle(color)
            
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 渐变按钮样式
public struct CaobaoGradientButton: View {
    let title: String
    let action: () -> Void
    
    public init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient.caobaoPrimary)
                        .shadow(color: .caobaoPrimary.opacity(0.3), radius: 8, y: 4)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 颜色扩展 - Hex 初始化
public extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - 动画扩展
public extension Animation {
    static let caobaoSpring = Animation.spring(response: 0.4, dampingFraction: 0.75)
    static let caobaoEaseOut = Animation.easeOut(duration: 0.3)
}

// MARK: - 功能图标颜色映射
public extension Color {
    static func featureColor(for title: String) -> Color {
        switch title {
        case "自由对话": return .caobaoPrimary
        case "今日运势": return .purple
        case "图片分析": return .orange
        case "毒舌金句": return .cyan
        case "吐槽大会": return .red
        case "毒舌昵称": return .blue
        case "犀利评分": return .pink
        case "决策助手": return .indigo
        case "早报": return .orange
        case "晚报": return .purple
        default: return .caobaoPrimary
        }
    }
}
