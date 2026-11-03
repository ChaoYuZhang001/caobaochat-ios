import Foundation

/// A bounded, local block parser. It never interprets HTML, fetches URLs, or parses inline markup.
enum AssistantMarkdown {
    struct Limits: Equatable, Sendable {
        var maxParsedUTF8Bytes: Int = 262_144
        var maxBlocks: Int = 2_000
        static let `default` = Limits()
    }

    enum Kind: Equatable, Hashable, Sendable {
        case paragraph
        case heading(level: Int)
        case unorderedListItem(marker: String)
        case orderedListItem(marker: String)
        case blockquote
        case code(language: String?, isClosed: Bool)
        case blank
        case literalFallback
    }

    struct Block: Identifiable, Equatable, Hashable, Sendable {
        /// UTF-8 start offset: stable while streaming appends to the same source.
        let id: Int
        let kind: Kind
        /// Prose omits its marker and final line ending; code retains exact body whitespace.
        /// For an unclosed fence, a renderer may show `source` verbatim until it closes.
        let text: String
        /// Exact original bytes, including markers and original line endings.
        let source: String
        /// UTF-8 offsets, not Character or UTF-16 offsets. Adjacent ranges are contiguous.
        let sourceRange: Range<Int>
    }

    private struct Line {
        let start: Int
        let contentEnd: Int
        let end: Int
    }

    private struct Fence {
        let marker: UInt8
        let count: Int
        let language: String?
    }

    private enum LineKind {
        case paragraph, blank
        case heading(Int, Int, Int)
        case unordered(String, Int)
        case ordered(String, Int)
        case quote(Int)
        case fence(Fence)
    }

    /// Concatenating all block.source values always reconstructs the input exactly.
    /// Limits bound structural parsing, not visibility: any unparsed tail is one literalFallback.
    /// Hard ceilings prevent accidental unbounded parsing even with caller-supplied limits.
    /// A nonempty input with a zero/negative limit still produces one visible fallback block.
    static func parse(_ markdown: String, limits: Limits = .default) -> [Block] {
        guard !markdown.isEmpty else { return [] }
        let byteLimit = max(0, min(limits.maxParsedUTF8Bytes, 1_048_576))
        let blockLimit = max(1, min(limits.maxBlocks, 10_000))
        let totalBytes = markdown.utf8.count
        let bytes = Array(markdown.utf8.prefix(byteLimit))
        let completeInput = bytes.count == totalBytes
        var lines: [Line] = []
        var cursor = 0
        while cursor < bytes.count {
            let start = cursor
            while cursor < bytes.count && bytes[cursor] != 10 && bytes[cursor] != 13 { cursor += 1 }
            let contentEnd = cursor
            if cursor == bytes.count {
                if completeInput { lines.append(Line(start: start, contentEnd: contentEnd, end: cursor)) }
                break
            }
            // Do not split a CRLF across the parse budget. Its whole line becomes literal.
            if bytes[cursor] == 13 && cursor + 1 == bytes.count && !completeInput { break }
            if bytes[cursor] == 13 && cursor + 1 < bytes.count && bytes[cursor + 1] == 10 { cursor += 2 }
            else { cursor += 1 }
            lines.append(Line(start: start, contentEnd: contentEnd, end: cursor))
        }
        var blocks: [Block] = []
        var lineIndex = 0
        var consumed = 0
        func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        func append(_ kind: Kind, _ text: String, _ start: Int, _ end: Int) {
            blocks.append(Block(id: start, kind: kind, text: text, source: string(start..<end), sourceRange: start..<end))
            consumed = end
        }
        while lineIndex < lines.count && blocks.count < blockLimit && limits.maxBlocks > 0 {
            let first = lines[lineIndex]
            switch classify(first, bytes) {
            case .blank:
                var end = first.end
                lineIndex += 1
                while lineIndex < lines.count {
                    guard case .blank = classify(lines[lineIndex], bytes) else { break }
                    end = lines[lineIndex].end; lineIndex += 1
                }
                append(.blank, "", first.start, end)
            case let .heading(level, start, end):
                append(.heading(level: level), string(start..<end), first.start, first.end)
                lineIndex += 1
            case let .unordered(marker, start):
                append(.unorderedListItem(marker: marker), string(start..<first.contentEnd), first.start, first.end)
                lineIndex += 1
            case let .ordered(marker, start):
                append(.orderedListItem(marker: marker), string(start..<first.contentEnd), first.start, first.end)
                lineIndex += 1
            case .quote:
                var quoteBytes: [UInt8] = []
                var last = first
                var hasQuoteLine = false
                while lineIndex < lines.count {
                    let line = lines[lineIndex]
                    guard case let .quote(start) = classify(line, bytes) else { break }
                    if hasQuoteLine { quoteBytes.append(contentsOf: bytes[last.contentEnd..<last.end]) }
                    quoteBytes.append(contentsOf: bytes[start..<line.contentEnd])
                    hasQuoteLine = true
                    last = line; lineIndex += 1
                }
                append(.blockquote, String(decoding: quoteBytes, as: UTF8.self), first.start, last.end)
            case let .fence(fence):
                lineIndex += 1
                let bodyStart = first.end
                var bodyEnd = bodyStart
                var sourceEnd = first.end
                var closed = false
                while lineIndex < lines.count {
                    let line = lines[lineIndex]
                    if isClosingFence(line, bytes, fence) {
                        bodyEnd = line.start; sourceEnd = line.end
                        lineIndex += 1; closed = true; break
                    }
                    bodyEnd = line.end; sourceEnd = line.end; lineIndex += 1
                }
                append(.code(language: fence.language, isClosed: closed), string(bodyStart..<bodyEnd), first.start, sourceEnd)
            case .paragraph:
                var last = first
                lineIndex += 1
                while lineIndex < lines.count {
                    guard case .paragraph = classify(lines[lineIndex], bytes) else { break }
                    last = lines[lineIndex]; lineIndex += 1
                }
                append(.paragraph, string(first.start..<last.contentEnd), first.start, last.end)
            }
        }
        if consumed < totalBytes {
            // Reserve a slot for visible overflow instead of dropping content or exceeding maxBlocks.
            if blocks.count >= blockLimit, let last = blocks.popLast() { consumed = last.sourceRange.lowerBound }
            let tail = String(decoding: markdown.utf8.dropFirst(consumed), as: UTF8.self)
            blocks.append(Block(id: consumed, kind: .literalFallback, text: tail, source: tail, sourceRange: consumed..<totalBytes))
        }
        return blocks
    }

