# Setup

## 1. Google Cloud project (done once by the publisher, never by users)

Every app that talks to Google, including Outlook and Thunderbird, identifies
itself with an OAuth client. FalconMail carries its client inside the app, so
users never see a client ID. Create it once:

1. Sign in to https://console.cloud.google.com and create a project, for
   example `FalconMail`.
2. APIs & Services → Library: enable **Gmail API**, **Google Drive API**,
   **Google Calendar API**, **People API**.
3. APIs & Services → OAuth consent screen → User type **External**. Fill in
   the app name, support email, logo, homepage, privacy policy and terms
   links (see below), and the authorized domain of the homepage.
4. Credentials → Create credentials → **OAuth client ID** → Application type
   **Desktop app**. Copy the client ID and client secret.
5. On the consent screen page press **Publish app** to move from Testing to
   Production.

### What "public for everyone" means with Google

- In **Testing** only the listed test users (max 100) can sign in. This is why
  a personal account that was added as a tester worked while a company
  account did not.
- In **Production, unverified**, anyone can sign in but Google shows a
  "Google hasn't verified this app" warning (Advanced → continue), and the app
  is capped at 100 users for sensitive and restricted scopes.
- For unlimited users the app must pass **Google's OAuth verification**. IMAP
  access uses the restricted scope `https://mail.google.com/`, and there is no
  narrower scope that allows IMAP, so the restricted-scope review is
  mandatory for any public Gmail client. It consists of brand verification
  (days), a scope justification with a demo video, and a **CASA security
  assessment** by an authorized lab (weeks, paid, renewed yearly). Thunderbird,
  Spark and every other public mail client go through the same process.
- Verification needs a public homepage and privacy policy. `docs/privacy.md`
  and `docs/terms.md` are starting drafts; GitHub Pages can host them.

Users who do not want to wait for verification, or whose Workspace admin
blocks third-party apps, can add Gmail through "Other email (IMAP)" with a
Google App Password. That path needs no OAuth client at all but covers mail
only.

Scopes the app requests:

| Scope | Used for |
| --- | --- |
| `https://mail.google.com/` | IMAP and SMTP (restricted scope) |
| `https://www.googleapis.com/auth/drive.file` | Archives on Google Drive (non-sensitive) |
| `https://www.googleapis.com/auth/calendar` | Calendar and Meet (sensitive) |
| `https://www.googleapis.com/auth/contacts.readonly` and `contacts.other.readonly` | Contacts sync (sensitive) |
| `https://www.googleapis.com/auth/userinfo.email` | Account identity |

### Public distribution on macOS

A public release must be signed with a Developer ID certificate and notarized,
otherwise Gatekeeper refuses to open it on other Macs. Add the five signing
secrets listed in `docs/ROADMAP.md` and the Release workflow signs and
notarizes automatically.

## 2. Put the client into the builds

Add two repository secrets on GitHub (Settings → Secrets and variables →
Actions): `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET`. CI and
Release builds embed them into the app's `Info.plist`. Google documents that
the secret of a Desktop app client is not confidential; it is still kept as a
secret so it never appears in the repository.

For a build from source on your own Mac, either copy
`App/FalconMail/Config/GoogleOAuth.example.plist` to `GoogleOAuth.plist` and
fill it in (the file is git-ignored), or paste the values under Settings →
Advanced in the app.

## Adding accounts in the app

Add account → type the email address → choose **Google Workspace or Gmail**
(the browser opens Google's sign-in) or **Custom settings** (IMAP and SMTP
server, port, username and password; the app tests both connections before
saving). Custom servers must offer SSL/TLS on the port, usually 993 and 465.

## 3. Build

One-time setup:

```sh
./scripts/setup.sh
open FalconMail.xcodeproj
```

This installs XcodeGen, generates the project, and enables git hooks that
regenerate it after every `git pull`, checkout or rebase. New files under
`App/` are picked up without any manual step. If a build ever complains about a
missing type right after a pull, run `make project`.

Select your team under Signing & Capabilities, then Run. The library tests run
with `swift test` or from the Xcode test navigator.

## 4. First run

Add account, enter your address, continue with Google. The browser opens, you
approve, and the browser redirects to a local port the app is listening on.
The app then lists folders, syncs the most recent 1000 messages per folder,
and keeps the inbox in IDLE.
