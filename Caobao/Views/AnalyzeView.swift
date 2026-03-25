import SwiftUI
import PhotosUI

// MARK: - Analyze View (图片分析)
struct AnalyzeView: View {
    @State private var selectedImage: UIImage?
    @State private var showingImagePicker = false
    @State private var showingCamera = false
    @State private var prompt = "请分析这张图片"
    @State private var loading = false
    @State private var result = ""
    @State private var copied = false
    
    #if os(iOS)
    @State private var selectedItem: PhotosPickerItem?
    #endif
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // 图片选择区域
                        VStack(spacing: 16) {
                            if let image = selectedImage {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 250)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.green, lineWidth: 2)
                                    )
                                
                                // 更换图片按钮
                                HStack(spacing: 16) {
                                    Button {
                                        showingImagePicker = true
                                    } label: {
                                        Label("相册", systemImage: "photo")
                                            .font(.subheadline)
                                    }
                                    
                                    #if os(iOS)
                                    Button {
                                        showingCamera = true
                                    } label: {
                                        Label("相机", systemImage: "camera")
                                            .font(.subheadline)
                                    }
                                    #endif
                                    
                                    Button {
                                        selectedImage = nil
                                        result = ""
                                    } label: {
                                        Label("清除", systemImage: "trash")
                                            .font(.subheadline)
                                            .foregroundStyle(.red)
                                    }
                                }
                            } else {
                                // 占位图
                                VStack(spacing: 16) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.system(size: 60))
                                        .foregroundStyle(.green.opacity(0.5))
                                    
                                    Text("选择或拍摄图片")
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                    
                                    HStack(spacing: 24) {
                                        #if os(iOS)
                                        PhotosPicker(selection: $selectedItem, matching: .images) {
                                            Label("相册", systemImage: "photo.fill")
                                                .padding()
                                                .background(Color.green.opacity(0.1))
                                                .foregroundStyle(.green)
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                        }
                                        .onChange(of: selectedItem) { _ in
                                            Task {
                                                if let data = try? await selectedItem?.loadTransferable(type: Data.self),
                                                   let image = UIImage(data: data) {
                                                    selectedImage = image
                                                }
                                            }
                                        }
                                        
                                        Button {
                                            showingCamera = true
                                        } label: {
                                            Label("相机", systemImage: "camera.fill")
                                                .padding()
                                                .background(Color.green.opacity(0.1))
                                                .foregroundStyle(.green)
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                        }
                                        #else
                                        Button {
                                            showingImagePicker = true
                                        } label: {
                                            Label("选择图片", systemImage: "photo.fill")
                                                .padding()
                                                .background(Color.green.opacity(0.1))
                                                .foregroundStyle(.green)
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                        }
                                        #endif
                                    }
                                }
                                .frame(height: 250)
                                .frame(maxWidth: .infinity)
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        // 分析提示词
                        VStack(alignment: .leading, spacing: 12) {
                            Text("分析指令")
                                .font(.headline)
                            
                            TextField("请分析这张图片", text: $prompt)
                                .textFieldStyle(.roundedBorder)
                            
                            // 快捷提示词
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(quickPrompts, id: \.self) { p in
                                        Button {
                                            prompt = p
                                        } label: {
                                            Text(p)
                                                .font(.caption)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(Color.green.opacity(0.1))
                                                .foregroundStyle(.green)
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(Color(.systemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        
                        // 分析按钮
                        Button {
                            analyzeImage()
                        } label: {
                            HStack {
                                if loading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(loading ? "分析中..." : "开始分析")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(loading || selectedImage == nil)
                        .opacity(selectedImage == nil ? 0.5 : 1)
                        
                        // 分析结果
                        if !result.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("分析结果")
                                        .font(.headline)
                                    
                                    Spacer()
                                    
                                    Button {
                                        copyResult()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                            Text(copied ? "已复制" : "复制")
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                    }
                                }
                                
                                ScrollView {
                                    Text(result)
                                        .font(.body)
                                        .lineSpacing(6)
                                }
                                .frame(maxHeight: 300)
                            }
                            .padding()
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("图片分析")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingCamera) {
                CameraView(image: $selectedImage)
            }
            #endif
        }
    }
    
    // MARK: - Data
    private let quickPrompts = [
        "请分析这张图片",
        "描述图片内容",
        "识别图中的文字",
        "分析图片情感",
        "这张图片想表达什么",
    ]
    
    // MARK: - Actions
    private func analyzeImage() {
        guard let image = selectedImage,
              let imageData = image.jpegData(compressionQuality: 0.8) else { return }
        
        loading = true
        result = ""
        
        Task {
            do {
                let stream = try await APIService.shared.analyzeImage(imageData: imageData, prompt: prompt)
                
                for try await chunk in stream {
                    await MainActor.run {
                        result += chunk
                    }
                }
                
                await MainActor.run {
                    loading = false
                }
            } catch {
                await MainActor.run {
                    loading = false
                    result = "分析失败，请重试"
                }
            }
        }
    }
    
    private func copyResult() {
        #if os(iOS)
        UIPasteboard.general.string = result
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}

// MARK: - Camera View (iOS)
#if os(iOS)
struct CameraView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        
        init(_ parent: CameraView) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.image = image
            }
            picker.dismiss(animated: true)
        }
    }
}
#endif

#Preview {
    AnalyzeView()
}
