import Foundation
import CryptoKit
import SQLite3

private struct DatabaseTestFailure: Error, CustomStringConvertible { let description: String }
private final class DatabaseGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0); private var active = false
    func block() { lock.lock(); active = true; lock.unlock(); semaphore.wait() }
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func open() { semaphore.signal() }
}
private final class DatabaseControl: @unchecked Sendable {
    private let lock = NSLock(); private var failPoint: AssistantArchiveFaultPoint?; private var gatePoint: AssistantArchiveFaultPoint?; private var gate: DatabaseGate?
    func fail(_ point: AssistantArchiveFaultPoint?) { lock.lock(); failPoint = point; lock.unlock() }
    func hold(_ point: AssistantArchiveFaultPoint, _ gate: DatabaseGate) { lock.lock(); gatePoint = point; self.gate = gate; lock.unlock() }
    func check(_ point: AssistantArchiveFaultPoint, _ owner: String) throws { lock.lock(); let fail = failPoint == point, gate = gatePoint == point ? self.gate : nil; lock.unlock(); if owner != "A" { return }; if fail { throw DatabaseTestFailure(description:"Injected storage fault") }; gate?.block() }
}
private final class DatabaseFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
private final class DatabasePublishControl: @unchecked Sendable {
    private let lock = NSLock(); private var next: DatabaseGate?
    func arm(_ gate: DatabaseGate) { lock.lock(); next = gate; lock.unlock() }
    func publish() { lock.lock(); let gate = next; next = nil; lock.unlock(); gate?.block() }
}
private final class DatabaseAuthorizationURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock(); private static var started = 0
    static func reset() { lock.lock(); started = 0; lock.unlock() }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return started }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixtures.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.started += 1; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"fixture\"}}]}\n\ndata: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
