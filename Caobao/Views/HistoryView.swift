import SwiftUI

@MainActor
struct HistoryView: View {
    let embeddedInHome: Bool
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var chat = ChatViewModel.shared
    @State private var conversations: [AssistantConversationSummary] = []
    @State private var loadedOwner: String?
    @State private var loadedQuery = ""
    @State private var path: [HistoryConversationRoute] = []
    @State private var searchText = ""
    @State private var searchOwner: String?
    @State private var reloadId = UUID()
    @State private var ownerEpoch = UUID()
    @State private var pageEpoch = UUID()
    @State private var activeRead: UUID?
    @State private var nextCursor: AssistantConversationCursor?
    @State private var generation: Int64?
    @State private var completedFirstPage: HistoryQueryIdentity?
    @State private var isLoading = false
    @State private var pageError: String?
    @State private var mustReloadFirstPage = false
    @State private var hasUpdates = false
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var mutationTask: Task<Void, Never>?
    @State private var mutationId: UUID?
    @State private var operationError: String?
    @State private var confirmClear = false
    @State private var clearRequest: HistoryClearRequest?
    private var owner: String { auth.user?.id ?? "local-device" }
    private var currentQuery: String { AssistantOwnerIdentity.matches(searchOwner, owner) ? searchText : "" }
    private var queryIdentity: HistoryQueryIdentity { .init(ownerId: owner, query: currentQuery, reloadId: reloadId) }
    private var displaysCurrentQuery: Bool { AssistantOwnerIdentity.matches(loadedOwner, owner) && loadedQuery == currentQuery }
    private var scopedSearch: Binding<String> {
        Binding(get: { currentQuery }, set: { value in searchOwner = owner; searchText = value })
    }
    private var canMutate: Bool { displaysCurrentQuery && mutationId == nil && chat.archiveIsReady && !chat.archiveIsLoading && !chat.isArchiveBusy }

    init(embeddedInHome: Bool = false) { self.embeddedInHome = embeddedInHome }

    var body: some View {
        let request = queryIdentity
        return Group {
            if embeddedInHome { historyContent }
            else {
                NavigationStack(path: $path) {
                    historyContent
                        .navigationDestination(for: HistoryConversationRoute.self) { route in
                            ConversationDetailView(conversationId: route.id, ownerId: route.ownerId)
                        }
                }
            }
        }
        .task(id: request) { await loadFirstPage(request) }
        .onChange(of: AssistantOwnerIdentity.ownerKey(owner)) { _ in resetOwnerScope() }
        .onReceive(NotificationCenter.default.publisher(for: .loginSuccess)) { _ in resetOwnerScope() }
        .onReceive(NotificationCenter.default.publisher(for: .logoutSuccess)) { _ in resetOwnerScope() }
        .onReceive(NotificationCenter.default.publisher(for: .conversationHistoryChanged)) { notification in
            if let sourceOwner = notification.object as? String, !AssistantOwnerIdentity.matches(sourceOwner, owner) { return }
            if displaysCurrentQuery { hasUpdates = true }
        }
        .onDisappear {
            loadMoreTask?.cancel(); mutationTask?.cancel()
            activeRead = nil; pageEpoch = UUID(); isLoading = false
        }
        .alert("无法更新历史记录", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("好") { operationError = nil }
        } message: { Text(verbatim: operationError ?? "") }
        .confirmationDialog("清空当前账号的全部会话？", isPresented: $confirmClear, titleVisibility: .visible, presenting: clearRequest) { request in
            Button("清空", role: .destructive) {
                guard request.epoch == ownerEpoch else { return }
                deleteHistory(ids: nil, ownerId: request.ownerId)
            }
            Button("取消", role: .cancel) { clearRequest = nil }
        }
    }