    private static func markerStart(_ line: Line, _ bytes: [UInt8]) -> Int? {
        var start = line.start
        while start < line.contentEnd && bytes[start] == 32 && start - line.start < 4 { start += 1 }
        return start - line.start <= 3 ? start : nil
    }

    private static func whitespace(_ value: UInt8) -> Bool { value == 32 || value == 9 }

    private static func classify(_ line: Line, _ bytes: [UInt8]) -> LineKind {
        if bytes[line.start..<line.contentEnd].allSatisfy(whitespace) { return .blank }
        guard let start = markerStart(line, bytes), start < line.contentEnd else { return .paragraph }
        let marker = bytes[start]
        if marker == 96 || marker == 126 {
            var end = start
            while end < line.contentEnd && bytes[end] == marker { end += 1 }
            if end - start >= 3 {
                let info = bytes[end..<line.contentEnd]
                if marker != 96 || !info.contains(96) {
                    let token = info.drop(while: whitespace).prefix(while: { !whitespace($0) })
                    let language = token.isEmpty ? nil : String(decoding: token, as: UTF8.self)
                    return .fence(Fence(marker: marker, count: end - start, language: language))
                }
            }
        }
        if marker == 35 {
            var end = start
            while end < line.contentEnd && bytes[end] == 35 { end += 1 }
            let level = end - start
            if level <= 6 && (end == line.contentEnd || whitespace(bytes[end])) {
                while end < line.contentEnd && whitespace(bytes[end]) { end += 1 }
                var textEnd = line.contentEnd
                while textEnd > end && whitespace(bytes[textEnd - 1]) { textEnd -= 1 }
                var hashes = textEnd
                while hashes > end && bytes[hashes - 1] == 35 { hashes -= 1 }
                if hashes < textEnd && (hashes == end || whitespace(bytes[hashes - 1])) {
                    textEnd = hashes
                    while textEnd > end && whitespace(bytes[textEnd - 1]) { textEnd -= 1 }
                }
                return .heading(level, end, textEnd)
            }
        }
        if marker == 62 {
            let end = start + 1
            return .quote(end < line.contentEnd && whitespace(bytes[end]) ? end + 1 : end)
        }
        if marker == 45 || marker == 43 || marker == 42 {
            var end = start + 1
            if end == line.contentEnd || whitespace(bytes[end]) {
                while end < line.contentEnd && whitespace(bytes[end]) { end += 1 }
                return .unordered(String(UnicodeScalar(marker)), end)
            }
        }
        if marker >= 48 && marker <= 57 {
            var end = start
            while end < line.contentEnd && bytes[end] >= 48 && bytes[end] <= 57 && end - start < 10 { end += 1 }
            if end - start <= 9 && end < line.contentEnd && (bytes[end] == 46 || bytes[end] == 41) {
                let delimiterEnd = end + 1
                if delimiterEnd == line.contentEnd || whitespace(bytes[delimiterEnd]) {
                    end = delimiterEnd
                    while end < line.contentEnd && whitespace(bytes[end]) { end += 1 }
                    return .ordered(String(decoding: bytes[start..<delimiterEnd], as: UTF8.self), end)
                }
            }
        }
        return .paragraph
    }

    private static func isClosingFence(_ line: Line, _ bytes: [UInt8], _ fence: Fence) -> Bool {
        guard let start = markerStart(line, bytes), start < line.contentEnd else { return false }
        var end = start
        while end < line.contentEnd && bytes[end] == fence.marker { end += 1 }
        return end - start >= fence.count && bytes[end..<line.contentEnd].allSatisfy(whitespace)
    }
}

extension AssistantMarkdown {
    /// Validates a copy request against a freshly resolved message. The source
    /// offset and UTF-8 payload must still identify the exact same code block.
    static func codeCopyText(in source: String, blockId: Int, expectedText: String) -> String? {
        guard let block = parse(source).first(where: { $0.id == blockId }),
              case .code(_, let isClosed) = block.kind else { return nil }
        let payload = isClosed ? block.text : block.source
        return payload.utf8.elementsEqual(expectedText.utf8) ? payload : nil
    }
}
