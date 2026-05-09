#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
APP_NAME="KeyMic"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="${PROJECT_DIR}/.release"
SPARKLE_TOOLS_DIR="${HOME}/.sparkle-tools"
KEYCHAIN_ACCOUNT="ed25519"  # Sparkle EdDSA signing key
RELEASE_REPO_SLUG="keymic-io/keymic"

FORCE=0
VERSION=""
for arg in "$@"; do
    case "$arg" in
        -f|--force) FORCE=1 ;;
        -*) echo "Unknown flag: $arg"; exit 1 ;;
        *) VERSION="$arg" ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 [-f] <version>  e.g. $0 -f 0.1.0"
    exit 1
fi

if [[ ! -x "${SPARKLE_TOOLS_DIR}/generate_appcast" ]]; then
    echo "Error: ${SPARKLE_TOOLS_DIR}/generate_appcast missing. Re-extract Sparkle tools."
    exit 1
fi

cd "$PROJECT_DIR"

if [[ "$FORCE" -eq 1 ]]; then
    echo "==> Force mode: removing existing v${VERSION} release/tag"
    gh release delete "v${VERSION}" --repo "${RELEASE_REPO_SLUG}" --yes --cleanup-tag 2>/dev/null || true
    git tag -d "v${VERSION}" 2>/dev/null || true
    git push origin ":refs/tags/v${VERSION}" 2>/dev/null || true
fi

echo "==> Updating Info.plist version to ${VERSION}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" Info.plist

echo "==> Preparing release assets"
rm -rf "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}"

# Build each arch separately
for ARCH in arm64 x86_64; do
    echo "==> Building ${APP_NAME} ${VERSION} (${ARCH})"
    swift build -c release --arch "${ARCH}"
done

ARM64_BIN="$(swift build -c release --arch arm64 --show-bin-path)/${APP_NAME}"
X86_BIN="$(swift build -c release --arch x86_64 --show-bin-path)/${APP_NAME}"
ARM64_SPARKLE="$(swift build -c release --arch arm64 --show-bin-path)/Sparkle.framework"

# Merge into universal binary
echo "==> Merging into universal binary with lipo"
UNIVERSAL_BIN="${RELEASE_DIR}/${APP_NAME}-universal"
lipo -create -output "${UNIVERSAL_BIN}" "${ARM64_BIN}" "${X86_BIN}"
lipo -info "${UNIVERSAL_BIN}"

# Assemble universal .app bundle
BUNDLE="${PROJECT_DIR}/${APP_NAME}.app"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources" "${BUNDLE}/Contents/Frameworks"
cp "${UNIVERSAL_BIN}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
install_name_tool -add_rpath "@executable_path/../Frameworks" "${BUNDLE}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
cp Info.plist "${BUNDLE}/Contents/"
cp Resources/gitleaks.toml "${BUNDLE}/Contents/Resources/"
cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/"
cp Resources/TrayIconTemplate.png "${BUNDLE}/Contents/Resources/"
cp Resources/TrayIconTemplate@2x.png "${BUNDLE}/Contents/Resources/"
cp -R "${ARM64_SPARKLE}" "${BUNDLE}/Contents/Frameworks/"
codesign --force --deep --sign "${CODESIGN_IDENTITY}" "${BUNDLE}/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "${CODESIGN_IDENTITY}" "${BUNDLE}"

APP_ZIP="${APP_NAME}-${VERSION}.zip"
ditto -c -k --sequesterRsrc --keepParent "${BUNDLE}" "${RELEASE_DIR}/${APP_ZIP}"
echo "==> Packaged: ${RELEASE_DIR}/${APP_ZIP}"

echo "==> Generating appcast.xml with generate_appcast"
cd "${RELEASE_DIR}"
rm -f appcast.xml

"${SPARKLE_TOOLS_DIR}/generate_appcast" \
    --account "${KEYCHAIN_ACCOUNT}" \
    --download-url-prefix "https://github.com/${RELEASE_REPO_SLUG}/releases/download/v${VERSION}/" \
    "${RELEASE_DIR}"

if [[ ! -f appcast.xml ]]; then
    echo "Error: generate_appcast did not produce appcast.xml"
    exit 1
fi
echo "==> appcast.xml generated"

cd "$PROJECT_DIR"
git add Info.plist
if git diff --cached --quiet; then
    echo "==> No Info.plist changes to commit"
else
    git commit -m "release: v${VERSION}"
    git push
    echo "==> Info.plist committed and pushed"
fi

# Deploy appcast.xml to gh-pages branch for Sparkle auto-update.
# The main source branch does NOT track appcast.xml — it lives exclusively
# on the gh-pages branch, served via GitHub Pages.
GH_PAGES_DIR=$(mktemp -d)
git worktree add "$GH_PAGES_DIR" gh-pages
cp "${RELEASE_DIR}/appcast.xml" "${GH_PAGES_DIR}/appcast.xml"
cd "$GH_PAGES_DIR"
git add appcast.xml
git commit -m "appcast: v${VERSION}"
git push origin gh-pages
cd "$PROJECT_DIR"
git worktree remove "$GH_PAGES_DIR"
echo "==> appcast.xml deployed to gh-pages"

git tag -a "v${VERSION}" -m "Release v${VERSION}"
git push origin "v${VERSION}"
echo "==> Tag v${VERSION} pushed"

gh release create "v${VERSION}" \
    --repo "${RELEASE_REPO_SLUG}" \
    --title "${APP_NAME} v${VERSION}" \
    --notes "Release v${VERSION}" \
    "${RELEASE_DIR}/${APP_NAME}-${VERSION}.zip"

echo "Release v${VERSION} complete!"
