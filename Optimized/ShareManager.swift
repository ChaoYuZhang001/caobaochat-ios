//
//  ShareManager.swift
//  草包 - 分享管理器
//
//  优化的分享功能，支持多种分享方式
//

import SwiftUI
import UIKit

// MARK: - 分享内容类型

/// 分享内容类型
enum ShareContentType {
    case text(String)
    case image(UIImage)
    case url(URL)
    case textWithImage(text: String, image: UIImage)
}

// MARK: - 分享管理器

/// 分享管理器
class ShareManager: ObservableObject {
    static let shared = ShareManager()
    
    private init() {}
    
    // MARK: - 分享内容
    
    /// 分享内容
    /// - Parameters:
    ///   - content: 分享内容
    ///   - sourceView: 来源视图（用于iPad显示分享菜单）
    func share(
        content: ShareContentType,
        sourceView: UIView? = nil,
        rect: CGRect? = nil
    ) {
        let items: [Any]
        
        switch content {
        case .text(let text):
            items = [text]
            
        case .image(let image):
            items = [image]
            
        case .url(let url):
            items = [url]
            
        case .textWithImage(let text, let image):
            items = [text, image]
        }
        
        let activityVC = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        
        // iPad支持
        if let sourceView = sourceView, let rect = rect {
            activityVC.popoverPresentationController?.sourceView = sourceView
            activityVC.popoverPresentationController?.sourceRect = rect
        }
        
        // 获取当前最顶层的ViewController
        if let rootVC = UIApplication.shared.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }
    
    // MARK: - 分享运势
    
    /// 分享运势
    func shareFortune(fortune: FortuneData, sourceView: UIView? = nil, rect: CGRect? = nil) {
        let text = """
        🌟 今日运势 🌟
        
        \(fortune.message)
        
        评分：\(fortune.score)/100
        建议：\(fortune.suggestion)
        
        来自草包AI - 犀利不刻薄 · 幽默有关怀 · 真实不虚伪
        """
        
        // 创建运势图片
        if let image = generateFortuneImage(fortune: fortune) {
            share(content: .textWithImage(text: text, image: image), sourceView: sourceView, rect: rect)
        } else {
            share(content: .text(text), sourceView: sourceView, rect: rect)
        }
    }
    
    // MARK: - 分享金句
    
    /// 分享金句
    func shareQuote(quote: Quote, sourceView: UIView? = nil, rect: CGRect? = nil) {
        let text = """
        💬 毒舌金句 💬
        
        "\(quote.content)"
        
        — 草包AI
        
        犀利不刻薄 · 幽默有关怀 · 真实不虚伪
        """
        
        // 创建金句图片
        if let image = generateQuoteImage(quote: quote) {
            share(content: .textWithImage(text: text, image: image), sourceView: sourceView, rect: rect)
        } else {
            share(content: .text(text), sourceView: sourceView, rect: rect)
        }
    }
    
    // MARK: - 分享对话
    
    /// 分享对话
    func shareConversation(messages: [Message], sourceView: UIView? = nil, rect: CGRect? = nil) {
        let text = messages.map { message in
            "\(message.isUser ? "我" : "草包"): \(message.content)"
        }.joined(separator: "\n\n")
        
        share(content: .text(text), sourceView: sourceView, rect: rect)
    }
    
    // MARK: - 分享到微信
    
    /// 分享到微信（需要集成微信SDK）
    func shareToWeChat(content: ShareContentType) {
        // 这里需要集成微信SDK
        // 示例代码：
        // let message = WXMediaMessage()
        // message.title = "草包AI"
        // message.description = "..."
        // 
        // let req = SendMessageToWXReq()
        // req.message = message
        // WXApi.send(req)
        
        print("分享到微信 - 需要集成微信SDK")
    }
    
    // MARK: - 生成运势图片
    
