# 草包客户端验收记录（2026-11-07）

本记录只记录当前 checkout 和当前 Simulator 的证据。历史文档、单元测试或代码存在不能替代真实账号、系统权限、生产推送和多设备验收。

本轮失败记录：第一次 iPad 构建中 Xcode 输出 `BUILD SUCCEEDED`，但脚本验签发现复用 DerivedData 后的 `Assets.car` 为无效密封资源（`sealed resource is missing or invalid`）。隔离旧 DerivedData 后重新构建，签名校验通过；归类为构建缓存/验签环境问题，不是客户端 Swift 功能失败。

本轮 UI 重试记录：同一台 iPad Pro 11-inch 在更新本地化资源后 `simctl io screenshot` 出现纯白画面，但系统日志显示 Caobao 进程和 SwiftUI 场景仍为 running-active、没有崩溃；换用干净的 iPad Pro 13-inch Simulator 后，中英文登录页均正常渲染。当前归类为单台 Simulator 前台/渲染状态问题，iPad 真机仍未验收。

签名门禁记录：项目的 iOS Debug/Release `DEVELOPMENT_TEAM` 仍为空，`security find-identity -v -p codesigning` 返回 `0 valid identities found`；因此 Apple Sign In、APNs 和正式 archive/TestFlight 不能在当前环境完成。归类为发布签名环境阻塞，不写入猜测的 Team ID 或证书信息。

服务端需要处理的接口、幂等、owner 隔离和生产门禁见 [SERVER_ACCEPTANCE_REQUIREMENTS_2026-11-07.md](SERVER_ACCEPTANCE_REQUIREMENTS_2026-11-07.md)。

## 当前已通过

