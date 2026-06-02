#!/usr/bin/env bash
# Single-command release pipeline for OpenClicky (direct distribution,
# NOT App Store):
#   1. bump-version.sh       -> updates MARKETING_VERSION + build number
#   2. release.sh            -> archive, Developer ID sign, DMG, notarize, staple
#   3. generate-appcast.sh   -> Sparkle EdDSA signature + appcast.xml
#   4. --publish (optional)  -> commit version+appcast, tag vX.Y.Z, push, and
#                               create the GitHub release with the DMG attached.
#                               Without --publish it just prints those steps.
#
# Usage:
#   scripts/ship.sh                          # uses current project version
#   scripts/ship.sh 1.1.0                    # bump marketing to 1.1.0, auto build++
#   scripts/ship.sh 1.1.0 7                  # bump marketing to 1.1.0, build to 7
#   scripts/ship.sh 1.1.0 7 --skip-notarize  # smoke-test the pipeline
#   scripts/ship.sh 1.1.0 --publish          # build + notarize + tag + GitHub release
#   scripts/ship.sh 1.1.0 --publish --skip-notarize --notes "..."  # test publish
#   scripts/ship.sh --no-bump                # skip bump, build whatever's in project

set -euo pipefail

cd "$(dirname "$0")/.."

NO_BUMP=0
SKIP_NOTARIZE=0
PUBLISH=0
NOTES=""
MARKETING=""
BUILD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-bump) NO_BUMP=1 ;;
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        --publish) PUBLISH=1 ;;
        --notes) NOTES="${2:-}"; shift ;;
        --help|-h)
            sed -n '2,22p' "$0"
            exit 0
            ;;
        *)
            if [[ -z "$MARKETING" ]]; then
                MARKETING="$1"
            elif [[ -z "$BUILD" ]]; then
                BUILD="$1"
            fi
            ;;
    esac
    shift
done

if [[ $NO_BUMP -eq 0 && -z "$MARKETING" ]]; then
    echo "ERROR: pass a marketing version (or use --no-bump)." >&2
    echo "  scripts/ship.sh 1.1.0           # bump to 1.1.0, auto-increment build" >&2
    echo "  scripts/ship.sh 1.1.0 7         # bump to 1.1.0, build 7" >&2
    echo "  scripts/ship.sh --no-bump       # build current project version" >&2
    exit 64
fi

# --- Sanity: working tree clean (warn, don't block) -----------------------
if ! git diff --quiet HEAD 2>/dev/null; then
    echo "WARNING: working tree has uncommitted changes. They will be baked into the build." >&2
    echo "         Press Ctrl-C to abort, or wait 3 seconds to continue..." >&2
    sleep 3
fi

# --- Step 1: bump ----------------------------------------------------------
if [[ $NO_BUMP -eq 0 ]]; then
    echo "==> Step 1/3: bumping version"
    if [[ -n "$BUILD" ]]; then
        scripts/bump-version.sh "$MARKETING" "$BUILD"
    else
        scripts/bump-version.sh "$MARKETING"
    fi
else
    echo "==> Step 1/3: skipped (--no-bump)"
    scripts/bump-version.sh --show
fi

