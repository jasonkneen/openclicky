#!/usr/bin/env bash
# Generate / refresh appcast.xml with a new Sparkle release item.
#
# Pulls version + build from the project, signs the DMG with the Sparkle
# EdDSA private key (stored in the login keychain by `sign_update --generate`),
# and writes a single-item appcast.xml pointing at a downloadable URL.
#
# Usage:
#   scripts/generate-appcast.sh dist/OpenClicky-1.1.0-7.dmg
#   scripts/generate-appcast.sh dist/OpenClicky-1.1.0-7.dmg \
#       https://github.com/Nirbhik-Acharya-official/openclicky-custom/releases/download/v1.1.0/OpenClicky-1.1.0-7.dmg
#
# If you omit the URL, the script uses a GitHub Releases convention based
# on the version tag.

set -euo pipefail

cd "$(dirname "$0")/.."

DMG_PATH="${1:-}"
DOWNLOAD_URL="${2:-}"

if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
    echo "Usage: $0 <dmg-path> [download-url]" >&2
    exit 64
fi

PROJECT="cursor-buddy.xcodeproj/project.pbxproj"
REPOSITORY="${OPENCICKY_GITHUB_REPOSITORY:-Nirbhik-Acharya-official/openclicky-custom}"
VERSION=$(grep -m1 "MARKETING_VERSION" "$PROJECT" | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' | tr -d ' ')
BUILD=$(xcrun agvtool what-version -terse 2>/dev/null | tail -1 | tr -d ' ')
MINIMUM_MACOS=$(grep -m1 "MACOSX_DEPLOYMENT_TARGET" "$PROJECT" | sed -E 's/.*MACOSX_DEPLOYMENT_TARGET = ([^;]+);.*/\1/' | tr -d ' ')

if [[ -z "$DOWNLOAD_URL" ]]; then
    DOWNLOAD_URL="https://github.com/${REPOSITORY}/releases/download/v${VERSION}/$(basename "$DMG_PATH")"
fi

# Locate Sparkle's sign_update binary. First try our project's DerivedData
# (preferred -- guarantees the same Sparkle version we link against);
# fall back to any sign_update on disk, or Homebrew.
find_sign_update() {
    local hit
    hit=$(find ~/Library/Developer/Xcode/DerivedData -path '*cursor*' -name sign_update -not -path '*old_dsa_scripts*' -type f 2>/dev/null | head -1)
    if [[ -n "$hit" ]]; then echo "$hit"; return; fi
    hit=$(find ~/Library/Developer/Xcode/DerivedData -name sign_update -not -path '*old_dsa_scripts*' -type f 2>/dev/null | head -1)
    if [[ -n "$hit" ]]; then echo "$hit"; return; fi
    command -v sign_update 2>/dev/null || true
}

SIGN_UPDATE=$(find_sign_update)
if [[ -z "$SIGN_UPDATE" ]]; then
    echo "ERROR: Could not find Sparkle's sign_update tool." >&2
    echo "       Build the project once in Xcode (Sparkle is an SPM dependency)" >&2
    echo "       or install via: brew install --cask sparkle" >&2
    exit 1
fi

echo "==> Using sign_update: $SIGN_UPDATE"
SIG_OUTPUT=$("$SIGN_UPDATE" --account openclicky-custom "$DMG_PATH")
ED_SIG=$(echo "$SIG_OUTPUT" | grep -oE 'sparkle:edSignature="[^"]+"' | sed -E 's/.*"([^"]+)".*/\1/')
LENGTH=$(echo "$SIG_OUTPUT" | grep -oE 'length="[0-9]+"' | sed -E 's/.*"([0-9]+)".*/\1/')

if [[ -z "$ED_SIG" || -z "$LENGTH" ]]; then
    echo "ERROR: sign_update did not return a usable signature. Raw output:" >&2
    echo "$SIG_OUTPUT" >&2
    echo "" >&2
    echo "If this is your first release, generate the keypair once:" >&2
    echo "  $SIGN_UPDATE --generate-keypair" >&2
    echo "Then update SUPublicEDKey in cursor-buddy/Info.plist with the printed public key." >&2
    exit 1
fi

PUB_DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')

echo "==> Writing appcast.xml"
cat > appcast.xml <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>OpenClicky Updates</title>
        <link>https://github.com/${REPOSITORY}</link>
        <description>OpenClicky direct-distribution updates.</description>
        <language>en</language>
        <item>
            <title>OpenClicky ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>${MINIMUM_MACOS}</sparkle:minimumSystemVersion>
            <enclosure
                url="${DOWNLOAD_URL}"
                length="${LENGTH}"
                type="application/octet-stream"
                sparkle:edSignature="${ED_SIG}"/>
        </item>
    </channel>
</rss>
XML

echo "Done."
echo ""
echo "appcast.xml now points at: ${DOWNLOAD_URL}"
echo ""
echo "Next steps:"
echo "  1. Upload ${DMG_PATH} to the GitHub release v${VERSION} (or whatever host the URL points at)."
echo "  2. git add appcast.xml cursor-buddy.xcodeproj/project.pbxproj"
echo "  3. git commit -m \"Release ${VERSION} (build ${BUILD})\""
echo "  4. git tag v${VERSION} && git push && git push --tags"
