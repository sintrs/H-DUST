#!/usr/bin/env python3
"""把上游最新启动器改成「打开即离线、名字能改、不会被更新覆盖」的版本。

背景
----
上游从 0.2.79 起删掉了离线身份，并用 `--developer-single-player` 把开发者模式
锁成单人，另有一套「发现新版本就替换自己」的逻辑。

client 本身**原生支持离线身份连服务器**：`connect_remote_session` 在没有账号会话时
用的就是 `offline_uuid(name)`，`--name` 也早有定义（跟着 `--server` 一起传即可）。
所以 client 一行都不用动。

五处改动
--------
1. `developer_offline.rs::mark()`：不再注入 `--developer-single-player`；改成从
   启动器同目录的 `offline-name.txt` 读离线名，用 `--name` 传给 client。
2. 同文件 `enabled()`：`HORIZON_LAUNCHER_DEVELOPER_OFFLINE` 由「必须设为 1」改成
   「默认开，设 0 才关」——双击就是离线版，不需要包装脚本导环境变量。
3. `backend::self_update_allowed()` 恒为 false —— 否则会提示更新、并把官方包下载
   回来覆盖掉这个二进制，离线就没了。
4. `launcher_setup.rs::launcher_download_available()` 恒为 false —— 版本页不再出现
   「有新启动器可下载」的提示。
5. 新文件 `launcher/src/rust_offline_bootstrap.rs`：启动时把**与二进制同级**的
   `data/versions/*` 装进启动器数据目录并选中，并关掉「自动装新版」。
   这样解压后双击二进制即可，不需要任何安装脚本。
6. `main.rs`：`mod rust_offline_bootstrap;` + 在 `startup::run()` 之前调用。

`require_capability()` 不动：它只探测 client 的 `--launch-api`，client 没改，仍通过。
"""
import re
import sys
from pathlib import Path

MARK = "H-RUST offline patch"

BOOTSTRAP = '''//! H-RUST offline patch: a package that sits next to this binary installs itself.
//!
//! The release is `horizon-launcher` + `data/versions/<tag>/`: opening the binary
//! copies the bundled build into the launcher data folder and selects it, so the
//! player never runs an install script.

use std::fs;
use std::path::Path;

/// Copies `data/versions/*` beside the executable into the launcher data folder,
/// and selects the newest copied one when nothing is selected yet.
pub fn ensure() {
    let Ok(executable) = std::env::current_exe() else {
        return;
    };
    let Some(beside) = executable.parent() else {
        return;
    };
    let bundled = beside.join("data").join("versions");
    if !bundled.is_dir() {
        return;
    }
    let Ok(entries) = fs::read_dir(&bundled) else {
        return;
    };
    let mut tags: Vec<String> = entries
        .flatten()
        .filter(|entry| entry.path().is_dir())
        .filter_map(|entry| entry.file_name().into_string().ok())
        .collect();
    tags.sort();
    for tag in tags {
        let target = horizon_launcher::backend::version_dir(&tag);
        if target.is_dir() {
            continue;
        }
        if copy_tree(&bundled.join(&tag), &target).is_err() {
            // A half copy would look installed; take it back out.
            let _ = fs::remove_dir_all(&target);
            continue;
        }
        let mut settings = horizon_launcher::backend::Settings::load();
        let mut changed = false;
        if settings.selected.is_none() {
            settings.selected = Some(tag);
            changed = true;
        }
        // Pinned package: never chase upstream versions on its own.
        if settings.install_new_versions.is_none() {
            settings.install_new_versions = Some(false);
            changed = true;
        }
        if changed {
            let _ = settings.save();
        }
    }
}

fn copy_tree(from: &Path, to: &Path) -> std::io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        let kind = entry.file_type()?;
        if kind.is_dir() {
            copy_tree(&entry.path(), &target)?;
        } else if kind.is_file() {
            fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}
'''


def fail(msg: str) -> None:
    print(f"patch: {msg}", file=sys.stderr)
    raise SystemExit(1)


