#!/bin/bash
# 把 HDRSwitch.app 打包成 DMG
#
# 产物：build/HDRSwitch-<版本>.dmg
# 内含：HDRSwitch.app / Applications 快捷方式 / 安装说明 / 可选组件（共享片源识别）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="HDRSwitch"
APP_PATH="build/${APP_NAME}.app"

# ── 版本号（取自 Info.plist）—— 打包产物一律带版本号，免得几个包分不清
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
VOL_NAME="${APP_NAME} ${VERSION}"
DMG="build/${APP_NAME}-${VERSION}.dmg"
STAGE="build/dmg"

echo "==> 0/5 版本 ${VERSION} → ${DMG}"

echo "==> 1/5 编译"
./build.sh >/dev/null

if [ ! -d "$APP_PATH" ]; then
    echo "✗ 编译失败：找不到 ${APP_NAME}.app"
    exit 1
fi

# ── 可选：编一个通用二进制（Intel + Apple Silicon）。
#    只为分发方便，失败不影响主流程 —— 回退到本机架构。
echo "==> 2/5 通用二进制（可选）"
UNI_DIR="build/universal"
UNI_BIN="$UNI_DIR/${APP_NAME}"
rm -rf "$UNI_DIR" && mkdir -p "$UNI_DIR"
SRCS="Sources/main.swift Sources/Detect.swift Sources/AutoHDR.swift Sources/WebProbe.swift"
FRAMEWORKS="-framework Cocoa -framework Carbon -framework ServiceManagement -framework AVFoundation -framework CoreMedia -framework IOKit"
ok_uni=1
for ARCH in arm64 x86_64; do
    if ! swiftc -swift-version 5 -O -target "${ARCH}-apple-macos13.0" $FRAMEWORKS \
         -o "$UNI_DIR/$ARCH" $SRCS >/dev/null 2>&1; then
        ok_uni=0
        echo "    ${ARCH} 编译失败，保持单架构"
        break
    fi
done
if [ "$ok_uni" = "1" ]; then
    lipo -create -output "$UNI_BIN" "$UNI_DIR/arm64" "$UNI_DIR/x86_64" 2>/dev/null && \
        cp "$UNI_BIN" "$APP_PATH/Contents/MacOS/${APP_NAME}" && \
        codesign --force --sign - --timestamp=none "$APP_PATH" >/dev/null 2>&1 && \
        echo "    已合成为通用二进制：$(lipo -archs "$APP_PATH/Contents/MacOS/${APP_NAME}")"
else
    echo "    使用本机架构：$(lipo -archs "$APP_PATH/Contents/MacOS/${APP_NAME}")"
fi

echo "==> 3/5 准备内容"
rm -rf "$STAGE"
mkdir -p "$STAGE"
touch build/.metadata_never_index
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 共享片源识别（可选）：把特权小工具和安装脚本一并放进来，
# 这样换台机器也能装，不必回到项目目录。
if [ -f build/hdrswitch-smbdump ] && [ -f Tools/install-helper.sh ]; then
    OPT="$STAGE/可选组件（共享识别）"
    mkdir -p "$OPT"
    cp build/hdrswitch-smbdump "$OPT/"
    cp Tools/install-helper.sh "$OPT/"
    cat > "$OPT/安装共享识别.command" <<'EOS'
#!/bin/bash
# 双击运行：安装「共享片源识别」辅助工具（会要求输入一次管理员密码）
#
# 安装两样东西：
#   /usr/local/libexec/hdrswitch-smbdump  只读小工具，列出 SMB 服务正在读的视频
#   /etc/sudoers.d/hdrswitch              只放行上面这一条命令，免密调用
# 卸载：sudo rm -f /usr/local/libexec/hdrswitch-smbdump /etc/sudoers.d/hdrswitch
cd "$(dirname "$0")" || exit 1

BIN="./hdrswitch-smbdump"
HELPER="./install-helper.sh"

echo "======================================================"
echo "  HDRSwitch · 共享片源识别辅助工具"
echo "======================================================"
echo ""

