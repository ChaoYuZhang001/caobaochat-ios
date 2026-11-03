# 本地备份恢复：实现与验证边界

更新日期：2026-10-30。范围：Phase 20 客户端本地 JSON 备份恢复。

本文记录当前生产源码的接口与默认行为。命令行检查、SDK 编译、原生操作和真实服务联调分别记录，不能相互替代；当前完整客户端发布目标仍未完成。

## 1. 产品范围与信任边界

- 入口为“数据与隐私 → 导入本地备份”。用户选择文件，先查看候选记录与安全说明，再明确确认合并；选择和预览不会自动写入业务数据。
- 只接受 `caobao.assistant.local-export`、`schemaVersion=1`、`dateEncoding=unix-seconds` 的兼容备份。新增的可选 v1 字段允许缺失，显式 `null` 不等同于旧版本缺失字段。
- 备份中的 `ownerId` 必须与当前数据范围的原始 UTF-8 字节完全一致，不提供跨账号迁移、自动认领、Unicode 规范化或模糊匹配。
- “此设备”及 `local-device` 是本地范围标签，不是文件来源、设备归属或账号身份已通过验证的证明。SHA-256 摘要用于重试识别，不是签名或身份凭证。
- JSON 为明文，可能含私人会话、图片、草稿、记忆和任务。仅选择可信文件。用户主动写入正文的敏感文字会保留，不承诺扫描或清除正文中的凭据样式文本。
- 恢复本身不联网、不调用模型、不申请或安排通知、不执行 AI 工具。服务器账号导出、云同步、Apple 登录及订阅权益不属于此功能。

## 2. 组件与调用顺序

| 组件 | 职责 |
| --- | --- |
| `AssistantDataManagementView.swift` | JSON 文件选择、只读安全作用域、预览、明确确认、当前身份/运行结果校验、部分失败后的再次确认 |
| `AssistantDataImport.swift` / `AssistantDataImporter` | 有界读取、JSON 语法与字段检查、归属/记录/图片验证、生成不可变恢复计划、去除执行能力 |
| `AssistantBackupFileReader`（同一源码文件内） | 只读、不跟随末级符号链接、非阻塞打开；对已打开的同一文件描述符做 `fstat` 常规文件校验，拒绝目录、FIFO 等输入 |
| `AssistantDataImportPlan` | 仅包含验证后的 owner、文件摘要、导出时间、会话/草稿/记忆/任务数组和预览计数；不保留 URL 或原始 JSON |
| `ChatViewModel.restoreLocalBackup(_:)` | 当前范围与忙碌状态校验、保护当前会话/草稿、协调两个存储、控制取消和结果发布 |
| `AssistantChatArchive.restoreBackup(...)` | 会话与草稿的 SQLite 插入式合并、删除标记保护、摘要记录和事务提交 |
| `AssistantLocalRepository.restoreBackup(...)` | 记忆与任务的插入式合并、安全默认值、工作区摘要记录和原子 JSON 保存 |

执行顺序：

1. 文件选择只接收单个 JSON。本地读取与解析在 detached worker 执行。文件以 `O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK` 打开，对同一 FD 校验常规文件后有界读取，不以先查路径元数据代替句柄校验；安全作用域与句柄在结束或失败时释放，取消传播给 worker。
2. 生成计划后展示候选数量、导出时间、已省略图片数量、转为文字的提案数量和不恢复的回执数量。
3. 确认操作绑定原始 owner、计划摘要、独立确认 run 和身份 epoch，不能由旧确认回调批准后来选择的文件。
4. VM 排除生成、图片处理、工具处理和其他归档操作，并持有归档 gate。先在同一次 SQLite 事务中保存当前真实会话/草稿，再合并备份会话与草稿。
5. SQLite 成功后再次校验身份、会话来源和归档授权，再以独立最终提交许可执行工作区恢复。
6. 仅向仍然有效的 owner/run/epoch 发布结果；更新历史列表，不自动打开恢复的会话，也不替换当前输入草稿。

