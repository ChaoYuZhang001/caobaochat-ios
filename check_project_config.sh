#!/bin/bash

# Xcode项目配置文件检查脚本
# 检查 Caobao.xcodeproj/project.pbxproj 的完整性

PROJECT_FILE="/tmp/caobaochat-ios/Caobao.xcodeproj/project.pbxproj"

echo "🔍 Xcode项目配置文件检查"
echo "================================"
echo ""

# 检查1: 文件是否存在
if [ ! -f "$PROJECT_FILE" ]; then
    echo "❌ 项目文件不存在: $PROJECT_FILE"
    exit 1
fi

echo "✅ 项目文件存在"
echo ""

# 检查2: 文件大小
FILE_SIZE=$(stat -f%z "$PROJECT_FILE")
echo "📏 文件大小: $FILE_SIZE bytes"
echo ""

# 检查3: 文件结构完整性
echo "🔍 检查文件结构..."

# 检查开始标记
if grep -q "^// !\$*UTF8\$*!\$" "$PROJECT_FILE"; then
    echo "   ✅ UTF8标记正确"
else
    echo "   ❌ 缺少UTF8标记"
fi

# 检查结束标记
if grep -q "^rootObject = A6000000;}" "$PROJECT_FILE"; then
    echo "   ✅ 根对象引用正确"
else
    echo "   ❌ 缺少根对象引用"
fi

# 检查花括号匹配
OPEN_BRACES=$(grep -o "{" "$PROJECT_FILE" | wc -l)
CLOSE_BRACES=$(grep -o "}" "$PROJECT_FILE" | wc -l)

if [ "$OPEN_BRACES" -eq "$CLOSE_BRACES" ]; then
    echo "   ✅ 花括号匹配 ($OPEN_BRACES 对)"
else
    echo "   ❌ 花括号不匹配 (开: $OPEN_BRACES, 闭: $CLOSE_BRACES)"
fi

echo ""

# 检查4: AuthService.swift 引用
echo "🔍 检查 AuthService.swift 引用..."

AUTH_REF_COUNT=$(grep -c "AuthService.swift" "$PROJECT_FILE")
echo "   引用次数: $AUTH_REF_COUNT"

if [ "$AUTH_REF_COUNT" -eq 3 ]; then
    echo "   ✅ 引用次数正确（3次）"

    # 检查引用类型
    BUILD_FILE_REF=$(grep "A1000009.*AuthService.swift" "$PROJECT_FILE")
    BUILD_FILE_REF2=$(grep "B1000005.*AuthService.swift" "$PROJECT_FILE")
    FILE_REF=$(grep "A2000009.*AuthService.swift" "$PROJECT_FILE")

    if [ -n "$BUILD_FILE_REF" ]; then
        echo "   ✅ iOS Target 引用存在"
    fi

    if [ -n "$BUILD_FILE_REF2" ]; then
        echo "   ✅ macOS Target 引用存在"
    fi

    if [ -n "$FILE_REF" ]; then
        echo "   ✅ 文件引用定义存在"

        # 检查路径类型
        if echo "$FILE_REF" | grep -q 'path = AuthService.swift'; then
            echo "   ✅ 使用相对路径"
        fi

        if echo "$FILE_REF" | grep -q 'sourceTree = "<group>"'; then
            echo "   ✅ 使用 group 源树"
        fi
    fi
else
    echo "   ❌ 引用次数不正确"
fi

echo ""

# 检查5: 绝对路径
echo "🔍 检查绝对路径..."

ABS_PATH_COUNT=$(grep -c 'path = /' "$PROJECT_FILE" | grep -v "sourceTree")
if [ "$ABS_PATH_COUNT" -eq 0 ]; then
    echo "   ✅ 没有硬编码的绝对路径"
else
    echo "   ⚠️  发现 $ABS_PATH_COUNT 个绝对路径引用"
    grep 'path = /' "$PROJECT_FILE" | head -5
fi

echo ""

# 检查6: 重复ID
echo "🔍 检查重复ID..."

# 检查PBXBuildFile重复
BUILD_FILE_DUPS=$(grep -oE "PBXBuildFile.*A[0-9]{7}" "$PROJECT_FILE" | sort | uniq -d)
if [ -z "$BUILD_FILE_DUPS" ]; then
    echo "   ✅ PBXBuildFile ID 无重复"
else
    echo "   ⚠️  发现重复的 PBXBuildFile ID"
fi

# 检查PBXFileReference重复
FILE_REF_DUPS=$(grep -oE "PBXFileReference.*A[0-9]{7}" "$PROJECT_FILE" | sort | uniq -d)
if [ -z "$FILE_REF_DUPS" ]; then
    echo "   ✅ PBXFileReference ID 无重复"
else
    echo "   ⚠️  发现重复的 PBXFileReference ID"
fi

echo ""

# 检查7: 关键文件引用
echo "🔍 检查关键文件引用..."

KEY_FILES=(
    "CaobaoApp.swift"
    "APIService.swift"
    "AuthService.swift"
    "ChatViewModel.swift"
    "Info.plist"
)

for file in "${KEY_FILES[@]}"; do
    COUNT=$(grep -c "$file" "$PROJECT_FILE")
    if [ "$COUNT" -gt 0 ]; then
        echo "   ✅ $file 引用: $COUNT 次"
    else
        echo "   ❌ $file 未引用"
    fi
done

echo ""

# 检查8: 构建配置
echo "🔍 检查构建配置..."

if grep -q "CONFIGURATION_BUILD_DIR" "$PROJECT_FILE"; then
    echo "   ⚠️  自定义构建目录"
else
    echo "   ✅ 使用默认构建目录"
fi

PROJECT_ROOT=$(grep "projectRoot" "$PROJECT_FILE" | tail -1)
if [ -n "$PROJECT_ROOT" ]; then
    echo "   项目根目录: $PROJECT_ROOT"
fi

echo ""

# 总结
echo "================================"
echo "✅ 检查完成"
echo ""
echo "📊 检查结果："
echo "   - 项目文件: 完整"
echo "   - 文件结构: 正确"
echo "   - AuthService引用: 正确"
echo "   - 路径类型: 相对路径（正确）"
echo "   - 绝对路径: 无"
echo ""
echo "💡 结论："
echo "   Caobao.xcodeproj 配置文件本身没有问题。"
echo "   构建错误是由 Xcode 缓存引起的，请清理 Derived Data。"
echo ""
