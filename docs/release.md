# Release

A release has four parts that must agree: the version in `project.yml`, a git tag on GitHub, a GitHub Release that
carries the DMG and the Sparkle ZIP, and `appcast.xml` on the `gh-pages` branch. The app reads
`https://asonas.github.io/Kikimimi/appcast.xml` (`SUFeedURL`), and the appcast points at the ZIP in the GitHub Release.

## What each file is for

| File | Who downloads it | Made by |
|---|---|---|
| `build/Kikimimi.dmg` | A person installing for the first time | `mise run notarize` |
| `build/Kikimimi-<version>.zip` | Sparkle, when updating an installed app | `mise run sparkle-zip` |
| `build/appcast.xml` | Sparkle, to learn that an update exists | `mise run appcast` |

Both the DMG and the ZIP contain the same Developer ID signed, notarized, stapled `Kikimimi.app`.

## Once per machine

- **Developer ID certificate**: `Developer ID Application: Yuya Fujiwara (QYP65434UW)` in the login keychain.
- **notarytool profile**: `mise run setup-notary` stores an Apple ID and an app-specific password as the keychain
  profile named by `NOTARY_PROFILE`. The profile belongs to the team, so the one made for YoruMimizuku is reused.
- **Sparkle key**: the EdDSA private key is in the login keychain under the account `kikimimi`. Its public half is
  `SUPublicEDKey` in `project.yml`. Every installed copy trusts only this key, so losing it means no installed copy
  can be updated again. Back it up with
  `build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account kikimimi -x <file>` and keep
  the file out of the repository.

## Procedure

1. On a clean `main`: `mise run bump <x.y.z>`, then commit `project.yml` and `App/Info.plist`.
   The bump also increments the build number. Sparkle compares build numbers, so a release whose build number did
   not grow is never offered.
2. Tag and push before publishing, so the release is cut from the commit that was built:
   ```bash
   git tag v<x.y.z>
   git push origin main v<x.y.z>
   ```
3. `mise run release` builds, signs, notarizes, and writes the three files above.
4. Write `build/release-notes-<x.y.z>.md`.
5. `mise run publish:release` creates the GitHub Release with the ZIP and the DMG.
6. `mise run publish:appcast` commits `appcast.xml` to `gh-pages` and waits until GitHub Pages has built it.
7. In an installed older copy, choose Kikimimi > アップデートを確認… and confirm the new version is offered.

Step 5 comes before step 6 on purpose: once the appcast is public, installed copies try to download the ZIP.

## When notarization fails

- `HTTP status code: 403. A required agreement is missing or has expired`: the Account Holder has to accept the
  updated agreement at https://developer.apple.com/account. Nothing in this repository can fix it.
- Any other rejection: `xcrun notarytool log <submission-id> --keychain-profile "$NOTARY_PROFILE"` lists the files
  that failed and why.

## Behavior to keep in mind

- Updates are offered, never installed silently (`SUAutomaticallyUpdate` is not set).
- A scheduled check is skipped while a recording is in progress, so no update window appears over an interview
  (`App/Update/AppUpdater.swift`). A check the user asks for from the menu still runs.
- Sparkle does not downgrade. To pull a bad release, publish a newer build number.
