import Foundation
import CryptoKit

extension Notification.Name {
    /// Posted by local memory editors after a successful owner-scoped write.
    static let assistantMemoryStoreChanged = Notification.Name("assistant.memoryStoreChanged")
    /// Posted after a server pull has been applied to the local repository.
    static let assistantMemorySyncApplied = Notification.Name("assistant.memorySyncApplied")
}

/// Errors from the authenticated memory sync surface. The service never turns a
/// conflict into a successful local overwrite.
enum AssistantCloudMemorySyncError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidOwner
    case invalidToken
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)
    case malformedMemory
    case persistenceFailure
    case conflict

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return AssistantLocalization.string("云端记忆服务配置无效。")
        case .invalidOwner: return AssistantLocalization.string("当前账号无效，无法同步记忆。")
        case .invalidToken: return AssistantLocalization.string("登录状态已失效，请重新登录。")
        case .invalidResponse, .malformedMemory: return AssistantLocalization.string("云端记忆服务返回了无效数据。")
        case .persistenceFailure: return AssistantLocalization.string("本地记忆保存失败，云端游标未推进。")
        case .responseTooLarge: return AssistantLocalization.string("云端记忆响应超过安全大小限制。")
        case .httpStatus(let status): return String(format: AssistantLocalization.string("云端记忆同步失败（HTTP %d）。"), status)
        case .conflict: return AssistantLocalization.string("云端记忆已发生变化，请重新同步后再保存。")
        }
    }
}

private struct AssistantCloudMemoryPayload: Codable, Equatable {
    let id: String
    let category: String
    let text: String?
    let consent: String
    let status: String
    let sourceMessageId: String?
    let locale: String?
    let version: Int64
    let seq: Int64
    let updatedAt: String
}

private struct AssistantCloudMemoryListResponse: Codable {
    let items: [AssistantCloudMemoryPayload]
}

private struct AssistantCloudMemoryChangesResponse: Codable {
    let memories: [AssistantCloudMemoryPayload]
    let nextCursor: Int64
    let headSeq: Int64
    let resyncRequired: Bool
}

private struct AssistantCloudMemoryUpsertRequest: Codable {
    let id: String
    let category: String
    let text: String
    let consent: String
    let sourceMessageId: String?
    let locale: String?
    let expectedVersion: Int64
}

private struct AssistantCloudMemoryRecord: Codable {
    var version: Int64
    var seq: Int64
    var updatedAt: TimeInterval
    var localDigest: String
    var dirty: Bool = false
}

private struct AssistantCloudMemoryState: Codable {
    var cursor: Int64 = 0
    var records: [String: AssistantCloudMemoryRecord] = [:]
}

/// Authenticated, owner-bound cloud memory synchronization.
///
/// The local repository remains the source of truth for UI reads. Sync applies
/// server changes through the repository's existing validation/CAS methods and
/// advances the cursor only after every page has been processed. A local
/// tombstone is never resurrected by a stale cloud row.
@MainActor
final class AssistantCloudMemorySyncClient {
    private let baseURL: URL
    private let session: URLSession
    private let redirectGuard: AssistantCloudMemoryRedirectGuard
    private let maximumResponseBytes: Int

    init(baseURL: URL = APIConfig.assistantBaseURL,
         sessionConfiguration: URLSessionConfiguration = .ephemeral,
         maximumResponseBytes: Int = 8 * 1024 * 1024) {
        self.baseURL = baseURL
        self.maximumResponseBytes = min(maximumResponseBytes, 16 * 1024 * 1024)
        let configuration = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        redirectGuard = AssistantCloudMemoryRedirectGuard()
        session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
    }

    func syncFromCloud(ownerId: String, token: String, repository: AssistantLocalRepositoryProtocol,
                       defaults: UserDefaults) async throws {
        try validate(ownerId: ownerId, token: token)
        var state = loadState(ownerId: ownerId, defaults: defaults)
        var cursor = state.cursor
        var pages = 0
        while true {
            pages += 1
            guard pages <= 1_000 else { throw AssistantCloudMemorySyncError.invalidResponse }
            let response = try await changes(token: token, cursor: cursor, limit: 200)
            if response.resyncRequired {
                state = AssistantCloudMemoryState()
                cursor = 0
                saveState(state, ownerId: ownerId, defaults: defaults)
                continue
            }
            for payload in response.memories {
                try apply(payload, ownerId: ownerId, repository: repository, state: &state)
            }
            guard response.nextCursor >= cursor else { throw AssistantCloudMemorySyncError.invalidResponse }
            cursor = response.nextCursor
            state.cursor = cursor
            saveState(state, ownerId: ownerId, defaults: defaults)
            if response.memories.isEmpty || cursor >= response.headSeq { break }
        }
    }

