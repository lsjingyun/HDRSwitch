#!/bin/bash
# 双击这个文件即可安装「共享片源识别」辅助工具。
#
# 它会做两件事（需要输入一次管理员密码）：
#   1. 装一个只读小工具 /usr/local/libexec/hdrswitch-smbdump
#      唯一功能：列出 SMB 服务当前打开的视频文件
#   2. 在 /etc/sudoers.d 里放行「仅这一条命令」，让 HDRSwitch 能免密调用它
#
# 卸载：sudo rm -f /usr/local/libexec/hdrswitch-smbdump /etc/sudoers.d/hdrswitch

cd "$(dirname "$0")" || exit 1

echo "======================================================"
echo "  HDRSwitch · 共享片源识别辅助工具"
echo "======================================================"
echo ""

BIN="$(pwd)/build/hdrswitch-smbdump"
HELPER_SCRIPT="$(pwd)/Tools/install-helper.sh"

if [ ! -f "$BIN" ]; then
    echo "✗ 找不到可执行文件：$BIN"
    echo "  请先在项目目录运行 ./build.sh"
    echo ""
    read -n 1 -s -r -p "按任意键关闭…"
    exit 1
fi
if [ ! -f "$HELPER_SCRIPT" ]; then
    echo "✗ 找不到安装脚本：$HELPER_SCRIPT"
    read -n 1 -s -r -p "按任意键关闭…"
    exit 1
fi

echo "接下来会要求输入管理员密码（只用于写入上述两个位置）。"
echo ""

sudo /bin/bash "$HELPER_SCRIPT" "$BIN" "$(id -un)"
RC=$?

echo ""
if [ $RC -ne 0 ]; then
    echo "✗ 安装失败（退出码 $RC）"
    read -n 1 -s -r -p "按任意键关闭…"
    exit $RC
fi

echo "✓ 安装完成。"
echo ""
echo "现在请到 Infuse 里播放共享中的视频，然后回到 HDRSwitch，"
echo "菜单里的「共享片源识别」应显示为已就绪。"
echo ""
echo "自测命令："
echo "  sudo -n /usr/local/libexec/hdrswitch-smbdump"
echo ""
read -n 1 -s -r -p "按任意键关闭…"
