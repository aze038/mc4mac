# FalconMail diagnostics

What FalconMail reports about its own problems, where the reports go and how they are kept
free of anything personal. The first section is for everyone; the rest is the exact contract
between the app and the backend that files the reports, which both sides implement.

## In plain words

- **What is sent.** When something goes wrong in FalconMail (an error, a crash, the app
  stopping to respond, or using far too much processor time or disk), it sends a short report
  to the FalconMail team, without asking. Once a day it also sends a health report: how many
  accounts, folders and messages it keeps, how much disk it uses, and how many syncs, errors
  and warnings it had.
- **When.** A minute after FalconMail starts, then every hour; within a minute of a crash or
  a hang. Reports wait on the Mac until the team's service confirms it has them.
- **Where it goes.** To a Google Sheets spreadsheet in a Drive folder owned by a
  freightmasters.llc Google Workspace account and shared with everyone at freightmasters.llc,
  so problems are found and fixed every day.
- **What is never sent.** Messages, subjects, contacts, e-mail addresses, the names of your
  own folders, attachment names and passwords. Addresses and folder names become short codes
  that cannot be turned back.
- **Which copies send.** Only a release build of FalconMail. A build made from the source code
  never sends anything.
- **How to switch it off.** Settings → Privacy → untick *Send diagnostic data to the FalconMail
  team*. Anything still waiting is deleted at once. *Show Data Waiting to Be Sent…* shows
  exactly what would go.

## Where things are

| Piece | Where |
| --- | --- |
| The app's side | `Sources/FalconCore/Diagnostics`, described in `docs/ARCHITECTURE.md` |
| The backend | `tools/diagnostics/apps-script/Code.gs`, described in `tools/diagnostics/README.md` |
| The owner's tools | `tools/diagnostics/fetch-reports.sh` and `symbolicate.py`, in the same README |
| Setting it up | `docs/DIAGNOSTICS_SETUP.md` |
| The daily triage | `docs/DAILY_TRIAGE.md` |

## The contract

Both sides implement exactly this. Either side may add a field to what it sends; the other
ignores any field it does not know.

### Upload

- HTTPS `POST` to `<FalconDiagnosticsURL>`, an Apps Script `/exec` URL.
- The body is UTF-8 JSON, sent as `Content-Type: text/plain;charset=utf-8`, which Apps Script
  accepts without a preflight. At most 256 KB, counted in UTF-8 bytes, and at most 200 events.
- Follow Apps Script's 302 redirect. The upload is filed before the redirect is answered.

### The answer

| Answer | Meaning | What the app does |
| --- | --- | --- |
| Final 2xx with `{"ok":true,"accepted":n,"duplicates":m}` | `n` events filed, `m` already filed earlier under the same IDs | Takes the whole batch out of its queue |
| The same with `"invalid":k` added | `k` events could not be filed (no usable `id`, `kind` or `signature`) and never will be | The same: they are not sent again |
| `{"ok":false,"error":"..."}`, or anything else | Refused or failed; nothing was filed | Keeps the events and tries again: 2 minutes later, doubling with jitter up to 6 hours, or in 10 minutes when offline |

### Body

```json
{
  "schema": 1,
  "key": "<FalconDiagnosticsKey ingest key>",
  "install": "<random UUID made once per install>",
  "app": { "version": "1.10.0", "build": "123", "channel": "release" },
  "os": "macOS 26.6 (25G5023)",
  "hw": "MacBookPro18,3",
  "locale": "en_GB",
  "sentAt": "<ISO 8601, UTC>",
  "events": [EVENT, ...]
}
```

One body carries the events of one build and one macOS version, so an event queued before an
update still goes out under the version it happened in.

### Event

| Field | What it holds |
| --- | --- |
| `id` | A UUID, unique per event. A resend carries the same one, so the backend files it once |
| `kind` | `error`, `warning`, `crash`, `hang`, `cpu`, `diskwrite`, `health` or `launch`. Health and launch reports only say an install is alive; they are never counted as problems |
| `signature` | A stable grouping key; see below |
| `title` | A short plain-language description anyone understands, the same for every event of one signature, at most 120 characters. For example *The mail server paused the connection: too many requests*, *FalconMail crashed: it used memory it should not have*, *Sending a message failed: the server refused the password* |
| `area` | The part of the app it came from, such as `IMAP`, `Sync` or `crash` |
| `count` | How many times it happened, from 1 to 10,000. Repeats within an hour are folded into one event, and the app starts a new event once one reaches 10,000 |
| `firstAt`, `lastAt` | ISO 8601, UTC |
| `message` | Redacted text, at most 2,000 characters |
| `context` | A redacted JSON object, at most 16 KB serialised |
| `account` | The account object below, or `null` |

