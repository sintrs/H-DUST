#!/usr/bin/env bash
# Packaged-build smoke test: the binary that a player actually unzips, run for real.
#
# The launcher build step already ran `--version`, but that proves nothing about the
# offline layer: a build where the owner gate came back on, or where the offline name
# stopped being honoured, compiles fine and then refuses to start the game. This runs
# the packaged binary in a throwaway data folder and checks the offline behaviour.
#
# Usage:
#   bash tools/ci/smoke-offline-package.sh <package.tar.gz> <version tag>
#
# Exit code 0: the package starts, lists its bundled build, keeps an offline name, and
# resolves a launch without a Microsoft account. 1: one of those broke, named in the log.
set -uo pipefail

TGZ=${1:?usage: smoke-offline-package.sh <package.tar.gz> <version tag>}
TAG=${2:?usage: smoke-offline-package.sh <package.tar.gz> <version tag>}

TOP=horizon-offline-linux-x86_64
# /tmp is small on some runners and this unpacks a ~200 MB build, so prefer a roomier temp.
mkdir -p "${SMOKE_TMPDIR:-${TMPDIR:-/var/tmp}}"
BASE=$(mktemp -d "$( cd "${SMOKE_TMPDIR:-${TMPDIR:-/var/tmp}}" && pwd )/h-smoke.XXXXXX")
LOG="$BASE/smoke.log"
FAILS=0

cleanup() { [[ "${KEEP_SMOKE:-0}" == 1 ]] && echo "kept: $BASE" || rm -rf "$BASE"; }
trap cleanup EXIT
: > "$LOG"

say() { echo "-- $*"; }
bad() { echo "::error title=Offline package smoke test::$*"; FAILS=$((FAILS + 1)); }

# run <label> <cmd...>: run it, logging both streams; 0 if it exited 0.
run() {
  local label=$1
  shift
  echo "### $label" >> "$LOG"
  if "$@" >> "$LOG" 2>&1; then
    say "ok   $label"
    return 0
  fi
  local code=$?
  say "FAIL $label (exit $code)"
  return $code
}

show_log() { sed 's/^/     | /' "$LOG" | tail -30; }

say "unpacking $TGZ"
mkdir -p "$BASE/extract"
if ! tar -xzf "$TGZ" -C "$BASE/extract" --no-same-owner --touch; then
  bad "cannot unpack $TGZ"
  exit 1
fi
PKG="$BASE/extract/$TOP"
[[ -x "$PKG/horizon-launcher" ]] || { bad "the package has no executable horizon-launcher"; exit 1; }
[[ -d "$PKG/data/versions/$TAG" ]] || { bad "the package has no bundled build at data/versions/$TAG"; exit 1; }
[[ -f "$PKG/data/versions/$TAG/.installed" ]] \
  || bad "the bundled build $TAG has no .installed marker, so the launcher never lists it"
[[ -f "$PKG/data/versions/$TAG/horizon-client" ]] \
  || bad "the bundled build $TAG has no horizon-client to play"

# A throwaway home: the first start has to populate it from data/versions. Both
# HORIZON_LAUNCHER_HOME (what data_dir() reads first) and HOME/XDG are redirected so
# nothing here can touch the runner's real state.
export HORIZON_LAUNCHER_HOME="$BASE/home"
mkdir -p "$HORIZON_LAUNCHER_HOME"
export HOME="$BASE/userhome"
export XDG_DATA_HOME="$BASE/userhome/.local/share"
export XDG_CONFIG_HOME="$BASE/userhome/.config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
export NO_AT_BRIDGE=1
# There is no keyring on a CI runner. Without this the launcher waits KEYCHAIN_WAIT for
# one before falling back to its file store, and `account list` can come back empty.
export HORIZON_NO_KEYCHAIN=1

L="$PKG/horizon-launcher"

say "1. the packaged binary starts"
if OUT=$("$L" --version 2>&1); then
  echo "$OUT" >> "$LOG"
  if [[ "$OUT" == horizon-launcher* ]]; then
    say "ok   --version -> $OUT"
  else
    bad "--version printed something unrecognisable: $OUT"
  fi
else
  bad "--version exited non-zero: $(echo "$OUT" | head -3)"
fi

say "2. first start installs the bundled build (horizon_bundle::ensure)"
# `ensure()` runs inside main() before any command, so any CLI call triggers it.
run "account list" "$L" account list || show_log
if [[ -f "$HORIZON_LAUNCHER_HOME/versions/$TAG/.installed" ]] \
   || [[ -f "$HORIZON_LAUNCHER_HOME/versions/$TAG/horizon-client" ]]; then
  say "ok   the bundled build was copied into $HORIZON_LAUNCHER_HOME/versions"
else
  bad "the bundled build was not installed into the data folder: a fresh unzip would show an empty version list (horizon_bundle::ensure did not run, or main() no longer calls it)"
  ls -R "$HORIZON_LAUNCHER_HOME" >> "$LOG" 2>&1
  show_log
fi

