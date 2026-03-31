# 草包 iOS 客户端

> 犀利不刻薄 · 幽默有关怀 · 真实不虚伪

毒舌但有用的 AI 助手 - iOS/macOS/watchOS 原生客户端

## 平台支持

| 平台 | 最低版本 | 状态 |
|------|---------|------|
| iOS | 16.0+ | ✅ 开发中 |
| iPadOS | 16.0+ | ✅ 开发中 |
| macOS | 13.0+ | ✅ 开发中 |
| watchOS | 9.0+ | ✅ 开发中 |

## 功能特性

### 核心功能

- 🧠 **AI 对话** - 多模型智能路由，流式响应
- 🎤 **语音对话** - 语音输入识别 + 语音播报
- 💡 **毒舌人设** - AI 用独特的方式帮助你
- ⭐ **收藏功能** - 收藏喜欢的金句和对话
- 📊 **数据统计** - 查看使用统计和分析

### 特色功能

- 🌅 **晨报** - 每日新闻摘要 + 天气 + 运势
- 🌙 **晚报** - 今日回顾 + 明日计划
- 🔥 **吐槽** - 毒舌点评你的烦恼
- 🎯 **决策** - 帮你做出选择
- 📖 **金句** - 每日毒舌金句
- 🔮 **运势** - 今日运势预测

## 技术栈

| 技术 | 用途 |
|------|------|
| Swift 5.9+ | 主要开发语言 |
| SwiftUI | UI 框架 |
| AVFoundation | 语音合成/识别 |
| Alamofire | 网络请求 |
| Combine | 响应式编程 |

## 项目结构

```
Caobao/
├── CaobaoApp.swift              # 应用入口
│
├── Models/                      # 数据模型
│   ├── User.swift               # 用户模型
│   ├── FavoriteItem.swift       # 收藏项
│   ├── FortuneData.swift        # 运势数据
│   ├── NicknameData.swift       # 昵称数据
│   └── MediaLinkDetector.swift  # 媒体链接检测器
│
├── Views/                       # 视图层
│   ├── ContentView.swift        # 主视图容器
│   ├── HomeView.swift           # 首页
│   ├── ChatView.swift           # 对话页
│   ├── FortuneView.swift        # 运势页
│   ├── FeaturesView.swift       # 功能页
│   ├── ProfileView.swift        # 个人中心
│   ├── SettingsView.swift       # 设置页
│   ├── CommonViews.swift        # 公共 UI 组件
│   ├── MessageBubble.swift      # 消息气泡组件
│   ├── MorningReportView.swift  # 晨报
│   ├── EveningReportView.swift  # 晚报
│   ├── RoastView.swift          # 吐槽
│   ├── DecisionView.swift       # 决策
│   ├── QuoteView.swift          # 金句
│   └── ...                      # 其他视图
│
├── ViewModels/                  # 视图模型
│   └── ChatViewModel.swift      # 对话逻辑
│
├── Services/                    # 服务层
│   ├── APIService.swift         # API 服务
│   ├── AuthService.swift        # 认证服务
│   └── SpeechManager.swift      # 语音管理
│
└── DesignSystem/                # 设计系统
    └── DesignSystem.swift       # 颜色、字体定义

Caobao-watchOS/                  # watchOS 独立目标
├── CaobaoWatchApp.swift         # watchOS 入口
├── WatchContentView.swift       # 主视图
├── WatchDecisionView.swift      # 决策
├── WatchRoastView.swift         # 吐槽
├── WatchFortuneView.swift       # 运势
├── WatchNewsView.swift          # 新闻
└── WatchAPIService.swift        # watchOS API
```

## 开发环境

- Xcode 15+
- iOS 16.0+ / macOS 13.0+ / watchOS 9.0+

## 配置

1. 克隆项目
```bash
git clone https://github.com/ChaoYuZhang001/caobaochat-ios.git
cd caobaochat-ios
```

2. 打开 `Caobao.xcodeproj`

3. 选择目标设备运行

## 登录方式

| 登录方式 | iOS | iPadOS | macOS | watchOS |
|---------|-----|--------|-------|---------|
| 🍎 Apple 登录 | ✅ | ✅ | ✅ | ❌ |
| 👤 游客模式 | ✅ | ✅ | ✅ | ✅ |

## 支持的模型

| 厂商 | 模型 |
|------|------|
| 阿里云 | 通义千问（16+模型）|
| 火山引擎 | 豆包系列（5+模型）|
| 腾讯 | 混元系列（4+模型）|
| DeepSeek | deepseek-chat/reasoner |
| Moonshot | Kimi 系列 |

## 后端服务

- **Web**: [https://caobao.chat](https://caobao.chat)
- **API**: https://caobao.chat/api
- **后端仓库**: [https://github.com/ChaoYuZhang001/caobaochat](https://github.com/ChaoYuZhang001/caobaochat)

## 最近更新

### 2024.03 - 代码重构
- 提取公共 UI 组件 (`CommonViews.swift`)
- 拆分大文件 (`MessageBubble.swift`, `MediaLinkDetector.swift`)
- 优化代码结构，提高可维护性

## License

MIT