导出与导入界面互斥。账号切换、登录/退出通知及页面离开会使尚未完成的预览、确认和结果发布失效。相同 owner 的退出再登录也不能复用旧授权。

## 3. 合并规则与安全默认值

### 3.1 会话、消息与草稿

- 仅新增；相同 ID 的本地记录优先，内容不同计为冲突，不覆盖本地正文。
- 本地会话删除标记阻止会话及其草稿复活。导入的记忆删除标记也不会覆盖已有本地同 ID 记录。
- 已有当前草稿先保存，其槽位不能被导入替换；恢复草稿保持非活动状态。
- 新会话可能只有未发送草稿、尚无历史会话正文。非空孤立草稿会生成可在历史中打开的空会话；有 ID 时保留原 ID，无 ID 时使用 `restored-draft-<backup SHA-256>`。无可读内容的孤立空草稿忽略。
- `pending` / `streaming` 消息转为 `failed`；移除 `requestId`、`generationId`、`replacesMessageId` 和服务端会话 ID，不能恢复旧网络生成。
- AI 待办提案通过原有生产验证后，转成带明确只读说明的普通可见文字；保留必要的人类可读建议及历史决定说明，不保留 `taskProposal` 执行结构。

### 3.2 记忆、任务与权限

- 新增有效记忆的 consent 为 `unconfirmed`，仍需用户明确确认后才能用于模型上下文。删除记忆不恢复已删正文。
- 新增任务统一 `reminderEnabled=false`、`requiresApproval=true`；原任务状态可保留，时间/时区/重复规则仍须通过验证。
- 登录凭据、API Key、模型连接配置、能力证明、通知许可及工具处理回执不恢复。现有记忆总开关、分类策略和安静时段保持不变。
- 本地已保存的工具回执继续保护其任务 ID，不能通过导入重新创建已被该回执处理过的任务。
- 历史说明文字不证明当前任务存在、提醒已安排或通知已送达。后续用户主动把恢复文字用于新对话，仍走正常对话与逐条工具确认流程。

## 4. 输入与资源限制

| 项目 | 当前限制 |
| --- | --- |
| 应用默认文件大小 | 32 MiB；读取循环的实际字节上限为准，不只依赖文件大小元数据 |
| 解析器可注入配置 | 正数，最大 64 MiB；不是面向用户的设置 |
| JSON 结构 | 重复对象键（含转义后的同名键）拒绝；嵌套深度最多 32，节点最多 250,000，单对象键数最多 64 |
| 记录数量 | 会话最多 1,000（含合成草稿会话），消息总数最多 10,000；记忆和任务各最多 10,000；候选草稿最多 1,001；回执最多 10,000 |
| 标识 | 非空、最多 1,024 UTF-8 字节、无控制字符；重复或归属不一致的记录拒绝 |
| 会话大字段 | 标题、预览、单条消息、草稿文字分别最多 1 MiB；记忆/任务另遵循现有工作区文字限制 |
| 图片 | 每条消息/草稿最多 3 张；JPEG，像素尺寸与声明一致；最长边 1,600，JPEG 文件字节最多 512,000，base64 最多 700,000 UTF-8 字节 |
| 日期 | 有限值；与现有日历策略一致，`Date.distantPast` 至公历 9999 年末，不再限定在 1970–2200 年 |
| 工作区重试摘要 | 每个原始 owner 最多 256 个不同备份摘要；达到上限拒绝新的工作区恢复，已有摘要仍可识别 |

关闭图片的备份不能夹带图片内容。解析器对记录、文本和图片分别预检，预检失败不会进入业务写入阶段；各存储仍独立复验，后阶段失败可产生下一节的部分结果。32 MiB 是文件/部分存储输入的限制，不是整个进程峰值内存承诺。

## 5. 原子性、失败与重试

两个存储分别原子保存，**不是跨存储事务**：

- SQLite：本次会话、草稿、摘要标记在一个事务中提交；未完成提交的失败回滚该事务。
- 工作区：记忆、任务、摘要标记与现有偏好组成候选快照，经最终许可后原子写入，再替换内存状态。
- 第一阶段失败不会继续调用第二阶段；第一阶段成功、第二阶段失败时，第一阶段保留，不声称已全部回滚。
- 取消或身份变化发生在提交开始之前可阻止相应提交；已经开始或完成提交后，取消只使后续工作与界面发布失效，不保证撤销已有数据。

