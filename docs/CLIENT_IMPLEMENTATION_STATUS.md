# CaoBao 客户端实现与验证状态

更新：2026-11-02。产品方向：国际化个人 AI 助理。最新本地记录为 **Phase 32：核心功能代码闭环与一次性任务执行修复**；P0 核心功能已实现并通过本地客户端/服务端回归。真实账号、真实服务端部署、APNs/StoreKit 送达、签名/TestFlight 与 iPhone Duo 专用设备仍属于独立发布验收门禁。

Phase 17 的 18 套 / 622 组、Phase 18 的 19 套 / 694 组、Phase 19 的 23 套 / 850 组保留为第 17–19 节的历史记录，各自的源码、二进制与原生子集不能扩展为后续阶段证明。核心代码闭环以 Phase 32 的当前回归为准；真实服务端、Apple/StoreKit、系统交付、实机性能、签名/TestFlight 和强制 iPhone Duo 门禁仍保留。

## 1. 当前客户端实现

以下为累计能力清单；最新会话同步与验证记录见第 23 节，其余能力按各历史章节的证据范围区分代码实现与仍待发布验收的项目。

### 助理与聊天

- SwiftUI 首页、任务、记忆、历史、设置与订阅界面；按窗口宽度/size class 切换导航，共享聊天状态。
- BYOK 实际发送支持 OpenAI Chat Completions / Responses / Anthropic Messages；密钥在 Keychain，配置按用户隔离。
- 完整目标地址（含路径/端口）、协议、模型、密钥变化后，向 BYOK 发送历史/记忆/任务前重新确认；不自动切换平台。
- SSE 支持多行、CRLF、注释、UTF-8、大小上限；保留部分输出，区分完成、取消、失败、空输出与提前 EOF。取消会关闭底层网络请求。
- 实际 URLSession dataTask 启动前，在同一 MainActor 连续执行段复验账号、会话、配置代次和所选个人上下文签名；检查到 resume() 之间没有 await。排队期间发生撤权/删除等有效上下文变化时拒绝旧请求，不自动重发。
- 平台只使用 v2；先创建服务器会话，再使用服务器 ID 发送消息，正文另带本地 clientConversationId；不自动旁路旧聊天 API。
- 独立会话创建客户端限制响应格式/大小、拒绝重定向、校验服务器 ID，并支持注入测试网络。
- 记忆/活动任务与历史的真实内容按预算装配；关闭/删除/未确认的记忆不进入请求；不可信参考内容独立分隔。
- 按消息 ID、生成 run 和 owner 更新；新建/切换会话或账号后旧事件不能写入新会话。恢复中断归档时不会伪装仍在生成。
- 经验证且明确启用的 BYOK 三协议支持单个 create_task 提案及逐条用户审批，真实本机任务/回执闭环见第 19 节；平台工具仍关闭，不承诺联网搜索或自主后台 Agent。
- 新增按账号/CN/INTL 隔离的平台模型选择与服务器目录；校验默认模型/能力/区域，自动模式不写死供应商。平台消息明确携带 serviceRegion 和可选 model，服务器仍是模型权限权威。
- 重新生成入口增加费用确认，确认前绑定账号、会话、消息和接入方式；不把旧确认套到新会话。
- 全历史详情新增继续入口；iOS 首页/侧栏最近、新建和快捷预填统一走受保护切换。源草稿和部分回复保存成功后才停止实际生成与导航，切换不自动发送；当前集成验证进度见第 17 节。

### 图片与语音

- 主聊天 PhotosPicker、多图预览/移除/草稿与三协议图片载荷；最多 3 张/消息，最长边 1600，单张重新编码后不超过 512,000 bytes。
- 本机图片检查输入大小/像素预算，应用方向后重编码 JPEG，去除源 EXIF/GPS；不走旧公共图片上传接口。
- 异步图片处理有账号、会话和任务代次守卫，切换会话不会携带旧图片。
- 系统 Speech/AVAudioEngine 按用户点击启动语音输入，最多 60 秒；后台/中断/账号变化会停止。支持手动朗读，不自动播放。
- 已提供相机、麦克风和语音识别的中英系统用途说明，披露不支持本机识别时可能由 Apple 处理。**未实际录音或验证 TTS/真机识别质量。**

### 存储、记忆、任务与提醒

- 会话、含图片草稿、记忆和任务按用户隔离；原子写入、iOS 文件保护、损坏文件保留且拒绝普通覆盖。
- Phase 17 的草稿采用单账号文件内按 conversationId 保存、独立活动指针；Phase 18 的 SQLite 迁移与显式准备边界见第 18 节。文字/图片未发送源仍保留可达的 draft-only 历史入口，不把草稿伪造为已发送消息。
- 记忆 CRUD、来源/同意、分类、搜索、导出和全局使用开关；新增按账号保存的类别使用开关。全局关闭或某类别关闭后，该类记忆仍可管理/备份，但不进入新请求的 ContextBuilder。
- 单条授权区分已授权、尚未确认、已停用；普通编辑保留未知 consent 原值，全局/类别重开不重新授予单条权限。编辑/删除通过完整记录快照 CAS，陈旧编辑不能覆盖新正文或复活删除记录。旧空白/超长正文未改变时仍可撤权。
- 类别关闭不等于删除；真正删除保留状态墓碑并清空正文及来源消息，备份也不能把已清空内容恢复出来。
- 任务 CRUD、完成/重开、暂停/恢复/取消、时区及到期时间；新增每日/每周规则、时分模板、可信生效下界及整计划完成确认。
- 一次性与重复本地提醒必须单独启用；仅保存到期时间或重复规则不会申请通知权限。保存失败按最新快照恢复旧提醒，完成/删除等操作清理整组通知。
- 提醒 ID 按 owner 隔离；系统锁屏内容不含任务正文；点击通知检查 owner 后跳转任务，支持冷启动暂存路由。
- 按 owner 保存的本地安静时段默认关闭，独立记录开始/结束分钟、地区时区与生效元数据；延后已开启的一次性/重复提醒，不改 dueAt、不开启新提醒、不额外请求权限。重复计划开启安静时段后预排 7 次并需前台补排，关闭时使用原生日历重复；具体防重放、失败与并发语义见第 13 节。
- 已完成通知后端、任务/会话/记忆的轻量云同步及部分真实 UI 测试，**不代表已通过系统权限、真实安排/送达或 APNs 验收**。本地每日/每周重复已实现；生产通知与真实多设备冲突验收仍待完成。

### 身份与权益

- 原生 Apple 登录配置随机 state 与 nonce/SHA256；原始 JWT/授权码交由 v2 服务验证，旧登录令牌不自动成为 v2 会话。
- 访问/刷新令牌、到期时间和服务根地址整组原子保存于 Keychain；合并刷新、账号代次守卫、退出残留防复活。
- 服务器账号导出与本机助理备份明确分开：前者保留服务端返回的 JSON，后者只收集当前 owner 的本地会话、草稿、记忆、任务、记忆使用策略及本机提醒偏好。
- 删除请求被服务端受理后，先保存按 owner/服务 origin/服务器 requestId 关联的清理元数据，再尝试处理本机提醒、记忆/任务、会话/草稿、该账号 BYOK Key 和偏好。记录不包含令牌、Key、对话正文或任意错误原文。
- 删除受理、服务器删除完成、本机清理完成是三个不同状态。退出登录后仍可见删除结果横幅；有已持久化待处理项时可以重试本地清理。重试不会刷新 Token、再次请求服务器删除或调用模型；当前已登录账号不会执行旧任务重试，也不展示旧账号横幅。
- 账号/身份代次变化或取消会停止后续清理；失败的组件保留待处理状态，关闭提示不丢弃尚未完成的任务。元数据损坏或无法保存会明确提示未能确认清理，而不伪造完成。
- 账号删除不等于取消 App Store 自动续订。服务端状态通过随机删除请求 ID 的只读查询回读；真实账号删除、Apple 生产环境和实际数据清除仍需联调验收。
- 每日 8 次只显示服务器已验证余额；账号切换/过期失效，刷新合并并节流。
- 首页分开展示每日与订阅周期余额；订阅周期和 included/remaining 来自服务器，不硬编码 600 次，也不把未来每日赠送当作现有余额。非法范围/日期和到期周期不能启用余额。
- StoreKit2 客户端具备读取商品、显式购买/恢复/管理与交易验证流程；价格和商品 ID 来自 StoreKit/服务器。账号 token 与服务器确认均通过才 finish；没有本地 Boolean 授权。
- **没有配置真实套餐或执行真实购买/恢复；US$9.99、600 次/月与叠加规则仍是拟定商业方案。**
- Storefront 仅给 CN/INTL 建议，需用户确认；不能证明下载时 Apple 账号、国籍或实际位置。

### 本地数据备份

- “数据与隐私”入口支持未登录的本机 BYOK 工作区；账号设置也可进入本机备份，并单独保留服务器账号数据导出入口。
- 生成备份前先将当前 ChatViewModel 尚未保存的草稿、图片和流式片段写入对应 owner 的归档；不会为导出而停止生成。flush 失败则不假装备份完整。
- 后台准备有协作取消及 owner/run 守卫；账号变化后清空待展示文档并丢弃旧结果。准备备份本身不请求服务器或上传；用户选用的文件供应商可以有自己的同步机制。
- 本地 JSON 使用 schemaName=caobao.assistant.local-export、schemaVersion=1、dateEncoding=unix-seconds；包含 includedScopes、图片选项与省略计数。draft 表示活动草稿，新增 conversationDrafts 与同名 scope 包含其他保存草稿；图片预算/省略计数覆盖所有草稿。记忆包括禁用记录、删除墓碑及全局/类别隐私选择；持久标记删除的会话/草稿不进入导出。
- schemaVersion=1 以新增字段方式加入 taskPreferences.quietHours，并在 includedScopes 增加 reminder-preferences；使用明确的类型与预算字段，不导出任意 UserDefaults。Phase 20 已加入同原始 owner 的本地备份预览与明确恢复，现有偏好不被导入覆盖，边界见第 20 节。
- 不读取或附加 Keychain 凭据、登录 Token 或连接配置；用户自己写在消息、草稿、记忆中的任意原文仍会保留，不是自动去敏或加密备份。
- 可明确排除会话和草稿中的图片，并按附件出现次数记录 omittedImageCount；不悄悄截断其他内容。默认输出预算 32 MiB，调用配置允许上限 64 MiB，先预算字段树再编码并以最终 Data 大小复核。
- 输出预算不等于源归档读取/解码内存上限，也不是跨会话文件与仓库的全局事务快照。读取损坏、不可访问路径或预算超限会失败；真正不存在的归档才视为空。
- 已接入原生 FileDocument/fileExporter；早期 iPad 导出小样本与 Phase 20 普通 QA19 文件选择、预览、现有冲突合并和重装后重复恢复分别保留各自证据。Phase 21 增加长期记忆的账号隔离云同步；仍未提供自动跨账号迁移，原生向空目的地新增、所有文件供应商、容量、真机与真实账号场景未完整验收。

### 国际化

- 主助理界面、身份/账号错误与权限说明提供简中/英文资源；旧工具页面仍有未完成的国际化。
- 核心动态错误/提示通过线程安全的 AssistantLocalization 选择实际 lproj，支持 system/en/zh-Hans；AppState 切换当前账号语言时同步该运行时选择，不新增全局持久化用户偏好。
- 新增 BYOK 显式连接测试：费用和目标服务确认、固定无隐私测试消息、约 16 个输出 token、20 秒总超时与取消；只确认文字流正常完成，不宣称图片/工具已兼容。初次空 API 配置不再阻止保存语言偏好。

## 2. 可复现验证

从仓库目录运行：

```sh
Scripts/test-assistant.sh
git diff --check
xcodebuild -resolvePackageDependencies -project Caobao.xcodeproj -scheme Caobao -clonedSourcePackagesDirPath "$PWD/.build/remote-source-packages" -onlyUsePackageVersionsFromResolvedFile
Scripts/build-simulator.sh
```

统一入口当前包含 28 套脚本，逐项名称与组数见 `.build/verification/phase20-final-regression-summary.json`；最新实际结果为 **947 个独立组、exit 0**，完整日志 `phase20-final-full-regression.log`，具体范围见第 20 节。只计独立 PASS 组，不将数字汇总行、定向重跑或 UI 检查重复累计；脚本存在不等于通过，历史 694/850 组不作为当前结果。

测试编译真实生产模块；会话/文件测试使用隔离临时目录，状态机使用 test-only 身份/Keychain 替身、注入 URLProtocol，删除测试使用隔离元数据与 fake cleaners。它们不访问真实网络、模型、Keychain、麦克风或通知权限，也不删除真实账号。平台路径测试验证服务器会话 ID 衔接，不等于完成 CiYuan2API 联调。

默认构建使用原 Caobao.xcodeproj、官方远程 Alamofire 和 Xcode 共享 Package.resolved，严格禁止自动选择其他版本；项目包缓存和 DerivedData 分别为 .build/remote-source-packages 与 .build/remote-client-derived-data。首次环境先按锁执行 xcodebuild -resolvePackageDependencies，再运行 Scripts/build-simulator.sh。显式设置 CAOBAO_LOCAL_ALAMOFIRE_PATH 时才复制到 simulator-workspace 并使用独立 simulator-derived-data；只改副本，不能把该模式当远程依赖验收。详见第 14 节。

## 3. 服务端对接

现有身份、对话、图片、StoreKit 和订阅周期额度结构见 [ASSISTANT_V2_API_CONTRACT.md](ASSISTANT_V2_API_CONTRACT.md)。**CiYuan2API 中的 CaoBao v2 实现、部署和生产验证尚未完成**。客户端代码和隔离测试不能替代服务端验签、额度事务与交易归属验证。

