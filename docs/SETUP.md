# Setup

## 1. Google Cloud project

1. Open https://console.cloud.google.com and create a project, for example
   `FalconMail`.
2. APIs & Services → Library: enable **Gmail API**, **Google Drive API**,
   **Google Calendar API**, **People API**.
3. APIs & Services → OAuth consent screen: choose **Internal** if the app is only
   for your Workspace domain. This skips Google's restricted-scope review.
4. Credentials → Create credentials → **OAuth client ID** → Application type
   **Desktop app**. Copy the client ID and client secret.

Scopes the app requests:

| Scope | Used for |
| --- | --- |
| `https://mail.google.com/` | IMAP and SMTP |
| `https://www.googleapis.com/auth/drive.file` | Archives on Google Drive |
| `https://www.googleapis.com/auth/calendar` | Calendar and Meet |
| `https://www.googleapis.com/auth/contacts.readonly` | Contacts sync |
| `https://www.googleapis.com/auth/userinfo.email` | Account identity |

## 2. Configure the app

Copy `App/FalconMail/Config/GoogleOAuth.example.plist` to
`App/FalconMail/Config/GoogleOAuth.plist` and fill in `ClientID` and
`ClientSecret`. The real file is ignored by git. You can also paste the values in
the app's account setup window; they are then kept in the Keychain.

## 3. Build

```sh
brew install xcodegen
xcodegen generate
open FalconMail.xcodeproj
```

Select your team under Signing & Capabilities, then Run. The library tests run
with `swift test` or from the Xcode test navigator.

## 4. First run

Add account → Google Workspace → Sign in. The browser opens, you approve, and
the browser redirects to a local port the app is listening on. The app then
lists folders, syncs the most recent 1000 messages per folder, and keeps the
inbox in IDLE.
