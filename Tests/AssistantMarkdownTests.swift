import Foundation

private struct MarkdownTestFailure: Error, CustomStringConvertible { let description: String }

@main private enum AssistantMarkdownTests {
    private static var count = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw MarkdownTestFailure(description: message) }
    }
    private static func run(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { throw MarkdownTestFailure(description: name + ": \(error)") }
        count += 1; print("PASS " + name)
    }
    @discardableResult
    private static func preserved(_ source: String, limits: AssistantMarkdown.Limits = .default) throws -> [AssistantMarkdown.Block] {
        let blocks = AssistantMarkdown.parse(source, limits: limits)
        try expect(blocks.map(\.source).joined().utf8.elementsEqual(source.utf8), "Source bytes must round-trip exactly")
        var end = 0
        for block in blocks {
            try expect(block.id == end && block.sourceRange.lowerBound == end, "IDs/ranges must be contiguous source offsets")
            try expect(block.sourceRange.count == block.source.utf8.count, "Ranges must count UTF-8 bytes")
            try expect(!block.source.isEmpty, "No empty/duplicate block range")
            end = block.sourceRange.upperBound
            if block.kind == .literalFallback { try expect(block.text.utf8.elementsEqual(block.source.utf8), "Overflow must be visible verbatim") }
        }
        try expect(end == source.utf8.count, "No unaccounted tail")
        try expect(Set(blocks.map(\.id)).count == blocks.count, "IDs must be unique")
        try expect(blocks.count <= max(1, min(limits.maxBlocks, 10_000)), "Total block count must respect bounded output")
        return blocks
    }
    static func main() {
        do { try runAll(); print("PASS \(count) Markdown test groups; Foundation only, no network or UI") }
        catch { print("FAIL \(error)"); exit(1) }
    }
    private static func runAll() throws {
        try run("code-copy-resolves-closed-body-by-source-offset") {
            let prefix = "前言\n\n", expected = "  print(\"你好\")\n"
            let source = prefix + "~~~swift\n" + expected + "~~~\n"
            try expect(AssistantMarkdown.codeCopyText(in: source, blockId: prefix.utf8.count, expectedText: expected)?.utf8.elementsEqual(expected.utf8) == true,
                "A closed block copies its exact indented body at a UTF-8 source offset")
        }
        try run("code-copy-resolves-unclosed-original-source") {
            let prefix = "Before\n\n", expected = "~~~text\n  unfinished\nlast"
            let source = prefix + expected
            try expect(AssistantMarkdown.codeCopyText(in: source, blockId: prefix.utf8.count, expectedText: expected)?.utf8.elementsEqual(expected.utf8) == true,
                "An unclosed block copies its original fence and content rather than fabricating a closed body")
        }
        try run("code-copy-rejects-stale-content-offset-and-prose") {
            let expected = "old value\n", source = "~~~\n" + expected + "~~~"
            try expect(AssistantMarkdown.codeCopyText(in: source, blockId: 1, expectedText: expected) == nil,
                "A stale source offset cannot copy another block")
            try expect(AssistantMarkdown.codeCopyText(in: "~~~\nnew value\n~~~", blockId: 0, expectedText: expected) == nil,
                "A changed code block cannot approve an old cached payload")
            try expect(AssistantMarkdown.codeCopyText(in: "old value", blockId: 0, expectedText: "old value") == nil,
                "A prose block is never accepted as a code-copy request")
        }
        try run("code-copy-checks-exact-utf8-not-canonical-equivalence") {
            let expected = "e\u{301}\n", composed = expected.precomposedStringWithCanonicalMapping
            let source = "~~~\n" + expected + "~~~"
            try expect(!expected.utf8.elementsEqual(composed.utf8), "Fixture must use genuinely distinct UTF-8 spellings")
            try expect(AssistantMarkdown.codeCopyText(in: source, blockId: 0, expectedText: expected)?.utf8.elementsEqual(expected.utf8) == true,
                "The original spelling remains copyable verbatim")
            try expect(AssistantMarkdown.codeCopyText(in: source, blockId: 0, expectedText: composed) == nil,
                "A normalized cached payload cannot silently replace exact user-visible code bytes")
        }
        try run("empty-source") {
            try expect(AssistantMarkdown.parse("").isEmpty, "Empty source should have no blocks")
        }
        try run("minimum-structural-api") {
            let source = "# 标题\n\n- 项目\n1. step\n> quote\n```swift\n  let value = 1\n```\n"
            let blocks = AssistantMarkdown.parse(source)
            try expect(blocks.map(\.source).joined() == source, "Source reconstruction must be exact")
            try expect(blocks.map(\.kind) == [.heading(level: 1), .blank, .unorderedListItem(marker: "-"), .orderedListItem(marker: "1."), .blockquote, .code(language: "swift", isClosed: true)], "Kinds should be recognizable")
            try expect(blocks.last?.text == "  let value = 1\n", "Code whitespace must be exact")
        }
        try run("all-six-heading-levels-and-optional-closing-hashes") {
            for level in 1...6 {
                let blocks = try preserved(String(repeating: "#", count: level) + " 标题 ###  \r\n")
                try expect(blocks.first?.kind == .heading(level: level), "All six levels must parse")
                try expect(blocks.first?.text == "标题", "Optional closing hashes must not become content")
            }
            try expect(AssistantMarkdown.parse("#").first?.text == "", "Empty heading allowed")
            try expect(AssistantMarkdown.parse("## abc#").first?.text == "abc#", "Attached hash is content")
        }
        try run("literal-malformed-markers") {
            for source in ["####### literal", "#attached", "---", "***", "-attached", "+attached", "1.attached", "1234567890. literal", "    # indented", "\t- indented"] {
                let blocks = try preserved(source)
                try expect(blocks.count == 1 && blocks[0].kind == .paragraph && blocks[0].text == source, "Invalid block markers must remain literal")
            }
        }
        try run("paragraph-internal-lines-and-terminal-line-ending") {
            for ending in ["\n", "\r", "\r\n"] {
                let blocks = try preserved(" first" + ending + "第二行  " + ending)
                try expect(blocks.count == 1 && blocks[0].text == " first" + ending + "第二行  ", "Only the final physical ending is removed")
            }
        }
        try run("blank-runs-preserve-source") {
            let source = "\n \t\r\n\r"
            let blocks = try preserved(source)
            try expect(blocks.count == 1 && blocks[0].kind == .blank && blocks[0].text.isEmpty, "Blank source is one spacing block")
        }
        try run("unordered-markers-and-three-space-indent") {
            let blocks = try preserved("- alpha\n + beta\n   * 第三项\n-\n")
            try expect(blocks.map(\.kind) == [.unorderedListItem(marker: "-"), .unorderedListItem(marker: "+"), .unorderedListItem(marker: "*"), .unorderedListItem(marker: "-")], "All allowed markers and empty item")
            try expect(blocks.map(\.text) == ["alpha", "beta", "第三项", ""], "Markers stripped only from display text")
        }
        try run("ordered-markers-retain-number-and-delimiter") {
            let blocks = try preserved("1. first\n009) second\n999999999. third\n0.\n")
            try expect(blocks.map(\.kind) == [.orderedListItem(marker: "1."), .orderedListItem(marker: "009)"), .orderedListItem(marker: "999999999."), .orderedListItem(marker: "0.")], "No integer conversion or numbering rewrite")
            try expect(blocks.map(\.text) == ["first", "second", "third", ""], "Ordered display body")
        }
        try run("quotes-preserve-empty-lines-and-inner-markers") {
            let blocks = try preserved("> \r\n> body\r\n>\r\n>> nested\r\n")
            try expect(blocks.count == 1 && blocks[0].kind == .blockquote, "Consecutive quote lines share one block")
            try expect(blocks[0].text == "\r\nbody\r\n\r\n> nested", "Empty first quote and nested marker must not disappear")
        }
        try run("fenced-code-exact-body-with-crlf-and-indentation") {
            let body = "\tlet 中文 = 1  \r\n\r\n  return 中文\r\n"
            let blocks = try preserved("  ```swift filename=test.swift\r\n" + body + "   ``` \t\r\n")
            try expect(blocks.count == 1 && blocks[0].kind == .code(language: "swift", isClosed: true), "Language is first info token")
            try expect(blocks[0].text.utf8.elementsEqual(body.utf8), "Never trim code body, blank lines or tabs")
        }
        try run("empty-closed-fence-and-no-language") {
            let blocks = try preserved("```\n```")
            try expect(blocks.count == 1 && blocks[0].kind == .code(language: nil, isClosed: true) && blocks[0].text.isEmpty, "An empty closed fence remains code")
        }
        try run("tilde-fence-and-longer-close") {
            let blocks = try preserved("~~~text\n  body\n~~~~~\n")
            try expect(blocks.first?.kind == .code(language: "text", isClosed: true), "Tilde and longer closing delimiter supported")
            try expect(blocks.first?.text == "  body\n", "Tilde body exact")
        }
        try run("short-mismatched-and-nonempty-fence-closers-are-body") {
            let body = "```\n~~~~\n````suffix\n    ````\n# code heading\n- code list\n"
            let blocks = try preserved("````swift\n" + body + "`````\n")
            try expect(blocks.count == 1 && blocks[0].kind == .code(language: "swift", isClosed: true), "Only valid matching close terminates fence")
            try expect(blocks[0].text == body, "Code cannot be reinterpreted as prose blocks")
        }
        try run("backtick-in-info-invalidates-only-backtick-opening") {
            let invalid = try preserved("```sw`ift")
            try expect(invalid.first?.kind == .paragraph, "Backtick info cannot contain a backtick")
            let tilde = try preserved("~~~sw`ift\nx\n~~~")
            try expect(tilde.first?.kind == .code(language: "sw`ift", isClosed: true), "Tilde info does not inherit backtick restriction")
        }
        try run("unclosed-fences-retain-all-body-and-original-source") {
            for source in ["```", "```swift", "```swift\n", "```swift\n  body", "~~~\n\nbody\n"] {
                let blocks = try preserved(source)
                guard case .code(_, isClosed: false) = blocks[0].kind else { throw MarkdownTestFailure(description: "Open fence must expose closure status") }
                try expect(blocks.count == 1 && blocks[0].source == source, "Renderer can show the entire source while streaming")
                if source.hasSuffix("  body") { try expect(blocks[0].text == "  body", "Unterminated final code line retained") }
            }
        }
        try run("html-and-remote-images-stay-literal") {
            let source = "<script>alert('x')</script>\n<img src=\"https://example.invalid/a.png\">\n![私人图片](https://example.invalid/private.png)"
            let blocks = try preserved(source)
            try expect(blocks.count == 1 && blocks[0].kind == .paragraph && blocks[0].text == source, "No HTML/image execution or implicit retrieval")
        }
        try run("unicode-offsets-and-byte-exact-normalization") {
            let source = "👨‍👩‍👧‍👦 e\u{301} é 中文\r\n\n# 你好🌏\n"
            let blocks = try preserved(source)
            let heading = blocks.first { $0.kind == .heading(level: 1) }
            try expect(heading?.id == "👨‍👩‍👧‍👦 e\u{301} é 中文\r\n\n".utf8.count, "Offsets count source bytes, not graphemes")
            try expect(heading?.text == "你好🌏", "Display is not decoded from partial UTF-8")
        }
        try run("zero-negative-and-tiny-budgets-return-visible-fallback") {
            let source = "中文\n# heading\n"
            for limit in [AssistantMarkdown.Limits(maxParsedUTF8Bytes: 0, maxBlocks: 2), .init(maxParsedUTF8Bytes: -1, maxBlocks: 2), .init(maxParsedUTF8Bytes: 100, maxBlocks: 0), .init(maxParsedUTF8Bytes: 100, maxBlocks: -1), .init(maxParsedUTF8Bytes: 1, maxBlocks: 2)] {
                let blocks = try preserved(source, limits: limit)
                try expect(blocks.count == 1 && blocks[0].kind == .literalFallback && blocks[0].text == source, "Invalid limits preserve all visible source")
            }
        }
        try run("every-byte-budget-preserves-unicode-and-crlf") {
            let source = "# 中文🌏\r\n\r\n```swift\r\n  let e = \"é\"\r\n```\r\n结束"
            for budget in 0...(source.utf8.count + 2) {
                _ = try preserved(source, limits: .init(maxParsedUTF8Bytes: budget, maxBlocks: 20))
            }
        }
        try run("block-budget-reserves-literal-tail-slot") {
            let source = (1...12).map { "# 标题\($0)\n" }.joined()
            for budget in 1...12 {
                let blocks = try preserved(source, limits: .init(maxParsedUTF8Bytes: 4096, maxBlocks: budget))
                try expect(blocks.count == budget, "Output count includes fallback")
                if budget < 12 { try expect(blocks.last?.kind == .literalFallback && blocks.last?.text.contains("标题12") == true, "Late source remains visible") }
                else { try expect(blocks.last?.kind == .heading(level: 1), "No overflow block when whole input fits") }
            }
        }
        try run("default-input-limit-and-caller-hard-ceiling") {
            let source = String(repeating: "中", count: 350_000) + "最后必须可见"
            for limits in [AssistantMarkdown.Limits.default, .init(maxParsedUTF8Bytes: Int.max, maxBlocks: Int.max)] {
                let blocks = try preserved(source, limits: limits)
                try expect(blocks.count == 1 && blocks[0].kind == .literalFallback && blocks[0].text.hasSuffix("最后必须可见"), "Oversized single line falls back whole, never silently truncates")
            }
        }
        try run("mixed-block-boundaries") {
            let source = "p1\np2\n# H\n- x\n2) y\n> z\n\n~~~\na\n~~~\nend"
            let blocks = try preserved(source)
            try expect(blocks.map(\.kind) == [.paragraph, .heading(level: 1), .unorderedListItem(marker: "-"), .orderedListItem(marker: "2)"), .blockquote, .blank, .code(language: nil, isClosed: true), .paragraph], "Structural markers interrupt paragraphs without swallowing neighbors")
        }
        try run("streaming-prefixes-preserve-source-and-completed-block-identities") {
            let fixedPrefix = "# 标题\n\n第一段\n\n"
            let streamed = "```swift\n  let 家 = \"🌏\"\n```\n\n结尾"
            let initial = try preserved(fixedPrefix)
            var source = fixedPrefix
            for character in streamed {
                source.append(character)
                let blocks = try preserved(source)
                try expect(Array(blocks.prefix(initial.count)) == initial, "Previously complete prefix blocks keep values/identity")
                let code = blocks.first { if case .code = $0.kind { return true }; return false }
                if let code { try expect(code.id == fixedPrefix.utf8.count, "Fence keeps identity when open/closed body grows") }
            }
            try expect(AssistantMarkdown.parse(source) == AssistantMarkdown.parse(source), "Parsing is deterministic")
        }
        try run("every-prefix-of-markers-is-safe-and-visible") {
            for document in ["###### 标题 ###\n", "0001) 项目\n", "~~~json\n{}\n~~~", "<div>![x](https://invalid)</div>", "\r\n👋🏽e\u{301}\r\n"] {
                var prefix = ""
                for character in document { prefix.append(character); _ = try preserved(prefix) }
            }
        }
        try run("adversarial-marker-runs-remain-bounded-and-visible") {
            let sources = [String(repeating: "#", count: 50_000), String(repeating: "1", count: 50_000) + ". value", String(repeating: ">", count: 50_000), String(repeating: "`", count: 50_000) + "\nbody"]
            for source in sources { _ = try preserved(source) }
            let manyBlocks = (1...10_100).map { "- \($0)\n" }.joined()
            let blocks = try preserved(manyBlocks, limits: .init(maxParsedUTF8Bytes: Int.max, maxBlocks: Int.max))
            try expect(blocks.count == 10_000 && blocks.last?.kind == .literalFallback && blocks.last?.text.contains("10100") == true, "Hard block ceiling still shows remaining source")
        }
    }
}
