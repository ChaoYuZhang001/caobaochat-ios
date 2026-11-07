# 草包服务端待验收需求（2026-11-07）

这份清单只记录客户端验收中确认需要服务端或生产环境处理的项目。当前生产探测使用无认证请求，不代表已完成真实账号业务验收。

本轮服务端源码单测未运行：当前客户端验收环境没有 `go` 命令（`go: command not found`）。以下服务端责任均来自源码/路由审计和公网 HTTP 结果，不能当作服务端测试通过。

## 当前生产证据

| 请求 | 当前结果 | 结论 |
| --- | --- | --- |
| `GET https://ciyuan2api.com/api/status` | `200` | 生产健康，版本 `v1.0.0-rc.48+ciyuan.reconstructed.20261106.1` |
| `GET /api/favorites` | `404 Invalid URL` | 旧在线收藏契约不存在 |
| `GET /api/sync/favorites` | `404 Invalid URL` | 旧同步收藏契约不存在 |
| `GET /api/v2/characters` | `401 UNAUTHENTICATED` | 路由存在；需要真实账号验证 CRUD |
| `GET /api/v2/proactive/profile` | `401 UNAUTHENTICATED` | 路由存在；需要真实账号验证 profile |
| `GET /api/v2/proactive/rules` | `401 UNAUTHENTICATED` | 路由存在；需要真实账号验证规则和执行记录 |
| `GET /api/v2/subscriptions/apple/config` | `401 UNAUTHENTICATED` | 路由存在；需要真实账号和 App Store 商品配置验证 |
| `GET /api/v2/entitlements` | `401 UNAUTHENTICATED` | 路由存在；需要真实账号验证订阅权益和额度账本 |
| `GET /api/v2/devices` | `404 Invalid URL` | 当前设备路由是 `POST` 注册；这条 GET 结果不能证明注销接口存在 |
| `DELETE /api/v2/devices/{deviceId}`（真实 Bearer、随机设备 ID） | 生产曾返回 `2xx`，客户端解码为 `unregistered`；当前 `feat/caobao-server-v2` 路由源码只注册 `POST /devices` | 生产与 checkout 契约不一致，不能把随机 ID 成功当作 handler 已验证；必须完成 production-versus-branch 比较，并用真实已注册设备验证 owner 隔离、禁用和 outbox 清理 |
| `GET /api/v2/sync/conversations?cursor=0&limit=1` | `401 UNAUTHENTICATED` | 会话 change feed 路由存在；需要真实账号和双设备验证 |
| `GET /api/v2/conversations/changes?cursor=0&limit=1` | `401 UNAUTHENTICATED` | 会话 change feed 兼容路由存在；需要真实账号和双设备验证 |
| `GET /api/v2/tasks/changes?cursor=0&limit=1` | `401 UNAUTHENTICATED` | 任务 change feed 路由存在；需要真实账号验证重复规则和墓碑 |
| `GET /api/v2/memories?cursor=0&limit=1` | `401 UNAUTHENTICATED` | 记忆路由存在；需要真实账号验证读写、冲突和删除同步 |
| `POST /api/v2/feedback` | `404 Invalid URL` | 当前部署没有客户端旧反馈路径；若保留反馈，需新增认证 owner-scoped 契约，或明确匿名反馈并同步修改客户端 |
| `POST /api/v2/proactive/runs/{runId}/snooze` | `404 Invalid URL` | 主动运行状态接口尚未部署；需补 read/snooze/dismiss/close-this-kind 的 owner-scoped 写接口和幂等版本校验 |

2026-11-08 客户端用真实已登录 Simulator 账号对当前生产资金池修复做了认证 CN 联调：`https://ciyuan2api.com` 返回完整流式生命周期，客户端捕获到 `generation`、多条 `delta`、`usage`、`completed`，并在本地保存服务端 `generationId`、`requestId` 和 token usage；本次未出现 `INTERNAL_ERROR`、`UPSTREAM_UNAVAILABLE` 或 `PLATFORM_FUNDING_UNAVAILABLE`。这证明当前 CN 资金池/渠道修复已通过一条真实对话链路，但不替代下面的 Apple、StoreKit、APNs、双设备同步、账号删除和 TestFlight 门禁。

同一真实账号随后通过客户端仅 Debug 的一次性探针完成自定义角色 `list → create → versioned update/disable → list 验证 → delete`，日志返回 `version=2` 和 `delete=deleted`；探针已撤销。该结果证明当前生产角色基础 CRUD 可达，但不证明版本冲突、跨设备墓碑或对话绑定协议。

同一真实账号读取主动 profile/rules 成功（`enabled=false`、规则数 `0`）。订阅配置请求返回 HTTP 200 且包含 2 个 Product ID，但当前 Simulator 的 StoreKit 返回 0 个可用自动续订商品；这把失败范围收敛到 App Store Connect/StoreKit 商品环境或商品配置，不代表客户端配置解析失败。生产随机设备 DELETE 曾返回 `unregistered`，但当前 checkout 路由未注册 DELETE；真实已注册设备、生产/分支契约比对、APNs token、outbox 清理和锁屏送达仍需验收。

