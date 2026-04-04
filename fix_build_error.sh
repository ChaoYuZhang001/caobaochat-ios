#!/bin/bash

# Xcode构建错误强制修复脚本
# 针对 "Build input file cannot be found" 错误

echo "🔧 Xcode构建错误强制修复工具"
echo "================================"
echo ""

# 检测当前目录
CURRENT_DIR=$(pwd)
echo "📍 当前目录: $CURRENT_DIR"

# 检测是否在项目目录中
if [[ ! "$CURRENT_DIR" == *"caobaochat-ios"* ]]; then
    echo ""
    echo "❌ 错误：请先进入项目目录"
    echo ""
    echo "请运行："
    echo "  cd ~/Desktop/caobaochat-ios  # 或你的项目路径"
    echo "  ./fix_build_error.sh"
    echo ""
    exit 1
fi

echo "✅ 检测到项目目录"
echo ""

# 验证关键文件
echo "🔍 验证关键文件..."
FILES_OK=true

if [ ! -f "Caobao.xcodeproj/project.pbxproj" ]; then
    echo "❌ Caobao.xcodeproj/project.pbxproj 不存在"
    FILES_OK=false
fi

if [ ! -f "Caobao/Services/AuthService.swift" ]; then
    echo "❌ Caobao/Services/AuthService.swift 不存在"
    FILES_OK=false
else
    echo "✅ Caobao/Services/AuthService.swift 存在"
fi

if [ "$FILES_OK" = false ]; then
    echo ""
    echo "❌ 关键文件缺失，无法继续修复"
    echo ""
    exit 1
fi

echo ""
echo "🚀 开始修复..."
echo ""

# 步骤1：强制关闭Xcode
echo "📱 [1/6] 强制关闭Xcode..."
killall -9 Xcode 2>/dev/null
sleep 2
echo "   ✅ Xcode已关闭"
echo ""

# 步骤2：清理Derived Data
echo "🗑️  [2/6] 清理Derived Data..."
DERIVED_DATA_DIRS=(
    "$HOME/Library/Developer/Xcode/DerivedData"
)

for dir in "${DERIVED_DATA_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        echo "   清理: $dir"
        rm -rf "$dir"/*
    fi
done
echo "   ✅ Derived Data已清理"
echo ""

# 步骤3：清理项目缓存
echo "🗑️  [3/6] 清理项目缓存..."
find . -name "*.xcuserstate" -type f -delete 2>/dev/null
find . -name "*.xcuserdata" -type d -exec rm -rf {} + 2>/dev/null
find . -name "*.xcscheme" -path "*/xcuserdata/*" -delete 2>/dev/null
echo "   ✅ 项目缓存已清理"
echo ""

# 步骤4：清理构建产物
echo "🗑️  [4/6] 清理构建产物..."
rm -rf build 2>/dev/null
rm -rf DerivedData 2>/dev/null
rm -rf *.xcworkspace/xcuserdata 2>/dev/null
echo "   ✅ 构建产物已清理"
echo ""

# 步骤5：清理Git状态（如果是Git仓库）
if [ -d ".git" ]; then
    echo "📦 [5/6] 重置Git状态..."
    git reset --hard HEAD 2>/dev/null
    git clean -fd 2>/dev/null
    echo "   ✅ Git状态已重置"
else
    echo "📦 [5/6] 跳过Git重置（非Git仓库）"
fi
echo ""

# 步骤6：重新打开项目
echo "🚀 [6/6] 重新打开项目..."
open Caobao.xcodeproj
sleep 3
echo "   ✅ 项目已打开"
echo ""

# 验证AuthService.swift是否在正确位置
echo ""
echo "🔍 验证AuthService.swift位置..."
REAL_PATH="$(pwd)/Caobao/Services/AuthService.swift"
echo "   实际路径: $REAL_PATH"

if [ -f "$REAL_PATH" ]; then
    echo "   ✅ 文件存在于正确位置"
else
    echo "   ❌ 文件不存在！"
    echo ""
    echo "   请检查项目结构是否完整"
fi

echo ""
echo "================================"
echo "✅ 修复完成！"
echo ""
echo "📋 接下来的步骤："
echo "   1. 在Xcode中，按 Command + Shift + K 清理构建"
echo "   2. 在Xcode中，确保选择了正确的 Scheme: Caobao"
echo "   3. 在Xcode中，按 Command + B 重新构建"
echo ""
echo "🔍 如果仍然报错："
echo "   1. 在Xcode中，点击 Product > Clean Build Folder (Shift + Command + K)"
echo "   2. 在Xcode中，选择 Product > Destination > 选择正确的设备"
echo "   3. 在Xcode中，点击 Product > Scheme > Edit Scheme"
echo "   4. 检查 Build Settings 中的所有路径设置"
echo ""
echo "💡 提示：如果问题持续存在，请尝试重新克隆项目："
echo "   cd ~/Desktop"
echo "   rm -rf caobaochat-ios"
echo "   git clone https://github.com/ChaoYuZhang001/caobaochat-ios.git"
echo "   cd caobaochat-ios"
echo "   open Caobao.xcodeproj"
echo ""
