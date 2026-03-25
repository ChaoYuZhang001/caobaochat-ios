//
//  FavoritesView.swift
//  Caobao
//
//  收藏页面
//

import SwiftUI

// MARK: - 收藏列表视图
struct FavoritesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var favorites: [FavoriteItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedType: String?
    @State private var showDeleteConfirmation = false
    @State private var itemToDelete: FavoriteItem?
    
    private let types = [
        ("全部", nil),
        ("金句", "quote"),
        ("昵称", "nickname"),
        ("消息", "message"),
        ("图片", "image")
    ]
    
    private var filteredFavorites: [FavoriteItem] {
        if let type = selectedType {
            return favorites.filter { $0.type == type }
        }
        return favorites
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 类型筛选
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(types, id: \.1) { type in
                            Button {
                                selectedType = type.1
                            } label: {
                                Text(type.0)
                                    .font(.subheadline)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(selectedType == type.1 ? Color.green : Color(.systemGray6))
                                    .foregroundColor(selectedType == type.1 ? .white : .primary)
                                    .cornerRadius(20)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .background(Color(.systemBackground))
                
                if isLoading {
                    Spacer()
                    ProgressView("加载中...")
                    Spacer()
                } else if let error = errorMessage {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 50))
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") {
                            loadFavorites()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    Spacer()
                } else if filteredFavorites.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "heart.slash")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        Text(selectedType == nil ? "暂无收藏" : "该类型暂无收藏")
                            .font(.headline)
                        Text("收藏的内容将显示在这里")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(filteredFavorites) { item in
                            favoriteRow(item)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        itemToDelete = item
                                        showDeleteConfirmation = true
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("我的收藏")
                        .font(.headline)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("返回") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text("\(filteredFavorites.count) 条")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onAppear {
                loadFavorites()
            }
            .alert("确认删除", isPresented: $showDeleteConfirmation) {
                Button("取消", role: .cancel) {
                    itemToDelete = nil
                }
                Button("删除", role: .destructive) {
                    if let item = itemToDelete {
                        deleteFavorite(item)
                    }
                }
            } message: {
                Text("确定要删除这条收藏吗？")
            }
        }
    }
    
    private func favoriteRow(_ item: FavoriteItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 类型标签
            HStack {
                Image(systemName: item.icon)
                    .foregroundColor(item.typeColor)
                Text(item.typeName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(item.typeColor)
                
                Spacer()
                
                Text(formatDate(item.created_at))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // 内容
            Text(item.content)
                .font(.subheadline)
                .foregroundColor(.primary)
                .lineLimit(3)
            
            // 上下文（如果有）
            if let context = item.context, !context.isEmpty {
                Text(context)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .padding(.top, 4)
                    .padding(.leading, 8)
                    .overlay(
                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(width: 2),
                        alignment: .leading
                    )
            }
        }
        .padding(.vertical, 8)
    }
    
    private func formatDate(_ dateString: String) -> String {
        let inputFormatter = ISO8601DateFormatter()
        inputFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        guard let date = inputFormatter.date(from: dateString) else {
            return dateString
        }
        
        let outputFormatter = DateFormatter()
        outputFormatter.dateFormat = "MM-dd HH:mm"
        return outputFormatter.string(from: date)
    }
    
    private func loadFavorites() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                // 使用无 token 版本的方法
                let items = try await APIService.shared.getFavorites(userId: nil, type: nil)
                await MainActor.run {
                    favorites = items
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
    
    private func deleteFavorite(_ item: FavoriteItem) {
        Task {
            do {
                try await APIService.shared.deleteFavorite(id: item.id)
                await MainActor.run {
                    favorites.removeAll { $0.id == item.id }
                    itemToDelete = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = "删除失败: \(error.localizedDescription)"
                }
            }
        }
    }
}

#Preview {
    FavoritesView()
}
