# Horizon · Linux 构建仓库（上游最新游戏 + 离线启动器）

这个仓库不含 Horizon 的源码，只放**构建脚本**和一个 **GitHub Actions workflow**：
每次触发现场克隆上游最新代码，编译出 Linux 二进制，并装进官方 nightly 包。

产物跑在 **glibc ≥ 2.35** 的机器上（Ubuntu 22.04+、Debian 12+、Arch 等），与上游官方包同档。

## 为什么需要它

官方包里**游戏**和**启动器**是配套发布的，而启动器从 0.2.79 起删掉了离线身份：

> `launcher: remove offline names; play only as an account that owns the game`

没有正版微软账号就进不去。离线分支（`gerdaroot/Horizon-Offline-Launcher`）保留了
`account::GATE_OPEN = true`，可以无账号开局，但它的**游戏本体是跟着自己的基线走的**，
总是滞后上游几天到两周。

这个仓库把两件事拆开各取所需：

| 部件 | 来源 | 为什么 |
|---|---|---|
| 游戏本体（`horizon-client` / `horizon-ctl` / `horizon-prepare` / `horizon-server`） | `horizon-rust/horizon` **默认分支最新提交** | 引擎要当天最新 |
| 启动器（`horizon-launcher`） | `gerdaroot/Horizon-Offline-Launcher` 默认分支 | 只有它还能离线开局 |

两路分别 clone 到 `game-src/` 和 `launcher-src/`，各自编译，最后装进官方 nightly 包的骨架里。

## 它能跟得上上游吗

**能，而且不需要「同步」这个动作。** 仓库里没有源码，workflow 每次 `git clone --depth 1`
上游默认分支 —— 你点哪一天，编的就是哪一天的上游。

会失效的不是源码，是脚本对上游结构的假设。为此 `build-linux.sh` 做了两处自适应：

| 原先的硬编码 | 现在 |
|---|---|
| `-p horizon-official --bin horizon-official -p horizon-client-lib --bin horizon-ctl ...` | 用 `cargo metadata` 现查 **每个 bin 属于哪个包**，上游给 crate 改名不会断，只要 bin 名不变 |
| 靠 `crates/horizon-official` 是否存在判布局 | 保留（上游 / 离线分支两种布局仍然靠它区分） |

真正还可能断的只剩三处，失败时对应的报错都很直白：

1. **bin 改名**（比如游戏入口不再叫 `horizon-official`）→ 编译那一步红
2. **`horizon-mod-host/build.rs` 换环境变量名** → 报 `set XXX for staged builds`，照着改名即可
3. **官方 nightly 包结构变了**（少了骨架目录）→ 「装进官方 nightly 包」那步红

## 怎么用

1. Actions → `Build Linux (upstream nightly + offline launcher)` → `Run workflow`
2. 参数默认即可（游戏 `horizon-rust/horizon`、启动器 `gerdaroot/Horizon-Offline-Launcher`、
   目标 `both`、CPU 基线 `x86-64`）
3. 跑完下载 Artifacts 里的 `horizon-linux-x86-64`，产物是：

```
dist/horizon-client  horizon-ctl  horizon-prepare  horizon-server  horizon-launcher  horizon-wasm-std.wasm
package/horizon-linux-x86_64-offline.tar.gz     ← 完整包，装这个
```

耗时约 25 分钟（游戏那段 wgpu / wasmtime / cranelift 是主要耗时，启动器 6 分钟）。

`target_cpu` 想快一点可以选 `x86-64-v3`（AVX2）。**不要**用 `native`：在支持 AVX-512 的机器上编出来的
拿到别处是 `SIGILL` 秒退。

## 装到目标机

```bash
tar -xzf horizon-linux-x86_64-offline.tar.gz
bash tools/ci/install-version-offline.sh ./horizon-linux-x86_64 nightly
```

脚本会拷到 `~/.local/share/horizon-launcher/versions/nightly/`、写 `.installed`、补可执行位，
并逐个二进制校验 glibc 地板（**双判据**：既要 ≤ 本机，也要报出真实数值）。

第一次进世界前，资源要就地导出（需要 Java 25）：

```bash
cd ~/.local/share/horizon-launcher/versions/nightly
./horizon-prepare --prepare --server-jar /路径/26.3-server.jar
```

启动：

```bash
HORIZON_LAUNCHER_NO_SELF_UPDATE=1 ./horizon-launcher
```

