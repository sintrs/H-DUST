#!/usr/bin/env bash
# 直接在构建机上编译 Horizon（不再需要 Debian 10 容器 / glibc 2.28 那一层）。
#
# 用法（在仓库根目录执行）：
#   bash tools/ci/build-linux.sh <源码根目录> <输出目录> launcher|game
#
# 产物跑在 glibc >= 2.35 的机器上（和上游官方包同档）。
#
# 两件事让这个脚本"跟得上"上游：
#   1. 编译目标按 bin 名在 workspace 里现查所属的包（cargo metadata），
#      上游给 crate 改名不会断，只要 bin 名不变；
#   2. 源码布局自动识别（上游 horizon-official / 离线分支 horizon-client）。
#
# 环境变量：
#   RUSTFLAGS               CPU 基线，默认 -C target-cpu=x86-64
#   HORIZON_GAME_BUILD_ID   构建身份；没给就从 git 取，取不到用时间戳
#   CARGO_TARGET_DIR        编译中间产物目录，默认 <源码>/target
set -uo pipefail

SRC=${1:?用法: build-linux.sh <源码根目录> [输出目录] [launcher|game]}
OUT=${2:-dist}
FLAVOR=${3:-game}

HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$SRC" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

case "$FLAVOR" in
  launcher|game|client) ;;
  *) echo "错误：第三个参数只能是 launcher、game 或 client" >&2; exit 2 ;;
esac
[[ "$FLAVOR" == client ]] && FLAVOR=game

cd "$SRC" || { echo "错误：进不去 $SRC" >&2; exit 1; }

: "${RUSTFLAGS:=-C target-cpu=x86-64}"
export RUSTFLAGS
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$SRC/target}"
export CARGO_TERM_COLOR=always
TARGET_DIR="$CARGO_TARGET_DIR"

# 构建身份：crates/horizon-mod-host/build.rs 要一个 commit 号，没给就自己跑
# `git rev-parse HEAD` 并断言成功（git rev-parse HEAD failed; set HORIZON_GAME_BUILD_ID
# for staged builds）。有这个变量它就不碰 git —— 上游给 staged build 留的正规入口。
if [[ -z "${HORIZON_GAME_BUILD_ID:-}" ]]; then
  HORIZON_GAME_BUILD_ID=$(git -C "$SRC" rev-parse HEAD 2>/dev/null \
    || echo "local-$(date -u +%Y%m%d%H%M%S)")
fi
export HORIZON_GAME_BUILD_ID

# Rust 版本：上游钉在 tools/ci/rust-version。装不上就退回当前 stable，但要留痕。
if [[ -f tools/ci/rust-version ]]; then
  WANT=$(tr -d '[:space:]' < tools/ci/rust-version)
  if [[ -n "$WANT" ]] && rustup toolchain install "$WANT" --profile minimal \
        -c rust-src -t wasm32-unknown-unknown >/dev/null 2>&1; then
    export RUSTUP_TOOLCHAIN="$WANT"
    echo "==> Rust $WANT（源码指定）"
  else
    echo "!! 装不上源码指定的 Rust ${WANT:-?}，退回当前工具链"
    rustup component add rust-src >/dev/null 2>&1 || true
    rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true
    rustup component add rust-src >/dev/null 2>&1 || true
  fi
fi

echo "==> 源码：$SRC"
echo "==> Rust：$(rustc -V 2>/dev/null || echo '未找到 rustc')"
echo "==> RUSTFLAGS=$RUSTFLAGS"
echo "==> 构建身份：$HORIZON_GAME_BUILD_ID"
echo "==> 宿主 glibc：$(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')（产物地板 = 这个值）"

