# FalconMail diagnostics: the contract

FalconMail sends redacted problem reports, automatically and without asking, to a Google Apps
Script web app that files them in Google Sheets shared with the freightmasters.llc domain. It can
be switched off in Settings → Privacy. Message content is never sent.

This page is the contract between the app and the backend. Both sides implement exactly this.

- App side: the diagnostics reporter in FalconMail.
- Backend: `tools/diagnostics/apps-script/Code.gs` (see `tools/diagnostics/README.md`).
- The owner's setup: `docs/DIAGNOSTICS_SETUP.md`. The daily triage: `docs/DAILY_TRIAGE.md`.

## Upload

- HTTPS `POST` to `<FalconDiagnosticsURL>`, an Apps Script `/exec` URL.
- Body: UTF-8 JSON, sent as `Content-Type: text/plain;charset=utf-8`, which Apps Script accepts
  without preflight concerns. At most 256 KB.
- Follow Apps Script's 302 redirect. The POST runs before the redirect.
- Success: the final response is 2xx with `{"ok":true,"accepted":n,"duplicates":m}`.
- Anything else: `{"ok":false,"error":"..."}`.

## Body

```json
{
  "schema": 1,
  "key": "<FalconDiagnosticsKey ingest key>",
  "install": "<random UUID made once per install>",
  "app": { "version": "1.10.0", "build": "123", "channel": "release" },
  "os": "macOS 26.6 (25G...)",
  "hw": "MacBookPro18,3",
  "locale": "en_US",
  "sentAt": "<ISO8601 UTC>",
  "events": [EVENT, ...]
}
```

At most 200 events per upload.

## Event

```json
{
  "id": "<UUID, unique per event, used for server-side dedupe>",
  "kind": "error" | "warning" | "crash" | "hang" | "cpu" | "diskwrite" | "health" | "launch",
  "signature": "<stable grouping key>",
  "title": "<short plain-language description>",
  "area": "<log area>",
  "count": <n occurrences folded into this event>,
  "firstAt": "ISO",
  "lastAt": "ISO",
  "message": "<redacted text, max 2,000 chars>",
  "context": { <redacted JSON, max 16 KB serialised> },
  "account": {
    "provider": "google" | "imap" | "exchange" | ...,
    "kind": "gmail" | "workspace" | "other",
    "host": "<IMAP host, e.g. mail.your-server.de, or empty>",
    "ref": "<8 hex chars>"
  } or null
}
```

- **signature**: a stable grouping key with no dynamic values: area + error type/code + source
  location, e.g. `IMAP.throttled@AccountSyncer.swift:131`.
- **title**: a short plain-language description a non-programmer understands, stable for the
  signature, at most 120 characters. For example:
  - Gmail paused the connection: too many requests
  - FalconMail crashed while opening a message
  - Sending a message failed: the server refused the password
- **account.ref**: HMAC-SHA256(install salt, lowercased address), 8 hex characters, so events of
  one account correlate within one install. Never reversible.

## Read (the owner's tooling only)

- `GET <url>?op=read&key=<READ key>&since=<ISO>&limit=<n<=5000>` →
  `{"ok":true,"rows":[ROW,...],"next":"<ISO or null>"}`, where each ROW is
  `{"receivedAt":"ISO","install":..,"title":..,"version":..,"os":..,"hw":..,"kind":..,"signature":..,"area":..,"count":..,"firstAt":..,"lastAt":..,"message":..,"context":<JSON string>,"account":<JSON string>,"eventId":..}`.
- `GET ?op=issues&key=<READ key>` → the Issues tab as JSON.
- `GET ?op=ping` → `{"ok":true}`.

## Redaction (app side, before anything is queued)

| What | Rule |
|---|---|
| E-mail addresses | Replaced by `<addr:ref>` |
| Message subjects, bodies, snippets, attachment names, contact names | Never included |
| Folder and label names | Only standard special-use names are kept: Inbox, Sent, Drafts, Trash, Junk/Spam, Archive, All Mail, Starred, Important. User labels become `<label:ref>` |
| IMAP literals and quoted strings after FETCH/SEARCH/APPEND commands | Stripped |
| OAuth tokens; Bearer, XOAUTH2, AUTHENTICATE and LOGIN arguments; passwords; `GOCSPX-` strings; URLs' query strings | Stripped |
| The user's home path | Replaced by `~` |
| IP addresses | Kept only for servers (host names) |
| Numbers | Kept in `message`, normalised out of `signature` |
