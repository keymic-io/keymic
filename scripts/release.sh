#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
APP_NAME="KeyMic"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_DIR="${PROJECT_DIR}/.release"
SPARKLE_TOOLS_DIR="${HOME}/.sparkle-tools"
KEYCHAIN_ACCOUNT="ed25519"  # Sparkle EdDSA signing key
RELEASE_REPO_SLUG="keymic-io/keymic"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>  e.g. $0 1.1.0"
    exit 1
fi

if [[ ! -x "${SPARKLE_TOOLS_DIR}/generate_appcast" ]]; then
    echo "Error: ${SPARKLE_TOOLS_DIR}/generate_appcast missing. Re-extract Sparkle tools."
    exit 1
fi

cd "$PROJECT_DIR"

echo "==> Updating Info.plist version to ${VERSION}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" Info.plist

echo "==> Building ${APP_NAME} ${VERSION}"
make build

echo "==> Preparing release assets"
rm -rf "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}"

APP_ZIP="${APP_NAME}-${VERSION}.zip"
APP_ZIP_PATH="${RELEASE_DIR}/${APP_ZIP}"
rm -f "$APP_ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "$APP_ZIP_PATH"
echo "==> Packaged: ${APP_ZIP_PATH}"

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

gh release create "v${VERSION}" \
    --repo "${RELEASE_REPO_SLUG}" \
    --title "${APP_NAME} v${VERSION}" \
    --notes "Release v${VERSION}" \
    "$APP_ZIP_PATH"

echo "Release v${VERSION} complete!"
