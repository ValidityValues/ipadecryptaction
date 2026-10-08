#!/usr/bin/env bash
set -Eeuo pipefail

work="${RUNNER_TEMP}/ipa-public"
artifacts="${GITHUB_WORKSPACE}/artifacts"
rm -rf "$work" "$artifacts"
mkdir -p "$work/sources" "$artifacts"

[[ "$APP_STORE_URL" =~ /id([0-9]+)(/|$|\?) ]] || { echo "::error::Invalid App Store URL"; exit 1; }
APP_ID="${BASH_REMATCH[1]}"

python3 - "$TARGET_IOS" <<'PY'
import re,sys
if not re.fullmatch(r"\d+(?:\.\d+){0,3}",sys.argv[1]):
    raise SystemExit("invalid iOS version")
PY

curl -fsSL --retry 3 --retry-all-errors \
  "https://itunes.apple.com/lookup?id=$APP_ID&entity=software" > "$work/lookup.json"

readarray -t meta < <(python3 - "$work/lookup.json" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8") as f: d=json.load(f)
r=d.get("results") or []
if not r: raise SystemExit("App Store app not found")
i=r[0]
print(i.get("trackName",""))
print(i.get("bundleId",""))
print(i.get("trackViewUrl",""))
PY
)

APP_NAME="${meta[0]:-Unknown}"
BUNDLE_ID="${meta[1]:-}"
APP_STORE_LINK="${meta[2]:-$APP_STORE_URL}"
[[ -n "$BUNDLE_ID" ]] || { echo "::error::Bundle ID not found"; exit 1; }

printf '%s\n' "$SOURCE_URLS" > "$work/sources.txt"

python3 - "$BUNDLE_ID" "$TARGET_IOS" "$work/sources.txt" "$work/candidates.json" <<'PY'
import json,re,sys,urllib.request
from pathlib import Path

bundle,target,source_file,out_file=sys.argv[1:]
urls=Path(source_file).read_text().split()

def v(s):
    nums=[int(x) for x in re.findall(r"\d+",str(s or ""))]
    return tuple((nums+[0]*8)[:8])

def ok_min(s):
    return bool(s) and v(s)<=v(target)

def apps(obj):
    if isinstance(obj,dict):
        if isinstance(obj.get("apps"),list):
            for x in obj["apps"]:
                if isinstance(x,dict): yield x
        for x in obj.values():
            if isinstance(x,(dict,list)): yield from apps(x)
    elif isinstance(obj,list):
        for x in obj:
            if isinstance(x,(dict,list)): yield from apps(x)

candidates=[]
seen=set()

for src_i,url in enumerate(urls):
    if not url: continue
    try:
        req=urllib.request.Request(url,headers={"User-Agent":"ipadecryptaction/1.0"})
        with urllib.request.urlopen(req,timeout=30) as r:
            data=json.loads(r.read())
    except Exception as e:
        print(f"::warning::Source failed: {url}: {e}")
        continue

    for app in apps(data):
        if str(app.get("bundleIdentifier","")).strip()!=bundle:
            continue

        vs=app.get("versions")
        if not isinstance(vs,list):
            vs=[]
        if app.get("downloadURL"):
            vs=[app,*vs]

        for item in vs:
            if not isinstance(item,dict): continue
            dl=str(item.get("downloadURL","")).strip()
            ver=str(item.get("version","")).strip()
            minos=str(item.get("minOSVersion") or item.get("minimumOSVersion") or app.get("minOSVersion") or app.get("minimumOSVersion") or "").strip()
            if not dl or not ver or not ok_min(minos): continue
            key=(ver,dl)
            if key in seen: continue
            seen.add(key)
            candidates.append({
                "name":str(app.get("name","") or ""),
                "bundleIdentifier":bundle,
                "version":ver,
                "buildVersion":str(item.get("buildVersion","") or ""),
                "date":str(item.get("date","") or ""),
                "minOSVersion":minos,
                "downloadURL":dl,
                "source":url,
                "sourceIndex":src_i,
            })

candidates.sort(
    key=lambda x:(v(x["version"]),x["date"],v(x["buildVersion"])),
    reverse=True
)