| 功能 | 结果 | 证据 | 备注 |
| --- | --- | --- | --- |
| 本地核心回归 | 通过 | `Scripts/test-assistant.sh`，`.build/verification/summary.json` | 18 套、528 个独立组、`exitCode: 0`；使用隔离文件、mock 网络和 fake 通知，不代表生产联调 |
| 代码卫生 | 通过 | `git diff --check` | 本轮修复、测试和构建完成后检查通过；提交后再确认工作树和 commit |
| CN 平台对话 | 通过（服务端资金池修复后复测） | iPhone 17 Pro Max Simulator，当前签名包；HTTP 200 网络日志；UI 完成态 | 发送 `: ping` 后返回 `pong 🏓`，界面从“正在连接…”进入完成态；额度从 `6/8` 变为 `5/8`；未出现 `INTERNAL_ERROR`/`UPSTREAM_UNAVAILABLE`。原始 SSE 的逐事件日志未持久化，因此 `started/delta/completed` 的 UI/扣额结果已验证，事件序列仍不作为独立日志证据。 |
| 任务基础 CRUD | 通过 | iPhone Simulator | 创建 `QA task`、完成/重开入口和编辑/删除入口可用；测试任务暂保留，未确认不可逆删除 |
| 四 Tab 导航 | 通过 | `ContentView.swift` + Simulator | 首页、对话、任务、我的可进入 |
| 模型设置统一入口 | 通过 | iPhone 17 Pro Max Simulator，最新签名构建 | 设置页不再展示只写入无效 `selectedModel` 的旧静态列表；仅保留助理设置入口，区域、平台模型、BYOK 和首页使用同一状态源 |
| 本地备份导出/导入 | 本地协议与恢复链路通过；真实文件供应商/真机未验收 | 客户端独立测试脚本 | 导出 35 组、导入解析 29 组、文件读取 6 组、恢复 ViewModel 15 组全部通过；覆盖 owner 隔离、版本/字段校验、重复恢复、权限中和、图片与工具提案降权、SQL/工作区失败回滚和取消。仍需真实 iPhone/iPad 文件选择器、多图片大文件和跨设备恢复验收；本地备份不等于云同步。 |
| 本轮新增界面本地化 | 通过（核心首页/登录入口） | `Caobao/en.lproj/Localizable.strings`、`Caobao/zh-Hans.lproj/Localizable.strings`；`Scripts/test-assistant-localization.sh`（19 组）；iPad Pro 13-inch Simulator 中英文启动截图 `.build/verification/ipad13-localization-en-20261107.png`、`.build/verification/ipad13-localization-20261107.png` | 修复首页 CTA、任务副文案、主动更新说明、快速模板提示和记忆同步错误的英文资源（`5eee890`）；中英文登录页已分别显示一致语言。历史工具仍有既存中文文案，未在本轮扩展范围内。 |
| Dynamic Type 登录布局 | 通过（Simulator） | iPad Pro 13-inch Simulator `content_size=accessibility-extra-extra-large`；`.build/verification/ipad13-dynamic-type-fixed-20261107.png`；`53cb592` | 大字体下能力入口改为纵向排列，避免 `Personal`、`Multilingual` 等英文单词被断词；普通字体继续横向排列。VoiceOver 焦点顺序、真实 iPad 和其他页面的大字体仍需验收。 |
| Apple 撤销通知处理与敏感日志清理 | 客户端修复通过 | `Caobao/CaobaoApp.swift`、`Caobao/Services/APIService.swift`、`Caobao/Views/QuoteView.swift`、`Caobao/Views/FavoritesView.swift`；`416f716`；macOS Debug/iOS signed build | macOS 已补齐 `credentialRevokedNotification` 的退出处理；旧 legacy Apple/删除接口、兼容流式接口、图片分析和金句/收藏入口不再打印原始认证响应、对话内容、图片链接、用户内容或 token 前缀。真实 Apple 授权、刷新和撤销仍需真账号验收 |
| 音频播放器生命周期 | 客户端修复通过 | `Caobao/Views/AudioPlayerView.swift`；签名 iOS/macOS Debug build | 播放结束通知和 periodic time observer 都保存 token，并在离开页面时移除，避免重复进入消息页累积 observer。 |
| macOS 首页导航与侧栏无障碍 | 客户端修复通过；真实 UI 未验收 | `Caobao/Views/MacContentView.swift`；macOS Debug build | 首页开始对话/查看任务现在真正切换工作区；侧栏入口改为 Button，支持键盘和 VoiceOver 语义并扩大点击区域。真实 macOS VoiceOver、Dynamic Type 和订阅/账号占位页仍未验收。 |
| 账号删除后的本地同步清理 | 客户端修复通过 | `Caobao/Services/AuthService.swift`、`Caobao/Views/AssistantWorkspaceViews.swift`；删除/同步测试；`f98f486` | 账号删除会清理记忆、会话、任务同步游标及待删除队列，同时清理本机收藏、主动模式配置和主动更新的已读/稍后状态，避免旧账号同步状态或本地状态残留。 |
| 冷启动通知路由 | 客户端修复通过；真实锁屏点击未验收 | `Caobao/Services/AssistantNotificationRouter.swift`；签名 iOS Simulator build | 通知回调先保留 owner-bound route，等待认证恢复后再校验，避免冷启动时过早丢弃任务或主动更新跳转。真实 APNs 锁屏点击和生产深链仍需验收。 |
| 客户端协议与隔离回归 | 通过 | 多个 `Scripts/test-assistant-*.sh` | Apple 身份 17 套、权益 14 套、设备注册、媒体 12 套、记忆同步 3 套、会话同步均通过；使用 mock HTTP/隔离数据，不替代真实设备验收 |

## 失败或未完成项

