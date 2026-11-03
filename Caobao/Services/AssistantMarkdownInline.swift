import Foundation

/// Local inline styling only. It never fetches media, opens links, or copies text.
enum AssistantMarkdownInline {
    private static let maximumParsedUTF8Bytes = 32 * 1024

    static func attributed(_ source: String) -> AttributedString {
        // Bound parsing rather than visibility. Raw markup and image syntax remain
        // fully literal so the native parser cannot discard or activate content.
        guard source.utf8.prefix(maximumParsedUTF8Bytes + 1).count <= maximumParsedUTF8Bytes,
              !source.contains("!["), !source.contains("<") else { return AttributedString(source) }
        do {
            var value = try AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            let unsafeRanges = value.runs.compactMap { run -> Range<AttributedString.Index>? in
                guard let link = run.link, !isAllowedLink(link) else { return nil }
                return run.range
            }
            for range in unsafeRanges { value[range].link = nil }
            return value
        } catch {
            return AttributedString(source)
        }
    }

    static func isAllowedLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }
}
