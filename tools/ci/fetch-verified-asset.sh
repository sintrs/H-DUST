#!/usr/bin/env bash
# Download one asset of the upstream nightly release and check it against the release's
# own SHA256SUMS.
#
# Both of our workflows copy the same game package; neither used to look at the release's
# checksum, so a truncated transfer or a swapped asset on the CDN would have shipped. The
# upstream publishes SHA256SUMS next to the assets (and a detached .sig over it); comparing
# against the checksum file catches the transfer going wrong, and comparing the checksum
# file against GitHub's own recorded digest for that asset catches the manifest itself
# having drifted from what GitHub stored.
#
# The .sig is a detached signature over SHA256SUMS. Verifying it needs the upstream's
# public key, which this repository does not carry; the digest GitHub records for the
# asset is the anchor used here instead.
#
# Usage:
#   bash tools/ci/fetch-verified-asset.sh <asset name> <output path>
#
# Exit code 0: the file is on disk and matches. 1: it does not (nothing is left behind).
set -uo pipefail

ASSET=${1:?usage: fetch-verified-asset.sh <asset name> <output path>}
OUT=${2:?usage: fetch-verified-asset.sh <asset name> <output path>}
REPO=horizon-rust/horizon
BASE="https://github.com/${REPO}/releases/download/nightly"

mkdir -p "$(dirname "$OUT")"
TMP="$OUT.part"
trap 'rm -f "$TMP"' EXIT

echo "==> $ASSET"
curl -fsSL --retry 3 --retry-all-errors -o "$TMP" "$BASE/$ASSET" \
  || { echo "::error title=Download failed::$ASSET could not be fetched"; exit 1; }
curl -fsSL --retry 3 --retry-all-errors -o "$TMP.sums" "$BASE/SHA256SUMS" \
  || { echo "::error title=Download failed::SHA256SUMS could not be fetched"; rm -f "$TMP.sums"; exit 1; }

# The line is "<sha256>  <name>"; take the one for our asset, exactly.
WANT=$(awk -v want="$ASSET" '$2 == want { print $1 }' "$TMP.sums")
if [[ -z "$WANT" ]]; then
  echo "::error title=Checksum missing::$ASSET is not listed in the release's SHA256SUMS"
  rm -f "$TMP.sums"
  exit 1
fi

GOT=$(sha256sum "$TMP" | cut -d' ' -f1)
if [[ "$GOT" != "$WANT" ]]; then
  echo "::error title=Checksum mismatch::$ASSET is $GOT, SHA256SUMS says $WANT"
  rm -f "$TMP.sums"
  exit 1
fi
echo "    sha256 $GOT matches SHA256SUMS"

# GitHub records a digest per asset. If it disagrees with SHA256SUMS, the manifest is not
# describing what GitHub is hosting, which is worth failing on rather than trusting.
if command -v gh >/dev/null 2>&1 || [[ -n "${GITHUB_TOKEN:-}" ]]; then
  API_DIGEST=$(curl -fsSL --retry 3 \
      -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/${REPO}/releases/tags/nightly" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for a in data.get("assets", []):
    if a.get("name") == sys.argv[1]:
        print((a.get("digest") or "").removeprefix("sha256:"))
        break
' "$ASSET" 2>/dev/null)
  if [[ -n "$API_DIGEST" && "$API_DIGEST" != "$GOT" ]]; then
    echo "::error title=Checksum disagrees with GitHub::SHA256SUMS says $WANT, GitHub records $API_DIGEST"
    rm -f "$TMP.sums"
    exit 1
  fi
  [[ -n "$API_DIGEST" ]] && echo "    GitHub records the same digest"
fi

rm -f "$TMP.sums"
mv "$TMP" "$OUT"
ls -lh "$OUT"
echo "    $OUT verified"
