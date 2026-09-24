# FalconMail diagnostics

## In plain words

- **What happens.** When something goes wrong in FalconMail (an error, a crash, the app
  stopping to respond), it sends a short report to the FalconMail team, without asking.
  Once a day it also sends a health report: how many accounts and messages it keeps,
  how much disk it uses, how many errors it met.
- **Where it goes.** To a Google Sheet in a Drive folder owned by a freightmasters.llc
  Google Workspace account and shared with the whole freightmasters.llc domain, so
  problems are found and fixed every day.
- **What is never sent.** Messages, subjects, contacts, e-mail addresses, the names of
  your own folders, attachment names and passwords. Addresses and folder names become
  short codes that cannot be turned back.
- **How to switch it off.** Settings → Privacy → untick *Send diagnostic data to the
  FalconMail team*. Anything still waiting is deleted at once. *Show Data Waiting to Be
  Sent…* shows exactly what would go.

The rest of this page is the contract between the app and the backend. Both sides
implement exactly this.

## The contract

### Upload

- HTTPS `POST` to `<FalconDiagnosticsURL>` (an Apps Script `/exec` URL).
- The body is UTF-8 JSON, sent with `Content-Type: text/plain;charset=utf-8`, which Apps
  Script accepts without preflight concerns. At most 256 KB.
- Follow Apps Script's 302 redirect. The POST runs before the redirect.
- Success is a final 2xx with JSON `{"ok":true,"accepted":n,"duplicates":m}`. Otherwise
  the answer is `{"ok":false,"error":"..."}`.

### Body

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

At most 200 events per body.

### Event

| Field | What it holds |
| --- | --- |
| `id` | UUID, unique per event, used for server-side dedupe |
| `kind` | `error`, `warning`, `crash`, `hang`, `cpu`, `diskwrite`, `health` or `launch` |
| `signature` | Stable grouping key with no dynamic values: area + error type/code + source location, for example `IMAP.throttled@AccountSyncer.swift:131` |
| `title` | Short plain-language description a non-programmer understands, stable for the signature, at most 120 characters, for example *Gmail paused the connection: too many requests*, *FalconMail crashed while opening a message*, *Sending a message failed: the server refused the password* |
| `area` | The log area |
| `count` | Number of occurrences folded into this event |
| `firstAt`, `lastAt` | ISO 8601 |
| `message` | Redacted text, at most 2,000 characters |
| `context` | Redacted JSON object, at most 16 KB serialised |
| `account` | The account object below, or `null` |

The `account` object:

| Field | What it holds |
| --- | --- |
| `provider` | `google`, `imap`, `exchange`, … |
| `kind` | `gmail`, `workspace` or `other` |
| `host` | The IMAP host, for example `mail.your-server.de`, or empty |
| `ref` | 8 hex characters of HMAC-SHA256(install salt, lower-cased address), so events of one account correlate within one install; never reversible |

### Read (for the owner's tooling only)

- `GET <url>?op=read&key=<READ key>&since=<ISO>&limit=<n ≤ 5000>` returns
  `{"ok":true,"rows":[{"receivedAt":"ISO","install":..,"title":..,"version":..,"os":..,"hw":..,"kind":..,"signature":..,"area":..,"count":..,"firstAt":..,"lastAt":..,"message":..,"context":<JSON string>,"account":<JSON string>,"eventId":..}],"next":"<ISO or null>"}`.
- `GET ?op=issues&key=<READ key>` returns the Issues tab as JSON.
- `GET ?op=ping` returns `{"ok":true}`.

### Redaction rules

Applied by the app before anything is queued.

| What | Becomes |
| --- | --- |
| E-mail addresses | `<addr:ref>` |
| Message subjects, bodies, snippets, attachment names, contact names | Never included |
| Folder and label names that are not standard special-use names (Inbox, Sent, Drafts, Trash, Junk/Spam, Archive, All Mail, Starred, Important) | Never included; user labels become `<label:ref>` |
| IMAP literals, and quoted strings after `FETCH`, `SEARCH` and `APPEND` commands | Stripped |
| OAuth tokens, Bearer, XOAUTH2, AUTHENTICATE and LOGIN arguments, passwords, `GOCSPX-` strings, URLs' query strings | Stripped |
| The user's home path | `~` |
| IP addresses | Kept only for servers (host names) |
| Numbers | Kept in `message`, normalised out of `signature` |
