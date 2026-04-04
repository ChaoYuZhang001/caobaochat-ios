import Foundation
import Alamofire

// MARK: - API Configuration
struct APIConfig {
    // API 服务器 - 只使用 caobao.chat
    static let serverURL = "https://caobao.chat"
    
    // 当前使用的 API 基础 URL
    static var baseURL: String {
        return "\(serverURL)/api"
    }
    
    // 是否为生产环境
    static var isProduction: Bool { true }
    
    // 调试：打印当前配置
    static func printConfiguration() {
        print("""
        ===== API 配置 =====
        环境: 生产
        服务器: \(serverURL)
        API: \(baseURL)
        ====================
        """)
    }
}

// MARK: - API Service
class APIService {
    static let shared = APIService()
    
    // 配置 Alamofire Session
    private let session: Session
    
    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30  // 请求超时 30 秒（服务端响应较慢）
        configuration.timeoutIntervalForResource = 60  // 资源超时 60 秒
        configuration.waitsForConnectivity = false  // 不等待连接，快速失败
        configuration.networkServiceType = .default
        
        // 不使用 ServerTrustManager，使用系统默认
        self.session = Session(configuration: configuration)
        
        // 打印配置信息
        APIConfig.printConfiguration()
    }
    
    // MARK: - 网络诊断
    func diagnoseNetwork() async {
        print("🔍 开始网络诊断...")
        APIConfig.printConfiguration()
        
        let url = "\(APIConfig.baseURL)/auth/guest/create"
        print("📡 测试服务器: \(url)")
        
        do {
            let response = try await session.request(url, method: .post)
                .validate()
                .serializingString()
                .value
            print("✅ 服务器连接成功: \(response.prefix(100))...")
        } catch {
            print("❌ 服务器连接失败: \(error.localizedDescription)")
        }
        
        print("🔍 网络诊断完成")
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
                        print("🔐 已添加 Authorization header")
                    }
                    
                    request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        print("❌ HTTP 错误: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                        continuation.finish()
                        return
                    }
                    
                    print("✅ 连接成功，开始读取流式数据...")
                    
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
                                        print("✅ 流式数据读取完成")
                                        continuation.finish()
                                        return
                                    }
                                    
                                    guard let jsonData = jsonStr.data(using: .utf8) else { continue }
                                    
                                    // 调试：打印原始 JSON
                                    print("📥 收到数据: \(jsonStr.prefix(200))")
                                    
                                    do {
                                        let event = try JSONDecoder().decode(ChatStreamEvent.self, from: jsonData)
                                        print("📦 解码成功: type=\(event.type ?? "nil"), content=\(event.content?.prefix(50) ?? "nil")")
                                        continuation.yield(event)
                                    } catch {
                                        print("❌ JSON 解码错误: \(error), JSON: \(jsonStr.prefix(100))")
                                    }
                                }
                            }
                            buffer.removeAll()
                        }
                    }
                    
                    print("✅ 流式数据读取结束")
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
                        print("🔐 已添加 Authorization header")
                    }
                    
                    request.httpBody = try? JSONSerialization.data(withJSONObject: parameters)
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        print("❌ HTTP 错误: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
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
                                        print("❌ JSON 解码错误: \(error)")
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
    
    // MARK: - Quote
    func getQuote(category: String = "random") async throws -> QuoteResponse {
        try await withCheckedThrowingContinuation { continuation in
            session.request(
                "\(APIConfig.baseURL)/caobao/quote",
                method: .post,
                parameters: ["category": category],
                encoding: JSONEncoding.default
            )
            .validate()
            .responseDecodable(of: QuoteResponse.self) { response in
                switch response.result {
                case .success(let quote):
                    continuation.resume(returning: quote)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Nickname
    func generateNickname(name: String = "", traits: String = "", style: String = "sharp") async throws -> NicknameResponse {
        print("🔄 生成毒舌昵称...")
        print("📍 API URL: \(APIConfig.baseURL)/caobao/nickname")
        
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
                    print("✅ 昵称生成成功")
                    continuation.resume(returning: result)
                case .failure(let error):
                    print("❌ 昵称生成失败: \(error.localizedDescription)")
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
                        print("❌ HTTP 错误: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                        continuation.finish()
                        return
                    }
                    
                    print("✅ 吐槽连接成功，开始读取流式数据...")
                    
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
                                        print("✅ 吐槽流式数据读取完成")
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
                    
                    print("✅ 吐槽流式数据读取结束")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Decision (决策助手)
    func makeDecision(question: String, options: [String]? = nil) async throws -> DecisionResponse {
        print("🔄 决策助手...")
        
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
        print("🔄 毒舌评分...")
        
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
                    print("✅ 评分成功: \(result.score)分")
                    continuation.resume(returning: result)
                case .failure(let error):
                    print("❌ 评分失败: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Morning Report
    func getMorningReport() async throws -> MorningReportResponse {
        print("🔄 获取早安报告...")
        
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
        print("🔄 获取晚安报告...")
        
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
                        print("❌ 图片分析 HTTP 错误: \(statusCode)")
                        continuation.finish()
                        return
                    }
                    
                    print("✅ 图片分析连接成功，开始读取流式数据...")
                    
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
                                        print("✅ 图片分析流式数据读取完成")
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
                    
                    print("✅ 图片分析流式数据读取结束")
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    /// 使用imageURI分析图片
    func analyzeImage(userId: String, imageURI: String) async throws -> String {
        print("📸 开始分析图片: \(imageURI)")

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

        print("📤 发送图片分析请求...")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("❌ 图片分析失败: HTTP \(statusCode)")
            throw NSError(domain: "APIService", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "图片分析失败: HTTP \(statusCode)"])
        }

        // 收集所有字节数据
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }

        print("📥 收集到 \(data.count) 字节")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            print("❌ 无法解析响应")
            throw NSError(domain: "APIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法解析响应"])
        }

        print("✅ 图片分析成功: \(content.prefix(50))...")
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
        print("🔄 开始游客登录...")
        print("📍 API URL: \(APIConfig.baseURL)/auth/guest/create")
        
        return try await withCheckedThrowingContinuation { continuation in
            session.request(
                "\(APIConfig.baseURL)/auth/guest/create",
                method: .post
            )
            .validate()
            .response { response in
                // 打印原始响应便于调试
                if let data = response.data {
                    print("📥 响应数据: \(String(data: data, encoding: .utf8) ?? "无法解码")")
                }
                
                if let error = response.error {
                    print("❌ 网络错误: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                
                // 尝试解码
                do {
                    guard let data = response.data else {
                        throw NSError(domain: "APIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无响应数据"])
                    }
                    let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                    print("✅ 游客登录成功: \(authResponse.user?.name ?? "未知用户")")
                    continuation.resume(returning: authResponse)
                } catch {
                    print("❌ 解码错误: \(error.localizedDescription)")
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
        print("🔄 开始 Apple 登录...")
        print("📍 API URL: \(APIConfig.baseURL)/auth/apple/native")
        
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
                // 打印原始响应便于调试
                if let data = response.data {
                    print("📥 Apple 登录响应: \(String(data: data, encoding: .utf8) ?? "无法解码")")
                }
                
                if let error = response.error {
                    print("❌ Apple 登录网络错误: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                
                // 尝试解码
                do {
                    guard let data = response.data else {
                        throw NSError(domain: "APIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无响应数据"])
                    }
                    let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                    print("✅ Apple 登录成功: \(authResponse.user?.name ?? "未知用户")")
                    continuation.resume(returning: authResponse)
                } catch {
                    print("❌ Apple 登录解码错误: \(error.localizedDescription)")
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
        print("🔄 开始注销账号...")
        print("📍 API URL: \(APIConfig.baseURL)/auth/delete-account")
        print("🔑 Token: \(token.prefix(20))...")
        
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
                // 打印原始响应
                if let data = response.data {
                    print("📥 注销响应: \(String(data: data, encoding: .utf8) ?? "无法解码")")
                }
                
                // 检查 HTTP 状态码
                if let statusCode = response.response?.statusCode {
                    print("📥 HTTP 状态码: \(statusCode)")
                    
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
    
    // MARK: - Guest Upgrade
    /// 游客升级为正式用户
    func guestUpgrade(
        guestToken: String,
        provider: String,
        identityToken: String? = nil,
        authorizationCode: String? = nil,
        email: String? = nil,
        verifyCode: String? = nil
    ) async throws -> AuthResponse {
        print("🔄 开始游客升级...")
        print("📍 API URL: \(APIConfig.baseURL)/auth/guest/upgrade")
        
        return try await withCheckedThrowingContinuation { continuation in
            var parameters: [String: Any] = [
                "guestToken": guestToken,
                "provider": provider,
                "migrateData": true
            ]
            
            // 根据不同的升级方式添加参数
            if let identityToken = identityToken {
                parameters["idToken"] = identityToken
            }
            if let authorizationCode = authorizationCode {
                parameters["code"] = authorizationCode
            }
            if let email = email {
                parameters["email"] = email
            }
            if let verifyCode = verifyCode {
                parameters["verifyCode"] = verifyCode
            }
            
            session.request(
                "\(APIConfig.baseURL)/auth/guest/upgrade",
                method: .post,
                parameters: parameters,
                encoding: JSONEncoding.default
            )
            .validate()
            .response { response in
                // 打印原始响应便于调试
                if let data = response.data {
                    print("📥 游客升级响应: \(String(data: data, encoding: .utf8) ?? "无法解码")")
                }
                
                if let error = response.error {
                    print("❌ 游客升级网络错误: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                
                // 尝试解码
                do {
                    guard let data = response.data else {
                        throw NSError(domain: "APIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无响应数据"])
                    }
                    let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
                    print("✅ 游客升级成功: \(authResponse.user?.name ?? "未知用户")")
                    continuation.resume(returning: authResponse)
                } catch {
                    print("❌ 游客升级解码错误: \(error.localizedDescription)")
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
    
    // MARK: - Feedback
    /// 提交用户反馈
    func submitFeedback(type: String, content: String, contact: String?, rating: Int) async throws {
        print("🔄 提交反馈...")
        
        return try await withCheckedThrowingContinuation { continuation in
            let parameters: [String: Any?] = [
                "type": type,
                "content": content,
                "contact": contact,
                "rating": rating
            ]
            
            session.request(
                "\(APIConfig.baseURL)/feedback",
                method: .post,
                parameters: parameters.compactMapValues { $0 },
                encoding: JSONEncoding.default
            )
            .validate()
            .response { response in
                if let error = response.error {
                    print("❌ 提交反馈失败: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                print("✅ 提交反馈成功")
                continuation.resume(returning: ())
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
                    
                    print("📤 发送对话请求: \(url.absoluteString)")
                    print("📤 参数: \(parameters)")
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        print("❌ 响应类型错误")
                        continuation.finish()
                        return
                    }
                    
                    print("📥 HTTP 状态码: \(httpResponse.statusCode)")
                    
                    guard httpResponse.statusCode == 200 else {
                        print("❌ HTTP 错误: \(httpResponse.statusCode)")
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
                                        print("✅ 流式传输完成")
                                        continuation.finish()
                                        return
                                    }
                                    
                                    guard let jsonData = jsonStr.data(using: .utf8) else {
                                        print("❌ 无法转换为 Data: \(jsonStr.prefix(50))")
                                        buffer.removeAll()
                                        continue
                                    }
                                    
                                    // 尝试解析为 ChatStreamEvent
                                    if let event = try? JSONDecoder().decode(ChatStreamEvent.self, from: jsonData) {
                                        if let content = event.content, !content.isEmpty {
                                            print("✅ 解析成功 content: \(content.prefix(30))")
                                            continuation.yield(event)
                                        } else if event.type != nil {
                                            print("📋 收到类型事件: \(event.type ?? "unknown")")
                                        }
                                    } else {
                                        // 尝试解析为 OpenAI 格式
                                        if let resp = try? JSONDecoder().decode(OpenAIStreamResponse.self, from: jsonData),
                                           let content = resp.choices.first?.delta.content {
                                            print("✅ OpenAI 格式解析成功: \(content.prefix(30))")
                                            continuation.yield(ChatStreamEvent(content: content, type: "content", model: nil, error: nil))
                                        } else {
                                            print("⚠️ 无法解析: \(jsonStr.prefix(100))")
                                        }
                                    }
                                }
                            }
                            buffer.removeAll()
                        }
                    }
                    
                    print("✅ 流读取完成")
                    continuation.finish()
                } catch {
                    print("❌ 流式错误: \(error.localizedDescription)")
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
                    
                    print("📤 发送图片对话请求: \(url.absoluteString)")
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        print("❌ 响应类型错误")
                        continuation.finish()
                        return
                    }
                    
                    print("📥 HTTP 状态码: \(httpResponse.statusCode)")
                    
                    guard httpResponse.statusCode == 200 else {
                        print("❌ HTTP 错误: \(httpResponse.statusCode)")
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
                                        print("✅ 流式传输完成")
                                        continuation.finish()
                                        return
                                    }
                                    
                                    guard let jsonData = jsonStr.data(using: .utf8) else {
                                        buffer.removeAll()
                                        continue
                                    }
                                    
                                    // 尝试解析为 ChatStreamEvent
                                    if let event = try? JSONDecoder().decode(ChatStreamEvent.self, from: jsonData) {
                                        if let content = event.content, !content.isEmpty {
                                            print("✅ 解析成功 content: \(content.prefix(30))")
                                            continuation.yield(event)
                                        }
                                    } else {
                                        // 尝试解析为 OpenAI 格式
                                        if let resp = try? JSONDecoder().decode(OpenAIStreamResponse.self, from: jsonData),
                                           let content = resp.choices.first?.delta.content {
                                            print("✅ OpenAI 格式解析成功: \(content.prefix(30))")
                                            continuation.yield(ChatStreamEvent(content: content, type: "content", model: nil, error: nil))
                                        }
                                    }
                                }
                            }
                            buffer.removeAll()
                        }
                    }
                    
                    print("✅ 流读取完成")
                    continuation.finish()
                } catch {
                    print("❌ 流式错误: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
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

// FortuneResponse 和 FortuneData 已移至 Models/FortuneData.swift

struct QuoteResponse: Codable {
    let success: Bool
    let quote: String?
    let category: String?
    let timestamp: String?
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
