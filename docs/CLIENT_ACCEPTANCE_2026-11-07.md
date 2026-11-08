# 草包客户端验收记录（2026-11-07）

本记录只记录当前 checkout 和当前 Simulator 的证据。历史文档、单元测试或代码存在不能替代真实账号、系统权限、生产推送和多设备验收。

本轮结论：客户端核心代码、iOS/macOS Debug/Release 编译、本地回归，以及一条真实 CN 对话流已通过；客户端和服务端整体仍不能标记“全部完成”，因为 Apple 真登录、StoreKit 真实商品、APNs/锁屏投递、双设备同步、账号删除服务端清理、主动 Worker 和 TestFlight 仍未通过真实发布门禁。

服务端待修复接口、发布配置和逐项通过标准见 [CLIENT_SERVER_FIX_REQUESTS.md](CLIENT_SERVER_FIX_REQUESTS.md)。

本轮失败记录：第一次 iPad 构建中 Xcode 输出 `BUILD SUCCEEDED`，但脚本验签发现复用 DerivedData 后的 `Assets.car` 为无效密封资源（`sealed resource is missing or invalid`）。隔离旧 DerivedData 后重新构建，签名校验通过；归类为构建缓存/验签环境问题，不是客户端 Swift 功能失败。

本轮 UI 重试记录：同一台 iPad Pro 11-inch 在更新本地化资源后 `simctl io screenshot` 出现纯白画面，但系统日志显示 Caobao 进程和 SwiftUI 场景仍为 running-active、没有崩溃；换用干净的 iPad Pro 13-inch Simulator 后，中英文登录页均正常渲染。当前归类为单台 Simulator 前台/渲染状态问题，iPad 真机仍未验收。

本轮回归失败与修复：2026-11-08 首次完整回归在 `quiet-edit-origin-never-replays-matured` 触发 fatal error，原因是 macOS `UNCalendarNotificationTrigger.nextTriggerDate()` 对已过期的一次性日历组件滚动到未来日期，导致安静时段编辑错误继承已成熟提醒。客户端已在 `ec7e55b` 按任务时区从完整日期组件重建实际 fire date；`AssistantReminderCoordinator` 独立套件随后 88/88 通过，完整回归修复后也已 exit 0。归类为客户端提醒协调器缺陷，已修复。

本轮生产联调补充：为避免 Simulator 无点击自动化能力，使用仅 Debug 的临时启动注入调用现有 `ChatViewModel` 发送路径；第一次注入过早触发客户端配置变更保护，显示“回复、原问题、账号或接入配置已变化”，未扣额度。等待登录权益、归档和区域状态稳定后重试，生产请求成功并完成完整 SSE；注入和 trace 均已撤销，工作树保持干净。

2026-11-08 生产契约探针补充：未携带认证访问 `/api/v2/characters`、`/api/v2/proactive/profile` 和 `/api/v2/proactive/rules` 均返回 `401 UNAUTHENTICATED`，证明路由和认证中间件可达，但不替代真实账号 CRUD/读写验收；`GET /api/v2/feedback` 返回 `404 Invalid URL`，当前没有可供客户端提交的 v2 反馈接口；`GET /api/v2/devices` 返回 `404`，不能据此判断 DELETE。随后用真实 Bearer 对随机设备 ID 执行 `DELETE /api/v2/devices/{deviceId}` 返回成功，证明注销 handler 已挂载；仍需真实已注册设备、旧账号失效和 outbox 清理验收。

2026-11-08 订阅/主动接口真实联调补充：真实 Bearer 读取主动 profile 和规则成功（`enabled=false`、规则数 `0`）。订阅配置请求返回 HTTP 200、配置包含 `2` 个 Product ID，但 StoreKit 在当前 Simulator 返回 `0` 个可用自动续订商品；失败归类为 App Store Connect/StoreKit 商品环境或商品配置联调，不是客户端商品筛选逻辑单独失败。随机设备 DELETE 返回成功；锁屏送达、APNs token、真实购买和额度账本仍未验收。

2026-11-08 自定义角色真实联调补充：在同一台已登录 iPhone 17 Pro Max Simulator 上通过仅 Debug 的临时启动参数调用现有客户端 API，完成 `list → create → versioned update/disable → list 验证 → delete`；运行日志为 `CAOBAO_E2E_CHARACTER success ... version=2 delete=deleted`。探针代码已撤销且未进入产品包；本证据只覆盖基础 CRUD，不覆盖角色绑定对话、版本冲突、多设备墓碑或群聊。

2026-11-08 主动规则真实联调补充：同一真实账号创建一个 7 天后运行的临时 schedule 规则，完成版本更新、列表验证和删除墓碑；运行日志为 `CAOBAO_E2E_PROACTIVE_RULE success version=2 delete=deleted`。规则未执行，探针代码已撤销；本证据只覆盖基础规则 CRUD，不覆盖 Worker、APNs、运行记录状态或多设备阅读/稍后同步。

2026-11-08 云任务真实联调补充：同一真实账号创建一个 7 天后到期的临时任务，完成版本更新、列表验证和删除墓碑；运行日志为 `CAOBAO_E2E_CLOUD_TASK success version=2 delete=deleted`。任务未执行，探针代码已撤销；本证据只覆盖云端任务基础 CRUD，不覆盖已有任务安全编辑、状态枚举、审批、冲突和双设备同步。

2026-11-08 云任务审批协议补充：客户端将 `taskId` 与 Unix 秒级 `nextRunAt` 的规范化 SHA-256 提取为共享函数，并加入固定向量回归；`Scripts/test-assistant-task-tool-protocol.sh` 当前 51 套通过，iOS Simulator 和 macOS Debug 构建均通过。真实 `waiting_approval → approve → Worker 执行` 尚未完成，因此这项证据只证明客户端哈希不会因重构漂移，不证明生产审批已消费。

2026-11-08 云任务状态显示修复：服务端 `draft`、`waiting_approval`、`failed` 和未知状态不再被客户端映射为本地 `active`；`scheduled/running` 保持 active，终态保持原值，其余状态 fail closed 为 paused。102 套本地仓库测试、完整回归（含 168 个 ChatViewModel 套件）和 iOS/macOS 构建均通过；待审批和失败任务仍显示服务端状态标签，但不会进入首页“今天要处理”。

2026-11-08 首页云任务摘要补齐：首页在登录、归档同步完成后以及下拉刷新时读取 owner-scoped 云任务摘要，与本地任务按 ID 去重，只把 `scheduled/running` 映射为“今天要处理”；草稿、待审批、失败和未知状态保持 fail-closed，不会误显示为可执行任务。云端读取失败时保留本地任务，不显示假空态。对应改动为 `HomeView.swift`，iOS Simulator 和 macOS Debug 构建均通过。