`AssistantDataImportResult` 的 `archive` 始终存在；`workspace=nil` 表示工作区未完成，`workspaceError` 说明该阶段失败。只有工作区结果存在且没有工作区错误，`isComplete` 才为 true。

预览数量是候选记录数，实际新增数可因冲突、删除标记和已处理摘要而更少。结果中的新增数属于本次尝试；`alreadyApplied` 只有两个存储均识别已处理摘要时才成立。

部分失败时，当前有效页面保留同一不可变计划，用户必须再次明确确认才可重试。离开或身份变化会清除预览，需重新选择原文件。两个存储各自识别原始文件字节的摘要，已完成阶段不会重复新增；改写、重新序列化或重新导出文件可能生成另一个摘要。

重试不替代原因处理。特别是工作区 256 个摘要容量上限不会仅靠再次确认消失；应检查实际错误，保留已经完成的会话恢复结果，不把永久失败描述成自动可恢复。

## 6. 验证时间线与当前门禁

### 6.1 已完成的隔离检查

| 检查 | 实际结果 | 范围 |
| --- | --- | --- |
| `Scripts/test-assistant-data-import.sh` | 29 组，通过，exit 0；FD 加固后再次通过 | 实际导出 → prepare；孤立/无 ID 草稿；1969/2201 任务；U+0085 拒绝；提案与回执中和及有界输入 |
| `Scripts/test-assistant-backup-file-reader.sh` | 新增 6 组，通过 | 真实临时常规文件、符号链接、目录、FIFO；验证非阻塞拒绝、描述符释放及原有取消/大小边界 |
| `Scripts/run-archive-restore-checks.sh` / `Scripts/test-assistant-archive.sh` | 新增 19 / 原有 38 组，通过 | 真实临时 SQLite；不等于原生系统文件提供器验证 |
| `Scripts/run-repository-restore-checks.sh` / `Scripts/test-assistant-repository.sh` | 新增 28 / 原有 101 组，通过 | 临时工作区文件；不调用网络、通知或工具 |
| `Scripts/test-assistant-data-import-viewmodel.sh` | 新增 15 组，通过 | 实际 VM、解析器、导出器与存储；测试身份壳，零 HTTP，无系统通知集成 |
| View 语法解析、两语言 `.strings` 校验 | 通过 | 各 841 个键、无重复；仅语法/资源，不替代 SDK 类型检查 |

定向分项不重复累计到统一总数。对应日志在 `.build/verification/`，包括 `phase20-data-import-regression.log`、`phase20-importer-after-fd-regression.log`、`phase20-backup-file-reader-regression.log` 和 `phase20-archive-restore-regression.log`。

### 6.2 加固前基线与最终源码

| 时间范围 | 证据与状态 |
| --- | --- |
| FD 加固前统一回归 | **27 套 / 941 个独立组，exit 0**；`phase20-pre-file-hardening-full-regression.log`、`phase20-pre-file-hardening-regression-summary.json`；不是最终源码回归结论 |
| FD 加固前正式 SDK | 实际 exit 0 / BUILD SUCCEEDED；`phase20-pre-file-hardening-sdk-build.log`、`phase20-pre-file-hardening-sdk-summary.log`；只对应该时点的生产输入 |
| 输入变更来源 | `phase20-file-hardening-provenance.json`：177 → 179 项，原有 Importer/统一脚本变化，新增文件读取测试和脚本；不声称全部源码始终未变 |
| 最终冻结清单 | `phase20-final-source.json`，179 项；已注册第 28 套 backup-file-reader 检查 |
| 最终统一回归 | **28 套 / 947 个独立组，exit 0**；`phase20-final-regression-summary.json`、`phase20-final-full-regression.log`；包括新增文件读取 6 组，不另行累计 |
| 最终正式 Simulator SDK | 实际 exit 0 / BUILD SUCCEEDED；`phase20-final-sdk-build.log`、`phase20-final-sdk-summary.log` |
| 最终构建与安装 | `phase20-installed-build.json`：179 项输入匹配、已装二进制与构建哈希匹配；普通 QA19，不等于 Duo 验证 |

