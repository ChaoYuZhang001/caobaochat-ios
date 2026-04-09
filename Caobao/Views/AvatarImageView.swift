//
//  AvatarImageView.swift
//  草包AI - 优化的头像加载组件
//
//  功能：
//  - 支持 WebP 格式（优先）
//  - PNG 降级支持
//  - 自动缓存
//  - 懒加载优化
//  - 错误处理
//

import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - AvatarImageView
struct AvatarImageView: View {
    let avatarId: String
    @State private var isLoading = true
    @State private var image: Image?
    @State private var loadError = false
    
    var body: some View {
        Group {
            if let image = image {
                // 成功加载的图片
                image
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            } else if loadError {
                // 加载失败，显示默认图标
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.gray)
            } else if isLoading {
                // 加载中显示占位符
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 40, height: 40)
            }
        }
        .task {
            await loadImage()
        }
    }
    
    // MARK: - Load Image
    private func loadImage() async {
        // 优先尝试 WebP 格式
        await loadAvatar(format: "webp")
    }
    
    // MARK: - Load Avatar with Format
    private func loadAvatar(format: String) async {
        isLoading = true
        loadError = false
        
        // 构建 URL
        let urlString = "https://caobao.coze.site/avatars/\(avatarId).\(format)"
        guard let url = URL(string: urlString) else {
            await handleError()
            return
        }
        
        do {
            // 下载图片
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // 验证图片数据
            #if os(iOS)
            if let uiImage = UIImage(data: data) {
                await MainActor.run {
                    self.image = Image(uiImage: uiImage)
                    self.isLoading = false
                    self.loadError = false
                }
            } else {
                // 图片数据无效
                if format == "webp" {
                    // WebP 失败，尝试 PNG
                    await loadAvatar(format: "png")
                } else {
                    await handleError()
                }
            }
            #else
            if let nsImage = NSImage(data: data) {
                await MainActor.run {
                    self.image = Image(nsImage: nsImage)
                    self.isLoading = false
                    self.loadError = false
                }
            } else {
                // 图片数据无效
                if format == "webp" {
                    // WebP 失败，尝试 PNG
                    await loadAvatar(format: "png")
                } else {
                    await handleError()
                }
            }
            #endif
        } catch {
            // 下载失败
            if format == "webp" {
                // WebP 失败，尝试 PNG
                await loadAvatar(format: "png")
            } else {
                await handleError()
            }
        }
    }
    
    // MARK: - Handle Error
    private func handleError() async {
        await MainActor.run {
            self.isLoading = false
            self.loadError = true
            self.image = nil
        }
    }
}

// MARK: - Preview
#Preview {
    VStack(spacing: 20) {
        Text("头像加载预览")
            .font(.headline)
        
        HStack(spacing: 20) {
            AvatarImageView(avatarId: "avatar1")
                .frame(width: 76, height: 76)
            
            AvatarImageView(avatarId: "avatar2")
                .frame(width: 76, height: 76)
            
            AvatarImageView(avatarId: "avatar3")
                .frame(width: 76, height: 76)
        }
    }
    .padding()
}
