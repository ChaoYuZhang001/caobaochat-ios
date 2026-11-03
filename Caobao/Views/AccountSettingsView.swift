import SwiftUI
import UniformTypeIdentifiers

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
    @State private var alertTitle = AssistantLocalization.string("提示")
    @State private var exportedData: IdentifiableString?
    @State private var accountOperationId: UUID?
    @State private var deletionSource: AccountOwnerConfirmation?
    @State private var accountOwnerEpoch = UUID()
    private struct AccountOwnerConfirmation { let id = UUID(); let ownerId: String?; let epoch: UUID }
    private var ownerObservationKey: String {
        authService.user.map { AssistantOwnerIdentity.ownerKey($0.id) } ?? "signed-out"
    }
    
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
                        Text(user.isGuest == true ? AssistantLocalization.string("游客") : user.authProvider.capitalized)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("账号信息")
            }
            
            // MARK: - 数据管理
            Section {
                NavigationLink {
                    AssistantDataManagementView(ownerId: authService.user?.id ?? "local-device")
                } label: { Label("导出此设备的数据", systemImage: "externaldrive") }
                // 导出数据
                Button {
                    let owner = authService.user?.id
                    let epoch = accountOwnerEpoch
                    Task {
                        await exportUserData(expectedOwner: owner, expectedEpoch: epoch)
                    }
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.green)
                        Text("导出服务器账号数据")
                            .foregroundStyle(.primary)
                        Spacer()
                        if isLoading {
                            ProgressView()
                        }
                    }
                }
                .disabled(isLoading || !authService.isLoggedIn)
                
                Text("本机助理数据与服务器账号资料分别导出，避免把其中一部分误认为全部数据。")
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
                    deletionSource = AccountOwnerConfirmation(ownerId: authService.user?.id, epoch: accountOwnerEpoch)
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.xmark")
                        Text("注销账号")
                    }
                }
                .disabled(isLoading)
                
                Text("提交后将申请删除账号及相关个人数据。删除完成后无法恢复，请先导出需要保留的数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("账号注销")
            } footer: {
                Text("服务器受理后将按删除流程处理，处理状态以服务器返回为准。")
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
                Text("如有问题或投诉，请通过客服邮箱联系我们。")
            }
        }
        .assistantNavigationTitle("账号设置")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // 注销确认弹窗
        .alert("注销账号", isPresented: Binding(
            get: { showDeleteConfirmation && deletionSource.map { $0.epoch == accountOwnerEpoch && AssistantOwnerIdentity.matches($0.ownerId, authService.user?.id) } == true },
            set: { showDeleteConfirmation = $0 }), presenting: deletionSource) { source in
            TextField(AuthService.accountDeletionConfirmationToken, text: $deleteConfirmationText)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            
            Button("取消", role: .cancel) {
                deleteConfirmationText = ""
                if deletionSource?.id == source.id { deletionSource = nil }
            }
            
            Button("确认注销", role: .destructive) {
                let confirmation = deleteConfirmationText
                Task {
                    await deleteAccount(expectedOwner: source.ownerId, confirmation: confirmation, sourceId: source.id, expectedEpoch: source.epoch)
                }
            }
            .disabled(isLoading || deleteConfirmationText != AuthService.accountDeletionConfirmationToken)
        } message: { _ in
            Text(String(format: AssistantLocalization.string("此操作将提交账号删除请求。删除完成后无法恢复。\n请输入“%@”以继续"), AuthService.accountDeletionConfirmationToken))
        }
        // 提示弹窗
        .alert(alertTitle, isPresented: $showSuccessAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(alertMessage ?? "")
        }
        // 导出数据结果
        .sheet(item: $exportedData) { identifiableData in
            if let owner = identifiableData.ownerId, AssistantOwnerIdentity.matches(authService.user?.id, owner) {
                ExportDataSheet(data: identifiableData.value, ownerId: owner)
            }
        }
        .onChange(of: ownerObservationKey) { _ in resetAccountOwnerScope() }
        .onReceive(NotificationCenter.default.publisher(for: .loginSuccess)) { _ in resetAccountOwnerScope() }
        .onReceive(NotificationCenter.default.publisher(for: .logoutSuccess)) { _ in resetAccountOwnerScope() }
    }
    
    // MARK: - 导出数据
    private func resetAccountOwnerScope() {
        accountOwnerEpoch = UUID()
        accountOperationId = nil; isLoading = false; exportedData = nil
        deletionSource = nil; showDeleteConfirmation = false; showExportConfirmation = false
        showSuccessAlert = false; deleteConfirmationText = ""; alertMessage = nil
    }

    private func exportUserData(expectedOwner owner: String?, expectedEpoch: UUID) async {
        guard expectedEpoch == accountOwnerEpoch, AssistantOwnerIdentity.matches(authService.user?.id, owner) else { return }
        let operation = UUID()
        accountOperationId = operation
        isLoading = true
        defer { if accountOperationId == operation { isLoading = false; accountOperationId = nil } }
        do {
            let result = try await authService.exportData()
            guard accountOperationId == operation, AssistantOwnerIdentity.matches(authService.user?.id, owner) else { return }
            if result.success {
                if let rawJSON = result.rawJSON {
                    exportedData = IdentifiableString(rawJSON, ownerId: owner)
                } else if let data = result.data,
                   let jsonData = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    exportedData = IdentifiableString(jsonString, ownerId: owner)
                }
            } else {
                alertTitle = AssistantLocalization.string("导出失败")
                alertMessage = AssistantLocalization.string("服务器返回了失败响应")
                showSuccessAlert = true
            }
        } catch {
            guard accountOperationId == operation, AssistantOwnerIdentity.matches(authService.user?.id, owner) else { return }
            alertTitle = AssistantLocalization.string("导出失败")
            // 处理不同类型的错误
            if let authError = error as? AuthError {
                switch authError {
                case .notLoggedIn:
                    alertMessage = AssistantLocalization.string("请先登录后再导出数据")
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
    }
    
    // MARK: - 注销账号
    private func deleteAccount(expectedOwner owner: String?, confirmation: String, sourceId: UUID, expectedEpoch: UUID) async {
        guard deletionSource?.id == sourceId, expectedEpoch == accountOwnerEpoch,
              AssistantOwnerIdentity.matches(authService.user?.id, owner) else { return }
        let operation = UUID()
        accountOperationId = operation
        isLoading = true
        defer { if accountOperationId == operation { isLoading = false; accountOperationId = nil } }
        do {
            let result = try await authService.deleteAccount(
                confirmation: confirmation,
                reason: "用户主动申请注销"
            )
            guard accountOperationId == operation,
                  AssistantOwnerIdentity.matches(authService.user?.id, owner) || authService.user == nil else { return }
            // AuthService owns scoped cleanup and session changes. A delayed
            // response must not clear or log out a subsequently signed-in account.
            alertTitle = AssistantLocalization.string("操作成功")
            alertMessage = result.message ?? AssistantLocalization.string("账号删除请求已提交，处理状态以服务器返回为准。")
            showSuccessAlert = true
            deleteConfirmationText = ""
        } catch {
            guard accountOperationId == operation, AssistantOwnerIdentity.matches(authService.user?.id, owner) else { return }
            alertTitle = AssistantLocalization.string("操作未完成")
            alertMessage = error.localizedDescription
            showSuccessAlert = true
        }
    }

}

// MARK: - Export Data Sheet
struct ExportDataSheet: View {
    let data: String
    let ownerId: String
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.dismiss) var dismiss
    @State private var document: AssistantBackupDocument?
    @State private var isSavingFile = false
    @State private var saveMessage: String?
    @State private var documentOwnerId: String?
    @State private var sheetOwnerId: String
    private var hasCurrentOwner: Bool {
        AssistantOwnerIdentity.matches(ownerId, sheetOwnerId) && AssistantOwnerIdentity.matches(auth.user?.id, ownerId)
    }
    private var hasCurrentDocument: Bool { hasCurrentOwner && AssistantOwnerIdentity.matches(documentOwnerId, ownerId) }
    init(data: String, ownerId: String) {
        self.data = data; self.ownerId = ownerId; _sheetOwnerId = State(initialValue: ownerId)
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                if hasCurrentOwner {
                VStack(alignment: .leading, spacing: 14) {
                    Text("服务器账号数据").font(.headline)
                    Text("本机助理数据需在“数据与隐私”中单独备份。此处只展示服务器返回的资料。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(String(decoding: data.utf8.prefix(16_384), as: UTF8.self))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if data.utf8.count > 16_384 {
                        Text("预览已截断；保存的 JSON 文件包含完整导出数据。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let saveMessage { Text(saveMessage).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
                } else { Text("当前账号已变化，请重新打开页面。").padding() }
            }
            .assistantNavigationTitle("导出的数据")
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
                    Button("保存 JSON 文件") {
                        guard hasCurrentOwner else { return }
                        documentOwnerId = ownerId; document = AssistantBackupDocument(data: Data(data.utf8)); isSavingFile = true
                    }.disabled(isSavingFile || !hasCurrentOwner)
                }
            }
            .fileExporter(isPresented: Binding(get: { isSavingFile && hasCurrentDocument }, set: { isSavingFile = $0 }),
                          document: hasCurrentDocument ? document : nil, contentType: .json,
                          defaultFilename: "CaoBao-server-account-data") { result in
                guard hasCurrentDocument else { return }
                document = nil
                switch result {
                case .success: saveMessage = AssistantLocalization.string("服务器数据文件已保存。")
                case .failure(let error):
                    saveMessage = (error as? CocoaError)?.code == .userCancelled
                        ? AssistantLocalization.string("已取消保存，未导出文件。") : error.localizedDescription
                }
            }
            .onChange(of: auth.user.map { AssistantOwnerIdentity.ownerKey($0.id) } ?? "signed-out") { _ in resetExportOwnerScope() }
            .onChange(of: AssistantOwnerIdentity.ownerKey(ownerId)) { _ in resetExportOwnerScope() }
            .onReceive(NotificationCenter.default.publisher(for: .loginSuccess)) { _ in resetExportOwnerScope() }
            .onReceive(NotificationCenter.default.publisher(for: .logoutSuccess)) { _ in resetExportOwnerScope() }
        }
    }
    private func resetExportOwnerScope() {
        isSavingFile = false; document = nil; documentOwnerId = nil; saveMessage = nil; dismiss()
    }
}

// Helper struct for identifiable strings (for sheet presentation)
struct IdentifiableString: Identifiable {
    let id = UUID()
    let value: String
    let ownerId: String?
    
    init(_ value: String, ownerId: String?) {
        self.value = value
        self.ownerId = ownerId
    }
}

#Preview {
    NavigationView {
        AccountSettingsView()
    }
}