say "3. the bundled build is listed as a normal installed version"
if run "versions --installed" "$L" versions --installed --json; then
  # `versions --installed --json` prints one {"installed": [...], "selected": ...} object;
  # take the last JSON object in the log so progress lines above it do not matter.
  if python3 - "$TAG" "$LOG" <<'PY'
import json, re, sys
tag, log = sys.argv[1], sys.argv[2]
text = open(log, encoding="utf-8", errors="replace").read()
found = None
for m in re.finditer(r"\{.*\}", text, re.DOTALL):
    try:
        data = json.loads(m.group(0))
    except Exception:
        continue
    if isinstance(data, dict) and "installed" in data:
        found = data
if found is None:
    sys.exit(2)
sys.exit(0 if tag in (found.get("installed") or []) else 1)
PY
  then
    say "ok   $TAG is in the installed list"
  else
    case $? in
      2) bad "\`versions --installed --json\` printed no JSON; the CLI shape changed" ;;
      *) bad "$TAG is not in \`versions --installed\`: the bundled copy is unreadable as a normal version (a developer-looking name, or the marker did not land)" ;;
    esac
    show_log
  fi
else
  show_log
fi

say "4. an offline name is kept and selected (no Microsoft account needed)"
if run "account offline SmokeTest_" "$L" account offline SmokeTest_; then
  # Stored, then read back: `offline_selected` in accounts.json is what the game is
  # launched with, and `account list` marking it is what the player sees.
  SAVED="$HORIZON_LAUNCHER_HOME/accounts.json"
  if [[ -f "$SAVED" ]] && grep -q '"offline_selected": "SmokeTest_"' "$SAVED"; then
    say "ok   accounts.json keeps SmokeTest_ as the name that plays"
  else
    bad "accounts.json does not record SmokeTest_ in offline_selected; the name was not kept"
    [[ -f "$SAVED" ]] && sed 's/^/     | /' "$SAVED" | head -20
  fi
  LIST=$("$L" account list 2>&1)
  echo "$LIST" >> "$LOG"
  if grep -qE '^\* SmokeTest_  offline' <<< "$LIST"; then
    say "ok   account list shows SmokeTest_ as the name in play"
  else
    bad "account list does not show SmokeTest_ as the offline name in play; it was stored but is ignored"
    echo "$LIST" | sed 's/^/     | /'
  fi
else
  bad "\`account offline SmokeTest_\` failed; the offline command is gone from the CLI"
  show_log
fi

say "5. the launch resolves without an owner (the gate is open)"
# `play` is the code path the patch edits. In order it: reads the sign-in -- which on a
# build with the gate closed is where an offline-only player is refused -- then checks the
# version is prepared. This package has no Minecraft 26.3 resources, so a working build
# always stops at "is not prepared yet", *after* the account step. Stopping there is the
# proof; being refused for want of an owner is the regression.
PLAY=$(timeout 300 "$L" play --version "$TAG" 2>&1 | head -60)
echo "$PLAY" >> "$LOG"
if grep -qiE "own(s)? the game|own Minecraft|sign in with a Microsoft account|no signed-in account" <<< "$PLAY"; then
  bad "play refused for want of an account that owns the game; the offline gate (GATE_OPEN) is closed again"
  echo "$PLAY" | sed 's/^/     | /'
elif grep -q "is not prepared yet" <<< "$PLAY"; then
  say "ok   play read the sign-in and asked for no account; it stopped only at the missing game resources"
else
  say "note: play ended with: $(echo "$PLAY" | head -3 | tr '\n' ' ')"
fi

say "6. this build will not replace itself with upstream's"
# `update` prints "does not replace itself" when self_update_allowed() is false -- which is
# what the patch pins. A build where that pin is gone would offer to install upstream's
# launcher, dropping the offline layer at the next start. No network is a skip, not a
# pass: an empty output proves nothing.
UPDATE_OUT=$(timeout 90 "$L" update 2>&1) || UPDATE_RC=$?
echo "$UPDATE_OUT" >> "$LOG"
if [[ "${UPDATE_RC:-0}" -ne 0 && -z "$UPDATE_OUT" ]]; then
  say "note: update needs the network; skipped on this runner"
elif grep -qi "does not replace itself" <<< "$UPDATE_OUT"; then
  say "ok   update says it will not replace itself"
elif grep -qiE "updated to|Updating the launcher|installed .*launcher" <<< "$UPDATE_OUT"; then
  bad "update installed a launcher over this build: self_update_allowed() is no longer pinned to false"
  echo "$UPDATE_OUT" | sed 's/^/     | /'
else
  say "note: could not tell from update's output: $(head -2 <<< "$UPDATE_OUT" | tr '\n' ' ')"
fi

echo
if [[ "$FAILS" -gt 0 ]]; then
  echo "::error title=Offline package smoke test::$FAILS check(s) failed for $TAG"
  echo "--- smoke.log ---"
  cat "$LOG" 2>/dev/null | tail -60 || true
  exit 1
fi
echo "smoke test passed for $TAG"