同一真实账号又创建了一个 7 天后运行的临时 schedule 规则，完成版本更新、列表验证和删除墓碑，返回 `version=2` 与 `delete=deleted`；规则未执行，探针已撤销。该结果证明生产主动规则基础 CRUD 可达，不证明 Worker、运行状态、APNs 或多设备阅读/稍后同步。

同一真实账号又创建了一个 7 天后到期的临时云任务，完成版本更新、列表验证和删除墓碑，返回 `version=2` 与 `delete=deleted`；任务未执行，探针已撤销。该结果证明生产云任务基础 CRUD 可达，不证明已有任务的安全编辑、状态映射、审批、冲突或双设备同步。

同一真实账号又创建了一条临时偏好记忆，完成版本更新、列表验证和删除墓碑，返回 `version=2` 与 `delete=deleted`；探针已撤销。该结果证明生产云记忆基础 CRUD 可达，不证明增量冲突、双设备同步或账号删除后的服务端清理。

## 必须完成的服务端项目

### 0. 旧工具兼容或下线

当前 `feat/caobao-server-v2` 路由源码只挂载 `/api/v2` 助理契约，未找到客户端旧工具使用的 `/api/caobao/*`、`/api/report/*` 或 `/api/analyze` 路径。产品需要继续保留这些二级入口时，服务端必须明确兼容路由的认证、owner、额度、错误和流式协议；否则客户端应迁移到 v2 或下线入口，不能把旧静态 API 方法当作已完成能力。

### 1. 收藏功能去处

当前客户端已改为 owner-scoped 本机金句收藏，不再调用 404 接口。若产品需要跨设备收藏，新增 v2 契约，至少包括：

- owner-scoped list/create/delete/sync；
- cursor、版本号、幂等键和删除墓碑；
- 账号删除、切换账号和旧 token 不能复活数据；
- 收藏类型、来源、创建时间和更新时间的稳定字段；
- 认证失败、版本冲突和重复请求的明确错误码。

### 2. 主动更新

现有 profile、rules、runs 和 pause-all 路由需要补齐生产闭环：

- `ProactiveRun` 返回服务端权威的 `readAt`、`snoozedUntil`、`dismissedAt` 或等价状态；
- owner-scoped 的 read、snooze、close-this-kind 操作，具备幂等键和版本冲突；
- 规则的 `nextRunAt`、`triggerReason`、`sourceRefs`、`conversationId` 保持稳定；
- scheduler/事件队列、租约、去重、重试、死信和每 owner 频率限制；
- 安静时段、每日上限、全局暂停和账号删除必须在 Worker 侧强制执行；
- APNs transactional outbox、旧 token 清理、锁屏通用标题和点击 conversation deep link；
- 设备注销或切换 Apple 账号时，必须失效旧 owner 的 APNs 设备绑定；不能只按 `(user_id, device_id_hash)` 保留旧账号 enabled 行，否则旧账号主动推送可能落到新账号设备；
- 高风险动作只能产生提案，不能由 Worker 直接写外部系统。

客户端已在 `603462a` 实现 logout 时使用旧 access token 异步 best-effort 调用 `DELETE /api/v2/devices/{deviceId}`，网络失败不能阻塞退出。生产随机设备 ID 曾返回 `unregistered`，但当前 `feat/caobao-server-v2` 路由源码只看到 `POST /devices`；服务端必须先完成 production-versus-branch 比较并确认正式 DELETE handler，再用真实已注册设备验证 owner-scoped、幂等禁用、旧账号失效和对应 outbox 清理。

客户端目前只在本机保存未读/稍后状态，并明确标注不代表多设备同步。

### 3. 自定义角色

`/api/v2/characters` 需要用真实账号验证：

- list/create/update/enable/disable/delete 全部校验 owner；
- `expectedVersion` 或条件更新，旧版本返回可识别的冲突错误；
- 删除墓碑、分页、重复请求幂等和账号切换隔离；
- `systemPrompt`、`memoryScope`、`allowGlobalMemory`、`language` 等字段有长度和枚举校验；
- 旧 token、旧设备和已删除角色不能复活。

### 4. Apple 登录和账号生命周期

用真实 Apple 账号和真实 Bearer 完成：授权、刷新、退出、撤销、账号删除、旧 token 失效，以及服务端 owner 数据清理。客户端当前只有协议/mock 证据。

### 5. StoreKit 订阅和额度账本

需要 App Store Connect、服务端和真机联合验收：

- 生产 `GET /api/v2/subscriptions/apple/config` 必须在真实 Bearer 下返回当前账号的 `userId`、稳定 `appAccountToken` 和非空 `productIds`；客户端不硬编码 Product ID，而是使用该响应调用 StoreKit；
- 每个 Product ID 必须同时存在于 App Store Connect 和服务端 `products` 配置，字段至少包括 `productId`、`planId`、`includedQuota`、`periodDays`；当前仓库示例为 `com.caobao.monthly`（30 天）和 `com.caobao.yearly`（365 天），正式值以生产配置为准；
- 真实 Product ID、订阅组、月付/年付周期和价格配置；
- purchase、restore、退款、撤销、grace period、过期和重复通知；
- Apple transaction/JWS 验证、原始交易绑定账号、幂等处理；
- `expiresAt`、状态和 quota ledger 一致，不能把 StoreKit 本地状态直接当作服务端权益；
- 购买成功、服务端拒绝和网络中断时客户端交易 finish 行为可复核。

