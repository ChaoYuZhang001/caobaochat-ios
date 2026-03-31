//
//  AboutView.swift
//  Caobao
//
//  关于页面
//

import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    
    private let features = [
        (icon: "bubble.left.and.bubble.right", title: "多模型对话", desc: "支持37+AI模型切换", color: Color.green),
        (icon: "sparkles", title: "毒舌特色", desc: "运势/金句/改名/评分", color: Color.purple),
        (icon: "waveform", title: "语音服务", desc: "TTS合成 / ASR识别", color: Color.orange),
        (icon: "doc.text.image", title: "图片文档", desc: "生成/理解/OCR", color: Color.blue)
    ]
    
    private let stats = [
        (value: "37+", label: "AI模型"),
        (value: "10万+", label: "用户选择"),
        (value: "500万+", label: "对话生成"),
        (value: "4.9", label: "用户评分")
    ]
    
    private let values = [
        (icon: "heart.fill", title: "真诚", desc: "不虚伪，不敷衍", color: Color.red),
        (icon: "star.fill", title: "有用", desc: "给建议，不只是吐槽", color: Color.yellow),
        (icon: "target", title: "靠谱", desc: "说到做到", color: Color.blue),
        (icon: "lightbulb.fill", title: "有趣", desc: "让生活多点乐子", color: Color.green)
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Hero 区域
                    heroSection
                    
                    // 统计数据
                    statsSection
                    
                    // 我们的故事
                    storySection
                    
                    // 核心功能
                    featuresSection
                    
                    // 价值观
                    valuesSection
                    
                    // 联系我们
                    contactSection
                    
                    // 底部信息
                    footerSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("关于我们")
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
    
    private var heroSection: some View {
        VStack(spacing: 16) {
            // Logo
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image("logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            
            Text("关于草包")
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.green)
            
            Text("毒舌但有用的AI助手")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("犀利吐槽 + 真诚建议 = 你的毒舌朋友")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 20)
    }
    
    private var statsSection: some View {
        HStack(spacing: 12) {
            ForEach(stats, id: \.label) { stat in
                VStack(spacing: 4) {
                    Text(stat.value)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    Text(stat.label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(.systemBackground))
                .cornerRadius(12)
            }
        }
    }
    
    private var storySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "rocket")
                    .foregroundColor(.green)
                Text("我们的故事")
                    .font(.headline)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                Text("\"世界就是一个巨大的草台班子。\"")
                    .font(.headline)
                    .foregroundColor(.green)
                
                Text("这是我们名字的来源。看似严肃的世界，其实每个人都在摸着石头过河——没有完美的剧本，没有彩排，大家都在即兴发挥。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text("我们觉得AI行业也是如此。那些高大上的AI产品，用起来未必顺手；反而是简单粗暴、接地气的东西，更能解决问题。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text("所以我们创造了草包——一个毒舌但有用、犀利但不伤人、幽默有关怀的AI助手。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(16)
    }
    
    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("核心功能")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(features, id: \.title) { feature in
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(feature.color.opacity(0.15))
                                .frame(width: 44, height: 44)
                            
                            Image(systemName: feature.icon)
                                .foregroundColor(feature.color)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text(feature.desc)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                }
            }
        }
    }
    
    private var valuesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("我们的价值观")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
            
            HStack(spacing: 12) {
                ForEach(values, id: \.title) { value in
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(value.color.opacity(0.15))
                                .frame(width: 50, height: 50)
                            
                            Image(systemName: value.icon)
                                .foregroundColor(value.color)
                        }
                        
                        Text(value.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        Text(value.desc)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(12)
        }
    }
    
    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("联系我们")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
            
            HStack(spacing: 12) {
                // 邮箱
                Link(destination: URL(string: "mailto:2900814034@qq.com")!) {
                    VStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.green.opacity(0.15))
                                .frame(width: 50, height: 50)
                            
                            Image(systemName: "envelope")
                                .foregroundColor(.green)
                        }
                        
                        Text("客服邮箱")
                            .font(.caption)
                            .fontWeight(.medium)
                        
                        Text("2900814034@qq.com")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                }
                
                // 工作时间
                VStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: 50, height: 50)
                        
                        Image(systemName: "clock")
                            .foregroundColor(.blue)
                    }
                    
                    Text("工作时间")
                        .font(.caption)
                        .fontWeight(.medium)
                    
                    Text("工作日 9:00-18:00")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.systemBackground))
                .cornerRadius(12)
            }
        }
    }
    
    private var footerSection: some View {
        VStack(spacing: 12) {
            Text("草台班子 © 2026")
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(spacing: 16) {
                Link("用户协议", destination: URL(string: "https://caobao.ai/legal/agreement")!)
                Link("隐私政策", destination: URL(string: "https://caobao.ai/legal/privacy")!)
                Link("意见反馈", destination: URL(string: "https://caobao.ai/feedback")!)
            }
            .font(.caption)
            .foregroundColor(.green)
        }
        .padding(.vertical, 20)
    }
}

#Preview {
    AboutView()
}