上述证据文件均位于 `.build/verification/`。已核对最终 28 个分项总和 947，完整日志 SHA-256 与摘要相同，最终 179 项输入匹配。Simulator 编译与安装匹配不等于原生完整功能、实机签名或 TestFlight 验收。

### 6.3 已完成的早期原生子集

仅使用独立普通 iPhone QA19（`725D4AF8-599C-4E04-B254-4A9E7D2C2C44`）与合成数据。FD 加固前的构建实际导出 5 个会话、0 记忆、0 任务的 JSON 到 On My iPhone，再通过系统文件选择器选择约 12 KB 文件；原生预览显示 5 会话、5 草稿、5 个转为文字的提案和 1 个忽略回执。预览截图为 `phase20-native-import-preview.png`。

同一早期二进制先实际打开“检查并合并”确认并取消：取消前后业务源数据字节一致，会话与工作区恢复标记均为零。随后实际明确确认首次合并，结果界面显示各类新增均为 0、冲突 5。只读磁盘复核为 5 会话、0 任务、0 记忆、1 个既有回执；两个存储各保存同一摘要的一个恢复标记，移除新增摘要元数据后的工作区内容与基线完全一致。证据 `phase20-native-after-first-merge.json`、`phase20-native-first-merge-result.png`。

这证明早期原生现有冲突保留与两阶段提交，**不证明原生新增记录导入**。安装记录单独保留为 `phase20-pre-file-hardening-installed-build.json`，该阶段截图不替代下一节的最终 FD 二进制复验。未写测试 API Key/能力证明，未进行真实 HTTP、IAP 或通知授权。

### 6.4 最终 FD 二进制的实际重复恢复

179 项输入匹配的最终正式构建重装后，实际通过系统 Recents 选择同一约 12 KB 文件，最终 FD 常规文件读取成功；预览仍为 5 会话、5 草稿、5 个中和提案、1 个忽略回执，再明确点击 Review / Confirm Merge。实际 AX 结果为 `This backup has already been processed. It was not imported again.`，会话/草稿/记忆/任务新增均为 0，新增冲突为 0。

只读复核确认工作区文件与首次合并后**逐字节一致**，两个存储仍各只有同一摘要的一个标记；SQLite integrity 为 ok，仍为 5 个会话、5 份草稿，活动槽 `c:qa19-failed-source`，0 任务、0 记忆、1 个既有回执。未重复创建任务、回执或恢复标记。

证据为 `phase20-native-ui-checks.json`、`phase20-installed-build.json`、`phase20-native-final-repeat-result.png`；汇总明确最终源码 179 项未变、安装二进制匹配、验证范围为现有内容的重复恢复，`fullClientGoalComplete=false`。预览中的 5 个中和提案是计划计数，**不代表本轮新增了 5 条只读历史**。本轮没有模型/探针/通知操作，没有写测试 Key 或能力证明。

### 6.5 仍待完成

- **PENDING：** 原生向空目的地新增记录、无效/畸形文件、账号切换、工作区 I/O 故障及部分结果后的重试。真实组件 CLI 已覆盖新增与故障，不替代这些原生操作。
- **PENDING：** 更完整的原生当前草稿保护、任务能力验证/批准/专用继续，以及其他未执行的系统交付场景。
- **PENDING：** 强制 iPhone Duo 指定设备/姿态验证；普通 iPhone 模拟器不能替代。
- **未由本功能验证：** 真实模型/平台网络、CiYuan2API 联调、Apple 登录、StoreKit、通知授权/送达、实机性能、实机签名及 TestFlight。

这些检查的后续结果只能依据实际运行证据更新。纯解析、隔离 CLI、SDK 成功或旧阶段原生检查均不能使未执行门禁自动通过；当前不声明整项恢复功能或完整客户端验收完成。
