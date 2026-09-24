# FalconMail

A native macOS mail client for Apple Silicon, built for people who live in
Google Workspace and are tired of Outlook's archiving.

- IMAP and SMTP with Google OAuth (Google Workspace first)
- Outlook-style three-pane layout: folders, message list, reading pane
- Unified inbox, conversation threading, full-text search including archives
- Archives are computed on the Mac and stored on Google Drive, OneDrive or
  Nextcloud in an open, cross-platform format that Windows can open with
  nothing but Explorer
- Contacts, calendar and Google Meet integration
- Rules, signatures, scheduled send, undo send, offline mode, notifications
- Tokens in the Keychain, optional archive encryption

## Diagnostics

FalconMail sends redacted diagnostic reports to the FalconMail team by default, so
problems are found and fixed quickly.

- **Sent:** errors, crashes, moments when the app stopped responding or used far too much
  processor time or disk, a daily health summary (how many accounts, folders and messages,
  disk used, sync and error counts), and the versions of FalconMail and macOS.
- **Never sent:** messages, subjects, contacts, e-mail addresses, the names of your own
  folders, attachment names or passwords. Addresses and folder names are replaced by
  short codes that cannot be turned back. FalconMail's own log file stays on your Mac;
  only its warnings and errors are reported, redacted the same way.
- **Switching it off:** Settings → Privacy → untick *Send diagnostic data to the
  FalconMail team*. Anything waiting is deleted at once, and *Show Data Waiting to Be
  Sent…* shows exactly what would go.

Only release builds send; a build from source never does. `docs/DIAGNOSTICS.md` says the
same in plain words, then gives the full contract and every redaction rule.

## Layout

| Path | What it is |
| --- | --- |
| `App/FalconMail` | SwiftUI application target |
| `Sources/FalconCore` | Platform library: IMAP, SMTP, MIME, OAuth, cache, sync, rules, archive, cloud storage |
| `Tests/FalconCoreTests` | Unit tests for the library |
| `docs/` | Architecture, archive format, setup, roadmap |
| `project.yml` | XcodeGen definition of the Xcode project |

## Building

See `docs/SETUP.md`. Short version:

```sh
./scripts/setup.sh
open FalconMail.xcodeproj
```

Requirements: macOS 14 or later, Apple Silicon, Xcode 15.3 or later.
