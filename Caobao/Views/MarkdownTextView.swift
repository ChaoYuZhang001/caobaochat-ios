import SwiftUI

/// Markdown 渲染视图 - 支持更美观的格式化显示
struct MarkdownTextView: View {
    let markdown: String
    @State private var attributedString: AttributedString?

    var body: some View {
        if let attributedString = attributedString {
            Text(attributedString)
        } else {
            Text(markdown)
                .onAppear {
                    parseMarkdown()
                }
        }
    }

    private func parseMarkdown() {
        let styled = formatMarkdown(markdown)
        self.attributedString = styled
    }

    /// 格式化 Markdown 文本，应用美观的样式
    private func formatMarkdown(_ markdown: String) -> AttributedString {
        var attributedString: AttributedString

        do {
            // 解析 Markdown
            attributedString = try AttributedString(markdown)

            // 应用样式
            attributedString = applyStyles(to: attributedString)
        } catch {
            // 解析失败，返回纯文本
            attributedString = AttributedString(markdown)
        }

        return attributedString
    }

    /// 应用样式到 AttributedString
    private func applyStyles(to string: AttributedString) -> AttributedString {
        var styledString = string

        // 遍历所有字符
        for index in styledString.characters.indices {
            // 获取当前字符的属性
            var attributes = styledString[index].attributes

            // 标题样式
            if attributes.presentationIntent?.kind == .header {
                let level = attributes.presentationIntent?.headerLevel ?? 1
                switch level {
                case 1:
                    styledString[index].font = .system(.title, design: .rounded).bold()
                    styledString[index].foregroundColor = .primary
                case 2:
                    styledString[index].font = .system(.title2, design: .rounded).bold()
                    styledString[index].foregroundColor = .primary
                case 3:
                    styledString[index].font = .system(.title3, design: .rounded).bold()
                    styledString[index].foregroundColor = .primary
                default:
                    styledString[index].font = .system(.headline).bold()
                }
            }
            // 粗体样式
            else if attributes.inlinePresentationIntent == .stronglyEmphasized {
                styledString[index].font = .system(.body, design: .rounded).bold()
            }
            // 斜体样式
            else if attributes.inlinePresentationIntent == .emphasized {
                styledString[index].font = .system(.body).italic()
            }
            // 行内代码样式
            else if attributes.inlinePresentationIntent == .code {
                styledString[index].font = .system(.caption, design: .monospaced)
                styledString[index].backgroundColor = Color(.systemGray6)
                styledString[index].foregroundColor = Color(.systemPink)
            }
            // 链接样式
            else if attributes.link != nil {
                styledString[index].foregroundColor = .blue
                styledString[index].underlineStyle = .single
            }
            // 默认样式
            else {
                styledString[index].font = .system(.body)
            }
        }

        return styledString
    }
}

// MARK: - 预览
#Preview {
    VStack(alignment: .leading, spacing: 16) {
        Text("Markdown 渲染示例")
            .font(.title)
            .padding()

        VStack(alignment: .leading, spacing: 12) {
            MarkdownTextView(markdown: """
            # 图片分析报告

            ## 概述
            这是一张**非常美丽**的风景照片，展现了*自然*的壮丽。

            ## 主要特点

            ### 色彩
            - 色彩鲜艳
            - 对比度适中
            - 光线柔和

            ### 构图
            1. 主体突出
            2. 背景简洁
            3. 视角独特

            ## 评价
            这是一张`优秀`的作品，值得推荐！

            ---
            *分析时间：2024年1月*
            """)
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(radius: 2)
        }
        .padding()
    }
}
