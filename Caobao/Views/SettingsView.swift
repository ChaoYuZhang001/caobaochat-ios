import SwiftUI

// MARK: - Settings View (设置)
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAssistantPreferences = false
    @AppStorage("colorScheme") private var colorScheme = "system"
    
    // 毒舌程度 - 与后端保持一致
    private let toxicLevels = [
        ("light", "温和", "温柔提醒，点到为止", "🌸"),
        ("normal", "标准", "一针见血，恰到好处", "🎯"),
        ("fierce", "爆辣", "直击灵魂，不留情面", "🔥"),
    ]
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 渐变背景 - 绿色系（代表效率与智能）
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(hex: "22c55e").opacity(0.08),
                        Color(hex: "16a34a").opacity(0.05),
                        Color.caobaoGroupedBackground
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                List {
                    // Account preferences are server-owned. Present the
                    // shared assistant settings flow so macOS and iOS use
                    // the same GET/PATCH contract and validation.
                    Section {
                        Button {
                            showAssistantPreferences = true
                        } label: {
                            Label("助理账号偏好", systemImage: "slider.horizontal.3")
                        }
                        Text("服务区域、平台模型和自定义 API 统一在助理设置中管理，首页会同步当前选择。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("助理")
                    }
                    
                    // 毒舌程度
                    Section {
                        ForEach(toxicLevels, id: \.0) { level in
                            Button {
                                appState.userSettings.toxicLevel = level.0
                                appState.saveUserSettings()
                            } label: {
                                HStack {
                                    Text(level.3)
                                        .font(.title2)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(level.1)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        
                                        Text(level.2)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    if appState.userSettings.toxicLevel == level.0 {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                        }
                    } header: {
                        Text("毒舌程度")
                    }
                    
                    // 外观设置
                    Section {
                        Picker("主题", selection: $colorScheme) {
                            Text("跟随系统").tag("system")
                            Text("浅色模式").tag("light")
                            Text("深色模式").tag("dark")
                        }
                        #if os(iOS)
                        .pickerStyle(.navigationLink)
                        #elseif os(macOS)
                        .pickerStyle(.automatic)
                        #endif
                        
                        Text("语音输入和朗读在对话页按需使用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("外观")
                    }
                    
                    // 关于
                    Section {
                        HStack {
                            Text("版本")
                            Spacer()
                            Text("1.0.0")
                                .foregroundStyle(.secondary)
                        }
                        
                        NavigationLink {
                            AIDeclarationView()
                        } label: {
                            HStack {
                                Image(systemName: "cpu")
                                    .foregroundStyle(.purple)
                                    .frame(width: 24)
                                Text("AI 使用声明")
                            }
                        }
                        
                        NavigationLink {
                            LegalView(type: .privacy)
                        } label: {
                            HStack {
                                Image(systemName: "hand.raised.fill")
                                    .foregroundStyle(.green)
                                    .frame(width: 24)
                                Text("隐私政策")
                            }
                        }
                        
                        NavigationLink {
                            LegalView(type: .agreement)
                        } label: {
                            HStack {
                                Image(systemName: "doc.text.fill")
                                    .foregroundStyle(.green)
                                    .frame(width: 24)
                                Text("用户协议")
                            }
                        }
                        
                        NavigationLink {
                            LegalView(type: .children)
                        } label: {
                            HStack {
                                Image(systemName: "figure.and.child.holdinghands")
                                    .foregroundStyle(.green)
                                    .frame(width: 24)
                                Text("未成年人保护")
                            }
                        }
                    } header: {
                        Text("关于")
                    }
                }
            }
            .navigationTitle("设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .preferredColorScheme(
                colorScheme == "dark" ? .dark : 
                colorScheme == "light" ? .light : nil
            )
            .sheet(isPresented: $showAssistantPreferences) {
                AssistantSettingsSheet()
                    .environmentObject(appState)
            }
        }
    }
}

// MARK: - App Storage Extension
extension UserDefaults {
    static var appGroup: UserDefaults {
        UserDefaults.standard
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
