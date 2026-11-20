#!/usr/bin/env bash
# 组装离线包：离线启动器 + 官方 nightly 游戏包，把游戏装成 developer- 版本。
#
# 两部分来源分开：
#   - 启动器：默认用官方包里的二进制；给了第 5 个参数就用自编的（打了离线补丁）覆盖。
#   - 游戏包：官方 nightly，原样复制，不编译。
#
# 启动器补丁做三件事（见 patch_launcher_offline.py）：不注入 --developer-single-player、
# 离线默认开启、永不自我替换。于是**双击/菜单直接打开就是离线版**，不需要环境变量。
# client 走正常启动路径，单人、多人、LAN 全部可用，身份是 client 原生的 offline_uuid(--name)。
#
# 包里没有安装脚本：解压后直接打开 horizon-launcher，它自己把随包的 data/versions
# 装进启动器数据目录并选中（补丁里的 rust_offline_bootstrap），名字改同目录的
# offline-name.txt。
#
# 用法:
#   bash make-offline-package.sh <launcher.tar.gz> <game.tar.gz> <commit> <输出目录> [自编的 horizon-launcher]
set -euo pipefail

LAUNCHER_TGZ=${1:?用法: make-offline-package.sh <launcher.tar.gz> <game.tar.gz> <commit> <输出目录> [launcher 二进制]}
GAME_TGZ=${2:?}
COMMIT=${3:?}
OUT=${4:-package}
LAUNCHER_BIN=${5:-}

[[ -f "$LAUNCHER_TGZ" ]] || { echo "错误：找不到启动器包 $LAUNCHER_TGZ" >&2; exit 1; }
[[ -f "$GAME_TGZ" ]] || { echo "错误：找不到游戏包 $GAME_TGZ" >&2; exit 1; }
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "错误：commit 必须是 40 位十六进制" >&2; exit 1; }

SHORT=${COMMIT:0:7}
NAME=horizon-offline-linux-x86_64
TAG="developer-$SHORT"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/h-offline.XXXXXX")
# KEEP_WORK=1 保留临时目录（本地排查用；CI 里不要设，否则盘子会涨）
if [[ "${KEEP_WORK:-0}" != "1" ]]; then
  trap 'rm -rf "$WORK"' EXIT
else
  trap 'echo "临时目录保留在 $WORK"' EXIT
fi
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

ROOT="$WORK/$NAME"
mkdir -p "$ROOT/data/versions/$TAG"

echo "==> 解开官方启动器"
tar -xzf "$LAUNCHER_TGZ" -C "$ROOT" --touch --no-same-owner
[[ -f "$ROOT/horizon-launcher" ]] || { echo "错误：启动器包里没有 horizon-launcher" >&2; exit 1; }
chmod +x "$ROOT/horizon-launcher"

if [[ -n "$LAUNCHER_BIN" ]]; then
  [[ -x "$LAUNCHER_BIN" ]] || { echo "错误：找不到自编的启动器 $LAUNCHER_BIN" >&2; exit 1; }
  install -Dm755 "$LAUNCHER_BIN" "$ROOT/horizon-launcher"
  echo "==> 已用自编的离线启动器覆盖官方二进制"
fi

echo "==> 解开官方游戏包"
mkdir -p "$WORK/game"
tar -xzf "$GAME_TGZ" -C "$WORK/game" --touch --no-same-owner 2>/dev/null || true
GAME_DIR=$(find "$WORK/game" -maxdepth 2 -type f -name 'horizon-client' | head -1)
[[ -n "$GAME_DIR" ]] || { echo "错误：游戏包里没有 horizon-client" >&2; exit 1; }
GAME_DIR=$(dirname "$GAME_DIR")

echo "==> 把游戏装成 $TAG"
# 用 tar 管道复制，解包带 -m（不还原 mtime）：有些文件系统不允许改时间戳
(cd "$GAME_DIR" && tar -cf - .) | (cd "$ROOT/data/versions/$TAG" && tar -xmf -)

# 上游 developer_install::is_developer 只看目录名前缀，配合这两个文件即可放行。
: > "$ROOT/data/versions/$TAG/.installed"
printf '{"revision":"%s"}\n' "$COMMIT" > "$ROOT/data/versions/$TAG/developer.json"

echo "==> 检查 client 声明的离线能力"
CLIENT="$ROOT/data/versions/$TAG/horizon-client"
[[ -f "$CLIENT" ]] || { echo "错误：版本目录里没有 horizon-client" >&2; exit 1; }
chmod +x "$CLIENT"
if "$CLIENT" --launch-api 2>/dev/null | grep -q -- '--developer-single-player'; then
  echo "    client 仍声明 --developer-single-player（本方案不依赖它）"
else
  echo "    注意：client 不再声明该选项；本方案不依赖它，继续"
fi

# 离线名：改这一行就行（3-16 位字母/数字/下划线）。启动器读它，用 --name 传给 client。
printf 'Player\n' > "$ROOT/offline-name.txt"

cat > "$ROOT/PLAY-OFFLINE.txt" <<EOF
Horizon offline package
=======================

Game build: upstream nightly $SHORT (copied verbatim, not rebuilt)
Launcher:   built from the same upstream source, offline patch applied
            (offline by default, multiplayer/LAN unlocked, never self-updates)

How to play
-----------
1. Open ./horizon-launcher (double-click it).
   The first start copies the bundled game build into the launcher data folder,
   selects it, and adds the launcher to the applications menu -- after that just
   click the icon.
2. Change your name in offline-name.txt next to the launcher (one line, 3-16
   letters, digits or _), then start it again. That name is your offline
   identity: the game plays as its offline UUID.
3. First time only, it needs Minecraft 26.3 assets: an installed Minecraft 26.3
   is found automatically (official / Prism / MultiMC / Modrinth / ATLauncher),
   or run
       ./horizon-launcher prepare --version $TAG

No Microsoft account is needed and no account session is read.
Single-player, multiplayer and LAN all work. Servers that require a real
Minecraft account (online-mode=true) will still reject offline identities.
EOF

ASSET="$OUT/$NAME-offline.tar.gz"
tar -czf "$ASSET" -C "$WORK" "$NAME"
echo "==> 打包完成：$ASSET（$(du -h "$ASSET" | cut -f1)）"
echo "    tag=$TAG  commit=$COMMIT"
