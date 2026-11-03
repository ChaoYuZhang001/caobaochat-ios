#if os(macOS)
import SwiftUI

/// macOS account preference editor.
///
/// The iOS target has the richer AssistantSettingsSheet in HomeView.swift,
/// while that file is intentionally not part of the macOS target. Keep the
/// same type name here so the mac toolbar and generic SettingsView can share
/// the account preference entry point on both platforms.
@MainActor
struct AssistantSettingsSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var language = "system"
    @State private var persona = "normal"
    @State private var region = ""
    @State private var isSaving = false
    @State private var isLoading = true
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("语言") {
                    Picker("助理语言", selection: $language) {
                        Text("跟随系统").tag("system")
                        Text("简体中文").tag("zh-Hans")
                        Text("English").tag("en")
                    }
                }
                Section("表达风格") {
                    Picker("草包风格", selection: $persona) {
                        Text("温和").tag("gentle")
                        Text("标准").tag("normal")
                        Text("犀利").tag("sharp")
                    }
                }
                Section("服务区域") {
                    Picker("默认模型区域", selection: $region) {
                        Text("未选择").tag("")
                        Text("中国大陆模型").tag("CN")
                        Text("海外模型").tag("INTL")
                    }
                    Text("平台模式保存前需要确认服务区域；服务端会校验对应模型池。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message {
                    Section { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .disabled(isLoading || isSaving)
            .navigationTitle("助理账号偏好")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(isLoading || isSaving || !["CN", "INTL"].contains(region))
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        await appState.refreshAssistantState(force: true)
        language = appState.assistantLanguage
        persona = appState.userSettings.toxicLevel
        region = appState.regionConfirmed ? appState.serviceRegion : ""
        isLoading = false
    }

    private func save() async {
        guard ["CN", "INTL"].contains(region), AuthService.shared.isLoggedIn else {
            message = "请先登录并确认服务区域。"
            return
        }
        isSaving = true
        message = nil
        defer { isSaving = false }
        do {
            let token = try await AuthService.shared.validAccessToken()
            let locale = language == "system" ? (Locale.preferredLanguages.first ?? "en") : language
            let request = AssistantPreferencesRequest(
                locale: locale,
                personaLevel: persona,
                serviceRegion: region,
                regionConfirmed: true,
                assistantMode: "platform",
                timeZone: nil
            )
            let response = try await APIService.shared.updateAssistantPreferences(token: token, request: request)
            guard response.success else { throw AssistantPreferencesClientError.invalidResponse }
            appState.assistantLanguage = language
            appState.userSettings.toxicLevel = persona
            appState.serviceRegion = region
            appState.regionConfirmed = true
            appState.saveUserSettings()
            appState.saveAssistantPreferences()
            message = "已保存并同步到服务器。"
        } catch {
            message = "设备设置已保留，服务器暂时无法同步：\(error.localizedDescription)"
        }
    }
}
#endif