### 6. 会话、任务和记忆同步

客户端已经实现会话 change feed pull、全量回填、消息合并、删除队列和 tombstone 提交；记忆和任务也有各自的游标同步路径。生产未认证探针只证明会话路由已挂载，不能证明业务闭环。需要至少两台真实设备验证：增量同步、版本冲突、删除墓碑、冷启动恢复、账号切换、账号删除和旧设备离线后重新上线。服务端必须保持 owner 隔离，不能用全量覆盖恢复旧数据，并应记录 change feed 的保留窗口、resync 语义和删除墓碑生命周期。

本轮客户端静态契约审计还确认以下服务端要求不能省略：

- `confirmed` 与 `explicit` 都是已授权记忆；bridge/history 注入逻辑必须接受两者，不能静默丢弃 `confirmed`。
- 当前客户端会话同步只恢复文本；如果产品要求跨设备恢复图片、tool_call/tool_result 或 taskProposal，服务端必须先定义安全附件引用、大小/类型限制、提案历史降权和不可执行的只读回放协议，不能要求客户端直接信任任意远端 content part。
- 云任务必须返回稳定 `version`，支持 owner-scoped 条件 PATCH、幂等键、冲突错误和删除墓碑；服务端状态 `draft`、`waiting_approval`、`running`、`failed`、`completed`、`cancelled`、`paused` 必须保持可区分。
- 云任务 `pause`、`cancel` 和恢复写操作也必须接受 `expectedVersion` 或 `If-Match-Version` 并返回新的权威任务；当前部署路由可调用但没有条件版本参数，客户端因此继续禁用云任务的无条件状态按钮，避免双设备覆盖。
- 任务审批必须有客户端可调用的明确接口（例如 `/approve`），并返回一次性结果；不能让客户端把等待审批或失败任务误显示为 active。
- 主动 profile 更新必须支持 `expectedVersion`；规则运行重试必须复用稳定幂等键，避免超时后重复执行。
- `POST /api/v2/proactive/pause-all` 也必须消费并校验 profile 的 `expectedVersion`，返回新的权威版本；当前 handler 只读取 `paused`，丢弃条件版本，不能作为多设备安全写入契约。
- APNs sender 必须保留 Worker 写入的 `ownerId`、`route`、`taskId`、`proactiveRunId` 等路由字段；否则客户端收到锁屏通知后无法完成 owner 校验和 conversation deep link。设备 DELETE handler 也必须实际挂载并清理旧 owner 的 outbox。
- 生产随机设备 DELETE 曾返回 `unregistered`，但当前 checkout 路由未注册 DELETE；必须先解释生产/分支差异，再补充真实已注册设备、owner 隔离、旧账号失效和 outbox 清理证据，不能用随机 ID 的成功替代完整 APNs 验收。

### 7. AI 群聊（新增功能）

当前客户端和服务端都没有群聊协议。开始实现前先确定：

- participants/roles、speaker turn、编排策略和最大轮数；
- SSE 事件格式、取消、重试、幂等和执行历史；
- 每个角色使用的记忆范围、隐私授权和额度扣减；
- 高风险工具仍需用户确认；
- 多设备同步、删除墓碑和审计字段。

自定义角色不能替代群聊协议。

### 8. Universal Links 发布配置

客户端已接入 `conversation`、`task` 和 `proactive` 三类 HTTPS 路由；服务端发布前还必须：

- 在 `https://caobao.chat/.well-known/apple-app-site-association` 返回有效 JSON，覆盖当前正式 bundle ID 和 `conversation/*`、`task/*`、`proactive/*` 路径；
- 正式签名包嵌入 `applinks:caobao.chat`，并在真实 iPhone 上从 Safari、冷启动和已登录/未登录状态分别验证；
- AASA 变更后验证 CDN/反向代理没有缓存旧文件，点击后 owner 校验和错误路由不会泄露会话数据。

当前实测两个 AASA 地址均返回 HTTP 200，但 `appIDs` 为空，路径仍是旧的 `/chat/*`、`/morning`、`/evening`、`/fortune`、`/roast`，因此不能触发当前客户端的三类 Universal Link。

## 服务端完成门禁

只有以下项目全部有真实证据，客户端和服务端才可标记完成：

1. 真实 Apple 登录全生命周期和 Bearer 验证；
2. StoreKit 沙盒购买、恢复、退款、撤销和额度账本；
3. 真实 APNs token、锁屏送达和点击深链；
4. 真实模型额度扣减和 CN/INTL 路由；
5. 两台设备的会话、任务、记忆同步及墓碑；
6. 账号删除后服务端任务、角色、通知和数据清理；
7. TestFlight 签名、安装、冷启动和生产健康检查；
8. 若启用 AI 群聊，完成独立协议、幂等和执行历史验收。
