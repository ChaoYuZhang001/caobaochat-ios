import Foundation

private enum DeepLinkTestFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { if case .assertion(let value) = self { return value }; return "assertion failed" }
}

@main
private struct AssistantDeepLinkTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw DeepLinkTestFailure.assertion(message) }
    }

    static func main() throws {
        guard let conversation = AssistantDeepLink(url: URL(string: "https://caobao.chat/conversation/conv-123")!) else {
            throw DeepLinkTestFailure.assertion("valid conversation link was rejected")
        }
        try expect(conversation == .conversation("conv-123"), "conversation route did not preserve id")

        guard let task = AssistantDeepLink(url: URL(string: "https://www.caobao.chat/task/task%2D123?source=push")!) else {
            throw DeepLinkTestFailure.assertion("valid task link was rejected")
        }
        try expect(task == .task("task-123"), "task route did not decode id")

        guard let proactive = AssistantDeepLink(url: URL(string: "https://caobao.chat/proactive/run-1")!) else {
            throw DeepLinkTestFailure.assertion("valid proactive link was rejected")
        }
        try expect(proactive == .proactive("run-1"), "proactive route did not preserve id")

        let invalid = [
            "http://caobao.chat/task/task-1",
            "https://evil.example/task/task-1",
            "https://caobao.chat/unknown/id",
            "https://caobao.chat/task",
            "https://caobao.chat/task/a/b",
            "https://caobao.chat/task/%20",
            "https://caobao.chat/task/a%2Fb",
            "https://caobao.chat/task/a%0Ab"
        ]
        for raw in invalid {
            try expect(AssistantDeepLink(url: URL(string: raw)!) == nil, "invalid link accepted: \(raw)")
        }

        let longID = String(repeating: "x", count: 257)
        try expect(AssistantDeepLink(url: URL(string: "https://caobao.chat/task/\(longID)")!) == nil,
                   "oversized route id was accepted")
        print("All 8 AssistantDeepLink checks passed")
    }
}