The `account` object:

| Field | What it holds |
| --- | --- |
| `provider` | `google`, `imap`, `exchange`, … |
| `kind` | `gmail`, `workspace` or `other` |
| `host` | The IMAP host, for example `mail.your-server.de`, or empty |
| `ref` | 8 hex characters of HMAC-SHA256 of the lower-cased address under a salt that never leaves the Mac, so one account's events can be matched within one install and never traced back |

### Signatures

A signature names where and how something failed, never with what, so the same failure reads the
same on every Mac and every run. It never holds a number, a name or any other value that changes:
its area, code and function are cut down to letters, dots, dashes and underscores.

| Event | Form | Example |
| --- | --- | --- |
| A logged error or warning | `Area.code@File.swift:function` | `IMAP.throttled@AccountSyncer.swift:loop` |
| A crash, hang, CPU or disk-write report | `Area.code@Binary` | `Crash.EXC_BAD_ACCESS.SIGSEGV@FalconMail`, `Hang.mainThread@AppKit` |
| A health or launch report | `Area.code@FalconMail` | `Health.daily@FalconMail`, `Launch.unclean@FalconMail` |

A logged failure is placed by its file and function, not its line: lines move whenever code
above them changes, nearly every release and above all in the one that fixes the failure, which
would make a fixed problem look new and lose the team's notes on it. A crash is placed by the
first binary in the crashed thread that is not the system's crash machinery; its function is
known only once the stack is symbolicated.

### Crash stacks

A crash report macOS writes runs to 50–200 KB, so the app sends a crash's `context` cut to what
the triage needs, always valid JSON and never over the 16 KB limit (it aims 1 KB below it):

- **From a macOS crash report** (`"source": "ips"`, shaped as an `.ips`): the `exception`
  (type, codes, signal), its reason (`asi`), `termination`, `faultingThread`, the crashed
  thread alone in `threads` (with its number in the report as `index`), the uncaught
  exception's `lastExceptionBacktrace` when there is one, and in `usedImages` only the images
  those frames use, each with `uuid`, `name`, `base` (load address) and `arch`, renumbered in
  the order the frames use them.
- **From MetricKit** (`"source": "metrickit"`): the `callStackTree` with the thread MetricKit
  blames (the crashed thread, or the main thread of a hang) first, and the
  `diagnosticMetaData`.

When that is still too large, what matters least goes first until it fits:

- In an `.ips`: frames in other binaries below the top eight, from the bottom of the stack up;
  then FalconMail's own frames below the top eight; then the top eight. At each step the crashed
  thread's frames go before the backtrace's, which shows where the exception was raised.
- In a MetricKit tree: the other threads, from the last; then all but the busiest branch of the
  blamed thread; then its deepest frames, a level at a time.

Whatever was left out is counted where it was, as `{"omitted": n}` in a list of frames,
`"subFramesOmitted": n` on a frame, `"framesOmitted": n` on a thread or `"callStacksOmitted": n`
on the tree, and the context says `"trimmed": true`. When macOS and MetricKit both report the
same crash, it is sent once, from the `.ips` report, which says more.

### Backend limits

The ingest key ships inside every release, so the backend protects itself and the spreadsheets
from a misbehaving build or a replayed key. What happens past each limit:

| Limit | Value | Past it |
| --- | --- | --- |
| Upload size | 256 KB, counted in UTF-8 bytes | Refused |
| Events in one upload | 200 | Refused |
| Uploads from one install | 60 an hour | Refused until the next hour |
| Events from one install | 1,000 a day, Baku time | Refused until the next day |
| Events from everyone | 5,000 and 10 million characters a day | Refused until the next day |
| `count` | 10,000 | Stored as 10,000 |
| `title` | 120 characters | Cut, ending in "…"; an empty title is stored as the signature |
| `signature` | 300 characters | Cut |
| `message` | 2,000 characters | Cut |
| `context` | 16 KB of JSON text | Stored as `{"truncated":true,"size":n,"start":"..."}`, still JSON, which loses the stack |
| `area`, `hw` | 60 characters | Cut |
| `app.version`, `app.build` | 30 characters | Cut |
| `os`, each account field | 100 characters | Cut |
| Event IDs | Remembered for 6 hours | A repeat is counted in `duplicates`, not filed |