本轮只读核验本地 CiYuan2API candidate-rc47-reconstructed：现有 /v1 三协议路由不能替代 CaoBao v2 账号、每日额度、会话和 StoreKit 业务契约；该 checkout 未发现对应 CaoBao 实现，127.0.0.1:3000/api/status 当时连接拒绝。本轮未修改或启动服务端，也不据此推断线上部署状态。

## 4. 发布门禁（未完成）

1. CiYuan2API 预发布/生产地址、Apple 正式验签/refresh/revoke、真实额度账本、区域/模型权限及订阅生命周期联调。
2. 真实上游三协议、长上下文与成本、语言质量、弱网和取消的端到端验证。
3. 真机图片/语音、通知授权与实际送达、StoreKit 沙盒购买/恢复/退款/撤销验证。
4. 用户授权的工具执行、任务 Worker/APNs 与跨设备同步；本地每日/每周重复已实现，真实通知安排和送达仍需验收。
5. 旧数据迁移、备份导入/恢复与跨设备同步；更多原生文件供应商/容量/真机保存场景；真实账号的服务器导出及删除完成闭环；旧工具国际化、全量 VoiceOver/Dynamic Type 和剩余语言细节。
6. **iPhone Duo 专用设备/姿态 API 与真机或专用模拟器验收，强制发布门禁。** 本机当前只有普通 iPhone/iPad 类型，不能以这些运行结果替代 Duo 验收。
7. 正式签名/archive/TestFlight；共享锁修复和原工程官方远程依赖构建已完成，见第 14 节。

## 5. 历史手动运行证据

- 既有 iPhone 17 Pro iOS 26.5 验证：通过页面新增测试任务并完成，进程重启后该任务仍为 completed。
- 既有 iPad Pro 11-inch (M5) iOS 26.5 验证：英语分栏首页；截图在 `.build/screenshots/`。
- 该历史阶段统一入口实际执行：**235 个独立测试组通过，exit 0**。分组：repository 17、protocol 17、archive 10、media 12、reminders 10、reminder-coordinator 8、identity 12、entitlements 13、conversation 14、localization 13、models 18、connection 14、data-export 16、deletion 18、chat-viewmodel 43。该数量保留为历史记录；当前日志和 summary 已更新为第 9 节的 299 组。汇总行不重复计数。
- 该历史阶段 Xcode 26.5 / iOS 26.5 Simulator Debug 构建已实际成功；当次安装前逐一比对了构建副本中的 70 个 Swift/strings/Info.plist 文件，未发现差异。没有进行正式签名归档。
- iPhone 17 Pro 新构建：英语首页区域/模式无残留中文，未登录订阅页显示不可用且不伪造价格/额度；实际竖屏→横屏→竖屏，仍停留在同一订阅页。
- 实际在设置将语气临时改为 Gentle，再从竖屏切横屏，弹窗及未保存选择保持；关闭弹窗未保存该测试修改。
- iPad Pro 11-inch (M5) 新构建：实际查看英语分栏首页与聊天输入区；图片、语音及发送入口可见。没有点击录音、购买或发起真实模型生成。
- 审查补上了侧边栏新建对话的实际清理动作、语音/图片会话守卫与聊天快捷操作本地化；最终界面资源更新已构建成功；平板实测个人助理欢迎语与三项快捷操作均为英文，输入后发送按钮启用，点击聊天页新建后草稿清空且发送按钮禁用。不扩大为侧边栏鼠标点击、真实语音/模型/订阅已经通过。
- 普通模拟器结果仍不能替代 iPhone Duo、Apple 登录、StoreKit 交易或系统通知实际送达验收。

该阶段截图：`.build/screenshots/assistant-latest-iphone-home.png`、`.build/screenshots/assistant-latest-ipad-chat.png`；均为本地模拟器测试产物。

## 6. 模型与设置历史阶段验证（2026-10-29）

- 模型目录：真实 URLProtocol 测试 18 组，覆盖区域错配、重复/缺失模型、明确能力、默认模型、大小边界、取消与拒绝重定向。
- 模型选择：真实 ChatViewModel 测试增至 29 组，包含 CN/INTL、账号隔离、自动不指定 model、完整模型 ID 到实际请求和归档、非法/未确认区域阻断。
- 动态语言：真实临时资源 Bundle 测试 13 组，覆盖实际 lproj、回退、格式及并发查值；不是仅替换 Locale 参数的静态测试。
- 连接检测：真实注入传输测试 14 组，包含三协议载荷、有效文本+终态、超时、工具/空输出/截断失败与取消底层请求。未接真实服务或产生模型费用。
- 只读复核发现并修复身份刷新失败的账号竞争：刷新前绑定账号/Token，旧取消或迟到失败不能覆盖新账号的模型/额度。此项为代码复核，不冒充已完成真实账号切换端到端测试。
- 设置页拆分为基础偏好、BYOK、连接检测与平台模型子视图；该阶段源码已实际构建成功；模型目录及连接测试界面可运行，导航语言修复也已安装到模拟器。

### 该阶段界面回归补充

- iPad / 系统英语：应用内英语→简中→英语双向切换，首页正文、侧栏和导航标题同步改变；没有用重建根视图或清空聊天来修复标题。测试结束恢复原英语偏好。
- 初次空 BYOK 配置可以保存语言；首页仍显示 Not configured / 未配置，没有虚构连接成功。
- 中文设置临时切换平台模式：显示自动区域默认及“未登录”，不生成供应商或可用模型列表。该模式草稿未保存，未冒充已联通真实服务。
- 使用未保存的 api.example.com / 虚拟模型 / 非真实Key，点击“测试连接”只显示费用确认；弹窗明确列出 api.example.com、可能费用及不发送历史/记忆/任务。实际选择取消并关闭设置，没有点击“继续测试”，没有发起真实模型请求；重新打开后字段为空，虚拟配置未保存。
- 费用确认截图：.build/screenshots/assistant-probe-cost-confirmation-zh-ipad.png；模型空状态截图：.build/screenshots/assistant-models-unavailable-zh-ipad.png。
- 该历史阶段结束时独立测试计数为235组；当前计数见第 9 节。原完整日志中的本地化数字汇总行不作为额外测试组；测试结束输出已统一，避免重复计数。
- 重新生成确认已编译并通过代码复核；真实付费对话下的整条UI/计费闭环仍待真实服务验收。CiYuan2API v2、Apple/StoreKit与iPhone Duo发布门禁仍未完成。

## 7. 数据管理与删除清理历史阶段证据（2026-10-29）

以下数量与 UI 记录对应当时已验证版本，保留历史事实；当前仓库、导出及总测试数量见第 9 节。

- 本地导出服务 16 组实际临时文件测试通过：账号隔离、完整范围及版本解码、保留用户原文、禁用/墓碑和类别隐私、明确图片排除及计数、刚好预算/超一字节、损坏/不可读来源、取消以及源文件逐字节不变。
- 仓库测试现为 17 组，归档测试 10 组；覆盖类别策略、只读导出快照、真正缺失与 ENOTDIR/读取失败的区分。ChatViewModel 测试现为 29 组，新增未保存草稿/图片/流式片段的导出前 flush、错误归属阻断及损坏/写失败传播。
- 删除通知/协调器 18 组通过：受理元数据持久化、不同 owner/origin、部分清理与仅重试失败项、关闭不丢待办、坏记录保留、同账号重新认证/身份变化和取消。使用 fake cleaners，不能据此声称真实 Keychain、系统通知或服务器数据已删除。
- 本阶段已验证版本的 Simulator 构建日志末尾为 BUILD SUCCEEDED，已安装到 iPad；当次构建副本的 70 个 Swift/strings/plist 比对一致，未做正式签名归档。此记录不覆盖之后尚未验证的源码变更。
- iPad 本地备份 UI 实际出现“The backup was saved to your selected location”；在模拟器 File Provider Storage 找到 CaoBao-assistant-backup.json 并解析，验证副本位于 .build/verification/local-export-simulator.json。此样本 owner 为 local-device，含一条草稿，conversation/memory/task 数量均为0，imagesIncluded=true，顶层无凭据/连接配置字段。这证明该小样本原生保存已完成，不等于已验证真实账号、多图片、大文件、全部文件供应商或导入恢复。
- 保存后通过真实新建对话入口恢复空草稿、发送按钮禁用。记忆页事实类别开关实际关闭后显示“Not used in new conversations”，磁盘 excludedMemoryCategories 中出现 local-device 的 fact；随后恢复开启。类别 UI 与磁盘变化已验证，未发送真实上游模型请求。
- 上述原生保存、草稿复位及类别开关的逐项验收记录为 `.build/verification/local-data-ui-checks.json`，类别截图为 `.build/screenshots/assistant-memory-categories-en-ipad.png`。检验文件明确标记 cloudSyncOrImportTested=false、realAccountDeletionTested=false。
- US$9.99/月、600次/月及每日赠送叠加仍是提案，未配置真实商品或套餐；CiYuan2API、Apple/StoreKit 和 iPhone Duo 仍为未完成的发布门禁。没有将本地测试或本次文件保存扩大为客户端/服务端全部完成。


## 8. 历史删除与导航回归阶段记录（2026-10-29）

- 新增按 owner 执行的统一 `deleteConversations(ids:ownerId:)` / `deleteAllConversations(ownerId:)`。删除当前会话不再经过会自动归档的普通 cancel 流程；迟到 delta 不能复活刚删除的归档。删除无关会话不终止当前生成、不清空当前输入、附件或 BYOK 授权。
- 删除集也检查持久草稿的 conversationId。若删除旧 B、当前为 A，则用 A 当前草稿替换 B 的残留草稿，避免下次启动恢复 B。实际临时目录复现已从 DELETED_ID_REAPPEARED=true 变为 false；不是仅检查数组中已无 B。
- 写盘前失败保留状态；归档与草稿两文件部分成功时明确报错，保留可见恢复内容并阻止受影响 ID 自动写回。没有宣称跨文件事务。
- `openConversation` 按当前 owner 和 ID 重新读取，不信任过期页面快照；重新打开当前会话为 no-op，避免旧归档覆盖未节流文本/草稿。
- HistoryView 的 Home 嵌入模式与详情共用 `[AssistantHomeRoute]`，独立模式仍有自己的 ID 路径。账号变化或删除时按 owner/有效 ID 修剪详情；详情只显示复制，不再提供空实现的点赞、重生成、删除或举报按钮。复制前重新查归属。
- 实际 UI 捕获过 `SwiftUI.AnyNavigationPath.Error.comparisonTypeMismatch`；统一 Home/History 路由、移除重复 detail 导航容器，并把侧栏改为手动选择后，iPad 已实测：首页→历史→详情→返回，以及 Chat/Home 切换、切回恢复原详情。搜索与日期为英语，详情只有 Copy。未点击复制以更改剪贴板，也未发起生成。
- 该阶段 ChatViewModel 真实生产代码隔离检查由29增至43组；当时统一入口合计235组、exit0。新增14组覆盖活跃流/迟到事件、owner变化、同页重开、旧草稿重启恢复、真实 chmod/immutable 文件失败及部分清理。测试使用临时归档与注入网络，不接真实账号或模型。
- UI 逐项记录：`.build/verification/history-ui-checks.json`；截图：`.build/screenshots/assistant-history-list-en-ipad.png`、`assistant-history-detail-en-ipad.png`。合成历史记录已移除，原始空草稿文件按备份逐字节恢复；未删除真实用户历史。
- 手机横屏紧凑分栏默认正文已实测；iOS17+ 使用 `preferredCompactColumn`，iOS16保留完整 Tab 布局。最终构建的 MinimumOSVersion 仍为16.0；未运行iOS16 runtime。iPhone17 Pro/iOS26.5已实际验证订阅页在正常竖屏与横屏之间保持同一路径，最新版本再次验证横屏进入订阅并旋转正常竖屏后返回首页。未执行购买或真实登录。

这些历史操作只管理本机归档，不构成服务器会话删除、跨设备同步或完整账号删除证明。


### 紧凑侧栏入口与最终验证边界

- Home/Chat/Tasks/Features/Profile 的紧凑根页新增44pt“显示侧栏”按钮，仅调用首选列动作；Home非空子路径和Features子目的页保留正常Back，不清空会话或导航。iPad普通宽屏没有新增重复根按钮；macOS为无操作兼容实现。
- 移除生命周期任务中重复强制正文列的赋值。仅DEBUG输出 `[CaoBaoLayout]` 枚举标签/路径深度诊断，不记录账号、会话ID、文本或凭据；Release不附加诊断观察。
- **侧栏按钮的完整点击验收尚未完成。** 当前远程可访问性树未暴露横屏导航栏按钮；坐标测试没有对应action事件，对已知可用订阅按钮做坐标对照还出现windowNotFoundAtPosition。不能区分输入命中与应用行为，因此不能把先前系统Back无变化认定为已确认产品缺陷，也不能声称新增侧栏按钮已通过实际点击。按钮可见与代码实现不等于闭环验收。
- 该侧栏阶段iOS26.5 Simulator Debug实际构建成功：`.build/verification/explicit-sidebar-build.log`。当次安装前70个Swift/strings/plist逐一比对一致，哈希在 `.build/verification/final-build-source-match.json`；当时已安装手机和平板。没有正式签名/archive/TestFlight或macOS目标完整构建。
- 手机旋转/输入范围记录 `.build/verification/compact-ui-checks.json`；订阅页面竖横屏截图为 `.build/screenshots/assistant-subscription-portrait-final-iphone.png` 和 `assistant-subscription-landscape-final-iphone.png`。这些普通设备结果仍不能替代强制iPhone Duo专用验收。

## 9. 本地安静时段与当前验证（2026-10-29）

### 9.1 时间和持久化语义

