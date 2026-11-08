# CaoBao Assistant v2 客户端联调契约

更新：2026-11-02。以下是当前客户端要求；CiYuan2API 的 CaoBao 代码已部署到生产，但服务开关仍需在配置 Apple 生产身份和模型池后启用。服务根地址由 `CaoBaoAssistantAPIBaseURL` 配置；HTTP 路径相对于该根地址，本机能力不因此新增服务器端点。最新本地记录为 **Phase 32：核心功能代码闭环与一次性任务执行修复**，客户端/服务端重点回归和 iOS/macOS Debug 构建均已通过；此前 Phase 20 的 28 套 / 947 个独立组仍作为历史回归证据。APNs/StoreKit 送达、完整原生/发布与强制 iPhone Duo 专用设备门禁仍未完成。

## 1. 公共规则

- 使用 HTTPS。认证接口接收原始 UTF-8 凭据，不能再次 Base64 编码 JWT。
- 认证后的请求使用 `Authorization: Bearer <accessToken>`。客户端不保存平台模型上游密钥。
- 普通响应为 JSON；消息生成使用 `text/event-stream`。不得通过重定向迁移带身份/对话内容的请求。
- 对话创建与消息发送使用 `Idempotency-Key`。重试同一标识必须返回同一业务结果，不能重复扣费。
- userId 从服务器验证的会话取得，不能信任请求体中的用户 ID、订阅 Boolean 或剩余次数。
- 客户端取消连接不等同于上游已取消。服务端应传播取消，并依据真实生成状态结算额度。

## 2. 身份与账号

| 方法与路径 | 请求 | 成功响应与规则 |
|---|---|---|
| `POST /auth/apple` | identityToken、authorizationCode、原始 nonce、locale、可选 storefront、设备当前 IANA `timeZone` | user 与 session，并返回区域建议和 `timeZoneRequired`；服务端验证 Apple 签名、issuer、audience、时效、nonce，并处理授权码。账号时区未固定时，服务端必须要求客户端先提交有效时区后才能领取每日额度 |
| `POST /auth/refresh` | refreshToken | 同结构新会话；用户必须与原会话一致；服务端轮换/撤销刷新凭据 |
| `POST /auth/logout` | Bearer | 200 JSON 或 204；撤销对应服务端会话 |
| `DELETE /me` | Bearer | deletionRequestId、status；202 表示任务受理，不是删除完成 |
| `GET /deletions/{deletionRequestId}` | 随机删除状态能力 | 仅返回 deletionRequestId、status、updatedAt、completedAt；不返回账号数据或清理步骤 |
| `GET /me/export` | Bearer | 原始 JSON（客户端上限 8 MiB）；不能将导出任务占位响应冒充用户数据 |

身份成功响应：

```json
{
  "user": {"id": "server-user-id", "displayName": "User"},
  "session": {
    "accessToken": "opaque-access-token",
    "refreshToken": "opaque-refresh-token",
    "expiresAt": "2026-10-30T00:00:00Z"
  }
}
```

示例令牌均为结构占位符。expiresAt 必须在实际响应时有效。删除状态支持 queued、accepted、pending、processing、running、needs_retry、completed；客户端将 pending、running、needs_retry 与完成区分展示。202 的受理不能作为删除完成证明；本机清理完成同样不证明服务器数据已删除。当前本地受理通知与恢复机制见第 11 节，服务器异步完成状态的真实查询/通知仍需服务端契约及联调。账号删除和取消订阅是不同操作，不能暗示删除账号会自动取消 App Store 自动续订。

## 3. 每日与订阅额度

`POST /entitlements/daily/claim`：返回 serviceDay、granted、remaining、claimed、nextResetAt。每天登录领取 8 次，必须由数据库事务保证同一服务日只领取一次；服务端定义服务日及重置时间。

`GET /entitlements`：

| 字段 | 类型 | 约束 |
|---|---|---|
| dailyRemaining | Int | 0…8 |
| dailyClaimed | Bool | 是否已成功领取当日次数 |
| nextResetAt | ISO8601 String? | 下一服务日边界 |
| serviceRegion | String | CN / INTL |
| regionSource | String? | user / manual 表示用户已确认 |
| allowedModels | String[] | 服务端允许当前账号使用的模型 |
| subscription | Object? | 下表；缺失表示没有可展示的订阅信息 |

subscription：plan、status、expiresAt，以及可选 `quota`。quota 用于展示**订阅额度周期**，不得将自然月、App Store 账期或客户端设备日期直接当作重置规则。

| quota 字段 | 类型 | 约束 |
|---|---|---|
| included | Int | 当前周期总额度，≥0 |
| remaining | Int | 当前周期剩余额度，0…included |
| periodStartsAt | ISO8601 String | 当前额度周期开始，含边界 |
| periodEndsAt | ISO8601 String | 当前额度周期截止，不含边界 |

仅 active / trialing / grace_period 状态且有效周期内展示订阅余额；未返回 quota 时不推算 600 次。客户端最多展示 5 分钟内验证的余额，账号变化、周期结束或凭据失效时隐藏。每日与订阅次数分开展示，不把“尚未领取的每日次数”相加为现有余额。

**套餐价格、人民币档位、600 次/月及与每日赠送是否叠加仍是商业方案，不是服务端既定配置。** 价格从 StoreKit Product.displayPrice 读取，实际权益只从服务器读取。扣除优先级、失败/中断结算、模型倍率和是否结转需由套餐配置明确，客户端不能自行决定。

## 4. 平台会话与生成

- `POST /conversations`：clientConversationId、title、locale；Idempotency-Key 为 `conversation.<localId>`；返回 `{"id":"server-id"}`。客户端后续只使用返回的服务端会话 ID。
- `POST /conversations/{serverId}/messages`：requestId、clientMessageId、conversationId、mode=platform、locale、persona、content、context、stream；Idempotency-Key 为 requestId。
- 平台消息还包含已确认的 `serviceRegion`（CN/INTL）；选择具体模型时包含 `model`，自动模式省略该字段。`clientConversationId` 保留本地关联，正文 `conversationId` 必须与 URL 中服务器 ID 一致。服务端必须再次校验区域、模型权限和额度，不得直接信任客户端选择。
- content 使用结构化 text/image parts；图片包含 mimeType、base64Data、width、height。客户端最多 3 张，单张重新编码后不超过 512,000 bytes。服务端必须独立做媒体校验、解码预算与模型能力检查。
- context 包含 messageIds/memoryIds/taskIds 及实际 messages/memories/tasks 快照。本地 ID 不能替代实际内容。服务端将快照视为用户参考数据，不能提升为高优先级指令。
- 生成事件支持 started/generation/metadata 的 generationId、delta 文本、usage、completed；失败必须明确。工具调用不能被当作普通文本完成，当前客户端不会执行工具。
- 服务端应在调用上游前预留额度，按最终真实状态提交/释放；不能依赖客户端最后是否收到了 completed。

## 5. StoreKit 订阅

`GET /subscriptions/apple/config` 返回 userId、appAccountToken（UUID）、productIds。token 必须绑定当前 CaoBao 用户且稳定，不能从任意客户端输入生成归属。

`POST /subscriptions/apple/verify` 接收 signedTransaction、transactionId、productId、appAccountToken，携带幂等键；返回 verified=true、userId，以及 subscription 的 status、productId、originalTransactionId、expiresAt。

服务端必须验证 Apple JWS 签名链、bundleId、environment、product、交易归属、撤销与到期等状态；必须处理服务端通知、退款、撤销、续期、宽限期及重复验证。客户端只有在本地验证与服务端确认均通过后才 finish 交易，不通过本地布尔值授予权益。权益最终回读 `GET /entitlements`。

## 6. 偏好、BYOK 与同步边界

- `PATCH /profile/preferences`：请求包含 locale、personaLevel、proactiveLevel、serviceRegion、regionConfirmed、assistantMode 和可选 IANA `timeZone`；成功响应返回 server-owned `preferences` 快照（含 regionSource、timeZoneLocked）。`assistantMode=byok` 仍是设备本地设置，不上传。当前 StoreKit storefront 仅用于区域建议；不能证明下载时账号、国籍、实际位置或数据驻留授权。用户确认后应用区域策略。
- BYOK 由设备直接访问用户配置的 HTTPS 服务；支持 Chat Completions、Responses、Anthropic Messages。密钥留在 Keychain，不上传 CaoBao，不消耗平台次数。完整目标地址、协议、模型或密钥变化后重新确认上下文发送。
- 当前历史、草稿、记忆和任务为按用户隔离的本地数据；本地提醒支持一次性及每日/每周重复，安静时段的有限批处理见第 17 节。跨设备同步、后台任务/APNs 和工具执行尚需独立契约与服务端实现，不能据此文档假设已经存在。
- 安静时段为 owner 隔离的本机提醒偏好，使用第 13 节的仓库/协调器接口；不加入 PATCH /profile/preferences，不上传服务器，也不控制其他应用或尚未接入的服务器推送。

## 7. 区域模型目录

`GET /models?region=CN` 或 `GET /models?region=INTL`，使用当前账号 Bearer。服务端返回当前账号、订阅和所选区域可用的模型：

| 字段 | 类型 | 要求 |
|---|---|---|
| serviceRegion | String | 必须与请求区域一致 |
| defaultModelId | String? | 当前区域默认模型；非空时必须存在于 models 且支持 streaming |
| models | Object[] | 最多 200 个，id 唯一；无权限可返回空列表与 null 默认值 |
| models[].id | String | 1…128 bytes，安全 ASCII 字母/数字及 `- _ . : /`；用于 JSON 选择，不作为 URL 路径 |
| models[].displayName | String | 非空、最多 256 个字符 |
| models[].provider | String? | 可选供应商显示资料，不含上游配置或密钥 |
| models[].capabilities | Object | vision、tools、streaming 三项 Bool 必须明确，不因字段缺失默认启用 |

