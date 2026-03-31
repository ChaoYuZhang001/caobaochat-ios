import SwiftUI

// MARK: - Settings View (设置)
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("selectedModel") private var selectedModel = "doubao-pro-32k"
    @AppStorage("colorScheme") private var colorScheme = "system"
    @AppStorage("toxicLevel") private var toxicLevel = "normal"
    @AppStorage("voiceEnabled") private var voiceEnabled = true
    
    private let models = [
        ("doubao-pro-32k", "豆包 Pro", "推荐，平衡性能与速度", "🚀"),
        ("doubao-lite-32k", "豆包 Lite", "快速响应，适合简单对话", "⚡"),
        ("deepseek-chat", "DeepSeek", "深度思考，逻辑性强", "🧠"),
        ("kimi", "Kimi", "长文本处理能力强", "📚"),
    ]
    
    private let toxicLevels = [
        ("light", "温和", "温柔提醒，点到为止", "🌸"),
        ("normal", "标准", "一针见血，恰到好处", "🎯"),
        ("heavy", "爆辣", "直击灵魂，不留情面", "🔥"),
    ]
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.caobaoGroupedBackground
                
                List {
                    // 模型选择
                    Section {
                        ForEach(models, id: \.0) { model in
                            Button {
                                selectedModel = model.0
                            } label: {
                                HStack {
                                    Text(model.3)
                                        .font(.title2)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.1)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        
                                        Text(model.2)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    if selectedModel == model.0 {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                        }
                    } header: {
                        Text("AI 模型")
                    }
                    
                    // 毒舌程度
                    Section {
                        ForEach(toxicLevels, id: \.0) { level in
                            Button {
                                toxicLevel = level.0
                                // 同步更新 AppState
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
                                    
                                    if toxicLevel == level.0 {
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
                        .pickerStyle(.navigationLink)
                        
                        Toggle("语音播报", isOn: $voiceEnabled)
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
