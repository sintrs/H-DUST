#!/usr/bin/env bash
# 在 Debian 10（glibc 2.28）环境里编译 Horizon 的二进制，然后校验符号版本。
#
# 用法（在 fork 仓库根目录执行）：
#   bash tools/ci/build-glibc228.sh .  dist launcher   # 启动器（1 个文件）
#   bash tools/ci/build-glibc228.sh .  dist game       # 客户端 + prepare + server（能编几个编几个）
#   bash tools/ci/build-glibc228.sh .  dist client     # 同上，等价于 game
#   NATIVE=1 bash tools/ci/build-glibc228.sh . dist game        # 不用 docker，在本机编
#
# 参数：
#   $1 源码根目录（clone 下来的仓库根，里面同时有 launcher/ 和 crates/）
#   $2 产物输出目录（默认 ./dist）
#   $3 launcher | game | client（默认 launcher）
#   $4 允许的最高 glibc 符号版本（默认 2.28，只用于校验）
#
# 依赖：docker（NATIVE=1 时改为本机 rustup + 6 个 -dev 包）。
# 第一次拉 debian:10 并装依赖约 3~5 分钟；编译本体 15~25 分钟（launcher），game 更长。
set -euo pipefail

SRC=${1:?用法: build-glibc228.sh <源码根目录> [输出目录] [launcher|client] [最高glibc版本]}
OUT=${2:-dist}
FLAVOR=${3:-launcher}
MAXGLIBC=${4:-2.28}

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$SRC" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

case "$FLAVOR" in
  launcher)
    # launcher/ 是独立 workspace（Cargo.toml 里自带 [workspace]）
    BIN=horizon-launcher
    NATIVE_DIR=launcher
    NATIVE_CMD='cargo build --release --locked'
    BUILD_CMD='cd /src/launcher && cargo build --release --locked'
    INSTALL_CMD='install -Dm755 /target/release/horizon-launcher /out/horizon-launcher'
    VERIFY_LIST='horizon-launcher'
    TARGET_SUB=release
    ;;
  client|game)
    # 客户端在根 workspace 里，和 game.yml 用的是同一条命令行。
    # 官方包里四个二进制全要 GLIBC_2.34+（见 README 第七节），所以 game 尽量都编：
    # 只换 horizon-client 的话，启动器在资源准备阶段调 horizon-prepare 时还会炸。
    #
    # 但 horizon-ctl 不在公开仓库的 workspace 里（上游用私有 runner 编），
    # 编它会让整条 cargo 命令失败，所以这里不编它、留用官方包里的那个（2.34，仅影响控制台/AI 功能）。
    # horizon-prepare / horizon-server 可能依赖 Mojang 的 jar 才能构建，编不动就跳过，不阻断。
    BIN=horizon-client
    NATIVE_DIR=.
    NATIVE_CMD='cargo build --release --locked -p horizon-client --bin horizon-client && for p in horizon-prepare horizon-server; do if cargo build --release --locked -p "$p"; then echo "== 编出 $p"; else echo "!! $p 编不动（多半缺构建期资源），跳过，留用官方包里的那个"; fi; done'
    BUILD_CMD="cd /src && $NATIVE_CMD"
    INSTALL_CMD='for b in horizon-client horizon-prepare horizon-server; do if [ -x "/target/release/$b" ]; then install -Dm755 "/target/release/$b" "/out/$b"; fi; done; true'
    VERIFY_LIST='horizon-client horizon-prepare horizon-server'
    TARGET_SUB=release
    ;;
  *)
    echo "错误：第三个参数只能是 launcher、client 或 game" >&2
    exit 2
    ;;
esac

echo "==> 目标：$VERIFY_LIST，最高 glibc 符号版本 $MAXGLIBC"

# CPU 指令集基线：x86-64 就是 rustc 的默认基线（LLVM 的 "baseline"、GCC 的 -march=x86-64），
# 写出来是为了不被别处的 target-cpu=native 带跑。目标机是兆芯 KX-7000 / 老款 Intel 时，
# AVX-512 指令会直接 SIGILL。
# 注意：值必须是 LLVM 认识的 CPU 名 —— x86-64、x86-64-v2、x86-64-v3、x86-64-v4 或具体型号。
# 写 "baseline" 会得到 "not a recognized processor" 并让 LLVM 报 64-bit code requested 而编译失败。
: "${RUSTFLAGS:=-C target-cpu=x86-64}"
export RUSTFLAGS
echo "==> RUSTFLAGS=$RUSTFLAGS"

if [[ "${NATIVE:-0}" == "1" ]] || ! command -v docker >/dev/null 2>&1; then
  # 本机编译：只有当这台机器自己就是 glibc 2.28（或更老）时才成立
  echo "==> 走本机编译（没有 docker，或 NATIVE=1）"
  command -v cargo >/dev/null 2>&1 || { echo "错误：本机没有 cargo，装 rustup 后再来" >&2; exit 1; }
  echo "    本机 glibc: $(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')"
  ( cd "$SRC/$NATIVE_DIR" && eval "$NATIVE_CMD" )
  for b in $VERIFY_LIST; do
    [[ -f "$SRC/$NATIVE_DIR/target/$TARGET_SUB/$b" ]] && install -Dm755 "$SRC/$NATIVE_DIR/target/$TARGET_SUB/$b" "$OUT/$b"
  done
  for b in $VERIFY_LIST; do
    [[ -f "$OUT/$b" ]] || continue
    bash "$HERE/verify-glibc.sh" "$OUT/$b" "$MAXGLIBC"
  done
  echo
  echo "完成：产物在 $OUT（$(echo $VERIFY_LIST | tr ' ' ' ')）"
  exit 0
fi

echo "==> 1/3 构建 glibc 2.28 编译镜像（命中缓存会很快）"
docker build -f "$HERE/Dockerfile.glibc228" -t horizon-glibc228:latest "$HERE"

echo "==> 2/3 编译 $FLAVOR（$VERIFY_LIST）"
# HOST_UID/HOST_GID：容器是 root，不 chown 的话产物在宿主机上删都删不掉
docker run --rm \
  -v "$SRC":/src \
  -v "$OUT":/out \
  -v horizon-glibc228-registry:/usr/local/cargo/registry \
  -v "horizon-glibc228-target-$FLAVOR":/target \
  -e CARGO_TARGET_DIR=/target \
  -e RUSTFLAGS="$RUSTFLAGS" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  horizon-glibc228:latest \
  bash -lc "$BUILD_CMD && $INSTALL_CMD && chown -R \"\$HOST_UID:\$HOST_GID\" /out"

echo "==> 3/3 校验符号版本（上限 $MAXGLIBC）"
for b in $VERIFY_LIST; do
  [[ -f "$OUT/$b" ]] || { echo "  ! 没有编出 $b，跳过校验"; continue; }
  docker run --rm \
    -v "$OUT":/out:ro \
    -v "$HERE":/ci:ro \
    horizon-glibc228:latest \
    bash /ci/verify-glibc.sh "/out/$b" "$MAXGLIBC"
done

echo
echo "完成：产物在 $OUT（$(echo $VERIFY_LIST | tr ' ' ' ')）"
echo "下一步：换进官方包 —— bash tools/ci/swap-228-package.sh horizon-linux-x86_64 $OUT"
