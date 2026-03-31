# 共享文件配置指南

## 需要共享到多个 Target 的文件

### macOS Target 共享文件 (来自 Caobao 目录)
以下文件需要在 Xcode 中添加到 macOS Target：

**Models:**
- `Caobao/Models/User.swift`
- `Caobao/Models/FortuneData.swift`
- `Caobao/Models/NicknameData.swift`
- `Caobao/Models/FavoriteItem.swift`

**Services:**
- `Caobao/Services/APIService.swift`
- `Caobao/Services/AuthService.swift`

**ViewModels:**
- `Caobao/ViewModels/ChatViewModel.swift`

**Views:**
- `Caobao/Views/MacContentView.swift`
- `Caobao/Views/FortuneView.swift`
- `Caobao/Views/HistoryView.swift`
- `Caobao/Views/ProfileView.swift`
- `Caobao/Views/SettingsView.swift`

**DesignSystem:**
- `Caobao/DesignSystem/DesignSystem.swift`

**入口文件:**
- `Caobao/CaobaoApp.swift` (需要条件编译)

### watchOS Target 独立文件 (已创建)
- `Caobao-watchOS/CaobaoWatchApp.swift`
- `Caobao-watchOS/WatchContentView.swift`
- `Caobao-watchOS/WatchFortuneView.swift`
- `Caobao-watchOS/WatchNewsView.swift`
- `Caobao-watchOS/WatchRoastView.swift`
- `Caobao-watchOS/WatchDecisionView.swift`
- `Caobao-watchOS/WatchAPIService.swift`

## Xcode 配置步骤

### 方法一：通过 Target Membership
1. 在 Xcode 左侧项目导航中选择文件
2. 打开右侧 File Inspector (⌥⌘1)
3. 在 Target Membership 区域勾选需要的 Target

### 方法二：通过 Build Phases
1. 选择项目 → 选择 Target
2. 进入 Build Phases → Compile Sources
3. 点击 "+" 添加需要编译的文件

### 方法三：批量配置
1. 选择多个文件 (按住 ⌘ 多选)
2. 右侧 File Inspector 中统一设置 Target Membership

## 条件编译示例

在共享文件中使用条件编译处理平台差异：

```swift
#if os(iOS)
// iOS 特定代码
#elseif os(macOS)
// macOS 特定代码
#elseif os(watchOS)
// watchOS 特定代码
#endif
```

## 注意事项

1. **平台 API 差异**：某些 API 仅在特定平台可用，需要使用条件编译
2. **资源文件**：Assets.xcassets 需要为每个平台创建独立的 AppIcon
3. **框架依赖**：macOS 可能需要不同的框架配置
4. **签名配置**：每个 Target 需要独立的签名配置
