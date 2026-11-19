#!/usr/bin/env bash
# 在目标机（UOS 20 / 麒麟 V10 / 任何 glibc 2.28）上，把一份游戏文件夹装成启动器认的"已安装版本"。
#
# 启动器不联网也能用：它列出已安装版本时只扫 $DATA/versions/ 下的目录，
# 谁带 .installed 标记就算装好了（backend.rs: installed_in）。
# 所以离线安装 = 把文件夹拷进 versions/<tag>/ 再补一个空文件 .installed。
#
# 用法：
#   bash install-version-offline.sh <游戏文件夹> [tag]
#
#   <游戏文件夹>  解开的 horizon-linux-x86_64/，或任意含 horizon-client 的目录
#   [tag]         版本名，默认 nightly（启动器里显示的名字）
#
# 装完启动：
#   HORIZON_LAUNCHER_NO_SELF_UPDATE=1 horizon-launcher     # 不联网、不自我替换
set -euo pipefail

SRC=${1:?用法: install-version-offline.sh <游戏文件夹> [tag]}
TAG=${2:-nightly}

SRC=$(cd "$SRC" && pwd)

# 允许直接指到上一层：包解开后是 horizon-linux-x86_64/ 这一层
if [[ ! -f "$SRC/horizon-client" ]]; then
  inner=$(find "$SRC" -maxdepth 2 -type f -name horizon-client 2>/dev/null | head -1)
  if [[ -n "$inner" ]]; then
    SRC=$(dirname "$inner")
    echo "==> 自动进入子目录：$SRC"
  else
    echo "错误：$SRC 里找不到 horizon-client（给错目录了？）" >&2
    exit 1
  fi
fi

DATA=${HORIZON_LAUNCHER_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/horizon-launcher}
DEST="$DATA/versions/$TAG"

echo "==> 数据目录：$DATA"
echo "==> 目标版本：$DEST"

if [[ -d "$DEST" ]]; then
  OLD="$DEST.old-$(date +%Y%m%d-%H%M%S)"
  echo "  ! 已存在同名版本，先改名为 $(basename "$OLD")"
  mv "$DEST" "$OLD"
fi

mkdir -p "$DATA/versions"
# 不用 cp -a：U 盘（exFAT/NTFS）上保留属主和时间会失败，整个安装就断在这里
cp -R "$SRC/." "$DEST/"
# 用重定向而不是 touch：某些文件系统（U 盘/fuse）连改时间都不允许
: > "$DEST/.installed"

for b in horizon-client horizon-ctl horizon-server horizon-prepare; do
  [[ -f "$DEST/$b" ]] && chmod +x "$DEST/$b"
done

# 装完立刻验一遍：本机 glibc 能不能满足，缺哪个符号版本一眼看到
if command -v objdump >/dev/null 2>&1; then
  mine=$(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')
  echo
  echo "==> 校验（本机 glibc $mine）"
  for b in horizon-client horizon-ctl horizon-server horizon-prepare; do
    [[ -f "$DEST/$b" ]] || continue
    need=$(objdump -T "$DEST/$b" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1 | sed 's/^GLIBC_//')
    if [[ -z "$need" ]]; then
      echo "  ? $b：读不出符号版本"
    elif [[ "$(printf '%s\n%s\n' "$need" "$mine" | sort -V | tail -1)" == "$mine" ]]; then
      echo "  ✓ $b：需要 GLIBC_$need ≤ 本机 $mine"
    else
      echo "  ✗ $b：需要 GLIBC_$need > 本机 $mine，启动会报 version not found"
    fi
  done
fi

# 资源有没有准备过（准备过才有 .local/horizon-client/*/horizon-resources.json）
if compgen -G "$DEST/.local/horizon-client/*/horizon-resources.json" >/dev/null 2>&1; then
  echo "  ✓ 资源已准备（.local/horizon-client/…/horizon-resources.json）"
else
  echo "  · 资源尚未准备：第一次按「开始游戏」时启动器会就地导出（需要 Java 25 + 你自己的 26.3）"
  echo "    也可以手工执行： cd \"$DEST\" && ./horizon-prepare --prepare --server-jar /路径/26.3-server.jar"
fi

cat <<EOF

==> 装好了。启动方式二选一：

  A. 用启动器（推荐，能看到版本、世界、设置）
       HORIZON_LAUNCHER_NO_SELF_UPDATE=1 horizon-launcher

  B. 不用启动器，直接跑游戏
       cd "$DEST" && ./horizon-client

想换数据目录（比如放到移动硬盘）：
  export HORIZON_LAUNCHER_HOME=/media/u盘/horizon
EOF