if [ ! -f "$BIN" ] || [ ! -f "$HELPER" ]; then
    echo "✗ 找不到 hdrswitch-smbdump 或 install-helper.sh"
    echo "  请把这三个文件放在同一个文件夹里再运行。"
    read -n 1 -s -r -p "按任意键关闭…"
    exit 1
fi

echo "接下来会要求输入管理员密码（只写入上面那两个位置）。"
echo ""

sudo /bin/bash "$HELPER" "$(pwd)/$BIN" "$(id -un)"
RC=$?
echo ""
if [ $RC -ne 0 ]; then
    echo "✗ 安装失败（退出码 $RC）"
    read -n 1 -s -r -p "按任意键关闭…"
    exit $RC
fi

echo "✓ 安装完成。"
echo ""
echo "接着到 Infuse 里播放共享中的视频，回到 HDRSwitch 菜单，"
echo "「共享片源识别」应显示为已就绪。"
echo ""
read -n 1 -s -r -p "按任意键关闭…"
EOS
    chmod +x "$OPT/安装共享识别.command"
    echo "    已附带可选组件"
fi

# 安装说明
cat > "$STAGE/安装说明.txt" <<EOT
HDRSwitch ${VERSION}
在 SDR 与 HDR 之间自动切换显示器，给 Mac 上播 HDR 片源的播放器和浏览器用。

完整说明见同目录的「使用说明.html」，双击用浏览器打开（也可以 ⌘P 存成 PDF）。
下面是装完就该知道的几件事。

安装
  把左边（或左上）的 HDRSwitch 拖到 Applications 文件夹上，然后从
  启动台 / 应用程序 里打开它。图标会出现在屏幕右上角的菜单栏里，
  没有窗口，也没有 Dock 图标。

第一次打开被系统拦住
  这个 App 没有做 Apple 公证（ad-hoc 签名），macOS 会提示「无法验证开发者」。
  解决办法：在「应用程序」里按住 Control 点它 → 打开 → 再点一次「打开」。
  或者：系统设置 → 隐私与安全性 → 往下滚到「仍要打开」。

要授权的两项
  1. 自动化（Apple 事件）—— 用来读浏览器里的实测画质，只在开启
     「网页视频按实测画质切换」时用到。第一次会弹窗，允许即可。
  2. 共享片源识别 —— 想让它认出 Infuse 通过 SMB 播的片源时，
     双击「可选组件（共享识别）」里的「安装共享识别.command」，
     输一次管理员密码。不装也能用，只是共享片源只能靠播放器判断。
     替代方案：给 HDRSwitch 开「完全磁盘访问权限」也能读到。

卸载
  把 App 拖到废纸篓。若装过辅助工具：
  sudo rm -f /usr/local/libexec/hdrswitch-smbdump /etc/sudoers.d/hdrswitch

说明
  它用的是 macOS 私有显示接口（SkyLight），系统大版本升级后可能失效，
  到时候重编一次通常就能修好。
EOT

# 使用说明（完整文档，跟着安装包一起走）
if [ -f docs/index.html ]; then
    cp docs/index.html "$STAGE/使用说明.html"
fi

# 许可证（MIT，分发时随包带上）
[ -f LICENSE ] && cp LICENSE "$STAGE/LICENSE.txt"

echo "==> 4/5 生成磁盘映像"
rm -f "$DMG"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO \
    -fs HFS+ -quiet "$DMG" 2>&1 | grep -v "deprecated" || true

if [ ! -f "$DMG" ]; then
    echo "✗ DMG 生成失败"
    exit 1
fi

# 校验：解压整卷数据做一次完整性检查（不挂载，避免需要特权）
echo "==> 5/5 校验磁盘映像"
hdiutil verify "$DMG" -quiet 2>&1 | grep -v deprecated || true

echo ""
echo "==> 完成"
ls -lh "$DMG" | awk '{print "    " $9 "  " $5}'
echo "    架构: $(lipo -archs "$APP_PATH/Contents/MacOS/${APP_NAME}")"
echo "    签名: $(codesign -dv "$APP_PATH" 2>&1 | grep -m1 'Signature' || echo 'ad-hoc')"
echo "    内容:"
(cd "$STAGE" && find . -maxdepth 2 -not -path "./HDRSwitch.app/*" | sed 's|^\./|      |' | sort)
