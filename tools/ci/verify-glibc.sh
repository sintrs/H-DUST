#!/usr/bin/env bash
# 校验一个 ELF 二进制对 glibc 的符号版本要求，以及它依赖的动态库。
#
# 用法: verify-glibc.sh <二进制> [最高允许版本，默认 2.28]
# 退出码: 0 = 全部符号版本 <= 上限；1 = 有超出的符号版本
#
# 注意：刻意不用 mapfile / 进程替换（< <(...)），沙箱或精简容器里没有 /dev/fd 时会直接崩。
set -uo pipefail

BIN=${1:?用法: verify-glibc.sh <二进制> [最高glibc版本]}
MAX=${2:-2.28}

[[ -f "$BIN" ]] || { echo "错误：找不到 $BIN" >&2; exit 1; }

if command -v objdump >/dev/null 2>&1; then
  RAW=$(objdump -T "$BIN" 2>/dev/null)
  NEEDED=$(objdump -p "$BIN" 2>/dev/null | awk '/NEEDED/ {print "  " $2}')
elif command -v readelf >/dev/null 2>&1; then
  RAW=$(readelf -sW --dyn-syms "$BIN" 2>/dev/null)
  NEEDED=$(readelf -d "$BIN" 2>/dev/null | awk -F'[][]' '/NEEDED/ {print "  " $2}')
else
  echo "错误：需要 binutils（objdump 或 readelf）" >&2
  exit 1
fi

# 取出所有 GLIBC_x.y 引用：去前缀、按版本排序、去重
VERS_RAW=$(printf '%s\n' "$RAW" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/^GLIBC_//' | sort -Vu | uniq)
VERS=()
for v in $VERS_RAW; do
  [[ -n "$v" ]] && VERS+=("$v")
done

if [[ ${#VERS[@]} -eq 0 ]]; then
  echo "没有找到任何 GLIBC_ 符号版本引用（可能是静态链接或非 glibc 目标）。"
  [[ -n "${NEEDED:-}" ]] && { echo "依赖的动态库:"; printf '%s\n' "$NEEDED"; }
  exit 0
fi

echo "符号版本清单（下限 → 上限）:"
for v in "${VERS[@]}"; do
  echo "  GLIBC_$v"
done

HIGHEST=${VERS[${#VERS[@]}-1]}
echo
echo "最高要求: GLIBC_$HIGHEST    允许上限: GLIBC_$MAX"

bad=0
for v in "${VERS[@]}"; do
  # 两个版本排序后取较大者；等于上限算通过
  if [[ "$(printf '%s\n%s\n' "$v" "$MAX" | sort -V | tail -1)" != "$MAX" ]]; then
    echo "  ✗ GLIBC_$v 超出上限 GLIBC_$MAX"
    bad=1
  fi
done

echo
echo "依赖的动态库（目标机上必须存在）:"
printf '%s\n' "${NEEDED:-  (无)}"

# ---- 指令集：glibc 过了也可能因为 CPU 指令集不对而 SIGILL ----
# 兆芯 KX-7000 / 多数家用 CPU 都没有 AVX-512。只要编译机上有人开了 target-cpu=native，
# 产物里就可能出现 zmm 指令，拿到目标机上是"ldd 一切正常但一跑就没"。
ISA_BAD=0
if command -v objdump >/dev/null 2>&1; then
  ZMM=$(objdump -d "$BIN" 2>/dev/null | grep -cE '%zmm|vpxord|vmovdqu64' || true)
  echo
  if [[ "${ZMM:-0}" -gt 0 ]]; then
    echo "指令集检查: ✗ 发现 $ZMM 条 AVX-512 指令（zmm）"
    echo "  KX-7000 这类 CPU 没有 AVX-512，运行会 SIGILL（非法指令）直接退出。"
    echo "  重新编译时加: RUSTFLAGS=\"-C target-cpu=baseline\"（或 x86-64-v2）"
    ISA_BAD=1
  else
    echo "指令集检查: ✓ 没有 AVX-512 指令（baseline 目标，老 CPU 不会 SIGILL）"
  fi
fi

echo
if [[ $bad -ne 0 ]]; then
  echo "结果：不通过 —— 这个二进制在 glibc $MAX 及更老的机器上会报 version not found。"
  echo "常见原因：编译镜像比 Debian 10 新，或某条链接路径把宿主机（runner）的 glibc 带进来了。"
  exit 1
fi

if [[ "${ISA_BAD:-0}" -ne 0 ]]; then
  echo "结果：glibc 通过，但指令集不通过 —— 在 KX-7000 / 老 Intel 上会 SIGILL。"
  exit 1
fi

echo "结果：通过 —— GLIBC_$HIGHEST <= GLIBC_$MAX，且指令集是 baseline，glibc $MAX 及更新的系统都能运行。"
