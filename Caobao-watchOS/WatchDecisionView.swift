import SwiftUI

// MARK: - Watch Decision View
struct WatchDecisionView: View {
    @EnvironmentObject var appState: WatchAppState
    @State private var optionA: String = ""
    @State private var optionB: String = ""
    @State private var decision: WatchDecision?
    @State private var isLoading = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let decision = decision {
                    decisionResult(decision)
                } else {
                    decisionInput
                }
            }
            .padding()
        }
        .navigationTitle("选择困难")
    }
    
    @ViewBuilder
    private var decisionInput: some View {
        Text("二选一")
            .font(.headline)
        
        // 选项 A
        VStack(alignment: .leading, spacing: 4) {
            Text("选项 A")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            TextField("第一个选项", text: $optionA)
                .textFieldStyle(.roundedBorder)
        }
        
        // 选项 B
        VStack(alignment: .leading, spacing: 4) {
            Text("选项 B")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            TextField("第二个选项", text: $optionB)
                .textFieldStyle(.roundedBorder)
        }
        
        Divider()
        
        Button {
            makeDecision()
        } label: {
            if isLoading {
                ProgressView()
            } else {
                Text("帮我决定")
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(optionA.isEmpty || optionB.isEmpty ? Color.gray : Color.green)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .disabled(optionA.isEmpty || optionB.isEmpty || isLoading)
        
        // 快速选项
        VStack(alignment: .leading, spacing: 6) {
            Text("快速选择")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            ForEach(QuickDecision.allCases) { quick in
                Button {
                    optionA = quick.optionA
                    optionB = quick.optionB
                } label: {
                    Text("\(quick.optionA) vs \(quick.optionB)")
                        .font(.caption2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
    
    @ViewBuilder
    private func decisionResult(_ decision: WatchDecision) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            
            Text("草包建议")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text(decision.choice)
                .font(.title3)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            
            Divider()
            
            Text(decision.reasoning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                self.decision = nil
                optionA = ""
                optionB = ""
            } label: {
                Text("再来一次")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private func makeDecision() {
        guard !optionA.isEmpty, !optionB.isEmpty else { return }
        
        isLoading = true
        
        Task {
            do {
                let response = try await WatchAPIService.shared.makeDecision(
                    question: "选择哪个",
                    options: [optionA, optionB]
                )
                await MainActor.run {
                    self.decision = WatchDecision(
                        choice: response.decision ?? optionA,
                        reasoning: response.reasoning ?? ""
                    )
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.decision = WatchDecision(
                        choice: optionA,
                        reasoning: "网络错误，随便选了一个"
                    )
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Quick Decision
enum QuickDecision: String, CaseIterable, Identifiable {
    case food = "美食"
    case movie = "电影"
    case work = "工作"
    case stay = "宅家"
    
    var id: String { rawValue }
    
    var optionA: String {
        switch self {
        case .food: return "火锅"
        case .movie: return "看电影"
        case .work: return "加班"
        case .stay: return "宅家"
        }
    }
    
    var optionB: String {
        switch self {
        case .food: return "烧烤"
        case .movie: return "逛街"
        case .work: return "摸鱼"
        case .stay: return "出门"
        }
    }
}

// MARK: - Watch Decision Model
struct WatchDecision {
    let choice: String
    let reasoning: String
}

#Preview {
    NavigationStack {
        WatchDecisionView()
            .environmentObject(WatchAppState())
    }
}
