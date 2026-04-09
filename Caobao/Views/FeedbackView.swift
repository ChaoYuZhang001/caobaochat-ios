//
//  FeedbackView.swift
//  Caobao
//
//  意见反馈页面
//

import SwiftUI

enum FeedbackType: String, CaseIterable {
    case bug = "bug"
    case feature = "feature"
    case content = "content"
    case other = "other"
    
    var label: String {
        switch self {
        case .bug: return "问题反馈"
        case .feature: return "功能建议"
        case .content: return "内容反馈"
        case .other: return "其他"
        }
    }
    
    var desc: String {
        switch self {
        case .bug: return "报告Bug或异常"
        case .feature: return "提出新功能想法"
        case .content: return "AI回复问题"
        case .other: return "其他意见或建议"
        }
    }
    
    var icon: String {
        switch self {
        case .bug: return "ladybug"
        case .feature: return "lightbulb"
        case .content: return "bubble.left.and.bubble.right"
        case .other: return "questionmark.circle"
        }
    }
}

struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedType: FeedbackType?
    @State private var rating: Int = 0
    @State private var content: String = ""
    @State private var contact: String = ""
    @State private var isSubmitting = false
    @State private var submitted = false
    @State private var errorMessage: String?
    
    private let ratings = [
        (value: 5, label: "非常满意", emoji: "😍"),
        (value: 4, label: "比较满意", emoji: "😊"),
        (value: 3, label: "一般", emoji: "😐"),
        (value: 2, label: "不太满意", emoji: "😕"),
        (value: 1, label: "很不满意", emoji: "😠")
    ]
    
    var body: some View {
        NavigationStack {
            if submitted {
                successView
            } else {
                formView
            }
        }
    }
    
    private var successView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
            
            Text("感谢您的反馈！")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("我们会认真对待每一条反馈，并在3个工作日内处理。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button {
                dismiss()
            } label: {
                Text("返回")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)
            .padding(.top, 20)
        }
    }
    
    private var formView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 标题
                VStack(spacing: 8) {
                    Text("意见反馈")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("您的意见是我们进步的动力")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                
                // 反馈类型
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("反馈类型")
                            .font(.headline)
                        Text("*")
                            .foregroundColor(.red)
                    }
                    
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(FeedbackType.allCases, id: \.self) { type in
                            typeButton(type: type)
                        }
                    }
                }
                
                // 满意度评分
                VStack(alignment: .leading, spacing: 12) {
                    Text("满意度评分")
                        .font(.headline)
                    
                    HStack(spacing: 8) {
                        ForEach(ratings, id: \.value) { item in
                            ratingButton(value: item.value, label: item.label, emoji: item.emoji)
                        }
                    }
                }
                
                // 反馈内容
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("详细描述")
                            .font(.headline)
                        Text("*")
                            .foregroundColor(.red)
                    }
                    
                    TextEditor(text: $content)
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(Color(.systemGray6).opacity(1))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(.systemGray4).opacity(1), lineWidth: 1)
                        )
                    
                    HStack {
                        Spacer()
                        Text("\(content.count)/500")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // 联系方式
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("联系方式")
                            .font(.headline)
                        Text("（选填）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    TextField("邮箱或微信（用于回复您）", text: $contact)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                
                // 错误信息
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                
                // 提交按钮
                Button {
                    submitFeedback()
                } label: {
                    HStack {
                        if isSubmitting {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        }
                        Text(isSubmitting ? "提交中..." : "提交反馈")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canSubmit ? Color.green : Color.gray)
                    .cornerRadius(12)
                }
                .disabled(!canSubmit || isSubmitting)
                
                // 其他联系方式
                VStack(alignment: .leading, spacing: 12) {
                    Text("其他联系方式")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("邮箱：")
                                .foregroundColor(.secondary)
                            Link("2900814034@qq.com", destination: URL(string: "mailto:2900814034@qq.com")!)
                                .foregroundColor(.green)
                        }
                        
                        Text("响应时间：工作日 9:00-18:00，一般3个工作日内回复")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.systemGray6).opacity(1))
                    .cornerRadius(12)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("取消") {
                    dismiss()
                }
            }
        }
    }
    
    private var canSubmit: Bool {
        selectedType != nil && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private func typeButton(type: FeedbackType) -> some View {
        Button {
            selectedType = type
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: type.icon)
                    .font(.title3)
                    .foregroundColor(selectedType == type ? .green : .secondary)
                
                Text(type.label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                
                Text(type.desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(selectedType == type ? Color.green.opacity(0.1) : Color(.systemGray6))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selectedType == type ? Color.green : Color.clear, lineWidth: 2)
            )
        }
    }
    
    private func ratingButton(value: Int, label: String, emoji: String) -> some View {
        Button {
            rating = value
        } label: {
            VStack(spacing: 4) {
                Text(emoji)
                    .font(.title2)
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(rating == value ? Color.green.opacity(0.1) : Color(.systemGray6))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(rating == value ? Color.green : Color.clear, lineWidth: 2)
            )
        }
    }
    
    private func submitFeedback() {
        guard let type = selectedType else { return }
        
        isSubmitting = true
        errorMessage = nil
        
        Task {
            do {
                try await APIService.shared.submitFeedback(
                    type: type.rawValue,
                    content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                    contact: contact.isEmpty ? nil : contact,
                    rating: rating > 0 ? rating : 5
                )
                
                await MainActor.run {
                    submitted = true
                    isSubmitting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }
}

#Preview {
    FeedbackView()
}
