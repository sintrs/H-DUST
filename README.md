# Horizon · UOS 20 (glibc 2.28) 构建仓库

这个仓库不含 Horizon 的源码，只放**构建脚本**和一个 **GitHub Actions workflow**：
在 Debian 10（glibc 2.28）容器里编译 Horizon 的 Linux 二进制，产出能在统信 UOS 20 上跑的包。

## 为什么需要它

Horizon 官方发布的 Linux 包全部在 `ubuntu-22.04` 上编译，二进制里写死了
`GLIBC_2.34` / `GLIBC_2.35` 的符号引用。UOS 20 是 glibc 2.28，`ld.so` 在 `main()` 之前
就会拒绝加载（`version 'GLIBC_2.35' not found`，退出码 1，stdout 0 字节，任何参数都无效）。
AppImage 也一样——它故意不打包 glibc，必须用系统那份。

符号版本是链接期写进 ELF 的，改不了、补不了，**只能在老环境里重新编译一次**。编完就是普通文件，
拷多少台机器都行。

## 两路源码（这是和一般做法最不一样的地方）

| 部件 | 来源 | 原因 |
|---|---|---|
| 游戏本体（`horizon-client` / `horizon-ctl` / `horizon-prepare` / `horizon-server`） | `horizon-rust/horizon`（真上游，最新） | 引擎要新的 |
| 启动器（`horizon-launcher`） | `gerdaroot/Horizon-Offline-Launcher` | **上游 0.2.79 把离线身份整个删掉了**：`account.rs` 里只剩 `old_offline` 的只读兼容，`launch_for_game` 在没有任何账号拥有游戏时直接 `Err(NoOwner)`。离线分支保留了 `GATE_OPEN = true`，可以无微软账号开局 |

两路都是同一套源码树结构，workflow 分别 clone 到 `game-src/` 和 `launcher-src/` 再各自编译。

## 怎么用

1. Actions → `Build Linux for glibc 2.28 (UOS 20 / Debian 10)` → `Run workflow`
2. 参数默认即可：游戏源码 `horizon-rust/horizon`、启动器源码 `gerdaroot/Horizon-Offline-Launcher`、
   目标 `both`、CPU 基线 `x86-64`
3. 跑完在本次运行的 **Artifacts** 里下载 `horizon-glibc228-x86-64.zip`
4. 里面有 `dist/`（单个二进制）和 `package/horizon-linux-x86_64-uos20.tar.gz`（完整包，装 UOS 用这个）

想快一点可以选 `x86-64-v3`（AVX2）——兆芯 KX-7000 支持 AVX2，属于白拿的收益。
**不要**在别处用 `target-cpu=native`：在 Intel 机器上编会带 AVX-512，拿到 KX-7000 上是 `SIGILL` 秒退。

## 装到 UOS 20 上

```bash
tar -xzf horizon-linux-x86_64-uos20.tar.gz
bash tools/ci/install-version-offline.sh ./horizon-linux-x86_64 nightly
HORIZON_LAUNCHER_NO_SELF_UPDATE=1 ./horizon-launcher
```

第一次进世界前，资源要就地导出（需要 Java 25，JRE 即可）：

```bash
cd ~/.local/share/horizon-launcher/versions/nightly
./horizon-prepare --prepare --server-jar /路径/26.3-server.jar
```

## 文件

| 文件 | 作用 |
|---|---|
| `tools/ci/Dockerfile.glibc228` | debian:10 + rustup（含 rust-src / wasm32 / llvm-tools）+ 开发包 + python3 |
| `tools/ci/build-glibc228.sh` | 建镜像 → 编译 → 校验（`launcher` / `game`） |
| `tools/ci/container-entry.sh` | 容器里真正干活的那一步：按源码布局选构建命令、装 Rust 版本、搬产物 |
| `tools/ci/verify-glibc.sh` | 校验 `GLIBC_x.y` 上限、CPU 基线（POPCNT/LZCNT）、列 NEEDED 库 |
| `tools/ci/make-uos-package.sh` | 以官方 nightly 包为骨架，只替换受 glibc 影响的二进制，逐个复验 ≤2.28 |
| `tools/ci/swap-228-package.sh` | 同上但作用于已解压目录（本地手工用） |
| `tools/ci/install-version-offline.sh` | 在目标机上装版本目录 + 就地校验 glibc |
| `.github/workflows/build-uos20.yml` | 手动触发的构建 workflow |

## 三个踩过的坑（留着，别再踩）

**1. 指令集判据不是「有没有 AVX-512」。** 第一版用 `objdump | grep %zmm`，26 条 zmm 把一次
已经成功的构建卡死在最后一步。上游 `tools/check_cpu_baseline.py` 的注释写明了原因：

> AVX, BMI2, SSSE3 and SSE4 do appear, always behind a CPUID check (ring's assembly, memchr,
> half's F16C, compiler_builtins' FMA) … Only POPCNT and LZCNT are checked.

真正会在 `main` 之前 `SIGILL` 的，是**没做 CPUID 检查就执行**的 `POPCNT` / `LZCNT`
（上游 #7264：Core 2 上 `0xc000001d`，进程直接退）。现在有上游脚本就跑上游的，没有就退回数助记符，
zmm 只作参考。

**2. `-C target-cpu=baseline` 不是合法 CPU 名。** LLVM 报
`'baseline' is not a recognized processor`，随后 `64-bit code requested on a subtarget that
doesn't support it`，编译 3 分钟就失败。合法值是 `x86-64` / `x86-64-v2/v3/v4` 或具体型号。

**3. 上游的构建命令和离线分支不一样。** 上游的游戏入口叫 `horizon-official`：

```
-p horizon-official --bin horizon-official -p horizon-client-lib --bin horizon-ctl \
-p horizon-prepare --bin horizon-prepare -p horizon-server --bin horizon-server
cp horizon-official horizon-client
```

另外还要顺带编一个共享 wasm 标准库（`cargo-horizon-mod wasm-std horizon-wasm-std.wasm`，
需要 rust-src + wasm32 target）。`container-entry.sh` 按 `crates/horizon-official` 是否存在自动识别两种布局。

## 说明

- 产物只解决 **glibc** 这一关。能否真正渲染出世界还取决于显卡驱动（UOS 上需要 Vulkan 1.0+ 或 OpenGL 4.x）。
- `exporters/` 目录只能在上游自托管的 runner 上编（要用 Mojang 的 jar），公开 CI 拿不到——
  所以打包时以官方 nightly 包为骨架，把它带上，只换二进制。
- 启动器的自更新指向 `gerdaroot` 的仓库，跑起来要带 `HORIZON_LAUNCHER_NO_SELF_UPDATE=1`，
  否则联网后可能把自己换回 2.35 的版本。
