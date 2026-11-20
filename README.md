# H-RUST

自用。跟上游 nightly 走，把启动器的离线账号层用补丁带回来，打成解压即用的 Linux 包。

## 用

下载 `horizon-offline-linux-x86_64-offline.tar.gz`，解压，直接运行里面的 `horizon-launcher`：

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
./horizon-launcher --version    # horizon-launcher 0.2.0 = 打过补丁的
./horizon-launcher account list # * YourName  offline  有这行就对了
```

## 发

两条 workflow，都读上游 nightly，与 `state/*.json` 比对，没变化就跳过：

| Workflow | 产物 | tag |
|---|---|---|
| `release-offline.yml` | 打补丁的启动器 + 官方本体，一个包自足 | `nightly-...-offline` |
| `release-game.yml` | 官方 nightly 包原样转发 | `nightly-...-game` |

同一个 nightly 上修 bug 重发：手动 `Release offline`，勾 `force=true`，覆盖同名 release 的资产，
不新增 tag。

`probe-port.yml` 是补丁探针，手动跑一次 `cargo check`（约 1 分钟），日志在 artifact `check-log`，
看 `error[E` 条数。

## 改

```bash
git clone https://github.com/sintrs/H-RUST.git && cd H-RUST
# 改 tools/ci/offline-port.patch、脚本、workflow
git add -A && git commit -m '...' && git push
```

补丁是唯一的真相，全部改动都在 `launcher/src`，`crates/` 不动。

改补丁**不要手改 hunk 计数**：

```bash
# 干净的上游源码里
git apply tools/ci/offline-port.patch
# 改文件，然后
git add -A && git diff --cached > tools/ci/offline-port.patch
git stash -u && git apply --check tools/ci/offline-port.patch   # 确认能干净贴上
```

上游改了 `account.rs` / `frame.rs` / `cli.rs` 时 `git apply` 会红，跑一次 `probe-port.yml` 就知道。

## 文件

| 文件 | 作用 |
|---|---|
| `tools/ci/offline-port.patch` | 离线账号层移植补丁 |
| `tools/ci/build-linux.sh` | 编译 |
| `tools/ci/make-offline-package.sh` | 组装离线包 |
| `tools/ci/monitor_upstream.py` | 解析上游 nightly 与 state 比较 |
| `.github/workflows/release-offline.yml` | 离线链路 |
| `.github/workflows/release-game.yml` | 本体链路 |
| `.github/workflows/probe-port.yml` | 补丁编译探针 |

## 限制

只出 Linux x86_64，glibc ≥ 2.35。本体不重编，直接用官方 nightly 的产物。
