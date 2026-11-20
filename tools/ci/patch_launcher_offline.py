#!/usr/bin/env python3
"""Enable offline play on an upstream launcher after reverting 1e789800af."""
import sys
from pathlib import Path

MARK = "H-RUST offline patch"


def patch_backend(root: Path) -> None:
    path = root / "launcher/src/backend.rs"
    text = path.read_text()

    if MARK not in text:
        parse_at = text.find("pub fn parse(text: &str) -> Self {")
        if parse_at < 0:
            raise SystemExit("backend.rs: Settings::parse not found")
        anchor = "        if let Some(fields) = value.as_object_mut() {\n"
        at = text.find(anchor, parse_at)
        if at < 0:
            raise SystemExit("backend.rs: parse fields block not found")
        insert = (
            anchor
            + "            // "
            + MARK
            + ": offline names work without a signed-in owner.\n"
            + "            fields.insert(\"dev_offline\".to_string(), serde_json::json!(true));\n"
        )
        text = text[:at] + insert + text[at + len(anchor) :]
        text = "// " + MARK + "\n" + text

    old_update = (
        "pub fn self_update_allowed() -> bool {\n"
        "    !cfg!(debug_assertions) && std::env::var_os(\"HORIZON_LAUNCHER_NO_SELF_UPDATE\").is_none()\n"
        "}"
    )
    if old_update in text:
        text = text.replace(
            old_update,
            "// "
            + MARK
            + ": never replace the patched launcher with a signed upstream one.\n"
            + "pub fn self_update_allowed() -> bool {\n"
            + "    false\n"
            + "}",
            1,
        )

    path.write_text(text)


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_launcher_offline.py <upstream-source-root>")
    root = Path(sys.argv[1])
    if not (root / "launcher/src/backend.rs").is_file():
        raise SystemExit(f"no launcher/src/backend.rs under {root}")
    patch_backend(root)
    print("patched: dev_offline on, self-update off")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
