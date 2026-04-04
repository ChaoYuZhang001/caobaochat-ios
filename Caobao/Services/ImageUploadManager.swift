import UIKit
import Photos

/// 图片上传管理器
class ImageUploadManager {
    static let shared = ImageUploadManager()
    private let apiService = APIService.shared

    private init() {}

    /// 最大文件大小（1MB）
    private let maxFileSize: Int64 = 1 * 1024 * 1024

    /// 目标宽度
    private let targetWidth: CGFloat = 1024

    /// 压缩质量
    private let compressionQuality: CGFloat = 0.7

    // MARK: - Public Methods

    /// 上传图片
    /// - Parameters:
    ///   - image: 要上传的图片
    ///   - userId: 用户ID
    ///   - progressHandler: 进度回调（0.0 - 1.0）
    ///   - completion: 完成回调
    func uploadImage(
        _ image: UIImage,
        userId: String,
        progressHandler: @escaping (Double) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        print("📸 开始处理图片...")

        // 步骤1: 验证图片
        guard let imageData = image.jpegData(compressionQuality: 1.0) else {
            let error = NSError(domain: "ImageUploadManager", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "无法获取图片数据"
            ])
            completion(.failure(error))
            return
        }

        print("📏 原始图片大小: \(imageData.count / 1024) KB")

        // 步骤2: 检查图片大小
        if imageData.count > maxFileSize * 2 {
            print("⚠️ 图片过大，开始压缩...")
        }

        // 步骤3: 压缩图片
        let compressedImage = compressImage(image)

        guard let compressedData = compressedImage.jpegData(compressionQuality: compressionQuality) else {
            let error = NSError(domain: "ImageUploadManager", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "无法压缩图片"
            ])
            completion(.failure(error))
            return
        }

        print("📏 压缩后大小: \(compressedData.count / 1024) KB")
        print("📉 压缩率: \(String(format: "%.1f%%", (1.0 - Double(compressedData.count) / Double(imageData.count)) * 100))")

        // 步骤4: 验证压缩后的图片
        if compressedData.isEmpty {
            let error = NSError(domain: "ImageUploadManager", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "压缩后的图片数据为空"
            ])
            completion(.failure(error))
            return
        }

        // 步骤5: 上传图片
        uploadImageData(compressedData, progressHandler: progressHandler, completion: completion)
    }

    // MARK: - Private Methods

    /// 压缩图片
    private func compressImage(_ image: UIImage) -> UIImage {
        // 1. 调整尺寸
        var size = image.size
        if size.width > targetWidth {
            let ratio = targetWidth / size.width
            size = CGSize(width: targetWidth, height: size.height * ratio)
        }

        // 2. 缩放图片
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: size))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()

        // 3. 检查是否需要进一步压缩
        guard let jpegData = resizedImage.jpegData(compressionQuality: 1.0) else {
            return resizedImage
        }

        if jpegData.count > maxFileSize {
            // 逐步降低质量直到满足大小要求
            var quality: CGFloat = 0.9
            var compressedData = jpegData

            while quality > 0.1 && compressedData.count > maxFileSize {
                quality -= 0.1
                if let newData = resizedImage.jpegData(compressionQuality: quality) {
                    compressedData = newData
                }
            }

            print("📏 质量调整后大小: \(compressedData.count / 1024) KB (质量: \(Int(quality * 100))%)")
        }

        return resizedImage
    }

    /// 上传图片数据
    private func uploadImageData(
        _ data: Data,
        progressHandler: @escaping (Double) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let filename = "image_\(Int(Date().timeIntervalSince1970)).jpg"

        print("📤 开始上传图片: \(filename)")

        Task {
            do {
                // 模拟进度
                progressHandler(0.3)
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒

                progressHandler(0.6)
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1秒

                // 调用 API 上传
                let response = try await apiService.uploadFile(data: data, filename: filename)

                progressHandler(1.0)

                print("✅ 图片上传成功: \(response.url)")

                await MainActor.run {
                    completion(.success(response.url))
                }
            } catch {
                print("❌ 图片上传失败: \(error)")

                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }
}
