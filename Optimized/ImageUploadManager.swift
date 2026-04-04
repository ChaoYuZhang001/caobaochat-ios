//
//  ImageUploadManager.swift
//  草包 - 图片上传管理器
//
//  优化图片上传流程，处理压缩、错误重试等
//

import UIKit
import SwiftUI

// MARK: - 图片上传管理器

/// 图片上传管理器
class ImageUploadManager: ObservableObject {
    static let shared = ImageUploadManager()
    
    @Published var isUploading = false
    @Published var uploadProgress: Double = 0.0
    
    private init() {}
    
    // MARK: - 图片处理
    
    /// 压缩图片到合适的大小
    /// - Parameters:
    ///   - image: 原始图片
    ///   - maxKB: 最大大小（KB），默认1024KB（1MB）
    /// - Returns: 压缩后的图片
    func compressImage(_ image: UIImage, maxKB: Int = 1024) -> UIImage? {
        // 首先尝试调整尺寸
        var resizedImage = image
        
        // 如果图片太大，先缩小尺寸
        let maxDimension: CGFloat = 2048
        let size = image.size
        
        if size.width > maxDimension || size.height > maxDimension {
            let ratio = min(maxDimension / size.width, maxDimension / size.height)
            let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
            
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            image.draw(in: CGRect(origin: .zero, size: newSize))
            resizedImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
        }
        
        // 然后压缩JPEG质量
        var compression: CGFloat = 1.0
        var imageData = resizedImage.jpegData(compressionQuality: compression)
        
        // 循环压缩直到达到目标大小
        while let data = imageData, data.count > maxKB * 1024 && compression > 0.1 {
            compression -= 0.1
            imageData = resizedImage.jpegData(compressionQuality: compression)
        }
        
        print("📷 图片压缩: 原始尺寸 \(image.size), 压缩后尺寸 \(resizedImage.size), 压缩率 \(Int(compression * 100))%, 大小 \(imageData?.count ?? 0) bytes")
        
        return resizedImage
    }
    
    /// 将图片转换为Base64
    /// - Parameters:
    ///   - image: 图片
    ///   - maxKB: 最大大小（KB）
    /// - Returns: Base64字符串，如果失败返回nil
    func convertToBase64(_ image: UIImage, maxKB: Int = 1024) -> String? {
        // 先压缩图片
        guard let compressedImage = compressImage(image, maxKB: maxKB) else {
            return nil
        }
        
        // 转换为JPEG数据
        guard let imageData = compressedImage.jpegData(compressionQuality: 0.8) else {
            return nil
        }
        
        // 转换为Base64
        let base64String = imageData.base64EncodedString()
        let dataURI = "data:image/jpeg;base64,\(base64String)"
        
        print("📷 Base64转换成功，大小: \(dataURI.count) 字符")
        
        return dataURI
    }
    
    // MARK: - 验证图片
    
    /// 验证图片是否适合上传
    /// - Parameter image: 图片
    /// - Returns: 验证结果和错误信息
    func validateImage(_ image: UIImage) -> (isValid: Bool, error: String?) {
        // 检查大小
        let sizeKB = image.jpegData(compressionQuality: 1.0)?.count ?? 0 / 1024
        if sizeKB > 10 * 1024 { // 10MB
            return (false, "图片太大，请选择小于10MB的图片")
        }
        
        // 检查尺寸
        let size = image.size
        if size.width > 8000 || size.height > 8000 {
            return (false, "图片分辨率太高")
        }
        
        // 检查格式
        guard let _ = image.jpegData(compressionQuality: 1.0) else {
            return (false, "不支持的图片格式")
        }
        
        return (true, nil)
    }
    
    // MARK: - 上传图片
    
