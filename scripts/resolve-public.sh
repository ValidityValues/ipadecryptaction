#!/usr/bin/env bash
set -Eeuo pipefail

WORKDIR="${RUNNER_TEMP}/appstore-public"
ARTIFACT_DIR="${GITHUB_WORKSPACE}/artifacts"

rm -rf "$WORKDIR" "$ARTIFACT_DIR"
mkdir -p "$WORKDIR" "$ARTIFACT_DIR"

if [[ "$APP_STORE_URL" =~ /id([0-9]+)(/|$|\?) ]]; then
  APP_ID="${BASH_REMATCH[1]}"
else
  echo "::error::Could not extract App Store ID from APP_STORE_URL."
  exit 1
fi

python3 - "$TARGET_IOS" <<'PY'
import re
import sys
if not re.fullmatch(r"\d+(?:\.\d+){0,3}", sys.argv[1]):
    raise SystemExit("invalid iOS version")
PY

curl -fsSL --retry 3 --retry-all-errors \
  "https://itunes.apple.com/lookup?id=$APP_ID&entity=software" \
  -o "$WORKDIR/lookup.json"

python3 - "$WORKDIR/lookup.json" "$ARTIFACT_DIR/metadata.json" <<'PY'
import json
import sys

src, dst = sys.argv[1:3]
with open(src, encoding="utf-8") as f:
    data=json.load(f)

results=data.get("results") or []
if not results:
    raise SystemExit("App Store app not found")

item=results[0]
out={
    "app_store_id": str(item.get("trackId", "")),
    "track_name": item.get("trackName", ""),
    "bundle_id": item.get("bundleId", ""),
    "current_version": item.get("version", ""),
    "current_minimum_ios": item.get("minimumOsVersion", ""),
    "seller": item.get("sellerName", ""),
    "price": item.get("formattedPrice", ""),
    "track_view_url": item.get("trackViewUrl", ""),
    "kind": item.get("kind", ""),
}
with open(dst,"w",encoding="utf-8") as f:
    json.dump(out,f,ensure_ascii=False,indent=2)
    f.write("\n")

print(json.dumps(out,ensure_ascii=False,indent=2))
PY

CURRENT_MIN="$(jq -r '.current_minimum_ios // empty' "$ARTIFACT_DIR/metadata.json")"

python3 - "$TARGET_IOS" "$CURRENT_MIN" <<'PY'
import sys

def v(s):
    p=[int(x) for x in s.split(".") if x != ""]
    p += [0]*(4-len(p))
    return tuple(p[:4])

target, minimum = map(v, sys.argv[1:3])
print(f"Target iOS: {sys.argv[1]}")
print(f"Current App Store minimum iOS: {sys.argv[2] or 'unknown'}")
print("Current listing is compatible." if target >= minimum else "Current listing requires a newer iOS.")
PY

cat > "$ARTIFACT_DIR/README.txt" <<EOF
This no-login workflow uses Apple's public iTunes Lookup metadata endpoint.

It does NOT download historical App Store binaries.

For an exact older App Store IPA chosen by iOS compatibility, use:
Actions -> Download compatible App Store IPA

That workflow requires an Apple Account because Apple's App Store download flow is authenticated.
EOF
