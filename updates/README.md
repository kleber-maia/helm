# Publishing Helm updates

Helm uses Sparkle 2.10.1. It checks hourly while open and on demand via
**Helm → Check for Updates…**. Updates require user confirmation before
installation and relaunch; running terminal processes are not restored.
The signed appcast on this branch is the index, and ZIPs come from tagged
GitHub Releases, including prereleases. GitHub's `/releases/latest` omits betas.

## Prepare a release

1. Increase `CURRENT_PROJECT_VERSION` (a strictly increasing integer across
   all release channels) and update `MARKETING_VERSION` in the app target
   configurations. The GitHub tag is `v` plus the marketing version.
2. Build and verify the Apple Silicon release from the exact source to tag.
   Verify signing, the app's launch, and the update flow with test copies
   before distributing. Developer ID signing and notarization, when available,
   are separate from the signatures on the feed and ZIP.
3. Use the [official Sparkle 2.10.1 tools][sparkle] and the existing Helm
   signing key in the login Keychain (Sparkle account `group.soft.HelmIDE`).
   Keep a secure backup of this key; do not commit or export it into the
   project. The app ships only the matching public key.

   ```bash
   python3 scripts/prepare-release.py \
     --app build/DerivedData/Build/Products/Release/Helm.app \
     --sparkle /path/to/extracted/Sparkle-2.10.1 \
     --account group.soft.HelmIDE --tag v1.0b22
   ```

   Optional `--notes path/to/notes.html` embeds notes in the feed. The
   command stages and verifies the signed ZIP and appcast under
   `build/releases/<tag>/`, without touching the published feed.

## Publish and verify

1. Upload the exact `Helm-<version>-arm64.zip` to the matching tagged
   [GitHub release][releases]. Verify it is public and matches the prepared
   archive before making the feed live.
2. Copy the generated `appcast.xml` here byte-for-byte and push it to
   `main`. Check the [public raw feed][feed]. Do not hand-edit signed XML
   or overwrite a published archive. Correct a faulty release with a
   higher build and a new tag.
3. Check that the current build reports no update and an older
   updater-enabled build finds the prerelease. For an install smoke test,
   use disposable copies and a test signing key; never publish fixtures or
   bad signatures. Include rejected downloads, install and relaunch, and
   session restoration as appropriate.

Helm requires signature verification for the feed and for the ZIP before
extraction. A new key cannot simply replace the existing key for clients that
already trust it. If the private key is lost, the current ad-hoc distribution
requires users to install a new trusted build manually.

[sparkle]: https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1
[releases]: https://github.com/kleber-maia/helm/releases
[feed]: https://raw.githubusercontent.com/kleber-maia/helm/main/updates/appcast.xml
