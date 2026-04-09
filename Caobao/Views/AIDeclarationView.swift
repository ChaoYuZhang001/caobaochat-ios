//
//  AIDeclarationView.swift
//  Caobao
//
//  AI 使用声明页面
//  符合 App Store 审核指南 5.1.1 和中国 AI 法规要求
//

import SwiftUI

struct AIDeclarationView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 顶部提示
                    warningCard
                    
                    // AI 说明
                    aiDescriptionSection
                    
                    // 使用限制
                    usageLimitSection
                    
                    // 免责声明
                    disclaimerSection
                    
                    // 用户责任
                    userResponsibilitySection
                    
                    // 举报入口
                    reportSection
                }
                .padding()
            }
            .background(Color.caobaoGroupedBackground)
            .navigationTitle("AI 使用声明")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    // MARK: - 警告卡片
    private var warningCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("重要提示")
                    .font(.headline)
                Text("AI 生成内容仅供参考，请独立判断其准确性")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }
    
    // MARK: - AI 说明
    private var aiDescriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "关于 AI 服务", icon: "cpu", color: .green)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("草包助手使用大语言模型（LLM）提供智能对话服务。我们的 AI 服务来自以下供应商：")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                VStack(spacing: 8) {
                    aiProviderRow(name: "火山引擎豆包", desc: "对话生成、视觉理解")
                    aiProviderRow(name: "通义千问", desc: "对话生成、多模态交互")
                    aiProviderRow(name: "DeepSeek", desc: "深度推理、代码生成")
                    aiProviderRow(name: "Kimi", desc: "长文本处理")
                    aiProviderRow(name: "文心一言", desc: "知识问答、创作辅助")
                    aiProviderRow(name: "腾讯混元", desc: "对话生成、多模态")
                    aiProviderRow(name: "讯飞星火", desc: "认知智能、语音交互")
                    aiProviderRow(name: "xAI Grok", desc: "幽默毒舌、实时信息")
                }
            }
        }
        .padding()
        .background(Color.caobaoSystemBackground)
        .cornerRadius(12)
    }
    
    private func aiProviderRow(name: String, desc: String) -> some View {
        HStack {
            Circle()
                .fill(Color.green.opacity(0.2))
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
    
    // MARK: - 使用限制
    private var usageLimitSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "使用限制", icon: "hand.raised", color: .red)
            
            VStack(alignment: .leading, spacing: 8) {
                limitationRow("不得用于医疗诊断或治疗建议")
                limitationRow("不得用于法律或金融专业决策")
                limitationRow("不得用于危害国家安全的行为")
                limitationRow("不得用于生成虚假信息或谣言")
                limitationRow("不得用于侵犯他人权益的内容")
                limitationRow("不得尝试绕过 AI 安全限制")
            }
        }
        .padding()
        .background(Color.caobaoSystemBackground)
        .cornerRadius(12)
    }
    
    private func limitationRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(.red)
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - 免责声明
    private var disclaimerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "免责声明", icon: "shield", color: .blue)
            
            VStack(alignment: .leading, spacing: 10) {
                disclaimerText("AI 生成的内容可能存在错误、偏见或不准确之处，不代表平台观点。")
                disclaimerText("用户应对 AI 生成的内容进行独立判断，并自行承担使用风险。")
                disclaimerText("平台不对因使用 AI 内容导致的任何损失承担责任。")
                disclaimerText("AI 可能会生成意外内容，如发现不当内容请及时举报。")
            }
        }
        .padding()
        .background(Color.caobaoSystemBackground)
        .cornerRadius(12)
    }
    
    private func disclaimerText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundColor(.blue)
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - 用户责任
    private var userResponsibilitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "您的责任", icon: "checkmark.shield", color: .purple)
            
            VStack(alignment: .leading, spacing: 10) {
                responsibilityRow("遵守中华人民共和国相关法律法规")
                responsibilityRow("不利用 AI 服务从事违法活动")
                responsibilityRow("对使用 AI 生成内容的行为负责")
                responsibilityRow("如发现违规内容，及时向我们举报")
            }
        }
        .padding()
        .background(Color.caobaoSystemBackground)
        .cornerRadius(12)
    }
    
    private func responsibilityRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.purple)
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - 举报入口
    private var reportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "内容举报", icon: "flag", color: .orange)
            
            Text("如您发现 AI 生成的违法违规、侵权或不当内容，请通过以下方式举报：")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(spacing: 10) {
                reportRow(icon: "envelope", title: "邮件举报", value: "2900814034@qq.com")
                reportRow(icon: "clock", title: "处理时效", value: "工作日 24 小时内响应")
            }
            
            NavigationLink {
                FeedbackView()
            } label: {
                HStack {
                    Image(systemName: "megaphone.fill")
                        .foregroundColor(.white)
                    Text("立即举报")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.orange)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color.caobaoSystemBackground)
        .cornerRadius(12)
    }
    
    private func reportRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.orange)
                .frame(width: 20)
            
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }
    
    // MARK: - Section Header
    private func sectionHeader(title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
            
            Text(title)
                .font(.headline)
        }
    }
}

#Preview {
    AIDeclarationView()
}
