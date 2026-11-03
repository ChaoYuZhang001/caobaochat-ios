import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

private struct ImportVMFailure: Error, CustomStringConvertible { let description: String }

private final class ImportVMRepositoryFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var rejects = false
    func setRejectsWrites(_ value: Bool) { lock.lock(); rejects = value; lock.unlock() }
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        lock.lock(); let reject = rejects; lock.unlock()
        if reject { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

private struct ImportVMBackup {
    let data: Data
    let plan: AssistantDataImportPlan
    let proposal: AssistantTaskProposal?
}

@MainActor private final class ImportVMFixture {
    static var closing: [ImportVMFixture] = []
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let owner: String
    let archive: AssistantChatArchive
    let repository: AssistantLocalRepository
    let repositoryManager: ImportVMRepositoryFileManager
    let transport: AssistantStreamTransport
    let conversationClient: AssistantConversationClient
    let vm: ChatViewModel
    private var additionalVMs: [ChatViewModel] = []
    private var additionalArchives: [AssistantChatArchive] = []
    var repositoryURL: URL { root.appendingPathComponent("repository.json") }
    var archiveURL: URL { root.appendingPathComponent("archive", isDirectory: true) }
    var prefix: String { "caobao.assistant.\(Data(owner.utf8).base64EncodedString())." }

    init(owner: String = "restore-owner-A", startupBarrier: (@Sendable () async -> Void)? = nil,
         imagePreparationBarrier: (@Sendable () async -> Void)? = nil,
         beforeArchiveCommit: (@Sendable () throws -> Void)? = nil,
         afterArchiveCommit: (@Sendable () async -> Void)? = nil,
         archiveFault: (@Sendable (AssistantArchiveFaultPoint, String) throws -> Void)? = nil) async throws {
        self.owner = owner
        root = FileManager.default.temporaryDirectory.appendingPathComponent("caobao-import-vm-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "caobao-import-vm." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        archive = AssistantChatArchive(directory: root.appendingPathComponent("archive", isDirectory: true), fault: archiveFault)
        try await archive.prepareAsync(userId: owner)
        repositoryManager = ImportVMRepositoryFileManager()
        repository = AssistantLocalRepository(fileURL: root.appendingPathComponent("repository.json"), fileManager: repositoryManager)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ChatFixtureURLProtocol.self]
        transport = AssistantStreamTransport(configuration: configuration, startupBarrier: startupBarrier)
        conversationClient = AssistantConversationClient(baseURL: APIConfig.assistantBaseURL, sessionConfiguration: configuration)
        AuthService.shared.user = ChatFixtureUser(id: owner); AuthService.shared.token = "fixture-access-only"
        let prefix = "caobao.assistant.\(Data(owner.utf8).base64EncodedString())."
        defaults.set("byok", forKey: prefix + "assistantMode")
        defaults.set("en", forKey: prefix + "language")
        defaults.set("CN", forKey: prefix + "serviceRegion")
        defaults.set("https://byok.fixtures.invalid/v1", forKey: "assistant.byok.\(owner).url")
        defaults.set("fixture-model", forKey: "assistant.byok.\(owner).model")
        defaults.set("openai-chat", forKey: "assistant.byok.\(owner).protocol")
        KeychainStore.set("fixture-byok-only", account: "byok-api-key.\(owner)")
        ChatFixtureURLProtocol.reset()
        vm = ChatViewModel(archive: archive, transport: transport, conversationClient: conversationClient,
            repository: repository, defaults: defaults, imagePreparationBarrier: imagePreparationBarrier,
            beforeArchiveCommit: beforeArchiveCommit, afterArchiveCommit: afterArchiveCommit)
        try await vm.waitForArchiveReady(ownerId: owner)
        await vm.waitForPendingArchiveWrites()
    }

    func configureOtherOwner(_ id: String) async throws {
        try await archive.prepareAsync(userId: id)
        let prefix = "caobao.assistant.\(Data(id.utf8).base64EncodedString())."
        defaults.set("byok", forKey: prefix + "assistantMode"); defaults.set("en", forKey: prefix + "language")
    }
    func restart() async throws -> (ChatViewModel, AssistantLocalRepository, AssistantChatArchive) {
        vm.cancel(); await vm.waitForPendingArchiveWrites()
        let diskArchive = AssistantChatArchive(directory: archiveURL), diskRepository = AssistantLocalRepository(fileURL: repositoryURL)
        let restarted = ChatViewModel(archive: diskArchive, transport: transport, conversationClient: conversationClient,
            repository: diskRepository, defaults: defaults)
        additionalVMs.append(restarted); additionalArchives.append(diskArchive)
        try await restarted.waitForArchiveReady(ownerId: owner)
        return (restarted, diskRepository, diskArchive)
    }
    func close() { vm.cancel(); for value in additionalVMs { value.cancel() }; Self.closing.append(self) }
    static func drain() async {
        let fixtures = closing; closing.removeAll()
        for fixture in fixtures {
            for value in [fixture.vm] + fixture.additionalVMs { await value.waitForPendingArchiveWrites() }
            for archive in [fixture.archive] + fixture.additionalArchives { _ = try? await archive.background { _ in () } }
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
    }
}

@main @MainActor private enum AssistantDataImportViewModelTests {
    private static let date = Date(timeIntervalSince1970: 1_793_232_000)
    private static var suites = 0
    private static var failures: [String] = []

    private static func expect(_ value: @autoclosure () async throws -> Bool, _ message: String) async throws {
        if try await !value() { throw ImportVMFailure(description: message) }
    }
    private static func wait(_ message: String, until predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { throw ImportVMFailure(description: "Timed out: " + message) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private static func rejection(_ operation: () async throws -> Void) async throws -> Error {
        do { try await operation() } catch { return error }
        throw ImportVMFailure(description: "Expected restore rejection")
    }
    private static func run(_ name: String, _ body: () async throws -> Void) async {
        print("RUN \(name)"); fflush(stdout)
        do {
            try await body()
            await ImportVMFixture.drain()
            try await expect(ChatFixtureURLProtocol.captured.isEmpty, "Restore tests must start zero intercepted or real HTTP requests")
            suites += 1; print("PASS \(name)")
        } catch {
            await ImportVMFixture.drain(); failures.append(name + ": " + String(describing: error)); print("FAIL \(name): \(error)")
        }
        fflush(stdout)
    }
    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
    }
    private static func image() throws -> AssistantImage {
        let context = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        let data = NSMutableData(), destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImportVMFailure(description: "Fixture image encoding failed") }
        return try AssistantImagePreprocessor.prepare(data as Data)
    }
    private static func proposal(owner: String) throws -> AssistantTaskProposal {
        let arguments = try json(["title": "Imported task suggestion", "notes": "Read-only imported audit",
            "due_at": NSNull(), "time_zone": NSNull(), "reminder_requested": false])
        let items: [[String: Any]] = [
            ["type": "reasoning", "id": "backup-reasoning", "summary": [], "encrypted_content": "private-opaque-trace-must-not-replay"],
            ["type": "function_call", "id": "backup-function", "call_id": "backup-call", "name": "create_task", "arguments": arguments, "status": "completed"]]
        let call = AssistantTaskToolCall(id: "backup-call", name: "create_task", arguments: arguments,
            trace: AssistantTaskToolTrace(protocolKind: .responses, assistantItemsJSON: try json(items)))
        return try AssistantTaskProposal(call: call, ownerId: owner, conversationId: "backup-tool-conversation",
            assistantMessageId: "backup-tool-assistant", sourceUserMessageId: "backup-tool-user", sourceUserText: "Please plan a task",
            configurationFingerprint: String(repeating: "a", count: 64), createdAt: date)
    }
    private static func backup(_ h: ImportVMFixture, tool: Bool = false, pictures: Bool = false,
                               includeImages: Bool = true, orphan: String? = nil, unassigned: Bool = false) throws -> ImportVMBackup {
        let directory = h.root.appendingPathComponent("source-" + UUID().uuidString, isDirectory: true)
        let source = AssistantChatArchive(directory: directory.appendingPathComponent("archive", isDirectory: true))
        try source.prepare(userId: h.owner)
        let repository = AssistantLocalRepository(fileURL: directory.appendingPathComponent("repository.json"))
        let attachment = pictures ? [try image()] : []
        for (index, id) in ["backup-main", "backup-secondary"].enumerated() {
            let messages = [
                ChatMessage(id: "backup-user-\(index)", role: .user, content: "Saved user text \(index)", timestamp: date, images: attachment.isEmpty ? nil : attachment),
                ChatMessage(id: "backup-assistant-\(index)", role: .assistant, content: "Saved answer \(index)", timestamp: date,
                    status: index == 0 ? .streaming : .completed, requestId: "old-request", generationId: "old-generation")]
            try source.upsert(Conversation(id: id, title: "Backup \(index)", preview: "Saved text", date: date,
                messages: messages, serverConversationId: "old-server-conversation"), userId: h.owner)
            try source.saveDraft("Saved draft \(index)", images: attachment, conversationId: id, userId: h.owner)
        }
        repository.addMemory(AssistantMemory(id: "backup-memory", userId: h.owner, category: .preference, text: "Keep user preference",
            sourceMessageId: "backup-user-0", consent: "explicit", status: .active, createdAt: date, updatedAt: date))
        repository.addMemory(AssistantMemory(id: "backup-deleted-memory", userId: h.owner, category: .fact, text: "Deleted secret",
            consent: "explicit", status: .active, createdAt: date, updatedAt: date))
        guard repository.deleteMemory(id: "backup-deleted-memory", userId: h.owner) else { throw ImportVMFailure(description: "Seed tombstone must persist") }
        repository.addTask(AssistantTask(id: "backup-task", userId: h.owner, title: "Imported task", instructions: "User reviews first",
            dueAt: date.addingTimeInterval(86_400), timeZone: "UTC", recurrenceRule: "FREQ=DAILY", requiresApproval: false,
            status: .active, createdAt: date, updatedAt: date, reminderEnabled: true, sourceMessageId: "backup-assistant-1"))
        var toolProposal: AssistantTaskProposal?
        if tool {
            let value = try proposal(owner: h.owner); toolProposal = value
            try source.upsert(Conversation(id: value.conversationId, title: "Tool history", preview: "Historical suggestion", date: date,
                messages: [ChatMessage(id: value.sourceUserMessageId, role: .user, content: "Please plan a task", timestamp: date),
                    ChatMessage(id: value.assistantMessageId, role: .assistant, content: "A historical suggestion", timestamp: date, taskProposal: value)]), userId: h.owner)
            let task = AssistantTask(id: value.taskId, userId: h.owner, title: value.arguments.title, instructions: value.arguments.notes,
                timeZone: "UTC", requiresApproval: true, status: .active, createdAt: date, updatedAt: date, reminderEnabled: false,
                sourceMessageId: value.assistantMessageId)
            let receipt = AssistantTaskToolReceipt(ownerId: h.owner, proposalId: value.id, taskId: task.id, decision: .saved,
                reminderState: .notRequested, committedAt: date, revision: 1)
            _ = try repository.commitTaskToolTask(task, receipt: receipt)
            _ = try repository.claimTaskToolContinuation(proposalId: value.id, ownerId: h.owner, expectedRevision: 1, attemptId: UUID().uuidString)
        }
        if let orphan { try source.saveDraft("Orphan draft text", conversationId: orphan, userId: h.owner) }
        if unassigned { try source.saveDraft("Unassigned draft text", userId: h.owner) }
        let exported = try AssistantDataExporter(archive: source, repository: repository).export(ownerId: h.owner,
            includeImages: includeImages, exportedAt: date)
        let plan = try AssistantDataImporter().prepare(data: exported.data, ownerId: h.owner)
        return ImportVMBackup(data: exported.data, plan: plan, proposal: toolProposal)
    }
    private static func open(_ vm: ChatViewModel, id: String, owner: String) async throws {
        if await vm.requestOpenConversation(id: id, ownerId: owner) { return }
        guard let ticket = vm.pendingConversationSwitch, await vm.confirmConversationSwitch(ticket) else {
            throw ImportVMFailure(description: "Restored draft must have a reachable protected history route: " + (vm.conversationSwitchError ?? "none"))
        }
    }

    static func main() async throws {
        setbuf(stdout, nil)
        await run("restore-real-export-plan-full-records-and-least-privilege") {
            let h = try await ImportVMFixture(); defer { h.close() }
            let source = try backup(h, pictures: true)
            let result = try await h.vm.restoreLocalBackup(source.plan)
            let records = try h.repository.exportSnapshot(for: h.owner), conversations = try h.archive.load(userId: h.owner)
            try await expect(result.isComplete && result.insertedConversationCount == 2 && result.insertedDraftCount == 2
                && result.insertedMemoryCount == 2 && result.insertedTaskCount == 1, "The real export/import/VM path must commit every scope with truthful counts")
            try await expect(conversations.count == 2 && conversations.allSatisfy { $0.serverConversationId == nil }
                && conversations.flatMap(\.messages).allSatisfy { $0.requestId == nil && $0.generationId == nil && $0.taskProposal == nil },
                "Imported history must not restore server or tool execution identities")
            try await expect(conversations.first(where: { $0.id == "backup-main" })?.messages.last?.status == .failed,
                "An interrupted old stream is historical failure, never a revived producer")
            try await expect(records.memories.count == 2 && records.memories.allSatisfy { $0.consent == "unconfirmed" }
                && records.memories.first(where: { $0.status == .deleted })?.text == "", "Memory use remains unconfirmed and tombstones remain scrubbed")
            try await expect(records.tasks.count == 1 && records.tasks[0].reminderEnabled == false && records.tasks[0].requiresApproval,
                "Imported task metadata cannot grant reminder or execution consent")
            try await expect(conversations.first?.messages.first?.images?.count == 1 && !h.vm.isLoading && !h.vm.isArchiveBusy,
                "Validated image records survive without starting a generation")
        }
        await run("restore-preserves-live-draft-and-inactive-restored-draft-is-reachable") {
            let h = try await ImportVMFixture(); defer { h.close() }
            let source = try backup(h), liveID = h.vm.conversationId
            h.vm.inputText = "Private live unsent text"
            h.vm.messages = [ChatMessage(id: "live-user", role: .user, content: "Live conversation", timestamp: date)]
            _ = try await h.vm.restoreLocalBackup(source.plan)
            try await expect(h.vm.conversationId == liveID && h.vm.inputText == "Private live unsent text"
                && h.vm.messages.first?.content == "Live conversation", "Restoration cannot activate an imported draft or replace the live view")
            let before = try h.archive.loadDraftSnapshot(userId: h.owner)
            try await expect(before.active.text == "Private live unsent text" && before.inactive.contains(where: { $0.conversationId == "backup-main" && $0.text == "Saved draft 0" }),
                "Restored slots must stay inactive behind the preserved live active slot")
            try await open(h.vm, id: "backup-main", owner: h.owner)
            try await expect(h.vm.inputText == "Saved draft 0" && (try h.archive.loadDraftRecord(conversationId: liveID, userId: h.owner)).text == "Private live unsent text",
                "A user can explicitly open the imported slot while the departed live draft remains durable")
        }
        await run("restore-retry-and-disk-restart-return-zero-new-counts") {
            let h = try await ImportVMFixture(); defer { h.close() }
            let source = try backup(h)
            _ = try await h.vm.restoreLocalBackup(source.plan)
            let repeated = try await h.vm.restoreLocalBackup(source.plan)
            try await expect(repeated.alreadyApplied && repeated.insertedConversationCount == 0 && repeated.insertedMemoryCount == 0 && repeated.insertedTaskCount == 0,
                "A repeated real plan must not insert again in either store")
            let (vm, repository, archive) = try await h.restart()
            let rePrepared = try AssistantDataImporter().prepare(data: source.data, ownerId: h.owner)
            let afterRestart = try await vm.restoreLocalBackup(rePrepared)
            try await expect(afterRestart.alreadyApplied && afterRestart.insertedConversationCount == 0 && afterRestart.insertedDraftCount == 0
                && afterRestart.insertedMemoryCount == 0 && afterRestart.insertedTaskCount == 0,
                "Both durable digest markers must survive real archive/repository reload")
            try await expect(try archive.load(userId: h.owner).count == 2 && repository.tasks(for: h.owner).count == 1,
                "Restart retry cannot duplicate records")
        }
        await run("restore-precommit-sql-failure-rolls-back-and-never-writes-workspace") {
            let fault = ChatFixtureArchiveFault()
            let h = try await ImportVMFixture(archiveFault: { point, owner in try fault.check(point, owner: owner) })
            defer { fault.arm(nil); h.close() }
            let source = try backup(h)
            fault.arm(.beforeCommit)
            _ = try await rejection { _ = try await h.vm.restoreLocalBackup(source.plan) }
            fault.arm(nil)
            try await expect(try h.archive.conversation(id: "backup-main", userId: h.owner) == nil
                && h.repository.memories(for: h.owner).isEmpty && h.repository.tasks(for: h.owner).isEmpty
                && !FileManager.default.fileExists(atPath: h.repositoryURL.path),
                "A real SQLite failure before COMMIT must precede every workspace write")
            let retry = try await h.vm.restoreLocalBackup(source.plan)
            try await expect(retry.isComplete && !retry.archive.alreadyApplied && retry.insertedConversationCount == 2 && retry.insertedTaskCount == 1,
                "Rollback must include the SQL digest marker so a real retry still inserts")
        }
        await run("restore-workspace-failure-is-explicit-partial-and-same-plan-resumes") {
            let h = try await ImportVMFixture(); defer { h.repositoryManager.setRejectsWrites(false); h.close() }
            let source = try backup(h)
            h.repositoryManager.setRejectsWrites(true)
            let partial = try await h.vm.restoreLocalBackup(source.plan)
            try await expect(!partial.isComplete && partial.workspace == nil && !(partial.workspaceError ?? "").isEmpty
                && partial.insertedConversationCount == 2 && partial.insertedMemoryCount == 0 && partial.insertedTaskCount == 0,
                "After SQL commits, a real repository failure must be reported as partial instead of rollback or success")
            try await expect(try h.archive.conversation(id: "backup-main", userId: h.owner) != nil
                && h.repository.memories(for: h.owner).isEmpty && h.repository.tasks(for: h.owner).isEmpty,
                "The partial result must match both real backing stores")
            h.repositoryManager.setRejectsWrites(false)
            let retry = try await h.vm.restoreLocalBackup(source.plan)
            try await expect(retry.isComplete && retry.archive.alreadyApplied && retry.insertedConversationCount == 0
                && retry.insertedMemoryCount == 2 && retry.insertedTaskCount == 1,
                "Same-plan retry must skip committed SQL and finish the missing atomic workspace merge")
            let final = try await h.vm.restoreLocalBackup(source.plan)
            try await expect(final.alreadyApplied && final.insertedTaskCount == 0, "A resumed backup remains fully idempotent")
        }
        for aba in [false, true] {
            await run(aba ? "restore-before-sql-commit-same-owner-session-aba-rejects" : "restore-before-sql-commit-owner-b-rejects") {
                let worker = ChatFixtureWorkerGate(); defer { worker.open() }
                let h = try await ImportVMFixture(beforeArchiveCommit: { worker.wait() }); defer { h.close() }
                let source = try backup(h), ownerB = "restore-owner-B"
                try await h.configureOtherOwner(ownerB)
                worker.arm()
                let operation = Task { @MainActor () -> Error? in
                    do { _ = try await h.vm.restoreLocalBackup(source.plan); return nil } catch { return error }
                }
                try await wait("restore held at real SQL beforeCommit") { worker.enteredCount > 0 && h.vm.isArchiveBusy }
                if aba {
                    AuthService.shared.applyFixtureIdentity(nil)
                    AuthService.shared.applyFixtureIdentity(ChatFixtureUser(id: h.owner))
                } else { AuthService.shared.applyFixtureIdentity(ChatFixtureUser(id: ownerB)) }
                h.vm.activateOwner()
                try await expect(h.vm.messages.isEmpty && h.vm.inputText.isEmpty, "Identity departure must hide the old owner's live content synchronously")
                worker.open()
                let error = await operation.value
                try await expect(error != nil, "An invalidated precommit permit cannot report successful restoration")
                try await h.vm.waitForArchiveReady(ownerId: aba ? h.owner : ownerB)
                try await expect(try h.archive.conversation(id: "backup-main", userId: h.owner) == nil
                    && h.repository.memories(for: h.owner).isEmpty && h.repository.tasks(for: h.owner).isEmpty,
                    "Precommit identity invalidation must roll SQL back and never start workspace mutation")
                try await expect(h.vm.activeOwner == (aba ? h.owner : ownerB) && h.vm.messages.isEmpty,
                    "The late old-owner completion cannot republish imported content")
            }
        }
        for aba in [false, true] {
            await run(aba ? "restore-after-sql-commit-same-owner-session-aba-blocks-workspace" : "restore-after-sql-commit-owner-b-blocks-workspace") {
                let gate = ChatFixtureAsyncGate(); defer { gate.open() }
                let h = try await ImportVMFixture(afterArchiveCommit: { await gate.wait() }); defer { h.close() }
                let source = try backup(h), ownerB = "restore-owner-B"
                try await h.configureOtherOwner(ownerB)
                let operation = Task { @MainActor () -> Error? in
                    do { _ = try await h.vm.restoreLocalBackup(source.plan); return nil } catch { return error }
                }
                try await wait("actual SQL commit completed before workspace") { gate.enteredCount == 1 }
                try await expect(try h.archive.conversation(id: "backup-main", userId: h.owner) != nil, "The postcommit fixture must actually have committed SQL")
                if aba {
                    AuthService.shared.applyFixtureIdentity(nil)
                    AuthService.shared.applyFixtureIdentity(ChatFixtureUser(id: h.owner))
                } else { AuthService.shared.applyFixtureIdentity(ChatFixtureUser(id: ownerB)) }
                h.vm.activateOwner()
                try await expect(h.vm.messages.isEmpty && h.vm.inputText.isEmpty, "An identity notification clears the old live presentation immediately")
                gate.open()
                guard let error = await operation.value else { throw ImportVMFailure(description: "Postcommit identity change cannot report complete success") }
                guard case AssistantArchiveStateError.committedChanged = error else { throw ImportVMFailure(description: "A truthful postcommit error must distinguish already-committed SQL: \(error)") }
                try await h.vm.waitForArchiveReady(ownerId: aba ? h.owner : ownerB)
                try await expect(h.repository.memories(for: h.owner).isEmpty && h.repository.tasks(for: h.owner).isEmpty
                    && !FileManager.default.fileExists(atPath: h.repositoryURL.path),
                    "Even a same-owner session ABA after SQL must prevent the late detached workspace write")
                if !aba {
                    try await expect(h.vm.activeOwner == ownerB && h.vm.messages.isEmpty
                        && !h.vm.conversations.contains(where: { $0.id == "backup-main" }), "A's committed history cannot appear in B's view")
                    AuthService.shared.applyFixtureIdentity(ChatFixtureUser(id: h.owner)); h.vm.activateOwner()
                    try await h.vm.waitForArchiveReady(ownerId: h.owner)
                }
                let retry = try await h.vm.restoreLocalBackup(source.plan)
                try await expect(retry.isComplete && retry.archive.alreadyApplied && retry.insertedTaskCount == 1,
                    "Returning to A and explicitly retrying may complete the missing workspace scope without redoing SQL")
            }
        }
        await run("restore-busy-queued-generation-rejects-before-any-http") {
            let startup = ChatFixtureAsyncGate(); defer { startup.open() }
            let h = try await ImportVMFixture(startupBarrier: { await startup.wait() }); defer { h.close() }
            let source = try backup(h)
            h.vm.inputText = "A queued generation"
            h.vm.sendMessage(userId: h.owner)
            try await wait("real generation waits before HTTP") { startup.enteredCount == 1 && h.vm.isLoading }
            let error = try await rejection { _ = try await h.vm.restoreLocalBackup(source.plan) }
            try await expect(error as? AssistantDataImportError == .busy && h.repository.tasks(for: h.owner).isEmpty
                && (try h.archive.conversation(id: "backup-main", userId: h.owner)) == nil,
                "An actual pending producer blocks restore without committing the backup")
            h.vm.cancel(); startup.open()
            await h.vm.waitForPendingArchiveWrites()
            try await expect(ChatFixtureURLProtocol.captured.isEmpty, "Neither the rejected restore nor the cancelled queued producer may start HTTP")
        }
        await run("restore-busy-real-image-preparation-rejects") {
            let gate = ChatFixtureAsyncGate(); defer { gate.open() }
            let h = try await ImportVMFixture(imagePreparationBarrier: { await gate.wait() }); defer { h.close() }
            let source = try backup(h)
            let operation = Task { await h.vm.addImageData(Data([0, 1]), ownerId: h.owner) }
            try await wait("actual image preparation held") { gate.enteredCount == 1 && h.vm.isPreparingImage }
            let error = try await rejection { _ = try await h.vm.restoreLocalBackup(source.plan) }
            try await expect(error as? AssistantDataImportError == .busy && h.repository.tasks(for: h.owner).isEmpty
                && (try h.archive.conversation(id: "backup-main", userId: h.owner)) == nil,
                "In-flight image processing must block import even without generation or HTTP")
            gate.open(); await operation.value
        }
        await run("restore-tool-history-neutralized-no-approval-or-provider-replay-authority") {
            let h = try await ImportVMFixture(); defer { h.close() }
            let source = try backup(h, tool: true)
            guard let proposal = source.proposal else { throw ImportVMFailure(description: "Expected actual validated tool history") }
            try await expect(source.plan.neutralizedProposalCount == 1 && source.plan.ignoredReceiptCount == 1,
                "Prepare must audit the real proposal and retained continuation receipt")
            _ = try await h.vm.restoreLocalBackup(source.plan)
            try await open(h.vm, id: proposal.conversationId, owner: h.owner)
            guard let message = h.vm.messages.first(where: { $0.id == proposal.assistantMessageId }) else { throw ImportVMFailure(description: "Restored tool text must be reachable") }
            try await expect(message.taskProposal == nil && message.content.contains("read-only")
                && message.content.contains("Imported task suggestion") && !message.content.contains("private-opaque-trace-must-not-replay"),
                "Only visible read-only audit text may enter restored chat history")
            try await expect(!h.vm.canReviewTaskProposal(messageId: message.id) && !h.vm.canApproveTaskProposal(messageId: message.id)
                && !h.vm.canContinueTaskProposal(messageId: message.id), "Restoration cannot mint a fresh review, approval or paired provider continuation")
            _ = try await rejection { _ = try h.vm.makeTaskProposalSource(messageId: message.id) }
            try await expect(try h.repository.taskToolReceipt(proposalId: proposal.id, ownerId: h.owner) == nil
                && h.repository.tasks(for: h.owner).allSatisfy { $0.reminderEnabled == false && $0.requiresApproval },
                "Backup receipts/claims must not enter the authoritative execution ledger or enable reminders")
        }
        await run("restore-orphan-and-unassigned-drafts-have-explicit-history-routes") {
            let h = try await ImportVMFixture(); defer { h.close() }
            let source = try backup(h, orphan: "orphan-original-slot", unassigned: true)
            let recovered = source.plan.drafts.filter { $0.text == "Orphan draft text" || $0.text == "Unassigned draft text" }
            try await expect(recovered.count == 2 && recovered.allSatisfy { $0.conversationId != nil },
                "Legitimate new-chat/orphan backups must prepare readable detached draft routes")
            h.vm.inputText = "Current unsent text"
            let liveID = h.vm.conversationId
            _ = try await h.vm.restoreLocalBackup(source.plan)
            try await expect(h.vm.inputText == "Current unsent text", "Synthesizing recovered draft routes cannot activate them")
            for draft in recovered {
                try await open(h.vm, id: draft.conversationId!, owner: h.owner)
                try await expect(h.vm.messages.isEmpty && h.vm.inputText == draft.text, "Each draft-only restored conversation must be reachable through the real VM switch API")
            }
            try await expect(try h.archive.loadDraftRecord(conversationId: liveID, userId: h.owner).text == "Current unsent text",
                "Opening recovered draft routes must retain the original live draft")
        }
        await run("restore-pre-cancelled-task-leaves-both-stores-unmodified") {
            let h = try await ImportVMFixture(); defer { h.close() }
            let source = try backup(h)
            let operation = Task { @MainActor () -> Error? in
                do { _ = try await h.vm.restoreLocalBackup(source.plan); return nil } catch { return error }
            }
            operation.cancel()
            let error = await operation.value
            try await expect(error is CancellationError && h.repository.memories(for: h.owner).isEmpty
                && h.repository.tasks(for: h.owner).isEmpty && (try h.archive.conversation(id: "backup-main", userId: h.owner)) == nil,
                "Cancellation before entry cannot create either store's records or digest marker")
            let retry = try await h.vm.restoreLocalBackup(source.plan)
            try await expect(retry.isComplete && !retry.archive.alreadyApplied && retry.insertedTaskCount == 1,
                "A pre-cancelled restore must remain genuinely retryable")
        }
        await run("restore-image-omitting-real-export-keeps-text-and-no-attachment") {
            let h = try await ImportVMFixture(); defer { h.close() }
            let source = try backup(h, pictures: true, includeImages: false)
            try await expect(source.plan.omittedImageCount == 4, "The actual exporter must count both message and draft attachment occurrences")
            _ = try await h.vm.restoreLocalBackup(source.plan)
            let history = try h.archive.load(userId: h.owner), drafts = try h.archive.loadDraftRecords(userId: h.owner)
            try await expect(history.flatMap(\.messages).allSatisfy { $0.images?.isEmpty ?? true }
                && drafts.allSatisfy { $0.images?.isEmpty ?? true } && history.count == 2
                && history.flatMap(\.messages).contains(where: { $0.content == "Saved user text 0" }),
                "Image omission must survive the real restore path without losing text or fabricating attachment data")
        }
        if !failures.isEmpty { throw ImportVMFailure(description: failures.joined(separator: "\n")) }
        print("All \(suites) AssistantDataImport ViewModel suites passed; actual production VM/importer/exporter/stores, test-only identity shell, zero HTTP and no OS notification integration.")
    }
}
