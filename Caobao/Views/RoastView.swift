import SwiftUI

// MARK: - Roast View (吐槽大会)
struct RoastView: View {
    @State private var content = ""
    @State private var intensity = "medium"
    @State private var loading = false
    @State private var result = ""
    @State private var copied = false
    
    private let intensities = [
        ("mild", "温和", "🌶️", "点到为止"),
        ("medium", "中等", "🌶️🌶️", "一针见血"),
        ("spicy", "爆辣", "🌶️🌶️🌶️", "直击灵魂"),
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
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // 吐槽内容
                        VStack(alignment: .leading, spacing: 12) {
                            Text("吐槽内容")
                                .font(.headline)
                            
                            TextEditor(text: $content)
                                .frame(minHeight: 120)
                                .padding(8)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color(.systemGray4), lineWidth: 1)
                                )
                            
                            // 快捷示例
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(quickExamples, id: \.self) { example in
                                        Button {
                                            content = example
                                        } label: {
                                            Text(example)
                                                .font(.caption)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(Color.green.opacity(0.1))
                                                .foregroundStyle(.green)
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
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
                                        isSelected: intensity == i.0
                                    ) {
                                        intensity = i.0
                                    }
                                }
                            }
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
                            .background(Color.red)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(loading || content.isEmpty)
                        .opacity(content.isEmpty ? 0.5 : 1)
                        
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
                                
                                ScrollView {
                                    Text(result)
                                        .font(.body)
                                        .lineSpacing(6)
                                }
                                .frame(maxHeight: 300)
                            }
                            .padding()
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("吐槽大会")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
    
    // MARK: - Actions
    private func startRoast() {
        loading = true
        result = ""
        
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
                }
            } catch {
                await MainActor.run {
                    loading = false
                    result = "吐槽失败，请重试"
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
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? Color.red.opacity(0.15) : Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.red : Color.clear, lineWidth: 2)
            )
        }
        .foregroundStyle(.primary)
    }
}

#Preview {
    RoastView()
}
