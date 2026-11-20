//! H-RUST offline package: the game build ships beside the launcher.
//!
//! Unzipping the package and opening the launcher is all a player does. On start, every version
//! bundled in `data/versions` next to the executable is copied into the launcher data directory
//! once (it is skipped when `.installed` is already there), the first of them is selected, and
//! automatic version installs are turned off: this build follows its own package, not upstream.
//!
//! Nothing here touches account, session or network state; it only lays files down.

use std::path::{Path, PathBuf};

/// The marker the launcher writes into a version directory it may start (`backend::COMPLETE`).
const COMPLETE: &str = ".installed";

fn exe_dir() -> Option<PathBuf> {
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(Path::to_path_buf))
}

/// Copies `from` into `to` recursively: files, directories, and the permissions that make the
/// game binaries executable.
fn copy_tree(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)?.flatten() {
        let source = entry.path();
        let target = to.join(entry.file_name());
        let kind = entry.file_type()?;
        if kind.is_dir() {
            copy_tree(&source, &target)?;
        } else if kind.is_symlink() {
            // The package keeps no symlinks; anything that is one is copied as its target so the
            // game never depends on where it was unpacked.
            match std::fs::canonicalize(&source) {
                Ok(real) if real.is_dir() => copy_tree(&real, &target)?,
                Ok(real) => {
                    std::fs::copy(&real, &target)?;
                }
                Err(_) => {}
            }
        } else {
            std::fs::copy(&source, &target)?;
        }
    }
    Ok(())
}

/// Installs the bundled versions, once each, into the launcher data directory.
pub fn ensure() {
    let Some(root) = exe_dir() else {
        return;
    };
    let bundled = root.join("data").join("versions");
    if !bundled.is_dir() {
        return;
    }
    let versions = horizon_launcher::backend::data_dir().join("versions");
    // A package run with HORIZON_LAUNCHER_HOME pointing at itself has nothing to copy.
    if same_dir(&bundled, &versions) {
        return;
    }
    let Ok(entries) = std::fs::read_dir(&bundled) else {
        return;
    };
    let mut names: Vec<String> = entries
        .flatten()
        .filter(|e| e.path().is_dir())
        .filter_map(|e| e.file_name().into_string().ok())
        .collect();
    names.sort();
    let mut ready: Vec<String> = Vec::new();
    for name in names {
        let target = versions.join(&name);
        if !target.join(COMPLETE).is_file() {
            if copy_tree(&bundled.join(&name), &target).is_err() {
                continue;
            }
            let _ = std::fs::write(target.join(COMPLETE), b"");
        }
        ready.push(name);
    }
    if ready.is_empty() {
        return;
    }
    let mut settings = horizon_launcher::backend::Settings::load();
    let mut changed = false;
    if settings.selected.is_none() {
        settings.selected = ready.first().cloned();
        changed = true;
    }
    // This package ships its game build: never chase upstream Nightlies on its own.
    if settings.install_new_versions.is_none() {
        settings.install_new_versions = Some(false);
        changed = true;
    }
    if changed {
        let _ = settings.save();
    }
}

/// Whether two paths name the same directory, without requiring either to exist as given.
fn same_dir(a: &Path, b: &Path) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}
