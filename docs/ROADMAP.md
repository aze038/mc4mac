# Roadmap

## Milestone 1: Foundation (this branch)

- [x] Project layout, XcodeGen, FalconCore package
- [x] Google OAuth with PKCE and loopback redirect, tokens in Keychain
- [x] IMAP client: XOAUTH2, LIST, SELECT, UID FETCH/SEARCH/STORE/MOVE, APPEND, IDLE
- [x] SMTP client with XOAUTH2
- [x] MIME parser and builder
- [x] File-based cache with one actor per folder, no SQLite
- [x] Sync engine with IDLE, flags, expunge, offline bodies
- [x] Conversation threading
- [x] Rules engine, outbox with scheduled send and undo send
- [x] Archive format v1, zip chunk writer, encryption, Google Drive backend
- [x] Archive reader with range reads and in-memory index search
- [x] Core Spotlight indexing
- [x] Three-pane UI, compose, account setup, archive UI, settings
- [x] Google People and Calendar clients, agenda view, Google Meet creation
- [x] In-app updates from GitHub Releases with mandatory mode and session restore
- [x] GitHub Actions: CI build and tests on every push, Release workflow on tags
- [x] First CI build green, v1.0.0 published on GitHub Releases
- [ ] Smoke test on a Mac with a Workspace test account

## Milestone 2: Daily driver

- Full calendar views (day, week, month), invitation accept/decline from mail
- Contact autocomplete ranking, contact groups
- HTML compose with formatting toolbar and inline images
- Drafts sync with the server
- Load older messages on demand, per-folder sync windows
- Smart folders (unread, flagged, attachments)
- Keyboard shortcuts parity with Outlook

## Milestone 3: Cross-platform archives

- Windows reference reader for `.fmarchive` (small .NET or Python tool)
- OLM and PST import
- Archive scheduling (auto-archive mail older than N months every week)
- Archive search across all archives at once

## Milestone 4: Microsoft 365 and Nextcloud

- Microsoft Graph mail, OneDrive backend, Teams meeting creation
- Nextcloud WebDAV backend, CalDAV and CardDAV
- Unified calendar and contacts across providers

## Backlog

- Add Developer ID signing and notarization secrets to the Release workflow
  (`MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_TEAM_ID`,
  `APPLE_ID`, `APPLE_APP_PASSWORD`). Until then releases are ad-hoc signed and
  need a right-click → Open on first launch.
- Sparkle-style in-app updates fed by GitHub Releases
- Crash reporting opt-in

## Compose window notes

- A message can be opened in its own window (⌘O or the context menu) so it sits
  next to a compose window.
- Attachments in the reading pane are draggable into any compose window, onto
  the Desktop, or into Finder. Files from Finder can be dropped on a compose
  window.
- "Edit in Default App" on a compose attachment opens it in Excel, Word or
  whatever owns the file type. FalconMail watches the file and refreshes the
  attachment on every save. macOS does not allow Office to be embedded inside
  another app's window, so this is the native equivalent of in-place editing.
