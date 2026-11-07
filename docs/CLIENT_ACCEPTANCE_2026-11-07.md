# 草包客户端验收记录（2026-11-07）

本记录只记录当前 checkout 和当前 Simulator 的证据。历史文档、单元测试或代码存在不能替代真实账号、系统权限、生产推送和多设备验收。

本轮失败记录：第一次 iPad 构建中 Xcode 输出 `BUILD SUCCEEDED`，但脚本验签发现复用 DerivedData 后的 `Assets.car` 为无效密封资源（`sealed resource is missing or invalid`）。隔离旧 DerivedData 后重新构建，签名校验通过；归类为构建缓存/验签环境问题，不是客户端 Swift 功能失败。

本轮 UI 重试记录：同一台 iPad Pro 11-inch 在更新本地化资源后 `simctl io screenshot` 出现纯白画面，但系统日志显示 Caobao 进程和 SwiftUI 场景仍为 running-active、没有崩溃；换用干净的 iPad Pro 13-inch Simulator 后，中英文登录页均正常渲染。当前归类为单台 Simulator 前台/渲染状态问题，iPad 真机仍未验收。

本轮回归失败与修复：2026-11-08 首次完整回归在 `quiet-edit-origin-never-replays-matured` 触发 fatal error，原因是 macOS `UNCalendarNotificationTrigger.nextTriggerDate()` 对已过期的一次性日历组件滚动到未来日期，导致安静时段编辑错误继承已成熟提醒。客户端已在 `ec7e55b` 按任务时区从完整日期组件重建实际 fire date；`AssistantReminderCoordinator` 独立套件随后 88/88 通过，完整回归修复后也已 exit 0。归类为客户端提醒协调器缺陷，已修复。

本轮生产联调补充：为避免 Simulator 无点击自动化能力，使用仅 Debug 的临时启动注入调用现有 `ChatViewModel` 发送路径；第一次注入过早触发客户端配置变更保护，显示“回复、原问题、账号或接入配置已变化”，未扣额度。等待登录权益、归档和区域状态稳定后重试，生产请求成功并完成完整 SSE；注入和 trace 均已撤销，工作树保持干净。

2026-11-08 生产契约探针补充：未携带认证访问 `/api/v2/characters`、`/api/v2/proactive/profile` 和 `/api/v2/proactive/rules` 均返回 `401 UNAUTHENTICATED`，证明路由和认证中间件可达，但不替代真实账号 CRUD/读写验收；`GET /api/v2/feedback` 返回 `404 Invalid URL`，当前没有可供客户端提交的 v2 反馈接口；`GET /api/v2/devices` 返回 `404`，不能据此判断 DELETE。随后用真实 Bearer 对随机设备 ID 执行 `DELETE /api/v2/devices/{deviceId}` 返回成功，证明注销 handler 已挂载；仍需真实已注册设备、旧账号失效和 outbox 清理验收。

2026-11-08 订阅/主动接口真实联调补充：真实 Bearer 读取主动 profile 和规则成功（`enabled=false`、规则数 `0`）。订阅配置请求返回 HTTP 200、配置包含 `2` 个 Product ID，但 StoreKit 在当前 Simulator 返回 `0` 个可用自动续订商品；失败归类为 App Store Connect/StoreKit 商品环境或商品配置联调，不是客户端商品筛选逻辑单独失败。随机设备 DELETE 返回成功；锁屏送达、APNs token、真实购买和额度账本仍未验收。

2026-11-08 自定义角色真实联调补充：在同一台已登录 iPhone 17 Pro Max Simulator 上通过仅 Debug 的临时启动参数调用现有客户端 API，完成 `list → create → versioned update/disable → list 验证 → delete`；运行日志为 `CAOBAO_E2E_CHARACTER success ... version=2 delete=deleted`。探针代码已撤销且未进入产品包；本证据只覆盖基础 CRUD，不覆盖角色绑定对话、版本冲突、多设备墓碑或群聊。

