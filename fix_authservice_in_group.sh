#!/bin/bash

# Xcode项目文件修复 - AuthService.swift缺失问题

PROJECT_FILE="/tmp/caobaochat-ios/Caobao.xcodeproj/project.pbxproj"

echo "🔧 修复Xcode项目文件..."
echo "================================"
echo ""

# 检查当前Services group
echo "📊 当前Services group内容:"
grep -A 5 'A5000006.*Services' "$PROJECT_FILE"
echo ""

# 修复Services group
echo "🔧 修复Services group..."

# 使用Python进行精确修改
python3 << 'PYTHON_SCRIPT'
import re

# 读取文件
with open('/tmp/caobaochat-ios/Caobao.xcodeproj/project.pbxproj', 'r') as f:
    content = f.read()

# 定义要替换的模式
old_pattern = r'(A5000006 /\* Services \*/ = \{[\s\n]*isa = PBXGroup;[\s\n]*children = \([\s\n]*A2000007 /\* APIService\.swift \*/,[\s\n]*\);)'
new_pattern = r'''\1
				A2000009 /* AuthService.swift */,
);'''

# 执行替换
content = re.sub(old_pattern, new_pattern, content, flags=re.MULTILINE)

# 写回文件
with open('/tmp/caobaochat-ios/Caobao.xcodeproj/project.pbxproj', 'w') as f:
    f.write(content)

print("✅ 修复完成")
PYTHON_SCRIPT

echo ""
echo "📊 修复后的Services group:"
grep -A 6 'A5000006.*Services' "$PROJECT_FILE"
echo ""

echo "================================"
echo "✅ Xcode项目文件修复完成！"
echo ""
echo "📋 后续步骤："
echo "   1. 关闭Xcode（如果打开）"
echo "   2. 清理Derived Data:"
echo "      rm -rf ~/Library/Developer/Xcode/DerivedData"
echo "   3. 重新打开Xcode"
echo "   4. 清理构建文件夹 (⌘+Shift+K)"
echo "   5. 重新构建项目 (⌘+B)"
echo ""