    private var historyContent: some View {
        Group {
            if !displaysCurrentQuery || (isLoading && conversations.isEmpty) {
                ProgressView("正在读取历史记录…")
            } else if conversations.isEmpty {
                if let pageError { pageFailure(pageError) }
                else { emptyState }
            } else { conversationList }
        }
        .assistantNavigationTitle("历史记录")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { clearRequest = .init(ownerId: owner, epoch: ownerEpoch); confirmClear = true } label: {
                    Image(systemName: "trash").foregroundStyle(.gray)
                }
                .accessibilityLabel("清空历史记录")
                .disabled(!canMutate)
            }
        }
        .searchable(text: scopedSearch, prompt: "搜索对话")
    }

    private var conversationList: some View {
        List {
            ForEach(conversations) { conversation in
                if embeddedInHome {
                    NavigationLink(value: AssistantHomeRoute.historyConversation(id: conversation.id, ownerId: loadedOwner ?? owner)) {
                        ConversationRowView(conversation: conversation)
                    }
                } else {
                    NavigationLink(value: HistoryConversationRoute(id: conversation.id, ownerId: loadedOwner ?? owner)) {
                        ConversationRowView(conversation: conversation)
                    }
                }
            }
            .onDelete { indices in
                guard canMutate, let sourceOwner = loadedOwner else { return }
                let ids = Set(indices.compactMap { conversations.indices.contains($0) ? conversations[$0].id : nil })
                if !ids.isEmpty { deleteHistory(ids: ids, ownerId: sourceOwner) }
            }
            Section {
                if isLoading { ProgressView("正在读取历史记录…") }
                else if let pageError { pageFailure(pageError) }
                else if nextCursor != nil {
                    Button("加载更多对话", action: loadNextPage).frame(minHeight: 44)
                } else { Text("已显示全部结果").font(.caption).foregroundStyle(.secondary) }
                if hasUpdates {
                    Button("历史记录有更新，重新加载", action: requestReload).frame(minHeight: 44)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { requestReload() }
    }

    private func pageFailure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: message).font(.subheadline).foregroundStyle(.secondary)
            Button(mustReloadFirstPage ? LocalizedStringKey("重新加载历史记录") : LocalizedStringKey("重试")) {
                if mustReloadFirstPage || conversations.isEmpty { requestReload() }
                else { loadNextPage() }
            }.frame(minHeight: 44)
        }.padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 60)).foregroundStyle(.gray.opacity(0.5))
            Text(currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? LocalizedStringKey("暂无历史记录") : LocalizedStringKey("没有匹配的对话"))
                .font(.headline).foregroundStyle(.secondary)
            Text(currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? LocalizedStringKey("开始一段新对话吧") : LocalizedStringKey("搜索会查询当前账号的全部历史。"))
                .font(.subheadline).foregroundStyle(.secondary)
            if hasUpdates { Button("重新加载历史记录", action: requestReload).frame(minHeight: 44) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private func requestReload() {
        loadMoreTask?.cancel(); activeRead = nil; pageEpoch = UUID(); isLoading = false
        reloadId = UUID()
    }
    private func loadFirstPage(_ identity: HistoryQueryIdentity) async {
        guard identity == queryIdentity, !Task.isCancelled else { return }
        // A detail round trip retains loaded metadata pages; query/owner/reload
        // identity changes still start from page one, and SQL validates the cursor.
        if completedFirstPage == identity { return }
        loadMoreTask?.cancel(); pageEpoch = UUID()
        loadedOwner = identity.ownerId; loadedQuery = identity.query
        conversations = []; nextCursor = nil; generation = nil; pageError = nil
        mustReloadFirstPage = false; hasUpdates = false
        completedFirstPage = nil
        await fetchPage(identity, cursor: nil, epoch: pageEpoch, append: false)
    }
    private func loadNextPage() {
        guard displaysCurrentQuery, !isLoading, !mustReloadFirstPage, let cursor = nextCursor else { return }
        let identity = queryIdentity, epoch = pageEpoch
        loadMoreTask?.cancel()
        isLoading = true
        loadMoreTask = Task { await fetchPage(identity, cursor: cursor, epoch: epoch, append: true) }
    }
    private func isCurrentRead(_ identity: HistoryQueryIdentity, epoch: UUID, run: UUID) -> Bool {
        !Task.isCancelled && identity == queryIdentity && pageEpoch == epoch && activeRead == run
            && AssistantOwnerIdentity.matches(identity.ownerId, owner) && AssistantOwnerIdentity.matches(loadedOwner, identity.ownerId) && loadedQuery == identity.query
    }
    private func fetchPage(_ identity: HistoryQueryIdentity, cursor: AssistantConversationCursor?, epoch: UUID, append: Bool) async {
        guard !Task.isCancelled, identity == queryIdentity, pageEpoch == epoch,
              AssistantOwnerIdentity.matches(loadedOwner, identity.ownerId), loadedQuery == identity.query else { return }
        let run = UUID(); activeRead = run; isLoading = true; pageError = nil
        defer { if activeRead == run { activeRead = nil; isLoading = false } }
        do {
            chat.activateOwner()
            try await chat.waitForArchiveReady(ownerId: identity.ownerId)
            guard isCurrentRead(identity, epoch: epoch, run: run) else { return }
            let page = try await chat.historyPage(ownerId: identity.ownerId, query: identity.query, cursor: cursor, limit: 50)
            guard isCurrentRead(identity, epoch: epoch, run: run) else { return }
            if append, let generation, generation != page.generation {
                invalidateCursor(); return
            }
            if append {
                var seen = Set(conversations.map(\.id))
                conversations.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
            } else { conversations = page.items; completedFirstPage = identity }
            generation = page.generation; nextCursor = page.nextCursor
            pageError = nil; mustReloadFirstPage = false
        } catch is CancellationError {
            if isCurrentRead(identity, epoch: epoch, run: run) {
                pageError = AssistantLocalization.string("历史记录读取已中断，请重试。")
            }
        } catch {
            guard isCurrentRead(identity, epoch: epoch, run: run) else { return }
            if case .cursorInvalidated = error as? AssistantChatStorageError { invalidateCursor() }
            else { pageError = error.localizedDescription }
        }
    }
    private func invalidateCursor() {
        nextCursor = nil; mustReloadFirstPage = true
        pageError = AssistantLocalization.string("历史记录已更新，请从第一页重新加载。")
    }

    private func deleteHistory(ids: Set<String>?, ownerId: String) {
        guard canMutate, AssistantOwnerIdentity.matches(ownerId, owner) else { return }
        let run = UUID(), epoch = ownerEpoch
        mutationId = run; loadMoreTask?.cancel(); pageEpoch = UUID(); activeRead = nil; isLoading = false
        // A committed deletion may outlive this view's cancelled task. Reentry
        // must read again even when cancellation suppresses the completion UI.
        completedFirstPage = nil
        mutationTask = Task {
            defer { if mutationId == run { mutationId = nil; mutationTask = nil } }
            guard !Task.isCancelled, mutationId == run, ownerEpoch == epoch, AssistantOwnerIdentity.matches(owner, ownerId) else { return }
            do {
                if let ids { try await chat.deleteConversations(ids: ids, ownerId: ownerId) }
                else { try await chat.deleteAllConversations(ownerId: ownerId) }
                guard !Task.isCancelled, mutationId == run, ownerEpoch == epoch, AssistantOwnerIdentity.matches(owner, ownerId) else { return }
                removeDeletedRoutes(ids: ids, ownerId: ownerId)
                clearRequest = nil; requestReload()
            } catch {
                guard !Task.isCancelled, mutationId == run, ownerEpoch == epoch, AssistantOwnerIdentity.matches(owner, ownerId) else { return }
                operationError = error.localizedDescription; requestReload()
            }
        }
    }
    private func resetOwnerScope() {
        loadMoreTask?.cancel(); mutationTask?.cancel(); mutationId = nil
        conversations = []; loadedOwner = nil; nextCursor = nil; generation = nil
        completedFirstPage = nil
        pageError = nil; operationError = nil; searchText = ""; searchOwner = owner; confirmClear = false; clearRequest = nil
        ownerEpoch = UUID(); pageEpoch = UUID(); activeRead = nil; isLoading = false; reloadId = UUID()
        path.removeAll { !AssistantOwnerIdentity.matches($0.ownerId, owner) }
        if embeddedInHome {
            appState.assistantHomePath.removeAll { route in
                if case .historyConversation(_, let routeOwner) = route { return !AssistantOwnerIdentity.matches(routeOwner, owner) }
                return false
            }
        }
    }
    private func removeDeletedRoutes(ids: Set<String>?, ownerId: String) {
        path.removeAll { AssistantOwnerIdentity.matches($0.ownerId, ownerId) && (ids == nil || ids!.contains($0.id)) }
        if embeddedInHome {
            appState.assistantHomePath.removeAll { route in
                if case .historyConversation(let id, let routeOwner) = route {
                    return AssistantOwnerIdentity.matches(routeOwner, ownerId) && (ids == nil || ids!.contains(id))
                }
                return false
            }
        }
    }
}

