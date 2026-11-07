import Foundation
import Alamofire
import Security

#if DEBUG
@inline(__always)
func assistantDebugLog(_ message: @autoclosure () -> String) {
    print(message())
}
#else
@inline(__always)
func assistantDebugLog(_ message: @autoclosure () -> String) {}
#endif

// MARK: - API Configuration
struct APIConfig {
    // Production API server for the deployed CiYuan2API instance.
    static let serverURL = "https://ciyuan2api.com"
    
    // 当前使用的 API 基础 URL
    static var baseURL: String {
        return "\(serverURL)/api"
    }

    static var assistantBaseURL: URL {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "CaoBaoAssistantAPIBaseURL") as? String,
           let url = URL(string: configured), url.scheme == "https", url.host != nil { return url }
        return URL(string: "https://ciyuan2api.com/api/v2")!
    }
    static var v2BaseURL: String { assistantBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    
    // 是否为生产环境
    static var isProduction: Bool { true }
    
    // 调试：打印当前配置
    static func printConfiguration() {
        assistantDebugLog("""
        ===== API 配置 =====
        环境: 生产
        服务器: \(serverURL)
        API: \(baseURL)
        ====================
        """)
    }
}

enum KeychainStore {
    private static let service = "chat.caobao.assistant"

    static func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus)) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - API Service
class APIService {
    static let shared = APIService()
    
    // 配置 Alamofire Session
    private let session: Session
    
    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60  // 请求超时 60 秒
        configuration.timeoutIntervalForResource = 120  // 资源超时 120 秒
        configuration.waitsForConnectivity = false  // 不等待连接，快速失败
        configuration.networkServiceType = .default
        
        // 不使用 ServerTrustManager，使用系统默认
        self.session = Session(configuration: configuration)
        
