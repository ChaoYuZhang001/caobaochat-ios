import Foundation

private enum Failure: Error { case assertion(String) }
private func expect(_ value: @autoclosure () -> Bool, _ detail: String) throws { if !value() { throw Failure.assertion(detail) } }
private func messages(_ count: Int = 6) -> [AssistantChatViewportMessage] {
    (0..<count).map { AssistantChatViewportMessage(id: "m-" + String($0), isUser: $0 % 2 == 0) }
}
private func context(_ owner: String = "owner", _ conversation: String = "chat") -> AssistantChatViewportContext {
    AssistantChatViewportContext(ownerId: owner, conversationId: conversation)!
}
private func geometry(_ anchor: String = "m-2", bottom: Double = 500, minY: Double = -120) -> AssistantChatViewportGeometry {
    AssistantChatViewportGeometry(viewportHeight: 100, contentMinY: minY, bottomY: bottom,
        frames: [AssistantChatViewportFrame(messageId: anchor, minY: -10, maxY: 60)])
}
private func paused(_ store: AssistantChatViewportStore, _ values: [AssistantChatViewportMessage] = messages(), anchor: String = "m-2") -> AssistantChatViewportSession {
    let start = store.begin(context: context(), messages: values)!
    _ = store.observe(session: start.session, messages: values, geometry: geometry(anchor), userIsScrolling: true)
    return start.session
}