- 配置为 enabled、startMinute、endMinute、timeZoneIdentifier。默认关闭，默认编辑时间为 22:00—08:00；默认时区取受支持的当前地区时区，无法匹配时用 UTC。分钟必须为 0…1439，开始与结束不可相同，关闭状态也校验配置。时区独立于每条任务的 timeZone，使用受支持的 IANA 标识及 UTC/GMT。
- 安静窗口开始包含、结束不包含，支持同日与跨夜。只用任务原始 dueAt 锚定当天/前一日窗口，命中时将通知 fireAt 延后至该窗口结束，再以 fireAt 判断过期；不改任务 dueAt、状态或 reminderEnabled。午夜前到期而早晨送达的提醒不会被误删；已错过原窗口的旧一次性提醒不会在以后每天复活。
- 夏令时重复时刻：开始取第一次出现，结束取最后一次出现；不存在的当地时刻取跳变后的首个真实时刻，不假设跳变恒为一小时，覆盖半小时与历史偏移。若窗口完全落在被跳过的间隙而没有真实持续区间，则不制造额外的安静窗口；非法日期/无法计算明确报错。
- 仓库按 owner 保存完整配置。单份仓库提交先暂存副本并原子写盘，成功后才替换内存；失败保持先前内存和磁盘配置，暴露 lastError。旧记录缺字段时默认关闭，损坏或不可读记录不能降级为空配置；账号删除同步清理对应配置。此原子性不扩大为跨归档文件或系统通知的事务。
- 本地备份新增 taskPreferences.quietHours 与 reminder-preferences scope，保持 schemaVersion=1 的增量字段演进；字段纳入导出前预算和最终 Data 大小复核，按 owner 隔离。无新增 HTTP、服务器偏好同步、APNs 或跨设备提醒同步。

### 9.2 保存、重排与在途候选保护

- saveQuietHours(_:ownerId:) 先检查账号/会话、取消与配置，再原子保存；抛错表示本次未保存。正常返回则配置已保存，report.errors 仅报告部分重排失败、取消或已被其他操作替代，不能将其显示成保存失败。UI 正常返回后读取当前 owner 的仓库值，不把旧请求值盖回新配置。
- 重排不请求系统通知授权、不启用未开启的任务提醒；替换失败时不留下落在新安静窗口的旧 pending。已提交后即使关闭设置页导致取消，仍执行带 owner/session 守卫的最佳努力重排；界面使用 owner/run 守卫丢弃迟到结果。
- 每个在途调度记录候选 plan、owner/session、安静策略快照/版本和 operation UUID。普通 reconcile 仅保留与当前有效候选完全匹配的 pending；策略变化使该豁免失效。迟到 add、saveTask 及持久化失败后的旧提醒恢复均重新检查策略，按 UUID 清理自身操作并从最新已落盘状态修复。
- 独立审查使用真实生产 actor 与 fake 通知后端复现过“后端已写候选、add completion 尚未返回，普通 reconcile 按旧任务删掉候选，随后任务保存成功却无通知”的竞态。holdAfterStore 精确模拟系统先应用请求再返回完成的时序；修复后同策略下候选和最终 pending 均保留，新策略下危险候选仍立即清理，授权请求数保持 0；这不是对真实通知中心送达的验收。

### 9.3 编译与 UI 验收边界

- 当前最终 iOS Simulator Debug 构建已实际成功，日志 `.build/verification/quiet-hours-ui-build.log` 末尾为 BUILD SUCCEEDED；该构建包含在途候选修复和设置页 PageIdentity。没有正式签名/archive/TestFlight 或 macOS 目标完整构建。
- 设置页 PageIdentity 的实际导航回归已于2026-10-30完成：启用/关闭的未保存草稿均在时区选择返回后保留，当前已保存摘要在明确保存前不变；选纽约后保存成功，磁盘4字段一致，重新安装/启动后仍恢复启用+纽约。随后选择上海并关闭保存成功。该场景为匿名本机工作区且没有启用中的任务提醒。
- 紧凑侧栏按钮的完整点击仍未验证；既有可见性、普通设备旋转与历史导航证据保留第 8 节的范围。真实通知授权/送达、CiYuan2API、Apple 登录、StoreKit 及 iPhone Duo 专用验收仍未完成。所有价格和套餐次数仍为提案。

### 9.4 静默阶段完整回归（历史基线）

统一入口已实际执行完成：**16 套脚本、299 个独立测试组，exit 0**。日志 `.build/verification/all-client-checks.log`，计数 `.build/verification/summary.json`；摘要行不重复计入测试组。

| 套件 | 通过组数 |
|---|---:|
| quiet-hours | 31 |
| repository | 23 |
| protocol | 17 |
| archive | 10 |
| media | 12 |
| reminders | 15 |
| reminder-coordinator | 26 |
| identity | 12 |
| entitlements | 13 |
| conversation | 14 |
| localization | 13 |
| models | 18 |
| connection | 14 |
| data-export | 20 |
| deletion | 18 |
| chat-viewmodel | 43 |
| **合计** | **299** |

静默相关检查使用真实 Foundation 策略、actor、隔离磁盘与 fake 通知后端，包含 DST/跨夜/原 due 锚定、原子保存失败、同账号竞争、holdAfterStore、账号切换及取消；不访问真实模型、执行真实购买/账号删除或请求系统通知授权，也不证明真实送达。


### 9.5 实际界面与测试数据收尾（2026-10-30）

- 已通过真实 iPhone17 Pro/iOS26.5 Simulator 可访问性入口验证：设置入口、默认关闭22:00–08:00/Asia/Shanghai、时区搜索和选择、草稿保留、明确保存反馈、重新安装与进程重启恢复、关闭并恢复原始时区。任务/记忆及任务提醒同意字段逐项比较未变，没有出现通知权限弹窗。
- 最终搜索支持空格/下划线等价城市名匹配，例如 New York 对应 America/New_York；实际无匹配输入显示双语空状态说明。没有通过UI修改钟点、切换真实账号或测试真实通知送达。
- 原始仓库备份在受限权限目录 `.build/verification/quiet-hours-ui-original/`；结束前校验其他字段未变，终止测试应用后恢复原始文件字节并重新启动。临时启用的纽约策略已清除，原始SHA256一致。
- 逐项UI记录：`.build/verification/quiet-hours-ui-checks.json`；保存界面截图：`.build/screenshots/assistant-quiet-hours-saved-en-iphone.png`。最终生产源文件比对为72个Swift/strings/plist，零差异，见 `.build/verification/final-build-source-match.json`。
- 299组隔离检查仍是临时文件/注入传输/fake通知后端验证，不能扩大为真实系统通知、跨账号联调、服务器推送、Apple/StoreKit或iPhone Duo完成。紧凑侧栏点击闭环仍保持单独待验收状态。

## 10. 聊天消息转记忆与待办（2026-10-30）

### 10.1 用户可见行为

- 当前聊天中已完成且非空的文字消息提供“保存为记忆”和“创建待办”。打开菜单或表单不写数据；记忆正文完整预填，待办说明完整预填且标题留空，必须由用户编辑确认并明确保存。
- 复用独立记忆/任务编辑器。正文保留首尾空白、缩进和换行；不自动截断、不解析日期、不调用模型、不执行消息中的操作。新待办默认无日期、重复或提醒，requiresApproval=true；即使保存，也不代表批准任何外部执行。提醒仍需用户自行设日期、开启开关并保存。
- 历史只读详情不增加派生入口；首页“最近对话”继续聊天的入口与“全部历史”只读详情分开验收。
- 记忆正文与任务说明上限20000个Swift Character，任务标题上限200；越界提示手动编辑，不静默裁剪。旧记录仍可读取、导出、删除及更改任务状态，正文修改遵守新边界。

### 10.2 来源、提交与数据兼容

- AssistantChatActionSource绑定owner、conversation、message、role/status、原文、作用域和消息修订号。账号/会话往返、删除/重生成、内容或状态变化均使旧确认失效；恢复相同文字不能复活旧确认，点赞不会使来源失效。
- 记忆来源在MainActor中同步复核并通过insertMemory原子只新增：已有ID与删除墓碑均不可覆盖。强制当前owner/source、explicit consent和active；读回核验，成功后消费票据，磁盘失败保留可重试草稿。
- 待办保存增加兼容参数validateBeforeCommit。最终MainActor来源复核与同步仓库提交之间没有await；按owner/operation的提交许可在身份、退出或安静策略变化时失效。通知候选已应用后若来源失效，沿原有路径清理/恢复，不先保存再报来源失效。
- AssistantTask.sourceMessageId是可选新增字段，旧档缺失仍可解码；导出保留该字段并纳入精确字节预算。没有新增或宣称已经实现服务端HTTP接口。

### 10.3 实际验证与范围

- 统一Scripts/test-assistant.sh已完成：**16套脚本、337个独立测试组，exit 0**。相对第9节历史基线新增38组：repository 29、reminder-coordinator 38、data-export 21、chat-viewmodel 62；其他套件计数不变。完整统计见 .build/verification/message-actions-summary.json，日志为 .build/verification/message-actions-all-client-checks.log。
- 最终iOS Simulator Debug构建成功：.build/verification/message-actions-final-build.log。72个生产Swift/strings/plist与构建副本逐项一致，记录 .build/verification/message-actions-build-source-match.json；双语资源plutil检查和git diff --check通过。
- iPhone17 Pro/iOS26.5 Simulator使用明确标识的本地完成消息夹具，实际验证菜单、预填、取消记忆不写、明确保存记忆、填写标题后保存待办、原文缩进/尾换行与来源/授权落盘、无默认日期/提醒/重复、重启后两类记录可查看。经“全部历史”进入的详情只显示真实复制操作。
- 打开与取消确认页不写仓库。新增记录保留有效记忆/安静偏好；旧档缺失的可选字典在正常写入时编码为空字典，语义不变。结束前比较其他owner与原记录未变，停止应用后恢复原始仓库字节及归档目录状态，再启动普通首页。证据 .build/verification/message-actions-ui-checks.json，受限原始备份 .build/verification/message-actions-ui-original/；截图 .build/screenshots/assistant-message-memory-confirmation-en-iphone.png 和 assistant-message-actions-history-readonly-en-iphone.png。
- 以上隔离测试和本地夹具UI没有访问真实模型、购买、真实账号切换或通知授权/送达；不代表CiYuan2API联调、Apple/StoreKit、云同步/任务执行、紧凑侧栏完整点击或强制iPhone Duo专用验收已经完成。客户端整体目标仍在进行中，价格/600次套餐仍是提案。

## 11. 失败重试与非破坏重新生成（2026-10-30）

### 11.1 用户可见恢复流程

- 最新failed/cancelled助手消息提供独立44pt重试入口，包括首token前失败或立即停止的空回复。重试发送原用户问题和图片，保留当前尚未发送的草稿与附件；明确提示这是新请求及可能费用，不把重试变成发送当前输入框。
- 最新completed回复的“更多消息操作”提供重新生成。早期回复不提供该动作，底层也拒绝旧目标，不能截断其后的用户/助手历史。普通旧气泡内重生成图标在v2关闭。
- 重生成先追加candidate并保留原完成答复；失败或停止时两者均保留，只有成功后才删除同一原问题下被明确替换的旧completed。失败candidate持有可选replacesMessageId，跨进程读取后仍能继续重试；普通failed/cancelled部分内容保持原样。
- 历史详情以共享纯状态策略区分completed、failed、cancelled以及归档中的pending/streaming中断。空正文不声称已有部分输出；历史仍只读，不添加无实现的重试按钮。
- 新聊天默认禁用旧举报入口，避免从v2聊天默认调用旧APIService反馈端点；不声称其他旧页面的接口已全部迁移。

### 11.2 来源与确认边界

- AssistantGenerationActionSource包含kind、owner/conversation/目标ID及私有scope、消息修订、原用户正文/图片、配置epoch和完整指纹。确认前后变化、改后恢复、账号/会话往返或重复消费都会拒绝旧票据；点赞不改变内容修订。
- 配置指纹绑定完整BYOK URL路径/端口、协议、模型、Key及平台origin/区域/模型/语言/人格，票据仅留SHA256，不保存明文密钥。AppState人格/区域/模式、ModelPreferences选模、Home的BYOK/语言保存及清Key发按owner隔离的同步事件，使旧配置确认失效；普通Token刷新不触发该设置事件。
- BYOK待确认意图明确区分普通send与generation。普通send绑定原草稿/图片与修订，generation绑定原消息；再次确认重新验来源和完整目的地，取消或失效不发请求。不会借确认回调误发新输入框内容。
- 每次显式重试/重生成新建requestId，沿用原clientMessageId，保持单一用户问题；只有同时存在generationId和已确认的serverConversationId绑定时，平台才走服务端 `/generations/{generationId}/retry`，旧本地记录或缺少绑定时回退到会话消息接口。停止时按requestId调用 `/generations/by-request/{requestId}/cancel`，覆盖started事件尚未到达的竞态；真实账本与费用结算仍以服务端为准。
- 系统confirmationDialog实测只显示多个message Text中的第一项，初版遗漏lineage替换说明；已将条件说明合为单个本地化Text，最终构建实际可见“仅成功后替换”，且英文主按钮Regenerate已补译。

### 11.3 验证与收尾

