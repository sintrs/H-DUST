#!/usr/bin/env bash
# 把自编的二进制装进官方 nightly 包，产出可以直接拷走的 tar.gz。
#
# 用法:
#   bash make-linux-package.sh <dist 目录> <输出目录> [骨架包路径或 URL]
#
# 为什么还要骨架包：官方包里除了几个二进制，还有 wasm 标准库、exporters、crates
# 与清单文件。那些和编译器无关，自己重造既没必要也造不出来（exporters 要用 Mojang
# 的 jar 编译）。所以做法是「拿官方包当骨架，只换掉我们编的那几个文件」。
#
# 与旧版（UOS 2.28）的区别：不再要求 GLIBC <= 2.28，只如实报告每个二进制的上限。
set -uo pipefail

DIST=${1:?用法: make-linux-package.sh <dist目录> <输出目录> [骨架包路径或URL]}
OUT=${2:-package}
SKEL=${3:-}

DIST=$(cd "$DIST" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

DIRNAME=horizon-linux-x86_64

if [[ -n "$SKEL" ]]; then
  case "$SKEL" in
    http://*|https://*)
      echo "==> 下载骨架包：$SKEL"
      curl -fL --retry 3 -m 900 -o "$WORK/skeleton.tar.gz" "$SKEL" || { echo "错误：骨架包下载失败" >&2; exit 1; }
      SKEL="$WORK/skeleton.tar.gz"
      ;;
  esac
  [[ -f "$SKEL" ]] || { echo "错误：找不到骨架包 $SKEL" >&2; exit 1; }
  echo "==> 解开骨架包"
  # --touch：不还原 tar 里存的 mtime。某些文件系统不允许改时间戳，tar 会刷一屏
  # "无法 utime" 并以错误状态退出 —— 踩过。
  tar -xzf "$SKEL" -C "$WORK" --touch --no-same-owner || true
  ROOT=$(find "$WORK" -maxdepth 2 -type d -name "$DIRNAME" | head -1)
  [[ -n "$ROOT" ]] || { echo "错误：骨架包里没有 $DIRNAME 目录" >&2; exit 1; }
else
  echo "!! 没给骨架包：只打包 dist 里的文件，包内可能缺 exporters / wasm 标准库"
  ROOT="$WORK/$DIRNAME"
  mkdir -p "$ROOT"
fi

echo
echo "==> 用 dist 里的文件替换骨架包内容"
REPLACED=0
for f in "$DIST"/*; do
  [[ -f "$f" ]] || continue
  name=$(basename "$f")
  case "$name" in
    horizon-client|horizon-ctl|horizon-prepare|horizon-server|horizon-launcher|horizon-wasm-std.wasm)
      was=""
      if [[ -f "$ROOT/$name" ]]; then was="（覆盖包内 $(du -h "$ROOT/$name" | cut -f1) 的旧文件）"; fi
      install -Dm755 "$f" "$ROOT/$name"
      echo "  ✓ $name$was"
      REPLACED=$((REPLACED + 1))
      ;;
  esac
done

if [[ $REPLACED -eq 0 ]]; then
  echo "错误：dist 里没有可替换的文件" >&2
  exit 1
fi

echo
echo "==> 包内每个 ELF 的 glibc 地板（这是它能在多老的系统上跑）"
find "$ROOT" -maxdepth 3 -type f -perm -u+x > "$WORK/exes"
while IFS= read -r f; do
  readelf -h "$f" >/dev/null 2>&1 || continue
  v=$(objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)
  [[ -z "$v" ]] && continue
  printf '  %-32s %s\n' "$(basename "$f")" "$v"
done < "$WORK/exes"

echo
ASSET=horizon-linux-x86_64-offline.tar.gz
tar -czf "$OUT/$ASSET" -C "$(dirname "$ROOT")" "$(basename "$ROOT")"
echo "==> 打包完成：$OUT/$ASSET（$(du -h "$OUT/$ASSET" | cut -f1)）"
echo
echo "装到启动器认的版本目录："
echo "  tar -xzf $ASSET"
echo "  bash tools/ci/install-version-offline.sh ./$(basename "$ROOT") nightly"
