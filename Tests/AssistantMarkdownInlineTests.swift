import Foundation

private struct MarkdownInlineTestFailure: Error, CustomStringConvertible { let description: String }

@main private enum AssistantMarkdownInlineTests {
    private static var count = 0
    private static let tick = String(UnicodeScalar(96)!)
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw MarkdownInlineTestFailure(description: message) }
    }
    private static func run(_ name: String, _ body: () throws -> Void) throws {
        do { try body() } catch { throw MarkdownInlineTestFailure(description: name + ": \(error)") }
        count += 1; print("PASS " + name)
    }
    private static func text(_ value: AttributedString) -> String { String(value.characters) }
    private static func links(_ value: AttributedString) -> [URL] { value.runs.compactMap { $0.link } }
    @discardableResult
    private static func literal(_ source: String) throws -> AttributedString {
        let value = AssistantMarkdownInline.attributed(source)
        try expect(text(value).utf8.elementsEqual(source.utf8), "Literal fallback must preserve every source byte")
        try expect(value.runs.allSatisfy { $0.link == nil && $0.inlinePresentationIntent == nil }, "Literal fallback must contain no active links or inline styling")
        return value
    }
    static func main() {
        do { try runAll(); print("PASS \(count) Markdown inline test groups; Foundation only, no network, clipboard, or UI") }
        catch { print("FAIL \(error)"); exit(1) }
    }
    private static func runAll() throws {
        try run("empty-and-plain-unicode") {
            try expect(text(AssistantMarkdownInline.attributed("")).isEmpty, "Empty input stays empty")
            let source = "你好，CaoBao 🍀 café e\u{301}"
            try expect(text(AssistantMarkdownInline.attributed(source)).utf8.elementsEqual(source.utf8), "Plain Unicode remains intact")
        }
        try run("strong-and-emphasis-have-native-intents") {
            let value = AssistantMarkdownInline.attributed("**粗体** 与 *emphasis*")
            try expect(text(value) == "粗体 与 emphasis", "Strong/emphasis markers must render as inline formatting")
            try expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "Strong text needs its actual Foundation intent")
            try expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true }, "Emphasis needs its actual Foundation intent")
        }
        try run("inline-code-preserves-its-literal-body") {
            let value = AssistantMarkdownInline.attributed("Code: " + tick + "**not bold** [x](https://example.com)" + tick)
            try expect(text(value) == "Code: **not bold** [x](https://example.com)", "Inline code does not recursively interpret its contents")
            try expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }, "Inline code needs its actual Foundation code intent")
            try expect(links(value).isEmpty, "URL-like text inside code must not become a link")
        }
        try run("https-and-http-explicit-links-remain") {
            let value = AssistantMarkdownInline.attributed("[安全](https://example.com/a?q=1#part) [HTTP](http://example.org)")
            try expect(text(value) == "安全 HTTP", "Explicit safe link labels remain visible")
            try expect(links(value).count == 2 && links(value).allSatisfy(AssistantMarkdownInline.isAllowedLink), "Safe HTTP/HTTPS links keep their real link attributes")
            try expect(links(value).contains { $0.scheme == "https" && $0.host == "example.com" }, "HTTPS destination is preserved")
        }
        try run("url-whitelist-validates-components") {
            for raw in ["https://example.com", "http://example.org/a", "HTTPS://example.com/path", "https://example.com/?address=a@b"] {
                guard let url = URL(string: raw) else { throw MarkdownInlineTestFailure(description: "Invalid safe URL fixture") }
                try expect(AssistantMarkdownInline.isAllowedLink(url), "HTTP/HTTPS without URL credentials is allowed")
            }
            for raw in ["../local", "#fragment", "//example.com/a", "https:relative", "https:///path", "javascript:run", "data:text/plain,hello", "file:///tmp/hidden", "mailto:test@example.com", "tel:123", "blob:https://example.com/id", "https://user:pass@example.com", "https://user@example.com", "https://@example.com", "https://%75ser:pass@example.com"] {
                guard let url = URL(string: raw) else { throw MarkdownInlineTestFailure(description: "Invalid blocked URL fixture: " + raw) }
                try expect(!AssistantMarkdownInline.isAllowedLink(url), "Missing scheme/host, dangerous schemes, and any URL user information must be rejected")
            }
        }
        for destination in ["javascript:alert%281%29", "data:text/plain;base64,SGVsbG8=", "file:///tmp/hidden", "mailto:test@example.com", "tel:123", "blob:https://example.com/id"] {
            try run("dangerous-scheme-link-is-passive-" + String(destination.prefix { $0 != ":" })) {
                let value = AssistantMarkdownInline.attributed("[可见标签](" + destination + ")")
                try expect(text(value) == "可见标签", "Removing unsafe link attributes must preserve the label")
                try expect(links(value).isEmpty, "No dangerous scheme may survive as a link attribute")
            }
        }
        try run("relative-fragment-and-protocol-relative-links-are-passive") {
            for destination in ["../local.md", "/private/path", "#section", "//example.com/path"] {
                let value = AssistantMarkdownInline.attributed("[visible](" + destination + ")")
                try expect(text(value) == "visible" && links(value).isEmpty, "Relative links retain visible labels without active destinations")
            }
        }
        try run("credentials-links-are-passive") {
            for destination in ["https://user:pass@example.com/a", "http://user@example.com", "https://@example.com", "https://%75ser:pass@example.com"] {
                let value = AssistantMarkdownInline.attributed("[visible](" + destination + ")")
                try expect(text(value) == "visible" && links(value).isEmpty, "URL credentials never survive in an active link")
            }
        }
        try run("sanitizing-multiple-ranges-preserves-safe-formatting") {
            let value = AssistantMarkdownInline.attributed("[good](https://example.com) / [bad](javascript:run) **bold** / [local](../file)")
            try expect(text(value) == "good / bad bold / local", "All labels and neighboring text remain visible")
            try expect(links(value).count == 1 && links(value)[0].host == "example.com", "Only the safe link survives multiple unsafe range mutations")
            try expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "Sanitization preserves neighboring strong styling")
        }
        try run("raw-url-autolinking-follows-native-parser") {
            let source = "raw https://example.com/path?q=1 and http://example.org"
            let native = try AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            let actual = AssistantMarkdownInline.attributed(source)
            try expect(text(actual) == text(native), "The renderer follows native raw-URL text handling")
            try expect(links(actual) == links(native).filter(AssistantMarkdownInline.isAllowedLink), "Do not invent raw URL linkification behavior")
        }
        try run("whitespace-and-linebreaks-remain-visible") {
            let source = "  before\t **bold**  \n\n  after  "
            let value = AssistantMarkdownInline.attributed(source)
            try expect(text(value) == "  before\t bold  \n\n  after  ", "Inline parsing preserves spacing, blank lines and indentation")
        }
        try run("html-and-angle-markup-use-complete-literal-fallback") {
            for source in ["<b>bold</b> **unchanged**", "before <script>alert(1)</script> after", "<https://example.com>", "1 < 2 and **literal**", "<img src=\"https://example.com/a.png\"> tail", "<!-- comment --> visible"] {
                try literal(source)
            }
        }
        try run("remote-and-local-image-markdown-use-complete-literal-fallback") {
            for source in ["before ![alt](https://example.com/a.png) **after**", "![hidden](file:///tmp/photo.png)", "![data](data:image/png;base64,AAAA)", "![half", "![reference][id]\n\n[id]: https://example.com/image.png"] {
                try literal(source)
            }
        }
        try run("exact-ascii-budget-still-parses") {
            let suffix = "**bold**"
            let source = String(repeating: "a", count: 32 * 1024 - suffix.utf8.count) + suffix
            try expect(source.utf8.count == 32 * 1024, "Exact byte-boundary fixture")
            let value = AssistantMarkdownInline.attributed(source)
            try expect(text(value).hasSuffix("bold") && !text(value).hasSuffix(suffix), "Exact-budget input still receives formatting")
            try expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "Exact-budget strong formatting remains native")
        }
        try run("one-byte-over-budget-remains-complete-literal") {
            let suffix = "**bold**"
            let source = String(repeating: "a", count: 32 * 1024 + 1 - suffix.utf8.count) + suffix
            try expect(source.utf8.count == 32 * 1024 + 1, "One-byte overflow fixture")
            try literal(source)
        }
        try run("unicode-byte-budget-does-not-split-characters") {
            let exact = String(repeating: "🍀", count: 8_190) + "**bold**"
            try expect(exact.utf8.count == 32 * 1024, "Emoji fixture reaches the byte budget, not a character-count budget")
            let value = AssistantMarkdownInline.attributed(exact)
            try expect(text(value) == String(repeating: "🍀", count: 8_190) + "bold", "Exact-budget emoji remain whole while the suffix renders")
            try literal(String(repeating: "🍀", count: 8_191) + "**bold**")
        }
        try run("large-fallback-never-truncates-the-tail") {
            let source = String(repeating: "多语言🌍\n", count: 8_000) + "final-tail **must remain literal**"
            let value = try literal(source)
            try expect(text(value).hasSuffix("final-tail **must remain literal**"), "The complete final tail stays visible after parser-budget overflow")
        }
        try run("unicode-composed-graphemes-retain-inline-intents") {
            let source = "**你好👩🏽‍💻e\u{301}** 和 " + tick + "值🍀" + tick
            let value = AssistantMarkdownInline.attributed(source)
            try expect(text(value) == "你好👩🏽‍💻e\u{301} 和 值🍀", "Complex graphemes and combining marks remain readable")
            try expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "Unicode strong text retains its intent")
            try expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true }, "Unicode code retains its intent")
        }
        try run("streaming-half-syntax-remains-visible-and-passive") {
            for source in ["*em", "**bold", tick + "code", "[label](", "[label](https://", "[label](javascript:", "[open]", "hello \\"] {
                let value = AssistantMarkdownInline.attributed(source)
                try expect(!text(value).isEmpty, "An unfinished streamed token cannot erase the visible paragraph")
                try expect(text(value) == source, "Unfinished inline syntax remains visible until completed")
                try expect(links(value).allSatisfy(AssistantMarkdownInline.isAllowedLink), "Incomplete streams never expose unsafe links")
            }
            let completed = AssistantMarkdownInline.attributed("**bold** " + tick + "code" + tick + " [safe](https://example.com)")
            try expect(text(completed) == "bold code safe" && links(completed).count == 1, "The completed stream upgrades to the intended inline formatting")
        }
        try run("repeat-rendering-is-deterministic") {
            let source = "**中文** [safe](https://example.com) [unsafe](file:///tmp/local)"
            try expect(AssistantMarkdownInline.attributed(source) == AssistantMarkdownInline.attributed(source), "Repeated local rendering produces stable text and attributes")
        }
    }
}
