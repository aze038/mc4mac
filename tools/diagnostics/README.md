# FalconMail diagnostics: backend and tools

FalconMail sends redacted problem reports on its own (see `docs/DIAGNOSTICS.md` for the contract).
They land in Google Sheets that everyone at freightmasters.llc can open, one spreadsheet a month,
and a daily Claude session triages them (`docs/DAILY_TRIAGE.md`).

| Piece | What it is |
|---|---|
| `apps-script/` | The Google Apps Script web app that receives the reports and keeps the spreadsheets tidy. |
| `fetch-reports.sh` | Pulls new reports to `~/FalconMailReports/` and prints them grouped by problem. |
| `symbolicate.py` | Turns the stack in a crash or hang report into function names and source lines. |
| `docs/DIAGNOSTICS_SETUP.md` | The owner's one-time steps to put it live. |

## What the team sees

Each month has a spreadsheet named `FalconMail Diagnostics 2026-09` in the Drive folder
`FalconMail Diagnostics`. It opens on the first of four tabs:

1. **Overview**: the day in a sentence at the top, then the last 24 hours, the last 7 days day by
   day, the ten most frequent open problems of the last 7 days (with when each was first and last
   seen), any problem that came back after it was marked fixed, and the versions in use. Labels
   and titles sit in a narrow first column with their figures beside them, so it reads on a phone.