- 统一Scripts/test-assistant.sh：**16套脚本、367个独立测试组，exit 0**。相对第10节新增30组：archive 16、data-export 22、chat-viewmodel 85；其他套件计数不变。日志 .build/verification/chat-recovery-all-client-checks.log，计数 .build/verification/chat-recovery-summary.json。
- 用真实生产状态机、隔离文件和注入传输验证：空失败/流中断、停止与三协议图片重试、新requestId、不重复用户问题、新草稿保留、早期目标拒绝、失败/停止保留原答复、重启lineage、配置11类变体、真实偏好保存事件及owner隔离、BYOK意图、平台服务器ID路由和迟到完成不删除已修改的前驱。不是对真实模型、付费、账号或网关联调的验收。
- 最终Simulator Debug构建成功：.build/verification/chat-recovery-final-build.log。72个生产Swift/strings/plist与构建副本一致，见 .build/verification/chat-recovery-build-source-match.json；双语plutil及git diff --check通过。没有正式签名/archive/TestFlight。
- iPhone17 Pro/iOS26.5本地夹具实际验证：空failed重试入口、原输入/费用说明、取消不改草稿/归档、缺失配置时显示预检错误且不新增generation；原完成答复与失败候选同时可见；最终lineage确认包含成功后才替换；最新completed菜单及Regenerate英文按钮；历史显示空pending/部分streaming中断、failed和cancelled且无重试。没有调用真实模型；网络成功/流取消等由注入传输测试覆盖。
- UI记录 .build/verification/chat-recovery-ui-checks.json；截图 .build/screenshots/assistant-empty-retry-preflight-en-iphone.png、assistant-retry-replacement-confirmation-en-iphone.png、assistant-history-generation-states-en-iphone.png。停止应用后恢复受限备份 .build/verification/chat-recovery-ui-original/ 的原始仓库字节和归档目录状态，再启动普通首页；未修改真实账号、API凭据、通知权限或购买。
- 发布门禁继续有效：CiYuan2API真实账号/额度/模型/订阅、Apple/StoreKit、真实网络与设备语音/通知、iPhone Duo专用验收仍未完成。此次本机devicetypes再次核对，没有Duo/fold专用类型；普通iPhone不能替代强制Duo验收。任务时区选择、重复任务和已过期提醒的恢复闭环也仍待开发，不能以367组检查代替这些功能。

## 12. 任务时区与过期提醒恢复（2026-10-30）

### 12.1 时区选择和旧数据兼容

- 新建/编辑任务可选择地区时区，复用带本地化名称、城市搜索和空结果说明的AssistantTimeZonePicker；安静时段继续使用同一组件的原默认标题与策略。任务表单以独立State保存选择，返回选择器不会重载草稿。
- 切换时区只改变显示，不重解释dueAt绝对时刻；DatePicker使用所选时区，保存使用已验证的原始标识，不以Foundation可能规范化的TimeZone.identifier覆盖UTC等选择。任务列表按记录时区显示，旧无效时区明确提示并仅以UTC显示到期时刻，不暗中修改数据。
- AssistantTaskTimeZonePolicy校验已支持的地区标识，默认新任务使用有效设备时区或UTC；旧无效标识保持原样并要求用户明确选择修复。新任务/实际修改时区严格校验，旧无效记录仍可读取、导出、删除和做不改时区的状态操作。
- 元数据编辑不强迫删改旧超长正文。表单保留未改标题/说明的原始内容，仅新建或正文实际变化才执行当前200/20000限制；过长旧内容有兼容说明。仓库CAS与普通更新使用相同规则。

### 12.2 明确恢复过期任务

- completed/paused/cancelled转active时，先按原dueAt及当前quiet策略推导真正fireAt；只有已开启提醒且fireAt已过才返回reactivationRequired，quiet延后仍在未来不会误判。不会将旧一次性提醒自动挪到明天。
- 选择“仅恢复待办并关闭旧提醒”：保持dueAt、时区、重复规则、内容、来源及requiresApproval，只改active、reminderEnabled=false和更新时间，不请求通知权限。
- 选择“修改提醒时间并恢复”：打开带说明的编辑器，用户明确保存才转active；可设置未来时间，或明确关闭旧提醒。取消不写任务，过期时间仍开启提醒时保存拒绝并保留表单。
- 所有任务编辑传expectedTask快照，状态操作也绑定实际旧快照。仓库updateTask(_:expecting:)在同一锁/原子写入内比较完整当前记录，冲突不覆盖、删除后不复活，磁盘失败保留旧值。通知候选已安排但CAS失败则走已有失败恢复。

### 12.3 并发与身份保护

- 通知的InFlightSchedule记录基础任务快照：编辑取previous，普通重排/失败恢复取实际计划源记录，新建nil表示原记录应不存在。在途豁免、同时间匹配快捷路径以及add成功/失败返回后均复验完整base、owner/session、quiet/version和操作UUID。
- 旧candidate已经写入系统而完成尚未返回时，任务被修改或删除会立即使豁免失效。普通重排及恢复add迟到后，只撤销自身UUID结果并按最新记录修复，不能把旧恢复快照重新排回；删除不重排。保持有效候选豁免，避免回归前期holdAfterStore问题。
- 私有修复预算最多两次额外pass；持续变动则撤掉旧请求并报告未完成，不无限递归。仍不承诺本地仓库和系统通知的跨资源事务，也不保证系统实际送达。
- TaskView显示及筛选绑定loadedOwner和真实Auth owner；每个异步操作有owner/UUID，成功、错误和defer回写均核验，刷新另检查run和仓库快照。身份变化清旧run与表单。通知深链不由旧账号页消费，也不打断尚在保存或已打开的任务表单。真实多账号UI切换尚未实测。

### 12.4 实际验证和剩余范围

- 统一Scripts/test-assistant.sh：**16套脚本、412个独立测试组，exit 0**；相对第11节新增45组，repository 46、reminder-coordinator 66，其余套件计数不变。记录 .build/verification/task-zone-reopen-summary.json，日志 .build/verification/task-zone-reopen-all-client-checks.log。
- 覆盖真实仓库CAS两线程竞争、保存失败回滚、无效旧时区修复、DST及非整点区域；真实coordinator+fake通知后端覆盖三个原状态、quiet延期、权限/设置/OS等待跨过期、快照变化、T1恢复悬挂后再改T2/删除、同时间变内容、新建absent、普通重排期间完成/删除、修复预算与新UUID保护。未访问真实通知权限或真实模型。
- 首次任务List表达式发生SwiftUI类型推断超时，拆为List/Section/editor辅助视图后解决。最终Simulator Debug编译成功，日志 .build/verification/task-zone-reopen-verified-build.log；72个生产Swift/strings/plist与构建副本一致，见 .build/verification/task-zone-reopen-build-source-match.json。双语plutil和git diff --check通过。
- iPhone17 Pro/iOS26.5实际本地夹具验证：修改标题后选择New York，返回仍保留草稿；保存后精确dueAt连秒不变。201字符旧标题在修复无效时区为UTC时完整保留，原说明/来源/审批字段不变，UTC没有改存GMT。时区说明和通知隐私说明均可见；两段footer已显式用VStack组织。
- 实际验证过期completed恢复选择与取消零写；“仅恢复待办”保存active并关闭提醒，保持原过期dueAt；paused经“修改提醒并恢复”页明确关闭旧提醒后保存为active，保存前原记录不变。重启后状态和时区仍在；没有通过UI修改日期/钟点、开启真实提醒或切换真实账号。未来日期/DST/等待竞态由纯策略与fake后端测试覆盖，不能替代系统送达。
- UI记录 .build/verification/task-zone-reopen-ui-checks.json；截图 .build/screenshots/assistant-task-zone-utc-en-iphone.png 与 assistant-expired-task-recovery-choice-en-iphone.png。比较原记录与偏好未变后，停止应用并恢复受限备份 .build/verification/task-zone-reopen-ui-original/ 的原始仓库字节与归档状态，再启动普通首页。测试未使用真实模型、账号操作或购买，未创建启用中的活动提醒。
- 第11节末尾的“任务时区/过期恢复待开发”是历史阶段记录，本节更新其本地实现状态；重复任务规则编辑/调度以及任务云同步/Worker/APNs仍未实现，Phase 21 只覆盖长期记忆同步。CiYuan2API、Apple/StoreKit、真实日期操作/语音/通知与强制iPhone Duo专用验收等发布门禁仍在，客户端完整目标尚未完成。

## 13. 每日与每周重复计划（2026-10-30，本地回归完成）

- 已实现规则、时分模板、星期选择、旧规则保留/替换、整计划完成确认、快照绑定的覆盖展示和读屏信息。
- 已实现原生每日/每周重复与安静时段 7 次滚动；生效下界、防重放、全组容量/回滚/迟到保护，以及仓库落盘前跨 origin 校验。
- 最终统一入口 Scripts/test-assistant.sh：16 套、478 个独立测试组、exit 0；仓库 85、安静时段 31、提醒策略 24、协调器 80、真实 ChatViewModel 隔离集成 89，原 66 个协调器场景均保留。统计只计 PASS 名称，不计数字汇总行。完整日志 .build/verification/recurrence-all-client-checks.log，分套结果 recurrence-summary.json；额外独立门禁不重复计入 478。
- 独立当前源码验证：7 项批处理硬断言通过；真实等待跨下一分钟后，save 以 recurrenceActivationElapsed 拒绝，仓库字节不变、新任务不存在、已添加 children 全清。最终材料 .build/verification/recurrence-independent-audit-v2/；4 个生产源与夹具哈希匹配，不使用真实通知中心。
- 最终 Simulator Debug 构建成功：.build/verification/recurrence-verified-build.log；完整日志 recurrence-xcode-build.log。72 个 Swift/strings/plist 与构建副本一致，见 recurrence-build-source-match.json 和 recurrence-source-sha256.json。新增的日期策略并发转换警告已消除；构建仍有 Xcode 无 AppIntents 依赖的元数据提取提示。
- 普通 iPhone 17 Pro / iOS 26.5 真实 UI：首轮验证 daily 时分/weekly 星期、空星期报错且原规则未写、MO/FR 有效保存、旧规则草稿往返保留/明确移除、整计划确认取消和完成；最终二进制复验旧规则参考日期说明、明确替换每日、读屏包含规则/时分/时区/提醒状态、重启恢复、新建每日及整计划完成。所有临时任务均关闭提醒，未发模型请求或通知授权；不能据此声称真实安排、有限覆盖文案或通知送达已经验收。
- 界面证据 recurrence-ui-checks.json；截图 .build/screenshots/assistant-recurrence-empty-week-rejected-en-iphone.png、assistant-recurring-daily-weekly-en-iphone.png、assistant-recurring-end-plan-en-iphone.png。验证无关记录保持后，5 个临时记录已移除，原任务/历史目录/偏好从受限 recurrence-ui-original 备份按原始字节恢复，重启后再核对原字节并实际确认普通首页无 QA 夹具。
- 真实通知授权/送达、后台无限补排、云同步/Worker/APNs、CiYuan2API/Apple/StoreKit 和强制 iPhone Duo 专用验收均未由本轮本地测试证明；完整客户端目标继续未完成。US$9.99 / 600 次仍只是商业提案。

## 14. 正式工程远程依赖构建（2026-10-30）

- 移除未被 Xcode 使用、版本/结构不一致的根 Package.resolved；保留 Xcode 实际共享锁 Caobao.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved，并用精确忽略例外让共享锁和 workspace 元数据可随代码提交。所有改动仍未 commit/push。
- 官方 Alamofire 5.12.2，revision bda9ed57d72988a3a2ada33d824583541f86eac6；checkout clean、版本标签和锁一致。包包含兼容工具链的版本化 manifest；不能只看主 manifest 而错误判断不兼容。
- 已实际完成原工程严格远程解析、原工程 Debug 模拟器构建、默认 Scripts/build-simulator.sh 严格锁构建；均 exit 0，没有本机路径替换。日志 remote-package-baseline.log、remote-client-baseline-build.log、remote-client-locked-script-build.log；元数据 remote-dependency-verification.json。均位于 .build/verification。
- 脚本默认使用独立 remote 缓存、onlyUsePackageVersionsFromResolvedFile 和 disableAutomaticPackageResolution；缺共享锁提前失败；成功后校验锁字节没有改变。本机覆盖仅在显式环境变量下使用副本，参数数组兼容系统 Bash 3.2。
- 独立临时夹具运行实际脚本、替换为假构建器的 5 项断言通过：默认参数、缺锁不调用构建器、本机覆盖不改原工程/锁、构建失败不假报成功、锁被改变即拒绝。材料 remote-build-script-audit；不重复计入 Swift 528 组。
- 首次环境可按相同共享锁显式运行解析命令，再运行默认构建脚本；不依赖 /tmp 本机包。正式签名归档、设备联调、TestFlight 仍未完成，不因无签名 Simulator 构建通过而宣称发布就绪。

## 15. 聊天 Markdown、代码与安全展示（2026-10-30）

