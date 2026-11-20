#!/usr/bin/env python3
"""把上游最新启动器改成「离线可玩、可连服务器」的版本（最小改动）。

背景
----
上游从 0.2.79 起删掉了离线身份，并用 `--developer-single-player` 把开发者模式
锁成单人：

  - `launcher/src/developer_offline.rs::mark()` 往命令行注入该 flag；
  - 同文件 `validate()` 见到 `--server` / `--quickPlayMultiplayer` 等就报错；
  - `crates/horizon-client/.../developer_launch.rs` 在 client 里再拦一层。

为什么只改一行就够
------------------
client 本身**原生支持离线身份连服务器**：`connect_remote_session` 在没有账号
会话时用的就是 `offline_uuid(name)`，`--name` 也早有定义。所有网络锁都只挂在
`developer_single_player` 这个开关上。

于是只要 `mark()` 不注入该 flag：

  * `validate(cmd)` 里 `offline` 恒为 false，所有网络校验自动跳过，无需改它；
  * `require_capability()` 只探测 client 的 `--launch-api`，client 没改，仍通过；
  * client 走正常启动路径 → 单人、多人、LAN 全部可用，且玩家身份是离线 UUID。

这样 gerdaroot 当年靠整树 fork 才做到的效果，现在只需删掉一次 `.arg(FLAG)`。
"""
import re
import sys
from pathlib import Path

MARKER = "H-RUST offline patch"


def fail(msg: str) -> None:
    print(f"patch: {msg}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    if len(sys.argv) != 2:
        fail("用法: patch_launcher_offline.py <上游源码根目录>")
    root = Path(sys.argv[1])
    target = root / "launcher/src/developer_offline.rs"
    if not target.is_file():
        fail(f"找不到 {target}")

    src = target.read_text(encoding="utf-8")
    if MARKER in src:
        print("patch: 已打过补丁，跳过")
    else:
        # 只动 mark() 的这一处注入：cmd.arg(FLAG) 换成 cmd。
        # 保留后续 .env_remove 链，确保不会继承到真实账号会话而变成 online 身份。
        pattern = r'    cmd\.arg\(FLAG\)\n        \.env_remove\("'
        replacement = (
            f"    // {MARKER}：不注入 --developer-single-player。\n"
            "    // client 无会话时本就用 offline_uuid(--name)，注入该 flag 只会把\n"
            "    // 多人/LAN 一并锁死；离线身份由下面的 env_remove 保证。\n"
            '    cmd.env_remove("'
        )
        src, n = re.subn(pattern, replacement, src, count=1)
        if n != 1:
            fail(
                "mark() 未匹配到预期片段（上游可能改了这段），"
                "请重新核对 launcher/src/developer_offline.rs"
            )

        # 顺带改掉会误导人的终端提示（原文案说 single-player only）。
        src = src.replace(
            'pub const NOTICE: &str = "Offline developer session: single-player only; no account features.";',
            'pub const NOTICE: &str = "Offline developer session: no account features; '
            'single-player, multiplayer and LAN use an offline identity.";',
        )
        target.write_text(src, encoding="utf-8")
        print("patch: launcher/src/developer_offline.rs 已修改")

    # 自检：改完必须满足下面几条，否则说明补丁没有真正生效。
    after = target.read_text(encoding="utf-8")
    checks = [
        (MARKER in after, "补丁标记缺失"),
        ("cmd.arg(FLAG)" not in after, "mark() 仍在注入 --developer-single-player"),
        ('cmd.env_remove("HORIZON_SESSION_FILE")' in after, "mark() 的 env_remove 链被破坏"),
        ("pub fn validate(cmd: &Command) -> Result<(), String> {" in after, "validate 签名被破坏"),
    ]
    for ok, msg in checks:
        if not ok:
            fail(msg)
    print("patch: 自检通过（不注入单人锁，client 走正常路径：单人 + 多人 + LAN）")


if __name__ == "__main__":
    main()
