# FalconMail architecture

## Principles

1. Native only. Swift, SwiftUI, AppKit where SwiftUI is not enough, plain
   files for the local cache, Core Spotlight for full-text search, CryptoKit
   for encryption, Network.framework for sockets. No third-party packages and
   no SQLite anywhere.
2. Apple Silicon only, macOS 14 or later.
3. Archives never touch the local disk. They are built in memory and streamed
   to cloud storage in bounded chunks.
4. Parallel by folder. Every folder owns its own directory and its own actor,
   so accounts and folders write at the same time without a shared lock.
5. Open formats. Anything the user keeps long term is stored in a format a
   Windows machine can read without FalconMail.

## Modules

```
App/FalconMail                SwiftUI app: windows, views, menus, notifications
Sources/FalconCore
  Net        StreamConnection  TLS byte stream with line and fixed-length reads
  IMAP       IMAPClient        Commands, tokenizer, parser, IDLE, UTF-7 names
  SMTP       SMTPClient        Submission with XOAUTH2
  MIME       MIMEParser        Headers, RFC 2047, multipart, transfer encodings
             MIMEBuilder       Outgoing messages with attachments
  Auth       GoogleOAuth       PKCE, loopback redirect, refresh
             KeychainStore     Token persistence
  Storage    FolderStore       One actor per folder: index snapshot, journal, bodies
             MailStore         Accounts, folders, change stream, unified inbox
  Sync       AccountSyncer     Incremental folder sync, IDLE, flag and delete sync
             SyncCoordinator   One syncer per account, event stream
  Threading  ConversationThreader
  Search     SpotlightIndexer  Core Spotlight indexing and queries
  Rules      RuleEngine        Conditions and actions applied on arrival
  Send       Outbox            Scheduled send and undo send
  Archive    ArchiveWriter/Reader, ZipChunkWriter, ArchiveCrypto, ArchiveIndex
  Drive      GoogleDriveStorage  Resumable uploads, range reads
  Import     MboxReader, EMLImporter
  Contacts   GooglePeopleClient
  Calendar   GoogleCalendarClient (events, Google Meet links)
  Diagnostics DiagnosticsCenter  Redaction, on-disk queue, uploads (docs/DIAGNOSTICS.md)
```

## Data flow

```
IMAP server ──► AccountSyncer ──► MIMEParser ──► FolderStore (one per folder) ──► files ──► AppModel ──► views
                    │                                   │
                    │ IDLE                              └──► SpotlightIndexer
                    ▼
              SyncEvent stream ──► notifications, badge, rules
```

Sync per folder:

1. `SELECT`, compare `UIDVALIDITY`. If it changed, drop the folder cache.
2. `UID FETCH (lastSyncedUID+1):*` headers, parse, insert, run rules.
3. `UID FETCH <window> (FLAGS)`, apply flag changes and remove expunged UIDs.
4. Bodies are fetched on demand and, for the most recent messages, in the
   background so the app works offline.
5. `INBOX` stays in `IDLE` and re-syncs on any event.

## Local cache

```
~/Library/Application Support/FalconMail/
  accounts.json
  rules.json
  archives.json
  Outbox/<id>.json + <id>.eml
  Contacts/<accountID>.json
  Accounts/<accountID>/
    folders.json
    Folders/<folderID>/
      index.plist        binary property list snapshot of all message summaries
      journal.jsonl      append-only operations since the last snapshot
      Bodies/<uid>.eml   raw messages for offline reading
```

`FolderStore` loads the snapshot and replays the journal at startup, keeps the
summaries in memory, appends every change to the journal, and rewrites the
snapshot after 2000 operations or on quit. A folder with 100 000 headers costs
roughly 30 MB of memory and loads in well under a second. Writes to different
folders never touch the same file, so syncing five accounts writes to five
directories at once.

`MailStore` owns the account and folder lists and publishes a change stream.
The app model listens and reloads only the folder that changed. Full-text
search of bodies goes through Core Spotlight, header search runs in memory.

## Archives and local space

`ArchiveWriter` accumulates one zip chunk in memory (default 256 MB) and streams
it to the cloud backend with resumable uploads in 8 MB pieces. Index shards are
built per chunk and uploaded when the chunk closes. Nothing is written under
`~/Library` or anywhere else on disk. Reading an archived message is a single
HTTP range request into the chunk, so opening a message from a 50 GB archive
costs the size of that message, not the size of the archive. See
`ARCHIVE_FORMAT.md`.

