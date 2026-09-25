#!/bin/zsh
# Builds, signs, notarizes and packages a Bosk release, and updates the Sparkle appcast.
# With --publish, it also creates the GitHub release (tag v<version>) with the DMG and the
# appcast, marks it as the latest release, and updates the Homebrew cask in the tap
# (a clone of tbergeron/homebrew-bosk next to this repository, or HOMEBREW_TAP).
# One-time setup is in docs/release.md. Usage:
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
tap=${HOMEBREW_TAP:-$root/../homebrew-bosk}
out="$root/release/$version"
derived="$root/build/release"
build_number=$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)
mkdir -p "$out"

# notarytool exits 0 even when Apple refuses the file, so check the status and show why.
notarize() {
  local result id
  result=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait | tee /dev/stderr)
  grep -q "status: Accepted" <<< "$result" && return
  id=$(sed -nE 's/^ *id: (.*)/\1/p' <<< "$result" | head -1)
  xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
  echo "Notarization refused $1. The reasons are above." >&2
  exit 1
}

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
  [[ -f "$tap/Casks/bosk.rb" ]] \
    || { echo "No Homebrew tap at $tap. Clone tbergeron/homebrew-bosk there, or set HOMEBREW_TAP." >&2; exit 1; }
  [[ -z "$(git -C "$tap" status --porcelain)" ]] \
    || { echo "The Homebrew tap at $tap has changes. Commit or remove them first." >&2; exit 1; }
  git -C "$tap" pull --quiet --ff-only
fi

echo "== Test BoskCore"
swift test --package-path "$root/Packages/BoskCore"

echo "== Build $version ($build_number)"
cd "$root"
xcodegen generate --quiet
xcodebuild -scheme Bosk -configuration Release -derivedDataPath "$derived" -destination 'platform=macOS' \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID" OTHER_CODE_SIGN_FLAGS="--timestamp" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  SPARKLE_FEED_URL="$SPARKLE_FEED_URL" SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" \
  clean build | grep -E "error:|warning: |BUILD" || true
app="$derived/Build/Products/Release/Bosk.app"
[[ -d "$app" ]] || { echo "Build failed." >&2; exit 1; }

# Xcode signs only the top of Sparkle.framework; its helpers stay ad-hoc signed and
# notarization refuses them. Sign them from the inside out, then the framework and the app.
echo "== Sign Sparkle"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for item in Versions/B/XPCServices/Installer.xpc Versions/B/XPCServices/Downloader.xpc \
            Versions/B/Autoupdate Versions/B/Updater.app .; do
  codesign -f -s "$DEVELOPER_ID" -o runtime --timestamp --preserve-metadata=entitlements "$sparkle/$item"
done
codesign -f -s "$DEVELOPER_ID" -o runtime --timestamp \
  --entitlements "$root/Bosk/Resources/Bosk.entitlements" "$app"

echo "== Check the signature"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv "$app" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime" \
  || { echo "The app is not signed with Developer ID and the hardened runtime." >&2; exit 1; }
! codesign -d --entitlements - "$app" 2>&1 | grep -q get-task-allow \
  || { echo "The app has the get-task-allow entitlement; notarization refuses it." >&2; exit 1; }

echo "== Notarize the app"
ditto -c -k --keepParent "$app" "$out/Bosk-notarize.zip"
notarize "$out/Bosk-notarize.zip"
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
notarize "$dmg"
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

  echo "== Update the Homebrew cask"
  # The cask downloads the DMG from the release, so it changes only after the release exists.
  sha=$(shasum -a 256 "$dmg" | cut -d " " -f 1)
  sed -i "" -E -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" \
    "$tap/Casks/bosk.rb"
  grep -q "^  version \"$version\"" "$tap/Casks/bosk.rb" && grep -q "^  sha256 \"$sha\"" "$tap/Casks/bosk.rb" \
    || { echo "Could not update $tap/Casks/bosk.rb. Change version and sha256 in it yourself." >&2; exit 1; }
  git -C "$tap" commit --quiet -m "Bosk $version" -- Casks/bosk.rb
  git -C "$tap" push --quiet origin HEAD
  echo
  echo "Published: https://github.com/$repo/releases/tag/v$version"
  echo "Homebrew: brew install --cask tbergeron/bosk/bosk"
else
  echo
  echo "Done: $dmg and $out/appcast.xml"
  echo "To publish, run again with --publish, or create GitHub release v$version with both files."
fi