2. **Issues**: one row per problem, the plain-language title first. The team fills in **Status**
   (New, Investigating, Fixed in *version*, Won't fix) and **Notes**; both are kept when the tab
   is rebuilt every hour, and carried into next month's spreadsheet. A problem counts as fixed
   only once a version follows "Fixed in". Fixed problems are greyed out and sink below open ones;
   one seen again in or after the version it was fixed in goes back among the open ones, its
   Versions marked "(after the fix)".
3. **Installs**: one row per Mac. The team types a **Tester name** against each Diagnostics ID
   (shown in FalconMail under Settings → Privacy); names then appear on Issues and Overview.
4. **Events**: every report as it arrived, newest at the bottom. Its filter starts with health and
   launch reports hidden; clear it to see them. Technical columns are on the right.

Dates are Baku time. Crashes are red, hangs and CPU or disk-write problems orange, errors amber and
warnings yellow. Health and launch reports only show that an install is alive: they feed Installs
and never count as problems.

The heading rows warn before anyone changes them. A column moved anyway is put back, with its
data, at the next hourly rebuild; to make room, hide columns instead. When a month ends, the old
spreadsheet's Issues and Installs tabs turn red and warn anyone typing there, as Status, Notes and
tester names are read from the newest spreadsheet.

With the default `SHARE_PERMISSION` of `VIEW`, only the owner can type Status, Notes and tester
names. Change it at the top of `Code.gs` to `DriveApp.Permission.EDIT` (or `COMMENT`) and run
`setup()` again to let the team do it too. Editors can never share the reports further.

## How the web app behaves

- **Upload** (`POST`): checks the ingest key, schema 1, at most 256 KB (counted in UTF-8 bytes)
  and at most 200 events, then appends all new events in one write under a script lock. Answers
  `{"ok":true,"accepted":n,"duplicates":m}`, plus `"invalid":k` when some events could not be
  filed (no usable `id`, `kind` or `signature`); those are dropped, so the app should not resend
  them. Every refusal is `{"ok":false,"error":"..."}` and the app keeps its events for later.
- **Duplicates**: event IDs are remembered for 6 hours, so a batch resent after a lost response is
  not filed twice. The hourly rebuild also counts each event ID once, in case the cache forgot.
- **Limits**: the ingest key ships inside every public release, so these protect the quotas and
  the spreadsheets from a misbehaving build or a replayed key:
  - 60 uploads an hour per install, checked before waiting for the lock;
  - 1,000 events a day per install, counted exactly under the lock, so no one install uses up
    the day;
  - 5,000 events and 10 million characters a day in all;
  - at most 10,000 occurrences folded into one event.
- **Text safety**: report text is untrusted, and the Overview says so.
  - Text that starts with `=`, `+`, `-`, `@`, `'`, a tab or a carriage return is stored as plain
    text, never as a formula, and comes back exactly as sent.
  - Control characters are removed (tabs and line breaks in messages stay), so nothing in a
    report can act on the owner's terminal.
  - Web addresses in titles and messages are stored readable but not clickable, as
    `https[:]//example[.]com`.
- **Trimming**: titles to 120 characters, messages to 2,000, context to 16 KB, and every cell under
  Sheets' 50,000-character limit. Context too large to keep whole is stored as
  `{"truncated":true,"size":n,"start":"..."}`, so it is always JSON. Only `provider`, `kind`,
  `host` and `ref` of an account are kept.
- **Months**: a new spreadsheet starts at midnight Baku time on the 1st (the nightly trigger or the
  first upload, whichever comes first), and the old month's Overview points to it. A month that
  would pass 40 million characters carries on in `... part 2`, well before Sheets' 100 MB limit.
- **Retention**: 90 days after a month ends, its spreadsheets go to the Drive trash (restorable
  for 30 days). Only files in this folder named like `FalconMail Diagnostics YYYY-MM` and owned by
  the folder's owner are touched; a file that cannot be trashed is logged and skipped.
- **Triggers**: `rebuildIssues` every hour; `dailyMaintenance` at about 00:15 Baku time. The
  rebuild reads this month's and last month's spreadsheets, at most the newest three, and the
  Overview says when it left older ones out.

### Reading, for the owner's tooling

`op=read` pages through every month oldest first. Rows carry the contract's fields plus `build`.
`since` is exclusive: pass the `next` of the previous page, or the newest `receivedAt` kept. Rows
are chosen by their `receivedAt`, not by where they sit on the tab, so sorting Events in Sheets
does not upset paging. Rows that arrived in one upload share a `receivedAt` and are never split
across pages, so a page can hold up to 199 rows more than `limit`; a page also stops at about
4 MB. `next` is `null` on the last page. `limit` defaults to 1,000 and is capped at 5,000.
`account` and `context` are JSON text, `"null"` when the event had none.

`op=issues` answers `{"ok":true,"updatedAt":"ISO","issues":[...]}`, each issue with `title`,
`kind`, `times`, `installs`, `testers`, `versions`, `firstSeen`, `lastSeen`, `status`, `notes`,
`example`, `area` and `signature`. A wrong key gets `{"ok":false,"error":"Not accepted"}` and
nothing else.

## The owner's tools

Both need only the Mac's own `python3`, and read the endpoint and read key from
`~/.config/falconmail/diagnostics.json` (see `docs/DIAGNOSTICS_SETUP.md`). They refuse to run if
that file can be read by anyone else.

```sh
tools/diagnostics/fetch-reports.sh              # what arrived since the last run
tools/diagnostics/fetch-reports.sh -v           # the same, with signatures, examples and event IDs
tools/diagnostics/fetch-reports.sh --days 7     # everything saved in the last week
tools/diagnostics/fetch-reports.sh --json       # the same summary as JSON, for the daily triage
tools/diagnostics/fetch-reports.sh --issues     # the Issues tab with the team's Status; read only
tools/diagnostics/symbolicate.py --event <ID>   # the stack of one crash or hang, with line numbers
```

`fetch-reports.sh` saves every new row to `~/FalconMailReports/YYYY-MM-DD.jsonl` and remembers
the newest one in `~/.config/falconmail/diagnostics.cursor`, so each run picks up exactly where
the last one ended. A row already saved is never saved or counted twice, and a next page that
would not move forward is refused rather than followed. It prints:

```
FalconMail diagnostics: 6 reports from 2 installs
Received 24 Sep 2026 07:00 to 24 Sep 2026 09:00, local time

Problems, newest first
  Problem                                           Kind          Times  Installs  Versions        Last seen     Trend
  ────────────────────────────────────────────────  ───────────  ──────  ────────  ──────────────  ────────────  ──────
  FalconMail stopped responding while showing a l…  Hang              1         1  1.10.0          24 Sep 08:59  New
  Gmail paused the connection: too many requests    Error             5         2  1.10.1, 1.10.0  24 Sep 08:40  Rising
```

**Trend** compares with the reports saved before: **New** was never seen, **Back** was seen but
not in the previous 7 days, and **Rising** happened at least 3 times and more than twice as often
as its daily average over the previous 7 days.

The table fits the terminal; in one narrower than about 100 columns each title gets a line of its
own above its figures. Neither tool prints a control character from a report.

`symbolicate.py` finds a MetricKit call-stack tree or an `.ips` report anywhere in a row's context
and looks up FalconMail's frames with `atos`, in the dSYM that the release build keeps at
`~/Library/Application Support/FalconMail Symbols/<version>/`, matched by UUID. Without symbols
for that build it says so and shows offsets. The version comes from the report, so only a plain
version number such as `1.10.0` is ever used as a folder name.

## Quotas this is designed around

From Google's [Apps Script quotas](https://developers.google.com/apps-script/guides/services/quotas)
(page dated 3 September 2026), the [CacheService reference](https://developers.google.com/apps-script/reference/cache/cache)
(13 April 2026) and [Drive's file limits](https://support.google.com/drive/answer/37603), checked on
24 September 2026. The account is a Google Workspace one.

| Limit | Value | How the design stays inside it |
|---|---|---|
| Script runtime | 6 min per execution | An upload takes a second or two; the hourly rebuild reads two months of events once, from three spreadsheets at most. |
| Simultaneous executions | 30 per user, 1,000 per script | Uploads run as the owner and hold the lock for a second or two; ~20 installs are far from 30 at once. |
| Trigger runtime | 6 h a day (Workspace) | 24 rebuilds and one nightly run a day. |
| Triggers | 20 per user per script | 2. |
| Properties reads and writes | 500,000 a day (Workspace) | About a dozen per upload: 60 uploads an hour from each of 20 installs, all day, would be about 350,000. |
| Property value / store | 9 KB per value, 500 KB per store | Keys, IDs and three counters for the day; the per-install counts share one value, kept under 8 KB. |
| Spreadsheets created | 3,200 a day (Workspace) | One or two a month. |
| Cache | 100 KB per value, 250-character keys, 6 h at most, 1,000 entries | Event IDs are kept in 16 entries, not one each; one rate counter per install. |
| Spreadsheet size | 20 million cells or 100 MB | 5,000 events and 10 million characters a day at most, and a new part at 40 million characters. |
| Cell | 50,000 characters | Cells are cut at 49,000. |

Web apps have no documented request-size or response-size limit; the contract's 256 KB upload and
the 4 MB read page keep well clear of trouble. Apps Script answers with a 302 redirect to
`script.googleusercontent.com`, so clients must follow redirects.

## Tests

All run offline; nothing talks to Google or any real server.

```sh
node --test tools/diagnostics/apps-script/test/
python3 -m unittest discover -s tools/diagnostics/test
```

The Node tests load `Code.gs` in a sandbox with in-memory stand-ins for SpreadsheetApp, DriveApp,
PropertiesService, CacheService, LockService, ContentService, Session, Utilities and ScriptApp
(`apps-script/test/harness.js`). The Python tests run `fetch-reports.sh` against a fake service on
127.0.0.1 that answers with Apps Script's redirect, and `symbolicate.py` against a small binary and
dSYM built on the spot with the Xcode command line tools.