客户端只列出支持流式的模型，按用户和 CN/INTL 分别保存选择。目录最长 5 分钟内有效；账号/令牌变化清空。目录不可用时显示错误，不用合成目录或虚构模型权限；已保存的选择不能导致静默调用其他模型。自动模式由服务端按区域配置决定默认模型。

## 8. BYOK 显式连接检测

连接检测完全在设备与用户配置的 API 服务之间进行，不新增 CaoBao 平台端点。点击前说明目标服务及可能发生的 API 费用；只发送固定测试词，不带会话、记忆、任务或图片，设置约 16 个输出 token 上限。Responses 保持 store=false。

成功必须收到有效文字、正常终态和 EOF；HTTP/格式/工具/空结果/截断/超时不得伪装成功。总时限默认 20 秒，可停止；配置改变、账号变化或关闭设置使结果失效并取消底层请求。检测不写历史、不扣平台次数、不静默切换服务，不等于已验证图片、工具能力或真实模型质量。

## 9. 本地助理备份（无新增 HTTP 端点）

服务器 `GET /me/export` 与本地 `AssistantDataExporter` 是两个不同范围。前者只返回服务器账号资料；后者只读取指定 owner 的本机归档和助理仓库。当前 UI 分开提供入口，不能将其中之一标为“已经导出全部云端与本机数据”。

### 9.1 本地文件结构

| 字段 | 类型 | 当前语义 |
|---|---|---|
| schemaName | String | 固定 caobao.assistant.local-export |
| schemaVersion | Int | 当前为 1 |
| dateEncoding | String | unix-seconds；Date 统一编码为 Unix 秒数，可能含小数，解码应使用 secondsSince1970 |
| ownerId | String | 本次请求的本机数据归属；匿名 BYOK 工作区当前为 local-device |
| exportedAt | Number | 生成时间，遵循 dateEncoding |
| includedScopes | String[] | conversations、draft、memories、tasks、memoryPreferences、reminder-preferences |
| imagesIncluded | Bool | 本次是否包含消息及草稿图片，不代表一定存在图片 |
| omittedImageCount | Int | 明确排除的附件出现次数，含草稿；不是不同图片 ID 的去重数量 |
| conversations | Object[] | 会话与消息、状态、请求/生成 ID、模型及 usage；保留流式部分结果的原状态 |
| draft | Object | text、可选 images、可选 conversationId |
| memories | Object[] | 该 owner 的全部记忆状态，含禁用记录与删除墓碑；墓碑正文为空且不恢复来源消息 |
| tasks | Object[] | 任务及其状态、时间/时区、已有重复规则和提醒设置；导出不执行任务或安排通知 |
| memoryPreferences | Object | memoryEnabled 与 excludedMemoryCategories |
| taskPreferences | Object | quietHours 对象：enabled、startMinute、endMinute、timeZoneIdentifier；字段规则见第 13 节 |

taskPreferences.quietHours 和 reminder-preferences scope 是 schemaVersion=1 的新增内容，不删除或改义旧字段。兼容读取方应忽略未知字段，并在旧备份缺失该偏好时采用默认关闭；这是字段兼容约定。当前客户端已实现本机备份导入/恢复，恢复仍只写入当前 owner 的本地存储，不代表云同步或自动启用提醒。导出只读取当前 owner 的类型化偏好，字段树预算明确计入全部 quietHours 字段及 scope，不扫描任意 UserDefaults。

凭据和连接配置不属于该本地文件范围：服务不读取或附加 Keychain 的访问/刷新 Token、API Key，或 UserDefaults 连接配置。除明确列出的 memoryPreferences 和 taskPreferences 外，其余语言、人格、模型选择等设备偏好不在此 schema 中。用户主动写在会话、草稿、记忆或任务里的原文会保留，不能以正则自动删除“看起来像 Key”的内容后仍宣称原文完整。文件为普通未加密 JSON，应由用户决定保存位置。

### 9.2 生成、取消与保存

- UI 首先调用真实 ChatViewModel 的 flushForDataExport，将当前 owner 尚未写盘的输入草稿、图片和流式片段保存；flush 出错则不返回“完整备份”。这一步不主动停止生成。
- 数据准备在后台任务执行，持有显式 owner/run；读取后、拷贝/预算循环及编码后协作检查取消。账号变化会撤回待展示文档、取消准备并丢弃旧结果。
- 默认输出预算 32 MiB，调用配置最大 64 MiB；先计算字段树预算，再编码并复核最终 Data。包含图片超限时明确报错，用户可以主动选择不含图片重试；不以静默截断制造成功。
- 仓库快照必须传播真实加载失败，不能将普通 mutation 的 lastError 等同于加载失败。归档仅在确实不存在时为空；ENOTDIR、权限或损坏不能伪装成空备份。导出不改写来源文件。
- 输出预算不是来源 JSON 的读取/解码内存上限，各存储读取有自己的锁，但当前没有跨会话文件和仓库的全局事务一致性保证。
- 准备 Data 不等于保存成功。当前通过 FileDocument/fileExporter 交给用户选位置，只有成功回调且 owner 仍匹配时显示保存成功；取消和失败另行显示。准备本身不发起上传，用户选用的文件供应商可有自己的同步机制。
- 服务器导出预览仅展示最多 16,384 个 UTF-8 字节，保存仍使用完整响应 JSON；这不是本地备份 schema，也不能据此声称真实服务器导出和文件保存已经联调完成。

本阶段已经验证一个 iPad 匿名工作区的小样本原生保存，并读取生成的 CaoBao-assistant-backup.json；检验副本位于 `.build/verification/local-export-simulator.json`，逐项 UI 验收记录为 `.build/verification/local-data-ui-checks.json`。样本包含草稿，其他记录数量为0，图片选项为 true；该结果不代替多图片、大容量、所有文件供应商、真机或真实账号验收。当前本地备份导入/恢复已由独立协议、文件读取和 ViewModel 测试覆盖；跨设备恢复和云同步仍需真实设备验收。

## 10. 本地记忆类别隐私

- 全局记忆开关与类别开关均按 userId 存储；类别为 fact、preference、importantDate、followUp、sharedContext。类别关闭仅停止 ContextBuilder 主动选择该类长期记忆条目，不删除其本地记录。
- 全局关闭时所有类别均不被选择；重开全局后保留原类别排除设置，不将各类别默默重置为允许。记忆仍可编辑、删除或导出。
- 真正删除保留 deleted 墓碑，清空 text 和 sourceMessageId；导出快照也保持该清空语义。类别排除列表进入本地备份的 memoryPreferences，禁用状态不得因导出或未来恢复而被提升为同意。
- 这些是当前本地策略，不新增 PATCH 端点，也不表示服务端已同步该类别选择。平台/BYOK 请求只附加经过本地选择的记忆快照；未来同步协议必须另外定义策略合并、删除墓碑与版本。
- 开关不改写现有会话/草稿/任务中的用户文字，也不回收此前已经发给上游或保存在服务器的内容；不能将“停止附加长期记忆条目”描述为已完成历史数据远程删除。

## 11. 账号删除受理通知与本机清理恢复

### 11.1 分离服务器与本机状态

远端动作由 `DELETE /me` 和状态只读的 `GET /deletions/{deletionRequestId}` 组成。DELETE 返回 deletionRequestId/status；由于服务端会立即撤销账号会话，后续状态查询使用该随机、不可猜测的请求 ID，不携带已撤销 Bearer token。客户端必须分别表达：服务器已受理、服务器确认完成、本机组件已清理。不能因 HTTP 202、退出登录、文件删除成功或用户关闭提示而把服务器状态升级为 completed。

客户端在收到有效受理后，先通过 `AssistantDeletionNoticeStore` 保存版本化的元数据任务，再授权 `AssistantDeletionCleanupCoordinator` 执行本机清理。元数据按 ownerId、服务 origin、服务器 requestId 关联，含任务 ID、受理时间、服务器状态、待处理组件和提示关闭状态；不含 Token、Key、消息、记忆正文或任意错误原文。不同账号、不同服务 origin 的任务不得互相覆盖。

本机待处理组件为 reminders、memoriesAndTasks、conversationsAndDraft、apiKey、preferences。每个组件成功后更新剩余项，单个失败保留该项，不把一次部分成功记为全部完成。损坏或无法保存的任务记录不能被当作空队列覆盖；无法确认清理时必须明确提示，不能伪造可恢复任务或完成结果。

### 11.2 恢复与通知规则

- 账号删除结果横幅放在登录、认证后及本机 BYOK 根内容之外，原会话退出不会让结果完全消失；旧账号提示不展示给随后已登录的账号。
- 只有已持久化、当前服务 origin 匹配的受理任务能授权重试。重试按钮仅在存在可重试待处理项且没有元数据读取问题时出现。
- `retryPendingLocalCleanup` 只在退出登录时运行，只处理待处理组件；不刷新 Token、不重复发起 DELETE、不请求模型，也不修改新登录会话。元数据异常时提示联系支持，而不是推断任意 owner 并清理。
- 清理前后检查身份与代次，身份变化、同账号重新登录或取消会停止后续工作；迟到旧结果不能登出或清空新会话。关闭提示不会删掉尚未完成的清理任务。
- 客户端在前台恢复时用已保存的请求 ID 查询 `GET /deletions/{deletionRequestId}`，只更新对应 owner/origin 的服务器状态；网络失败或未知请求保留原元数据并在下次前台重试。本机重试不会刷新 Token、再次请求删除或清理其他账号。
- 账号删除不取消 App Store 自动续订。订阅管理仍须通过 App Store 的独立流程。

### 11.3 历史阶段验证范围

该历史阶段已验证版本的完整客户端回归为 **221 个独立测试组，exit 0**：其中本地导出16、删除通知/协调器18、仓库17、归档10、真实 ChatViewModel 集成29。删除测试使用隔离元数据与 fake cleaners，不是实际账号删除、Keychain 或通知中心清理的生产验证。该数量不能证明之后的历史删除/导航或安静时段变更；当前 `.build/verification/summary.json` 已更新为第 13 节的 299 组。

