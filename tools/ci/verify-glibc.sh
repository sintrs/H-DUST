#!/usr/bin/env bash
# 校验一个 ELF 二进制对 glibc 的符号版本要求、依赖的动态库，以及 CPU 指令集基线。
#
# 用法: verify-glibc.sh <二进制> [最高允许版本，默认 2.28] [源码根目录]
# 退出码: 0 = 通过；1 = 有超出的 glibc 符号版本，或指令集基线不通过
#
# 注意：刻意不用 mapfile / 进程替换（< <(...)），沙箱或精简容器里没有 /dev/fd 时会直接崩。
set -uo pipefail

BIN=${1:?用法: verify-glibc.sh <二进制> [最高glibc版本] [源码根目录]}
MAX=${2:-2.28}
SRC=${3:-}

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

# ---------------- 指令集基线 ----------------
# 判据：只有 POPCNT 和 LZCNT。
#
# 这里踩过一次坑：早先写的是"扫 %zmm，出现 AVX-512 就判不通过"，结果 26 条 zmm 把一次
# 已经成功的构建卡死在最后一步。上游 tools/check_cpu_baseline.py 的注释说清了原因：
#   AVX、BMI2、SSSE3、SSE4 这些都会出现在产物里，但一律在 CPUID 检查之后才执行
#   （ring 的汇编、memchr、half 的 F16C、compiler_builtins 的 FMA……）。
# 也就是说 SIMD 指令的数量不能作为判据，真正会在 main 之前 SIGILL 的，是"没有 CPUID
# 保护就用了"的 POPCNT / LZCNT（上游 issue #7264：Core 2 上 0xc000001d，进程直接退）。
#
# 所以：有上游脚本就用上游的（它按符号边界判断，比数助记符准），没有就退回数助记符。
find_llvm_objdump() {
  if command -v llvm-objdump >/dev/null 2>&1; then
    command -v llvm-objdump
    return 0
  fi
  local sys
  sys=$(rustc --print sysroot 2>/dev/null) || return 0
  ls "$sys"/lib/rustlib/*/bin/llvm-objdump 2>/dev/null | head -1
}

ISA_BAD=0
ISA_SAID=""
echo
if [[ -n "$SRC" && -f "$SRC/tools/check_cpu_baseline.py" ]]; then
  OBD=$(find_llvm_objdump)
  if [[ -n "$OBD" ]]; then
    echo "指令集检查（上游 tools/check_cpu_baseline.py，判据 POPCNT / LZCNT）:"
    if LLVM_OBJDUMP="$OBD" python3 "$SRC/tools/check_cpu_baseline.py" "$BIN"; then
      ISA_SAID="✓ 没有未受保护的 POPCNT / LZCNT（baseline x86-64 能启动）"
    else
      ISA_SAID="✗ 命中未受保护的 POPCNT / LZCNT —— 老 CPU 上会在 main 之前 SIGILL"
      ISA_BAD=1
    fi
  else
    echo "（没有 llvm-objdump，跳过上游脚本，改用助记符统计）"
  fi
fi

if [[ -z "$ISA_SAID" ]]; then
  echo "指令集检查（数 POPCNT / LZCNT 助记符）:"
  CNT=$(objdump -d --no-show-raw-insn "$BIN" 2>/dev/null | awk -F'\t' '
    /^[[:space:]]*[0-9a-f]+:/ {
      n = split($2, a, " "); m = a[1]; sub(/[wlq]$/, "", m)
      if (m == "popcnt" || m == "lzcnt") c++
    }
    END { print c + 0 }')
  # AVX / AVX2 / AVX-512 的数量只作参考，不参与判定：它们都在 CPUID 检查后面
  ZMM=$(objdump -d --no-show-raw-insn "$BIN" 2>/dev/null | grep -c '%zmm' || true)
  echo "  POPCNT/LZCNT: ${CNT:-0} 条 · AVX-512(zmm): ${ZMM:-0} 条（后者不参与判定）"
  if [[ "${CNT:-0}" -gt 0 ]]; then
    ISA_SAID="✗ 有 ${CNT} 条 POPCNT/LZCNT，无法确认都做了 CPUID 保护"
    ISA_BAD=1
  else
    ISA_SAID="✓ 没有 POPCNT / LZCNT（Core 2 这一档也能启动）"
  fi
fi
echo "  $ISA_SAID"

echo
if [[ $bad -ne 0 ]]; then
  echo "结果：不通过 —— 这个二进制在 glibc $MAX 及更老的机器上会报 version not found。"
  echo "常见原因：编译镜像比 Debian 10 新，或某条链接路径把宿主机（runner）的 glibc 带进来了。"
  exit 1
fi

if [[ "${ISA_BAD:-0}" -ne 0 ]]; then
  echo "结果：glibc 通过（GLIBC_$HIGHEST <= GLIBC_$MAX），但指令集基线不通过。"
  exit 1
fi

echo "结果：通过 —— GLIBC_$HIGHEST <= GLIBC_$MAX，指令集基线也过，glibc $MAX 及更新的系统都能运行。"
