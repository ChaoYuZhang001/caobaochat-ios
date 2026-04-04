//
//  DynamicIslandManager.swift
//  草包 - Dynamic Island适配
//
//  为iPhone 14 Pro及更新机型提供Dynamic Island支持
//

import SwiftUI
import ActivityKit

#if canImport(ActivityKit)
import ActivityKit
#endif

// MARK: - Dynamic Island活动状态

/// Dynamic Island活动状态
@available(iOS 16.1, *)
struct DynamicIslandAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var message: String
        var isProcessing: Bool
        var progress: Double
    }
    
    var title: String
}

// MARK: - Dynamic Island管理器

/// Dynamic Island管理器
@available(iOS 16.1, *)
class DynamicIslandManager: ObservableObject {
    @Published var currentActivity: Activity<DynamicIslandAttributes>?
    
    // MARK: - 开始活动
    
    /// 开始一个新的Dynamic Island活动
    /// - Parameters:
    ///   - title: 标题
    ///   - message: 消息内容
    ///   - isProcessing: 是否正在处理
    func startActivity(title: String, message: String, isProcessing: Bool = true) {
        let attributes = DynamicIslandAttributes(title: title)
        let initialState = DynamicIslandAttributes.ContentState(
            message: message,
            isProcessing: isProcessing,
            progress: 0.0
        )
        
        let activityContent = ActivityContent(
            state: initialState,
            staleDate: nil
        )
        
        // 创建活动
        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: activityContent,
                pushType: nil
            )
        } catch {
            print("Failed to start activity: \(error)")
        }
    }
    
    // MARK: - 更新活动
    
    /// 更新Dynamic Island活动内容
    /// - Parameters:
    ///   - message: 新的消息内容
    ///   - isProcessing: 是否正在处理
    ///   - progress: 进度 (0.0 - 1.0)
    func updateActivity(message: String, isProcessing: Bool, progress: Double = 0.0) {
        guard let activity = currentActivity else { return }
        
        let updatedState = DynamicIslandAttributes.ContentState(
            message: message,
            isProcessing: isProcessing,
            progress: progress
        )
        
        Task {
            await activity.update(
                ActivityContent(
                    state: updatedState,
                    staleDate: nil
                )
            )
        }
    }
    
    // MARK: - 结束活动
    
    /// 结束当前的Dynamic Island活动
    func endActivity() {
        Task {
            await currentActivity?.end(nil, dismissalPolicy: .immediate)
            currentActivity = nil
        }
    }
    
    // MARK: - 预定义场景
    
    /// AI对话场景
    func startChatActivity() {
        startActivity(
            title: "草包AI",
            message: "正在思考中...",
            isProcessing: true
        )
    }
    
    /// 更新对话内容
    func updateChatActivity(message: String) {
        updateActivity(message: message, isProcessing: false)
    }
    
    /// 运势生成场景
    func startFortuneActivity() {
        startActivity(
            title: "今日运势",
            message: "正在为你算卦...",
            isProcessing: true
        )
    }
    
    /// 图片分析场景
    func startImageAnalysisActivity() {
        startActivity(
            title: "图片分析",
            message: "正在分析图片...",
            isProcessing: true
        )
    }
}

// MARK: - Dynamic Island视图扩展

@available(iOS 16.1, *)
extension View {
    /// Dynamic Island紧凑模式
    func dynamicIslandCompact(title: String, message: String) -> some View {
        self.overlay {
            if #available(iOS 16.2, *) {
                DynamicIsland {
                    // 展开模式
                    DynamicIslandExpandedRegion(.leading) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                                .font(.headline)
                            Text(message)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    DynamicIslandExpandedRegion(.trailing) {
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundStyle(.blue)
                    }
                } compactLeading: {
                    // 紧凑模式 - 左侧
                    Image(systemName: "sparkles")
                        .foregroundStyle(.blue)
                } compactTrailing: {
                    // 紧凑模式 - 右侧
                    Text(title)
                        .font(.caption)
                } minimal: {
                    // 最小模式
                    Image(systemName: "sparkles")
                        .foregroundStyle(.blue)
                }
            }
        }
    }
}

// MARK: - Live Activity UI配置

#if canImport(ActivityKit) && canImport(WidgetKit)
import WidgetKit

@available(iOS 16.1, *)
struct CaobaoLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DynamicIslandAttributes.self) { context in
            // 锁屏/通知中心视图
            HStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 40)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.title)
                        .font(.headline)
                    Text(context.state.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    if context.state.isProcessing {
                        ProgressView(value: context.state.progress)
                            .progressViewStyle(.linear)
                    }
                }
            }
            .padding()
        } dynamicIsland: { context in
            // Dynamic Island视图
            DynamicIsland {
                // 展开模式
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.title)
                            .font(.headline)
                        Text(context.state.message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        if context.state.isProcessing {
                            ProgressView(value: context.state.progress)
                                .progressViewStyle(.linear)
                        }
                    }
                }
                
                DynamicIslandExpandedRegion(.trailing) {
                    Button {
                        // 点击操作
                    } label: {
                        Image(systemName: context.state.isProcessing ? "stop.circle" : "play.circle")
                            .font(.title3)
                            .foregroundStyle(.blue)
                    }
                }
            } compactLeading: {
                // 紧凑模式 - 左侧
                Image(systemName: "sparkles")
                    .foregroundStyle(.blue)
            } compactTrailing: {
                // 紧凑模式 - 右侧
                if context.state.isProcessing {
                    ProgressView()
                        .tint(.blue)
                } else {
                    Text(context.attributes.title)
                        .font(.caption2)
                }
            } minimal: {
                // 最小模式
                Image(systemName: "sparkles")
                    .foregroundStyle(.blue)
            }
        }
    }
}
#endif

// MARK: - 使用示例

/*
// 在ViewModel中使用
class ChatViewModel: ObservableObject {
    @Published var isProcessing = false
    private let dynamicIslandManager = DynamicIslandManager()
    
    func sendMessage() {
        // 开始处理
        isProcessing = true
        if #available(iOS 16.1, *) {
            dynamicIslandManager.startChatActivity()
        }
        
        // API调用...
        
        // 更新状态
        if #available(iOS 16.1, *) {
            dynamicIslandManager.updateChatActivity(message: "草包：...")
        }
        
        // 完成后
        isProcessing = false
        if #available(iOS 16.1, *) {
            dynamicIslandManager.endActivity()
        }
    }
}

// 在View中使用
struct ChatView: View {
    var body: some View {
        // 内容
    }
    .onChange(of: viewModel.isProcessing) { newValue in
        if newValue {
            if #available(iOS 16.1, *) {
                dynamicIslandManager.startChatActivity()
            }
        } else {
            if #available(iOS 16.1, *) {
                dynamicIslandManager.endActivity()
            }
        }
    }
}
*/
