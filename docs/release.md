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
4. **GitHub.** Create the repository `tommybergeron/bosk` and turn on GitHub Pages.
   The DMGs go to GitHub Releases, and the update feed is
   `https://tommybergeron.github.io/bosk/appcast.xml` (the default in `scripts/release.sh`).

## Each release

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=bosk-notary SPARKLE_PUBLIC_KEY=… scripts/release.sh 0.2.0
```

The script:
1. runs the BoskCore tests;
2. builds Release with the version and build number;
3. signs with Developer ID and the hardened runtime, then checks the signature;
4. notarizes and staples the app;
5. makes, signs, notarizes and staples the DMG;
6. updates `appcast.xml`.

Then upload the DMG to the GitHub release `v<version>` of tommybergeron/bosk, and publish
`appcast.xml` on GitHub Pages.

## Check before publishing

- On a Mac that never had Bosk: open the DMG, drag Bosk to Applications, open it. There must be
  no Gatekeeper warning.
- Install version N, publish N+1, and choose "Check for Updates…": Sparkle updates to N+1.
- Run the checks in docs/manual-checklist.md and docs/perf-budgets.md.