    func syncToCloud(ownerId: String, token: String, repository: AssistantLocalRepositoryProtocol,
                     defaults: UserDefaults) async throws {
        try validate(ownerId: ownerId, token: token)
        // Pull first so an edit is compared against the server's latest version.
        try await syncFromCloud(ownerId: ownerId, token: token, repository: repository, defaults: defaults)
        let remote = try await list(token: token, limit: 200)
        var remoteByID = Dictionary(remote.items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var state = loadState(ownerId: ownerId, defaults: defaults)
        let records = repository.memoryRecords(for: ownerId)
        for local in records {
            try Task.checkCancellation()
            guard local.userId == ownerId, validIdentifier(local.id) else { continue }
            let digest = Self.digest(local)
            let prior = state.records[local.id]
            if prior?.localDigest == digest, prior?.dirty != true { continue }

            if local.status == .deleted {
                if let cloud = remoteByID[local.id], cloud.status != "deleted" {
                    if prior?.dirty == true { throw AssistantCloudMemorySyncError.conflict }
                    try await delete(id: local.id, token: token)
                }
                state.records[local.id] = AssistantCloudMemoryRecord(
                    version: prior?.version ?? remoteByID[local.id]?.version ?? 0,
                    seq: prior?.seq ?? remoteByID[local.id]?.seq ?? 0,
                    updatedAt: prior?.updatedAt ?? 0,
                    localDigest: digest, dirty: false)
                continue
            }

            let cloud = remoteByID[local.id]

            let request = AssistantCloudMemoryUpsertRequest(
                id: local.id,
                category: Self.serverCategory(local.category),
                text: local.text,
                consent: local.consent,
                sourceMessageId: local.sourceMessageId,
                locale: nil,
                expectedVersion: cloud?.version ?? prior?.version ?? 0)
            let saved = try await upsert(request, token: token)
            remoteByID[local.id] = saved
            state.records[local.id] = AssistantCloudMemoryRecord(
                version: saved.version, seq: saved.seq,
                updatedAt: (try? Self.parseTimestamp(saved.updatedAt))?.timeIntervalSince1970 ?? 0,
                localDigest: digest, dirty: false)
        }
        saveState(state, ownerId: ownerId, defaults: defaults)
        try await syncFromCloud(ownerId: ownerId, token: token, repository: repository, defaults: defaults)
    }

    private func apply(_ payload: AssistantCloudMemoryPayload, ownerId: String,
                       repository: AssistantLocalRepositoryProtocol,
                       state: inout AssistantCloudMemoryState) throws {
        guard validIdentifier(payload.id), let remoteDate = try? Self.parseTimestamp(payload.updatedAt),
              let category = Self.localCategory(payload.category),
              payload.status == "active" || payload.status == "deleted" else {
            throw AssistantCloudMemorySyncError.malformedMemory
        }
        let existing = repository.memoryRecords(for: ownerId).first { $0.id == payload.id }
        let prior = state.records[payload.id]
        let existingDigest = existing.map(Self.digest)
        let localDirty = existing != nil && (prior == nil || prior?.localDigest != existingDigest)
        let localNewer = existing.map { $0.updatedAt.timeIntervalSince1970 > remoteDate.timeIntervalSince1970 } ?? false
        let preserveLocal = localDirty && localNewer
        if payload.status == "deleted" {
            if existing?.status == .active {
                if !preserveLocal {
                    guard repository.deleteMemory(id: payload.id, userId: ownerId) else {
                        throw AssistantCloudMemorySyncError.persistenceFailure
                    }
                }
            }
        } else if existing?.status != .deleted {
            guard let text = payload.text, !text.isEmpty else { throw AssistantCloudMemorySyncError.malformedMemory }
            let candidate = AssistantMemory(id: payload.id, userId: ownerId, category: category,
                text: text, sourceMessageId: payload.sourceMessageId, consent: payload.consent,
                status: .active, createdAt: existing?.createdAt ?? remoteDate, updatedAt: remoteDate)
            if existing != nil {
                if !preserveLocal {
                    guard repository.updateMemory(candidate) else {
                        throw AssistantCloudMemorySyncError.persistenceFailure
                    }
                }
            } else {
                guard repository.insertMemory(candidate) else {
                    throw AssistantCloudMemorySyncError.persistenceFailure
                }
            }
        }
        let final = repository.memoryRecords(for: ownerId).first { $0.id == payload.id }
        let finalDigest = final.map(Self.digest) ?? ""
        let preservedLocalEdit = preserveLocal && finalDigest == existingDigest
            && final?.status == existing?.status
        let localDigest = preservedLocalEdit ? (prior?.localDigest ?? "") : finalDigest
        state.records[payload.id] = AssistantCloudMemoryRecord(version: payload.version, seq: payload.seq,
            updatedAt: remoteDate.timeIntervalSince1970, localDigest: localDigest, dirty: preservedLocalEdit)
    }

    private func changes(token: String, cursor: Int64, limit: Int) async throws -> AssistantCloudMemoryChangesResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("sync/changes"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "cursor", value: String(cursor)), URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else { throw AssistantCloudMemorySyncError.invalidConfiguration }
        return try await send(url: url, method: "GET", token: token, body: nil)
    }