- AssistantMarkdown 提供本地块解析：标题 1–6、段落、有序/无序列表、引用、反引号/波浪线代码围栏及语言标签。source 和 UTF-8 sourceRange 精确保留原文，按字节起始偏移生成稳定 block ID；关闭围栏的代码正文保留缩进/换行，未关闭围栏完整显示 source 并提供复制原文入口。
- 默认结构预算 256 KiB / 2000 块，硬上限 1 MiB / 10000 块；超预算尾部完整可见原文回退。Inline 原生解析上限 32 KiB，支持强调/行内代码/安全链接；图片语法或原始 HTML 标记保守显示原文。不是完整 CommonMark/GFM、表格/数学/语法高亮引擎；未支持语法不得丢弃原文。
- 链接属性仅允许 HTTP/HTTPS、非空 host 且无 user/password；危险/相对地址保留文字并剥除链接。用户点击时 OpenURL 再校验。该规则只控制用户激活的展示链接，不能当 BYOK/API 出站授权策略。代码仅作文本展示，复制不运行代码。
- MessageBubble 默认 allowsRemoteMedia=false：不自动从回复或代码中提取、删除或加载媒体 URL。旧媒体能力保留显式开关，当前所有调用点均未启用。用户文本改为完整 verbatim；显式本机图片附件不受影响。存档/导出的 content 未重写。
- 真实长消息测试发现内部 LazyVStack 与外层消息懒加载形成高度估算循环：滚动后进程持续 99.6% CPU，采样指向 LazySubviewPlacements / AttributeGraph。正文改为有界块的稳定 VStack；同一夹具滚动恢复响应、空闲 CPU 实测 0.0%。这是单个可复现用例的修复，不是全量性能基准。故障采样 markdown-ui-process-sample.txt 已保留。
- 外层消息滚动保留子元素；代码区域暴露完整无障碍值与横向动作，复制按钮独立可访问。实际普通 iPhone 17 Pro / iOS 26.5 验证标题、强调、行内代码、列表、引用、用户原文、URL 保留、图片语法字面量及安全/不支持链接的视觉区别；10 次系统横向分页到同一长代码行右端，气泡未撑宽，完整读屏值保持。未闭合取消回复保留围栏/缩进/URL、Copy original 和 Stopped 状态，不伪装仍生成。
- 最终统一 18 套 / 528 个独立组 exit 0，包括新增 block 25、inline 25；日志 markdown-all-client-checks.log，统计 markdown-summary.json。实际剪贴板复制/朗读、外部链接打开、网络抓包、现场 VoiceOver 朗读、真实模型流及大规模历史性能本轮未验证。
- 最终原工程严格远程构建 exit 0：markdown-final-remote-build.log；完整日志 markdown-xcode-build.log。111 个源码/资源/工程/锁/脚本输入保持一致，74 个 Swift/strings/plist 文件；UI 验证的 Caobao.debug.dylib 与最终构建 SHA256 相同，见 markdown-build-source-match.json。
- UI 证据 markdown-ui-checks.json；截图 assistant-markdown-prose-en-iphone.png、assistant-markdown-code-links-en-iphone.png、assistant-markdown-code-right-edge-en-iphone.png、assistant-markdown-unclosed-en-iphone.png 位于 .build/screenshots。三份临时会话已清理，原始任务/记忆、会话/草稿和偏好从受限 markdown-ui-original 备份按字节恢复，重新启动后复核原字节并确认正常首页无 QA 夹具。
- 后续客户端优先项：全历史续聊的草稿/生成保护、单条记忆授权显示与操作一致性、归档分页及后台 I/O。现有真实服务端/Apple/StoreKit、通知、完整无障碍/动态字体和强制 iPhone Duo 等门禁继续未完成；客户端完整目标保持进行中。

## 16. 单条记忆授权、陈旧编辑与实际请求启动（2026-10-30）

### 16.1 授权和持久化

- AssistantMemoryAuthorizationPolicy 统一解释单条 consent：去除首尾空白并忽略大小写后，explicit/confirmed 表示允许，revoked/disabled 表示停用，其他原值（含 NA）均为尚未确认；deleted 始终排除。全局、类别和单条授权是独立条件，不相互代替。
- 新记录允许使用时保存 explicit，否则保存 unconfirmed；旧记录从不允许变为允许时保存 confirmed，从允许变为停用时保存 revoked；授权效果未改变则完整保留旧 consent 字符串，普通修改不将未知状态正规化为授权。
- 页面显示已保存授权、当前可选状态、来源和创建/更新时间；编辑器的草稿开关与已保存状态分开展示。空白正文即使旧 consent 为允许也显示不会附加。列表仅四行预览、按更新时间倒序，编辑与持久化仍保留全文，不截断超长旧数据。
- updateMemory(_:expecting:) / deleteMemory(_:) 在仓库锁内匹配 owner、id、active 和完整旧快照；不插入、不复活墓碑。更新保留已存 createdAt/sourceMessageId，新增使用 insertMemory。仅实际正文 UTF-8 改变才应用新输入校验；旧超长可只改授权/分类，旧空白可撤权但不能直接获新授权。
- 页面和编辑器校验实际 Auth owner、页面代次及编辑目标 UUID，登录/退出清空旧编辑状态；读取失败保留原始数据且展示重试，不伪装空仓库。无修改的保存只关闭编辑器，不改更新时间。删除动作绑定确认快照和页面代次，不依赖对话框关闭后的 presentation Binding。
- 聊天来源保存只接受 exact explicit/unconfirmed，仍校验来源票据、owner、原文和状态；成功才消费票据。新增未授权记忆保留管理能力，但不进入实际个人上下文。

### 16.2 实际网络启动边界

- 准备请求保留原始查询与已选择个人上下文的 SHA256 签名；身份刷新、平台会话创建等待后重新检查。最终 beforeStart 在同步 MainActor 启动段复验 run、实际身份/活动 owner、会话/scope、完整配置 fingerprint/epoch 和上下文签名，再创建 dataTask 并 resume；中间没有 await。
- 传输改为每请求串行 URLSession delegate，保留增量 SSE、UTF-8、CRLF、大小预算、终止/非空验证与工具调用拒绝。排队取消、预取消或检查抛错均不启动请求；不缓存 cookie/凭据，拒绝重定向。完成先锁内标记并摘取资源，再锁外取消/结束 continuation，避免 onTermination 重入死锁。
- 已经发送的内容无法撤回。撤权只阻止后续将该条作为长期记忆附加；会话历史可能含相同内容，界面明确提示可删除相关会话或新建会话。不把已发请求描述为未发送，不自动删改上下文后偷偷重试。

### 16.3 验证与边界

- 最终全量 18 套 / 566 个独立组 exit 0：repository 101、protocol 29、chat-viewmodel 99，其余保持回归覆盖。真实传输启动排队测试使用 URLProtocol 拦截，覆盖撤权/删除、全局/分类关闭、账号切换、配置及其代次变化；不访问真实模型或凭据。
- 首次全量遇到历史导出夹具试图用 active-only API 插入 deleted 状态，已改为明确的临时磁盘残留墓碑夹具。导出 22 组通过，额外断言原盘确有残留、结果清除正文/来源、导出前后原文件字节不变；没有削弱生产墓碑保护。首次失败日志保留 memory-authorization-full-regression-fixture-failure.log。
- 实际普通 iPhone 17 Pro / iOS 26.5：未知授权编辑器默认关闭；草稿开关开启后取消保留完整原记录；普通分类修改保留 raw NA、正文、来源与创建时间；明确授权写 confirmed、撤销写 revoked；全局/偏好类别关闭再开启不重新授权；空白与 20,027 字符旧正文可不改正文撤权；真实删除确认生成清空正文/来源的墓碑；冷重启保留仓库字节并正常展示撤权、隐藏删除项。四行预览已视觉检查。
- 本轮未把远程文本 setter 的显示变化当作成功输入；未完成通过新增工具栏按钮创建未授权记忆的完整实际 UI 流程。新增未授权/来源票据/陈旧写入由隔离测试覆盖，不扩大为所有输入方式、现场 VoiceOver、动态字体、真机或 iPhone Duo 验收。
- 最终严格官方远程 Simulator 构建 exit 0，完整日志 memory-authorization-final-build.log；最终 115 个源码/资源/工程/锁/脚本及测试文件快照 memory-authorization-final-source.json。已安装 Caobao.debug.dylib 与构建相同，记录 memory-authorization-final-binary.json。
- UI 检查 memory-authorization-ui-checks.json，截图 memory-authorization-final-preview-iphone.png。原数据/偏好由受限 memory-authorization-ui-original 备份按字节恢复；重启正常首页、再次核对原字节且无 QA16 记录，记录 memory-authorization-restoration.json。本轮未调用真实模型、真实登录/购买或通知授权，不修改原后端或 CiYuan2API。
- 下一客户端优先项仍为全历史续聊的草稿/生成保护、归档分页和后台 I/O；真实服务端、Apple/StoreKit、通知、正式发布与强制 iPhone Duo 发布门禁未完成，完整目标继续进行中。

## 17. 安全全历史续聊、多会话草稿与持久删除保护（2026-10-30）

- 全历史详情可继续任意当前 owner 会话，不受首页最近 3 条/侧栏最近 10 条限制。准备和确认绑定源会话、owner/scope、草稿及生成代次，目标按 ID 重新读取；当前同一会话不打断流或草稿。图片处理中、API 发送确认未处理时拒绝切换。
- 统一确认展示冻结实际 ticket；系统关闭不在按钮 action 前清掉它，迟到关闭只拒绝同 ID，不影响替换票据。成功事件使分栏同 tab/同 ID 也进入实时聊天；不在初始化/身份激活时抢导航。快捷操作为独立新稿预填，不覆盖源输入、不自动发送。
- .json.draft 增加版本化账号 envelope、活动指针和多个草稿；selectDraft 同锁一次原子保存源、验证最终目标并切活动。旧无关联稿单独保留，读取不改盘。完整本机备份 schemaVersion=1 新增 conversationDrafts（inactive，原 draft 仍表示 active），图片省略计数及编码预算包括全部草稿。
- 审查发现删除 messages 后清稿失败仅靠内存 blocked 会在重启时恢复旧稿，已扩展持久 deletedConversationIds；删除先落保护并清关联稿，再写过滤的历史。全量清理用 isPurgingAll 保护中间态，成功仍删除账号两文件。保护写失败不伪装已删；后续阶段失败冷启亦隐藏旧内容、阻止重新写入，需明确重试物理清理。恢复新建确认按标记选择重试单条或全量清理，不能在准备票据阶段因旧保护拦死恢复入口。
- login/logout 通知到达时同步停止旧底层 producer、图片任务并失效来源/确认票据，覆盖同一 MainActor 回合退出再回原 owner；不依赖迟到 activateOwner 才发现账号改变。仅真实中断 run 的 partial 需要安全落盘，跨 owner 不写旧稿；普通 token 刷新及额度/订阅更新不发送这两身份通知，不被当换身份取消。
- 最终统一 18 套 / 622 个独立组 exit 0：Archive 38、DataExport 31、ChatViewModel 124，其余完整回归；旧 99 个 VM 组保留，新增 25 组。覆盖源/目标/其他草稿、draft-only、默认取消、写失败/部分保存、生成与 owner/scope ABA、真实 URLProtocol producer 取消、删除冷启动与启动前持久保护。日志 history-continuation-full-regression.log，计数 history-continuation-regression-summary.json；独立分套和 UI 检查不重复计数。
- 首轮统一在 networkConnectionLost 夹具失败，记录 history-continuation-full-regression-protocol-failure.log。独立 Foundation 对照证实夹具立即 didFail 时 URLSession 尚未交付 data callback；并非 transport 丢失已收到的增量。仅测试改为消费者实际收到 partial 后再释放原生 -1005，仍严格要求仅 partial、原错误码、无 completed，并确认一次真实故障注入；无 sleep、重试或放宽断言。生产 AssistantProtocol 未改，诊断与修正日志 caobao-urlsession-error-delivery-20261030.log、caobao-protocol-network-ack-fix-20261030.log 均已归档。
- 最终原工程严格官方远程 SDK 构建 exit 0，日志 history-continuation-final-build.log；148 个源码/资源/工程/锁/脚本及测试文件快照 history-continuation-final-source.json。构建后仅上述测试夹具调整，生产构建输入未变；构建前快照另存 history-continuation-build-source-before-protocol-fixture-fix.json。已安装 Caobao.debug.dylib 与最终构建 SHA256 相同，见 history-continuation-final-binary.json。
- 早期普通 iPhone 17 Pro / iOS 26.5 实测：第 16 个历史（在最近 10 条外）打开详情并继续，系统取消不改 archive/draft 字节；确认后目标稿恢复，源文字/人工小 JPEG/第三稿不丢；新建与快捷预填不发送消息，未发送稿有历史入口；冷启动恢复源文字/图片；实际只读夹具目录导致保存失败时保持原页/输入与文件字节，恢复可写后重试成功。检查 history-continuation-ui-checks.json，保留 earlyUI 标识及早期构建范围，不混作持久删除修正后的二进制证明。
- 最终二进制再次验证：无消息草稿冷启动后可从历史继续且不发送；同一当前会话不出现切换确认；当前第 11 个历史（最近 10 条外）详情继续、系统取消精确保留文件字节，确认恢复独立目标稿且源/其他稿与 32 条历史消息不变。另播种有效全量清理中断夹具（raw 仍含 32 条旧消息）：冷启动旧内容不可见；快捷操作显示专用恢复确认；取消保留 raw/保护字节；明确确认后物理移除旧 archive，仅创建用户明确的新预填，不恢复任何旧稿。该夹具不是实际崩溃/系统故障注入，实际写入各阶段失败由隔离测试覆盖。
- 新增备份范围说明在最终普通 iPhone 英文界面可见，明确包括其他会话未发送稿；没有在本轮准备或保存真实用户备份。分栏成功事件代码与 SDK 验证已通过，本轮实际 UI 仅普通 iPhone，不扩大为新分栏/iPad 侧栏、VoiceOver/Dynamic Type、真实上游或强制 iPhone Duo 姿态验收。
- 原数据/偏好从受限 history-continuation-ui-original 备份按字节恢复；冷启动正常首页、进入并返回静态隐私页后，再次核对原字节及文件集合，确认无 QA17 夹具或额外 app-data 文件。记录 history-continuation-restoration.json；截图 history-continuation-final-purge-recovered-iphone.png 与 history-continuation-restored-home-iphone.png 位于 .build/screenshots。本轮未使用真实模型、登录、购买或通知权限，也未修改原后端/CiYuan2API。
- Phase 17 验收时归档仍为全量 JSON、同步读取和写入；该历史基线不把对数组取 prefix 当分页，也不证明已达到大规模历史延迟要求。
- Phase 17 之后已进入第 18 节的 SQLite 分页、后台 I/O 与操作门改造；该阶段的源码、统一测试和最终二进制须独立核验，不能沿用本节验收结论。第 4 节发布门禁继续保留。

## 18. Phase 18：SQLite 分页、后台 I/O 与操作门（本地验证记录，2026-10-30）