该历史阶段 Simulator 构建已成功；iPad 本机文件保存和类别开关 UI/磁盘变化有具体证据。它们均不能证明 CiYuan2API 已实现、Apple/StoreKit 已联通、真实用户全量删除已完成或 **iPhone Duo 已适配验收**。US$9.99/月、600次/月及赠送叠加仍是未配置的提案。


## 12. 本地历史与导航边界（无新增 HTTP 端点）

当前客户端历史来自 owner 隔离的本机归档。单条、批量、全部清理只作用于该账号的本机记录及命中的持久草稿；不请求旧版云历史，不把本机清理声称为服务器会话或账号数据已删除。云端会话生命周期及同步仍需独立接口和真实联调。

- 所有历史读取/删除同时校验当前身份与已激活 owner。UI 导航保存会话 ID/owner，详情重新解析当前归档，不接受旧快照的消息内容作为权威。
- 删除当前会话时使生成 run 失效并取消 producer，不执行会重新 upsert 被删会话的普通保存路径；未命中的当前生成/输入/附件/接入确认保持不变。
- 持久草稿的 conversationId 命中删除集时同样清理或替换，避免进程重启恢复已删除会话 ID。
- 本地归档和草稿是分开的文件；部分文件提交后失败会明确报错并保留恢复内容、阻止自动写回，不提供跨文件原子性保证，也不把部分失败响应当作成功。
- 详情只提供可执行的复制；复制前重新读取 owner 与消息。跨账号旧结果不能经详情进入当前聊天。

该历史阶段真实生产 ChatViewModel 的临时目录/注入传输检查共43组，包含历史新增14组；当时全入口235组exit0。另有 iPad 合成历史 UI 往返/侧栏恢复证据，见 `.build/verification/history-ui-checks.json`。这不证明真实服务端删除、iPhone Duo、StoreKit或Apple身份联调完成；当前全入口数量见第 13 节。


### 客户端宽度导航验收补充

Home历史详情统一使用带owner的ID路由；紧凑正文列使用iOS17+原生列状态，iOS16保留Tab功能路径。普通iPhone模拟器已验证订阅导航跨正常竖/横屏保持。紧凑根页的显式侧栏动作已实现，但当前远程导航栏输入没有可靠送达证据，完整点击闭环仍未验收；此限制不改变任何HTTP接口，也不能作为Duo已完成证明。详细证据见 `.build/verification/compact-ui-checks.json` 与实施状态文档。

## 13. 本地安静时段与提醒重排（无新增 HTTP 端点）

### 13.1 配置与默认值

本机类型 AssistantQuietHours 按 owner 保存，与任务自身 timeZone 分开。当前只作用于已主动开启的本机一次性任务提醒，不表示系统专注模式、服务器推送、APNs 或跨设备配置已经实现。

| 字段 | 类型 | 约束和默认值 |
|---|---|---|
| enabled | Bool | 默认 false；不能据此启用任何 task.reminderEnabled |
| startMinute | Int | 0…1439；默认 1320，即 22:00 |
| endMinute | Int | 0…1439；默认 480，即 08:00；不得与 startMinute 相同 |
| timeZoneIdentifier | String | 明确的受支持 IANA 标识，另允许 UTC/GMT；UTF-8 最长 128 bytes；默认受支持的当前地区时区，否则 UTC |

关闭状态也要求字段合法；不接受用相同起止值表达全天安静。时区不是固定 UTC 偏移，旅行或系统时区变化不会将已保存的标识默默改成另一地区。缺少旧仓库偏好时默认关闭；无法读取或损坏不能被解释成默认关闭并覆盖原记录。

### 13.2 调度时间规则

- 使用配置时区的当地分钟，开始包含、结束不包含。endMinute 大于 startMinute 为同日窗口，小于则跨夜。
- deliveryDate(for: dueAt) 只以任务原始绝对 dueAt 锚定可能覆盖它的当地当天/前一日窗口。命中时 fireAt 取对应结束瞬间；未命中或关闭时仍为原 dueAt。禁止用 reconcile 的当前日期为旧任务重新锚定窗口，防止错过的一次性提醒每天复活。
- ReminderPolicy 先计算上述 fireAt，再要求其至少晚于 now 一秒。原 dueAt 虽早于 now、但延后 fireAt 仍在未来的提醒继续有效；原窗口结束已过去则按 pastDue 处理。不得修改任务 dueAt、任务状态或提醒同意字段。
- 夏令时重复时刻的开始取 first、结束取 last；跳过的当地时刻采用跳变后的第一个真实瞬间，不假设固定一小时跳变，覆盖半小时及历史偏移。整段窗口均不存在且无真实持续区间时不制造安静窗口；非法日期/无法计算时明确失败。
- 通知计划保存调整后的绝对瞬间；触发组件冻结任务记录时区在 fireAt 的实际偏移，避免重复钟点歧义。任务的展示时区与安静策略时区保持独立。

### 13.3 本地接口与提交边界

| 接口 | 返回与约束 |
|---|---|
| quietHours(for userId: String) throws -> AssistantQuietHours | 只读该 owner 的已保存值；校验身份、加载状态和配置，真实加载失败须传播 |
| setQuietHours(_:for:) -> Bool | 单份仓库强原子提交：暂存副本、先原子落盘、成功后换内存；false 暴露 lastError，保留先前磁盘和内存值 |
| AssistantReminderPolicy.plan(for:ownerId:now:quietHours:) | quietHours 默认 .disabled，保持旧调用兼容；纯 Foundation，无授权/系统通知/存储副作用 |
| AssistantReminderCoordinator.saveQuietHours(_:ownerId:) async throws -> AssistantReminderReconciliationReport | 检查活动 owner/session 和配置后先落盘，再对当前 owner 重排，不请求通知权限、不启用任务提醒 |

saveQuietHours 的结果必须按以下方式显示：

1. 抛错发生在提交前：身份/会话已变化、预先取消、配置无效或原子写盘失败；本次未保存，旧配置保持，不能触发通知重排。
2. 正常返回表示配置已经提交；report.statesByTaskId 表达逐任务状态，report.errors 表达部分调度失败、提交后的取消、账号切换或同账号策略竞争。存在 errors 不能改称“本次未保存”。
3. 提交后关闭页面导致取消仍执行带 owner/session 守卫的最佳努力重排；不能因此把旧 pending 留在新安静窗口。owner 变化不得继续影响新账号，界面通过 owner/run 丢弃过期结果。
4. UI 正常返回后重新读取当前 owner 的仓库值，防止旧请求值覆盖后来已保存的设置。设置页 PageIdentity 按账号识别加载状态，避免从时区页返回时重载未保存草稿；匿名本机工作区已实际验证启用与关闭草稿均保留、明确保存、磁盘字段及重启恢复，详见UI验收记录。

账号删除时清理该 owner 的安静偏好；导出采用第 9 节的 taskPreferences.quietHours。以上原子性只针对单份仓库，不承诺仓库与系统通知或其他归档文件的跨资源事务。

### 13.4 并发、失败与验收边界

- 重排保留稳定的 owner/task 通知标识，先移除违反已保存新策略的旧 pending，再尝试替换；逐任务失败继续处理其他任务，明确报告并允许前台重试。不得因开启安静时段再次弹权限，也不得静默开启旧任务的提醒。
- 每个 in-flight add 保存候选 plan、owner/session、quiet 快照与版本、operation UUID。普通 reconcile 只保留当前有效且请求与候选完全匹配的 pending；不能无条件跳过所有 in-flight。新策略版本令旧候选豁免失效，仍需清除落在新窗口的请求。
- 独立审查使用真实生产 actor 与 fake 通知后端复现过：候选已写 pending、完成尚未返回时，reconcile 按旧仓库任务删候选，最终任务保存成功而 pending=0。holdAfterStore 精确模拟系统先应用后完成的时序；修复后相同策略保留候选和最终 pending，新策略变化立即清理危险候选。迟到 add、任务 Save 和失败回滚按最新已落盘任务/策略修复，按 UUID 清理自身操作；此结果不是对真实通知中心的验收。
- 静默功能阶段统一入口曾通过 16 套脚本、299 个独立测试组，exit 0；其中 quiet-hours 31、repository 23、reminders 15、reminder-coordinator 26、data-export 20。完整分组见 [CLIENT_IMPLEMENTATION_STATUS.md](CLIENT_IMPLEMENTATION_STATUS.md) 第 9 节与 `.build/verification/summary.json`，日志为 `.build/verification/all-client-checks.log`。
- 最终 iOS Simulator Debug 编译成功，日志 `.build/verification/quiet-hours-ui-build.log`。静默设置的零活动提醒场景已实际验证保存、时区返回和重启恢复；真实通知送达和紧凑侧栏完整点击仍未验证。隔离测试/fake 通知后端和构建成功不代表真实系统授权/通知送达、服务器部署、Apple/StoreKit 或 iPhone Duo 验收完成。所有价格和额度套餐仍是提案。


### 13.5 本机界面证据与恢复

2026-10-30完成 iPhone17 Pro/iOS26.5 Simulator 匿名工作区回归，记录 `.build/verification/quiet-hours-ui-checks.json`：未保存启停在时区返回后保持，保存后字段与UI一致，重新安装/启动恢复，最终关闭并恢复原始仓库字节。场景事先确认零活动且启用提醒的任务；没有新增任务提醒同意、通知权限弹窗、真实模型或交易。该验证不代表真实账号、系统通知交付或云推送契约已经实现。

地区时区搜索对空格和下划线做等价匹配，空结果显示说明；这不改变持久化IANA标识，也不对模型服务区域做推断。UI没有修改任务dueAt，时间策略仍由原始dueAt推导通知fireAt。

## 14. 用户确认的消息派生记录（本地，2026-10-30）

本节为已实现的客户端本地契约，不新增或声称部署任何HTTP接口。

