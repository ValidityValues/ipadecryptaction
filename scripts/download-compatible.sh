#!/usr/bin/env bash
set -Eeuo pipefail

WORKDIR="${RUNNER_TEMP}/ipa-work"
ARTIFACT_DIR="${GITHUB_WORKSPACE}/artifacts"
IPATOOL_VERSION="2.6.0"
IPATOOL_URL="https://github.com/majd/ipatool/releases/download/v${IPATOOL_VERSION}/ipatool-${IPATOOL_VERSION}-linux-amd64.tar.gz"
IPATOOL_SHA_URL="${IPATOOL_URL}.sha256sum"

rm -rf "$WORKDIR" "$ARTIFACT_DIR"
mkdir -p "$WORKDIR" "$ARTIFACT_DIR"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "::error::Required environment variable is missing: $name"
    exit 1
  fi
}

require_env APP_STORE_URL
require_env TARGET_IOS
require_env APPLE_ID
require_env APPLE_PASSWORD
require_env IPATOOL_KEYCHAIN_PASSPHRASE

if [[ "$APP_STORE_URL" =~ /id([0-9]+)(/|$|\?) ]]; then
  APP_ID="${BASH_REMATCH[1]}"
else
  echo "::error::Could not extract a numeric App Store ID from APP_STORE_URL."
  exit 1
fi

if ! python3 - "$TARGET_IOS" <<'PY'
import re
import sys

value = sys.argv[1]
if not re.fullmatch(r"\d+(?:\.\d+){0,3}", value):
    raise SystemExit("invalid iOS version")
PY
then
  echo "::error::Invalid iOS version: $TARGET_IOS"
  exit 1
fi

echo "App Store ID: $APP_ID"
echo "Target iOS: $TARGET_IOS"

cd "$WORKDIR"

echo "Installing ipatool ${IPATOOL_VERSION}..."
curl -fL --retry 3 --retry-all-errors "$IPATOOL_URL" -o ipatool.tar.gz
curl -fL --retry 3 --retry-all-errors "$IPATOOL_SHA_URL" -o ipatool.sha256sum

expected_sha="$(awk '{print $1}' ipatool.sha256sum | head -n1)"
actual_sha="$(sha256sum ipatool.tar.gz | awk '{print $1}')"
if [[ "$expected_sha" != "$actual_sha" ]]; then
  echo "::error::ipatool SHA-256 mismatch."
  exit 1
fi

tar -xzf ipatool.tar.gz
IPATOOL="$(find "$WORKDIR" -maxdepth 2 -type f -name ipatool -perm -u+x | head -n1)"
if [[ -z "$IPATOOL" ]]; then
  echo "::error::ipatool binary was not found after extraction."
  exit 1
fi

export XDG_STATE_HOME="$WORKDIR/state"
export XDG_DATA_HOME="$WORKDIR/data"
mkdir -p "$XDG_STATE_HOME" "$XDG_DATA_HOME"

common_args=(
  --non-interactive
  --keychain-passphrase "$IPATOOL_KEYCHAIN_PASSPHRASE"
)

echo "Logging into the App Store..."
login_args=(
  "$IPATOOL" auth login
  "${common_args[@]}"
  --email "$APPLE_ID"
  --password "$APPLE_PASSWORD"
)
if [[ -n "${APPLE_AUTH_CODE:-}" ]]; then
  login_args+=(--auth-code "$APPLE_AUTH_CODE")
fi
"${login_args[@]}"

echo "Fetching App Store version history..."
versions_json="$("$IPATOOL" list-versions \
  "${common_args[@]}" \
  --format json \
  --app-id "$APP_ID" \
  --platform iphone)"

mapfile -t VERSION_IDS < <(
  printf '%s' "$versions_json" |
    jq -er '.externalVersionIdentifiers[]' |
    tac
)

if [[ "${#VERSION_IDS[@]}" -eq 0 ]]; then
  echo "::error::No App Store versions were returned for app $APP_ID."
  exit 1
fi

echo "Found ${#VERSION_IDS[@]} App Store version identifiers."
echo "Trying newest-to-oldest until MinimumOSVersion <= $TARGET_IOS."

