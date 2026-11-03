import SwiftUI
import UniformTypeIdentifiers

/// Local snapshots are separate from the server's account export. Preparing a
/// document never uploads it; the user chooses the destination in Files.
struct AssistantDataManagementView: View {
    let ownerId: String
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var chat = ChatViewModel.shared
    @Environment(\.locale) private var locale
    @State private var includeImages = true
    @State private var isPreparing = false
    @State private var exportTask: Task<Void, Never>?
    @State private var exportRunId: UUID?
    @State private var document: AssistantBackupDocument?
    @State private var preparedOwnerId: String?
    @State private var summary: BackupSummary?
    @State private var statusMessage: String?
    @State private var operationError: String?
    @State private var showFileExporter = false
    @State private var identityEpoch = UUID()
    @State private var showFileImporter = false
    @State private var filePickerSource: ImportPickerSource?
    @State private var importTask: Task<Void, Never>?
    @State private var importRunId: UUID?
    @State private var isReadingImport = false
    @State private var isRestoringImport = false
    @State private var importPlan: AssistantDataImportPlan?
    @State private var importResult: AssistantDataImportResult?
    @State private var importError: String?
    @State private var importStatus: String?
    @State private var importWasAttempted = false
    @State private var showImportConfirmation = false
    @State private var confirmationSource: ImportConfirmationSource?
    private let exporter = AssistantDataExporter()
    private let importer = AssistantDataImporter(maximumBytes: 32 * 1024 * 1024)
    private var currentOwner: String { auth.user?.id ?? "local-device" }
    private var hasCurrentScope: Bool { AssistantOwnerIdentity.matches(ownerId, currentOwner) }
    private var hasCurrentPreparedDocument: Bool {
        hasCurrentScope && AssistantOwnerIdentity.matches(preparedOwnerId, ownerId)
    }
    private var hasCurrentImportPlan: Bool {
        hasCurrentScope && importPlan.map { AssistantOwnerIdentity.matches($0.ownerId, ownerId) } == true
    }
    private var isExportBusy: Bool { isPreparing || showFileExporter }
    private var isImportBusy: Bool { isReadingImport || isRestoringImport || showFileImporter || showImportConfirmation }
    private var localDataIsBusy: Bool {
        chat.isArchiveBusy || chat.archiveIsLoading || chat.isLoading || chat.isPreparingImage || chat.taskToolOperationMessageId != nil
    }

    var body: some View {
        let pickerSource = filePickerSource
        let approvalSource = confirmationSource
        return content
        .assistantNavigationTitle("数据与隐私")
        .fileExporter(isPresented: Binding(get: { showFileExporter && hasCurrentPreparedDocument }, set: { showFileExporter = $0 }),
                      document: hasCurrentPreparedDocument ? document : nil, contentType: .json,
                      defaultFilename: "CaoBao-assistant-backup") { result in
            handleFileSave(result)
        }
        .fileImporter(isPresented: Binding(get: { showFileImporter && hasCurrentScope }, set: { showFileImporter = $0 }),
                      allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            handleFileImport(result, source: pickerSource)
        }
        .confirmationDialog("合并此备份到当前本地数据？", isPresented: Binding(
            get: { showImportConfirmation && hasCurrentImportPlan }, set: { showImportConfirmation = $0 }), titleVisibility: .visible) {
            Button("确认合并") { restoreBackup(source: approvalSource) }
            Button("取消", role: .cancel) { confirmationSource = nil }
        } message: {
            Text("只新增记录，保留本地冲突和删除标记。会话与工作区分别原子保存；中断或失败后可能已有部分数据写入，可用同一文件重试。不会开启提醒或执行工具。")
        }
        .onChange(of: AssistantOwnerIdentity.ownerKey(ownerId)) { _ in resetForIdentityChange() }
        .onChange(of: AssistantOwnerIdentity.ownerKey(currentOwner)) { _ in resetForIdentityChange() }
        .onReceive(NotificationCenter.default.publisher(for: .loginSuccess)) { _ in resetForIdentityChange() }
        .onReceive(NotificationCenter.default.publisher(for: .logoutSuccess)) { _ in resetForIdentityChange() }
        .onChange(of: includeImages) { _ in document = nil; summary = nil; statusMessage = nil }
        .onDisappear {
            cancelPreparation()
            cancelImport(clearPlan: true)
            if !showFileExporter { document = nil; summary = nil; preparedOwnerId = nil }
        }
    }