签名门禁记录：项目的 iOS Debug/Release `DEVELOPMENT_TEAM` 仍为空，`security find-identity -v -p codesigning` 返回 `0 valid identities found`；因此 Apple Sign In、APNs 和正式 archive/TestFlight 不能在当前环境完成。归类为发布签名环境阻塞，不写入猜测的 Team ID 或证书信息。

服务端需要处理的接口、幂等、owner 隔离和生产门禁见 [SERVER_ACCEPTANCE_REQUIREMENTS_2026-11-07.md](SERVER_ACCEPTANCE_REQUIREMENTS_2026-11-07.md)。

## 当前已通过

| 功能 | 结果 | 证据 | 备注 |
| --- | --- | --- | --- |
| 本地核心回归 | 通过（当前 checkout 重跑） | `Scripts/test-assistant.sh`；`/tmp/caobao-acceptance-regression-20261108.log`；末尾 `All 168 actual ChatViewModel integration suites passed`、`EXIT=0` | 修复安静时段成熟提醒继承后，原有 18 套、528 个独立组保持 `exitCode: 0`，并新增 8 条 `AssistantDeepLink` 路由边界检查；覆盖协议、同步、媒体、提醒、删除、备份和 ChatViewModel；使用隔离文件、mock 网络和 fake 通知，不代表生产联调 |
| 生产流式错误提示 | 通过（客户端） | `AssistantProtocol.swift`、中英文资源、`4ea0f26`、`5b7c09e`；`test-assistant-protocol.sh`、`test-assistant-localization.sh` | `PLATFORM_FUNDING_UNAVAILABLE`、`UPSTREAM_UNAVAILABLE`、`QUOTA_EXCEEDED` 现在映射为可操作的中英文提示，未知错误仍保留安全错误码；覆盖协议归一化和本地化回归。 |
| iOS/macOS Debug 构建 | 通过 | `Scripts/build-simulator.sh`、`xcodebuild -scheme Caobao-macOS -sdk macosx`；2026-11-07 | iOS Simulator 脚本和 macOS target 均返回 `** BUILD SUCCEEDED **`；构建未使用正式签名，因此不替代真机 archive/TestFlight 门禁 |
| 代码卫生 | 通过 | `git diff --check` | 本轮修复、测试和构建完成后检查通过；提交后再确认工作树和 commit |
| CN 平台对话 | 通过（服务端资金池修复后再次复测） | iPhone 17 Pro Max Simulator，签名包；生产 `https://ciyuan2api.com`；`xcrun simctl launch --console-pty` 逐事件日志 | 2026-11-08 发送 `: e2e raw sse acceptance` 后收到 `generation(gen_RjPZPiVVMeACCO53KmrfMg)`、多条 `delta(...)`、`usage`、`completed`；UI 将 assistant 消息标记 `completed`，本地归档保存 `generationId`/`requestId`/token usage；未出现 `INTERNAL_ERROR`、`UPSTREAM_UNAVAILABLE` 或 `PLATFORM_FUNDING_UNAVAILABLE`。此前 `: ping` 验收曾记录额度 `6/8 → 5/8`；本轮重点确认生产资金池修复后的真实 SSE 完整链路。逐事件日志来自仅 Debug 的临时 trace，验证后已撤销，不进入产品代码。 |
| 任务基础 CRUD | 通过 | iPhone Simulator | 创建 `QA task`、完成/重开入口和编辑/删除入口可用；测试任务暂保留，未确认不可逆删除 |
| 四 Tab 导航 | 通过 | `ContentView.swift` + Simulator | 首页、对话、任务、我的可进入 |
| 模型设置统一入口 | 通过 | iPhone 17 Pro Max Simulator，最新签名构建 | 设置页不再展示只写入无效 `selectedModel` 的旧静态列表；仅保留助理设置入口，区域、平台模型、BYOK 和首页使用同一状态源 |
| 本地备份导出/导入 | 本地协议与恢复链路通过；真实文件供应商/真机未验收 | 客户端独立测试脚本 | 导出 35 组、导入解析 29 组、文件读取 6 组、恢复 ViewModel 15 组全部通过；覆盖 owner 隔离、版本/字段校验、重复恢复、权限中和、图片与工具提案降权、SQL/工作区失败回滚和取消。仍需真实 iPhone/iPad 文件选择器、多图片大文件和跨设备恢复验收；本地备份不等于云同步。 |
| 核心工作区本地化 | 通过（核心页面） | `Caobao/en.lproj/Localizable.strings`、`Caobao/zh-Hans.lproj/Localizable.strings`；核心静态键扫描 `missing static keys: 0`；`Scripts/test-assistant-localization.sh`（19 组）；`c67acc3`、`23ac9e6` | 主动更新、任务规则、设置、账号、订阅、通用状态和 macOS 工作区缺失的英文资源已补齐；首页产品名误写已修正为“草包”。旧工具页面仍有既存中文文案，继续作为二级工具维护，不阻塞首发核心页面验收。 |
| Dynamic Type 登录布局 | 通过（Simulator） | iPad Pro 13-inch Simulator `content_size=accessibility-extra-extra-large`；`.build/verification/ipad13-dynamic-type-fixed-20261107.png`；`53cb592` | 大字体下能力入口改为纵向排列，避免 `Personal`、`Multilingual` 等英文单词被断词；普通字体继续横向排列。VoiceOver 焦点顺序、真实 iPad 和其他页面的大字体仍需验收。 |
| Apple 撤销通知处理与敏感日志清理 | 客户端修复通过 | `Caobao/CaobaoApp.swift`、`Caobao/Services/APIService.swift`、`Caobao/Views/QuoteView.swift`、`Caobao/Views/FavoritesView.swift`；`416f716`；macOS Debug/iOS signed build | macOS 已补齐 `credentialRevokedNotification` 的退出处理；旧 legacy Apple/删除接口、兼容流式接口、图片分析和金句/收藏入口不再打印原始认证响应、对话内容、图片链接、用户内容或 token 前缀。真实 Apple 授权、刷新和撤销仍需真账号验收 |
| 音频播放器生命周期 | 客户端修复通过 | `Caobao/Views/AudioPlayerView.swift`；签名 iOS/macOS Debug build | 播放结束通知和 periodic time observer 都保存 token，并在离开页面时移除，避免重复进入消息页累积 observer。 |
| macOS 首页导航与侧栏无障碍 | 客户端修复通过；真实 UI 未验收 | `Caobao/Views/MacContentView.swift`；macOS Debug build | 首页开始对话/查看任务现在真正切换工作区；侧栏入口改为 Button，支持键盘和 VoiceOver 语义并扩大点击区域。个人页已挂载历史、记忆、订阅、助理设置、自定义角色和账号与数据入口；真实 macOS VoiceOver、Dynamic Type、账号删除和订阅闭环仍未验收。 |
| 账号删除后的本地同步清理 | 客户端修复通过 | `Caobao/Services/AuthService.swift`、`Caobao/Views/AssistantWorkspaceViews.swift`；删除/同步测试；`f98f486` | 账号删除会清理记忆、会话、任务同步游标及待删除队列，同时清理本机收藏、主动模式配置和主动更新的已读/稍后状态，避免旧账号同步状态或本地状态残留。 |
| 冷启动通知路由 | 客户端修复通过；真实锁屏点击未验收 | `Caobao/Services/AssistantNotificationRouter.swift`、`AssistantWorkspaceViews.swift`；签名 iOS Simulator build | 通知回调先保留 owner-bound route，等待认证恢复后再校验；任务页在登录账号云同步失败时保留待处理任务 ID，只有同步成功后才把缺失任务判为删除，避免临时网络故障丢失深链。真实 APNs 锁屏点击和生产深链仍需验收。 |
| 客户端协议与隔离回归 | 通过 | 多个 `Scripts/test-assistant-*.sh` | Apple 身份 17 套、权益 14 套、设备注册、媒体 12 套、记忆同步 3 套、会话同步均通过；使用 mock HTTP/隔离数据，不替代真实设备验收 |
| macOS 图片/音视频表面 | 客户端构建通过；真实媒体未验收 | `AnalyzeView.swift`、`MessageBubble.swift`、`AudioPlayerView.swift`；iOS/macOS Debug build | macOS 图片分析现在接入文件选择器，视频和音频使用真实播放器；真实 URL、权限、网络失败和大文件仍需设备验收。远程媒体默认仍关闭，避免把不可信回复中的 URL 自动拉取。 |
| 法律文档离线降级 | 客户端修复通过；真实断网 UI 未验收 | `LegalView.swift`、`WebView.swift`；iOS/macOS Debug build | WebView 现在回调加载失败，法律页在协议、隐私、未成年人保护和 AI 声明页面显示本地内容，并提供重新加载入口；此前 `webURL` 永远非空且失败回调缺失，离线文案不可达。真实断网、服务器 5xx 和文案版本仍需设备验收。 |

