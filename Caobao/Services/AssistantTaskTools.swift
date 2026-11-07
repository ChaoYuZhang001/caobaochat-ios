import Foundation
import CryptoKit

enum AssistantTaskToolMode: String, Codable, Hashable, Sendable {
    case disabled, taskProposal, capabilityProbe
    var functionName: String? {
        switch self {
        case .disabled: return nil
        case .taskProposal: return "create_task"
        case .capabilityProbe: return "caobao_task_probe"
        }
    }
}

/// Canonical arguments digest used when approving one cloud reminder run.
/// Field order, quoting, and Unix-second precision are part of the contract.
enum AssistantCloudTaskApproval {
    static func argumentsHash(taskId: String, scheduledAt: Int64) -> String {
        let canonical = "{\"taskId\":\"\(taskId)\",\"scheduledAt\":\(scheduledAt)}"
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

enum AssistantTaskToolError: LocalizedError, Equatable {
    case unavailable, invalidArguments, invalidTrace, tooLarge, sourceChanged
    case decisionRequired, alreadyResolved, taskConflict, persistenceFailed, capabilityRequired
    var errorDescription: String? {
        let key: String
        switch self {
        case .unavailable: key = "当前接入方式尚未启用待办建议。"
        case .invalidArguments: key = "待办建议的内容或时间格式无效，未创建任务。请手动编辑或重新提出请求。"
        case .invalidTrace: key = "待办建议的调用信息不完整，未创建任务。"
        case .tooLarge: key = "待办建议超过安全大小限制，未创建任务。"
        case .sourceChanged: key = "待办建议的来源或接入设置已改变，请重新打开后确认。"
        case .decisionRequired: key = "请先确认或拒绝当前待办建议，再继续对话。"
        case .alreadyResolved: key = "这条待办建议已经处理，不会重复创建任务。"
        case .taskConflict: key = "无法确认已有任务与这条建议的关联，未重复创建。请查看任务列表。"
        case .persistenceFailed: key = "待办建议的处理结果未能保存，请保留页面并重试。"
        case .capabilityRequired: key = "请先验证当前自定义 API 的待办工具能力，再启用建议。"
        }
        return AssistantLocalization.string(key)
    }
}

/// Provider-owned assistant items needed to pair a completed call and result.
/// Never execute content from this envelope. A changed destination uses plain text.
struct AssistantTaskToolTrace: Codable, Hashable, Sendable {
    static let maximumBytes = 262_144
    let protocolKind: AssistantWireProtocol
    let assistantItemsJSON: String

    func jsonItems() throws -> [[String: Any]] {
        guard assistantItemsJSON.utf8.count <= Self.maximumBytes else { throw AssistantTaskToolError.tooLarge }
        guard let bytes = assistantItemsJSON.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]],
              !items.isEmpty, items.count <= 32 else { throw AssistantTaskToolError.invalidTrace }
        return items
    }
}

struct AssistantTaskToolCall: Codable, Hashable, Sendable {
    static let maximumArgumentBytes = 65_536
    let id: String
    let name: String
    let arguments: String
    let trace: AssistantTaskToolTrace

    func validate(for mode: AssistantTaskToolMode) throws {
        guard mode != .disabled, name == mode.functionName,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id.utf8.count <= 256, !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AssistantTaskToolError.invalidTrace
        }
        guard arguments.utf8.count <= Self.maximumArgumentBytes else { throw AssistantTaskToolError.tooLarge }
        try trace.validateStructure(callId: id, name: name, arguments: arguments)
        switch mode {
        case .disabled: throw AssistantTaskToolError.unavailable
        case .taskProposal: _ = try AssistantTaskToolArguments(json: arguments)
        case .capabilityProbe:
            let value = try AssistantTaskToolScalarObject.parse(arguments)
            guard value == ["ok": .boolean(true)] else { throw AssistantTaskToolError.invalidArguments }
        }
    }
}

struct AssistantTaskToolExchange: Codable, Hashable, Sendable {
    let call: AssistantTaskToolCall
    let configurationFingerprint: String
    let resultJSON: String
}

struct AssistantTaskToolArguments: Codable, Hashable, Sendable {
    let title: String
    let notes: String
    let dueAt: String?
    let timeZone: String?
    let reminderRequested: Bool
    enum CodingKeys: String, CodingKey {
        case title, notes
        case dueAt = "due_at", timeZone = "time_zone", reminderRequested = "reminder_requested"
    }

