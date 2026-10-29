#!/bin/bash
# 编译 HDRSwitch.app
set -euo pipefail
cd "$(dirname "$0")"

APP="build/HDRSwitch.app"   # 放进 build/：该目录标了 .metadata_never_index，不会被 Launchpad 收成重复图标
echo "==> 编译中…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -swift-version 5 -O \
    -target arm64-apple-macos13.0 \
    -o "$APP/Contents/MacOS/HDRSwitch" \
    Sources/main.swift Sources/Detect.swift Sources/AutoHDR.swift Sources/WebProbe.swift \
    -framework Cocoa -framework Carbon -framework ServiceManagement \
    -framework AVFoundation -framework CoreMedia -framework IOKit

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> 签名（ad-hoc）"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "==> 完成: $(pwd)/$APP"
echo
echo "双击 $APP 即可，图标会出现在菜单栏右上角。"
echo "想放进 /Applications 就执行: cp -R $APP /Applications/"
