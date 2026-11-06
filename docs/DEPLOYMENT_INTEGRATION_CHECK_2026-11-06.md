# 客户端与 ciyuan2api.com 联调记录（2026-11-06）

## 已验证

- https://ciyuan2api.com/ 返回 HTTP 200。
- TLS 证书为 ciyuan2api.com，Let's Encrypt，TLS 1.3，证书校验通过。
- GET /api/status 返回 HTTP 200。
- 未携带认证访问 GET /api/v2/models、GET /api/v2/profile/preferences 和 GET /api/v2/characters，服务端返回 401 UNAUTHENTICATED。
- GET /api/v2/ 返回 404；v2 根路径没有根路由，这不影响具体资源路由。
- 响应头版本：v1.0.0-rc.48+ciyuan.reconstructed.20261106.1。
- 客户端 Simulator Debug 构建：BUILD SUCCEEDED。
- 客户端完整 Scripts/test-assistant.sh 回归通过，包含 168 个 ChatViewModel 集成套件；测试使用 mock 网络，不代表真实账号生成成功。

## 客户端配置

生产默认地址统一为：

    https://ciyuan2api.com
    https://ciyuan2api.com/api/v2

已同步修改：

- Caobao/Services/APIService.swift
- Caobao/Services/AssistantPreferences.swift
- Caobao/Services/AssistantDeviceRegistration.swift
- Caobao-watchOS/WatchAPIService.swift
- Optimized/NetworkOptimizer.swift

Info.plist 的 CaoBaoAssistantAPIBaseURL 已经是 https://ciyuan2api.com/api/v2，本次同时修复非 Bundle fallback，避免测试、watchOS 或初始化路径回到旧域名。

## 仍未证明

以下需要真实 Apple 账号或真实设备继续验收：

1. Sign in with Apple 登录、刷新、退出和撤销。
2. /api/v2/models、/api/v2/characters、对话和任务接口的真实 Bearer 请求。
3. 真实模型流式生成、额度预留/扣减/释放和错误重试。
4. APNs token 注册、锁屏送达、通知点击深链。
5. StoreKit 沙盒购买、恢复、退款和撤销。
6. 多设备会话、任务、记忆和角色同步。
7. TestFlight 签名、安装、生产健康检查和回滚。

未携带凭据的 HTTP 200/401 只能证明域名、TLS、Nginx 和认证入口可达，不能证明业务登录或模型调用已经成功。