private struct HistoryConversationRoute: Hashable {
    let id: String
    let ownerId: String
    let ownerIdentityKey: String
    init(id: String, ownerId: String) {
        self.id = id; self.ownerId = ownerId; ownerIdentityKey = AssistantOwnerIdentity.ownerKey(ownerId)
    }
}
private struct HistoryQueryIdentity: Hashable {
    let ownerId: String
    let ownerIdentityKey: String
    let query: String
    let reloadId: UUID
    init(ownerId: String, query: String, reloadId: UUID) {
        self.ownerId = ownerId; ownerIdentityKey = AssistantOwnerIdentity.ownerKey(ownerId)
        self.query = query; self.reloadId = reloadId
    }
}
private struct HistoryClearRequest: Identifiable { let id = UUID(); let ownerId: String; let epoch: UUID }

struct ConversationRowView: View {
    let conversation: AssistantConversationSummary
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(conversation.title).font(.headline).lineLimit(1)
            Text(conversation.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            if conversation.messageCount == 0 {
                Label("尚无已发送消息", systemImage: "square.and.pencil").font(.caption).foregroundStyle(.secondary)
            }
            Text(conversation.date, format: .dateTime.year().month().day().hour().minute())
                .font(.caption).foregroundStyle(.tertiary)
        }.padding(.vertical, 4)
    }
}

