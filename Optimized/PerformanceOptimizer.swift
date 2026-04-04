//
//  PerformanceOptimizer.swift
//  草包 - 性能优化器
//
//  提供性能优化工具和策略
//

import SwiftUI
import Combine

// MARK: - 性能监控器

/// 性能监控器
class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()
    
    @Published var memoryUsage: UInt64 = 0
    @Published var cpuUsage: Double = 0.0
    @Published var frameRate: Double = 60.0
    
    private var cancellables = Set<AnyCancellable>()
    private var frameCount = 0
    private var lastFrameTime = Date()
    
    private init() {
        startMonitoring()
    }
    
    private func startMonitoring() {
        // 每秒更新一次
        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateMetrics()
            }
            .store(in: &cancellables)
    }
    
    private func updateMetrics() {
        // 获取内存使用
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            memoryUsage = info.resident_size
        }
        
        // 计算帧率
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFrameTime)
        if elapsed > 0 {
            frameRate = Double(frameCount) / elapsed
        }
        frameCount = 0
        lastFrameTime = now
    }
    
    func recordFrame() {
        frameCount += 1
    }
    
    // 获取格式化的内存使用
    func formattedMemoryUsage() -> String {
        let mb = Double(memoryUsage) / 1024 / 1024
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - 图片缓存管理器

/// 图片缓存管理器
class ImageCacheManager: ObservableObject {
    static let shared = ImageCacheManager()
    
    private let cache = NSCache<NSString, UIImage>()
    private var cacheKeys = Set<String>()
    private let maxCacheSize: Int = 50 * 1024 * 1024 // 50MB
    private let maxCacheCount = 100
    
    private init() {
        cache.totalCostLimit = maxCacheSize
        cache.countLimit = maxCacheCount
        
        // 监听内存警告
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    // MARK: - 缓存操作
    
    /// 缓存图片
    func cacheImage(_ image: UIImage, forKey key: String) {
        let cost = Int(image.size.width * image.size.height * 4) // 假设每像素4字节
        cache.setObject(image, forKey: key as NSString, cost: cost)
        cacheKeys.insert(key)
    }
    
    /// 获取缓存的图片
    func getCachedImage(forKey key: String) -> UIImage? {
        return cache.object(forKey: key as NSString)
    }
    
    /// 移除指定图片缓存
    func removeCachedImage(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
        cacheKeys.remove(key)
    }
    
    /// 清空所有缓存
    func clearCache() {
        cache.removeAllObjects()
        cacheKeys.removeAll()
    }
    
    // MARK: - 内存警告处理
    
    @objc private func handleMemoryWarning() {
        // 清理缓存
        clearCache()
        print("Memory warning - cleared image cache")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - 延迟加载视图

/// 延迟加载视图 - 优化列表性能
struct LazyLoadView<Content: View>: View {
    let content: () -> Content
    @State private var isVisible = false
    
    var body: some View {
        GeometryReader { geometry in
            if isVisible {
                content()
            } else {
                Color.clear
                    .onAppear {
                        // 检查是否在可视区域内
                        if geometry.frame(in: .global).intersects(
                            UIScreen.main.bounds
                        ) {
                            isVisible = true
                        }
                    }
            }
        }
    }
}

// MARK: - 节流器

/// 节流器 - 限制函数调用频率
class Throttler {
    private var workItem: DispatchWorkItem?
    private var lastRun: Date = Date.distantPast
    private let queue: DispatchQueue
    private let minimumDelay: TimeInterval
    
    init(minimumDelay: TimeInterval, queue: DispatchQueue = .main) {
        self.minimumDelay = minimumDelay
        self.queue = queue
    }
    
    func throttle(_ block: @escaping () -> Void) {
        workItem?.cancel()
        
        workItem = DispatchWorkItem(block: { [weak self] in
            self?.lastRun = Date()
            block()
        })
        
        let delay = Date().timeIntervalSince(lastRun) - minimumDelay
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: workItem!)
    }
    
    func cancel() {
        workItem?.cancel()
    }
}

// MARK: - 防抖器

/// 防抖器 - 延迟执行函数
class Debouncer {
    private var workItem: DispatchWorkItem?
    private let queue: DispatchQueue
    private let delay: TimeInterval
    
    init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }
    
    func debounce(_ block: @escaping () -> Void) {
        workItem?.cancel()
        
        workItem = DispatchWorkItem(block: block)
        queue.asyncAfter(deadline: .now() + delay, execute: workItem!)
    }
    
    func cancel() {
        workItem?.cancel()
    }
}

// MARK: - 列表性能优化

/// 列表性能优化修饰器
struct ListPerformanceModifier: ViewModifier {
    let id: String
    
    func body(content: Content) -> some View {
        content
            .id(id)
            .drawingGroup(opaque: false) // 优化渲染
    }
}

extension View {
    /// 列表性能优化
    func optimizedList(id: String = UUID().uuidString) -> some View {
        self.modifier(ListPerformanceModifier(id: id))
    }
    
    /// 条件渲染 - 仅在需要时渲染
    @ViewBuilder
    func render(if condition: Bool) -> some View {
        if condition {
            self
        }
    }
}

// MARK: - 数据加载优化

/// 分页加载器
class PaginatedLoader<T: Decodable>: ObservableObject {
    @Published var items: [T] = []
    @Published var isLoading = false
    @Published var hasMore = true
    
    private var currentPage = 1
    private let pageSize: Int
    private let loadPage: (Int, Int) async throws -> [T]
    
    init(pageSize: Int = 20, loadPage: @escaping (Int, Int) async throws -> [T]) {
        self.pageSize = pageSize
        self.loadPage = loadPage
    }
    
    func loadFirstPage() async {
        currentPage = 1
        items.removeAll()
        hasMore = true
        await loadNextPage()
    }
    
    func loadNextPage() async {
        guard !isLoading && hasMore else { return }
        
        isLoading = true
        
        do {
            let newItems = try await loadPage(currentPage, pageSize)
            
            await MainActor.run {
                items.append(contentsOf: newItems)
                currentPage += 1
                isLoading = false
                hasMore = newItems.count == pageSize
            }
        } catch {
            await MainActor.run {
                isLoading = false
            }
            print("Failed to load page: \(error)")
        }
    }
    
    func refresh() async {
        await loadFirstPage()
    }
}

// MARK: - 内存优化

/// 内存优化工具
struct MemoryOptimizer {
    /// 释放未使用的内存
    static func trimMemory() {
        // 清理图片缓存
        ImageCacheManager.shared.clearCache()
        
        // 发送内存警告通知
        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    /// 检查内存使用情况
    static func checkMemoryUsage() -> (used: UInt64, total: UInt64, percentage: Double) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let used = info.resident_size
            // iOS没有公开的总内存API，使用估计值
            let total: UInt64 = 2 * 1024 * 1024 * 1024 // 2GB
            let percentage = Double(used) / Double(total) * 100
            
            return (used, total, percentage)
        }
        
        return (0, 0, 0)
    }
    
    /// 自动清理策略
    static func autoCleanupIfNeeded() {
        let (_, _, percentage) = checkMemoryUsage()
        
        if percentage > 80 {
            // 内存使用超过80%，执行清理
            trimMemory()
        }
    }
}

// MARK: - 启动优化

/// 启动优化器
class StartupOptimizer {
    static let shared = StartupOptimizer()
    
    private init() {}
    
    /// 延迟初始化非关键组件
    func initializeComponents() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // 初始化性能监控
            _ = PerformanceMonitor.shared
            
            // 预加载常用资源
            self.preloadResources()
        }
    }
    
    private func preloadResources() {
        // 预加载图片缓存
        _ = ImageCacheManager.shared
        
        // 可以在这里添加其他预加载逻辑
    }
}

