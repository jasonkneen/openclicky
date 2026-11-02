# OpenClicky App Updates

OpenClicky uses Sparkle 2 for direct-distribution updates. This does not apply to a future Mac App Store build, where updates must come through the App Store.

The app is configured for OTA-style updates:

- `SUEnableAutomaticChecks`: checks for updates automatically.
- `SUAllowsAutomaticUpdates`: allows the automatic update option.
- `SUAutomaticallyUpdate`: defaults to background download and install behavior.
- `SUScheduledCheckInterval`: checks roughly once per day.

## Update Feed

- Feed URL in the app: `https://raw.githubusercontent.com/Nirbhik-Acharya-official/openclicky-custom/main/appcast.xml`
- Feed file in this repo: `appcast.xml`
- Release asset host: GitHub Releases under `https://github.com/Nirbhik-Acharya-official/openclicky-custom/releases`
- Public EdDSA key in `Info.plist`: `SUPublicEDKey`
- Sparkle Keychain account: `openclicky-custom`

The GitHub Action `.github/workflows/check-upstream.yml` checks `jasonkneen/openclicky:main` once a day. If upstream has new commits, it refreshes `automation/upstream-sync` and opens or updates a pull request against this fork's `main`. The action uses the repository's `GITHUB_TOKEN`; if GitHub blocks pull-request creation, enable Actions to create pull requests in the fork's Actions settings.

The checked-in `appcast.xml` is intentionally an empty OpenClicky feed until the first signed release artifact exists.

The Sparkle key for account `openclicky-custom` is generated in the setup Mac's login Keychain, and its public key is configured in `SUPublicEDKey`. Keep the private key in the macOS Keychain or a protected CI secret; never commit it. Existing OpenClicky builds that trust the upstream key cannot install fork updates unless they first receive an update signed by the upstream key, so install this fork directly before relying on its feed.

## Release Flow

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in Xcode.
2. Archive the app in Xcode with the `cursor-buddy` scheme.
3. Export a Developer ID signed app for direct distribution.
4. Package the exported `.app` into a DMG.
5. Notarize and staple the DMG.
6. Sign the DMG for Sparkle with Sparkle's `sign_update` tool.
7. Upload the stapled DMG to a GitHub Release named `v<MARKETING_VERSION>`.
8. Add a new item to `appcast.xml`.
9. Commit and push `appcast.xml` to `main`.

## Appcast Item Shape

Use this template after replacing the version, build, date, URL, byte length, and Sparkle signature:

```xml
<item>
    <title>OpenClicky 1.0.1</title>
    <pubDate>Fri, 24 Apr 2026 16:10:08 +0000</pubDate>
    <sparkle:version>7</sparkle:version>
    <sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>
    <enclosure
        url="https://github.com/Nirbhik-Acharya-official/openclicky-custom/releases/download/v1.0.1/OpenClicky-1.0.1.dmg"
        length="12345678"
        type="application/octet-stream"
        sparkle:edSignature="SIGNATURE_FROM_SPARKLE_SIGN_UPDATE"/>
</item>
```

## Local Commands

The exact Sparkle binary path depends on where Xcode stores Swift package artifacts. If the app archive contains Sparkle tools, use that `sign_update`; otherwise build or download Sparkle's release tools.

```sh
# Notarize the DMG. The keychain profile is created once with notarytool store-credentials.
xcrun notarytool submit OpenClicky-1.0.1.dmg --keychain-profile "openclicky-custom-notary" --wait
xcrun stapler staple OpenClicky-1.0.1.dmg

# Generate Sparkle's EdDSA signature.
sign_update --account openclicky-custom OpenClicky-1.0.1.dmg

# Get the byte length for the appcast enclosure.
stat -f%z OpenClicky-1.0.1.dmg
```

## Review Checklist

- The DMG opens without Gatekeeper warnings on a clean Mac.
- `spctl --assess --type open --context context:primary-signature -vv OpenClicky-1.0.1.dmg` accepts it.
- The appcast URL is reachable over HTTPS.
- The new appcast item has a higher `sparkle:version` than the installed build.
- The appcast item URL exactly matches the uploaded GitHub Release asset.
- `sparkle:edSignature` was generated from the final stapled DMG, not an earlier copy.
- A clean installed build checks the feed and offers or stages the update without sending the user to GitHub manually.

## Local OTA Test

Use this to prove the update loop before publishing to GitHub Releases. Build the app in Xcode, not with terminal `xcodebuild`, so macOS permission state remains tied to the proper app identity.

### 1. Build And Install The Baseline

1. In Xcode, set `MARKETING_VERSION` to a lower test version, for example `1.0.0`.
2. Set `CURRENT_PROJECT_VERSION` to a lower build number, for example `100`.
3. Archive/export a Developer ID signed app or run a proper Release build from Xcode.
4. Install that build into `/Applications/OpenClicky.app`.
5. Quit OpenClicky.

Point that installed build at a local appcast:

```sh
defaults write com.jkneen.openclicky OpenClickySparkleFeedURLOverride -string "http://127.0.0.1:8808/appcast.xml"
```

The override only accepts `https`, `file`, or local `http` feeds. Non-local `http` is ignored. When this override is present, OpenClicky triggers a Sparkle background check immediately on launch.

### 2. Build The Update

1. In Xcode, bump `MARKETING_VERSION`, for example to `1.0.1`.
2. Bump `CURRENT_PROJECT_VERSION`, for example to `101`.
3. Archive/export the updated app.
4. Package it as `OpenClicky-1.0.1.dmg`.
5. Sign the final DMG with Sparkle's `sign_update --account openclicky-custom` and keep the signature output.

### 3. Serve A Local Feed

Create a temporary update folder and appcast:

```sh
scripts/create-local-appcast.sh /path/to/OpenClicky-1.0.1.dmg 1.0.1 101 "SIGNATURE_FROM_SPARKLE_SIGN_UPDATE"
```

That writes `/tmp/openclicky-ota/appcast.xml` with a higher `sparkle:version` than the installed app:

```xml
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>OpenClicky Local Updates</title>
        <item>
            <title>OpenClicky 1.0.1</title>
            <pubDate>Fri, 24 Apr 2026 16:10:08 +0000</pubDate>
            <sparkle:version>101</sparkle:version>
            <sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>
            <enclosure
                url="http://127.0.0.1:8808/OpenClicky-1.0.1.dmg"
                length="DMG_BYTE_LENGTH"
                type="application/octet-stream"
                sparkle:edSignature="SIGNATURE_FROM_SPARKLE_SIGN_UPDATE"/>
        </item>
    </channel>
</rss>
```

Serve the folder:

```sh
cd /tmp/openclicky-ota
python3 -m http.server 8808 --bind 127.0.0.1
```

### 4. Trigger The Update

1. Launch `/Applications/OpenClicky.app`.
2. Sparkle will read the local feed override and see the higher build.
3. Accept or wait for the update flow.
4. After relaunch, confirm the app version/build changed.

Clear the local feed override after testing:

```sh
defaults delete com.jkneen.openclicky OpenClickySparkleFeedURLOverride
```