    private func generateFortuneImage(fortune: FortuneData) -> UIImage? {
        let size = CGSize(width: 400, height: 600)
        
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        defer { UIGraphicsEndImageContext() }
        
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
        // 背景
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                UIColor(hex: "#10B981").cgColor,
                UIColor(hex: "#059669").cgColor
            ] as CFArray,
            locations: [0.0, 1.0]
        )!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: size.width, y: size.height),
            options: []
        )
        
        // Logo
        let logo = UIImage(systemName: "sparkles")
        logo?.draw(at: CGPoint(x: size.width/2 - 30, y: 40), ofSize: CGSize(width: 60, height: 60))
        
        // 标题
        let title = "今日运势"
        (title as NSString).draw(
            in: CGRect(x: 20, y: 120, width: size.width - 40, height: 30),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 24, weight: .bold),
                .foregroundColor: UIColor.white
            ]
        )
        
        // 内容
        let contentRect = CGRect(x: 20, y: 170, width: size.width - 40, height: 200)
        fortune.message.draw(
            in: contentRect,
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor.white
            ],
            context: NSStringDrawingContext()
        )
        
        // 评分
        let scoreText = "评分：\(fortune.score)/100"
        (scoreText as NSString).draw(
            in: CGRect(x: 20, y: 390, width: size.width - 40, height: 25),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 16),
                .foregroundColor: UIColor.white.withAlphaComponent(0.8)
            ]
        )
        
        // 建议
        let suggestionRect = CGRect(x: 20, y: 430, width: size.width - 40, height: 100)
        fortune.suggestion.draw(
            in: suggestionRect,
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor.white.withAlphaComponent(0.7)
            ],
            context: NSStringDrawingContext()
        )
        
        // 底部
        let footer = "来自草包AI"
        (footer as NSString).draw(
            in: CGRect(x: 20, y: 550, width: size.width - 40, height: 20),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.white.withAlphaComponent(0.5)
            ]
        )
        
        return UIGraphicsGetImageFromCurrentImageContext()
    }
    
    // MARK: - 生成金句图片
    
    private func generateQuoteImage(quote: Quote) -> UIImage? {
        let size = CGSize(width: 400, height: 500)
        
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        defer { UIGraphicsEndImageContext() }
        
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        
        // 背景
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                UIColor(hex: "#F59E0B").cgColor,
                UIColor(hex: "#D97706").cgColor
            ] as CFArray,
            locations: [0.0, 1.0]
        )!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: size.width, y: size.height),
            options: []
        )
        
        // Logo
        let logo = UIImage(systemName: "quote.bubble.fill")
        logo?.draw(at: CGPoint(x: size.width/2 - 25, y: 40), ofSize: CGSize(width: 50, height: 50))
        
        // 标题
        let title = "毒舌金句"
        (title as NSString).draw(
            in: CGRect(x: 20, y: 110, width: size.width - 40, height: 30),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 20, weight: .bold),
                .foregroundColor: UIColor.white
            ]
        )
        
        // 内容
        let contentRect = CGRect(x: 20, y: 160, width: size.width - 40, height: 250)
        quote.content.draw(
            in: contentRect,
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 18),
                .foregroundColor: UIColor.white
            ],
            context: NSStringDrawingContext()
        )
        
        // 底部
        let footer = "— 草包AI"
        (footer as NSString).draw(
            in: CGRect(x: 20, y: 450, width: size.width - 40, height: 20),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 12),
                .foregroundColor: UIColor.white.withAlphaComponent(0.5)
            ]
        )
        
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}

// MARK: - 分享按钮

/// 分享按钮
struct ShareButton: View {
    let content: ShareContentType
    var sourceView: UIView?
    var rect: CGRect?
    
    var body: some View {
        Button(action: {
            HapticManager.light()
            ShareManager.shared.share(
                content: content,
                sourceView: sourceView,
                rect: rect
            )
        }) {
            Image(systemName: "square.and.arrow.up")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 分享菜单

/// 分享菜单
struct ShareMenu: View {
    let fortune: FortuneData?
    let quote: Quote?
    let messages: [Message]?
    
    @State private var showShareSheet = false
    @State private var shareContent: ShareContentType?
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack(spacing: 0) {
                // 分享运势
                if let fortune = fortune {
                    Button(action: {
                        HapticManager.light()
                        shareContent = .text(generateFortuneText(fortune: fortune))
                        showShareSheet = true
                    }) {
                        VStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .font(.title2)
                            Text("运势")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    Divider()
                }
                
                // 分享金句
                if let quote = quote {
                    Button(action: {
                        HapticManager.light()
                        shareContent = .text(generateQuoteText(quote: quote))
                        showShareSheet = true
                    }) {
                        VStack(spacing: 8) {
                            Image(systemName: "quote.bubble")
                                .font(.title2)
                            Text("金句")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    Divider()
                }
                
                // 分享对话
                if let messages = messages, !messages.isEmpty {
                    Button(action: {
                        HapticManager.light()
                        shareContent = .text(generateConversationText(messages: messages))
                        showShareSheet = true
                    }) {
                        VStack(spacing: 8) {
                            Image(systemName: "message")
                                .font(.title2)
                            Text("对话")
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                }
                
                // 系统分享
                Button(action: {
                    HapticManager.light()
                    if let fortune = fortune {
                        ShareManager.shared.shareFortune(fortune: fortune)
                    }
                }) {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title2)
                        Text("更多")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            }
            .background(Color(.systemBackground))
        }
        .sheet(isPresented: $showShareSheet) {
            if let content = shareContent {
                ShareSheet(content: content)
            }
        }
    }
    
    // MARK: - 生成文本
    
    private func generateFortuneText(fortune: FortuneData) -> String {
        """
        🌟 今日运势 🌟
        
        \(fortune.message)
        
        评分：\(fortune.score)/100
        建议：\(fortune.suggestion)
        
        来自草包AI
        """
    }
    
    private func generateQuoteText(quote: Quote) -> String {
        """
        💬 毒舌金句 💬
        
        "\(quote.content)"
        
        — 草包AI
        """
    }
    
    private func generateConversationText(messages: [Message]) -> String {
        messages.map { message in
            "\(message.isUser ? "我" : "草包"): \(message.content)"
        }.joined(separator: "\n\n")
    }
}

// MARK: - 分享Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let content: ShareContentType
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let items: [Any]
        
        switch content {
        case .text(let text):
            items = [text]
        case .image(let image):
            items = [image]
        case .url(let url):
            items = [url]
        case .textWithImage(let text, let image):
            items = [text, image]
        }
        
        let activityVC = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        
        return activityVC
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 使用示例

/*
// 简单分享
Button("分享") {
    ShareManager.shared.share(content: .text("分享内容"))
}

// 分享运势
ShareButton(content: .text("运势内容"))

// 在消息气泡中添加分享
MessageBubble(
    message: message,
    onShare: {
        ShareManager.shared.shareConversation(messages: [message])
    }
)

// 使用分享菜单
VStack {
    // 内容
}
.overlay(alignment: .bottom) {
    ShareMenu(
        fortune: fortune,
        quote: quote,
        messages: messages
    )
}

// SwiftUI方式
ShareSheet(content: .text("分享内容"))
*/
