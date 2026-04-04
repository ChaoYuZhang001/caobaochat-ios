import SwiftUI
import AVFoundation

// MARK: - Audio Player View
/// 内嵌音频播放器组件
struct AudioPlayerView: View {
    let url: URL
    let autoPlay: Bool
    
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isLoaded = false
    @State private var timeObserver: Any?
    
    init(url: URL, autoPlay: Bool = false) {
        self.url = url
        self.autoPlay = autoPlay
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // 进度条
            ProgressView(value: currentTime, total: max(duration, 1))
                .tint(.green)
                .background(Color.gray.opacity(0.3))
                .clipShape(Capsule())
            
            HStack(spacing: 12) {
                // 播放/暂停按钮
                Button {
                    togglePlay()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 36, height: 36)
                        
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: isPlaying ? 0 : 1)
                    }
                }
                
                // 时间显示
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatTime(currentTime))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                    
                    Text("/ \(formatTime(duration))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // 音频图标
                Image(systemName: "waveform")
                    .font(.system(size: 16))
                    .foregroundStyle(.green.opacity(0.6))
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            cleanup()
        }
    }
    
    // MARK: - Setup Player
    private func setupPlayer() {
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        
        // 监听播放状态
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            isPlaying = false
            currentTime = 0
            player?.seek(to: .zero)
        }
        
        // 添加时间观察者
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { time in
            currentTime = time.seconds
            if !isLoaded, let duration = player?.currentItem?.duration.seconds, duration > 0 {
                self.duration = duration
                isLoaded = true
                
                // 自动播放
                if autoPlay {
                    player?.play()
                    isPlaying = true
                }
            }
        }
    }
    
    // MARK: - Toggle Play
    private func togglePlay() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }
    
    // MARK: - Cleanup
    private func cleanup() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        player?.pause()
        player = nil
    }
    
    // MARK: - Format Time
    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Audio Link Detector
/// 检测消息中的音频链接
struct AudioLinkDetector {
    static func extractAudioLinks(from text: String) -> [(url: URL, label: String)] {
        let audioExtensions = ["mp3", "m4a", "wav", "aac", "ogg", "opus"]
        var results: [(url: URL, label: String)] = []
        
        // 正则匹配 URL
        let urlPattern = #"https?://[^\s<>"{}|\\^`\[\]]+"#
        guard let urlRegex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) else {
            return results
        }
        
        let range = NSRange(text.startIndex..., in: text)
        let matches = urlRegex.matches(in: text, options: [], range: range)
        
        for match in matches {
            guard let urlRange = Range(match.range, in: text) else { continue }
            let urlString = String(text[urlRange])
            
            // 检查是否是音频链接
            let lowercased = urlString.lowercased()
            let isAudio = audioExtensions.contains { ext in
                lowercased.hasSuffix(".\(ext)") || lowercased.contains(".\(ext)?")
            }
            
            if isAudio, let url = URL(string: urlString) {
                // 提取链接前的标签文字
                let beforeRange = text.startIndex..<urlRange.lowerBound
                let beforeText = String(text[beforeRange])
                
                // 尝试提取标签（如 "暴躁版催工语音"）
                var label = "语音消息"
                if let lastLine = beforeText.components(separatedBy: "\n").last,
                   !lastLine.trimmingCharacters(in: .whitespaces).isEmpty,
                   !lastLine.contains("http") {
                    label = lastLine.trimmingCharacters(in: .whitespaces)
                    // 限制标签长度
                    if label.count > 20 {
                        label = String(label.prefix(20)) + "..."
                    }
                }
                
                results.append((url: url, label: label))
            }
        }
        
        return results
    }
    
    /// 移除文本中的音频链接
    static func removeAudioLinks(from text: String) -> String {
        let audioExtensions = ["mp3", "m4a", "wav", "aac", "ogg", "opus"]
        var result = text
        
        let urlPattern = #"https?://[^\s<>"{}|\\^`\[\]]+"#
        guard let urlRegex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) else {
            return result
        }
        
        let range = NSRange(result.startIndex..., in: result)
        let matches = urlRegex.matches(in: result, options: [], range: range)
        
        // 从后往前替换，避免索引偏移
        for match in matches.reversed() {
            guard let urlRange = Range(match.range, in: result) else { continue }
            let urlString = String(result[urlRange])
            
            let lowercased = urlString.lowercased()
            let isAudio = audioExtensions.contains { ext in
                lowercased.hasSuffix(".\(ext)") || lowercased.contains(".\(ext)?")
            }
            
            if isAudio {
                result.removeSubrange(urlRange)
                // 移除链接前可能的多余空格和换行
                result = result.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            }
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Preview
#Preview {
    VStack(spacing: 20) {
        AudioPlayerView(
            url: URL(string: "https://coze-coding-project.tos.coze.site/audio/test.mp3")!,
            autoPlay: false
        )
        
        AudioPlayerView(
            url: URL(string: "https://coze-coding-project.tos.coze.site/audio/test2.mp3")!,
            autoPlay: true
        )
    }
    .padding()
}