Report text is untrusted, so the backend also removes control characters, makes web addresses
and e-mail addresses unclickable and never lets Sheets run text as a formula; the details are in
`tools/diagnostics/README.md`.

### Reading (the owner's tooling only)

Every read needs the read key, which is not the ingest key. A wrong key gets
`{"ok":false,"error":"Not accepted"}` and nothing else.

- `GET <url>?op=read&key=<read key>&since=<ISO>&limit=<n>` answers
  `{"ok":true,"rows":[ROW, ...],"next":"<ISO or null>"}`, oldest first. `since` is exclusive:
  pass the `next` of the previous page. `limit` defaults to 1,000 and is capped at 5,000; a
  page keeps the rows of one upload together, so it can run up to 199 rows past `limit`, and
  stops at about 4 MB. `next` is `null` on the last page.
- `GET <url>?op=issues&key=<read key>` answers `{"ok":true,"updatedAt":"ISO","issues":[...]}`,
  the Issues tab, each issue with `title`, `kind`, `times`, `installs`, `testers`,
  `versions`, `firstSeen`, `lastSeen`, `status`, `notes`, `example`, `area` and `signature`.
- `GET <url>?op=ping` answers `{"ok":true}`, with no key.

Each ROW holds:

| Field | What it holds |
| --- | --- |
| `receivedAt` | When the backend filed it, ISO 8601 |
| `install` | The install's UUID |
| `version`, `build` | The app's version and build, from the upload's `app` |
| `os`, `hw` | From the upload |
| `eventId` | The event's `id` |
| `kind`, `signature`, `title`, `area`, `count`, `firstAt`, `lastAt`, `message` | The event's fields, as stored |
| `context`, `account` | JSON text, `"null"` when the event had none |

## Redaction rules

FalconMail applies these on the Mac, before an event is queued, so nothing unredacted is ever
written to its queue or sent. Each rule is tested in `DiagnosticsRedactorTests`.

| What | Becomes |
| --- | --- |
| E-mail addresses, in any script, quoted or in angle brackets | `<addr:ref>`, the same 8-character reference as an account's `ref` |
| A name written beside an address: quoted, before it, surname first, or in brackets after it | Removed; the rest of the sentence stays |
| Message subjects, bodies, snippets, attachment names and contact names | Never included. A `Subject:` or similar header line becomes `Subject: <text>`, an encoded word `<text>` |
| Folder and label names | Standard ones stay: Inbox, Sent, Drafts, Trash, Junk or Spam, Archive, All Mail, Starred, Important, with or without `[Gmail]/` or `INBOX.`. Any other becomes `<label:ref>`: in IMAP commands and Gmail labels, wherever one of the account's own folder names stands as a word, and, for a short name such as HR or 2024, wherever a server or FalconMail names a folder |
| IMAP literals, and quoted strings and search terms after `FETCH`, `SEARCH` and `APPEND` | `{n}<literal>` and `"…"` |
| Text between quotation marks | Between double quotes, kept only when it reads like a code, such as `"invalid_grant"`. Between any language's typographic marks (“…”, „…“, «…», 「…」, ״…״ and the rest) always `…`. Between single quotes, kept when it reads like code, such as `'NSInvalidArgumentException'` or `'try!'`, otherwise `'…'` |
| An uncaught exception's name and reason in a crash report | Kept between their single quotes, as the runtime writes them, with every other rule still applied inside them |
| OAuth tokens, `Bearer` and `Basic` credentials, XOAUTH2 strings, `AUTHENTICATE` and `LOGIN` arguments, passwords, client secrets (`GOCSPX-…`, `AIza…`), GitHub tokens, `Authorization` headers and long base64 blobs | `<token>`, `<secret>`, `<redacted>` or `<base64>` |
| Web addresses | Their query string, fragment and any `user:password@` removed; an HTTP request line loses its query |
| The home folder's path, and any other `/Users/<name>` | `~` |
| IP addresses | `<ip>`, except those of the configured servers |
| Numbers | Kept in `message`, never in `signature` |
| Identifiers of the Mac or its user in a crash report (crash reporter key, boot and sleep IDs, user ID, file paths) | Never included |
