#!/usr/bin/env bash
# 把自编（glibc 2.28）的二进制换进官方 Linux 包，并逐个校验符号版本。
#
# 为什么要换四个而不是一个：
#   官方包里 horizon-client / horizon-ctl / horizon-server / horizon-prepare 全部
#   在 ubuntu-22.04 上编（需要 GLIBC_2.34~2.35），在 glibc 2.28 上**一个都起不来**。
#   启动器只换掉 horizon-client 不够：它在资源准备阶段可能去执行包里自带的
#   horizon-prepare，LAN 联机会用 horizon-server。
#
# 用法：
#   bash swap-228-package.sh <官方包解压目录> <自编产物目录> [最高glibc版本]
#
# 例：
#   tar -xzf horizon-linux-x86_64.tar.gz            # 得到 horizon-linux-x86_64/
#   bash tools/ci/build-glibc228.sh . dist client   # 编出 dist/horizon-client
#   bash swap-228-package.sh horizon-linux-x86_64 dist
#
# 原文件会备份成 <名字>.orig-235（只备份第一次，重复运行不会覆盖备份）。
set -euo pipefail

PKG=${1:?用法: swap-228-package.sh <官方包目录> <自编产物目录> [最高glibc版本]}
DIST=${2:?用法: swap-228-package.sh <官方包目录> <自编产物目录> [最高glibc版本]}
MAX=${3:-2.28}

HERE=$(cd "$(dirname "$0")" && pwd)
PKG=$(cd "$PKG" && pwd)
DIST=$(cd "$DIST" && pwd)

command -v objdump >/dev/null 2>&1 || { echo "错误：需要 objdump（binutils）" >&2; exit 1; }

maxglibc() { objdump -T "$1" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1 | sed 's/^GLIBC_//'; }

echo "==> 官方包：$PKG"
echo "==> 自编产物：$DIST"
echo "==> 允许的最高 glibc：$MAX"
echo

SWAPPED=0
MISSING=0
FAILED=0

for bin in horizon-client horizon-ctl horizon-server horizon-prepare horizon-launcher; do
  new="$DIST/$bin"
  old="$PKG/$bin"

  if [[ ! -f "$new" ]]; then
    # 没有这一份不算错：离线单人只需要 client（launcher 另放在别处）
    [[ -f "$old" ]] && echo "  · $bin：未提供自编版本，包内仍是官方的 $(maxglibc "$old")"
    continue
  fi

  v=$(maxglibc "$new")
  if [[ -z "$v" ]]; then
    echo "  ✗ $bin：读不出符号版本（不是 ELF 或已 strip 过头？）" >&2
    FAILED=$((FAILED + 1))
    continue
  fi

  # 版本比较：仅当自编版高于上限时拒绝，避免把 2.35 的产物换进去伪装成修好了
  if [[ "$(printf '%s\n%s\n' "$v" "$MAX" | sort -V | tail -1)" != "$MAX" ]]; then
    echo "  ✗ $bin：最高 GLIBC_$v > $MAX，拒绝替换" >&2
    FAILED=$((FAILED + 1))
    continue
  fi

  if [[ -f "$old" ]]; then
    # 不用 cp -p：容器/跨文件系统的 mtime 保留会失败
    [[ -f "$old.orig-235" ]] || cp "$old" "$old.orig-235"
    was=$(maxglibc "$old")
  else
    was="(包里原本没有)"
    MISSING=$((MISSING + 1))
  fi

  install -m755 "$new" "$old"
  echo "  ✓ $bin：$was → GLIBC_$v"
  SWAPPED=$((SWAPPED + 1))
done

echo
echo "==> 换完后再扫一遍整包，确认没有漏下的 2.3x 二进制"
LEFTOVER=0
# 不用进程替换：部分最小化环境没有 /dev/fd
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
find "$PKG" -maxdepth 2 -type f -perm -u+x ! -name '*.orig-235' > "$LIST" 2>/dev/null || true
while IFS= read -r f; do
  v=$(maxglibc "$f")
  [[ -z "$v" ]] && continue
  if [[ "$(printf '%s\n%s\n' "$v" "$MAX" | sort -V | tail -1)" != "$MAX" ]]; then
    echo "  ! $(basename "$f") 仍需要 GLIBC_$v（$f）"
    LEFTOVER=$((LEFTOVER + 1))
  fi
done < "$LIST"

echo
if [[ $FAILED -gt 0 ]]; then
  echo "结果：失败 —— $FAILED 个二进制被拒（原因见上）。" >&2
  exit 1
fi
if [[ $LEFTOVER -gt 0 ]]; then
  echo "结果：还有 $LEFTOVER 个可执行文件需要 GLIBC_$MAX 以上，其中若包含 client/prepare，游戏仍会起不来。"
  exit 2
fi
echo "结果：通过 —— 已替换 $SWAPPED 个，整包所有可执行文件都在 glibc $MAX 以内。"
echo "原文件备份为 *.orig-235，想回退就换回来。"