    private func list(token: String, limit: Int) async throws -> AssistantCloudMemoryListResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("memories"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        guard let url = components?.url else { throw AssistantCloudMemorySyncError.invalidConfiguration }
        return try await send(url: url, method: "GET", token: token, body: nil)
    }

    private func upsert(_ value: AssistantCloudMemoryUpsertRequest, token: String) async throws -> AssistantCloudMemoryPayload {
        try await send(url: baseURL.appendingPathComponent("memories"), method: "POST", token: token,
                       body: try JSONEncoder().encode(value))
    }

    private func delete(id: String, token: String) async throws {
        _ = try await send(url: baseURL.appendingPathComponent("memories").appendingPathComponent(id),
                           method: "DELETE", token: token, body: nil) as AssistantEmptyResponse
    }

    private func send<Response: Decodable>(url: URL, method: String, token: String, body: Data?) async throws -> Response {
        guard baseURL.scheme?.lowercased() == "https", baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil, baseURL.host != nil else {
            throw AssistantCloudMemorySyncError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard data.count <= maximumResponseBytes else { throw AssistantCloudMemorySyncError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else { throw AssistantCloudMemorySyncError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 409 { throw AssistantCloudMemorySyncError.conflict }
            throw AssistantCloudMemorySyncError.httpStatus(http.statusCode)
        }
        if Response.self == AssistantEmptyResponse.self { return AssistantEmptyResponse() as! Response }
        guard !data.isEmpty else { throw AssistantCloudMemorySyncError.invalidResponse }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw AssistantCloudMemorySyncError.invalidResponse }
    }

    private func validate(ownerId: String, token: String) throws {
        guard validIdentifier(ownerId) else { throw AssistantCloudMemorySyncError.invalidOwner }
        guard !token.isEmpty, token.utf8.count <= 16_384,
              token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw AssistantCloudMemorySyncError.invalidToken
        }
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) || $0 == "-" || $0 == "_"
        }
    }

    private func loadState(ownerId: String, defaults: UserDefaults) -> AssistantCloudMemoryState {
        guard let data = defaults.data(forKey: stateKey(ownerId)),
              let state = try? JSONDecoder().decode(AssistantCloudMemoryState.self, from: data) else { return AssistantCloudMemoryState() }
        return state
    }

    private func saveState(_ state: AssistantCloudMemoryState, ownerId: String, defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: stateKey(ownerId)) }
    }

    private func stateKey(_ ownerId: String) -> String {
        "assistant.cloud-memory." + Data(ownerId.utf8).base64EncodedString()
    }

    private static func parseTimestamp(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value), date.timeIntervalSince1970.isFinite else {
            throw AssistantCloudMemorySyncError.malformedMemory
        }
        return date
    }

    private static func digest(_ memory: AssistantMemory) -> String {
        let value = [memory.id, memory.userId, memory.category.rawValue, memory.text,
                     memory.sourceMessageId ?? "", memory.consent, memory.status.rawValue,
                     String(memory.createdAt.timeIntervalSince1970), String(memory.updatedAt.timeIntervalSince1970)].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func serverCategory(_ category: AssistantMemoryCategory) -> String {
        switch category {
        case .fact: return "fact"
        case .preference: return "preference"
        case .importantDate: return "date"
        case .followUp: return "task"
        case .sharedContext: return "shared_context"
        }
    }

    private static func localCategory(_ category: String) -> AssistantMemoryCategory? {
        switch category {
        case "fact": return .fact
        case "preference": return .preference
        case "date", "importantDate": return .importantDate
        case "task", "followUp": return .followUp
        case "shared_context", "sharedContext": return .sharedContext
        default: return nil
        }
    }
}

private struct AssistantEmptyResponse: Decodable {
    init() {}
}

private final class AssistantCloudMemoryRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