        // 打印配置信息
        APIConfig.printConfiguration()
    }
    
    // MARK: - 网络诊断
    func diagnoseNetwork() async {
        assistantDebugLog("🔍 开始网络诊断...")
        APIConfig.printConfiguration()
        
        let url = "\(APIConfig.baseURL)/auth/guest/create"
        assistantDebugLog("📡 测试服务器: \(url)")
        
        do {
            _ = try await session.request(url, method: .post)
                .validate()
                .serializingString()
                .value
            assistantDebugLog("✅ 服务器连接成功")
        } catch {
            assistantDebugLog("❌ 服务器连接失败: \(error.localizedDescription)")
        }
        
        assistantDebugLog("🔍 网络诊断完成")
    }
    
    // MARK: - Chat Stream (使用 URLSession 实现流式响应)
    func chatStream(
        userId: String,
        prompt: String,
        sessionId: String? = nil,
        attachments: [Attachment]? = nil,
        token: String? = nil
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let parameters: [String: Any] = [
                        "prompt": prompt,
                        "stream": true,
                        "sessionId": sessionId ?? UUID().uuidString,
                        "attachments": attachments?.map { ["type": $0.type, "url": $0.url] } ?? []
                    ]
                    
                    let url = URL(string: "\(APIConfig.baseURL)/chat")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    
                    // 添加 Authorization header
                    if let token = token {
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        assistantDebugLog("🔐 已添加 Authorization header")
                    }
                    
                    request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        assistantDebugLog("❌ HTTP 错误: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                        continuation.finish()
                        return
                    }
                    
                    assistantDebugLog("✅ 连接成功，开始读取流式数据...")
                    
                    // 按行读取，而不是按字节读取
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
                                        assistantDebugLog("✅ 流式数据读取完成")
                                        continuation.finish()
                                        return
                                    }
                                    
                                    guard let jsonData = jsonStr.data(using: .utf8) else { continue }
                                    
                                    // Streamed content can contain prompts, memories, or private replies.
                                    assistantDebugLog("📥 收到流式事件")
                                    
                                    do {
                                        let event = try JSONDecoder().decode(ChatStreamEvent.self, from: jsonData)
                                        assistantDebugLog("📦 解码成功: type=\(event.type ?? "nil")")
                                        continuation.yield(event)
                                    } catch {
                                        assistantDebugLog("❌ JSON 解码错误: \(error.localizedDescription)")
                                    }
                                }
                            }
                            buffer.removeAll()
                        }
                    }
                    
                    assistantDebugLog("✅ 流式数据读取结束")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Chat Stream with Image
    func chatStreamWithImage(
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
                        "prompt": prompt,
                        "stream": true,
                        "sessionId": sessionId ?? UUID().uuidString,
                        "attachments": [
                            ["type": "image", "url": imageURI]
                        ]
                    ]
                    
                    let url = URL(string: "\(APIConfig.baseURL)/chat")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    
                    // 添加 Authorization header
                    if let token = token {
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                        assistantDebugLog("🔐 已添加 Authorization header")
                    }
                    
                    request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        assistantDebugLog("❌ HTTP 错误: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
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
                                        let event = try JSONDecoder().decode(ChatStreamEvent.self, from: jsonData)
                                        continuation.yield(event)
                                    } catch {
                                        assistantDebugLog("❌ JSON 解码错误: \(error)")
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
    
    // MARK: - Fortune
    func getFortune(userId: String) async throws -> FortuneResponse {
        try await withCheckedThrowingContinuation { continuation in
            session.request(
                "\(APIConfig.baseURL)/caobao/fortune",
                method: .post,
                parameters: ["userId": userId],
                encoding: JSONEncoding.default
            )
            .validate()
            .responseDecodable(of: FortuneResponse.self) { response in
                switch response.result {
                case .success(let fortune):
                    continuation.resume(returning: fortune)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Fortune with Params (支持完整参数)
    func getFortuneWithParams(
        fortuneType: String = "general",
        name: String? = nil,
        birthday: String? = nil,
        question: String? = nil,
        zodiac: String? = nil
    ) async throws -> FortuneResponse {
        var params: [String: Any] = [
            "fortuneType": fortuneType,
            "random": name == nil && birthday == nil
        ]
        
        if let name = name {
            params["name"] = name
        }
        if let birthday = birthday {
            params["birthday"] = birthday
        }
        if let question = question {
            params["question"] = question
        }
        if let zodiac = zodiac {
            params["zodiac"] = zodiac
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request(
                "\(APIConfig.baseURL)/caobao/fortune",
                method: .post,
                parameters: params,
                encoding: JSONEncoding.default
            )
            .validate()
            .responseDecodable(of: FortuneResponse.self) { response in
                switch response.result {
                case .success(let fortune):
                    continuation.resume(returning: fortune)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Quote
    // MARK: - Quote
    func getQuote(category: String = "random") async throws -> QuoteResponse {
        let url = "\(APIConfig.baseURL)/caobao/quote"
        assistantDebugLog("🔄 请求扎心金句...")
        assistantDebugLog("📍 URL: \(url)")
        assistantDebugLog("📦 参数: category=\(category)")
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request(
                url,
                method: .post,
                parameters: ["category": category],
                encoding: JSONEncoding.default
            )
            .validate()
            .response { response in
                assistantDebugLog("📥 收到响应，状态码: \(response.response?.statusCode ?? -1)")
                
                switch response.result {
                case .success(let data):
                    guard let data = data else {
                        let error = NSError(domain: "APIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "响应数据为空"])
                        continuation.resume(throwing: error)
                        return
                    }
                    
                    // 尝试解码为 QuoteResponse
                    do {
                        let decoder = JSONDecoder()
                        let quoteResponse = try decoder.decode(QuoteResponse.self, from: data)
                        assistantDebugLog("✅ 解码成功: success=\(quoteResponse.success)")
                        continuation.resume(returning: quoteResponse)
                    } catch {
                        assistantDebugLog("❌ 解码失败: \(error)")
                        assistantDebugLog("📋 尝试手动解析...")
                        
                        // 尝试手动解析 JSON
                        if let jsonData = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            assistantDebugLog("🔍 JSON 结构: \(jsonData.keys)")
                            
                            // 如果格式不对，返回一个友好的错误响应
                            let fallbackResponse = QuoteResponse(
                                success: false,
                                quote: nil,
                                category: category,
                                timestamp: nil,
                                fallback: true,
                                error: "数据格式错误: \(error.localizedDescription)"
                            )
                            continuation.resume(returning: fallbackResponse)
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                    
                case .failure(let error):
                    assistantDebugLog("❌ 请求失败: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Nickname
    func generateNickname(name: String = "", traits: String = "", style: String = "sharp") async throws -> NicknameResponse {
        assistantDebugLog("🔄 生成毒舌昵称...")
        assistantDebugLog("📍 API URL: \(APIConfig.baseURL)/caobao/nickname")
        
        return try await withCheckedThrowingContinuation { continuation in
            let parameters: [String: Any] = [
                "name": name,
                "traits": traits,
                "style": style
            ]
            
            session.request(
                "\(APIConfig.baseURL)/caobao/nickname",
                method: .post,
                parameters: parameters,
                encoding: JSONEncoding.default
            )
            .validate()
            .responseDecodable(of: NicknameResponse.self) { response in
                switch response.result {
                case .success(let result):
                    assistantDebugLog("✅ 昵称生成成功")
                    continuation.resume(returning: result)
                case .failure(let error):
                    assistantDebugLog("❌ 昵称生成失败: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Roast (吐槽)
    func roast(content: String, intensity: String = "medium") async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // 将 iOS 强度映射到后端参数
                    // intensity: mild/medium/spicy -> mode: gentle/normal/fierce, intensity: 2/3/4
                    let modeMap: [String: String] = [
                        "mild": "gentle",
                        "medium": "normal",
                        "spicy": "fierce"
                    ]
                    let intensityNumMap: [String: Int] = [
                        "mild": 2,
                        "medium": 3,
                        "spicy": 4
                    ]
                    
                    let parameters: [String: Any] = [
                        "content": content,
                        "mode": modeMap[intensity] ?? "normal",
                        "intensity": intensityNumMap[intensity] ?? 3,
                        "stream": true  // 启用流式输出
                    ]
                    
                    let url = URL(string: "\(APIConfig.baseURL)/caobao/roast")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        assistantDebugLog("❌ HTTP 错误: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                        continuation.finish()
                        return
                    }
                    
                    assistantDebugLog("✅ 吐槽连接成功，开始读取流式数据...")
                    
                    // 按行读取并解析 SSE 数据
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
                                        assistantDebugLog("✅ 吐槽流式数据读取完成")
                                        continuation.finish()
                                        return
                                    }
                                    
                                    // 解析 JSON 获取 content
                                    if let jsonData = jsonStr.data(using: .utf8),
                                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                                       let content = json["content"] as? String, !content.isEmpty {
                                        continuation.yield(content)
                                    }
                                }
                            }
                            buffer.removeAll()
                        }
                    }
                    
                    assistantDebugLog("✅ 吐槽流式数据读取结束")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Decision (决策助手)
    func makeDecision(question: String, options: [String]? = nil) async throws -> DecisionResponse {
        assistantDebugLog("🔄 决策助手...")
        
        return try await withCheckedThrowingContinuation { continuation in
            var parameters: [String: Any] = ["question": question]
            if let options = options {
                parameters["options"] = options
            }
            
            session.request(
                "\(APIConfig.baseURL)/caobao/decision",
                method: .post,
                parameters: parameters,
                encoding: JSONEncoding.default
            )
            .validate()
            .responseDecodable(of: DecisionResponse.self) { response in
                switch response.result {
                case .success(let result):
                    continuation.resume(returning: result)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Rate (毒舌评分)
    func rate(content: String, type: String = "text") async throws -> RateResponse {
        assistantDebugLog("🔄 毒舌评分...")
        
        return try await withCheckedThrowingContinuation { continuation in
            let parameters: [String: Any] = [
                "content": content,
                "type": type
            ]
            
            session.request(
                "\(APIConfig.baseURL)/caobao/rate",
                method: .post,
                parameters: parameters,
                encoding: JSONEncoding.default
            )
            .validate()
            .responseDecodable(of: RateResponse.self) { response in
                switch response.result {
                case .success(let result):
                    assistantDebugLog("✅ 评分成功: \(result.score)分")
                    continuation.resume(returning: result)
                case .failure(let error):
                    assistantDebugLog("❌ 评分失败: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Morning Report
    func getMorningReport() async throws -> MorningReportResponse {
        assistantDebugLog("🔄 获取早安报告...")
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request("\(APIConfig.baseURL)/report/morning")
                .validate()
                .responseDecodable(of: MorningReportResponse.self) { response in
                    switch response.result {
                    case .success(let result):
                        continuation.resume(returning: result)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
    
    // MARK: - Evening Report
    func getEveningReport() async throws -> EveningReportResponse {
        assistantDebugLog("🔄 获取晚安报告...")
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request("\(APIConfig.baseURL)/report/evening")
                .validate()
                .responseDecodable(of: EveningReportResponse.self) { response in
                    switch response.result {
                    case .success(let result):
                        continuation.resume(returning: result)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
    
    // MARK: - Analyze Image/File
    func analyzeImage(imageData: Data, prompt: String = "请分析这张图片") async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = URL(string: "\(APIConfig.baseURL)/analyze")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    
                    // 将图片转为 base64 data URI
                    let base64String = imageData.base64EncodedString()
                    let fileData = "data:image/jpeg;base64,\(base64String)"
                    
                    let body: [String: Any] = [
                        "fileData": fileData,
                        "fileName": "image.jpg",
                        "fileType": "image/jpeg",
                        "prompt": prompt
                    ]
                    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                        assistantDebugLog("❌ 图片分析 HTTP 错误: \(statusCode)")
                        continuation.finish()
                        return
                    }
                    
                    assistantDebugLog("✅ 图片分析连接成功，开始读取流式数据...")
                    
                    // 按行读取并解析 SSE 数据
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
                                        assistantDebugLog("✅ 图片分析流式数据读取完成")
                                        continuation.finish()
                                        return
                                    }
                                    
                                    // 解析 JSON 获取 content
                                    if let jsonData = jsonStr.data(using: .utf8),
                                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                                       let content = json["content"] as? String, !content.isEmpty {
                                        continuation.yield(content)
                                    }
                                }
                            }
                            buffer.removeAll()
                        }
                    }
                    
                    assistantDebugLog("✅ 图片分析流式数据读取结束")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    /// 使用imageURI分析图片
    func analyzeImage(userId: String, imageURI: String) async throws -> String {
        assistantDebugLog("📸 开始分析图片")

        let url = URL(string: "\(APIConfig.baseURL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let parameters: [String: Any] = [
            "message": "请分析这张图片",
            "stream": false,
            "sessionId": UUID().uuidString,
            "attachments": [["type": "image", "url": imageURI]]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)

        assistantDebugLog("📤 发送图片分析请求...")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            assistantDebugLog("❌ 图片分析失败: HTTP \(statusCode)")
            throw NSError(domain: "APIService", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "图片分析失败: HTTP \(statusCode)"])
        }

        // 收集所有字节数据
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }

        assistantDebugLog("📥 收集到 \(data.count) 字节")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            assistantDebugLog("❌ 无法解析响应")
            throw NSError(domain: "APIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法解析响应"])
        }

        assistantDebugLog("✅ 图片分析成功")
        return content
    }
    
    // MARK: - Upload File
    func uploadFile(data: Data, filename: String) async throws -> UploadResponse {
        try await withCheckedThrowingContinuation { continuation in
            session.upload(
                multipartFormData: { formData in
                    formData.append(data, withName: "file", fileName: filename)
                },
                to: "\(APIConfig.baseURL)/upload"
            )
            .validate()
            .responseDecodable(of: UploadResponse.self) { response in
                switch response.result {
                case .success(let result):
                    continuation.resume(returning: result)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Guest Login
    func guestLogin() async throws -> AuthResponse {
        assistantDebugLog("🔄 开始游客登录...")
        assistantDebugLog("📍 API URL: \(APIConfig.baseURL)/auth/guest/create")
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request(
                "\(APIConfig.baseURL)/auth/guest/create",
                method: .post
            )
            .validate()
            .response { response in
                if let error = response.error {
                    assistantDebugLog("❌ 网络错误: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                
                // 尝试解码
                do {
                    guard let data = response.data else {
                        throw NSError(domain: "APIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无响应数据"])
                    }
                    let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                    assistantDebugLog("✅ 游客登录成功")
                    continuation.resume(returning: authResponse)
                } catch {
                    assistantDebugLog("❌ 解码错误: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Apple Login (iOS/macOS 原生)
    func appleLogin(
        identityToken: String,
        authorizationCode: String,
        userIdentifier: String,
        email: String?,
        fullName: String?
    ) async throws -> AuthResponse {
        assistantDebugLog("🔄 开始 Apple 登录...")
        assistantDebugLog("📍 API URL: \(APIConfig.baseURL)/auth/apple/native")
        
        return try await withCheckedThrowingContinuation { continuation in
            let parameters: [String: Any?] = [
                "identityToken": identityToken,
                "authorizationCode": authorizationCode,
                "userIdentifier": userIdentifier,
                "email": email,
                "fullName": fullName
            ]
            
            session.request(
                "\(APIConfig.baseURL)/auth/apple/native",
                method: .post,
                parameters: parameters.compactMapValues { $0 },
                encoding: JSONEncoding.default
            )
            .validate()
            .response { response in
                if let error = response.error {
                    assistantDebugLog("❌ Apple 登录网络错误: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                
                // 尝试解码
                do {
                    guard let data = response.data else {
                        throw NSError(domain: "APIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无响应数据"])
                    }
                    let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                    assistantDebugLog("✅ Apple 登录成功")
                    continuation.resume(returning: authResponse)
                } catch {
                    assistantDebugLog("❌ Apple 登录解码错误: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Delete Account
    func deleteAccount(
        token: String,
        confirmation: String,
        reason: String?
    ) async throws -> DeleteAccountResponse {
        assistantDebugLog("🔄 开始注销账号...")
        assistantDebugLog("📍 API URL: \(APIConfig.baseURL)/auth/delete-account")
        
        return try await withCheckedThrowingContinuation { continuation in
            let parameters: [String: Any] = [
                "confirmation": confirmation,
                "reason": reason ?? ""
            ]
            
            let headers: HTTPHeaders = [
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/json"
            ]
            
            session.request(
                "\(APIConfig.baseURL)/auth/delete-account",
                method: .post,
                parameters: parameters,
                encoding: JSONEncoding.default,
                headers: headers
            )
            .response { response in
                // 检查 HTTP 状态码
                if let statusCode = response.response?.statusCode {
                    assistantDebugLog("📥 HTTP 状态码: \(statusCode)")
                    
                    if statusCode == 401 {
                        // 未授权 - token 可能无效
                        continuation.resume(returning: DeleteAccountResponse(
                            success: false,
                            message: nil,
                            error: "登录已过期，请重新登录后再试",
                            deletedAt: nil
                        ))
                        return
                    }
                }
                
                // 尝试解码
                if let data = response.data {
                    if let result = try? JSONDecoder().decode(DeleteAccountResponse.self, from: data) {
                        continuation.resume(returning: result)
                        return
                    }
                    
                    // 尝试解析通用响应
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let success = json["success"] as? Bool ?? false
                        let message = json["message"] as? String
                        let error = json["error"] as? String
                        
                        continuation.resume(returning: DeleteAccountResponse(
                            success: success,
                            message: message,
                            error: error,
                            deletedAt: nil
                        ))
                        return
                    }
                }
                
                // 如果都失败了，返回错误
                if let error = response.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: DeleteAccountResponse(
                        success: false,
                        message: nil,
                        error: "注销失败，请稍后重试",
                        deletedAt: nil
                    ))
                }
            }
        }
    }
    
    // MARK: - Export Data
    func exportData(token: String) async throws -> ExportDataResponse {
        try await withCheckedThrowingContinuation { continuation in
            let headers: HTTPHeaders = [
                "Authorization": "Bearer \(token)"
            ]
            
            session.request(
                "\(APIConfig.baseURL)/auth/export-data",
                method: .get,
                headers: headers
            )
            .validate()
            .responseDecodable(of: ExportDataResponse.self) { response in
                switch response.result {
                case .success(let result):
                    continuation.resume(returning: result)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Sync Chat Messages
    /// 同步聊天记录到云端
    func syncChatMessages(token: String, messages: [[String: Any]]) async throws -> SyncResponse {
        try await withCheckedThrowingContinuation { continuation in
            let headers: HTTPHeaders = [
                "Content-Type": "application/json"
            ]
            
            session.request(
                "\(APIConfig.baseURL)/sync/chat",
                method: .post,
                parameters: ["messages": messages, "mode": "merge"],
                encoding: JSONEncoding.default,
                headers: headers
            )
            .validate()
            .responseDecodable(of: SyncResponse.self) { response in
                switch response.result {
                case .success(let result):
                    continuation.resume(returning: result)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// 从云端获取聊天记录
    func getCloudChatMessages(token: String) async throws -> ChatMessagesResponse {
        try await withCheckedThrowingContinuation { continuation in
            session.request(
                "\(APIConfig.baseURL)/sync/chat",
                method: .get
            )
            .validate()
            .responseDecodable(of: ChatMessagesResponse.self) { response in
                switch response.result {
                case .success(let result):
                    continuation.resume(returning: result)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Sync Settings
    /// 同步用户设置
    func syncSettings(token: String, settings: [String: Any]) async throws -> SettingsResponse {
        try await withCheckedThrowingContinuation { continuation in
            session.request(
                "\(APIConfig.baseURL)/sync/settings",
                method: .post,
                parameters: settings,
                encoding: JSONEncoding.default
            )
            .validate()
            .responseDecodable(of: SettingsResponse.self) { response in
                switch response.result {
                case .success(let result):
                    continuation.resume(returning: result)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// 从云端获取用户设置
    func getCloudSettings(token: String) async throws -> SettingsResponse {
        try await withCheckedThrowingContinuation { continuation in
            session.request(
                "\(APIConfig.baseURL)/sync/settings",
                method: .get
            )
            .validate()
            .responseDecodable(of: SettingsResponse.self) { response in
                switch response.result {
                case .success(let result):
                    continuation.resume(returning: result)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Sync Favorites
    /// 添加收藏
    func addFavorite(token: String, type: String, content: String, metadata: [String: Any]? = nil) async throws -> FavoriteResponse {
        try await withCheckedThrowingContinuation { continuation in
            var parameters: [String: Any] = ["type": type, "content": content]
            if let metadata = metadata {
                parameters["metadata"] = metadata
            }
            
            session.request(
                "\(APIConfig.baseURL)/sync/favorites",
                method: .post,
                parameters: parameters,
                encoding: JSONEncoding.default
            )
            .validate()
            .responseDecodable(of: FavoriteResponse.self) { response in
                switch response.result {
                case .success(let result):
                    continuation.resume(returning: result)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// 获取收藏列表
    func getFavorites(token: String, type: String? = nil) async throws -> FavoritesListResponse {
        try await withCheckedThrowingContinuation { continuation in
            var url = "\(APIConfig.baseURL)/sync/favorites"
            if let type = type {
                url += "?type=\(type)"
            }
            
            session.request(url, method: .get)
                .validate()
                .responseDecodable(of: FavoritesListResponse.self) { response in
                    switch response.result {
                    case .success(let result):
                        continuation.resume(returning: result)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
    
    /// 移除收藏
    func removeFavorite(token: String, favoriteId: String) async throws -> SyncResponse {
        try await withCheckedThrowingContinuation { continuation in
            session.request(
                "\(APIConfig.baseURL)/sync/favorites?id=\(favoriteId)",
                method: .delete
            )
            .validate()
            .responseDecodable(of: SyncResponse.self) { response in
                switch response.result {
                case .success(let result):
                    continuation.resume(returning: result)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - User Stats
    /// 获取用户信息和使用统计
    func getUserInfo() async throws -> UserInfoResponse {
        try await withCheckedThrowingContinuation { continuation in
            session.request("\(APIConfig.baseURL)/auth/me")
                .validate()
                .responseDecodable(of: UserInfoResponse.self) { response in
                    switch response.result {
                    case .success(let result):
                        continuation.resume(returning: result)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
    
    // MARK: - Favorites (更新方法签名以匹配 FavoritesView)
    /// 获取收藏列表 (无 token 版本)
    func getFavorites(userId: String? = nil, type: String? = nil) async throws -> [FavoriteItem] {
        try await withCheckedThrowingContinuation { continuation in
            var url = "\(APIConfig.baseURL)/favorites"
            var params: [String] = []
            
            if let userId = userId {
                params.append("userId=\(userId)")
            }
            if let type = type {
                params.append("type=\(type)")
            }
            
            if !params.isEmpty {
                url += "?" + params.joined(separator: "&")
            }
            
            session.request(url, method: .get)
                .validate()
                .response { response in
                    if let error = response.error {
                        continuation.resume(throwing: error)
                        return
                    }
                    
                    guard let data = response.data else {
                        continuation.resume(returning: [])
                        return
                    }
                    
                    do {
                        // 解析完整的响应
                        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        if let items = json?["data"] as? [[String: Any]] {
                            let favorites = items.compactMap { item -> FavoriteItem? in
                                guard let id = item["id"] as? Int,
                                      let type = item["type"] as? String,
                                      let content = item["content"] as? String,
                                      let createdAt = item["created_at"] as? String else {
                                    return nil
                                }
                                return FavoriteItem(
                                    id: id,
                                    type: type,
                                    content: content,
                                    context: item["context"] as? String,
                                    created_at: createdAt
                                )
                            }
                            continuation.resume(returning: favorites)
                        } else {
                            continuation.resume(returning: [])
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
    
    /// 删除收藏
    func deleteFavorite(id: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.request(
                "\(APIConfig.baseURL)/favorites?id=\(id)",
                method: .delete
            )
            .validate()
            .response { response in
                if let error = response.error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    // MARK: - Chat Stream V2 (使用 /api/v1/chat/completions 端点)
    func chatStreamV2(
        userId: String,
        message: String,
        sessionId: String? = nil,
        model: String? = nil,
        toxicLevel: String? = nil,
        attachments: [Attachment]? = nil,
        token: String? = nil
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var parameters: [String: Any] = [
                        "message": message,
                        "stream": true,
                        "sessionId": sessionId ?? UUID().uuidString,
                        "model": model ?? "doubao-pro-32k",
                        "attachments": attachments?.map { ["type": $0.type, "url": $0.url] } ?? []
                    ]
                    
                    // 添加毒舌程度设置
                    if let toxicLevel = toxicLevel {
                        parameters["toxicLevel"] = toxicLevel
                    }
                    
                    // 注意: baseURL 已包含 /api，所以直接拼接 /v1/chat/completions
                    let url = URL(string: "\(APIConfig.baseURL)/v1/chat/completions")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let token = token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                    request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
                    
                    assistantDebugLog("📤 发送对话请求: \(url.absoluteString)")
                    assistantDebugLog("📤 对话参数已准备（流式）")
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        assistantDebugLog("❌ 响应类型错误")
                        continuation.finish()
                        return
                    }
                    
                    assistantDebugLog("📥 HTTP 状态码: \(httpResponse.statusCode)")
                    
                    guard httpResponse.statusCode == 200 else {
                        assistantDebugLog("❌ HTTP 错误: \(httpResponse.statusCode)")
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
                                        assistantDebugLog("✅ 流式传输完成")
                                        continuation.finish()
                                        return
                                    }
                                    
                                    guard let jsonData = jsonStr.data(using: .utf8) else {
                                        assistantDebugLog("❌ 流事件无法转换为 Data")
                                        buffer.removeAll()
                                        continue
                                    }
                                    
                                    if let event = Self.decodeUnifiedStreamEvent(jsonData) {
                                        continuation.yield(event)
                                    } else {
                                        assistantDebugLog("⚠️ 无法解析统一事件")
                                    }
                                }
                            }
                            buffer.removeAll()
                        }
                    }
                    
                    assistantDebugLog("✅ 流读取完成")
                    continuation.finish()
                } catch {
                    assistantDebugLog("❌ 流式错误: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

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
                        "message": prompt, "stream": true,
                        "sessionId": sessionId ?? UUID().uuidString, "model": "deepseek-chat",
                        "attachments": [["type": "image", "url": imageURI]]
                    ]
                    // 注意: baseURL 已包含 /api，所以直接拼接 /v1/chat/completions
                    let url = URL(string: "\(APIConfig.baseURL)/v1/chat/completions")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let token = token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                    request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
                    
                    assistantDebugLog("📤 发送图片对话请求: \(url.absoluteString)")
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        assistantDebugLog("❌ 响应类型错误")
                        continuation.finish()
                        return
                    }
                    
                    assistantDebugLog("📥 HTTP 状态码: \(httpResponse.statusCode)")
                    
                    guard httpResponse.statusCode == 200 else {
                        assistantDebugLog("❌ HTTP 错误: \(httpResponse.statusCode)")
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
                                        assistantDebugLog("✅ 流式传输完成")
                                        continuation.finish()
                                        return
                                    }
                                    
                                    guard let jsonData = jsonStr.data(using: .utf8) else {
                                        buffer.removeAll()
                                        continue
                                    }
                                    
                                    if let event = Self.decodeUnifiedStreamEvent(jsonData) {
                                        continuation.yield(event)
                                    }
                                }
                            }
                            buffer.removeAll()
                        }
                    }
                    
                    assistantDebugLog("✅ 流读取完成")
                    continuation.finish()
                } catch {
                    assistantDebugLog("❌ 流式错误: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - CaoBao Assistant Stream (统一 /api/v2 契约)

    func assistantStream(
        conversationId: String,
        request: AssistantMessageRequest,
        token: String
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard request.mode.lowercased() == "platform",
                          ["CN", "INTL"].contains(request.serviceRegion),
                          !request.requestId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          !request.content.isEmpty else {
                        throw AssistantAPIError.invalidResponse
                    }
                    let url = URL(string: "\(APIConfig.v2BaseURL)/conversations/\(conversationId)/messages")!
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.setValue(request.requestId, forHTTPHeaderField: "Idempotency-Key")
                    var payload = request
                    // The server conversation id is authoritative and must agree
                    // with both the URL and the request body, even for callers
                    // using this legacy-compatible helper.
                    payload.conversationId = conversationId
                    if payload.clientConversationId == nil { payload.clientConversationId = conversationId }
                    urlRequest.httpBody = try JSONEncoder().encode(payload)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw AssistantAPIError.invalidResponse
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        throw AssistantAPIError.httpStatus(httpResponse.statusCode)
                    }

                    var buffer = Data()
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        buffer.append(byte)
                        guard byte == 0x0A else { continue }

                        defer { buffer.removeAll(keepingCapacity: true) }
                        guard let line = String(data: buffer, encoding: .utf8) else { continue }
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }
                        guard let data = payload.data(using: .utf8),
                              let event = Self.decodeUnifiedStreamEvent(data) else { continue }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Requests server-side cancellation for a platform generation. The
    /// streaming task is still cancelled locally by the caller; this request
    /// closes the gap where the upstream relay is alive after the client has
    /// stopped reading the SSE connection.
    func cancelAssistantGeneration(generationId: String, token: String) async throws {
        guard !token.isEmpty, generationId.utf8.count <= 128,
              !generationId.isEmpty,
              generationId.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57) ||
                  ($0.value >= 65 && $0.value <= 90) ||
                  ($0.value >= 97 && $0.value <= 122) || $0 == "-" || $0 == "_"
              }) else { throw AssistantAPIError.invalidResponse }
        var request = URLRequest(url: APIConfig.assistantBaseURL
            .appendingPathComponent("generations")
            .appendingPathComponent(generationId)
            .appendingPathComponent("cancel"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AssistantAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AssistantAPIError.httpStatus(http.statusCode) }
    }

    /// Request-id cancellation is safe to issue before the server has emitted
    /// its generation id. It is scoped by the authenticated account server-side.
    func cancelAssistantGeneration(requestId: String, token: String) async throws {
        guard !token.isEmpty, requestId.utf8.count <= 128,
              !requestId.isEmpty,
              requestId.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57) ||
                  ($0.value >= 65 && $0.value <= 90) ||
                  ($0.value >= 97 && $0.value <= 122) || $0 == "-" || $0 == "_"
              }) else { throw AssistantAPIError.invalidResponse }
        var request = URLRequest(url: APIConfig.assistantBaseURL
            .appendingPathComponent("generations")
            .appendingPathComponent("by-request")
            .appendingPathComponent(requestId)
            .appendingPathComponent("cancel"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AssistantAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AssistantAPIError.httpStatus(http.statusCode) }
    }

    /// 归一化 OpenAI Chat/Responses、Anthropic Messages 和 CaoBao 自定义事件。
    /// 必须先检查供应商结构，再尝试全可选的自定义模型，避免空事件抢先解码。
    private static func decodeUnifiedStreamEvent(_ data: Data) -> ChatStreamEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return try? JSONDecoder().decode(ChatStreamEvent.self, from: data)
        }

        if let choices = object["choices"] as? [[String: Any]],
           let first = choices.first,
           let delta = first["delta"] as? [String: Any],
           let content = delta["content"] as? String {
            return ChatStreamEvent(content: content, type: "delta", model: object["model"] as? String, error: nil)
        }

        if let type = object["type"] as? String {
            switch type {
            case "response.output_text.delta":
                let text = object["delta"] as? String
                return ChatStreamEvent(content: text, type: "delta", model: nil, error: nil)
            case "content_block_delta":
                let delta = object["delta"] as? [String: Any]
                let text = delta?["text"] as? String
                return ChatStreamEvent(content: text, type: "delta", model: nil, error: nil)
            case "response.completed", "message_stop", "completed":
                return ChatStreamEvent(content: nil, type: "completed", model: nil, error: nil)
            case "error", "response.failed":
                let errorObject = object["error"] as? [String: Any]
                let message = (errorObject?["message"] as? String)
                    ?? (errorObject?["msg"] as? String)
                    ?? (object["message"] as? String)
                    ?? "上游协议返回错误"
                return ChatStreamEvent(
                    content: nil,
                    type: "error",
                    model: nil,
                    error: ChatStreamEvent.ErrorResponse(code: 0, msg: message)
                )
            default:
                break
            }
        }

        if let content = object["content"] as? String {
            return ChatStreamEvent(content: content, type: object["type"] as? String ?? "content", model: object["model"] as? String, error: nil)
        }

        if let event = try? JSONDecoder().decode(ChatStreamEvent.self, from: data),
           event.content != nil || event.error != nil || event.type != nil {
            return event
        }
        return nil
    }
}

// MARK: - Models

// OpenAI 格式流式响应（用于 chatStreamV2）
struct OpenAIStreamResponse: Codable {
    let choices: [OpenAIChoice]
}

struct OpenAIChoice: Codable {
    let delta: OpenAIDelta
    let finishReason: String?
    
    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

struct OpenAIDelta: Codable {
    let content: String?
    let role: String?
}

struct ChatStreamEvent: Codable {
    let content: String?
    let type: String?
    let model: String?
    let error: ErrorResponse?
    
    struct ErrorResponse: Codable {
        let code: Int
        let msg: String
    }
}

enum AssistantAPIError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "助理服务返回了无效响应"
        case .httpStatus(let status):
            return "助理服务请求失败（HTTP \(status)）"
        }
    }
}

struct AssistantMessageRequest: Codable {
    let requestId: String
    var clientMessageId: String
    var conversationId: String
    var clientConversationId: String?
    let mode: String
    let locale: String
    let model: String?
    let serviceRegion: String
    let persona: AssistantPersona
    let content: [AssistantContentPart]
    let context: AssistantRequestContext
    let stream: Bool
    let maxTokens: Int?

    init(requestId: String, mode: String, locale: String, persona: AssistantPersona,
         content: [AssistantContentPart], context: AssistantRequestContext, stream: Bool,
         clientMessageId: String? = nil, conversationId: String = "",
         clientConversationId: String? = nil, model: String? = nil,
         serviceRegion: String = "", maxTokens: Int? = nil) {
        self.requestId = requestId
        self.clientMessageId = clientMessageId ?? requestId
        self.conversationId = conversationId
        self.clientConversationId = clientConversationId
        self.mode = mode
        self.locale = locale
        self.model = model
        self.serviceRegion = serviceRegion
        self.persona = persona
        self.content = content
        self.context = context
        self.stream = stream
        self.maxTokens = maxTokens
    }

    struct AssistantPersona: Codable {
        let level: String
    }

    struct AssistantRequestContext: Codable {
        let messageIds: [String]
        let memoryIds: [String]
        let taskIds: [String]
        let messages: [AssistantContextMessage]
        let memories: [AssistantContextMemory]
        let tasks: [AssistantContextTask]

        init(messageIds: [String] = [], memoryIds: [String] = [], taskIds: [String] = [],
             messages: [AssistantContextMessage] = [], memories: [AssistantContextMemory] = [],
             tasks: [AssistantContextTask] = []) {
            self.messageIds = messageIds
            self.memoryIds = memoryIds
            self.taskIds = taskIds
            self.messages = messages
            self.memories = memories
            self.tasks = tasks
        }
    }

    struct AssistantContextMessage: Codable {
        let id: String?
        let role: String
        let content: [AssistantContentPart]
    }

    struct AssistantContextMemory: Codable {
        let id: String?
        let category: String?
        let text: String
        let consent: String?
    }

    struct AssistantContextTask: Codable {
        let id: String?
        let title: String
        let status: String?
        let dueAt: String?
        let instructions: String?
        let timeZone: String?
        let recurrenceRule: String?
        let recurrenceStartsAt: String?
        let timeMeaning: String?
        let requiresApproval: Bool
        let reminderEnabled: Bool
    }
}

struct AssistantContentPart: Codable {
    let type: String
    let text: String?
    let imageUrl: String?
    let imageB64: String?
    let base64Data: String?
    let mimeType: String?
    let width: Int?
    let height: Int?

    var url: String? { imageUrl }

    static func text(_ value: String) -> AssistantContentPart {
        AssistantContentPart(type: "text", text: value, imageUrl: nil, imageB64: nil,
            base64Data: nil, mimeType: nil, width: nil, height: nil)
    }

    init(type: String, text: String?, imageUrl: String?, imageB64: String? = nil,
         base64Data: String? = nil, mimeType: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.type = type; self.text = text; self.imageUrl = imageUrl; self.imageB64 = imageB64
        self.base64Data = base64Data; self.mimeType = mimeType; self.width = width; self.height = height
    }

    init(type: String, text: String?, url: String?) {
        self.init(type: type, text: text, imageUrl: url)
    }
}

// FortuneResponse 和 FortuneData 已移至 Models/FortuneData.swift

struct QuoteResponse: Codable {
    let success: Bool
    let quote: String?
    let category: String?
    let timestamp: Int?
    let fallback: Bool?
    let error: String?
}

// NicknameResponse 和 NicknameItem 已移至 Models/NicknameData.swift

struct RoastResponse: Codable {
    let success: Bool
    let content: String?
    let error: String?
}

struct DecisionResponse: Codable {
    let success: Bool
    let decision: String?
    let confidence: Int?
    let reasoning: String?
    let pros: [String]?
    let cons: [String]?
    let alternativeView: String?
    let finalAdvice: String?
    let warning: String?
    let question: String?
    let options: [String]?
    let decidedAt: String?
    let error: String?
    
    // 兼容旧代码的便捷属性
    var recommendation: String? { decision }
    var reasons: [String]? {
        var arr: [String] = []
        if let r = reasoning { arr.append(r) }
        if let w = warning { arr.append(w) }
        return arr.isEmpty ? nil : arr
    }
    var finalWord: String? { finalAdvice }
}

struct RateResponse: Codable {
    let success: Bool
    let item: String?
    let overallScore: Int?
    let overallComment: String?
    let dimensions: [RateDimension]?
    let pros: [String]?
    let cons: [String]?
    let verdict: String?
    let recommendation: String?
    let roastLevel: Int?
    let ratedAt: String?
    let error: String?
    
    // 兼容旧字段
    var score: Int { overallScore ?? 0 }
    var comment: String? { overallComment }
    var suggestion: String? { recommendation }
}

struct RateDimension: Codable {
    let name: String
    let score: Int
    let comment: String
}

struct MorningReportResponse: Codable {
    let code: Int
    let message: String?
    let data: MorningReport?
    let error: String?
    
    var success: Bool { code == 200 }
    
    struct MorningReport: Codable {
        let date: String?
        let available: Bool?
        let message: String?
        let nextUpdate: String?
        let greeting: String?
        let todos: [TodoItem]? // 从昨日聊天提取的待办
        let yesterdayReview: String? // 昨日回顾
        let fortune: FortuneInfo?
        let health: String?
        let action: String?
        let topic: String?
        let caobaoSays: String?
        let quote: String?
        let funFact: String?
        let news: [NewsItem]?
        
        struct TodoItem: Codable {
            let content: String
            let isCompleted: Bool?
            let source: String? // 来源对话
        }
        
        struct FortuneInfo: Codable {
            let stars: Int
            let comment: String?
        }
        
        struct NewsItem: Codable {
            let title: String?
            let summary: String?
            let url: String?
            let source: String?
            let comment: String?
        }
    }
}

struct EveningReportResponse: Codable {
    let code: Int
    let message: String?
    let data: EveningReport?
    let error: String?
    
    var success: Bool { code == 200 }
    
    struct EveningReport: Codable {
        let date: String?
        let available: Bool?
        let message: String?
        let nextUpdate: String?
        let greeting: String?
        let chatSummary: String? // 今日对话总结
        let keywords: [String]? // 今日关键词
        let achievements: [String]? // 今日成就
        let mood: MoodInfo?
        let review: String?
        let tomorrowPlan: [String]?
        let topic: String?
        let caobaoSays: String?
        let quote: String?
        let funFact: String?
        let news: [NewsItem]?
        let sleepTip: String?
        
        struct MoodInfo: Codable {
            let analysis: String?
            let suggestion: String?
        }
        
        struct NewsItem: Codable {
            let title: String?
            let summary: String?
            let url: String?
            let source: String?
            let comment: String?
        }
    }
}

struct AnalyzeResponse: Codable {
    let success: Bool
    let result: String?
    let error: String?
}

struct UploadResponse: Codable {
    let success: Bool
    let url: String?
    let error: String?
}

struct AuthResponse: Codable {
    let success: Bool
    let user: User?
    let session: Session?
    let error: String?
    let message: String?  // 升级成功时的消息
    let isGuest: Bool?    // 游客登录标识
    
    // 便捷访问 token - 优先从 session.token 获取，否则尝试从顶级 token 字段获取
    var token: String? {
        session?.token ?? session?.id  // 兼容后端返回 session.id 作为 token 的情况
    }
    
    struct Session: Codable {
        let id: String
        let token: String?
        let refreshToken: String?
        let expiresAt: Int?
        
        enum CodingKeys: String, CodingKey {
            case id
            case token
            case refreshToken
            case expiresAt
        }
        
        // 自定义解码，处理可选字段
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            token = try container.decodeIfPresent(String.self, forKey: .token)
            refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
            expiresAt = try container.decodeIfPresent(Int.self, forKey: .expiresAt)
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(token, forKey: .token)
            try container.encodeIfPresent(refreshToken, forKey: .refreshToken)
            try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        }
    }
}

struct DeleteAccountResponse: Codable {
    let success: Bool
    let message: String?
    let error: String?
    let deletedAt: String?
}

struct ExportDataResponse: Codable {
    let success: Bool
    let data: [String: String]?
    let exportedAt: String?
    let error: String?
}

struct Attachment {
    let type: String
    let url: String
    let name: String?
}

// MARK: - Sync Response Models
struct SyncResponse: Codable {
    let success: Bool
    let message: String?
    let error: String?
    let count: Int?
    let syncedAt: Int?
}

// MARK: - Cloud Memory Sync Models
/// Server-owned memory record. `version`, `seq`, `status`, and `updatedAt`
/// must be persisted as returned; clients must not synthesize them.
struct CloudMemory: Codable, Identifiable {
    let id: String
    let category: String
    let text: String?
    let consent: String
    let status: String
    let sourceMessageId: String?
    let locale: String?
    let version: Int64
    let seq: Int64
    let updatedAt: String
}

struct CloudMemoryListResponse: Codable {
    let items: [CloudMemory]
}

struct CloudMemoryUpsertRequest: Codable {
    let id: String
    let category: String
    let text: String
    let consent: String
    let sourceMessageId: String?
    let locale: String?
    let expectedVersion: Int64?
}

struct CloudMemorySyncChangesResponse: Codable {
    let memories: [CloudMemory]
    let nextCursor: Int64
    let headSeq: Int64
    let resyncRequired: Bool
}

struct CloudMemoryDeleteResponse: Codable {
    let status: String
}

// MARK: - Cloud task synchronization models
/// Server task fields are deliberately kept separate from AssistantTask. The
/// server does not own local notification consent or recurrence activation.
struct CloudTask: Codable, Identifiable {
    let id: String
    let title: String
    let instructions: String?
    let timeZone: String
    let recurrenceRule: String?
    let requiresApproval: Bool
    let status: String
    let version: Int64
    let dueAt: String?
    let nextRunAt: String?
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?
}

struct CloudTaskListResponse: Codable {
    let items: [CloudTask]
}

struct CloudTaskChangesResponse: Codable {
    let items: [CloudTask]
    let nextCursor: String?
    let headCursor: String?
}

struct CloudTaskUpsertRequest: Codable {
    let id: String
    let title: String
    let instructions: String?
    let timeZone: String
    let recurrenceRule: String?
    let requiresApproval: Bool?
    let dueAt: String?
    let expectedVersion: Int64?
}

struct CloudTaskApprovalRequest: Codable {
    let toolName: String
    let argumentsHash: String
    let destination: String
    let scope: String?
    let expiresInSeconds: Int64
}

struct CloudTaskApprovalResponse: Codable {
    let status: String
    let expiresAt: String
}

// MARK: - Cloud custom character models
/// An owner-scoped custom AI role. The server owns versioning and tombstones.
struct CloudCharacter: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let avatar: String?
    let description: String?
    let systemPrompt: String?
    let greeting: String?
    let language: String?
    let memoryScope: String
    let allowGlobalMemory: Bool
    let enabled: Bool
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?
}

struct CloudCharacterListResponse: Codable {
    let items: [CloudCharacter]
}

struct CloudCharacterUpsertRequest: Codable {
    let id: String
    let name: String
    let avatar: String?
    let description: String?
    let systemPrompt: String
    let greeting: String?
    let language: String?
    let memoryScope: String?
    let allowGlobalMemory: Bool
    let enabled: Bool?
    let expectedVersion: Int64?
}

struct CloudCharacterDeleteResponse: Codable {
    let status: String
}


// MARK: - Cloud proactive assistant synchronization models
struct CloudProactiveQuietHours: Codable, Equatable {
    let enabled: Bool
    let startMinute: Int
    let endMinute: Int
}

struct CloudProactiveProfile: Codable, Equatable {
    let enabled: Bool
    let mode: String
    let quietHours: CloudProactiveQuietHours
    let timeZone: String
    let dailyLimit: Int
    let companionEnabled: Bool
    let pausedAll: Bool
    let version: Int64
    let updatedAt: String
}

struct CloudProactiveProfileResponse: Codable {
    let profile: CloudProactiveProfile
}

struct CloudProactiveProfileUpdateRequest: Codable {
    let enabled: Bool?
    let mode: String?
    let quietHours: CloudProactiveQuietHours?
    let timeZone: String?
    let dailyLimit: Int?
    let companionEnabled: Bool?
    let pausedAll: Bool?
    let expectedVersion: Int64?
}

struct CloudProactiveRule: Codable, Identifiable {
    let id: String
    let kind: String
    let prompt: String
    let cadence: String?
    let sourceScopes: [String]?
    let nextRunAt: String?
    let status: String
    let version: Int64
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?
}

struct CloudProactiveRulesResponse: Codable {
    let items: [CloudProactiveRule]
}

struct CloudProactiveRuleUpsertRequest: Codable {
    let id: String
    let kind: String
    let prompt: String
    let cadence: String?
    let sourceScopes: [String]?
    let nextRunAt: String?
    let expectedVersion: Int64?
}

struct CloudProactiveRun: Codable, Identifiable {
    let id: String
    let ruleId: String
    let triggerReason: String
    let sourceRefs: [String]?
    let conversationId: String?
    let status: String
    let idempotencyKey: String
    let createdAt: String
    let deliveredAt: String?
    /// Optional fields are accepted for forward compatibility with the
    /// server-side read/snooze/dismissal contract. Older deployments omit
    /// them, so the client continues using its owner-scoped local fallback.
    let readAt: String?
    let snoozedUntil: String?
    let dismissedAt: String?
}

struct CloudProactiveRunsResponse: Codable {
    let items: [CloudProactiveRun]
    let nextCursor: String?
}

struct CloudProactiveRunRequest: Codable {
    let idempotencyKey: String
}

struct CloudProactivePauseRequest: Codable {
    let paused: Bool
}

struct ChatMessagesResponse: Codable {
    let success: Bool
    let messages: [CloudChatMessage]?
    let count: Int?
    let syncedAt: Int?
    let error: String?
}

struct CloudChatMessage: Codable {
    let id: String
    let role: String
    let content: String
    let timestamp: Double
    let type: String?
    let mode: String?
    let liked: Bool?
    let disliked: Bool?
}

struct SettingsResponse: Codable {
    let success: Bool
    let settings: CloudSettings?
    let syncedAt: Int?
    let error: String?
}

struct CloudSettings: Codable {
    let toxicLevel: String?
    let theme: String?
    let language: String?
    let voiceEnabled: Bool?
    let notifications: Bool?
    let nickname: String?
    let avatarType: String?
    let avatarValue: String?
}

struct FavoriteResponse: Codable {
    let success: Bool
    let favorite: CloudFavorite?
    let error: String?
}

struct FavoritesListResponse: Codable {
    let success: Bool
    let favorites: [CloudFavorite]?
    let count: Int?
    let error: String?
}

struct CloudFavorite: Codable {
    let id: String
    let type: String
    let content: String
    let metadata: [String: String]?
    let createdAt: Int?
}


// MARK: - User Info Response
struct UserInfoResponse: Codable {
    let success: Bool
    let user: User?
    let usageStats: [String: UsageStat]?
    let error: String?
    
    struct UsageStat: Codable {
        let count: Int
        let limit: Int
        let remaining: Int
    }
    
    // 便捷方法：获取总对话次数
    var totalChats: Int {
        usageStats?["chat"]?.count ?? 0
    }
    
    // 便捷方法：获取使用天数（从创建时间计算）
    func getUsageDays(createdAt: Int?) -> Int {
        guard let createdAt = createdAt else { return 1 }
        let createdDate = Date(timeIntervalSince1970: Double(createdAt) / 1000)
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: createdDate, to: Date()).day ?? 1
        return max(1, days)
    }
}

// MARK: - CaoBao Assistant v2 API

struct AssistantPreferencesRequest: Codable {
    let locale: String
    let personaLevel: String
    let serviceRegion: String
    let regionConfirmed: Bool
    let assistantMode: String
    /// The account timezone is sent as an explicit IANA identifier so the
    /// server can own the daily allowance boundary. It is optional for
    /// backwards-compatible preference updates from an account that has not
    /// completed timezone setup yet.
    let timeZone: String?
    let proactiveLevel: String?

    init(locale: String, personaLevel: String, serviceRegion: String, regionConfirmed: Bool,
         assistantMode: String, timeZone: String? = nil, proactiveLevel: String? = nil) {
        self.locale = locale
        self.personaLevel = personaLevel
        self.serviceRegion = serviceRegion
        self.regionConfirmed = regionConfirmed
        self.assistantMode = assistantMode
        self.timeZone = timeZone
        self.proactiveLevel = proactiveLevel
    }
}

extension APIService {
    /// Lists server task definitions. Local notification state is never
    /// serialized here; the caller remains authoritative for reminders.
    func listCloudTasks(token: String, limit: Int? = nil) async throws -> CloudTaskListResponse {
        var url = "\(APIConfig.v2BaseURL)/tasks"
        if let limit { url += "?limit=\(max(0, limit))" }
        return try await session.request(url, method: .get, headers: authHeaders(token))
            .validate().serializingDecodable(CloudTaskListResponse.self).value
    }

    /// Reads owner-scoped task mutations, including deletion tombstones. The
    /// caller persists the returned cursor only after every item is applied.
    func syncCloudTaskChanges(token: String, cursor: String? = nil, limit: Int? = nil) async throws -> CloudTaskChangesResponse {
        var components = URLComponents(string: "\(APIConfig.v2BaseURL)/tasks/changes")!
        var query: [URLQueryItem] = []
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(max(0, limit)))) }
        components.queryItems = query.isEmpty ? nil : query
        return try await session.request(components.url!, method: .get, headers: authHeaders(token))
            .validate().serializingDecodable(CloudTaskChangesResponse.self).value
    }

    /// Tombstones one server task. Local reminder cleanup remains a separate
    /// operation owned by the task coordinator.
    func deleteCloudTask(token: String, id: String) async throws {
        var safeID = CharacterSet.alphanumerics
        safeID.insert(charactersIn: "-_.~")
        let escaped = id.addingPercentEncoding(withAllowedCharacters: safeID) ?? id
        _ = try await session.request("\(APIConfig.v2BaseURL)/tasks/\(escaped)", method: .delete,
                                      headers: authHeaders(token)).validate().serializingData().value
    }

    /// Creates or updates a server task using optimistic version checking.
    func upsertCloudTask(token: String, request: CloudTaskUpsertRequest) async throws -> CloudTask {
        var safeID = CharacterSet.alphanumerics
        safeID.insert(charactersIn: "-_.~")
        let escapedID = request.id.addingPercentEncoding(withAllowedCharacters: safeID) ?? request.id
        let path = request.expectedVersion == nil
            ? "\(APIConfig.v2BaseURL)/tasks"
            : "\(APIConfig.v2BaseURL)/tasks/\(escapedID)"
        let method: HTTPMethod = request.expectedVersion == nil ? .post : .patch
        return try await session.request(path, method: method, parameters: request,
                                         encoder: JSONParameterEncoder.default,
                                         headers: authHeaders(token))
            .validate().serializingDecodable(CloudTask.self).value
    }

    /// Approves exactly the next scheduled reminder occurrence. The server
    /// binds this hash to the task id and nextRunAt, so a stale or changed
    /// task cannot reuse an approval for a different execution.
    func approveCloudTask(token: String, id: String, nextRunAt: Date,
                          expiresInSeconds: Int64 = 3600) async throws -> CloudTaskApprovalResponse {
        var safeID = CharacterSet.alphanumerics
        safeID.insert(charactersIn: "-_.~")
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == "\"" || $0 == "\\" }),
              let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: safeID) else {
            throw AssistantAPIError.invalidResponse
        }
        let scheduledAt = Int64(nextRunAt.timeIntervalSince1970)
        guard scheduledAt > 0 else { throw AssistantAPIError.invalidResponse }
        // Keep this byte-for-byte aligned with the server's
        // CaoBaoReminderArgumentsHash implementation.
        let argumentsHash = AssistantCloudTaskApproval.argumentsHash(taskId: trimmed, scheduledAt: scheduledAt)
        let request = CloudTaskApprovalRequest(toolName: "task.reminder", argumentsHash: argumentsHash,
            destination: trimmed, scope: nil, expiresInSeconds: max(1, min(expiresInSeconds, 86_400)))
        return try await session.request("\(APIConfig.v2BaseURL)/tasks/\(escaped)/approve", method: .post,
                                         parameters: request, encoder: JSONParameterEncoder.default,
                                         headers: authHeaders(token)).validate()
            .serializingDecodable(CloudTaskApprovalResponse.self).value
    }

    /// Lists active custom roles owned by the authenticated account.
    func listCloudCharacters(token: String, limit: Int? = nil) async throws -> CloudCharacterListResponse {
        var url = "\(APIConfig.v2BaseURL)/characters"
        if let limit { url += "?limit=\(max(0, limit))" }
        return try await session.request(url, method: .get, headers: authHeaders(token))
            .validate().serializingDecodable(CloudCharacterListResponse.self).value
    }

    /// Creates or updates a custom role. Updates use the path id and an
    /// expectedVersion guard; a missing expectedVersion creates through POST.
    func upsertCloudCharacter(token: String, request: CloudCharacterUpsertRequest) async throws -> CloudCharacter {
        var safeID = CharacterSet.alphanumerics
        safeID.insert(charactersIn: "-_.~")
        let id = request.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedID = id.addingPercentEncoding(withAllowedCharacters: safeID) ?? id
        let path = request.expectedVersion == nil
            ? "\(APIConfig.v2BaseURL)/characters"
            : "\(APIConfig.v2BaseURL)/characters/\(escapedID)"
        let method: HTTPMethod = request.expectedVersion == nil ? .post : .patch
        return try await session.request(path, method: method, parameters: request,
                                         encoder: JSONParameterEncoder.default,
                                         headers: authHeaders(token))
            .validate().serializingDecodable(CloudCharacter.self).value
    }

    /// Tombstones a custom role. The server clears its prompt and preserves
    /// the public id so stale devices cannot resurrect it.
    func deleteCloudCharacter(token: String, id: String, expectedVersion: Int64? = nil) async throws -> CloudCharacterDeleteResponse {
        var safeID = CharacterSet.alphanumerics
        safeID.insert(charactersIn: "-_.~")
        let escaped = id.addingPercentEncoding(withAllowedCharacters: safeID) ?? id
        var headers = authHeaders(token)
        if let expectedVersion {
            headers.add(name: "If-Match-Version", value: String(expectedVersion))
        }
        return try await session.request("\(APIConfig.v2BaseURL)/characters/\(escaped)",
                                         method: .delete, headers: headers)
            .validate().serializingDecodable(CloudCharacterDeleteResponse.self).value
    }


    func fetchProactiveProfile(token: String) async throws -> CloudProactiveProfileResponse {
        try await session.request("\(APIConfig.v2BaseURL)/proactive/profile", method: .get,
                                  headers: authHeaders(token)).validate()
            .serializingDecodable(CloudProactiveProfileResponse.self).value
    }

    func updateProactiveProfile(token: String, request: CloudProactiveProfileUpdateRequest) async throws -> CloudProactiveProfileResponse {
        try await session.request("\(APIConfig.v2BaseURL)/proactive/profile", method: .put,
                                  parameters: request, encoder: JSONParameterEncoder.default,
                                  headers: authHeaders(token)).validate()
            .serializingDecodable(CloudProactiveProfileResponse.self).value
    }

    func listProactiveRules(token: String, limit: Int? = nil) async throws -> CloudProactiveRulesResponse {
        var url = "\(APIConfig.v2BaseURL)/proactive/rules"
        if let limit { url += "?limit=\(max(0, limit))" }
        return try await session.request(url, method: .get, headers: authHeaders(token)).validate()
            .serializingDecodable(CloudProactiveRulesResponse.self).value
    }

    func upsertProactiveRule(token: String, request: CloudProactiveRuleUpsertRequest) async throws -> CloudProactiveRule {
        var safeID = CharacterSet.alphanumerics
        safeID.insert(charactersIn: "-_.~")
        let id = request.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = id.isEmpty ? "\(APIConfig.v2BaseURL)/proactive/rules" :
            "\(APIConfig.v2BaseURL)/proactive/rules/\(id.addingPercentEncoding(withAllowedCharacters: safeID) ?? id)"
        let method: HTTPMethod = id.isEmpty ? .post : .patch
        return try await session.request(path, method: method, parameters: request,
                                         encoder: JSONParameterEncoder.default,
                                         headers: authHeaders(token)).validate()
            .serializingDecodable(CloudProactiveRule.self).value
    }

    func deleteProactiveRule(token: String, id: String, expectedVersion: Int64? = nil) async throws {
        var safeID = CharacterSet.alphanumerics
        safeID.insert(charactersIn: "-_.~")
        var url = "\(APIConfig.v2BaseURL)/proactive/rules/\(id.addingPercentEncoding(withAllowedCharacters: safeID) ?? id)"
        if let expectedVersion { url += "?expectedVersion=\(expectedVersion)" }
        _ = try await session.request(url, method: .delete, headers: authHeaders(token))
            .validate().serializingData().value
    }

    func listProactiveRuns(token: String, cursor: String? = nil, limit: Int? = nil) async throws -> CloudProactiveRunsResponse {
        var components = URLComponents(string: "\(APIConfig.v2BaseURL)/proactive/runs")!
        var query: [URLQueryItem] = []
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(max(0, limit)))) }
        components.queryItems = query.isEmpty ? nil : query
        return try await session.request(components.url!, method: .get, headers: authHeaders(token)).validate()
            .serializingDecodable(CloudProactiveRunsResponse.self).value
    }

    func runProactiveRule(token: String, ruleId: String, idempotencyKey: String) async throws -> CloudProactiveRun {
        var safeID = CharacterSet.alphanumerics
        safeID.insert(charactersIn: "-_.~")
        let escaped = ruleId.addingPercentEncoding(withAllowedCharacters: safeID) ?? ruleId
        let request = CloudProactiveRunRequest(idempotencyKey: idempotencyKey)
        return try await session.request("\(APIConfig.v2BaseURL)/proactive/rules/\(escaped)/run", method: .post,
                                         parameters: request, encoder: JSONParameterEncoder.default,
                                         headers: authHeaders(token)).validate()
            .serializingDecodable(CloudProactiveRun.self).value
    }

    func pauseAllProactive(token: String, paused: Bool = true) async throws -> CloudProactiveProfileResponse {
        let request = CloudProactivePauseRequest(paused: paused)
        return try await session.request("\(APIConfig.v2BaseURL)/proactive/pause-all", method: .post,
                                         parameters: request, encoder: JSONParameterEncoder.default,
                                         headers: authHeaders(token)).validate()
            .serializingDecodable(CloudProactiveProfileResponse.self).value
    }

    /// Fetches active memories. Ownership is inferred from the bearer token.
    func listCloudMemories(token: String, limit: Int? = nil) async throws -> CloudMemoryListResponse {
        var url = "\(APIConfig.v2BaseURL)/memories"
        if let limit { url += "?limit=\(max(0, limit))" }
        return try await session.request(url, method: .get, headers: authHeaders(token))
            .validate().serializingDecodable(CloudMemoryListResponse.self).value
    }

    /// Creates or updates a memory. `expectedVersion` is an optimistic-lock
    /// guard; omit it only when creating a new record.
    func upsertCloudMemory(token: String, request: CloudMemoryUpsertRequest) async throws -> CloudMemory {
        var safeID = CharacterSet.alphanumerics
        safeID.insert(charactersIn: "-_.~")
        let escapedID = request.id.addingPercentEncoding(withAllowedCharacters: safeID) ?? request.id
        return try await session.request(
            "\(APIConfig.v2BaseURL)/memories/\(escapedID)", method: .patch,
            parameters: request, encoder: JSONParameterEncoder.default,
            headers: authHeaders(token)
        ).validate().serializingDecodable(CloudMemory.self).value
    }

    /// Creates a memory when the caller does not want to address a path id.
    func createCloudMemory(token: String, request: CloudMemoryUpsertRequest) async throws -> CloudMemory {
        return try await session.request(
            "\(APIConfig.v2BaseURL)/memories", method: .post,
            parameters: request, encoder: JSONParameterEncoder.default,
            headers: authHeaders(token)
        ).validate().serializingDecodable(CloudMemory.self).value
    }

    /// Deletes a memory by creating a server-side tombstone.
    func deleteCloudMemory(token: String, id: String) async throws -> CloudMemoryDeleteResponse {
        var safeID = CharacterSet.alphanumerics
        safeID.insert(charactersIn: "-_.~")
        let escaped = id.addingPercentEncoding(withAllowedCharacters: safeID) ?? id
        return try await session.request(
            "\(APIConfig.v2BaseURL)/memories/\(escaped)", method: .delete,
            headers: authHeaders(token)
        ).validate().serializingDecodable(CloudMemoryDeleteResponse.self).value
    }

    /// Reads changes after `cursor`. Tombstones are returned in `memories` and
    /// must be applied before advancing the local cursor to `nextCursor`.
    func syncCloudMemoryChanges(token: String, cursor: Int64 = 0, limit: Int? = nil) async throws -> CloudMemorySyncChangesResponse {
        var components = URLComponents(string: "\(APIConfig.v2BaseURL)/sync/changes")!
        var query = [URLQueryItem(name: "cursor", value: String(max(0, cursor)))]
        if let limit { query.append(URLQueryItem(name: "limit", value: String(max(0, limit)))) }
        components.queryItems = query
        return try await session.request(components.url!, method: .get, headers: authHeaders(token))
            .validate().serializingDecodable(CloudMemorySyncChangesResponse.self).value
    }

    /// 领取当日 8 次平台额度。服务端是权威，客户端只使用返回值更新展示。
    func claimDailyQuota(token: String) async throws -> DailyQuotaResponse {
        let url = "\(APIConfig.v2BaseURL)/entitlements/daily/claim"
        return try await session.request(url, method: .post, headers: authHeaders(token))
            .validate()
            .serializingDecodable(DailyQuotaResponse.self)
            .value
    }

    /// Deletes an owner-scoped server conversation. The server appends a
    /// tombstone so other devices can remove their local copy.
    func deleteCloudConversation(token: String, id: String) async throws {
        var safeID = CharacterSet.alphanumerics
        safeID.insert(charactersIn: "-_.~")
        let escaped = id.addingPercentEncoding(withAllowedCharacters: safeID) ?? id
        _ = try await session.request(
            "\(APIConfig.v2BaseURL)/conversations/\(escaped)", method: .delete,
            headers: authHeaders(token)
        ).validate().serializingData().value
    }

    func fetchAssistantEntitlements(token: String) async throws -> AssistantEntitlementResponse {
        let url = "\(APIConfig.v2BaseURL)/entitlements"
        return try await session.request(url, method: .get, headers: authHeaders(token))
            .validate()
            .serializingDecodable(AssistantEntitlementResponse.self)
            .value
    }

    func updateAssistantPreferences(
        token: String,
        request: AssistantPreferencesRequest
    ) async throws -> AssistantPreferencesResponse {
        let url = "\(APIConfig.v2BaseURL)/profile/preferences"
        return try await session.request(
            url,
            method: .patch,
            parameters: request,
            encoder: JSONParameterEncoder.default,
            headers: authHeaders(token)
        )
        .validate()
        .serializingDecodable(AssistantPreferencesResponse.self)
        .value
    }

    private func authHeaders(_ token: String) -> HTTPHeaders {
        [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json"
        ]
    }
}
