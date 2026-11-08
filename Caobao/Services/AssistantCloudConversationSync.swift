import Foundation

/// Owner-scoped synchronizer for the v2 conversation archive. Conversation
/// mutations are consumed from the append-only change feed, including delete
/// tombstones. Local pending/streaming messages are retained until recovery.
enum AssistantCloudConversationSyncError: LocalizedError, Equatable {
    case invalidConfiguration, invalidResponse, responseTooLarge, ownerChanged, historyRequiresSnapshot
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return AssistantLocalization.string("会话同步配置无效。")
        case .invalidResponse: return AssistantLocalization.string("会话同步响应无效。")
        case .responseTooLarge: return AssistantLocalization.string("会话同步数据超过安全大小限制。")
        case .ownerChanged: return AssistantLocalization.string("账号已变化，会话同步已停止。")
        case .historyRequiresSnapshot: return AssistantLocalization.string("会话历史需要完整快照同步。")
        case .httpStatus(let status): return AssistantLocalization.string("会话同步失败（HTTP \(status)）。")
        }
    }
}

final class AssistantCloudConversationSync {
    private struct Page<T: Decodable>: Decodable { let items: [T]; let nextCursor: String? }
    private struct ChangePage: Decodable {
        let items: [RemoteChange]
        let nextCursor: Int64
        let headSeq: Int64
        let resyncRequired: Bool
    }
    private struct RemoteConversation: Codable {
        let id: String; let clientConversationId: String; let title: String?; let locale: String?
        let status: String?; let createdAt: String; let updatedAt: String
    }
    private struct RemoteMessage: Decodable {
        let id: String; let conversationId: String; let clientMessageId: String?
        let generationId: String?; let requestId: String?; let role: String
        let content: [RemotePart]; let status: String?; let model: String?; let createdAt: String
    }
    private struct RemotePart: Decodable { let type: String; let text: String? }
    private struct RemoteChange: Decodable {
        let seq: Int64
        let event: String
        let id: String
        let clientConversationId: String
        let title: String
        let locale: String
        let status: String
        let updatedAt: String
    }
    private struct SnapshotState: Codable {
        var nextPageCursor: String? = nil
        var pending: [RemoteConversation] = []
        var active: RemoteConversation? = nil
        var messageCursor: String? = nil
        var endReached = false
        var pageCount = 0
    }
    private struct SyncState: Codable {
        var cursor: Int64 = 0
        var snapshot: SnapshotState? = nil
        var snapshotTargetCursor: Int64? = nil

        init(cursor: Int64 = 0, snapshot: SnapshotState? = nil, snapshotTargetCursor: Int64? = nil) {
            self.cursor = cursor
            self.snapshot = snapshot
            self.snapshotTargetCursor = snapshotTargetCursor
        }

