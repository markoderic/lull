# Releasing

## First time only

Store notarization credentials. This asks for an app-specific password, which you create at [account.apple.com](https://account.apple.com).

```bash
xcrun notarytool store-credentials lull-notary --apple-id you@example.com --team-id B376DM5LNP
```

Publish the repository:

```bash
gh repo create markoderic/lull --public --source . --push --description "GIFs and looping videos as your Mac wallpaper. It rests when nobody's looking."
```

## Each release

1. Update the version in `Resources/Info.plist` and add an entry to `CHANGELOG.md`.
2. Run the tests:

   ```bash
   swift test
   python3 scripts/e2e/run.py
   ```

3. Build, sign and notarize:

   ```bash
   NOTARY_PROFILE=lull-notary SIGN_IDENTITY="Developer ID Application: Marko Deric (B376DM5LNP)" scripts/release.sh
   ```

4. Publish, replacing the version in both places:

   ```bash
   gh release create v1.0.0 dist/Lull-1.0.0.dmg --title "Lull 1.0.0" --notes-file CHANGELOG.md
   ```

Without notarization, downloaders see a macOS warning and have to approve the app in System Settings.
