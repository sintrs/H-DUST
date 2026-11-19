#!/usr/bin/env bash
# 把自编的（glibc 2.28）二进制装进官方发布包，产出可以直接拷到 UOS 20 上的 tar.gz。
#
# 用法:
#   bash make-uos-package.sh <dist 目录> <输出目录> [骨架包路径或 URL]
#
# 为什么要骨架包：官方包里除了四个二进制，还有 wasm 标准库、exporters、以及启动器读取的清单文件。
# 那些东西和 glibc 无关，自己重造既没必要也造不出来（exporters 要用 Mojang 的 jar 编译）。
# 所以做法是「拿官方包当骨架，只换掉受 glibc 影响的二进制」——离线分支的 CI 也是这么干的。
#
# 不给骨架包时只打包 dist 里的文件（能跑，但可能缺 exporters）。
set -uo pipefail

DIST=${1:?用法: make-uos-package.sh <dist目录> <输出目录> [骨架包路径或URL]}
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
  # --touch：不还原 tar 里存的 mtime。某些文件系统（U 盘 exFAT、fuse、部分 tmpfs）不允许
  # 改时间戳，tar 会刷一屏 "无法 utime" 然后以错误状态退出 —— 踩过。
  tar -xzf "$SKEL" -C "$WORK" --touch --no-same-owner || true
  # 包里目录名可能就是 horizon-linux-x86_64，也可能多一层，统一找
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
  # 只处理包内已有的同名文件，或者明确的二进制/清单里该有的文件
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
echo "==> 校验包内每个 ELF 的 glibc 上限（超过 2.28 的会被点名）"
BAD=0
# 用临时文件收集，避开进程替换（没有 /dev/fd 的精简环境会崩）
find "$ROOT" -maxdepth 3 -type f -perm -u+x > "$WORK/exes"
while IFS= read -r f; do
  # 用 readelf 判 ELF（比 head -c 4 | grep 二进制安全），不是 ELF 就跳过
  readelf -h "$f" >/dev/null 2>&1 || continue
  v=$(objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)
  [[ -z "$v" ]] && continue
  ver=${v#GLIBC_}
  if [[ "$(printf '%s\n2.28\n' "$ver" | sort -V | tail -1)" == "2.28" ]]; then
    echo "  ✓ $(basename "$f")  GLIBC_$ver"
  else
    echo "  ✗ $(basename "$f")  GLIBC_$ver  > 2.28 —— UOS 20 加载不了"
    BAD=$((BAD + 1))
  fi
done < "$WORK/exes"

echo
ASSET=horizon-linux-x86_64-uos20.tar.gz
tar -czf "$OUT/$ASSET" -C "$(dirname "$ROOT")" "$(basename "$ROOT")"
echo "==> 打包完成：$OUT/$ASSET（$(du -h "$OUT/$ASSET" | cut -f1)）"

if [[ $BAD -ne 0 ]]; then
  echo
  echo "!! 还有 $BAD 个文件超过 2.28（上面 ✗）。它们在 UOS 上会报 version not found，"
  echo "   要么用 dist 里的同名文件覆盖，要么从包里删掉那部分功能。"
  exit 1
fi

echo
echo "拷到 UOS 上："
echo "  tar -xzf $ASSET && bash install-version-offline.sh ./$(basename "$ROOT") nightly"
