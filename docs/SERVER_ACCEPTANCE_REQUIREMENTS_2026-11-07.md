# 草包服务端待验收需求（2026-11-07）

这份清单只记录客户端验收中确认需要服务端或生产环境处理的项目。当前生产探测使用无认证请求，不代表已完成真实账号业务验收。

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
| `GET /api/v2/sync/conversations?cursor=0&limit=1` | `401 UNAUTHENTICATED` | 会话 change feed 路由存在；需要真实账号和双设备验证 |
| `GET /api/v2/conversations/changes?cursor=0&limit=1` | `401 UNAUTHENTICATED` | 会话 change feed 兼容路由存在；需要真实账号和双设备验证 |
| `GET /api/v2/tasks/changes?cursor=0&limit=1` | `401 UNAUTHENTICATED` | 任务 change feed 路由存在；需要真实账号验证重复规则和墓碑 |
| `GET /api/v2/memories?cursor=0&limit=1` | `401 UNAUTHENTICATED` | 记忆路由存在；需要真实账号验证读写、冲突和删除同步 |

## 必须完成的服务端项目

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

建议新增认证接口 `DELETE /api/v2/devices/{deviceId}`。接口必须 owner-scoped、幂等，禁用对应设备并清理该设备待发送 outbox；客户端已在 `603462a` 实现 logout 时使用旧 access token 异步 best-effort 调用，网络失败不能阻塞退出。当前服务端只有 `POST /api/v2/devices`，因此这项仍不能仅靠客户端完成。

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

### 7. AI 群聊（新增功能）

当前客户端和服务端都没有群聊协议。开始实现前先确定：

- participants/roles、speaker turn、编排策略和最大轮数；
- SSE 事件格式、取消、重试、幂等和执行历史；
- 每个角色使用的记忆范围、隐私授权和额度扣减；
- 高风险工具仍需用户确认；
- 多设备同步、删除墓碑和审计字段。

自定义角色不能替代群聊协议。

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
