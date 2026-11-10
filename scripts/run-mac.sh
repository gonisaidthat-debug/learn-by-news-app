#!/bin/zsh
# 맥(Catalyst) 빌드 → 그대로 open. 사용: scripts/run-mac.sh
set -e
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project LearnByNews.xcodeproj -scheme LearnByNews \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration build 2>&1 | grep -E 'error:|BUILD' | sort -u
open -n "$PWD/build/DerivedData/Build/Products/Debug-maccatalyst/LearnByNews.app"
