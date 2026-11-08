# 草包客户端验收矩阵（2026-11-08）

这份矩阵把当前客户端验收结果按责任归类，避免把本地测试、静态代码或随机探针当成生产完成证据。

## 结论

当前 iPhone、iPad 和 macOS 客户端源码可编译，本地协议、数据隔离、任务工具、提醒、同步和 ChatViewModel 回归已通过；iPhone Release archive 和开发签名已经通过，深色模式和超大字体下的登录页也已复测。整体仍未达到生产完成标准。Apple 账号登录、StoreKit、APNs、双设备、账号删除、主动 Worker 和 TestFlight 尚未通过真实门禁。

## 已通过或客户端已处理

| 能力 | 结果 | 证据 |
| --- | --- | --- |
| 对话流、停止、重试、重新生成 | 客户端协议通过；CN 真实流曾完成 `started → delta → completed` | `Scripts/test-assistant.sh`，168 个 ChatViewModel 套件 |
| 图片消息 | 本地预处理、尺寸、EXIF、历史隔离通过 | 媒体 12 组；真实上传仍待真机 |
| 语音入口 | iPhone/macOS 入口和权限逻辑存在 | 真实麦克风、识别、朗读仍待真机 |
| 记忆 | 本地策略、云增量、版本、墓碑和 owner 隔离通过 | 记忆同步 3 组；真实双设备未验收 |
| 会话历史与草稿 | SQLite、归档、删除、导入导出通过 | 数据库 38、归档 39、删除 18 组 |
| 任务与提醒 | 时区、DST、重复、安静时段和协调器通过 | 安静时段 31、提醒协调器 88 组 |
| 任务工具审批 | 提案、哈希、receipt、继续执行安全边界通过 | 协议 51、执行 48、导出 13 组 |
| 主动规则与角色 CRUD | 基础页面和真实 CRUD 已验证 | 服务端真实 CRUD；角色对话仍未接入 |
| 本地化、深链解析、冷启动 | 本地测试和 Simulator smoke 通过 | 本地化 19、深链 8 组；真机深链未验收 |
| iPad UI 适配 smoke | 当前 Release 包在 Dynamic Type `accessibility-extra-extra-extra-large` 和深色模式下首屏启动无 crash；登录按钮在两种模式下保持可见 | `/tmp/caobao-ipad-a11y-fix-20261108.png`、`/tmp/caobao-ipad-dark-fix-stable-20261108.png`；不替代 VoiceOver/真机验收 |
| iOS/macOS Debug/Release 编译 | 当前 checkout 全新 DerivedData 均退出 0；最终 iPhone 真机 Debug 签名包 `codesign` 校验通过，TeamIdentifier 为 `26CX9F23YL` | `/tmp/caobao-final-device-signing-20261108.log`、`/tmp/caobao-resume-macos-darkfix-build-20261108.log` |
| 登录页外观与可访问性 | Apple 按钮按系统外观选择黑/白样式；超大字体使用可增长高度，按钮背景和点击区域保持可见 | `Caobao/Services/AuthService.swift`、上述两张 Simulator 截图 |

## 未通过或等待服务端/发布环境

| 能力 | 当前失败/缺口 | 责任 |
| --- | --- | --- |
| Apple 登录全生命周期 | iPhone 真机 Debug 签名已通过；当前只有开发证书，未连接真实 iPhone，Simulator 也未登录 Apple 账户，完整登录/刷新/撤销仍未通过 | 真实设备、Apple 账号、服务端 |
| StoreKit 订阅 | 服务端配置有 2 个 Product ID，但 StoreKit 商品数为 0 | App Store Connect、服务端配置、正式签名 |
| APNs 锁屏投递 | 未验证真实 token、outbox、Worker、重试、锁屏和点击回流 | 服务端 + 真机 |
| APNs 点击字段 | 客户端要求 owner 绑定的 `ownerId`、`route` 和任务/主动运行 ID；checkout 的 APNs sender 当前只把 `deepLink` 写入最终 JSON | 服务端 payload 契约/发布 |
| 设备注销 | 客户端发送 DELETE；checkout 分支缺 DELETE，生产与分支漂移 | 服务端发布/契约 |
| 主动任务执行 | profile/rule CRUD 通过，Worker、run、conversation 回流未闭环 | 服务端 |
| 主动阅读/稍后/关闭此类 | 服务端没有多设备 read/snooze/dismiss/close-kind 接口 | 服务端新增 |
| 云任务暂停/取消 | 服务端未消费 `expectedVersion`，客户端已 fail-closed | 服务端契约 |
| 账号删除云端清理 | 未证明旧设备、任务、通知和墓碑全部清理 | 服务端真实验收 |
| Universal Links | AASA `appIDs=[]`，没有新 conversation/task/proactive 路径 | 服务端发布配置 |
| 双设备同步 | 本地 merge/tombstone 通过，真实双设备未完成 | 服务端 + 真机 |
| 大规模历史完整恢复 | 客户端已把全量回退的会话页、活动会话和消息游标按 owner 持久化；增量变更超过 1,000 条消息会安全降级为完整快照，定向大数据分页和降级测试通过 | 客户端修复通过；完整生产双设备仍待真机/服务端验收 |
| VoiceOver/Dynamic Type | Simulator 的 iPad 深色模式与超大字体已复测；VoiceOver 和真实设备仍未验收 | 真机发布门禁 |