@main private enum AssistantChatDatabaseTests {
    private static var count = 0
    private static let date = Date(timeIntervalSince1970: 1_793_232_000)
    private static let storageErrorCases: [(error: AssistantChatStorageError, key: String, english: String)] = [
        (.notPrepared, "本地历史记录尚未准备好，请稍后重试。", "Local history is not ready yet. Please try again shortly."),
        (.cursorInvalidated, "历史记录已更新，请从第一页重新加载。", "History changed. Reload from the first page."),
        (.invalidPageLimit, "无法加载这页历史记录，请重新加载列表。", "Unable to load this history page. Reload the list."),
        (.invalidOwner, "当前账号信息无效，请重新打开页面后重试。", "The current account information is invalid. Reopen this page and try again."),
        (.authoritativeStoreUnavailable, "无法打开当前账号的本地历史记录，请稍后重试。现有数据不会被自动覆盖。", "Unable to open this account's local history. Please try again later. Existing data will not be overwritten automatically."),
        (.corruptStore, "本地历史记录格式异常，已停止本次操作以保护数据。请稍后重试。", "Local history could not be read correctly. This operation was stopped to protect your data. Please try again later."),
        (.publicationCommittedCleanupPending, "本次更改已保存，但本地清理尚未完成。请重试清理。", "Your changes are saved, but local cleanup is not complete. Please retry cleanup."),
        (.transactionBoundary, "无法在当前状态下完成本次操作，请重新打开页面后重试。", "This operation cannot be completed in the current state. Reopen the page and try again."),
        (.revisionConflict, "这条会话已被其他操作更新，请重新打开后再保存。", "This conversation changed elsewhere. Reopen it before saving."),
        (.invalidQuery, "搜索内容过长，请缩短后重试。", "Your search is too long. Shorten it and try again."),
        (.purgeRecoveryRequired, "上次本地清理尚未完成。请先重试清理，再继续使用历史记录。", "Previous local cleanup is not complete. Retry cleanup before using history."),
        (.sqlite(5), "本地历史记录暂时无法读写，请稍后重试。", "Local history is temporarily unavailable. Please try again later.")
    ]
    private static func storageErrorBundle(_ folder: URL) throws -> Bundle {
        let root = folder.appendingPathComponent("StorageErrors.bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true), resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "chat.caobao.storage-errors." + UUID().uuidString, "CFBundleName": "StorageErrorFixture",
            "CFBundleVersion": "1", "CFBundlePackageType": "BNDL", "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": ["en", "zh-Hans"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        for language in ["en", "zh-Hans"] {
            let target = resources.appendingPathComponent(language + ".lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let values = Dictionary(uniqueKeysWithValues: storageErrorCases.map { ($0.key, language == "en" ? $0.english : $0.key) })
            try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: target.appendingPathComponent("Localizable.strings"))
        }
        guard let bundle = Bundle(path: root.path) else { throw DatabaseTestFailure(description: "Cannot open storage error resource fixture") }
        return bundle
    }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw DatabaseTestFailure(description:message) } }
    private static func rejects(_ operation: () throws -> Void) throws -> Error { do { try operation() } catch { return error }; throw DatabaseTestFailure(description:"Expected storage rejection") }
    private static func asyncRejects(_ operation: () async throws -> Void) async throws -> Error { do { try await operation() } catch { return error }; throw DatabaseTestFailure(description:"Expected async rejection") }
    private static func ready(_ folder: URL, owners:[String] = ["A"], control: DatabaseControl? = nil) throws -> AssistantChatArchive { let store = AssistantChatArchive(directory:folder,fault:{ point,owner in try control?.check(point,owner) }); for owner in owners { try store.prepare(userId:owner) }; return store }
    private static func conv(_ id:String, title:String? = nil, preview:String = "preview", order:Double = 0, turn:String? = nil, text:String = "private body") -> Conversation { Conversation(id:id,title:title ?? "Title "+id,preview:preview,date:date.addingTimeInterval(order),messages:[ChatMessage(id:turn ?? "u-"+id,role:.user,content:"question",timestamp:date),ChatMessage(id:"a-"+id,role:.assistant,content:text,timestamp:date,status:.streaming,requestId:"r",generationId:"g",model:"m",usage:AssistantUsage(inputTokens:2,outputTokens:3),replacesMessageId:"older")],serverConversationId:"server-"+id) }
    private static func legacyURL(_ folder:URL, owner:String="A") -> URL { let hash=SHA256.hash(data:Data(owner.utf8)).map { String(format:"%02x",$0) }.joined(); return folder.appendingPathComponent(hash+".json") }
    private static func files(_ folder:URL) throws -> [String:Data] { var result:[String:Data]=[:]; for url in try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) { result[url.lastPathComponent]=try Data(contentsOf:url) }; return result }
    private static func seedLegacy(_ folder:URL) throws { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); try JSONEncoder().encode([conv("legacy",text:"legacy private")]).write(to:legacyURL(folder)); try JSONEncoder().encode(AssistantChatDraft(text:"legacy draft",conversationId:"legacy")).write(to:legacyURL(folder).appendingPathExtension("draft")) }
    private static func wait(_ gate:DatabaseGate) async throws { for _ in 0..<200 { if gate.entered { return }; try await Task.sleep(nanoseconds:5_000_000) }; throw DatabaseTestFailure(description:"Worker gate was not entered") }
    private static func fastSnapshot(_ archive: AssistantChatArchive, blocked: DatabaseGate) async throws -> AssistantArchiveAuthorizationSnapshot {
        let timeout = DatabaseFlag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { timeout.set(); blocked.open() }
        let result = await MainActor.run { archive.authorizationSnapshot(userId: "A") }
        try expect(!timeout.isSet, "MainActor authorization must return while the worker is still blocked, not after the failsafe releases it")
        return result
    }
    private static func run(_ name:String, root:URL, _ operation:(URL) async throws -> Void) async throws { let folder=root.appendingPathComponent(name); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true); do { try await operation(folder) } catch { throw DatabaseTestFailure(description:name+": \(error)") }; count += 1; print("PASS "+name); fflush(stdout) }
    static func main() async { do { try await runAll() } catch { fputs("FAIL \(error)\n",stderr); exit(1) } }
    private static func runAll() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("caobao-database-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        try await run("sqlite-explicit-preparation-and-cache-only-readiness",root:root) { folder in
            let a=AssistantChatArchive(directory:folder); try expect(!a.isPrepared(userId:"A"),"Readiness is cache only")
            let error=try rejects { _=try a.pageSummaries(userId:"A") }; try expect(error as? AssistantChatStorageError == .notPrepared && (try files(folder)).isEmpty,"Sync query cannot start migration")
            try await a.prepareAsync(userId:"A"); try expect(a.isPrepared(userId:"A") && FileManager.default.fileExists(atPath:a.databaseURL(userId:"A").path),"Actual database publishes before ready")
        }
        try await run("sqlite-real-keyset-all-pages-decode-zero-bodies",root:root) { folder in
            let a=try ready(folder)
            for index in 0..<125 { try a.upsert(conv(String(format:"%03d",index),order:Double(index/3),text:String(repeating:"private",count:100)),userId:"A") }
            let raw=try AssistantChatDatabase(url:a.databaseURL(userId:"A"),create:false); defer { try? raw.close() }; try raw.execute("UPDATE bodies SET payload=? WHERE id='000'",[.blob(Data("{broken unseen body".utf8))])
            let before=try a.diagnostics(userId:"A"); var ids:[String]=[], cursor:AssistantConversationCursor?
            repeat { let page=try await a.pageSummariesAsync(userId:"A",cursor:cursor,limit:17); ids += page.items.map(\.id); cursor=page.nextCursor } while cursor != nil
            try expect(ids.count == 125 && Set(ids).count == 125 && ids.first == "124" && ids.last == "000","Tie sort keys use ID and genuine SQL pages cover every header once")
            try expect(try a.diagnostics(userId:"A").bodyDecodes == before.bodyDecodes,"Even a corrupt unseen body cannot be read or decoded by metadata paging")
        }
        try await run("sqlite-detail-loads-one-complete-snapshot",root:root) { folder in
            let a=try ready(folder), full=conv("one",text:"all fields \0 中文"); try a.upsert(full,userId:"A"); try a.upsert(conv("other"),userId:"A")
            let before=try a.diagnostics(userId:"A").bodyDecodes, loaded=try await a.conversationAsync(id:"one",userId:"A")
            try expect(try loaded == full && a.diagnostics(userId:"A").bodyDecodes == before+1,"ID lookup preserves all statuses usage lineage images and server ID without decoding another body")
        }
        try await run("sqlite-unicode-full-search-and-literal-wildcards",root:root) { folder in
            let a=try ready(folder); for index in 0..<70 { try a.upsert(conv("row\(index)",title:index == 0 ? "CAFÉ 中文 100%_literal":"Other",preview:index == 0 ? "命中":"none",order:Double(index)),userId:"A") }
            let searched = try await a.pageSummariesAsync(userId:"A",query:"cafe 中文")
            try expect(searched.items.map(\.id) == ["row0"],"Search finds normalized metadata beyond the first page")
            try expect(try a.pageSummaries(userId:"A",query:"%_literal").items.count == 1 && a.pageSummaries(userId:"A",query:"不存在").items.isEmpty,"Search parameters are literal and never interpolation")
        }
        try await run("sqlite-nul-text-and-blob-roundtrip-with-strict-utf8",root:root) { folder in
            let a=try ready(folder), value=conv("nul",title:"before\0标题after",preview:"preview\0秘密after",text:"body\0byte\n"); try a.upsert(value,userId:"A")
            let header=try a.pageSummaries(userId:"A").items[0]
            try expect(try header.title.utf8.elementsEqual(value.title.utf8) && header.preview.utf8.elementsEqual(value.preview.utf8) && a.conversation(id:"nul",userId:"A") == value,"Explicit byte counts preserve NUL in TEXT and JSON BLOB")
            try expect(try a.pageSummaries(userId:"A",query:"秘密after").items.count == 1 && a.pageSummaries(userId:"A",query:"\0秘密").items.count == 1,"Full metadata search does not stop at an embedded NUL")
            let raw=try AssistantChatDatabase(url:a.databaseURL(userId:"A"),create:false); defer { try? raw.close() }; try raw.execute("UPDATE headers SET title=CAST(X'80' AS TEXT) WHERE id='nul'")
            let before=try files(folder), error=try rejects { _=try a.pageSummaries(userId:"A") }; try expect(error as? AssistantChatStorageError == .corruptStore && (try files(folder)) == before,"Invalid UTF8 is an explicit error rather than replacement text")
        }
        try await run("sqlite-owner-cursor-query-and-generation-binding",root:root) { folder in
            let a=try ready(folder,owners:["A","B"]); for index in 0..<3 { try a.upsert(conv("\(index)",order:Double(index)),userId:"A") }; let page=try a.pageSummaries(userId:"A",limit:1), cursor=page.nextCursor!
            try expect(try rejects { _=try a.pageSummaries(userId:"B",cursor:cursor) } as? AssistantChatStorageError == .cursorInvalidated,"Owner cursor cannot cross databases")
            try expect(try rejects { _=try a.pageSummaries(userId:"A",query:"changed",cursor:cursor) } as? AssistantChatStorageError == .cursorInvalidated,"Query change requires fresh page")
            try a.upsert(conv("new",order:99),userId:"A"); try expect(try rejects { _=try a.pageSummaries(userId:"A",cursor:cursor) } as? AssistantChatStorageError == .cursorInvalidated,"Structural changes invalidate old list generations")
        }
        try await run("sqlite-stream-body-updates-do-not-reorder-or-invalidate-default-pages",root:root) { folder in
            let a=try ready(folder); try a.upsert(conv("old",preview:"match",order:0),userId:"A"); try a.upsert(conv("live",preview:"match",order:1),userId:"A")
            let first=try a.pageSummaries(userId:"A",limit:1), search=try a.pageSummaries(userId:"A",query:"match",limit:1)
            try a.upsert(conv("live",preview:"match changed",order:100,text:"more streaming output"),userId:"A")
            try expect(try a.pageSummaries(userId:"A",cursor:first.nextCursor,limit:1).items.map(\.id) == ["old"] && a.pageSummaries(userId:"A").generation == first.generation,"Same user turn keeps stable sort and default pagination")
            try expect(try rejects { _=try a.pageSummaries(userId:"A",query:"match",cursor:search.nextCursor) } as? AssistantChatStorageError == .cursorInvalidated,"Actual search membership text has its own generation")
            try a.upsert(conv("live",order:101,turn:"next-user-turn"),userId:"A"); try expect(try a.pageSummaries(userId:"A").generation != first.generation,"A new user turn advances ordering")
        }
        try await run("sqlite-revision-cas-rejects-stale-full-snapshot",root:root) { folder in
            let a=try ready(folder); try a.upsert(conv("one"),userId:"A"); let revision=try a.pageSummaries(userId:"A").items[0].revision
            try a.upsert(conv("one",text:"newest"),expectingRevision:revision,userId:"A"); let before=try files(folder)
            try expect(try rejects { try a.upsert(conv("one",text:"stale"),expectingRevision:revision,userId:"A") } as? AssistantChatStorageError == .revisionConflict && a.conversation(id:"one",userId:"A")?.messages.last?.content == "newest" && files(folder) == before,"Stale revision cannot replace complete current history")
        }
        try await run("sqlite-compound-cancel-before-commit-rolls-back-conversation-and-drafts",root:root) { folder in
            let control=DatabaseControl(), a=try ready(folder,control:control), gate=DatabaseGate(); defer { gate.open() }; let original=conv("one"); try a.upsert(original,userId:"A"); try a.saveDraft("source",conversationId:"s",userId:"A"); control.hold(.beforeCommit,gate)
            let task=Task { try await a.backgroundTransaction(userId:"A",operation:{ store in try store.upsert(conv("one",text:"new"),userId:"A"); return try store.selectDraft(conversationId:"target",preserving:AssistantChatDraft(text:"changed",conversationId:"s"),userId:"A") }) }
            try await wait(gate); task.cancel(); gate.open(); let error=try await asyncRejects { _=try await task.value }
            try expect(try error is CancellationError && a.conversation(id:"one",userId:"A") == original && a.loadDraftRecords(userId:"A").map(\.text) == ["source"],"Nested legacy writes share one cancellation rollback boundary")
        }
        try await run("sqlite-cancel-after-commit-linearization-returns-real-commit",root:root) { folder in
            let a=try ready(folder), gate=DatabaseGate(); defer { gate.open() }
            let task=Task { try await a.backgroundTransaction(userId:"A",operation:{ store in try store.upsert(conv("committed"),userId:"A"); return "stored" },beforeCommit:{ gate.block() }) }
            try await wait(gate); task.cancel(); gate.open(); let result=try await task.value
            try expect(try result == "stored" && a.conversation(id:"committed",userId:"A") != nil,"Cancellation after successful synchronous authorization cannot misreport a committed write as rolled back")
        }
        try await run("sqlite-queued-cancellation-and-mainactor-responsiveness",root:root) { folder in
            let a=try ready(folder), gate=DatabaseGate(); defer { gate.open() }; let blocker=Task { try await a.background { _ in gate.block() } }; try await wait(gate)
            let responsive=await MainActor.run { true }; try expect(responsive,"Blocked storage worker does not block MainActor")
            let cancelled=Task { try await a.background { try $0.upsert(conv("never"),userId:"A") } }; cancelled.cancel(); gate.open(); try await blocker.value
            let error=try await asyncRejects { try await cancelled.value }; try expect(try error is CancellationError && a.load(userId:"A").isEmpty,"Queued cancelled job does not reach SQL mutation")
        }
        try await run("sqlite-migration-prepublication-failures-preserve-legacy-bytes",root:root) { folder in
            for (index,point) in [AssistantArchiveFaultPoint.migrationRead,.migrationImported,.migrationVerified,.beforePublish].enumerated() {
                let sub=folder.appendingPathComponent("stage\(index)"); try seedLegacy(sub); let before=try files(sub), control=DatabaseControl(); control.fail(point); let a=AssistantChatArchive(directory:sub,fault:{ p,o in try control.check(p,o) })
                _=try await asyncRejects { try await a.prepareAsync(userId:"A") }
                try expect(try files(sub) == before && !a.isPrepared(userId:"A") && !FileManager.default.fileExists(atPath:a.databaseURL(userId:"A").path),"Before publish every injected stage leaves original source bytes and no false ready store")
            }
        }
        try await run("sqlite-migration-cancellation-is-background-and-nondestructive",root:root) { folder in
            try seedLegacy(folder); let before=try files(folder), control=DatabaseControl(), gate=DatabaseGate(); defer { gate.open() }; control.hold(.migrationImported,gate)
            let a=AssistantChatArchive(directory:folder,fault:{ p,o in try control.check(p,o) }), task=Task { try await a.prepareAsync(userId:"A") }
            try await wait(gate); let responsive=await MainActor.run { true }; try expect(responsive,"Migration import cannot monopolize the UI actor"); task.cancel(); gate.open()
            let error=try await asyncRejects { try await task.value }; try expect(try error is CancellationError && files(folder) == before && !a.isPrepared(userId:"A"),"Cancelled unpublished migration preserves every original byte")
        }
        try await run("sqlite-postpublication-cleanup-failure-is-a-committed-authority",root:root) { folder in
            for (index,point) in [AssistantArchiveFaultPoint.afterPublish,.legacyCleanup].enumerated() {
                let sub=folder.appendingPathComponent("stage\(index)"); try seedLegacy(sub); let original=try Data(contentsOf:legacyURL(sub)), control=DatabaseControl(); control.fail(point)
                let a=AssistantChatArchive(directory:sub,fault:{ p,o in try control.check(p,o) }); let error=try await asyncRejects { try await a.prepareAsync(userId:"A") }
                try expect(try error as? AssistantChatStorageError == .publicationCommittedCleanupPending && a.isPrepared(userId:"A") && a.conversation(id:"legacy",userId:"A")?.messages.last?.content == "legacy private" && Data(contentsOf:legacyURL(sub)) == original,"Published DB is usable and error truthfully reports cleanup rather than rollback")
                try Data("corrupt obsolete backup".utf8).write(to:legacyURL(sub)); let cold=try ready(sub)
                try expect(try cold.conversation(id:"legacy",userId:"A")?.id == "legacy" && !FileManager.default.fileExists(atPath:legacyURL(sub).path),"Cold preparation never falls back to an obsolete source")
            }
        }
        try await run("sqlite-missing-or-corrupt-authority-database-never-falls-back",root:root) { folder in
            let a=try ready(folder); try a.upsert(conv("current"),userId:"A"); try JSONEncoder().encode([conv("old-resurrection")]).write(to:legacyURL(folder)); try FileManager.default.removeItem(at:a.databaseURL(userId:"A")); let before=try files(folder), cold=AssistantChatArchive(directory:folder)
            try expect(try rejects { try cold.prepare(userId:"A") } as? AssistantChatStorageError == .authoritativeStoreUnavailable && files(folder) == before,"Published marker with missing DB cannot remigrate old private JSON")
            _=try rejects { _=try a.load(userId:"A") }; try expect(!a.isPrepared(userId:"A"),"An open cached handle cannot keep writing to an unlinked database")
        }
        try await run("sqlite-crashed-staged-publication-recovers-verified-database",root:root) { folder in
            let source=folder.appendingPathComponent("source"), a=try ready(source); try a.upsert(conv("staged"),userId:"A")
            let target=folder.appendingPathComponent("target"); try seedLegacy(target); let b=AssistantChatArchive(directory:target)
            try Data(contentsOf:a.databaseURL(userId:"A")).write(to:b.databaseURL(userId:"A").appendingPathExtension("migrating"))
            try JSONSerialization.data(withJSONObject:["ownerId":"A","state":"publishing","version":1]).write(to:b.authorityURL(userId:"A"))
            try b.prepare(userId:"A"); try expect(try b.load(userId:"A").map(\.id) == ["staged"],"Crash between intent and rename resumes the verified staged database, never old JSON")
        }
        try await run("sqlite-legacy-envelope-import-preserves-all-drafts-and-tombstones",root:root) { folder in
            try JSONEncoder().encode([conv("dead"),conv("live")]).write(to:legacyURL(folder))
            let draft=AssistantChatDraft(text:"live draft",conversationId:"live"), row=try JSONSerialization.jsonObject(with:JSONEncoder().encode(draft))
            let envelope:[String:Any]=["version":1,"ownerId":"A","activeConversationId":"live","activeUnassigned":false,"unassignedDraft":["text":"unassigned"],"conversationDrafts":["live":row,"dead":["text":"deleted draft","conversationId":"dead"]],"deletedConversationIds":["dead"]]
            try JSONSerialization.data(withJSONObject:envelope).write(to:legacyURL(folder).appendingPathExtension("draft")); let a=try ready(folder)
            try expect(try a.load(userId:"A").map(\.id) == ["live"] && a.deletedConversationIds(userId:"A") == ["dead"] && a.loadDraftRecord(userId:"A") == draft && a.loadDraftRecords(userId:"A").map(\.text) == ["unassigned","live draft"],"Migration retains active/unassigned/inactive state and irreversible deletion decisions")
        }
        try await run("sqlite-exact-owner-identity-and-invalid-owner-utf8",root:root) { folder in
            let composed="é", decomposed="e\u{301}", a=try ready(folder,owners:[composed,decomposed]); try a.upsert(conv("one",text:"composed"),userId:composed); try a.upsert(conv("one",text:"decomposed"),userId:decomposed)
            try expect(try a.conversation(id:"one",userId:composed)?.messages.last?.content == "composed" && a.conversation(id:"one",userId:decomposed)?.messages.last?.content == "decomposed","Unicode normalization must not merge owner caches or files")
            let store=try ready(folder), raw=try AssistantChatDatabase(url:store.databaseURL(userId:"A"),create:false); try raw.execute("UPDATE meta SET value=CAST(X'80' AS TEXT) WHERE key='owner'"); try raw.close(); let before=try files(folder), cold=AssistantChatArchive(directory:folder)
            _=try rejects { try cold.prepare(userId:"A") }; try expect(try files(folder) == before && !cold.isPrepared(userId:"A"),"Invalid owner bytes never become replacement identities")
        }
        try await run("sqlite-authorized-purge-does-not-require-readable-legacy-or-db",root:root) { folder in
            try seedLegacy(folder); let a=try ready(folder); try Data("not sqlite".utf8).write(to:a.databaseURL(userId:"A")); try Data("bad legacy".utf8).write(to:legacyURL(folder))
            let cold=AssistantChatArchive(directory:folder); try cold.deleteAll(userId:"A"); try cold.prepare(userId:"A")
            try expect(try cold.load(userId:"A").isEmpty && cold.loadDraftRecords(userId:"A").isEmpty && !FileManager.default.fileExists(atPath:legacyURL(folder).path),"Explicit authorized erasure cleans corrupt authority and old backups rather than being trapped by failed migration")
        }
        try await run("sqlite-compound-cross-owner-write-rolls-back-and-export-is-complete",root:root) { folder in
            let a=try ready(folder,owners:["A","B"])
            _=try await asyncRejects { try await a.backgroundTransaction(userId:"A",operation:{ store in try store.saveDraft("A partial",conversationId:"a",userId:"A"); try store.saveDraft("B forbidden",conversationId:"b",userId:"B") }) }
            try expect(try a.loadDraftRecords(userId:"A").isEmpty && a.loadDraftRecords(userId:"B").isEmpty,"A compound transaction cannot make side commits into another owner")
            try await a.backgroundTransaction(userId:"A",operation:{ store in try store.upsert(conv("one"),userId:"A"); try store.saveDraft("inactive",conversationId:"old",userId:"A"); try store.saveDraft("active",conversationId:"one",userId:"A") })
            let before=try files(folder), snapshot=try await a.loadExportSnapshotAsync(userId:"A")
            try expect(try snapshot.conversations.count == 1 && snapshot.activeDraft.text == "active" && snapshot.inactiveDrafts.map(\.text) == ["inactive"] && files(folder) == before,"One SQL read transaction exports complete bodies and every draft without source mutation")
        }
        try await run("sqlite-legacy-source-change-before-publish-never-loses-the-newer-bytes",root:root) { folder in
            try seedLegacy(folder)
            let newer = try JSONEncoder().encode([conv("newer",text:"newest original legacy content")])
            let oldDraft = try Data(contentsOf:legacyURL(folder).appendingPathExtension("draft"))
            let a = AssistantChatArchive(directory:folder,fault:{ point,_ in if point == .beforePublish { try newer.write(to:legacyURL(folder),options:.atomic) } })
            _ = try await asyncRejects { try await a.prepareAsync(userId:"A") }
            try expect(try !a.isPrepared(userId:"A") && Data(contentsOf:legacyURL(folder)) == newer && Data(contentsOf:legacyURL(folder).appendingPathExtension("draft")) == oldDraft && !FileManager.default.fileExists(atPath:a.databaseURL(userId:"A").path),"Changed original source aborts unpublished migration without cleaning or overwriting new legacy data")
            let cold = try ready(folder); try expect(try cold.load(userId:"A").map(\.id) == ["newer"],"Explicit retry migrates the latest complete source")
        }
        try await run("sqlite-corrupt-staged-complete-flag-is-not-enough-to-publish",root:root) { folder in
            let source = folder.appendingPathComponent("source"), a = try ready(source); try a.upsert(conv("staged"),userId:"A")
            let target = folder.appendingPathComponent("target"); try seedLegacy(target); let b = AssistantChatArchive(directory:target), temp = b.databaseURL(userId:"A").appendingPathExtension("migrating")
            try Data(contentsOf:a.databaseURL(userId:"A")).write(to:temp)
            let raw = try AssistantChatDatabase(url:temp,create:false); try raw.execute("UPDATE bodies SET payload=?",[.blob(Data("{corrupt staged body".utf8))]); try raw.close()
            try JSONSerialization.data(withJSONObject:["ownerId":"A","state":"publishing","version":1]).write(to:b.authorityURL(userId:"A"))
            let before = try files(target); _ = try rejects { try b.prepare(userId:"A") }
            try expect(try !b.isPrepared(userId:"A") && !FileManager.default.fileExists(atPath:b.databaseURL(userId:"A").path) && files(target) == before,"Recovered stage is fully decoded and checked before rename or original cleanup")
        }
        try await run("sqlite-malformed-required-draft-or-state-is-never-a-missing-record",root:root) { folder in
            let a = try ready(folder); try a.saveDraft("source",conversationId:"s",userId:"A"); try a.saveDraft("target",conversationId:"t",userId:"A")
            let raw = try AssistantChatDatabase(url:a.databaseURL(userId:"A"),create:false); defer { try? raw.close() }
            try raw.execute("UPDATE drafts SET payload=42 WHERE slot='c:t'")
            let before = try files(folder)
            _ = try rejects { _ = try a.loadDraftRecord(userId:"A") }
            _ = try rejects { _ = try a.loadDraftRecord(conversationId:"t",userId:"A") }
            _ = try rejects { try a.saveDraft("overwrite",conversationId:"t",userId:"A") }
            _ = try rejects { _ = try a.selectDraft(conversationId:"t",preserving:AssistantChatDraft(text:"edit",conversationId:"s"),userId:"A") }
            try expect(try files(folder) == before,"Malformed existing BLOB cannot be silently replaced through active read, target lookup, save or selection")
            try raw.execute("DELETE FROM state"); let damaged = try files(folder)
            _ = try rejects { _ = try a.pageSummaries(userId:"A") }; _ = try rejects { _ = try a.isPurgingAll(userId:"A") }
            try expect(try files(folder) == damaged,"Missing authority state is explicit corruption, not default zero or false")
        }
        try await run("sqlite-missing-full-body-fails-detail-and-export-without-hiding-header",root:root) { folder in
            let a = try ready(folder); try a.upsert(conv("one"),userId:"A")
            let raw = try AssistantChatDatabase(url:a.databaseURL(userId:"A"),create:false); defer { try? raw.close() }; try raw.execute("DELETE FROM bodies WHERE id='one'")
            let before = try files(folder); try expect(try a.pageSummaries(userId:"A").items.count == 1,"Metadata query remains body independent")
            _ = try rejects { _ = try a.conversation(id:"one",userId:"A") }; _ = try rejects { _ = try a.loadExportSnapshot(userId:"A") }
            _ = try rejects { try a.upsert(conv("one",text:"overwrite"),userId:"A") }
            try expect(try files(folder) == before,"Required missing body is not a missing conversation or permission to overwrite corruption")
        }
        try await run("authorization-fast-mainactor-read-never-enters-a-blocked-worker",root:root) { folder in
            let a = try ready(folder), gate = DatabaseGate(); defer { gate.open() }
            let worker = Task { try await a.background { _ in gate.block() } }; try await wait(gate)
            let snapshot = try await fastSnapshot(a,blocked:gate)
            try expect(snapshot.prepared && !snapshot.unknown && snapshot.canWrite(conversationId:"live"), "A busy normal storage worker does not block valid cached authorization")
            gate.open(); try await worker.value
            try a.upsert(conv("one"),userId:"A"); try a.saveDraft("active",conversationId:"one",userId:"A")
            let exported = try await a.exportSnapshotAsync(userId:"A")
            try expect(exported.ownerId == "A" && exported.conversations.count == 1 && exported.activeDraft.text == "active" && exported.generation != nil, "Typed export is owner-bound and complete after one SQL snapshot")
        }
        try await run("authorization-preparation-unknown-is-fast-and-fail-closed",root:root) { folder in
            try seedLegacy(folder); let control = DatabaseControl(), gate = DatabaseGate(); defer { gate.open() }; control.hold(.migrationImported,gate)
            let a = AssistantChatArchive(directory:folder,fault:{ p,o in try control.check(p,o) }), worker = Task { try await a.prepareAsync(userId:"A") }
            try await wait(gate); let snapshot = try await fastSnapshot(a,blocked:gate)
            try expect(!snapshot.prepared && snapshot.unknown && !snapshot.canWrite(conversationId:"legacy"), "Unknown unpublished migration never grants an HTTP start")
            gate.open(); try await worker.value
            try expect(a.authorizationSnapshot(userId:"A").canWrite(conversationId:"legacy"), "Only actual publication grants readiness")
        }
        try await run("authorization-rollback-restores-permission-and-inflight-starts-zero-http",root:root) { folder in
            let a = try ready(folder); try a.upsert(conv("victim"),userId:"A"); let other = try ready(folder), baseline = a.authorizationSnapshot(userId:"A"), gate = DatabaseGate(); defer { gate.open() }
            let operation = Task { try await other.backgroundTransaction(userId:"A",operation:{ store in try store.delete(ids:["victim"],userId:"A") },beforeCommit:{ gate.block(); throw DatabaseTestFailure(description:"rollback after fence") }) }
            try await wait(gate); let during = try await fastSnapshot(a,blocked:gate)
            try expect(during.inFlightDestructive && !during.canWrite(conversationId:"victim"), "Another instance's in-flight destructive transaction is immediately visible")
            DatabaseAuthorizationURLProtocol.reset(); let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DatabaseAuthorizationURLProtocol.self]
            let transport = AssistantStreamTransport(configuration:configuration), request = URLRequest(url:URL(string:"https://fixtures.invalid/authorization")!)
            do { for try await _ in transport.events(for:request,beforeStart:{ if !a.authorizationSnapshot(userId:"A").canWrite(conversationId:"victim") { throw CancellationError() } }) { } }
            catch is CancellationError { }
            try expect(DatabaseAuthorizationURLProtocol.count == 0, "The actual transport startup hook cannot bypass the shared destructive fence")
            gate.open(); _ = try await asyncRejects { try await operation.value }
            let after = a.authorizationSnapshot(userId:"A")
            try expect(try after.identity == baseline.identity && after.version > baseline.version && !after.inFlightDestructive && after.deletedIDs.isEmpty && after.canWrite(conversationId:"victim") && a.conversation(id:"victim",userId:"A") != nil, "SQL rollback removes only its own fence and restores the real committed authorization")
        }
        try await run("authorization-other-instance-committed-delete-is-immediate",root:root) { folder in
            let a = try ready(folder); try a.upsert(conv("victim"),userId:"A"); let b = try ready(folder), before = a.authorizationSnapshot(userId:"A")
            try b.delete(ids:["victim"],userId:"A")
            let after = await MainActor.run { a.authorizationSnapshot(userId:"A") }
            try expect(after.identity == before.identity && after.version > before.version && after.deletedIDs == ["victim"] && !after.canWrite(conversationId:"victim") && after.canWrite(conversationId:"other"), "Owner-scoped process-wide cache reflects another legitimate facade's commit without SQL on MainActor")
            _ = try rejects { try a.upsert(conv("victim"),userId:"A") }
        }
        try await run("authorization-delayed-publication-cannot-regress-newer-sql-generation",root:root) { folder in
            let publishing = DatabasePublishControl(), a = AssistantChatArchive(directory:folder,authorizationPublishBarrier:{ publishing.publish() }); try a.prepare(userId:"A")
            try a.upsert(conv("first"),userId:"A"); try a.upsert(conv("second"),userId:"A"); let b = try ready(folder), gate = DatabaseGate(); defer { gate.open() }; publishing.arm(gate)
            let first = Task { try await a.background { try $0.delete(ids:["first"],userId:"A") } }; try await wait(gate)
            try b.delete(ids:["second"],userId:"A"); let newer = b.authorizationSnapshot(userId:"A")
            try expect(newer.deletedIDs == ["first","second"], "Later SQL commit contains both deletion decisions")
            gate.open(); try await first.value; let final = a.authorizationSnapshot(userId:"A")
            try expect(final.version >= newer.version && final.deletedIDs == ["first","second"] && !final.inFlightDestructive && !final.canWrite(conversationId:"first") && !final.canWrite(conversationId:"second"), "Earlier postcommit publication cannot overwrite newer metadata")
        }
        try await run("authorization-purge-recreate-retires-old-handle-and-old-publisher",root:root) { folder in
            let publishing = DatabasePublishControl(), a = AssistantChatArchive(directory:folder,authorizationPublishBarrier:{ publishing.publish() }); try a.prepare(userId:"A"); let b = try ready(folder), oldIdentity = a.authorizationSnapshot(userId:"A").identity, gate = DatabaseGate(); defer { gate.open() }; publishing.arm(gate)
            let oldWrite = Task { try await a.background { try $0.upsert(conv("old"),userId:"A") } }; try await wait(gate)
            try b.deleteAll(userId:"A"); try b.prepare(userId:"A"); try b.upsert(conv("fresh"),userId:"A"); let current = b.authorizationSnapshot(userId:"A")
            try expect(current.identity != oldIdentity && current.canWrite(conversationId:"fresh"), "Fresh authority has a different persisted incarnation")
            gate.open(); try await oldWrite.value
            try expect(a.authorizationSnapshot(userId:"A").identity == current.identity && a.authorizationSnapshot(userId:"A").version >= current.version, "Retired identity publication cannot reactivate an old database")
            _ = try rejects { try a.upsert(conv("old"),userId:"A") }
            try expect(!a.isPrepared(userId:"A"), "Old handle is closed even though the same database path now exists again")
            try a.prepare(userId:"A"); try expect(try a.load(userId:"A").map(\.id) == ["fresh"], "Explicit preparation opens the new handle without reviving old rows")
        }
        try await run("authorization-unprepared-purge-intent-seals-all-existing-instances",root:root) { folder in
            let a = try ready(folder); try a.upsert(conv("private"),userId:"A"); try a.saveDraft("private",conversationId:"private",userId:"A")
            let control = DatabaseControl(), gate = DatabaseGate(); defer { gate.open() }; control.hold(.purgeDatabaseRemoval,gate)
            let b = AssistantChatArchive(directory:folder,fault:{ p,o in try control.check(p,o) }), operation = Task { try await b.background { try $0.deleteAll(userId:"A") } }
            try await wait(gate); let during = try await fastSnapshot(a,blocked:gate)
            try expect(during.purging && !during.canWrite(conversationId:"private"), "Durably accepted file-level purge intent protects another already-open SQL facade")
            try a.prepare(userId:"A")
            try expect(a.authorizationSnapshot(userId:"A").purging, "A fresh SQL snapshot of the old unpurged handle cannot clear the durable intent seal")
            _ = try rejects { try a.upsert(conv("bypass"),userId:"A") }
            try expect(try rejects { _ = try a.exportSnapshot(userId:"A") } as? AssistantChatStorageError == .purgeRecoveryRequired && a.loadDraftRecords(userId:"A").isEmpty, "Another instance must reject pending-purge export while ordinary UI draft reads stay redacted")
            gate.open(); try await operation.value
            let cold = AssistantChatArchive(directory:folder)
            try expect(try !cold.isPurgingAll(userId:"A") && !cold.authorizationSnapshot(userId:"A").canWrite(conversationId:"private"), "Completed purge remains unprepared rather than authorizing a stale source")
        }
        try await run("authorization-foreign-destructive-rollback-cannot-leak-a-fence",root:root) { folder in
            let a = try ready(folder,owners:["A","B"])
            _ = try await asyncRejects { try await a.backgroundTransaction(userId:"A",operation:{ try $0.delete(ids:["foreign"],userId:"B") }) }
            _ = try await asyncRejects { try await a.backgroundTransaction(userId:"A",operation:{ try $0.deleteAll(userId:"B") }) }
            let b = a.authorizationSnapshot(userId:"B")
            try expect(b.prepared && !b.inFlightDestructive && !b.purging && b.canWrite(conversationId:"live"), "Rejected cross-owner operations release their own owner's fence and cannot permanently deny the other account")
        }
        try await run("authorization-warm-purge-retry-survives-another-instances-unknown-observation",root:root) { folder in
            let control = DatabaseControl(), a = try ready(folder,control:control); try a.upsert(conv("old"),userId:"A"); control.fail(.purgeDatabaseRemoval)
            _ = try rejects { try a.deleteAll(userId:"A") }
            let observer = AssistantChatArchive(directory:folder); _ = try rejects { try observer.prepare(userId:"A") }
            try expect(a.authorizationSnapshot(userId:"A").purging && a.authorizationSnapshot(userId:"A").unknown, "A cold observer correctly seals unknown pending purge state")
            control.fail(nil)
            try a.deleteAll(userId:"A"); try a.prepare(userId:"A")
            try expect(try a.load(userId:"A").isEmpty && !a.authorizationSnapshot(userId:"A").purging && a.authorizationSnapshot(userId:"A").prepared, "The original warm facade can explicitly finish authorized cleanup without requiring a successful read preparation")
        }
        try await run("export-pending-purge-throws-in-typed-tuple-and-async-paths",root:root) { folder in
            let control = DatabaseControl(), a = try ready(folder,owners:["A","B"],control:control)
            try a.upsert(conv("private-A"),userId:"A"); try a.upsert(conv("kept-B"),userId:"B"); control.fail(.purgeDatabaseRemoval)
            _ = try rejects { try a.deleteAll(userId:"A") }
            let before = try files(folder)
            try expect(try rejects { _ = try a.loadExportSnapshot(userId:"A") } as? AssistantChatStorageError == .purgeRecoveryRequired, "Tuple export cannot turn pending cleanup into a successful empty backup")
            try expect(try rejects { _ = try a.exportSnapshot(userId:"A") } as? AssistantChatStorageError == .purgeRecoveryRequired, "Typed export rejects the same pending state")
            let tupleError = try await asyncRejects { _ = try await a.loadExportSnapshotAsync(userId:"A") }, typedError = try await asyncRejects { _ = try await a.exportSnapshotAsync(userId:"A") }
            try expect(tupleError as? AssistantChatStorageError == .purgeRecoveryRequired && typedError as? AssistantChatStorageError == .purgeRecoveryRequired, "Async wrappers preserve explicit pending-purge failure")
            try expect(try files(folder) == before && a.exportSnapshot(userId:"B").conversations.map(\.id) == ["kept-B"], "Rejected exports preserve sources and cannot affect the other account")
            control.fail(nil); try a.deleteAll(userId:"A")
            try expect(try a.loadExportSnapshot(userId:"A").conversations.isEmpty && a.exportSnapshot(userId:"A").conversations.isEmpty, "Actually completed purge still permits an honest empty snapshot")
        }
        try await run("export-purge-accepted-after-sql-read-still-rejects-captured-content",root:root) { folder in
            for typed in [false,true] {
                let sub = folder.appendingPathComponent(typed ? "typed" : "tuple"), barrier = DatabasePublishControl(), gate = DatabaseGate(); defer { gate.open() }
                let a = AssistantChatArchive(directory:sub,exportSnapshotBarrier:{ barrier.publish() }); try a.prepare(userId:"A"); try a.upsert(conv("private"),userId:"A"); barrier.arm(gate)
                let exporting = Task { try await a.background { store -> Int in if typed { return try store.exportSnapshot(userId:"A").conversations.count }; return try store.loadExportSnapshot(userId:"A").conversations.count } }
                try await wait(gate)
                let control = DatabaseControl(); control.fail(.purgeDatabaseRemoval)
                let deleting = AssistantChatArchive(directory:sub,fault:{ p,o in try control.check(p,o) }); _ = try rejects { try deleting.deleteAll(userId:"A") }
                let afterIntent = try files(sub); gate.open()
                let error = try await asyncRejects { _ = try await exporting.value }
                try expect(try error as? AssistantChatStorageError == .purgeRecoveryRequired && files(sub) == afterIntent, "Post-read protection refuses already copied old content without touching pending cleanup sources")
            }
        }
        try await run("storage-errors-all-cases-use-english-and-simplified-chinese-resources",root:root) { folder in
            let bundle = try storageErrorBundle(folder)
            defer { AssistantLocalization.setLanguage("system") }
            try expect(storageErrorCases.count == 12 && Set(storageErrorCases.map(\.key)).count == 12, "Every storage error case has its own explicit resource key")
            for language in ["en", "zh-Hans"] {
                AssistantLocalization.setLanguage(language)
                for item in storageErrorCases {
                    try expect(item.error.localizationKey == item.key, "The error maps to the intended fixed user-facing key")
                    try expect(item.error.localizedMessage(bundle: bundle) == (language == "en" ? item.english : item.key), "Storage errors use the actual selected resource language rather than raw enum descriptions")
                }
            }
        }
        try await run("storage-errors-foundation-bridging-displays-localized-error-descriptions",root:root) { _ in
            defer { AssistantLocalization.setLanguage("system") }
            for language in ["en", "zh-Hans"] {
                AssistantLocalization.setLanguage(language)
                for item in storageErrorCases {
                    let expected = AssistantLocalization.string(item.key), erased: Error = item.error
                    try expect(item.error.errorDescription == expected && erased.localizedDescription == expected
                        && (item.error as NSError).localizedDescription == expected, "Home and all other Error/NSError consumers receive the shared LocalizedError message")
                    for implementation in ["AssistantChatStorageError", "Error Domain=", "Code=", "sqlite3_", "SELECT ", "/Users/", "/private/", "Bearer "] {
                        try expect(!erased.localizedDescription.contains(implementation), "Public descriptions never disclose enum names, SQL, paths or credential syntax")
                    }
                }
            }
        }
        try await run("storage-errors-distinguish-committed-cleanup-and-hide-sqlite-codes",root:root) { folder in
            let bundle = try storageErrorBundle(folder)
            defer { AssistantLocalization.setLanguage("system") }
            for language in ["en", "zh-Hans"] {
                AssistantLocalization.setLanguage(language)
                let committed = AssistantChatStorageError.publicationCommittedCleanupPending.localizedMessage(bundle: bundle)
                try expect(committed.contains(language == "en" ? "changes are saved" : "已保存")
                    && committed.contains(language == "en" ? "not complete" : "尚未完成")
                    && !committed.contains(language == "en" ? "not saved" : "未保存"), "A committed publication with incomplete cleanup must not be called an unsaved operation")
                let pending = AssistantChatStorageError.purgeRecoveryRequired.localizedMessage(bundle: bundle)
                try expect(pending.contains(language == "en" ? "Retry cleanup" : "重试清理"), "Cold pending purge offers the actual recovery action without claiming cleanup finished")
                let generic = AssistantChatStorageError.sqlite(5).localizedMessage(bundle: bundle)
                for code: Int32 in [Int32.min, -1, 0, 5, 11, Int32.max] {
                    let value = AssistantChatStorageError.sqlite(code).localizedMessage(bundle: bundle)
                    try expect(value == generic && !value.contains(String(code)), "SQLite details remain private regardless of the associated result code")
                }
            }
        }
        print("All \(count) AssistantChatDatabase suites passed; actual SQLite, migration/cancellation boundaries and localized storage errors.")
    }
}