2026-11-08 前台恢复补齐：首页从后台回到前台时，在会话同步后重新读取同一 owner 的云任务摘要，避免任务在后台被修改后只能靠冷启动或手动下拉刷新才更新。补丁后 iOS/macOS Debug 构建均返回 `** BUILD SUCCEEDED **`。

2026-11-08 主动工作区状态收口：未登录时暂停全部、添加规则和刷新执行记录按钮现在禁用，并显示登录提示；主动执行记录不再直接显示 `queued/running/completed` 等 raw 状态，改用已有中英文本地化状态文案；macOS 首页主动模式改为显示本地化标题，不再暴露 `important/daily/normal` 原始枚举。归类为客户端 UI/状态反馈修复。

2026-11-08 云记忆真实联调补充：同一真实账号创建一条临时偏好记忆，完成版本更新、列表验证和删除墓碑；运行日志为 `CAOBAO_E2E_CLOUD_MEMORY success version=2 delete=deleted`。探针代码已撤销；本证据只覆盖云记忆基础 CRUD，不覆盖两台设备的增量冲突和账号删除后的服务端清理。

2026-11-08 客户端品牌文案修复：中文首页、登录页、关于页和本地任务通知统一显示“草包”，英文资源继续显示 CaoBao；提醒测试已改为校验当前本地化品牌和通用通知正文。完整回归与 iOS/macOS 构建均通过。

2026-11-08 游客升级入口收口：客户端当前只支持 Apple 正式账号和 BYOK；已删除个人页升级入口、Sheet、Apple 二次登录 UI，以及旧游客升级 API 类型和方法，避免未来误调用无法完成的账号升级流程。若未来支持游客转 Apple，服务端需先定义数据归属迁移、幂等和失败恢复协议。

2026-11-08 反馈入口收口：生产 `/feedback` 返回 404，客户端已停止调用旧接口，反馈表单改为生成系统邮件并打开用户设备的邮件应用；没有邮件应用时显示可复制的官方邮箱。服务端反馈接口暂不阻塞首发客户端。

2026-11-08 内容举报同样改为邮件反馈：消息气泡的举报表单不再调用旧 `/feedback`，改为生成包含原因和截断消息正文的系统邮件；`allowsReporting` 仍默认关闭，避免未授权的举报入口出现在核心对话路径。

2026-11-08 生产配置复核：`https://ciyuan2api.com/api/status` 返回 HTTP 200，版本头仍为 `v1.0.0-rc.48+ciyuan.reconstructed.20261106.1`；`https://caobao.chat/.well-known/apple-app-site-association` 和根路径均返回 HTTP 200，但 `appIDs` 为空且仍只声明旧工具路径，新的 conversation/task/proactive 深链仍不能验收。

2026-11-08 客户端/服务端设备注销契约复核：客户端 `AssistantDeviceRegistrationClient.unregister()` 发送 `DELETE /api/v2/devices/{deviceId}` 并要求 `status=unregistered`；当前 `feat/caobao-server-v2` 路由源码只注册 `POST /api/v2/devices`，未发现 DELETE handler。此前生产对随机设备 ID 的 DELETE 探针返回成功，和 checkout 不一致，不能继续作为通过证据；必须完成 production-versus-branch 比较并确认正式注销响应、旧账号失效和 outbox 清理。归类为服务端发布/契约核对。

2026-11-08 二级图片分析复核：`AnalyzeView` 仍调用旧 `APIService.analyzeImage`，请求 `/api/analyze`，未携带 Bearer、owner 或额度协议；现代聊天图片附件走 Assistant v2，两者不能混为一谈。归类为客户端 + 服务端协议未验收的二级功能，后续迁移到 Assistant v2 或补齐旧接口契约。

2026-11-08 图片分析选图修复：`AnalyzeView` 在已有图片时的“相册”按钮此前只切换未绑定的 `showingImagePicker`，iOS 不会打开系统 PhotosPicker；客户端现将 picker 绑定到页面根部，并统一处理首次选择与更换图片。`db7be41`，iOS Simulator Debug 构建退出 `0`；旧 `/api/analyze` 的认证、owner 和额度协议仍未验收，继续按二级兼容功能记录。
2026-11-08 旧图片分析入口收口：`AnalyzeView` 原先点击“开始分析”会调用生产不存在的 `/api/analyze` 并得到 404；客户端现在改为显示“服务端接口待迁移”，不再发起无效请求，并引导用户在 Assistant v2 对话中添加图片。提交 `390b1d5`；iOS/macOS Debug 构建均明确返回 `BUILD SUCCEEDED`（`/tmp/caobao-legacy-analyze-ios-20261108.log`、`/tmp/caobao-legacy-analyze-macos-20261108.log`）。完整回归随后明确退出 `0`（`/tmp/caobao-final-regression-after-legacy-analyze-20261108.log`，168 个 ChatViewModel 套件通过）。归类为客户端防误导修复；旧功能仍等待服务端迁移，不计入核心图片分析完成。
2026-11-08 旧工具提示本地化收口：新增的“功能暂未启用”“服务端接口待迁移”和旧图片分析迁移说明已加入中英文 Localizable.strings；`Scripts/test-assistant-localization.sh` 明确退出 `0`（19 组），iOS/macOS Debug 构建明确返回 `BUILD SUCCEEDED`（`/tmp/caobao-localized-legacy-image-ios-20261108.log`、`/tmp/caobao-localized-legacy-image-macos-20261108.log`）。

2026-11-08 macOS 图片导入修复：`fileImporter` 返回的安全作用域 URL 现在显式开启访问，读取受控 Data 后构造 `NSImage` 并释放作用域，避免直接 `NSImage(contentsOf:)` 在沙盒下失败。`b029f29`；媒体测试明确退出 `0`，macOS Debug 构建明确退出 `0`。真实大文件、权限拒绝和网络上传仍未验收。

2026-11-08 Apple/订阅/账号专项客户端审计：`Scripts/test-assistant-identity.sh` 明确退出 `0`（17 个身份套件），`Scripts/test-assistant-entitlements.sh` 明确退出 `0`（14 个权益套件）。代码已复核 nonce/state、JWT/授权码原文、刷新 owner 校验、Keychain 会话、撤销、删除状态能力、StoreKit `appAccountToken`、服务器验证后交易 finish 和账号切换取消任务；未发现可独立修复的客户端缺陷。有效签名身份仍为 0，真实 Apple/APNs/TestFlight 未验收；StoreKit 商品为 0，归 App Store Connect/StoreKit 配置和真实账号环境；账号删除服务端清理仍未验收。