struct AssistantProactiveSourceBanner: View {
    let source: AssistantProactiveConversationSource

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .foregroundStyle(Color.caobaoPrimary)
            VStack(alignment: .leading, spacing: 3) {
                Text("由主动任务创建")
                    .font(.subheadline.weight(.semibold))
                Text("这段对话来自草包的主动更新，来源和触发原因可在主动更新中查看。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.caobaoPrimary.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("由主动任务创建")
    }
}

@MainActor
struct ConversationDetailView: View {
    let conversationId: String
    let ownerId: String
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var chat = ChatViewModel.shared
    @State private var conversation: Conversation?
    @State private var loadedId: String?
    @State private var loadedOwner: String?
    @State private var operationError: String?
    @State private var reloadId = UUID()
    @State private var viewEpoch = UUID()
    @State private var activeRead: UUID?
    @State private var isLoading = false
    @State private var contentHasUpdates = false
    @State private var reloadWhenGenerationEnds = false
    @State private var copyTask: Task<Void, Never>?
    @State private var copyRun: UUID?
    @State private var continueTask: Task<Void, Never>?
    @State private var continueRun: UUID?
    private var owner: String { auth.user?.id ?? "local-device" }
    private var loadIdentity: DetailLoadIdentity { .init(liveOwner: owner, sourceOwner: ownerId, conversationId: conversationId, reloadId: reloadId) }
    private var visibleConversation: Conversation? { AssistantOwnerIdentity.matches(owner, ownerId) && AssistantOwnerIdentity.matches(loadedOwner, ownerId) && loadedId == conversationId ? conversation : nil }
    private var canOperate: Bool { AssistantOwnerIdentity.matches(owner, ownerId) && chat.archiveIsReady && !chat.archiveIsLoading && !chat.isArchiveBusy }

