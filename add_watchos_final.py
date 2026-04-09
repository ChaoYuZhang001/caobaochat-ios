#!/usr/bin/env python3
import re

with open('Caobao.xcodeproj/project.pbxproj', 'r') as f:
    content = f.read()

# 验证原始文件
if content.count('{') != content.count('}'):
    print(f"ERROR: Unbalanced brackets in original file")
    exit(1)

# 1. 添加 watchOS PBXBuildFile entries (在 /* End PBXBuildFile section */ 之前)
build_files = '''		// watchOS Target
		W1000001 /* CaobaoWatchApp.swift in Sources */ = {isa = PBXBuildFile; fileRef = W2000001; };
		W1000002 /* WatchContentView.swift in Sources */ = {isa = PBXBuildFile; fileRef = W2000002; };
		W1000003 /* WatchFortuneView.swift in Sources */ = {isa = PBXBuildFile; fileRef = W2000003; };
		W1000004 /* WatchNewsView.swift in Sources */ = {isa = PBXBuildFile; fileRef = W2000004; };
		W1000005 /* WatchRoastView.swift in Sources */ = {isa = PBXBuildFile; fileRef = W2000005; };
		W1000006 /* WatchDecisionView.swift in Sources */ = {isa = PBXBuildFile; fileRef = W2000006; };
		W1000007 /* WatchAPIService.swift in Sources */ = {isa = PBXBuildFile; fileRef = W2000007; };
		W1000008 /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = W2000008; };
'''
content = content.replace('/* End PBXBuildFile section */', build_files + '\t/* End PBXBuildFile section */')

# 2. 添加 watchOS PBXFileReference entries
file_refs = '''		// watchOS 文件
		W2000001 /* CaobaoWatchApp.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CaobaoWatchApp.swift; sourceTree = "<group>"; };
		W2000002 /* WatchContentView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WatchContentView.swift; sourceTree = "<group>"; };
		W2000003 /* WatchFortuneView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WatchFortuneView.swift; sourceTree = "<group>"; };
		W2000004 /* WatchNewsView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WatchNewsView.swift; sourceTree = "<group>"; };
		W2000005 /* WatchRoastView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WatchRoastView.swift; sourceTree = "<group>"; };
		W2000006 /* WatchDecisionView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WatchDecisionView.swift; sourceTree = "<group>"; };
		W2000007 /* WatchAPIService.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = WatchAPIService.swift; sourceTree = "<group>"; };
		W2000008 /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };
		W2000009 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; };
		W3000001 /* Caobao-watchOS.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "Caobao-watchOS.app"; sourceTree = BUILT_PRODUCTS_DIR; };
'''
content = content.replace('/* End PBXFileReference section */', file_refs + '\t/* End PBXFileReference section */')

# 3. 添加 watchOS PBXGroup (在 PBXNativeTarget 开始之前)
watchos_group = '''		A5000009 /* Caobao-watchOS */ = {
			isa = PBXGroup;
			children = (
				W2000001 /* CaobaoWatchApp.swift */,
				W2000002 /* WatchContentView.swift */,
				W2000003 /* WatchFortuneView.swift */,
				W2000004 /* WatchNewsView.swift */,
				W2000005 /* WatchRoastView.swift */,
				W2000006 /* WatchDecisionView.swift */,
				W2000007 /* WatchAPIService.swift */,
				W2000008 /* Assets.xcassets */,
				W2000009 /* Info.plist */,
			);
			path = "Caobao-watchOS";
			sourceTree = "<group>";
		};

'''
content = content.replace('/* Begin PBXNativeTarget section */', watchos_group + '/* Begin PBXNativeTarget section */')

# 4. 添加 watchOS PBXFrameworksBuildPhase
frameworks = '''		W4000001 /* Frameworks (watchOS) */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
'''
content = content.replace('/* End PBXFrameworksBuildPhase section */', frameworks + '\t/* End PBXFrameworksBuildPhase section */')

