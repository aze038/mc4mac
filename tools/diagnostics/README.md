# FalconMail diagnostics: backend and tools

FalconMail sends redacted problem reports on its own (see `docs/DIAGNOSTICS.md` for the contract).
They land in Google Sheets that everyone at freightmasters.llc can open, one spreadsheet a month,
and a daily Claude session triages them (`docs/DAILY_TRIAGE.md`).

| Piece | What it is |
|---|---|
| `apps-script/` | The Google Apps Script web app that receives the reports and keeps the spreadsheets tidy. |
| `docs/DIAGNOSTICS_SETUP.md` | The owner's one-time steps to put it live. |

## What the team sees

Each month has a spreadsheet named `FalconMail Diagnostics 2026-09` in the Drive folder
`FalconMail Diagnostics`. It opens on the first of four tabs:

1. **Overview**: the last 24 hours, the last 7 days day by day, the ten most frequent open
   problems, any problem that came back after it was marked fixed, and the versions in use.
2. **Issues**: one row per problem, the plain-language title first. The team fills in **Status**
   (New, Investigating, Fixed in …, Won't fix) and **Notes**; both are kept when the tab is
   rebuilt every hour, and carried into next month's spreadsheet. Fixed problems are greyed out
   and sink below open ones.
3. **Installs**: one row per Mac. The team types a **Tester name** against each Diagnostics ID
   (shown in FalconMail under Settings → Privacy); names then appear on Issues and Overview.
4. **Events**: every report as it arrived, for detail. Technical columns are on the right.

Dates are Baku time. Crashes are red, hangs and CPU or disk-write problems orange, errors amber and
warnings yellow. Health and launch reports only show that an install is alive: they feed Installs
and never count as problems.

With the default `SHARE_PERMISSION` of `VIEW`, only the owner can type Status, Notes and tester
names. Change it at the top of `Code.gs` to `DriveApp.Permission.EDIT` (or `COMMENT`) and run
`setup()` again to let the team do it too.

## How the web app behaves

- **Upload** (`POST`): checks the ingest key, schema 1, at most 256 KB (counted in UTF-8 bytes)
  and at most 200 events, then appends all new events in one write under a script lock. Answers
  `{"ok":true,"accepted":n,"duplicates":m}`, plus `"invalid":k` when some events could not be
  filed (no usable `id`, `kind` or `signature`); those are dropped, so the app should not resend
  them. Every refusal is `{"ok":false,"error":"..."}` and the app keeps its events for later.
- **Duplicates**: event IDs are remembered for 6 hours, so a batch resent after a lost response is
  not filed twice. The hourly rebuild also counts each event ID once, in case the cache forgot.
- **Limits**: 60 uploads an hour per install and 5,000 events a day in all. The ingest key ships
  inside every public release, so the daily cap is what protects the quotas and the spreadsheet.
- **Formula safety**: text that starts with `=`, `+`, `-`, `@`, a tab or a carriage return is
  stored as plain text, never as a formula. Treat the text in the sheet as untrusted all the
  same: do not follow links in it.
- **Trimming**: titles to 120 characters, messages to 2,000, context to 16 KB, and every cell under
  Sheets' 50,000-character limit. Only `provider`, `kind`, `host` and `ref` of an account are kept.
- **Months**: a new spreadsheet starts at midnight Baku time on the 1st (the nightly trigger or the
  first upload, whichever comes first), and the old month's Overview points to it. A month that
  would pass 40 million characters carries on in `... part 2`, well before Sheets' 100 MB limit.
- **Retention**: 90 days after a month ends, its spreadsheets go to the Drive trash (restorable
  for 30 days). Only files in this folder named like `FalconMail Diagnostics YYYY-MM` are touched.
- **Triggers**: `rebuildIssues` every hour; `dailyMaintenance` at about 00:15 Baku time.

### Reading, for the owner's tooling

`op=read` pages through every month oldest first. Rows carry the contract's fields plus `build`.
`since` is exclusive: pass the `next` of the previous page, or the `receivedAt` of the last row
kept. Rows that arrived in one upload share a `receivedAt` and are never split across pages, so a
page can hold up to 199 rows more than `limit`; a page also stops at about 4 MB. `next` is `null`
on the last page. `limit` defaults to 1,000 and is capped at 5,000.

`op=issues` answers `{"ok":true,"updatedAt":"ISO","issues":[...]}`, each issue with `title`,
`kind`, `times`, `installs`, `testers`, `versions`, `firstSeen`, `lastSeen`, `status`, `notes`,
`example`, `area` and `signature`. A wrong key gets `{"ok":false,"error":"Not accepted"}` and
nothing else.

## Quotas this is designed around

From Google's [Apps Script quotas](https://developers.google.com/apps-script/guides/services/quotas)
(page dated 3 September 2026), the [CacheService reference](https://developers.google.com/apps-script/reference/cache/cache)
(13 April 2026) and [Drive's file limits](https://support.google.com/drive/answer/37603), checked on
24 September 2026. The account is a Google Workspace one.

| Limit | Value | How the design stays inside it |
|---|---|---|
| Script runtime | 6 min per execution | An upload takes a second or two; the hourly rebuild reads two months of events once. |
| Simultaneous executions | 30 per user, 1,000 per script | Uploads run as the owner and hold the lock for a second or two; ~20 installs are far from 30 at once. |
| Trigger runtime | 6 h a day (Workspace) | 24 rebuilds and one nightly run a day. |
| Triggers | 20 per user per script | 2. |
| Properties reads and writes | 500,000 a day (Workspace) | Under ten per upload: even 60 uploads an hour from 20 installs stay under 300,000. |
| Property value / store | 9 KB per value, 500 KB per store | Keys, IDs and one counter per day. |
| Spreadsheets created | 3,200 a day (Workspace) | One or two a month. |
| Cache | 100 KB per value, 250-character keys, 6 h at most, 1,000 entries | Event IDs are kept in 16 entries, not one each; one rate counter per install. |
| Spreadsheet size | 20 million cells or 100 MB | 5,000 events a day at most, and a new part at 40 million characters. |
| Cell | 50,000 characters | Cells are cut at 49,000. |

Web apps have no documented request-size or response-size limit; the contract's 256 KB upload and
the 4 MB read page keep well clear of trouble. Apps Script answers with a 302 redirect to
`script.googleusercontent.com`, so clients must follow redirects.

## Tests

All run offline; nothing talks to Google or any server.

```sh
node --test tools/diagnostics/apps-script/test/
```

The Node tests load `Code.gs` in a sandbox with in-memory stand-ins for SpreadsheetApp, DriveApp,
PropertiesService, CacheService, LockService, ContentService, Session, Utilities and ScriptApp
(`apps-script/test/harness.js`).
