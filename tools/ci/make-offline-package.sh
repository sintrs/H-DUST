#!/usr/bin/env bash
# 组装离线包：官方最新启动器 + 官方 nightly 游戏包，把游戏装成 developer- 版本。
#
# 为什么不需要编译：上游启动器自带单人离线能力（launcher/src/developer_offline.rs），
# 触发条件只有三条——版本目录名以 developer- 开头、目录里有 .installed、
# developer.json 里是 40 位十六进制 revision。官方 horizon-client 原生支持
# --developer-single-player（已实测 --launch-api 里列出该选项）。
#
# 用法:
#   bash make-offline-package.sh <launcher.tar.gz> <game.tar.gz> <commit> <输出目录>
set -euo pipefail

LAUNCHER_TGZ=${1:?用法: make-offline-package.sh <launcher.tar.gz> <game.tar.gz> <commit> <输出目录>}
GAME_TGZ=${2:?}
COMMIT=${3:?}
OUT=${4:-package}

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

echo "==> 确认官方 client 仍然支持离线单人"
CLIENT="$ROOT/data/versions/$TAG/horizon-client"
[[ -f "$CLIENT" ]] || { echo "错误：版本目录里没有 horizon-client" >&2; exit 1; }
chmod +x "$CLIENT"
if ! "$CLIENT" --launch-api 2>/dev/null | grep -q -- '--developer-single-player'; then
  echo "错误：这个 client 不再提供 --developer-single-player，离线方案失效" >&2
  exit 1
fi
echo "    OK：--developer-single-player 存在"

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
Launcher:   official horizon-launcher for this release (not rebuilt)

Run:        ./run-offline.sh

The first launch installs the game into the launcher data folder and selects it.
You still need Minecraft 26.3 assets once: either an installed Minecraft 26.3
(the launcher finds the official/Prism/MultiMC/Modrinth/ATLauncher folders) or
run:  ./run-offline.sh prepare --version $TAG

Offline play is single-player only; LAN and servers are refused by design.
EOF

ASSET="$OUT/$NAME-offline.tar.gz"
tar -czf "$ASSET" -C "$WORK" "$NAME"
echo "==> 打包完成：$ASSET（$(du -h "$ASSET" | cut -f1)）"
echo "    tag=$TAG  commit=$COMMIT"