| 入口 | 约束 |
|---|---|
| ChatViewModel.makeActionSource(messageId:) | 当前账号/会话内唯一、已完成、非空文字消息；返回绑定owner/conversation/message/role/status/content及作用域、修订号的票据 |
| validateActionSource(_:) | 打开确认页和实际提交前核验；账号/会话往返、删除、重生成或原文/状态变化使票据永久失效，点赞不影响 |
| saveMemoryFromMessage(_:source:) | 同一MainActor无await核验后调用仓库insert-only，强制来源归属、explicit和active；成功后消费票据，失败不误报成功 |
| AssistantLocalRepository.insertMemory(_:) -> Bool | 锁内检查不存在同owner/ID（包括墓碑），校验并原子落盘；不支持此接口的旧repository默认false且不写 |
| AssistantReminderCoordinator.saveTask(..., validateBeforeCommit:) | 默认nil兼容旧调用。提供来源闭包时，通知查询前初验；最终MainActor复核与同步仓库提交相邻执行，中间无await；身份/quiet变更使提交许可失效，候选提醒按既有回滚路径处理 |

AssistantTask新增可选sourceMessageId，缺失按nil解码。显式数据导出保留来源且计入字节预算；不表示已经实现导入、跨设备同步或服务器来源查询。记忆沿用既有sourceMessageId。

确认页预填完整原文，正文保留缩进和尾换行；任务标题由用户填写，默认requiresApproval=true、无dueAt/recurrenceRule且reminderEnabled=false。保存仅创建计划，不批准或执行外部动作，也不触发模型请求。只有用户另行设置日期、开启提醒并保存才可能进入通知授权流程。

新内容边界为记忆正文20000、任务标题200、说明20000个Swift Character，超限要求用户编辑；旧超长内容不因新规则失去读取、导出、删除和非正文任务状态操作。不得通过自动去空白绕过边界。

本轮统一337组隔离检查与最终Simulator构建通过；本地夹具UI验证预填、明确保存、原文/来源落盘、重启恢复和历史只读，结束后恢复测试前字节。完整范围和证据见CLIENT_IMPLEMENTATION_STATUS.md第10节；真实账号/模型/通知、Apple/StoreKit、CiYuan2API及iPhone Duo仍需对应验收。

## 15. 显式重试与最新回复替换（客户端，2026-10-30）

- canPerformGenerationAction / makeGenerationActionSource / performGenerationAction仅接受当前账号/会话最后一条已结束助手回复。failed/cancelled为retry，completed为regenerate；消息正文可为空，但须有原用户问题或图片。历史详情只展示状态，不在只读页面发起生成。
- 每次用户明确确认后创建新的requestId及Idempotency-Key，沿用原clientMessageId与serverConversationId。只有原generationId和已确认的serverConversationId同时存在时，平台重试/重生成才调用POST /generations/{generationId}/retry；旧本地记录或缺少服务端绑定时回退到POST /conversations/{id}/messages。停止生成同时按requestId调用POST /generations/by-request/{requestId}/cancel，避免started事件尚未到达时留下上游任务。两者都是新的计费候选请求，服务端必须按新requestId做额度事务，并明确同clientMessageId的多次generation归属；GET generation状态仍用于断线恢复，不能把本地取消当作已完成结算证明。
- 票据绑定原用户正文/图片、目标与替换前驱的修订、owner/scope及完整配置指纹/epoch。账号/会话/内容/配置变动或改后恢复均失效，源票据不能重复消费；配置事件按owner隔离。Key只参与内存中的SHA256指纹，不写入票据或归档明文。
- BYOK确认保存send/generation意图，确认时重新准备当前已授权上下文并复验完整目的地。send须仍对应原草稿和附件；generation总是使用原问题和图片，保留新草稿。取消/失效不向任何服务商发送内容。
- ChatMessage增加可选replacesMessageId（旧档缺失为nil）。重生成先保存candidate和原completed，失败/停止保留两者；成功仅删除同一原问题内唯一、修订未变的被替换completed。failed candidate跨进程保留lineage；重试成功仍仅替换该前驱，其他历史和失败片段不截断。该字段是本地恢复/导出元数据，未新增上游HTTP字段或承诺服务端历史替换实现。
- 数据导出保留lineage并纳入精确字节预算。历史pending/streaming按展示解释为中断，不修改原始归档、不伪装服务器仍在生成或已可续传。

最终统一367组隔离检查与Simulator构建通过。普通iPhone本地夹具UI覆盖空失败入口、取消/预检数据保持、成功后替换说明和历史状态；未证明真实服务端、模型、费用、通知或iPhone Duo验收。证据和未完成项见CLIENT_IMPLEMENTATION_STATUS.md第11节。

## 16. 任务时区、条件更新与过期恢复（本地，2026-10-30）

本节是客户端本地契约，不表示部署了新的HTTP接口、Worker或APNs。

| API | 行为 |
|---|---|
| AssistantTaskTimeZonePolicy.validatedIdentifier(_:) | 校验已支持地区标识，返回原String；不静默trim、替换无效旧值或把UTC存为GMT |
| timeZone(for:) / changingTimeZone(of:to:) | 前者供显示，后者仅复制修改timeZone；不改dueAt绝对Date、内容、状态、授权或时间戳 |
| AssistantLocalRepository.updateTask(_:expecting:) -> Bool | concrete仓库的原子CAS；同锁内核owner/id与完整当前快照，staleTask / recordNotFound / invalidRecord区分，不upsert或复活删除记录 |
| saveTask(..., expectedTask: AssistantTask? = nil, validateBeforeCommit: ... = nil) | 兼容旧调用；expectedTask初验及每次实际提交均复核，最终写用CAS。validateBeforeCommit与同步提交仍按原MainActor许可边界执行 |
| updateTaskStatus(id:ownerId:status:) | 自动携带实际旧快照；inactive且提醒开启的激活若真实fireAt已过，抛reactivationRequired(原记录)，不提交候选active状态 |
| reopenTaskWithoutReminder(_:ownerId:) | 用户明确选择后关闭旧提醒并恢复active，保留dueAt/zone/rule/正文/source/审批；不申请通知权限，不自动改下一天 |

时区默认值只用于新建；旧无效zone仍可读/导出/删除及不改zone的状态更新。新增或真正改zone时验证。未改正文的元数据编辑保留旧超长标题/说明，正文变化仍服从当前长度约束。UI DatePicker绑定原Date并应用显示时区，不重解释墙上时间；标识按用户选择的原String保存。

恢复过期的判断先由原dueAt应用最新quiet策略，再比较实际fireAt；权限查询、OS排程和MainActor跳转后在真正提交前重查。另一路编辑器要求明确Save才恢复，既可改到未来，也可关闭旧提醒；取消不写。

在途记录带baseTask完整快照（nil=新建前不存在），有效豁免与add返回都复核。候选因CAS/身份/quiet/base变化失败，清理仅限自身UUID；恢复和普通reconcile都以最新仓库为准，删除不排回。私有修复预算最多两次额外pass，持续竞争则移除旧结果并报告未完成，不无限递归或误删更新操作。仍不是仓库与系统通知的全局事务，系统授权和送达需独立验收。

统一412组隔离检查和最终Simulator构建通过；普通iPhone UI验证时区/草稿/精确dueAt、旧长标题修复、两种恢复路径及取消/重启。编辑恢复UI以关闭旧提醒完成，没有实际编辑日期/钟点、真实账号切换或真实通知交付。完整证据及门禁见CLIENT_IMPLEMENTATION_STATUS.md第12节。

## 17. 每日与每周重复计划（本地，2026-10-30）

本节更新第 13、16 节的一次性限制；不增加 HTTP、云同步、Worker 或 APNs。整合验收见实施状态第 13 节。

### 17.1 规则与生效边界

- AssistantTaskRecurrence 支持空、FREQ=DAILY、FREQ=WEEKLY;BYDAY=MO,TU,...，可指定 INTERVAL=1；拒绝重复/未知字段、其他间隔、COUNT/UNTIL、空或无效星期。ISO 星期周一 1 至周日 7。输入最多 512 UTF-8 字节；候选数量 0...32，零也验证模板。
- 重复 dueAt 只提供记录时区的当地时分，安排时秒为零；日历日期不是未来开始门槛。nextOccurrences 严格返回下界之后的候选。一次性仍使用完整绝对日期。
- recurrenceStartsAt 是仓库生成的可选生效下界。新建、语义规则/当地时分/时区改变、非活动恢复活动、提醒重新启用时重设；仅正文、模板日期或秒改变不重设；调用者伪造值不生效。一次性清除此字段；未知旧规则未改变时保持兼容。
- 本地仓库仅新增生效元数据采用带小数的 Unix 秒，旧业务日期仍为 ISO8601；重载保留亚秒。上下文和显式导出沿用各自编码，不可据此驱动系统通知。

### 17.2 安排与防重放

- 安静时段关闭：每日一个、每周每个所选星期一个原生重复触发器，保留 IANA 时区，只匹配时分/星期，拒绝额外隐藏日历约束。系统预计的下一时刻不是实际送达保证。
- 安静时段开启：对原始 occurrence 应用现有安静窗口、按实际触发时刻去重，预排后续 7 个未来单次提醒，需要打开应用补排。32 个本命名空间、64 个全应用 pending 是本应用预算，不是 Apple 硬上限。
- 安静策略和 quietHoursEffectiveAt 在同一 Store 原子保存；同值重存不改变生效时间。新增 origin 晚于计划和策略生效下界，只继承仍未成熟、身份与 occurrence 均匹配的既有 pending。新建/恢复不得补昨晚；改变安静结束不得重放已成熟 origin。旧元数据缺失不能回落 createdAt，无合法 pending 时从本次启用后的下一次开始。
- occurrence 标识绑定原始时刻，安静版本不制造新 occurrence。原生/滚动/旧单次模式迁移清理旧 children。暂停、取消、完成、删除和登出清理整组。

### 17.3 批处理、原子提交与覆盖