    init(conversationId: String, ownerId: String) { self.conversationId = conversationId; self.ownerId = ownerId }
    init(conversation: Conversation) { self.init(conversationId: conversation.id, ownerId: AuthService.shared.user?.id ?? "local-device") }

    var body: some View {
        let request = loadIdentity
        return Group {
            if let conversation = visibleConversation { detail(conversation) }
            else if isLoading, AssistantOwnerIdentity.matches(owner, ownerId) { ProgressView("正在读取对话…") }
            else {
                VStack(spacing: 12) {
                    Text(verbatim: operationError ?? AssistantHistoryOperationError.conversationUnavailable.localizedDescription)
                        .font(.subheadline).foregroundStyle(.secondary)
                    if AssistantOwnerIdentity.matches(owner, ownerId) { Button("重新读取对话") { reloadId = UUID() }.frame(minHeight: 44) }
                }.padding()
            }
        }
        .navigationTitle(visibleConversation?.title ?? AssistantLocalization.string("历史记录"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: request) { await reload(request) }
        .onChange(of: AssistantOwnerIdentity.ownerKey(owner)) { _ in resetIdentity() }
        .onChange(of: conversationId) { _ in resetIdentity() }
        .onReceive(NotificationCenter.default.publisher(for: .loginSuccess)) { _ in resetIdentity() }
        .onReceive(NotificationCenter.default.publisher(for: .logoutSuccess)) { _ in resetIdentity() }
        .onReceive(NotificationCenter.default.publisher(for: .conversationHistoryChanged)) { notification in
            guard AssistantOwnerIdentity.matches(owner, ownerId) else { return }
            if let sourceOwner = notification.object as? String, !AssistantOwnerIdentity.matches(sourceOwner, ownerId) { return }
            guard let changedId = notification.userInfo?["conversationId"] as? String else { contentHasUpdates = true; return }
            guard changedId == conversationId else { return }
            if chat.isLoading { contentHasUpdates = true; reloadWhenGenerationEnds = true }
            else { reloadId = UUID() }
        }
        .onChange(of: chat.isLoading) { loading in
            if !loading, reloadWhenGenerationEnds { reloadWhenGenerationEnds = false; contentHasUpdates = false; reloadId = UUID() }
        }
        .onDisappear { resetIdentity() }
    }

    private func detail(_ conversation: Conversation) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    if let source = appState.activeAssistantProactiveSource,
                       AssistantOwnerIdentity.matches(source.ownerId, ownerId),
                       source.conversationId == conversationId {
                        AssistantProactiveSourceBanner(source: source)
                    }
                    Button(action: continueConversation) {
                        Label("继续此对话", systemImage: "arrow.turn.up.right").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).tint(.caobaoPrimary)
                    .disabled(!canOperate || continueRun != nil)
                    .accessibilityIdentifier("assistant.history.continue")
                    Text("不会自动发送消息。切换会保留草稿；若正在生成，将先请你确认停止。").font(.caption).foregroundStyle(.secondary)
                    if conversation.messages.isEmpty {
                        Text("此会话尚无已发送消息。若有已保存草稿，继续后会恢复。").font(.caption).foregroundStyle(.secondary)
                    }
                    if contentHasUpdates { Button("对话内容有更新，重新载入") { contentHasUpdates = false; reloadId = UUID() }.frame(minHeight: 44) }
                    if let operationError {
                        Text(verbatim: operationError).font(.caption).foregroundStyle(.red)
                        Button("重新读取对话") { reloadId = UUID() }.frame(minHeight: 44)
                    }
                }
                ForEach(conversation.messages) { message in
                    #if os(iOS)
                    if let images = message.images, !images.isEmpty { AssistantImagesView(images: images) }
                    #endif
                    if !message.content.isEmpty || message.taskProposal == nil { MessageBubble(message: message, userSettings: appState.userSettings, allowsMutatingActions: false,
                        onCopy: { copyMessage(id: message.id) },
                        onCopyCode: { blockId, payload in await copyCode(messageId: message.id, blockId: blockId, expectedText: payload) }) }
                    if let proposal = message.taskProposal { historyTaskProposal(proposal, messageId: message.id, isComplete: message.status == .completed) }
                    if let key = message.statusDescriptionKey(isHistorical: true) {
                        Text(LocalizedStringKey(key)).font(.caption).foregroundStyle(message.status == .failed ? Color.red : Color.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            }.padding()
        }
    }
    @ViewBuilder
    private func historyTaskProposal(_ proposal: AssistantTaskProposal, messageId: String, isComplete: Bool) -> some View {
        if AssistantOwnerIdentity.matches(owner, ownerId), AssistantOwnerIdentity.matches(proposal.ownerId, ownerId), proposal.conversationId == conversationId, proposal.assistantMessageId == messageId {
            let read = historicalTaskProposalReceipt(proposal)
            AssistantTaskToolProposalView(proposal: proposal, receipt: read.receipt, isHistorical: true,
                isBusy: !canOperate || continueRun != nil, canReview: false, canDecline: false, canContinue: false,
                proposalIsComplete: isComplete, receiptReadFailed: read.failed,
                operationError: read.failed ? AssistantLocalization.string("无法读取待办处理结果，请稍后重试。") : nil,
                onReview: {}, onDecline: {}, onContinue: {}, onOpenCurrentChat: continueConversation)
        }
    }
    private func historicalTaskProposalReceipt(_ proposal: AssistantTaskProposal) -> (receipt: AssistantTaskToolReceipt?, failed: Bool) {
        do { return (try chat.taskProposalReceipt(proposal: proposal), false) }
        catch { return (nil, true) }
    }
    private func stillDisplays(_ id: String, ownerId: String, epoch: UUID) -> Bool {
        !Task.isCancelled && AssistantOwnerIdentity.matches(owner, ownerId) && AssistantOwnerIdentity.matches(self.ownerId, ownerId) && conversationId == id && viewEpoch == epoch
    }
    private func reload(_ identity: DetailLoadIdentity) async {
        guard !Task.isCancelled, identity == loadIdentity, AssistantOwnerIdentity.matches(owner, ownerId) else { return }
        let run = UUID(); activeRead = run; isLoading = true; conversation = nil
        loadedOwner = nil; loadedId = nil; operationError = nil
        contentHasUpdates = false; reloadWhenGenerationEnds = false
        defer { if activeRead == run { activeRead = nil; isLoading = false } }
        do {
            chat.activateOwner()
            try await chat.waitForArchiveReady(ownerId: identity.sourceOwner)
            guard !Task.isCancelled, activeRead == run, identity == loadIdentity else { return }
            let value = try await chat.conversation(withId: identity.conversationId, ownerId: identity.sourceOwner)
            guard !Task.isCancelled, activeRead == run, identity == loadIdentity, AssistantOwnerIdentity.matches(owner, identity.sourceOwner) else { return }
            conversation = value; loadedOwner = identity.sourceOwner; loadedId = identity.conversationId
            if value == nil { operationError = AssistantHistoryOperationError.conversationUnavailable.localizedDescription }
        } catch is CancellationError {
            if !Task.isCancelled, activeRead == run, identity == loadIdentity {
                operationError = AssistantLocalization.string("对话读取已中断，请重试。")
            }
        }
        catch {
            guard !Task.isCancelled, activeRead == run, identity == loadIdentity else { return }
            operationError = error.localizedDescription
        }
    }
    private func continueConversation() {
        guard canOperate, continueRun == nil else { return }
        let run = UUID(), epoch = viewEpoch, sourceOwner = ownerId, sourceId = conversationId
        continueRun = run
        continueTask = Task {
            defer { if continueRun == run { continueRun = nil; continueTask = nil } }
            guard continueRun == run, stillDisplays(sourceId, ownerId: sourceOwner, epoch: epoch) else { return }
            let succeeded = await chat.requestOpenConversation(id: sourceId, ownerId: sourceOwner)
            guard succeeded, continueRun == run, stillDisplays(sourceId, ownerId: sourceOwner, epoch: epoch) else { return }
            AssistantConversationNavigation.activateChat(appState: appState, ownerId: sourceOwner)
        }
    }
    private func copyMessage(id: String) {
        guard canOperate, visibleConversation?.messages.contains(where: { $0.id == id }) == true else { return }
        copyTask?.cancel()
        let run = UUID(), epoch = viewEpoch, sourceOwner = ownerId, sourceId = conversationId
        copyRun = run
        copyTask = Task {
            defer { if copyRun == run { copyRun = nil; copyTask = nil } }
            guard copyRun == run, stillDisplays(sourceId, ownerId: sourceOwner, epoch: epoch),
                  visibleConversation?.messages.contains(where: { $0.id == id }) == true else { return }
            do {
                let current = try await chat.conversation(withId: sourceId, ownerId: sourceOwner)
                guard copyRun == run, stillDisplays(sourceId, ownerId: sourceOwner, epoch: epoch),
                      visibleConversation?.messages.contains(where: { $0.id == id }) == true else { return }
                guard let message = current?.messages.first(where: { $0.id == id }) else {
                    operationError = AssistantLocalization.string("消息已更新，请重新读取对话后再复制。")
                    return
                }
                chat.copyMessage(message)
            } catch {
                guard copyRun == run, stillDisplays(sourceId, ownerId: sourceOwner, epoch: epoch) else { return }
                operationError = error.localizedDescription
            }
        }
    }
    private func copyCode(messageId: String, blockId: Int, expectedText: String) async -> Bool {
        guard canOperate, visibleConversation?.messages.contains(where: { $0.id == messageId }) == true else { return false }
        copyTask?.cancel(); copyTask = nil
        let run = UUID(), epoch = viewEpoch, sourceOwner = ownerId, sourceId = conversationId
        copyRun = run
        defer { if copyRun == run { copyRun = nil } }
        do {
            guard copyRun == run, stillDisplays(sourceId, ownerId: sourceOwner, epoch: epoch) else { return false }
            let current = try await chat.conversation(withId: sourceId, ownerId: sourceOwner)
            guard copyRun == run, stillDisplays(sourceId, ownerId: sourceOwner, epoch: epoch),
                  visibleConversation?.messages.contains(where: { $0.id == messageId }) == true else { return false }
            guard let message = current?.messages.first(where: { $0.id == messageId }),
                  let payload = AssistantMarkdown.codeCopyText(in: message.content, blockId: blockId, expectedText: expectedText) else {
                operationError = AssistantLocalization.string("代码内容已变化，请重新选择后复制。")
                return false
            }
            guard copyRun == run, stillDisplays(sourceId, ownerId: sourceOwner, epoch: epoch) else { return false }
            // No suspension between the final owner/task check and the clipboard write.
            MarkdownTextView.writeCodeToClipboard(payload)
            return true
        } catch {
            guard copyRun == run, stillDisplays(sourceId, ownerId: sourceOwner, epoch: epoch) else { return false }
            operationError = error.localizedDescription
            return false
        }
    }
    private func resetIdentity() {
        viewEpoch = UUID(); activeRead = nil; conversation = nil; loadedOwner = nil; loadedId = nil
        copyTask?.cancel(); copyTask = nil; copyRun = nil
        continueTask?.cancel(); continueTask = nil; continueRun = nil
        isLoading = false; operationError = nil; reloadId = UUID()
        contentHasUpdates = false; reloadWhenGenerationEnds = false
    }
}

private struct DetailLoadIdentity: Hashable {
    let liveOwner: String
    let sourceOwner: String
    let liveOwnerIdentityKey: String
    let sourceOwnerIdentityKey: String
    let conversationId: String
    let reloadId: UUID
    init(liveOwner: String, sourceOwner: String, conversationId: String, reloadId: UUID) {
        self.liveOwner = liveOwner; self.sourceOwner = sourceOwner
        liveOwnerIdentityKey = AssistantOwnerIdentity.ownerKey(liveOwner)
        sourceOwnerIdentityKey = AssistantOwnerIdentity.ownerKey(sourceOwner)
        self.conversationId = conversationId; self.reloadId = reloadId
    }
}

#Preview { HistoryView() }