`HORIZON_LAUNCHER_NO_SELF_UPDATE=1` 不能省：否则启动器联网后会把自己换成官方版（要正版账号）。

## 文件

| 文件 | 作用 |
|---|---|
| `tools/ci/build-linux.sh` | 编译（`launcher` / `game`），自动识别布局与 bin 所属包 |
| `tools/ci/make-linux-package.sh` | 以官方 nightly 包为骨架，只替换我们编的二进制，报告每个 ELF 的 glibc 地板 |
| `tools/ci/install-version-offline.sh` | 在目标机上装成启动器认的版本目录 + 就地校验 |
| `.github/workflows/build-linux.yml` | 手动触发的 workflow |

## 一个已知的组合风险

「上游最新游戏 + 离线 fork 启动器」在两边基线差得远时，可能撞上运行时的 cache lease 契约：

```
Horizon: cannot acquire launcher cache leases:
this managed installation has unregistered cache directories
```

这是 2026-11-19 实测到的：上游 `dd67b76`（11-19）的客户端 + fork `1.4.4`（基线 11-08）启动即退，
同一启动器换回配套的客户端就正常。**不是账号问题，也不是 glibc 问题。**

真撞上了，解法是把 `game_ref` 填成与该启动器配套的那个 nightly 日期（看 fork 的
`sync with Horizon's Nightly` 提交，或它 release 说明里写的日期）再编一次。

## 三个踩过的坑（留着，别再踩）

**1. `-C target-cpu=baseline` 不是合法 CPU 名。** LLVM 报
`'baseline' is not a recognized processor`，随后 `64-bit code requested on a subtarget that
doesn't support it`。合法值是 `x86-64` / `x86-64-v2/v3/v4` 或具体型号。

**2. 指令集判据不是「有没有 AVX-512」。** 上游 `tools/check_cpu_baseline.py` 写明：

> AVX, BMI2, SSSE3 and SSE4 do appear, always behind a CPUID check … Only POPCNT and LZCNT are checked.

拿 `objdump | grep %zmm` 去卡会把一次成功的构建误杀（踩过，26 条 zmm）。

**3. `horizon-mod-host/build.rs` 需要构建身份。** 它要一个 commit 号，没给就自己跑
`git rev-parse HEAD` 并断言成功。CI 里 git 可能因 dubious ownership 拒绝服务，于是 panic：

```
git rev-parse HEAD failed; set HORIZON_GAME_BUILD_ID for staged builds
```

workflow 在宿主侧算好 `HORIZON_GAME_BUILD_ID` 写进环境变量，脚本缺值再从 git 取、取不到用时间戳兜底。

## 说明

- `exporters/` 只能在上游自托管 runner 上编（要用 Mojang 的 jar），公开 CI 拿不到 ——
  所以打包时以官方 nightly 包为骨架，把它带上，只换二进制。
- 产物只解决 glibc / 编译这一关。能否渲染取决于显卡驱动（Vulkan 1.0+ 或 OpenGL 4.x）。

## 自动跟版：两条独立链路

拆成两个互不干扰的 workflow，各自监控、各自 state、各自 tag 后缀：

| Workflow | 产物 | tag | state |
|---|---|---|---|
| `.github/workflows/release-game.yml` | 官方 nightly 包原样复制，不编译 | `nightly-YYYY-MM-DD-xxxxxxx-game` | `state/game.json` |
| `.github/workflows/release-offline.yml` | 离线启动器（上游源码编 + 离线补丁）+ 官方游戏 | `nightly-YYYY-MM-DD-xxxxxxx-offline` | `state/offline.json` |

两者都用 `tools/ci/monitor_upstream.py` 读 `horizon-rust/horizon/releases`，
解析 `Nightly YYYY-MM-DD · xxxxxxx`，与各自 state 比较；没变化就跳过，有变化才构建发布。

- **本体链路**：直接下载官方 `horizon-linux-x86_64.tar.gz`，一个字节不改，校验 commit 后发布。
- **离线链路**：游戏包同样原样复制；**只编启动器**——拿同一 nightly 的上游源码，
  打 `tools/ci/offline-port.patch` 后编译，替换掉官方二进制。

### 离线是怎么来的

上游 11-09 的 `1e789800af` 删掉了整套离线账号（`Player::Offline`、`add_offline`、
`offline_selected`），之后只能用 `--developer-single-player` 进开发者单人模式，
而那条路把多人、LAN 一起锁死。