- plans 返回完整组；旧单数 plan 面对多结果明确报错，不截断。先全组容量预检，再安排与 CAS 提交；失败回滚，并按既有有限预算恢复最新记录。保留 owner/session/quiet/version/operation UUID、基底快照和迟到请求保护。
- addTask(_:validateBeforePersist:) 与 updateTask(_:expecting:validateBeforePersist:) 在仓库锁内、实际生效时间归一化后、落盘前同步校验。校验必须纯，不可回读仓库或 await。等待系统回调跨过首 origin 时抛 recurrenceActivationElapsed，不落盘，候选组回滚；不得先保存再宣称未保存。
- updateTaskStatus 可携带 expectedTask 确认快照，陈旧记录不更新。完成表示结束整个重复计划，界面明确确认，不是仅完成单次。
- coverageByTaskId 仅在所有必需请求存在且完全匹配时提供 nextFireAt / through / scheduledCount / repeating。原生 through=nil；滚动为有限截止。部分失败不得用最晚日期伪装完整覆盖。
- 列表区分一次性完整日期、重复时分/星期、未知旧规则参考值。每周空选择拒绝保存；旧 raw rule 可明确保留/替换；切回一次性提示检查完整日期。覆盖缓存绑定 owner 和完整任务快照，过期不展示旧安排证明。
- 平台与 BYOK 上下文包含规则、时区、提醒偏好和可选生效下界；wall-clock-template / unsupported-rule 明确含义。reminderEnabled 不是安排或送达证明。完整 JSON 元数据计入预算，个人记录仍是不可信参考数据，不能自动授权工具。

最终本地验证：统一 16 套 478 个独立测试组 exit 0，另 7 项独立 batch 和真实跨分钟原子拒绝门禁通过；额外门禁不计入 478。最终 Simulator 构建与 72 个源码/资源文件一致。普通 iPhone UI 与数据恢复范围见 CLIENT_IMPLEMENTATION_STATUS.md 第 13 节；真实系统通知安排/送达、服务器/Apple/StoreKit 和强制 iPhone Duo 验收仍未完成。


## 18. 本地 Markdown 与展示链接（2026-10-30）

本节仅客户端展示，不增加 HTTP，不改变身份、模型、每日/订阅额度、价格或原始消息存档。

- AssistantMarkdown.parse(_:limits:) -> [Block]：id/sourceRange 是 UTF-8 偏移；source 逐块拼接等于输入。支持基本标题、段落、列表、引用和带语言代码围栏。关闭代码显示/复制 exact body；未关闭显示/复制 exact source。解析预算只限制结构化工作，余文完整回退可见，不截断个人内容。
- AssistantMarkdownInline.attributed(_:) / isAllowedLink(_:)：原生行内格式、32 KiB 预算，图片和 HTML 保守原文显示。不支持或不安全链接仅去链接属性、不丢标签。HTTP(S)/host/无 userinfo 校验只用于用户激活的展示链接，不放宽 BYOK 的 HTTPS、确认或密钥策略。
- MarkdownTextView 只本地渲染。正文使用稳定 VStack，外层按消息懒加载；代码独立横向滚动、可选择、复制按钮只写平台剪贴板，不执行源文本。代码无障碍值保留完整正文。
- MessageBubble 默认停用隐式 URL 媒体检测/剥除/加载，用户消息保持 verbatim。显式本机图片附件与原存档不受影响。旧媒体允许标志不得被误当作用户已授权上传或加载第三方内容。

最终 18 套 528 组隔离检查及严格官方远程 iOS Simulator 构建通过；UI 运行二进制与最终构建哈希一致。具体支持子集、真实 UI 修复、未执行的剪贴板/网络/现场 VoiceOver 验收，以及原数据恢复，见 CLIENT_IMPLEMENTATION_STATUS.md 第 15 节。完整客户端与 iPhone Duo 发布门禁仍未完成。

## 19. 单条记忆授权与请求启动一致性（2026-10-30）

本节只扩展本机记录解释、编辑和发送边界，不新增 HTTP、不改变已有 v2 请求字段或套餐价格。

- 单条有效授权：active 且 consent 规范比较为 explicit/confirmed；revoked/disabled 不允许，未知原值为未确认，deleted 排除。规范比较只用于判定，不回写旧 raw consent。正文仍须非空，并通过全局/类别和上下文预算选择；单条允许不是每次使用或 BYOK 目的地确认的替代。
- 新增保存 explicit 或 unconfirmed；旧记录显式开关从不允许到允许写 confirmed，允许到停用写 revoked，其余保留原字符串。来源消息保存只接受 exact explicit/unconfirmed，不能伪造 confirmed 或其他状态绕过来源票据。
- 现有 updateMemory(_:expecting:) / deleteMemory(_:) 要求完整确认快照 CAS，不插入、不复活；已存来源和创建时间不可由更新替换。正文未改动的旧超长/空白可以撤权，空白不能获新授权。无改动保存不更新时间。
- 准备的请求绑定原查询与所选个人上下文签名；认证和会话创建等待后及实际 transport beforeStart 中重新核验 owner、run、会话/scope、完整配置及 epoch。最终钩子与 dataTask.resume() 同步在 MainActor 执行，无 await 间隙；启动前上下文或其有效授权不再匹配就拒绝，不静默增删个人上下文或自动重发。
- 排队期间取消或钩子失败不启动 HTTP；底层串行 delegate 保持逐块 SSE 和真实取消。网络已经启动后的内容无法撤回；长期记忆撤权不自动删除会话历史中的同样事实。
- 导出仍包括未确认/已停用记录及删除墓碑；墓碑正文与来源始终清空，导出不改写源文件。历史残留磁盘墓碑必须通过真实磁盘夹具验证，不能用现行 active-only 插入 API 伪造成功。

最终统一 18 套 / 566 组 exit 0，严格官方远程 Simulator 构建和普通 iPhone 实际授权/取消/撤销/删除/重启检查通过；新增工具栏按钮创建的完整 UI、真实模型/账号/订阅/通知与强制 iPhone Duo 验收不在已通过范围。数据恢复和完整证据见 CLIENT_IMPLEMENTATION_STATUS.md 第 16 节。

## 20. 安全续聊、多会话草稿与持久删除保护（2026-10-30）

本节记录 Phase 17 的本机客户端合同与历史验收基线；其中 JSON 文件和同步归档实现正在由第 21 节的 Phase 18 SQLite 改造替代，不代表当前阶段已完成验收。不新增 HTTP、不自动发送消息，不以本地状态代替服务器账号、模型或额度权威。

- requestOpenConversation(id:ownerId:) / requestNewConversation(ownerId:initialText:) 返回 true 才可导航。需要确认时返回 false 并发布 pendingConversationSwitch；confirmConversationSwitch(_:) 再验证实际 owner、源 session/scope、草稿和生成代次。拒绝或关闭不写草稿、不停止生成；同一当前会话不重载旧消息。初始预填仅作为新会话草稿，不调用模型。
- 身份 login/logout 通知须在同一 MainActor 回合同步失效票据并停止旧 producer/图片任务，不能仅排异步 activateOwner；同回合账号变化后恢复也不能重新启用旧确认。跨 owner 不把旧输入写给新账号。
- 图片处理中或存在尚未处理的 BYOK 发送确认时，拒绝切换。目标 conversation 按当前 owner 的 ID 重新读取。正常切换先保存源会话及文字/图片草稿，再取消实际生成并恢复目标草稿；历史 pending/streaming 不当作仍在运行。messages 与 draft 为两个文件，不承诺全局事务：源历史已落盘但草稿选择失败时明确报告部分保存，保留当前 UI/输入和实际 producer，不伪装已切换。
- AssistantChatArchive 在单账号哈希 .json.draft 中保存 version=1、ownerId、活动指针、未关联旧稿和 conversationDrafts map；读取兼容旧 JSON 字符串/旧 AssistantChatDraft，不自动迁移。selectDraft(conversationId:preserving:initialDraft:userId:) 同锁一次原子提交源草稿和活动目标，最终目标（包括已经存在的目标）必须先校验正文/图片；initialDraft 只初始化缺失目标，不能覆盖旧稿。
- 未发送文字/图片源在离开时保留 messages=[] 的可达历史记录，标题/预览为草稿提示，不伪造已发送 user 消息。原始消息、图片、serverConversationId 和中断状态按既有规则保存；不得用局部消息页覆盖完整 archive。
- envelope 新增可缺省 deletedConversationIds 与 isPurgingAll。delete(ids:userId:purgeUnassignedDraft:) 先原子落删除保护并清关联草稿，再写过滤的消息 archive；明确当前会话删除才可清未关联旧稿。公开读取、草稿快照与导出投影不返回已删除内容，upsert/saveDraft/select 拒绝写回删除 ID；保护提交后后续阶段失败也不能因重启或 owner 往返恢复旧稿。
- deleteAll 先落全量保护并清稿，再写空历史并移除两文件；保护写失败保留原数据并失败，后续阶段失败保持保护，只有明确重试才继续物理清理。isPurgingAll(userId:) 与 deletedConversationIds(userId:) 纯读不执行删除。恢复新建的确认不得承诺保留已删除稿；全量中断先重试 deleteAll，单条中断重试对应 delete，再仅使用用户明确预填创建新稿，不 upsert 旧源。
- 完整本机备份 schemaVersion=1 新增 conversationDrafts 数组与同名 includedScopes；仅包含 inactive 稿，原 draft 仍表示 active。全部草稿纳入图片选择、按附件出现次数的 omittedImageCount 和完整编码预算。旧 v1 备份可缺新字段；损坏稿不能静默遗漏为成功备份。备份范围界面明确说明其他会话的未发送稿也会包含。

Phase 17 最后完整验收基线为统一 18 套 / 622 组 exit 0，严格官方远程 Simulator 构建通过，已安装二进制与构建一致；当时最终普通 iPhone 复验历史继续、取消、目标稿恢复，以及有效全 purge 中断夹具的冷启动隔离/明确重试/物理清理。首轮协议错误夹具经确定性交付握手修正，当时生产 transport 未变。早期与最终 UI 范围、全部日志及原数据恢复见 CLIENT_IMPLEMENTATION_STATUS.md 第 17 节。这些历史证据不覆盖第 21 节的新存储/异步源码；真实服务端与 Apple/StoreKit/通知、强制 iPhone Duo 专用验收也未因本地接口而完成。