// MARK: - 使用示例

/*
// 性能监控
let monitor = PerformanceMonitor.shared
print("Memory: \(monitor.formattedMemoryUsage())")
print("CPU: \(monitor.cpuUsage)%")
print("FPS: \(monitor.frameRate)")

// 图片缓存
let imageCache = ImageCacheManager.shared
imageCache.cacheImage(image, forKey: "avatar")
let cachedImage = imageCache.getCachedImage(forKey: "avatar")

// 节流器 - 限制滚动事件频率
let throttler = Throttler(minimumDelay: 0.3)
scrollView.onScroll {
    throttler.throttle {
        // 处理滚动
    }
}

// 防抖器 - 搜索输入
let debouncer = Debouncer(delay: 0.5)
searchField.onChange { newValue in
    debouncer.debounce {
        // 执行搜索
    }
}

// 延迟加载列表
LazyVStack {
    ForEach(items) { item in
        LazyLoadView {
            ItemRow(item: item)
        }
    }
}

// 分页加载
let loader = PaginatedLoader<Item>(pageSize: 20) { page, size in
    return try await api.fetchItems(page: page, size: size)
}

await loader.loadFirstPage()

// 内存优化
let usage = MemoryOptimizer.checkMemoryUsage()
print("Memory usage: \(usage.percentage)%")

if usage.percentage > 80 {
    MemoryOptimizer.trimMemory()
}
*/
