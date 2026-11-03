import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Local rendering only. Remote images and HTML remain literal reference text.
@MainActor
struct MarkdownTextView: View {
    let markdown: String
    private let blocks: [AssistantMarkdown.Block]
    private let onCopyCode: (@MainActor (Int, String) async -> Bool)?
    @State private var copiedBlockId: Int?
    @State private var copyingBlockId: Int?
    @State private var copyRunId: UUID?
    @State private var copyTask: Task<Void, Never>?

    init(markdown: String, onCopyCode: (@MainActor (Int, String) async -> Bool)? = nil) {
        self.markdown = markdown
        self.onCopyCode = onCopyCode
        blocks = AssistantMarkdown.parse(markdown)
    }

    var body: some View {
        // The chat already virtualizes messages. A nested lazy stack can keep
        // invalidating its estimated height when code scroll views are revealed.
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in blockView(block) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(.caobaoPrimary)
        .environment(\.openURL, OpenURLAction { url in
            AssistantMarkdownInline.isAllowedLink(url) ? .systemAction : .discarded
        })
        .onChange(of: markdown) { _ in invalidateCopy() }
        .onDisappear { invalidateCopy() }
    }

    @ViewBuilder
    private func blockView(_ block: AssistantMarkdown.Block) -> some View {
        switch block.kind {
        case .paragraph:
            prose(block.text)
        case .heading(let level):
            prose(block.text, font: headingFont(level))
                .accessibilityAddTraits(.isHeader)
        case .unorderedListItem(let marker), .orderedListItem(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: marker).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                prose(block.text).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        case .blockquote:
            prose(block.text)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .padding(.vertical, 2)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                }
        case .code(let language, let isClosed):
            codeBlock(block, language: language, isClosed: isClosed)
        case .blank:
            Color.clear.frame(height: 3).accessibilityHidden(true)
        case .literalFallback:
            Text(verbatim: block.source)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func prose(_ text: String, font: Font = .body) -> some View {
        Text(AssistantMarkdownInline.attributed(text))
            .font(font)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        default: return .headline
        }
    }

    private func codeBlock(_ block: AssistantMarkdown.Block, language: String?, isClosed: Bool) -> some View {
        let content = isClosed ? block.text : block.source
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let language, !language.isEmpty {
                    Text(verbatim: language).font(.caption.monospaced()).lineLimit(1)
                } else { Text("代码").font(.caption) }
                Spacer(minLength: 4)
                Button {
                    copyCode(content, blockId: block.id)
                } label: {
                    Label(copiedBlockId == block.id ? LocalizedStringKey("已复制") :
                        (isClosed ? LocalizedStringKey("复制代码") : LocalizedStringKey("复制原文")),
                        systemImage: copiedBlockId == block.id ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderless)
                .disabled(copyingBlockId != nil)
                .accessibilityHint("仅复制此代码块，不会运行代码或发送网络请求。")
            }
            .foregroundStyle(.secondary)
            if !isClosed {
                Text("代码块尚未结束，暂按原文显示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                Text(verbatim: content)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("代码内容，可左右滚动")
            .accessibilityValue(Text(verbatim: content))
            .accessibilityIdentifier("assistant.markdown.code.\(block.id)")
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private func copyCode(_ text: String, blockId: Int) {
        guard copyingBlockId == nil else { return }
        if let onCopyCode {
            let run = UUID()
            copyRunId = run; copyingBlockId = blockId
            copyTask = Task { @MainActor in
                let copied = await onCopyCode(blockId, text)
                guard !Task.isCancelled, copyRunId == run else { return }
                if copied { copiedBlockId = blockId }
                copyingBlockId = nil; copyRunId = nil; copyTask = nil
            }
            return
        }
        Self.writeCodeToClipboard(text)
        copiedBlockId = blockId
    }

    private func invalidateCopy() {
        copyTask?.cancel(); copyTask = nil; copyRunId = nil
        copyingBlockId = nil; copiedBlockId = nil
    }

    @MainActor
    static func writeCodeToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

#Preview {
    ScrollView {
        MarkdownTextView(markdown: "# Today’s plan\n\n1. Review the priorities\n2. Finish one important task\n\n> You choose the next step.")
            .padding()
    }
}
