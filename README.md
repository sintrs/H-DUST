# H-RUST

跟上游 nightly 走，打个补丁，做成解压即用的 Linux 包。

## 用

Releases 页的 `nightly-offline`，附件就是最新的包（每次构建覆盖，只有一个）：

```bash
tar -xzf horizon-linux-x86_64-offline.tar.gz
./horizon-launcher
```

包内没有套一层目录，解开就是 `horizon-launcher` 和 `data/`，不用再 `cd`。

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

## 发

两条 workflow，都读上游 nightly，与 `state/*.json` 比对，没变化就跳过。产物发到**滚动 Release**：
每个 workflow 一个固定 tag，每次构建覆盖附件，所以仓库里始终只有两个 Release。

| Workflow | Release tag | 附件 |
|---|---|---|
| `release-offline.yml` | `nightly-offline` | `horizon-linux-x86_64-offline.tar.gz` — 启动器 + 本体，一个包自足 |
| `release-game.yml` | `nightly-game` | `horizon-linux-x86_64-game.tar.gz` — 上游 nightly 包原样转发 |

两个附件同一个前缀，后缀说明是什么：`-offline` 是打过补丁的包，`-game` 是官方原件。

每次运行另留一份 artifact（保留 3 天），方便核对某一次的具体产物。

同一个 nightly 上修 bug 重跑：手动 `Build offline`，勾 `force=true`，附件会被覆盖。

## 改

```bash
git clone https://github.com/sintrs/H-RUST.git && cd H-RUST
# 改 tools/ci/offline-port.patch、脚本、workflow
git add -A && git commit -m '...' && git push
```

补丁是唯一的真相。改补丁不要手改 hunk 计数：

```bash
# 干净的上游源码里
git apply tools/ci/offline-port.patch
# 改文件，然后
git add -A && git diff --cached > tools/ci/offline-port.patch
git stash -u && git apply --check tools/ci/offline-port.patch   # 确认能干净贴上
```

上游改了相关源文件时 `git apply` 会红，跑一次 `probe-port.yml` 就知道。

### 两道闸

`git apply` 只看上下文行，不看行为：上游把一个函数改成空实现，补丁照样贴得干净，编出来也能跑，
只是功能没了。所以打完补丁之后、打包之后各有一道检查：

| 检查 | 时机 | 抓什么 |
|---|---|---|
| `check-port-invariants.py` | 补丁贴完后 | 补丁依赖的 25 个上游契约。谁挪了就说谁挪了 |
| `smoke-offline-package.sh` | 打包装好之后 | 解开真实的包跑一次：二进制起得来、随包版本被装进数据目录、离线名存得住并生效、`play` 不被账号挡住、不会自我更新 |

两道都是真跑，不是 grep 过一遍就算。本地也能跑：

```bash
python3 tools/ci/check-port-invariants.py <打过补丁的源码目录>
bash tools/ci/smoke-offline-package.sh <离线包.tar.gz> <版本 tag>
```

## 限制

只出 Linux x86_64，glibc ≥ 2.35。本体不重编，直接用上游 nightly 的产物。
