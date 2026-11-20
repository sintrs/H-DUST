#!/usr/bin/env bash
# 组装离线包：自编的离线启动器 + 官方 nightly 游戏包（原样复制，不编译）。
#
# 与 gerdaroot 那套同源：离线账号体系（离线名、无拥有者可玩）是**源码级移植**的，
# 补丁见 tools/ci/offline-port.patch，不是靠环境变量或开发者版目录名。
# 因此版本目录就是普通名字（nightly-<date>-<sha>），启动器按正常版本对待它。
#
# 包里没有任何脚本：解压后直接打开 horizon-launcher，它自己把随包的 data/versions
# 装进启动器数据目录并选中（launcher/src/horizon_bundle.rs）。离线名在启动器的
# 设置 → 账号页里改，也可以 `horizon-launcher account offline NAME`。
#
# 用法:
#   bash make-offline-package.sh <launcher.tar.gz> <game.tar.gz> <commit> <输出目录> <自编 launcher> <版本 tag>
set -euo pipefail

LAUNCHER_TGZ=${1:?用法: make-offline-package.sh <launcher.tar.gz> <game.tar.gz> <commit> <输出目录> <launcher 二进制> <版本 tag>}
GAME_TGZ=${2:?}
COMMIT=${3:?}
OUT=${4:-package}
LAUNCHER_BIN=${5:?}
TAG=${6:?}

[[ -f "$LAUNCHER_TGZ" ]] || { echo "错误：找不到启动器包 $LAUNCHER_TGZ" >&2; exit 1; }
[[ -f "$GAME_TGZ" ]] || { echo "错误：找不到游戏包 $GAME_TGZ" >&2; exit 1; }
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "错误：commit 必须是 40 位十六进制" >&2; exit 1; }
[[ -x "$LAUNCHER_BIN" ]] || { echo "错误：找不到自编的启动器 $LAUNCHER_BIN" >&2; exit 1; }
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "错误：版本 tag 含非法字符：$TAG" >&2; exit 1; }

SHORT=${COMMIT:0:7}
NAME=horizon-offline-linux-x86_64

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
VERSIONS="$ROOT/data/versions/$TAG"
mkdir -p "$VERSIONS"

echo "==> 解开官方启动器包（只取随包的图标与 LICENSE）"
mkdir -p "$WORK/launcher-pkg"
tar -xzf "$LAUNCHER_TGZ" -C "$WORK/launcher-pkg" --touch --no-same-owner
# 官方包里除二进制外还有 desktop 文件、图标等：一并留用，二进制换成自编的。
if [[ -f "$WORK/launcher-pkg/horizon-launcher" ]]; then
  (cd "$WORK/launcher-pkg" && tar -cf - .) | (cd "$ROOT" && tar -xmf -)
fi
install -Dm755 "$LAUNCHER_BIN" "$ROOT/horizon-launcher"
echo "==> 已放入自编的离线启动器"

echo "==> 解开官方游戏包"
mkdir -p "$WORK/game"
tar -xzf "$GAME_TGZ" -C "$WORK/game" --touch --no-same-owner 2>/dev/null || true
GAME_DIR=$(find "$WORK/game" -maxdepth 2 -type f -name 'horizon-client' | head -1)
[[ -n "$GAME_DIR" ]] || { echo "错误：游戏包里没有 horizon-client" >&2; exit 1; }
GAME_DIR=$(dirname "$GAME_DIR")

echo "==> 把游戏装成 $TAG"
# tar 管道复制，解包带 -m（不还原 mtime）：有些文件系统不允许改时间戳
(cd "$GAME_DIR" && tar -cf - .) | (cd "$VERSIONS" && tar -xmf -)

# 普通版本目录：启动器靠 .installed 认出"已安装"，靠目录名当 tag。
: > "$VERSIONS/.installed"

CLIENT="$VERSIONS/horizon-client"
[[ -f "$CLIENT" ]] || { echo "错误：版本目录里没有 horizon-client" >&2; exit 1; }
chmod +x "$CLIENT"
for extra in horizon-ctl horizon-prepare horizon-server; do
  [[ -f "$VERSIONS/$extra" ]] && chmod +x "$VERSIONS/$extra"
done

cat > "$ROOT/PLAY-OFFLINE.txt" <<EOF
Horizon offline package
=======================

Game build: upstream nightly $SHORT (copied verbatim, not rebuilt)
Launcher:   built from the same upstream source with the offline account patch
            (offline names, no account needed, multiplayer and LAN work, no self-update)

How to play
-----------
1. Open ./horizon-launcher (double-click it).
   The first start copies the bundled game build into the launcher data folder and
   selects it -- after that just click the launcher's icon.
2. Your offline name: Settings -> Account -> "Play offline", type a name (3 to 16
   letters, digits or _) and press Enter. The game then plays as that name's
   offline UUID. From a terminal, the same:
       ./horizon-launcher account offline YourName
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