    init(json: String) throws {
        let object = try AssistantTaskToolScalarObject.parse(json)
        guard Set(object.keys) == ["title", "notes", "due_at", "time_zone", "reminder_requested"],
              case .string(let title)? = object["title"], case .string(let notes)? = object["notes"],
              case .boolean(let reminder)? = object["reminder_requested"] else { throw AssistantTaskToolError.invalidArguments }
        func optionalString(_ key: String) throws -> String? {
            switch object[key] {
            case .string(let value)?: return value
            case .null?: return nil
            default: throw AssistantTaskToolError.invalidArguments
            }
        }
        self.title = title; self.notes = notes
        dueAt = try optionalString("due_at"); timeZone = try optionalString("time_zone")
        reminderRequested = reminder
        try validate()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decode(String.self, forKey: .notes)
        dueAt = try c.decodeIfPresent(String.self, forKey: .dueAt)
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone)
        reminderRequested = try c.decode(Bool.self, forKey: .reminderRequested)
        try validate()
    }

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200,
              notes.count <= 20_000,
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !notes.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }),
              (dueAt == nil) == (timeZone == nil) else { throw AssistantTaskToolError.invalidArguments }
        if let zone = timeZone {
            guard zone.utf8.count <= 128,
                  zone == "UTC" || zone == "GMT" || TimeZone.knownTimeZoneIdentifiers.contains(zone),
                  TimeZone(identifier: zone) != nil, parsedDueDate != nil else { throw AssistantTaskToolError.invalidArguments }
        }
    }

    var parsedDueDate: Date? {
        guard let raw = dueAt, raw.utf8.count <= 64,
              let expression = try? NSRegularExpression(pattern: "^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\\.([0-9]{1,9}))?(Z|[+-]([0-9]{2}):([0-9]{2}))$"),
              let match = expression.firstMatch(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw)) else { return nil }
        func part(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: raw) else { return nil }
            return String(raw[range])
        }
        guard let year = part(1).flatMap(Int.init), let month = part(2).flatMap(Int.init), let day = part(3).flatMap(Int.init),
              let hour = part(4).flatMap(Int.init), let minute = part(5).flatMap(Int.init), let second = part(6).flatMap(Int.init),
              (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second),
              let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        let components = DateComponents(timeZone: utc, year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let nominal = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: nominal)
        guard actual.year == year, actual.month == month, actual.day == day,
              actual.hour == hour, actual.minute == minute, actual.second == second else { return nil }
        var offset = 0
        if part(8) != "Z" {
            guard let offsetHour = part(9).flatMap(Int.init), let offsetMinute = part(10).flatMap(Int.init),
                  (0...23).contains(offsetHour), (0...59).contains(offsetMinute) else { return nil }
            offset = (offsetHour * 3_600 + offsetMinute * 60) * (part(8)?.first == "-" ? -1 : 1)
        }
        let fraction = part(7).flatMap { Double("0." + $0) } ?? 0
        let value = nominal.addingTimeInterval(fraction - Double(offset))
        guard value.timeIntervalSince1970.isFinite,
              (946_684_800...4_102_444_800).contains(value.timeIntervalSince1970) else { return nil }
        return value
    }
}

/// Only scalar parameters are allowed. Duplicate, escaped duplicate, extra and
/// nested keys are rejected before Foundation could silently pick a last value.
private struct AssistantTaskToolScalarObject {
    enum Value: Equatable { case string(String), boolean(Bool), null }
    let bytes: [UInt8]
    var offset = 0
    static func parse(_ raw: String) throws -> [String: Value] {
        guard raw.utf8.count <= AssistantTaskToolCall.maximumArgumentBytes else { throw AssistantTaskToolError.tooLarge }
        var parser = Self(bytes: Array(raw.utf8)); return try parser.object()
    }
    mutating func whitespace() { while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
    mutating func consume(_ byte: UInt8) throws {
        whitespace(); guard offset < bytes.count, bytes[offset] == byte else { throw AssistantTaskToolError.invalidArguments }; offset += 1
    }
    mutating func string() throws -> String {
        whitespace(); let start = offset; try consume(34)
        var escaped = false
        while offset < bytes.count {
            let byte = bytes[offset]; offset += 1
            if escaped { escaped = false; continue }
            if byte == 92 { escaped = true; continue }
            if byte == 34 {
                guard let result = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) else { throw AssistantTaskToolError.invalidArguments }
                return result
            }
        }
        throw AssistantTaskToolError.invalidArguments
    }
    mutating func value() throws -> Value {
        whitespace(); guard offset < bytes.count else { throw AssistantTaskToolError.invalidArguments }
        if bytes[offset] == 34 { return .string(try string()) }
        for (literal, value) in [("true", Value.boolean(true)), ("false", .boolean(false)), ("null", .null)] {
            let token = Array(literal.utf8)
            if bytes[offset...].starts(with: token) { offset += token.count; return value }
        }
        throw AssistantTaskToolError.invalidArguments
    }
    mutating func object() throws -> [String: Value] {
        try consume(123); whitespace(); var result: [String: Value] = [:]
        if offset < bytes.count, bytes[offset] == 125 { offset += 1 }
        else {
            while true {
                let key = try string()
                guard key.utf8.count <= 64, !result.keys.contains(key), result.count < 8 else { throw AssistantTaskToolError.invalidArguments }
                try consume(58); result[key] = try value(); whitespace()
                guard offset < bytes.count else { throw AssistantTaskToolError.invalidArguments }
                if bytes[offset] == 125 { offset += 1; break }
                try consume(44)
            }
        }
        whitespace(); guard offset == bytes.count else { throw AssistantTaskToolError.invalidArguments }
        return result
    }
}

