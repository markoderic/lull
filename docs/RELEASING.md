# Releasing

## First time only

Store notarization credentials. This asks for an app-specific password, which you create at [account.apple.com](https://account.apple.com) under Sign-In and Security. The password goes straight into your keychain. This Mac is already set up.

```bash
xcrun notarytool store-credentials lull-notary --apple-id you@example.com --team-id B376DM5LNP
```

Publish the repository:

```bash
gh repo create markoderic/lull --public --source . --push --description "GIFs and looping videos as your Mac wallpaper. It rests when nobody's looking."
```

## Each release

1. Update the version in `Resources/Info.plist` and add an entry to `CHANGELOG.md`.
2. Run the tests. The second command takes over your screen for about 8 minutes, and `--hardened` runs them under the security settings a signed release uses.

   ```bash
   swift test
   python3 scripts/e2e/run.py --hardened
   ```

3. Build, sign and notarize. Apple checks the app and the DMG separately, which usually takes a few minutes. The script stops if Apple rejects either one, and finishes by checking them the way macOS checks a download.

   ```bash
   NOTARY_PROFILE=lull-notary SIGN_IDENTITY="Developer ID Application: Marko Deric (B376DM5LNP)" scripts/release.sh
   ```

4. Publish, replacing the version throughout:

   ```bash
   gh release create v1.0.0 dist/Lull-1.0.0.dmg dist/Lull-1.0.0.dmg.sha256 --title "Lull 1.0.0" --notes-file CHANGELOG.md
   ```

## Certificate expiry

The Developer ID certificate on this Mac expires on February 1, 2027. Renew it in your Apple Developer account before then. Releases already signed and notarized should keep working after it expires, but new ones can't be signed without a current certificate.