# ---- bin → 所属包 ----------------------------------------------------------
# 上游把 bin 分散在 horizon-official / horizon-client-lib / horizon-prepare /
# horizon-server 几个包里，名字和目录名并不对应。硬编码 `-p` 一旦上游搬家就断，
# 这里让 cargo 自己说 bin 属于哪个包。取不到就退回 `--bin`（workspace 内唯一时也管用）。
META_FILE=$(mktemp)
cargo metadata --format-version 1 --no-deps > "$META_FILE" 2>/dev/null || true
trap 'rm -f "$META_FILE"' EXIT

pkg_of_bin() {
  [[ -s "$META_FILE" ]] || return 1
  python3 - "$1" "$META_FILE" <<'PY'
import json, sys
want, path = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception:
    sys.exit(1)
for pkg in data.get("packages", []):
    for t in pkg.get("targets", []):
        if t.get("name") == want and "bin" in t.get("kind", []):
            print(pkg["name"])
            sys.exit(0)
sys.exit(1)
PY
}

# build_bin <bin> <必需?1:0>
build_bin() {
  local bin=$1 required=${2:-1} pkg
  if pkg=$(pkg_of_bin "$bin") && [[ -n "$pkg" ]]; then
    echo "==> 编译 $bin（包：$pkg）"
    cargo build --release --locked -p "$pkg" --bin "$bin"
  else
    echo "==> 编译 $bin（workspace 里没查到所属包，直接按 bin 名编）"
    cargo build --release --locked --bin "$bin"
  fi
  if [[ $? -ne 0 ]]; then
    if [[ "$required" == 1 ]]; then
      echo "错误：$bin 编译失败" >&2
      exit 1
    fi
    echo "!! $bin 编不出来，跳过（包里用官方那个）"
    return 1
  fi
  return 0
}

collect() {
  local bin=$1 out=$2
  if [[ -x "$TARGET_DIR/release/$bin" ]]; then
    install -Dm755 "$TARGET_DIR/release/$bin" "$OUT/$out"
    echo "    → $out（$(du -h "$OUT/$out" | cut -f1)）"
    return 0
  fi
  echo "!! 找不到 $TARGET_DIR/release/$bin" >&2
  return 1
}

case "$FLAVOR" in
  launcher)
    echo "==> 启动器：launcher/ 是独立 workspace"
    ( cd launcher && cargo build --release --locked ) || { echo "错误：启动器编译失败" >&2; exit 1; }
    collect horizon-launcher horizon-launcher || exit 1
    ;;

  game)
    # 布局：上游把游戏入口叫 horizon-official，打完包才改名 horizon-client；
    # 离线分支（gerdaroot）仍是旧的 horizon-client 直出。
    if [[ -d crates/horizon-official ]]; then
      LAYOUT=upstream
      GAME_BIN=horizon-official
    else
      LAYOUT=legacy
      GAME_BIN=horizon-client
    fi
    echo "==> 源码布局：$LAYOUT（游戏入口 $GAME_BIN）"

    build_bin "$GAME_BIN" 1 || exit 1
    collect "$GAME_BIN" horizon-client || exit 1

    for b in horizon-ctl horizon-prepare horizon-server; do
      if build_bin "$b" 0; then
        collect "$b" "$b" || true
      fi
    done

    # 共享的 wasm 标准库：官方包就摆在二进制旁边，缺了它 mod 运行时会拒绝加载。
    # 需要 rust-src + wasm32-unknown-unknown 才能出。
    if cargo run --locked -p cargo-horizon-mod -- wasm-std "$OUT/horizon-wasm-std.wasm"; then
      echo "    → horizon-wasm-std.wasm"
    else
      echo "!! wasm-std 编不出来（缺 rust-src / wasm32 target？）—— 打包时用官方包里那个"
      rm -f "$OUT/horizon-wasm-std.wasm"
    fi
    ;;
esac

echo
echo "==> 产物："
for f in "$OUT"/*; do
  [[ -f "$f" ]] || continue
  v=$(objdump -T "$f" 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)
  printf '    %-26s %8s  %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)" "${v:-（非 ELF）}"
done
