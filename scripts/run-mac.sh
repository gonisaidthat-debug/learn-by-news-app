#!/bin/zsh
# 맥에서 실행 ("My Mac (Designed for iPad)"). Xcode 없이 xcodebuild로 빌드해 Wrapper 구조로 감싼 뒤 연다.
# 사용: scripts/run-mac.sh [LBN_MOCK=1 등 환경변수는 --env 로 전달됨: scripts/run-mac.sh LBN_MOCK=1 LBN_ROUTE=notebook:a1]
set -e
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project LearnByNews.xcodeproj -scheme LearnByNews \
  -destination 'platform=macOS,variant=Designed for iPad' \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  ENABLE_DEBUG_DYLIB=NO build 2>&1 | grep -E 'error:|BUILD' | sort -u
APP="$PWD/build/DerivedData/Build/Products/Debug-iphoneos/LearnByNews.app"
W="$PWD/build/mac/LearnByNews.app"            # iOS 번들은 맥에서 Wrapper/ + WrappedBundle 구조로 감싸야 열린다
rm -rf "$W"; mkdir -p "$W/Wrapper"; cp -R "$APP" "$W/Wrapper/"; ln -s Wrapper/LearnByNews.app "$W/WrappedBundle"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$W"
pkill -f 'Wrapper/LearnByNews.app/LearnByNews' 2>/dev/null || true
ENVS=(); for kv in "$@"; do ENVS+=(--env "$kv"); done
open -n "${ENVS[@]}" "$W"
echo "열었다: $W"
