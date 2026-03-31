import Foundation

// MARK: - Watch API Service
/// 简化版 API 服务，专用于 watchOS
class WatchAPIService {
    static let shared = WatchAPIService()
    
    private let baseURL = "https://caobao.chat/api"
    private let session: URLSession
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Get Fortune
    func getFortune() async throws -> WatchFortuneResponse {
        let url = URL(string: "\(baseURL)/caobao/fortune")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw WatchAPIError.serverError
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(WatchFortuneResponse.self, from: data)
    }
    
    // MARK: - Get Morning Report
    func getMorningReport() async throws -> WatchMorningReportResponse {
        let url = URL(string: "\(baseURL)/report/morning")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw WatchAPIError.serverError
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(WatchMorningReportResponse.self, from: data)
    }
    
    // MARK: - Get Roast
    func getRoast(type: String) async throws -> WatchRoastResponse {
        let url = URL(string: "\(baseURL)/caobao/roast?type=\(type)")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw WatchAPIError.serverError
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(WatchRoastResponse.self, from: data)
    }
    
    // MARK: - Make Decision
    func makeDecision(question: String, options: [String]) async throws -> WatchDecisionResponse {
        let url = URL(string: "\(baseURL)/caobao/decision")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "question": question,
            "options": options
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw WatchAPIError.serverError
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(WatchDecisionResponse.self, from: data)
    }
}

// MARK: - Watch API Error
enum WatchAPIError: Error, LocalizedError {
    case serverError
    case decodingError
    
    var errorDescription: String? {
        switch self {
        case .serverError: return "服务器错误"
        case .decodingError: return "数据解析错误"
        }
    }
}

// MARK: - Response Models

struct WatchFortuneResponse: Codable {
    let success: Bool
    let fortuneIndex: Int
    let fortuneSummary: String
    let loveScore: Int
    let careerScore: Int
    let wealthScore: Int
    let healthScore: Int
    let advice: String
    
    // Coding keys for different API response formats
    enum CodingKeys: String, CodingKey {
        case success
        case fortuneIndex = "fortune_index"
        case fortuneSummary = "fortune_summary"
        case loveScore = "love_score"
        case careerScore = "career_score"
        case wealthScore = "wealth_score"
        case healthScore = "health_score"
        case advice
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        fortuneIndex = try container.decodeIfPresent(Int.self, forKey: .fortuneIndex) ?? 50
        fortuneSummary = try container.decodeIfPresent(String.self, forKey: .fortuneSummary) ?? ""
        loveScore = try container.decodeIfPresent(Int.self, forKey: .loveScore) ?? 50
        careerScore = try container.decodeIfPresent(Int.self, forKey: .careerScore) ?? 50
        wealthScore = try container.decodeIfPresent(Int.self, forKey: .wealthScore) ?? 50
        healthScore = try container.decodeIfPresent(Int.self, forKey: .healthScore) ?? 50
        advice = try container.decodeIfPresent(String.self, forKey: .advice) ?? ""
    }
}

struct WatchMorningReportResponse: Codable {
    let success: Bool
    let news: [WatchNewsResponse]?
    
    enum CodingKeys: String, CodingKey {
        case success
        case news
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        
        // Handle nested data structure
        if let dataContainer = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .news) {
            news = try dataContainer.decodeIfPresent([WatchNewsResponse].self, forKey: .news)
        } else {
            news = try container.decodeIfPresent([WatchNewsResponse].self, forKey: .news)
        }
    }
}

struct WatchNewsResponse: Codable {
    let title: String?
    let source: String?
    let summary: String?
    let comment: String?
}

struct WatchRoastResponse: Codable {
    let success: Bool
    let content: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case content
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? "生成失败"
    }
}

struct WatchDecisionResponse: Codable {
    let success: Bool
    let decision: String?
    let reasoning: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case decision
        case reasoning
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decodeIfPresent(Bool.self, forKey: .success) ?? true
        decision = try container.decodeIfPresent(String.self, forKey: .decision)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
    }
}
