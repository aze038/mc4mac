# FalconMail for Google accounts: a Gmail API engine with no IMAP and no SMTP

Design document, 25 September 2026, revision 2.

- **What it replaces.** The "API-first hybrid" parts of the earlier mail-engine design (revision 2, kept privately by the owner). That design still used IMAP for the whole-mailbox skeleton, the list rows and the bodies. This one uses only the Gmail API for Google accounts. Appendix A lists what is kept from it, what changes and what is dropped.
- **Code references** are `file:line` at mc4mac `9046d5b` (v1.10.0), unless a worktree is named: `fm-windows` at `1ab97a5`, `fm-inline-images` at `f906ed1`, olm2cloud at its current checkout.
- **Google facts** come from the fact sheet given with this task. All its pages were read on 25 September 2026, and they are cited as [S1]…[S32]. Two more pages were read for this design on the same day:
  - [S33] the Gmail API search guide (developers.google.com/workspace/gmail/api/guides/filtering, updated 2026-09-10): dates in `q` are read as midnight Pacific time, and epoch seconds give exact times;
  - [S34] the labels guide (…/guides/labels, updated 2026-09-10): an app may add or remove INBOX, SPAM, TRASH, UNREAD, STARRED, IMPORTANT and the five `CATEGORY_*` labels, but not SENT or DRAFT.
- **Labels in the text.** *(Estimate)* marks a figure worked out here that has not been measured. *(Probe)* marks behaviour that Google does not document; work item G1 checks each one once on the owner's own test account (§14.4). The probe has a read-only part and a small write part, and the write part runs only with the owner's approval.
- **Quota costs** are the new ones, which apply to projects created from 1 May 2026: `messages.get` 20, `threads.get` 40, `attachments.get` 20, and 6,000 units a minute per user per project [S1]. If the project turns out to be on the old tier, every figure here gets better.

**What changed in revision 2.** Three reviews of revision 1 (quota and capacity; correctness and data safety; fidelity to Outlook) raised 65 points. Every one is answered in the **Review log** at the end, with the decision and the section it changed. The biggest changes:
- **Budget.** Google's 6,000 units a minute is shared by every copy of FalconMail on the same account and by olm2cloud. So FalconMail keeps v1.10.0's 3,000 a minute per account on each Mac, and uses less while it sees an import running (§1.3).
- **New mail** is decided by when Gmail received it, not by where it sits in the list. An imported message dated 2037 can no longer silence notifications (§4.3).
- **Sending.** A send whose outcome is unclear is checked, and if it is not found it is held for the owner. It is never sent again by itself (§8.2).
- **Drafts.** Closing a message keeps its copy on the Mac until Gmail has saved it. Today's code deletes that copy first. This fix ships early, with `fm-windows` (§14.2).
- **Outlook's folders.** Folders use Outlook's names (Archive, Sent, Deleted Items, Junk Email), and every action has a written rule for every folder (§2.2, §7.1).
- **Honest scrolling figures.** Mail never seen before fills about 3 screens a minute, not 7–9 (§5.7).

The previous version is kept at `/private/tmp/claude-501/-Users-kmuradoff-mc4mac/8f7bb11b-871e-4f45-817b-f5ba1ea3c7a9/scratchpad/revise/gmail-api-engine-design.v1.md`.

---

## Summary

**The decision.** From 25 September 2026 the owner's rule is this: *"make sure we use Google API everywhere when we use FalconMail with Google Accounts."* So FalconMail uses only the Gmail API for Gmail and Google Workspace accounts, and never opens an IMAP or SMTP connection for them once they are switched. That covers:
- folders and the message list;
- noticing new mail and changes;
- opening messages and attachments;
- every action and every rule;
- sending, drafts and imports;
- the archive job and search.

Other accounts keep v1.10.0's IMAP and SMTP engine unchanged.

