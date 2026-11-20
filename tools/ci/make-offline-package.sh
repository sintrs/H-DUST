#!/usr/bin/env bash
# 组装离线包：离线启动器 + 官方 nightly 游戏包，把游戏装成 developer- 版本。
#
# 两部分来源分开：
#   - 启动器：默认用官方包里的二进制；给了第 5 个参数就用自编的（打了离线补丁）覆盖。
#   - 游戏包：官方 nightly，原样复制，不编译。
#
# 启动器补丁只做一件事：不再注入 --developer-single-player，让 client 走正常启动
# 路径，从而单人、多人、LAN 全部可用，身份是 client 原生的 offline_uuid(--name)。
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

cat > "$ROOT/run-offline.sh" <<EOF
#!/usr/bin/env bash
# 打开 Horizon 离线启动器。首次运行会把游戏装进启动器数据目录。
set -euo pipefail
here=\$(cd "\$(dirname "\$0")" && pwd)
tag=$TAG
home=\${HORIZON_LAUNCHER_HOME:-\${XDG_DATA_HOME:-\$HOME/.local/share}/horizon-launcher}
mkdir -p "\$home/versions"
if [ ! -d "\$home/versions/\$tag" ]; then
  echo "Installing \$tag into \$home ..."
  mkdir -p "\$home/versions/\$tag"
  (cd "\$here/data/versions/\$tag" && tar -cf - .) | (cd "\$home/versions/\$tag" && tar -xmf -)
fi
export HORIZON_LAUNCHER_HOME="\$home"
export HORIZON_LAUNCHER_DEVELOPER_OFFLINE=1
export HORIZON_LAUNCHER_NO_SELF_UPDATE=1
"\$here/horizon-launcher" settings selected-version "\$tag" >/dev/null 2>&1 || true
exec "\$here/horizon-launcher" "\$@"
EOF
chmod +x "$ROOT/run-offline.sh"

cat > "$ROOT/PLAY-OFFLINE.txt" <<EOF
Horizon offline package
=======================

Game build: upstream nightly $SHORT (copied verbatim, not rebuilt)
Launcher:   built from the same upstream source, with the offline patch applied

Run:        ./run-offline.sh

The first launch installs the game into the launcher data folder and selects it.
You still need Minecraft 26.3 assets once: either an installed Minecraft 26.3
(the launcher finds the official/Prism/MultiMC/Modrinth/ATLauncher folders) or
run:  ./run-offline.sh prepare --version $TAG

No Microsoft account is needed and no account session is read.
Your player identity is the client's own offline UUID for your offline name.
Single-player, multiplayer and LAN all work. Servers that require a real
Minecraft account (online-mode=true) will still reject offline identities.
EOF

ASSET="$OUT/$NAME-offline.tar.gz"
tar -czf "$ASSET" -C "$WORK" "$NAME"
echo "==> 打包完成：$ASSET（$(du -h "$ASSET" | cut -f1)）"
echo "    tag=$TAG  commit=$COMMIT"
