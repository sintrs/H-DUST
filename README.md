# Horizon · Linux 离线包

这个仓库不含 Horizon 的源码，只放**一个移植补丁**、两个打包/监控脚本和三条 workflow：
上游 nightly 一变，现场拉源码、只编启动器、游戏本体原样复制，打成「解压就能玩」的包发出去。

## 为什么要它

上游 0.2.79 起删掉了离线身份 —— 11-09 的 `1e789800af` 把 `Player::Offline`、`add_offline`、
`offline_selected` 整段删除，没有正版微软账号就进不去；此后只剩 `--developer-single-player`
那条开发者通道，而它把多人和 LAN 一起锁死。

`gerdaroot/Horizon-Offline-Launcher` 能无账号开局，但那是 10-29 上传的**孤儿快照**，基线冻在
11-08 之后不再跟上游，没法 `merge`（11-08→11-19 之间启动器 +23706/−16953、`main.rs` 拆走
5281 行、`horizon-mods` 拆成 18 个 crate）。

所以这里把两件事拆开：

| 部件 | 来源 | 说明 |
|---|---|---|
| 游戏本体 | 官方 nightly 包 `horizon-linux-x86_64.tar.gz` | 一个字节不改，直接复制 |
| 启动器 | 同一 nightly 的**上游源码** + `tools/ci/offline-port.patch` | 把离线账号层移植回来，再编译 |

## 两条链路

| Workflow | 产物 | tag | state |
|---|---|---|---|
| `release-game.yml` | 官方 nightly 包原样复制（自带官方启动器） | `nightly-YYYY-MM-DD-xxxxxxx-game` | `state/game.json` |
| `release-offline.yml` | 自编离线启动器 + 官方游戏，一个包自足 | `nightly-YYYY-MM-DD-xxxxxxx-offline` | `state/offline.json` |

两者都用 `tools/ci/monitor_upstream.py` 读 `horizon-rust/horizon/releases`，解析
`Nightly YYYY-MM-DD · xxxxxxx` 与各自 state 比较：没变化跳过，变了才构建。
同一个 nightly 上重发（修 bug）会**覆盖同名 release 的资产与说明**，不新增 tag。

## 补丁改了什么

`tools/ci/offline-port.patch` —— 16 个文件、+540/−89 行，全部在 `launcher/src`，`crates/` 一行未动。
client 本来就用 `offline_uuid(name)` 算身份，不需要改游戏本体。

| 文件 | 改的什么 |
|---|---|
| `account.rs` | 恢复 `offline` 名单、`offline_selected`、`Player`、`add_offline`、`name_arg`；`GATE_OPEN = true` 打开拥有者门；`GameSession` 加 `name` |
| `cli.rs` | `account offline NAME` / `forget-offline` / `select` 认离线名 |
| `glass_account.rs` | 账号页新增 **Play offline** 卡片：输入框直接改离线名 |
| `switch_page.rs` | 顶栏 `who_plays()` 按 `accounts.player()` 三态取名（微软账号 / 离线名 / 游戏自造名） |
| `frame.rs` | 有名字就显示账号胶囊；选中离线名时不再显示「Sign in with Microsoft」 |
| `glass_sheet.rs` | 离线版没有「最新版」概念，版本按钮显示包内实际 tag |
| `horizon_bundle.rs`（新增） | 启动时把随包 `data/versions` 装进数据目录、写 `.installed`、选中、关掉自动装新版 |
| `backend.rs` | `self_update_allowed()` 恒 false，不再把自己换回官方版 |
| `launcher_setup.rs` | `launcher_download_available()` 恒 false，不再提示下载新启动器 |
| `developer_play.rs` / `backend/developer_play.rs` | `GameSession { name }` 解构后 `--name <离线名>` 传给 client |
| `titlebar.rs` | 窗口标题改为 `Horizon Offline` |

**版本目录没有 `developer-` 前缀**：那是上游开发者通道的判据（`is_developer()` 只看目录名 +
`.installed` + `developer.json`）。移植版走正常账号路径，目录就是
`data/versions/nightly-YYYY-MM-DD-xxxxxxx/`，启动器当普通版本对待。

## 包里有什么

```
horizon-offline-linux-x86_64/
  horizon-launcher                 自编，打了离线补丁
  data/versions/nightly-.../       官方 nightly 游戏，原样复制（含 .installed）
  PLAY-OFFLINE.txt
```

没有安装脚本、没有 `run-offline.sh`、没有 `offline-name.txt`。解压后直接打开
`horizon-launcher`，它自己把随包版本装进 `~/.local/share/horizon-launcher/` 并选中。

离线名在 **设置 → 账号 → Play offline** 里改，或者：

```bash
./horizon-launcher account offline YourName
./horizon-launcher account                 # 看现在是谁在玩
./horizon-launcher account forget-offline YourName
```

> 连 `online-mode=true` 的正版服务器仍会被服务端拒绝 —— 这是离线身份的固有限制。
> 离线服（`online-mode=false`）和 LAN 不受影响。

首次进世界前，资源要从本机 Minecraft 导出一次（需要 Java 25），启动器会引导；
也可直接：

```bash
./horizon-launcher prepare --version nightly-YYYY-MM-DD-xxxxxxx
```

## 文件

| 文件 | 作用 |
|---|---|
| `tools/ci/offline-port.patch` | **唯一的真相**：离线账号层移植补丁，含新增的 `horizon_bundle.rs` |
| `tools/ci/build-linux.sh` | 编译（`launcher` / `game`），自动识别布局与 bin 所属包 |
| `tools/ci/make-offline-package.sh` | 组装离线包：自编启动器 + 官方游戏，无任何脚本 |
| `tools/ci/monitor_upstream.py` | 解析上游 nightly，与 state 比较 |
| `.github/workflows/release-offline.yml` | 离线链路：编启动器 + 打包 + 发布 |
| `.github/workflows/release-game.yml` | 本体链路：原样复制官方包 |
| `.github/workflows/probe-port.yml` | 手动 `cargo check` 探针，只验补丁还贴不贴得上，不发版 |

## 维护

本地改文件 → `git push` → GitHub 上跑，不要把上游源码 vendor 进仓库：

```bash
git clone https://github.com/sintrs/H-RUST.git
cd H-RUST
# 改 tools/ci/offline-port.patch、脚本、workflow
git add -A && git commit -m '...' && git push
```

- **补丁腐烂是唯一要持续盯的**：上游一改 `account.rs` / `frame.rs` / `cli.rs`，`git apply` 会红。
  `probe-port.yml` 就是为此准备的 —— 手动跑一次 `cargo check`（约 1 分钟），
  日志在 artifact `check-log` 里，看 `error[E` 的条数。
- **改补丁的正确姿势**：不要手改 hunk 计数。做法是干净源码 → `git apply` 现有补丁 →
  改文件 → `git add -A && git diff --cached > tools/ci/offline-port.patch` →
  再 `git stash -u` 后 `git apply --check` 确认能干净贴上。
- `state/*.json` 由 Actions 自动提交，手工只用于排查或回退。
- 当前**没有配置 `RELEASE_SIGNING_KEY`**：发的是可直接用的产物，不是可自动更新的签名通道；
  启动器已关掉自更新，不会把自己换回官方版。

## 已知限制

- 只出 Linux x86_64（glibc ≥ 2.35，与官方包同档）。
- 游戏本体不重编：`exporters/` 只能在上游自托管 runner 上编（要 Mojang 的 jar），
  公开 CI 拿不到，所以原样沿用官方包里的。
- 渲染取决于显卡驱动（Vulkan 1.0+ 或 OpenGL 4.x），与 glibc 无关。