| 功能 | 当前状态 | 责任归类 | 原因/下一步 |
| --- | --- | --- | --- |
| 我的收藏 | 客户端已降级为 owner-scoped 本机金句收藏；在线收藏仍失败 | **客户端已处理；服务端待定** | 生产 `GET /api/favorites` 和 `GET /api/sync/favorites` 均返回 HTTP 404；客户端入口已改为明确的“本机金句收藏”，可查看和删除，并按账号隔离，不再调用必失败的在线接口。若需要跨设备收藏，服务端仍需补 owner-scoped v2 API、认证和删除墓碑。 |
| 数据统计 | 通过 | **客户端** | 新增 owner-scoped `AssistantUsageStatsStore`；仅成功完成的非空回答计数，取消/失败不计数，重试按 message ID 幂等，账号隔离。真实 Simulator 发送后详细页显示累计发送 1、我的消息 1、AI 回复 1、今日/周/月各 2；安装最新构建后“我的”概览同步显示对话 1、使用 1 天、连续 1 天。 |
| Apple 登录全生命周期 | 未验收；客户端入口已运行时通过 | 服务端 + 系统环境 + 正式签名 | 当前签名 QA19 Simulator 勾选协议后点击“通过 Apple 登录”，成功弹出系统“登录 Apple 账户 / 需要在‘设置’中登录 Apple 账户”提示，证明客户端入口和 `ASAuthorization` 调用链可达；因 Simulator 未登录 Apple 账户，未继续输入凭据。iOS/macOS 已有撤销通知处理、nonce/state/JWT/授权码和 Keychain 会话逻辑；源码 entitlement 含 Apple Sign In、APNs 和 Associated Domains，但当前 `DEVELOPMENT_TEAM` 为空的 Simulator 签名实际嵌入空 entitlement；构建脚本现已明确提示“real-device archive signing still required”（`build-simulator.sh`）。仍未完成真实授权、刷新、退出、撤销及真实 Bearer 验证。 |
| StoreKit 订阅 | 未验收；Simulator 页面可进入 | 服务端 + App Store Connect + 客户端 | 当前签名 Simulator 已进入订阅页并完成商品加载，显示“订阅暂不可用”和“当前 App Store 地区暂无可购买的订阅商品”；客户端不硬编码 Product ID，会读取服务端 `subscriptions/apple/config` 后调用 StoreKit。客户端入口、恢复购买和管理入口存在，但尚未配置/验证真实商品、购买、恢复、退款、撤销和额度账本闭环。当前失败归因于服务端商品配置/App Store Connect 环境，不能据此判定客户端购买流程通过。 |
| APNs/系统提醒 | 未验收；客户端注销调用已补，生产注销路由已挂载 | 服务端 Worker/APNs + 客户端 | 本地提醒策略、设备注册协议和签名 iOS 构建通过；客户端登出现在会使用旧 access token best-effort 调用 `DELETE /api/v2/devices/{deviceId}`，只读取已有设备 ID，不会在退出时新建 Keychain 设备记录；网络失败不阻塞退出（`603462a`、`6795f73`）。2026-11-07 最新无认证探针返回 `401 UNAUTHENTICATED`，证明生产路由已挂载；尚未用真实 token 验证 owner 隔离、幂等禁用和 outbox 清理，也未验证锁屏送达、点击深链、安静时段生产行为。 |
| 图片 | 部分通过 | 客户端 + 上游 | 图片入口和本地预处理测试通过；未在真实账号下发送图片并验证生产上游能力。 |
| 语音输入/朗读 | iPhone 路径已实现，真实设备未验收；macOS 属于后续功能 | 客户端/系统权限 | `AssistantSpeechController` 已覆盖权限、locale、设备端识别回退、60 秒上限、账号切换、中断和 TTS 8,000 字上限；未真实录音、识别或朗读。macOS 当前是明确 no-op，且 `MacChatView` 没有语音入口；完整实现需要原生 `AVFoundation + Speech`、权限/entitlement、桌面 UI 和真实 macOS 权限验收，按 iPhone 首发计划不作为本轮小修。 |
| 会话/任务/记忆云同步 | 未验收；客户端协议已具备，生产闭环未证实 | 服务端 + 客户端联调 | 客户端已有 owner-scoped 会话 change feed pull、全量回填、消息合并、删除队列和 tombstone 提交；`syncToCloud` 仍只负责记忆上行，会话消息由对话接口写入。生产未认证探针显示 `/api/v2/sync/conversations`、`/api/v2/conversations/changes`、`/api/v2/conversations` 均返回 401，说明路由已挂载，但尚未用两个真实账号/设备验证增量、冲突、删除墓碑和账号切换闭环。 |
| 主动更新 | 部分补齐，仍未完成 | **客户端 + 服务端** | 当前签名 Simulator 已打开主动更新页，开关从关闭切换到开启再恢复关闭；频率选择、未读数量、下一次运行、陪伴模式和每日上限入口均可见。此前已验证暂停/恢复全部、运行记录的查看/稍后、本机已读状态及通知关联对话回流；客户端现已把服务端会话 ID 解析为本地会话 ID，且兼容服务端返回的 `readAt`、`snoozedUntil`、`dismissedAt`，旧部署仍回退 owner-scoped 本机状态（`5dc27bf`）。本机状态明确不冒充多设备同步。仍缺服务端关闭此类接口、多设备写入闭环和生产 Worker/APNs 验收。服务端还需在 logout/换账号时失效旧账号的 APNs 设备绑定，避免旧账号推送落到新账号设备。 |
| 自定义角色 | 客户端已补 UI，待真实认证/API 验收 | **客户端 + 服务端联调** | 当前签名 Simulator 已从助理设置进入角色列表和新建编辑器，确认名称、头像、简介、语言、启用、行为提示、问候语和记忆范围控件存在；本次未保存测试角色，避免污染账号。客户端支持 owner-scoped 角色列表、新建/编辑/启用/删除和版本墓碑处理，复用 `/api/v2/characters`；公网未认证只能证明路由返回 401，尚未用真实账号完成 CRUD 闭环。 |
| AI 群聊 | 未实现 | **客户端 + 服务端新增** | 当前代码没有群聊参与者、编排、speaker/turn 模型或 SSE；不能用现有 personaLevel 代替。 |
| macOS/iPad 信息架构 | macOS 核心导航已修复；iPad 模拟器布局通过，真机和辅助功能仍未验收 | **客户端 UI** | macOS 侧栏现在只保留首页、对话、任务和工作区，旧工具统一进入“工具模板”，最近对话常驻侧栏；首页导航和侧栏无障碍控件已修复。最新 iPad Pro 11-inch (M5) Simulator 签名包已启动并显示侧栏、首页、主动更新、任务、工作区、订阅、设置、主 CTA 和四个快速模板；截图 `.build/verification/ipad-acceptance-20261107.png`。真实 iPad 触控、VoiceOver、Dynamic Type、订阅和账号闭环仍需验收。 |
| iPhone Duo、真机/TestFlight | 未验收 | 发布环境 | 当前普通 Simulator 不能证明 Duo 专用设备、正式签名归档、TestFlight 安装和系统级行为。 |

