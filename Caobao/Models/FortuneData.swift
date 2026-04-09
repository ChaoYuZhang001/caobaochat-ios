import Foundation

// MARK: - Fortune Data Model (统一运势数据模型，与 Web API 对齐)
public struct FortuneData: Codable {
    public let overall: Int
    public let overallComment: String?
    public let aspects: FortuneAspects?
    public let luckyItem: String?
    public let luckyColor: String?
    public let luckyNumber: Int?
    public let warning: String?
    public let suggestion: String?
    public let date: String?  // 添加日期字段
    
    // 便捷属性，兼容旧代码
    public var love: Int { aspects?.love?.score ?? 50 }
    public var career: Int { aspects?.work?.score ?? 50 }
    public var wealth: Int { aspects?.wealth?.score ?? 50 }
    public var health: Int { aspects?.health?.score ?? 50 }
    public var message: String { overallComment ?? "" }
    public var advice: String { suggestion ?? "" }
    
    // 用于 HomeView 简化显示的便捷初始化器
    public init(overall: Int, love: Int, career: Int, wealth: Int, health: Int, message: String = "", advice: String = "", luckyColor: String = "#4CAF50", luckyNumber: Int = 7) {
        self.overall = overall
        self.overallComment = message
        self.aspects = FortuneAspects(
            love: FortuneAspect(score: love, comment: ""),
            work: FortuneAspect(score: career, comment: ""),
            wealth: FortuneAspect(score: wealth, comment: ""),
            health: FortuneAspect(score: health, comment: "")
        )
        self.luckyItem = nil
        self.luckyColor = luckyColor
        self.luckyNumber = luckyNumber
        self.warning = nil
        self.suggestion = advice
        self.date = nil
    }
    
    // 完整初始化器，用于从 API 响应创建
    public init(
        overall: Int,
        overallComment: String? = nil,
        aspects: FortuneAspects? = nil,
        luckyItem: String? = nil,
        luckyColor: String? = nil,
        luckyNumber: Int? = nil,
        warning: String? = nil,
        suggestion: String? = nil,
        date: String? = nil
    ) {
        self.overall = overall
        self.overallComment = overallComment
        self.aspects = aspects
        self.luckyItem = luckyItem
        self.luckyColor = luckyColor
        self.luckyNumber = luckyNumber
        self.warning = warning
        self.suggestion = suggestion
        self.date = date
    }
}

// MARK: - Fortune Aspects
public struct FortuneAspects: Codable, Sendable {
    public let love: FortuneAspect?
    public let work: FortuneAspect?
    public let wealth: FortuneAspect?
    public let health: FortuneAspect?
    
    // 其他可能的面相（可选，API可能不返回）
    public let charm: FortuneAspect?
    public let relationship: FortuneAspect?
    public let colleague: FortuneAspect?
    public let opportunity: FortuneAspect?
    public let income: FortuneAspect?
    public let invest: FortuneAspect?
    public let spend: FortuneAspect?
    public let other: FortuneAspect?
    
    // 便捷初始化器，用于本地创建
    public init(
        love: FortuneAspect? = nil,
        work: FortuneAspect? = nil,
        wealth: FortuneAspect? = nil,
        health: FortuneAspect? = nil,
        charm: FortuneAspect? = nil,
        relationship: FortuneAspect? = nil,
        colleague: FortuneAspect? = nil,
        opportunity: FortuneAspect? = nil,
        income: FortuneAspect? = nil,
        invest: FortuneAspect? = nil,
        spend: FortuneAspect? = nil,
        other: FortuneAspect? = nil
    ) {
        self.love = love
        self.work = work
        self.wealth = wealth
        self.health = health
        self.charm = charm
        self.relationship = relationship
        self.colleague = colleague
        self.opportunity = opportunity
        self.income = income
        self.invest = invest
        self.spend = spend
        self.other = other
    }
}

// MARK: - Fortune Aspect
public struct FortuneAspect: Codable, Sendable {
    public let score: Int
    public let comment: String
    
    public init(score: Int, comment: String) {
        self.score = score
        self.comment = comment
    }
}

// MARK: - Fortune Response (API 响应)
public struct FortuneResponse: Codable, Sendable {
    public let success: Bool
    public let date: String?
    public let overall: Int
    public let overallComment: String?
    public let aspects: FortuneAspects?
    public let luckyItem: String?
    public let luckyColor: String?
    public let luckyNumber: Int?
    public let warning: String?
    public let suggestion: String?
    public let timestamp: String?
    public let error: String?
    
    // 转换为 FortuneData
    public func toFortuneData() -> FortuneData {
        return FortuneData(
            overall: overall,
            overallComment: overallComment,
            aspects: aspects,
            luckyItem: luckyItem,
            luckyColor: luckyColor,
            luckyNumber: luckyNumber,
            warning: warning,
            suggestion: suggestion,
            date: date
        )
    }
}
