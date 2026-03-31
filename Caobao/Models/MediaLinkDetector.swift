import Foundation

// MARK: - Media Type
enum MediaType {
    case image
    case video
    case audio
}

// MARK: - Media Link
struct MediaLink: Identifiable {
    let id = UUID()
    let url: URL
    let type: MediaType
    let label: String?
}

// MARK: - Media Link Detector
struct MediaLinkDetector {
    
    /// 检测消息中的所有媒体链接
    static func extractMediaLinks(from text: String) -> [MediaLink] {
        var results: [MediaLink] = []
        
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg"]
        let videoExtensions = ["mp4", "mov", "avi", "webm", "mkv", "m4v"]
        let audioExtensions = ["mp3", "m4a", "wav", "aac", "ogg", "opus"]
        
        // 先处理文本，修复可能被换行的 URL
        let normalizedText = fixBrokenURLs(in: text)
        
        // 更宽松的 URL 正则：匹配 http 开头到遇到空格或结束
        let urlPattern = #"https?://[^\s]*"#
        guard let urlRegex = try? NSRegularExpression(pattern: urlPattern, options: .caseInsensitive) else {
            return results
        }
        
        let range = NSRange(normalizedText.startIndex..., in: normalizedText)
        let matches = urlRegex.matches(in: normalizedText, options: [], range: range)
        
        for match in matches {
            guard let urlRange = Range(match.range, in: normalizedText) else { continue }
            let urlString = String(normalizedText[urlRange])
            let lowercased = urlString.lowercased()
            
            // 检测媒体类型
            let mediaType: MediaType?
            
            // 检查 URL 是否包含图片扩展名（可能后面有 ? 参数）
            if imageExtensions.contains(where: { ext in
                lowercased.contains(".\(ext)?") || 
                lowercased.contains(".\(ext)") ||
                lowercased.hasSuffix(".\(ext)")
            }) {
                mediaType = .image
            } else if videoExtensions.contains(where: { ext in
                lowercased.contains(".\(ext)?") || 
                lowercased.contains(".\(ext)") ||
                lowercased.hasSuffix(".\(ext)")
            }) {
                mediaType = .video
            } else if audioExtensions.contains(where: { ext in
                lowercased.contains(".\(ext)?") || 
                lowercased.contains(".\(ext)") ||
                lowercased.hasSuffix(".\(ext)")
            }) {
                mediaType = .audio
            } else {
                mediaType = nil
            }
            
            guard let type = mediaType else { continue }
            
            // 清理 URL（移除末尾可能的多余字符）
            let cleanUrlString = cleanURL(urlString)
            guard let url = URL(string: cleanUrlString) else { continue }
            
            // 尝试从原始文本中提取标签
            let label = extractLabelBeforeURL(in: text, urlStart: urlString.components(separatedBy: "/").prefix(4).joined(separator: "/"))
            
            results.append(MediaLink(url: url, type: type, label: label))
        }
        
        return results
    }
    
    /// 修复被换行打断的 URL
    private static func fixBrokenURLs(in text: String) -> String {
        var result = text
        
        // 找到所有 https:// 或 http:// 开头的位置
        let httpsPattern = #"https?://"#
        guard let httpsRegex = try? NSRegularExpression(pattern: httpsPattern, options: .caseInsensitive) else {
            return result
        }
        
        let range = NSRange(result.startIndex..., in: result)
        let matches = httpsRegex.matches(in: result, options: [], range: range)
        
        // 从后往前处理，避免索引偏移
        var processedRanges: [Range<String.Index>] = []
        
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: result) else { continue }
            
            // 检查这个范围是否已经被处理过
            var alreadyProcessed = false
            for processed in processedRanges {
                if processed.contains(matchRange.lowerBound) {
                    alreadyProcessed = true
                    break
                }
            }
            if alreadyProcessed { continue }
            