## 失败或未完成项

| 功能 | 当前状态 | 责任归类 | 原因/下一步 |
| --- | --- | --- | --- |
| 我的收藏 | 客户端已降级为 owner-scoped 本机金句收藏；在线收藏仍失败 | **客户端已处理；服务端待定** | 生产 `GET /api/favorites` 和 `GET /api/sync/favorites` 均返回 HTTP 404；客户端入口已改为明确的“本机金句收藏”，可查看和删除，并按账号隔离，不再调用必失败的在线接口。若需要跨设备收藏，服务端仍需补 owner-scoped v2 API、认证和删除墓碑。 |
| 数据统计 | 通过 | **客户端** | 新增 owner-scoped `AssistantUsageStatsStore`；仅成功完成的非空回答计数，取消/失败不计数，重试按 message ID 幂等，账号隔离。真实 Simulator 发送后详细页显示累计发送 1、我的消息 1、AI 回复 1、今日/周/月各 2；安装最新构建后“我的”概览同步显示对话 1、使用 1 天、连续 1 天。 |
| Apple 登录全生命周期 | 未验收；客户端入口已运行时通过 | 服务端 + 系统环境 + 正式签名 | 当前签名 QA19 Simulator 勾选协议后点击“通过 Apple 登录”，成功弹出系统“登录 Apple 账户 / 需要在‘设置’中登录 Apple 账户”提示，证明客户端入口和 `ASAuthorization` 调用链可达；因 Simulator 未登录 Apple 账户，未继续输入凭据。iOS/macOS 已有撤销通知处理、nonce/state/JWT/授权码和 Keychain 会话逻辑；源码 entitlement 含 Apple Sign In、APNs 和 Associated Domains，但当前 `DEVELOPMENT_TEAM` 为空的 Simulator 签名实际嵌入空 entitlement；构建脚本现已明确提示“real-device archive signing still required”（`build-simulator.sh`）。仍未完成真实授权、刷新、退出、撤销及真实 Bearer 验证。 |
| StoreKit 订阅 | 未验收；服务端配置可读但 StoreKit 无可用商品 | 服务端 + App Store Connect + 客户端 | 真实 Bearer 请求 `subscriptions/apple/config` 返回 HTTP 200 且含 2 个 Product ID；当前签名 Simulator 的 StoreKit 返回 0 个可用自动续订商品，页面显示“订阅暂不可用”。客户端不硬编码 Product ID，筛选和账号绑定逻辑已通过本地测试；仍需 App Store Connect/StoreKit 商品、真机购买、恢复、退款、撤销和额度账本闭环。 |
| APNs/系统提醒 | 未验收；设备注销真实接口已通过 | 服务端 Worker/APNs + 客户端 | 真实 Bearer 对随机设备 ID 调用 `DELETE /api/v2/devices/{deviceId}` 返回成功，证明注销 handler 已挂载；客户端登出会使用旧 access token best-effort 调用该接口，只读取已有设备 ID，不会在退出时新建 Keychain 设备记录；网络失败不阻塞退出（`603462a`、`6795f73`）。真实已注册设备、旧 owner 失效、outbox 清理、锁屏送达、点击深链和安静时段生产行为仍未验证。 |
| 图片 | 部分通过 | 客户端 + 上游 | 图片入口和本地预处理测试通过；未在真实账号下发送图片并验证生产上游能力。 |
| 语音输入/朗读 | iPhone/macOS 客户端入口已实现，真实设备未验收 | 客户端/系统权限 | `AssistantSpeechController` 已覆盖 iOS/macOS 权限、locale、设备端识别回退、60 秒上限、账号切换、中断和 TTS 8,000 字上限；`MacChatView` 已加入麦克风、停止和朗读入口，macOS Debug build 通过。尚未在真实 iPhone/macOS 麦克风环境完成授权、录音、识别和朗读验收，正式包仍需检查 Speech/Microphone 权限和签名。 |
| 会话/任务/记忆云同步 | 未验收；客户端协议已具备，生产闭环未证实 | 服务端 + 客户端联调 | 客户端已有 owner-scoped 会话 change feed pull、全量回填、消息合并、删除队列和 tombstone 提交；记忆同步支持版本/墓碑；任务页当前只把本地独有任务 POST 到云端，已有云任务的本地编辑/状态变更暂不自动 PATCH（本地没有持久化 server version，避免无版本覆盖）。`syncToCloud` 仍只负责记忆上行，会话消息由对话接口写入。生产未认证探针显示 `/api/v2/sync/conversations`、`/api/v2/conversations/changes`、`/api/v2/conversations` 均返回 401，说明路由已挂载，但尚未用两个真实账号/设备验证增量、冲突、删除墓碑和账号切换闭环。 |
| 记忆授权字段兼容 | 客户端已做兼容；服务端仍需修复 | **客户端 + 服务端协议** | 本地策略把 `confirmed` 和 `explicit` 都视为已授权；当前客户端平台请求把 `confirmed` 规范化为 `explicit`，避免现有 bridge 静默丢失已确认记忆，并有 ChatViewModel 回归覆盖。服务端 bridge 仍需正式接受 `confirmed`，否则其他客户端或旧版本仍会丢上下文。 |
| 云任务编辑、状态和审批 | 未完成 | **客户端 + 服务端协议** | 客户端没有持久化云端 `version`，已有云任务的编辑/状态变化不会安全 PATCH；`waiting_approval`、`failed`、`running`、`draft` 目前会被压成 active，客户端也没有云端审批调用。需要补 `version`/条件 PATCH、状态枚举映射、`/approve` 闭环、幂等和冲突 UI，再做双设备验收。 |
| 主动更新 | 客户端版本/幂等已补；仍未完成服务端闭环 | **客户端 + 服务端** | 当前签名 Simulator 已打开主动更新页，开关从关闭切换到开启再恢复关闭；频率选择、未读数量、下一次运行、陪伴模式和每日上限入口均可见。二轮 UI 验收实际启用安静时段并保存，页面显示“安静时段已启用”，随后关闭并保存恢复原状态。此前已验证暂停/恢复全部、运行记录的查看/稍后、本机已读状态及通知关联对话回流；客户端现已把服务端会话 ID 解析为本地会话 ID，且兼容服务端返回的 `readAt`、`snoozedUntil`、`dismissedAt`，旧部署仍回退 owner-scoped 本机状态（`5dc27bf`）。Profile 更新现在携带并持久化服务端 `expectedVersion`，规则运行失败重试复用 owner/rule 级幂等键，避免重复执行。服务端关闭此类、阅读/稍后多设备写入、生产 Worker/APNs 和真实冲突验收仍未完成。服务端还需在 logout/换账号时失效旧账号的 APNs 设备绑定，避免旧账号推送落到新账号设备。 |
| 自定义角色 | 基础真实 CRUD 通过；角色聊天接入、冲突和跨设备仍未完成 | **客户端 + 服务端联调** | 客户端已将记忆范围从错误的 `private/workspace` 对齐为服务端接受的 `none/character/group`，默认使用 `character`，避免新建角色必然收到 400。2026-11-08 已在已登录 Simulator 完成 owner-scoped list/create/versioned update-disable/list 验证/delete 墓碑，且已撤销仅 Debug 探针；UI 也已确认名称、头像、简介、语言、启用、行为提示、问候语和记忆范围控件存在。仍需真实版本冲突、多设备墓碑和账号切换验收；角色尚未接入对话请求，需新增 `characterId/version` 与服务端提示词、记忆范围协议。 |
| AI 群聊 | 未实现 | **客户端 + 服务端新增** | 当前代码没有群聊参与者、编排、speaker/turn 模型或 SSE；不能用现有 personaLevel 代替。 |
| macOS/iPad 信息架构 | macOS 核心导航、历史和“我的”已补齐；iPad 模拟器布局通过，真机和辅助功能仍未验收 | **客户端 UI** | macOS 侧栏现在保留首页、对话、任务、历史、我的和工作区，旧工具统一进入“工具模板”，最近对话常驻侧栏；历史页支持本地搜索并回到对话，个人页显示账号/统计并提供记忆、订阅和设置入口。最新 iPad Pro 11-inch (M5) Simulator 签名包已启动并显示侧栏、首页、主动更新、任务、工作区、订阅、设置、主 CTA 和四个快速模板；截图 `.build/verification/ipad-acceptance-20261107.png`。真实 iPad 触控、VoiceOver、Dynamic Type、订阅和账号闭环仍需验收。 |
| iPhone Duo、真机/TestFlight | 未验收 | 发布环境 | 当前普通 Simulator 不能证明 Duo 专用设备、正式签名归档、TestFlight 安装和系统级行为。 |
| macOS 详细统计/关于/官方页 | 客户端页面已补；真实 UI/内容验收未完成 | **客户端 UI** | macOS “我的”现在提供详细统计、完整关于页（版本、核心能力、隐私控制、法律/支持）和完整官方信息页（理念、产品矩阵、联系方式）；详细统计读取 owner-scoped 本机完成对话计数。真实 VoiceOver、内容审校和与 iOS 视觉完全一致仍需验收；`75c6765`，macOS Debug build 通过。 |
| macOS 对话图片/任务提案 | 任务提案流程和本地图片选择已补；真实上传/交互未验收 | **客户端 macOS parity** | `MacChatView` 现在复用统一消息气泡，显示本地图片附件、朗读入口，提供 security-scoped 图片文件选择、缩略图移除，并在后台读取文件后接入任务提案查看、编辑确认、拒绝和一次性继续请求。多图预处理、真实上传、权限和大文件仍需设备验收。 |
| 图片保存权限 | 客户端修复；真实设备未验收 | **客户端配置** | `UIImageWriteToSavedPhotosAlbum` 需要写入权限说明；已在 `Info.plist` 增加 `NSPhotoLibraryAddUsageDescription`。真实相册授权、保存失败和取消流程仍需设备验收。 |
| Universal Links | 客户端路由已补；AASA 配置不合格、真机未验收 | **客户端 + 服务端发布配置** | `CaobaoApp` 现在解析 `https://caobao.chat/conversation/{id}`、`/task/{id}`、`/proactive/{runId}`，支持登录延迟消费、owner 绑定和 iOS/macOS 路由。2026-11-08 实测 AASA 返回 200，但 `appIDs` 为空且只声明旧的 `/chat/*`、`/morning` 等路径，未覆盖三类新路由；服务端需先修 AASA，再做正式 Associated Domains 签名和真机点击验收。 |
| 旧设置状态 | 客户端已修复；真实账号切换未验收 | **客户端状态整合** | 旧 `SettingsView` 已移除无消费者的 `voiceEnabled` 开关，毒舌程度只读写 owner-scoped `appState.userSettings`，避免与旧 `UserDefaults` 键分裂。真实账号切换和服务端 persona 偏好仍需验收。 |
| 游客升级 | 死链 | **客户端产品/认证** | `AuthService` 的 `canUpgrade` 永远为 false，游客升级区和升级弹窗无法到达；需要重新接通游客转 Apple 账号，或删除误导入口。 |
| 反馈提交 | 未验收 | **客户端 + 服务端协议** | `FeedbackView` 仍调用旧 `/feedback` 且未带 Bearer；当前只能证明表单可达，不能证明生产提交成功。应迁移到 owner-scoped 认证接口或明确支持匿名反馈后再验收。 |
| 远程媒体与举报 | 默认关闭/未验收 | **客户端接线 + 服务端协议** | `MessageBubble` 的举报和远程音视频路径由 `allowsReporting/allowsRemoteMedia` 控制，现有聊天/历史调用未显式开启；媒体默认关闭是安全策略，举报若保留需补认证接口和真实提交验收。 |
| 旧收藏/旧工具协议 | 二级兼容面未验收 | **客户端清理 + 服务端兼容** | `FavoritesView` 和 `FeaturesView` 仍有旧 `/api` 方法定义，但核心入口已转本机收藏和 Assistant v2；旧页面应删除或标明兼容范围，不能把静态方法当作可用功能。 |

