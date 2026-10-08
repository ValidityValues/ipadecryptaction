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

if [[ -n "${SOURCE_URLS//[[:space:]]/}" ]]; then
  printf '%s\n' "$SOURCE_URLS" > "$work/sources-extra.txt"
else
  : > "$work/sources-extra.txt"
fi

{
  cat "$GITHUB_WORKSPACE/config/public-sources.txt"
  cat "$work/sources-extra.txt"

  echo "::group::Refreshing public source catalog"
  if curl -fsSL --retry 3 --retry-all-errors --max-time 30 \
      "https://raw.githubusercontent.com/victordedomenico/awesome-altstore/main/README.md" \
      -o "$work/awesome-altstore.md"; then
    python3 - "$work/awesome-altstore.md" <<'PY'
import re
import sys
from pathlib import Path

text=Path(sys.argv[1]).read_text(encoding="utf-8",errors="replace")
for url in re.findall(r'\]\((https?://[^)\s]+)\)', text):
    if url.startswith(("https://awesome.re","http://awesome.re")):
        continue
    if "reddit.com/" in url:
        continue
    if "explore.alt.store" in url or "altsource.by.lao.sb" in url:
        continue
    print(url)
PY
  else
    echo "::warning::Could not refresh Awesome AltStore catalog; using bundled catalog."
  fi
  echo "::endgroup::"
} | tr '[:space:]' '\n' | sed '/^$/d' | awk '!seen[$0]++' > "$work/sources.txt"

echo "Checking $(wc -l < "$work/sources.txt") public sources..."

python3 - "$BUNDLE_ID" "$TARGET_IOS" "$work/sources.txt" "$work/candidates.json" <<'PY'
import json,re,sys,urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

bundle,target,source_file,out_file=sys.argv[1:]
urls=Path(source_file).read_text(encoding="utf-8").split()

def v(s):
    nums=[int(x) for x in re.findall(r"\d+",str(s or ""))]
    return tuple((nums+[0]*8)[:8])

def compatible(minos):
    return not minos or v(minos)<=v(target)

def iter_apps(obj):
    if isinstance(obj,dict):
        identity=obj.get("bundleIdentifier") or obj.get("bundleID") or obj.get("bundleId")
        has_package=obj.get("downloadURL") or obj.get("link")
        if identity and (has_package or obj.get("versions")):
            yield obj

        for key in ("apps","data"):
            value=obj.get(key)
            if isinstance(value,(dict,list)):
                yield from iter_apps(value)

        for value in obj.values():
            if isinstance(value,(dict,list)):
                yield from iter_apps(value)

    elif isinstance(obj,list):
        for value in obj:
            if isinstance(value,(dict,list)):
                yield from iter_apps(value)

def fetch_source(src):
    try:
        req=urllib.request.Request(
            src,
            headers={"User-Agent":"ipadecryptaction/1.0"}
        )
        with urllib.request.urlopen(req,timeout=20) as response:
            return src,json.loads(response.read()),None
    except Exception as exc:
        return src,None,str(exc)

source_results=[]
with ThreadPoolExecutor(max_workers=12) as pool:
    futures=[pool.submit(fetch_source,url) for url in urls if url]
    for future in as_completed(futures):
        source_results.append(future.result())

candidates=[]
seen=set()

for url,data,error in source_results:
    if error:
        print(f"::warning::Source failed: {url}: {error}")
        continue

    for app in iter_apps(data):
        app_bundle=str(
            app.get("bundleIdentifier")
            or app.get("bundleID")
            or app.get("bundleId")
            or ""
        ).strip()

        if app_bundle!=bundle:
            continue

        versions=app.get("versions")
        if not isinstance(versions,list):
            versions=[]

        if app.get("downloadURL") or app.get("link"):
            versions=[app,*versions]

        for item in versions:
            if not isinstance(item,dict):
                continue

            dl=str(item.get("downloadURL") or item.get("link") or "").strip()
            ver=str(item.get("version") or item.get("bundleVersion") or "").strip()
            minos=str(
                item.get("minOSVersion")
                or item.get("minimumOSVersion")
                or item.get("minOS")
                or app.get("minOSVersion")
                or app.get("minimumOSVersion")
                or app.get("minOS")
                or ""
            ).strip()

            if not dl or not ver or not compatible(minos):
                continue

            key=(ver,dl)
            if key in seen:
                continue
            seen.add(key)

            candidates.append({
                "name":str(app.get("name") or "").strip(),
                "bundleIdentifier":bundle,
                "version":ver,
                "buildVersion":str(
                    item.get("buildVersion")
                    or item.get("build")
                    or ""
                ).strip(),
                "date":str(
                    item.get("date")
                    or item.get("versionDate")
                    or ""
                ).strip(),
                "minOSVersion":minos,
                "downloadURL":dl,
                "source":url,
                "sourceIndex":urls.index(url) if url in urls else 999999
            })

