import Foundation

// MARK: - User Model (API Response)
struct User: Codable, Identifiable {
    let id: String
    let authProvider: String
    let isGuest: Bool?
    let createdAt: Int?
    let updatedAt: Int?
    let lastLoginAt: Int?
    let settings: APIUserSettings?
    let stats: APIUserStats?
    let name: String?
    let email: String?
    let avatar: String?
    let guestExpiresAt: Int?
    
    // 便捷属性
    var displayName: String {
        name ?? "用户"
    }
    
    var isExpired: Bool {
        guard let expiresAt = guestExpiresAt else { return false }
        return Date().timeIntervalSince1970 * 1000 > Double(expiresAt)
    }
}

// MARK: - API User Settings (来自服务器)
struct APIUserSettings: Codable {
    let toxicLevel: String?
    let theme: String?
    let language: String?
    let voiceEnabled: Bool?
    let notifications: Bool?
}

// MARK: - API User Stats (来自服务器)
struct APIUserStats: Codable {
    let totalConversations: Int?
    let totalTokens: Int?
    let totalMessages: Int?
    let avgRating: Double?
    let achievements: [String]?
}
