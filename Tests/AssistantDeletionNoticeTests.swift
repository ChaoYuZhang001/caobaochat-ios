import Foundation

private enum TestFailure: Error { case assertion(String), fixture }

@main @MainActor
private enum AssistantDeletionNoticeTests {
    static var groups = 0
    static let origin = "https://assistant.example/api/v2"
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestFailure.assertion(message) }
    }
    static func run(_ name: String, _ body: (AssistantDeletionNoticeStore, UserDefaults, String) async throws -> Void) async throws {
        let suite = "caobao.deletion.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "fixture-jobs", store = AssistantDeletionNoticeStore(defaults: defaults, key: key)
        try await body(store, defaults, key)
        groups += 1; print("PASS " + name)
    }
    static func record(_ store: AssistantDeletionNoticeStore, owner: String = "account-A", request: String = "delete-A", origin: String = "https://assistant.example/api/v2", status: AssistantDeletionServerStatus = .accepted) throws -> AssistantDeletionCleanupJob {
        try store.recordAccepted(ownerId: owner, origin: origin, serverRequestId: request, status: status)
    }
    static func main() async {
        do { try await runAll(); print("PASS \(groups) deletion notice test groups; isolated metadata and fake cleaners only") }
        catch { print("FAIL \(error)"); exit(1) }
    }
    static func runAll() async throws {
        try await run("empty-store-does-not-authorize-cleanup") { store, _, _ in
            var calls = 0
            try expect(store.jobs().isEmpty, "Absent queue must remain empty")
            try await AssistantDeletionCleanupCoordinator(store: store).retry(origin: origin, currentOwnerId: { nil }) { _, _ in calls += 1 }
            try expect(calls == 0, "No accepted job means no cleanup")
        }
        try await run("accepted-job-is-durable-metadata-only") { store, defaults, key in
            let job = try record(store)
            let reloaded = AssistantDeletionNoticeStore(defaults: defaults, key: key)
            try expect(reloaded.jobs() == [job], "Jobs must reload from the actual injected UserDefaults suite")
            let raw = defaults.data(forKey: key)!
            let top = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
            let values = top["jobs"] as! [[String: Any]]
            try expect(Set(values[0].keys) == Set(["id", "ownerId", "origin", "serverRequestId", "serverStatus", "acceptedAt", "pendingComponents", "noticeDismissed"]), "Persist only known metadata fields")
            let notice = try store.notice(currentOwnerId: nil, origin: origin)!
            try expect(notice.serverStatus == .accepted && notice.hasPendingLocalCleanup && notice.canRetry, "Acceptance cannot imply server or local completion")
        }
        try await run("multiple-owners-and-origins-are-preserved") { store, _, _ in
            _ = try record(store)
            _ = try record(store, owner: "account-B", request: "delete-B")
            _ = try record(store, owner: "account-C", request: "delete-C", origin: "https://other.example/v2")
            try expect(store.jobs().count == 3, "A second job must not replace prior unfinished jobs")
            try expect(store.notice(currentOwnerId: nil, origin: origin)?.pendingJobCount == 2, "Notices are origin scoped")
            try expect(store.notice(currentOwnerId: nil, origin: "https://unknown.example") == nil, "Unrelated services cannot see jobs")
        }
        try await run("signed-in-accounts-never-see-old-notices") { store, _, _ in
            _ = try record(store)
            for owner in ["account-A", "account-B", "local-device"] {
                try expect(store.notice(currentOwnerId: owner, origin: origin) == nil, "Any non-nil logged-in owner must hide deletion results")
            }
        }
        try await run("partial-cleanup-persists-exact-failed-component") { store, defaults, key in
            let job = try record(store)
            var calls: [AssistantDeletionCleanupComponent] = []
            try await AssistantDeletionCleanupCoordinator(store: store).perform(jobId: job.id, origin: origin, mayClean: { true }) { component, owner in
                try expect(owner == "account-A", "Cleaner must use persisted job owner")
                calls.append(component)
                if component == .apiKey { throw TestFailure.fixture }
            }
            let restored = AssistantDeletionNoticeStore(defaults: defaults, key: key)
            try expect(calls == AssistantDeletionCleanupComponent.allCases, "One failure must not prevent other scoped cleanup")
            try expect(restored.jobs().first?.pendingComponents == [.apiKey], "The exact failed component must survive process reload")
            try expect(restored.notice(currentOwnerId: nil, origin: origin)?.hasPendingLocalCleanup == true, "A logged-out user must still see local failure")
        }
        try await run("retry-cleans-only-pending-components") { store, _, _ in
            let job = try record(store, status: .processing)
            try store.updatePending(jobId: job.id, components: [.apiKey])
            var calls: [AssistantDeletionCleanupComponent] = []
            try await AssistantDeletionCleanupCoordinator(store: store).retry(origin: origin, currentOwnerId: { nil }) { component, _ in calls.append(component) }
            try expect(calls == [.apiKey], "Retry must not repeat already completed work")
            let notice = try store.notice(currentOwnerId: nil, origin: origin)!
            try expect(!notice.hasPendingLocalCleanup && notice.serverStatus == .processing, "Finishing local cleanup cannot claim server deletion complete")
        }
        try await run("completed-server-and-local-states-stay-independent") { store, _, _ in
            let job = try record(store, status: .completed)
            try expect(store.notice(currentOwnerId: nil, origin: origin)?.serverStatus == .completed, "Use actual server completion")
            try expect(store.notice(currentOwnerId: nil, origin: origin)?.hasPendingLocalCleanup == true, "Completed server job may still have local failures")
            try await AssistantDeletionCleanupCoordinator(store: store).perform(jobId: job.id, origin: origin, mayClean: { true }) { _, _ in }
            try expect(store.notice(currentOwnerId: nil, origin: origin)?.hasPendingLocalCleanup == false, "Report actual local completion")
        }
        try await run("signed-in-retry-is-inert") { store, _, _ in
            _ = try record(store)
            var calls = 0
            try await AssistantDeletionCleanupCoordinator(store: store).retry(origin: origin, currentOwnerId: { "account-B" }) { _, _ in calls += 1 }
            try expect(calls == 0 && store.jobs()[0].pendingComponents.count == 5, "Cannot clean while another account is logged in")
        }
        try await run("wrong-origin-retry-is-inert") { store, _, _ in
            _ = try record(store)
            var calls = 0
            try await AssistantDeletionCleanupCoordinator(store: store).retry(origin: "https://other.example", currentOwnerId: { nil }) { _, _ in calls += 1 }
            try expect(calls == 0, "Retry must never cross service origins")
        }
        try await run("identity-change-during-cleaner-stops-further-work") { store, _, _ in
            let job = try record(store)
            var owner: String?, calls = 0
            try await AssistantDeletionCleanupCoordinator(store: store).retry(origin: origin, currentOwnerId: { owner }) { _, scopedOwner in
                try expect(scopedOwner == job.ownerId, "Cleaner must not read the new owner")
                calls += 1; owner = "account-B"
            }
            try expect(calls == 1, "Do not clear later components after login")
            try expect(store.jobs()[0].pendingComponents.count == 5, "Do not claim completion after identity changed")
        }
        try await run("same-owner-reauthentication-invalidates-initial-cleanup") { store, _, _ in
            let job = try record(store)
            var epoch = 1, calls = 0
            let owner = "account-A"
            try await AssistantDeletionCleanupCoordinator(store: store).perform(jobId: job.id, origin: origin,
                mayClean: { epoch == 1 && owner == job.ownerId }) { _, _ in
                calls += 1; epoch = 2
            }
            try expect(calls == 1 && store.jobs()[0].pendingComponents.count == 5, "A new same-owner session cannot inherit old request cleanup authority")
        }
        try await run("unknown-job-does-not-authorize-components") { store, _, _ in
            _ = try record(store)
            var calls = 0
            try await AssistantDeletionCleanupCoordinator(store: store).perform(jobId: UUID(), origin: origin,
                mayClean: { true }) { _, _ in calls += 1 }
            try expect(calls == 0, "Only persisted accepted job IDs can authorize cleanup")
        }
        try await run("dismissal-never-loses-unfinished-jobs") { store, _, _ in
            let job = try record(store)
            try store.dismiss(origin: origin)
            try expect(store.jobs()[0].pendingComponents == job.pendingComponents, "Dismissal is not successful cleanup")
            var calls = 0
            try await AssistantDeletionCleanupCoordinator(store: store).retry(origin: origin, currentOwnerId: { nil }) { _, _ in calls += 1 }
            try expect(calls == 5, "Dismissed pending work remains recoverable")
            try store.dismiss(origin: origin)
            try expect(store.notice(currentOwnerId: nil, origin: origin) == nil, "Completed local notices can be dismissed persistently")
        }
        try await run("malformed-raw-data-is-preserved") { store, defaults, key in
            let corrupt = Data("not-json".utf8); defaults.set(corrupt, forKey: key)
            do { _ = try record(store); throw TestFailure.assertion("Must reject corrupt records") }
            catch is AssistantDeletionMetadataError { }
            try expect(defaults.data(forKey: key) == corrupt, "Cannot replace malformed storage with a new queue")
            var calls = 0
            do { try await AssistantDeletionCleanupCoordinator(store: store).retry(origin: origin, currentOwnerId: { nil }) { _, _ in calls += 1 }; throw TestFailure.assertion("Corrupt queue must fail") }
            catch is AssistantDeletionMetadataError { }
            try expect(calls == 0 && defaults.data(forKey: key) == corrupt, "Corruption cannot authorize cleanup or erase evidence")
        }
        try await run("invalid-types-schema-and-jobs-remain-intact") { store, defaults, key in
            for value in ["wrong-type", Data("{\"version\":2,\"jobs\":[]}".utf8)] as [Any] {
                defaults.set(value, forKey: key)
                do { _ = try store.jobs(); throw TestFailure.assertion("Invalid values must fail") }
                catch is AssistantDeletionMetadataError { }
                try expect(defaults.object(forKey: key) != nil, "Invalid values must be retained")
            }
            defaults.removeObject(forKey: key)
            do { _ = try record(store, owner: " "); throw TestFailure.assertion("Blank owner must fail") }
            catch is AssistantDeletionMetadataError { }
            try expect(defaults.object(forKey: key) == nil, "Invalid new records cannot be written")
        }
        try await run("deduplication-keeps-progress-and-upgrades-server-status") { store, _, _ in
            let first = try record(store)
            try store.updatePending(jobId: first.id, components: [.apiKey])
            let duplicate = try record(store, status: .completed)
            try expect(duplicate.id == first.id && duplicate.pendingComponents == [.apiKey], "Repeated server request cannot reset cleanup progress")
            try expect(store.jobs().count == 1 && duplicate.serverStatus == .completed, "Preserve server completion without duplicating jobs")
            _ = try record(store, status: .accepted)
            try expect(store.jobs()[0].serverStatus == .completed, "Do not downgrade confirmed server completion")
        }
        try await run("cancellation-preserves-job-and-stops-cleanup") { store, _, _ in
            _ = try record(store)
            var calls = 0
            let operation = Task { @MainActor in
                try await AssistantDeletionCleanupCoordinator(store: store).retry(origin: origin, currentOwnerId: { nil }) { _, _ in
                    calls += 1; withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            do { try await operation.value; throw TestFailure.assertion("Cancellation must propagate") }
            catch is CancellationError { }
            try expect(calls == 1 && store.jobs()[0].pendingComponents.count == 5, "Cancellation cannot lose unfinished components")
        }
        try await run("multiple-jobs-retry-does-not-overwrite-failures") { store, _, _ in
            _ = try record(store)
            _ = try record(store, owner: "account-B", request: "delete-B", status: .completed)
            try await AssistantDeletionCleanupCoordinator(store: store).retry(origin: origin, currentOwnerId: { nil }) { component, owner in
                if owner == "account-A", component == .apiKey { throw TestFailure.fixture }
            }
            let values = try store.jobs()
            try expect(values.count == 2 && values[0].pendingComponents == [.apiKey] && values[1].pendingComponents.isEmpty, "Retain all unfinished jobs with independent progress")
            try expect(store.notice(currentOwnerId: nil, origin: origin)?.serverStatus == .accepted, "A newer completed job cannot imply older server jobs completed")
        }
    }
}