## 21. Phase 18：SQLite 归档与异步操作边界（本地验证记录，2026-10-30）

本节记录当前本地接线与验证范围，不新增 HTTP 端点，不代表服务端已实现或完整产品已完成。Phase 17 的 18 套 / 622 组仍按其历史范围保留；本轮 19 套 / 694 组与正式构建证据独立列于下文。

### 21.1 本地读取与分页

- 历史列表通过 `historyPage(ownerId:query:cursor:limit:) async` 读取数据库摘要；`AssistantConversationSummary` 不包含完整 messages，不可作为完整 Conversation 写回。元数据游标绑定 owner、规范化 query、generation 和排序位置，失效时明确要求第一页重载；搜索在数据库执行。
- 详情和继续通过 owner + conversation ID 按需读取完整正文。后台准备/迁移和 worker I/O 显式等待；UI 必须在每次 await 后复验当前 owner、query/路由、run 与视图代次，拒绝旧结果发布。
- 删除/全清保留显式授权和提交许可。提交前取消或身份失效拒绝提交；已经提交的删除不能因取消而声称回滚，也不能经自动保存恢复旧正文/草稿。历史页在明确删除开始时失效首屏缓存，重进重新读取，不重放 mutation，不按当前已加载 ID 集合删除合法详情路由。
- durable purge 意图须由后台 prepare 在冷启动发布；不能因同步缓存初始 unknown / purging=false 而前置短路，遗漏恢复准备或使明确新建恢复不可达。pending purge 的导出在读前、SQL 内和读后均明确失败，不以成功空快照代替未完成清理。

### 21.2 启动授权、导出与复制

- 生成与创建会话的异步等待钩子先等待操作门；最终同步钩子在同一 MainActor job 内复验身份、会话/scope、配置和所选个人上下文，然后实际 `dataTask.resume()`，中间无 await。创建标题也属于个人内容，不能先启动创建请求再核验。同步可写性检查使用短锁授权快照，不在 MainActor 回到 worker `queue.sync` 读取 SQL 或迁移状态。
- `flushForDataExport(ownerId:) async` 返回 owner-bound `AssistantArchiveExportSnapshot`：当前会话/草稿 flush 与完整归档快照读取在同一操作门和 SQLite 事务内完成。后台编码器消费捕获的不可变快照，不再在门释放后重新读活动归档。记忆/任务仓库仍独立读取，不承诺跨仓库全局事务。
- 代码复制回调在最终写剪贴板前复验源身份与 exact UTF-8 代码内容。历史详情重新读取当前 owner 的消息；实时聊天使用当前消息和会话 scope。renderer 不得在回调授权前自行复制，失败不能显示已复制。真实剪贴板和无障碍交互仍需独立原生验收。

### 21.3 本地验证记录与待补项

- 本轮统一 19 套 / 694 组 exit 0；Database 35、Archive 38、VM 143、Export 35、Protocol 33、Conversation 20、Markdown 29，其他组及总数见 `.build/verification/phase18-final-regression-summary.json`。统一日志 `phase18-final-full-regression.log`，152 项回归源码记录 `phase18-final-source.json`，摘要确认 sourceUnchanged=true。
- 正式官方远程 SDK 构建 exit 0：`.build/verification/phase18-final-sdk-build.log`、`phase18-final-sdk-summary.log`；132 项非 Tests 生产输入 `phase18-final-sdk-input-source.json`；已安装二进制与构建一致见 `phase18-final-binary.json`。这些文件均位于 `.build/verification/`。
- VM 冷启动新增测试以全新 namespace 和实际含 260 条旧消息的数据验证 unknown 缓存、bootstrap 隐藏旧内容、新建确认可达、取消字节不变、明确恢复只保留新稿且零生成 HTTP；明确破坏性确认属于隔离测试。创建会话 20 组拦截测试仍覆盖等待、撤权、取消及原错，不涉及真实上游或凭据。
- 最终普通 iPhone 17 Pro / iOS 26.5 原生观察 130 会话、260 消息、3 稿迁移与 50 / 50 / 30 分页，130 唯一无遗漏；真实 cold pending marker 保留旧 260 条源消息但 UI 隐藏，恢复重试已可达确认。原生仅取消并核对 archive / authority 全部字节不变，未执行最终原生破坏性确认。
- 最终二进制冷启仅加载首屏后，搜索未加载的 `nebula-003` 唯一命中，完整正文/代码块可见；续聊取消保留全部 archive/authority 字节，明确确认恢复目标草稿，源/其他稿与 260 条消息不变，再次冷启动恢复目标正文/草稿。见 `phase18-ui-checks.json`。原始两份文件/偏好按字节恢复并再次进入正常首页；新引擎正常生成空 SQLite/authority，headers/bodies/drafts/deleted 均为零，无 QA18 残留，见 `phase18-restoration.json`。这不承诺跨设备、真实模型或剪贴板验收。
- 首屏外搜索、继续取消/接受、冷启动与游标失效的早期完整 UI 记录为 `phase18-ui-checks-before-cold-purge-fix.json`；早期游标原生用例仍仅对应修复前二进制，不冒充最终原生范围。
- 已知 UI 跟进：Home preparationError 仍可能显示 Foundation 存储 enum 原文；VM loadFromLocal 的本地化映射不等于所有 UI 出口已修复。真实剪贴板与现场无障碍仍需对应验收。
- 真实服务端、Apple/StoreKit、真实模型/通知、实机性能、签名/TestFlight 和强制 iPhone Duo 专用验收均未完成。本阶段不改变任何套餐价格、人民币档位、月额度或每日赠送叠加的拟定状态。

## 22. Phase 19：用户批准的本机待办工具（2026-10-30）

本节是新增的本机/BYOK 客户端契约，不新增已部署的 CaoBao HTTP 端点。平台 v2 工具仍停用，模型目录 tools=true 不代表服务端已经提供工具调用、审批或结果续接；原后端与 CiYuan2API 未因本地实现而完成联调。完整工具契约见 ASSISTANT_TASK_TOOLS.md。

### 22.1 调用、审批与真实结果

- 仅经显式费用确认的无副作用 caobao_task_probe、当前配置指纹和 schemaVersion=1 验证后，用户才可启用 BYOK create_task。探针不读取历史或创建任务；配置、身份或运行代次改变会使旧证明/回调失效。
- 三协议完整工具流只产生持久提案；半截、未知、并行、超限或失败调用不执行。模型不能指定 owner、稳定任务 ID 或审批结果。当前票据绑定 owner、会话、源消息、内容、配置与代次；未完成来源只读。
- 用户明确保存后，真实任务与 saved 回执同次原子写入。提醒默认关闭，有明确日期且用户主动开启时才另行更新已保存任务，继续经过权限、来源和 CAS；通知失败仍保留任务，不回到随机 ID 创建路径。declined 仅保存拒绝记录。
- receipt 的 reminderState 表示创建时的历史结果，不是当前任务/通知状态。专用继续先持久声明一次 continuationAttemptId，再允许网络启动；取消、崩溃或失败不自动恢复该次尝试，不证明请求已发送或回复完成，也不再次执行任务。下一轮关闭新工具，并使用真实仓库结果。
- 历史只读处理记录，进入实时会话后重新签票据；备份保留提案和 taskToolReceipts，不执行、重新创建或自动启用提醒。raw UTF-8 owner 与运行时 Base64 key 用于账号边界，规范别名冲突拒写而不迁移旧 ID；系统 Keychain、已启动请求和 OS 已受理动作不因此被宣称可以撤回。

### 22.2 本地验证与 UI-only 构建修复

- 统一 **23 套 / 850 个独立测试组 exit 0**，实际摘要 `.build/verification/phase19-final-regression-summary.json`、日志 `phase19-final-full-regression.log`。关键工具分项为协议 42、能力 21、执行 42、导出 13，另有 VM 167、提醒协调器 88、身份 15；全部已包含在 850 内。
- 两份 166 项源码/资源/工程清单 `phase19-source-before-home-compiler-fix.json` 与 `phase19-final-source.json` 实际只有 HomeView 不同，摘要记录 `cliInputsUnchanged=true`。这是 CLI 启动后的 UI-only SwiftUI 表达式拆分，保留全部 State、来源和费用/Probe 守卫；没有把全部源码清单称作未变，也未把最初 SDK 类型检查超时报为 CLI 测试失败。
- 最终官方远程 iOS Simulator SDK 重试实际 exit 0，`phase19-final-sdk-build.log` 与 `phase19-final-sdk-summary.log` 记录 **BUILD SUCCEEDED**；首次 SDK 失败摘要保留于 `phase19-sdk-home-typecheck-failure-summary.log`。各 `phase19-*` 文件均位于 `.build/verification/`，精确范围见实施状态第 19 节。
- 原生随后确认提案日期标签把 2030-01-02T03:04:05Z / UTC 显示为 11:04 AM + UTC；只将 ProposalView 改为指定 locale/zone 的预格式化 String，再 Text(verbatim:)。`phase19-post-native-source.json` 的 166 项输入对比上一份最终清单只改此 UI 文件，CLI 输入未变。追加 `phase19-post-native-sdk-build.log`、`phase19-post-native-sdk-summary.log` 再次 exit 0 / BUILD SUCCEEDED；`phase19-post-native-installed-build.json` 确认冻结源码及已装二进制匹配。

### 22.3 原生验证与发布边界

首个成功构建的普通 QA19 二进制已实际通过 UI 拒绝提案，仓库保存一个 revision=1 / declined / notRequested 回执，tasks 为空；重启和重装后拒绝状态、未发送草稿保留，仓库字节与拒绝后副本一致。最终日期修正后二进制已复验 failed-source 的 Result unconfirmed/未完成只读解释及无执行按钮，历史 body-memory 正文/Copy 入口保留、仅有进入当前对话复核路由，无直接任务执行；两处均为 3:04 AM + UTC。最终截图 `phase19-native-final-failed-source.png`、`phase19-native-final-history-readonly.png` 与 `phase19-native-ui-checks.json` 限定其真实范围，不以早期截图替代最终证据。

