#!/usr/bin/env bash
# 在 Debian 10（glibc 2.28）环境里编译 Horizon 的二进制，然后校验符号版本与 CPU 基线。
#
# 用法（在仓库根目录执行）：
#   bash tools/ci/build-glibc228.sh .  dist launcher   # 启动器（1 个文件）
#   bash tools/ci/build-glibc228.sh .  dist game       # 客户端 + ctl + prepare + server（+ wasm-std）
#   NATIVE=1 bash tools/ci/build-glibc228.sh . dist game   # 不用 docker，在本机编
#
# 参数：
#   $1 源码根目录（clone 下来的仓库根，里面同时有 launcher/ 和 crates/）
#   $2 产物输出目录（默认 ./dist）
#   $3 launcher | game | client（client 等价于 game）
#   $4 允许的最高 glibc 符号版本（默认 2.28，只用于校验）
#
# 依赖：docker（NATIVE=1 时改为本机 rustup + 那几套 -dev 包）。
# 编译本体在容器里由 container-entry.sh 完成 —— 那条命令要从这里穿两层引号过去，
# 内联写必然出错，所以独立成文件。
set -uo pipefail

SRC=${1:?用法: build-glibc228.sh <源码根目录> [输出目录] [launcher|game] [最高glibc版本]}
OUT=${2:-dist}
FLAVOR=${3:-launcher}
MAXGLIBC=${4:-2.28}

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$SRC" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

case "$FLAVOR" in
  launcher) VERIFY_LIST='horizon-launcher' ;;
  game|client) VERIFY_LIST='horizon-client horizon-ctl horizon-prepare horizon-server' ;;
  *)
    echo "错误：第三个参数只能是 launcher、game 或 client" >&2
    exit 2
    ;;
esac

# CPU 基线：x86-64 就是 rustc 的默认基线（LLVM 的 "baseline"、GCC 的 -march=x86-64）。
# 值必须是 LLVM 认识的 CPU 名 —— x86-64 / x86-64-v2 / x86-64-v3 / x86-64-v4 或具体型号。
# 写 "baseline" 会得到 "'baseline' is not a recognized processor"，随后 LLVM 报
# "64-bit code requested on a subtarget that doesn't support it" 而编译失败（踩过）。
: "${RUSTFLAGS:=-C target-cpu=x86-64}"
export RUSTFLAGS

# 构建身份（游戏本体必需）：
#   crates/horizon-mod-host/build.rs 要一个 commit 号，没给就自己跑 `git rev-parse HEAD`。
#   容器里进程是 root、/src 属主是宿主用户，git 会以 "dubious ownership" 拒绝服务，
#   build.rs 直接 panic（git rev-parse HEAD failed; set HORIZON_GAME_BUILD_ID for staged builds）。
#   有这个环境变量它就不碰 git 了 —— 这是上游给 staged build 留的正规入口。
#   宿主侧能取到就取真实 commit，取不到（比如导出成 tar 的源码）给个时间戳兜底。
if [[ -z "${HORIZON_GAME_BUILD_ID:-}" ]]; then
  HORIZON_GAME_BUILD_ID=$(git -C "$SRC" rev-parse HEAD 2>/dev/null \
    || echo "local-$(date -u +%Y%m%d%H%M%S)")
fi
export HORIZON_GAME_BUILD_ID

echo "==> 目标：$VERIFY_LIST"
echo "==> 源码：$SRC"
echo "==> RUSTFLAGS=$RUSTFLAGS"
echo "==> 构建身份：$HORIZON_GAME_BUILD_ID"

run_native() {
  echo "==> 走本机编译（没有 docker，或 NATIVE=1）"
  echo "    本机 glibc: $(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')（必须 <= $MAXGLIBC，否则产物会带更新的符号）"
  command -v cargo >/dev/null 2>&1 || { echo "错误：本机没有 cargo，装 rustup 后再来" >&2; exit 1; }
  SRC_ROOT="$SRC" OUT_DIR="$OUT" bash "$HERE/container-entry.sh" "$([ "$FLAVOR" = launcher ] && echo launcher || echo game)" || exit 1
}

if [[ "${NATIVE:-0}" == "1" ]] || ! command -v docker >/dev/null 2>&1; then
  run_native
else
  echo "==> 1/3 构建 glibc 2.28 编译镜像（命中缓存会很快）"
  docker build -f "$HERE/Dockerfile.glibc228" -t horizon-glibc228:latest "$HERE" || exit 1

  echo "==> 2/3 编译（容器内）"
  # registry 与 target 都挂命名卷，重复编译不用从零来
  docker run --rm \
    -v "$SRC":/src \
    -v "$OUT":/out \
    -v "$HERE":/ci:ro \
    -v horizon-glibc228-registry:/usr/local/cargo/registry \
    -v "horizon-glibc228-target-$FLAVOR":/target \
    -e CARGO_TARGET_DIR=/target \
    -e RUSTFLAGS="$RUSTFLAGS" \
    -e HORIZON_GAME_BUILD_ID="$HORIZON_GAME_BUILD_ID" \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    horizon-glibc228:latest \
    bash /ci/container-entry.sh "$([ "$FLAVOR" = launcher ] && echo launcher || echo game)" || {
      echo "错误：编译失败，看上面容器里的输出" >&2
      exit 1
    }
fi

echo "==> 3/3 校验（glibc 上限 $MAXGLIBC + CPU 基线）"
FAIL=0
for b in $VERIFY_LIST; do
  if [[ ! -f "$OUT/$b" ]]; then
    echo
    echo "-- $b：没有编出来，跳过校验（用官方包里那个代替）"
    continue
  fi
  echo
  echo "########## $b ##########"
  if command -v docker >/dev/null 2>&1 && [[ "${NATIVE:-0}" != "1" ]]; then
    docker run --rm -v "$OUT":/out:ro -v "$SRC":/src:ro -v "$HERE":/ci:ro \
      horizon-glibc228:latest bash /ci/verify-glibc.sh "/out/$b" "$MAXGLIBC" /src || FAIL=1
  else
    bash "$HERE/verify-glibc.sh" "$OUT/$b" "$MAXGLIBC" "$SRC" || FAIL=1
  fi
done

echo
if [[ $FAIL -ne 0 ]]; then
  echo "结论：有二进制没通过校验，见上面的 ✗。"
  exit 1
fi

echo "完成：产物在 $OUT"
if [[ "$FLAVOR" != "launcher" ]]; then
  echo "下一步：换进官方包 —— bash tools/ci/swap-228-package.sh <解压后的包目录> $OUT"
fi