### 18.1 当前改造范围

- 归档改用系统 SQLite，拆分会话元数据、完整消息正文、草稿和删除保护。历史通过数据库查询返回 `AssistantConversationSummary`，按游标加载后续页；搜索查询当前 owner 的数据库，不只筛选已加载数组。游标绑定 owner、规范化 query 与 generation；正文仅在明确按 ID 读取时完整解码，不用摘要或局部页构造完整会话写回。
- 显式准备、旧 JSON/多会话草稿迁移、校验、发布和归档读写移到串行 worker。迁移失败保留原始材料；已有权威存储不可用时拒绝普通覆盖或回退旧内容。主线程请求启动快检使用短锁授权快照，不能重新同步等待大型 SQL、迁移或导出任务。
- 冷启动存在 durable purge 意图时，必须先后台 prepare 并发布该意图，再开放恢复入口；不能让前置 `isPurgingAll` 短路把授权缓存留在 unknown，导致旧内容虽然被隐藏但明确恢复不可达。pending purge 的导出在读取前、SQL 内及读取后均拒绝，不以成功的空备份掩盖未完成清理。
- VM 和 UI 的历史读取、打开/新建、删除/全清、导出接入异步操作与 owner/scope/run/epoch 守卫。操作门覆盖独占切换和快照提交；提交前失效拒绝操作，已提交后取消或账号变化只抑制过期发布，不宣称数据库已经回滚。
- 导出由 VM 在同一操作门和 SQLite 事务内保存当前会话/草稿并读取完整 owner-bound 归档快照，再由后台编码器消费该不可变快照。记忆/任务仓库仍有自己的读取边界，不承诺跨仓库全局事务；备份文件范围和保存成功判定沿用现有规则。
- 历史 UI 接入首屏/后续页、数据库搜索、游标失效后的明确重载和异步详情。显式删除开始即失效首屏完成缓存，防止删除已提交但界面任务取消后，重进仍沿用旧列表；不按最近 10 条或当前页 ID 裁剪合法详情路由。
- 代码复制使用源身份和 exact UTF-8 内容复验：历史详情按 ID 重新读取，实时聊天验证当前消息、会话 scope 与视图代次；最后同步写入剪贴板。复制回调成功后才显示成功状态，不从过期 renderer 快照先行复制。
- 创建服务器会话也接入 `beforeStartWait` 与最终同步 `beforeStart`；标题可能包含用户输入，等待期间不应先启动创建 HTTP。每请求串行委托保留响应大小、格式、服务器 ID 与重定向限制；钩子原始授权错误不改写为通用网络错误。

### 18.2 统一回归与正式构建

| 项目 | 当前记录 |
|---|---|
| 历史完整验收基线 | Phase 17：18 套 / 622 组；仅对应第 17 节源码和二进制 |
| Phase 18 最终统一回归 | 19 套 / 694 组 exit 0；摘要 `.build/verification/phase18-final-regression-summary.json`，完整日志 `phase18-final-full-regression.log` |
| 关键组数 | Database 35、Archive 38、ChatViewModel 143、DataExport 35、Protocol 33、Conversation 20、Markdown 29；其余分项及总数见上述摘要，不重复累计 |
| 回归源码记录 | `.build/verification/phase18-final-source.json` 共 152 项；摘要记录 sourceUnchanged=true |
| 正式 SDK 构建 | 官方远程 SDK 构建 exit 0；日志 `.build/verification/phase18-final-sdk-build.log`、`phase18-final-sdk-summary.log`，132 项非 Tests 生产输入记录于 `phase18-final-sdk-input-source.json` |
| 已安装二进制 | `.build/verification/phase18-final-binary.json` 记录已安装二进制与正式构建一致 |
| 最终搜索/继续与原数据恢复 | 已完成限定范围复验；证据 `phase18-ui-checks.json`、`phase18-restoration.json`，详细范围见下节 |

### 18.3 冷启动清理与原生界面范围

- VM 143 组中的新增冷启动场景使用全新 namespace，复制实际含 260 条旧消息的数据；初始缓存为 unknown / purging=false。后台 bootstrap 隐藏旧数据并发布恢复状态，新建可达专用确认；取消保持字节不变，明确确认后只保留新稿，生成 HTTP 为零。此处的破坏性确认是隔离测试，不是真实账号或最终原生 UI 的破坏操作。
- 最终正式二进制在普通 iPhone 17 Pro / iOS 26.5 上重新验证：130 个会话、260 条消息、3 份草稿迁移；原生实际观察 50 / 50 / 30 分页，共 130 个唯一 ID、无遗漏。
- 最终正式二进制的真实 cold pending marker 场景中，旧 260 条消息仍在源数据，界面隐藏旧内容；重试已经可达确认。原生只执行取消，并核对全部 archive / authority 字节不变；**没有执行最终原生破坏性确认**。
- 早期完整 UI 覆盖首屏外搜索、继续的取消/接受、冷启动与游标失效，范围记录于 `.build/verification/phase18-ui-checks-before-cold-purge-fix.json`。该记录属于 cold-purge 修复前的早期二进制，不冒充最终正式二进制 UI 证据。
- 最终正式二进制再次冷启动，仅加载首屏后搜索 `nebula-003`，唯一命中未加载的第 003 个会话；完整用户/助手正文和代码块可见。续聊取消返回同一详情且全部 archive/authority 字节不变；明确确认恢复目标草稿，源第 130 个会话及其他第 120 个会话草稿保留，260 条历史消息不变；再次冷启动进入聊天，目标完整正文与草稿恢复，没有自动发送。证据 `.build/verification/phase18-ui-checks.json`；截图 `.build/screenshots/phase18-final-history003-continued.png`。
- 原数据与偏好从权限 0700 的 `phase18-ui-original` 备份按字节恢复；启动前原文件集合精确一致，启动后两份原文件字节仍一致、正常首页可见、无 QA18 内容。新引擎正常冷启额外创建空 SQLite/authority 两文件，headers/bodies/drafts/deleted 全为零；这不是夹具残留，不能把新引擎合法初始化误判成恢复失败。证据 `.build/verification/phase18-restoration.json`；截图 `.build/screenshots/phase18-final-restored-home.png`。
- 代码复制的真实剪贴板及现场无障碍交互不因解析/授权测试自动视为通过；本轮没有操作真实剪贴板、登录、购买、模型或通知权限。早期游标失效/重载仅保留早期二进制范围，不扩展为最终原生用例。

### 18.4 已知跟进与发布边界

- Home 的 preparationError 路径仍可能显示 Foundation 存储 enum 的原始文字；VM `loadFromLocal` 已映射本地化错误，不代表所有 UI 错误出口已统一修复。
- 本轮统一隔离测试、SDK 与普通模拟器记录不能证明真实服务端、Apple/StoreKit、真实模型、通知安排/送达、实机性能、签名/TestFlight 或强制 iPhone Duo 专用适配已完成。商业价格、人民币档位、600 次/月与每日赠送叠加仍保留原拟定状态。


## 19. Phase 19：本机待办工具与账号边界（本地验证记录，2026-10-30）

### 19.1 已实现范围与边界

- 已接入经能力验证、明确启用的 BYOK 三协议单个 create_task 提案、当前来源审批票据、真实任务/回执原子提交、可选提醒及一次持久声明的专用继续；具体参数、状态与协议见 ASSISTANT_TASK_TOOLS.md。平台 v2 工具仍关闭，不修改原后端或 CiYuan2API，不新增已部署的 HTTP 工具执行承诺。
- 提醒默认关闭且模型请求仅为建议；明确开启还必须有到期时间。任务先真实保存，再更新该任务安排提醒；失败不重复创建。界面显示创建时历史回执，不能由旧 scheduled 状态推断当前仍开启或已经送达。
- 未完成/失败来源只读；来源用户已删或配置改变时不能执行旧建议，但完整提案可明确本地拒绝，避免未决建议阻塞后续普通聊天。包含提案的消息隐藏普通创建待办入口，并在旧菜单/编辑器最终提交再次复验；明确的记忆、复制等动作保留。
- 专用继续由仓库 CAS 声明 continuationAttemptId，删除聊天标记或重启不能重开该次尝试；声明后失败不证明 HTTP 已发送，也不会自动重试或再次执行任务。
- 存储错误呈现、严格时间解析、回执防重放与 Unix 日期持久表示已修复。原始 UTF-8 账号边界覆盖已授权存储与核心 UI 缓存/异步许可；UI 生命周期使用可逆 Base64 owner key，旧 owner 表单和文档不可重新绑定给规范等价但字节不同的账号，不迁移持久 ID。该代码和隔离检查不等于系统 Keychain Unicode 行为或已交给 OS 的动作已全验收。

### 19.2 统一回归与正式构建

| 项目 | 实际证据与范围 |
|---|---|
| 历史完整基线 | Phase 18 的 19 套 / 694 组与第 18 节限定的构建、普通模拟器记录，保留原范围 |
| Phase 19 统一隔离测试 | **23 套 / 850 个独立测试组，exit 0**；`.build/verification/phase19-final-regression-summary.json` 与 `phase19-final-full-regression.log` |
| 工具关键分项 | 协议聚合 42、能力探针 21、真实本机执行/回执 42、工具导出 13；均已包含在 850 内 |
| 其他关键分项 | ChatViewModel 167、ReminderCoordinator 88、Identity 15、Database 38、Archive 38；其余分项见统一摘要 |
| 首份源码与输入记录 | 两份 166 项清单：`phase19-source-before-home-compiler-fix.json`、`phase19-final-source.json`；当时 CLI 启动后只改 HomeView，`cliInputsUnchanged=true` |
| Home 拆分后 SDK 重试 | 官方远程 iOS Simulator SDK 实际 exit 0，**BUILD SUCCEEDED**；`phase19-final-sdk-build.log`、`phase19-final-sdk-summary.log` |
| 日期修正后最新输入 | `phase19-post-native-source.json` 166 项；与上一清单只差 ProposalView，CLI 输入仍未改变 |
| 日期修正后 SDK / 安装 | `phase19-post-native-sdk-build.log`、`phase19-post-native-sdk-summary.log` 实际 exit 0 / BUILD SUCCEEDED；`phase19-post-native-installed-build.json` 确认源码与已安装二进制匹配 |
| 原生 QA19 | 拒绝/持久化、最终 failed/history 只读与日期显示限定子集已验证；`phase19-native-ui-checks.json` 明确其余未测路径，完整客户端目标未完成 |

上述 `phase19-*` 文件均位于 `.build/verification/`。已核对 23 个分项总和为 850，完整回归日志 SHA256 与摘要一致；定向测试不在统一总数外重复累计。

首轮 SDK 曾因 HomeView 的大 SwiftUI 表达式类型检查超时而失败，历史摘要为 `phase19-sdk-home-typecheck-failure-summary.log`。之后仅进行 Home 设置页的 UI-only 子表达式拆分，原 State、来源守卫、Probe、取消与费用确认保留，没有 AnyView 或根 id 重建。前后清单实际只差 HomeView；最终 Home SHA256 为 `7716bfae8f5479fbe628613bf900f56b85768ce151bcd772ba7248281c86f099`。该文件不属于 CLI 编译输入，因此本次 SDK 修复没有改变已通过的 CLI 输入；最终 SDK 成功另行验证该 UI 源码，而不是把最初 SDK 失败误报为 CLI 失败。

### 19.3 原生 QA19：日期修正与限定验证

- 使用独立普通 iPhone QA19 模拟器，不以原用户设备的数据做新功能夹具。首个成功构建的二进制实际 UI 拒绝 local-device 提案，真实仓库为 tasks={}、一个 revision=1 / declined / notRequested 回执；重启后拒绝卡与原未发送草稿保留，仓库字节不变。证据：`phase19-native-local-after-decline.json`、`phase19-native-decline-before.png`、`phase19-native-decline-after.png`。这不是原生创建任务或安排提醒通过。
- 首个二进制的 failed/history 截图保留为早期范围；最终日期修正后二进制已再次观察 failed-source 为 Result unconfirmed，明确未完成来源只读且无复核/拒绝/继续按钮；历史列表 5 条进入 body-memory 详情后，正文和 Copy 入口保留，仅有进入当前会话复核的路由，无创建执行按钮，两处时间均为 3:04 AM + UTC。最终证据 `phase19-native-final-failed-source.png`、`phase19-native-final-history-readonly.png` 与 `phase19-native-ui-checks.json`；未执行复制或由该路由批准任务。
- 原生发现提案夹具的 due_at=2030-01-02T03:04:05Z、time_zone=UTC，却被 Text 日期环境显示为 11:04 AM + UTC。仅修改 ProposalView，使用环境 locale 和指定时区预格式化 String，再 Text(verbatim:)；Date、状态与授权守卫不变。最新 UI 源码 SHA256 为 `8e5d6821aad992c2fc74b12b265276852ba2b230e7a23378b87369c6b042fae0`，具体单文件差异与 CLI 输入未变见 `phase19-native-timezone-ui-fix.json` 和 `phase19-post-native-source.json`。
- 追加官方 SDK 构建与 QA19 重装均实际成功；已装二进制哈希与构建匹配，166 项输入全部匹配，见 `phase19-post-native-installed-build.json`。最终 AX 已实际确认 qa19-decline 为 Jan 2, 2030 at 3:04 AM + UTC、Declined，原未发送草稿仍在且无复核/拒绝/继续按钮；`phase19-native-timezone-corrected.png` 与日期修正记录的 nativeRecheckPassed=true 为证据。未据此推断已消耗或发送一次继续。
- 独立 SQLite mode=ro 检查报告完整性正常、迁移完成、5 会话和 10 条唯一消息、所有提案来源/摘要有效；5 份草稿含 39 字符拒绝草稿。当前任务和记忆均为零，只有一个 revision=1 / declined / notRequested 回执，无 taskId 或 continuationAttemptId，仓库字节与拒绝后副本一致。汇总 `phase19-native-ui-checks.json` 的 fullClientGoalComplete=false；QA 仍保留合成夹具，不假报清场或用户数据恢复。重装后 dataContainer 正常变更，stage 记录保留 initialDataContainer。
- **原生未测**：设置下部的费用确认、无副作用能力验证/工具启用保存、批准提案、编辑保存、专用继续确认和取消，以及具备有效当前 Key/证明时的陈旧配置审批保护。当前 relay 滚动/触摸拖动不稳定，QA19 Keychain 未写测试 Key、未播种工具能力证明；不强行绕开能力门禁，也不将隔离 42/167/21 组当作这些原生路径已通过。
- 没有真实模型/平台网络、真实身份、IAP 或通知授权/送达操作；剪贴板、系统交付及完整任务创建的原生验证仍未完成。最终 failed/history 与时区复验只完成上述限定子集，不是整体客户端完成。

