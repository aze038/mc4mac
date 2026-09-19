# Setup

## 1. Google Cloud project (done once, by the company, not by users)

Every app that talks to Google, including Outlook and Thunderbird, identifies
itself with an OAuth client. FalconMail carries its client inside the app, so
users never see a client ID. Create it once:

1. Sign in to https://console.cloud.google.com **with a Workspace admin
   account of your company domain**, not a personal Gmail account. The project
   must belong to the Workspace organization for the next step to be available.
2. Create a project, for example `FalconMail`.
3. APIs & Services → Library: enable **Gmail API**, **Google Drive API**,
   **Google Calendar API**, **People API**.
4. APIs & Services → OAuth consent screen: choose **Internal**. Every user in
   the domain can then sign in, no Google verification review, no test-user
   list. (**External** in *Testing* mode only lets the listed test users sign
   in, which is why a personal account can work while a company account is
   refused.)
5. Credentials → Create credentials → **OAuth client ID** → Application type
   **Desktop app**. Copy the client ID and client secret.
6. If the Workspace admin console restricts third-party apps (Security → Access
   and data control → API controls), mark the app as trusted there.

Scopes the app requests:

| Scope | Used for |
| --- | --- |
| `https://mail.google.com/` | IMAP and SMTP |
| `https://www.googleapis.com/auth/drive.file` | Archives on Google Drive |
| `https://www.googleapis.com/auth/calendar` | Calendar and Meet |
| `https://www.googleapis.com/auth/contacts.readonly` and `contacts.other.readonly` | Contacts sync |
| `https://www.googleapis.com/auth/userinfo.email` | Account identity |

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
