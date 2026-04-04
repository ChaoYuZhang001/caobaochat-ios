#!/bin/bash

# 修复Xcode项目文件中AuthService.swift缺失的问题

PROJECT_FILE="/Users/apple/Desktop/caobaochat-ios/Caobao.xcodeproj/project.pbxproj"
BACKUP_FILE="/Users/apple/Desktop/caobaochat-ios/Caobao.xcodeproj/project.pbxproj.backup"

echo "🔧 修复Xcode项目文件 - AuthService.swift缺失问题"
echo "================================"
echo ""

# 1. 备份项目文件
echo "📋 备份项目文件..."
cp "$PROJECT_FILE" "$BACKUP_FILE"
echo "   ✅ 备份完成: $BACKUP_FILE"
echo ""

# 2. 检查当前Services group的内容
echo "📊 检查Services group..."
echo "   当前Services group包含："
grep -A 5 'A5000006.*Services' "$PROJECT_FILE" | grep 'A200000'
echo ""

# 3. 查找AuthService.swift的引用ID
AUTH_REF_ID=$(grep -E 'A200[0-9]+.*AuthService\.swift' "$PROJECT_FILE" | head -1 | grep -oE 'A200[0-9]{4}')
echo "🔍 找到AuthService.swift引用ID: $AUTH_REF_ID"
echo ""

# 4. 修复Services group，添加AuthService.swift
echo "🔧 修复Services group..."

# 读取文件内容
CONTENT=$(cat "$PROJECT_FILE")

# 替换Services group的children
# 从：
# A5000006 /* Services */ = {
#     isa = PBXGroup;
#     children = (
#         A2000007 /* APIService.swift */,
#     );
#     path = Services;
#     sourceTree = "<group>";
# };

# 到：
# A5000006 /* Services */ = {
#     isa = PBXGroup;
#     children = (
#         A2000007 /* APIService.swift */,
#         A2000009 /* AuthService.swift */,
#     );
#     path = Services;
#     sourceTree = "<group>";
# };

# 使用sed进行替换
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' '/A5000006.*Services/,/path = Services;/{
        /children = (/a\
                A2000009 /* AuthService.swift */,
    }' "$PROJECT_FILE"
else
    # Linux
    sed -i '/A5000006.*Services/,/path = Services;/{
        /children = (/a\
                A2000009 /* AuthService.swift */,
    }' "$PROJECT_FILE"
fi

echo "   ✅ Services group已更新"
echo ""

# 5. 验证修复
echo "✅ 验证修复结果..."
echo "   更新后的Services group："
grep -A 6 'A5000006.*Services' "$PROJECT_FILE"
echo ""

# 6. 检查引用是否正确
echo "🔍 验证AuthService.swift引用..."
AUTH_REFS=$(grep -c "AuthService.swift" "$PROJECT_FILE")
echo "   引用次数: $AUTH_REFS"
if [ "$AUTH_REFS" -ge 3 ]; then
    echo "   ✅ 引用正常"
else
    echo "   ⚠️  引用可能有问题"
fi
echo ""

echo "================================"
echo "✅ 修复完成！"
echo ""
echo "📋 后续步骤："
echo "   1. 关闭Xcode（如果打开）"
echo "   2. 清理Derived Data:"
echo "      rm -rf ~/Library/Developer/Xcode/DerivedData"
echo "   3. 重新打开Xcode"
echo "   4. 清理构建文件夹 (⌘+Shift+K)"
echo "   5. 重新构建项目 (⌘+B)"
echo ""
echo "💡 如果问题仍然存在，请恢复备份："
echo "   cp $BACKUP_FILE $PROJECT_FILE"
echo ""
