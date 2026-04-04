//
//  NetworkOptimizer.swift
//  草包 - 网络优化和离线模式
//
//  优化网络请求，支持离线模式
//

import Foundation
import Combine

// MARK: - 网络状态

/// 网络状态
enum NetworkStatus {
    case unknown
    case notReachable
    case reachableViaWWAN    // 蜂窝网络
    case reachableViaWiFi    // WiFi
    
    var isReachable: Bool {
        switch self {
        case .reachableViaWWAN, .reachableViaWiFi:
            return true
        default:
            return false
        }
    }
}

// MARK: - 网络监控器

/// 网络监控器
class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    
    @Published var status: NetworkStatus = .unknown
    @Published var isConnected = false
    
    private let reachability = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    
    private init() {
        startMonitoring()
    }
    
    // MARK: - 开始监控
    
    private func startMonitoring() {
        reachability.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.updateStatus(path: path)
            }
        }
        reachability.start(queue: queue)
    }
    
    // MARK: - 更新状态
    
    private func updateStatus(path: NWPath) {
        if path.status == .satisfied {
            if path.usesInterfaceType(.wifi) {
                status = .reachableViaWiFi
            } else if path.usesInterfaceType(.cellular) {
                status = .reachableViaWWAN
            } else {
                status = .reachableViaWiFi
            }
            isConnected = true
        } else {
            status = .notReachable
            isConnected = false
        }
    }
    
    // MARK: - 停止监控
    
    func stopMonitoring() {
        reachability.cancel()
    }
}

// MARK: - 请求缓存

/// 请求缓存
class RequestCache: NSObject {
    static let shared = RequestCache()
    
    private let cache = URLCache(
        memoryCapacity: 50 * 1024 * 1024,    // 50MB
        diskCapacity: 100 * 1024 * 1024,     // 100MB
        diskPath: "CaobaoRequestCache"
    )
    
    private override init() {
        super.init()
        URLCache.shared = cache
    }
    
    // MARK: - 缓存操作
    
    /// 获取缓存的响应
    func getCachedResponse(for request: URLRequest) -> CachedURLResponse? {
        return cache.cachedResponse(for: request)
    }
    
    /// 存储响应到缓存
    func storeResponse(_ response: CachedURLResponse, for request: URLRequest) {
        cache.storeCachedResponse(response, for: request)
    }
    
    /// 清除所有缓存
    func removeAllCache() {
        cache.removeAllCachedResponses()
    }
    
    /// 获取缓存大小
    func getCacheSize() -> Int {
        return cache.currentMemoryUsage + cache.currentDiskUsage
    }
}

// MARK: - 离线存储

/// 离线存储
class OfflineStorage: ObservableObject {
    static let shared = OfflineStorage()
    
    private let userDefaults = UserDefaults.standard
    
    // MARK: - 存储键
    
    private enum Keys {
        static let messages = "cached_messages"
        static let fortunes = "cached_fortunes"
        static let quotes = "cached_quotes"
        static let lastSync = "last_sync_time"
    }
    
    // MARK: - 消息缓存
    
    /// 缓存消息
    func cacheMessages(_ messages: [Message]) {
        if let data = try? JSONEncoder().encode(messages) {
            userDefaults.set(data, forKey: Keys.messages)
        }
    }
    
    /// 获取缓存的消息
    func getCachedMessages() -> [Message]? {
        guard let data = userDefaults.data(forKey: Keys.messages),
              let messages = try? JSONDecoder().decode([Message].self, from: data) else {
            return nil
        }
        return messages
    }
    
    // MARK: - 运势缓存
    
    /// 缓存运势
    func cacheFortune(_ fortune: FortuneData) {
        if let data = try? JSONEncoder().encode(fortune) {
            userDefaults.set(data, forKey: Keys.fortunes)
        }
    }
    
    /// 获取缓存的运势
    func getCachedFortune() -> FortuneData? {
        guard let data = userDefaults.data(forKey: Keys.fortunes),
              let fortune = try? JSONDecoder().decode(FortuneData.self, from: data) else {
            return nil
        }
        return fortune
    }
    
    // MARK: - 金句缓存
    
    /// 缓存金句
    func cacheQuote(_ quote: Quote) {
        if let data = try? JSONEncoder().encode(quote) {
            userDefaults.set(data, forKey: Keys.quotes)
        }
    }
    
    /// 获取缓存的金句
    func getCachedQuote() -> Quote? {
        guard let data = userDefaults.data(forKey: Keys.quotes),
              let quote = try? JSONDecoder().decode(Quote.self, from: data) else {
            return nil
        }
        return quote
    }
    
    // MARK: - 同步时间
    
    /// 更新最后同步时间
    func updateLastSyncTime() {
        userDefaults.set(Date().timeIntervalSince1970, forKey: Keys.lastSync)
    }
    
    /// 获取最后同步时间
    func getLastSyncTime() -> Date? {
        let timestamp = userDefaults.double(forKey: Keys.lastSync)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }
    
    /// 检查是否需要同步
    func needsSync(interval: TimeInterval = 3600) -> Bool {
        guard let lastSync = getLastSyncTime() else {
            return true
        }
        return Date().timeIntervalSince(lastSync) > interval
    }
    
    // MARK: - 清除缓存
    
    /// 清除所有离线缓存
    func clearAllCache() {
        userDefaults.removeObject(forKey: Keys.messages)
        userDefaults.removeObject(forKey: Keys.fortunes)
        userDefaults.removeObject(forKey: Keys.quotes)
        userDefaults.removeObject(forKey: Keys.lastSync)
    }
}

// MARK: - 优化的API服务

/// 优化的API服务
class OptimizedAPIService {
    static let shared = OptimizedAPIService()
    
