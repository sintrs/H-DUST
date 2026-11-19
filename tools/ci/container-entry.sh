#!/usr/bin/env bash
# 在 Debian 10（glibc 2.28）容器里做真正的那一步：装源码指定的 Rust 版本 + 编译 + 把产物搬出来。
#
# 单独成一个文件的原因：这些命令要穿过 docker run 的 -e 和 bash -lc 两层引号，
# 内联写必然打错一个引号就静默跑成别的东西。放这里，本地和 CI 走的是同一份。
#
# 用法（容器内）:
#   SRC_ROOT=/src OUT_DIR=/out bash container-entry.sh launcher|game
# 环境:
#   SRC_ROOT  源码根目录（默认 /src）
#   OUT_DIR   产物目录（默认 /out）
#   HOST_UID/HOST_GID  产物 owner（容器是 root，不改的话宿主上删不掉）
set -uo pipefail

FLAVOR=${1:?用法: container-entry.sh launcher|game}
SRC_ROOT=${SRC_ROOT:-/src}
OUT_DIR=${OUT_DIR:-/out}

cd "$SRC_ROOT" || { echo "错误：没有 $SRC_ROOT" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# 源码布局：上游 horizon-rust/horizon 有 crates/horizon-official（游戏入口叫 horizon-official，
# 打完包才改名 horizon-client）；离线分支 gerdaroot 那份还是旧的 horizon-client 直出。
LAYOUT=legacy
[[ -d crates/horizon-official ]] && LAYOUT=upstream
echo "==> 源码布局：$LAYOUT"

# 上游把 Rust 版本钉在 tools/ci/rust-version（当前 1.99.1）。编不上就退回镜像里的 stable。
if [[ -f tools/ci/rust-version ]]; then
  WANT=$(tr -d '[:space:]' < tools/ci/rust-version)
  if [[ -n "$WANT" ]] && rustup toolchain install "$WANT" --profile minimal \
        -c rust-src -t wasm32-unknown-unknown >/dev/null 2>&1; then
    export RUSTUP_TOOLCHAIN="$WANT"
    echo "==> 用源码指定的 Rust $WANT（含 rust-src 与 wasm32 target）"
  else
    echo "!! 装不上源码指定的 Rust ${WANT:-?}，改用镜像里的 stable"
    rustup component add rust-src >/dev/null 2>&1 || true
    rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true
  fi
fi
rustc -V
echo "==> RUSTFLAGS=${RUSTFLAGS:-(未设置)}"

# CARGO_TARGET_DIR 由镜像设为 /target；本机编译时则是源码树下的 target/
TARGET_DIR=${CARGO_TARGET_DIR:-$SRC_ROOT/target}

case "$FLAVOR" in
  launcher)
    # launcher/ 是独立 workspace（Cargo.toml 里自带 [workspace]）
    ( cd launcher && cargo build --release --locked ) || exit 1
    install -Dm755 "$TARGET_DIR/release/horizon-launcher" "$OUT_DIR/horizon-launcher"
    echo "==> 产出 horizon-launcher"
    ;;

  game)
    if [[ "$LAYOUT" == upstream ]]; then
      # 与上游 .github/workflows/game-build.yml 第 209 行完全同一条命令：
      # 游戏本体是 horizon-official（horizon-client 那个名字是 horizon-official 打完包的副本）
      cargo build --release --locked \
        -p horizon-official --bin horizon-official \
        -p horizon-client-lib --bin horizon-ctl \
        -p horizon-prepare --bin horizon-prepare \
        -p horizon-server --bin horizon-server || exit 1
      install -Dm755 "$TARGET_DIR/release/horizon-official" "$OUT_DIR/horizon-client"
      for b in horizon-ctl horizon-prepare horizon-server; do
        install -Dm755 "$TARGET_DIR/release/$b" "$OUT_DIR/$b"
        echo "==> 产出 $b"
      done
      # 共享的 wasm 标准库：官方包里就摆在二进制旁边（game-build.yml 第 225 行），
      # 缺了它 mod 运行时会拒绝加载。它要 rust-src + wasm32-unknown-unknown 才能编。
      if cargo run --locked -p cargo-horizon-mod -- wasm-std "$OUT_DIR/horizon-wasm-std.wasm"; then
        echo "==> 产出 horizon-wasm-std.wasm"
      else
        echo "!! wasm-std 编不出来（缺 rust-src / wasm32 target？）—— 用官方包里那个"
        rm -f "$OUT_DIR/horizon-wasm-std.wasm"
      fi
    else
      # 离线分支（gerdaroot）：旧的直出命名，且 horizon-ctl 不在公开 workspace 里，编不动就跳过
      cargo build --release --locked -p horizon-client --bin horizon-client || exit 1
      install -Dm755 "$TARGET_DIR/release/horizon-client" "$OUT_DIR/horizon-client"
      echo "==> 产出 horizon-client"
      for p in horizon-prepare horizon-server horizon-ctl; do
        if cargo build --release --locked -p "$p" >/dev/null 2>&1 && [[ -x "$TARGET_DIR/release/$p" ]]; then
          install -Dm755 "$TARGET_DIR/release/$p" "$OUT_DIR/$p"
          echo "==> 产出 $p"
        else
          echo "!! $p 编不动，留用官方包里的那个（它要求 GLIBC_2.34，只在控制台/联机时才会被调到）"
        fi
      done
    fi
    ;;

  *)
    echo "错误：目标只能是 launcher 或 game" >&2
    exit 2
    ;;
esac

if [[ -n "${HOST_UID:-}" && -n "${HOST_GID:-}" ]]; then
  chown -R "$HOST_UID:$HOST_GID" "$OUT_DIR" 2>/dev/null || true
fi
echo "==> 编译完成，产物在 $OUT_DIR"
