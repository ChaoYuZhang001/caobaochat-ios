//
//  LegalView.swift
//  Caobao
//
//  法律文档视图
//  使用 H5 页面展示，支持离线降级
//

import SwiftUI

// MARK: - Legal View
/// 法律文档视图
/// 包含用户协议、隐私政策、未成年人保护等
/// 优先加载 H5 页面，离线时降级到本地内容
struct LegalView: View {
    let type: LegalType
    @Environment(\.dismiss) var dismiss
    @State private var isLoading = true
    @State private var loadError = false
    
    var body: some View {
        ZStack {
            if let url = type.webURL {
                // 优先加载 H5 页面
                WebView(url: url) {
                    isLoading = false
                }
                .opacity(isLoading ? 0 : 1)
                
                // 加载中状态
                if isLoading {
                    ProgressView("加载中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // 降级到本地内容
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(type.content)
                            .font(.body)
                            .lineSpacing(6)
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(type.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("关闭") {
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Legal Type
enum LegalType: String, Identifiable, CaseIterable {
    case agreement = "用户协议"
    case privacy = "隐私政策"
    case children = "未成年人保护"
    case aiDeclaration = "AI使用声明"
    
    var id: String { rawValue }
    
    var title: String { rawValue }
    
    var icon: String {
        switch self {
        case .agreement: return "doc.text.fill"
        case .privacy: return "hand.raised.fill"
        case .children: return "figure.and.child.holdinghands"
        case .aiDeclaration: return "cpu"
        }
    }
    
    /// H5 页面 URL（优先使用）
    /// 注意：法律文档是 H5 页面，路径不带 /api 前缀
    var webURL: URL? {
        let serverURL = APIConfig.serverURL
        
        switch self {
        case .agreement:
            return URL(string: "\(serverURL)/legal/agreement")
        case .privacy:
            return URL(string: "\(serverURL)/legal/privacy")
        case .children:
            return URL(string: "\(serverURL)/legal/children")
        case .aiDeclaration:
            return URL(string: "\(serverURL)/legal/ai-declaration")
        }
    }
    
    /// 本地内容（离线降级使用）
    var content: String {
        switch self {
        case .agreement:
            return LegalContent.userAgreement
        case .privacy:
            return LegalContent.privacyPolicy
        case .children:
            return LegalContent.childrenProtection
        case .aiDeclaration:
            return LegalContent.aiDeclaration
        }
    }
}

// MARK: - Legal Content
enum LegalContent {
    
    // MARK: - 用户协议
    static let userAgreement = """
【草包助手用户协议】

更新日期：2026年3月28日
生效日期：2026年3月28日

欢迎使用草包助手！为使用草包助手服务（以下简称"本服务"），您应当阅读并遵守《草包助手用户协议》（以下简称"本协议"）。请您务必审慎阅读、充分理解各条款内容，特别是免除或限制责任的相应条款。

一、服务条款的确认和接纳

1.1 草包助手的所有权和运营权归草台班子团队所有。

1.2 用户在使用草包助手提供的各项服务之前，应仔细阅读本服务协议。如用户不同意本服务协议及/或随时对其的修改，用户可以主动停止使用草包助手提供的服务。

1.3 用户一旦注册使用草包助手的服务，即视为用户已了解并完全同意本服务协议各项内容。

二、服务说明

2.1 草包助手是一个AI智能助手应用，提供对话、运势、决策等功能。

2.2 用户理解，草包助手仅提供相关信息及服务，不承担因信息准确性、完整性引发的任何责任。

2.3 用户需自行配备注册和使用本服务所需的各项设备（如个人电脑、手机等）和费用（如电话费、上网费等）。

三、用户注册

3.1 用户注册成功后，草包助手将给予每个用户一个用户账号及相应的密码，该用户账号和密码由用户负责保管。

3.2 用户对以其用户账号进行的所有活动和事件负法律责任。

3.3 用户在使用草包助手服务过程中，必须遵循以下原则：
（1）遵守中国有关的法律和法规；
（2）不得为任何非法目的而使用网络服务系统；
（3）遵守所有与网络服务有关的网络协议、规定和程序；
（4）不得利用草包助手服务进行任何可能对互联网正常运转造成不利影响的行为。

四、用户隐私保护

4.1 保护用户隐私是草包助手的一项基本政策，草包助手保证不对外公开或向第三方提供单个用户的注册资料及用户在使用网络服务时存储在草包助手的非公开内容，但下列情况除外：
（1）事先获得用户的明确授权；
（2）根据有关的法律法规要求；
（3）按照相关政府主管部门的要求；
（4）为维护社会公众的利益；
（5）为维护草包助手的合法权益。

4.2 草包助手可能会与第三方合作向用户提供相关的网络服务，在此情况下，如该第三方同意承担与草包助手同等的保护用户隐私的责任，则草包助手有权将用户的注册资料等提供给该第三方。

五、用户账号安全

5.1 用户一旦注册成功，成为草包助手的用户，将得到一个用户名和密码，用户对其用户名和密码的安全负全部责任。

5.2 用户对以其用户账号进行的所有活动和事件负法律责任。

5.3 用户若发现任何非法使用用户账号或存在安全漏洞的情况，请立即通知草包助手。

六、服务变更、中断或终止

6.1 鉴于网络服务的特殊性，用户同意草包助手有权随时变更、中断或终止部分或全部的服务。

6.2 用户理解，草包助手需要定期或不定期地对提供网络服务的平台或相关的设备进行检修或者维护，如因此类情况而造成服务在合理时间内的中断，草包助手无需为此承担任何责任。

七、法律责任

7.1 用户理解并同意，草包助手不对因下述任一情况而导致的任何损害赔偿承担责任，包括但不限于利润、商誉、使用、数据等方面的损失或其它无形损失的损害赔偿：
（1）使用或未能使用本服务；
（2）第三方以任何方式进行的使用；
（3）用户传输的内容遭到第三方盗用；
（4）任何非因草包助手的原因而引起的与本服务有关的其它事宜。

7.2 用户理解并同意，草包助手在提供服务的过程中，可能会因网络设备维修、网络故障、黑客攻击等原因造成服务中断或不能满足用户要求的情况，草包助手不承担任何责任。

八、协议修改

8.1 草包助手有权随时修改本协议的任何条款，一旦本协议的内容发生变动，草包助手将会在相关页面上公布修改之后的协议内容。

8.2 如果用户不同意草包助手修改的内容，用户可以主动停止使用草包助手的服务。如果用户在修改内容公告后继续使用草包助手的服务，则视为用户已经接受协议的修改。

九、法律适用与争议解决

9.1 本协议的订立、执行和解释及争议的解决均应适用中华人民共和国法律。

9.2 如双方就本协议内容或其执行发生任何争议，双方应尽力友好协商解决；协商不成时，任何一方均可向草包助手所在地的人民法院提起诉讼。

十、其他

10.1 本协议构成用户和草包助手之间的完整协议，取代用户和草包助手之前就本服务所达成的所有协议。

10.2 如果本协议的任何条款被认定为无效或不可执行，该条款应视为可分的且并不影响本协议其余条款的有效性及可执行性。

草台班子团队
联系邮箱：2900814034@qq.com
"""

    // MARK: - 隐私政策
    static let privacyPolicy = """
【草包助手隐私政策】

更新日期：2026年3月28日
生效日期：2026年3月28日

引言

草台班子团队（以下简称"我们"）深知个人信息对您的重要性，我们将按照法律法规要求，采取相应安全保护措施，尽力保护您的个人信息安全可控。

一、我们如何收集和使用您的个人信息

1. 账号注册与登录
当您注册和登录账号时，我们会收集您的：
- 设备信息（设备型号、操作系统版本、设备标识符）
- 网络信息（IP地址、网络类型）
- 账号信息（Apple ID 信息，如您选择 Sign in with Apple 登录）

2. 功能使用
当您使用草包助手提供的服务时，我们会收集：
- 对话记录：您与AI的对话内容
- 使用记录：您使用的功能、时间、频次等

二、我们如何共享您的个人信息

为提供智能对话功能，我们会将您的对话内容发送给以下AI服务提供商：
- 火山引擎（豆包大模型）
- 通义千问（阿里云）
- DeepSeek（深度求索）
- Kimi（月之暗面）
- 文心一言（百度）
- 腾讯混元
- 讯飞星火

上述服务提供商均已按照《生成式人工智能服务管理办法》完成算法备案。

三、您如何管理您的个人信息

您有权：访问、更正、删除您的个人信息，以及注销账号和导出数据。

四、联系我们

电子邮件：2900814034@qq.com
"""

    // MARK: - 未成年人保护
    static let childrenProtection = """
【草包助手未成年人保护政策】

更新日期：2026年3月28日
生效日期：2026年3月28日

一、监护人同意

若您是未成年人，请在监护人的陪同下阅读本政策，并在取得监护人同意后使用我们的服务。

二、未成年人个人信息的收集

我们收集未成年人个人信息的原则：合法、正当、必要，经监护人同意。

三、监护人权利

监护人有权：查询、更正、删除未成年人的个人信息，注销账号。

四、联系我们

电子邮件：2900814034@qq.com
"""

    // MARK: - AI 使用声明
    static let aiDeclaration = """
【草包助手 AI 使用声明】

一、AI 服务说明

草包助手使用大语言模型（LLM）提供智能对话服务。AI 生成内容仅供参考。

二、使用限制

- 不得用于医疗诊断或治疗建议
- 不得用于法律或金融专业决策
- 不得用于危害国家安全的行为
- 不得用于生成虚假信息

三、免责声明

AI 生成的内容可能存在错误，用户应独立判断其准确性。

四、举报方式

电子邮件：2900814034@qq.com
"""
}

// MARK: - Preview
#Preview {
    NavigationStack {
        LegalView(type: .privacy)
    }
}