真实服务端、真实 BYOK 模型、Apple/StoreKit、系统通知、实机性能、签名/TestFlight 与强制 iPhone Duo 专用设备/姿态仍是独立发布门禁；普通 QA19 iPhone 不能替代 Duo。所有既有价格、人民币档位和额度拟定状态保持不变。

## 20. Phase 20：本地备份预览与安全恢复（2026-10-30）

### 20.1 已实现的客户端范围

- “数据与隐私”接入 JSON 文件选择、后台有界读取、预览及独立明确确认；导入与导出互斥，禁止生成、图片、工具或其他归档操作进行时启动恢复。默认最大 32 MiB，只读句柄以 O_NOFOLLOW/O_NONBLOCK 打开，并对同一 FD 做 fstat 常规文件校验，不依赖可被替换的路径元数据。
- 仅接受兼容本地 schemaVersion=1 文件，原始 UTF-8 owner 必须相同；不自动认领、不跨账号迁移。local-device/“此设备”和 SHA-256 摘要不构成来源或身份认证。备份明文且保留用户正文，凭据、模型配置和系统许可不恢复。
- 仅新增并保留本地冲突、会话删除保护与现有偏好。真实当前会话/草稿先受事务保护，恢复后不自动激活会话或覆盖输入。只有草稿的新会话可生成确定性空会话入口；无内容的孤立空稿忽略。
- 工具提案验证后转为明确只读的普通文字，处理回执不回放；消息旧请求/生成/替换与服务器会话标识移除，pending/streaming 转 failed。新增记忆 unconfirmed；新增任务 reminderEnabled=false、requiresApproval=true，不创建通知或执行工具。
- SQLite 会话/草稿及摘要标记，与工作区记忆/任务及摘要标记分别原子提交，**不承诺跨存储全回滚**。第二阶段失败保留第一阶段，同一不可变计划可在再次明确确认后重试；每原始 owner 的工作区最多记录 256 个不同备份摘要，永久错误需先处理原因。
- 文件选择与审批回调分别绑定 owner、run、epoch/摘要；登录/退出通知同步使旧范围失效，旧 owner 的计划不重新绑定。取消在提交开始前可阻止提交，已开始/已完成的提交不能宣称被撤销，过期结果不发布。详细接口与限制见 `ASSISTANT_DATA_RESTORE.md`；这是客户端本地能力，没有新增 HTTP 端点。

### 20.2 验证时间线与最终构建

| 阶段 | 实际记录 |
|---|---|
| 加固前统一回归 | **27 套 / 941 个独立组，exit 0**；`phase20-pre-file-hardening-full-regression.log`、`phase20-pre-file-hardening-regression-summary.json` |
| 已通过的恢复分项 | Importer 29、SQLite restore 19、repository restore 28、restore VM 15；既有 Archive 38、Repository 101；定向组不在 941 外重复累计 |
| 加固前正式 SDK | 实际 exit 0 / BUILD SUCCEEDED；`phase20-pre-file-hardening-sdk-build.log`、`phase20-pre-file-hardening-sdk-summary.log`；仅属于加固前生产输入 |
| FD 加固后的定向检查 | 新增 backup-file-reader 6 组、Importer 29 组重跑通过；`phase20-backup-file-reader-regression.log`、`phase20-importer-after-fd-regression.log` |
| 输入来源 | `phase20-file-hardening-provenance.json` 记录 177 → 179 项、Importer/统一入口变化及两个测试文件新增；最终清单 `phase20-final-source.json` |
| 最终统一回归 | **28 套 / 947 个独立组，exit 0**；`phase20-final-regression-summary.json`、`phase20-final-full-regression.log`；FD 6 组已在总数内 |
| 最终正式 SDK | 实际 exit 0 / BUILD SUCCEEDED；`phase20-final-sdk-build.log`、`phase20-final-sdk-summary.log` |
| 最终安装对应 | `phase20-installed-build.json`：179 项输入匹配、已装二进制与构建哈希相同；不由此推断最终原生交互已通过 |

上述证据位于 `.build/verification/`。已核对 28 个分项总和 947、完整日志 SHA-256 与摘要一致、179 项输入匹配。命令行检查使用实际生产组件、临时存储或测试身份/网络壳；没有真实模型/平台请求、购买或 OS 通知集成。语法与两语言资源检查通过，各 841 个键、无重复；不替代原生验收。

### 20.3 原生范围与发布门禁

- FD 加固前普通 iPhone QA19（`725D4AF8-599C-4E04-B254-4A9E7D2C2C44`）使用合成 5 会话、0 记忆/任务，实际导出到 On My iPhone，再从系统文件选择器选择约 12 KB JSON；预览实际为 5 会话、5 草稿、5 个只读文字提案、1 个忽略回执，见 `phase20-native-import-preview.png`。
- 早期二进制先实际打开确认并取消，业务源数据字节一致、两个恢复标记为零；随后实际确认首次合并，界面各类新增 0、冲突 5。磁盘为 5 会话、0 任务/记忆、1 个既有回执；两个存储各保存同一摘要的一个标记，移除新增摘要元数据后的工作区内容与基线完全一致。`phase20-native-after-first-merge.json`、`phase20-native-first-merge-result.png` 证明冲突保留与提交，**不证明原生新增记录导入**。
- 早期安装记录保留为 `phase20-pre-file-hardening-installed-build.json`；首次合并属于加固前二进制。最终 179 项匹配的 FD 二进制重装后，实际从系统 Recents 再选同一约 12 KB 文件，预览仍为 5/5/5/1，再明确确认合并。AX 实际显示已处理、不会重复导入，各类新增 0、冲突 0。
- 最终磁盘工作区与首次合并后逐字节一致，两个存储仍各有同摘要的一个标记；5 会话/5 草稿，活动槽 c:qa19-failed-source，0 任务/记忆、1 个既有回执，SQLite integrity=ok。`phase20-native-ui-checks.json` 与 `phase20-native-final-repeat-result.png` 证明最终 FD 读取及重装后的持久幂等，`phase20-installed-build.json` 确认最终输入/二进制匹配；**不证明原生新增记录导入或故障/身份链路**。预览中的 5 个中和提案不是本轮已新增历史的证明。
- 原生向空目的地新增、畸形/无效文件、工作区 I/O 故障/部分重试、账号切换、完整草稿保护，以及 Phase 19 未完成的有效 Key/能力验证、任务批准和专用继续仍需独立验证；真实组件 CLI 覆盖不替代这些原生操作。没有写入测试 API Key 或能力证明，没有模型/探针/通知操作、真实 Apple 登录、IAP 或通知授权/送达。
- 完整恢复功能和完整客户端目标均不声明已验收完成。真实服务端/CiYuan2API/真实 BYOK、Apple/StoreKit、系统交付、实机性能、签名/TestFlight及**强制 iPhone Duo 指定设备/姿态**继续保留为独立门禁，普通 QA19 不能豁免 Duo。商业价格、人民币档位与额度规则仍保持既有拟定状态。

## 21. Phase 21：账号隔离的记忆云同步（2026-10-30）

### 21.1 已实现的客户端闭环

- `AssistantCloudMemorySyncClient` 使用 `/api/v2` Bearer 鉴权、owner 派生的本地游标状态、分页 `/sync/changes`、服务端 `version/seq/status/updatedAt` 和删除墓碑；只接受 HTTPS、禁止重定向、限制响应体大小，不把 token 写入日志或持久化。
- 登录账号进入首页或 macOS 容器时先拉取服务端记忆，回到前台和下拉刷新也会触发拉取；记忆编辑/删除成功后发出 owner-scoped 变更通知，上行使用 `expectedVersion`，再拉取服务端版本。服务端较新的变更不会复活本地墓碑；409 冲突保留本地数据并显示同步错误。
- 本地仓库增加 `memoryRecords(for:)`，同步和导出可读取保留的删除墓碑，普通记忆界面仍只显示 active 记录。同步结果通过 `assistantMemorySyncApplied` 刷新当前账号页面，账号变化不会把旧结果发布到新账号。
- APIService 的云记忆方法统一使用 `APIConfig.v2BaseURL`；路径 ID 只允许安全字符并做 URL 编码，服务端 owner 仍由 Bearer 身份决定。

### 21.2 本地验证与边界

- `Scripts/test-assistant-cloud-memory-sync.sh` 使用真实 `AssistantLocalRepository`、真实同步客户端和网络夹具验证：增量 active 行与 tombstone 应用、游标推进、Bearer 头、上行 `expectedVersion=0`、服务器版本回读，以及本地脏编辑遇到服务端墓碑时的保留与 409 冲突；**3 套 / exit 0**。
- `Scripts/test-assistant-chat-viewmodel.sh` 与 `Scripts/test-assistant-data-import-viewmodel.sh` 在接入同步客户端后均 exit 0；本轮最终改动后的 `xcodebuild -project Caobao.xcodeproj -scheme Caobao -sdk iphonesimulator ... build` 返回 0，日志 `/tmp/caobao-ios-build.cloudsync4.log` 末尾为 `** BUILD SUCCEEDED **`。
- 当前只同步长期记忆；会话、任务、设置仍没有完整云端冲突合并。真实 CaoBao 服务端、Apple 登录/StoreKit、真实网络错误重试、后台同步、真机和强制 iPhone Duo 仍是发布门禁，不能用夹具证据替代。

## 22. Phase 22：任务定义云同步（2026-10-30）

### 22.1 已实现范围

- 任务页面首次进入时使用 `/api/v2/tasks` 拉取服务端任务，并合并到当前账号的本地任务库；本地独有任务使用 `POST /api/v2/tasks` 上传。
- 服务端任务的 `status`、时间、时区、重复规则、审批要求和版本字段按 v2 合约解析；本地 `reminderEnabled`、来源消息和重复计划起点继续由本地提醒系统持有，不由云端任务覆盖。
- API 客户端支持带 `expectedVersion` 的任务 `PATCH`，为后续版本合并保留乐观锁入口；当前任务页只对本地独有定义执行 POST，避免没有云端版本状态时覆盖另一设备的编辑。

### 22.2 边界与验证

- 当前服务端任务接口只有全量列表和单条写入，没有任务增量游标、删除墓碑或删除端点。因此本阶段不宣称完成任务的删除同步、多端冲突合并或本地同 ID 编辑上行；本地任务和提醒在离线时仍可用。
- `xcodebuild -project Caobao.xcodeproj -scheme Caobao -sdk iphonesimulator -configuration Debug -derivedDataPath /tmp/caobao-ios-build.tasks CODE_SIGNING_ALLOWED=NO build` 实际返回 0，日志末尾为 `** BUILD SUCCEEDED **`；`git diff --check` 通过。
- 任务同步与记忆同步均依赖真实登录和 v2 服务端；生产账号、跨设备任务冲突、任务删除传播、后台同步、Apple/StoreKit、真实通知送达、真机和强制 iPhone Duo 仍是发布门禁。

## 23. Phase 23：会话历史拉取同步（2026-10-30）

### 23.1 已实现范围

- `AssistantCloudConversationSync` 使用 v2 `GET /conversations` 和 `GET /conversations/:conversationId/messages`，携带 Bearer token、分页游标和 8 MiB 单响应上限；拒绝重定向、非 HTTPS 配置和非 `cnv_<数字>` 服务端会话标识。
- 登录后的同步入口会先拉取云端会话，再拉取记忆；远端缺失于本地的会话和消息按 `clientConversationId`、`clientMessageId`、`requestId`、`generationId` 幂等合并。已有本地草稿、pending/streaming 消息和本地删除标记不会被云端恢复覆盖。
- 会话同步是 pull-only：不上传草稿、BYOK 会话或本地删除，也不把服务端历史当作工具授权或系统指令。远端图片及非 text 内容暂不导入，文本历史可恢复；异常时间戳或重复游标会拒绝本次同步，避免把损坏数据写入本地或无限请求。
- 为控制单次恢复的资源范围，每次最多处理 200 个会话，每个会话最多读取 1,000 条消息；超出部分不会在本轮导入。拉取完成后，若当前可见会话没有未保存消息或进行中的生成，会安全刷新到合并后的云端历史。

### 23.2 边界与验证

- 服务端目前没有会话版本/变更游标/删除墓碑，因此本阶段不宣称完成双向冲突合并、删除传播或可靠增量同步；本地 archive 仍是删除和草稿的权威来源。
- `Scripts/test-assistant-cloud-conversation-sync.sh` 覆盖 Bearer、分页、服务端会话关联、消息幂等合并、本地 pending 保留和删除墓碑不复活；独立测试通过。原有 `AssistantConversationClient` 20 组测试继续保留。
- 会话同步仍依赖真实登录和服务端数据；生产网络、后台同步、真实账号、真机和强制 iPhone Duo 验收仍未完成。

