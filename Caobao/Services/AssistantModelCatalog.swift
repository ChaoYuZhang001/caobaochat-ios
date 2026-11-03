import Foundation

struct AssistantModelCapabilities: Codable, Equatable, Hashable {
    let vision: Bool
    let tools: Bool
    let streaming: Bool
}

struct AssistantModelDescriptor: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let displayName: String
    let provider: String?
    let capabilities: AssistantModelCapabilities
}

struct AssistantModelCatalogResponse: Codable, Equatable, Hashable {
    let serviceRegion: String
    let defaultModelId: String?
    let models: [AssistantModelDescriptor]
}

enum AssistantModelCatalogError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidInput
    case invalidResponse
    case regionMismatch
    case unexpectedContentType
    case responseTooLarge
    case networkUnavailable
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return AssistantLocalization.string("模型目录服务配置无效，请稍后重试。")
        case .invalidInput: return AssistantLocalization.string("模型目录请求无效，请确认账号与服务区域。")
        case .invalidResponse: return AssistantLocalization.string("模型目录响应无效，未更新可用模型。")
        case .regionMismatch: return AssistantLocalization.string("模型目录与所选服务区域不一致，未更新可用模型。")
        case .unexpectedContentType: return AssistantLocalization.string("模型目录未返回预期的数据格式。")
        case .responseTooLarge: return AssistantLocalization.string("模型目录超过安全大小限制，未更新可用模型。")
        case .networkUnavailable: return AssistantLocalization.string("暂时无法读取模型目录，请检查网络后重试。")
        case .httpStatus(let status):
            switch status {
            case 401, 403: return AssistantLocalization.string("账号认证失败，请重新登录。")
            case 429: return AssistantLocalization.string("操作过于频繁，请稍后重试。")
            default: return AssistantLocalization.string("读取模型目录未成功，请稍后重试。")
            }
        }
    }
}

/// A stateless account-bound catalog request. Only server-supplied capabilities
/// are decoded; neither an unavailable catalog nor a missing flag grants access.
final class AssistantModelCatalogClient {
    private let baseURL: URL
    private let maximumResponseBytes: Int
    private let session: URLSession

    init(baseURL: URL, sessionConfiguration: URLSessionConfiguration = .ephemeral,
         maximumResponseBytes: Int = 524_288) {
        self.baseURL = baseURL
        self.maximumResponseBytes = min(maximumResponseBytes, 1_048_576)
        let configuration = (sessionConfiguration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        session = URLSession(configuration: configuration, delegate: AssistantModelCatalogRedirectGuard(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func fetch(accessToken: String, region: String) async throws -> AssistantModelCatalogResponse {
        try Task.checkCancellation()
        guard maximumResponseBytes > 0, baseURL.scheme?.lowercased() == "https",
              let host = baseURL.host, !host.isEmpty, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false) else {
            throw AssistantModelCatalogError.invalidConfiguration
        }
        guard ["CN", "INTL"].contains(region), !accessToken.isEmpty, accessToken.utf8.count <= 16_384,
              accessToken.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw AssistantModelCatalogError.invalidInput
        }
        components.queryItems = [URLQueryItem(name: "region", value: region)]
        guard let url = components.url else { throw AssistantModelCatalogError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw AssistantModelCatalogError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw AssistantModelCatalogError.httpStatus(http.statusCode) }
            guard http.statusCode == 200 else { throw AssistantModelCatalogError.invalidResponse }
            guard let mime = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                mime == "application/json" || (mime.hasPrefix("application/") && mime.hasSuffix("+json")) else {
                throw AssistantModelCatalogError.unexpectedContentType
            }
            if let length = http.value(forHTTPHeaderField: "Content-Length") {
                guard let declared = Int64(length), declared >= 0 else { throw AssistantModelCatalogError.invalidResponse }
                guard declared <= Int64(maximumResponseBytes) else { throw AssistantModelCatalogError.responseTooLarge }
            }
            let task = bytes.task
            let data = try await withTaskCancellationHandler(operation: {
                var data = Data()
                for try await byte in bytes {
                    if data.count.isMultiple(of: 4_096) { try Task.checkCancellation() }
                    guard data.count < maximumResponseBytes else { throw AssistantModelCatalogError.responseTooLarge }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return data
            }, onCancel: { task.cancel() })
            guard let result = try? JSONDecoder().decode(AssistantModelCatalogResponse.self, from: data) else {
                throw AssistantModelCatalogError.invalidResponse
            }
            guard result.serviceRegion == region else { throw AssistantModelCatalogError.regionMismatch }
            try validate(result)
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as AssistantModelCatalogError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AssistantModelCatalogError.networkUnavailable
        }
    }

    private func validate(_ catalog: AssistantModelCatalogResponse) throws {
        guard catalog.models.count <= 200 else { throw AssistantModelCatalogError.invalidResponse }
        var ids = Set<String>()
        for model in catalog.models {
            guard !model.id.isEmpty, model.id.utf8.count <= 128,
                  model.id.unicodeScalars.allSatisfy(Self.modelIdentifierCharacter), ids.insert(model.id).inserted,
                  !model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  model.displayName.count <= 256,
                  !model.displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw AssistantModelCatalogError.invalidResponse
            }
        }
        if let defaultId = catalog.defaultModelId {
            guard let model = catalog.models.first(where: { $0.id == defaultId }), model.capabilities.streaming else {
                throw AssistantModelCatalogError.invalidResponse
            }
        }
    }

    private static func modelIdentifierCharacter(_ value: Unicode.Scalar) -> Bool {
        (65...90).contains(value.value) || (97...122).contains(value.value) || (48...57).contains(value.value)
            || value == "-" || value == "_" || value == "/" || value == ":" || value == "."
    }
}

final class AssistantModelCatalogRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