Path(out_file).write_text(json.dumps(candidates,ensure_ascii=False,indent=2),encoding="utf-8")
print(f"Found {len(candidates)} compatible candidates")
for x in candidates[:10]:
    print(f"- {x['version']} (min iOS {x['minOSVersion']}) from {x['source']}")
PY

count="$(jq length "$work/candidates.json")"
[[ "$count" != "0" ]] || {
  echo "::error::No compatible IPA found in the configured public AltStore sources."
  echo "::error::Add a source JSON containing this Bundle ID."
  exit 1
}

candidate="$work/candidate.ipa"
selected_version=""
selected_build=""
selected_min=""
selected_url=""
selected_source=""

while IFS= read -r row; do
    url="$(jq -r '.downloadURL' <<<"$row")"
    source="$(jq -r '.source' <<<"$row")"
    advertised="$(jq -r '.version' <<<"$row")"

    echo "Downloading candidate $advertised from $source"
    rm -f "$candidate"
    if ! curl -fL --retry 3 --retry-all-errors --max-time 900 "$url" -o "$candidate"; then
        echo "::warning::Download failed: $url"
        continue
    fi
    [[ -s "$candidate" ]] || continue

    plist="$work/Info.plist"
    rm -f "$plist"
    info_path="$(unzip -Z1 "$candidate" 2>/dev/null | grep -E '^Payload/[^/]+\.app/Info\.plist$' | head -n1 || true)"
    [[ -n "$info_path" ]] || { echo "::warning::Not a normal IPA"; continue; }
    unzip -p "$candidate" "$info_path" > "$plist"

    readarray -t actual < <(python3 - "$plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],"rb") as f: d=plistlib.load(f)
print(str(d.get("CFBundleIdentifier","")).strip())
print(str(d.get("CFBundleShortVersionString","")).strip())
print(str(d.get("CFBundleVersion","")).strip())
print(str(d.get("MinimumOSVersion","")).strip())
PY
    )

    actual_bundle="${actual[0]:-}"
    actual_version="${actual[1]:-}"
    actual_build="${actual[2]:-}"
    actual_min="${actual[3]:-}"

    echo "IPA: bundle=$actual_bundle version=$actual_version build=$actual_build min_iOS=$actual_min"

    [[ "$actual_bundle" == "$BUNDLE_ID" ]] || { echo "::warning::Bundle mismatch"; continue; }

    python3 - "$TARGET_IOS" "$actual_min" <<'PY'
import sys
def v(s):
    p=[int(x) for x in s.split(".")]
    p += [0]*(4-len(p))
    return tuple(p[:4])
raise SystemExit(0 if v(sys.argv[2])<=v(sys.argv[1]) else 1)
PY

    selected_version="$actual_version"
    selected_build="$actual_build"
    selected_min="$actual_min"
    selected_url="$url"
    selected_source="$source"
    break
done < <(jq -c '.[]' "$work/candidates.json")

[[ -n "$selected_version" ]] || {
  echo "::error::No candidate passed final IPA verification."
  exit 1
}

safe_bundle="$(printf '%s' "$BUNDLE_ID" | tr -c 'A-Za-z0-9._-' '_')"
safe_version="$(printf '%s' "$selected_version" | tr -c 'A-Za-z0-9._-' '_')"
output="$artifacts/${safe_bundle}_${safe_version}.ipa"
mv "$candidate" "$output"

cat > "$artifacts/metadata.json" <<EOF
{
  "app_store_id": "$APP_ID",
  "app_store_url": "$APP_STORE_LINK",
  "app_name": "$APP_NAME",
  "bundle_id": "$BUNDLE_ID",
  "version": "$selected_version",
  "build": "$selected_build",
  "minimum_os_version": "$selected_min",
  "target_ios": "$TARGET_IOS",
  "source": "$selected_source",
  "download_url": "$selected_url",
  "package_state": "public AltStore-source IPA"
}
EOF

cat > "$artifacts/README.txt" <<EOF
App: $APP_NAME
Bundle ID: $BUNDLE_ID
Version: $selected_version
Build: $selected_build
Minimum iOS: $selected_min
Target iOS: $TARGET_IOS
Source: $selected_source

This is a public-source IPA, not Apple's authenticated App Store package.
It may be modified or unsigned.
EOF

echo "Selected $APP_NAME $selected_version ($selected_build), minimum iOS $selected_min"
