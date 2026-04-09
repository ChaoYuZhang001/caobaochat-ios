import SwiftUI

// MARK: - Settings View (设置)
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("selectedModel") private var selectedModel = "qwen-plus"
    @AppStorage("colorScheme") private var colorScheme = "system"
    @AppStorage("toxicLevel") private var toxicLevel = "normal"
    @AppStorage("voiceEnabled") private var voiceEnabled = true
    
    // 模型列表 - 与后端保持一致
    private let models = [
        ("qwen-plus", "通义千问 Plus", "推荐，平衡性能与速度", "🚀"),
        ("qwen-turbo", "通义千问 Turbo", "快速响应，适合简单对话", "⚡"),
        ("deepseek-chat", "DeepSeek Chat", "深度思考，逻辑性强", "🧠"),
        ("kimi-32k", "Kimi", "长文本处理能力强", "📚"),
        ("grok-2-1212", "Grok 2", "马斯克出品，幽默毒舌", "🧪"),
    ]
    
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
                                // 同步到 appState 以保持联动
                                appState.userSettings.toxicLevel = level.0
                                appState.saveUserSettings()
                                print("🎯 切换毒舌程度: \(level.1)")
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
                        #if os(iOS)
                        .pickerStyle(.navigationLink)
                        #elseif os(macOS)
                        .pickerStyle(.automatic)
                        #endif
                        
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