## 首发去处或新增功能

| 功能 | 处理 |
| --- | --- |
| watchOS | 不纳入首发；当前 target 因重复产物退出 65。若恢复，需客户端 target 重做和旧 API 迁移。 |
| WidgetKit | 当前没有 WidgetKit target；需要时重新接入工程、签名和深链。 |
| 旧运势、晨报、晚报、吐槽、决策、旧图片分析 | 保留为二级迁移入口；旧接口 404 时客户端已阻断无效请求。 |
| 自定义角色对话 | 新增客户端 + 服务端协议，至少需要 `characterId`、角色版本和 memory scope。 |
| AI 群聊 | 新增客户端 + 服务端协议，需要参与者、轮次、speaker、停止/取消、幂等和执行历史。 |
| 完整跨设备多媒体/工具历史 | 新增安全附件引用、大小校验、提案降权和服务端协议；当前只恢复文本历史。 |

## 重新验收顺序

1. 服务端先完成设备 DELETE、AASA、APNs Worker/outbox、账号删除清理和条件状态更新。
2. 使用正式签名真机验收 Apple、StoreKit、APNs、语音/图片权限和 Universal Links。
3. 使用两台设备验证会话、任务、记忆、主动状态和删除墓碑。
4. 完成主动 Worker 实际执行、角色绑定对话和 TestFlight 安装后，才能重新评估“客户端和服务端全部完成”。

详细证据见 [CLIENT_ACCEPTANCE_2026-11-07.md](CLIENT_ACCEPTANCE_2026-11-07.md) 和 [CLIENT_SERVER_FIX_REQUESTS.md](CLIENT_SERVER_FIX_REQUESTS.md)。

## 本轮重验环境

- 客户端工程当前 iOS Debug/Release 配置使用团队 `26CX9F23YL`；`security find-identity` 找到有效 Apple Development 证书，真机 generic `iphoneos` Debug 构建退出 0，包内 entitlement 和 provisioning profile 已由 `codesign` 验证。
- `https://ciyuan2api.com/api/status` 仍返回 `v1.0.0-rc.48+ciyuan.reconstructed.20261106.1`；本地 `feat/caobao-server-v2` 与远程仍在 `f03f8be`。因此服务端“已修复”尚未反映到当前 checkout 或公开生产版本，本轮只把服务端路由探针作为鉴权可达性证据。
- 生产 AASA 仍返回空 `appIDs`/`webcredentials.apps`，且没有 conversation/task/proactive 新路径；Universal Links 和真实 APNs 不能据此标记通过。
- 2026-11-08 09:20 UTC 公网复核仍为 `X-New-Api-Version: v1.0.0-rc.48+ciyuan.reconstructed.20261106.1`；AASA 仍为 `appIDs=[]`、`webcredentials.apps=[]`。服务端修复声明尚未形成可验证的公网版本变化。

## 本轮客户端闭环修复