日期修正后的最终二进制已安装且与构建哈希匹配；qa19-decline 的 AX 实际显示 3:04 AM + UTC、Declined 和原草稿，无复核/拒绝/继续按钮。`phase19-native-timezone-ui-fix.json`、`phase19-native-timezone-corrected.png` 记录了 11:04→3:04 的实际修正，不表示已原生执行专用继续。

独立 SQLite 只读检查报告完整性正常、迁移完成、5 会话/10 条唯一消息、5 草稿与合法来源/摘要。只有一个拒绝回执且无 taskId/continuation claim，任务和记忆均为零；重装后容器路径正常变化，stage 记录保留初始路径，不声称已经清空 QA 或恢复用户数据。汇总记录明确 fullClientGoalComplete=false。

QA19 Keychain 没有写入测试 API Key，也没有播种能力证明；受当前 relay 下部表单滚动/触摸限制，原生费用确认、能力验证/启用、批准/编辑保存、专用继续确认/取消，以及有效 Key/证明下的陈旧配置审批保护均未测试。隔离协议/执行/VM/探针测试不能替代这些路径，**当前不声明 Phase 19 完整原生验收已通过**。没有真实模型/平台网络、登录、IAP 或通知授权/送达；真实上游、服务端、Apple/StoreKit、系统交付、实机性能、签名/TestFlight 和强制 iPhone Duo 专用姿态仍是发布门禁。价格、人民币档位和额度拟定状态不变。

## 23. 客户端本地备份恢复契约补充（Phase 20，2026-10-30）

### 23.1 本地接口，不新增 HTTP

本节只补充 iOS 设备内的恢复行为，不新增 REST/SSE 端点、不改变服务端 v2 协议，也不表示后端、CiYuan2API 或云同步已部署。详细字段、安全限制与验证时间线见 `ASSISTANT_DATA_RESTORE.md`；阶段状态见 `CLIENT_IMPLEMENTATION_STATUS.md` 第 20 节。

| 本地 API / 类型 | 约定 |
|---|---|
| `AssistantDataImporter(maximumBytes:)` | 默认 32 MiB；URL 只读 FD 校验、有界读取、重复键/字段/类型/归属/日期/记录/图片预检，不写业务存储 |
| `prepare(url:ownerId:)` / `prepare(data:ownerId:)` | 返回不可变 `AssistantDataImportPlan`；文件必须是兼容本地导出 schema v1，owner 原始 UTF-8 完全一致 |
| `AssistantDataImportPlan` | ownerId、backupDigest、exportedAt、conversations、drafts、memories、tasks、omittedImageCount、neutralizedProposalCount、ignoredReceiptCount；不持有源 URL 或原始 JSON |
| `ChatViewModel.restoreLocalBackup(_:) async throws` | 显式确认后的本地两阶段协调；保持当前草稿、验证最终许可，不调用模型/通知/工具 |
| `AssistantDataImportResult` | 必有 archive；workspace 可空，workspaceError 说明第二阶段未完成；isComplete 仅在 workspace 存在且无错误时为 true |
| 计数与重复处理 | 新增/冲突数为本次尝试；alreadyApplied 要求两个存储均识别相同摘要，不把预览候选数当实际写入数 |

`local-device` 标签与文件摘要不提供身份认证。该契约拒绝自动 owner 重绑定和跨账号恢复，不把备份中声明的 owner 当作登录凭据。

### 23.2 合并、权限与失败语义

- 同 ID 本地记录与本地删除保护优先，仅新增不覆盖；当前会话/草稿先受保护，导入不自动打开恢复会话。孤立非空稿生成可读空会话；无 ID 草稿使用确定性摘要 ID，仍保持非活动。
- SQLite 会话/草稿/摘要标记同事务，工作区记忆/任务/摘要标记同次原子文件保存；两个存储不构成全局事务。SQL 已成功而工作区失败时返回部分结果，不谎称 SQL 回滚。
- 同文件可由用户再次明确确认重试，已处理摘要不重复新增。工作区每原始 owner 最多 256 个不同摘要，达到上限的新文件恢复不能只靠循环重试解决；错误需保留实际原因。
- 导入记忆为 unconfirmed，任务提醒关闭且需要审批。提案只保留可读文字，处理回执不恢复，旧 request/generation/replaces/server-conversation 标识移除；待处理消息标记 failed。不会恢复凭据、API Key、接入配置、工具能力证明或 OS 许可，当前偏好不变。
- 预览/确认/后台结果绑定原始 owner、运行和身份代次；身份通知、页面离开、取消可阻止未开始提交或后续结果发布，已开始/完成的提交不保证撤销。该约束不扩展成对系统已执行动作的撤回承诺。

### 23.3 证据范围与待验项目

FD 加固前统一回归实际为 **27 套 / 941 个独立组，exit 0**，正式 Simulator SDK 实际成功，原记录保留为 `phase20-pre-file-hardening-*`。`phase20-file-hardening-provenance.json` 记录输入由 177 至 179 项及具体变化。最终统一回归实际为 **28 套 / 947 个独立组，exit 0**；已核对分项总和与日志 SHA-256，证据为 `phase20-final-regression-summary.json`、`phase20-final-full-regression.log`。Importer 29、archive restore 19、repository restore 28、restore VM 15 和新增文件读取 6 组均包含在最终总数内，不重复累计。

最终正式 Simulator SDK 实际 exit 0 / BUILD SUCCEEDED，记录 `phase20-final-sdk-build.log`、`phase20-final-sdk-summary.log`；`phase20-installed-build.json` 确认最终 179 项输入及已装二进制与构建哈希匹配。上述 `phase20-*` 文件均在 `.build/verification/`。这不是实机签名、TestFlight 或完整原生交互通过的证明。

早期普通 QA19 原生实际导出合成备份、通过系统文件选择器打开，展示 5 会话/5 草稿/5 个中和提案/1 个忽略回执；先确认取消，业务源数据字节不变、恢复标记为零，随后明确确认首次合并。界面各类新增 0、冲突 5，两个存储各有同一摘要的一个标记；磁盘仍为 5 会话、0 任务/记忆、1 个既有回执，工作区除新增摘要元数据外与基线完全一致。`phase20-native-after-first-merge.json`、`phase20-native-first-merge-result.png` 记录 FD 加固前现有冲突保留与提交。

最终 179 项匹配的正式 FD 二进制重装后，实际经系统 Recents 再选同一约 12 KB 文件，预览仍为 5/5/5/1，明确确认后实际 AX 显示 `This backup has already been processed. It was not imported again.`，各类新增 0、冲突 0。工作区与首次合并后逐字节一致，两个摘要标记仍各一个；5 会话/5 草稿，活动槽 c:qa19-failed-source，0 任务/记忆、1 个既有回执，SQLite integrity=ok。`phase20-native-ui-checks.json`、`phase20-native-final-repeat-result.png` 与安装对应记录证明最终文件读取及重装后重复恢复；汇总明确 `fullClientGoalComplete=false`。

**本轮原生没有向空目的地新增记录。** 预览中 5 个中和提案不证明新只读历史已落库；畸形文件、账号变化、工作区故障/部分重试和完整草稿保护等仍依赖隔离覆盖，待实际原生验证，不把已验证的重复路径扩展为全部恢复场景通过。

当前不声明完整功能或客户端完成。真实服务端/模型、Apple/StoreKit、通知/系统交付、完整任务审批与继续、实机性能、签名/TestFlight 和强制 iPhone Duo 指定设备/姿态继续独立验收；本地 CLI、SDK 和普通 iPhone 子集不替代它们。

## 24. 记忆云同步客户端补充（Phase 21，2026-10-30）

客户端已消费现有的 `GET /api/v2/sync/changes`、`GET /api/v2/memories`、`POST /api/v2/memories` 和 `DELETE /api/v2/memories/:memoryId`。游标只在整页成功应用后推进；服务端返回的 `version`、`seq`、`status`、`updatedAt` 原样进入同步状态，删除保留墓碑。上行创建/编辑携带 `expectedVersion`，409 冲突不覆盖本地记录。Bearer token 仅放在请求头，客户端禁止重定向并限制响应大小。

同步只针对长期记忆，owner 由认证身份决定，客户端不会从请求体认领账号。当前已在真实本地仓库和 URLProtocol 网络夹具中验证增量拉取、删除墓碑、游标推进、Bearer 头及 `expectedVersion`；真实账号、生产网络、后台同步及任务/会话云同步仍未由本地证据证明。

## 25. 任务定义同步客户端补充（Phase 22，2026-10-30）

客户端任务页消费现有的 `GET /api/v2/tasks`、`POST /api/v2/tasks` 和带 `expectedVersion` 的 `PATCH /api/v2/tasks/:taskId`。首次进入任务页时拉取服务端定义；本地独有定义尝试创建到服务端。服务端状态、时区、重复规则和版本字段进入本地任务；提醒授权、来源消息和重复计划起点保留在本地。

服务端目前没有任务同步游标、删除墓碑或删除端点，客户端因此不推断远端删除，也不在没有云端版本状态时把本地同 ID 编辑覆盖到服务器。本阶段是任务定义的受限拉取与本地新增上传，不是完整的多端冲突或删除同步。任务页面离线时继续使用本地提醒和任务库。

## 26. 会话历史拉取同步客户端补充（Phase 23，2026-10-30）

客户端任务/首页同步消费现有的 `GET /api/v2/conversations?cursor=<id>&limit=<n>` 和 `GET /api/v2/conversations/:conversationId/messages?cursor=<id>&limit=<n>`。请求使用认证 Bearer token；服务端会话 ID 仅接受 `cnv_<数字>` 形式，消息按 `clientMessageId`、`requestId`、`generationId` 和服务端消息 ID 与本地历史幂等关联。时间戳和分页游标必须可解析且不能重复；远端非 text 内容（包括图片）不导入。