2026-11-08 最新 iPhone Simulator 冷启动：将当前 Debug 包安装到 iPhone 17 Pro Max `15AFDF2E-A189-48E0-BD56-DC18BD7AC926`，启动截图 `/tmp/caobao-ui-acceptance-home-20261108.png` 显示登录页、Apple 登录、BYOK 入口和协议入口；进程日志未发现 Caobao crash/fatal。该证据只证明未登录首屏可见性，不能替代 Apple 认证、登录后 Home、真实设备或签名验收。

2026-11-08 macOS Debug 冷启动：当前 `Caobao-macOS.app` 构建明确退出 `0`，实际打开窗口并显示中文登录页、Apple 登录和 BYOK 入口；截图 `/tmp/caobao-macos-ui-smoke-20261108.png`，系统日志未发现 Caobao crash/fatal。该证据只覆盖本机 macOS 未登录首屏，不替代 VoiceOver、Dynamic Type、真实账号、签名和订阅验收。

2026-11-08 Universal Link 实机模拟器探针：从当前 iPhone Simulator 打开 `https://caobao.chat/conversation/conv_acceptance_20261108` 后进入 Safari 的 `caobao.chat` 起始页，没有进入草包 App；截图 `/tmp/caobao-universal-link-login-20261108.png`。客户端路由解析和登录延迟消费已有本地测试，但线上 AASA `appIDs` 为空且未声明 `conversation/*`，本次失败归类为服务端发布配置，不修改客户端路由。

2026-11-08 最终 Release 门禁和 warning 收口：iOS Simulator Release、macOS Release 均重新构建明确退出 `0`。客户端修复了 Swift 6 actor-isolation 警告和首页主动更新无障碍文本的弃用本地化插值；macOS target/plist 补齐 `public.app-category.productivity`，该 warning 消失。剩余 `appintentsmetadataprocessor` “No AppIntents.framework dependency” 仅表示当前没有挂载 AppIntents target，不影响已挂载功能；若产品启用 Siri/App Shortcuts，归类为后续客户端工程接入。

2026-11-08 最终源码统一回归：`Scripts/test-assistant.sh` 在上述 UI/工程修复后明确退出 `0`，末尾为 `All 168 actual ChatViewModel integration suites passed`；该回归仍使用隔离文件、mock 网络和 fake 通知，不替代真实 Apple、StoreKit、APNs、模型请求或双设备生产门禁。

2026-11-08 二级旧工具契约复核：运势、金句、昵称、吐槽、决策、评分、早晚报和旧图片分析仍调用 `/api/caobao/*`、`/api/report/*` 或 `/api/analyze`；当前 `feat/caobao-server-v2` 路由源码只挂载 `/api/v2` 助理契约，未找到这些旧路径。它们继续作为二级/兼容入口，不计入核心完成；若保留，服务端需明确兼容路由，否则客户端应迁移或下线入口。

2026-11-08 冷启动 UI smoke：将最新 iOS Simulator 包安装到已启动的 iPhone 17 Pro Max，启动后截图显示首页主动更新、任务、主 CTA、额度卡和四个一级 Tab，2 分钟日志无 Caobao 崩溃记录。该证据只覆盖 Simulator 冷启动和首屏可见性，不替代真实设备权限、签名和网络验收。

2026-11-08 APNs 账号切换竞态修复：客户端登出/凭证撤销的设备 `DELETE` 可能异步晚于新账号 `POST`，重复登出还可能并发发送多个 DELETE。`AssistantRemoteNotificationCoordinator` 现在串行等待完整注销链后再注册新 owner；设备注册协议套件 5/5 通过，iOS Simulator 构建成功。该修复降低客户端竞态风险，但仍不能替代服务端 owner-scoped DELETE、旧账号失效和 outbox 清理的真实验收。

2026-11-08 回归复跑补充：当前 checkout 的 `Scripts/test-assistant-chat-viewmodel.sh` 明确退出 `0`，168 个 ChatViewModel 集成套件全部通过；`Scripts/test-assistant-task-tool-protocol.sh` 明确退出 `0`（51/51）；`Scripts/test-assistant-repository.sh` 明确退出 `0`（102/102）。这些测试使用隔离文件、fake 通知和 mock 网络，不代表 Apple、StoreKit、APNs 或双设备生产闭环。

2026-11-08 完整回归补充：统一入口 `Scripts/test-assistant.sh` 明确退出 `0`，覆盖 quiet hours、仓库、云同步、设备注册、媒体、提醒、身份、协议、任务工具、备份/导入导出、删除、深链和 ChatViewModel；末尾仍为 168 个 ChatViewModel 集成套件通过。该脚本不执行真实 Apple、StoreKit、APNs 或模型请求。

2026-11-08 客户端独立修复补充：注销与重新登录之间的 APNs 设备 DELETE/POST 现在串行化，重复 logout/revoke 也按链排队，避免旧 owner 的慢 DELETE 在新 owner POST 之后到达并误禁用新 owner 的设备目标；本地设备注册套件退出 `0`，Simulator 构建成功。服务端仍需提供 owner-scoped DELETE、旧 owner 失效和 outbox 清理的真实证据。

2026-11-08 无障碍补充：消息点赞/取消点赞、点踩/取消点踩、删除、视频播放/暂停和 macOS 设置按钮补齐 VoiceOver 标签，并补齐中英文资源；本地化 19/19、deep-link 8/8、entitlements 14/14、iOS/macOS Debug 构建通过。真实 VoiceOver、真机和 Dynamic Type 全页面仍未完成。

2026-11-08 二级工具无障碍补充：运势、早报、晚报的刷新按钮，金句收藏/取消收藏以及决策工具的添加/删除选项补齐 VoiceOver 标签和中英文资源；localization 19/19、iOS/macOS Debug 构建通过。旧工具的服务端 404/兼容协议问题仍按二级功能记录，不因无障碍修复而变成核心完成。

2026-11-08 watchOS 目标复测：`xcodebuild -scheme Caobao-watchOS -sdk watchsimulator -configuration Debug CODE_SIGNING_ALLOWED=NO` 退出 `65`，错误仍为 `Multiple commands produce .../Caobao-watchOS.app/Caobao-watchOS`。watchOS 按首发范围排除；若重新纳入，归因于客户端 target 构建和旧接口迁移，不计入当前首发完成度。

2026-11-08 legacy 日志修复：`APIService` 及运势、金句、决策、昵称、媒体和触觉页面的诊断输出统一改为 `assistantDebugLog`，Release 包不再输出 URL、服务端错误文本或本地路径，Debug 包仍保留排障能力。协议 9/9+24/24、本地化 19/19、ChatViewModel 168/168、iOS/macOS Debug 构建均通过；二级旧接口本身的 404/认证/额度协议问题仍按兼容功能记录。

2026-11-08 Release 构建复核：日志门控改动后，iOS Simulator Release 和 macOS Release 均明确返回 `** BUILD SUCCEEDED **`（`CODE_SIGNING_ALLOWED=NO`）。构建环境仍没有有效 Apple 签名身份，因此这只是 Release 编译/打包门禁通过，不替代正式 archive、Apple 登录、APNs 或 TestFlight 验收；macOS 仍有未设置 App Category 的 Xcode warning。

