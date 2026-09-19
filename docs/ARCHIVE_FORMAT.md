# FalconMail archive format (`.fmarchive`)

Version 1. Goals: readable on Windows and macOS without FalconMail, random
access to a single message over HTTP without downloading the archive, streaming
creation with bounded memory and no local disk, optional encryption.

## Structure

An archive is a folder named `<name>.fmarchive` in the storage backend
(Google Drive, OneDrive, Nextcloud, or a local folder for exports).

```
Work 2019-2023.fmarchive/
  manifest.json
  index/
    messages-00001.jsonl        one JSON object per message
    terms-00001.json            inverted index of words for full-text search
    messages-00002.jsonl
    terms-00002.json
  chunks/
    chunk-00001.zip             ordinary zip, "stored" entries, one .eml per message
    chunk-00002.zip
```

A person on Windows opens `chunks/chunk-00001.zip` in Explorer and
double-clicks any `.eml` to open it in Outlook or Windows Mail. No tools needed.

## Chunks

- Standard zip, no compression (method 0), no zip64. A chunk holds at most
  60 000 entries and at most 1 GB, so it always fits classic zip limits.
- Entry names are `<folder path with / separators>/<uid>-<short id>.eml`.
- Each entry is the message exactly as received from IMAP (RFC 5322, CRLF).
- Because entries are stored, not compressed, a message can be read with one
  range request: `offset` and `length` from the index point at the entry data.

## Index

`messages-NNNNN.jsonl` has one line per message in chunk NNNNN:

```json
{"id":"b7f3…","folder":"INBOX","uid":4211,"messageId":"<x@y>","subject":"Q3 numbers",
 "from":"ana@example.com","fromName":"Ana","to":["me@example.com"],"cc":[],
 "date":"2021-04-02T09:14:00Z","flags":["seen","answered"],"size":48211,
 "hasAttachments":true,"attachments":["q3.xlsx"],"threadKey":"<root@y>",
 "chunk":"chunks/chunk-00001.zip","entry":"INBOX/4211-b7f3.eml","offset":18234,"length":48211,
 "snippet":"Hi, attached are the…"}
```

`terms-NNNNN.json` maps lowercase words (subject, addresses, plain text body)
to line numbers in the matching `messages-NNNNN.jsonl`:

```json
{"numbers":[0,17,340],"q3":[0]}
```

FalconMail loads index shards into memory on demand; the archive itself is
never downloaded in full.

## Manifest

```json
{
  "format": "falconmail-archive",
  "version": 1,
  "name": "Work 2019-2023",
  "createdAt": "2026-09-19T12:00:00Z",
  "generator": "FalconMail 0.1.0",
  "account": {"email": "me@example.com", "provider": "google"},
  "encryption": null,
  "folders": [{"path": "INBOX", "messageCount": 12000}],
  "chunks": [{"name": "chunks/chunk-00001.zip", "messageCount": 12000, "byteSize": 734003200, "sha256": "…"}],
  "indexShards": [{"messages": "index/messages-00001.jsonl", "terms": "index/terms-00001.json"}],
  "messageCount": 12000,
  "byteSize": 734003200
}
```

## Encryption (optional)

When a password is set:

- Key: PBKDF2-HMAC-SHA256, 600 000 iterations, 16-byte random salt, 32-byte key.
- Every `.eml` entry becomes `.eml.enc`: AES-256-GCM, 12-byte random nonce,
  stored as `nonce || ciphertext || tag` (CryptoKit `combined` layout).
- Every index file becomes `.enc` with the same construction.
- `manifest.json` stays readable and carries
  `{"algorithm":"AES-256-GCM","kdf":"PBKDF2-HMAC-SHA256","iterations":600000,"salt":"<base64>","check":"<base64>"}`
  where `check` is the sealed UTF-8 string `falconmail-archive-v1`, used to
  verify a password before reading anything.

The algorithms are available in .NET, Python and OpenSSL, so a Windows reader
is a short script. A reference reader lives in `tools/` once that milestone
lands.

## Import and export

- Export to a local folder or a USB stick uses the same layout, so a Windows
  user gets zips of `.eml` files.
- Import accepts `.fmarchive` folders, `.eml` files and `.mbox` files, and
  writes messages back to any IMAP folder with `APPEND`, keeping flags and
  dates. OLM and PST import are on the roadmap.