            // 从 URL 开始位置向后查找，直到遇到真正的结束
            var urlEnd = result.endIndex
            var currentIndex = matchRange.upperBound
            
            while currentIndex < result.endIndex {
                let char = result[currentIndex]
                
                // 检查是否是 URL 的结束字符
                if char == " " || char == "\t" {
                    // 空格和制表符是真正的结束
                    urlEnd = currentIndex
                    break
                } else if char == "\n" || char == "\r" {
                    // 换行符可能不是结束，检查下一行是否是 URL 的延续
                    let nextIndex = result.index(after: currentIndex)
                    if nextIndex < result.endIndex {
                        let nextChar = result[nextIndex]
                        // 如果下一行以 / 或其他 URL 字符开头，说明是延续
                        if nextChar == "/" || nextChar.isLetter || nextChar.isNumber || nextChar == "_" || nextChar == "-" || nextChar == "?" || nextChar == "=" || nextChar == "&" || nextChar == "." {
                            // 这是 URL 的延续，移除换行符
                            result.remove(at: currentIndex)
                            // 继续处理
                            continue
                        }
                    }
                    // 否则，换行是结束
                    urlEnd = currentIndex
                    break
                }
                
                currentIndex = result.index(after: currentIndex)
            }
            
            processedRanges.append(matchRange.lowerBound..<urlEnd)
        }
        
        return result
    }
    
    /// 清理 URL 字符串
    private static func cleanURL(_ urlString: String) -> String {
        var result = urlString
        
        // 移除末尾的非 URL 字符（如标点符号）
        while let lastChar = result.last {
            if lastChar == "." || lastChar == "," || lastChar == "!" || lastChar == "?" || lastChar == "。"
               || lastChar == "，" || lastChar == "！" || lastChar == "？" || lastChar == "）" || lastChar == ")"
               || lastChar == "\"" || lastChar == "'" || lastChar == "」" || lastChar == "\"" {
                result.removeLast()
            } else {
                break
            }
        }
        
        return result
    }
    
    /// 从 URL 前面的文本中提取标签
    private static func extractLabelBeforeURL(in text: String, urlStart: String) -> String? {
        // 在原始文本中查找 URL 的位置
        guard let range = text.range(of: urlStart) else {
            // 尝试查找域名
            if let domainRange = text.range(of: "coze.site") {
                let beforeText = String(text[text.startIndex..<domainRange.lowerBound])
                return extractLabel(from: beforeText)
            }
            return nil
        }
        
        let beforeText = String(text[text.startIndex..<range.lowerBound])
        return extractLabel(from: beforeText)
    }
    
    /// 从 URL 前面的文本中提取标签
    private static func extractLabel(from text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 排除太短、包含 http、或看起来像 URL 一部分的文本
            if !trimmed.isEmpty && 
               !trimmed.contains("http") && 
               !trimmed.contains("://") &&
               trimmed.count > 2 && 
               trimmed.count <= 30 &&
               !trimmed.hasSuffix("/") &&
               !trimmed.hasPrefix("/") {
                return trimmed
            }
        }
        return nil
    }
    
    /// 移除文本中的所有媒体链接
    static func removeMediaLinks(from text: String) -> String {
        var result = text
        
        // 先修复被换行的 URL
        result = fixBrokenURLs(in: result)
        
        let allExtensions = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg",
                            "mp4", "mov", "avi", "webm", "mkv", "m4v",
                            "mp3", "m4a", "wav", "aac", "ogg", "opus"]
        
        let urlPattern = #"https?://[^\s]*"#
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
            
            let isMedia = allExtensions.contains { ext in
                lowercased.contains(".\(ext)?") || 
                lowercased.contains(".\(ext)") ||
                lowercased.hasSuffix(".\(ext)")
            }
            
            if isMedia {
                result.removeSubrange(urlRange)
            }
        }
        
        // 清理多余的空行和孤立的标签
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[ \t]+$"#, with: "", options: .regularExpression)
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
