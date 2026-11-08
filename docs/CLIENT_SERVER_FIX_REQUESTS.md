# 草包客户端待服务端修复清单

这份清单只记录客户端已经实现、但无法在当前生产契约或发布环境完成验收的项目。客户端不以本地 mock、静态路由或随机资源探针替代真实服务端行为。

当前服务端 checkout 已包含 `service/caobao/worker.go`、`service/caobao/proactive.go` 和 `service/caobao/apns.go`；因此主动 Worker、运行生成和 outbox 属于“代码存在但生产配置/真实投递未验收”，不是简单的“服务端未实现”。本机没有 Go 工具链（`go: command not found`），本轮未执行服务端 `go test`，该结果归类为验证环境限制。

| 优先级 | 服务端要求 | 当前证据 | 通过标准 |
| --- | --- | --- | --- |
| P0 | `DELETE /api/v2/devices/{deviceId}` owner-scoped、幂等，并返回 `{status:"unregistered"}` | 客户端已串行化旧账号 DELETE 与新账号 POST；checkout 分支只注册 POST | 旧账号设备立即失效；重复 DELETE 不报错；outbox 不再向旧 owner 投递；新账号同设备注册不被旧 DELETE 覆盖 |
| P0 | APNs transactional outbox、Worker 重试/死信、安静时段和 owner 频率限制 | 客户端已有 token 注册、通知路由和通用锁屏标题 | 真实 token 注册后锁屏送达；点击进入正确 conversation/task/proactive；失败可重试且不重复投递 |
| P0 | APNs 自定义点击字段必须进入最终 JSON payload：`ownerId`、`route`、`taskId`/`proactiveRunId`（并保留通用锁屏标题） | checkout 的 `PushPayload` 定义了字段，但 `APNsSender.Send` 当前只写入 `deepLink`；客户端无 `ownerId` 时会安全丢弃冷启动路由 | 对任务和主动更新各发送一条真实通知，锁屏不泄露正文，点击冷启动后只进入当前 owner 的正确页面；服务端单测和生产抓包/日志证明字段存在 |
| P0 | 账号删除清理会话、记忆、任务、主动规则、执行记录、设备和 outbox，并保留墓碑防止旧任务复活 | 客户端本地清理和删除队列已通过；云端清理未验收 | 删除后旧 token、旧设备、旧任务和旧通知全部失效；重新登录不能恢复已删除数据 |
| P0 | AASA 正式配置 `webcredentials.apps`、`applinks.details[].appIDs`，覆盖 `/conversation/*`、`/task/*`、`/proactive/*` | 当前 AASA HTTP 200，但 `appIDs=[]` 且只有旧路径 | 正式签名真机点击三类链接均进入 App，并在登录恢复后打开 owner 正确页面 |
| P0 | App Store Connect 商品、服务端 Apple 交易验签和 quota ledger 完成配置 | `/subscriptions/apple/config` 有 2 个 Product ID；当前 StoreKit 商品数为 0 | 沙盒购买、恢复、退款、撤销均由服务端确认；客户端只在 confirmed entitlement 后显示额度 |
| P1 | `/api/v2/proactive/pause-all` 接受 `expectedVersion`，冲突返回明确 409/版本错误并返回新 profile | 客户端已发送条件版本并拒绝未递增响应；checkout handler 尚未执行条件更新 | 两台设备并发暂停/恢复不会互相覆盖；客户端可刷新权威状态 |
| P1 | 主动运行阅读、稍后、关闭此类的 owner-scoped 接口和执行历史状态 | 客户端当前只保存本机 read/snooze；关闭此类只提示未提供接口 | 多设备阅读/稍后/关闭状态一致，规则删除后旧 run 不重新出现 |
| P1 | 主动规则 Worker 真正执行 schedule/internal event，并写入 `ProactiveRun`、conversation 回流和幂等键 | 规则 CRUD 已真实通过；规则未实际执行 | 真实规则从 queued 到 completed/delivered，生成消息回到正确对话，重复扫描只生成一次 |
| P1 | 云任务 pause/cancel 使用 `expectedVersion`，并明确 `draft/waiting_approval/failed` 状态转换 | 客户端已 fail-closed 显示状态；当前服务端 handler 没有条件更新 | 并发编辑返回冲突；审批、暂停、取消和 Worker 状态可追踪且不误执行 |
| P1 | 自定义角色对话绑定协议，至少包含 `characterId`、角色版本和 memory scope | 角色 CRUD 已通过；当前对话请求只有 persona level | 创建/切换角色后请求携带正确版本和记忆范围，旧版本冲突不会静默使用旧提示词 |
| P2 | AI 群聊协议：参与者、轮次、speaker、停止/取消、幂等和执行历史 | 当前客户端没有群聊模型或 SSE 编排 | 先完成服务端协议和安全审批，再添加客户端群聊 UI；不能用 persona level 代替 |
| P2 | 旧运势、晨报、晚报、吐槽、决策、收藏和旧图片分析接口 | 生产旧路径仍有 404；客户端已降级或阻断无效请求 | 明确补齐认证/owner/额度/SSE 协议，或正式下线二级入口；不能以静态 API 方法存在视为完成 |

## 客户端已处理的边界

- Apple nonce/state、JWT 原文、Keychain 会话、账号切换和撤销处理已通过本地协议测试。
- StoreKit 不硬编码 Product ID，只接受服务端配置和服务器确认的权益。
- APNs 注销与重新注册已串行化，但服务端仍必须实现 owner-scoped DELETE。
- 主动更新、角色、任务、记忆和会话页面已做 owner 校验、版本/墓碑保护和失败提示。
- 旧接口不可用时客户端不再发送已知 404 请求，功能保留为二级迁移入口或明确下线。

## 验收门禁

完成以上服务端项后，必须重新执行真实 Apple、StoreKit 沙盒、APNs 锁屏、双设备同步、账号删除、主动 Worker、AASA 真机点击和 TestFlight 安装；本地 `Scripts/test-assistant.sh` 通过不能替代这些门禁。
