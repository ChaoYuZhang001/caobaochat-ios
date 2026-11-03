# CaoBao 本机待办工具契约

更新：2026-10-30。Phase 19 统一 23 套 / 850 个独立测试组 exit 0；Home 拆分及原生发现的日期展示修正后，官方远程 iOS Simulator SDK 均已成功。QA19 已验证拒绝持久化、最终只读边界和时区修正等限定子集，完整原生链路未完成。本文不代表服务端、真实模型、Apple/StoreKit、系统通知送达或 iPhone Duo 已验收。

## 1. 产品边界

- 首个工具为 create_task：模型只提出待办建议，用户查看、编辑并明确保存后才创建真实本机任务。
- 当前只在经能力验证、明确启用的 BYOK 模式声明工具。平台 v2 工具仍关闭，不借用旧接口，也不把模型目录 tools=true 当作服务端已部署证明。
- 提案支持一次性任务。原有手工任务编辑的每日/每周重复不受影响；提案编辑器不开放重复规则，执行器也拒绝通过隐藏字段加入重复规则。
- 没有邮件、购买、网页提交、任意 URL、远程脚本或后台 Agent 执行。主动通知仍需独立权限与真实系统安排，不以模型文字推断成功。

## 2. 显式能力验证与费用

- 设置中先确认费用与目标服务，再发送固定的 caobao_task_probe 函数调用。唯一参数为 ok=true，不发送历史、记忆、任务或图片，不创建任务或申请通知权限。
- 探针输出上限为 128 tokens，客户端总期限最多 20 秒；只有完整合法调用、成功终止和原生 HTTP EOF 都满足才返回证明。它不保证服务商一定按参数收费或遵守输出限制。
- 证明绑定完整端点、协议、模型与 Key 摘要生成的配置指纹；持久化工具偏好同时要求 schemaVersion=1。修改配置后重新验证，历史证明不能自动授权新目的地。
- 成功证明先留在编辑页；用户明确启用并保存后才写入偏好。取消、账号变化、字段变化与迟到回调不能保存过期证明。
- 普通聊天未启用工具时仍严格拒绝工具调用。验证、聊天和“让助理继续”都可能产生用户 API 服务商费用；本机保存或拒绝建议本身不调用模型。

## 3. 参数与协议

函数参数严格限定为以下五项，全部必须出现，不允许额外键、重复键、嵌套对象或以数字冒充布尔值：

| 字段 | 类型与含义 |
|---|---|
| title | 非空字符串，最多 200 个用户可感知字符 |
| notes | 字符串，最多 20,000 个用户可感知字符 |
| due_at | 带 Z 或明确偏移的完整 ISO 时间字符串，或 null |
| time_zone | 有效 IANA 时区、UTC/GMT，或 null；与 due_at 同时为空或同时有值 |
| reminder_requested | 布尔值，仅代表模型建议，不能授予通知权限 |

- 参数原始 UTF-8 最多 65,536 bytes；时间校验严格检查 Gregorian 日期、时分秒和偏移范围，不接受被系统日期解析器自动规范化的 2 月 30 日或越界时差。当前提案时间支持 2000–2100 年的绝对时间范围。
- 模型不能提供 owner、taskId、审批或已执行状态。客户端签发绑定账号、会话、助手消息、源用户消息与原文摘要、配置指纹的不可变提案和稳定任务 ID。
- Chat Completions 聚合 tool-call index/id/name/arguments；Responses 关联 output item/call_id、done 和 completed output；Anthropic 聚合内容块、JSON delta、block stop 与 tool_use 终止。
- 一轮最多一个合法工具调用。并行、未知工具、半截 JSON、超限、取消、网络失败或终止不完整均不能产出可执行提案；有效文字的普通空输出保护保留。
- 同一配置和协议的后续请求保留必要供应商上下文：Responses reasoning/encrypted_content 及受限 reasoning_text 内容；Anthropic thinking/signature；不同配置仅保留普通可见文字，不发送旧 opaque 状态。

## 4. 确认与持久化

1. 完整工具流成功后将建议保存到 ChatMessage.taskProposal。未完成/失败来源只能查看，不能执行。
2. 当前会话重新读取来源并签发当前审批票据；旧票据不能因重启、账号 ABA、改源或重新进入页面而自动恢复执行权。
3. 用户编辑标题、说明、日期和时区。提醒默认关闭；即使模型请求提醒，也需用户明确开启。开启提醒必须有明确到期时间。
4. 执行器在同一 MainActor 连续段最终校验来源，然后把真实 task 与 saved 回执写入同一个原子 JSON 仓库提交。任务先以 reminderEnabled=false 保存。
5. 若用户要求提醒，随后只更新这条已保存任务，并经真实 ReminderCoordinator 再次校验来源、权限、记录 CAS 和系统安排。失败保留已创建待办，不重复创建。
6. 用户拒绝时只保存 declined 回执，没有任务或通知副作用。

