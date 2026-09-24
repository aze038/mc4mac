# In-app updates from GitHub Releases

FalconMail checks the GitHub Releases of the repository named by
`FalconUpdateRepository` in `Info.plist` (default `aze038/mc4mac`) eight
seconds after launch and every six hours, plus on demand from the FalconMail
menu or Settings → Updates.

## What a release must contain

| Asset | Required | Purpose |
| --- | --- | --- |
| `FalconMail-<version>.dmg` | for people | Drag-to-Applications disk image |
| `FalconMail-<version>.zip` | yes | The same app zipped with `ditto -c -k --keepParent`; the in-app updater downloads this one |
| `update.json` | no | Metadata, see below |

The release tag is the version, for example `v0.2.0`. It is compared with the
app's `CFBundleShortVersionString`. Drafts are ignored. Pre-releases are
ignored unless the user opts in.

`update.json`:

```json
{
  "version": "0.2.0",
  "mandatory": false,
  "minimumSupportedVersion": "0.1.5",
  "sha256": "<sha256 of the zip>",
  "notes": "Optional release notes, overrides the release body"
}
```

- `mandatory: true`, or a line `mandatory: true` or the token `[mandatory]` in
  the release body, marks a serious-bug release. The user gets only "Update
  Now" or "Quit". Skip and Later are not offered and the app is disabled
  behind the prompt.
- `minimumSupportedVersion` makes the update mandatory only for installs older
  than that version.
- `sha256` is verified after download when present.

## What happens on update

1. The zip is streamed to a temporary folder with a progress bar.
2. `ditto` extracts it, the bundle version is checked, and `codesign --verify`
   must pass.
3. Session state is saved: open drafts (already saved on every keystroke), the
   selected folder and messages, the search text, and every open message
   window.
4. The running bundle is moved aside, the new one copied into place, and a
   shell waits for the old process to exit before `open`ing the new app.
5. On launch the app restores the selection and reopens every compose and
   message window.

If anything fails the previous bundle is put back and the prompt shows the
error with a retry button.

## Private repositories

A public repository needs no credentials. For a private repository the user
stores a fine-grained token with read access to Contents in Settings → Updates.
It lives in the Keychain.

## CI contract

The release workflow in the backlog must: build for arm64, sign with Developer
ID, notarize, staple, zip with `ditto -c -k --keepParent`, compute the sha256,
write `update.json`, and publish both assets on a GitHub Release whose tag is
`v<version>`.

## Workflows

- `.github/workflows/ci.yml` builds the app and, on every push, runs the
  FalconCore tests, the diagnostics web app's and triage tools' tests, and the
  test of `scripts/embed-google-client.sh`.
- `.github/workflows/release.yml` runs on a `v*` tag or by hand from the
  Actions tab (with a "mandatory" checkbox). It builds Release, signs and
  notarizes when the secrets exist, zips the app, writes `update.json` with
  the sha256 and publishes the GitHub Release. Tag a release with
  `git tag v0.2.0 && git push origin v0.2.0`.

## Read-only locations and App Translocation

An unsigned app opened from Downloads runs from a hidden read-only mount
(App Translocation), and an app launched from a mounted DMG is read-only too.
The updater therefore installs into `/Applications` (or `~/Applications`)
whenever the running bundle cannot be replaced in place, and relaunches from
there. On launch from any location outside an Applications folder the app
offers to move itself there once; "Not Now" is remembered.
