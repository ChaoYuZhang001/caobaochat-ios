#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
workspace="$root/.build/simulator-workspace"
derived="$root/.build/remote-client-derived-data"
packages="$root/.build/remote-source-packages"
lock="$root/Caobao.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
log="$root/.build/simulator-build.log"
destination="$(printenv CAOBAO_SIMULATOR_DESTINATION || true)"
local_package="$(printenv CAOBAO_LOCAL_ALAMOFIRE_PATH || true)"
signing_allowed="$(printenv CAOBAO_CODE_SIGNING_ALLOWED || true)"
if [ -z "$destination" ]; then destination='generic/platform=iOS Simulator'; fi
if [ -z "$signing_allowed" ]; then signing_allowed='YES'; fi
mkdir -p "$root/.build"
if [ -n "$local_package" ]; then
    derived="$root/.build/simulator-derived-data"
    [ -f "$local_package/Package.swift" ] || { echo "Missing local Alamofire package"; exit 1; }
    mkdir -p "$workspace"
    rsync -a --exclude '.git' --exclude '.build' --exclude 'DerivedData' "$root/" "$workspace/"
    python3 - "$workspace/Caobao.xcodeproj/project.pbxproj" "$local_package" <<'PY'
import re,sys,json
from pathlib import Path
p=Path(sys.argv[1]);s=p.read_text()
pattern=r'E1000001 /\* XCRemoteSwiftPackageReference "Alamofire" \*/ = \{\s*isa = XCRemoteSwiftPackageReference;\s*repositoryURL = "https://github.com/Alamofire/Alamofire.git";\s*requirement = \{.*?\};\s*\};'
replacement='E1000001 /* XCLocalSwiftPackageReference "Alamofire" */ = {\n isa = XCLocalSwiftPackageReference;\n relativePath = '+json.dumps(sys.argv[2])+';\n};'
s,n=re.subn(pattern,lambda _:replacement,s,flags=re.S)
if n!=1: raise SystemExit('Expected exactly one remote Alamofire reference')
p.write_text(s)
PY
    project="$workspace/Caobao.xcodeproj"
else
    [ -f "$lock" ] || { echo "Missing shared SwiftPM lock: $lock"; exit 1; }
    project="$root/Caobao.xcodeproj"
fi
build_args=(-project "$project" -scheme Caobao -configuration Debug -destination "$destination" -derivedDataPath "$derived")
if [ -z "$local_package" ]; then
    build_args+=(-clonedSourcePackagesDirPath "$packages" -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution)
    lock_before="$(shasum -a 256 "$lock" | awk '{print $1}')"
    echo "Dependency mode: remote, shared lock required"
else
    echo "Dependency mode: explicit local override (not remote-package acceptance)"
fi
echo "Simulator signing: CODE_SIGNING_ALLOWED=$signing_allowed"
if xcodebuild "${build_args[@]}" CODE_SIGNING_ALLOWED="$signing_allowed" build > "$log" 2>&1; then
    if [ -z "$local_package" ]; then
        lock_after="$(shasum -a 256 "$lock" | awk '{print $1}')"
        [ "$lock_before" = "$lock_after" ] || { echo "Shared SwiftPM lock changed during build; review and resolve dependencies before retrying."; exit 1; }
    fi
    if [ "$signing_allowed" = "YES" ]; then
        app="$derived/Build/Products/Debug-iphonesimulator/Caobao.app"
        codesign --verify --deep --strict --verbose=2 "$app" >/dev/null
        echo "Code signing: verified"
        embedded_entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null || true)"
        if [[ "$embedded_entitlements" == *"com.apple.developer.applesignin"* ]]; then
            echo "Apple Sign In entitlement: present in simulator signature"
        else
            echo "Apple Sign In entitlement: absent in simulator signature; real-device archive signing still required"
        fi
        if [[ "$embedded_entitlements" == *"aps-environment"* ]]; then
            echo "APNs entitlement: present in simulator signature"
        else
            echo "APNs entitlement: absent in simulator signature; real-device archive signing still required"
        fi
    fi
    tail -5 "$log"
    echo "Application: $derived/Build/Products/Debug-iphonesimulator/Caobao.app"
else
    rg -n 'error:|BUILD FAILED|warning:' "$log" | head -60 || true
    tail -15 "$log"
    exit 1
fi
