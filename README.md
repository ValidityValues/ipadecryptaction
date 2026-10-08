# ipadecryptaction

Personal GitHub Actions workflow for selecting and downloading the newest App Store IPA that supports a target iOS version.

## Workflow

Open **Actions → Download compatible App Store IPA → Run workflow**.

Enter:

- **App Store URL** — for example `https://apps.apple.com/us/app/example/id123456789`
- **iOS version** — for example `16.5.1`

The workflow extracts the numeric App Store ID, authenticates to the App Store, gets the available version identifiers, tries them from newest to oldest, reads the main `Payload/*.app/Info.plist`, and stops at the newest package whose `MinimumOSVersion` is compatible with the requested iOS version.

The selected IPA plus `metadata.json` are uploaded as the `compatible-ipa` workflow artifact.

## Required repository secrets

Create these GitHub repository secrets:

- `APPLE_ID` — Apple Account email address or phone number used for the App Store.
- `APPLE_PASSWORD` — Apple Account password.
- `APPLE_AUTH_CODE` — current 2FA verification code when the account requires one.
- `IPATOOL_KEYCHAIN_PASSPHRASE` — random passphrase for ipatool's temporary file-backed keychain.

Do not put Apple credentials in workflow inputs, source files, or commits. For personal use, making the repository private is strongly recommended.

## Tooling

The workflow currently uses ipatool **2.6.0**, the current upstream release when this project was created, and verifies its published SHA-256 checksum before executing it.

ipatool can search the App Store, list available versions, and download App Store app packages. App Store iOS packages downloaded this way can remain FairPlay-protected/encrypted.

## DRM limitation

This project deliberately **does not remove or bypass Apple's FairPlay DRM**. The downloaded artifact may therefore still be an encrypted App Store IPA.

I can help with the acquisition, version-selection, IPA inspection, signing/repackaging of legitimately decrypted files, and other non-DRM parts of the workflow, but not with implementing a FairPlay bypass.

Paid apps also require the Apple Account to have the necessary App Store entitlement.

## Why `MinimumOSVersion`

Apple documents `MinimumOSVersion` as the bundle key specifying the minimum supported iOS/iPadOS/tvOS/watchOS version. The workflow uses the value from the actual IPA's `Info.plist` instead of guessing from the current App Store listing.

## Output

The artifact contains:

```
compatible-ipa/
├── <bundle-id>_<version>.ipa
└── metadata.json
```

Example metadata:

```json
{
  "app_store_id": "123456789",
  "bundle_id": "com.example.app",
  "version": "x.y.z",
  "minimum_os_version": "16.0",
  "target_ios": "16.5.1",
  "external_version_id": "87654321",
  "platform": "iphone",
  "package_state": "App Store encrypted IPA",
  "ipatool_version": "2.6.0"
}
```

## No-login mode

The repository also has **Resolve App Store app (no Apple ID)**. It accepts the same App Store URL and target iOS version, but only uses Apple's public iTunes Lookup metadata. It can tell you whether the **current** App Store listing is compatible with that iOS version.

It cannot retrieve an arbitrary historical App Store binary without authentication. Apple's authenticated App Store download flow is still used by **Download compatible App Store IPA** for exact historical version selection.


## No-Apple-ID IPA download

Use **Actions → Download compatible IPA (no Apple ID)**.

Inputs:

- **App Store URL**
- **Target iOS**
- **AltStore source JSON URLs** (optional; a default set is already provided)

The workflow uses Apple's public Lookup endpoint only to resolve the App Store ID to a Bundle ID. It then searches the configured AltStore-compatible JSON sources for that Bundle ID, filters versions whose `minOSVersion` is compatible with the requested iOS, chooses the newest candidate, downloads it, and verifies the Bundle ID and `MinimumOSVersion` from the IPA's actual `Info.plist`.

This mode does **not** log into Apple and does **not** download the binary from Apple's authenticated App Store endpoint. The resulting package comes from the configured public source and can be modified or unsigned.

For example, the public WuXu library currently contains `com.google.ios.youtube` and publishes IPA download URLs together with iOS compatibility metadata. citeturn968806search0


The no-login downloader now scans the built-in public source catalog in parallel, supports both modern AltStore `downloadURL` records and IPA Library/PlayCover-style `link` + `bundleID` records, and falls back to IPA Dump when all JSON-source candidates fail. PlayCover's source model uses `bundleID`, `version`, and `link` for this older IPA Library format. citeturn117261search0turn952718search0
