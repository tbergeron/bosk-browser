#!/bin/zsh
# Builds, signs, notarizes and packages a Bosk release, and updates the Sparkle appcast.
# One-time setup is in docs/release.md. Usage:
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=bosk-notary \
#   SPARKLE_PUBLIC_KEY=<base64 key from generate_keys> \
#   scripts/release.sh 0.2.0
#
set -euo pipefail

version=${1:?Usage: scripts/release.sh <version>}
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your "Developer ID Application: ..." identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile (xcrun notarytool store-credentials)}"
SPARKLE_FEED_URL=${SPARKLE_FEED_URL:-https://tommybergeron.github.io/bosk/appcast.xml}
: "${SPARKLE_PUBLIC_KEY:?Set SPARKLE_PUBLIC_KEY}"

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/release/$version"
derived="$root/build/release"
build_number=$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)
mkdir -p "$out"

echo "== Test BoskCore"
swift test --package-path "$root/Packages/BoskCore"

echo "== Build $version ($build_number)"
cd "$root"
xcodegen generate --quiet
xcodebuild -scheme Bosk -configuration Release -derivedDataPath "$derived" -destination 'platform=macOS' \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID" OTHER_CODE_SIGN_FLAGS="--timestamp" \
  SPARKLE_FEED_URL="$SPARKLE_FEED_URL" SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" \
  clean build | grep -E "error:|warning: |BUILD" || true
app="$derived/Build/Products/Release/Bosk.app"
[[ -d "$app" ]] || { echo "Build failed." >&2; exit 1; }

echo "== Check the signature"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv "$app" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime" \
  || { echo "The app is not signed with Developer ID and the hardened runtime." >&2; exit 1; }

echo "== Notarize the app"
ditto -c -k --keepParent "$app" "$out/Bosk-notarize.zip"
xcrun notarytool submit "$out/Bosk-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
rm "$out/Bosk-notarize.zip"

echo "== Make the DMG"
dmg="$out/Bosk-$version.dmg"
staging=$(mktemp -d)
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Bosk" -srcfolder "$staging" -ov -format UDZO "$dmg"
rm -rf "$staging"
codesign --sign "$DEVELOPER_ID" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg"

echo "== Update the appcast"
# generate_appcast signs the update with the EdDSA private key in your keychain
# (created by generate_keys) and writes appcast.xml next to the DMGs.
generate_appcast=$(find "$derived/SourcePackages/artifacts" -name generate_appcast -type f | head -1)
"$generate_appcast" --download-url-prefix "https://github.com/tommybergeron/bosk/releases/download/v$version/" "$out"

echo
echo "Done: $dmg and $out/appcast.xml"
echo "Next: create GitHub release v$version with the DMG, then publish appcast.xml at $SPARKLE_FEED_URL."