2026-11-08 日志改动后完整回归复跑：`Scripts/test-assistant.sh` 使用隔离文件、mock 网络和 fake 通知明确退出 `0`；末尾为 `All 168 actual ChatViewModel integration suites passed`。该结果确认日志门控没有引入客户端行为回归，仍不覆盖真实 Apple、StoreKit、APNs、模型请求或双设备生产链路。

2026-11-08 主动任务版本条件客户端补齐：暂停全部/恢复全部现在携带本地已知的 `expectedVersion`，只有服务器返回推进后的 profile 版本才更新本机状态；如果旧服务端忽略条件字段或返回未推进版本，客户端提示刷新重试并重新读取权威状态，避免静默覆盖多设备修改。`test-assistant-protocol.sh` 明确退出 `0`，iOS/macOS Debug 构建均明确退出 `0`。服务端仍必须真正执行条件更新并返回冲突状态，当前不能据此宣称多设备暂停已通过。

2026-11-08 生产健康复核补充：`GET https://ciyuan2api.com/api/status` curl 退出 `0`、HTTP `200`，响应头 `X-New-Api-Version: v1.0.0-rc.48+ciyuan.reconstructed.20261106.1`，JSON 中 `setup=true` 且 `server_address=https://ciyuan2api.com`。本轮没有重复发送模型请求，避免无必要扣减真实额度；部署后真实 CN `started → delta → usage → completed` 证据沿用本文件既有记录。

签名门禁记录：项目的 iOS Debug/Release `DEVELOPMENT_TEAM` 仍为空，`security find-identity -v -p codesigning` 返回 `0 valid identities found`；因此 Apple Sign In、APNs 和正式 archive/TestFlight 不能在当前环境完成。归类为发布签名环境阻塞，不写入猜测的 Team ID 或证书信息。

服务端需要处理的接口、幂等、owner 隔离和生产门禁见 [SERVER_ACCEPTANCE_REQUIREMENTS_2026-11-07.md](SERVER_ACCEPTANCE_REQUIREMENTS_2026-11-07.md)。

## 当前已通过

| 功能 | 结果 | 证据 | 备注 |
| --- | --- | --- | --- |
| 本地核心回归 | 通过（当前 checkout 重跑） | `Scripts/test-assistant.sh`；`/tmp/caobao-home-cloud-task-summary-full-regression-20261108.log`；末尾 `All 168 actual ChatViewModel integration suites passed` | 当前改动后完整脚本跑完，协议、同步、媒体、提醒、删除、备份、深链和 ChatViewModel 均有通过输出；使用隔离文件、mock 网络和 fake 通知，不代表生产联调 |
| 生产流式错误提示 | 通过（客户端） | `AssistantProtocol.swift`、中英文资源、`4ea0f26`、`5b7c09e`；`test-assistant-protocol.sh`、`test-assistant-localization.sh` | `PLATFORM_FUNDING_UNAVAILABLE`、`UPSTREAM_UNAVAILABLE`、`QUOTA_EXCEEDED` 现在映射为可操作的中英文提示，未知错误仍保留安全错误码；覆盖协议归一化和本地化回归。 |
| iOS/macOS Debug 构建 | 通过（当前改动后重跑） | iOS `/tmp/caobao-home-cloud-task-summary-ios-build-20261108.log`；macOS `/tmp/caobao-home-cloud-task-summary-macos-build-20261108.log` | 两个 target 均返回 `** BUILD SUCCEEDED **`；iOS Simulator 签名仍明确提示 Apple Sign In/APNs entitlement 缺失，构建未使用正式签名，因此不替代真机 archive/TestFlight 门禁 |
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
| macOS 首页导航与侧栏无障碍 | 客户端修复通过；真实 UI 未验收 | `Caobao/Views/MacContentView.swift`、`AssistantWorkspaceViews.swift`；当前 macOS Debug build | 首页开始对话/查看任务现在真正切换工作区；侧栏入口改为 Button，支持键盘和 VoiceOver 语义并扩大点击区域；主动模式标题使用本地化名称。个人页已挂载历史、记忆、订阅、助理设置、自定义角色和账号与数据入口；真实 macOS VoiceOver、Dynamic Type、账号删除和订阅闭环仍未验收。 |
| 账号删除后的本地同步清理 | 客户端修复通过 | `Caobao/Services/AuthService.swift`、`Caobao/Views/AssistantWorkspaceViews.swift`；删除/同步测试；`f98f486` | 账号删除会清理记忆、会话、任务同步游标及待删除队列，同时清理本机收藏、主动模式配置和主动更新的已读/稍后状态，避免旧账号同步状态或本地状态残留。 |
| 冷启动通知路由 | 客户端修复通过；真实锁屏点击未验收 | `Caobao/Services/AssistantNotificationRouter.swift`、`AssistantWorkspaceViews.swift`；签名 iOS Simulator build | 通知回调先保留 owner-bound route，等待认证恢复后再校验；任务/主动运行 ID 限长并拒绝控制字符，owner 使用字节精确匹配；任务页在登录账号云同步失败时保留待处理任务 ID，只有同步成功后才把缺失任务判为删除，避免临时网络故障丢失深链。真实 APNs 锁屏点击和生产深链仍需验收。 |
| 客户端协议与隔离回归 | 通过 | 多个 `Scripts/test-assistant-*.sh` | Apple 身份 17 套、权益 14 套、设备注册、媒体 12 套、记忆同步 3 套、会话同步均通过；使用 mock HTTP/隔离数据，不替代真实设备验收 |
| macOS 图片/音视频表面 | 客户端构建通过；真实媒体未验收 | `AnalyzeView.swift`、`MessageBubble.swift`、`AudioPlayerView.swift`；iOS/macOS Debug build | macOS 图片选择入口保留为兼容页面但分析请求已阻断，视频和音频使用真实播放器；真实 URL、权限、网络失败和大文件仍需设备验收。远程媒体默认仍关闭，避免把不可信回复中的 URL 自动拉取。 |
| 法律文档离线降级 | 客户端修复通过；真实断网 UI 未验收 | `LegalView.swift`、`WebView.swift`；iOS/macOS Debug build | WebView 现在回调加载失败，法律页在协议、隐私、未成年人保护和 AI 声明页面显示本地内容，并提供重新加载入口；此前 `webURL` 永远非空且失败回调缺失，离线文案不可达。真实断网、服务器 5xx 和文案版本仍需设备验收。 |

## 失败或未完成项

