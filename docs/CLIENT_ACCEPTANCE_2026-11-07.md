# 草包客户端验收记录（2026-11-07）

本记录只记录当前 checkout 和当前 Simulator 的证据。历史文档、单元测试或代码存在不能替代真实账号、系统权限、生产推送和多设备验收。

服务端需要处理的接口、幂等、owner 隔离和生产门禁见 [SERVER_ACCEPTANCE_REQUIREMENTS_2026-11-07.md](SERVER_ACCEPTANCE_REQUIREMENTS_2026-11-07.md)。

## 当前已通过

| 功能 | 结果 | 证据 | 备注 |
| --- | --- | --- | --- |
| 本地核心回归 | 通过 | `Scripts/test-assistant.sh`，`.build/verification/summary.json` | 18 套、528 个独立组、`exitCode: 0`；使用隔离文件、mock 网络和 fake 通知，不代表生产联调 |
| 代码卫生 | 通过 | `git diff --check` | 本轮修复、测试和构建完成后检查通过；提交后再确认工作树和 commit |
| CN 平台对话 | 通过 | iPhone 17 Pro Max Simulator，CN 模式 | 资金池修复后连续消息成功返回；额度从 `8/8` 变为 `7/8` 再到 `6/8`；无 `INTERNAL_ERROR`/`UPSTREAM_UNAVAILABLE` |
| 任务基础 CRUD | 通过 | iPhone Simulator | 创建 `QA task`、完成/重开入口和编辑/删除入口可用；测试任务暂保留，未确认不可逆删除 |
| 四 Tab 导航 | 通过 | `ContentView.swift` + Simulator | 首页、对话、任务、我的可进入 |
| 模型设置统一入口 | 通过 | iPhone 17 Pro Max Simulator，最新签名构建 | 设置页不再展示只写入无效 `selectedModel` 的旧静态列表；仅保留助理设置入口，区域、平台模型、BYOK 和首页使用同一状态源 |
| 本轮新增界面本地化 | 通过（新增入口） | `Caobao/en.lproj/Localizable.strings`、`Caobao/zh-Hans.lproj/Localizable.strings`；`Scripts/test-assistant-localization.sh`；全新 QA19 Simulator 启动截图 | 主动更新、暂停/恢复、运行记录、自定义角色、macOS 工具模板、本机收藏和对话切换提示已补齐中英文资源；系统原生 Apple 登录按钮随系统语言显示；历史工具仍有既存中文文案，未在本轮扩展范围内 |
| Apple 撤销通知处理与敏感日志清理 | 客户端修复通过 | `Caobao/CaobaoApp.swift`、`Caobao/Services/APIService.swift`；macOS Debug build | macOS 已补齐 `credentialRevokedNotification` 的退出处理；旧 legacy Apple/删除接口和兼容流式接口不再打印原始认证响应、对话内容或 token 前缀。真实 Apple 授权、刷新和撤销仍需真账号验收 |
| 音频播放器生命周期 | 客户端修复通过 | `Caobao/Views/AudioPlayerView.swift`；签名 iOS/macOS Debug build | 播放结束通知和 periodic time observer 都保存 token，并在离开页面时移除，避免重复进入消息页累积 observer。 |
| macOS 首页导航与侧栏无障碍 | 客户端修复通过；真实 UI 未验收 | `Caobao/Views/MacContentView.swift`；macOS Debug build | 首页开始对话/查看任务现在真正切换工作区；侧栏入口改为 Button，支持键盘和 VoiceOver 语义并扩大点击区域。真实 macOS VoiceOver、Dynamic Type 和订阅/账号占位页仍未验收。 |
| 账号删除后的本地同步清理 | 客户端修复通过 | `Caobao/Services/AuthService.swift`；删除/同步测试 | 账号删除会清理记忆同步游标和本机收藏，避免旧账号同步状态或本地收藏残留。 |
| 客户端协议与隔离回归 | 通过 | 多个 `Scripts/test-assistant-*.sh` | Apple 身份 17 套、权益 14 套、设备注册、媒体 12 套、记忆同步 3 套、会话同步均通过；使用 mock HTTP/隔离数据，不替代真实设备验收 |

## 失败或未完成项

