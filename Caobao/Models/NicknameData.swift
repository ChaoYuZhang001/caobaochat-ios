import Foundation

// MARK: - Nickname Item (昵称项)
struct NicknameItem: Codable {
    let name: String
    let reason: String
}

// MARK: - Nickname Response (API 响应)
struct NicknameResponse: Codable {
    let success: Bool
    let nicknames: [NicknameItem]?
    let error: String?
}