- 首页顺序已收敛为“主动更新 → 今日任务 → 开始对话 → 快速模板 → 最近对话 → 额度/二级工具 → 数据与隐私”，避免额度卡和工具入口打断主 CTA 与最近工作。
- 主动运行打开关联对话后，客户端会在对话详情和继续对话页显示“由主动任务创建”来源标记；该标记只用于展示，不授予额外执行权限。iOS/macOS Debug 构建均通过，日志为 `/tmp/caobao-source-marker-ios-20261108.log` 与 `/tmp/caobao-source-marker-macos-20261108.log`。
- 主动运行的“稍后”仍是本机状态，“关闭此类”仍提示服务端接口缺失；多设备阅读状态、关闭规则和 Worker 投递不计入已完成。
- 自定义角色仍只完成 owner-scoped CRUD；对话请求没有 `characterId/version`，AI 群聊没有参与者/轮次/speaker 协议，因此这两项继续列为客户端+服务端新增功能。
- 当前 iPhone 17 Pro Max Simulator 已安装本轮 Debug 包并启动，`simctl launch` 返回 PID，7 秒后截图成功；应用进程 crash/fatal 日志为空（`/tmp/caobao-source-marker-launch-20261108.png`、`/tmp/caobao-source-marker-launch-logs-20261108.txt`）。系统仍停在未登录 Apple 账户验证面板，不能计入 Apple 登录完成。
- 本轮主动来源标记改动后的 iOS Simulator Release 与 macOS Release 均在全新 DerivedData 构建成功；Release 包安装到 iPhone 17 Pro Max Simulator 后启动成功，应用 crash/fatal 日志为空（`/tmp/caobao-acceptance-final-release-ios-20261108.log`、`/tmp/caobao-acceptance-final-release-macos-20261108.log`、`/tmp/caobao-acceptance-final-release-launch-20261108.png`）。这仍不替代正式分发签名、真机和 TestFlight。
- 主动对话来源标记新增中英文资源；本地化 19 组、iOS/macOS Debug 构建均通过（`/tmp/caobao-acceptance-localization-20261108.log`、`/tmp/caobao-acceptance-localization-ios-20261108.log`、`/tmp/caobao-acceptance-localization-macos-20261108.log`）。
- 最终代码/资源状态再次执行 `Scripts/test-assistant.sh`，全部列出的套件退出 0，末尾为 `All 168 actual ChatViewModel integration suites passed`（`/tmp/caobao-acceptance-final-regression-20261108.log`）。
- 2026-11-08 07:09 UTC 生产复核仍返回 `X-New-Api-Version: v1.0.0-rc.48+ciyuan.reconstructed.20261106.1`；AASA 仍为 HTTP 200 但 `webcredentials.apps=[]`、`applinks.details[].appIDs=[]`，只有旧 `/chat/*`、`/morning`、`/evening`、`/fortune`、`/roast` 路径。因此服务端修复尚未进入公开生产，Apple Associated Domains/Universal Links 仍未通过。
- iPhone `iphoneos` Release 使用团队 `26CX9F23YL` 正式签名构建成功；`codesign` 显示 Apple Development、TeamIdentifier `26CX9F23YL`、Apple Sign In、APNs development 和 Associated Domains entitlement（`/tmp/caobao-final-device-release-signing-20261108.log`）。这证明 Release 配置可签名，但仍不是 Distribution/TestFlight 证据。
- 2026-11-08 07:19 UTC 追加 generic iOS Release archive：`xcodebuild archive` 退出 `0`，归档位于 `.build/final-release-archive-20261108-1519/Caobao.xcarchive`，日志为 `/tmp/caobao-final-release-archive-20261108.log`；归档使用 `Apple Development: ChaoYu Zhang (QW34KDM365)`。因此“可归档/开发安装”已通过，但钥匙串仍没有 Apple Distribution 身份，TestFlight/生产分发仍未通过。
- 2026-11-08 07:18 UTC 生产状态再次返回 HTTP 200 和 `X-New-Api-Version: v1.0.0-rc.48+ciyuan.reconstructed.20261106.1`；当前电脑没有连接真实 iPhone，`xcrun xctrace list devices` 仅列出 Mac 和 Simulator。真机 Apple、StoreKit、APNs 和 Universal Links 验收继续保持未通过。
- 会话同步游标修复后的最终回归：`Scripts/test-assistant.sh` 退出 `0`，末尾为 `All 168 actual ChatViewModel integration suites passed`（`/tmp/caobao-full-regression-after-resumable-sync-v3-20261108.log`）；定向同步测试覆盖 201 个会话、1,001 条消息和 HTTP 503 后恢复（`/tmp/caobao-cloud-conversation-final-v3-20261108.log`）。最终 iOS/macOS Debug 构建均 `BUILD SUCCEEDED`（`/tmp/caobao-resumable-sync-v3-ios-20261108.log`、`/tmp/caobao-resumable-sync-v3-macos-20261108.log`）。
- 最终同步修复 Release archive：`xcodebuild archive` 退出 `0`，`.build/resumable-sync-final-archive-20261108/Caobao.xcarchive` 通过 `codesign --verify --deep --strict`，TeamIdentifier `26CX9F23YL`、身份仍为 Apple Development（`/tmp/caobao-resumable-sync-final-archive-20261108.log`）。这证明最终代码可归档和开发签名，不证明 Distribution/TestFlight。
- 增量大历史降级后的最终回归：`Scripts/test-assistant.sh` 退出 `0`，末尾仍为 `All 168 actual ChatViewModel integration suites passed`（`/tmp/caobao-full-regression-after-resumable-sync-v4-20261108.log`）；最终 Release archive `.build/resumable-sync-final-v4-archive-20261108/Caobao.xcarchive` 通过 `codesign --verify --deep --strict`，TeamIdentifier `26CX9F23YL`（`/tmp/caobao-resumable-sync-final-v4-archive-20261108.log`）。