2026-11-08 旧工具入口收口：`FeaturesView` 不再把运势、图片分析、金句等旧接口页面标为“核心功能”，改为“工具模板/对话工具”二级区域，并明确提示旧服务端接口正在迁移；首页、对话、任务和我的四个核心入口不受影响。旧 API 仍未计入核心完成，服务端若不提供兼容协议，后续应继续迁移或下线对应页面。收口后 iOS/macOS Debug 构建分别明确返回 `BUILD SUCCEEDED`（`/tmp/caobao-legacy-tools-ios-20261108.log`、`/tmp/caobao-legacy-tools-macos-20261108.log`）；同一轮 `Scripts/test-assistant.sh` 命令退出 `0`，末尾为 168 个 ChatViewModel 套件通过（输出记录于 `/tmp/caobao-legacy-tools-regression-20261108.log`）。

2026-11-08 旧工具请求阻断：iPhone `FeaturesView` 和 macOS `MacToolsView` 现在将已知旧接口卡片改为“暂未启用”按钮，点击只显示迁移说明，不再发起已知 404 请求；本机金句收藏仍可打开。改动后 iOS/macOS Debug 构建均明确返回 `BUILD SUCCEEDED`（`/tmp/caobao-legacy-tools-disabled-ios-20261108.log`、`/tmp/caobao-legacy-tools-disabled-macos-20261108.log`）。

同一改动的 Release 构建也已通过：iOS Simulator 和 macOS Release 均明确返回 `BUILD SUCCEEDED`（`/tmp/caobao-legacy-tools-disabled-release-ios-20261108.log`、`/tmp/caobao-legacy-tools-disabled-release-macos-20261108.log`）。这仍是未签名 Release 编译证据，不替代正式 archive、TestFlight 和真机验收。

2026-11-08 生产状态复核：`https://ciyuan2api.com/api/status` 返回 HTTP 200，`X-New-Api-Version: v1.0.0-rc.48+ciyuan.reconstructed.20261106.1`；`/api/caobao/fortune`、`/api/report/morning`、`/api/analyze` 仍返回 HTTP 404。`https://caobao.chat/.well-known/apple-app-site-association` 返回 HTTP 200，但 `webcredentials.apps` 和 `applinks.details[0].appIDs` 仍为空，components 仍只有旧工具路径。结论未变：旧工具兼容/AASA 属于服务端发布项，客户端已阻断无效调用。
2026-11-08 00:16 UTC 生产探针复测：`/api/status` 仍为 HTTP 200、版本 `v1.0.0-rc.48+ciyuan.reconstructed.20261106.1`；`/api/caobao/fortune`、`/api/report/morning`、`/api/analyze` 仍为 HTTP 404；AASA 仍为 HTTP 200 但 `webcredentials.apps`、`applinks.details[0].appIDs` 为空且未声明 conversation/task/proactive 路径。该结果再次确认剩余项属于服务端兼容路由和发布配置，客户端继续保持阻断无效旧请求。

2026-11-08 客户端接口覆盖审计：核心首页、对话、任务、记忆、主动规则和订阅页面调用 `/api/v2` 契约；旧 `/api/caobao/*`、`/api/report/*`、`/api/analyze` 只存在于二级兼容页面或未挂载代码，未发现核心导航直接调用旧路径。该审计支持将旧工具从首发核心范围移出，而不是把静态 API 方法存在误判为功能完成。

2026-11-08 主动更新展示收口：执行记录现在显示本地化“生成于”时间、可用时显示“送达于”时间，并补齐“查看 / 稍后 / 关闭此类”操作。关闭此类目前只提示服务端接口尚未提供，引导用户到主动规则中暂停或删除，不伪造成功状态。iOS/macOS Debug 构建均明确返回 `BUILD SUCCEEDED`（`/tmp/caobao-proactive-row-ios-20261108.log`、`/tmp/caobao-proactive-row-macos-20261108.log`）。
2026-11-08 主动更新反馈本地化收口：主动运行时间、来源和“关闭此类”提示，以及暂停/保存结果消息统一通过 AssistantLocalization 读取中英文资源，避免英文模式显示中文。`Scripts/test-assistant-localization.sh` 明确退出 `0`（19 组），iOS/macOS Debug 构建明确返回 `BUILD SUCCEEDED`（`/tmp/caobao-proactive-localized-ios-20261108.log`、`/tmp/caobao-proactive-localized-macos-20261108.log`）。
2026-11-08 主动运行触发原因和未知状态本地化收口：触发原因、时间/来源动态文本和未知云端状态现在显式通过 AssistantLocalization 格式化，避免 `Text(String)`/隐式插值绕过语言资源。`Scripts/test-assistant-localization.sh` 明确退出 `0`（19 组），iOS/macOS Debug 构建明确返回 `BUILD SUCCEEDED`（`/tmp/caobao-proactive-trigger-localized-ios-20261108.log`、`/tmp/caobao-proactive-trigger-localized-macos-20261108.log`）。
2026-11-08 主动触发本地化后的完整客户端回归：`Scripts/test-assistant.sh` 明确退出 `0`，日志为 `/tmp/caobao-final-regression-trigger-localized-20261108.log`，末尾为 `All 168 actual ChatViewModel integration suites passed`；该回归仍是隔离文件、mock 网络和 fake 通知，不替代真实 Apple、StoreKit、APNs、模型请求、双设备和 TestFlight 门禁。
2026-11-08 官方信息和旧工具提示本地化补齐：iOS 官方页产品描述、macOS 产品矩阵名称/描述/“开发中”徽标，以及 iOS/macOS 旧接口不可用提示均显式使用 LocalizedStringKey 或 AssistantLocalization；英文模式不再回退到对应中文动态文案。`Scripts/test-assistant-localization.sh` 退出 `0`（19 组），iOS/macOS Debug 构建明确返回 `BUILD SUCCEEDED`（`/tmp/caobao-official-localized-ios-20261108.log`、`/tmp/caobao-official-localized-macos-20261108.log`）。
2026-11-08 官方页产品矩阵标签本地化补齐：iOS 产品名称、功能标签和“开发中”徽标也改为显式 LocalizedStringKey；本地化测试退出 `0`（19 组），iOS Debug 构建退出 `0`（`/tmp/caobao-official-matrix-localized-ios-20261108.log`），完整回归退出 `0` 且 168 个 ChatViewModel 套件通过（`/tmp/caobao-final-regression-official-matrix-localized-20261108.log`）。
2026-11-08 官方页和旧工具本地化后的完整客户端回归：`Scripts/test-assistant.sh` 明确退出 `0`，日志为 `/tmp/caobao-final-regression-official-localized-20261108.log`，末尾为 `All 168 actual ChatViewModel integration suites passed`；仍是隔离文件、mock 网络和 fake 通知，不替代真实 Apple、StoreKit、APNs、双设备和 TestFlight 门禁。
2026-11-08 主动更新展示改动后的完整回归复跑：`Scripts/test-assistant.sh` 明确退出 `0`，日志为 `/tmp/caobao-final-regression-after-proactive-row-20261108.log`，末尾为 `All 168 actual ChatViewModel integration suites passed`；该回归仍使用隔离文件、mock 网络和 fake 通知，不替代真实 Apple、StoreKit、APNs、模型请求或双设备生产门禁。

