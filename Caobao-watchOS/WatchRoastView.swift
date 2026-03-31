import SwiftUI

// MARK: - Watch Roast View
struct WatchRoastView: View {
    @EnvironmentObject var appState: WatchAppState
    @State private var roastContent: String = ""
    @State private var isLoading = false
    @State private var roastType: RoastType = .random
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // 类型选择
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RoastType.allCases) { type in
                            Button {
                                roastType = type
                                loadRoast()
                            } label: {
                                Text(type.rawValue)
                                    .font(.caption2)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(roastType == type ? Color.green : Color.gray.opacity(0.2))
                                    .foregroundStyle(roastType == type ? .white : .primary)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                
                Divider()
                
                // 毒舌内容
                if roastContent.isEmpty {
                    placeholder
                } else {
                    roastContent
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.green.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    
                    Button {
                        loadRoast()
                    } label: {
                        Label("再来一句", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .navigationTitle("毒舌")
        .task {
            if roastContent.isEmpty {
                loadRoast()
            }
        }
    }
    
    private var placeholder: some View {
        VStack(spacing: 16) {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.8)
                Text("生成中...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "flame.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange.opacity(0.5))
                
                Text("需要一点毒舌？")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Button {
                    loadRoast()
                } label: {
                    Text("开始毒舌")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func loadRoast() {
        isLoading = true
        
        Task {
            do {
                let response = try await WatchAPIService.shared.getRoast(type: roastType.apiType)
                await MainActor.run {
                    self.roastContent = response.content ?? ""
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.roastContent = "生成失败，请重试"
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Roast Type
enum RoastType: String, CaseIterable, Identifiable {
    case random = "随机"
    case love = "情话"
    case motivational = "毒鸡汤"
    case savage = "扎心"
    
    var id: String { rawValue }
    
    var apiType: String {
        switch self {
        case .random: return "random"
        case .love: return "love"
        case .motivational: return "motivational"
        case .savage: return "savage"
        }
    }
}

#Preview {
    NavigationStack {
        WatchRoastView()
            .environmentObject(WatchAppState())
    }
}
