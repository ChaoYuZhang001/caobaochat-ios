//
//  SiriIntents.swift
//  草包 - Siri快捷指令
//
//  支持通过Siri快速调用草包AI功能
//

import Intents
import IntentsUI
import SwiftUI

// MARK: - 查询运势Intent

/// 查询今日运势Intent
@available(iOS 12.0, *)
class CheckFortuneIntent: INIntent {
    
}

@available(iOS 12.0, *)
class CheckFortuneIntentHandler: NSObject, INExtension, CheckFortuneIntentHandling {
    func handler(for intent: CheckFortuneIntent) -> Any {
        return self
    }
    
    func handle(intent: CheckFortuneIntent, completion: @escaping (CheckFortuneIntentResponse) -> Void) {
        // 调用运势API
        Task {
            do {
                let fortune = try await APIService.shared.getFortune()
                
                let response = CheckFortuneIntentResponse.success(
                    fortune: fortune.message,
                    date: Date()
                )
                completion(response)
            } catch {
                completion(CheckFortuneIntentResponse.failure(error: error.localizedDescription))
            }
        }
    }
    
    func confirm(intent: CheckFortuneIntent, completion: @escaping (CheckFortuneIntentResponse) -> Void) {
        completion(CheckFortuneIntentResponse.ready())
    }
}

// MARK: - 获取毒舌金句Intent

/// 获取毒舌金句Intent
@available(iOS 12.0, *)
class GetQuoteIntent: INIntent {
    
}

@available(iOS 12.0, *)
class GetQuoteIntentHandler: NSObject, INExtension, GetQuoteIntentHandling {
    func handler(for intent: GetQuoteIntent) -> Any {
        return self
    }
    
    func handle(intent: GetQuoteIntent, completion: @escaping (GetQuoteIntentResponse) -> Void) {
        // 调用金句API
        Task {
            do {
                let quote = try await APIService.shared.getQuote()
                
                let response = GetQuoteIntentResponse.success(
                    quote: quote.content,
                    author: "草包AI"
                )
                completion(response)
            } catch {
                completion(GetQuoteIntentResponse.failure(error: error.localizedDescription))
            }
        }
    }
    
    func confirm(intent: GetQuoteIntent, completion: @escaping (GetQuoteIntentResponse) -> Void) {
        completion(GetQuoteIntentResponse.ready())
    }
}

// MARK: - AI对话Intent

/// AI对话Intent
@available(iOS 12.0, *)
class ChatIntent: INIntent {
    @NSManaged public message: String?
}

@available(iOS 12.0, *)
class ChatIntentHandler: NSObject, INExtension, ChatIntentHandling {
    func handler(for intent: ChatIntent) -> Any {
        return self
    }
    
    func handle(intent: ChatIntent, completion: @escaping (ChatIntentResponse) -> Void) {
        guard let message = intent.message else {
            completion(ChatIntentResponse.failure(error: "消息不能为空"))
            return
        }
        
        // 调用对话API
        Task {
            do {
                let response = try await APIService.shared.sendMessage(message: message)
                
                let intentResponse = ChatIntentResponse.success(
                    response: response.content
                )
                completion(intentResponse)
            } catch {
                completion(ChatIntentResponse.failure(error: error.localizedDescription))
            }
        }
    }
    
    func confirm(intent: ChatIntent, completion: @escaping (ChatIntentResponse) -> Void) {
        completion(ChatIntentResponse.ready())
    }
}

// MARK: - 决策助手Intent

/// 决策助手Intent
@available(iOS 12.0, *)
class DecisionIntent: INIntent {
    @NSManaged public options: [String]?
}

@available(iOS 12.0, *)
class DecisionIntentHandler: NSObject, INExtension, DecisionIntentHandling {
    func handler(for intent: DecisionIntent) -> Any {
        return self
    }
    
    func handle(intent: DecisionIntent, completion: @escaping (DecisionIntentResponse) -> Void) {
        guard let options = intent.options, !options.isEmpty else {
            completion(DecisionIntentResponse.failure(error: "请提供选项"))
            return
        }
        
        // 调用决策API
        Task {
            do {
                let decision = try await APIService.shared.makeDecision(options: options)
                
                let response = DecisionIntentResponse.success(
                    choice: decision.choice,
                    reason: decision.reason
                )
                completion(response)
            } catch {
                completion(DecisionIntentResponse.failure(error: error.localizedDescription))
            }
        }
    }
    
    func confirm(intent: DecisionIntent, completion: @escaping (DecisionIntentResponse) -> Void) {
        completion(DecisionIntentResponse.ready())
    }
}

// MARK: - 吐槽Intent