@main
private enum AssistantChatViewportTests {
    static func main() throws {
        var groups = 0
        func run(_ name: String, _ body: () throws -> Void) throws { try body(); groups += 1; print("PASS viewport: " + name) }
        try run("default-new-chat-follows-latest") {
            let start = AssistantChatViewportStore().begin(context: context(), messages: messages())!
            try expect(start.update.state.followingLatest && start.update.target == .latest("m-5"), "new chat destination")
        }
        try run("empty-new-chat-has-no-invented-target") {
            let start = AssistantChatViewportStore().begin(context: context(), messages: [])!
            try expect(start.update.target == nil && start.update.state.followingLatest, "empty target")
        }
        try run("raw-owner-aliases-are-separate-contexts") {
            let store = AssistantChatViewportStore(), a = context("é"), b = context("e\u{301}")
            try expect(a != b && a.key != b.key, "raw owner key")
            let start = store.begin(context: a, messages: messages())!
            _ = store.observe(session: start.session, messages: messages(), geometry: geometry(), userIsScrolling: true)
            try expect(store.begin(context: b, messages: messages())!.update.state.followingLatest, "other owner inherited reading")
        }
        try run("raw-conversation-aliases-are-separate") {
            try expect(context("o", "é") != context("o", "e\u{301}"), "raw conversation key")
        }
        try run("invalid-contexts-are-rejected") {
            for owner in ["", " ", "a\u{85}", String(repeating: "x", count: 1_025)] {
                try expect(AssistantChatViewportContext(ownerId: owner, conversationId: "c") == nil, "bad context")
            }
        }
        try run("actual-visible-frames-pause-and-anchor") {
            let store = AssistantChatViewportStore(), session = paused(store)
            try expect(store.state(for: session) == AssistantChatViewportState(followingLatest: false, anchorMessageId: "m-2"), "visible anchor")
        }
        try run("overscan-does-not-become-visible-anchor") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let sample = AssistantChatViewportGeometry(viewportHeight: 100, contentMinY: -120, bottomY: 500, frames: [
                .init(messageId: "m-0", minY: -200, maxY: -100), .init(messageId: "m-3", minY: 10, maxY: 80),
                .init(messageId: "m-5", minY: 300, maxY: 500)])
            let state = store.observe(session: session, messages: messages(), geometry: sample, userIsScrolling: true)
            try expect(state?.anchorMessageId == "m-3", "overscan anchor")
        }
        try run("stream-height-growth-does-not-pause-following") {
            let store = AssistantChatViewportStore(), start = store.begin(context: context(), messages: messages())!
            let state = store.observe(session: start.session, messages: messages(), geometry: geometry(bottom: 800), userIsScrolling: false)
            try expect(state?.followingLatest == true, "program content change")
        }
        try run("paused-reader-not-resumed-by-layout-or-content") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let state = store.observe(session: session, messages: messages(), geometry: geometry(bottom: 100), userIsScrolling: false)
            try expect(state?.followingLatest == false, "implicit resume")
        }
        try run("manual-return-to-bottom-resumes-following") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let state = store.observe(session: session, messages: messages(), geometry: geometry(bottom: 120), userIsScrolling: true)
            try expect(state?.followingLatest == true, "manual bottom")
        }
        try run("explicit-back-to-latest-resumes") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let update = store.resumeLatest(session: session, messages: messages())
            try expect(update?.state.followingLatest == true && update?.target == .latest("m-5"), "explicit resume")
        }
        try run("assistant-append-does-not-force-paused-reader") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let values = messages() + [.init(id: "assistant-next", isUser: false)]
            let update = store.messagesChanged(session: session, messages: values, isGenerating: true)
            try expect(update?.state.followingLatest == false && update?.target == nil, "assistant append")
        }
        try run("continuing-deltas-do-not-force-paused-reader") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let update = store.messagesChanged(session: session, messages: messages(), isGenerating: true)
            try expect(update?.target == nil && update?.state.followingLatest == false, "continuing generation")
        }
        try run("real-new-user-turn-follows-latest") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let values = messages() + [.init(id: "user-next", isUser: true), .init(id: "pending-next", isUser: false)]
            let update = store.messagesChanged(session: session, messages: values, isGenerating: true)
            try expect(update?.state.followingLatest == true && update?.target == .latest("pending-next"), "new submission")
        }
        try run("loading-history-is-not-user-submission") {
            let store = AssistantChatViewportStore(); _ = paused(store)
            let session = store.begin(context: context(), messages: [])!.session
            let update = store.messagesChanged(session: session, messages: messages(), isGenerating: false)
            try expect(update?.state.followingLatest == false && update?.resumedByUserMessage == false, "history load")
        }
        try run("fast-failed-user-append-still-follows") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let update = store.messagesChanged(session: session, messages: messages() + [.init(id: "failed-fast-user", isUser: true)], isGenerating: false)
            try expect(update?.state.followingLatest == true && update?.resumedByUserMessage == true, "fast request failure")
        }
        try run("deleting-a-user-does-not-resume") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let update = store.messagesChanged(session: session, messages: messages().filter { $0.id != "m-4" }, isGenerating: true)
            try expect(update?.state.followingLatest == false && update?.target == nil, "user deletion")
        }
        try run("new-shell-restores-paused-message-anchor") {
            let store = AssistantChatViewportStore(), old = paused(store)
            let start = store.begin(context: context(), messages: messages())!
            try expect(start.update.target == .anchor("m-2") && !start.update.state.followingLatest, "shell restore")
            try expect(store.state(for: old) == nil, "old shell remained authorized")
        }
        try run("new-shell-restores-following-to-latest") {
            let store = AssistantChatViewportStore()
            _ = store.begin(context: context(), messages: messages())
            try expect(store.begin(context: context(), messages: messages())!.update.target == .latest("m-5"), "follow restore")
        }
        try run("empty-bootstrap-preserves-saved-anchor-until-load") {
            let store = AssistantChatViewportStore(); _ = paused(store)
            let start = store.begin(context: context(), messages: [])!
            try expect(start.update.target == nil && start.update.state.anchorMessageId == "m-2", "bootstrap bookmark")
            let update = store.messagesChanged(session: start.session, messages: messages(), isGenerating: false)
            try expect(update?.target == .anchor("m-2") && update?.state.followingLatest == false, "loaded restore")
        }
        try run("stale-session-geometry-and-actions-are-rejected") {
            let store = AssistantChatViewportStore(), old = paused(store)
            let current = store.begin(context: context(), messages: messages())!.session
            try expect(store.observe(session: old, messages: messages(), geometry: geometry(bottom: 100), userIsScrolling: true) == nil, "stale frames")
            try expect(store.resumeLatest(session: old, messages: messages()) == nil, "stale button")
            try expect(store.messagesChanged(session: old, messages: messages(), isGenerating: true) == nil, "stale message event")
            try expect(store.state(for: current)?.followingLatest == false, "stale write")
        }
        try run("finished-session-cannot-publish") {
            let store = AssistantChatViewportStore(), session = paused(store); store.finish(session: session)
            try expect(store.restore(session: session, messages: messages()) == nil && store.state(for: session) == nil, "finished session")
        }
        try run("old-finish-cannot-invalidate-replacement") {
            let store = AssistantChatViewportStore(), old = paused(store)
            let current = store.begin(context: context(), messages: messages())!.session; store.finish(session: old)
            try expect(store.state(for: current) != nil, "late disappear")
        }
        try run("deleted-anchor-keeps-actual-visible-survivor-without-scroll") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let update = store.messagesChanged(session: session, messages: messages().filter { $0.id != "m-2" }, isGenerating: false, visibleMessageIds: ["removed", "m-3"])
            try expect(update?.state.anchorMessageId == "m-3" && update?.target == nil, "visible survivor")
        }
        try run("deleted-anchor-uses-validated-next-neighbor") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let update = store.messagesChanged(session: session, messages: messages().filter { $0.id != "m-2" }, isGenerating: false)
            try expect(update?.target == .anchor("m-3") && update?.state.followingLatest == false, "next neighbor")
        }
        try run("deleted-anchor-uses-previous-neighbor") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let update = store.messagesChanged(session: session, messages: messages().filter { !["m-2", "m-3"].contains($0.id) }, isGenerating: false)
            try expect(update?.target == .anchor("m-1"), "previous neighbor")
        }
        try run("all-neighbors-deleted-clamps-to-existing-id") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let values = [AssistantChatViewportMessage(id: "survivor", isUser: false)]
            try expect(store.messagesChanged(session: session, messages: values, isGenerating: false)?.target == .anchor("survivor"), "ordinal fallback")
        }
        try run("all-messages-deleted-has-no-invented-anchor") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let update = store.messagesChanged(session: session, messages: [], isGenerating: false)
            try expect(update?.state.anchorMessageId == nil && update?.target == nil, "empty deletion")
        }
        try run("bounded-lru-evicts-old-ticket") {
            let store = AssistantChatViewportStore(capacity: 2)
            let a = store.begin(context: context("o", "a"), messages: messages())!.session
            _ = store.begin(context: context("o", "b"), messages: messages())
            _ = store.begin(context: context("o", "c"), messages: messages())
            try expect(store.contextCount == 2 && store.state(for: a) == nil, "LRU bound")
        }
        try run("context-capacity-has-hard-upper-bound") {
            let store = AssistantChatViewportStore(capacity: Int.max)
            for index in 0..<140 { _ = store.begin(context: context("o", String(index)), messages: []) }
            try expect(store.contextCount == 128, "context upper bound")
        }
        try run("duplicate-invalid-and-oversized-input-is-rejected") {
            let store = AssistantChatViewportStore()
            for values in [[.init(id: "a", isUser: true), .init(id: "a", isUser: false)], [.init(id: "x\u{85}", isUser: true)]] as [[AssistantChatViewportMessage]] {
                try expect(store.begin(context: context(), messages: values) == nil, "invalid messages")
            }
            try expect(store.begin(context: context(), messages: messages(20_001)) == nil && store.contextCount == 0, "message bound")
        }
        try run("invalid-and-stale-geometry-is-rejected") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let samples = [AssistantChatViewportGeometry(viewportHeight: 0, contentMinY: 0, bottomY: 0, frames: []),
                .init(viewportHeight: 100, contentMinY: .nan, bottomY: 0, frames: []),
                .init(viewportHeight: 100, contentMinY: 0, bottomY: .infinity, frames: []),
                .init(viewportHeight: 100, contentMinY: 0, bottomY: 100, frames: [.init(messageId: "foreign", minY: 0, maxY: 50)])]
            for sample in samples { try expect(store.observe(session: session, messages: messages(), geometry: sample, userIsScrolling: true) == nil, "invalid geometry") }
            try expect(store.state(for: session)?.followingLatest == false, "invalid observation mutation")
        }
        try run("offscreen-only-frames-cannot-replace-reading-anchor") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let sample = AssistantChatViewportGeometry(viewportHeight: 100, contentMinY: -120, bottomY: 500,
                frames: [.init(messageId: "m-0", minY: -100, maxY: -1)])
            try expect(store.observe(session: session, messages: messages(), geometry: sample, userIsScrolling: false)?.anchorMessageId == "m-2", "overscan write")
        }
        try run("queued-latest-rejected-after-user-pauses") {
            let store = AssistantChatViewportStore(), start = store.begin(context: context(), messages: messages())!
            try expect(store.canApply(session: start.session, target: .latest("m-5")), "initial latest authorization")
            _ = store.observe(session: start.session, messages: messages(), geometry: geometry(), userIsScrolling: true)
            try expect(!store.canApply(session: start.session, target: .latest("m-5")), "late auto scroll")
        }
        try run("queued-anchor-rejected-after-anchor-deletion") {
            let store = AssistantChatViewportStore(), session = paused(store)
            _ = store.messagesChanged(session: session, messages: messages().filter { $0.id != "m-2" }, isGenerating: false)
            try expect(!store.canApply(session: session, target: .anchor("m-2")) && store.canApply(session: session, target: .anchor("m-3")), "deleted queued anchor")
        }
        try run("queued-target-rejected-after-shell-replacement") {
            let store = AssistantChatViewportStore(), session = paused(store)
            _ = store.begin(context: context(), messages: messages())
            try expect(!store.canApply(session: session, target: .anchor("m-2")), "old shell queued target")
        }
        try run("replaced-history-does-not-count-as-new-append") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let values = (0..<12).map { AssistantChatViewportMessage(id: "loaded-" + String($0), isUser: true) }
            let update = store.messagesChanged(session: session, messages: values, isGenerating: false)
            try expect(update?.state.followingLatest == false && update?.resumedByUserMessage == false, "replacement hydration")
        }
        try run("raw-message-alias-frame-and-target-use-exact-bytes") {
            let store = AssistantChatViewportStore(), a = "é", b = "e\u{301}"
            let values = [AssistantChatViewportMessage(id: a, isUser: true), .init(id: b, isUser: false)]
            let start = store.begin(context: context(), messages: values)!
            let state = store.observe(session: start.session, messages: values, geometry: geometry(b), userIsScrolling: true)
            try expect(state?.anchorMessageId?.utf8.elementsEqual(b.utf8) == true, "raw frame anchor")
            try expect(store.canApply(session: start.session, target: .anchor(b)) && !store.canApply(session: start.session, target: .anchor(a)), "raw queued target")
            try expect(AssistantChatViewportTarget.anchor(a) != .anchor(b), "raw target equality")
        }
        try run("invalid-event-does-not-change-bookmark") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let bad = [AssistantChatViewportMessage(id: "a", isUser: true), .init(id: "a", isUser: false)]
            try expect(store.messagesChanged(session: session, messages: bad, isGenerating: true) == nil, "invalid message event")
            try expect(store.state(for: session)?.anchorMessageId == "m-2" && store.state(for: session)?.followingLatest == false, "invalid event changed bookmark")
        }
        try run("width-restore-keeps-reading-state-and-valid-id") {
            let store = AssistantChatViewportStore(), session = paused(store)
            let update = store.restore(session: session, messages: messages())
            try expect(update?.target == .anchor("m-2") && update?.state.followingLatest == false, "width restore")
        }
        try run("first-anchor-top-padding-clamp-completes-restore") {
            let sample = AssistantChatViewportGeometry(viewportHeight: 100, contentMinY: 0, bottomY: 500,
                frames: [.init(messageId: "m-0", minY: 16, maxY: 80)])
            try expect(AssistantChatViewportStore.hasReached(.anchor("m-0"), geometry: sample, firstMessageId: "m-0"), "first padded message")
        }
        try run("middle-anchor-must-reach-top-or-real-clamp") {
            let sample = AssistantChatViewportGeometry(viewportHeight: 100, contentMinY: -50, bottomY: 500,
                frames: [.init(messageId: "m-2", minY: 60, maxY: 90)])
            try expect(!AssistantChatViewportStore.hasReached(.anchor("m-2"), geometry: sample, firstMessageId: "m-0"), "visible is not top aligned")
        }
        try run("latest-restore-requires-visible-tail-not-only-height") {
            let sample = AssistantChatViewportGeometry(viewportHeight: 100, contentMinY: -500, bottomY: 100,
                frames: [.init(messageId: "m-3", minY: 0, maxY: 100)])
            try expect(!AssistantChatViewportStore.hasReached(.latest("m-5"), geometry: sample, firstMessageId: "m-0"), "missing real tail frame")
        }
        try run("actual-tail-at-bottom-completes-restore") {
            let sample = AssistantChatViewportGeometry(viewportHeight: 100, contentMinY: -500, bottomY: 116,
                frames: [.init(messageId: "m-5", minY: -50, maxY: 100)])
            try expect(AssistantChatViewportStore.hasReached(.latest("m-5"), geometry: sample, firstMessageId: "m-0"), "real visible tail")
        }
        print("All \(groups) AssistantChatViewport groups passed; actual bounded production policy, no UI, network or credentials.")
    }
}