candidates.sort(
    key=lambda x:(v(x["version"]),x["date"],v(x["buildVersion"])),
    reverse=True
)

Path(out_file).write_text(
    json.dumps(candidates,ensure_ascii=False,indent=2),
    encoding="utf-8"
)

print(f"Found {len(candidates)} compatible candidates")
for x in candidates[:15]:
    print(
        f"- {x['version']} "
        f"(min iOS {x['minOSVersion'] or 'unknown'}) "
        f"from {x['source']}"
    )
PY
count="$(jq length "$work/candidates.json")"
echo "AltStore/SideStore candidates: $count"

legacy_dir="$work/legacy"
mkdir -p "$legacy_dir"
if bash "$GITHUB_WORKSPACE/scripts/download-legacystore.sh" "$APP_ID" "$TARGET_IOS" "$legacy_dir"; then
  if [[ -s "$legacy_dir/candidates.json" ]]; then
    legacy_count="$(jq length "$legacy_dir/candidates.json")"
    echo "Legacy Store candidates: $legacy_count"
    jq -s 'add | unique_by(.version,.downloadURL) |
      sort_by([.version,.date,.buildVersion]) | reverse'       "$work/candidates.json" "$legacy_dir/candidates.json" > "$work/candidates.merged.json"
    mv "$work/candidates.merged.json" "$work/candidates.json"
  fi
else
  echo "::warning::Legacy Store lookup unavailable for App Store ID $APP_ID."
fi

count="$(jq length "$work/candidates.json")"
echo "Total compatible candidates after Legacy Store: $count"
if [[ "$count" == "0" ]]; then
  echo "::warning::No compatible candidate found in JSON sources or Legacy Store; trying IPA Dump fallback."
fi

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
    if not s:
        return None
    p=[int(x) for x in s.split(".")]
    p += [0]*(4-len(p))
    return tuple(p[:4])

target=v(sys.argv[1])
minimum=v(sys.argv[2])

if minimum is not None and minimum > target:
    raise SystemExit(1)
PY

    selected_version="$actual_version"
    selected_build="$actual_build"
    selected_min="$actual_min"
    selected_url="$url"
    selected_source="$source"
    break
done < <(jq -c '.[]' "$work/candidates.json")

if [[ -z "$selected_version" ]]; then
  echo "All configured JSON candidates failed. Trying IPA Dump..."
  fallback_dir="$work/ipadump"
  mkdir -p "$fallback_dir"

  if bash "$GITHUB_WORKSPACE/scripts/download-ipadump.sh" "$APP_ID" "$TARGET_IOS" "$fallback_dir"; then
    selected_version="$(jq -r '.version' "$fallback_dir/result.json")"
    selected_build="$(jq -r '.build' "$fallback_dir/result.json")"
    selected_min="$(jq -r '.minimum_os_version' "$fallback_dir/result.json")"
    selected_url="$(jq -r '.download_url' "$fallback_dir/result.json")"
    selected_source="IPA Dump"
    cp "$fallback_dir/result.ipa" "$work/candidate.ipa"
  else
    echo "::warning::IPA Dump fallback did not return a compatible downloadable IPA."
  fi
fi

[[ -n "$selected_version" ]] || {
  echo "::error::No compatible IPA could be found in any configured public source."
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
  "package_state": "public third-party IPA source"
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

This is a public third-party IPA source, not Apple's authenticated App Store package.
It may be modified, decrypted, repackaged, or unsigned. Verify the source and package before installing it.
EOF

echo "Selected $APP_NAME $selected_version ($selected_build), minimum iOS $selected_min"
