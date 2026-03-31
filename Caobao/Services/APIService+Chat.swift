import Foundation
import Alamofire

// MARK: - Chat API Extension
extension APIService {
    
    /// 使用 /api/v1/chat/completions 端点的流式对话
    /// 支持 OpenAI 兼容格式，自动注入草包人设
    func chatStreamV2(
        userId: String,
        message: String,
        sessionId: String? = nil,
        attachments: [Attachment]? = nil,
        token: String? = nil
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // 使用草包格式请求
                    let parameters: [String: Any] = [
                        "message": message,
                        "stream": true,
                        "sessionId": sessionId ?? UUID().uuidString,
                        "model": "deepseek-chat",
                        "attachments": attachments?.map { ["type": $0.type, "url": $0.url] } ?? []
                    ]
                    
                    // 使用正确的 API 端点
                    let url = URL(string: "\(APIConfig.baseURL)/api/v1/chat/completions")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    
                    // 添加 Authorization header
                    if let token = token {
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        print("🔐 已添加 Authorization header")
                    }
                    
                    request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
                    
                    print("📤 发送请求到: \(url.absoluteString)")
                    print("📤 请求参数: \(parameters)")
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        print("❌ HTTP 错误: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                        continuation.finish()
                        return
                    }
                    
                    print("✅ 连接成功，开始读取流式数据...")
                    
                    // 按行读取 SSE 数据
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)
                        
                        // 检测换行符
                        if byte == 0x0A { // \n
                            if let line = String(data: buffer, encoding: .utf8) {
                                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                                
                                if trimmedLine.hasPrefix("data: ") {
                                    let jsonStr = String(trimmedLine.dropFirst(6))
                                    
                                    if jsonStr == "[DONE]" {
                                        print("✅ 流式数据读取完成")
                                        continuation.finish()
                                        return
                                    }
                                    
                                    guard let jsonData = jsonStr.data(using: .utf8) else { continue }
                                    
                                    do {
                                        // 尝试解析 OpenAI 格式响应
                                        if let openaiResponse = try? JSONDecoder().decode(OpenAIStreamResponse.self, from: jsonData) {
                                            // OpenAI 格式：提取 delta.content
                                            if let content = openaiResponse.choices.first?.delta.content {
                                                let event = ChatStreamEvent(content: content, type: "content", model: nil, error: nil)
                                                continuation.yield(event)
                                            }
                                        } else {
                                            // 尝试解析草包格式响应
                                            let event = try JSONDecoder().decode(ChatStreamEvent.self, from: jsonData)
                                            if let content = event.content, !content.isEmpty {
                                                continuation.yield(event)
                                            }
                                        }
                                    } catch {
                                        print("⚠️ JSON 解码跳过: \(error.localizedDescription)")
                                    }
                                }
                            }
                            buffer.removeAll()
                        }
                    }
                    
                    print("✅ 流式数据读取结束")
                    continuation.finish()
                } catch {
                    print("❌ 流式请求错误: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    /// 流式图片理解
    func chatStreamWithImageV2(
        userId: String,
        prompt: String,
        imageURI: String,
        sessionId: String?,
        token: String? = nil
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let parameters: [String: Any] = [
                        "message": prompt,
                        "stream": true,
                        "sessionId": sessionId ?? UUID().uuidString,
                        "model": "deepseek-chat",
                        "attachments": [
                            ["type": "image", "url": imageURI]
                        ]
                    ]
                    
                    let url = URL(string: "\(APIConfig.baseURL)/api/v1/chat/completions")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    
                    if let token = token {
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    
                    request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        continuation.finish()
                        return
                    }
                    
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)
                        
                        if byte == 0x0A {
                            if let line = String(data: buffer, encoding: .utf8) {
                                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                                
                                if trimmedLine.hasPrefix("data: ") {
                                    let jsonStr = String(trimmedLine.dropFirst(6))
                                    
                                    if jsonStr == "[DONE]" {
                                        continuation.finish()
                                        return
                                    }
                                    
                                    guard let jsonData = jsonStr.data(using: .utf8) else { continue }
                                    
                                    do {
                                        if let openaiResponse = try? JSONDecoder().decode(OpenAIStreamResponse.self, from: jsonData) {
                                            if let content = openaiResponse.choices.first?.delta.content {
                                                let event = ChatStreamEvent(content: content, type: "content", model: nil, error: nil)
                                                continuation.yield(event)
                                            }
                                        } else {
                                            let event = try JSONDecoder().decode(ChatStreamEvent.self, from: jsonData)
                                            if let content = event.content, !content.isEmpty {
                                                continuation.yield(event)
                                            }
                                        }
                                    } catch {
                                        // 跳过解码错误
                                    }
                                }
                            }
                            buffer.removeAll()
                        }
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - OpenAI Stream Response Format
struct OpenAIStreamResponse: Codable {
    let id: String?
    let object: String?
    let created: Int?
    let model: String?
    let choices: [OpenAIChoice]
    
    struct OpenAIChoice: Codable {
        let index: Int?
        let delta: OpenAIDelta
        let finishReason: String?
        
        enum CodingKeys: String, CodingKey {
            case index
            case delta
            case finishReason = "finish_reason"
        }
    }
    
    struct OpenAIDelta: Codable {
        let role: String?
        let content: String?
    }
}