        // State written by older client versions only contained `cursor`.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cursor = try container.decodeIfPresent(Int64.self, forKey: .cursor) ?? 0
            snapshot = try container.decodeIfPresent(SnapshotState.self, forKey: .snapshot)
            snapshotTargetCursor = try container.decodeIfPresent(Int64.self, forKey: .snapshotTargetCursor)
        }
    }

    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    private let baseURL: URL
    private let session: URLSession
    private let maximumResponseBytes: Int
    private let defaults: UserDefaults

    init(baseURL: URL = APIConfig.assistantBaseURL,
         sessionConfiguration: URLSessionConfiguration = .ephemeral,
         maximumResponseBytes: Int = 8 * 1024 * 1024,
         defaults: UserDefaults = .standard) {
        self.baseURL = baseURL
        self.maximumResponseBytes = min(maximumResponseBytes, 32 * 1024 * 1024)
        self.defaults = defaults
        let configuration = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 90
        let delegate = RedirectBlocker()
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func sync(ownerId: String, token: String, archive: AssistantChatArchive) async throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil,
              baseURL.fragment == nil, !ownerId.isEmpty, !token.isEmpty else {
            throw AssistantCloudConversationSyncError.invalidConfiguration
        }
        var state = loadState(ownerId: ownerId)
        if state.snapshot != nil {
            do {
                let complete = try await fullSnapshot(ownerId: ownerId, token: token, archive: archive, state: &state)
                saveState(state, ownerId: ownerId)
                if complete {
                    state.snapshot = nil
                    if let target = state.snapshotTargetCursor {
                        state.cursor = max(state.cursor, target)
                        state.snapshotTargetCursor = nil
                    }
                    saveState(state, ownerId: ownerId)
                }
            } catch {
                // Preserve the active conversation/page cursor so a transient
                // network or cancellation failure resumes without restarting.
                saveState(state, ownerId: ownerId)
                throw error
            }
            return
        }
        var cursor = state.cursor
        var changePages = 0
        while true {
            changePages += 1
            guard changePages <= 1_000 else { throw AssistantCloudConversationSyncError.invalidResponse }
            let changes = try await getChanges(cursor: cursor, limit: 200, token: token)
            if changes.resyncRequired {
                state = SyncState()
                cursor = 0
                state.snapshot = SnapshotState()
                saveState(state, ownerId: ownerId)
                do {
                    _ = try await fullSnapshot(ownerId: ownerId, token: token, archive: archive, state: &state)
                    saveState(state, ownerId: ownerId)
                } catch {
                    saveState(state, ownerId: ownerId)
                    throw error
                }
                return
            }
            guard changes.nextCursor >= cursor, changes.headSeq >= changes.nextCursor else {
                throw AssistantCloudConversationSyncError.invalidResponse
            }
            var previousSeq = cursor
            for change in changes.items {
                try Task.checkCancellation()
                guard change.seq > previousSeq, change.seq <= changes.nextCursor else {
                    throw AssistantCloudConversationSyncError.invalidResponse
                }
                do {
                    try await apply(change: change, ownerId: ownerId, token: token, archive: archive)
                } catch AssistantCloudConversationSyncError.historyRequiresSnapshot {
                    // A large incremental history cannot be safely applied a
                    // page at a time without losing the change cursor. Fall
                    // back to the complete snapshot and advance the cursor
                    // only after that snapshot is durable.
                    state.snapshot = SnapshotState()
                    state.snapshotTargetCursor = changes.nextCursor
                    do {
                        let complete = try await fullSnapshot(ownerId: ownerId, token: token, archive: archive, state: &state)
                        saveState(state, ownerId: ownerId)
                        if complete {
                            state.snapshot = nil
                            if let target = state.snapshotTargetCursor {
                                state.cursor = max(state.cursor, target)
                                state.snapshotTargetCursor = nil
                            }
                            saveState(state, ownerId: ownerId)
                        }
                    } catch {
                        saveState(state, ownerId: ownerId)
                        throw error
                    }
                    return
                }
                previousSeq = change.seq
            }
            cursor = changes.nextCursor
            state.cursor = cursor
            saveState(state, ownerId: ownerId)
            // A zero head means the server predates the change feed. Preserve
            // compatibility by importing the existing snapshot once.
            if changes.items.isEmpty && cursor == 0 && changes.headSeq == 0 {
                state.snapshot = SnapshotState()
                do {
                    _ = try await fullSnapshot(ownerId: ownerId, token: token, archive: archive, state: &state)
                    saveState(state, ownerId: ownerId)
                } catch {
                    saveState(state, ownerId: ownerId)
                    throw error
                }
                return
            }
            if changes.items.isEmpty || cursor >= changes.headSeq { return }
        }
    }

    /// Submits a local conversation deletion. The server records the delete
    /// tombstone and the next sync delivers it to other devices.
    func deleteConversation(id: String, token: String) async throws {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.isEmpty else { throw AssistantCloudConversationSyncError.invalidConfiguration }
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = baseURL.appendingPathComponent("conversations/\(escaped)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AssistantCloudConversationSyncError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func fullSnapshot(ownerId: String, token: String, archive: AssistantChatArchive,
                             state: inout SyncState) async throws -> Bool {
        var snapshot = state.snapshot ?? SnapshotState()
        var imported = 0
        while imported < 200 {
            if snapshot.active == nil && snapshot.pending.isEmpty {
                guard !snapshot.endReached else {
                    state.snapshot = nil
                    return true
                }
                snapshot.pageCount += 1
                guard snapshot.pageCount <= 1_000 else { throw AssistantCloudConversationSyncError.invalidResponse }
                let requestedCursor = snapshot.nextPageCursor
                let page: Page<RemoteConversation> = try await get(path: "conversations", cursor: requestedCursor, limit: 50, token: token)
                let nextCursor = normalizedCursor(page.nextCursor)
                guard nextCursor == nil || nextCursor != requestedCursor else {
                    throw AssistantCloudConversationSyncError.invalidResponse
                }
                snapshot.nextPageCursor = nextCursor
                snapshot.endReached = nextCursor == nil
                snapshot.pending = page.items
                if page.items.isEmpty { continue }
            }

            if snapshot.active == nil {
                snapshot.active = snapshot.pending.removeFirst()
                snapshot.messageCursor = nil
            }
            guard let remote = snapshot.active else { throw AssistantCloudConversationSyncError.invalidResponse }
            do {
                try Task.checkCancellation()
                guard validServerConversationId(remote.id) else { throw AssistantCloudConversationSyncError.invalidResponse }
                guard validClientConversationId(remote.clientConversationId) else {
                    throw AssistantCloudConversationSyncError.invalidResponse
                }
                guard date(remote.createdAt) != nil, date(remote.updatedAt) != nil else {
                    throw AssistantCloudConversationSyncError.invalidResponse
                }
                let result = try await fetchMessagePage(remote.id, token: token, cursor: snapshot.messageCursor)
                guard result.messages.allSatisfy({ date($0.createdAt) != nil }) else {
                    throw AssistantCloudConversationSyncError.invalidResponse
                }
                try await merge(remote: remote, messages: result.messages, ownerId: ownerId, archive: archive)
                if let next = result.nextCursor {
                    guard next != snapshot.messageCursor else { throw AssistantCloudConversationSyncError.invalidResponse }
                    snapshot.messageCursor = next
                    state.snapshot = snapshot
                    return false
                }
                snapshot.active = nil
                snapshot.messageCursor = nil
                imported += 1
                state.snapshot = snapshot
            } catch {
                // Keep the active conversation and cursor in state. A retry is
                // safe because merge() is idempotent by message identity.
                state.snapshot = snapshot
                throw error
            }
        }
        state.snapshot = snapshot
        return false
    }

    private func getChanges(cursor: Int64, limit: Int, token: String) async throws -> ChangePage {
        var components = URLComponents(url: baseURL.appendingPathComponent("sync/conversations"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "cursor", value: String(max(0, cursor))),
                                 URLQueryItem(name: "limit", value: String(max(1, min(limit, 200))))]
        return try await getURL(components.url!, token: token)
    }

    private func apply(change: RemoteChange, ownerId: String, token: String,
                       archive: AssistantChatArchive) async throws {
        guard change.seq > 0, validServerConversationId(change.id),
              validClientConversationId(change.clientConversationId),
              date(change.updatedAt) != nil,
              ["upsert", "delete"].contains(change.event.lowercased()) else {
            throw AssistantCloudConversationSyncError.invalidResponse
        }
        let local = try await archive.background { try $0.load(userId: ownerId) }
        let localMatch = local.first { $0.serverConversationId == change.id || $0.id == change.clientConversationId }
        let localId = localMatch?.id ?? change.clientConversationId
        guard validClientConversationId(localId) else { throw AssistantCloudConversationSyncError.invalidResponse }
        if change.event.lowercased() == "delete" {
            if localMatch != nil {
                try await archive.backgroundTransaction(userId: ownerId) { store in
                    try store.delete(ids: [localId], userId: ownerId)
                }
            }
            return
        }
        let messages = try await fetchMessages(change.id, token: token)
        let remote = RemoteConversation(id: change.id, clientConversationId: change.clientConversationId,
            title: change.title, locale: change.locale, status: change.status,
            createdAt: change.updatedAt, updatedAt: change.updatedAt)
        try await merge(remote: remote, messages: messages, ownerId: ownerId, archive: archive)
    }

    private func loadState(ownerId: String) -> SyncState {
        guard let data = defaults.data(forKey: stateKey(ownerId: ownerId)),
              let state = try? JSONDecoder().decode(SyncState.self, from: data), state.cursor >= 0 else {
            return SyncState()
        }
        return state
    }

    private func saveState(_ state: SyncState, ownerId: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey(ownerId: ownerId))
    }

    private func stateKey(ownerId: String) -> String {
        "caobao.assistant.cloudConversationSync." + Data(ownerId.utf8).base64EncodedString()
    }

    private func fetchMessages(_ id: String, token: String) async throws -> [RemoteMessage] {
        let result = try await fetchMessagePage(id, token: token, cursor: nil)
        guard result.nextCursor == nil else { throw AssistantCloudConversationSyncError.historyRequiresSnapshot }
        return result.messages
    }

    private struct MessagePageResult {
        let messages: [RemoteMessage]
        let nextCursor: String?
    }

    private func fetchMessagePage(_ id: String, token: String, cursor initialCursor: String?) async throws -> MessagePageResult {
        guard validServerConversationId(id) else { throw AssistantCloudConversationSyncError.invalidResponse }
        var cursor = normalizedCursor(initialCursor)
        var seenCursors = Set<String>()
        var pageCount = 0
        var result: [RemoteMessage] = []
        repeat {
            // Keep each invocation within the existing 1,000-message budget
            // (five pages at the server's maximum page size). A non-nil
            // cursor is returned so full snapshots resume on the next sync.
            if pageCount >= 5 {
                return MessagePageResult(messages: result, nextCursor: cursor)
            }
            pageCount += 1
            let page: Page<RemoteMessage> = try await get(path: "conversations/\(escaped(id))/messages", cursor: cursor, limit: 200, token: token)
            result.append(contentsOf: page.items)
            if let next = normalizedCursor(page.nextCursor) {
                guard seenCursors.insert(next).inserted else { throw AssistantCloudConversationSyncError.invalidResponse }
                cursor = next
            } else {
                cursor = nil
            }
        } while cursor != nil
        return MessagePageResult(messages: result, nextCursor: cursor)
    }

    private func get<T: Decodable>(path: String, cursor: String?, limit: Int, token: String) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = query
        return try await getURL(components.url!, token: token)
    }

    private func getURL<T: Decodable>(_ url: URL, token: String) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AssistantCloudConversationSyncError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AssistantCloudConversationSyncError.httpStatus(http.statusCode) }
        guard data.count <= maximumResponseBytes else { throw AssistantCloudConversationSyncError.responseTooLarge }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw AssistantCloudConversationSyncError.invalidResponse }
    }

    private func merge(remote: RemoteConversation, messages: [RemoteMessage], ownerId: String,
                       archive: AssistantChatArchive) async throws {
        let local = try await archive.background { try $0.load(userId: ownerId) }
        let localMatch = local.first { $0.serverConversationId == remote.id || $0.id == remote.clientConversationId }
        let localId = localMatch?.id ?? remote.clientConversationId
        guard validClientConversationId(localId) else { throw AssistantCloudConversationSyncError.invalidResponse }
        guard !(try await archive.background { try $0.deletedConversationIds(userId: ownerId).contains(localId) }) else { return }
        let existing = localMatch?.messages ?? []
        let existingKeys = Set(existing.flatMap { messageIdentityKeys(id: $0.id, requestId: $0.requestId, generationId: $0.generationId) })
        var seenRemoteKeys = Set<String>()
        let additions = messages.sorted { (date($0.createdAt) ?? .distantPast) < (date($1.createdAt) ?? .distantPast) }
            .compactMap { message -> ChatMessage? in
                guard message.conversationId == remote.id else { return nil }
                let remoteKeys = messageIdentityKeys(id: message.id, requestId: message.requestId,
                                                     generationId: message.generationId,
                                                     clientMessageId: message.clientMessageId)
                let key = message.clientMessageId ?? message.requestId ?? message.generationId ?? message.id
                guard !key.isEmpty, !remoteKeys.contains(where: existingKeys.contains),
                      seenRemoteKeys.isDisjoint(with: remoteKeys) else { return nil }
                seenRemoteKeys.formUnion(remoteKeys)
                let text = message.content.compactMap { part in part.type == "text" ? part.text : nil }.joined()
                guard message.role == "user" || message.role == "assistant" else { return nil }
                guard !text.isEmpty else { return nil }
                return ChatMessage(id: key, role: message.role == "assistant" ? .assistant : .user,
                    content: text, timestamp: date(message.createdAt) ?? Date(),
                    status: status(message.status), requestId: message.requestId,
                    generationId: message.generationId, model: message.model)
            }
        let combined = (existing + additions).sorted { left, right in
            if left.timestamp != right.timestamp { return left.timestamp < right.timestamp }
            return left.id < right.id
        }
        guard !additions.isEmpty || localMatch == nil || localMatch?.serverConversationId != remote.id else { return }
        let title = localMatch?.title ?? remote.title ?? String(combined.first?.content.prefix(40) ?? "")
        let preview = combined.last?.content ?? localMatch?.preview ?? ""
        let conversation = Conversation(id: localId, title: title, preview: preview,
            date: date(remote.updatedAt) ?? localMatch?.date ?? Date(), messages: combined,
            serverConversationId: remote.id)
        try await archive.backgroundTransaction(userId: ownerId, operation: { store in
            try store.upsert(conversation, userId: ownerId)
        })
    }

    private func validServerConversationId(_ value: String) -> Bool {
        let suffix = value.dropFirst(4)
        return value.hasPrefix("cnv_") && !suffix.isEmpty && suffix.utf8.allSatisfy { (48...57).contains($0) }
    }
    private func validClientConversationId(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= 1_024
    }
    private func normalizedCursor(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private func escaped(_ value: String) -> String { value }
    private func messageIdentityKeys(id: String?, requestId: String? = nil,
                                     generationId: String? = nil, clientMessageId: String? = nil) -> Set<String> {
        Set([id, requestId, generationId, clientMessageId].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        })
    }
    private func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? { formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value) }()
    }
    private func status(_ value: String?) -> ChatMessage.Status {
        switch value?.lowercased() { case "cancelled": return .cancelled; case "failed": return .failed; default: return .completed }
    }
}
