#!/bin/zsh
# Builds, signs, notarizes and packages a Bosk release, and updates the Sparkle appcast.
# With --publish, it also creates the GitHub release (tag v<version>) with the DMG and the
# appcast, and marks it as the latest release. One-time setup is in docs/release.md. Usage:
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=bosk-notary \
#   scripts/release.sh 0.2.0 [--publish]
#
set -euo pipefail

version=${1:?Usage: scripts/release.sh <version> [--publish]}
publish=false
[[ "${2:-}" == "--publish" ]] && publish=true
repo=tbergeron/bosk-browser
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your "Developer ID Application: ..." identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile (xcrun notarytool store-credentials)}"
SPARKLE_FEED_URL=${SPARKLE_FEED_URL:-https://github.com/tbergeron/bosk-browser/releases/latest/download/appcast.xml}
# The public key is in project.yml; set SPARKLE_PUBLIC_KEY only to override it.
SPARKLE_PUBLIC_KEY=${SPARKLE_PUBLIC_KEY:-$(sed -nE 's/^ *SPARKLE_PUBLIC_KEY: "(.*)"/\1/p' "$(dirname "$0")/../project.yml")}

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/release/$version"
derived="$root/build/release"
build_number=$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)
mkdir -p "$out"

# Check everything for publishing before the long build, so a problem shows at once.
if $publish; then
  echo "== Check that the release can be published"
  command -v gh >/dev/null || { echo "Install the GitHub CLI: brew install gh" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "Sign in to GitHub first: gh auth login" >&2; exit 1; }
  [[ -z "$(git -C "$root" status --porcelain)" ]] \
    || { echo "Commit your changes first: the release must match the pushed code." >&2; exit 1; }
  git -C "$root" fetch --quiet origin main
  [[ "$(git -C "$root" rev-parse HEAD)" == "$(git -C "$root" rev-parse origin/main)" ]] \
    || { echo "Push main first: the release tag goes on the pushed commit." >&2; exit 1; }
  ! gh release view "v$version" --repo "$repo" >/dev/null 2>&1 \
    || { echo "Release v$version already exists on GitHub." >&2; exit 1; }
fi

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
"$generate_appcast" --download-url-prefix "https://github.com/$repo/releases/download/v$version/" "$out"

if $publish; then
  echo "== Publish GitHub release v$version"
  # --latest makes the feed address (releases/latest/download/appcast.xml) point to this release.
  gh release create "v$version" "$dmg" "$out/appcast.xml" --repo "$repo" \
    --target "$(git -C "$root" rev-parse HEAD)" --title "Bosk $version" --generate-notes --latest
  echo
  echo "Published: https://github.com/$repo/releases/tag/v$version"
else
  echo
  echo "Done: $dmg and $out/appcast.xml"
  echo "To publish, run again with --publish, or create GitHub release v$version with both files."
fi