# Refresh values for downstream steps.
PROJECT="cursor-buddy.xcodeproj/project.pbxproj"
FINAL_VERSION=$(grep -m1 "MARKETING_VERSION" "$PROJECT" | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' | tr -d ' ')
FINAL_BUILD=$(xcrun agvtool what-version -terse 2>/dev/null | tail -1 | tr -d ' ')

# --- Step 2: build/sign/notarize ------------------------------------------
echo ""
echo "==> Step 2/3: archive + sign + notarize"
if [[ $SKIP_NOTARIZE -eq 1 ]]; then
    scripts/release.sh "$FINAL_VERSION" "$FINAL_BUILD" --skip-notarize
else
    scripts/release.sh "$FINAL_VERSION" "$FINAL_BUILD"
fi

DMG_PATH="dist/OpenClicky-${FINAL_VERSION}-${FINAL_BUILD}.dmg"
if [[ ! -f "$DMG_PATH" ]]; then
    echo "ERROR: release.sh did not produce expected DMG at $DMG_PATH" >&2
    exit 1
fi

# --- Step 3: appcast -------------------------------------------------------
echo ""
echo "==> Step 3/3: Sparkle appcast"
scripts/generate-appcast.sh "$DMG_PATH"

# --- Step 4: publish (optional) -------------------------------------------
TAG="v${FINAL_VERSION}"
if [[ $PUBLISH -eq 1 ]]; then
    echo ""
    echo "==> Step 4: publishing GitHub release ${TAG}"

    command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not found; cannot publish." >&2; exit 1; }
    gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated (run 'gh auth login')." >&2; exit 1; }

    if git rev-parse "$TAG" >/dev/null 2>&1 || gh release view "$TAG" >/dev/null 2>&1; then
        echo "ERROR: tag/release ${TAG} already exists. Bump the version or delete it first." >&2
        exit 1
    fi

    # Commit only the version + appcast bump (not unrelated working changes).
    git add appcast.xml cursor-buddy.xcodeproj/project.pbxproj
    git add -u -- '*Info.plist' 2>/dev/null || true
    if ! git diff --cached --quiet; then
        git commit -m "Release ${FINAL_VERSION} (build ${FINAL_BUILD})"
    else
        echo "    (no version/appcast changes to commit)"
    fi

    # Release notes: --notes override, else autogenerate from commits since last tag.
    NOTES_FILE="$(mktemp)"
    trap 'rm -f "$NOTES_FILE"' EXIT
    if [[ -n "$NOTES" ]]; then
        printf '%s\n' "$NOTES" > "$NOTES_FILE"
    else
        LAST_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
        {
            echo "## OpenClicky ${FINAL_VERSION} (build ${FINAL_BUILD})"
            echo ""
            if [[ -n "$LAST_TAG" ]]; then
                git log "${LAST_TAG}..HEAD" --no-merges --pretty=format:'- %s'
            else
                git log -n 20 --no-merges --pretty=format:'- %s'
            fi
            echo ""
        } > "$NOTES_FILE"
    fi

    BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    git tag "$TAG"
    echo "==> Pushing ${BRANCH} + ${TAG}..."
    git push origin "$BRANCH"
    git push origin "$TAG"

    echo "==> Creating GitHub release ${TAG} with ${DMG_PATH}..."
    gh release create "$TAG" "$DMG_PATH" \
        --title "OpenClicky ${FINAL_VERSION}" \
        --notes-file "$NOTES_FILE"

    echo ""
    echo "================================================================"
    echo "  Published ${TAG}: $(gh release view "$TAG" --json url -q .url 2>/dev/null)"
    if [[ $SKIP_NOTARIZE -eq 1 ]]; then
        echo "  WARNING: DMG is NOT notarized (--skip-notarize). Downloaders hit a"
        echo "           Gatekeeper warning. Re-run without --skip-notarize to ship."
    fi
    echo "================================================================"
    exit 0
fi

echo ""
echo "================================================================"
echo "  Release ${FINAL_VERSION} (build ${FINAL_BUILD}) ready."
echo "================================================================"
echo ""
echo "  DMG:      ${DMG_PATH}"
echo "  Appcast:  appcast.xml"
echo ""
echo "Remaining manual steps:"
echo "  1. Create the GitHub release:"
echo "       gh release create v${FINAL_VERSION} ${DMG_PATH} \\"
echo "         --title \"OpenClicky ${FINAL_VERSION}\" \\"
echo "         --notes \"Release notes here\""
echo ""
echo "  2. Commit + tag + push:"
echo "       git add appcast.xml cursor-buddy.xcodeproj/project.pbxproj"
echo "       git commit -m \"Release ${FINAL_VERSION} (build ${FINAL_BUILD})\""
echo "       git tag v${FINAL_VERSION}"
echo "       git push && git push --tags"
echo ""
echo "  Sparkle SUFeedURL points at the appcast on the main branch, so"
echo "  shipping the appcast.xml commit is what triggers OTA updates."
