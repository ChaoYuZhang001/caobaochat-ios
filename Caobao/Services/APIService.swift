import Foundation
import Alamofire

// MARK: - API Configuration
struct APIConfig {
    // API 服务器
    struct Server {
        // 主服务器 - 当前沙箱环境
        static let primary = "https://497e37c9-8c1b-42f1-b312-7b3023324915.dev.coze.site"
        // 沙箱生产环境
        static let sandbox = "https://caobao.coze.site"
        // 腾讯云服务器
        static let tencent = "https://caobao.chat"
        // 备用地址（直连IP）
        static let fallback = "http://49.235.213.222:5000"
        // 当前使用的服务器
        static let current = primary
    }
    
    // 当前使用的 API 基础 URL
    static var baseURL: String {
        // 优先检查环境变量覆盖
        if let domain = ProcessInfo.processInfo.environment["API_BASE_URL"] {
            print("🌐 使用环境变量 API: \(domain)")
            return "\(domain)/api"
        }
        
        return "\(Server.current)/api"
    }
    
    // 是否为生产环境
    static var isProduction: Bool { true }
    
    // 调试：打印当前配置
    static func printConfiguration() {
        print("""
        ===== API 配置 =====
        环境: 生产
        服务器: \(Server.current)
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
        
        let servers = [
            ("主服务器(沙箱)", APIConfig.Server.primary),
            ("腾讯云服务器", APIConfig.Server.tencent),
            ("备用IP", APIConfig.Server.fallback),
        ]
        
        for (name, server) in servers {
            let url = "\(server)/api/auth/guest/create"
            print("📡 测试 \(name): \(url)")
            
            do {
                let response = try await session.request(url, method: .post)
                    .validate()
                    .serializingString()
                    .value
                print("✅ \(name) 连接成功: \(response.prefix(100))...")
            } catch {
                print("❌ \(name) 连接失败: \(error.localizedDescription)")
            }
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
                    let parameters: [String: Any] = [
                        "content": content,
                        "intensity": intensity
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
        try await withCheckedThrowingContinuation { continuation in
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
            .validate()
            .responseDecodable(of: DeleteAccountResponse.self) { response in
                switch response.result {
                case .success(let result):
                    continuation.resume(returning: result)
                case .failure(let error):
                    continuation.resume(throwing: error)
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
        try await withCheckedThrowingContinuation { continuation in
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
}

// MARK: - Models
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
    let recommendation: String?
    let reasons: [String]?
    let warnings: [String]?
    let alternatives: [String]?
    let finalWord: String?
    let question: String?
    let options: [String]?
    let timestamp: String?
    let error: String?
    
    // 兼容旧代码的便捷属性
    var decision: String? { recommendation }
    var reason: String? { reasons?.joined(separator: "\n") ?? finalWord }
}

struct RateResponse: Codable {
    let success: Bool
    let score: Int
    let deductions: [String]?
    let additions: [String]?
    let comment: String?
    let suggestion: String?
    let error: String?
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
        let fortune: FortuneInfo?
        let health: String?
        let action: String?
        let topic: String?
        let caobaoSays: String?
        let quote: String?
        let funFact: String?
        let news: [NewsItem]?
        
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
    
    // 便捷访问 token
    var token: String? {
        session?.token
    }
    
    struct Session: Codable {
        let id: String
        let token: String
        let refreshToken: String?
        let expiresAt: Int?
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