is_compatible() {
  python3 - "$TARGET_IOS" "$1" <<'PY'
import sys

def v(s):
    p = [int(x) for x in s.split(".")]
    p += [0] * (4 - len(p))
    return tuple(p[:4])

target, minimum = map(v, sys.argv[1:3])
raise SystemExit(0 if target >= minimum else 1)
PY
}

candidate="$WORKDIR/candidate.ipa"

selected_version=""
selected_min_ios=""
selected_bundle_id=""
selected_external_id=""

for external_id in "${VERSION_IDS[@]}"; do
  rm -f "$candidate" "$WORKDIR/Info.plist"

  echo "Downloading external version ID $external_id..."

  if ! "$IPATOOL" download \
      "${common_args[@]}" \
      --app-id "$APP_ID" \
      --platform iphone \
      --external-version-id "$external_id" \
      --output "$candidate"; then
    echo "::warning::Download failed for external version ID $external_id; trying the next older version."
    continue
  fi

  if [[ ! -s "$candidate" ]]; then
    echo "::warning::Downloaded file is empty for external version ID $external_id."
    continue
  fi

  info_plist="$(unzip -Z1 "$candidate" | grep -E '^Payload/[^/]+\\.app/Info\\.plist$' | head -n1 || true)"
  if [[ -z "$info_plist" ]]; then
    echo "::warning::No main Payload/*.app/Info.plist found in external version ID $external_id."
    continue
  fi

  unzip -p "$candidate" "$info_plist" > "$WORKDIR/Info.plist"

  readarray -t plist_data < <(
    python3 - "$WORKDIR/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as f:
    data = plistlib.load(f)

minimum = str(data.get("MinimumOSVersion", "")).strip()
version = str(data.get("CFBundleShortVersionString", "")).strip()
bundle = str(data.get("CFBundleIdentifier", "")).strip()

if not minimum:
    raise SystemExit("MISSING_MINIMUM_OS")

print(minimum)
print(version)
print(bundle)
PY
  ) || {
    echo "::warning::Could not parse Info.plist for external version ID $external_id; trying the next older version."
    continue
  }

  minimum_ios="${plist_data[0]}"
  display_version="${plist_data[1]:-unknown}"
  bundle_id="${plist_data[2]:-unknown}"

  echo "Candidate: version=$display_version, MinimumOSVersion=$minimum_ios, bundle=$bundle_id"

  if is_compatible "$minimum_ios"; then
    selected_version="$display_version"
    selected_min_ios="$minimum_ios"
    selected_bundle_id="$bundle_id"
    selected_external_id="$external_id"
    break
  fi

  echo "Skipping $display_version: requires iOS $minimum_ios."
done

if [[ -z "$selected_external_id" ]]; then
  echo "::error::No downloaded App Store version supports iOS $TARGET_IOS."
  exit 1
fi

safe_bundle="$(printf '%s' "$selected_bundle_id" | tr -c 'A-Za-z0-9._-' '_')"
safe_version="$(printf '%s' "$selected_version" | tr -c 'A-Za-z0-9._-' '_')"
output_ipa="$ARTIFACT_DIR/${safe_bundle}_${safe_version}.ipa"

mv "$candidate" "$output_ipa"

cat > "$ARTIFACT_DIR/metadata.json" <<JSON
{
  "app_store_id": "$APP_ID",
  "app_store_url": "$APP_STORE_URL",
  "bundle_id": "$selected_bundle_id",
  "version": "$selected_version",
  "minimum_os_version": "$selected_min_ios",
  "target_ios": "$TARGET_IOS",
  "external_version_id": "$selected_external_id",
  "platform": "iphone",
  "package_state": "App Store encrypted IPA",
  "ipatool_version": "$IPATOOL_VERSION"
}
JSON

echo
echo "========================================"
echo "Selected compatible App Store package"
echo "App ID:             $APP_ID"
echo "Bundle ID:          $selected_bundle_id"
echo "Version:            $selected_version"
echo "Minimum iOS:        $selected_min_ios"
echo "Target iOS:         $TARGET_IOS"
echo "External version:   $selected_external_id"
echo "Output:             $output_ipa"
echo "========================================"
