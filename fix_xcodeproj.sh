#!/bin/bash
# 修复损坏的 Xcode 项目文件

set -e

echo "开始修复..."

# 1. 备份并删除损坏的文件
echo "1. 备份并删除 Caobao.xcodeproj..."
mv Caobao.xcodeproj Caobao.xcodeproj.broken

# 2. 从 GitHub 重新下载
echo "2. 从 GitHub 重新下载..."
git fetch origin
git checkout origin/main -- Caobao.xcodeproj

# 3. 验证
echo "3. 验证..."
if [ -f "Caobao.xcodeproj/project.pbxproj" ]; then
    echo "✅ 项目文件已恢复"
else
    echo "❌ 恢复失败"
    exit 1
fi

# 4. 删除 Xcode 缓存
echo "4. 删除 Xcode 缓存..."
rm -rf ~/Library/Developer/Xcode/DerivedData/Caobao-*

echo ""
echo "✅ 修复完成！"
echo "请重新打开: open Caobao.xcodeproj"
