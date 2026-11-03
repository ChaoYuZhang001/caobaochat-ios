import Foundation

enum AssistantModelPreferences {
    static func key(ownerId: String, region: String) -> String {
        "caobao.assistant.\(Data(ownerId.utf8).base64EncodedString()).platformModel.\(region)"
    }

    /// An absent selection means the server's regional default, never a local fallback.
    static func selectedModel(ownerId: String, region: String, defaults: UserDefaults = .standard) -> String {
        guard !ownerId.isEmpty, ["CN", "INTL"].contains(region),
              let saved = defaults.string(forKey: key(ownerId: ownerId, region: region)),
              validIdentifier(saved) else { return "" }
        return saved
    }

    static func save(_ modelId: String, ownerId: String, region: String, defaults: UserDefaults = .standard) throws {
        guard !ownerId.isEmpty, ["CN", "INTL"].contains(region),
              modelId.isEmpty || validIdentifier(modelId) else { throw InvalidSelection() }
        let name = key(ownerId: ownerId, region: region)
        let previous = selectedModel(ownerId: ownerId, region: region, defaults: defaults)
        if modelId.isEmpty { defaults.removeObject(forKey: name) }
        else { defaults.set(modelId, forKey: name) }
        if previous != modelId {
            NotificationCenter.default.post(name: Notification.Name("assistant.generationConfigurationChanged"), object: ownerId)
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value)
                || ["-", "_", ".", ":", "/"].contains(String($0))
        }
    }

    struct InvalidSelection: Error {}
}
