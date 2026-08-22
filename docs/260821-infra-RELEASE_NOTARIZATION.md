# Release: signing, notarization, credentials

Reference for `## Sign, Notarize & Release` in CLAUDE.md. This is the process
that produced v1.4.4, plus the parts that bit us afterwards.

## Credentials

Notarization uses a `notarytool` keychain profile named `pc418` (Apple ID +
app-specific password, team VBC54DC2R5). The Developer ID signing identity
(`262B7A8B…`, "Developer ID Application: Jiachen Gao") lives in the same login
keychain.

Both are **machine-local**: they do not sync and are not backed up in this repo.
Confirm the profile before starting a release:

```bash
xcrun notarytool history --keychain-profile "pc418"   # lists past submissions
```

If the keychain is locked this can report `No Keychain password item found for
profile: pc418` even though the profile exists — unlock the login keychain and
retry before concluding it is gone. If it genuinely is gone, recreate it;
app-specific passwords cannot be read back from Apple, only regenerated at
appleid.apple.com → Sign-In and Security:

```bash
xcrun notarytool store-credentials "pc418" \
  --apple-id "<apple-id-email>" --team-id VBC54DC2R5 --password "<app-specific-password>"
```

## Staple the DMG, not just the .app

Stapling `pitchshift.app` does **not** propagate into a disk image built from it.
An un-stapled DMG forces Gatekeeper into a live lookup against Apple, so users who
are offline or behind a firewall get a first-open failure. v1.4.4 shipped this way:
the app inside both artifacts validates, but `xcrun stapler validate pitchshift.dmg`
reports "does not have a ticket stapled to it".

Verify both artifacts before uploading — each must say `source=Notarized Developer ID`:

```bash
spctl -a -vvv -t exec pitchshift.app && xcrun stapler validate pitchshift.app
xcrun stapler validate pitchshift.dmg
```

## CI does not notarize

`.github/workflows/release.yml` is armed on `push: tags: 'v*'` and only runs
`make build`, which ad-hoc signs (`codesign --sign -`). Since the credentials are
in the local keychain rather than GitHub secrets, CI cannot notarize — a
`git push --tags` would run it and let `softprops/action-gh-release` overwrite good
manual artifacts with Gatekeeper-rejected ones. As of v1.4.4 the workflow has never
run; every release asset was uploaded by hand.

Until it is fixed, either disarm it (`on: workflow_dispatch:`) or wire it up:

1. Export the Developer ID cert as a password-protected `.p12`, `base64 -i cert.p12`.
2. Add repo secrets `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`,
   `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID` (`VBC54DC2R5`), `NOTARY_PASSWORD`. An App
   Store Connect API key (`--key` / `--key-id` / `--issuer`) is the better fit here
   than an app-specific password, since the same `.p8` works locally and in CI.
3. Import the cert into an ephemeral keychain before the build step, then run
   `sign.sh` + `notarytool submit` + `stapler staple` before the DMG/ZIP packaging.

Two ordering traps: `sign.sh` calls `make build` itself, so the standalone
`make build` step becomes a redundant second build; and stapling must happen
*before* packaging so the ticket ends up inside the shipped artifacts.

## Account

The repo is public, so `gh release create` must run as **pc418**
(`~/gh-login/gh-login.sh`, then `gh auth logout --hostname github.com --user pc418`
immediately after). The default logged-in account is `facilec`.