## 未纳入首发或未挂载的客户端表面

- **watchOS**：当前工程有独立 watchOS target，但仍使用旧的 `/api` 运势/早报/吐槽/决策接口，没有 Bearer、owner 隔离或云同步；本轮 `xcodebuild -scheme Caobao-watchOS -sdk watchsimulator` 还因 `Multiple commands produce .../Caobao-watchOS.app/Caobao-watchOS` 失败。按产品计划暂不纳入首发；若恢复该范围，责任归类为客户端 watchOS 重做 + target 构建修复 + 服务端认证兼容，不能把现有 target 当作已完成。
- **WidgetKit**：`CaobaoWidgets/CaobaoWidget.swift` 有实现文件，但工程没有 Widget target 引用，当前不可构建；若需要桌面/锁屏小组件，责任归类为客户端工程接入、签名和深链验收。
- **Optimized/**：其中的 Dynamic Island、Siri、推送管理、分享和图片上传等 Swift 文件没有加入 Xcode target；它们是未挂载代码，不能计入已完成功能。产品需要时应逐项接入并补真实系统验收，否则作为待清理的死代码。
- **HapticManager**：虽然已加入 iOS target，但全仓没有调用点；当前不能把触觉反馈计入已完成能力。需要时接入消息发送、任务完成等明确交互，否则清理死代码。
- **旧 APIService 方法**：旧收藏、旧聊天流、旧设置和旧云同步方法目前只有定义，没有核心页面调用；当前产品以 `Assistant*` v2 客户端为准。旧接口应标记兼容范围或删除，不能用静态方法存在证明功能完成。
- **macOS 设置差异**：当前 `AssistantMacPreferencesView` 只覆盖语言、风格和服务区域；语音、通知/安静时段、主动模式、BYOK 和数据管理仍通过工作区入口分散提供。若要求与 iOS 完全同构，归类为客户端补齐；否则保留平台化设置并在产品说明中明确范围。
- **官方页标签**：已修复“开发中”标签条件错误，改为显式 `isComingSoon`，并通过 iOS/macOS 构建验证。

## 功能去处与新增

- 运势、晨报、晚报、吐槽、决策、金句、收藏、统计和反馈保留为二级工具/设置入口，不继续扩充一级导航。
- 自定义角色管理页面已补齐，仍需真实账号验证 `/api/v2/characters` 的 CRUD、版本冲突和墓碑同步；AI 群聊是新的跨端功能，必须先补服务端协议、参与者/轮次模型、幂等和执行历史，再接客户端 UI。
- 主动更新已补暂停/恢复全部、首页未读数/下一次运行、本机查看/稍后和通知点击回流；来源解释使用现有 `triggerReason/sourceRefs`。本机已读/稍后不宣称跨设备同步；服务端仍需提供阅读/稍后状态、关闭此类接口和生产 Worker/APNs。

## 下一轮验收顺序

1. 若要跨设备收藏，服务端补 owner-scoped v2 API（含认证、删除墓碑和同步）；当前客户端已明确使用本机金句收藏，不阻塞其他验收。
2. 在真实账号和真实设备上验收 Apple、StoreKit、APNs、图片/语音、双设备同步（会话 change feed、记忆 change feed、任务 change feed、删除墓碑）、账号删除和 TestFlight。
3. 完善主动更新剩余交互，完成真实角色 CRUD 验收，再实现 AI 群聊协议/编排。
