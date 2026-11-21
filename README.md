# H-RUST

跟上游 nightly 走，把启动器的离线账号层用补丁带回来，打成解压即用的 Linux 包。

## 用

Actions 里点最近一次 `Build offline` 的运行，页面底部 **Artifacts** 下载
`horizon-offline-nightly-...`，里面是 `horizon-offline-linux-x86_64-offline.tar.gz`。
解压后直接运行里面的 `horizon-launcher`：

```bash
tar -xzf horizon-offline-linux-x86_64-offline.tar.gz
cd horizon-offline-linux-x86_64
./horizon-launcher
```

首次启动会把随包的 `data/versions/` 装进 `~/.local/share/horizon-launcher/`，选中该版本，
并关掉自动更新。之后不再需要这个解压目录（约占 180 MB，可以删）。

### 改名字

界面：**设置 → 账号 → Play offline**，输入名字点 **Use this name**。

命令行：

```bash
./horizon-launcher account offline YourName   # 加一个离线名并选中
./horizon-launcher account                    # 看现在是谁在玩
./horizon-launcher account select YourName    # 在多个名字间切换
./horizon-launcher account forget-offline YourName
```

顶栏会显示当前离线名；Home 标题旁显示实际版本 tag。

### 自检

```bash
./horizon-launcher --version    # horizon-launcher 2.4.4 = 打过补丁的
./horizon-launcher account list # * YourName  offline  有这行就对了
```

## 发

两条 workflow，都读上游 nightly，与 `state/*.json` 比对，没变化就跳过。只上传 Actions artifact
（保留 90 天），不发 Release：

| Workflow | Artifact | 内容 |
|---|---|---|
| `release-offline.yml` | `horizon-offline-nightly-...` | 打补丁的启动器 + 官方本体，一个包自足 |
| `release-game.yml` | `horizon-game-nightly-...` | 官方 nightly 包原样转发 |

同一个 nightly 上修 bug 重跑：手动 `Build offline`，勾 `force=true`，旧 artifact 留着不影响，
下载时认最新的运行编号。

`probe-port.yml` 是补丁探针，手动跑一次 `cargo check`（约 1 分钟），日志在 artifact `check-log`，
看 `error[E` 条数。

## 改

```bash
git clone https://github.com/sintrs/H-RUST.git && cd H-RUST
# 改 tools/ci/offline-port.patch、脚本、workflow
git add -A && git commit -m '...' && git push
```

补丁是唯一的真相：`launcher/src` 下的代码，加上 `launcher/Cargo.toml` 与 `launcher/Cargo.lock`
里的版本号（`2.4.4`，`--locked` 构建要求两者一致）。`crates/` 不动。

改补丁**不要手改 hunk 计数**：

```bash
# 干净的上游源码里
git apply tools/ci/offline-port.patch
# 改文件，然后
git add -A && git diff --cached > tools/ci/offline-port.patch
git stash -u && git apply --check tools/ci/offline-port.patch   # 确认能干净贴上
```

上游改了 `account.rs` / `frame.rs` / `cli.rs` 时 `git apply` 会红，跑一次 `probe-port.yml` 就知道。

### 两道闸

`git apply` 只看上下文行，不看行为：上游把一个函数改成空实现，补丁照样贴得干净，编出来也能跑，
只是离线层没了。所以打完补丁之后、打包之后各有一道检查：

| 检查 | 时机 | 抓什么 |
|---|---|---|
| `check-port-invariants.py` | 补丁贴完后 | 补丁依赖的 25 个上游契约（`GATE_OPEN`、`launch_for_game` 签名、`Player` 三态、`GameSession.name`、`.installed`、`data_dir()`、`nightly::date_of`…）。谁挪了就说谁挪了 |
| `smoke-offline-package.sh` | 打包装好之后 | 解开真实的包跑一次：二进制起得来、随包版本被装进数据目录、离线名存得住并生效、`play` 不被账号挡住、不会自我更新 |

两道都是真跑，不是 grep 过一遍就算。本地也能跑：

```bash
python3 tools/ci/check-port-invariants.py <打过补丁的源码目录>
bash tools/ci/smoke-offline-package.sh <离线包.tar.gz> <版本 tag>
```

## 文件

| 文件 | 作用 |
|---|---|
| `tools/ci/offline-port.patch` | 离线账号层移植补丁 |
| `tools/ci/build-linux.sh` | 编译 |
| `tools/ci/make-offline-package.sh` | 组装离线包 |
| `tools/ci/check-port-invariants.py` | 补丁依赖的上游契约检查 |
| `tools/ci/smoke-offline-package.sh` | 打包后的冒烟测试 |
| `tools/ci/monitor_upstream.py` | 解析上游 nightly 与 state 比较 |
| `.github/workflows/release-offline.yml` | 离线链路 |
| `.github/workflows/release-game.yml` | 本体链路 |
| `.github/workflows/probe-port.yml` | 补丁编译探针 |

## 限制

只出 Linux x86_64，glibc ≥ 2.35。本体不重编，直接用官方 nightly 的产物。
