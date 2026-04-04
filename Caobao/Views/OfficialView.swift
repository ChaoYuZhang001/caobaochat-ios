//
//  OfficialView.swift
//  Caobao
//
//  草台班子官网页面
//

import SwiftUI

struct OfficialView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Hero
                    heroSection
                    
                    // 理念
                    philosophySection
                    
                    // 产品矩阵
                    productsSection
                    
                    // 团队文化
                    cultureSection
                    
                    // 联系方式
                    contactSection
                }
                .padding()
            }
            .background(Color.caobaoGroupedBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("草台班子")
                        .font(.headline)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("返回") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    // MARK: - Hero Section
    private var heroSection: some View {
        VStack(spacing: 16) {
            // Logo
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.green.opacity(0.2), Color.green.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                
                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 70, height: 70)
                    .clipShape(Circle())
            }
            
            Text("草台班子")
                .font(.title)
                .fontWeight(.bold)
            
            Text("世界就是一个巨大的草台班子")
                .font(.headline)
                .foregroundColor(.green)
            
            Text("看似严肃的世界，其实每个人都在摸着石头过河。我们不追求完美的技术，只想做出有用、好用、有趣的AI产品。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .padding(.vertical, 20)
    }
    
    // MARK: - Philosophy Section
    private var philosophySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("我们的理念")
                .font(.headline)
            
            VStack(spacing: 12) {
                philosophyItem(
                    icon: "bubble.left.and.bubble.right",
                    title: "有用",
                    desc: "不装高大上，只解决实际问题",
                    color: .green
                )
                
                philosophyItem(
                    icon: "hand.thumbsup",
                    title: "好用",
                    desc: "简单直接，上手就会",
                    color: .blue
                )
                
                philosophyItem(
                    icon: "face.smiling",
                    title: "有趣",
                    desc: "毒舌但温暖，吐槽但有爱",
                    color: .orange
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
    }
    
    private func philosophyItem(icon: String, title: String, desc: String, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.15))
                    .frame(width: 44, height: 44)
                
                Image(systemName: icon)
                    .foregroundColor(color)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Products Section
    private var productsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("产品矩阵")
                .font(.headline)
            
            VStack(spacing: 12) {
                productCard(
                    name: "草包助手",
                    desc: "毒舌但有用的AI助手",
                    features: ["37+ AI模型", "运势/金句/吐槽", "语音/图片/文档"],
                    color: .green
                )
                
                productCard(
                    name: "草根社区",
                    desc: "AI原生内容社区（开发中）",
                    features: ["AI创作分享", "提示词市场", "Agent工坊"],
                    color: .purple
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
    }
    
    private func productCard(name: String, desc: String, features: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name)
                    .font(.headline)
                    .foregroundColor(color)
                
                Spacer()
                
                if name.contains("开发中") {
                    Text("Coming Soon")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(color.opacity(0.15))
                        .foregroundColor(color)
                        .cornerRadius(4)
                }
            }
            
            Text(desc)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack(spacing: 8) {
                ForEach(features, id: \.self) { feature in
                    Text(feature)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.systemGray6))
                        .cornerRadius(4)
                }
            }
        }
        .padding()
        .background(color.opacity(0.05))
        .cornerRadius(12)
    }
    
    // MARK: - Culture Section
    private var cultureSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("团队文化")
                .font(.headline)
            
            VStack(spacing: 12) {
                cultureItem(
                    emoji: "🎯",
                    title: "结果导向",
                    desc: "不卷工时，只看产出"
                )
                
                cultureItem(
                    emoji: "🚀",
                    title: "快速迭代",
                    desc: "小步快跑，持续优化"
                )
                
                cultureItem(
                    emoji: "💡",
                    title: "拥抱变化",
                    desc: "唯一不变的就是变化"
                )
                
                cultureItem(
                    emoji: "🤝",
                    title: "开放协作",
                    desc: "每个人都是产品经理"
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
    }
    
    private func cultureItem(emoji: String, title: String, desc: String) -> some View {
        HStack(spacing: 12) {
            Text(emoji)
                .font(.title2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Contact Section
    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("联系我们")
                .font(.headline)
            
            VStack(spacing: 12) {
                contactRow(
                    icon: "envelope.fill",
                    title: "商务合作",
                    value: "2900814034@qq.com",
                    color: .green
                )
                
                contactRow(
                    icon: "message.fill",
                    title: "用户反馈",
                    value: "2900814034@qq.com",
                    color: .blue
                )
                
                contactRow(
                    icon: "clock.fill",
                    title: "工作时间",
                    value: "工作日 9:00-18:00",
                    color: .orange
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
    }
    
    private func contactRow(icon: String, title: String, value: String, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.15))
                    .frame(width: 36, height: 36)
                
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(color)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            
            Spacer()
        }
    }
}

#Preview {
    OfficialView()
}