2026-11-08 自定义角色绑定专项审计：`AssistantMessageRequest`（`APIService.swift:1627-1670`）只有 `persona.level`，`ChatViewModel.prepare()`（`ChatViewModel.swift:1716-1725`）的平台请求和 BYOK 请求都没有 `characterId/version`；对话页也没有当前角色选择或会话绑定状态。角色 CRUD 通过不等于角色对话完成；此项归类为客户端 + 服务端新增功能，需先确定 `characterId`、版本/冲突和 memory scope 协议，再补客户端选择、持久化、请求字段和同步。

2026-11-08 主动/任务状态写入专项审计：客户端主动运行只有 owner-scoped 本机 read/snooze，明确不宣称跨设备；没有服务端 read/snooze/dismiss/close-kind API。客户端暂停全部会发送 `expectedVersion` 并拒绝不递增响应，但 checkout 服务端 `PauseAllProactive` 只读取 `paused`，`SetTaskStatus` 也没有版本条件；云任务页面因此禁用已有云任务的本地 pause/cancel。归类为服务端契约/Worker 缺口，客户端暂不补无效或不安全的写入。

| 功能 | 当前状态 | 责任归类 | 原因/下一步 |
| --- | --- | --- | --- |
| 我的收藏 | 客户端已降级为 owner-scoped 本机金句收藏；在线收藏仍失败 | **客户端已处理；服务端待定** | 生产 `GET /api/favorites` 和 `GET /api/sync/favorites` 均返回 HTTP 404；核心入口使用本机金句收藏，旧 `FavoritesView` 兼容入口也已改为同一本机存储包装页，不再调用必失败的在线接口。若需要跨设备收藏，服务端仍需补 owner-scoped v2 API、认证和删除墓碑。 |
| 数据统计 | 通过 | **客户端** | 新增 owner-scoped `AssistantUsageStatsStore`；仅成功完成的非空回答计数，取消/失败不计数，重试按 message ID 幂等，账号隔离。真实 Simulator 发送后详细页显示累计发送 1、我的消息 1、AI 回复 1、今日/周/月各 2；安装最新构建后“我的”概览同步显示对话 1、使用 1 天、连续 1 天。 |
| Apple 登录全生命周期 | 未验收；客户端入口已运行时通过 | 服务端 + 系统环境 + 正式签名 | 当前签名 QA19 Simulator 勾选协议后点击“通过 Apple 登录”，成功弹出系统“登录 Apple 账户 / 需要在‘设置’中登录 Apple 账户”提示，证明客户端入口和 `ASAuthorization` 调用链可达；因 Simulator 未登录 Apple 账户，未继续输入凭据。iOS/macOS 已有撤销通知处理、nonce/state/JWT/授权码和 Keychain 会话逻辑；源码 entitlement 含 Apple Sign In、APNs 和 Associated Domains，但当前 `DEVELOPMENT_TEAM` 为空的 Simulator 签名实际嵌入空 entitlement；构建脚本现已明确提示“real-device archive signing still required”（`build-simulator.sh`）。仍未完成真实授权、刷新、退出、撤销及真实 Bearer 验证。 |
| StoreKit 订阅 | 未验收；服务端配置可读但 StoreKit 无可用商品 | 服务端 + App Store Connect + 客户端 | 真实 Bearer 请求 `subscriptions/apple/config` 返回 HTTP 200 且含 2 个 Product ID；当前签名 Simulator 的 StoreKit 返回 0 个可用自动续订商品，页面显示“订阅暂不可用”。客户端不硬编码 Product ID，筛选和账号绑定逻辑已通过本地测试；仍需 App Store Connect/StoreKit 商品、真机购买、恢复、退款、撤销和额度账本闭环。 |
| APNs/系统提醒 | 客户端注销竞态已修复；整体仍未验收 | 服务端 Worker/APNs + 客户端协议 | 客户端登出会使用旧 access token best-effort 调用 `DELETE /api/v2/devices/{deviceId}`，现在 DELETE 与后续 POST 注册串行化，重复注销也不会并发。当前 `feat/caobao-server-v2` 路由源码仍只看到 `POST /api/v2/devices`；此前随机 DELETE 生产探针成功，不能代替 production-versus-branch 比较。真实已注册 token、旧 owner 失效、outbox 清理、锁屏送达、点击深链和安静时段生产行为仍未验证。归因：客户端竞态已修复，服务端/正式签名真机门禁未完成。 |
| 图片 | Assistant v2 聊天图片部分通过；旧图片分析已阻断无效请求 | 客户端已处理；服务端迁移待定 | 聊天图片入口和本地预处理测试通过；`AnalyzeView` 现在只显示“服务端接口待迁移”，不再 POST 生产不存在的 `/api/analyze`，并引导用户使用 Assistant v2 对话图片。旧图片分析保留为二级兼容页面但不计入核心完成；后续迁移到 Assistant v2，或由服务端补齐认证、owner、额度和流式错误协议。 |
| 语音输入/朗读 | iPhone/macOS 客户端入口已实现，真实设备未验收 | 客户端/系统权限 | `AssistantSpeechController` 已覆盖 iOS/macOS 权限、locale、设备端识别回退、60 秒上限、账号切换、中断和 TTS 8,000 字上限；`MacChatView` 已加入麦克风、停止和朗读入口，macOS Debug build 通过。尚未在真实 iPhone/macOS 麦克风环境完成授权、录音、识别和朗读验收，正式包仍需检查 Speech/Microphone 权限和签名。 |
| 会话/任务/记忆云同步 | 文本和基础记录同步有本地回归；多模态/工具历史与双设备生产闭环未验收 | **客户端 + 服务端联调；功能范围需明确** | 真实账号已创建 7 天后到期的临时云任务，完成版本更新、列表验证和删除墓碑；客户端已有 owner-scoped 会话 change feed pull、全量回填、消息合并、删除队列和 tombstone 提交，记忆同步支持版本/墓碑。任务编辑现在持久化 owner-scoped 云端版本和脏任务 ID，拉取时不覆盖本地脏编辑，内容变更使用条件 PATCH，冲突保留本机并提示。当前会话同步按安全策略只恢复文本，远端图片、tool_call/tool_result 和 taskProposal 不写入本机归档；若“跨设备继续”要求完整多模态/工具历史，需新增安全附件引用、大小校验、提案降权和服务端契约。状态审批和两台真实设备仍未验收。 |
| 记忆授权字段兼容 | 客户端已做兼容；服务端仍需修复 | **客户端 + 服务端协议** | 本地策略把 `confirmed` 和 `explicit` 都视为已授权；当前客户端平台请求把 `confirmed` 规范化为 `explicit`，避免现有 bridge 静默丢失已确认记忆，并有 ChatViewModel 回归覆盖。服务端 bridge 仍需正式接受 `confirmed`，否则其他客户端或旧版本仍会丢上下文。 |
| 云任务编辑、状态和审批 | 内容编辑条件同步已补；等待确认审批入口和状态 fail-closed 已补；首页摘要已补；暂停/取消仍未完成 | **客户端 + 服务端协议** | 客户端持久化云端 `version`/脏任务，编辑后使用 `expectedVersion` PATCH；版本不一致时保留本机编辑并提示，不静默覆盖。`waiting_approval` 任务现在使用服务端 `task.reminder` 精确参数哈希调用 `/approve`，成功后刷新权威状态；`draft`、`waiting_approval`、`failed` 和未知云端状态不会再默认显示为本地 active，只有 `scheduled/running` 映射为 active；首页登录同步完成和下拉刷新会读取云任务摘要，读取失败不会清空本地任务。服务端虽然注册了 pause/cancel 路由，但 handler 没有 expectedVersion，客户端也没有安全的状态写入方法；需要先确定条件状态协议，再完成客户端接入和真实账号验证。 |
| 主动更新 | 基础 profile/规则 CRUD 真实通过；运行与投递闭环未完成 | **客户端 + 服务端** | 当前签名 Simulator 已打开主动更新页，开关从关闭切换到开启再恢复关闭；频率选择、未读数量、下一次运行、陪伴模式和每日上限入口均可见。未登录时暂停全部、添加规则和刷新运行记录已禁用并显示登录提示；运行记录使用本地化状态文案，macOS 首页主动模式使用本地化标题。真实账号已完成 profile/rules 读取，并创建 7 天后运行的临时规则，完成版本更新、列表验证和删除墓碑。二轮 UI 验收实际启用安静时段并保存，页面显示“安静时段已启用”，随后关闭并保存恢复原状态；此前已验证暂停/恢复全部、运行记录的查看/稍后、本机已读状态及通知关联对话回流。客户端现已把服务端会话 ID解析为本地会话 ID，兼容 `readAt`、`snoozedUntil`、`dismissedAt`，持久化 profile `expectedVersion`、规则运行幂等键，并在暂停/恢复全部时拒绝未推进的服务器版本；但当前服务端 `pause-all` handler 仍需真正执行并验证 `expectedVersion`，客户端不能把暂停/恢复宣称为多设备安全写入。服务端关闭此类、阅读/稍后多设备写入、生产 Worker/APNs、规则真实运行和冲突验收仍未完成；logout/换账号时还需失效旧账号 APNs 设备绑定。 |
| 自定义角色 | 基础真实 CRUD 通过；角色聊天接入、冲突和跨设备仍未完成 | **客户端 + 服务端联调** | 客户端已将记忆范围从错误的 `private/workspace` 对齐为服务端接受的 `none/character/group`，默认使用 `character`，避免新建角色必然收到 400。2026-11-08 已在已登录 Simulator 完成 owner-scoped list/create/versioned update-disable/list 验证/delete 墓碑，且已撤销仅 Debug 探针；UI 也已确认名称、头像、简介、语言、启用、行为提示、问候语和记忆范围控件存在。仍需真实版本冲突、多设备墓碑和账号切换验收；角色尚未接入对话请求，需新增 `characterId/version` 与服务端提示词、记忆范围协议。 |
| AI 群聊 | 未实现 | **客户端 + 服务端新增** | 当前代码没有群聊参与者、编排、speaker/turn 模型或 SSE；不能用现有 personaLevel 代替。 |
| macOS/iPad 信息架构 | macOS 核心导航、历史和“我的”已补齐；iPad 模拟器布局通过，真机和辅助功能仍未验收 | **客户端 UI** | macOS 侧栏现在保留首页、对话、任务、历史、我的和工作区，旧工具统一进入“工具模板”，最近对话常驻侧栏；历史页支持本地搜索并回到对话，个人页显示账号/统计并提供记忆、订阅和设置入口。最新 iPad Pro 11-inch (M5) Simulator 签名包已启动并显示侧栏、首页、主动更新、任务、工作区、订阅、设置、主 CTA 和四个快速模板；截图 `.build/verification/ipad-acceptance-20261107.png`。真实 iPad 触控、VoiceOver、Dynamic Type、订阅和账号闭环仍需验收。 |
| iPhone Duo、真机/TestFlight | 未验收 | 发布环境 | 当前普通 Simulator 不能证明 Duo 专用设备、正式签名归档、TestFlight 安装和系统级行为。 |
| macOS 详细统计/关于/官方页 | 客户端页面已补；真实 UI/内容验收未完成 | **客户端 UI** | macOS “我的”现在提供详细统计、完整关于页（版本、核心能力、隐私控制、法律/支持）和完整官方信息页（理念、产品矩阵、联系方式）；详细统计读取 owner-scoped 本机完成对话计数。真实 VoiceOver、内容审校和与 iOS 视觉完全一致仍需验收；`75c6765`，macOS Debug build 通过。 |
| macOS 对话图片/任务提案 | 任务提案流程和本地图片选择已补；真实上传/交互未验收 | **客户端 macOS parity** | `MacChatView` 现在复用统一消息气泡，显示本地图片附件、朗读入口，提供 security-scoped 图片文件选择、缩略图移除，并在后台读取文件后接入任务提案查看、编辑确认、拒绝和一次性继续请求。多图预处理、真实上传、权限和大文件仍需设备验收。 |
| 图片保存权限 | 客户端修复；真实设备未验收 | **客户端配置** | `UIImageWriteToSavedPhotosAlbum` 需要写入权限说明；已在 `Info.plist` 增加 `NSPhotoLibraryAddUsageDescription`。真实相册授权、保存失败和取消流程仍需设备验收。 |
| Universal Links | 客户端路由已补；AASA 配置不合格、真机未验收 | **客户端 + 服务端发布配置** | `CaobaoApp` 现在解析 `https://caobao.chat/conversation/{id}`、`/task/{id}`、`/proactive/{runId}`，支持登录延迟消费、owner 绑定和 iOS/macOS 路由。2026-11-08 实测 AASA 返回 200，但 `appIDs` 为空且只声明旧的 `/chat/*`、`/morning` 等路径，未覆盖三类新路由；服务端需先修 AASA，再做正式 Associated Domains 签名和真机点击验收。 |
| 旧设置状态 | 客户端已修复；真实账号切换未验收 | **客户端状态整合** | 旧 `SettingsView` 已移除无消费者的 `voiceEnabled` 开关，毒舌程度只读写 owner-scoped `appState.userSettings`，避免与旧 `UserDefaults` 键分裂。真实账号切换和服务端 persona 偏好仍需验收。 |
| 游客升级 | 客户端入口和旧 API 已移除 | **客户端已收口；服务端协议待定** | 当前产品只创建 Apple 正式账号或 BYOK 本地账号；个人页不再展示永远不可达的游客升级区和升级 Sheet，客户端也不再保留旧升级调用。若未来支持游客转 Apple，服务端需定义数据归属迁移、幂等和失败恢复协议后再重新接入。 |
| 反馈提交 | 客户端邮件反馈可用；云端反馈未接入 | **客户端已处理；服务端接口待定** | 生产 `/feedback` 返回 404，客户端已移除旧网络提交路径，表单改为系统邮件 `mailto:`；若未来需要云端工单，服务端需提供认证/匿名范围、限流、附件和回执协议，再重新接入。 |
| 远程媒体与举报 | 远程媒体默认关闭；举报改为邮件且默认关闭 | **客户端已处理；服务端云端举报接口待定** | `MessageBubble` 的远程音视频路径仍由 `allowsRemoteMedia` 控制，现有聊天/历史调用未显式开启。举报路径改为系统邮件，包含原因和截断正文，不再调用生产 404 的旧反馈接口；若未来需要云端举报，服务端需提供认证、内容留存、限流和处理回执协议。 |
| 旧收藏/旧工具协议 | 二级兼容面未验收 | **客户端清理 + 服务端兼容** | `FavoritesView` 和 `FeaturesView` 仍有旧 `/api` 方法定义，但核心入口已转本机收藏和 Assistant v2；旧页面应删除或标明兼容范围，不能把静态方法当作可用功能。 |