## Security

- OAuth tokens live in the Keychain, never in the database.
- The reading pane blocks remote content by default with a CSP and rewrites
  `cid:` images to data URLs.
- Archive encryption is AES-256-GCM per entry with a PBKDF2 derived key. The
  password is never stored; losing it means losing the archive.
- App sandbox and hardened runtime are on.

## Diagnostics

The contract with the backend is in `DIAGNOSTICS.md`. On the app's side:

| Piece | Where | What it does |
| --- | --- | --- |
| `DiagnosticsCenter` | `FalconCore/Diagnostics` | Collects, redacts, queues and uploads, on a queue of its own so no caller waits |
| `DiagnosticsRedactor` | `FalconCore/Diagnostics` | The redaction rules, tested against a corpus of awkward inputs |
| `DiagnosticsSignature`, `DiagnosticsTitle` | `FalconCore/Diagnostics` | Grouping keys and plain-language titles |
| `DiagnosticsQueue` | `FalconCore/Diagnostics` | `Diagnostics/queue.jsonl` in Application Support: 1 MB at most, repeats within an hour folded into a count |
| `DiagnosticsUploader` | `FalconCore/Diagnostics` | Batches of at most 200 events and 256 KB over a session that keeps nothing |
| `CrashReports`, `MetricKitDiagnostics` | `FalconCore/Diagnostics` | The app's own `.ips` crash reports and MetricKit payloads, made into events |
| `DiagnosticsService` | `App/FalconMail/Services` | Reads the Info.plist and the Settings switch, subscribes to MetricKit, counts for the health report |
| `DiagnosticsPrivacySection` | `App/FalconMail/Views` | The switch, the diagnostics ID and the data waiting, in Settings → Privacy |

What becomes an event:

- Every `Log.warning` and `Log.error` line, never `Log.info`. Each error alert and banner
  the app shows is one, under the area `Alert`.
- Crashes, from the app's own reports in `~/Library/Logs/DiagnosticReports` at launch and
  from MetricKit, which also reports hangs, heavy CPU use and heavy disk writes. A crash
  both report is sent once, from the `.ips` report, which says more. A build run from
  Xcode's build folder is never reported.
- A `launch` event at each start, saying whether the last session quit normally, and a
  `health` event once a day.

When it is sent: a minute after launch, then hourly; within a minute of a crash or hang;
after a failure, two minutes later, doubling with jitter up to six hours; when offline,
again in ten minutes. An event leaves the queue only once the server has confirmed it.

Who sends: only a Release build with the bundle identifier `com.falconmail.app`, an
endpoint and key in its Info.plist (the release workflow fills them from the
`FALCON_DIAGNOSTICS_URL` and `FALCON_DIAGNOSTICS_KEY` secrets), and the switch on.
Switching it off deletes the queue, and switching it back on leaves out whatever happened
while it was off. The release workflow keeps each build's dSYM in
`~/Library/Application Support/FalconMail Symbols/<version>/<build>/` on the runner,
where the daily triage symbolicates crashes; dSYMs are never uploaded.

## Gmail specifics

- `[Gmail]/All Mail` is skipped during sync to avoid duplicates. It is offered
  as the source when archiving a whole account.
- Folder roles come from RFC 6154 special-use attributes.
- Google Drive access uses the `drive.file` scope, which only sees files the
  app created and does not require Google's restricted-scope review.

## Why not SQLite, Core Data or SwiftData

Core Data and SwiftData are both SQLite underneath, so they were ruled out with
it. The file store above gives parallel writes per folder, instant startup from
a binary snapshot, and human-readable journals for debugging. The trade-off is
memory proportional to the number of cached headers, which the per-folder sync
window keeps bounded.

## Localization

UI strings are SwiftUI string literals, which are localization keys by
default. `App/FalconMail/Resources/Localizable.xcstrings` is the string
catalog with the translations (Russian, Turkish, Azerbaijani and German so
far). macOS picks the language from System Settings; untranslated strings fall
back to English. Xcode adds new keys to the catalog on each build; translators
edit the catalog in Xcode or as JSON.

## App icon

`scripts/render_icon.py` draws the icon (macOS squircle, glass envelope) with
Pillow and writes every size into `App/FalconMail/Assets.xcassets`. It also
renders the DMG background. Re-run it after changing the design; the PNGs are
committed so Xcode and CI never need Python.