现在的做法是**把离线账号层移植回最新的启动器**，和 gerdaroot 那套同源，但跟着上游走：

| 文件 | 改的什么 |
|---|---|
| `launcher/src/account.rs` | 恢复 `offline` 名单、`offline_selected`、`Player`、`add_offline`、`name_arg`，`GATE_OPEN = true` 打开拥有者门 |
| `launcher/src/account.rs` | `GameSession` 加 `name`，启动时以 `--name <离线名>` 传给 client |
| `launcher/src/cli.rs` | `account offline NAME` / `forget-offline` / `select` 认离线名 |
| `launcher/src/glass_account.rs` | 账号页新增「Play offline」卡片：输入框直接改离线名 |
| `launcher/src/horizon_bundle.rs` | 启动时把随包 `data/versions` 装进数据目录并选中 |
| `launcher/src/backend.rs` | `self_update_allowed()` 恒 false，不再自我替换 |
| `launcher/src/launcher_setup.rs` | `launcher_download_available()` 恒 false，不再提示「下载新启动器」 |

合计 14 个文件、+503/−74 行，全部在 `launcher/src` 里，`crates/` 一行未动——
client 本来就用 `offline_uuid(name)` 算身份，不需要改游戏本体。

**版本目录名不再有 `developer-` 前缀**：那是上游开发者通道的判据
（`developer_install::is_developer` 只看目录名 + `.installed` + `developer.json`）。
移植版走正常账号路径，所以目录就是 `data/versions/nightly-YYYY-MM-DD-xxxxxxx/`，
启动器当普通版本对待。

### 包里有什么

```
horizon-offline-linux-x86_64/
  horizon-launcher                 自编，打了离线补丁
  data/versions/nightly-.../       官方 nightly 游戏，原样复制
  PLAY-OFFLINE.txt
```

没有安装脚本、没有 `run-offline.sh`、没有 `offline-name.txt`。解压后直接打开
`horizon-launcher`，它自己把随包版本装进启动器数据目录并选中。离线名在
**设置 → 账号 → Play offline** 里改，或者：

```bash
./horizon-launcher account offline YourName
./horizon-launcher account            # 看当前是谁在玩
```

> 连 `online-mode=true` 的正版服务器仍会被服务端拒绝——这是离线身份的固有限制，
> 与 gerdaroot 那套离线启动器一致。离线服（`online-mode=false`）和 LAN 不受影响。

> 早期试过「整文件反向合并删除离线账号那次提交」：11-09 到当前 nightly 隔了 2 万多次
> 提交、19 个启动器源码被大改，`git revert` 后编译报 `horizon_mods` 缺失、
> `Settings` 字段不存在等一堆错。那条路已放弃。

手动重建：在 Actions 里选对应 workflow → Run workflow，勾 `force` 可按当前上游 nightly
强制再跑一次（同版本 tag 已存在时会拒绝覆盖，不会静默替换）。

## 后面怎么维护

采用「**本地改脚本 → git push → GitHub 编译**」的方式，不要把上游源码 vendor 进这个仓库：

```bash
git clone https://github.com/sintrs/H-DUST.git
cd H-RUST
# 改 tools/ci/*.sh、offline-port.patch、monitor_upstream.py、workflow
git add -A && git commit -m '...' && git push
```

- 仓库保持很小（几十 KB），只有脚本、补丁、监控 state 和 workflow。
- 每次构建时 Actions 现场拉上游源码，源码天然是新的。
- `state/game.json` 和 `state/offline.json` 由各自的 Actions 自动提交，
  手工只用于排查或回退，别当成主编辑对象。
- `build-linux.yml` 保留作手动构建备用；正式产物由两条 `release-*.yml` 生成：
  **只编启动器，游戏二进制原样复制官方 nightly 包**。
- **补丁腐烂是唯一要持续盯的**：上游一改 `account.rs` / `cli.rs`，`git apply` 会失败。
  `probe-port.yml` 就是为此准备的——手动跑一次 `cargo check`，只看编译错误不发版，
  在真正发版前就能知道补丁还贴不贴得上。
- 当前**没有配置 `RELEASE_SIGNING_KEY`**，发布的是可直接使用的产物，不是可自动更新的
  签名通道；启动器已关掉自更新，所以不会把自己换回官方版。