# 5. 添加 watchOS PBXResourcesBuildPhase
resources = '''		W8000002 /* Resources (watchOS) */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				W1000008 /* Assets.xcassets in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
'''
content = content.replace('/* End PBXResourcesBuildPhase section */', resources + '\t/* End PBXResourcesBuildPhase section */')

# 6. 添加 watchOS PBXSourcesBuildPhase
sources = '''		W8000001 /* Sources (watchOS) */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				W1000001 /* CaobaoWatchApp.swift in Sources */,
				W1000002 /* WatchContentView.swift in Sources */,
				W1000003 /* WatchFortuneView.swift in Sources */,
				W1000004 /* WatchNewsView.swift in Sources */,
				W1000005 /* WatchRoastView.swift in Sources */,
				W1000006 /* WatchDecisionView.swift in Sources */,
				W1000007 /* WatchAPIService.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
'''
content = content.replace('/* End PBXSourcesBuildPhase section */', sources + '\t/* End PBXSourcesBuildPhase section */')

# 7. 添加 watchOS PBXNativeTarget (在 PBXProject section 开始之前)
watchos_target = '''		W6000001 /* Caobao-watchOS */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = W7000001;
			buildPhases = (
				W8000001 /* Sources */,
				W4000001 /* Frameworks */,
				W8000002 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = "Caobao-watchOS";
			productName = "Caobao-watchOS";
			productReference = W3000001;
			productType = "com.apple.product-type.application.watchapp2";
		};

'''
content = content.replace('/* Begin PBXProject section */', watchos_target + '/* Begin PBXProject section */')

# 8. 添加到 targets 列表 (在 PBXProject section 内部)
old_targets = '''targets = (
				A6000001 /* Caobao */,
				B6000001 /* Caobao-macOS */,
			);'''
new_targets = '''targets = (
				A6000001 /* Caobao */,
				W6000001 /* Caobao-watchOS */,
				B6000001 /* Caobao-macOS */,
			);'''
content = content.replace(old_targets, new_targets)

# 9. 添加 TargetAttributes for watchOS
content = content.replace(
    '''					C6000001 = {
						Create''',
    '''					C6000001 = {
						CreatedOnToolsVersion = 15.0;
					};
					W6000001 = {
						CreatedOnToolsVersion = 15.0;
					};'''
)

# 10. 添加 XCConfigurationList for watchOS
config_list = '''		W7000001 /* Build configuration list for PBXNativeTarget "Caobao-watchOS" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				W9000001 /* Debug */,
				W9000002 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
'''
content = content.replace('/* End XCConfigurationList section */', config_list + '\t/* End XCConfigurationList section */')

# 11. 添加 XCBuildConfiguration for watchOS
debug_config = '''		W9000001 /* Debug (watchOS) */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "Caobao-watchOS/Info.plist";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0.0;
				PRODUCT_BUNDLE_IDENTIFIER = caobao.chat.watchkitapp;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = watchos;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 4;
				WATCHOS_DEPLOYMENT_TARGET = 9.0;
			};
			name = Debug;
		};
'''
release_config = '''		W9000002 /* Release (watchOS) */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = "Caobao-watchOS/Info.plist";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0.0;
				PRODUCT_BUNDLE_IDENTIFIER = caobao.chat.watchkitapp;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = watchos;
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
				TARGETED_DEVICE_FAMILY = 4;
				WATCHOS_DEPLOYMENT_TARGET = 9.0;
			};
			name = Release;
		};
'''
content = content.replace('/* End XCBuildConfiguration section */', debug_config + release_config + '\t/* End XCBuildConfiguration section */')

# 验证
if content.count('{') != content.count('}'):
    print(f"ERROR: Unbalanced brackets after modification")
    print(f"Opens: {content.count('{')}, Closes: {content.count('}')}")
    exit(1)

with open('Caobao.xcodeproj/project.pbxproj', 'w') as f:
    f.write(content)

print("SUCCESS! watchOS target added")