def edit(path: Path, pattern: str, replacement: str, what: str) -> None:
    """按 pattern 替换一次；已经改过（含标记）则跳过。"""
    src = path.read_text(encoding="utf-8")
    if MARK in src and replacement in src:
        return
    new, n = re.subn(pattern, replacement, src, count=1)
    if n != 1:
        fail(f"{what}: 未匹配到预期片段（上游可能改了这段），请重新核对 {path.name}")
    path.write_text(new, encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        fail("用法: patch_launcher_offline.py <上游源码根目录>")
    root = Path(sys.argv[1])
    offline = root / "launcher/src/developer_offline.rs"
    backend = root / "launcher/src/backend.rs"
    main_rs = root / "launcher/src/main.rs"
    setup = root / "launcher/src/launcher_setup.rs"
    bootstrap = root / "launcher/src/rust_offline_bootstrap.rs"
    for p in (offline, backend, main_rs, setup):
        if not p.is_file():
            fail(f"找不到 {p}")

    # 1) mark()：不注入单人锁，改用 offline-name.txt 定离线名。
    old_mark = (
        "pub fn mark(cmd: &mut Command) {\n"
        "    cmd.arg(FLAG)\n"
        '        .env_remove("HORIZON_SESSION_FILE")\n'
        '        .env_remove("HORIZON_ACCOUNT_SESSIONS")\n'
        '        .env_remove("HORIZON_LAUNCHER_EXE");\n'
        "}\n"
    )
    new_mark = (
        "pub fn mark(cmd: &mut Command) {\n"
        f"    // {MARK}：不注入 --developer-single-player。\n"
        "    // client 无会话时本就用 offline_uuid(--name)，注入该 flag 只会把\n"
        "    // 多人/LAN 一并锁死；离线身份由下面的 env_remove 保证。\n"
        '    cmd.env_remove("HORIZON_SESSION_FILE")\n'
        '        .env_remove("HORIZON_ACCOUNT_SESSIONS")\n'
        '        .env_remove("HORIZON_LAUNCHER_EXE");\n'
        f"    // {MARK}：离线名取启动器同目录的 offline-name.txt。\n"
        "    if let Some(name) = bundled_offline_name() {\n"
        '        cmd.arg("--name").arg(name);\n'
        "    }\n"
        "}\n"
        "\n"
        "/// The offline name in `offline-name.txt` beside the launcher, if it is usable.\n"
        "fn bundled_offline_name() -> Option<String> {\n"
        "    let directory = std::env::current_exe().ok()?.parent()?.to_path_buf();\n"
        '    let text = std::fs::read_to_string(directory.join("offline-name.txt")).ok()?;\n'
        "    let name: String = text\n"
        "        .lines()\n"
        '        .next()\n'
        '        .unwrap_or("")\n'
        "        .chars()\n"
        "        .filter(|c| c.is_ascii_alphanumeric() || *c == '_')\n"
        "        .take(16)\n"
        "        .collect();\n"
        "    (name.len() >= 3).then_some(name)\n"
        "}\n"
    )
    edit(offline, re.escape(old_mark), new_mark, "mark() 注入点")

    # 2) 离线默认开启（设 0 才关）。
    edit(
        offline,
        r'    if std::env::var_os\(ENV\)\.as_deref\(\) != Some\(std::ffi::OsStr::new\("1"\)\) \{\n'
        r"        return false;\n    \}",
        f"    // {MARK}：离线默认开启，只有显式设 ENV=0 才关。\n"
        '    if std::env::var_os(ENV).as_deref() == Some(std::ffi::OsStr::new("0")) {\n'
        "        return false;\n    }",
        "enabled() 默认开关",
    )

    # 3) 永不自我替换：不提示更新，也不会把补丁版覆盖回官方包。
    edit(
        backend,
        r"pub fn self_update_allowed\(\) -> bool \{\n"
        r'(    !cfg!\(debug_assertions\) && std::env::var_os\("HORIZON_LAUNCHER_NO_SELF_UPDATE"\)\.is_none\(\))\n\}',
        "pub fn self_update_allowed() -> bool {\n"
        f"    // {MARK}：这个二进制永不自我替换，否则会提示更新并覆盖掉离线补丁。\n"
        "    false\n}",
        "self_update_allowed()",
    )

    # 4) 随包自装：新文件。
    if MARK not in bootstrap.read_text(encoding="utf-8") if bootstrap.exists() else True:
        bootstrap.write_text(BOOTSTRAP, encoding="utf-8")

    # 5) main() 里挂上自装。
    edit(
        setup,
        r"    pub\(crate\) fn launcher_download_available\(&self\) -> bool \{\n"
        r"        !backend::package_managed_launcher\(\)\n    \}",
        "    pub(crate) fn launcher_download_available(&self) -> bool {\n"
        f"        // {MARK}：本包不提示更新、不提供「下载新启动器」。\n"
        "        false\n    }",
        "launcher_download_available()",
    )

    edit(
        main_rs,
        r"fn main\(\) \{\n    startup::run\(\);\n\}",
        "mod rust_offline_bootstrap;\n"
        "\n"
        "fn main() {\n"
        f"    // {MARK}：把随包的 data/versions 装进启动器数据目录并选中。\n"
        "    rust_offline_bootstrap::ensure();\n"
        "    startup::run();\n"
        "}",
        "main() 自装入口",
    )

    # 顺带改掉会误导人的提示（原文案说 single-player only）。
    src = offline.read_text(encoding="utf-8")
    src = src.replace(
        'pub const NOTICE: &str = "Offline developer session: single-player only; no account features.";',
        'pub const NOTICE: &str = "Offline developer session: no account features; '
        'single-player, multiplayer and LAN use an offline identity.";',
    )
    offline.write_text(src, encoding="utf-8")

    # 自检：改完必须满足下面几条，否则说明补丁没有真正生效。
    after = offline.read_text(encoding="utf-8")
    back = backend.read_text(encoding="utf-8")
    entry = main_rs.read_text(encoding="utf-8")
    boot = bootstrap.read_text(encoding="utf-8") if bootstrap.exists() else ""
    checks = [
        (MARK in after, "补丁标记缺失"),
        ("cmd.arg(FLAG)" not in after, "mark() 仍在注入 --developer-single-player"),
        ('cmd.env_remove("HORIZON_SESSION_FILE")' in after, "mark() 的 env_remove 链被破坏"),
        ("bundled_offline_name()" in after, "离线名读取缺失"),
        ('Some(std::ffi::OsStr::new("0"))' in after, "enabled() 未改成默认开启"),
        ("pub fn validate(cmd: &Command) -> Result<(), String> {" in after, "validate 签名被破坏"),
        ("HORIZON_LAUNCHER_NO_SELF_UPDATE\"))" not in back, "self_update_allowed() 未关掉"),
        (MARK in back, "backend.rs 补丁标记缺失"),
        (MARK in boot and "pub fn ensure()" in boot, "自装模块缺失"),
        ("launcher_download_available" in setup.read_text(encoding="utf-8")
         and "!backend::package_managed_launcher()" not in setup.read_text(encoding="utf-8"),
         "launcher_download_available() 未关掉"),
        ("rust_offline_bootstrap::ensure();" in entry, "main() 未调用自装"),
        ("startup::run();" in entry, "main() 被破坏"),
    ]
    for ok, msg in checks:
        if not ok:
            fail(msg)
    print("patch: 自检通过（默认离线 + 离线名 + 不自更新 + 随包自装）")


if __name__ == "__main__":
    main()
