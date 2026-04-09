import SwiftUI

// MARK: - Decision View (决策助手)
struct DecisionView: View {
    @State private var question = ""
    @State private var options: [String] = ["", ""]
    @State private var loading = false
    @State private var result: DecisionResult?
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 蓝紫渐变背景
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(hex: "667eea"),
                        Color(hex: "764ba2")
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // 头部Banner
                        VStack(spacing: 16) {
                            // 渐变标签
                            Text("纠结终结者")
                                .font(.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            Color.white.opacity(0.3),
                                            Color.white.opacity(0.1)
                                        ]),
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                            
                            // 大标题
                            Text("选择困难？")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            
                            // 副标题
                            Text("帮你做出最不后悔的决定")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        
                        // 问题输入
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "questionmark.circle.fill")
                                    .foregroundStyle(Color(hex: "667eea"))
                                Text("你的问题")
                                    .font(.headline)
                            }
                            
                            TextField("今天中午吃什么？", text: $question)
                                .textFieldStyle(.roundedBorder)
                                .focused($isInputFocused)
                                .onSubmit {
                                    makeDecision()
                                }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        // 选项输入
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("选项（可选）")
                                    .font(.headline)
                                
                                Spacer()
                                
                                Button {
                                    if options.count < 6 {
                                        options.append("")
                                    }
                                } label: {
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(Color(hex: "667eea"))
                                }
                            }
                            
                            ForEach(Array(options.enumerated()), id: \.offset) { index, _ in
                                HStack {
                                    Text("\(index + 1)")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundStyle(.white)
                                        .frame(width: 20, height: 20)
                                        .background(Color(hex: "667eea"))
                                        .clipShape(Circle())
                                    
                                    TextField("选项 \(index + 1)", text: $options[index])
                                        .textFieldStyle(.roundedBorder)
                                    
                                    if options.count > 2 {
                                        Button {
                                            options.remove(at: index)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        // 决策按钮
                        Button {
                            makeDecision()
                        } label: {
                            HStack {
                                if loading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "hand.tap.fill")
                                }
                                Text(loading ? "决策中..." : "帮我决定")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color(hex: "667eea"),
                                        Color(hex: "764ba2")
                                    ]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(loading || question.isEmpty)
                        .opacity(question.isEmpty ? 0.5 : 1)
                        
                        // 结果展示
                        if let result = result {
                            ResultCard(result: result)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("选择困难")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
    
    // MARK: - Actions
    private func makeDecision() {
        // 验证问题不为空
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        
        // 收缩键盘
        isInputFocused = false
        loading = true
        
        let validOptions = options.filter { !$0.isEmpty }
        let optionsToSend = validOptions.isEmpty ? nil : validOptions
        
        Task {
            do {
                let response = try await APIService.shared.makeDecision(
                    question: question,
                    options: optionsToSend
                )
                await MainActor.run {
                    if response.success, let decision = response.decision {
                        result = DecisionResult(
                            decision: decision,
                            reason: response.reasoning ?? response.finalAdvice ?? "",
                            warnings: response.warning != nil ? [response.warning!] : nil,
                            alternatives: nil,
                            finalWord: response.finalAdvice
                        )
                    } else if let error = response.error {
                        // 显示错误提示
                        print("决策错误: \(error)")
                    }
                    loading = false
                }
            } catch {
                await MainActor.run {
                    loading = false
                    print("决策请求失败: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Components
struct ResultCard: View {
    let result: DecisionResult
    @State private var copied = false
    
    var body: some View {
        VStack(spacing: 16) {
            // 决策结果
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                
                Text("草包的决定")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text(result.decision)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical)
            
            Divider()
            
            // 理由
            VStack(alignment: .leading, spacing: 8) {
                Text("毒舌理由")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Text(result.reason)
                    .font(.body)
                    .lineSpacing(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // 警告
            if let warnings = result.warnings, !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("需要注意", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    
                    ForEach(warnings, id: \.self) { warning in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                            Text(warning)
                                .font(.subheadline)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            
            // 备选方案
            if let alternatives = result.alternatives, !alternatives.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("备选方案", systemImage: "lightbulb.fill")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                    
                    ForEach(alternatives, id: \.self) { alt in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                            Text(alt)
                                .font(.subheadline)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            
            // 金句
            if let finalWord = result.finalWord, !finalWord.isEmpty {
                VStack(spacing: 8) {
                    Divider()
                    Text("🎯 \(finalWord)")
                        .font(.body)
                        .fontWeight(.medium)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                        .padding(.vertical, 8)
                }
            }
            
            // 复制按钮
            Button {
                var textToCopy = "\(result.decision)\n\n理由：\(result.reason)"
                if let warnings = result.warnings, !warnings.isEmpty {
                    textToCopy += "\n\n需要注意：\n" + warnings.map { "• \($0)" }.joined(separator: "\n")
                }
                if let finalWord = result.finalWord {
                    textToCopy += "\n\n🎯 \(finalWord)"
                }
                #if os(iOS)
                UIPasteboard.general.string = textToCopy
                #elseif os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(textToCopy, forType: .string)
                #endif
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copied = false
                }
            } label: {
                HStack {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "已复制" : "复制结果")
                }
                .font(.subheadline)
                .foregroundStyle(.green)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Model
struct DecisionResult {
    let decision: String
    let reason: String
    let warnings: [String]?
    let alternatives: [String]?
    let finalWord: String?
}

#Preview {
    DecisionView()
}
