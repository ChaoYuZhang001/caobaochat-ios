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
        ("sharp", "犀利毒舌", "🔥", "一针见血", Color.red, Color.orange),
        ("gentle", "温和吐槽", "🌸", "温柔一刀", Color.pink, Color.red),
        ("funny", "搞笑调侃", "🎭", "笑中带刀", Color.purple, Color.indigo),
    ]
    
    private var selectedStyleColors: (Color, Color) {
        styles.first { $0.0 == style }.map { ($0.4, $0.5) } ?? (.blue, .cyan)
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 渐变背景
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.blue.opacity(0.2),
                        Color.cyan.opacity(0.15),
                        Color.teal.opacity(0.1),
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
                        
                        // 风格选择
                        VStack(alignment: .leading, spacing: 12) {
                            Text("昵称风格")
                                .font(.headline)
                            
                            HStack(spacing: 12) {
                                ForEach(styles, id: \.0) { s in
                                    StyleCard(
                                        emoji: s.2,
                                        name: s.1,
                                        desc: s.3,
                                        isSelected: style == s.0,
                                        gradient: (s.4, s.5)
                                    ) {
                                        style = s.0
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        // 特点选择
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                Text("快速选择特点")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                            ], spacing: 8) {
                                ForEach(traits, id: \.self) { trait in
                                    TraitChip(
                                        trait: trait,
                                        isSelected: selectedTraits.contains(trait),
                                        color: selectedStyleColors.0
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
                                    .foregroundStyle(selectedStyleColors.0)
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
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
                            .background(
                                LinearGradient(
                                    gradient: Gradient(colors: [selectedStyleColors.0, selectedStyleColors.1]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
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
                                        gradient: (selectedStyleColors.0, selectedStyleColors.1),
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
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("个性昵称")
                        .font(.headline)
                        .foregroundStyle(.blue)
                }
            }
        }
    }
    
    // MARK: - Header Banner
    private var headerBanner: some View {
        VStack(spacing: 12) {
            // 渐变标签
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.caption)
                Text("个性昵称")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.blue.opacity(0.9), Color.cyan.opacity(0.9)]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .foregroundStyle(.white)
            
            Text("给你起个名")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.blue, Color.cyan]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            
            Text("让草包给你起一个有创意的个性昵称")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
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
    var color: Color = .blue
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(trait)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? color : Color(.systemGray5))
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
    var gradient: (Color, Color) = (.blue, .cyan)
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
                    .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                Group {
                    if isSelected {
                        LinearGradient(
                            gradient: Gradient(colors: [gradient.0, gradient.1]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    } else {
                        Color(.systemGray6)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: isSelected ? gradient.0.opacity(0.3) : .clear, radius: 4, y: 2)
        }
        .foregroundStyle(isSelected ? .white : .primary)
    }
}

struct NicknameCard: View {
    let nickname: NicknameItem
    let index: Int
    let copied: Bool
    var gradient: (Color, Color) = (.blue, .cyan)
    let onCopy: () -> Void
    
    var body: some View {
        HStack {
            Text("\(index)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [gradient.0, gradient.1]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
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