## 功能去处与新增

- 运势、晨报、晚报、吐槽、决策、金句、收藏、统计和反馈保留为二级工具/设置入口，不继续扩充一级导航。
- 自定义角色管理页面已补齐，仍需真实账号验证 `/api/v2/characters` 的 CRUD、版本冲突和墓碑同步；AI 群聊是新的跨端功能，必须先补服务端协议、参与者/轮次模型、幂等和执行历史，再接客户端 UI。
- 主动更新已补暂停/恢复全部、首页未读数/下一次运行、本机查看/稍后和通知点击回流；来源解释使用现有 `triggerReason/sourceRefs`。本机已读/稍后不宣称跨设备同步；服务端仍需提供阅读/稍后状态、关闭此类接口和生产 Worker/APNs。

## 下一轮验收顺序

1. 若要跨设备收藏，服务端补 owner-scoped v2 API（含认证、删除墓碑和同步）；当前客户端已明确使用本机金句收藏，不阻塞其他验收。
2. 在真实账号和真实设备上验收 Apple、StoreKit、APNs、图片/语音、双设备同步（会话 change feed、记忆 change feed、任务 change feed、删除墓碑）、账号删除和 TestFlight。
3. 完善主动更新剩余交互，完成真实角色 CRUD 验收，再实现 AI 群聊协议/编排。
