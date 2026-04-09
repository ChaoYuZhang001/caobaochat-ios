import SwiftUI
import AVKit
import AVFoundation

#if os(macOS)
import AppKit
#endif

// MARK: - Message Bubble
struct MessageBubble: View {
    let message: ChatMessage
    let userSettings: UserSettings
    let autoPlayAudio: Bool
    let onCopy: () -> Void
    let onLike: () -> Void
    let onDislike: () -> Void
    let onRegenerate: () -> Void
    let onDelete: () -> Void
    @State private var showActions = false
    @State private var showReportSheet = false
    @State private var reportReason = ""
    @State private var reportSubmitted = false
    
    init(message: ChatMessage, 
         userSettings: UserSettings, 
         autoPlayAudio: Bool = false,
         onCopy: @escaping () -> Void = {},
         onLike: @escaping () -> Void = {},
         onDislike: @escaping () -> Void = {},
         onRegenerate: @escaping () -> Void = {},
         onDelete: @escaping () -> Void = {}) {
        self.message = message
        self.userSettings = userSettings
        self.autoPlayAudio = autoPlayAudio
        self.onCopy = onCopy
        self.onLike = onLike
        self.onDislike = onDislike
        self.onRegenerate = onRegenerate
        self.onDelete = onDelete
    }
    
    // 提取所有媒体链接
    private var mediaLinks: [MediaLink] {
        MediaLinkDetector.extractMediaLinks(from: message.content)
    }
    
    // 移除媒体链接后的文本
    private var displayText: String {
        MediaLinkDetector.removeMediaLinks(from: message.content)
    }
    
    // 格式化 Markdown 文本
    private func formatMarkdown(_ text: String) -> AttributedString {
        // 预处理文本，移除 Markdown 语法标记
        var processedText = text
        
        // 移除标题标记 (# ## ### 等)
        processedText = processedText.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
        
        // 移除粗体标记 (**text** 或 __text__)
        processedText = processedText.replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
        processedText = processedText.replacingOccurrences(of: "__([^_]+)__", with: "$1", options: .regularExpression)
        
        // 移除斜体标记 (*text* 或 _text_)
        processedText = processedText.replacingOccurrences(of: "\\*([^*]+)\\*", with: "$1", options: .regularExpression)
        processedText = processedText.replacingOccurrences(of: "_([^_]+)_", with: "$1", options: .regularExpression)
        
        // 移除删除线标记 (~~text~~)
        processedText = processedText.replacingOccurrences(of: "~~([^~]+)~~", with: "$1", options: .regularExpression)
        
        // 移除行内代码标记 (`code`)
        processedText = processedText.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        
        // 移除分隔线 (--- 或 ***)
        processedText = processedText.replacingOccurrences(of: "^[-]{3,}$", with: "————————", options: .regularExpression)
        processedText = processedText.replacingOccurrences(of: "^[*]{3,}$", with: "————————", options: .regularExpression)
        
        // 处理列表项 (- item 或 * item)
        processedText = processedText.replacingOccurrences(of: "^[\\-\\*]\\s+", with: "• ", options: .regularExpression)
        
        // 处理有序列表 (1. item)
        processedText = processedText.replacingOccurrences(of: "^(\\d+)\\.\\s+", with: "$1. ", options: .regularExpression)
        
        // 尝试解析为 AttributedString
        do {
            return try AttributedString(markdown: processedText, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            // 如果解析失败，返回普通文本
            return AttributedString(processedText)
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant {
                avatarView(name: "草包", isAI: true)
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
                // 文本内容（如果有）
                if !displayText.isEmpty {
                    if message.role == .assistant {
                        // AI消息使用美观的Markdown渲染
                        #if os(iOS)
                        MarkdownTextView(markdown: displayText)
                            .font(.body)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color(.systemBackground))
                            .foregroundStyle(.primary)
                            .clipShape(
                                RoundedRectangle(cornerRadius: 18)
                                    .inset(by: 0.5)
                            )
                            // AI 消息左上角直角
                            .overlay(
                                GeometryReader { geo in
                                    Path { path in
                                        path.move(to: CGPoint(x: 18, y: 0))
                                        path.addLine(to: CGPoint(x: 0, y: 0))
                                        path.addLine(to: CGPoint(x: 0, y: 18))
                                    }
                                    .fill(Color(.systemBackground))
                                }
                            )
                        #else
                        Text(displayText)
                            .font(.body)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color(nsColor: .textBackgroundColor))
                            .foregroundStyle(.primary)
                            .clipShape(
                                RoundedRectangle(cornerRadius: 18)
                                    .inset(by: 0.5)
                            )
                            .overlay(
                                GeometryReader { geo in
                                    Path { path in
                                        path.move(to: CGPoint(x: 18, y: 0))
                                        path.addLine(to: CGPoint(x: 0, y: 0))
                                        path.addLine(to: CGPoint(x: 0, y: 18))
                                    }
                                    .fill(Color(nsColor: .textBackgroundColor))
                                }
                            )
                        #endif
                    } else {
                        // 用户消息使用简单的文本渲染
                        Text(formatMarkdown(displayText))
                            .font(.body)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(
                                RoundedRectangle(cornerRadius: 18)
                                    .inset(by: 0.5)
                            )
                            // 用户消息右上角直角
                            .overlay(
                                GeometryReader { geo in
                                    Path { path in
                                        path.move(to: CGPoint(x: geo.size.width - 18, y: 0))
                                        path.addLine(to: CGPoint(x: geo.size.width, y: 0))
                                        path.addLine(to: CGPoint(x: geo.size.width, y: 18))
                                    }
                                    .fill(Color.blue)
                                }
                            )
                    }
                }
                
                // 媒体内容（图片、视频、音频）
                if !mediaLinks.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(Array(mediaLinks.enumerated()), id: \.element.id) { index, mediaLink in
                            MediaContentView(
                                mediaLink: mediaLink,
                                autoPlayAudio: autoPlayAudio && index == 0
                            )
                        }
                    }
                    .padding(.horizontal, 4)
                }
                
