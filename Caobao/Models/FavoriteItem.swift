//
//  FavoriteItem.swift
//  Caobao
//
//  收藏数据模型
//

import Foundation
import SwiftUI

struct FavoriteItem: Identifiable, Codable {
    let id: Int
    let type: String
    let content: String
    let context: String?
    let created_at: String
    
    var typeName: String {
        switch type {
        case "quote": return "金句"
        case "nickname": return "昵称"
        case "message": return "消息"
        case "image": return "图片"
        default: return "其他"
        }
    }
    
    var icon: String {
        switch type {
        case "quote": return "quote.bubble"
        case "nickname": return "person"
        case "message": return "bubble.left.and.bubble.right"
        case "image": return "photo"
        default: return "star"
        }
    }
    
    var typeColor: Color {
        switch type {
        case "quote": return .green
        case "nickname": return .blue
        case "message": return .purple
        case "image": return .orange
        default: return .gray
        }
    }
    
    var displayDate: String {
        // 格式化日期显示
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        
        if let date = isoFormatter.date(from: created_at) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "MM-dd HH:mm"
            return displayFormatter.string(from: date)
        }
        return created_at
    }
}
