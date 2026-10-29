#!/bin/bash
# install-helper.sh — 以 root 身份运行（由 HDRSwitch 通过管理员授权调用）
#
# 安装两样东西：
#   1. /usr/local/libexec/hdrswitch-smbdump  —— 只读的 root 小工具
#   2. /etc/sudoers.d/hdrswitch              —— 允许当前用户免密执行「这一个」命令
#
# 目的：让 HDRSwitch 能知道「本机 SMB 共享此刻正在被读的是哪个视频文件」。
# 卸载：rm -f /usr/local/libexec/hdrswitch-smbdump /etc/sudoers.d/hdrswitch

set -e

TARGET=/usr/local/libexec/hdrswitch-smbdump
SUDOERS=/etc/sudoers.d/hdrswitch

if [ -z "$1" ] || [ ! -f "$1" ]; then
    echo "usage: install-helper.sh <path-to-binary> <user>" >&2
    exit 2
fi
if [ -z "$2" ]; then
    echo "usage: install-helper.sh <path-to-binary> <user>" >&2
    exit 2
fi

SRC="$1"
REAL_USER="$2"

mkdir -p /usr/local/libexec
cp -f "$SRC" "$TARGET"
chown root:wheel "$TARGET"
chmod 755 "$TARGET"

# sudoers：只放行这一条绝对路径的命令，不接受参数
printf '%s ALL=(root) NOPASSWD: %s\n' "$REAL_USER" "$TARGET" > "$SUDOERS"
chown root:wheel "$SUDOERS"
chmod 440 "$SUDOERS"

# 语法校验，坏了就撤回（否则 sudo 可能整体失效）
if ! /usr/sbin/visudo -c -f "$SUDOERS" >/dev/null 2>&1; then
    rm -f "$SUDOERS"
    echo "ERROR: sudoers 校验失败，已回滚" >&2
    exit 3
fi

echo "installed: $TARGET"
echo "sudoers:   $SUDOERS"
echo "--- 当前 smbd 打开的视频文件 ---"
"$TARGET" || true