struct AssistantTaskProposal: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let ownerId: String
    let conversationId: String
    let assistantMessageId: String
    let sourceUserMessageId: String
    let sourceUserContentDigest: String
    let configurationFingerprint: String
    let call: AssistantTaskToolCall
    let arguments: AssistantTaskToolArguments
    let createdAt: Date
    var taskId: String { "tool-task-" + Self.digest([id]) }

    init(call: AssistantTaskToolCall, ownerId: String, conversationId: String, assistantMessageId: String,
         sourceUserMessageId: String, sourceUserText: String, configurationFingerprint: String, createdAt: Date = Date()) throws {
        try call.validate(for: .taskProposal)
        self.ownerId = ownerId; self.conversationId = conversationId; self.assistantMessageId = assistantMessageId
        self.sourceUserMessageId = sourceUserMessageId; sourceUserContentDigest = Self.digest([sourceUserText])
        self.configurationFingerprint = configurationFingerprint; self.call = call
        arguments = try AssistantTaskToolArguments(json: call.arguments); self.createdAt = createdAt
        id = "proposal-" + Self.digest([ownerId, conversationId, assistantMessageId, sourceUserMessageId, call.id, call.arguments])
        try validate(ownerId: ownerId, conversationId: conversationId, messageId: assistantMessageId)
    }

    func validate(ownerId: String, conversationId: String, messageId: String) throws {
        guard self.ownerId.utf8.elementsEqual(ownerId.utf8), self.conversationId.utf8.elementsEqual(conversationId.utf8),
              assistantMessageId.utf8.elementsEqual(messageId.utf8),
              [ownerId, conversationId, messageId, sourceUserMessageId].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 1_024 }),
              Self.isDigest(configurationFingerprint), Self.isDigest(sourceUserContentDigest), createdAt.timeIntervalSince1970.isFinite,
              id == "proposal-" + Self.digest([ownerId, conversationId, messageId, sourceUserMessageId, call.id, call.arguments]) else { throw AssistantTaskToolError.sourceChanged }
        try call.validate(for: .taskProposal)
        let parsed = try AssistantTaskToolArguments(json: call.arguments)
        guard arguments.title.utf8.elementsEqual(parsed.title.utf8), arguments.notes.utf8.elementsEqual(parsed.notes.utf8),
              arguments.dueAt == parsed.dueAt, arguments.timeZone == parsed.timeZone,
              arguments.reminderRequested == parsed.reminderRequested else { throw AssistantTaskToolError.invalidArguments }
    }

    static func digest(_ components: [String]) -> String {
        var data = Data()
        for component in components {
            let bytes = Data(component.utf8); var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }; data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func isDigest(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) }
}

enum AssistantTaskToolPreferences {
    static let schemaVersion = 1
    private static func prefix(_ ownerId: String) -> String { "caobao.assistant." + Data(ownerId.utf8).base64EncodedString() + "." }
    static func isEnabled(defaults: UserDefaults, ownerId: String, configurationFingerprint: String) -> Bool {
        let key = prefix(ownerId)
        return AssistantTaskProposal.isDigest(configurationFingerprint) && defaults.integer(forKey: key + "taskToolsSchemaVersion") == schemaVersion
            && defaults.bool(forKey: key + "taskToolsEnabled")
            && defaults.string(forKey: key + "taskToolsVerifiedFingerprint") == configurationFingerprint
    }
    static func set(enabled: Bool, verifiedFingerprint: String?, defaults: UserDefaults, ownerId: String) throws {
        guard verifiedFingerprint.map(AssistantTaskProposal.isDigest) ?? !enabled else { throw AssistantTaskToolError.capabilityRequired }
        let key = prefix(ownerId); defaults.set(enabled, forKey: key + "taskToolsEnabled")
        if let verifiedFingerprint {
            defaults.set(verifiedFingerprint, forKey: key + "taskToolsVerifiedFingerprint")
            defaults.set(schemaVersion, forKey: key + "taskToolsSchemaVersion")
        } else {
            defaults.removeObject(forKey: key + "taskToolsVerifiedFingerprint")
            defaults.removeObject(forKey: key + "taskToolsSchemaVersion")
        }
    }
    static func verifiedFingerprint(defaults: UserDefaults, ownerId: String) -> String? {
        guard defaults.integer(forKey: prefix(ownerId) + "taskToolsSchemaVersion") == schemaVersion else { return nil }
        return defaults.string(forKey: prefix(ownerId) + "taskToolsVerifiedFingerprint")
    }
}
