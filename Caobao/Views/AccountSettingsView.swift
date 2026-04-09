import SwiftUI

// MARK: - Account Settings View
/// 账号设置视图
/// 符合《个人信息保护法》和 Apple App Store 审核指南要求
struct AccountSettingsView: View {
    @StateObject private var authService = AuthService.shared
    @State private var showDeleteConfirmation = false
    @State private var showExportConfirmation = false
    @State private var deleteConfirmationText = ""
    @State private var isLoading = false
    @State private var alertMessage: String?
    @State private var showSuccessAlert = false
    @State private var alertTitle = "提示"
    @State private var exportedData: IdentifiableString?
    
    var body: some View {
        List {
            // MARK: - 账号信息
            Section {
                if let user = authService.user {
                    HStack {
                        Text("用户ID")
                        Spacer()
                        Text(user.id)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    
                    if let name = user.name {
                        HStack {
                            Text("昵称")
                            Spacer()
                            Text(name)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    HStack {
                        Text("登录方式")
                        Spacer()
                        Text(user.isGuest == true ? "游客" : user.authProvider.capitalized)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("账号信息")
            }
            
            // MARK: - 数据管理
            Section {
                // 导出数据
                Button {
                    Task {
                        await exportUserData()
                    }
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.green)
                        Text("导出我的数据")
                            .foregroundStyle(.primary)
                        Spacer()
                        if isLoading {
                            ProgressView()
                        }
                    }
                }
                .disabled(isLoading)
                
                Text("根据《个人信息保护法》第45条，您有权获取您的个人数据副本")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("数据管理")
            } footer: {
                Text("导出的数据为 JSON 格式，可用于迁移至其他服务或本地备份")
            }
            
            // MARK: - 账号注销
            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.xmark")
                        Text("注销账号")
                    }
                }
                
                Text("注销后，您的所有数据将被永久删除且无法恢复")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("账号注销")
            } footer: {
                Text("根据《个人信息保护法》第15条和第47条，您有权撤回同意并要求删除您的个人信息。注销后15个工作日内完成数据处理。")
            }
            
            // MARK: - 法律信息
            Section {
                NavigationLink {
                    LegalView(type: .privacy)
                } label: {
                    HStack {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(.green)
                            .frame(width: 24)
                        Text("隐私政策")
                    }
                }
                
                NavigationLink {
                    LegalView(type: .agreement)
                } label: {
                    HStack {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(.green)
                            .frame(width: 24)
                        Text("用户协议")
                    }
                }
                
                NavigationLink {
                    LegalView(type: .children)
                } label: {
                    HStack {
                        Image(systemName: "figure.and.child.holdinghands")
                            .foregroundStyle(.green)
                            .frame(width: 24)
                        Text("未成年人保护")
                    }
                }
            } header: {
                Text("法律信息")
            }
            
            // MARK: - 联系方式
            Section {
                HStack {
                    Image(systemName: "envelope.fill")
                        .foregroundStyle(.green)
                    Text("客服邮箱")
                    Spacer()
                    Text("2900814034@qq.com")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            } header: {
                Text("联系我们")
            } footer: {
                Text("如有任何问题或投诉，我们将在15个工作日内回复")
            }
        }
        .navigationTitle("账号设置")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // 注销确认弹窗
        .alert("注销账号", isPresented: $showDeleteConfirmation) {
            TextField("请输入\"确认注销\"", text: $deleteConfirmationText)
            
            Button("取消", role: .cancel) {
                deleteConfirmationText = ""
            }
            
            Button("确认注销", role: .destructive) {
                Task {
                    await deleteAccount()
                }
            }
            .disabled(deleteConfirmationText != "确认注销")
        } message: {
            Text("此操作不可撤销，所有数据将被永久删除。\n请输入\"确认注销\"以继续")
        }
        // 提示弹窗
        .alert(alertTitle, isPresented: $showSuccessAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(alertMessage ?? "")
        }
        // 导出数据结果
        .sheet(item: $exportedData) { identifiableData in
            ExportDataSheet(data: identifiableData.value)
        }
    }
    
    // MARK: - 导出数据
    private func exportUserData() async {
        isLoading = true
        do {
            let result = try await authService.exportData()
            if result.success {
                if let data = result.data,
                   let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    exportedData = IdentifiableString(jsonString)
                }
            } else {
                alertTitle = "导出失败"
                alertMessage = "服务器返回了失败响应"
                showSuccessAlert = true
            }
        } catch {
            alertTitle = "导出失败"
            // 处理不同类型的错误
            if let authError = error as? AuthError {
                switch authError {
                case .notLoggedIn:
                    alertMessage = "请先登录后再导出数据"
                case .exportFailed(let message):
                    alertMessage = message
                default:
                    alertMessage = authError.errorDescription
                }
            } else {
                alertMessage = error.localizedDescription
            }
            showSuccessAlert = true
        }
        isLoading = false
    }
    
    // MARK: - 注销账号
    private func deleteAccount() async {
        isLoading = true
        do {
            let _ = try await authService.deleteAccount(
                confirmation: "确认注销",
                reason: "用户主动申请注销"
            )
            // 清除所有本地数据
            clearAllLocalData()
            // 导航回首页
            alertTitle = "操作成功"
            alertMessage = "账号已成功注销，正在返回首页..."
            showSuccessAlert = true
            // 延迟导航
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first {
                    window.rootViewController?.dismiss(animated: true)
                }
            }
            deleteConfirmationText = ""
        } catch {
            alertTitle = "注销失败"
            alertMessage = error.localizedDescription
            showSuccessAlert = true
        }
        isLoading = false
    }
    
    // MARK: - 清除所有本地数据
    private func clearAllLocalData() {
        // 清除 UserDefaults 中的数据
        let keysToRemove = [
            "conversationHistory",  // 对话历史
            "caobao_guest_id",
            "caobao_guest_token",
            "caobao_guest_created_at",
            "caobao_chat_history",
            "caobao_settings",
            "caobao_user_preferences"
        ]
        
        for key in keysToRemove {
            UserDefaults.standard.removeObject(forKey: key)
        }
        
        // 清除 AuthService 的登录状态
        authService.logout()
        
        print("已清除所有本地数据")
    }
}

// MARK: - Export Data Sheet
struct ExportDataSheet: View {
    let data: String
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                Text(data)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
            }
            .navigationTitle("导出的数据")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: data) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

// Helper struct for identifiable strings (for sheet presentation)
struct IdentifiableString: Identifiable {
    let id: String
    let value: String
    
    init(_ value: String) {
        self.id = value
        self.value = value
    }
}

#Preview {
    NavigationView {
        AccountSettingsView()
    }
}
