#!/usr/bin/env bash
# Build, sign, package, and notarize OpenClicky for distribution.
#
# One-time setup (do this once per machine before first release build):
#   1) Have a "Developer ID Application: Jason Kneen (SW75ZJJ5R6)" cert in
#      the login keychain. Verify with:
#        security find-identity -v -p codesigning | grep 'Developer ID'
#   2) Create an app-specific password at https://appleid.apple.com (under
#      Sign-In and Security -> App-Specific Passwords).
#   3) Store the notary credentials in a keychain profile (one time):
#        xcrun notarytool store-credentials \
#          --apple-id "you@example.com" \
#          --team-id "SW75ZJJ5R6" \
#          --password "abcd-efgh-ijkl-mnop" \
#          OpenClickyNotary
#      The profile name "OpenClickyNotary" is what NOTARY_PROFILE below
#      points at; change both if you prefer a different name.
#   4) If you keep modifying .mcp.json locally and don't want it staged each
#      time, run once: git update-index --skip-worktree .mcp.json
#
# Usage:
#   scripts/release.sh                 # uses MARKETING_VERSION/CURRENT_PROJECT_VERSION from project
#   scripts/release.sh 1.1.0 7         # override version + build number
#   scripts/release.sh 1.1.0 7 --skip-notarize  # archive + DMG only
#
# Output:
#   dist/OpenClicky-<version>-<build>.dmg  (signed + stapled when notarized)

set -euo pipefail

cd "$(dirname "$0")/.."

# --- Configuration ---------------------------------------------------------
SCHEME="leanring-buddy"
PROJECT="leanring-buddy.xcodeproj"
APP_NAME="OpenClicky"
BUNDLE_ID="com.jkneen.openclicky"
TEAM_ID="SW75ZJJ5R6"
SIGNING_IDENTITY="Developer ID Application: Jason Kneen (${TEAM_ID})"
NOTARY_PROFILE="OpenClickyNotary"
EXPORT_OPTIONS="scripts/ExportOptions.plist"

BUILD_DIR="build"
DIST_DIR="dist"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_PATH="${BUILD_DIR}/Export"

# --- Args ------------------------------------------------------------------
SKIP_NOTARIZE=0
VERSION=""
BUILD_NUMBER=""

for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        --help|-h)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            if [[ -z "$VERSION" ]]; then
                VERSION="$arg"
            elif [[ -z "$BUILD_NUMBER" ]]; then
                BUILD_NUMBER="$arg"
            fi
            ;;
    esac
done

# Read defaults from the Xcode project if not overridden.
if [[ -z "$VERSION" ]]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" leanring-buddy/Info.plist 2>/dev/null \
        || grep -m1 "MARKETING_VERSION" "${PROJECT}/project.pbxproj" | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' | tr -d ' ')
fi
if [[ -z "$BUILD_NUMBER" ]]; then
    BUILD_NUMBER=$(grep -m1 "CURRENT_PROJECT_VERSION" "${PROJECT}/project.pbxproj" | sed -E 's/.*CURRENT_PROJECT_VERSION = ([^;]+);.*/\1/' | tr -d ' ')
fi

echo "==> Building ${APP_NAME} ${VERSION} (${BUILD_NUMBER})"

# --- Sanity checks ---------------------------------------------------------
if ! security find-identity -v -p codesigning | grep -q "${SIGNING_IDENTITY}"; then
    echo "ERROR: Signing identity not found in keychain: ${SIGNING_IDENTITY}" >&2
    echo "       Install your Developer ID Application cert and try again." >&2
    exit 1
fi

if [[ ! -f "${EXPORT_OPTIONS}" ]]; then
    echo "ERROR: ${EXPORT_OPTIONS} missing." >&2
    exit 1
fi

# --- Clean previous artifacts ----------------------------------------------
rm -rf "${BUILD_DIR}" "${DIST_DIR}/${APP_NAME}-${VERSION}-${BUILD_NUMBER}.dmg"
mkdir -p "${BUILD_DIR}" "${DIST_DIR}"

# --- Archive ---------------------------------------------------------------
echo "==> Archiving..."
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${ARCHIVE_PATH}" \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    archive | xcbeautify 2>/dev/null || \
xcodebuild \
    -project "${PROJECT}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${ARCHIVE_PATH}" \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    archive

# --- Export ----------------------------------------------------------------
echo "==> Exporting Developer ID build..."
xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}"

EXPORTED_APP="${EXPORT_PATH}/${APP_NAME}.app"
if [[ ! -d "${EXPORTED_APP}" ]]; then
    # Some Xcode versions export under the scheme/target name instead of PRODUCT_NAME.
    EXPORTED_APP=$(find "${EXPORT_PATH}" -maxdepth 2 -name "*.app" -print -quit)
fi
[[ -d "${EXPORTED_APP}" ]] || { echo "ERROR: exported .app not found in ${EXPORT_PATH}" >&2; exit 1; }

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "${EXPORTED_APP}"
spctl --assess --type execute --verbose=2 "${EXPORTED_APP}" || true

# --- DMG -------------------------------------------------------------------
DMG_NAME="${APP_NAME}-${VERSION}-${BUILD_NUMBER}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
STAGE_DIR="${BUILD_DIR}/dmg-stage"

echo "==> Building DMG ${DMG_PATH}..."
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"
cp -R "${EXPORTED_APP}" "${STAGE_DIR}/"
ln -s /Applications "${STAGE_DIR}/Applications"

hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "${STAGE_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" >/dev/null

echo "==> Signing DMG..."
codesign --sign "${SIGNING_IDENTITY}" --timestamp "${DMG_PATH}"

# --- Notarize --------------------------------------------------------------
if [[ "${SKIP_NOTARIZE}" -eq 1 ]]; then
    echo "==> Skipping notarization (--skip-notarize)."
    echo "Final DMG (unstapled): ${DMG_PATH}"
    exit 0
fi

echo "==> Submitting to Apple notary service (this can take a few minutes)..."
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

echo "==> Stapling notarization ticket..."
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"

echo ""
echo "Done. Notarized DMG ready: ${DMG_PATH}"