| 功能 | 当前状态 | 责任归类 | 原因/下一步 |
| --- | --- | --- | --- |
| 我的收藏 | 客户端已降级为 owner-scoped 本机金句收藏；在线收藏仍失败 | **客户端已处理；服务端待定** | 生产 `GET /api/favorites` 和 `GET /api/sync/favorites` 均返回 HTTP 404；客户端入口已改为明确的“本机金句收藏”，可查看和删除，并按账号隔离，不再调用必失败的在线接口。若需要跨设备收藏，服务端仍需补 owner-scoped v2 API、认证和删除墓碑。 |
| 数据统计 | 通过 | **客户端** | 新增 owner-scoped `AssistantUsageStatsStore`；仅成功完成的非空回答计数，取消/失败不计数，重试按 message ID 幂等，账号隔离。真实 Simulator 发送后详细页显示累计发送 1、我的消息 1、AI 回复 1、今日/周/月各 2；安装最新构建后“我的”概览同步显示对话 1、使用 1 天、连续 1 天。 |
| Apple 登录全生命周期 | 未验收；客户端撤销处理已补 | 服务端 + 系统环境 | iOS/macOS 已有撤销通知处理、nonce/state/JWT/授权码和 Keychain 会话逻辑；仍未完成真实授权、刷新、退出、撤销及真实 Bearer 验证。 |
| StoreKit 订阅 | 未验收；Simulator 页面可进入 | 服务端 + App Store Connect + 客户端 | 真实 Simulator 已进入订阅页，显示“订阅暂不可用”和“当前 App Store 地区暂无可购买的订阅商品”；客户端入口、恢复购买和管理入口存在，但尚未配置/验证真实商品、购买、恢复、退款、撤销和额度账本闭环。当前失败归因于服务端商品配置/App Store Connect 环境，不能据此判定客户端购买流程通过。 |
| APNs/系统提醒 | 未验收 | 服务端 Worker/APNs + 客户端 | 本地提醒策略和协议测试通过；未验证真实 token、锁屏送达、点击深链、服务端 outbox、安静时段生产行为。 |
| 图片 | 部分通过 | 客户端 + 上游 | 图片入口和本地预处理测试通过；未在真实账号下发送图片并验证生产上游能力。 |
| 语音输入/朗读 | iPhone 路径已实现，真实设备未验收 | 客户端/系统权限 | `AssistantSpeechController` 已覆盖权限、locale、设备端识别回退、60 秒上限、账号切换、中断和 TTS 8,000 字上限；未真实录音、识别或朗读。macOS 目前是明确 no-op，若纳入 macOS 首发需新增原生音频入口。 |
| 会话/任务/记忆云同步 | 未验收；客户端协议已具备，生产闭环未证实 | 服务端 + 客户端联调 | 客户端已有 owner-scoped 会话 change feed pull、全量回填、消息合并、删除队列和 tombstone 提交；`syncToCloud` 仍只负责记忆上行，会话消息由对话接口写入。生产未认证探针显示 `/api/v2/sync/conversations`、`/api/v2/conversations/changes`、`/api/v2/conversations` 均返回 401，说明路由已挂载，但尚未用两个真实账号/设备验证增量、冲突、删除墓碑和账号切换闭环。 |
| 主动更新 | 部分补齐，仍未完成 | **客户端 + 服务端** | 已在 iPhone 17 Pro Max Simulator 实际显示并验证暂停/恢复全部、首页未读数和下一次排程、运行记录的查看/稍后、本机已读状态及通知关联对话回流；客户端现已把服务端会话 ID 解析为本地会话 ID，避免点击后找不到对话。本机状态明确不冒充多设备同步。仍缺服务端阅读/稍后字段、关闭此类接口、多设备未读闭环和生产 Worker/APNs 验收。 |
| 自定义角色 | 客户端已补 UI，待真实认证/API 验收 | **客户端 + 服务端联调** | 已在 iPhone 17 Pro Max Simulator 实际进入角色入口和新建编辑器，支持 owner-scoped 角色列表、新建/编辑/启用/删除和版本墓碑处理，复用 `/api/v2/characters`；公网未认证只能证明路由返回 401，尚未用真实账号完成 CRUD 闭环。 |
| AI 群聊 | 未实现 | **客户端 + 服务端新增** | 当前代码没有群聊参与者、编排、speaker/turn 模型或 SSE；不能用现有 personaLevel 代替。 |
| macOS/iPad 信息架构 | macOS 核心导航已修复；iPad/真机仍未验收 | **客户端 UI** | macOS 侧栏现在只保留首页、对话、任务和工作区，旧工具统一进入“工具模板”，最近对话常驻侧栏；首页导航和侧栏无障碍控件已修复，但订阅/账号仍有后续占位页。iPad 的实际布局与 VoiceOver/Dynamic Type 仍需设备验收。 |
| iPhone Duo、真机/TestFlight | 未验收 | 发布环境 | 当前普通 Simulator 不能证明 Duo 专用设备、正式签名归档、TestFlight 安装和系统级行为。 |

## 功能去处与新增

- 运势、晨报、晚报、吐槽、决策、金句、收藏、统计和反馈保留为二级工具/设置入口，不继续扩充一级导航。
- 自定义角色管理页面已补齐，仍需真实账号验证 `/api/v2/characters` 的 CRUD、版本冲突和墓碑同步；AI 群聊是新的跨端功能，必须先补服务端协议、参与者/轮次模型、幂等和执行历史，再接客户端 UI。
- 主动更新已补暂停/恢复全部、首页未读数/下一次运行、本机查看/稍后和通知点击回流；来源解释使用现有 `triggerReason/sourceRefs`。本机已读/稍后不宣称跨设备同步；服务端仍需提供阅读/稍后状态、关闭此类接口和生产 Worker/APNs。

## 下一轮验收顺序

1. 若要跨设备收藏，服务端补 owner-scoped v2 API（含认证、删除墓碑和同步）；当前客户端已明确使用本机金句收藏，不阻塞其他验收。
2. 在真实账号和真实设备上验收 Apple、StoreKit、APNs、图片/语音、双设备同步（会话 change feed、记忆 change feed、任务 change feed、删除墓碑）、账号删除和 TestFlight。
3. 完善主动更新剩余交互，完成真实角色 CRUD 验收，再实现 AI 群聊协议/编排。
