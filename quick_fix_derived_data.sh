#!/bin/bash

# Xcode构建错误快速修复脚本
# 错误：Build input file cannot be found: '/Users/apple/Desktop/caobaochat-ios/AuthService.swift'

echo "🔧 开始修复Xcode构建错误..."
echo "================================"
echo ""

# 验证AuthService.swift文件存在
AUTH_SERVICE="/Users/apple/Desktop/caobaochat-ios/Caobao/Services/AuthService.swift"
if [ -f "$AUTH_SERVICE" ]; then
    echo "✅ AuthService.swift 文件存在"
    echo "   位置: $AUTH_SERVICE"
else
    echo "❌ AuthService.swift 文件不存在"
    echo "   预期位置: $AUTH_SERVICE"
    exit 1
fi
echo ""

# 1. 关闭Xcode（提醒用户）
echo "⚠️  请先关闭 Xcode"
echo "   如果Xcode正在运行，请先关闭它，然后按回车继续"
read -p "按回车继续..."

# 2. 清理Derived Data
echo ""
echo "🧹 清理 Xcode Derived Data..."
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"

if [ -d "$DERIVED_DATA" ]; then
    echo "   删除 Derived Data..."
    rm -rf "$DERIVED_DATA"
    echo "   ✅ Derived Data 已清理"
else
    echo "   ℹ️  Derived Data 目录不存在"
fi
echo ""

# 3. 清理项目构建缓存
echo "🧹 清理项目构建缓存..."
cd /Users/apple/Desktop/caobaochat-ios
rm -rf build/
rm -rf *.xcworkspace/xcuserdata
rm -rf *.xcodeproj/xcuserdata
rm -rf .build/
echo "   ✅ 项目构建缓存已清理"
echo ""

# 4. 清理Xcode缓存
echo "🧹 清理 Xcode 缓存..."
XCODE_CACHE="$HOME/Library/Caches/com.apple.dt.Xcode"
if [ -d "$XCODE_CACHE" ]; then
    echo "   清理 Xcode 缓存..."
    rm -rf "$XCODE_CACHE"
    echo "   ✅ Xcode 缓存已清理"
fi
echo ""

# 5. 重置项目配置
echo "🔄 重置项目配置..."
xcodebuild clean
echo "   ✅ 项目已清理"
echo ""

echo "================================"
echo "✅ 修复完成！"
echo ""
echo "📋 后续步骤："
echo "   1. 重新打开 Xcode"
echo "   2. 打开项目: /Users/apple/Desktop/caobaochat-ios/Caobao.xcodeproj"
echo "   3. 清理构建文件夹 (⌘+Shift+K)"
echo "   4. 重新构建项目 (⌘+B)"
echo ""
echo "💡 如果问题仍然存在，请尝试："
echo "   - Product > Clean Build Folder (⇧⌘K)"
echo "   - 或删除整个项目，重新从GitHub克隆"
echo ""
