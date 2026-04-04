import SwiftUI

// MARK: - Nickname View (毒舌昵称)
struct NicknameView: View {
    @State private var name = ""
    @State private var selectedTraits: Set<String> = []
    @State private var customTrait = ""
    @State private var style = "sharp"
    @State private var loading = false
    @State private var result: [NicknameItem]?
    @State private var copied: Int? = nil
    
    private let traits = [
        "总是拖延", "爱玩手机", "夜猫子", "吃货", "社恐",
        "爱发呆", "强迫症", "选择困难", "容易焦虑", "佛系青年",
    ]
    
    private let styles = [
        ("sharp", "犀利毒舌", "🔥", "一针见血"),
        ("gentle", "温和吐槽", "🌸", "温柔一刀"),
        ("funny", "搞笑调侃", "🎭", "笑中带刀"),
    ]
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.caobaoGroupedBackground
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // 名字输入
                        VStack(alignment: .leading, spacing: 12) {
                            Text("你的名字")
                                .font(.headline)
                            
                            TextField("输入名字（可选）", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        // 特点选择
                        VStack(alignment: .leading, spacing: 12) {
                            Text("你的特点")
                                .font(.headline)
                            
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                            ], spacing: 12) {
                                ForEach(traits, id: \.self) { trait in
                                    TraitChip(
                                        trait: trait,
                                        isSelected: selectedTraits.contains(trait)
                                    ) {
                                        if selectedTraits.contains(trait) {
                                            selectedTraits.remove(trait)
                                        } else {
                                            selectedTraits.insert(trait)
                                        }
                                    }
                                }
                            }
                            
                            // 自定义特点
                            HStack {
                                TextField("自定义特点...", text: $customTrait)
                                    .textFieldStyle(.roundedBorder)
                                
                                if !customTrait.isEmpty {
                                    Button("添加") {
                                        selectedTraits.insert(customTrait)
                                        customTrait = ""
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        // 风格选择
                        VStack(alignment: .leading, spacing: 12) {
                            Text("昵称风格")
                                .font(.headline)
                            
                            HStack(spacing: 12) {
                                ForEach(styles, id: \.0) { s in
                                    StyleCard(
                                        emoji: s.1,
                                        name: s.2,
                                        desc: s.3,
                                        isSelected: style == s.0
                                    ) {
                                        style = s.0
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        // 生成按钮
                        Button {
                            generateNickname()
                        } label: {
                            HStack {
                                if loading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "wand.and.stars")
                                }
                                Text(loading ? "生成中..." : "生成毒舌昵称")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(loading || (name.isEmpty && selectedTraits.isEmpty))
                        .opacity((name.isEmpty && selectedTraits.isEmpty) ? 0.5 : 1)
                        
                        // 结果展示
                        if let nicknames = result {
                            VStack(spacing: 16) {
                                Text("为你生成的毒舌昵称")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                
                                ForEach(Array(nicknames.enumerated()), id: \.element.name) { index, item in
                                    NicknameCard(
                                        nickname: item,
                                        index: index + 1,
                                        copied: copied == index,
                                        onCopy: {
                                            copyToClipboard(item.name, index: index)
                                        }
                                    )
                                }
                            }
                            .padding()
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("毒舌昵称")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
    
    // MARK: - Actions
    private func generateNickname() {
        loading = true
        let traitsStr = selectedTraits.joined(separator: "、")
        
        Task {
            do {
                let response = try await APIService.shared.generateNickname(
                    name: name,
                    traits: traitsStr,
                    style: style
                )
                await MainActor.run {
                    if response.success, let nicknames = response.nicknames {
                        result = nicknames
                    } else {
                        // 显示后端返回的错误信息
                        let errorMsg = response.error ?? "生成失败，请重试"
                        print("❌ 昵称生成失败: \(errorMsg)")
                    }
                    loading = false
                }
            } catch {
                await MainActor.run {
                    loading = false
                    print("❌ 昵称生成异常: \(error.localizedDescription)")
                    // 可以添加 alert 或 toast 提示用户
                }
            }
        }
    }
    
    private func copyToClipboard(_ text: String, index: Int) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = nil
        }
    }
}

// MARK: - Components
struct TraitChip: View {
    let trait: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(trait)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.green : Color(.systemGray5))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
    }
}

struct StyleCard: View {
    let emoji: String
    let name: String
    let desc: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(emoji)
                    .font(.title)
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isSelected ? Color.green.opacity(0.15) : Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.green : Color.clear, lineWidth: 2)
            )
        }
        .foregroundStyle(.primary)
    }
}

struct NicknameCard: View {
    let nickname: NicknameItem
    let index: Int
    let copied: Bool
    let onCopy: () -> Void
    
    var body: some View {
        HStack {
            Text("\(index)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.green)
                .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 4) {
                Text(nickname.name)
                    .font(.headline)
                
                Text(nickname.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(action: onCopy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : .secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// NicknameItem 已移至 Models/NicknameData.swift

#Preview {
    NicknameView()
}
