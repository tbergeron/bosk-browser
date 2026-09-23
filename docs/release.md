# Releasing Bosk

Bosk is distributed as a notarized DMG (not the Mac App Store), with Sparkle 2 for updates.
It is not sandboxed.

## One-time setup

These steps need your Apple Developer account and your keychain, so they are not automated.

1. **Developer ID certificate.** In Xcode > Settings > Accounts > Manage Certificates, add a
   "Developer ID Application" certificate. Check it with
   `security find-identity -v -p codesigning`.
   (On 2026-09-23 this Mac had only Apple Development and Apple Distribution certificates.)
2. **Notarization credentials.** Create an app-specific password at account.apple.com, then:
   ```bash
   xcrun notarytool store-credentials bosk-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```
3. **Sparkle keys.** Build once, then run Sparkle's key tool. It saves the private key in your
   keychain and prints the public key:
   ```bash
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```
4. **GitHub.** The repository `tbergeron/bosk-browser` must be **public**, so people can download
   the DMG and Sparkle can read the feed without signing in. No GitHub Pages: the feed is a file
   attached to each release, at
   `https://github.com/tbergeron/bosk-browser/releases/latest/download/appcast.xml`
   (the default in `scripts/release.sh`). GitHub sends that address to the newest release.

## Each release

Publishing needs the GitHub CLI, one time: `brew install gh`, then `gh auth login`.
Commit and push first: `--publish` refuses to run when the code on GitHub is not the code you build.

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=bosk-notary scripts/release.sh 0.2.0 --publish
```

The script:
1. runs the BoskCore tests;
2. builds Release with the version and build number;
3. signs with Developer ID and the hardened runtime, then checks the signature;
4. notarizes and staples the app;
5. makes, signs, notarizes and staples the DMG;
6. updates `appcast.xml`;
7. with `--publish`: creates the GitHub release `v<version>` with the DMG and `appcast.xml`,
   with notes made from the commits, and marks it as the latest release.

Without `--publish`, create the GitHub release `v<version>` yourself and attach both files.
Mark it as the latest release, so the feed address points to it.

## Check before publishing

- On a Mac that never had Bosk: open the DMG, drag Bosk to Applications, open it. There must be
  no Gatekeeper warning.
- Install version N, publish N+1, and choose "Check for Updates…": Sparkle updates to N+1.
- Run the checks in docs/manual-checklist.md and docs/perf-budgets.md.