该客户端路径只做 pull-only 合并：新增远端历史，保留本地草稿、未完成消息和删除标记，不上传本地草稿或删除。单次调用最多处理 200 个会话、每轮最多读取每个会话 1,000 条消息；客户端把全量回退的会话页、活动会话和消息游标按 owner 持久化，后续同步会继续处理剩余页，不再静默丢弃超出单次预算的历史。增量变更若超过该安全预算会自动降级为完整快照，只有快照持久化完成后才推进变更游标，避免以不完整历史覆盖本地。当前可见会话只有在本地没有未保存或进行中的内容时才刷新。由于当前服务端没有会话版本、变更游标和删除墓碑，这不能替代完整双向多端同步。

## 27. APNs 设备注册客户端补充（Phase 24，2026-10-30）

客户端调用现有 `POST /api/v2/devices`：

```json
{
  "deviceId": "stable-keychain-device-id",
  "platform": "ios",
  "pushToken": "lowercase-apns-token-hex",
  "environment": "sandbox|production",
  "topic": "caobao.chat"
}
```

请求必须携带当前账号的 `Authorization: Bearer <accessToken>`，服务端从 Bearer 身份确定 owner；`deviceId` 不作为用户身份，服务端保存其 hash。客户端只在已有通知授权时注册远程通知，接收到 token 后按当前 owner 上报；重定向、非 HTTPS、非 `registered` 响应和超限字段均视为失败。客户端不把 APNs token 写日志或放入业务导出。

设备注册测试只证明 URLSession 请求契约和本地重试边界；模拟器、离线夹具和无签名构建不能证明 Apple APNs token、真实服务端设备记录、APNs Worker/outbox 或系统送达。生产通知仍需 Apple 配置、真实账号、真机和 TestFlight 联调。


## 28. 账号偏好回读同步客户端补充（Phase 25，2026-10-30）

新增认证接口 `GET /api/v2/profile/preferences`，响应沿用：

```json
{
  "success": true,
  "preferences": {
    "assistantMode": "platform",
    "regionConfirmed": true,
    "locale": "zh-CN",
    "personaLevel": "normal",
    "proactiveLevel": "",
    "serviceRegion": "CN",
    "regionSource": "user",
    "timeZone": "Asia/Shanghai",
    "timeZoneLocked": true
  }
}
```

客户端只把服务端身份绑定的 locale、persona 和已确认区域用于跨设备恢复；locale 会映射为 `zh-* → zh-Hans`、`en-* → en`，空或未确认区域会清理旧本地区域。BYOK endpoint/key、模型选择、提醒安静时段和本机通知授权不由该接口覆盖。Bearer、owner、token 和账号代次必须在请求前后保持一致；网络失败不能清空现有本地偏好。

偏好 GET 使用独立的 HTTPS URLSession：响应必须是单个 200 JSON、大小受限且字段满足服务端枚举/时区约束；任何 3xx 都直接失败，不跟随带 Bearer 的重定向。偏好 PATCH 的服务端实现先校验全部字段，再在一个数据库事务中提交账户时区锁、区域确认和可变偏好；失败不能留下部分写入。客户端设置保存不重复提交已经锁定的设备时区。

## 29. 订阅跨设备快照与 StoreKit 生命周期（Phase 26，2026-10-30）

服务端 `GET /api/v2/entitlements` 的 `subscription` 是账号权威快照：`status` 允许 `none`、`active`、`trialing`、`grace_period`、`expired`、`refunded`、`revoked`，并可返回服务端商品 `productId` 和 ISO8601 `expiresAt`。客户端只展示经过状态、商品标识和日期校验的快照；快照本身不把未配置的价格或月度额度变成本地授权。

Apple Server Notification 的状态变更以已验证 JWS 的 `signedDate` 单调应用；迟到事件不会覆盖新状态。通知先写入 durable inbox，未知交易链保留待绑定，worker 在后续 tick 重试；首次客户端验证也会补偿同一原始交易链的 pending 通知。重复通知由 `notificationId` 去重。

iOS 在应用启动建立 `Transaction.updates` 监听。账号或订阅配置尚未就绪时，未完成交易只进入内存待处理队列；当前账号、服务器商品白名单和 `appAccountToken` 均通过校验后才调用服务器 verify，并在服务器确认后 finish。订阅配置暂时不可用不能导致未确认交易被结束。

订阅页优先显示本机刚由服务器验证的交易，若没有则显示当前登录账号的 `/entitlements` 快照。网络或畸形响应不会把已有快照改成“无订阅”；退出登录或账号切换会撤销旧账号显示。上述本地测试和模拟器构建不替代真实 Apple 登录、StoreKit 商品、Server Notifications、退款/续订和多设备生产联调。

## 30. 服务端生成可靠性与通知 outbox 补充（2026-10-30）

- 自动选模的 fallback 只在首个候选没有可用正文时重试；一旦产生可见正文或请求被取消，不得再次发送上游请求。切换到 fallback 时，在首个 delta 前发送一次 `model_policy` SSE 事件，成功后 generation 的实际 model/protocol 必须与重连 replay 和 GET 一致。
- SSE replay 必须从已持久化的 usage 恢复非零 `usage` 事件，并保持 `started`、正文 delta、usage、completed 的顺序。取消状态以服务端 generation 为准，工具事件不得被降级成普通文本完成。
- APNs outbox 行在发送前通过 `sending + claimToken + leaseUntil` 原子认领；完成或失败必须携带 claim token，租约过期后才可由另一 worker 重领。达到重试上限进入 `dead`，不能静默丢弃；旧的无租约完成 API 只用于兼容历史调用。
- Apple 交易验证要求非空 `Idempotency-Key`，并校验请求中的 transaction/product/appAccountToken 与已验签交易；同 notificationId 的不同 payload 是冲突。订阅状态按 Apple signedDate 单调应用，退款/撤销终态不能被旧前台回放重新激活。

本节的服务端回归覆盖 `./model ./service/caobao ./controller/caobao`，客户端回归覆盖 iOS/macOS Debug 构建和 168 个 ChatViewModel 集成套件；这些证据不替代真实上游模型、Apple Server Notifications、APNs 系统交付、生产部署、签名/TestFlight 或 iPhone Duo 实机验收。

## 31. 会话与任务增量同步契约（2026-11-02）

### 31.1 会话变更

- `GET /api/v2/sync/conversations?cursor=<seq>&limit=<n>` 返回 `{items,nextCursor,headSeq,resyncRequired}`；`GET /api/v2/conversations/changes` 是兼容别名。`cursor` 是当前账号的 append-only 序号，不能由客户端伪造 owner。
- `upsert` 事件包含会话摘要；`delete` 事件是删除墓碑。`DELETE /api/v2/conversations/:conversationId` 必须按认证 owner 校验，删除会话时清理消息正文并追加墓碑。
- 客户端本地删除已绑定的服务端会话后，会把服务端 ID 放入 owner-scoped 待上行队列；登录同步先尝试冲刷队列，网络失败不撤销本地删除，后续同步继续重试。
- 客户端应用完整页面后才写入游标；`nextCursor` 不得回退，超过 `headSeq` 或负值直接拒绝并等待重新同步。若服务端尚未提供变更 feed，客户端才回退到受限全量拉取。

### 31.2 任务变更

- `GET /api/v2/tasks/changes?cursor=<updatedAt:id>&limit=<n>` 返回 `{items,nextCursor,headCursor}`；任务条目同时承载 active row 或 `deletedAt` tombstone。`DELETE /api/v2/tasks/:taskId` 只作用于认证 owner，并取消待运行 occurrence。
- 任务游标按 `(updatedAt,id)` 升序比较。服务端对同一任务的连续编辑使用严格递增的 `updatedAt`，因此同一 Unix 秒内的编辑和删除不会被下一设备跳过；客户端只在所有条目成功应用后保存游标。
- 本地提醒授权、通知内容和任务工具执行仍由客户端本地策略控制；同步删除会清理本地任务及提醒，但不会把云端任务状态当作用户批准或执行结果。

### 31.3 证据边界

当前本地回归已覆盖会话/任务 feed 的游标、删除墓碑、同秒任务编辑、Bearer 和 owner 约束；这证明代码契约和隔离测试，不证明真实多设备冲突、后台调度、APNs 送达、生产部署或 iPhone Duo 验收。


## 32. 自定义角色与 AI 群聊（2026-11-05）

### 32.1 已实现的自定义角色接口

当前服务端已提供 owner-scoped 私有角色 CRUD：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v2/characters?limit=<n>` | 返回当前账号的 active 角色 |
| POST | `/api/v2/characters` | 创建角色；`id` 由客户端生成 |
| PATCH | `/api/v2/characters/:characterId` | 使用 `expectedVersion` 做乐观锁更新 |
| DELETE | `/api/v2/characters/:characterId` | 使用 `If-Match-Version`，服务端保留删除墓碑 |

角色字段包含 `name`、`avatar`、`description`、`systemPrompt`、`greeting`、`language`、`memoryScope`、`allowGlobalMemory`、`enabled` 和 `version`。角色提示词属于用户配置，不能覆盖服务端安全规则；账号删除会清理角色数据。

客户端通过 `APIService.listCloudCharacters`、`upsertCloudCharacter` 和 `deleteCloudCharacter` 调用这些接口，使用认证身份确定 owner，不从请求体接收 ownerId。

### 32.2 AI 群聊状态

AI 群聊的产品和数据模型已经记录在 `CUSTOM_PERSONAS_AND_AI_GROUP_CHAT.md`。群聊生成编排、参与者接口、speaker 级 SSE 和停止/重试链路尚未接入当前服务端，因此不能把“自定义角色 CRUD 已完成”表述为“AI 群聊已完成”。

首发实现约束：

- 只支持用户本人和 2–4 个私有 AI 角色；
- 默认使用 `mention` 模式，后续再开放 `moderated`；
- 角色记忆与全局用户记忆隔离；
- 每条用户消息最多 4 轮，角色和子生成分别计量额度；
- 外部写操作仍需提案和用户确认；
- 旧单聊请求保持兼容。

