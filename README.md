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
brew install xcodegen
xcodegen generate
open FalconMail.xcodeproj
```

Requirements: macOS 14 or later, Apple Silicon, Xcode 15.3 or later.
