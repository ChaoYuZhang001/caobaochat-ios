import SwiftUI

// MARK: - Roast View (吐槽大会)
struct RoastView: View {
    @State private var content = ""
    @State private var intensity = "medium"
    @State private var loading = false
    @State private var result = ""
    @State private var copied = false
    @State private var errorMessage: String?
    
    private let intensities = [
        ("mild", "温和", "🌶️", "点到为止", Color.green),
        ("medium", "中等", "🌶️🌶️", "一针见血", Color.orange),
        ("spicy", "爆辣", "🌶️🌶️🌶️", "直击灵魂", Color.red),
    ]
    
    private let quickExamples = [
        "我的老板总说\"这个很简单，你随便搞搞\"",
        "朋友借钱不还还装没事人",
        "相亲遇到奇葩男/女",
        "同事总爱抢功劳甩锅",
        "领导画饼从来不兑现",
    ]
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 渐变背景
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.red.opacity(0.2),
                        Color.orange.opacity(0.15),
                        Color.yellow.opacity(0.1),
                        Color.caobaoGroupedBackground
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // 头部 Banner
                        headerBanner
                        
                        // 吐槽强度
                        VStack(alignment: .leading, spacing: 12) {
                            Text("吐槽强度")
                                .font(.headline)
                            
                            HStack(spacing: 12) {
                                ForEach(intensities, id: \.0) { i in
                                    IntensityCard(
                                        emoji: i.2,
                                        name: i.1,
                                        desc: i.3,
                                        isSelected: intensity == i.0,
                                        color: i.4
                                    ) {
                                        intensity = i.0
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        // 快捷示例
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Text("快速选择")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(quickExamples, id: \.self) { example in
                                        Button {
                                            content = example
                                        } label: {
                                            Text(example.count > 12 ? String(example.prefix(12)) + "..." : example)
                                                .font(.caption)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(content == example ? Color.red : Color(.systemGray6))
                                                .foregroundStyle(content == example ? .white : .primary)
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        // 吐槽内容
                        VStack(alignment: .leading, spacing: 12) {
                            Text("吐槽内容")
                                .font(.headline)
                            
                            TextEditor(text: $content)
                                .frame(minHeight: 100)
                                .padding(8)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color(.systemGray4), lineWidth: 1)
                                )
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        // 吐槽按钮
                        Button {
                            startRoast()
                        } label: {
                            HStack {
                                if loading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "flame.fill")
                                }
                                Text(loading ? "吐槽中..." : "开始吐槽")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                LinearGradient(
                                    gradient: Gradient(colors: [Color.red, Color.orange]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(loading || content.isEmpty)
                        .opacity(content.isEmpty ? 0.5 : 1)
                        
                        // 错误提示
                        if let error = errorMessage {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(error)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(Color.orange.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        
                        // 吐槽结果
                        if !result.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("毒舌点评")
                                        .font(.headline)
                                    
                                    Spacer()
                                    
                                    Button {
                                        copyResult()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                            Text(copied ? "已复制" : "复制")
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                    }
                                }
                                
                                // 格式化显示结果
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 12) {
                                        ForEach(formatResult(result), id: \.self) { paragraph in
                                            if paragraph.hasPrefix("【") && paragraph.hasSuffix("】") {
                                                // 标题
                                                Text(paragraph)
                                                    .font(.headline)
                                                    .foregroundStyle(.red)
                                            } else if paragraph.hasPrefix("•") || paragraph.hasPrefix("-") || paragraph.hasPrefix("·") {
                                                // 列表项
                                                HStack(alignment: .top, spacing: 8) {
                                                    Text("•")
                                                        .foregroundStyle(.green)
                                                    Text(paragraph.dropFirst())
                                                        .font(.body)
                                                }
                                            } else if paragraph.hasPrefix("👉") {
                                                // 强调项
                                                HStack(alignment: .top, spacing: 8) {
                                                    Text("👉")
                                                    Text(paragraph.dropFirst(2))
                                                        .font(.body)
                                                        .fontWeight(.medium)
                                                }
                                            } else {
                                                // 普通段落
                                                Text(paragraph)
                                                    .font(.body)
                                                    .lineSpacing(6)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 400)
                            }
                            .padding()
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("吐槽大会")
                        .font(.headline)
                        .foregroundStyle(.red)
                }
            }
        }
    }
    
    // MARK: - Header Banner
    private var headerBanner: some View {
        VStack(spacing: 12) {
            // 渐变标签
            HStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .font(.caption)
                Text("被骂一顿")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.red.opacity(0.9), Color.orange.opacity(0.9)]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .foregroundStyle(.white)
            
            Text("专治各种不服")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.red, Color.orange]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            
            Text("让草包用毒舌的方式，狠狠吐槽你一顿")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
    
    // MARK: - Format Result
    /// 格式化吐槽结果
    private func formatResult(_ text: String) -> [String] {
        // 按换行分割
        var paragraphs = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        // 如果没有明显的分段，尝试按句号分割
        if paragraphs.count == 1 && paragraphs.first?.count ?? 0 > 100 {
            paragraphs = text.components(separatedBy: "。")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { $0 + "。" }
        }
        
        return paragraphs
    }
    
    // MARK: - Actions
    private func startRoast() {
        loading = true
        result = ""
        errorMessage = nil
        
        Task {
            do {
                let stream = try await APIService.shared.roast(content: content, intensity: intensity)
                
                for try await chunk in stream {
                    await MainActor.run {
                        result += chunk
                    }
                }
                
                await MainActor.run {
                    loading = false
                    if result.isEmpty {
                        errorMessage = "吐槽生成失败，请重试"
                    }
                }
            } catch {
                await MainActor.run {
                    loading = false
                    errorMessage = "吐槽失败: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func copyResult() {
        #if os(iOS)
        UIPasteboard.general.string = result
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}

// MARK: - Components
struct IntensityCard: View {
    let emoji: String
    let name: String
    let desc: String
    let isSelected: Bool
    var color: Color = .red
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(emoji)
                    .font(.title2)
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isSelected {
                        LinearGradient(
                            gradient: Gradient(colors: [color, color.opacity(0.7)]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    } else {
                        Color(.systemGray6)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: isSelected ? color.opacity(0.3) : .clear, radius: 4, y: 2)
        }
        .foregroundStyle(isSelected ? .white : .primary)
    }
}

#Preview {
    RoastView()
}
