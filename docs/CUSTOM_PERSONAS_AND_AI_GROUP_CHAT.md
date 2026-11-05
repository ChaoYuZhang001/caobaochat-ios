# 自定义角色与 AI 群聊

## 产品定位

自定义角色和 AI 群聊属于“对话”二级能力，不新增 iPhone 一级 Tab。用户可以先创建一个私有角色，再把 2–4 个角色加入群聊。群聊默认由用户触发，角色不会自行创建角色、发起外部写操作或互相无限循环。

首发目标是让用户完成这条闭环：

```text
创建角色 → 预览角色 → 新建群聊 → 选择 2–4 个角色 → @角色或选择主持模式 → 生成多角色回复 → 停止/重试/继续
```

## P0 功能范围

### 自定义角色

角色为 owner-scoped 私有资源，字段如下：

```text
Character
- id
- ownerId
- name
- avatar
- description
- systemPrompt
- greeting
- language
- memoryScope: none | character | group
- enabled
- version
- deletedAt
- createdAt
- updatedAt
```

角色创建页需要支持名称、头像、职责、语气、开场白和记忆范围。系统安全规则始终优先于用户自定义提示词；自定义提示词作为不可信配置处理。

### AI 群聊

群聊复用现有 Conversation 和 Message，但增加参与者和运行记录：

```text
Conversation
- conversationType: single | group
- groupMode: mention | moderated | round_robin
- maxTurns

ConversationParticipant
- conversationId
- characterId
- displayOrder
- enabled
- muted
- turnPolicy
- version
- deletedAt

GroupRun
- id
- conversationId
- triggerMessageId
- status: pending | running | waiting_approval | succeeded | failed | cancelled
- turnIndex
- selectedCharacterId
- idempotencyKey
- usage
- error
- createdAt
- completedAt
```

消息继续保留 `role=user|assistant`，新增 `speakerType=user|character|moderator`、`speakerId`、`speakerVersion` 和 `turnIndex`，这样历史、同步、删除墓碑和导出仍然可以复用现有会话链路。

首发只开放两种模式：

- `mention`：用户使用 `@角色名` 指定回复对象；没有明确 @ 时由主持角色回复。
- `moderated`：低成本路由器从已启用角色中选择一名角色回复，最多执行两轮。

`round_robin` 作为实验开关保留，默认关闭；每条用户消息最多 4 轮、最多 4 个角色，达到上限立即结束。

## API 契约

```text
GET    /api/v2/characters
POST   /api/v2/characters
PATCH  /api/v2/characters/{characterId}
DELETE /api/v2/characters/{characterId}

POST   /api/v2/conversations/group
GET    /api/v2/conversations/{conversationId}/participants
PUT    /api/v2/conversations/{conversationId}/participants

POST   /api/v2/conversations/{conversationId}/messages
POST   /api/v2/conversations/{conversationId}/stop
```

群聊消息请求增加：

```json
{
  "groupMode": "mention",
  "mentionedCharacterIds": ["character_01"],
  "maxTurns": 2,
  "requestId": "..."
}
```

SSE 增加以下事件：

```text
group.turn.started
group.speaker.selected
token
group.turn.completed
group.completed
approval.required
error
```

所有写操作都必须校验 owner、使用版本条件更新、要求幂等键，并保留删除墓碑。群聊中的角色只能读取本角色允许的记忆和当前群聊摘要；用户的全局记忆必须明确授权后才能注入。

## 客户端交互

- 对话的新建入口增加“选择角色”和“创建角色”。
- 群聊顶部显示角色头像、名称、启用状态和当前模式。
- 消息气泡显示角色头像、角色名和运行状态。
- 输入框支持 `@` 角色选择。
- 每一轮显示“正在等待谁、已使用多少额度、还能运行几轮”。
- 用户可以停止本轮、重试失败角色、继续未完成群聊。
- iPhone 将角色放在“对话 → 新建/角色”；iPad/macOS 侧栏增加“角色”二级入口。
- 角色记忆默认隔离；群聊只共享本群摘要。

## 安全与成本边界

1. 外部写操作、发送消息、购买、删除和提交表单仍然只能生成提案并等待用户确认。
2. 单群最多 4 个角色，单条用户消息最多 4 轮；默认串行执行，暂停后取消后续轮次。
3. 每个 owner 有群聊每日额度和并发锁；每个角色单独记录用量，防止自激循环。
4. 连续忽略只影响陪伴模式，不得用角色之间的争执、内疚或焦虑诱导回复。
5. 锁屏通知只显示通用标题，不显示角色提示词、记忆或群聊正文。

## 验收门禁

- 角色创建、编辑、预览、禁用、删除和恢复错误处理。
- 角色 owner 隔离、版本冲突、幂等重复请求和删除墓碑。
- `mention` 模式只让被点名角色回复。
- `moderated` 模式每条消息最多两轮，达到上限后稳定结束。
- 停止、取消、断线重连、重试和跨设备同步。
- 角色记忆隔离、群聊摘要注入和全局记忆授权。
- 每角色 usage、每日上限、并发限制和失败重试。
- VoiceOver、Dynamic Type、中英文切换和 iPhone/iPad/macOS 布局。
- 真实 Apple 会话、APNs、StoreKit 和 TestFlight 验收仍然属于发布门禁。

当前代码中的 `personaLevel` 只是三档风格偏好，不能替代角色实体；角色和群聊需要新增 owner-scoped 数据模型与服务器接口。

