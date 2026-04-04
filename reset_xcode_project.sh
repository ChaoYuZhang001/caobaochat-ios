#!/bin/bash

# Xcode项目完全重置脚本
# 用途：解决Build input file cannot be found错误

echo "🔧 开始重置Xcode项目..."

# 检查当前目录
CURRENT_DIR=$(pwd)
if [[ ! "$CURRENT_DIR" == *"caobaochat-ios"* ]]; then
    echo "❌ 错误：请在caobaochat-ios项目根目录下运行此脚本"
    echo "   当前目录: $CURRENT_DIR"
    exit 1
fi

echo "✅ 当前目录正确: $CURRENT_DIR"

# 1. 关闭Xcode
echo "📱 正在关闭Xcode..."
killall Xcode 2>/dev/null
sleep 2

# 2. 删除Derived Data
echo "🗑️  正在清理Derived Data..."
rm -rf ~/Library/Developer/Xcode/DerivedData/caobaochat-ios-*
rm -rf ~/Library/Developer/Xcode/DerivedData/Caobao-*

# 3. 删除用户状态文件
echo "🗑️  正在清理用户状态文件..."
find . -name "*.xcuserstate" -delete 2>/dev/null
find . -name "*.xcuserdata" -type d -exec rm -rf {} + 2>/dev/null

# 4. 删除构建目录
echo "🗑️  正在清理构建目录..."
rm -rf build/
rm -rf DerivedData/

# 5. 删除锁文件
echo "🗑️  正在清理锁文件..."
find . -name "project.xcworkspace" -name "xcuserdata" -type d -exec rm -rf {} + 2>/dev/null

# 6. 验证关键文件
echo "🔍 正在验证关键文件..."
REQUIRED_FILES=(
    "Caobao.xcodeproj/project.pbxproj"
    "Caobao/App/App.swift"
    "Caobao/Services/AuthService.swift"
)

MISSING_FILES=0
for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo "✅ $file 存在"
    else
        echo "❌ $file 不存在"
        MISSING_FILES=$((MISSING_FILES + 1))
    fi
done

if [ $MISSING_FILES -gt 0 ]; then
    echo "⚠️  警告：发现 $MISSING_FILES 个缺失文件"
    read -p "是否继续？(y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# 7. 重新生成项目文件（如果需要）
echo "🔧 正在重置项目文件..."
if [ -f ".git/index" ]; then
    echo "📦 检测到Git仓库，重置到最新提交..."
    git reset --hard HEAD
    git clean -fd
fi

# 8. 打开项目
echo "🚀 正在打开Xcode项目..."
open Caobao.xcodeproj

echo ""
echo "✅ 重置完成！"
echo ""
echo "📋 下一步操作："
echo "   1. 在Xcode中，按 Command + Shift + K 清理构建"
echo "   2. 在Xcode中，选择正确的Scheme: Caobao"
echo "   3. 在Xcode中，按 Command + B 重新构建"
echo "   4. 如果仍然报错，请选择 Product -> Clean Build Folder (Shift + Command + K)"
echo ""
echo "🔍 如果问题仍然存在，请检查："
echo "   1. Xcode -> Settings -> Locations -> Derived Data 路径"
echo "   2. 确保没有其他项目占用相同名称"
echo "   3. 尝试重新克隆项目"
echo ""