**What the owner gets**
- **Every message is in the list.** Inbox, Sent, every label, Junk Email, Deleted Items and Archive (Gmail's All Mail), with no "Load older" and no "Show more". The status bar's **Items** count is the folder's real total.
- **Outlook's folders.** Under [Gmail]: Drafts, Archive, Sent, Deleted Items, Junk Email, Important and Starred, in that order, as in the owner's Legacy Outlook.
- **Little disk.** Only the newest 1,000 messages of each account are kept on the Mac, with the first screen of the Inbox and of the 12 folders used most recently. Those open at once, and offline. Everything else on disk is a 32-byte-per-message index that holds no text. Typical use is **about 12–25 MB per account**, and never more than about 43 MB.
- **New mail within about 30 seconds**, with notifications and Outlook's sounds as today. Clicking a notification opens the message.
- **Actions show at once and can be undone.** One call changes up to 1,000 messages. An action that cannot reach Gmail yet waits on the Mac and is sent later.
- **Sending uses Gmail's own send.** Nothing is ever sent twice: a send whose outcome is unclear is held for the owner unless Gmail's records show it went.
- **Closing saves to Drafts, and Discard throws the message away, with Undo** (the owner's rule of 25 September). The text is never lost, even if FalconMail quits while Gmail is saving it.
- **A double-clicked message opens in its own window at once.** Today it waits 0.3 s before even asking Gmail; that wait goes (§6).
- **"Protocol error" cannot appear for a Google account.** Every refusal from Google is typed, and becomes one plain sentence.

**Key numbers** (per account; the timings are estimates until work item G1 measures them)

| | 55,000 messages | 200,000 messages |
|---|---|---|
| First screen of a newly added or newly switched account | ≈ 1.5 s | ≈ 1.5 s |
| First screen of the Inbox and the 12 most used folders on later launches (from disk) | < 150 ms | < 150 ms |
| Every message listed, so the whole list is complete (Mac idle / owner working) | ≈ 40 s / ≈ 1.2 min, ≈ 1,200 units | ≈ 2 min / ≈ 5 min, ≈ 4,900 units |
| Fully set up: the index, plus the newest 1,000 kept on the Mac with their text (Mac idle / owner working) | ≈ 20 min / ≈ 40 min, ≈ 39,000 units | ≈ 21 min / ≈ 42 min, ≈ 42,000 units |
| Old mail never seen before, scrolled into view | the first screen at once; about 3 screens a minute after that | same |
| Units on a typical day, once set up | ≈ 36,000 (0.4% of Google's per-user day) | same |
| Disk | ≈ 12–20 MB | ≈ 17–25 MB |

**Why quota is fine.**
- Google gives each user 6,000 units a minute, **shared** by every app in our Google project that works on that user's mail: FalconMail on each Mac, and olm2cloud. FalconMail takes at most half of it, 3,000, per account on each Mac. That is v1.10.0's figure today.
- A typical day uses about 36,000 units. That is 0.4% of Google's per-user day, an average of 25 units a minute.
- 200 accounts use about 9% of the project's 80 million units a day. That figure is a **billing threshold**, not a cut-off (§1.4).
- **The one tight case** is olm2cloud importing into an account while FalconMail is busy with the same account. olm2cloud's default of 200 imports a minute takes 5,000 units on its own. So FalconMail drops to 2,000 a minute while it sees an import running, and this design recommends 150 imports a minute for olm2cloud. That change is a decision for the owner (§1.3, §15.3).
- **What this costs the owner:** scrolling through old mail never seen before is slower. The first screen fills at once, and after that about 3 screens a minute. Rows beyond that stay grey, with a footer that says they are loading.

**How it is built** (§14)

| What | Ships |
|---|---|
| **E1–E3, early fixes:** closing keeps the draft until Gmail or IMAP has it, and Discard deletes the saved copy only after Undo has expired (E1); message windows open without the 0.3 s wait (E2); the attachment price fix (E3) | In v1.10.x. E1 and E2 go with `fm-windows`, the owner's windows and Discard work |
| **G0–G7:** the engine, the list, actions, sending and drafts, and the move from IMAP | Each merges behind a per-account switch that stays off. The switch goes on only when all have landed and the acceptance targets pass: first for the owner's test account, then his other accounts one at a time, when he says so |

**What the owner asked, and where it is answered**

| The owner's words (24–25 Sep) | Where |
|---|---|
| "use Google API in priority… everywhere… with Google Accounts" | §1, and the zero-connection proof in §12.5 |
| "IMAP is just suspending the account" | §1.5, §11 |
| He sees only about 1,000 messages ("show all emails") | §5, and the Items count in §5.11 |
| "Cache offline latest 1000 emails. That's it." | §2.4, §2.6 |
| Fast search | §5.10 |
| "Sometimes I see it says Protocol Error" | §10 |
| Outlook look, sounds and notifications as today | §2.2, §4.7, §5 |
| Double-click opens its own window, which minimises like a compose window; Discard for new mail and replies; closing saves to Drafts | The windows and Discard are built in the `fm-windows` worktree. This design adds what those windows need: E1 and E2, which ship with it (§14.2); opening any Google message by its Gmail id, including when offline (§5.9); and Gmail drafts behind Close and Discard (§8.4) |

**Decisions that need the owner** (§15.3): approving G1's small write probe on his test account; olm2cloud's import pace and upload cap; a daily cap on the Google project; whether the text of rows he has already seen may stay on disk; and what Delete means inside a label folder.

---

## 1. Decisions, and why quota is fine

### 1.1 Decisions

1. **The API only, for Google accounts.** An account signed in with Google (gmail.com, googlemail.com or a Workspace domain) and switched to the new engine is served by `GmailAccountEngine`. It never creates an `IMAPClient` or an `SMTPClient`.
   - A guard refuses any connection to Google's IMAP or SMTP hosts for a switched account, and logs every connection to those hosts for any account, so a mistake fails loudly and anything still on IMAP shows in the daily report (§12.5).
   - Other accounts keep `AccountSyncer` unchanged (§13).
2. **The index is built from list calls, not message fetches.**
   - `messages.list` returns ids and thread ids, newest first, 500 per page, for 5 units [S7].
   - Listing All Mail once gives every message's place in the order. Listing each shown label gives every message's labels, which carry the read state (UNREAD), the flag (STARRED), the folders and the categories.
   - Together they give a 32-byte record per message: order, read state, flag, folders, categories and conversation, for **every** message. Building it for 55,000 messages costs about 1,200 units. The same records fetched one message at a time would cost 1,100,000.
3. **A row's text is fetched only when the row is shown.**
   - `messages.get format=metadata` costs 20 units for a single message, and `threads.get format=metadata` costs 40 for a whole conversation.
   - Up to 25 rows are fetched in one HTTP batch. Beyond what is kept on the Mac, they are held in memory only (§5.7).
   - The newest 1,000 messages of each account are the only message text on disk. Each conversation among them also keeps a short summary (senders, count, newest date), so conversation rows paint from disk (§2.4).
4. **One key everywhere.** The Gmail message id, with the thread id and history id beside it. A Google row's id becomes `"<accountUUID>:gm:<hex>"`, which `MailStore` never resolves, so no old code path can act on it by mistake. Every path that must act on one is routed by engine (§7.7).
5. **Changes come from polling `history.list`**, every 30 s while the owner is active, for 2 units a call. Google recommends polling for installed apps [S6]. Push through Pub/Sub would need a credential shipped in every copy of the app [S6][S30], so it is not used.
6. **One writer and one cursor.** `GmailAccountEngine`, an actor, owns all of the account's state. The history cursor lives only in the index journal, written in the same flush as the changes it covers, so a crash can only replay changes and never skip them (§4.5).
7. **Mail is new when Gmail received it since the last check**, by Gmail's clock, whatever its place in the list (§4.3).
8. **Every change the owner makes is shown at once and can be undone.**
   - Each change is sent as label changes: `modify` for 5 units, or `batchModify` for up to 1,000 messages at 50 units.
   - Each folder has written rules for Archive, Move and Delete, so a move never asks Gmail for something it refuses and never takes a flag off (§7.1).
   - A pending change is kept in `pendingOps.json` until Gmail confirms it, for at most 24 hours, as v1.10.0 does.
   - Retrying is safe, because adding or removing a label twice changes nothing.
9. **Sending uses `messages.send`, with no SMTP fallback.**
   - The sent row appears in Sent and in its conversation from Gmail's answer.
   - A send whose outcome is unclear is looked for in the history. If it is found, it is marked sent. If not, it is **held for the owner**, as v1.10.0 does, and never sent again by itself (§8.2).
10. **Drafts use `drafts.create`, `drafts.update` and `drafts.delete`.** Closing saves to Drafts and Discard deletes after the undo window, per the owner's rule of 25 September. The copy on the Mac is deleted only once Gmail has the draft (§8.4).
11. **Imports use `messages.import`** with `internalDateSource=dateHeader` and `neverMarkSpam=true`, and are placed from Gmail's answer. **The archive job uses `format=raw` downloads.** Both are paced by units and by bytes.
12. **Budgets** (§11).
    - **Units.** At most **3,000 units in any 60 seconds** per account on each Mac, which is half of Google's shared 6,000. It is a token bucket that refills 2,000 a minute and holds at most 1,000, so a click always finds units and background work cannot use up a minute in its first seconds.
    - **Classes of work.** Change checks and new mail come first, so scrolling never delays new mail. Work the owner is waiting for comes next, then whole-view actions, then background work, which never takes the bucket below 500.
    - **While another app is importing** into the account, FalconMail stays at or below 2,000 a minute.
    - **Requests in flight.** At most 4 HTTP requests per account, 2 of them kept for work the owner is waiting for. At most 35 batch parts in flight: 25 for one screen of rows, and 10 for background work.
    - **Bytes.** FalconMail meters every API byte over a rolling 24 hours: 1,500 MB down (800 MB for background work) and 400 MB up (300 MB for imports). Google's allowance, by inference, is about 2,500 MB down and 500 MB up, shared by all of the user's API clients [S4][S16].
13. **The list is virtualised.**
    - An `NSTableView` holds an immutable `ListSnapshot` of 24 bytes per row. It hosts the Outlook row component from `fm-list-rows` **unchanged**, one `NSHostingView` per reusable cell.
    - Rows not yet fetched are drawn with the same component in its redacted look, applied by the host. They already show the unread dot, the flag and the conversation's unread count, all known from the index.
14. **Outlook's names and order in the sidebar** for Gmail's system folders (§2.2).
15. **The switch.** Each Google account moves on its own switch, and only once its pending IMAP actions have been sent. The old IMAP store stays untouched on disk, so v1.10.0 can take the account back without losing anything. It is deleted only 14 days after the move, and only after the owner confirms (§12).

### 1.2 The arithmetic

**What the calls cost** [S1]: `history.list` 2; `messages.list` 5; `labels.get` 1; `labels.create` 5; `messages.get` (any format) 20; `threads.get` 40; `attachments.get` 20; `modify` 5; `batchModify` 50 for up to 1,000 ids; `messages.send` 100; `messages.import` and `messages.insert` 25; `drafts.create`, `drafts.update`, `drafts.delete` and `drafts.list` 10, 15, 10 and 5; `batchDelete` 50.

**One account on a typical day, once set up** *(estimate; G7's "typical day" test replays it against the fake mailbox)*

| Work | Calls a day | Units |
|---|---|---|
| Change checks: every 30 s for 10 active hours, every 2 min for 4 idle hours | 1,320 | 2,640 |
| New mail kept on the Mac: `format=full` for about 150 messages | 150 | 3,000 |
| Pictures in that mail: at most one extra call per message (§2.4) | ≤ 150 | ≤ 3,000 |
| Folder counts after changes (`labels.get`) | 300 | 300 |
| Older rows scrolled into view: about 300 rows, 40% of them conversations (20 or 40 units a row) | ≈ 300 | 8,400 |
| First screens of folders outside the 13 kept on the Mac, about 5 a day | 5 batches | 2,500 |
| Opening older messages, and their pictures | ≈ 120 | 2,400 |
| Attachments opened or saved | 30 | 600 |
| Search: 20 searches of 5 + about 15 new rows × 20, and 40 id-only lookups while typing | 360 | 6,300 |
| Actions: 200 single changes and 5 bulk ones | 205 | 1,250 |
| Marked read on opening | 150 | 750 |
| Sending 30 messages | 30 | 3,000 |
| Drafts: 30 × (create + two updates + delete) | 120 | 1,500 |
| Date anchors at midnight, send-as addresses, profile, daily count check | ≈ 60 | ≈ 100 |
| **Total** | | **≈ 36,000** |

Revision 1's "look at the top of All Mail after new mail" (500 units) is gone: new mail is now recognised by its arrival time (§4.3).

**How that compares with Google's limits**
- **Per user.** The user's daily ceiling is 6,000 × 1,440 = 8.64 million units, so a typical day uses 0.4% of it. The average is about 25 units a minute.
- **The busiest minute** of a normal day is a search plus three screens of old rows: 505 + 3 × 700 ≈ 2,600 units. FalconMail never goes above 3,000 in any 60 seconds for one account on one Mac.
- **First day.** Setting up an account costs about 30,000–55,000 units more, typically about 40,000 *(estimate)*:
  - the index: 1,200 at 55,000 messages, 4,900 at 200,000, and 5,100 for a mailbox migrated from Outlook with 150 labels;
  - the date anchors: about 600, only if date groups are on;
  - the newest 1,000 with their pictures: 20,000–40,000, typically 29,000;
  - conversation summaries for threads with older members: about 6,000;
  - the first screens of the 13 folders kept: about 2,000, since most are already among the newest.
- **Project, per day.** 80 million units a day is the point above which Google will bill, once billing starts after 90 days' notice. It is not a refusal, and it cannot be raised [S1].

| Accounts | Typical day | A heavy day (3× typical) | If every account were set up that same day |
|---|---|---|---|
| 20 | 0.7 M (0.9%) | 2.1 M (2.7%) | + 0.9 M |
| 50 | 1.8 M (2.2%) | 5.4 M (6.7%) | + 2.2 M |
| 200 | 7.1 M (8.9%) | 21 M (27%) | + 8.6 M |

- **olm2cloud uses the same project.** A migration of 100,000 messages costs 2.5 million units. So:
  - 10 such migrations in one day, with 200 FalconMail accounts on a heavy day, come to about 46 million (58%);
  - 20 come to about 71 million (89%);
  - 30 would pass 80 million.
  - Large migrations should therefore be spread over several days. The daily health report shows the project's units, so any growth shows within a day (§10.3).
- **Project, per minute** (1.2 million [S1]). If 200 accounts all sat at FalconMail's ceiling of 3,000 at the same moment, that would be 0.6 million, or 50%. A busy minute is about 2,600 per account, so 43%, and only if every account peaked at once.
- **Compared with the hybrid design.** That design used about 10,000 units per account a day, because IMAP supplied the rows and bodies. This one uses about 3.5 times as much and is still far inside every limit. The rows and bodies that IMAP used to carry now cost units instead of IMAP bandwidth, and IMAP bandwidth is the allowance whose overuse suspends accounts.

### 1.3 Sharing Google's per-user limit

**In plain words:** Google's 6,000 units a minute belongs to the user, not to one copy of FalconMail. Every app in our Google project that works on that user's mail takes from the same 6,000. FalconMail therefore keeps to half of it, and less while it sees another app importing.

| Who is using the account | Most units in one minute | Within 6,000? |
|---|---|---|
| FalconMail on one Mac | 3,000 | yes, 50% |
| FalconMail on two Macs | 6,000, only if both scroll old mail in the same minute | at the limit. A refusal (429) halves each Mac's budget, and nothing is lost |
| FalconMail and olm2cloud at today's 200 imports a minute (5,000 units) | 3,000 + 5,000 = 8,000 | **no** |
| FalconMail while it sees an import (2,000) and olm2cloud at 200 a minute | 7,000 | **no**: olm2cloud is refused now and then, and slows itself |
| FalconMail while it sees an import (2,000) and olm2cloud at **150** a minute (3,750) | 5,750 | yes |
| Two Macs and olm2cloud together | can pass 6,000 | no. Refusals halve every client's budget, and nothing is lost |

- **How FalconMail sees another app importing.** Imports arrive in the change history as additions deep in the mailbox's order. More than 50 in one check, or 200 in 10 minutes, that FalconMail did not import itself, start flood mode (§4.3). In flood mode FalconMail stays at or below 2,000 units a minute, background work at or below 500, and the filling of the newest 1,000 pauses.
- **What olm2cloud should change** (decision O1, §15.3). Its default is 200 imports a minute at 25 units each (olm2cloud `GmailImporter.swift:19` and `:332`; `MigrationSession.swift:129`). For an account that is also open in FalconMail, 150 a minute keeps the two together under 6,000. A later step could let both apps on one Mac book from one shared budget file; that needs a change to both apps and is not part of this plan.
- **Uploads are shared too.** Google says the API's upload and download allowances are per user and shared by all of the user's API clients, and that going over them can bring refusals for hours [S4]. Google does not say whether imports count against the upload allowance.
  - **If they do,** a migration day could use it up. Gmail would then refuse FalconMail's sends and draft saves for hours, and this design has no SMTP fallback. olm2cloud aims at 200 imports a minute, about 29 GB of upload a day at 100 KB a message, with no daily cap (olm2cloud `MigrationSession.swift:413-419`).
  - **Containment.** FalconMail recognises this refusal on a send or a draft save and says so plainly: "Gmail has paused uploads for {email} until {time}; an import may be using the allowance. The message stays in the Outbox." Nothing is lost (§8.2, §10.2). olm2cloud should cap its daily upload for an account that also uses FalconMail, at about 350 MB, and stop at the first bandwidth refusal (decision O1).
  - **Finding out.** G1 looks for upload refusals in olm2cloud's own logs of past real migrations, with the owner's permission. Nobody tests this on a live account.

### 1.4 What happens if a limit is reached anyway

| Limit | Google's answer | What FalconMail does | What the owner sees |
|---|---|---|---|
| Per user, 6,000 a minute, shared (§1.3) | 429, or 403 `rateLimitExceeded` / `userRateLimitExceeded`, with a retry time [S4] | Halves its own budget, waits for the retry time, then recovers by a tenth a minute. Work the owner is waiting for goes first. Changes the owner made wait; they are never undone by this (§7.3) | Nothing for the first minute. After that, in the status bar: "Waiting a moment before loading more of {email}'s messages." Rows stay grey. Mail on the Mac, actions (queued) and sending (queued) carry on |
| Requests at the same time (number not published, shared by all of the user's clients) | 429 "Too many concurrent requests for user" [S4] | Halves the batch parts it has in flight, for 10 minutes | Nothing |
| API download allowance (≈ 2,500 MB a day, inferred [S4][S16]) | 429 with a retry time, which can last hours | Its own budget stops background downloads at 800 MB and everything but checks at 1,500 MB. On a 429 it pauses API downloads until the retry time | "FalconMail has paused downloading older mail for {email} until {time}, to stay within Gmail's daily limit. New mail still arrives." |
| API upload allowance (≈ 500 MB a day, inferred; shared with olm2cloud, §1.3) | 429 with a retry time, which can last hours | Imports stop at 300 MB of FalconMail's own 400 MB, keeping the rest for sends and drafts. On a 429 the Outbox and draft saves wait until the retry time | "Gmail has paused uploads for {email} until {time}; an import may be using the allowance. The message stays in the Outbox." |
| Sending (2,000 a day on Workspace, 500 on gmail.com [S18][S19]) | 429 "User-rate limit exceeded (Mail sending)" | The Outbox holds the message until the retry time and does not retry before then | "Gmail's daily sending limit for {email} was reached. The message stays in the Outbox." |
| The project's 80 million a day | **None.** It is a billing threshold: once Google starts billing, use above it is charged, not refused [S1]. A 403 `dailyLimitExceeded` appears only if the project owner sets a daily cap himself [S4] | Reports the project's units in the daily health report. If the owner sets a cap (decision O2, §15.3), a `dailyLimitExceeded` holds every call until midnight Pacific time, and change checks stop | Only with a cap: "Today's Gmail allowance for FalconMail is used up until {time}. Mail on this Mac stays available; changes you make are sent then." |

### 1.5 Why this is safer than IMAP
- **IMAP.** Going over the IMAP bandwidth limit suspends the account's Gmail for 1–24 hours, and an admin can lift it only 5 times a year [S16][S20]. That was the owner's experience.
- **The API.** Its limits are described only as refusals with a retry time [S1][S4]. Its bandwidth is counted apart from IMAP's [S4].
- **What is not promised.** Google's general "server request limits" page suspends an account that sends too many requests at once, and it does not exclude the API [S17]. The same page advises mail clients, which it names as IMAP and POP, to check for mail about once every 15 minutes. **FalconMail's check every 30 seconds goes well beyond that advice.** It is kept because each check is one small API call of 2 units, and new mail within half a minute is what the owner expects; open question 1 offers once a minute while FalconMail is not in front. To stay far from anything that could look like abuse, the design:
  - checks for changes at most twice a minute per account on each Mac;
  - keeps each account at or below half of the per-user limit, and below that while another app imports;
  - backs off at the first 403 or 429, and halves its batch parts after a concurrency refusal;
  - never retries without waiting.

---

## 2. Identity and store

### 2.1 Keys (new file `Sources/FalconCore/GmailEngine/GmailIdentity.swift`)
```swift
public struct GmailMessageID: Hashable, Comparable, Codable, Sendable { public let raw: UInt64; public var hex: String }  // API "id"
public struct GmailThreadID:  Hashable, Codable, Sendable { public let raw: UInt64; public var hex: String }               // API "threadId"
public struct GmailLabelID:   Hashable, Codable, Sendable { public let value: String }  // "INBOX", "Label_123"
public struct HistoryID:      Comparable, Codable, Sendable { public let raw: UInt64 }  // sent as a string of digits
public enum RowKey: Hashable, Sendable {          // what the list, windows and actions pass around
    case gmail(account: UUID, id: GmailMessageID) // string form "<accountUUID>:gm:<hex>"
    case stored(String)                           // today's "<account>:<folder>:<uid>" for IMAP accounts
}
```
- **Parsing ids.** An id that does not parse as 64-bit hex is refused and logged. Gmail's ids are 16 hex digits.
- **`MessageSummary` gains only optional fields** (Types.swift:132-201): `gmailID`, `gmailThreadID`, `labelIDs`, `internalDate`, `bcc`, `replyTo`. Synthesised `Codable` reads a missing optional as nil, so every stored file of v1.10.0 still loads.
- **`threadKey` for Google rows is `"gm:<threadHex>"`.** The server-only search rows already use this (GmailSearch.swift:42).
- **`folderID` on a Google `MessageSummary`** is filled in from the view the row is shown in, at the moment it is built. It is never stored (§7.2).

### 2.2 Labels, and how they map to Outlook's sidebar

Gmail has labels, and Outlook has folders. The sidebar follows the owner's Legacy Outlook (a private capture kept outside the repo): Inbox at the top, then the [Gmail] group with Drafts, Archive, Sent, Deleted Items, Junk Email, Important and Starred, in that order. v1.10.0 shows Gmail's IMAP names instead ("Sent Mail", "All Mail", "Spam", "Trash"); switched accounts show Outlook's.

| Gmail label | `FolderRole` | Sidebar name | Place | Notes |
|---|---|---|---|---|
| `INBOX` | `.inbox` | Inbox | top of the account | |
| `DRAFT` | `.drafts` | Drafts | [Gmail], 1st | an app cannot add or remove it [S34]. Its count is the **number of drafts**, as in Outlook, not the unread count |
| none: All Mail | `.all` | **Archive** | [Gmail], 2nd | every message except those in Junk Email, Deleted Items and chats |
| `SENT` | `.sent` | **Sent** | [Gmail], 3rd | an app cannot add or remove it [S34] |
| `TRASH` | `.trash` | **Deleted Items** | [Gmail], 4th | Gmail empties it after 30 days |
| `SPAM` | `.junk` | **Junk Email** | [Gmail], 5th | |
| `IMPORTANT` | `.important` | Important | [Gmail], then alphabetically with the rest | listed with the other labels at the first load (§3) |
| `STARRED` | `.flagged` | Starred | [Gmail], alphabetically | also the flag on every row |
| `UNREAD` | none | not a folder | | the read state of every row |
| `CATEGORY_PERSONAL`, `_SOCIAL`, `_PROMOTIONS`, `_UPDATES`, `_FORUMS` | none | not folders | | Focused and Other (§5.3) |
| `CHAT` | none | hidden | | chats are left out of every view |
| a user label, `type: user` | `.other` | its name, with `/` nesting as a folder tree (`Clients/Acme` shows Acme under Clients) | at the account level, alphabetically | see "Which labels are shown" |

- **Names.**
  - System folders take the Outlook names above, whatever v1.10.0 called them. The group keeps the name the account used, such as `[Gmail]` or `[Google Mail]`.
  - **UUIDs are kept.** When the account's v1.10.0 `folders.json` holds a folder with the same role, or a user folder with the same path, its UUID is reused. So the recent move targets, rules, the collapsed state and the selection survive the switch. Otherwise the UUID is made from SHA-256 of `accountID + labelID`.
  - Folders are keyed by label id, so renaming a label keeps its contents. v1.10.0 deletes a folder's directory when it drops out of the IMAP listing (MailStore.swift:178-229).
  - **The same names everywhere.** The Move menu (today it shows the raw path, such as `[Gmail]/Sent Mail`, CommandBar.swift:267), expanded conversation rows, the Folder column and status texts such as "Draft saved to Drafts" all use the sidebar name.
- **Which labels are shown.** The Gmail API does not carry Gmail's "Show in IMAP" setting, which decided v1.10.0's sidebar.
  - At the switch, the folders the account had in `folders.json` are the ones shown, so the sidebar looks as it did.
  - Labels created after the switch are shown.
  - For an account added after the release, labels set to `labelShow` or `labelShowIfUnread` are shown, and `labelHide` ones are not [S25].
  - Settings ▸ Accounts gains "Show all Gmail labels".
  - Hidden labels are not listed and take no index slot, so they cost nothing.
- **`FolderInfo` gains `gmailLabelID: String?`.** For Google folders, `uidValidity`, `uidNext` and the other cursor fields stay 0.
- **Switched accounts' folders never go through `MailStore`'s folder map.** `MailStore.updateFolder` and `reconcileFolders` write `folders.json` and delete folder directories (MailStore.swift:178-229). If Google folders were written there with `uidValidity` 0, v1.10.0 would treat them as renumbered after going back and download everything again. G7 keeps them in the engine's own label table only, and a test hashes `Accounts/<id>/`, apart from `Gmail/`, before and after the full scenario run.
- **The label table** (`labels.json`) holds, for each label: its id, name, type, visibility, whether it is shown, its **bit slot**, the counts `labels.get` last gave, and whether its membership is complete (§3).

### 2.3 The index: the whole mailbox at 32 bytes a message (`GmailEngine/GmailIndex.swift`)
```swift
struct GmailIndexRecord {      // 32 bytes, stride 32
    var id: UInt64             // Gmail message id
    var threadID: UInt64       // Gmail thread id
    var labelBits: UInt64      // slots 0–15 fixed system labels, 16–63 the 48 largest shown user labels
    var order: UInt32          // place in the account's order: newer is larger; gaps of 16 allow inserts
    var attrs: UInt16          // tombstone, provisional, cached, attachmentKnown, hasAttachment, sizeBand (3 bits), sizeKnown
    var spare: UInt16
}
final class GmailIndex {
    var records: ContiguousArray<GmailIndexRecord>   // a slot never moves; deletes are tombstones until compaction
    var slotByID: [UInt64: Int32]
    var byOrder: [Int32]                             // slots sorted by order, newest last; top inserts append
    var overflow: [UInt16: ContiguousArray<Int32>]   // shown user labels beyond the 48 slots: sorted record slots, 4 B per member
}
```
- **Fixed slots.** INBOX 0, SENT 1, DRAFT 2, SPAM 3, TRASH 4, UNREAD 5, STARRED 6, IMPORTANT 7, CATEGORY_PERSONAL 8, SOCIAL 9, PROMOTIONS 10, UPDATES 11, FORUMS 12, CHAT 13; 14–15 are spare.
- **Where each field comes from.**
  - **Order** comes from one listing of All Mail with `includeSpamTrash=true`, which returns every message newest first [S7]. Record i of N gets order `(N − i) × 16`.
  - A **view's order** is All Mail's order filtered by one label bit, or by one overflow list, so it needs no dates and no sorting.
  - **Label bits** come from listing each shown label, with `includeSpamTrash=true` so the bits stay exact for mail in Deleted Items.
  - **The attachment bit and the size band** come from a handful of search lists (`has:attachment`, `larger:25K`, `larger:100K`, `larger:1M`, `larger:5M`), fetched only when the owner first sorts or filters by them. After that, the metadata of new mail keeps them current.
- **Mailboxes migrated from Outlook.** olm2cloud creates one Gmail label for every Outlook folder path (olm2cloud `GmailImporter.swift:130-139`), so a migrated mailbox often has 100 or more labels covering most of its mail. The 48 largest shown labels take bit slots; the rest go into `overflow`, 4 bytes per message in the label. At 200,000 messages with 150 labels and 70% of the mail in labels, the overflow holds about 35,000 memberships, about 0.14 MB *(estimate; `calc2.py`)*. It is written in the snapshot beside the records.
- **No dates are stored in the index.** The date on a row comes with its text. The date group headers come from **date anchors** (§5.6).
- **Snapshot plus journal** (`index.snap`, `index.journal`), the pattern of FolderStore.swift:3-10:
  - The journal is append-only. It holds two kinds of record, described in §4.5: **change records** tied to cursor records, and self-contained **listing pages**. Resync start and end markers are change records.
  - Compaction runs at 5,000 journal operations or at quit. It rewrites the snapshot atomically, then truncates the journal. So the SSD writes follow the changes, not the size of the mailbox.
- **Size.** 55,000 messages take 1.8 MB on disk and about 3.5 MB in memory with the lookup tables. 200,000 take 6.4 MB on disk (6.6 MB with a migrated mailbox's overflow) and about 13 MB in memory *(estimate; the hybrid design's 40-byte record measured 14.4 MB at 200,000)*.

### 2.4 The newest 1,000, kept on the Mac (`GmailEngine/GmailMessageCache.swift`)

**Which messages** (never Junk Email or Deleted Items), filled in this order up to 1,000:
1. Drafts, messages with a pending change, and messages open in a window or tab. There are rarely more than a few dozen.
2. **First screens of the Inbox and the 12 folders used most recently.** Each keeps one screen: as many rows as the owner's list showed last time, at least 20 and at most 30. That is at most 390 slots, and most of these rows are among the newest overall, so they seldom need a slot of their own. Any other folder fetches its first screen when it is opened (one batch, ≤ 1,000 units, about a second), and keeps it in memory for the session.
3. **The account's newest** by `order`.

**What is kept for each:**
- the row: sender name and address, subject, preview of up to 100 characters, date, first To, attachment bit and size;
- the headers a reply or forward needs: Reply-To, Cc, Message-ID, In-Reply-To and References;
- a **reduced body**: the text and HTML parts, plus inline pictures of 100 KB or less, compressed with LZFSE at `bodies/<hex>.lzfse`;
- attachments as stubs only (part id, name, type, size).

**A summary for each conversation** that has a cached member: its senders in order, the number of messages and the newest date, about 150–200 bytes. Conversation rows are built from it on first paint, so a folder's first screen in Conversations view costs nothing (§5.4). It is built from the cached rows when every member is cached, and otherwise from one `threads.get format=metadata` (40 units) in the background. The history keeps it current, because a new member arrives with its `format=full` fetch.

**Rules:**
- **No flags or labels are stored with a cached message.** They are always read from the index, so a cache that lags the journal can be incomplete but never wrong.
- **Limits.** The count may reach 1,050, and eviction then brings it back to 1,000. Bodies are capped at **32 MB per account**; past that, the bodies of the oldest cached messages go and their rows stay.
- **Filling it costs 20–40 units per message.** One `format=full` call gives both the row and the text [S14]. When that answer shows two or more inline pictures and a `sizeEstimate` of 1 MB or less, one `format=raw` call (20 units) replaces the separate `attachments.get` calls, and the existing `MIMEParser` reads the pictures from it. One picture alone costs one `attachments.get` (20). So no message costs more than 40, however many signature logos it carries *(G1's probe counts inline pictures per message on the test account)*.
- **Offline search.** A header-and-preview term index (about 0.3 MB) lets the owner search these messages without a connection. Words in the bodies are indexed in memory, and only while offline.
- **Spotlight** indexes the cached messages, as v1.10.0 indexes its stored mail. An entry is removed when its message leaves the cache. The account's old IMAP entries are removed with `SpotlightIndexer.removeAccount` at the switch.
- **Rows seen once are not kept after a relaunch.** A row fetched beyond the 1,000 is held in memory for the session only, so it comes back grey after the next launch until it is scrolled into view again. Keeping those row lines (not bodies) on disk, about 0.5 KB each, would stop that. It goes against the owner's rule "latest 1000 emails. That's it.", so it is decision O3 (§15.3). This design builds the rule as he stated it.

### 2.5 Counts
- **Sidebar counts** come from the index bits. They are exact for every folder whose membership is complete. Drafts shows its number of drafts, provisional ones included (§8.4); every other folder shows its unread count, as today.
- **Before a label's listing is complete** (§3), its count comes from `labels.get` (`messagesTotal`, `messagesUnread`), at 1 unit per label [S15].
- **Once a day, when the Mac is idle,** `labels.get` is asked for every shown label, which costs about 40 units (150 for a migrated mailbox). A label whose counts differ from the bits is listed again (§4.4). Google does not say whether `messagesTotal` counts messages in Junk Email and Deleted Items, so the bits are counted **by the same rule** once G1's probe has found it. Without that, every label with a message in Deleted Items would disagree every day, and be listed again for nothing.
- **All Mail** is checked the same way against `getProfile`'s `messagesTotal`, with the Junk Email and Deleted Items rule the probe finds.
- **The Dock badge** adds up the unread count of every account's Inbox.

### 2.6 Disk and memory, per account

| On disk (`Accounts/<id>/Gmail/`) | 55,000 | 200,000 | Worst case |
|---|---|---|---|
| `index.snap` and `index.journal`, with any overflow labels | 1.8 MB | 6.4 MB | 6.8 MB |
| Label table, date anchors, drafts map, pending changes, `state.json` | < 0.1 MB | < 0.1 MB | 0.2 MB |
| Cached rows and reply headers (1,000 × ≈ 1 KB) | 1 MB | 1 MB | 1 MB |
| Conversation summaries (≈ 1,000 × 200 B) | 0.2 MB | 0.2 MB | 0.3 MB |
| Reduced bodies (LZFSE) | 8–15 MB *(estimate)* | same | 32 MB (cap) |
| Header and preview terms | 0.3 MB | 0.3 MB | 0.5 MB |
| **Total** | **≈ 12–18 MB** | **≈ 17–23 MB** | **≈ 41–43 MB** |

- **Nothing is cached anywhere else,** apart from Spotlight's entries for the same cached messages. `GoogleAPI` already uses an ephemeral session with no URL cache (GoogleAPI.swift:30-42), and the message web views use a store that does not persist.

| In memory, at 200,000 messages | Size |
|---|---|
| Index and its lookup tables | ≈ 13 MB |
| The shown view's `ListSnapshot` (24 bytes per row once its fields are ordered as in §5.2; All Mail) | ≈ 4.8 MB |
| `RowContentStore`: 5,000 rows fetched this session, ≈ 500 B each | ≈ 2.5 MB |
| Cached rows, conversation summaries and the term index | ≈ 1.7 MB |
| **Total** | **≈ 22 MB**, plus one body cache of 64 MB shared by every account |

### 2.7 Kept only in memory
- rows fetched this session beyond the 1,000, and first screens of folders outside the 13 kept;
- opened messages that are not cached, with their pictures and attachments;
- `format=raw` downloads used for View Source, Save as .eml and forwarding as an attachment;
- search results;
- conversation details from `threads.get` for conversations with no cached member.

All of it is gone when FalconMail quits.

---

## 3. First load and backfill

**In plain words:** Inbox shows in about a second and a half. The rest of the list is complete within about a minute for most mailboxes, and within about two minutes for 200,000 messages when the Mac is idle (about five while the owner works). The newest 1,000 are then kept on the Mac within about twenty minutes when idle. The owner's own clicks always go first.

**The steps, for a newly added or newly switched account**

| Step | Calls | Units (55k / 200k) | Time *(estimate)* |
|---|---|---|---|
| 0 | `getProfile` (email check, **base history id H0**, total) together with `labels.list`. H0 goes into the journal as the base cursor. | 2 | 0.3 s |
| 1 | `labels.get` for every shown label, in batches of at most 25, together with `messages.list` of INBOX (100 ids) | ≈ 25–45 (≈ 155 with 150 labels) | 0.4 s |
| 2 | **First screen:** row text for the ≈ 15 visible rows in one batch (`metadata` for single messages, `threads.get format=metadata` for conversations) | 300–600 | 0.8 s, so **≈ 1.5 s in all** |
| 3 | **Index:** listing chains for All Mail (with Junk Email and Deleted Items); INBOX, SENT, UNREAD, STARRED, IMPORTANT, DRAFT, SPAM and TRASH; INBOX combined with each of the four non-Primary categories (`labelIds` combined means a message must have all of them [S7]); each shown user label; and CHAT, if G1's probe finds that `messages.list` returns chats. The chain of the selected folder goes first. Each round sends one HTTP batch with the next page of up to 8 chains (§11.1). A mailbox over 50,000 lists All Mail in parallel slices by year (`after:`/`before:` in epoch seconds [S33]). | 1,200 / 4,900 (5,100 migrated) | idle ≈ 40 s / ≈ 2 min; owner working ≈ 1.2 min / ≈ 5 min |
| 4 | **Check the counts:** each label's bits against `labels.get`, and All Mail against `getProfile`, by the probe's rule for Junk Email and Deleted Items (§2.5). A list that differs by more than the changes applied meanwhile is listed again. | ≈ 40–150, plus any relisting | a few seconds |
| 5 | **Date anchors**, only when "Show in groups" is on or All Inboxes needs them (§5.6) | ≈ 600 | a few seconds |
| 6 | **The newest 1,000:** `format=full` in batches of 10, newest first, with their pictures (§2.4). Then the conversation summaries, then the first screens of the Inbox and the 12 most used folders. | ≈ 37,000 (28,000–48,000) | idle ≈ 20 min; owner working ≈ 40 min |
| 7 | `history.list(startHistoryId: H0)` applies whatever changed during steps 0–6. Replaying is harmless. The normal 30 s checks also run throughout. | 2 a page | < 1 s |

**Listing costs for the index, in detail** (500 ids a page, 5 units a page; each list's last page is usually part-filled) *(estimate; `calc2.py`)*

| List | 55,000 (Inbox 20k, Sent 6k, Unread 3k, Important 10k, 20 labels with 10k, 12k Inbox in other categories) | 200,000 (Inbox 80k, Sent 20k, Unread 30k, Important 40k, 40 labels with 60k, 50k Inbox in other categories) | 200,000 migrated from Outlook (Inbox 20k, Sent 30k, Unread 10k, Important 60k, 150 labels with 140k, 10k Inbox in other categories) |
|---|---|---|---|
| All Mail with Junk Email and Deleted Items | 110 pages | 400 | 400 |
| INBOX, SENT, UNREAD | 58 | 260 | 120 |
| IMPORTANT | 20 | 80 | 120 |
| STARRED, DRAFT, SPAM, TRASH | 5 | 10 | 10 |
| INBOX with each of the 4 non-Primary categories | 24 | 100 | 20 |
| User labels | 20 | 120 | 347 |
| **Total** | **≈ 237 pages, ≈ 1,200 units** | **≈ 970 pages, ≈ 4,900 units** | **≈ 1,017 pages, ≈ 5,100 units** |

- **Why not `threads.list`.** Google does not document the order of its results [S8], and `messages.list` already gives every message's thread id.
- **Why not `messages.get` for every message.** It would cost 1.1 million units at 55,000 and 4 million at 200,000, and take many hours at FalconMail's rate.
- **Pacing (§11).** Steps 3–6 are background work. It takes units only when nothing the owner is waiting for is queued, and never takes the account's bucket below 500. The first screen, clicks, opens and searches go first.
- **Before a label's listing is complete:**
  - its view shows the rows known so far, and the status bar says "Syncing {email}: 12,000 of 55,000 messages", in FalconMail's existing words (AppModel.swift:258-262);
  - its count and the Items count come from `labels.get`;
  - a conversation's size may grow as its older messages are listed.
- **Messages that move during listing.** A page can repeat or skip a message when *another* message arrives or goes while the list is being read. The history repairs arrivals and deletions, but it cannot repair a skip, because the skipped message has no change of its own. So:
  - step 4's count check catches a list that came out short, and lists it again;
  - any id seen in a label list or in a history label record but missing from the index is **placed** (§4.3), never ignored;
  - a listing never deletes anything by itself: in a resync, ids that a listing leaves out are confirmed one by one before they go (§4.4).
- **Resuming.** Each listing page goes into the journal as one self-contained record, with its chain's label and page token (§4.5). A quit or a crash resumes from the last page saved. Google's page tokens could expire; if one is refused, that chain starts again from the top, and ids already stored are skipped.

---

## 4. Change detection

### 4.1 When FalconMail checks

| State | Interval | Units a day |
|---|---|---|
| Awake and online, with the owner active in the last 30 minutes, whether FalconMail is in front or not (notifications matter most when another app is in front) | **30 s** | 240 an hour |
| Awake, with no input for 30 minutes or the screen locked | 2 min | 60 an hour |
| Asleep, or offline | none | 0 |
| Waking, a network change, Send & Receive, 2 s and 10 s after a message goes out, a pending change committed | at once, then back to the interval | |
| Paused by Google (rate limit, or a daily cap the owner set) | none until the retry time | |

- **Against Google's advice.** Google's server request limits page advises mail clients, which it names as IMAP and POP, to check about once every 15 minutes [S17]. Checking every 30 seconds goes well beyond that. It is kept because a check is one API call of 2 units; open question 1 offers once a minute while FalconMail is not in front.
- **One entry point.** `engine.poke(reason:)`. At most one check runs at a time, and a poke during a check schedules exactly one more.
- **What a check asks for.** Each check is `history.list(startHistoryId: cursor, historyTypes: messageAdded, messageDeleted, labelAdded, labelRemoved, maxResults: 500)`, paged to the end [S12].
- **Checks never wait behind scrolling.** Checks and the fetch of new mail are first in the account's queue (§11.1), so new mail still shows within the 35-second target during heavy scrolling.
- **New mail on waking.** A check runs at once on `NSWorkspace.didWakeNotification`. An `NWPathMonitor` change runs one as well, reusing the monitor in SyncCoordinator.swift:57-67. So mail that came in during sleep shows within a few seconds of opening the lid.

### 4.2 One check, step by step
1. **Collect the changes in history order,** and reduce them per message:
   - an id **added and deleted within the same check** is dropped: it is never fetched and never shown. Every draft autosave in Gmail on the web or the phone does this, and so do FalconMail's own draft saves;
   - label changes are applied in order, so the final labels win.
2. **Apply deletions and label changes straight to the index.**
   - A delete becomes a tombstone, which also removes the message from the cache.
   - A label change sets and clears bits.
   - A label change for an id **not in the index** means the index missed it (§3): the id joins the added ids and is placed in step 3.
   - None of this needs a fetch.
3. **Place the added ids** (§4.3).
   - A **404 on any fetch** for placing means the message was deleted meanwhile. It is journaled as a tombstone and never placed.
   - An id that cannot be placed now for another reason (a timeout, a pause) is journaled as **waiting to be placed**, and tried again on the next check. It never holds up the cursor, so one bad message can never stop new mail.
4. **Save.** The check's changes, then a cursor record holding the newest history id, go into the journal and are flushed together (§4.5).
5. **Tell the list.** The list gets a `ListDiff` (§5.2). A diff of more than 500 rows reloads the table from the new snapshot instead of animating the inserts.
6. **Refresh counts.** `labels.get` runs for labels whose bits changed, at most one call per label per minute.
7. **Handle new mail.** Mail that arrived now (§4.3) triggers notifications, rules and mutes (§4.7, §7.6).

### 4.3 Which mail is new, and where it goes

**In plain words:** a message is new when Gmail received it since the last check, by Gmail's own clock. Where it sits in the list does not matter. So imported mail, or a message dated years ahead, can never stop notifications.

1. **Fetch the added ids.**
   - Up to 10 in a check: `format=full` for each, in one batch (20 units each). That gives the labels, `internalDate`, size, attachment bit and the text.
   - More than 10: `format=minimal` for each (20), in batches of at most 10 parts, then `format=full` only for those that turn out to have arrived now.
2. **Arrived now** means all of these hold:
   - its `internalDate` is no earlier than the start of the last successful check, less 10 minutes. The 10 minutes cover a large message that Gmail took longer to scan, which can reach the history after a later one. After sleep, the last check was before the sleep, so mail that came in during sleep counts;
   - its `internalDate` is no more than a day ahead. An imported message dated 2037 is old mail, and can never make later mail look old;
   - FalconMail did not import it itself (§9.1);
   - during a flood, it is not dated before the flood began.
   - The times are Gmail's: FalconMail keeps the offset between the Mac's clock and the `Date` header of Gmail's answers, so a wrong Mac clock does not matter.
3. **Mail that arrived now** goes in above the current top of the order, in `internalDate` order among itself. Its text is already fetched, and it joins the newest 1,000.
4. **Other added mail goes deep.** `format=minimal` (if `full` was not already fetched) gives its `internalDate`; `messages.list q="before:<internalDate in epoch seconds>" maxResults=1` (5 units) gives the next older message, which is already in the index. The message goes in just above that one, with a midpoint order key. When a gap between keys is used up, the neighbours are renumbered, as journaled upserts. That is 25 units each, and it never notifies.
5. **Flood mode.** When more than 50 deep ids arrive in one check, or more than 200 within 10 minutes, **not counting FalconMail's own imports**, FalconMail:
   - stops fetching them one by one, and marks them provisional, so they are not shown yet;
   - treats it as another app importing (§1.3): its own use drops to at most 2,000 units a minute, background work to at most 500, and the filling of the newest 1,000 pauses;
   - every 30 minutes, and once when the flood ends, lists All Mail again, plus only the labels whose `labels.get` count has changed. The listing orders and labels every message in one pass: ≈ 1,200 units at 55,000 and ≈ 4,900 at 200,000. A 25,000-message olm2cloud import at 150 a minute takes about 2.8 hours, so it costs about 6 relistings, about 30,000 units at 200,000 *(estimate)*;
   - asks again only the date boundaries that have a newly placed message just above their anchor (§5.6), at 5 units each;
   - still shows real new mail at once, notifies as usual and runs rules on it, because the arrival test in step 2 runs on every check;
   - ends after 30 minutes without deep ids.

### 4.4 When the history is too old (HTTP 404)
Google keeps the change history for at least a week as a rule, but sometimes only for hours. An expired start point returns 404 [S5][S12]. When that happens:
1. `getProfile` gives H1. The journal records **`resyncBegin(H1)`**, and the cursor does **not** move yet.
2. Every list is fetched again, as in §3 step 3, chain by chain with journaled pages, and compared with the index:
   - new ids go in with their listed order;
   - every label's bits are replaced by its listing, except where a change of the owner's is still held (§7.5);
   - ids no longer listed are only **candidates** for removal. Each is confirmed with `format=minimal` in batches, where a 404 means gone; with more than about 200 candidates, a second listing confirms them instead. Only confirmed ids become tombstones, and only in the flush that holds `resyncEnd`.
3. That costs **≈ 1,200 units at 55,000 and ≈ 4,900 at 200,000**, plus 20 per candidate. Messages never change their content, so cached rows and bodies are kept.
4. **`resyncEnd` and a cursor record at H1** are saved in one flush, and `history.list(H1)` then applies whatever happened during the resync.
5. A launch that finds `resyncBegin` without `resyncEnd` starts the resync again, so the gap can never be skipped.
6. **New mail during a resync.** While the resync runs, and while a second 404 waits out the 6-hour limit below, there is no usable cursor. So every check lists the top of All Mail instead (100 ids, 5 units), fetches any id the index does not know, and applies the arrival test of §4.3. The status bar says "Checking {email} for changes". New mail keeps arriving and being announced.
7. At most one **full relisting** runs every 6 hours unless the owner asks for one. The limit never applies to finding new mail. The log gets `resync reason=history404 removed=n added=m units=u`.
8. **The same "list one label again" repair** fixes a label whose daily count check disagrees (§2.5), for the cost of that label alone.

### 4.5 A cursor that survives a crash
- **The index journal is the only place the cursor lives.** It holds two kinds of record:
  - **Change records** (upserts from history, tombstones, label-bit changes, "waiting to be placed", resync markers), followed by a **cursor record**. On load, change records are applied only **up to the last complete cursor record**. Anything after it is dropped, and the next `history.list` replays it.
  - **Listing pages**: one self-contained record per page, holding its chain, page token, ids and the bits to set, with its length and a checksum. A complete page is applied on load whether or not a cursor record follows. Listing pages only add records or set bits; they never remove anything.
- **Flushing.** Each check appends its records and then its cursor record, and flushes them together with `fcntl(F_BARRIERFSYNC)`, which keeps the writes in order.
- **Replaying is harmless:** a tombstone for an id already gone, or a label bit already set, changes nothing.
- **`state.json` never holds a cursor.** The cache is a projection of the index, as described in §2.4.
- **Test:** kill the process between any two writes of a check, a listing page or a resync, relaunch, and the state matches the fake mailbox with no delete and no label change missing.

### 4.6 Echoes of FalconMail's own changes
- **The owner's own changes come back.** A change the owner made returns as `labelAdded` or `labelRemoved`. A send returns as `messageAdded` with SENT, and a draft save as a delete plus an add.
- **They are applied in the same idempotent way.** A count moves only when a bit really flips, so nothing is counted twice.
- **The owner's change wins until Gmail confirms it** (§7.3). While a change is held or being sent, history records for its messages leave the labels that change touches alone. **Those skipped records are kept with the change.**
  - Once Gmail confirms the change, they are dropped, and the next check brings everything into line.
  - If the change ends without being sent (Undo within the window, a refusal, a 404), the kept records are applied then. With more than 50, FalconMail instead fetches `format=minimal` for those ids and takes their labels from Gmail. So a delete made on the phone while the owner's own delete of the same message was waiting is not lost when he presses Undo.
- **A sent message or saved draft goes into the index from Gmail's answer.** When its `messageAdded` arrives later, the id is already known and nothing is fetched again.

### 4.7 Notifications and sounds, as today
- **Announced as new mail** only when all of these hold:
  - it **arrived now** (§4.3);
  - it carries INBOX, and not SPAM or TRASH;
  - its `internalDate` is within the last 24 hours;
  - its From is not one of the owner's addresses: `AccountInfo.ownAddresses` (ReplyAddressing.swift:6-10) plus the Gmail send-as addresses from `users.settings.sendAs.list`, fetched once a day;
  - its conversation is not muted.
- **The event and the path are unchanged.** The engine sends `SyncEvent.newMessages(accountID:, folderID: <the Inbox FolderInfo id>, messages:)`, so `AppModel.announce` (AppModel.swift:682-686), `NotificationService.announce` (Notifications.swift:77-88), the per-account notification setting and the sound all work unchanged.
- **Clicking a notification, and its buttons.** Today `applyFromNotification` and `reveal(messageID:)` look the message up with `store.message(id:)` (AppModel.swift:724-757), which never finds a Gmail key, so every click would say "That message is no longer here". For Google rows both go through `ListSource.summary(for:in:)` with the account's Inbox view. The click selects the row, switching to Focused or Other when Focused Inbox is on, as Outlook does. Archive, Delete, Mark as Read and Flag go through the Gmail change path (§7.3). G7 owns this, and the scenario test clicks the notification and every button.
- **Rules** use the same test with a 48-hour window, and run during a flood too (§7.6).

| Moment | What the engine sends | What MailSoundGate (MailSounds.swift:86-122) does |
|---|---|---|
| New delivered mail in the Inbox | `.newMessages` | New message sound, through `announce` |
| Send & Receive | `.started`, then the check, then `.finished` and `.checked(foundNewMail:)`. It is true when that check announced new mail, or would have but for the owner's notification setting. | No new messages, once every account asked has answered with none |
| One failed check (timeout, 5xx, network) | `.health(.connecting)`, quietly | Starts a failure episode, silently |
| Still failing after 2 minutes, or needs signing in again, or blocked (Workspace admin policy, API off, client refused) | `.health(.offline(since:))`, `.needsSignIn` or `.blocked(reason)`, then `.error(sentence)` | Mailbox sync error, once the episode has lasted 60 s (unchanged) |
| Google asked FalconMail to wait (rate limit, bandwidth, a daily cap) **for more than 60 seconds** | `.health(.apiPaused(until:))` (**new case**). A shorter wait sends nothing, and the account stays `.online` | Nothing: it is a pause, not a failure, as `imapPaused` is today (MailSounds.swift:99-106, 185-189) |
| A check that recovers, applies changes, or was asked for | `.finished` | Ends the failure episode |
| A message goes out | Outbox `.sent` (unchanged) | Sent sound |

- **Why `.finished` is not sent after every check.** A check every 30 seconds must not make the status line flicker "Checking…". So `.started` is sent only for Send & Receive and on waking, and `.finished` only as the table says.

---

## 5. The list

**In plain words:** every message of every folder is in the list, in Outlook's look, and the Items count is the folder's real total. The scroll bar is the size of the whole folder. A row the Mac has not seen yet is drawn in grey for a moment, with its unread dot and flag already right, and fills in within about a second of the scroll stopping. Old mail never seen before fills about three screens a minute; past that a footer says it is loading. Nothing loads older mail in pages, and nothing says "Show more".

### 5.1 How the list is built

```
 ListController (@MainActor) ── MessageTableView (NSTableView; cell = NSHostingView<the fm-list-rows row, unchanged>)
      ▲ ListSnapshot (immutable, 24 B/row) · ListDiff · RowContentStore (LRU of 5,000 row models)
      │
 ListSource (protocol)  ── GmailListSource (actor ListIndex over GmailIndex + RowFetchScheduler)
                        └─ StoreListSource  (today's MailStore rows, for IMAP accounts: §13)
```

### 5.2 The shared interface (`Sources/FalconCore/Engine/ListSource.swift`)
```swift
public struct ListView: Hashable, Sendable {
    public enum Scope: Hashable, Sendable { case folder(UUID), allInboxes, search(UUID) }
    public var scope: Scope
    public var filters: Set<ListFilter>          // unread, flagged, attachments, focused, other, mentionsMe
    public var sort: ListSortSpec                // key + ascending
    public var conversations: Bool
    public var dateGroups: Bool
}
// Fields ordered largest first: size 23, stride 24. In the order key, slot, kind, members… it would be size 26, stride 32.
public struct DisplayRecord { var key: UInt64; var slot: Int32; var bits: UInt32; var members: UInt16; var unread: UInt16; var group: UInt16; var kind: UInt8 }
public struct ListSnapshot: Sendable { public let view: ListView; public let rows: ContiguousArray<DisplayRecord>; public let headers: [Int: String]; public let complete: Bool; public let itemCount: Int }
public struct ListDiff: Sendable { public let inserted: IndexSet; public let removed: IndexSet; public let reloaded: IndexSet; public let snapshot: ListSnapshot }
public enum RowAvailability: Sendable { case available(MessageSummary), gone, unavailable(reason: String) }
public protocol ListSource: AnyObject, Sendable {
    func snapshot(of view: ListView) async -> ListSnapshot
    func changes(of view: ListView) -> AsyncStream<ListDiff>
    func requestRows(_ keys: [RowKey], priority: RowPriority)        // fire and forget; rows arrive on `rows`
    var rows: AsyncStream<[RowKey: MessageRowContent]> { get }
    func summary(for key: RowKey, in view: ListView) async -> RowAvailability   // reply, forward, window, notification
}
```
- **A test** checks `MemoryLayout<DisplayRecord>.stride == 24`.
- **Gone or unavailable.** `summary(for:in:)` says `gone` only when Gmail answered 404 for the message. Offline, or while Gmail has paused FalconMail, it says `unavailable`, and a window stays open (§5.9).
- **The main thread never waits for a row.** `viewFor(row:)` is synchronous. It reads the snapshot's record and whatever `RowContentStore` holds, and never awaits.
- **Where the snapshot is built.** `ListIndex`, an actor in `Sources/FalconCore/List/ListIndex.swift`, builds snapshots off the main thread.
  - A view is a single pass over `byOrder` with one AND per record, and needs no sort. For 200,000 messages that is about 1–2 ms *(estimate)*.
  - Conversations are grouped with one hash-set pass. The hybrid design's bench grouped 200,000 in 41 ms.

### 5.3 Views, filters, Focused and Other, and All Inboxes
- **Folders.** A folder view is every message with that label, less SPAM, TRASH and CHAT, except in the Junk Email and Deleted Items views themselves. Archive (All Mail) is everything but those three.
- **Unread and Flagged** filters use the bits, so they cover every message. Today they cover only the loaded window (AppModel.swift:867-895).
- **Has attachments** uses the attachment bit. The first time it is used, the `has:attachment` listing fills that bit: about 20% of the mailbox divided by 100, in units.
- **Focused and Other** follow Gmail's categories:
  - **Focused** is the Inbox's Primary and Updates mail, and mail with no category. Updates holds order confirmations, shipping notices, bills and statements, which a freight business needs to see.
  - **Other** is the Inbox's Promotions, Social and Forums mail.
  - Settings ▸ Reading gains one line to move Updates to Other, for someone who prefers Gmail's own tabs.
  - **Move to Focused** and **Move to Other**, as in Outlook, change the category label (for example `−CATEGORY_PROMOTIONS +CATEGORY_PERSONAL`), which an app may do [S34].
  - The badge option "include only Focused messages" is enabled, now that the index gives exact counts (today it is disabled, NotificationsPane.swift:48-53).
  - This replaces the guess from the sender's name at AppModel.swift:881-892, as the hybrid design's open question 4 recommended.
- **All Inboxes** merges every account's Inbox by date:
  - **For rows whose date is known** (cached, or fetched this session), by that exact date. That covers every account's newest mail, because the newest 1,000 are cached.
  - **For older rows not yet fetched,** by a time worked out between date anchors (§5.6): to the day for the last month, and to the month before that.
  - **As such rows load,** they settle into their exact places. A row never moves while it is on screen; the move is applied to rows outside the visible range.

### 5.4 Conversations from Gmail's threads
- **Grouping.** A conversation row is every message of the view that shares a thread id. It sits where its newest member sits. This is exactly Outlook's conversation order, and it needs no dates.
- **The conversation row, as in the owner's Legacy Outlook screenshot:**
  - **The senders,** in order. They come, in this order of preference: from the conversation summary kept on the Mac (§2.4); from the cached rows and index bits, when every member is cached; from `RowContentStore`, when fetched this session; and otherwise from one `threads.get format=metadata` call (40 units) in the landing's batch. So conversations among the newest 1,000 and in the kept first screens paint from disk, at no cost, and offline.
  - A single message gets its row from `messages.get format=metadata` (20 units).
  - **The unread count badge** comes from the bits, with no fetch.
  - **The blue dot and blue subject** show while anything is unread.
  - **The attachment clip.**
  - **The date:** "Yesterday", `dd.MM.yyyy` or a time, as the row component formats it.
- **Expanding** shows compact one-line child rows: the sender and the date. That includes members in other folders, such as your replies in Sent, with the folder's Outlook name, as Outlook shows them. The same `threads.get` answer, or the kept summary, covers this.
- **Actions on a conversation row** act on the members that carry the view's label, by the rules of §7.1. Revision 1's separate "Delete Conversation" is dropped: v1.10.0 has no such command, the owner did not ask for it, and it would have trashed his own sent replies.

### 5.5 Sorting

| Sort (ListRows.swift:26-43) | How | Covers every message? |
|---|---|---|
| Date, either direction | `order` | yes |
| Flag status, read status | bits, then `order` | yes |
| Attachments | attachment bit, filled on first use, then `order` | yes |
| Size (Outlook's bands, ListRows.swift:94-102) | size band, from four `larger:` listings on first use (≈ 1,900 units at 200,000, once), then `order` | yes, by band |
| Account (All Inboxes) | account, then `order` | yes |
| Folder (Archive, search) | Deleted Items and Junk Email first, then the first label in sidebar order; a message with no folder label shows "Archive"; then `order` | yes |
| From, To, Subject (alphabetical) | text is needed, and fetching it for every message would cost 20 units each | **every row stays.** Rows whose text is known go into Outlook's sender (or recipient, or subject) groups at the top. The rest follow in one group, "Older messages, by date". Up to 200 more rows are fetched in the background for each sort. Footer: "Messages from before {date} are listed by date. Search to find mail from a sender." (open question 2) |

### 5.6 Date groups ("Show in groups")
- **When they are used.** They are off by default (`showInGroups`, AppModel.swift:314). The default is Conversations with no groups, which is the look of the owner's screenshot. When they are on, the headers match `ListSort.dayKey` (ListRows.swift:85-92): Today, Yesterday, Earlier this week, Earlier this month, and then one header per month.
- **Where a header goes.** The header for a boundary B goes before the first message older than B. That message is found with `messages.list(includeSpamTrash=true, q: "before:<B in epoch seconds>", maxResults: 1)` [S33], which costs **5 units per boundary** and needs no dates for any other message.
  - Anchors are account-wide. Each view places the header before its first member at or below the anchor's order.
  - Every monthly boundary back to the oldest message costs about 600 units for ten years. The oldest message's date comes from one `format=minimal` call on the last id of All Mail.
  - The four recent anchors are worked out again at local midnight, for 20 units.
  - **After a relisting or a deep placement,** only a boundary with a newly placed message directly above its anchor can have moved, so only those boundaries are asked again, at 5 units each. Revision 1 worked them all out again after every relisting.

### 5.7 The virtualised table, placeholders and fetching rows
- **The view.** `MessageTableView`, a new file `App/FalconMail/List/MessageTableView.swift`, is an `NSViewRepresentable` over `NSTableView`. It replaces `List(model.rows…)` (MessageListView.swift:174).
- **Hosting the row component unchanged.**
  - Each reusable `NSTableCellView` holds one `NSHostingView` of the row component that the `fm-list-rows` worktree is building in `App/FalconMail/Views`. When a cell is reused, only its `rootView` is set again.
  - The only thing this design asks of that component is that it be a pure function of the value it is given and of callbacks, with no `@Environment(AppModel.self)` reads for per-row state. Today's rows read `model.selectedMessageIDs`, `model.categories` and `model.isExpanded` (MessageListView.swift:333-341, 471-473). The table instead supplies `isSelected` from `NSTableRowView.isSelected`, and the expansion and categories from the row model.
  - `RowModelAdapter`, a new file owned by G4, turns `MessageRowContent` into that component's input type, so G4 adapts to whatever `fm-list-rows` delivers without editing it.
  - **Placeholders** are the same component, given a model with the bits already known and **fixed dummy text of typical length** for the sender, subject and preview. The host applies `.redacted(reason: .placeholder)`, which draws a grey bar in place of each piece of text; empty text would draw no bar at all. The quick-action buttons that appear on hover (MessageListView.swift:381) are hidden on placeholder rows, so nobody deletes a row he cannot read. The offscreen snapshot check covers placeholder rows.
  - The owner's screenshot of Outlook's message list shows his real mail and is kept outside the repo. It is used only to compare by eye, and is never copied into the repo or a test.
- **Row heights.** There are four fixed heights, answered at once from the record's kind:
  - a three-line row when the preview is on (`OL.listRow`);
  - a two-line row when it is off;
  - a compact one-line child row;
  - a date header of 30 pt.
  - A full sweep of the heights happens only on a full reload.
- **Fetching rows** (`List/RowFetchScheduler.swift`). From the visible range, missing keys are fetched in this order:
  1. the rows that are visible;
  2. one screen ahead in the scroll direction, once the scroll settles (100 ms with the speed below 3 screens a second). This is background work, ranked first among it.
  - Nothing is fetched during a fast fling. Requests not yet sent are dropped when their rows leave the window, and requests already in flight are shared by key.
  - A **landing** needs up to 25 rows, in one HTTP batch. It costs 20 units for each single message and 40 for each conversation not already known: **500 units if all are single messages, about 700 with 40% conversations, 1,000 if all are conversations**. It fills in about **0.8–1.2 s** *(estimate; G1 measures it)*.
  - Rows already in `RowContentStore`, the cache or a conversation summary cost nothing, so scrolling back is free.
- **The limit on scrolling through old mail never seen before.** The account's bucket holds 1,000 units and refills 2,000 a minute (§11.1). So:
  - the first landing after a pause always fills at once;
  - with 40% conversations, **about 4 landings fill in the first minute, and about 3 a minute after that**; with only single messages, 6 and then 4;
  - reading downwards through old mail at one screen every 20 seconds stays within budget;
  - jumping around faster leaves rows grey for up to about 20 seconds per screen. **As soon as rows are waiting on the budget,** a footer says "Loading more of {email}'s messages…", and it goes when they fill.
- **Offline, or paused by Google for more than a minute.** Grey rows could not fill, so the list shows only the rows whose text is known, in their order, followed by one footer line: "54,210 older messages are on Gmail. They'll show when you're back online." The Items count stays the folder's real total. In the reading pane, a message that is not on the Mac says "This message hasn't been downloaded. It will open when you're back online.", in Outlook's manner.

### 5.8 Selection at 200,000 rows
- **What is selected** is an `IndexSet` over the snapshot, taken from `NSTableView.selectedRowIndexes`, plus a form for "everything in this view except…". It is not a `Set<String>` of ids (AppModel.swift:151).
- **Select All in 200,000 rows** costs a few bytes.
- **An action on the whole view** is described by the view and a history id, not by 200,000 ids (§7.4).
- **Code that still uses `selectedMessageIDs`** (commands, the reading pane) gets the ids when 1,000 or fewer rows are selected. Above 1,000, every such command either hands over to the whole-view predicate (Move, Archive, Delete, Mark read or unread, Flag, Junk, Categorise) or refuses with "Select 1,000 messages or fewer for this command." It never acts on the first 1,000 and silently leaves the rest. A test selects 1,001 rows and runs each command.

### 5.9 Double-click: the message's own window, minimised to the tray
The owner asked (25 September) that a double-clicked message open in its own window, which minimises into the tray like a compose window. The `fm-windows` worktree builds that for every account (WindowTray.swift, Workspace.swift, MessageDetailView.swift). This design makes sure any Google row opens that way, reliably:
- **Opening.** The table's `doubleAction`, Return and ⌘O call `AppModel.openMessage(…)` with the row's key string (`"<account>:gm:<hex>"`).
  - **At once.** GmailOpener's 0.3 s wait is only for moving through the reading pane with the arrow keys; a window, Reply and Forward open without it (§6; E2 ships this early).
  - **By its key alone.** The window asks the engine for the summary and the message. A cached message opens from disk; any other message is fetched as in §6. Double-clicking a grey row opens the window at once, and it fills in when the text arrives.
- **A window closes itself only when the message is gone.** Today `fm-windows` dismisses a message window whenever `model.message(id:)` returns nil (fm-windows MessageDetailView.swift:429). For a Google message that is not cached, that would also happen offline or while Gmail has paused FalconMail. So for Google rows the window uses `summary(for:in:)`:
  - `gone` (Gmail answered 404): the window closes, and the status line says "This message was moved or deleted on another device.";
  - `unavailable`: the window stays open with what the index knows, and the sentence "You're offline, and this message is not kept on this Mac." It fills in by itself later.
- **Restored after a relaunch.** Each window goes into a new `gmailWindows` field in `session.json` (SessionState.swift) as `{rowKey, contextLabel, inTray, title}`, never into v1.10.0's `windows` or `fm-windows`' `trayMessageWindows` lists. So:
  - a downgrade never restores an empty window;
  - a window minimised to the tray comes back in the tray, with its title;
  - Archive and Move from a restored window know their folder (`contextLabel`; a window opened from a notification uses INBOX).
  - Today's filter, which leaves server-only rows out of the session (AppModel.swift:563), stays for the old search rows.
- **The tray chip's title** is updated when the message's text arrives. A window minimised before then would otherwise keep an empty title (WindowTray.swift:99-103).
- **Open windows refresh.** Every change the engine applies to an open message advances `openMessagesRevision` (fm-windows AppModel.swift:211), which open windows already watch.
- **The same message twice** brings its one window forward, keyed by `RowKey`.
- **A draft that is already being edited** in a compose window or tab is brought forward when it is opened again from Drafts, instead of opening a second editor on the same Gmail draft (§8.4).

### 5.10 Search
- **Google accounts.**
  - `messages.list q=` costs 5 units and returns ids newest first. The existing `GmailAccountSearch` (GmailSearch.swift:174-433) keeps its query building and paging.
  - Its resolution now produces **engine rows**, keyed by `RowKey`: their bits come from the index, their text from `RowContentStore`, the cache or one metadata batch for up to 25 rows. So **every result can be acted on**, and the read-only server rows (GmailSearch.swift:5-44, 84-94) go away for switched accounts.
  - **First results:** under 1 s at the 95th percentile. One list call takes ≈ 0.3 s and one batch of ≤ 25 rows ≈ 0.7 s *(estimate)*. The cost is at most ≈ 505 units, and less for rows already known.
- **As you type:**
  - the match is local over the loaded rows, instant and free;
  - after a 600 ms pause with 3 or more characters, FalconMail asks Gmail for the **matching ids only** (5 units) and shows those rows it already knows;
  - it fetches the text of the other rows on Return, or after 1.5 seconds without typing. So typing "freight invoice march" slowly costs a few 5-unit lookups, not three full searches of 505.
- **Offline, or while Gmail is paused,** search covers the term index of the cached 1,000, with the existing notice (GoogleErrorParser.swift:152-165).

### 5.11 The status bar
- **Items** is the number of messages in the view, taken from the index bits (in Conversations view too, as Outlook counts items). While a folder is still being listed, it is `labels.get`'s `messagesTotal`. Today it is `messages.count`, the rows loaded in memory (MainWindow.swift:154, OutlookCommands.swift:82), which is where the owner saw "only about 1,000". G4 owns it, and an acceptance test checks "Items: 200,000" on the large test mailbox.
- **Progress** goes in the status bar, where Outlook shows it, in FalconMail's existing words: "Syncing {email}: 12,000 of 55,000 messages".
- **"All folders are up to date."** shows only once every folder shown in the sidebar has been listed in full, and every account is reachable (MainWindow.swift:142-150).
- **"Connected to:"** keeps an account whose Gmail pause is under 60 seconds, and one in `.apiPaused`, since neither is offline (§10.2).

---

## 6. Opening messages and attachments
- **Cached (the newest 1,000):** from disk. LZFSE decodes a 100 KB body in well under 1 ms. It costs 0 units.
- **Not cached: two stages, into memory only.** The existing `GmailAPIClient.openText` and `withInlineImages` (GmailMessageContent.swift:152-179) do this.
  1. **Text first.** `format=full` costs 20 units and returns the headers and text parts; attachments come only as ids [S14]. A text part Gmail held back for its length is fetched with `attachments.get` if it is 5 MB or less (`longestWaitedText`, GmailMessageContent.swift:66). **The text shows now.**
  2. **Then the pictures.** Inline pictures of 100 KB or less that the HTML refers to by `cid:`. With two or more pictures and a message of 1 MB or less, one `format=raw` call (20 units) brings them all, read with `MIMEParser`. Otherwise each costs 20 units. At most 20 are fetched on their own; past that, a "Show all pictures" bar appears.
- **The 0.3 s wait only where it helps.** `GmailOpener` waits 0.3 s before any first open today (GmailMessageContent.swift:186-205), so a double-clicked window waits a third of a second before it even asks Gmail. The wait is kept only when the selection moves in the reading pane, where the arrow keys pass over rows nobody reads. Double-click, Return, ⌘O, Reply and Forward open at once. This is E2, which ships early (§14.2).
- **Attachments.** `attachments.get` is called only when an attachment is opened, saved, dragged, forwarded or shown in Quick Look, at 20 units each, with its bytes metered.
  - A cached message keeps its attachment's part id. If Gmail refuses a stored attachment id, one new `format=full` call (20 units) gets a fresh one.
  - *(Probe: whether attachment ids stay valid over time.)*
- **The whole message.** View Source, Save as .eml and Forward as Attachment use `format=raw` (20 units), held in memory only.
- **Large messages.** The text shows after the text parts alone, whatever size the attachments are.
  - **Sending limits are checked before upload.** Gmail accepts at most 25 MB of attachments in a message, measured before encoding [S18], and at most 35 MB for the encoded upload [S13]. A message over either is refused before anything is uploaded: "Gmail can't send more than 25 MB of attachments in one message. Remove some, or share them from Google Drive." FalconMail already has a Drive picker.
- **In memory** there is one body cache for the whole app, 64 MB, least recently used first. It replaces today's count-based `removeAll` at 200 (AppModel.swift:1274).
- **Nothing is written to disk** unless the message belongs in the newest 1,000.
- **Marking as read on opening** follows today's setting, and goes through the change path (§7): `modify −UNREAD`, 5 units.

---

## 7. Actions

**In plain words:** every change shows at once, can be undone for as long as it can today, and reaches Gmail as label changes. Each folder has written rules, so a move never asks Gmail for something it refuses and never removes a flag by accident. Up to 1,000 messages move in one call. If Gmail cannot be reached, the change waits on the Mac and is sent later, for up to 24 hours.

### 7.1 Outlook's actions in Gmail's terms

**Actions that do not depend on the folder**

| Action | Gmail API | Units | Undo |
|---|---|---|---|
| Mark read / unread | `−UNREAD` / `+UNREAD` | 5 per message with `modify`; 50 per 1,000 with `batchModify` | restores each message's own earlier state |
| Flag / unflag | `+STARRED` / `−STARRED` | same | same |
| Copy to folder X | `+X` | same | `−X` where it was added |
| Junk / Not junk | `+SPAM −INBOX` / `−SPAM +INBOX` | 5 or 50 | reverses it |
| Mute (Ignore) | `−UNREAD −INBOX` now; later arrivals in the thread get the same (§7.6) | 5 or 50 | Unmute |
| Move to Focused / Move to Other | change the category label (§5.3) | 5 or 50 | reverses it |
| Mark all as read in a view | the view's ids carrying UNREAD, in `batchModify` pages | 50 per 1,000 | none, as today |
| Outlook colour categories | local, keyed by the Gmail row id (open question 3) | 0 | as today |

**Archive, Move and Delete, by the folder they are used in** (V is the view the action was taken in)

| In this folder | Archive | Move to folder X | Delete |
|---|---|---|---|
| Inbox, or a search | `−INBOX` | `+X −INBOX` | `+TRASH` |
| A user label L | `−L` | `+X −L` | `+TRASH` |
| Archive (All Mail), Starred, Important | `−INBOX`; the flag and Important stay | `+X −INBOX`; the flag stays | `+TRASH` |
| Sent | greyed out | `+X` only. The row stays in Sent, and the status says "Moved to X. Gmail keeps a copy in Sent." | `+TRASH` |
| Drafts | greyed out | not offered | Discard: `drafts.delete` after the undo window (§8.4) |
| Junk Email | `−SPAM` (it goes to Archive) | `+X −SPAM` | `+TRASH −SPAM` |
| Deleted Items | `−TRASH` (it goes to Archive) | `+X −TRASH`; Move to Inbox is `−TRASH +INBOX` | delete for good, after asking (below) |

- **Move targets for a Google account.** Drafts and Sent are never offered, because Gmail refuses to add them [S34]; today the Move palette offers every selectable folder (AppModel.swift:1190-1193; MoveTargets.swift). Moving to **Archive** is the Archive action; to **Starred**, `+STARRED` with nothing removed; to **Deleted Items**, Delete; to **Junk Email**, Junk.
- **Delete puts the message in Deleted Items everywhere,** whichever folder it was deleted in, because Gmail's Trash takes it out of every label. v1.10.0 and Legacy Outlook over Gmail's IMAP do the same. Outlook's own per-folder delete would be "remove only this label"; which the owner wants is decision O4 (§15.3). The default is Deleted Items everywhere, as today.
- **Delete** is `+TRASH` with `batchModify`, since an app may apply TRASH [S34]. *(Probe: that it matches `messages.trash`, which costs 20 each; if not, `messages.trash` goes in HTTP batches.)* Undo is `−TRASH`, which gives the message back its other labels.
- **Delete for good and Empty Folder** (in Deleted Items and Junk Email) use `batchDelete`, which needs `https://mail.google.com/`, already granted (GoogleOAuth.swift:5) [S28][S29]. It cannot be undone, so:
  - it **always asks first, with the count**, from the sidebar's Delete All as well. Today the sidebar runs `purgeEverything` without asking (SidebarView.swift:110); only the menu command asks (OutlookCommands.swift:96-106);
  - just before deleting, FalconMail runs a change check and lists TRASH (or SPAM) afresh, and deletes only ids that are both in the index's view and in the fresh list. A message restored from Deleted Items on the phone a moment ago is therefore never deleted;
  - it deletes in chunks of 1,000, with a change check between chunks, and logs the counts.
- **Where V comes from.** It is read from the `ListSnapshot` the action was taken in, never from a stored summary. Test: open a message in label X, go to Inbox, archive it, and only INBOX is removed.
- **What each message really changes.** Deltas are worked out per message at the time of the action, by the table above: `add` is what the message lacks, and `remove` is only what it has, never STARRED or IMPORTANT unless the action is about them; for read and flag, only the messages whose state flips. The change stores these deltas, and Undo reverses only them.
- **Which call.** One to nine messages use `modify` per message. Ten or more use `batchModify` in chunks of 1,000 [S27].
- **Tests:** one `GmailActionTests` case for every cell of the table, and one for every move target.

### 7.2 Why no stored folder decides an action
A Google message is in many folders at once. A row cached while shown under label X and later archived from the Inbox must lose INBOX, not X. So `MessageSummary.folderID` for Google rows is filled in from the view when the summary is built (§2.1), and the action's context travels with the action.

### 7.3 Showing at once, Undo, and the pending-changes file
Each change follows the same steps as today (AppModel.swift:1288-1378):
1. **Show it.** The change is applied to the index bits at once, and a `ListDiff` goes to the list.
2. **Record it.** A `PendingGmailOp` is written to `Accounts/<id>/Gmail/pendingOps.json`:
   - its fields: `{id, kind, deltas: [GmailMessageID: (add, remove)], contextLabel, createdAt, knownAt: HistoryID, phase: held(until) | committing(attempt) | committed, wholeView: ViewPredicate?, skippedRecords}`;
   - v1.10.0 never reads this file, and Gmail changes never go into `pendingActions.json`.
3. **Hold it for the undo window** (`undoActionSeconds`). Undo during the window drops it, nothing is sent, and any history records it held back are applied (§4.6).
4. **Send it.**
   - Adding or removing a label is idempotent, so **any failure that might be temporary** is retried with backoff until it succeeds: a timeout, 5xx, being offline, a 429, and a **403 whose reason is a rate or quota reason** (`rateLimitExceeded`, `userRateLimitExceeded`, `dailyLimitExceeded`, `quotaExceeded`). Those wait for their retry time, or until midnight Pacific for a daily cap. They never undo the owner's change.
   - A **definite refusal** is handled by what it says:
     - a 404 on a message means it was deleted meanwhile, so that id is dropped;
     - a 404 on a label means the folder is gone, so the labels are reloaded and the owner sees "The folder “X” no longer exists";
     - a 400, or a 403 with a reason such as `domainPolicy`, `insufficientPermissions` or `forbidden`, puts the rows back and says why (§10.2).
5. **Undo after it was sent** reverses the stored deltas, as a new change.
6. **After a restart,** pending changes are sent again, **for at most 24 hours** after they were made, as v1.10.0 does (AccountSyncer.swift:176, 1951-1954). Older ones are dropped and their rows put back from Gmail's state.
   - **After a gap** (the Mac was off, or the owner went back to v1.10.0 for a while), each change is checked first: if the history since its `knownAt` touched any of its messages, that message is dropped from the change, because someone has acted on it since. If that history has expired, the change is dropped and the account is listed again (§4.4).
7. **At quit,** the undo window ends and pending changes are sent, with at most 5 s allowed, as `flushPendingActions` does today.

### 7.4 Actions on a whole view
"Select All" followed by an action, or "Mark all as read":
- is stored as `{view, predicate, knownAt}`;
- runs as its own class of work, capped at **1,500 units a minute** and giving way to anything the owner is waiting for (§11.1), with a progress line;
- 200,000 messages take 200 calls × 50 = **10,000 units, about 7 minutes**. The rows change on screen at once, and scrolling and opening carry on meanwhile;
- messages that arrive after `knownAt` are left alone.

### 7.5 When a history record and a pending change disagree
- **While a change is held or being sent,** history records for its ids leave its labels alone, and are kept with the change (§4.6). Listings and resyncs leave them alone too, so a row the owner has just archived never comes back while his change is on its way. This is today's `suppressedUIDs` idea, keyed by Gmail id.
- **Once Gmail confirms it,** the next check settles the state. Someone else's change in between, for example on the phone, then wins, as it would in Gmail.
- **If the change ends without being sent** (Undo, a refusal, a 404), the kept records are applied, so nothing done on another device meanwhile is lost.

### 7.6 Rules and mutes through the API
- **Which mail they act on.** Only mail that **arrived now** (§4.3) and carries INBOX: with an `internalDate` in the last 48 hours, not from the owner's own addresses. They run during a flood too, because the arrival test does not depend on it; imported mail never counts as arrived now.
- **How rules are checked.** Locally, with `RuleEngine` (RuleEngine.swift:72-112). A body condition uses the text that the `format=full` fetch of new mail already gave, so it costs nothing extra.
- **How their actions go.** As changes with no undo window, sent at once:

| Rule action | Gmail change |
|---|---|
| move to folder | `+label −INBOX` |
| copy | `+label` |
| mark read | `−UNREAD` |
| flag | `+STARRED` |
| delete | `+TRASH` |
| archive | `−INBOX` |
| stop | stops processing further rules |

- **Folders named in a rule.** A rule stores a folder path, which is resolved to a label by its name. System folders are resolved by role.
- **Cost.** 5 units per action, with no IMAP command anywhere.
- **Run Rules Now** (AppModel.swift:1955; AccountSyncer.swift:2153) runs over the Inbox's cached newest messages (open question 15).
- **Mutes** stay in `muted.json` (MuteStore.swift) as they are. New mail is matched to a muted conversation by its thread (`gm:<threadHex>`), or by its Message-ID and References against the record's `messageIDs`, which the `format=full` fetch of new mail already gives. Matched mail gets `−INBOX −UNREAD` and is not announced. **Unmute** removes every record of the account whose thread key or message ids match the conversation, so no twin record keeps it muted (§12.2).

### 7.7 Every path that acts on a Google account is routed
Today `AppModel.perform` skips any account that has no `AccountSyncer`, after the rows have already left the screen (AppModel.swift:1296), so an action nobody routed would look done and never reach Gmail. So:
- **Routed by engine:** `perform`, `createFolder`, `loadOlder`, `runRulesOnInbox`, imports, the archive job, notification actions (§4.7), and draft saving and discarding (§8.4).
- **New Folder** uses `labels.create` (5 units). Today it would say "is not connected yet" (AppModel.swift:1639-1646), and the IMAP path uses `createMailbox` (AccountSyncer.swift:2189).
- **Load older** is not shown for switched accounts, since every message is already in the list (AppModel.swift:1678-1690).
- **An account with neither engine** gives a visible error ("{email} isn't connected, so this wasn't done.") and the rows come back, instead of a silent skip.
- **Test.** The scenario test (§14.3, G7) records every action entry point and checks that each reached the fake Gmail.

---

## 8. Sending and drafts

### 8.1 Sending with `messages.send`
- **`GmailSender: MessageSender`**, a new file `Sources/FalconCore/Gmail/GmailSender.swift`:
  - it uploads to `https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=multipart`;
  - the upload has a JSON part `{"threadId": "<hex>"}` for a reply or forward, then a `message/rfc822` part holding the Outbox's `.eml` as `MIMEBuilder` built it (Outbox.swift:120-130), with an `X-FalconMail-Attempt: <attemptID>` header added;
  - the limits of §6 are checked before upload;
  - it costs **100 units**.
- **Bcc.** `MIMEBuilder` writes no Bcc header, and Gmail takes the recipients from the headers. So `GmailSender` inserts `Bcc:` from `OutboxItem.recipients` less To and Cc, on this path only. Gmail removes it from the delivered copies and keeps it in the sender's Sent copy. A test checks that the header is in the API upload.
- **Choosing the sender.** `RoutingSender`, a new file `Send/RoutingSender.swift`, chooses by the account's engine: `GmailSender` for switched Google accounts, and `SMTPSender` for every other account (SyncCoordinator.swift:165-219). **There is no SMTP fallback for a Google account** (open question 10).
- **Keeping replies in their conversation.** `ComposeDraft` gains `gmailThreadID`, taken from the replied message's key. In-Reply-To and References are already set by `ComposeDraft.reply`. The subject must match, up to its "Re:", as Gmail requires for threading.
- **The Sent row appears at once.** Gmail answers with `{id, threadId, labelIds}`.
  - The engine adds the record at the top, with those labels, before the Outbox marks the message sent.
  - Its cached body comes from the `.eml` that was just sent, at no cost. Its row and headers come from the `.eml` too if G1's probe finds that Gmail keeps FalconMail's Message-ID; otherwise from one `metadata` call (20 units), so the cached copy carries Gmail's Message-ID and later replies thread correctly.
  - Sent and the conversation update at once, and the echo in the history later changes nothing (§4.6).
  - v1.10.0's sync of Sent 5 s and 30 s after a send (AccountSyncer.swift:278-291) is not needed for switched accounts.

### 8.2 The Outbox, and never sending twice
The Outbox's behaviour stays as it is: the undo window, scheduled sending, `sendBegan` saved to disk before the first byte (Outbox.swift:180-238), and held items. `OutboxItem` gains optional fields only: `attemptID`, `messageID` (read from the `.eml`), `preSendHistoryID`, `gmailSentID`, `gmailDraftID` and `gmailThreadID`.

**The rule:** FalconMail looks in Gmail's records to **confirm** a send, never to permit sending again. A send it cannot confirm is held for the owner, as v1.10.0 holds an interrupted send (Outbox.swift:86-98).

1. **Before sending,** the Outbox saves `sendBegan`, a new `attemptID`, and **`preSendHistoryID`, the engine's current cursor**. That costs 0 units, and the cursor is never later than Gmail's own position.
2. **Gmail answers 200:** the message is sent, and `gmailSentID` is stored.
3. **A failure that provably came before the upload started** (no connection could be made, a DNS failure, offline, the token could not be refreshed) is retried by itself with backoff, because Gmail never saw the message.
4. **An answer that leaves it unclear** (a timeout after the upload began, a 5xx, a dropped connection), or an item found with `sendBegan` at launch:
   - about 30 seconds later, and again about 2 minutes later, FalconMail calls `history.list(startHistoryId: preSendHistoryID, historyTypes: messageAdded, labelId: SENT)`, then `metadata` for the few ids it adds (20 each), asking for the headers `Message-ID`, `X-Google-Original-Message-ID` and `X-FalconMail-Attempt`;
   - **any match means sent**; `gmailSentID` is stored;
   - **no match after both looks** means the outcome is unknown. The message is **held** for the owner with today's wording: "FalconMail stopped while this was being sent, so it may already have gone. Check Sent, then send it again or remove it." (Outbox.swift:98). It is never sent again without him.
   - Two reasons the check alone is not trusted to allow a resend: Google does not promise that `messages.send` keeps FalconMail's Message-ID (some reports say Gmail replaces it and keeps the original only in `X-Google-Original-Message-ID`), and Google says a send can be accepted and still be processed for minutes afterwards [S4]. *(Probe: whether `messages.send` keeps the Message-ID and a custom X- header.)*
5. **If that history has expired** (404): `messages.list q="rfc822msgid:<id> in:sent"`, once, and again 2 minutes later. Found means sent. Not found means **held**, as above.
6. **Limits.**
   - A 429 "User-rate limit exceeded (Mail sending)", or any sending-limit reason, holds the message until the retry time [S4][S18].
   - **A bandwidth 429 on the upload** is its own case: "Gmail has paused uploads for {email} until {time}; an import may be using the allowance. The message stays in the Outbox." (§1.3).
   - A refused address (400 on To, Cc or Bcc) fails it with "Gmail refused the address {x}."
   - A 200 means Gmail accepted it; a limit reached a little later shows up on later sends, or as a bounce in the Inbox [S4].
7. **Clearing out sent items.** A sent item is deleted 7 days after sending, **only once `gmailSentID` is known**.

### 8.3 Sending limits (Google's, for reference)
- **Workspace:** 2,000 messages a day, 10,000 recipients a day, and 500 recipients per message through the API [S18].
- **gmail.com:** 500 a day [S19].
- **The API shares these limits** with the web and the phone [S4]. FalconMail adds no limit of its own.

### 8.4 Drafts, and the owner's rule for closing and Discard (25 September)

**The rule:** *"When we start new conversation, or reply to any mail, there should be option Discard the message. By closing it, it stores into drafts."* The `fm-windows` worktree builds the Discard control and the new closing behaviour in the windows, for every account. For Google accounts, those windows call into `GmailDrafts` (a new file, `GmailEngine/GmailDrafts.swift`) through `AppModel.saveDraftToServer` and a new `discardDraft`, which are routed by the account's engine.

**Three safety rules, for every account.** The first two ship early, with `fm-windows`, as E1 (§14.2):
1. **The copy on the Mac is deleted only once the server has the draft.** Today `saveDraftToServer` sets `drafts[id] = nil` first, which deletes `<data>/Drafts/<uuid>.json` at once, and only then starts the save (AppModel.swift:1724-1727; unchanged in fm-windows AppModel.swift:1813-1815). If FalconMail quits or crashes before the server answers, the message is in neither place. Under the owner's new rule every close with content goes this way. So the local file stays until the save succeeds; for a Google account `gmailDraftID` is written into it first. At quit, FalconMail waits up to 5 seconds for draft saves in flight, as `flushPendingActions` does for actions. At launch, `saveLeftoverDrafts` (AppModel.swift:1760-1764) updates a draft that already has a `gmailDraftID` rather than creating another.
2. **Discard deletes the saved copy only after the undo window.** The local file goes at once, as `fm-windows` already does, and the content is held in memory for Undo. The copy in Drafts (a Gmail draft, or the IMAP row it was reopened from) is deleted when the undo window ends. A marker "discarded, delete pending" is written in its place, so a quit during the window finishes the delete at quit or at the next launch, and never saves the message back to Drafts. Undo cancels the delete and brings the window back **with its link to the saved copy**. Today `fm-windows` deletes the saved copy at once and clears that link (fm-windows Workspace.swift:106-113); Gmail's `drafts.delete` is permanent, with nothing kept in Deleted Items.
3. **A save never creates a second draft.** Every draft keeps one Message-ID for its whole life, and carries an `X-FalconMail-Draft: <draft UUID>` header in every save. At most one save per draft is in flight; a newer save waits and the latest content wins, so saves never finish out of order. Before retrying a `drafts.create` that timed out, FalconMail looks in the history since the save began for a draft carrying that header, and updates it if found.

| What the owner does | What Gmail is asked | Units |
|---|---|---|
| Closes a message with something written in it (window, tab, ⌘W, the × on a tray chip) | the first save is `drafts.create` with `message.raw` and `message.threadId`; later saves are `drafts.update` [S13] | 10, then 15 |
| Closes a message untouched since it opened, or blank | nothing, as today (UnsentMessage.swift:46-48). If this session's autosave had already created a Gmail draft for it, that draft is deleted, so no stray copy stays in Drafts | 0, or 10 |
| Save Draft in the compose title row | `drafts.create` or `drafts.update` at once. Today it only saves on the Mac (ComposeView.swift:346-349) | 10 or 15 |
| Keeps writing | an automatic save once a minute while the content changes (open question 14). Only on the Gmail engine; accounts still on IMAP keep today's behaviour | 15 a minute |
| Discard | the window closes at once. The Gmail draft, if one exists, is deleted with `drafts.delete` **after the undo window** (rule 2) | 10 |
| Opens a message from Drafts | the draft id comes from a map of message ids to draft ids (`drafts.list`, 5 units per 500, refreshed when DRAFT bits change). Later saves update that draft, never a second copy. If the draft is already open in a compose window, that window comes forward instead | 5, and 0 if the message is cached |
| Opens a draft saved before the switch | its old IMAP row's Message-ID is resolved to the Gmail draft id (`rfc822msgid:`, then the map), and later saves update that draft instead of creating one beside it | 5 |
| Deletes in Drafts | the same as Discard: `drafts.delete` after the undo window | 10 |
| Sends a draft | the Outbox sends with `messages.send`, then `drafts.delete` runs once the send is confirmed. `gmailDraftID` and `gmailThreadID` are kept in the `OutboxItem` and in the compose sidecar (ComposeDraft.swift:225-251), so this still happens after a relaunch, and Undo Send reopens the message with its draft and its conversation. This replaces the IMAP purge at AppModel.swift:1749-1755 | 100 + 10 |
| Offline, or Gmail paused | the save waits as a pending draft change, and the local file keeps the content (rule 1). **A provisional row appears in Drafts at once**, with the draft's subject, and the status says "Saved to Drafts. It goes to Gmail when you're back online." Double-clicking it reopens the copy on the Mac. Gmail's id replaces it when Gmail answers | |
| A save Gmail refuses with 404 (the draft was sent or deleted elsewhere) | `drafts.create` of a new draft, so the text is never dropped | 10 |

- **`ComposeDraft` gains optional fields** `gmailDraftID`, `gmailDraftMessageID` and `stableMessageID`, which an older build ignores.
- **Each save's answer goes into the index at once.** It gives the draft's new message id; the old one is removed. The history echo then changes nothing, and an add and delete within one check is dropped (§4.2).
- **The Drafts count** is the number of drafts, provisional ones included (§2.5). It is the owner's visible sign that closing saved his message.
- **Why not `drafts.send`.** Sending always goes through the Outbox, so Undo Send, scheduled sending and the check against sending twice work in one way for every message.
- **What these windows cost in a day:** 30 drafts × (10 + 2 × 15 + 10) ≈ 1,500 units.

---

## 9. Imports and the archive job

### 9.1 Importing .eml and .mbox files: `messages.import`
- **The call.** An upload to `https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/import?uploadType=multipart&internalDateSource=dateHeader&neverMarkSpam=true&processForCalendar=false`, holding:
  - JSON `{"labelIds": [<target label>]}`, plus INBOX when importing into the Inbox;
  - the raw message.
  - It costs 25 units, allows up to 150 MB per message, and the scope `https://mail.google.com/` is already granted [S10][S13].
- **Why `import` and not `insert`:**
  1. `import` puts the message through Gmail's normal delivery scanning and classification [S10]. An old mbox may hold malware, and Gmail's scan should see it. `insert` skips most of that, like an IMAP APPEND [S11].
  2. `neverMarkSpam=true` keeps imported mail out of Junk Email, which `insert` has no way to promise.
  3. `internalDateSource=dateHeader` sorts imported mail by its own date, not at the top of the Inbox.
  4. olm2cloud already imports into the same mailboxes with `import` (olm2cloud `GmailImporter.swift:155`), so both apps produce the same results.
  - One risk: Gmail may give imported mail categories, and so move it between Focused and Other. That is accepted, because it is Gmail's own view of the mail.
- **Read state.** Mail is imported as read, with no UNREAD label, unless the mbox's `Status:` header says otherwise (open question 7).
- **Placed at once, from Gmail's answer.** `messages.import` answers with the new message's id, thread id and labels, and FalconMail knows the date it uploaded. So each imported message:
  - goes into the index at once, and shows in its folder straight away, so the owner never sees an import finish with nothing in the folder;
  - is placed next to the message found by one `before:` query for each distinct day in the batch (5 units a day), which is exact to the day. A relisting of All Mail when the import ends (and once a day during a long one) puts every imported message in its exact place;
  - is written to the account's **import log** (`Gmail/imports.json`, ids only, kept 7 days), so its echo in the history is known: it never counts as new mail, never starts flood mode, and never runs rules or notifications.
- **Pacing, by units and by bytes.**
  - At most 60 imports a minute (1,500 units), as background work.
  - Imports stop at **300 MB of upload a day**, keeping 100 MB of FalconMail's 400 MB for sends and drafts (§11.2).
  - **So an import's time is whichever is longer, the units or the bytes.** At 75 KB a message, 10,000 messages are 750 MB, which takes about 2.5 days; the units alone would take about 2.8 hours. As a rule, **about 3½ days per GB**. The import sheet says so before it starts, shows progress, and resumes where it stopped.
  - 10,000 messages cost about 250,000 units, which is 0.3% of the project's day.
  - There is no sync after each message, as there is today (AccountSyncer.swift:2032-2098).
  - The old dates mean no rules and no notifications run.

### 9.2 The archive job (to Drive or the Mac)
- **One job, two sources.** `ArchiveSource` (ArchiveJob.swift:38-55) becomes a protocol with two implementations: the IMAP one for other accounts, and `GmailArchiveSource`, a new file.
- **Listing.** For each chosen folder, `messages.list(labelIds: [label], q: "before:<epoch seconds>")` gives the ids, at 5 units per 500 [S33].
- **Downloading.** Each message comes as `format=raw` (20 units, about 4/3 of the message's size) and goes to `ArchiveWriter.add`, with flags from the index bits.
- **Pacing.**
  - At most 60 messages a minute (1,200 units).
  - The bytes count against the **background API download budget of 800 MB a day** (§11.2).
  - 10,000 typical messages come to about 1 GB, so about 1–2 days, with progress shown and resuming where it stopped.
- **"Remove from Gmail after archiving"** does what v1.10.0's IMAP expunge does on Gmail: it takes the message out of **the archived folder only** (ArchiveJob.swift:131-150 expunges in that folder, which on Gmail removes only that label).
  - Archiving a user label X removes `X`; archiving the Inbox removes `INBOX`. The message stays in Archive (All Mail) and in its other folders.
  - Only archiving Archive (All Mail) itself moves messages to Deleted Items (`+TRASH`), where Gmail deletes them for good after 30 days. The sheet says so in that case.
  - Messages are removed only after their part of the archive is safely written or uploaded, in `batchModify` pages of 1,000 at 50 units. Nothing is deleted for good.

---

## 10. Setting up an account, and its health

### 10.1 Adding a Google account
- **Signing in** works as today (AppModel.swift:1858-1878). Then:
  1. **`getProfile`** (1 unit): the address must be the one that signed in.
  2. **The granted scopes.** The token's `scope` must include `https://mail.google.com/`. Google's consent screen lets people untick boxes. If it is missing: "FalconMail needs permission to read and send mail for {email}. Sign in again and leave every box ticked."
  3. **`labels.list`** (1 unit) gives the sidebar.
- **No IMAP and no SMTP check.** `AccountProbe.test` (AccountProbe.swift:56-73) stays for other accounts only.
- **A custom account whose server is `imap.gmail.com` or `smtp.gmail.com`** (an app password):
  - a new one is not added as IMAP; the sheet offers "Sign in with Google" instead (open question 17);
  - an existing one, added before the release (AddAccountSheet suggests imap.gmail.com for gmail.com addresses), stays on IMAP until the owner signs in with Google. Settings ▸ Accounts shows a line for it: "{email} uses Gmail through IMAP. Sign in with Google to use the Gmail API." Every IMAP connection it makes is logged (§12.5), so the daily report shows it.

### 10.2 Status sentences (GoogleErrorParser.swift and MailServiceError.swift)
Every refusal is classified from its HTTP status and Google's reason code, never from its text (GoogleErrorParser.swift:105-118). `FalconError.protocolError` is never raised for a Google account, so "Protocol error" cannot appear for one. New reason codes are added to the parser: `domainPolicy`, `failedPrecondition`, a sending-limit 429, a bandwidth 429 (told apart for downloads and uploads), `payloadTooLarge`, and a 404 during history, which means the history has expired. **A 403 is sorted by its reason:** rate and quota reasons are temporary and wait; the rest are definite (§7.3).

| Condition | Status line (per account) | What FalconMail does |
|---|---|---|
| Rate limited (429, or 403 `rateLimitExceeded` / `userRateLimitExceeded`) | nothing for the first minute, then "Waiting a moment before loading more of {email}'s messages." | the limiter backs off; `.apiPaused(until:)` only once the wait passes 60 s |
| A daily cap the owner set on the project (403 `dailyLimitExceeded` / `quotaExceeded`, §1.4) | "Today's Gmail allowance for FalconMail is used up until {time}. Mail on this Mac stays available; changes you make are sent then." | holds everything until midnight Pacific (GoogleErrorParser.swift:177-182) |
| Its own download budget, or a download bandwidth 429 | "FalconMail has paused downloading older mail for {email} until {time}, to stay within Gmail's daily limit. New mail still arrives." | background stops; work the owner asks for continues until the hard stop |
| An upload bandwidth 429 (on a send, a draft save or an import) | "Gmail has paused uploads for {email} until {time}; an import may be using the allowance. The message stays in the Outbox." | the Outbox, draft saves and imports wait until the retry time |
| Token revoked or expired (`invalid_grant`, or 401 after one forced refresh) | "{email} needs you to sign in again." [Sign In] | `.needsSignIn`; no retries |
| Client refused (`unauthorized_client`, `admin_policy_enforced`, `access_denied`) | "Google didn't accept FalconMail's sign-in for {email}. Sign in again; if it keeps happening, the Workspace administrator may need to allow FalconMail." | `.blocked` |
| Workspace admin turned off apps (403 `domainPolicy`) | "The Workspace administrator has turned off Gmail access for apps like FalconMail for {email}." | `.blocked`; checked again once an hour |
| Gmail not enabled for the user (400 `failedPrecondition`) | "Gmail isn't turned on for {email}." | `.blocked`; checked again once an hour |
| Gmail API off for the project (`accessNotConfigured`) | "Gmail API is off for this build's Google project." | `.blocked`; checked again every 10 minutes, as today (GmailQuotaLimiter.swift:105-112) |
| Scope missing (`insufficientPermissions`) | as in §10.1 step 2 | `.needsSignIn` |
| Offline (URL errors) | "Offline — showing the messages kept on this Mac." | checks resume when the network path is usable |
| Temporary (5xx, `backendError`, timeout) | nothing for 2 minutes, then "Reconnecting to {email}…" | backoff (§11.1) |
| Message gone (404 on a message) | for something the owner did: "This message was moved or deleted on another device." | the row is removed after a `minimal` check (20 units) |
| Folder gone (404 on a label) | "The folder “{name}” no longer exists on the server." | labels reloaded |
| Sending limit, refused address, too large | §8.2, §6 | Outbox |

- **The new health case.** `AccountHealth` (MailServiceError.swift:210-236) gains **`.apiPaused(until:)`**:
  - the engine sends it only once a pause has lasted, or will last, **more than 60 seconds**. Shorter waits stay `.online`, so the frequent short waits of a first day never make the status bar flicker;
  - `isFailing` is false, as for `.imapPaused` (MailSounds.swift:185-189);
  - it is **not** shown as offline. Today `AppModel` sets `online[id]` from `isReachable` straight away (AppModel.swift:642-644), and the sidebar shows the offline icon for any case it does not name (SidebarView.swift:141-147). So `.apiPaused` gets the hourglass icon in the sidebar, the account stays in "Connected to:" (MainWindow.swift:142-150), and `AppModel.pausedAccountNotices` (AppModel.swift:246-255) gains the case and shows its sentence;
  - G3 adds a test: a 30-second Retry-After changes no health state.
- **Tokens.** The token is refreshed about 5 minutes before it expires, once per account however many ask (`tokens.keepFresh`, SyncCoordinator.swift:126). `OAuthToken.clientID` (OAuthToken.swift:11) keeps refreshes on the client that issued the token.

### 10.3 Diagnostics
- **A new area, `gmail`,** in the redacted reports. Its codes are the `GoogleAPIError.Kind` values plus `historyExpired`, `floodMode`, `resync`, `imapBlocked`, `imapUsed` (§12.5), `sendUnconfirmed`, `sendHeld`, `draftSaveFailed` and `uploadPaused`.
- **Plain titles** go in `DiagnosticsTitle.specials` (DiagnosticsSignature.swift:313-331). For example:
  - `gmail.rateLimited`: "Gmail asked FalconMail to slow down";
  - `gmail.historyExpired`: "Gmail's change list had expired, so FalconMail listed the mailbox again";
  - `gmail.imapBlocked`: "FalconMail tried to use IMAP for a Google account and was stopped";
  - `gmail.imapUsed`: "A Google account still uses IMAP";
  - `gmail.uploadPaused`: "Gmail paused uploads for an account".
- **The daily health report** adds, for each account:
  - units used, rounded to thousands, and the project's total for the day;
  - the number of 429 and 403 answers, by reason;
  - checks, resyncs, flood-mode hours, and API MB down and up;
  - IMAP and SMTP connections to Google's hosts, which should be 0 for switched accounts.
  - It never includes subjects, addresses or text. The redactor already removes folder names, so label names go in `names:` as they do today.

---

## 11. Rate limiting and bandwidth

### 11.1 `GmailQuotaLimiter`, extended (GmailQuotaLimiter.swift)
- **Every method with its price.** `GmailMethod` gains every call used here, with the prices of §1.2.
  - **This fixes a bug:** `attachmentsGet` is priced at 5 (GmailQuotaLimiter.swift:10), but Google now charges 20 [S1]. This is E3, which ships on its own (§14.2).
- **The budget: a token bucket per account.** Today's limiter keeps a one-minute ledger, which lets a single call into an empty minute and makes a call wait until the oldest booking is a minute old (GmailQuotaLimiter.swift:73). That lets background work spend the whole minute in its first seconds, and then leaves a click waiting up to a minute. It is replaced by a bucket that:
  - **refills 2,000 units a minute** (about 33 a second) and **holds at most 1,000**, so no 60-second window ever passes **3,000**, v1.10.0's figure and half of Google's shared 6,000 (§1.3);
  - after a 429 or a 403 rate reason, honours the retry time, halves its refill (never below a quarter), and recovers by a tenth a minute, as today (GmailQuotaLimiter.swift:89-100);
  - in flood mode (another app importing, §4.3), refills at most 1,500 a minute and holds at most 500, so FalconMail stays at or below 2,000 in any minute.
- **Classes of work, in order of priority:**
  1. **checks and new mail:** `history.list`, the fetch of mail that arrived, and the look at the top during a resync. First in the queue, so scrolling never delays new mail;
  2. **interactive:** visible rows, opens, attachments, actions, sends, drafts and search;
  3. **bulk:** actions on a whole view, at most 1,500 a minute (§7.4);
  4. **background**, ranked: the screen ahead of the scroll, then the newest 1,000 and conversation summaries, then the index and anchors, then imports and the archive job. Background work takes units only when nothing of a higher class is waiting, and never takes the bucket below 500, so a click always finds units. While the owner has done something in the last 10 seconds, background uses at most 1,000 a minute.
- **Batches are counted part by part.** A batch books the sum of its parts before it is sent, because Google counts n parts as n calls [S3].
  - A batch holds at most 25 parts for a screen of rows, 10 for `format=full` or `raw`, and **10 for background work**.
  - Refused parts are not refunded.
  - Parts may be answered in any order, and are matched by `Content-ID` [S3].
  - **The batch address is a probe item.** The batch guide gives `https://gmail.googleapis.com/batch/gmail/v1` and the discovery document gives `https://gmail.googleapis.com/batch` [S3][S13]; G1 finds which answers before anything depends on it.
- **How many at once.** Google does not publish its per-user limit on requests at the same time, and all of the user's clients share it; Google says large batches can trigger it [S4]. So:
  - per account, at most **4 HTTP requests in flight**, of which background work may hold at most 2, so 2 are always free for a click;
  - per account, at most **35 batch parts in flight**: 25 for one screen of rows and 10 for background work;
  - after a "Too many concurrent requests" 429, both part limits halve (to 12 and 5) for 10 minutes. Revision 1 dropped to 2 connections, which could still carry 50 parts;
  - across all accounts on the Mac, at most 8 background requests in flight, so five new accounts share the network. There is no Mac-wide limit on units: Google has none per install, and each account's bucket already bounds it. Revision 1's guard of 12,000 a minute across accounts would have made every account's clicks wait behind the others' first-day work;
  - G1's probe never looks for this limit on the owner's account, since that would cause the very refusals the design avoids.
- **Other refusals:**
  - **5xx or `backendError`:** Google's backoff, `min(2ⁿ s + up to 1 s at random, 64 s)`, waiting at least 1 s before the first retry. A change the owner made retries without end at 64 s intervals, within its 24 hours (§7.3). A read gives up after 5 tries and says so [S4].
  - **A daily cap the owner set:** everything is held until midnight Pacific. **API off:** held for 10 minutes. This keeps today's behaviour (GmailQuotaLimiter.swift:102-112).

### 11.2 `TrafficMeter`, counting API bytes (TrafficMeter.swift)
- **What is counted.** `GmailAPIClient` counts the bytes of every request and response under the account, in new optional `apiDown` and `apiUp` fields of each hourly bucket. An older build reads the file and ignores them.
- **The budgets** (new `TrafficLimits.api`), over a rolling 24 hours:

| Budget | Limit | What happens past it |
|---|---|---|
| Background downloads (cache fill, index, archive job) | 800 MB | background work pauses |
| All downloads | 1,500 MB (60% of the inferred 2,500 [S4][S16]) | only change checks continue |
| Imports | 300 MB up | imports wait until the rolling day has room |
| All uploads (sends, drafts, imports) | 400 MB (80% of the inferred 500) | sends and drafts still go; Google's own refusal, if it comes, is handled as in §1.4 |

- **FalconMail's meter cannot see olm2cloud's bytes,** which share Google's allowance (§1.3). That is why imports keep 100 MB clear for sending, and why olm2cloud should cap its own uploads (decision O1).
- **A typical day** uses about 50–60 MB down: changes, new mail, opens, 30 attachments and search.

### 11.3 What the owner sees while FalconMail waits
- **In the list:** the rows already shown stay; grey rows stay grey, with a footer that gives the sentence and the time (§5.7). Offline, or paused for more than a minute, only rows with text are shown, with one footer line.
- **Opening a message** that is not cached: "Waiting a moment for Gmail. This message opens by itself." It opens when the wait is over.
- **Actions** show as usual and wait in `pendingOps.json`.
- **Sending** waits in the Outbox as "Waiting for Gmail".
- **The status bar** gives the account's sentence (§10.2). There is no sound, because a pause is not a failure.

---

## 12. Moving from v1.10.0's IMAP store

**In plain words:** switching an account keeps everything the owner made on this Mac (the Outbox, drafts, categories, mutes, rules, signatures and contacts) and leaves the old IMAP copy untouched. So v1.10.0 can take the account back at any time. An account switches only once its waiting IMAP actions have reached Gmail, so nothing he deleted or moved comes back. After the switch, a test proves that no IMAP or SMTP connection is ever opened for that account.

### 12.1 The switch
- **Where it lives.** `Pref.gmailEngine.<accountID>`, shown in Settings ▸ Accounts as "Use the Gmail API (recommended)".
- **Its default.** On for Google accounts added after the release.
- **Existing accounts are switched as part of the release, in stages** (open question 11): first the owner's test account; then his own main account after 7 days with no data problem in the daily report; then the others, one at a time, when he says so. Until an account is switched it stays on IMAP, as today, and the daily report shows it (§12.5).
- **Order of the switch, per account:**
  1. **Pending IMAP actions go first.** Everything in `pendingActions.json` for the account is sent through the old engine. This is the account's last IMAP use.
     - **If they cannot all be sent**, for example because the Mac is offline, **the account is not switched.** It stays on IMAP, and Settings says why: "{email} has changes waiting to reach Gmail. It will switch once they have gone." The switch is tried again when the network is back.
     - Revision 1 translated such actions to Gmail ids instead. That cannot work: for archive, move and delete, v1.10.0 removes the row from its folder store before the server command runs, and a pending operation holds only UIDs and a folder id (AccountSyncer.swift:1826-1838; MailAction.swift:16-26). So exactly the destructive actions could not be resolved, and the mail would come back.
  2. **`AccountSyncer` stops** for the account, and `GmailAccountEngine` starts. The first screen shows in about 1.5 s (§3).
  3. **Local state is re-keyed** (§12.2), in the background, in batches of 50.
  4. **The account's Spotlight entries from the old store are removed;** the cached 1,000 are indexed again as they arrive (§2.4).
  5. **The old store is left as it is,** read-only (§12.3).

### 12.2 What is kept, and how it is re-keyed to Gmail ids

**Matching by Message-ID, safely.** Some senders reuse a Message-ID, and imports can duplicate one. v1.10.0's search already guards against this: it trusts a Message-ID only if it is usable (not `<>`, and with a domain), and only when the subject or date also agrees (`usableMessageID` and `sameMessage`, GmailSearch.swift:363-375). Re-keying uses the same two checks. If more than one message still matches, nothing is guessed.

| Kept on this Mac | Where | How it moves |
|---|---|---|
| Pending server actions | `pendingActions.json` (MailAction.swift:49-95) | sent before the switch; the account does not switch until they are (§12.1) |
| Outbox items, and local drafts | `Outbox/`, `Drafts/`, the session's drafts | not tied to a message; unchanged. A draft opened from an old IMAP row is resolved to its Gmail draft when opened (§8.4). `ComposeDraft.sourceMessage` keeps its old id; when opened, it is resolved by Message-ID with the checks above, and if that fails the draft opens as a new one |
| Outlook colour categories | UserDefaults `mailCategoryAssignments`, keyed `acc:folder:uid` (OutlookCommands.swift:54) | for each key: the stored summary gives its Message-ID; `messages.list q="rfc822msgid:<id>" includeSpamTrash=true maxResults=5` (5 units) gives candidates, checked with `sameMessage`; a new key `acc:gm:<hex>` is **added** for a single match. **Old keys are kept.** Keys with no match, or with more than one, go into a `legacy` map, are not applied, and are never deleted |
| Muted conversations | `muted.json` (MuteStore.swift) | **not rewritten.** Each record keeps one `threadKey` (MuteStore.swift:3-10), and adding a second record for the same conversation would make Unmute leave its twin behind (MuteStore.swift:50-55, 70-83). New Gmail mail is matched to the existing records by Message-ID and References instead (§7.6), and Unmute removes every matching record |
| Flags and read state | on Gmail already (STARRED, UNREAD) | nothing to move |
| Signatures, rules, notification settings, contacts, recent move targets | keyed by account, address or folder UUID | unchanged. Folder UUIDs are reused by role and path (§2.2), so rules and move targets still point to the same folders |
| Open windows and tabs | `session.json` | re-keyed by Message-ID, with the checks above, into the new `gmailWindows` field (§5.9) |

- **`session.json` keeps v1.10.0's entries.** The new build rewrites `session.json` from its own open windows on its first save (AppModel.swift:561-571), so "the old entries stay" does not happen by itself. The new build therefore **carries the old entries forward untouched**, and keeps `acc:gm:` keys out of v1.10.0's fields (`windows`, `openTabs`, `minimizedTabs`, `activeTab`, `selectedMessageIDs`, and `fm-windows`' `trayMessageWindows`). Google windows and tabs go only into new fields.
- **Cost.** Usually a few hundred lookups at 5 units each, so under 2,000 units, run in the background.
- **Progress** is saved in `Gmail/migration.json`, so a relaunch carries on.
- **Why nothing is taken from the old cache.** Seeding the newest 1,000 from the old `.eml` bodies would save about 15 units per message. But it needs a Message-ID lookup for each one, and it would carry v1.10.0's unbounded cache forward. It is left out, for simplicity (Appendix A).

### 12.3 What is not used, and when it goes
- **Not used by the Gmail engine:** the old folder stores (`index.plist`, `terms.plist`, the `.eml` bodies), `folders.json`, `syncExtras.json` and the old Spotlight entries. The engine never writes `folders.json` or any folder directory (§2.2).
- **They stay on disk, untouched.** Settings shows "Remove the old copy of {email} ({size})" once the account has run on the Gmail API for **14 days in a row with no switch back**. It is deleted only when the owner confirms.

### 12.4 Going back to v1.10.0 loses nothing

| What | What v1.10.0 finds |
|---|---|
| The account in `accounts.json` | unchanged: the same provider, hosts and id. v1.10.0 does not know the switch, and starts its IMAP engine from its own saved position; its newest-first catch-up closes the gap |
| The old IMAP store | exactly as it was before the switch, since the engine never writes it (§2.2) |
| Mail changed under the new build (read, flagged, moved, deleted) | it is on Gmail; v1.10.0's next pass and its flag check pick it up |
| Drafts saved under the new build | in Gmail's Drafts, which v1.10.0 lists over IMAP |
| Messages sent under the new build | in Gmail's Sent |
| The Outbox | the same files; the new optional fields are ignored (Swift's decoder skips unknown keys) |
| Local drafts | the same files; `gmailDraftID` is ignored |
| Categories and mutes | the old keys and records are still there, and mutes were never rewritten |
| `session.json` | the old entries, carried forward untouched; `gmailWindows` is ignored |
| `Gmail/` (index, cache, `pendingOps.json`) | ignored; kept for the next upgrade |
| A change made offline just before going back | kept in `Gmail/pendingOps.json`. On the next upgrade it is sent only if it is less than 24 hours old **and** nothing has touched its messages since (§7.3). If v1.10.0 changed the account meanwhile, the new build says "Changes made before you went back to an earlier FalconMail were not sent, because the mail has changed since." and drops them. Changes are sent at quit whenever Gmail can be reached |

- **Going back and then forward again.** v1.10.0 writes ComposeDraft files and Outbox items back without the new fields (AppModel.swift:298-305; Outbox.swift:226-236). A draft saved under v1.10.0 is appended over IMAP, and would then be created again by `drafts.create`, so it would appear twice. So after an upgrade, a draft with no `gmailDraftID` is first matched to an existing Gmail draft by its `X-FalconMail-Draft` header or its stable Message-ID, and updated if found. A fixture test goes back and then forward.

### 12.5 Proof that no IMAP or SMTP connection is ever opened for a switched Google account
1. **Routing.** `SyncCoordinator.start(account:)` (SyncCoordinator.swift:117-127) creates a `GmailAccountEngine` for a switched Google account and **never** an `AccountSyncer`. `RoutingSender` never calls `SMTPSender` for it. `FileImport` and `ArchiveJob` take their source from the engine. Every action path is routed (§7.7).
2. **A guard, by host.** `TransportGuard`, a new file `Sources/FalconCore/Sync/TransportGuard.swift`, knows Google's IMAP and SMTP hosts (`imap.gmail.com`, `smtp.gmail.com`, and the `googlemail.com` names) and the set of switched accounts' addresses. `IMAPClient.connect`, `SMTPClient.connect` and `AccountProbe`'s client all ask it, with the host and the user name they will log in as, since `SMTPClient(host:port:)` and the probe's `IMAPClient` carry no account (SMTPClient.swift:37; AccountProbe.swift:23-24, 57-65).
   - For a switched account it throws `MailServiceError(.local, "IMAP is not used for Google accounts")` and logs `gmail.imapBlocked`.
   - For any other account it lets the connection go and logs `gmail.imapUsed`, once per account per day. So the daily report shows every account that still uses IMAP with Google, including custom accounts set up with an app password.
3. **The test** (`Tests/FalconCoreTests/ZeroIMAPTests.swift`, work item G7):
   - A switched Google account runs against `FakeGmailURLProtocol`, with `FakeIMAPServer` listening on loopback, an `IMAPConnector` spy and an SMTP `deliver` spy (SyncCoordinator.swift:176-182).
   - The script: add the account, backfill, a check with new mail, Send & Receive, waking, a network change, opening, an attachment, every action from every folder with undo, New Folder, a rule firing, a mute and unmute, search, clicking a notification and each of its buttons, sending, drafts (save, update, discard, send), an .mbox import, an archive job with removal, a history 404 and resync, a flood, relaunch, and turning the switch off and on again.
   - **It asserts:**
     - `FakeIMAPServer.peakConnections == 0` and `loginCount == 0` (FakeIMAPServer.swift:315-317);
     - both spies were called 0 times;
     - `TransportGuard` refused nothing, because nothing tried;
     - every action entry point reached the fake Gmail (§7.7).
   - A second test switches the account off, and asserts that pending Gmail changes were sent first, that IMAP connects again, and that nothing under `Gmail/` was deleted.

### 12.6 Turning the switch off
- **Pending Gmail changes are sent first.** Otherwise v1.10.0's IMAP sync would bring back mail the owner had just deleted.
- **If they cannot be sent,** for example offline, the switch refuses to turn off and says why: "{email} has changes waiting to reach Gmail. Try again when you're online." This mirrors §12.1 step 1.
- The `Gmail/` folder is kept for the next time.

---

## 13. Accounts that are not Google

- **They are unchanged.** `AccountSyncer`, `FolderStore`, `SMTPSender`, the Phase 0 fixes, the IMAP archive job and the imports all stay as in v1.10.0. The early fixes E1 and E2 (§14.2) apply to every account.
- **The UI is shared through `ListSource`.** `StoreListSource`, a new file `App/FalconMail/List/StoreListSource.swift`, serves today's `MailStore` rows through the same interface:
  - a snapshot is the folder's stored rows, in the existing thread and sort code (ListRows.swift);
  - rows are all known at once;
  - diffs come from `StoreChange.messagesChanged`;
  - actions go through today's `AccountSyncer` calls.
  - So the new table, the double-click window and the selection work the same for every account.
- **All Inboxes** merges Google Inboxes (§5.3) with IMAP Inboxes, which have exact dates.
- **Google accounts still on IMAP** (not yet switched, or added as custom IMAP with an app password) are logged by `TransportGuard` (§12.5), so the owner can see which are left.
- **Later.** The hybrid design's Phase 6 (an `IMAPAccountEngine` for other servers) remains possible, and is not part of this work.

---

## 14. Build plan

**In plain words:** three small fixes ship first, in v1.10.x; two of them ride with `fm-windows`, the owner's windows and Discard, because they make that work safe and quick. Then seven pieces of engine work are built at the same time by separate engineers in separate worktrees, each owning its own files and each tested only against fakes. Each merges as soon as it is done, behind the switch, which stays off. The switch goes on for the owner's test account only when all seven have landed and the targets in §14.6 pass.

### 14.1 First, one day: the contracts (G0, the lead)
- **The files:**
  - `Sources/FalconCore/Engine/EngineContracts.swift`: `MailAccountEngine`, `ListSource`, `ListView`, `ListSnapshot` (with `itemCount`), `DisplayRecord` (24 bytes), `ListDiff`, `RowAvailability`, `MessageRowContent`, `MailActionRequest`, `ActionReceipt`, `DraftRef`, `PokeReason`, `WorkClass`;
  - `Engine/RowKey.swift`;
  - `GmailEngine/GmailIdentity.swift`;
  - the protocols `GmailTransport` (what G1 provides) and `GmailStore` (what G2 provides).
- **These are types only.** They merge first, and every item builds against them.

### 14.2 Early fixes, which ship in v1.10.x

| Item | What it fixes | Files it changes | Tests | Ships |
|---|---|---|---|---|
| **E1 Draft safety** (in `fm-windows`) | Closing keeps the copy on the Mac until the server has the draft; quitting waits up to 5 s for saves in flight; leftover drafts are updated, not created again; Discard deletes the saved copy only after the undo window, with a "delete pending" marker so a quit neither loses nor revives it; Undo keeps the link to the saved copy (§8.4 rules 1 and 2) | fm-windows: `App/FalconMail/State/AppModel.swift` (`saveDraftToServer`, `saveLeftoverDrafts`, the quit path), `App/FalconMail/State/Workspace.swift` (`discardCompose`, `undoDiscard`), `Sources/FalconCore/Send/UnsentMessage.swift` (the marker), `App/FalconMail/State/ComposeDraft.swift` | `UnsentMessageTests`: the local file survives until the save answers; a simulated quit between closing and the answer saves the draft exactly once at the next launch; Discard, then quit within the window, leaves nothing in Drafts and nothing on the Mac; Undo within the window keeps the saved copy | with `fm-windows` |
| **E2 Open at once** | `GmailOpener` waits 0.3 s only when the reading pane's selection moves; windows, Return, ⌘O, Reply and Forward open at once (§6) | `Sources/FalconCore/Gmail/GmailMessageContent.swift` (`GmailOpener` takes the wait per call), `App/FalconMail/State/ServerSearch.swift` (its callers). `fm-inline-images` at `f906ed1` does not touch GmailMessageContent.swift | `MessageOpeningTests`: a window's open is sent at once; three arrow-key moves within 0.3 s send one open | with `fm-windows` if it has not merged yet, otherwise straight after it |
| **E3 Attachment price** | `attachmentsGet` booked at 20 units, not 5 | `Gmail/GmailQuotaLimiter.swift` (G1's file) | `GmailTransportTests`: every price | on its own |

**Outside this repo, on the owner's go only:** O1 in olm2cloud (§15.3): an import pace of 150 a minute and a daily upload cap of about 350 MB for accounts also used in FalconMail, and a stop at the first bandwidth refusal (olm2cloud `GmailImporter.swift`, `MigrationSession.swift`).

### 14.3 The engine work items

| Item | What it delivers | Files it owns (new files marked +) | Tests (all against fakes) | Depends on |
|---|---|---|---|---|
| **G1 Transport** | Every call used here; batches (25, 10 for `full`/`raw` and background); multipart uploads; the prices; **the token bucket and the classes of work** (§11.1); requests and batch parts in flight; 403s sorted by reason; bandwidth 429s told apart for uploads and downloads; API byte metering and budgets; **the probe** (§14.4) | `Gmail/GmailAPIClient.swift`, `Gmail/GmailQuotaLimiter.swift`, `Gmail/GmailBudget.swift`+, `Gmail/GoogleErrorParser.swift`, `Gmail/GmailBatch.swift`+, `Gmail/GmailUpload.swift`+, `Gmail/GmailWireTypes.swift`+, `Sync/TrafficMeter.swift`, and the fakes: `Tests/…/Support/FakeGmailMailbox.swift`, `FakeGmailURLProtocol.swift` | `GmailTransportTests`+, `GmailBudgetTests`+, `GmailBatchTests`+: every price; no 60 s window over 3,000; background never takes the bucket below 500; a click during a background burst gets its units within 0.1 s; flood limits (≤ 2,000); ≤ 4 requests and ≤ 35 parts in flight, 2 requests kept for clicks; a concurrency 429 halves the parts; each 403 reason sorted; upload and download 429s told apart; answers in any order; Retry-After; 5xx backoff; `+` encoded; bytes metered | G0 |
| **G2 Store** | The index (32 B) with overflow label lists; the journal with its two kinds of record and the cursor; the label table (with visibility); date anchors; the cache of 1,000 with LZFSE bodies and the 32 MB cap; the first-screen rule; conversation summaries; the import log; file layout under `Gmail/` | `GmailEngine/GmailIndex.swift`+, `GmailJournal.swift`+, `GmailLabelTable.swift`+, `DateAnchors.swift`+, `GmailMessageCache.swift`+, `GmailBodyStore.swift`+, `GmailThreadSummaries.swift`+, `GmailFiles.swift`+ | `GmailIndexTests`+: 200,000 records built in under 1 s, memory under 15 MB; 150 labels with overflow; `GmailJournalCrashTests`+: killed between any two writes (change records, listing pages, resync markers), it converges; listing pages apply without a cursor, change records only up to one; `GmailMessageCacheTests`+: 1,050 back to 1,000; the first-screen rule with 150 folders stays ≤ 390 slots; the caps; summaries kept current | G0 |
| **G3 Sync engine** | `GmailAccountEngine`; backfill (§3) with the count check; change checks and their timing (§4.1); reducing a check (§4.2); **the arrival rule** and placement (§4.3); flood mode with other-app limits; the 404 resync with confirmed tombstones and new mail meanwhile; echoes with kept records; new-mail selection, notifications and sound events; `AccountHealth.apiPaused` after 60 s; diagnostics titles | `GmailEngine/GmailAccountEngine.swift`+, `GmailBackfill.swift`+, `GmailHistorySync.swift`+, `GmailPlacement.swift`+, `GmailPollSchedule.swift`+, `GmailNewMail.swift`+, `GmailImportLog.swift`+, `Sync/MailServiceError.swift`, `Models/MailSounds.swift`, `Diagnostics/DiagnosticsSignature.swift` | `GmailBackfillTests`+: the order of steps; units at or below the table for the 55k, 200k and migrated fixtures; resuming; a message deleted above the page cursor during listing leaves the message after it in the index; `GmailHistoryTests`+: arrived now vs deep; **a 2037-dated imported message changes nothing, and new mail is still announced**; an add and delete in one check; an add, then a delete before the fetch; a stream of web-style draft autosaves; an unknown id in a label record is placed; a 404 resync confirms before removing; new mail during a resync; a flood of 25,000 from another app costs at most 40,000 units at 200,000 with no notifications; FalconMail's own import never floods; an echo changes no count; `GmailSoundEventTests`+: every row of the §4.7 table, and a 30 s Retry-After changes no health state | G0; G1 and G2 through their protocols |
| **G4 List** | `ListIndex` (views, conversations, sorts, headers, All Inboxes, Focused and Other); `RowFetchScheduler`; `MessageTableView` hosting the `fm-list-rows` component; placeholders with dummy text; `RowContentStore`; `RowModelAdapter`; `StoreListSource`; the busy and offline footers; the status bar (Items, progress, "All folders are up to date."); sorting by From with groups; the 1,000-row selection rule; search producing engine rows, and ids only while typing | `Sources/FalconCore/List/ListIndex.swift`+, `List/RowFetchScheduler.swift`+, `App/FalconMail/List/MessageTableView.swift`+, `ListController.swift`+, `RowContentStore.swift`+, `RowModelAdapter.swift`+, `StoreListSource.swift`+, `Gmail/GmailSearch.swift`, `App/FalconMail/Views/MainWindow.swift` (the status bar only) | `ListIndexTests`+: a 200,000-row view in under 5 ms, grouping in under 50 ms; `MemoryLayout<DisplayRecord>.stride == 24`; a first screen from disk in Conversations view costs 0 units, offline too; "Items: 200,000"; `RowFetchSchedulerTests`+: at most 25 per landing, nothing during a fling, stale requests dropped; the 5th to 10th landing in a minute show the footer at once; 1,001 selected rows never act on 1,000; typing a three-word search slowly costs only id lookups; offscreen snapshot checks with `-FalconMailSnapshot`, placeholders included | G0 |
| **G5 Actions** | Deltas by the per-folder rules (§7.1); move targets; delete for good with a fresh listing; undo; `pendingOps.json` with the 24-hour expiry and the gap check; kept history records; actions on a whole view as bulk work; `labels.create`; Move to Focused and Other; rules and mutes through the API; categories keyed by Gmail id | `GmailEngine/GmailActions.swift`+, `PendingGmailOps.swift`+, `GmailRules.swift`+, `GmailMute.swift`+, `App/FalconMail/State/OutlookCommands.swift`, `App/FalconMail/Services/MoveTargets.swift` | `GmailActionTests`+: one case for every cell of the §7.1 table and every move target; a move from Starred keeps the flag; a move from Deleted Items removes TRASH; Empty Deleted Items leaves a message restored on the phone; undo within the window sends nothing; undo after sending reverses only the deltas; a phone delete during a held delete survives Undo; replay after a restart applies once; a change older than 24 hours is dropped; a 403 rate reason never puts rows back; 200,000 archived in at most 200 `batchModify` calls at ≤ 1,500 a minute; the "label X, then Inbox" context test; `GmailRulesTests`+; unmute leaves no twin | G0; G3's engine API |
| **G6 Send, drafts, imports, archive** | `GmailSender` with the attempt header; `RoutingSender`; the Outbox's optional fields and its **confirm-only** check; `GmailDrafts` with the three safety rules and the provisional Drafts row; `messages.import` placed from its answer, paced by units and bytes; `GmailArchiveSource` with per-folder removal | `Gmail/GmailSender.swift`+, `Send/RoutingSender.swift`+, `Send/Outbox.swift`, `GmailEngine/GmailDrafts.swift`+, `Import/GmailImport.swift`+, `Archive/ArchiveJob.swift`, `Archive/GmailArchiveSource.swift`+; optional fields in `App/FalconMail/State/ComposeDraft.swift` after `fm-windows` and `fm-inline-images` merge | `GmailSendTests`+: a crash mid-send is never sent again without the owner; a timeout after acceptance is found in the history and marked sent; a send Gmail took but gave a new Message-ID is still found by the attempt header; a failure before the upload is retried by itself; Bcc only in the API upload; `threadId`; the Sent row appears before `send` returns; a sending limit and an upload 429 are held with their sentences; `GmailDraftTests`+: create, update, discard with undo, send then delete; a create that timed out is not created twice; overlapping saves finish in order; a 404 on update creates; a quiet close deletes this session's autosave; after relaunch the sent draft is still deleted; `GmailImportTests`+: rows appear at once, no flood, no notification, time bounded by bytes; `GmailArchiveTests`+: removing a label folder leaves the Inbox copy | G0, G1 |
| **G7 Integration and migration** (lands last) | Routing by engine for every entry point (§7.7) and for notifications; message windows that close only when a message is gone, with `gmailWindows` and the tray; `TransportGuard` by host, with logging; the switch in Settings, its staged default, the pending-IMAP gate and the switch-off gate; re-keying with the Message-ID checks; mutes left as they are; `session.json` carried forward; Google folders kept out of `MailStore`; the sidebar's Outlook names and order, Drafts count and hourglass; "Show all Gmail labels"; the custom-Gmail line; Spotlight for the cached 1,000; the Focused and Other setting; Delete All asking first; swapping `List` for `MessageTableView`; the Google check when adding an account | `Sync/SyncCoordinator.swift`, `Sync/TransportGuard.swift`+, `IMAP/IMAPClient.swift` and `SMTP/SMTPClient.swift` (connect hook only), `Sync/AccountProbe.swift` (hook only), `GmailEngine/GmailMigration.swift`+, `App/…/State/AppModel+Engines.swift`+, `State/AppModel.swift`, `Views/MessageListView.swift`, `Views/SidebarView.swift`, `Views/CommandBar.swift`, `State/ServerSearch.swift`, `State/SessionState.swift`, `Views/AddAccountSheet.swift`, `Views/SettingsPanes.swift`, `Views/NotificationsPane.swift`, `Services/Notifications.swift`, `Search/SpotlightIndexer.swift` | `ZeroIMAPTests`+ (§12.5); `GmailMigrationTests`+: re-keying with a reused Message-ID; an account with pending IMAP actions does not switch until they are sent; switching off sends pending Gmail changes first; fixtures of v1.10.0's files that load after upgrading, after going back, and after going back and forward again; `session.json` keeps v1.10.0's entries; a hash of `Accounts/<id>/` apart from `Gmail/` is unchanged by the full scenario; `GmailScenarioTests`+: the "typical day" replay against the §14.6 targets, and "FalconMail and olm2cloud on one account" | all of them |

### 14.4 What G1's probe checks
Once, on the owner's own test account only, and never on any other account.

**Read-only part:**
- that `snippet` comes back with `metadata` and `threads.get`;
- that `messages.list` returns newest first, with and without `labelIds`;
- that `before:<epoch seconds>` matches `internalDate`;
- whether `messageAdded` history records carry `labelIds`;
- how long attachment ids stay valid;
- which batch address answers: `https://gmail.googleapis.com/batch/gmail/v1` from the batch guide, or `https://gmail.googleapis.com/batch` from the discovery document [S3][S13];
- whether `labels.get`'s `messagesTotal` and `getProfile`'s `messagesTotal` count Junk Email and Deleted Items (§2.5);
- whether `messages.list` returns chat messages (§3);
- how many inline pictures a message has, as counts only (§2.4);
- response times (median and 95th percentile) of list pages, batches of 25 metadata calls, `full`, and history.

**Write part, only with the owner's approval** (decision O5). It works only on messages it creates, under a label "FalconMail probe", never touches existing mail, and deletes everything it made at the end:
- one message made with `messages.insert`: that `batchModify +TRASH` works like `messages.trash`;
- one message sent to the test account itself: whether `messages.send` keeps FalconMail's Message-ID and an `X-FalconMail-Attempt` header (§8.2);
- one draft created and updated: whether it keeps its Message-ID and the `X-FalconMail-Draft` header (§8.4).

**Never probed:** the per-user limit on requests at the same time, and the bandwidth limits, since finding them means being refused. Whether olm2cloud's imports count against the upload allowance is looked for in olm2cloud's own logs of past real migrations, with the owner's permission (§1.3).

### 14.5 The fakes
`FakeGmailMailbox` (Tests/FalconCoreTests/Support/FakeGmailMailbox.swift) becomes the in-memory Gmail mailbox model, with G1 owning it. It gains:
- `history` with a retained floor, so that start points below it give 404, and history in the order Gmail writes it, including an add and delete of one id in the same page;
- `labels.get` counts; `threads.get`; `labels.create`;
- `modify`, `batchModify`, `trash`, `untrash`, `batchDelete`;
- upload `send` (which can keep or replace the Message-ID) and `import`; `drafts.*`; `sendAs`; the batch endpoint;
- fixtures: 55,000, 200,000, and **200,000 migrated from Outlook with 150 labels**; an imported message dated 2037;
- a **second client** that shares the per-user budget, to play olm2cloud or a second Mac;
- faults: 429 with Retry-After, 403 for each reason, 500, a timeout **after** a send was accepted, a concurrency 429 counted by batch parts, upload and download bandwidth 429s, and delays per endpoint;
- units, bytes and the peak number of requests and parts in flight, per endpoint.

Other items extend it only in their own files (`FakeGmailMailbox+Drafts.swift` and so on), to keep their changes apart.

### 14.6 Acceptance targets
Run against the fakes on the M1 Pro, with these delays injected: list page 300 ms, batch of 25 metadata 800 ms, `full` 400 ms, history 150 ms. The figures G1's probe measures replace these delays once it has run.

| Target | Threshold |
|---|---|
| First screen, from disk, of the Inbox and the 12 most used folders, in Conversations view, offline too | < 150 ms and 0 units |
| First screen of any other folder | < 1.2 s at the 95th percentile, ≤ 1,000 units |
| First screen of a new account | < 2.5 s at the 95th percentile |
| Every message listed | 55,000 in < 60 s idle, ≤ 1,500 units; 200,000 in < 3 min idle and < 6 min while the owner works, ≤ 5,500 units, for both the usual and the migrated fixture |
| Fully set up (index and newest 1,000) | < 30 min idle; ≤ 55,000 units at 200,000 |
| Fling at 120 Hz over 200,000 rows with the hosted row component | main-thread work < 8 ms a frame |
| Landings after scrolling stops | the first 4 in any minute: filled < 1.2 s at the 95th percentile, ≤ 25 rows each; the 5th to 10th: the footer shows at once, and each fills within 25 s |
| Opening | cached < 100 ms; the text of an uncached message < 1.0 s at the 95th percentile; a window's request sent < 50 ms after the double-click |
| An action | the row changes < 16 ms after the click; Gmail's answer < 1 s at the 95th percentile after the undo window |
| New mail | in the list and announced within 35 s while the owner is active, including during heavy scrolling and during a resync; unaffected by a message dated 2037 |
| Units | the typical-day replay ≤ 40,000 units; no 60 s window over 3,000 per account; ≤ 2,000 in flood mode; ≤ 4 requests and ≤ 35 parts in flight |
| Sharing | FalconMail and a second client importing at 150 a minute never book more than 6,000 units in any minute together |
| Disk | ≤ 20 MB on the typical fixture; never over 43 MB; nothing under `~/Library/Caches` |
| Memory | < 35 MB per account at 200,000, not counting the shared body cache |
| Safety | 0 IMAP and 0 SMTP connections for a switched account (§12.5); crashes converge (§4.5); a send is never repeated without the owner (§8.2); a draft's text survives a kill between closing and Gmail's answer (§8.4); nothing deleted or moved before the switch comes back (§12.1); no Google folder written through `MailStore` (§2.2) |

### 14.7 What ships together, and the other worktrees
- **Shipping.**
  - **In v1.10.x, before the engine:** E1 and E2 with `fm-windows`; E3 on its own. They change behaviour for every account, and need no switch.
  - **Merged behind the switch as each is green:** G0 first; then G1, G2 and G4 in parallel; then G3, G5 and G6; G7 last. Nothing a user sees changes while the switch is off.
  - **Must all have landed before the switch goes on for any account:** G1 to G7. With IMAP gone for a switched account there is no fallback, so the list, actions, sending, drafts and imports must all be there.
  - **Switch on for the owner's test account** once the §14.6 targets pass and G1's probe has run (its write part only if he approves) and its findings are folded in.
  - **Then his main account** after 7 days on the test account with no data problem in the daily report, **then the others one at a time** when he says so. An account that olm2cloud is still importing into is switched only after decision O1.
- **The three worktrees already open:**
  - **`fm-windows`** (at `1ab97a5`, four commits past `9046d5b`) owns WindowTray.swift, Workspace.swift, ComposeView.swift, ComposeRibbon.swift, UnsentMessage.swift, UnsentMessageAlert.swift (which it removes), `Util/PopupWindows.swift`, the menus in FalconMailApp.swift, the window parts of MessageDetailView.swift, and its additions to SessionState.swift and AppModel.swift. **It carries E1, and E2 if it has not merged yet.** It lands before G6's draft routing and before G7. G6's `GmailDrafts` is FalconCore only; G7 then routes `saveDraftToServer` and `discardDraft` by engine.
  - **`fm-list-rows`** (at `9046d5b`, no commits yet) owns the row component in `App/FalconMail/Views` and OutlookLook.swift. G4 only hosts it, through `RowModelAdapter`. G7 swaps `List` for `MessageTableView` in MessageListView.swift after `fm-list-rows` lands.
  - **`fm-inline-images`** (at `f906ed1`) owns inline pictures in the MIME code (ComposedBody.swift, ComposedHTML.swift, InlinePictures.swift, MIMEBuilder.swift), the editor, and small parts of ComposeDraft.swift, AppModel.swift and MessageDetailView.swift. It does not touch GmailMessageContent.swift, so E2 does not clash with it. `GmailSender` adds its header at upload, not in `MIMEBuilder`. G7's change to the open path in MessageDetailView.swift waits for it.
- **Rough effort:** E1 2–3 days; E2 half a day; E3 half a day; G0 1 day; G1 4–5 days; G2 5–6 days; G3 2 weeks; G4 2–2.5 weeks; G5 1.5 weeks; G6 1.5–2 weeks; G7 1.5 weeks. **With 5–6 engineers, 4–5 weeks** for the engine.
- **The rules of every item:**
  - Tests use only fakes, and nothing ever connects to the owner's real accounts, apart from G1's probe on his test account.
  - FalconMail is never launched on the owner's desktop; UI checks render offscreen.
  - Every new stored field is optional, or lives in its own file.
  - Nothing is pushed or released without the owner's go.

---

## 15. Risks and open questions

### 15.1 Risks, and how each is contained

| Risk | Containment |
|---|---|
| **The per-user limit is shared** by FalconMail on each Mac and by olm2cloud (§1.3). Two Macs can reach 6,000 in a minute; FalconMail beside olm2cloud at its default passes it | 3,000 per account per Mac, as v1.10.0; 2,000 while another app imports; halving on a 429, with nothing lost. olm2cloud at 150 a minute (O1). The scenario test "FalconMail and olm2cloud on one account" |
| **The upload allowance is shared**, and olm2cloud's imports may count against it. A migration day could stop sending and draft saves for hours, with no SMTP fallback | A plain sentence; the Outbox and drafts wait, and nothing is lost. Imports in FalconMail stop at 300 MB a day. olm2cloud's daily upload cap and stop at the first bandwidth refusal (O1). olm2cloud's past logs are checked for upload refusals |
| **Old mail never seen before scrolls slowly:** about 3 screens a minute | The first screen after a pause fills at once; conversation summaries and the kept first screens cost nothing; the footer shows at once; rows fetched once stay for the session. O3 would keep seen rows across launches |
| **Behaviour Google does not document** (`snippet` in metadata; list order; `before:` epoch semantics; TRASH through `batchModify`; labels on `messageAdded`; attachment ids; whether a sent message keeps its Message-ID; how counts treat Junk Email and Deleted Items; chats in lists) | G1's probe checks each (§14.4). Each has a fallback: `full` instead of `metadata`; ordering by `internalDate` from fetched rows; `messages.trash` in batches; a `minimal` call for labels; fetching `full` again; the attempt header and holding for the owner; counting by whichever rule Google uses; `-in:chats` |
| **Google changes its limits again**, or starts billing above 80 million [S2] | About 9% of the project's day at 200 accounts. Units reported daily for each account and for the project. A daily cap and an alert (O2). Large migrations spread over several days |
| **Suspension is not ruled out for the API** [S17], and checking every 30 s goes beyond Google's advice for IMAP and POP clients | Half of the per-user limit at most; checks of 2 units; backoff at the first refusal; open question 1 |
| **Unclear sends are now held for the owner** rather than tried again by themselves, so he may see "Check Sent" a little more often | Two looks in the history, at 30 s and 2 min, find almost every send that went. Only a send Gmail has no record of after both is held |
| **Mailboxes migrated from Outlook** have 100 or more labels | Overflow label lists; first screens for the 13 folders used most; `labels.get` in batches of 25; a migrated fixture in every test of units and time |
| **The restricted scope** `https://mail.google.com/` [S31]. An external app still in "Testing" gets refresh tokens that expire after 7 days [S32] | Unchanged from v1.10.0, which already asks for this scope. For users outside the owner's Workspace, see open question 16 |
| **No SMTP fallback**, so sending waits if the API is down, uploads are paused, or a daily cap is reached | The Outbox holds messages with a plain sentence, and nothing is lost. Open question 10 |
| **The history expires** after more than a week offline | A relisting bounded at 1,200 or 4,900 units, which resumes if cut off; nothing is removed without being confirmed; new mail keeps arriving meanwhile |
| **Hosting SwiftUI rows in `NSTableView` misses the fling target** | The fling test in G4. If it misses: pre-render row images for placeholders, and use SwiftUI only for rows with text. The component itself does not change |
| **A mistake quietly uses IMAP** | `TransportGuard` by host, `imapUsed` in the daily report, and `ZeroIMAPTests` |
| **Google accounts stay on IMAP until switched.** Until then, `fm-windows`' rule that closing saves to Drafts adds an IMAP APPEND on each close for them | The staged switch plan (§12.1). The APPENDs are about 30 a day and small beside the sync traffic of an IMAP account; automatic saving once a minute is only on the Gmail engine. The daily report counts every Google IMAP connection |
| **Going back to v1.10.0 with a change still unsent** | Kept for at most 24 hours, and dropped if its messages were touched since (§7.3, §12.4). Changes are sent at quit |
| **Re-keying matches the wrong message** | Message-IDs are used only when usable and when the subject or date agrees; more than one match is never guessed; unresolved keys go into the `legacy` map; mutes are not rewritten |
| **A wrong clock on the Mac** makes new mail look old | The arrival test uses Gmail's time, from the `Date` header of its answers |

### 15.2 Open questions for the owner (the default is what gets built unless he says otherwise)

| # | Question | Default |
|---|---|---|
| 1 | How often to check for new mail | **Every 30 s** while active, whether FalconMail is in front or not; every 2 min when idle. This goes beyond Google's advice for IMAP and POP clients (§1.5). The alternative is once a minute while FalconMail is not in front |
| 2 | Sorting a big Google folder by From, To or Subject | **Every row stays**: rows with known text are grouped at the top, and the rest follow by date, with a footer pointing to search. Fetching every row would take hours of quota |
| 3 | Outlook colour categories | **Kept on this Mac**, keyed by the Gmail id. The alternative is to sync them as Gmail labels named "Category/…" |
| 4 | What Archive means | **Settled:** Archive takes the message out of the Inbox; it stays in Archive (Gmail's All Mail), as in Legacy Outlook |
| 5 | What Delete means | **Move to Deleted Items**, which can be undone. Deleting inside a label folder is decision O4. Empty Folder and Delete in Deleted Items are permanent, after asking |
| 6 | Focused and Other | **Focused is Primary, Updates and mail with no category**; Other is Promotions, Social and Forums. One setting moves Updates to Other |
| 7 | Read state of imported mail | **Read** |
| 8 | Keep the index on disk (6.4 MB at 200,000) | **Yes**. Without it, listing everything again at each launch takes 2–5 minutes and about 4,900 units |
| 9 | Which folders open at once and offline | **The Inbox and the 12 folders used most recently**, one screen each (20–30 rows). Others fetch their first screen when opened, in about a second |
| 10 | Let a Google account send by SMTP when the API cannot be used | **No**, per the owner's rule. The Outbox holds the message. This includes the case where an import has used the upload allowance (§1.3) |
| 11 | Which Google accounts move first | **The owner's test account**, then his main account after 7 days with no data problem, then the others one at a time, when he says so |
| 12 | FalconMail's ceiling per account | **3,000 units in any minute on each Mac** (half of Google's shared 6,000), and 2,000 while another app imports |
| 13 | When to delete the old IMAP copy | **After 14 days with no switch back, and his confirmation in Settings** |
| 14 | Saving drafts to Gmail automatically while writing | **Once a minute while the content changes**, as well as on closing and on Save, on the Gmail engine only |
| 15 | What Run Rules Now covers | **The cached newest messages of the Inbox** |
| 16 | Should the Google sign-in be verified for people outside the owner's Workspace? The restricted scope needs Google's review [S31], and apps in Testing re-ask every 7 days [S32] | **No change for now.** It matters only once people outside his Workspace use release builds |
| 17 | A Gmail account added as a custom IMAP account with an app password | **Offer Sign in with Google instead**, and treat the account as Google. Existing ones stay on IMAP, with a line in Settings, until he signs in with Google |

### 15.3 Decisions that need the owner
These change something outside FalconMail's code, or go against a rule he stated. Nothing here blocks the early fixes or the engine work; each has a safe default.

| # | Decision | Recommendation | If he says no |
|---|---|---|---|
| **O1** | **olm2cloud's pace and uploads** (a separate app, released only on his go). For an account that is also used in FalconMail: import at 150 a minute instead of 200; cap the day's uploads at about 350 MB; stop at the first bandwidth refusal | Yes. It keeps FalconMail and olm2cloud together under Google's 6,000 a minute, and leaves room for sending on a migration day | Both apps are refused now and then during migrations, and slow themselves. If imports do count against the upload allowance, sending from FalconMail can pause for hours on a migration day (the message waits in the Outbox) |
| **O2** | **A daily cap on the Google project**, a little below 80 million (for example 75 million), in the Cloud Console under IAM & Admin ▸ Quotas & System Limits, with a Cloud Monitoring alert at 50% | Yes. Google will bill above 80 million once billing starts, and the cap turns that into a pause FalconMail already handles | Nothing is ever refused. On a very heavy day, once billing has started, use above 80 million is charged |
| **O3** | **Keep the text lines of rows already seen** (sender, subject, date and preview; no bodies), about 0.5 KB each, about 10 MB for 20,000 rows | No, because his rule is "latest 1000 emails. That's it." It is built that way | (Default.) Rows he saw before a relaunch come back grey until scrolled into view, which costs quota again |
| **O4** | **Delete inside a label folder:** move to Deleted Items everywhere (as v1.10.0 and Legacy Outlook over Gmail's IMAP do), or remove only that label (the message stays in its other folders and in Archive) | Deleted Items everywhere, as today | (Default.) |
| **O5** | **G1's write probe** on his test account: one inserted message, one message sent to the test account itself, one draft, all under a "FalconMail probe" label and deleted at the end; and reading olm2cloud's logs of past migrations for upload refusals | Yes. Without it, sending twice is prevented only by holding every unclear send for him | The design keeps its safe fallbacks: unclear sends are held, drafts are matched by the history, and `messages.trash` is used in batches |

---

## Appendix A. What carries over from `mail-engine-design.md` revision 2

| Kept | Changed | Dropped |
|---|---|---|
| The rule of at most 1,000 cached, reduced LZFSE bodies, the 32 MB cap and 1,050 back to 1,000 | The skeleton is 32 B and built from `messages.list` per label, not 40 B from IMAP `X-GM-*`; the order comes from All Mail's listing, not INTERNALDATE. First screens are kept for the Inbox and the 12 most used folders, not for every folder | Every IMAP transport: the watcher, the IDLE doorbell, the interactive lane on IMAP, the background worker, IMAP byte budgets and the command token buckets for Google accounts |
| The virtualised `NSTableView`, the immutable `ListSnapshot` and `RowContentStore`, a `viewFor` that never waits, IndexSet selection, and predicates for whole-view actions | Cells host the `fm-list-rows` SwiftUI component unchanged, in place of AppKit-drawn cells | Lean IMAP row fetches and the IMAP body cache fill; the `X-GM-RAW` search fallback |
| Typed errors and one status per account; "Protocol error" never shown | Rows cost 20 or 40 units when fetched, so fetching waits for the scroll to settle and is paced by a token bucket; date headers come from `before:` anchors | The UIDVALIDITY remap, the CONDSTORE resync and the msgid checks on UID fetches: none are needed without IMAP |
| The one cursor, kept in the journal and flushed with its changes, and the kill-between-writes test | A 404 resync lists everything again (1,200 or 4,900 units) instead of CONDSTORE, and confirms before removing | Building the new store alongside the old engine: the new first screen takes 1.5 s, so the switch happens at once |
| Pending changes in their own file, per-message deltas, undo, and context from the view | No SMTP fallback; every Google send uses `messages.send`, and an unclear send is held for the owner | Translating pending IMAP actions: the switch waits for them to be sent |
| The Outbox never sends twice | Drafts follow the owner's rule of 25 Sep: closing saves, Discard deletes after the undo window, and the Mac's copy stays until Gmail has the draft | |
| Testing only against fakes, the per-account switch, and phases that each ship safely | The fake Gmail mailbox becomes the main model, with a second client; the fake IMAP server is used only to count zero connections | |
| Outlook's look, sounds and notifications (24 h window, own addresses skipped) | New mail is decided by arrival time; Outlook's folder names; `AccountHealth.apiPaused` is added, after 60 s, and treated as a pause, not a failure | |

## Appendix B. Sources
- **S1–S32:** the Google fact sheet given with this task, read on 25 September 2026. The pages are saved in the session scratchpad `gdocs/`. For revision 2 the quota page [S1] and the errors page [S4] were read again for their exact words on the daily billing threshold, `dailyLimitExceeded`, concurrent requests and bandwidth.
- **S17:** Google's server request limits page, checked again in its saved copy (`gdocs/sa_1359240.html`) for its advice to set a mail client to check for new mail about once every 15 minutes; the page speaks of mail clients and mentions IMAP and POP.
- **S33:** Gmail API, "Searching for messages" (developers.google.com/workspace/gmail/api/guides/filtering), last updated 2026-09-10, read 2026-09-25.
- **S34:** Gmail API, "Manage labels" (developers.google.com/workspace/gmail/api/guides/labels), last updated 2026-09-10, read 2026-09-25.
- **Code** at mc4mac `9046d5b`; `fm-windows` at `1ab97a5`; `fm-inline-images` at `f906ed1`; olm2cloud's importer (`Sources/OLMCore/Migration/GmailImporter.swift`, `App/olm2cloud/State/MigrationSession.swift`). Nothing in any repo was changed for this document.
- **Figures** for revision 2 are worked out in `/private/tmp/claude-501/-Users-kmuradoff-mc4mac/8f7bb11b-871e-4f45-817b-f5ba1ea3c7a9/scratchpad/revise/calc2.py`.

---

## Review log

Revision 1 was reviewed three times on 25 September 2026: for **quota and capacity** (A), for **correctness and data safety** (B), and for **fidelity to Outlook** (C). Each point is listed below with its decision and what changed. Where two reviews raised the same point, both rows point to the same change.

**The decisions in short.** All 65 points are taken up. 55 are accepted as proposed. 10 are accepted with a change, and the change is explained in the row. Three proposals within those points are turned down, each with a reason: interactive borrowing up to 4,500 a minute (A1), fetching a conversation's newest message first and the whole thread after a second (A4), and shipping Gmail drafts before `fm-windows` (B15).

**What the reviews checked and found correct:** the typical day of revision 1 (32,140 units), the index costs (1,200 and 4,560 units), a whole-view action on 200,000 messages (10,000 units), the project percentages without olm2cloud, and the prices against Google's page of 10 September 2026.

**Scope.** All three reviews noted that the owner's request relayed in this run, message windows that pop out and minimise like compose, and Discard for new mail and replies, is built in `fm-windows`, not here. This revision covers only where that work meets Google accounts, and two fixes that make it safe and quick now: E1 (drafts are never lost on closing; Discard deletes after Undo has expired) and E2 (windows open without the 0.3 s wait), both shipping with `fm-windows` (§14.2).

### Review A: quota and capacity

| # | Severity | The point | Decision | What changed, and where |
|---|---|---|---|---|
| A1 | critical | Google's 6,000 a minute is per user per project and shared by every client; two Macs at 4,500 book 9,000, and FalconMail beside olm2cloud (200 imports a minute, 5,000 units, not "one a second") books 9,500 | **Accepted with a change** | The ceiling is 3,000 in any minute per account on each Mac, as in v1.10.0, and 2,000 while another app imports; the two-Mac claim is corrected; olm2cloud's pace and upload cap become decision O1; a "FalconMail and olm2cloud on one account" scenario test is added (§1.1, §1.3, §11.1, §14.3, §14.6, §15.1, §15.3). **Turned down:** letting interactive work borrow up to 4,500 for a minute, because two Macs borrowing at once would pass 6,000; the bucket's 1,000-unit burst gives the first screen at once instead. A shared budget file for both apps on one Mac is noted as a possible later step, since it needs both apps changed |
| A2 | major | The upload allowance is shared by all of the user's API clients; if imports count, a migration day could stop sending and draft saves for hours, with no SMTP fallback | Accepted | Named as a risk; bandwidth 429s on sends and drafts are told apart and get their own sentence; FalconMail's imports stop at 300 MB a day to keep room for sending; olm2cloud's cap is part of O1; olm2cloud's past logs are checked, never a live account (§1.3, §1.4, §8.2, §10.2, §11.2, §14.4, §15.1) |
| A3 | major | The one-minute ledger lets background work spend a minute in its first seconds; the Mac-wide guard and the 4 connections do not separate background from interactive work; whole-view actions and checks compete with clicks | **Accepted with a change** | A token bucket per account (2,000 a minute, holding 1,000); background never takes it below 500; classes in priority order, checks first; whole-view actions capped at 1,500 a minute; 2 of the 4 connections kept for clicks; the Mac-wide unit guard is removed and replaced by at most 8 background requests in flight across accounts (§1.1, §7.4, §11.1). **The change:** checks and new mail come first in the queue instead of having a separate 200-unit allowance, which would have broken the "never over 3,000 in a minute" guarantee; a 2-unit check gets its units within a fraction of a second either way |
| A4 | major | A screen of rows costs 500–1,000 units in the default Conversations view, not 300–700, so fewer screens a minute; rows can stay grey for about 50 seconds; the busiest minute and project-per-minute figures are understated; the landing target cannot hold past the fifth screen | **Accepted with a change** | Landing costs restated; about 4 landings in the first minute, then about 3 a minute; the footer shows as soon as rows wait on budget; busiest minute ≈ 2,600, project per minute 43%; the target covers the first 4 landings in a minute, and a test covers the 5th to 10th (§1.2, §5.7, §14.6). **Turned down:** fetching only the newest message of a conversation first and the whole thread after a second on screen, because while reading most rows stay on screen longer than that, so most conversation rows would cost 60 units instead of 40. Conversation summaries on disk (A5) lower the cost instead |
| A5 | major | Conversation rows after a launch cost 40 units each, since thread details were memory-only, so "every folder opens from disk" did not hold in Conversations view | Accepted | A summary of each conversation with a cached member is kept on disk; rows paint from it; the target and a test say the first screen from disk in Conversations view costs 0 units, offline too (§2.4, §2.6, §5.4, §14.3, §14.6) |
| A6 | major | Mailboxes migrated by olm2cloud have 100+ labels: the first-screen rule contradicts itself, folders get fewer rows than a screen, overflow labels are not sized, step 1 exceeds the batch limit, and the index passes its target | Accepted | A migrated fixture (200,000 messages, 150 labels, 70% labelled) in the listing table and the tests; first screens kept for the Inbox and the 12 most used folders only; overflow lists sized at 4 bytes a membership; `labels.get` in batches of 25; targets set at ≤ 5,500 units for both fixtures (§2.3, §2.4, §2.6, §3, §14.5, §14.6) |
| A7 | major | FalconMail's own imports trigger flood mode and relist every 10 minutes (about 214,000 units for 25,000 messages); the stated import time ignores the 400 MB-a-day upload cap | Accepted | Own imports are placed from `messages.import`'s answer, logged, and never flood; one relisting at the end (daily during a long import); floods from other apps relist every 30 minutes; only touched date boundaries are asked again; import time is the longer of units and bytes, about 3½ days per GB (§4.3, §5.6, §9.1) |
| A8 | major | 80 million a day is a billing threshold, not a refusal, so "wait until midnight" never happens; the project table leaves out olm2cloud; the summary and table disagreed (9% and 8%) | Accepted | §1.4 says Google bills above it; a daily cap and alert become decision O2; olm2cloud's migrations are in the project figures, with advice to spread them; the summary and table now agree at 9% (8.9%) (§1.2, §1.4, §10.2, §15.3) |
| A9 | major | The per-user concurrency limit is shared; 50 batch parts in flight, and dropping to 2 connections still allows 50 parts | **Accepted with a change** | Batch parts in flight are limited, and halve after a concurrency 429; background batches hold at most 10 parts; the probe never looks for this limit (§1.4, §11.1, §14.4). **The change:** the limit is 35 parts (25 for a screen of rows, 10 for background), not 15, because a screen of rows is one 25-part batch and splitting it would double its wait |
| A10 | major | An imported message with a future date would sit at the top of All Mail and silently stop new-mail notices and rules | Accepted | New mail is decided by arrival time, and a message dated more than a day ahead is old mail; a 2037 fixture in `GmailHistoryTests` (§4.3, §14.3, §14.5) |
| A11 | minor | Each inline picture costs 20 units, so signature logos push the cache fill to 40,000–60,000 | Accepted | With two or more pictures in a message of 1 MB or less, one `format=raw` call replaces them, so no message costs more than 40; the probe counts pictures per message; first-day figures updated (§1.2, §2.4, §6, §14.4) |
| A12 | minor | `GmailOpener` waits 0.3 s before every first open, which delays the owner's double-click windows | Accepted | The wait applies only to moves in the reading pane; it ships early as E2, with `fm-windows` (§5.9, §6, §14.2) |
| A13 | minor | `DisplayRecord` as declared has a stride of 32, not 24 | Accepted | Fields reordered; a test checks the stride (§2.6, §5.2, §14.3) |
| A14 | minor | Placeholders with empty text draw no grey bars | Accepted | Placeholder rows get fixed dummy text of typical length; the offscreen snapshot covers them (§5.7) |
| A15 | minor | Google's server request limits page advises checking once every 15 minutes (for IMAP and POP); 30 s is well beyond it | **Accepted with a change** | Said plainly (§1.5, §4.1). **The change:** the default stays every 30 s whether FalconMail is in front or not, because notifications matter most when it is behind other apps and each check is 2 units; once a minute while behind is offered in open question 1 |
| A16 | minor | Google does not say whether `labels.get` counts Spam and Trash, so the daily check could relist labels every day for nothing | Accepted | The probe finds the rule, and counts are compared by the same rule; All Mail is checked against `getProfile` the same way (§2.5, §14.4) |
| A17 | minor | Searching after a 600 ms pause runs several full searches while someone types slowly | Accepted | While typing, only ids are fetched (5 units); row text on Return or after 1.5 s (§1.2, §5.10) |
| A18 | minor | Small arithmetic: first-day timing had no margin and assumed an idle Mac; the look at the top ran even when every id was known; the batch address was stated as fact | Accepted | Both timings (idle and working) given everywhere; the set-up target is now 30 minutes, since conversation summaries and first screens are part of it; the look at the top is removed altogether, since the arrival rule no longer needs it; the batch address is a probe item (§1.2, §3, §11.1, §14.6) |

### Review B: correctness and data safety

| # | Severity | The point | Decision | What changed, and where |
|---|---|---|---|---|
| B1 | critical | The "never send twice" check relies on Gmail keeping FalconMail's Message-ID, checks too early, and resends by itself when it finds nothing, reversing v1.10.0's rule | Accepted | The history is used only to confirm a send; an `X-FalconMail-Attempt` header and `X-Google-Original-Message-ID` are matched too; two looks, at 30 s and 2 min; if not found, held for the owner with v1.10.0's words; retried by itself only when the failure came before the upload; the probe checks what `messages.send` keeps; the Sent row takes Gmail's Message-ID if it differs (§8.1, §8.2, §14.4) |
| B2 | critical | A message skipped by a paged listing is never repaired, and a 404 resync then tombstones real mail | Accepted | Counts checked after listing, with relisting on a mismatch; ids seen in a label list or history but missing from the index are placed; resync removals are confirmed first, and written only with `resyncEnd`; a test deletes a message above the page cursor during listing (§3, §4.2, §4.4, §14.3) |
| B3 | critical | A message added and deleted within one check (every web draft autosave) has no defined handling, and could stall change checks or leave ghost rows | Accepted | Records are reduced in history order and such ids dropped; a 404 when placing is a deletion; ids that cannot be placed wait without holding the cursor; three tests (§4.2, §14.3) |
| B4 | major | Closing a message deletes its local copy before the server has saved it; under the owner's new rule every close goes this way | Accepted | The local file stays until the save succeeds; quit waits up to 5 s; leftovers are updated, not created again. It ships now as E1 in `fm-windows`, where the same code is unchanged (§8.4, §14.2) |
| B5 | major | Drafts duplicated or left behind: a timed-out create, overlapping saves, no durable draft id after sending or Undo Send, drafts from before the switch, autosaved drafts left by a quiet close, discarded drafts brought back at launch | **Accepted with a change** | A stable Message-ID and `X-FalconMail-Draft` header on every save; one save in flight per draft; `gmailDraftID` and `gmailThreadID` in `OutboxItem` and the sidecar; pre-switch drafts resolved to their Gmail draft; a quiet close deletes this session's autosave; a "delete pending" marker on Discard; a 404 on update creates a new draft (§8.2, §8.4, §12.4). **The change:** a timed-out create is looked for in the history since the save began, not in `drafts.list`, which does not return headers |
| B6 | major | While a change is held, skipped history records are lost for good if the change is then undone or refused | Accepted | Skipped records are kept with the change and applied (or refetched) if it ends without being sent (§4.6, §7.3, §7.5) |
| B7 | major | `pendingOps.json` never expires, so Gmail changes could be replayed weeks later; switching off does not send pending changes first | Accepted | 24-hour expiry, as v1.10.0; a gap check against the history before replaying; switching off sends first and refuses while it cannot; the going-back table says what happens (§7.3, §12.4, §12.6) |
| B8 | major | Pending IMAP archive, move and delete actions cannot be translated, because v1.10.0 removes their rows before the server command runs | Accepted | An account does not switch until its pending IMAP actions have been sent; there is no translation (§12.1). The optional `messageIDs` field for `PendingServerOperation` is not added, since it is no longer needed |
| B9 | major | Re-keying by Message-ID alone ignores v1.10.0's own safeguards against reused ids | Accepted | `usableMessageID` and `sameMessage` are used; more than one match is never guessed; destructive actions are no longer translated at all (§12.2) |
| B10 | major | Adding a second mute record makes Unmute leave its twin, so mail stays hidden | Accepted | Mute records are not rewritten; new mail is matched by Message-ID and References; Unmute removes every matching record; a test (§7.6, §12.2, §14.3) |
| B11 | major | Move, Archive and Delete are undefined from Trash, Spam, Starred, Important, Sent and Drafts, and some move targets are refused by Gmail | Accepted | A rule for every folder and every move target, with a test for each (§7.1). Same change as C2 |
| B12 | major | The sidebar's Delete All does not ask, and permanent deletion would use a possibly stale index | Accepted | It always asks with the count; a fresh listing is intersected with the index; chunks with checks between; counts logged (§7.1) |
| B13 | major | The archive job's "remove" would trash mail the owner keeps in other folders | Accepted | It removes only the archived folder's label, as v1.10.0's expunge does on Gmail; `+TRASH` only when archiving All Mail, after the archive is written (§9.2) |
| B14 | major | Actions with no route are dropped silently; New Folder and Load older have no Gmail path | Accepted | Every entry point routed by engine; `labels.create`; Load older hidden; a visible error when an account has no engine; the scenario test checks each entry point (§7.7, §12.5) |
| B15 | major | "No IMAP" holds only for new accounts: existing and custom Gmail accounts stay on IMAP, the guard cannot see SMTP's account, and `fm-windows`' saving on every close adds IMAP APPENDs | **Accepted with a change** | A staged plan switches existing accounts as part of the release; the guard works by host and login name, covering `AccountProbe`; every Google IMAP connection is logged in the daily report; custom Gmail accounts get a line offering Sign in with Google (§10.1, §12.1, §12.5, §13). **Turned down:** shipping Gmail drafts with or before `fm-windows`. It would hold the owner's windows and Discard behind the engine for weeks, and using `drafts.create` for accounts still on IMAP needs Gmail draft ids for IMAP rows, a bridge between the two engines that is more risk than the roughly 30 small APPENDs a day it would save. Automatic saving stays off on IMAP, and the APPENDs are listed as a risk (§15.1) |
| B16 | major | "New" meant "above the top": a slowly scanned message is missed, recently dated imports are announced, and rules never run during a flood | Accepted | New mail is decided by `internalDate` against the last check less 10 minutes, excluding FalconMail's own imports and, during a flood, mail dated before it began; rules run during floods (§4.3, §4.7, §7.6) |
| B17 | major | Two installs each within their own ceiling do not stay within the per-user limit together | Accepted | Same change as A1 (§1.3, §11.1, §15.1) |
| B18 | major | Commands on the old selection path act on the first 1,000 rows and silently leave the rest | Accepted | Above 1,000 they use the whole-view predicate or refuse; a test with 1,001 rows (§5.8) |
| B19 | major | "A 400 or 403 puts the rows back" would undo the owner's changes on a rate-limit 403 | Accepted | 403s are sorted by reason: rate and quota reasons wait; only definite refusals put rows back (§7.3, §10.2) |
| B20 | minor | Journal rules contradicted each other: listing pages carry no cursor record, and listings could overwrite held changes | Accepted | Two kinds of journal record; resync removals only with `resyncEnd`; held changes are protected from listings too (§4.4, §4.5, §7.5) |
| B21 | minor | No way to see new mail while a resync runs or waits out its 6-hour limit | Accepted | Each check lists the top of All Mail during a resync; the 6-hour limit covers only the full relisting (§4.4) |
| B22 | minor | `session.json` is rewritten, so old entries do not stay; `acc:gm` keys could leak into v1.10.0's fields; restored windows would not know their folder | Accepted | Old entries carried forward; Google keys only in new fields; each window stores its folder, tray state and title (§5.9, §12.2) |
| B23 | minor | Going back and then forward again duplicates drafts saved under v1.10.0 | Accepted | Drafts without a Gmail id are matched by header or Message-ID before creating; a fixture test (§12.4, §14.3) |
| B24 | minor | The "read-only" probe trashes a message | Accepted | The probe has a read-only part and a write part; the write part needs the owner's approval (O5), works only on its own messages under a probe label, and deletes them at the end (§14.4, §15.3) |
| B25 | minor | FalconMail's own imports stay invisible for up to 10 minutes, inviting a second import | Accepted | Imported messages show at once from Gmail's answer (§9.1). Same change as A7 |
| B26 | minor | Nothing said Google folders never go through `MailStore`, which rewrites `folders.json` and deletes folder directories | Accepted | Stated, and a test hashes the account's old files before and after the full scenario (§2.2, §12.3, §14.3) |

### Review C: fidelity to Outlook

| # | Severity | The point | Decision | What changed, and where |
|---|---|---|---|---|
| C1 | major | Google folder names and order are Gmail's IMAP ones, not those in the owner's Legacy Outlook screenshot (Drafts, Archive, Sent, Deleted Items, Junk Email, Important, Starred) | **Accepted with a change** | Outlook's names and order; the group keeps the account's name; the same names in the Move menu, conversation rows, the Folder column and status texts; the Folder column's rule (§2.2, §5.5). **The change:** a test checks the names and order in code; the screenshot shows the owner's real mail, so it is compared by eye only and never used in a test |
| C2 | major | Archive and Move are undefined in Sent, Drafts, Starred, Important, Junk Email and Deleted Items, and Move offers folders Gmail refuses | Accepted | The per-folder table and move targets; Delete in Drafts discards after the undo window; §7.1 says plainly that Delete reaches every folder, and O4 asks whether he wants Outlook's per-folder delete (§7.1, §15.3). Same change as B11 |
| C3 | major | Notifications and their buttons look the message up in `MailStore`, which never finds a Gmail key | Accepted | Both go through `ListSource`, select the row with Focused and Other in mind, and act through the Gmail change path; the scenario test clicks them (§4.7, §12.5) |
| C4 | major | `fm-windows`' message window closes itself when the lookup fails, so offline or paused Google messages would vanish; there is no tray state for Gmail windows; chip titles stay empty | Accepted | `RowAvailability` tells "gone" from "unavailable"; only "gone" closes a window; `gmailWindows` stores tray state and title; the chip title updates; engine changes advance `openMessagesRevision` (§5.2, §5.9) |
| C5 | major | Closing offline shows nothing in Drafts, so the message looks lost; a draft could be opened twice | Accepted | A provisional row in Drafts at once, with a sentence; a draft already open is brought forward (§5.9, §8.4) |
| C6 | major | The status bar's "Items:" would still count loaded rows, which is where the owner saw "only about 1,000" | Accepted | Items comes from the index; G4 owns it, with a test of "Items: 200,000" (§5.11, §14.3) |
| C7 | major | Important is shown but never listed at first load; CHAT is never listed though views rely on it | Accepted | IMPORTANT is listed with the others; CHAT is listed if the probe finds chats in lists, otherwise nothing is needed (§2.2, §3, §14.4) |
| C8 | major | Offline, grey rows stay grey for good, and hover buttons act on rows nobody can read | **Accepted with a change** | Offline, or paused over a minute, only rows with text are shown, followed by one footer line with the count; the Items count stays true; hover buttons are hidden on placeholders; Outlook's wording in the reading pane (§5.7). **The change:** the scroll bar follows the rows shown, since a bar sized for rows that are not drawn would scroll into empty space |
| C9 | major | Conversation rows wait for `threads.get` even when cached, and show no senders offline | Accepted | Same change as A5 (§2.4, §5.4, §14.6) |
| C10 | major | Rows beyond the 1,000 turn grey on every launch; the first screen kept per folder is shorter than the list shows; the cap arithmetic did not add up | **Accepted with a change** | First screens sized from the owner's last list height, 20–30 rows, for the Inbox and the 12 most used folders, at most 390 slots (§2.4). **The change:** keeping the text of rows already seen is decision O3, and the default follows the owner's rule "latest 1000 emails. That's it."; the design says what he sees if he keeps it (§2.4, §15.3) |
| C11 | major | Sorting by From, To or Subject hides everything but the newest 1,000 and makes the count wrong | Accepted | Every row stays; rows with text are grouped, the rest follow by date; up to 200 more fetched per sort; a new footer (§5.5, §15.2) |
| C12 | major | A short Gmail pause would at once show the account offline and drop it from "Connected to:" | Accepted | `.apiPaused` only after 60 s, with the hourglass; the account stays connected; `pausedAccountNotices` gains it; a test (§4.7, §5.11, §10.2) |
| C13 | minor | Open question 4 set Gmail's Archive against "Outlook's Archive folder", but for Gmail they are the same | Accepted | Now a settled statement (§15.2) |
| C14 | minor | Drafts shows no count, though Outlook shows the number of drafts, which is the sign that closing saved | Accepted | Drafts shows its number of drafts, provisional ones included (§2.2, §2.5, §8.4) |
| C15 | minor | The API does not carry "Show in IMAP", so labels the owner had hidden would appear | Accepted | The switch keeps the folders `folders.json` showed; new labels are shown; "Show all Gmail labels" in Settings; hidden labels cost nothing (§2.2) |
| C16 | minor | Other would hold Updates (confirmations, shipping, bills), and there is no Move to Focused or Other | Accepted | Focused holds Primary, Updates and uncategorised mail; a setting moves Updates to Other; Move to Focused and Move to Other; the Focused-only badge option enabled (§5.3, §7.1, §15.2) |
| C17 | minor | Delete Conversation is a new command, unrequested, that would trash sent replies | Accepted | Dropped (§5.4, §7.1) |
| C18 | minor | Several status sentences were jargon or misleading, and "All folders are up to date." could show during the first listing | Accepted | Progress in the status bar in FalconMail's words; new sentences for waiting and for downloads; "up to date" only once every shown folder is listed (§3, §5.11, §10.2) |
| C19 | minor | Gmail's limit is 25 MB of attachments before encoding and 35 MB encoded; the sentence gave 35 MB | Accepted | Both are checked; the sentence points to Google Drive (§6) |
| C20 | minor | Dropping Spotlight removes a search path the owner may use | Accepted | The cached 1,000 are indexed and removed on eviction (§2.4, §12.1) |
| C21 | minor | `fm-windows` deletes the saved draft at once on Discard, while the design deleted it after the undo window | Accepted | One rule, after the undo window, for every account, written in §8.4 and shipped in `fm-windows` as E1 (§8.4, §14.2) |