    private let baseURL = "https://caobao.chat/api"
    private let session: URLSession
    
    private init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = RequestCache.shared.cache
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        
        session = URLSession(configuration: config)
    }
    
    // MARK: - 通用请求
    
    /// 执行请求
    func performRequest<T: Decodable>(
        endpoint: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        useCache: Bool = true,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        guard let url = URL(string: baseURL + endpoint) else {
            completion(.failure(NSError(domain: "Invalid URL", code: -1, userInfo: nil)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let body = body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        
        // 检查缓存
        if useCache, let cached = RequestCache.shared.getCachedResponse(for: request) {
            if let decoded = try? JSONDecoder().decode(T.self, from: cached.data) {
                DispatchQueue.main.async {
                    completion(.success(decoded))
                }
                return
            }
        }
        
        // 网络请求
        session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                // 网络错误，尝试使用离线数据
                if !NetworkMonitor.shared.isConnected {
                    self?.handleOfflineRequest(endpoint: endpoint, completion: completion)
                    return
                }
                
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "No data", code: -1, userInfo: nil)))
                }
                return
            }
            
            // 解码响应
            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                
                // 缓存响应
                if let response = response as? HTTPURLResponse {
                    let cached = CachedURLResponse(response: response, data: data)
                    RequestCache.shared.storeResponse(cached, for: request)
                }
                
                DispatchQueue.main.async {
                    completion(.success(decoded))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }.resume()
    }
    
    // MARK: - 离线请求处理
    
    /// 处理离线请求
    private func handleOfflineRequest<T: Decodable>(
        endpoint: String,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        // 根据endpoint返回缓存数据
        if endpoint.contains("fortune"), let cached: FortuneData = OfflineStorage.shared.getCachedFortune() {
            completion(.success(cached as! T))
        } else if endpoint.contains("quote"), let cached: Quote = OfflineStorage.shared.getCachedQuote() {
            completion(.success(cached as! T))
        } else if endpoint.contains("message"), let cached: [Message] = OfflineStorage.shared.getCachedMessages() {
            completion(.success(cached as! T))
        } else {
            completion(.failure(NSError(domain: "Offline", code: -1, userInfo: [NSLocalizedDescriptionKey: "离线模式下无缓存数据"])))
        }
    }
    
    // MARK: - API方法
    
    /// 发送消息
    func sendMessage(message: String, completion: @escaping (Result<String, Error>) -> Void) {
        performRequest(
            endpoint: "/chat",
            method: "POST",
            body: ["message": message],
            completion: completion
        )
    }
    
    /// 获取运势
    func getFortune(completion: @escaping (Result<FortuneData, Error>) -> Void) {
        performRequest(endpoint: "/fortune", completion: completion) { result in
            if case .success(let fortune) = result {
                OfflineStorage.shared.cacheFortune(fortune)
                OfflineStorage.shared.updateLastSyncTime()
            }
            completion(result)
        }
    }
    
    /// 获取金句
    func getQuote(completion: @escaping (Result<Quote, Error>) -> Void) {
        performRequest(endpoint: "/quote", completion: completion) { result in
            if case .success(let quote) = result {
                OfflineStorage.shared.cacheQuote(quote)
            }
            completion(result)
        }
    }
    
    /// 做决策
    func makeDecision(options: [String], completion: @escaping (Result<Decision, Error>) -> Void) {
        performRequest(
            endpoint: "/decision",
            method: "POST",
            body: ["options": options],
            completion: completion
        )
    }
    
    /// 吐槽
    func roast(topic: String, completion: @escaping (Result<String, Error>) -> Void) {
        performRequest(
            endpoint: "/roast",
            method: "POST",
            body: ["topic": topic],
            completion: completion
        )
    }
}

// MARK: - 使用示例

/*
// 监控网络状态
class ContentViewModel: ObservableObject {
    @Published var isOnline = NetworkMonitor.shared.isConnected
    
    init() {
        NetworkMonitor.shared.$isConnected
            .assign(to: &$isOnline)
    }
}

// 优化的API调用
OptimizedAPIService.shared.getFortune { result in
    switch result {
    case .success(let fortune):
        print("运势: \(fortune.message)")
    case .failure(let error):
        // 离线模式下会自动返回缓存数据
        if NetworkMonitor.shared.isConnected {
            print("网络错误: \(error)")
        } else {
            print("使用离线数据")
        }
    }
}

// 清除缓存
RequestCache.shared.removeAllCache()
OfflineStorage.shared.clearAllCache()

// 检查缓存大小
let cacheSize = RequestCache.shared.getCacheSize()
print("缓存大小: \(cacheSize) bytes")

// 在设置页面管理缓存
struct CacheSettingsView: View {
    var body: some View {
        Form {
            Section("缓存管理") {
                HStack {
                    Text("请求缓存")
                    Spacer()
                    Text(formatBytes(RequestCache.shared.getCacheSize()))
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text("离线数据")
                    Spacer()
                    if let lastSync = OfflineStorage.shared.getLastSyncTime() {
                        Text(lastSync, style: .relative)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未同步")
                            .foregroundStyle(.secondary)
                    }
                }
                
                Button("清除所有缓存") {
                    RequestCache.shared.removeAllCache()
                    OfflineStorage.shared.clearAllCache()
                    HapticManager.medium()
                }
                .foregroundStyle(.red)
            }
            
            Section("网络状态") {
                HStack {
                    Text("连接状态")
                    Spacer()
                    Image(systemName: NetworkMonitor.shared.isConnected ? "wifi" : "wifi.exclamationmark")
                        .foregroundStyle(NetworkMonitor.shared.isConnected ? .green : .red)
                    Text(NetworkMonitor.shared.isConnected ? "已连接" : "未连接")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("缓存设置")
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
*/
