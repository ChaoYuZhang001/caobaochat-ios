import Foundation
import Darwin

private struct BackupReaderFailure: Error, CustomStringConvertible { let description: String }
private final class ReaderDeadlineState: @unchecked Sendable {
    private let lock = NSLock(); private var timedOut = false
    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
}

@main private enum AssistantBackupFileReaderTests {
    static var groups = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw BackupReaderFailure(description: message) } }
    static func invalid(_ url: URL) throws {
        do {
            let handle = try AssistantBackupFileReader.openRegularFile(url: url); try? handle.close()
            throw BackupReaderFailure(description: "Non-regular source unexpectedly accepted")
        } catch AssistantDataImportError.invalidFormat {}
    }
    static func run(_ name: String, _ body: () async throws -> Void) async throws { try await body(); groups += 1; print("PASS backup-file-reader: \(name)") }
    static func descriptorCount() -> Int { (0..<1_024).reduce(0) { $0 + (Darwin.fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) } }
    static func fifoChild(_ path: String) throws {
        try invalid(URL(fileURLWithPath: path))
    }
    static func runFIFOChild(_ path: String) async throws -> (status: Int32, timedOut: Bool) {
        let child = Process(), deadline = ReaderDeadlineState()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--fifo-child", path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            let watchdog = DispatchWorkItem {
                if child.isRunning { deadline.markTimedOut(); Darwin.kill(child.processIdentifier, SIGKILL) }
            }
            child.terminationHandler = { process in
                watchdog.cancel(); continuation.resume(returning: (process.terminationStatus, deadline.expired))
            }
            do {
                try child.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)
            } catch { watchdog.cancel(); continuation.resume(throwing: error) }
        }
    }
    static func emptyBackup() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaName": "caobao.assistant.local-export", "schemaVersion": 1, "dateEncoding": "unix-seconds",
            "ownerId": "A", "exportedAt": 1_793_232_000, "includedScopes": ["conversations", "draft", "memories", "tasks", "memoryPreferences"],
            "imagesIncluded": true, "omittedImageCount": 0, "conversations": [], "draft": ["text": ""],
            "memories": [], "tasks": [], "memoryPreferences": ["memoryEnabled": true, "excludedMemoryCategories": []]
        ], options: [.sortedKeys])
    }
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--fifo-child" { try fifoChild(CommandLine.arguments[2]); return }
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caobao-backup-reader-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let regular = root.appendingPathComponent("regular.json"), link = root.appendingPathComponent("link.json"), broken = root.appendingPathComponent("broken.json"), fifo = root.appendingPathComponent("named-pipe.json")
        let content = Data("known public temporary bytes".utf8)
        try content.write(to: regular)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: root.appendingPathComponent("missing.json"))
        try expect(Darwin.mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)) == 0, "Actual temporary FIFO must be created")
        try await run("regular-fd-flags-same-descriptor-read-and-close") {
            let handle = try AssistantBackupFileReader.openRegularFile(url: regular), descriptor = handle.fileDescriptor
            try expect(Darwin.fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0, "Descriptor must not survive exec")
            try expect(Darwin.fcntl(descriptor, F_GETFL) & O_NONBLOCK != 0, "Opening must be nonblocking before file type validation")
            var metadata = stat(); try expect(Darwin.fstat(descriptor, &metadata) == 0 && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), "Read handle must refer to the validated regular descriptor")
            try expect(try handle.readToEnd() == content, "Regular bytes must remain unchanged")
            try handle.close(); errno = 0
            try expect(Darwin.fcntl(descriptor, F_GETFD) == -1 && errno == EBADF, "Closing the returned handle must close its descriptor")
        }
        try await run("real-and-broken-symlinks-refused-without-reading-target") {
            try invalid(link); try invalid(broken)
            try expect(try Data(contentsOf: regular) == content, "Rejected symlinks cannot change their target")
        }
        try await run("directory-and-non-file-url-refused") {
            try invalid(root); try invalid(URL(string: "https://example.com/never-requested.json")!)
        }
        try await run("actual-fifo-refused-with-safe-async-process-deadline") {
            // No writer is opened. A regression to blocking open is killed in
            // an isolated child rather than hanging a structured task group.
            let result = try await runFIFOChild(fifo.path)
            try expect(!result.timedOut && result.status == 0, "A FIFO without any writer must be rejected before the two-second safety deadline")
        }
        try await run("rejected-fifo-and-directory-descriptors-do-not-leak") {
            let before = descriptorCount()
            for _ in 0..<100 { try invalid(fifo); try invalid(root); try invalid(link) }
            try expect(descriptorCount() <= before, "Every descriptor rejected after fstat must be closed")
        }
        try await run("importer-bounds-configuration-and-cancellation-preserved") {
            let backup = try emptyBackup(), url = root.appendingPathComponent("valid-backup.json")
            try backup.write(to: url)
            let plan = try AssistantDataImporter(maximumBytes: backup.count).prepare(url: url, ownerId: "A")
            try expect(plan.ownerId == "A" && plan.conversations.isEmpty && plan.backupDigest.count == 64, "Exact-size regular backup remains supported")
            do { _ = try AssistantDataImporter(maximumBytes: backup.count - 1).prepare(url: url, ownerId: "A"); throw BackupReaderFailure(description: "Read limit must reject the extra byte") } catch AssistantDataImportError.tooLarge {}
            do { _ = try AssistantDataImporter(maximumBytes: 0).prepare(url: link, ownerId: "A"); throw BackupReaderFailure(description: "Configuration must fail before file open") } catch AssistantDataImportError.invalidConfiguration {}
            let operation = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try AssistantDataImporter().prepare(url: url, ownerId: "A")
            }
            do { _ = try await operation.value; throw BackupReaderFailure(description: "Cancelled bounded read must reject") } catch is CancellationError {}
            try expect(try Data(contentsOf: url) == backup, "All failures leave selected backup bytes untouched")
        }
        print("All \(groups) backup file-reader groups passed with actual temporary regular files, symlinks, directory and FIFO; no provider, UI or notification actions.")
    }
}