/// 吐槽Intent
@available(iOS 12.0, *)
class RoastIntent: INIntent {
    @NSManaged public topic: String?
}

@available(iOS 12.0, *)
class RoastIntentHandler: NSObject, INExtension, RoastIntentHandling {
    func handler(for intent: RoastIntent) -> Any {
        return self
    }
    
    func handle(intent: RoastIntent, completion: @escaping (RoastIntentResponse) -> Void) {
        guard let topic = intent.topic else {
            completion(RoastIntentResponse.failure(error: "话题不能为空"))
            return
        }
        
        // 调用吐槽API
        Task {
            do {
                let roast = try await APIService.shared.roast(topic: topic)
                
                let response = RoastIntentResponse.success(
                    roast: roast.content
                )
                completion(response)
            } catch {
                completion(RoastIntentResponse.failure(error: error.localizedDescription))
            }
        }
    }
    
    func confirm(intent: RoastIntent, completion: @escaping (RoastIntentResponse) -> Void) {
        completion(RoastIntentResponse.ready())
    }
}

// MARK: - Siri快捷指令管理器

/// Siri快捷指令管理器
@available(iOS 12.0, *)
class SiriShortcutsManager: ObservableObject {
    static let shared = SiriShortcutsManager()
    
    private init() {}
    
    // MARK: - 查询运势
    
    /// 添加"查询运势"快捷指令
    func addCheckFortuneShortcut() {
        let intent = CheckFortuneIntent()
        let shortcut = INShortcut(intent: intent)
        
        INVoiceShortcutCenter.shared.setShortcut(shortcut) { error in
            if let error = error {
                print("Failed to add shortcut: \(error)")
            } else {
                print("Shortcut added successfully")
            }
        }
    }
    
    /// 查询运势
    func checkFortune() {
        let intent = CheckFortuneIntent()
        let shortcut = INShortcut(intent: intent)
        
        let voiceShortcut = INVoiceShortcut(shortcut: shortcut)
        
        let interaction = INInteraction(shortcut: shortcut)
        interaction.identifier = "check_fortune"
        
        interaction.donate { error in
            if let error = error {
                print("Donation failed: \(error)")
            }
        }
    }
    
    // MARK: - 获取金句
    
    /// 添加"获取金句"快捷指令
    func addGetQuoteShortcut() {
        let intent = GetQuoteIntent()
        let shortcut = INShortcut(intent: intent)
        
        INVoiceShortcutCenter.shared.setShortcut(shortcut) { error in
            if let error = error {
                print("Failed to add shortcut: \(error)")
            } else {
                print("Shortcut added successfully")
            }
        }
    }
    
    /// 获取金句
    func getQuote() {
        let intent = GetQuoteIntent()
        let shortcut = INShortcut(intent: intent)
        
        let interaction = INInteraction(shortcut: shortcut)
        interaction.identifier = "get_quote"
        
        interaction.donate { error in
            if let error = error {
                print("Donation failed: \(error)")
            }
        }
    }
    
    // MARK: - AI对话
    
    /// 添加"AI对话"快捷指令
    func addChatShortcut() {
        let intent = ChatIntent()
        intent.message = "你好"
        let shortcut = INShortcut(intent: intent)
        
        INVoiceShortcutCenter.shared.setShortcut(shortcut) { error in
            if let error = error {
                print("Failed to add shortcut: \(error)")
            } else {
                print("Shortcut added successfully")
            }
        }
    }
    
    /// 发送消息
    func sendMessage(_ message: String) {
        let intent = ChatIntent()
        intent.message = message
        let shortcut = INShortcut(intent: intent)
        
        let interaction = INInteraction(shortcut: shortcut)
        interaction.identifier = "chat_\(message.hashValue)"
        
        interaction.donate { error in
            if let error = error {
                print("Donation failed: \(error)")
            }
        }
    }
    
    // MARK: - 决策助手
    
    /// 添加"决策助手"快捷指令
    func addDecisionShortcut() {
        let intent = DecisionIntent()
        intent.options = ["选项A", "选项B"]
        let shortcut = INShortcut(intent: intent)
        
        INVoiceShortcutCenter.shared.setShortcut(shortcut) { error in
            if let error = error {
                print("Failed to add shortcut: \(error)")
            } else {
                print("Shortcut added successfully")
            }
        }
    }
    
    /// 做决策
    func makeDecision(options: [String]) {
        let intent = DecisionIntent()
        intent.options = options
        let shortcut = INShortcut(intent: intent)
        
        let interaction = INInteraction(shortcut: shortcut)
        interaction.identifier = "decision_\(options.joined().hashValue)"
        
        interaction.donate { error in
            if let error = error {
                print("Donation failed: \(error)")
            }
        }
    }
    