## 未纳入首发或未挂载的客户端表面

- **watchOS**：当前工程有独立 watchOS target，但仍使用旧的 `/api` 运势/早报/吐槽/决策接口，没有 Bearer、owner 隔离或云同步；本轮 `xcodebuild -scheme Caobao-watchOS -sdk watchsimulator` 还因 `Multiple commands produce .../Caobao-watchOS.app/Caobao-watchOS` 失败。按产品计划暂不纳入首发；若恢复该范围，责任归类为客户端 watchOS 重做 + target 构建修复 + 服务端认证兼容，不能把现有 target 当作已完成。
- **WidgetKit**：`CaobaoWidgets/CaobaoWidget.swift` 有实现文件，但工程没有 Widget target 引用，当前不可构建；若需要桌面/锁屏小组件，责任归类为客户端工程接入、签名和深链验收。

2026-11-08 工程 target 审计：`xcodebuild -list` 当前仅列出 `Caobao`、`Caobao-macOS`、`Caobao-watchOS`，没有 WidgetKit target；watchOS 复测退出 `65`，错误仍为 `Multiple commands produce .../Caobao-watchOS.app/Caobao-watchOS`（`/tmp/caobao-watchos-audit-20261108.log`）。watchOS 按首发范围排除；若重新纳入，归类为客户端 target 构建修复。
2026-11-08 iPad Pro 13-inch Simulator 冷启动复测：启动 `81B65E72-F2C4-4916-9542-AE7D9CA503E7`，安装最新 iOS Debug 包并成功启动 `caobao.chat`；截图 `/tmp/caobao-ipad-acceptance-20261108.png` 显示中文登录页、Apple 登录、BYOK、协议开关和能力说明，Caobao 进程日志 `/tmp/caobao-ipad-logs-20261108.txt` 未发现 crash/fatal。该证据只覆盖大屏未登录冷启动可见性，不替代真实 iPad、签名、Apple、StoreKit 或 VoiceOver/Dynamic Type 验收。
- **Optimized/**：其中的 Dynamic Island、Siri、推送管理、分享和图片上传等 Swift 文件没有加入 Xcode target；它们是未挂载代码，不能计入已完成功能。产品需要时应逐项接入并补真实系统验收，否则作为待清理的死代码。
- **HapticManager**：虽然已加入 iOS target，但全仓没有调用点；当前不能把触觉反馈计入已完成能力。需要时接入消息发送、任务完成等明确交互，否则清理死代码。
- **旧 APIService 方法**：旧收藏、旧聊天流、旧设置和旧云同步方法目前只有定义，没有核心页面调用；当前产品以 `Assistant*` v2 客户端为准。旧接口应标记兼容范围或删除，不能用静态方法存在证明功能完成。
- **macOS 设置差异**：当前 `AssistantMacPreferencesView` 只覆盖语言、风格和服务区域；语音、通知/安静时段、主动模式、BYOK 和数据管理仍通过工作区入口分散提供。若要求与 iOS 完全同构，归类为客户端补齐；否则保留平台化设置并在产品说明中明确范围。
- **官方页标签**：已修复“开发中”标签条件错误，改为显式 `isComingSoon`，并通过 iOS/macOS 构建验证。

## 功能去处与新增

- 运势、晨报、晚报、吐槽、决策、金句、收藏、统计和反馈保留为二级工具/设置入口，不继续扩充一级导航。
- 旧 `/api/analyze` 图片分析保留为二级兼容入口但不计入核心完成；迁移到 Assistant v2 或补齐认证、owner、额度和流式错误协议后再恢复“已完成”状态。
- 自定义角色管理页面已补齐，仍需真实账号验证 `/api/v2/characters` 的 CRUD、版本冲突和墓碑同步；AI 群聊是新的跨端功能，必须先补服务端协议、参与者/轮次模型、幂等和执行历史，再接客户端 UI。
- 主动更新已补暂停/恢复全部、首页未读数/下一次运行、本机查看/稍后和通知点击回流；来源解释使用现有 `triggerReason/sourceRefs`。本机已读/稍后不宣称跨设备同步；服务端仍需提供阅读/稍后状态、关闭此类接口和生产 Worker/APNs。
- 跨设备会话当前明确采用“文本历史优先”策略：图片、工具调用结果和任务提案不会从远端直接恢复，避免不受控的附件下载或把历史提案当成执行权限；若产品要求完整跨设备继续，这是客户端 + 服务端的新增功能，不应把现有文本同步证据扩大解释。

## 下一轮验收顺序

1. 若要跨设备收藏，服务端补 owner-scoped v2 API（含认证、删除墓碑和同步）；当前客户端已明确使用本机金句收藏，不阻塞其他验收。
2. 在真实账号和真实设备上验收 Apple、StoreKit、APNs、图片/语音、双设备同步（会话 change feed、记忆 change feed、任务 change feed、删除墓碑）、账号删除和 TestFlight。
3. 完善主动更新剩余交互，完成真实角色 CRUD 验收，再实现 AI 群聊协议/编排。