回执字段包括 ownerId、proposalId、taskId、decision、reminderState、committedAt、revision 和可选 continuationAttemptId。owner 命名空间使用原始 UTF-8 的 Base64；任务和回执不会靠显示名称归属。首次提交先选定仓库明确的 Unix 秒表示，保证回执在内存、重启读取与 CAS 中精确一致。

旧仓库没有 taskToolReceipts 字段时兼容为空；字段显式为 null、错型、非法归属或越界修订则拒绝加载和覆盖。已处理回执保留，删除任务不会使相同建议重新创建。删除账号本机数据时会清除其回执。

## 5. 真实状态与后续回复

- saved 只表示待办实际写入。scheduled 表示该次保存流程完成系统安排，不保证通知送达；后续任务编辑和系统状态也可能改变。
- 界面将通知结果明确表述为创建时的历史回执，不把旧回执当作当前提醒设置。
- 来源变化、取消或回执写入失败发生在任务已提交之后时，不能伪称任务回滚。未确认的提醒结果保持 pending/unknown，用户可在任务列表检查。
- “让助理继续”先提示费用并重新核验目的地。专用继续最多一次持久尝试：仓库 CAS 声明 continuationAttemptId 后才允许网络启动。删聊天标记或重启不能恢复该专用尝试。
- 该声明不证明 HTTP 已发送或回复已完成；声明后取消、崩溃或失败可能消耗此次尝试。不会自动重试或重新执行任务，用户仍可普通发送新消息。
- 后续回复关闭新工具调用；结果来自真实仓库及回执，后来删除的任务会报告 task_no_longer_available，不从提案参数编造成功。

## 6. 历史、备份与身份

- 历史详情只读提案和回执；处理时进入当前会话重新核验。工具消息隐藏旧的普通“创建待办”入口，防止绕过稳定 ID 和专用回执；记忆、复制等明确用户动作保留。
- 本机备份 schemaVersion=1 以新增 taskToolReceipts 范围和字段保留处理记录；消息内完整提案、调用与 opaque 上下文一起受逐字段预算约束。导出不执行建议、重建任务或启用通知，也不读取真实 Keychain 凭据或原始连接配置。
- 账号比较使用原始 UTF-8；旧 JSON owner map 遇到规范等价但字节不同的冲突时安全拒绝第二个写入，不自动迁移或重映射旧 ID。
- 身份、提醒、归档、UI 许可及按账号异步任务分别有当前来源守卫。测试并不证明真实 Apple、系统 Keychain 或已交给 OS 的动作可以被任意撤回。

## 7. 验收记录

### 7.1 统一隔离测试与源码证据

- 统一入口实际完成 **23 套 / 850 个独立测试组，exit 0**。摘要为 `.build/verification/phase19-final-regression-summary.json`，完整日志为 `phase19-final-full-regression.log`。已核对分项总和为 850，日志 SHA256 与摘要一致；各定向结果已包含在统一总数内，不另行累加。
- 关键分项：task-tool-protocol 42、task-tool-capability 21、task-tool-execution 42、task-tool-export 13、ChatViewModel 167、ReminderCoordinator 88、Identity 15。其余分项以实际摘要为准。测试使用隔离仓库、可控通知后端和被拦截的网络，不等于真实模型、真实账号或系统通知送达。
- 首份统一回归/SDK 汇总的 `phase19-source-before-home-compiler-fix.json` 与 `phase19-final-source.json` 均记录 166 项源码、资源和工程输入，当时 CLI 启动后仅 HomeView 改变，摘要记录 `cliInputsUnchanged=true`。之后另有下节记录的 ProposalView 纯 UI 日期修正；当前最新清单为 `phase19-post-native-source.json`，不把全部源码清单称作未变。

### 7.2 SDK 重试与 UI-only 修复

