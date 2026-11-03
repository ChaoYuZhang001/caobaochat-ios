import Foundation

/// Explicit presentation opt-in for app-owned errors whose descriptions already
/// use fixed, localized strings. Unknown LocalizedError values are not trusted.
protocol AssistantLocalizedNetworkFailure: LocalizedError {}

/// Dynamic strings use the same explicit resource language as the SwiftUI UI.
/// Selection is process-local; per-account persistence remains the owner's job.
enum AssistantLocalization {
    private final class LanguageState: @unchecked Sendable {
        let lock = NSLock()
        var value = "system"
    }

    private static let state = LanguageState()

    static func setLanguage(_ value: String) {
        state.lock.lock()
        state.value = normalized(value)
        state.lock.unlock()
    }

    static func string(_ key: String) -> String {
        string(key, bundle: .main)
    }

    static func networkErrorDescription(_ error: Error) -> String {
        networkErrorDescription(error, bundle: .main)
    }

    /// Map OS network errors without rendering their localizedDescription, URL,
    /// userInfo, certificate details or provider body in the app's language.
    static func networkErrorDescription(_ error: Error, bundle: Bundle) -> String {
        let key: String
        if error is CancellationError {
            key = "连接检测已取消，未确认连接成功。"
        } else {
            let network = error as NSError
            if network.domain == NSURLErrorDomain {
                switch network.code {
                case URLError.Code.secureConnectionFailed.rawValue, URLError.Code.serverCertificateHasBadDate.rawValue,
                     URLError.Code.serverCertificateUntrusted.rawValue, URLError.Code.serverCertificateHasUnknownRoot.rawValue,
                     URLError.Code.serverCertificateNotYetValid.rawValue, URLError.Code.clientCertificateRejected.rawValue,
                     URLError.Code.clientCertificateRequired.rawValue, URLError.Code.appTransportSecurityRequiresSecureConnection.rawValue:
                    key = "无法建立安全连接，请检查服务证书和地址后重试。"
                case URLError.Code.timedOut.rawValue:
                    key = "连接检测超时，请检查地址和网络后重试。"
                case URLError.Code.notConnectedToInternet.rawValue, URLError.Code.dataNotAllowed.rawValue,
                     URLError.Code.internationalRoamingOff.rawValue, URLError.Code.callIsActive.rawValue:
                    key = "网络不可用，请检查网络连接后重试。"
                case URLError.Code.networkConnectionLost.rawValue:
                    key = "网络连接已中断，请重试连接检测。"
                case URLError.Code.cannotFindHost.rawValue, URLError.Code.dnsLookupFailed.rawValue:
                    key = "无法解析服务地址，请检查地址后重试。"
                case URLError.Code.cannotConnectToHost.rawValue, URLError.Code.badURL.rawValue, URLError.Code.unsupportedURL.rawValue:
                    key = "无法连接到服务，请检查地址和网络后重试。"
                case URLError.Code.cancelled.rawValue:
                    key = "连接检测已取消，未确认连接成功。"
                default:
                    key = "连接检测失败，请检查配置和网络后重试。"
                }
            } else if let trusted = error as? AssistantLocalizedNetworkFailure, let description = trusted.errorDescription {
                return description
            } else {
                key = "连接检测失败，请检查配置和网络后重试。"
            }
        }
        return string(key, bundle: bundle)
    }

    /// Bundle injection exercises the real resource lookup without changing the
    /// host's AppleLanguages, app preferences, identity, or Keychain.
    static func string(_ key: String, bundle: Bundle) -> String {
        state.lock.lock()
        let language = state.value
        state.lock.unlock()
        return string(key, language: language, bundle: bundle)
    }

    /// Maps the view's locale to one of the actual app resource languages.
    /// Unsupported locales retain Foundation's normal bundle fallback.
    static func resourceLanguage(for locale: Locale) -> String {
        switch locale.language.languageCode?.identifier {
        case "en": return "en"
        case "zh":
            if locale.language.script?.identifier == "Hans" { return "zh-Hans" }
            if locale.language.script?.identifier == "Hant" { return "system" }
            switch locale.region?.identifier {
            case nil, "CN", "SG": return "zh-Hans"
            default: return "system"
            }
        default: return "system"
        }
    }

    static func string(_ key: String, language: String, bundle: Bundle) -> String {
        let language = normalized(language)
        guard language != "system" else {
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }

        // An explicit app language must select its lproj, rather than merely
        // passing a Locale to String(localized:) while keeping the host bundle.
        // Missing translations fall back to English, then the development/Base
        // resources, and finally the source key.
        let candidates = [language, "en", bundle.developmentLocalization, "Base"].compactMap { $0 }
        let missing = "__CAOBAO_MISSING_LOCALIZATION_783D3B8E__" + key
        var visited = Set<String>()
        for candidate in candidates where visited.insert(candidate).inserted {
            guard let path = bundle.path(forResource: candidate, ofType: "lproj"),
                  let localizedBundle = Bundle(path: path) else { continue }
            let value = localizedBundle.localizedString(forKey: key, value: missing, table: nil)
            if value != missing { return value }
        }
        return key
    }

    private static func normalized(_ value: String) -> String {
        switch value {
        case "en", "zh-Hans": return value
        default: return "system"
        }
    }
}