    /// 上传图片并获取分析结果
    /// - Parameters:
    ///   - image: 图片
    ///   - userId: 用户ID
    ///   - onProgress: 进度回调
    ///   - completion: 完成回调
    func uploadImage(
        _ image: UIImage,
        userId: String,
        onProgress: @escaping (Double) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // 验证图片
        let validation = validateImage(image)
        guard validation.isValid else {
            completion(.failure(NSError(domain: "ImageUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: validation.error ?? "图片验证失败"])))
            return
        }
        
        isUploading = true
        
        // 转换为Base64
        guard let imageURI = convertToBase64(image, maxKB: 1024) else {
            isUploading = false
            completion(.failure(NSError(domain: "ImageUpload", code: -2, userInfo: [NSLocalizedDescriptionKey: "图片转换失败"])))
            return
        }
        
        onProgress(0.5) // 压缩完成
        
        // 调用API分析图片
        Task {
            do {
                let result = try await APIService.shared.analyzeImage(
                    userId: userId,
                    imageURI: imageURI
                )
                
                await MainActor.run {
                    self.isUploading = false
                    onProgress(1.0)
                    completion(.success(result))
                }
            } catch {
                await MainActor.run {
                    self.isUploading = false
                    completion(.failure(error))
                }
            }
        }
    }
}

// MARK: - 图片上传视图

/// 图片上传进度视图
struct ImageUploadProgressView: View {
    let progress: Double
    let isUploading: Bool
    
    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: progress)
                .progressViewStyle(CircularProgressViewStyle())
            
            Text(isUploading ? "正在上传..." : "上传完成")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 4)
    }
}

// MARK: - 图片选择器（带优化）

/// 优化的图片选择器
struct OptimizedImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImagePicked: (UIImage) -> Void
    let onError: (String) -> Void
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        
        // 限制图片大小
        picker.allowsEditing = false
        
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked, onError: onError)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImagePicked: (UIImage) -> Void
        let onError: (String) -> Void
        
        init(onImagePicked: @escaping (UIImage) -> Void, onError: @escaping (String) -> Void) {
            self.onImagePicked = onImagePicked
            self.onError = onError
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            picker.dismiss(animated: true)
            
            if let image = info[.originalImage] as? UIImage {
                // 验证图片
                let validation = ImageUploadManager.shared.validateImage(image)
                
                if validation.isValid {
                    HapticManager.light()
                    onImagePicked(image)
                } else {
                    HapticManager.error()
                    onError(validation.error ?? "图片选择失败")
                }
            } else {
                HapticManager.error()
                onError("无法获取图片")
            }
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - 图片上传状态

/// 图片上传状态
enum ImageUploadState {
    case idle
    case picking
    case compressing
    case uploading(progress: Double)
    case success
    case error(message: String)
}

// MARK: - 使用示例

/*
// 在ViewModel中使用
class ChatViewModel: ObservableObject {
    @Published var uploadState: ImageUploadState = .idle
    
    func handleSelectedImage(_ image: UIImage, userId: String) {
        uploadState = .compressing
        HapticManager.light()
        
        ImageUploadManager.shared.uploadImage(
            image,
            userId: userId
        ) { progress in
            DispatchQueue.main.async {
                self.uploadState = .uploading(progress: progress)
            }
        } completion: { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let response):
                    self.uploadState = .success
                    // 处理成功
                case .failure(let error):
                    self.uploadState = .error(message: error.localizedDescription)
                    HapticManager.error()
                }
            }
        }
    }
}

// 在View中使用
struct ChatView: View {
    @State private var showImagePicker = false
    @State private var uploadError: String?
    @State private var showUploadProgress = false
    
    var body: some View {
        VStack {
            // 对话内容...
            
            if showUploadProgress {
                ImageUploadProgressView(
                    progress: viewModel.uploadProgress,
                    isUploading: viewModel.isUploading
                )
            }
        }
        .sheet(isPresented: $showImagePicker) {
            if #available(iOS 14.0, *) {
                OptimizedImagePicker(
                    sourceType: .photoLibrary,
                    onImagePicked: { image in
                        viewModel.handleSelectedImage(image, userId: userId)
                    },
                    onError: { error in
                        uploadError = error
                    }
                )
            }
        }
        .alert("图片上传", isPresented: .constant(uploadError != nil)) {
            Button("确定") { uploadError = nil }
        } message: {
            Text(uploadError ?? "")
        }
    }
}
*/
