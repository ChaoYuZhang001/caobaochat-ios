import SwiftUI

/// Markdown 渲染视图 - 支持更美观的格式化显示
struct MarkdownTextView: View {
    let markdown: String

    var body: some View {
        Text(markdown)
            .textSelection(.enabled)
            .font(.body)
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