## 24. Phase 24：APNs 设备注册客户端闭环（2026-10-30）

### 24.1 已实现范围

- 新增 `AssistantDeviceRegistrationClient`，对接现有 `POST /api/v2/devices`；请求使用 HTTPS、Bearer、JSON 和 `deviceId/platform/pushToken/environment/topic` 字段，拒绝重定向，不把 token 或设备标识写入日志。
- iOS 使用 Keychain 保存稳定设备 ID，APNs `deviceToken` 转为小写 hex；登录成功、token 刷新、前台恢复和 token 变化都会尝试按当前账号注册。只有系统通知权限已经允许时才调用 `registerForRemoteNotifications`，不会静默弹出授权框；退出登录会取消在途注册。
- Debug/Release 的 `aps-environment` 与 `sandbox/production` 请求环境分别由 Xcode 构建配置提供；设备注册失败只在下一次前台或 token 事件重试，不伪造注册成功。

### 24.2 验证与边界

- `Scripts/test-assistant-device-registration.sh` 使用真实 URLSession/URLProtocol 验证 POST 路径、Bearer、JSON 字段、空输入拒绝、重定向阻断和异常响应；输出 `All device registration suites passed`。
- `xcodebuild -project Caobao.xcodeproj -scheme Caobao -sdk iphonesimulator -configuration Debug -derivedDataPath /tmp/caobao-ios-build.device-registration CODE_SIGNING_ALLOWED=NO build` 返回 0，日志 `/tmp/caobao-ios-build.device-registration.log` 末尾为 `** BUILD SUCCEEDED **`；`git diff --check`、工程 plist 检查通过。
- 模拟器不能产生可送达的 APNs token；本阶段没有真实 Apple 登录、生产 APNs、服务端设备行、通知 outbox/Worker、系统交付、真机、签名/TestFlight 或 iPhone Duo 证据。服务端已有注册路由，但完整通知发布门禁仍未完成。


## 25. Phase 25：账号偏好服务端回读同步（2026-10-30）

### 25.1 已实现范围

- 服务端新增认证后的 `GET /api/v2/profile/preferences`，返回 locale、persona、CN/INTL 区域确认、账户时区锁定状态和服务端来源；原有 PATCH 更新接口复用同一快照构造。
- iOS `AppState.refreshAssistantState()` 在登录/前台刷新时通过独立的严格 `AssistantPreferencesClient` 读取服务端偏好，按 owner、access token 和任务代次校验后应用规范化 locale、persona 和已确认区域；服务端返回空/未确认区域时会清理旧本地区域，BYOK、模型连接、安静时段仍保持设备本地。
- 客户端偏好 GET 只允许 HTTPS、Bearer、JSON 和有界响应，拒绝重定向，不把凭据转发到第二个地址；HomeView 保存设置不再重复提交已锁定的设备时区，避免跨时区移动导致整包 PATCH 失败。
- 偏好回读有 5 分钟新鲜度和并发合并，失败保留当前账号本地快照并在下一个窗口重试；不把其他账号的服务器结果发布到当前 UI。

### 25.2 验证与边界

- 服务端 `TestPreferencesClientContract` 额外覆盖非法区域不会锁定首次时区；偏好字段在写入前完成长度/控制字符校验，时区、区域和偏好更新在同一数据库事务内提交。`model`、`service/caobao`、`controller/caobao` 重点测试通过。
- `Scripts/test-assistant-preferences.sh` 覆盖认证 GET、路径、重定向阻断、畸形快照和无效 token；全量 `Scripts/test-assistant.sh` 通过（含 168 组 ChatViewModel 集成测试）。
- iOS Simulator Debug 构建 `/tmp/caobao-ios-build.preferences-final.log` 末尾为 `** BUILD SUCCEEDED **`；工程和差异检查通过。
- 当前没有真实 Apple 账号、多设备冲突、生产网络或跨设备 UI 验证；服务端仍需真实部署后联调，任务/会话完整双向同步仍未完成。

## 26. Phase 26：订阅跨设备快照与 StoreKit 生命周期（2026-10-30）

### 26.1 已实现范围

- 服务端订阅状态按 Apple `signedDate` 单调应用；旧通知不能覆盖较新的续订、到期、退款或撤销状态。pending 通知进入 worker 重试，首次交易绑定后也会立即补偿处理。
- `GET /api/v2/entitlements` 返回当前账号最新订阅快照，包含 `productId`、生命周期 `status` 和 `expiresAt`；active/grace 超过服务端到期时间会归一为 expired，终态不会退化为 none。
- iOS StoreKit 交易流在应用启动时建立独立监听。配置或登录暂不可用时，未完成交易保留在内存队列；服务器配置就绪后按当前账号令牌和商品白名单重新验证，不提前 finish 未确认交易。
- 订阅页在没有本机已验证交易时读取并校验 `/entitlements` 的账号快照，展示商品 ID、状态和到期时间；网络或格式错误保留上一份有效快照，账号切换/退出登录会清理账号绑定状态。

### 26.2 验证与边界

- 服务端 `model`、`service/caobao`、`controller/caobao` 重点测试通过，包含乱序通知拒绝旧状态和 revoked 跨设备读取；`git diff --check` 通过。
- `Scripts/test-assistant-entitlements.sh`：14/14 通过；iOS Simulator Debug build 返回 0，日志 `/tmp/caobao-ios-build.current2.log` 末尾为 `** BUILD SUCCEEDED **`。
- macOS 偏好页、基础聊天页以及 Fortune/History/Profile 已进入 macOS target；旧页面的颜色、工具栏、分享控制器和导航类型已完成 macOS 兼容分支。最终 `xcodebuild -project Caobao.xcodeproj -scheme Caobao-macOS -sdk macosx -configuration Debug -derivedDataPath /tmp/caobao-macos-fix2i CODE_SIGNING_ALLOWED=NO build` 返回 0，末尾为 `** BUILD SUCCEEDED **`。
- 真实 Apple Server Notifications、StoreKit 生产商品、账号登录、退款/续订和跨设备网络联调仍需发布门禁；服务端未凭价格推导套餐额度，订阅快照不会自行授予未配置的月度额度。

## 27. Phase 27：服务端生成可靠性、通知 outbox 租约与 macOS target（2026-10-30）

### 27.1 已实现范围

- 服务端 relay fallback 只在首个候选没有可用正文时重试；已经向客户端发出正文或请求已取消时不会重复上游请求。fallback 的首个可见 delta 前发送一次 `model_policy` SSE 事件，成功后把实际 model/protocol 持久化到 generation，重连和 GET 使用同一实际策略。
- SSE replay 从已持久化的 `UsageJson` 恢复非零 usage 事件，重连顺序保持 `started → delta → usage → completed`；生成取消会观察数据库状态并停止上游请求，工具事件不会被伪装成普通文本完成。
- APNs transactional outbox 使用 `sending` 状态、claim token 和过期租约。claim 通过条件更新避免多 worker 同时发送同一行；完成/失败必须携带租约 token，过期租约可重领，达到重试上限进入 `dead`。Dispatcher 已切换到带租约的完成接口，旧接口仍保留兼容。
- Apple 订阅验证要求幂等键并校验请求交易、商品和 appAccountToken 与签名交易一致；同 notificationId 的不同 payload 返回冲突，旧的前台交易回放不能重新激活已退款/撤销链。APNs 发送使用设备保存的 environment/topic。
- macOS target 的 Fortune、History、Profile、偏好页和基础聊天页已完成跨平台分支；macOS 13 可用占位页替代高版本 API，移除 macOS 不可用的 iOS speech 调用。

### 27.2 本地验证与边界

- 服务端 `GOTOOLCHAIN=local GOWORK=off go test -count=1 ./model ./service/caobao ./controller/caobao` 通过，包含 fallback policy、SSE replay、StoreKit 防护、APNs outbox exclusive lease/expired lease 和通知冲突测试；`git diff --check` 通过。
- iOS Simulator Debug build 与 macOS Debug build 均返回 0，末尾为 `** BUILD SUCCEEDED **`；`Scripts/test-assistant.sh` 的 168 个 ChatViewModel 集成套件全部通过，工程/entitlements plist lint 通过。
- 当前证据仍是本地代码、模拟器和隔离网络/数据库测试。真实 upstream model、Apple 登录/StoreKit 商品、APNs token/系统送达、生产部署、签名/TestFlight、实机性能和强制 iPhone Duo 专用姿态仍需独立验收。

## 28. Phase 28：会话与任务增量云同步（2026-11-02）

### 28.1 已实现范围

- 服务端新增 owner-scoped 会话变更 feed：`GET /api/v2/sync/conversations`（兼容别名 `/conversations/changes`），会话创建/更新追加 upsert 事件，删除保留 tombstone 并清理消息正文；新增 `DELETE /api/v2/conversations/:conversationId`。
- iOS `AssistantCloudConversationSync` 使用 owner-scoped 持久游标消费 upsert/delete，整页应用成功后才推进游标；拒绝负数、回退、超过服务端 head 的损坏游标，并在服务端无变更 feed 时回退到受限全量拉取。
- 服务端新增任务变更 feed `GET /api/v2/tasks/changes` 与 `DELETE /api/v2/tasks/:taskId`。任务删除写入 `deletedAt` tombstone、取消待运行 occurrence；iOS 任务页应用 tombstone、删除本地提醒状态并持久化 owner-scoped 游标，同时保留本地删除待上行队列。
- 任务变更游标按 `(updatedAt,id)` 排序；服务端编辑/状态/删除路径会保证 `updatedAt` 单调递增，即使同一 Unix 秒内连续编辑也不会被增量同步跳过。

### 28.2 验证与边界

- `Scripts/test-assistant-cloud-conversation-sync.sh` 通过，包含 DELETE 路径/Bearer 校验；`Scripts/test-assistant-cloud-memory-sync.sh` 3/3 通过；`Scripts/test-assistant-chat-viewmodel.sh` 168 个集成套件通过。
- 服务端 `GOTOOLCHAIN=local GOWORK=off go test -count=1 ./model ./controller/caobao ./service/caobao` 通过；模型回归覆盖会话删除 tombstone、任务同秒编辑游标和删除传播。`git diff --check` 两端通过。
- iOS Simulator Debug 与 macOS Debug 构建均已通过；当前证据仍是本地隔离数据库/网络夹具和模拟器，未证明真实账号、生产部署、后台调度、APNs 送达或多设备冲突合并。

## 29. Phase 29：同步游标与删除队列加固（2026-11-02）

- 会话客户端拒绝页面内乱序、重复或超出 `nextCursor` 的变更序号；任务客户端校验 RFC3339 `updatedAt`、复合游标不回退以及 `headCursor` 不早于当前页，并在整页处理成功后才保存游标。
- 本地删除成功后进入 owner-scoped 待上行删除队列；队列遍历使用稳定快照，网络失败保留待重试项。远端 tombstone 先清理本地提醒，再移除待上行标记，避免旧 active 行复活。
- 会话历史删除现在把已有 `serverConversationId` 放入 owner-scoped 队列，通过 `DELETE /api/v2/conversations/:conversationId` 上行；登录同步时先冲刷队列，失败项保留，不阻塞本地删除结果。
- 服务端 `UpsertCaoBaoTask`、状态转换、运行完成、批准恢复和删除路径统一使用单调 `updated_at`，同一 Unix 秒内的连续编辑仍能产生可消费的变化。

本阶段的加固已包含在 iOS Debug、macOS Debug 和服务端重点回归中；生产网络、多设备冲突和真实通知交付仍需单独验收。

## 30. Phase 32：核心功能代码闭环与一次性任务执行修复（2026-11-02）

### 30.1 核心功能完成口径

- P0 客户端与服务端代码路径已闭环：Apple 身份会话、每日额度领取/预留/扣减/释放、订阅状态、CN/INTL 模型策略、BYOK 三协议、多轮流式生成/停止/重试/重新生成、图片与语音入口、人格配置、记忆 CRUD/授权/关闭/删除、任务与本地提醒、会话/任务/记忆云同步、删除墓碑、账号本地清理和自适应 iPhone/iPad/macOS 布局均有实际实现。
- 服务端任务 worker 对一次性任务不再调用空重复规则计算；一次性提醒完成后写入 completed，不会被错误标记 failed。提醒通知 payload 改为结构化 JSON 编码，任务标题或任务 ID 含引号、反斜杠或换行时仍保持有效且可解析。
- 账号删除状态查询已闭环：服务端提供 `GET /api/v2/deletions/{deletionRequestId}` 的状态只读能力；客户端在前台恢复时不携带已撤销 token 回读状态，并按 owner/origin 更新本地删除元数据，网络失败保留原状态等待下次重试。
- 该口径表示核心代码功能已经完成；真实 Apple 账号、生产模型、APNs/StoreKit 交付、签名/TestFlight、真实多设备与 iPhone Duo 专用姿态仍是发布环境验收，不再作为代码功能缺口混入核心开发状态。

### 30.2 当前验证

- `Scripts/test-assistant.sh` 最新运行 exit 0；包含 101 个本地仓库、44 个视口、50 个任务工具协议、38 个 SQLite、38 个归档、88 个提醒协调、48 个任务执行、35 个导出、28 个恢复、15 个导入、17 个身份客户端、18 个删除通知、168 个 ChatViewModel 集成等当前生产代码回归组；身份状态查询和本机删除状态回归均通过。
- `GOTOOLCHAIN=local GOWORK=off go test -count=1 ./model ./controller/caobao ./service/caobao` 通过；`./service/caobao` 新增一次性任务和提醒 JSON 回归通过。
- iOS Simulator Debug 构建 `/tmp/caobao-ios-core-final.log` 返回 0，末尾为 `** BUILD SUCCEEDED **`；两端 `git diff --check` 通过。