- 首轮正式 SDK 在 HomeView 的复杂 SwiftUI 表达式发生类型检查超时，历史失败摘要保留于 `phase19-sdk-home-typecheck-failure-summary.log`；这是 SDK/UI 编译失败，不是统一 CLI 测试失败。
- 随后只将 Home 设置页拆为私有 `some View` 子表达式和 `loadSettings()`，保留原类型内全部 State、raw owner/run/config 守卫、取消、Probe 和费用确认；未使用 AnyView 或重建根 id。Home 最终 SHA256 为 `7716bfae8f5479fbe628613bf900f56b85768ce151bcd772ba7248281c86f099`。该视图不属于 CLI 编译输入，因此未改变上述 850 组测试的实际输入。
- 修复后正式官方远程 SDK 重试实际 exit 0，日志 `.build/verification/phase19-final-sdk-build.log` 与 `phase19-final-sdk-summary.log` 明确记录 **BUILD SUCCEEDED**。本节各个 `phase19-*` 文件均位于 `.build/verification/`。
- QA19 随后发现日期标签错误：夹具 `2030-01-02T03:04:05Z / UTC` 在 Asia/Shanghai 环境下显示为 11:04 AM，却仍标 UTC。仅将 ProposalView 改为按界面 locale 与指定 zone 先格式化 String，再用 Text(verbatim:) 展示；没有改 Date、模型、审批或提醒逻辑。`phase19-native-timezone-ui-fix.json` 记录前后显示与 `cliInputsUnchanged=true`。
- `phase19-post-native-source.json` 同为 166 项，对比上一份最终清单只改 ProposalView，最新 SHA256 为 `8e5d6821aad992c2fc74b12b265276852ba2b230e7a23378b87369c6b042fae0`；累计两次 UI 修正均不改变 CLI 输入。再次正式 SDK 构建 exit 0 / BUILD SUCCEEDED，日志为 `phase19-post-native-sdk-build.log` 与 `phase19-post-native-sdk-summary.log`。安装实际成功，`phase19-post-native-installed-build.json` 确认全部冻结源码和已安装二进制与构建匹配。

### 7.3 原生 QA19：限定子集与未测路径

- 首个成功构建的二进制已实际通过 UI 拒绝本机提案；仓库真实写入 revision=1、decision=declined、reminderState=notRequested 的一个回执，tasks 仍为空，没有创建任务。真实重启后拒绝状态与原未发送草稿保留，仓库字节未变。证据为 `phase19-native-local-after-decline.json`、`phase19-native-decline-before.png` 与 `phase19-native-decline-after.png`。
- 首个二进制的 failed-source/history 观察保留为早期范围；日期修正后的最终二进制已再次验证 failed-source 为 Result unconfirmed、明确未完成来源只读且无复核/拒绝/继续执行按钮，历史 body-memory 正文与 Copy 入口保留，仅有进入当前对话复核的路由，无直接创建执行。两处均显示 3:04 AM + UTC。最终截图为 `phase19-native-final-failed-source.png`、`phase19-native-final-history-readonly.png`；不将“入口可见”扩大为批准、复制或继续已执行。
- 日期修正后的最终二进制已确认 qa19-decline 显示 Jan 2, 2030 at 3:04 AM + UTC、Declined，未发送草稿仍在，无复核/拒绝/继续按钮。`phase19-native-timezone-ui-fix.json` 的 nativeRecheckPassed=true 与 `phase19-native-timezone-corrected.png` 记录了 11:04→3:04 的实际修正；按钮缺席不等于已执行一次继续。
- 最终范围汇总为 `phase19-native-ui-checks.json`：166 项输入全部匹配，仓库当前字节与拒绝后副本一致。独立 SQLite mode=ro 检查报告 integrity ok、迁移完成、5 会话/10 条唯一消息及来源摘要有效、5 份草稿；拒绝草稿保留 39 字符。仓库只有一个拒绝回执，taskId 与 continuation claim 均为空，任务/记忆均为零；不声称已清空 QA 夹具。重装后的 dataContainer 正常变化，`phase19-native-stage.json` 保留 initialDataContainer，不能把路径变化当作数据丢失或用户数据恢复证明。
- 没有向 QA19 Keychain 写入测试 API Key，也没有播种工具能力证明。当前 relay 未能稳定滚动到设置下部，故原生费用确认、能力验证/启用保存、批准、编辑保存、专用继续确认/取消，以及有效当前 Key/证明下的陈旧配置审批保护**均未测试**；不能以协议 42、执行 42、VM 167 或探针 21 的隔离结果替代。
- 没有调用真实模型/平台接口、真实登录、IAP、通知授权或送达；也不声称剪贴板或完整本机任务创建已通过原生验收。完整目标与独立发布门禁继续保留，原生不是整体验收完成。

强制 iPhone Duo 专用设备/姿态验收、真实上游、Apple/StoreKit、通知送达、签名/TestFlight 与服务端对接仍为发布门禁。2026-10-30 本机 simctl 设备类型清单未发现 Duo/Fold，普通 iPhone 测试不能替代该项。