    private var content: some View {
        List {
            scopeSection
            if hasCurrentScope {
            exportSection
            if hasCurrentPreparedDocument, let summary { summarySection(summary) }
            if let statusMessage { Text(statusMessage).font(.subheadline).foregroundStyle(.secondary) }
            if let operationError { Text(operationError).font(.subheadline).foregroundStyle(.red).textSelection(.enabled) }
            importSection
            if hasCurrentImportPlan, let importPlan { importPreviewSection(importPlan) }
            if hasCurrentImportPlan, let importResult { importResultSection(importResult) }
            if let importStatus { Text(importStatus).font(.subheadline).foregroundStyle(.secondary) }
            if let importError { Text(importError).font(.subheadline).foregroundStyle(.red).textSelection(.enabled) }
            } else { Text("账号已变化，请重新打开数据导出。") }
        }
    }

    private var scopeSection: some View {
        Section("此设备上的助理数据") {
            Label("会话、消息和输入草稿", systemImage: "bubble.left.and.bubble.right")
            Text("备份包含当前输入及其他会话保存的未发送草稿；图片是否导出由下方开关决定。")
                .font(.caption).foregroundStyle(.secondary)
            Label("记忆及其使用开关", systemImage: "brain.head.profile")
            Label("任务、状态和提醒设置", systemImage: "checklist")
            Text("备份还包含 AI 待办提案和处理记录；导出不会再次创建任务或开启提醒。")
                .font(.caption).foregroundStyle(.secondary)
            Text("只导出当前用户在此设备的数据，不会读取或附加登录凭据、API Key 或连接配置。你主动写入会话和记忆的原文会保留。")
                .font(.caption).foregroundStyle(.secondary)
            Text("服务器账号资料需在账号设置中单独导出；本备份不代表云同步，也不会自动恢复或启用提醒。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var exportSection: some View {
        Section("导出本地备份") {
            Toggle("包括图片附件", isOn: $includeImages).disabled(isExportBusy || isImportBusy)
            Text("关闭图片导出时，文字和记录仍会保留，文件会标明省略的图片附件数量。单个备份最大 32 MB。")
                .font(.caption).foregroundStyle(.secondary)
            Text("JSON 备份文件未额外加密，可能包含私人内容。请只保存或分享至你信任的位置。")
                .font(.caption).foregroundStyle(.secondary)
            if isPreparing {
                HStack {
                    ProgressView()
                    Text("正在准备备份…")
                    Spacer()
                    Button("取消准备") { cancelPreparation() }
                }
            } else {
                Button { prepareBackup() } label: { Label("导出此设备的数据", systemImage: "square.and.arrow.up") }
                    .disabled(ownerId.isEmpty || !AssistantOwnerIdentity.matches(ownerId, currentOwner) || isImportBusy)
            }
        }
    }

    private var importSection: some View {
        Section("导入本地备份") {
            Text("选择不超过 32 MB 的 CaoBao JSON 备份，预览后再确认合并。只接受原始用户标识与当前范围完全一致的备份。")
                .font(.caption).foregroundStyle(.secondary)
            Text("“此设备”只是本地数据范围标签，不是设备来源或身份已验证的证明。备份是明文文件，可能含私人内容；只选择你信任的备份。")
                .font(.caption).foregroundStyle(.secondary)
            Text("导入在本机完成，不上传、不调用模型、不申请通知权限，也不执行 AI 工具。登录凭据、API Key、连接配置和处理回执不会恢复，现有偏好保持不变。")
                .font(.caption).foregroundStyle(.secondary)
            if isReadingImport {
                HStack {
                    ProgressView()
                    Text("正在读取并检查备份…")
                    Spacer()
                    Button("取消读取") { cancelImport(clearPlan: true) }
                }
            } else if isRestoringImport {
                HStack { ProgressView(); Text("正在合并本地备份…") }
                Text("离开页面会取消尚未提交的操作；已保存的数据会保留。可再次选择同一备份检查并重试。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button { chooseBackup() } label: { Label("选择备份文件", systemImage: "square.and.arrow.down") }
                    .disabled(ownerId.isEmpty || !hasCurrentScope || isExportBusy || isImportBusy || localDataIsBusy)
            }
            if localDataIsBusy && !isReadingImport && !isRestoringImport {
                Text("请等待对话、图片或本地数据操作完成，再导入备份。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func importPreviewSection(_ plan: AssistantDataImportPlan) -> some View {
        Section("待导入的备份范围") {
            LabeledContent { Text(verbatim: plan.exportedAt.formatted(.dateTime.year().month().day().hour().minute().locale(locale))) }
                label: { Text("备份导出时间（当前时区）") }
            LabeledContent { Text(plan.conversations.count, format: .number.locale(locale)) } label: { Text("会话数量") }
            LabeledContent { Text(plan.drafts.count, format: .number.locale(locale)) } label: { Text("未发送草稿") }
            LabeledContent { Text(plan.memories.count, format: .number.locale(locale)) } label: { Text("记忆记录（含删除标记）") }
            LabeledContent { Text(plan.tasks.count, format: .number.locale(locale)) } label: { Text("任务") }
            LabeledContent { Text(plan.omittedImageCount, format: .number.locale(locale)) } label: { Text("备份中已省略的图片附件") }
            LabeledContent { Text(plan.neutralizedProposalCount, format: .number.locale(locale)) } label: { Text("转为普通文字的 AI 提案") }
            LabeledContent { Text(plan.ignoredReceiptCount, format: .number.locale(locale)) } label: { Text("不恢复的处理回执") }
            Text("仅新增，不覆盖本地同 ID 记录；本地删除标记优先。恢复的记忆需重新确认，任务提醒关闭且需重新审批。AI 提案仅作为可读文字保存。")
                .font(.caption).foregroundStyle(.secondary)
            Text("不会自动切换到恢复的会话，也不会替换当前输入草稿。预览数量是备份中的候选记录，实际新增数量可能更少。")
                .font(.caption).foregroundStyle(.secondary)
            if importResult?.isComplete != true {
                Button { requestImportConfirmation() } label: {
                    if importWasAttempted { Text("重试未完成的导入") }
                    else { Text("检查并合并备份") }
                }
                    .disabled(isExportBusy || isImportBusy || localDataIsBusy)
            }
            Button("关闭备份预览", role: .cancel) { cancelImport(clearPlan: true) }
                .disabled(isReadingImport || isRestoringImport)
        }
    }

    private func importResultSection(_ result: AssistantDataImportResult) -> some View {
        Section("本次导入结果") {
            if result.isComplete {
                if result.alreadyApplied { Text("此备份已处理，本次未重复导入。") }
                else { Text("备份合并已完成。已有记录和删除标记可能使部分条目跳过。") }
            } else {
                Text("会话和草稿已完成合并，记忆和任务尚未完成。已保存的数据会保留；请重新确认后重试同一备份。")
                    .foregroundStyle(.orange)
            }
            LabeledContent { Text(result.insertedConversationCount, format: .number.locale(locale)) } label: { Text("本次新增会话") }
            LabeledContent { Text(result.insertedDraftCount, format: .number.locale(locale)) } label: { Text("本次新增草稿") }
            LabeledContent { Text(result.insertedMemoryCount, format: .number.locale(locale)) } label: { Text("本次新增记忆") }
            LabeledContent { Text(result.insertedTaskCount, format: .number.locale(locale)) } label: { Text("本次新增任务") }
            LabeledContent { Text(result.conflictCount, format: .number.locale(locale)) } label: { Text("保留的本地冲突记录") }
            if let error = result.workspaceError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text("结果分别来自会话和工作区的保存记录，不代表跨存储的一次性事务。若中断后未看到结果，请重新选择同一文件检查，已处理记录不会重复新增。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func summarySection(_ summary: BackupSummary) -> some View {
        Section("已准备的备份范围") {
            LabeledContent { Text(summary.conversations, format: .number.locale(locale)) } label: { Text("会话数量") }
            LabeledContent { Text(summary.memories, format: .number.locale(locale)) } label: { Text("记忆记录（含删除标记）") }
            LabeledContent { Text(summary.tasks, format: .number.locale(locale)) } label: { Text("任务") }
            LabeledContent { Text(summary.omittedImages, format: .number.locale(locale)) } label: { Text("省略的图片附件") }
            Text("包括已保存的草稿、记忆使用策略和提醒安静时段。删除标记不包含已删除的记忆正文。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func prepareBackup() {
        guard AssistantOwnerIdentity.matches(ownerId, currentOwner), !ownerId.isEmpty, !isImportBusy else {
            operationError = AssistantLocalization.string("账号已变化，请重新打开数据导出。")
            return
        }
        cancelPreparation()
        document = nil; summary = nil; preparedOwnerId = nil; statusMessage = nil; operationError = nil
        let id = UUID(), owner = ownerId, images = includeImages, epoch = identityEpoch
        let exporter = self.exporter
        exportRunId = id; isPreparing = true
        exportTask = Task { @MainActor in
            do {
                let chat = ChatViewModel.shared
                chat.activateOwner()
                let archiveSnapshot = try await chat.flushForDataExport(ownerId: owner)
                guard !Task.isCancelled, exportRunId == id, identityEpoch == epoch, AssistantOwnerIdentity.matches(owner, currentOwner), AssistantOwnerIdentity.matches(ownerId, owner) else { return }
                let worker = Task.detached(priority: .userInitiated) {
                    try exporter.export(ownerId: owner, includeImages: images, capturedSnapshot: archiveSnapshot)
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                  onCancel: { worker.cancel() })
                guard !Task.isCancelled, exportRunId == id, identityEpoch == epoch, AssistantOwnerIdentity.matches(owner, currentOwner), AssistantOwnerIdentity.matches(ownerId, owner) else { return }
                document = AssistantBackupDocument(data: result.data)
                preparedOwnerId = owner
                summary = BackupSummary(conversations: result.conversationCount, memories: result.memoryCount,
                                        tasks: result.taskCount, omittedImages: result.omittedImageCount)
                showFileExporter = true
            } catch {
                guard !Task.isCancelled, exportRunId == id, identityEpoch == epoch, AssistantOwnerIdentity.matches(owner, currentOwner), AssistantOwnerIdentity.matches(ownerId, owner) else { return }
                operationError = error.localizedDescription
            }
            guard exportRunId == id else { return }
            isPreparing = false; exportRunId = nil; exportTask = nil
        }
    }

    private func cancelPreparation() {
        exportRunId = nil; exportTask?.cancel(); exportTask = nil; isPreparing = false
    }

    private func resetForIdentityChange() {
        identityEpoch = UUID()
        cancelPreparation()
        cancelImport(clearPlan: true)
        showFileExporter = false; document = nil; summary = nil; preparedOwnerId = nil
        statusMessage = nil; operationError = nil
    }

    private func chooseBackup() {
        guard hasCurrentScope, !ownerId.isEmpty, !isExportBusy, !isImportBusy, !localDataIsBusy else { return }
        cancelImport(clearPlan: true)
        filePickerSource = ImportPickerSource(ownerId: ownerId, runId: UUID(), epoch: identityEpoch)
        showFileImporter = true
    }

    private func handleFileImport(_ result: Result<[URL], Error>, source: ImportPickerSource?) {
        guard let source, filePickerSource?.runId == source.runId,
              identityEpoch == source.epoch, AssistantOwnerIdentity.matches(source.ownerId, ownerId),
              AssistantOwnerIdentity.matches(source.ownerId, currentOwner) else { return }
        filePickerSource = nil; showFileImporter = false
        switch result {
        case .success(let urls):
            guard urls.count == 1, let url = urls.first, !isExportBusy, !localDataIsBusy else {
                importError = AssistantLocalization.string("无法读取所选备份，请等待当前操作完成后重新选择文件。")
                return
            }
            readBackup(url: url, source: source)
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled {
                importStatus = AssistantLocalization.string("已取消选择备份，未开始导入。")
            } else {
                importError = AssistantLocalization.string("无法读取所选备份，请等待当前操作完成后重新选择文件。")
            }
        }
    }

    private func readBackup(url: URL, source: ImportPickerSource) {
        let importer = self.importer
        importRunId = source.runId; isReadingImport = true
        importPlan = nil; importResult = nil; importError = nil; importStatus = nil; importWasAttempted = false
        importTask = Task { @MainActor in
            do {
                // The file provider's read grant is used only by the bounded
                // parser. It is released on every path; the URL is not retained.
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let plan = try importer.prepare(url: url, ownerId: source.ownerId)
                    try Task.checkCancellation()
                    return plan
                }
                let plan = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                 onCancel: { worker.cancel() })
                guard importRunIsCurrent(source.runId, owner: source.ownerId, epoch: source.epoch) else { return }
                guard AssistantOwnerIdentity.matches(plan.ownerId, source.ownerId) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                importPlan = plan
            } catch {
                guard importRunIsCurrent(source.runId, owner: source.ownerId, epoch: source.epoch) else { return }
                importError = error.localizedDescription
            }
            guard importRunIsCurrent(source.runId, owner: source.ownerId, epoch: source.epoch) else { return }
            importRunId = nil; importTask = nil; isReadingImport = false
        }
    }

    private func requestImportConfirmation() {
        guard hasCurrentImportPlan, let plan = importPlan, !isExportBusy, !isImportBusy, !localDataIsBusy,
              importResult?.isComplete != true else { return }
        confirmationSource = ImportConfirmationSource(ownerId: ownerId, backupDigest: plan.backupDigest, runId: UUID(), epoch: identityEpoch)
        showImportConfirmation = true
    }

    private func restoreBackup(source: ImportConfirmationSource?) {
        guard let confirmation = source, confirmationSource?.runId == confirmation.runId,
              let plan = importPlan, hasCurrentImportPlan,
              confirmation.epoch == identityEpoch, AssistantOwnerIdentity.matches(confirmation.ownerId, ownerId),
              confirmation.backupDigest == plan.backupDigest, !isExportBusy,
              !isReadingImport, !isRestoringImport, !localDataIsBusy else { return }
        confirmationSource = nil; showImportConfirmation = false
        let id = UUID(), owner = ownerId, epoch = identityEpoch
        importRunId = id; isRestoringImport = true; importWasAttempted = true
        importResult = nil; importError = nil; importStatus = nil
        importTask = Task { @MainActor in
            do {
                let result = try await chat.restoreLocalBackup(plan)
                guard importRunIsCurrent(id, owner: owner, epoch: epoch) else { return }
                importResult = result
            } catch {
                guard importRunIsCurrent(id, owner: owner, epoch: epoch) else { return }
                importError = error.localizedDescription
                importStatus = AssistantLocalization.string("未确认的部分可在重新确认后重试；已保存的数据会保留。")
            }
            guard importRunIsCurrent(id, owner: owner, epoch: epoch) else { return }
            importRunId = nil; importTask = nil; isRestoringImport = false
        }
    }

    private func importRunIsCurrent(_ id: UUID, owner: String, epoch: UUID) -> Bool {
        !Task.isCancelled && importRunId == id && identityEpoch == epoch &&
        AssistantOwnerIdentity.matches(owner, ownerId) && AssistantOwnerIdentity.matches(owner, currentOwner)
    }

    private func cancelImport(clearPlan: Bool) {
        importRunId = nil; importTask?.cancel(); importTask = nil
        isReadingImport = false; isRestoringImport = false
        showFileImporter = false; filePickerSource = nil
        showImportConfirmation = false; confirmationSource = nil
        if clearPlan {
            importPlan = nil; importResult = nil; importError = nil; importStatus = nil; importWasAttempted = false
        }
    }

    private func handleFileSave(_ result: Result<URL, Error>) {
        guard let owner = preparedOwnerId, AssistantOwnerIdentity.matches(owner, currentOwner), AssistantOwnerIdentity.matches(ownerId, owner) else { return }
        document = nil
        switch result {
        case .success:
            statusMessage = AssistantLocalization.string("备份已保存到你选择的位置。")
            operationError = nil
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled {
                statusMessage = AssistantLocalization.string("已取消保存，未导出文件。")
            } else { operationError = error.localizedDescription }
        }
    }

    private struct BackupSummary {
        let conversations: Int
        let memories: Int
        let tasks: Int
        let omittedImages: Int
    }

    private struct ImportPickerSource {
        let ownerId: String
        let runId: UUID
        let epoch: UUID
    }

    private struct ImportConfirmationSource {
        let ownerId: String
        let backupDigest: String
        let runId: UUID
        let epoch: UUID
    }
}

struct AssistantBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= 64 * 1024 * 1024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        _ = try JSONSerialization.jsonObject(with: data)
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
