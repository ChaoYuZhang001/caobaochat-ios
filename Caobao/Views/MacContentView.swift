import SwiftUI

#if os(macOS)
import AppKit

// MARK: - Mac Content View (三栏布局)
struct MacContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var chatViewModel = ChatViewModel()
    @State private var selectedFeature: MacFeature = .chat
    @State private var selectedConversation: Conversation?
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 左侧边栏 - 功能导航
            MacSidebarView(
                selectedFeature: $selectedFeature,
                selectedConversation: $selectedConversation,
                conversations: chatViewModel.conversations
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            // 右侧内容区
            MacDetailView(
                selectedFeature: selectedFeature,
                conversation: selectedConversation,
                chatViewModel: chatViewModel
            )
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    NotificationCenter.default.post(name: .newChat, object: nil)
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                }
                
                Spacer()
                
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gear")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .frame(width: 500, height: 600)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChat)) { _ in
            selectedConversation = nil
            selectedFeature = .chat
        }
        .task {
            // 登录后自动同步云端数据
            if AuthService.shared.isLoggedIn {
                await chatViewModel.syncFromCloud()
            }
        }
    }
}

// MARK: - Mac Feature Enum
enum MacFeature: String, CaseIterable, Identifiable {
    case chat = "自由对话"
    case fortune = "今日运势"
    case analyze = "文件秒懂"
    case quote = "扎心金句"
    case roast = "毒舌吐槽"
    case nickname = "个性昵称"
    case rate = "犀利评分"
    case decision = "决策助手"
    case morningReport = "早报"
    case eveningReport = "晚报"
    case favorites = "收藏"
    case history = "历史"
    case profile = "我的"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .chat: return "message.fill"
        case .fortune: return "star.fill"
        case .analyze: return "photo.fill"
        case .quote: return "quote.bubble.fill"
        case .roast: return "flame.fill"
        case .nickname: return "person.crop.circle.badge.plus"
        case .rate: return "star.leadinghalf.filled"
        case .decision: return "questionmark.circle.fill"
        case .morningReport: return "sun.max.fill"
        case .eveningReport: return "moon.fill"
        case .favorites: return "heart.fill"
        case .history: return "clock.fill"
        case .profile: return "person.fill"
        }
    }
    
    var iconColor: Color {
        switch self {
        case .chat: return .green
        case .fortune: return .orange
        case .analyze: return .blue
        case .quote: return .purple
        case .roast: return .red
        case .nickname: return .pink
        case .rate: return .yellow
        case .decision: return .cyan
        case .morningReport: return .orange
        case .eveningReport: return .indigo
        case .favorites: return .red
        case .history: return .gray
        case .profile: return .green
        }
    }
}

// MARK: - Mac Sidebar View
struct MacSidebarView: View {
    @Binding var selectedFeature: MacFeature
    @Binding var selectedConversation: Conversation?
    let conversations: [Conversation]
    
    var body: some View {
        ZStack {
            // 渐变背景 - 温暖的橙黄渐变
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(hex: "fbbf24").opacity(0.1),
                    Color(hex: "f59e0b").opacity(0.05),
                    Color.caobaoGroupedBackground
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            List {
            // 核心功能
            Section("核心功能") {
                ForEach([MacFeature.chat, .fortune, .analyze]) { feature in
                    MacFeatureRow(feature: feature, isSelected: selectedFeature == feature)
                        .onTapGesture {
                            selectedFeature = feature
                            selectedConversation = nil
                        }
                }
            }
            
            // 毒舌特色
            Section("毒舌特色") {
                ForEach([MacFeature.quote, .roast, .nickname, .rate]) { feature in
                    MacFeatureRow(feature: feature, isSelected: selectedFeature == feature)
                        .onTapGesture {
                            selectedFeature = feature
                            selectedConversation = nil
                        }
                }
            }
            
            // 智能助手
            Section("智能助手") {
                ForEach([MacFeature.decision, .morningReport, .eveningReport]) { feature in
                    MacFeatureRow(feature: feature, isSelected: selectedFeature == feature)
                        .onTapGesture {
                            selectedFeature = feature
                            selectedConversation = nil
                        }
                }
            }
            
            // 其他
            Section("其他") {
                ForEach([MacFeature.favorites, .history, .profile]) { feature in
                    MacFeatureRow(feature: feature, isSelected: selectedFeature == feature)
                        .onTapGesture {
                            selectedFeature = feature
                            selectedConversation = nil
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("草包")
        }
    }
}

// MARK: - Mac Feature Row
struct MacFeatureRow: View {
    let feature: MacFeature
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: feature.icon)
                .foregroundStyle(feature.iconColor)
                .frame(width: 20)
            
            Text(feature.rawValue)
                .font(.body)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(6)
    }
}

// MARK: - Mac Detail View
struct MacDetailView: View {
    let selectedFeature: MacFeature
    let conversation: Conversation?
    @ObservedObject var chatViewModel: ChatViewModel
    
    var body: some View {
        Group {
            switch selectedFeature {
            case .chat:
                ChatView()
            case .fortune:
                FortuneView()
            case .analyze:
                AnalyzeView()
            case .quote:
                QuoteView()
            case .roast:
                RoastView()
            case .nickname:
                NicknameView()
            case .rate:
                RateView()
            case .decision:
                DecisionView()
            case .morningReport:
                MorningReportView()
            case .eveningReport:
                EveningReportView()
            case .favorites:
                FavoritesView()
            case .history:
                HistoryView()
            case .profile:
                ProfileView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview
#Preview {
    MacContentView()
        .environmentObject(AppState())
        .frame(width: 1000, height: 700)
}
#endif
