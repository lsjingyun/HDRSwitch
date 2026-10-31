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

# 签名。优先用本机的自签名证书 —— 它的 designated requirement 只绑
# 「bundle id + 证书指纹」，重编译后 cdhash 变了也仍然算同一个 App，
# 于是「完全磁盘访问权限」这类授权不会每次编译后失效。
# ad-hoc 签名的 requirement 直接绑 cdhash，改一行代码系统就当成新 App，
# 授权全部重问一遍（之前反复弹「访问可移除宗卷」就是这么来的）。
SIGN_ID="HDRSwitch Self Signed"
SIGN_KC="$HOME/Library/Keychains/hdrswitch.keychain-db"
# 这把钥匙串是专门给签名用的（证书是自签的，私钥只在本机）。
# 独立钥匙串默认会自己上锁，锁住之后 codesign 报 errSecInternalComponent ——
# 看起来像「证书丢了」，其实只是没解锁。密码固定，解锁一次就行；
# 想换密码就改这里，并同步重建一次钥匙串。
SIGN_PW="hdrswitch-local"

if [ -f "$SIGN_KC" ]; then
    security unlock-keychain -p "$SIGN_PW" "$SIGN_KC" 2>/dev/null || true
fi

if security find-certificate -c "$SIGN_ID" "$SIGN_KC" >/dev/null 2>&1; then
    echo "==> 签名（${SIGN_ID}）"
    codesign --force --keychain "$SIGN_KC" --sign "$SIGN_ID" "$APP"
else
    echo "==> 签名（ad-hoc）"
    codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true
fi

echo "==> 完成: $(pwd)/$APP"
echo
echo "双击 $APP 即可，图标会出现在菜单栏右上角。"
echo "想放进 /Applications 就执行: cp -R $APP /Applications/"