    // MARK: - 吐槽
    
    /// 添加"吐槽"快捷指令
    func addRoastShortcut() {
        let intent = RoastIntent()
        intent.topic = "今天"
        let shortcut = INShortcut(intent: intent)
        
        INVoiceShortcutCenter.shared.setShortcut(shortcut) { error in
            if let error = error {
                print("Failed to add shortcut: \(error)")
            } else {
                print("Shortcut added successfully")
            }
        }
    }
    
    /// 吐槽
    func roast(topic: String) {
        let intent = RoastIntent()
        intent.topic = topic
        let shortcut = INShortcut(intent: intent)
        
        let interaction = INInteraction(shortcut: shortcut)
        interaction.identifier = "roast_\(topic.hashValue)"
        
        interaction.donate { error in
            if let error = error {
                print("Donation failed: \(error)")
            }
        }
    }
    
    // MARK: - 捐赠所有快捷指令
    
    /// 捐赠所有快捷指令（让Siri学习用户习惯）
    func donateAllShortcuts() {
        checkFortune()
        getQuote()
        sendMessage("你好")
        makeDecision(options: ["吃饭", "睡觉"])
        roast(topic: "天气")
    }
}

// MARK: - Siri快捷指令设置视图

@available(iOS 14.0, *)
struct SiriShortcutsSettingsView: View {
    @EnvironmentObject var siriManager: SiriShortcutsManager
    @State private var showAddShortcut = false
    
    var body: some View {
        Form {
            Section("草包AI快捷指令") {
                ShortcutRow(
                    title: "查询今日运势",
                    subtitle: "让Siri帮你算一卦",
                    icon: "sparkles",
                    action: {
                        siriManager.addCheckFortuneShortcut()
                        showAddShortcut = true
                    }
                )
                
                ShortcutRow(
                    title: "获取毒舌金句",
                    subtitle: "来一句毒舌金句",
                    icon: "quote.bubble",
                    action: {
                        siriManager.addGetQuoteShortcut()
                        showAddShortcut = true
                    }
                )
                
                ShortcutRow(
                    title: "AI对话",
                    subtitle: "和草包AI聊聊",
                    icon: "message.fill",
                    action: {
                        siriManager.addChatShortcut()
                        showAddShortcut = true
                    }
                )
                
                ShortcutRow(
                    title: "决策助手",
                    subtitle: "纠结时帮你做决定",
                    icon: "target",
                    action: {
                        siriManager.addDecisionShortcut()
                        showAddShortcut = true
                    }
                )
                
                ShortcutRow(
                    title: "吐槽",
                    subtitle: "吐槽一下",
                    icon: "flame",
                    action: {
                        siriManager.addRoastShortcut()
                        showAddShortcut = true
                    }
                )
            }
            
            Section("使用说明") {
                Text("""
                添加快捷指令后，你可以这样说：
                
                • "Siri，查一下今日运势"
                • "Siri，来一句毒舌金句"
                • "Siri，用草包AI对话"
                • "Siri，帮我和草包做个决定"
                • "Siri，用草包吐槽一下"
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Siri快捷指令")
        .alert("快捷指令已添加", isPresented: $showAddShortcut) {
            Button("确定", role: .cancel) { }
        } message: {
            Text("你可以在设置 > Siri与搜索中管理这些快捷指令")
        }
        .onAppear {
            // 捐赠快捷指令，让Siri学习
            siriManager.donateAllShortcuts()
        }
    }
}

// MARK: - 快捷指令行

@available(iOS 14.0, *)
struct ShortcutRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: {
            HapticManager.light()
            action()
        }) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 32)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 使用示例

/*
// 在App启动时捐赠快捷指令
@main
struct CaobaoApp: App {
    @StateObject private var siriManager = SiriShortcutsManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(siriManager)
        }
    }
    .onAppear {
        // 捐赠快捷指令
        if #available(iOS 12.0, *) {
            siriManager.donateAllShortcuts()
        }
    }
}

// 用户执行操作时捐赠
class ChatViewModel: ObservableObject {
    @EnvironmentObject var siriManager: SiriShortcutsManager
    
    func sendMessage(_ message: String) {
        // 发送消息
        // ...
        
        // 捐赠快捷指令
        if #available(iOS 12.0, *) {
            siriManager.sendMessage(message)
        }
    }
}

// 在设置页面添加快捷指令
NavigationLink {
    if #available(iOS 14.0, *) {
        SiriShortcutsSettingsView()
            .environmentObject(siriManager)
    } else {
        Text("需要iOS 14.0及以上版本")
    }
} label: {
    Label("Siri快捷指令", systemImage: "mic.fill")
}
*/
