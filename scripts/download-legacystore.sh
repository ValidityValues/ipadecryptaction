#!/usr/bin/env bash
set -Eeuo pipefail

APP_ID="$1"
TARGET_IOS="$2"
WORKDIR="$3"

mkdir -p "$WORKDIR"
rm -f "$WORKDIR/candidates.json"

api="https://legacystore.app/api/v1/apps/$APP_ID"

if ! curl -fsSL --retry 3 --retry-all-errors --max-time 30 "$api" -o "$WORKDIR/app.json"; then
  echo "::warning::Legacy Store API could not load App Store ID $APP_ID."
  exit 2
fi

python3 - "$WORKDIR/app.json" "$TARGET_IOS" "$WORKDIR/candidates.json" <<'PY'
import json
import re
import sys
from pathlib import Path

src, target, out = sys.argv[1:]

def version(s):
    parts=[int(x) for x in re.findall(r"\d+", str(s or ""))]
    parts += [0] * (8-len(parts))
    return tuple(parts[:8])

with open(src, encoding="utf-8") as f:
    app=json.load(f)

candidates=[]
for item in app.get("versions", []):
    if not isinstance(item, dict):
        continue

    minimum=str(item.get("minimum_os_version") or "").strip()
    if minimum and version(minimum) > version(target):
        continue

    for copy in item.get("copies", []):
        if not isinstance(copy, dict):
            continue
        if copy.get("install_status") != "installable":
            continue

        url=str(copy.get("download_url") or "").strip()
        if not url:
            continue

        candidates.append({
            "name": str(app.get("name") or ""),
            "bundleIdentifier": str(app.get("bundle_id") or ""),
            "version": str(item.get("version") or ""),
            "buildVersion": "",
            "date": "",
            "minOSVersion": minimum,
            "downloadURL": url,
            "source": "Legacy Store",
            "ipa_id": str(copy.get("ipa_id") or ""),
            "sha1": str(copy.get("sha1") or ""),
            "install_status": "installable"
        })

candidates.sort(
    key=lambda x:(version(x["version"]), version(x["buildVersion"]), x["date"]),
    reverse=True
)

Path(out).write_text(
    json.dumps(candidates, ensure_ascii=False, indent=2),
    encoding="utf-8"
)

print(
    f"Legacy Store: {len(candidates)} installable compatible copies "
    f"for {app.get('name','unknown')}"
)

for x in candidates[:15]:
    print(
        f"- {x['version']} (min iOS {x['minOSVersion'] or 'unknown'}) "
        f"ipa_id={x['ipa_id']}"
    )
PY
