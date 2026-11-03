import Foundation

private struct LocalizationTestFailure: Error, CustomStringConvertible { let description: String }
private struct UnknownLocalizedNetworkFailure: LocalizedError {
    var errorDescription: String? { "OS中文错误 https://private.invalid/secret?api_key=PRIVATE-TEXT" }
}
private struct TrustedLocalizedNetworkFailure: AssistantLocalizedNetworkFailure {
    let text: String?
    var errorDescription: String? { text }
}

private final class LocalizationFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func add(_ message: String) { lock.lock(); messages.append(message); lock.unlock() }
    var first: String? { lock.lock(); defer { lock.unlock() }; return messages.first }
}

@main
private enum AssistantLocalizationTests {
    private static var suites = 0

    private struct Fixture {
        let root: URL
        let bundle: Bundle
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw LocalizationTestFailure(description: message) }
    }

    private static func run(_ name: String, _ body: () throws -> Void) throws {
        try body(); suites += 1; print("PASS \(name)")
    }

    private static func fixture(_ values: [String: [String: String]], development: String = "en") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CaoBaoLocalization-\(UUID().uuidString).bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "chat.caobao.localization-fixture.\(UUID().uuidString)",
            "CFBundleName": "LocalizationFixture", "CFBundleVersion": "1", "CFBundlePackageType": "BNDL",
            "CFBundleDevelopmentRegion": development, "CFBundleLocalizations": values.keys.sorted()]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        for (language, strings) in values {
            let folder = resources.appendingPathComponent(language + ".lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: strings, format: .xml, options: 0)
                .write(to: folder.appendingPathComponent("Localizable.strings"))
        }
        guard let bundle = Bundle(path: root.path) else {
            try? FileManager.default.removeItem(at: root)
            throw LocalizationTestFailure(description: "Could not open the real temporary resource bundle")
        }
        return Fixture(root: root, bundle: bundle)
    }

    static func main() throws {
        let values = ["en": ["greeting": "Hello", "今日助理": "Today", "english-only": "English fallback", "same-as-key": "English replacement",
            "format": "Remaining %lld / %lld for %@ (100%%)", "line\nquoted": "First line\nSecond line: “quoted”", "empty-value": ""],
            "zh-Hans": ["greeting": "你好", "今日助理": "今日助理", "same-as-key": "same-as-key",
                "format": "剩余 %lld / %lld 次，%@（100%%）", "line\nquoted": "第一行\n第二行：“引号”", "empty-value": ""]]
        let fixture = try fixture(values)
        defer { fixture.remove(); AssistantLocalization.setLanguage("system") }
        let systemGreeting = fixture.bundle.localizedString(forKey: "greeting", value: "greeting", table: nil)

        try run("default-system-uses-resource-bundle-selection") {
            try expect(AssistantLocalization.string("greeting", bundle: fixture.bundle) == systemGreeting,
                "Default selection must be the bundle's real system selection")
            let missing = "untranslated-main-bundle-key"
            try expect(AssistantLocalization.string(missing) == Bundle.main.localizedString(forKey: missing, value: missing, table: nil),
                "The production no-argument bundle path must use Bundle.main")
        }

        try run("explicit-english-selects-english-lproj") {
            AssistantLocalization.setLanguage("en")
            try expect(AssistantLocalization.string("greeting", bundle: fixture.bundle) == "Hello", "English override did not select its actual lproj")
            try expect(AssistantLocalization.string("greeting", language: "en", bundle: fixture.bundle) == "Hello", "Explicit bundle lookup must select English")
        }

        try run("explicit-simplified-chinese-selects-chinese-lproj") {
            AssistantLocalization.setLanguage("zh-Hans")
            try expect(AssistantLocalization.string("greeting", bundle: fixture.bundle) == "你好", "Chinese override did not select its actual lproj")
            try expect(AssistantLocalization.string("greeting", language: "en", bundle: fixture.bundle) == "Hello", "An injected lookup must not mutate global language selection")
            try expect(AssistantLocalization.string("greeting", bundle: fixture.bundle) == "你好", "Explicit lookup changed the app language")
        }

        try run("system-restores-foundation-bundle-behavior") {
            AssistantLocalization.setLanguage("system")
            try expect(AssistantLocalization.string("greeting", bundle: fixture.bundle) == systemGreeting, "System reset must release the app override")
            try expect(AssistantLocalization.string("greeting", language: "system", bundle: fixture.bundle) == systemGreeting, "Injected system behavior must use the bundle")
        }

        try run("environment-locale-maps-to-supported-resource-language") {
            let cases: [(String, String)] = [
                ("en", "en"), ("en_US", "en"), ("en-GB", "en"), ("en_US_POSIX", "en"),
                ("zh-Hans", "zh-Hans"), ("zh_Hans_CN", "zh-Hans"), ("zh_Hans_TW", "zh-Hans"),
                ("zh_CN", "zh-Hans"), ("zh_SG", "zh-Hans"), ("zh", "zh-Hans"),
                ("zh-Hant", "system"), ("zh_Hant_CN", "system"), ("zh_TW", "system"),
                ("zh_HK", "system"), ("zh_MO", "system"),
                ("fr_FR", "system"), ("de_DE", "system"), ("ar", "system")
            ]
            for (identifier, expected) in cases {
                try expect(AssistantLocalization.resourceLanguage(for: Locale(identifier: identifier)) == expected,
                    "Environment locale did not map to its supported resource language: " + identifier)
            }
        }

        try run("navigation-title-string-changes-with-environment-locale") {
            // Exercise the modifier's actual Foundation lookup path using the
            // reported title key. Global service language must not override the
            // explicit environment locale or require rebuilding a view identity.
            let titleKey = "今日助理"
            AssistantLocalization.setLanguage("zh-Hans")
            let english = AssistantLocalization.string(titleKey,
                language: AssistantLocalization.resourceLanguage(for: Locale(identifier: "en_US")), bundle: fixture.bundle)
            AssistantLocalization.setLanguage("en")
            let chinese = AssistantLocalization.string(titleKey,
                language: AssistantLocalization.resourceLanguage(for: Locale(identifier: "zh-Hans")), bundle: fixture.bundle)
            let englishAgain = AssistantLocalization.string(titleKey,
                language: AssistantLocalization.resourceLanguage(for: Locale(identifier: "en")), bundle: fixture.bundle)
            try expect(english == "Today" && chinese == "今日助理" && englishAgain == "Today",
                "The same source key must produce different native title Strings as the environment changes")
            try expect(english != chinese, "Changing locale must change the resolved navigation title value")
        }

        try run("unsupported-environment-locale-uses-normal-bundle-fallback") {
            AssistantLocalization.setLanguage("zh-Hans")
            let language = AssistantLocalization.resourceLanguage(for: Locale(identifier: "fr_FR"))
            try expect(AssistantLocalization.string("greeting", language: language, bundle: fixture.bundle) == systemGreeting,
                "An unsupported view locale must preserve Foundation's real resource fallback")
        }

        try run("invalid-language-cannot-select-an-arbitrary-resource-path") {
            for language in ["", "fr", "EN", "zh", "zh-Hant", " en ", "../en", "en/../../", String(repeating: "a", count: 1_000)] {
                AssistantLocalization.setLanguage("zh-Hans")
                AssistantLocalization.setLanguage(language)
                try expect(AssistantLocalization.string("greeting", bundle: fixture.bundle) == systemGreeting, "Invalid app language must reset to system")
                try expect(AssistantLocalization.string("greeting", language: language, bundle: fixture.bundle) == systemGreeting, "Injected invalid language must reset to system")
            }
        }

        try run("missing-translation-falls-back-to-english-and-source-key") {
            AssistantLocalization.setLanguage("zh-Hans")
            try expect(AssistantLocalization.string("english-only", bundle: fixture.bundle) == "English fallback", "Missing Chinese translation must use the English lproj")
            try expect(AssistantLocalization.string("totally-missing", bundle: fixture.bundle) == "totally-missing", "Missing translations must preserve their source key")
            try expect(AssistantLocalization.string("same-as-key", bundle: fixture.bundle) == "same-as-key", "A valid translation equal to the key must not be mistaken for a missing value")
            try expect(AssistantLocalization.string("empty-value", bundle: fixture.bundle) == "", "An intentionally empty translated value must remain empty")
        }

        try run("missing-selected-language-bundle-falls-back") {
            let english = try self.fixture(["en": ["greeting": "English-only bundle"]])
            defer { english.remove() }
            try expect(AssistantLocalization.string("greeting", language: "zh-Hans", bundle: english.bundle) == "English-only bundle", "A missing selected lproj must not block English fallback")
            let development = try self.fixture(["fr": ["greeting": "Development fallback"]], development: "fr")
            defer { development.remove() }
            try expect(AssistantLocalization.string("greeting", language: "zh-Hans", bundle: development.bundle) == "Development fallback", "Missing English must use the actual development resource bundle")
            let base = try self.fixture(["Base": ["greeting": "Base fallback"]])
            defer { base.remove() }
            try expect(AssistantLocalization.string("greeting", language: "en", bundle: base.bundle) == "Base fallback", "Missing development resources must use Base")
        }

        try run("format-placeholders-survive-resource-selection") {
            for (language, expected) in [("en", "Remaining 7 / 600 for CaoBao (100%)"), ("zh-Hans", "剩余 7 / 600 次，CaoBao（100%）")] {
                AssistantLocalization.setLanguage(language)
                let format = AssistantLocalization.string("format", bundle: fixture.bundle)
                let rendered = String(format: format, Int64(7), Int64(600), "CaoBao")
                try expect(rendered == expected, "Numeric, object and percent format tokens must remain intact")
            }
        }

        try run("unicode-newlines-and-quotes-round-trip") {
            for language in ["en", "zh-Hans"] {
                AssistantLocalization.setLanguage(language)
                try expect(AssistantLocalization.string("line\nquoted", bundle: fixture.bundle) == values[language]!["line\nquoted"], "Source-key newlines and translated Unicode must round-trip through the actual strings file")
            }
        }

        try run("concurrent-language-updates-and-bundle-lookups") {
            let failures = LocalizationFailures()
            let allowed = Set(["Hello", "你好", systemGreeting])
            DispatchQueue.concurrentPerform(iterations: 2_000) { index in
                let language = ["en", "zh-Hans", "system", "invalid"][index % 4]
                AssistantLocalization.setLanguage(language)
                let translated = AssistantLocalization.string("greeting", bundle: fixture.bundle)
                if !allowed.contains(translated) { failures.add("Concurrent global lookup returned an invalid value: " + translated) }
                let explicit = AssistantLocalization.string("greeting", language: "en", bundle: fixture.bundle)
                if explicit != "Hello" { failures.add("Concurrent explicit lookup lost its resource bundle") }
                if AssistantLocalization.string("missing-\(index)", bundle: fixture.bundle) != "missing-\(index)" {
                    failures.add("Concurrent fallback mixed source keys")
                }
            }
            if let failure = failures.first { throw LocalizationTestFailure(description: failure) }
            AssistantLocalization.setLanguage("en")
            try expect(AssistantLocalization.string("greeting", bundle: fixture.bundle) == "Hello", "State must remain usable after concurrent mutations")
        }

        let secure = "无法建立安全连接，请检查服务证书和地址后重试。"
        let timeout = "连接检测超时，请检查地址和网络后重试。"
        let offline = "网络不可用，请检查网络连接后重试。"
        let interrupted = "网络连接已中断，请重试连接检测。"
        let dns = "无法解析服务地址，请检查地址后重试。"
        let host = "无法连接到服务，请检查地址和网络后重试。"
        let cancelled = "连接检测已取消，未确认连接成功。"
        let fallback = "连接检测失败，请检查配置和网络后重试。"
        let english = [secure: "A secure connection could not be established. Check the service certificate and address, then try again.",
            timeout: "The connection check timed out. Check the address and network, then try again.",
            offline: "The network is unavailable. Check your connection and try again.",
            interrupted: "The network connection was interrupted. Try the connection check again.",
            dns: "The service address could not be resolved. Check the address and try again.",
            host: "Could not connect to the service. Check the address and network, then try again.",
            cancelled: "The connection check was cancelled. A successful connection was not confirmed.",
            fallback: "The connection check failed. Check your settings and network, then try again.",
            "app-http": "Service request failed (HTTP %d)", "app-config": "Enter a valid HTTPS address."]
        var chinese = Dictionary(uniqueKeysWithValues: [secure, timeout, offline, interrupted, dns, host, cancelled, fallback].map { ($0, $0) })
        chinese["app-http"] = "服务请求失败（HTTP %d）"; chinese["app-config"] = "请输入有效的 HTTPS 地址。"
        let networkFixture = try self.fixture(["en": english, "zh-Hans": chinese])
        defer { networkFixture.remove() }
        let privateDetails = "TLS错误导致安全连接失败。 https://private.invalid/path?api_key=PRIVATE-TEXT"
        try run("network-tls-certificate-errors-use-explicit-app-language") {
            let codes: [URLError.Code] = [.secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection]
            for language in ["en", "zh-Hans"] {
                AssistantLocalization.setLanguage(language)
                for code in codes {
                    let value = NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: privateDetails, NSURLErrorFailingURLStringErrorKey: "https://private.invalid/secret"])
                    let presented = AssistantLocalization.networkErrorDescription(value, bundle: networkFixture.bundle)
                    try expect(presented == (language == "en" ? english[secure]! : secure), "TLS errors must resolve through the app's selected lproj, independently of Chinese OS text")
                    try expect(!presented.contains("private.invalid") && !presented.contains("PRIVATE-TEXT") && !presented.contains(privateDetails), "Certificate and URL detail must never be rendered")
                }
            }
        }
        try run("network-timeout-offline-dns-host-and-interruption-have-specific-messages") {
            let mappings: [(URLError.Code, String)] = [(.timedOut, timeout), (.notConnectedToInternet, offline), (.dataNotAllowed, offline),
                (.internationalRoamingOff, offline), (.callIsActive, offline), (.networkConnectionLost, interrupted),
                (.cannotFindHost, dns), (.dnsLookupFailed, dns), (.cannotConnectToHost, host), (.badURL, host), (.unsupportedURL, host)]
            for language in ["en", "zh-Hans"] {
                AssistantLocalization.setLanguage(language)
                for (code, key) in mappings {
                    let error = URLError(code, userInfo: [NSLocalizedDescriptionKey: privateDetails])
                    try expect(AssistantLocalization.networkErrorDescription(error, bundle: networkFixture.bundle) == (language == "en" ? english[key]! : key), "Each supported network category must use its specific app-language message")
                }
            }
            AssistantLocalization.setLanguage("en")
            try expect(AssistantLocalization.networkErrorDescription(URLError(.timedOut)) == AssistantLocalization.string(timeout), "Production overload must use the same main-bundle lookup path")
        }
        try run("network-cancellation-never-presents-success") {
            for language in ["en", "zh-Hans"] {
                AssistantLocalization.setLanguage(language)
                let expected = language == "en" ? english[cancelled]! : cancelled
                for error: Error in [CancellationError(), URLError(.cancelled)] {
                    try expect(AssistantLocalization.networkErrorDescription(error, bundle: networkFixture.bundle) == expected, "Swift and URL cancellation must explicitly state that success is unconfirmed")
                }
            }
        }
        try run("network-unknown-os-and-untrusted-localized-errors-have-private-free-fallback") {
            let errors: [Error] = [NSError(domain: "ForeignProvider", code: URLError.Code.timedOut.rawValue, userInfo: [NSLocalizedDescriptionKey: privateDetails]),
                UnknownLocalizedNetworkFailure(), URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: privateDetails])]
            for language in ["en", "zh-Hans"] {
                AssistantLocalization.setLanguage(language)
                for error in errors {
                    let presented = AssistantLocalization.networkErrorDescription(error, bundle: networkFixture.bundle)
                    try expect(presented == (language == "en" ? english[fallback]! : fallback), "Unknown domains or descriptions cannot bypass the app-language fallback")
                    try expect(!presented.contains("PRIVATE-TEXT") && !presented.contains("private.invalid"), "Unknown LocalizedError is not a trusted raw provider string")
                }
            }
            let onlyEnglish = try self.fixture(["en": [fallback: english[fallback]!]])
            defer { onlyEnglish.remove() }
            AssistantLocalization.setLanguage("zh-Hans")
            try expect(AssistantLocalization.networkErrorDescription(UnknownLocalizedNetworkFailure(), bundle: onlyEnglish.bundle) == english[fallback], "Missing selected resources retain the standard English fallback")
        }
        try run("network-explicit-app-localized-http-and-configuration-semantics-preserved") {
            for language in ["en", "zh-Hans"] {
                AssistantLocalization.setLanguage(language)
                let http = String(format: AssistantLocalization.string("app-http", bundle: networkFixture.bundle), 401)
                let configuration = AssistantLocalization.string("app-config", bundle: networkFixture.bundle)
                for value in [http, configuration] {
                    try expect(AssistantLocalization.networkErrorDescription(TrustedLocalizedNetworkFailure(text: value), bundle: networkFixture.bundle) == value, "Explicitly trusted app-localized formats and configuration guidance must not become generic network failures")
                }
                try expect(AssistantLocalization.networkErrorDescription(TrustedLocalizedNetworkFailure(text: nil), bundle: networkFixture.bundle) == (language == "en" ? english[fallback]! : fallback), "An app error without a description still has a stable fallback")
            }
        }
        try run("network-message-lookups-stay-safe-during-concurrent-language-updates") {
            let failures = LocalizationFailures(), allowed = Set([secure, english[secure]!])
            DispatchQueue.concurrentPerform(iterations: 500) { index in
                AssistantLocalization.setLanguage(index.isMultiple(of: 2) ? "en" : "zh-Hans")
                let error = NSError(domain: NSURLErrorDomain, code: URLError.Code.secureConnectionFailed.rawValue, userInfo: [NSLocalizedDescriptionKey: privateDetails])
                let presented = AssistantLocalization.networkErrorDescription(error, bundle: networkFixture.bundle)
                if !allowed.contains(presented) { failures.add("Concurrent network error lookup mixed OS text or resources") }
            }
            if let failure = failures.first { throw LocalizationTestFailure(description: failure) }
        }
        print("All \(suites) localization test groups passed")
    }
}
