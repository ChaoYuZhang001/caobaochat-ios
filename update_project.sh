#!/bin/bash

# 更新 Xcode 项目文件脚本
# 用于添加 macOS 和 watchOS Target

echo "📦 开始更新 Xcode 项目..."

# 备份原有项目文件
echo "📋 备份原有项目文件..."
cp Caobao.xcodeproj/project.pbxproj Caobao.xcodeproj/project.pbxproj.backup

# 使用新的项目文件
echo "🔄 应用新的项目配置..."
cp Caobao.xcodeproj/project_macos_watch.pbxproj Caobao.xcodeproj/project.pbxproj

# 删除临时文件
rm -f Caobao.xcodeproj/project_macos_watch.pbxproj

echo "✅ 项目更新完成！"
echo ""
echo "📝 下一步操作："
echo "1. 在 Xcode 中打开项目"
echo "2. 检查所有 Target 配置"
echo "3. 配置共享文件到多个 Target"
echo "4. 测试编译所有平台"
