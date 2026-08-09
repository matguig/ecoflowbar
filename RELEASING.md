# Releasing EcoFlowBar

Distribution model: **notarized DMG via GitHub Releases** — no website to
maintain.

## One-time: Apple setup

1. Enroll in the [Apple Developer Program](https://developer.apple.com/programs/)
   ($99/year).
2. Create a **Developer ID Application** certificate:
   Xcode → Settings → Accounts → Manage Certificates → "+" →
   Developer ID Application.
3. Export it as `.p12` (right-click in Xcode/Keychain → Export) with a
   password.
4. Create an **app-specific password** at [appleid.apple.com](https://appleid.apple.com)
   (Sign-In and Security → App-Specific Passwords).
5. Locally, store the notarization profile:

   ```bash
   xcrun notarytool store-credentials ecoflow-notary \
     --apple-id "you@example.com" --team-id "YOURTEAMID" --password "xxxx-xxxx-xxxx-xxxx"
   ```

6. On GitHub (Settings → Secrets and variables → Actions), create the
   secrets listed at the top of
   [.github/workflows/release.yml](.github/workflows/release.yml)
   (`base64 -i cert.p12 | pbcopy` for `MACOS_CERT_P12`).

## Every release

### Via CI (recommended)

```bash
git tag v1.0.0 && git push origin v1.0.0
```

GitHub Actions builds the self-contained app, signs it, notarizes it and
publishes the DMG on the release. Nothing else to do.

### Locally

```bash
EF_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
EF_NOTARY_PROFILE=ecoflow-notary \
./release.sh 1.0.0
```

Without those variables, `./release.sh 1.0.0` produces an **ad-hoc test
DMG** (rejected by Gatekeeper on other machines — local testing only).

## What ships inside the app

`release.sh` embeds into `EcoFlowBar.app/Contents/Resources/daemon/`:
the daemon scripts, the BLE library, and a **standalone Python runtime**
(python-build-standalone) with dependencies preinstalled.
**Zero user prerequisites**: macOS 14+ on Apple Silicon, that's it.
DMG ≈ 50 MB.
