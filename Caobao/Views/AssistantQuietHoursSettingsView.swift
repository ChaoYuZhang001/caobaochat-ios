import SwiftUI

/// This page edits a draft. Notification authorization is never requested here.
struct AssistantQuietHoursSettingsView: View {
    let ownerId: String
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.locale) private var locale
    @State private var policy = AssistantQuietHours.disabled
    @State private var savedPolicy: AssistantQuietHours?
    @State private var loadedIdentity: PageIdentity?
    @State private var isLoaded = false
    @State private var isSaving = false
    @State private var saveRunId: UUID?
    @State private var saveTask: Task<Void, Never>?
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var schedulingWarnings: [String] = []
    private let repository = AssistantLocalRepository.shared
    private var currentOwner: String { auth.user?.id ?? "local-device" }
    private var ownsPage: Bool { !ownerId.isEmpty && ownerId == currentOwner }
    private var pageIdentity: PageIdentity { PageIdentity(ownerId: ownerId, currentOwner: currentOwner) }
    private var isLoadedForCurrentIdentity: Bool { isLoaded && loadedIdentity == pageIdentity }
    private struct PageIdentity: Hashable { let ownerId: String; let currentOwner: String }

    var body: some View {
        Form {
            if !ownsPage {
                Text("账号已变化，请重新打开安静时段设置。").foregroundStyle(.secondary)
            } else if !isLoadedForCurrentIdentity {
                Section {
                    if let statusMessage { Text(statusMessage).foregroundStyle(.secondary) }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    Button("重新读取设置") { reload(force: true) }
                }
            } else {
                configurationSection
                savedSection
                Section {
                    Button { save() } label: {
                        HStack {
                            if isSaving { ProgressView() }
                            Text(LocalizedStringKey(isSaving ? "正在保存安静时段…" : "保存安静时段"))
                        }.frame(minHeight: 44)
                    }
                    .disabled(isSaving || validationMessage != nil)
                    if let validationMessage { Text(validationMessage).font(.caption).foregroundStyle(.red) }
                    if let statusMessage { Text(statusMessage).font(.subheadline).foregroundStyle(.secondary) }
                    if let errorMessage { Text(errorMessage).font(.subheadline).foregroundStyle(.red) }
                    ForEach(Array(schedulingWarnings.enumerated()), id: \.offset) { item in
                        Text(item.element).font(.caption).foregroundStyle(.red)
                    }
                }
                Section {
                    Text("安静时段只影响此账号在本机已开启的任务提醒，不会开启新提醒或请求通知权限。")
                    Text("它不控制 Apple 系统通知、其他应用或尚未接入的服务器推送。")
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .tint(.caobaoPrimary)
        .assistantNavigationTitle("安静时段")
        .task(id: pageIdentity) { reload() }
        .onChange(of: pageIdentity) { _ in resetForIdentityChange(); reload() }
        .onDisappear { cancelPresentation() }
    }

    private var configurationSection: some View {
        Section {
            Toggle("启用安静时段", isOn: $policy.enabled).frame(minHeight: 44)
            DatePicker("开始时间", selection: minuteBinding(start: true), displayedComponents: .hourAndMinute)
                .accessibilityLabel("开始时间")
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                .environment(\.calendar, Calendar(identifier: .gregorian))
            DatePicker("结束时间", selection: minuteBinding(start: false), displayedComponents: .hourAndMinute)
                .accessibilityLabel("结束时间")
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                .environment(\.calendar, Calendar(identifier: .gregorian))
            NavigationLink {
                        AssistantTimeZonePicker(selection: $policy.timeZoneIdentifier)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("安静时段时区")
                    Text(policy.timeZoneIdentifier).font(.caption).foregroundStyle(.secondary)
                }.frame(minHeight: 44)
            }
            Text("按所选时区的当地时间生效；开始时间包含在内，结束时间不包含在内。")
                .font(.caption).foregroundStyle(.secondary)
            Text("落在安静时段内的提醒会延后至结束，不改变任务到期时间；错过的旧提醒不会每天重新推迟。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("提醒时间偏好") }
        .disabled(isSaving)
    }

    @ViewBuilder
    private var savedSection: some View {
        if let savedPolicy {
            Section("当前已保存") {
                Text(LocalizedStringKey(savedPolicy.enabled ? "安静时段已启用" : "安静时段未启用"))
                Text(timeText(savedPolicy.startMinute) + " – " + timeText(savedPolicy.endMinute))
                Text(savedPolicy.timeZoneIdentifier).font(.caption).foregroundStyle(.secondary)
                Text("通知是否实际送达仍取决于系统权限和设备状态。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var validationMessage: String? {
        do { try policy.validated(); return nil }
        catch { return error.localizedDescription }
    }

    /// DatePicker is a pure clock editor. UTC prevents today's DST transition
    /// from altering the minutes the user selected for the recorded policy zone.
    private func minuteBinding(start: Bool) -> Binding<Date> {
        Binding(get: {
            Date(timeIntervalSince1970: Double(start ? policy.startMinute : policy.endMinute) * 60)
        }, set: { value in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let parts = calendar.dateComponents([.hour, .minute], from: value)
            guard let hour = parts.hour, let minute = parts.minute else { return }
            if start { policy.startMinute = hour * 60 + minute }
            else { policy.endMinute = hour * 60 + minute }
        })
    }

    private func timeText(_ minute: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .none; formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: Double(minute) * 60))
    }

    private func reload(force: Bool = false) {
        guard ownsPage, !isSaving else { return }
        guard force || !isLoadedForCurrentIdentity else { return }
        do {
            let stored = try repository.quietHours(for: ownerId)
            policy = stored; savedPolicy = stored; isLoaded = true
            loadedIdentity = pageIdentity
            statusMessage = nil; errorMessage = nil; schedulingWarnings = []
        } catch { isLoaded = false; errorMessage = error.localizedDescription }
    }

    private func save() {
        guard ownsPage, isLoadedForCurrentIdentity, !isSaving else { return }
        do { try policy.validated() } catch { errorMessage = error.localizedDescription; return }
        let owner = ownerId, requested = policy, run = UUID()
        saveRunId = run; isSaving = true; errorMessage = nil; statusMessage = nil; schedulingWarnings = []
        saveTask = Task { @MainActor in
            var committed = false
            do {
                let report = try await AssistantReminderCoordinator.shared.saveQuietHours(requested, ownerId: owner)
                committed = true
                guard !Task.isCancelled, saveRunId == run, ownerId == owner, currentOwner == owner else { return }
                let current = try repository.quietHours(for: owner)
                savedPolicy = current; policy = current
                var seen = Set<String>()
                schedulingWarnings = report.errors.filter { seen.insert($0).inserted }
                let key: String
                if current != requested { key = "安静时段已由其他操作更新，当前显示最新保存值。" }
                else if report.errors.isEmpty { key = "安静时段已保存。" }
                else { key = "设置已保存，但部分提醒未能重新安排。请重试保存或打开任务检查。" }
                statusMessage = AssistantLocalization.string(key)
                NotificationCenter.default.post(name: Notification.Name("assistant.reminders.changed"), object: nil)
            } catch {
                guard !Task.isCancelled, saveRunId == run, ownerId == owner, currentOwner == owner else { return }
                errorMessage = error.localizedDescription
                if committed {
                    statusMessage = AssistantLocalization.string("设置已保存，但无法读取当前配置，请重新打开设置。")
                    isLoaded = false
                } else { statusMessage = AssistantLocalization.string("本次设置未保存，原设置保持不变。") }
            }
            guard saveRunId == run else { return }
            saveRunId = nil; isSaving = false; saveTask = nil
        }
    }

    private func cancelPresentation() {
        saveRunId = nil; saveTask?.cancel(); saveTask = nil; isSaving = false
    }

    private func resetForIdentityChange() {
        cancelPresentation()
        isLoaded = false; loadedIdentity = nil; savedPolicy = nil; policy = .disabled
        statusMessage = nil; errorMessage = nil; schedulingWarnings = []
    }
}

struct AssistantTimeZonePicker: View {
    @Binding var selection: String
    private let title: String
    private let supportedIdentifiers: Set<String>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var query = ""
    init(selection: Binding<String>, title: String = "安静时段时区",
         supportedIdentifiers: Set<String> = AssistantQuietHours.supportedTimeZoneIdentifiers) {
        _selection = selection
        self.title = title
        self.supportedIdentifiers = supportedIdentifiers
    }
    private var zones: [String] {
        let needle = searchKey(query)
        return supportedIdentifiers.sorted().filter { identifier in
            needle.isEmpty || searchKey(identifier).contains(needle)
                || searchKey(zoneName(identifier)).contains(needle)
        }
    }

    var body: some View {
        List(zones, id: \.self) { identifier in
            Button { selection = identifier; dismiss() } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(identifier).foregroundStyle(.primary)
                        Text(zoneName(identifier)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selection == identifier { Image(systemName: "checkmark").foregroundStyle(Color.caobaoPrimary) }
                }.frame(minHeight: 44)
            }.buttonStyle(.plain)
        }
        .overlay {
            if zones.isEmpty {
                VStack(spacing: 8) {
                    Text("没有匹配的时区").font(.headline)
                    Text("试试城市名或地区时区标识，例如 New York 或 Asia/Shanghai。")
                        .font(.caption)
                }.foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
        .searchable(text: $query, prompt: "搜索地区时区")
        .assistantNavigationTitle(title)
    }

    private func zoneName(_ identifier: String) -> String {
        TimeZone(identifier: identifier)?.localizedName(for: .generic, locale: locale) ?? identifier
    }

    private func searchKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            .filter { !$0.isWhitespace && $0 != "_" }
    }
}
