#!/usr/bin/env bash
set -Eeuo pipefail

APP_ID="$1"
TARGET_IOS="$2"
WORKDIR="$3"

mkdir -p "$WORKDIR"
rm -f "$WORKDIR/result.ipa" "$WORKDIR/result.json" "$WORKDIR/version-pages.txt" "$WORKDIR/candidates.tsv"

python3 - "$APP_ID" "$WORKDIR/version-pages.txt" <<'PY'
import html.parser
import re
import sys
import urllib.request
from pathlib import Path

app_id, out_file = sys.argv[1:]
regions = ["us", "tw", "cn", "jp", "kr", "gb", "de", "fr", "ca", "au"]

seen = set()
pages = []

class Parser(html.parser.HTMLParser):
    def handle_starttag(self, tag, attrs):
        if tag != "a":
            return
        href = dict(attrs).get("href", "")
        if not href:
            return
        absolute = href if href.startswith("http") else "https://ipadump.com" + href
        pattern = rf"/en/apps/[a-z]{{2}}/{re.escape(app_id)}/([0-9][0-9A-Za-z._-]*)/?$"
        if re.search(pattern, absolute) and absolute not in seen:
            seen.add(absolute)
            pages.append(absolute)

for region in regions:
    url = f"https://ipadump.com/en/apps/{region}/{app_id}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=20) as response:
            data = response.read().decode("utf-8", "replace")
        parser = Parser()
        parser.feed(data)
    except Exception:
        continue

Path(out_file).write_text("\n".join(pages) + "\n", encoding="utf-8")
print(f"IPA Dump version pages found: {len(pages)}")
PY

if [[ ! -s "$WORKDIR/version-pages.txt" ]]; then
  echo "::warning::IPA Dump has no discoverable version pages for App ID $APP_ID."
  exit 2
fi

python3 - "$WORKDIR/version-pages.txt" "$WORKDIR/candidates.tsv" <<'PY'
import html.parser
import re
import sys
import urllib.request
from pathlib import Path
from urllib.parse import urljoin

pages = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
rows = []
seen = set()

class Parser(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
    def handle_starttag(self, tag, attrs):
        if tag == "a":
            href = dict(attrs).get("href", "")
            if href:
                self.links.append(href)

def version_from_url(url):
    m = re.search(r"/([0-9][0-9A-Za-z._-]*)/?$", url)
    return m.group(1) if m else ""

for page in pages:
    try:
        req = urllib.request.Request(page, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=20) as response:
            source = response.read().decode("utf-8", "replace")
    except Exception:
        continue

    parser = Parser()
    parser.feed(source)
    version = version_from_url(page)

    for href in parser.links:
        absolute = urljoin(page, href)
        low = absolute.lower()
        if ".ipa" not in low and "download" not in low:
            continue
        key = (version, absolute)
        if key in seen:
            continue
        seen.add(key)
        rows.append((version, absolute, page))

def key(row):
    nums = [int(x) for x in re.findall(r"\d+", row[0])]
    return tuple((nums + [0] * 8)[:8])

rows.sort(key=key, reverse=True)

Path(sys.argv[2]).write_text(
    "".join(f"{version}\t{url}\t{page}\n" for version, url, page in rows),
    encoding="utf-8"
)
print(f"IPA Dump download candidates found: {len(rows)}")
PY

while IFS=$'\t' read -r version url page; do
  [[ -n "$url" ]] || continue
  echo "Trying IPA Dump $version: $url"
  rm -f "$WORKDIR/result.ipa"

  if ! curl -fL --retry 2 --retry-all-errors --max-time 900 "$url" -o "$WORKDIR/result.ipa"; then
    continue
  fi

  [[ -s "$WORKDIR/result.ipa" ]] || continue

  info_path="$(unzip -Z1 "$WORKDIR/result.ipa" 2>/dev/null |
    grep -E '^Payload/[^/]+\.app/Info\.plist$' |
    head -n1 || true)"

  [[ -n "$info_path" ]] || continue
  unzip -p "$WORKDIR/result.ipa" "$info_path" > "$WORKDIR/result.plist"

  if python3 - "$WORKDIR/result.plist" "$APP_ID" "$TARGET_IOS" <<'PY'
import plistlib
import sys

plist, app_id, target = sys.argv[1:]
with open(plist, "rb") as f:
    data = plistlib.load(f)

bundle = str(data.get("CFBundleIdentifier", "")).strip()
minimum = str(data.get("MinimumOSVersion", "")).strip()

if app_id == "388497605" and bundle != "com.google.Authenticator":
    raise SystemExit(1)

def version(value):
    parts = [int(x) for x in value.split(".") if x]
    parts += [0] * (4 - len(parts))
    return tuple(parts[:4])

if minimum and version(minimum) > version(target):
    raise SystemExit(1)

raise SystemExit(0)
PY
  then
    readarray -t actual < <(python3 - "$WORKDIR/result.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
print(str(d.get("CFBundleIdentifier", "")).strip())
print(str(d.get("CFBundleShortVersionString", "")).strip())
print(str(d.get("CFBundleVersion", "")).strip())
print(str(d.get("MinimumOSVersion", "")).strip())
PY
)

    actual_bundle="${actual[0]:-}"
    actual_version="${actual[1]:-}"
    actual_build="${actual[2]:-}"
    actual_min="${actual[3]:-}"

    cat > "$WORKDIR/result.json" <<EOF
{
  "source": "IPA Dump",
  "source_page": "$page",
  "download_url": "$url",
  "bundle_id": "$actual_bundle",
  "version": "$actual_version",
  "build": "$actual_build",
  "minimum_os_version": "$actual_min",
  "target_ios": "$TARGET_IOS"
}
EOF

    echo "IPA Dump selected version $actual_version."
    exit 0
  fi
done < "$WORKDIR/candidates.tsv"

echo "::warning::IPA Dump could not provide a downloadable compatible IPA."
exit 3