                // 操作栏 - AI 消息显示
                if message.role == .assistant && !message.content.isEmpty {
                    HStack(spacing: 12) {
                        // 时间
                        Text(formatTime(message.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        // 复制
                        Button {
                            onCopy()
                            #if os(iOS)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            #endif
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        // 点赞
                        Button {
                            onLike()
                        } label: {
                            Image(systemName: message.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .font(.caption)
                                .foregroundStyle(message.liked ? .blue : .secondary)
                        }
                        
                        // 踩
                        Button {
                            onDislike()
                        } label: {
                            Image(systemName: message.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                .font(.caption)
                                .foregroundStyle(message.disliked ? .red : .secondary)
                        }
                        
                        // 重新生成
                        Button {
                            onRegenerate()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        // 删除
                        Button {
                            onDelete()
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        // 举报
                        Button {
                            showReportSheet = true
                        } label: {
                            Image(systemName: "flag")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.horizontal, 4)
                }
                
                // 用户消息只显示时间
                if message.role == .user {
                    Text(formatTime(message.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
            }
            
            if message.role == .user {
                userAvatar
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .sheet(isPresented: $showReportSheet) {
            reportSheet
        }
    }
    
    // MARK: - Report Sheet
    @ViewBuilder
    private var reportSheet: some View {
        NavigationStack {
            if reportSubmitted {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.green)
                    
                    Text("感谢您的反馈")
                        .font(.headline)
                    
                    Text("我们会尽快处理您的举报")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Button("关闭") {
                        showReportSheet = false
                        reportSubmitted = false
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            } else {
                Form {
                    Section("举报原因") {
                        Button("内容不当或违规") { submitReport(reason: "内容不当或违规") }
                        Button("虚假或误导性信息") { submitReport(reason: "虚假或误导性信息") }
                        Button("侵犯个人权益") { submitReport(reason: "侵犯个人权益") }
                        Button("其他问题") { submitReport(reason: "其他问题") }
                    }
                }
                .navigationTitle("举报内容")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showReportSheet = false }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
    
    private func submitReport(reason: String) {
        // 提交举报到服务器
        Task {
            do {
                try await APIService.shared.submitFeedback(
                    type: "report",
                    content: "消息举报: \(reason)\n\n消息内容: \(message.content.prefix(200))",
                    contact: nil,
                    rating: 1
                )
                await MainActor.run {
                    reportSubmitted = true
                }
            } catch {
                print("举报提交失败: \(error)")
            }
        }
    }
    
    @ViewBuilder
    private var userAvatar: some View {
        if let emoji = userSettings.avatarEmoji {
            Text(emoji)
                .font(.title2)
                .frame(width: 36, height: 36)
                #if os(iOS)
                .background(Color(.systemGray5))
                #else
                .background(Color(nsColor: .quaternaryLabelColor))
                #endif
                .clipShape(Circle())
        } else if let url = userSettings.avatarUrl, !url.isEmpty {
            AsyncImage(url: URL(string: url)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                case .failure(_):
                    // 加载失败显示默认头像
                    Text(String(userSettings.nickname.prefix(1)))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.blue)
                case .empty:
                    ProgressView()
                @unknown default:
                    ProgressView()
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
        } else {
            Text(String(userSettings.nickname.prefix(1)))
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.blue)
                .clipShape(Circle())
        }
    }
    
    private func avatarView(name: String, isAI: Bool) -> some View {
        Image("Logo")
            .resizable()
            .scaledToFit()
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.green.opacity(0.3), lineWidth: 2)
            )
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Quick Action Button
struct QuickActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.green)
                Text(title)
                    .font(.subheadline)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            #if os(iOS)
            .background(Color(.systemBackground))
            #else
            .background(Color(nsColor: .textBackgroundColor))
            #endif
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.05), radius: 2)
        }
    }
}

// MARK: - Media Content View
struct MediaContentView: View {
    let mediaLink: MediaLink
    let autoPlayAudio: Bool
    @State private var isImageLoading = true
    @State private var isVideoPlaying = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 媒体标签
            if let label = mediaLink.label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            
            switch mediaLink.type {
            case .image:
                // 图片显示
                AsyncImage(url: mediaLink.url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 280, maxHeight: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .contextMenu {
                                Button {
                                    // 保存图片
                                    Task {
                                        await saveImage(mediaLink.url)
                                    }
                                } label: {
                                    Label("保存图片", systemImage: "square.and.arrow.down")
                                }
                                ShareLink(item: mediaLink.url)
                            }
                    case .failure(_):
                        // 加载失败显示占位图
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("图片加载失败")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 200, height: 150)
                        #if os(iOS)
                        .background(Color(.systemGray6))
                        #else
                        .background(Color(nsColor: .controlBackgroundColor))
                        #endif
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    case .empty:
                        ProgressView()
                            .frame(width: 200, height: 150)
                            #if os(iOS)
                            .background(Color(.systemGray6))
                            #else
                            .background(Color(nsColor: .controlBackgroundColor))
                            #endif
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    @unknown default:
                        ProgressView()
                    }
                }
                // 图片水印
                .overlay(alignment: .bottomTrailing) {
                    Text("草包AI生成")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(4)
                        .background(Color.black.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }
                
            case .video:
                // 视频播放器
                #if os(iOS)
                VideoPlayerView(url: mediaLink.url)
                    .frame(maxWidth: 280, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                #else
                Text("视频播放")
                    .frame(width: 280, height: 200)
                    .background(Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                #endif
                
            case .audio:
                // 音频播放器
                #if os(iOS)
                AudioPlayerView(url: mediaLink.url, autoPlay: autoPlayAudio)
                    .frame(maxWidth: 280)
                #else
                Text("音频播放")
                    .frame(width: 280)
                    .background(Color.gray)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                #endif
            }
        }
    }
    
    private func saveImage(_ url: URL) async {
        #if os(iOS)
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let uiImage = UIImage(data: data) {
                UIImageWriteToSavedPhotosAlbum(uiImage, nil, nil, nil)
            }
        } catch {
            print("保存图片失败: \(error)")
        }
        #endif
    }
}

// MARK: - Video Player View
struct VideoPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    
    var body: some View {
        ZStack {
            Color.black
            
            if let player = player {
                VideoPlayer(player: player)
                    .disabled(true)
            } else {
                ProgressView()
                    .tint(.white)
            }
            
            // 播放/暂停按钮
            Button {
                togglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.3))
        }
        .onAppear {
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
    
    private func togglePlay() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }
}
