#if DEBUG
import SwiftUI
import AppKit
import WebKit
import FalconCore

/// `-FalconMailSnapshot <directory>` draws the compose window's title band and ribbon, the
/// ribbon over a body with ¶ showing its marks, the Table picker idle and with a size and text to
/// convert, the address suggestions over a compose window's header, a message's own window with
/// its Message ribbon, a compose window with Discard beside Send, the tray at the foot of the
/// mailbox window holding a minimised message window and a minimised compose window, and the
/// status bar offering Undo after a message is discarded, the main window's Home ribbon,
/// which shares the compose ribbon's tiles, the reading header with a subject too long for its
/// line, folded and shown whole, the Settings window's icon grid, its Signatures pane
/// with two stand-in signatures, with none and with its notice of a damaged file set aside, its
/// Notifications and Sounds pane and every other pane, the Privacy pane with its diagnostics
/// section as a release build shows it and the sheet of data waiting to be sent, and a
/// signature's editor window for a signature, for a new one and with ¶ showing the marks for
/// what does not print, a new message whose signature has a logo, replies quoting a message from
/// Outlook with its logo and one from Gmail whose logo is fetched from the web, with pictures from
/// the web off and on, in both appearances into PNGs at twice their size in that directory, with
/// the messages they would send as inline-sample.eml and reply-quote-sample.eml,
/// writes down beside them the words and buttons of the question asked before a signature is
/// deleted, the message list with made-up conversations, a made-up conversation of four
/// messages stacked in the reading pane and in its own window, the newest open and the rest
/// folded, the unread one with its blue dot, the mailbox window filling a 1728 × 1117 point
/// screen with a message window alone in the middle and two minimised to tabs in its status bar,
/// then with a message window and a compose window side by side and one tab, and those tabs
/// close up, and a reply to a made-up chain from Outlook for Mac, Outlook for Windows and Gmail
/// as its compose window shows it, also made narrower and wider, as the reader shows what it
/// sends and as that HTML reads 600 and 1200 points wide, written as outlook-chain-reply.eml,
/// then quits. With `-FalconMailSnapshotOnly list` it draws the message list alone, with
/// `stack` the conversation alone, with `fullscreen` the mailbox window filling the screen
/// alone, with `signature-import` only the Signatures pane offering an import, the import sheets
/// for Outlook and Gmail, macOS's refusal and the pane after an import, all with made-up
/// signatures, with `chain` the reply to the chain alone, and `stack50` times a conversation of
/// fifty messages instead, writing how long it held up the main thread, and with
/// `sent-recipients` a made-up message the owner sent to people in To, Cc and Bcc, as the
/// reading pane, its own window and its conversation show it, with the Outbox, the status bar
/// while it is sending and the compose window that wrote it.
/// Nothing is ever put on screen or activated, so they can be measured against Outlook's while
/// the Mac is in use; the settings windows are drawn as they look in front, as Outlook's were
/// captured. Run it with CFFIXED_USER_HOME pointing at an empty folder, so the model reads no
/// mail; the stand-in signatures are held in memory and never saved.
enum ComposeSnapshot {
    private static let appearances: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]

    @MainActor static func runIfRequested() {
        guard let directory = UserDefaults.standard.string(forKey: "FalconMailSnapshot") else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        // A body that exists but has not been clicked, as in a fresh message.
        let formatter = TextFormatter()
        formatter.attach(ComposeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200)))
        let model = AppModel()
        let only = UserDefaults.standard.string(forKey: "FalconMailSnapshotOnly")
        if only == "stack" {
            conversationStack(model, to: directory)
            exit(0)
        }
        if only == "stack50" {
            longConversation(model, to: directory)
            exit(0)
        }
        if only == "fullscreen" {
            fullScreen(model, to: directory)
            exit(0)
        }
        if only == "signature-import" {
            signatureImport(model, to: directory, prefix: "fm-sig-import")
            exit(0)
        }
        if only == "sent-recipients" {
            sentRecipients(model, to: directory)
            exit(0)
        }
        messageList(model, to: directory)
        if only == "list" { exit(0) }
        if only == "chain" {
            outlookChain(model, to: directory)
            exit(0)
        }
        for (name, appearance) in appearances {
            render(ribbon(formatter), size: NSSize(width: OL.composeWindowWidth, height: 160), appearance: appearance,
                   to: "\(directory)/ribbon-\(name).png")
            render(composeWithMarks(), size: NSSize(width: OL.composeWindowWidth, height: 380), appearance: appearance,
                   to: "\(directory)/compose-marks-\(name).png")
            let menu = NSSize(width: TableGrid.width, height: 272)
            render(picker(hovering: nil, converts: false), size: menu, appearance: appearance, to: "\(directory)/table-\(name).png")
            render(picker(hovering: TableSize(columns: 3, rows: 4), converts: true), size: menu, appearance: appearance,
                   to: "\(directory)/table-hover-\(name).png")
            suggestions(model, appearance: appearance, to: directory, name: name)
            render(CommandBar().environment(model).frame(maxHeight: .infinity, alignment: .top),
                   size: NSSize(width: 1728, height: 140), appearance: appearance,
                   to: "\(directory)/home-\(name).png")
            for expanded in [false, true] {
                render(MessageReaderView(message: longSubject, subjectExpanded: expanded)
                        .environment(model).environmentObject(model.updates).themedRoot(),
                       size: NSSize(width: 760, height: 220), appearance: appearance,
                       to: "\(directory)/reading-subject-\(expanded ? "expanded" : "collapsed")-\(name).png")
            }
        }
        windows(model, to: directory)
        fullScreen(model, to: directory)
        signatures(model, to: directory)
        signatureImport(model, to: directory, prefix: "signature-import")
        inlinePictures(model, to: directory)
        replyQuotes(model, to: directory)
        conversationStack(model, to: directory)
        sentRecipients(model, to: directory)
        outlookChain(model, to: directory)
        // Before the settings panes, so that the Privacy pane shows the release build's stand-in.
        privacy(model, to: directory)
        for (name, appearance) in appearances {
            captureSettings(nil, model: model, active: false, appearance: appearance, to: "\(directory)/settings-grid-\(name).png")
            captureSettings(.notifications, model: model, active: true, appearance: appearance,
                            to: "\(directory)/notifications-\(name).png")
            // A pane that scrolls does not come out of a titled window with a toolbar offscreen on
            // macOS 26, so the other panes are drawn on their own, without the window's buttons.
            for pane in SettingsPane.allCases where pane != .signatures && pane != .notifications {
                render(SettingsRoot(navigator: SettingsNavigator(pane: pane))
                        .environment(\.controlActiveState, .key).environment(model).environmentObject(model.updates).themedRoot(),
                       size: pane.windowSize, appearance: appearance, to: "\(directory)/settings-\(pane.rawValue)-\(name).png")
            }
            // macOS draws an alert's glass, words and buttons itself, so offscreen only its icon
            // comes out; what it says and how its buttons stand is written down instead.
            let alert = SignatureDeletion.alert()
            alert.window.appearance = NSAppearance(named: appearance)
            alert.layout()
            try? describe(alert).write(toFile: "\(directory)/delete-alert-\(name).txt", atomically: true, encoding: .utf8)
        }
        exit(0)
    }

    /// The message list at Outlook's width, over made-up mail: an unread conversation opened
    /// out with its newest message selected, read conversations with previews, a paperclip, an
    /// unread count, names too long for their line, senders sent on by a group, one message
    /// whose preview has not arrived, a flag, and dates of today, yesterday and earlier. Drawn
    /// with the list holding the keyboard, as Outlook's was captured, once without, and once
    /// with the pointer on a conversation.
    @MainActor private static func messageList(_ model: AppModel, to directory: String) {
        let account = AccountInfo(email: "alex@example.com", displayName: "Alex Example", provider: "imap",
                                  imapHost: "example.invalid", smtpHost: "example.invalid")
        model.accounts = [account]
        let threads = ListSnapshotMail(accountID: account.id).threads
        model.threads = threads
        model.messages = threads.flatMap(\.messages)
        model.storedInSelection = 300
        model.rebuildRows()
        model.expandedThreadIDs = [threads[0].id]
        model.selectedMessageIDs = [ListRow.childTag(threads[0].messages[0].id)]
        let size = NSSize(width: OL.listWidth, height: 830)
        for (focused, suffix) in [(true, ""), (false, "-unfocused")] {
            MessageListView.snapshotListHasKeyboard = focused
            for (name, appearance) in appearances {
                render(MessageListView().environment(model).environmentObject(model.updates).themedRoot(),
                       size: size, appearance: appearance, to: "\(directory)/list\(suffix)-\(name).png")
            }
        }
        // The pointer on the conversation with the count, its quick actions over its icons.
        MessageListView.snapshotListHasKeyboard = true
        ConversationRow.snapshotHoveredID = threads[4].id
        render(MessageListView().environment(model).environmentObject(model.updates).themedRoot(),
               size: size, appearance: .darkAqua, to: "\(directory)/list-hover-dark.png")
        ConversationRow.snapshotHoveredID = nil
        MessageListView.snapshotListHasKeyboard = nil
        model.threads = []
        model.messages = []
        model.expandedThreadIDs = []
        model.selectedMessageIDs = []
        model.rebuildRows()
    }

    /// A made-up conversation of four messages as the reading pane stacks it and as its own
    /// window shows it: the newest open, quoting the one under it behind •••, and the other three
    /// folded to a line each, the unread one under it with its blue dot and blue sender. Their
    /// text is handed to the model as if fetched, and WebKit draws it as the app does.
    @MainActor private static func conversationStack(_ model: AppModel, to directory: String) {
        let account = AccountInfo(email: "alex@example.com", displayName: "Alex Example", provider: "imap",
                                  imapHost: "example.invalid", smtpHost: "example.invalid")
        model.accounts = [account]
        let mail = StackSnapshotMail(accountID: account.id).messages
        for (message, parsed) in mail { model.snapshotBody(parsed, for: message.id) }
        let messages = mail.map(\.0)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        for (name, appearance) in appearances {
            let pane = host(ConversationStackView(messages: messages).environment(model).environmentObject(model.updates).themedRoot(),
                            size: NSSize(width: 1728 - OL.sidebarWidth - OL.listWidth, height: 840), appearance: appearance)
            captureWithMessages(pane, appearance: appearance, to: "\(directory)/convstack-pane-\(name).png")
            let window = host(MessageWindowView(messageID: messages[0].id, message: messages[0], conversation: messages)
                                .themedRoot().environment(model).environmentObject(model.updates),
                              size: NSSize(width: 917, height: 1006), appearance: appearance, style: style)
            captureWithMessages(window, appearance: appearance, to: "\(directory)/convstack-window-\(name).png")
        }
    }

    /// A made-up reply the owner sent to two people, copying three and blind-copying two, as the
    /// reading pane shows it in Sent, as its own window shows it, and as the second card of its
    /// conversation; the Outbox and the status bar while it waits to go, naming every box; and the
    /// compose window it was written in, its Bcc row showing because it names someone although the
    /// Bcc button is off. The Bcc recipients are shown from the record written as it was sent,
    /// since what went out, and so Gmail's copy in Sent Mail, does not name them.
    @MainActor private static func sentRecipients(_ model: AppModel, to directory: String) {
        let account = AccountInfo.google(email: "alex@example.com", displayName: "Alex Example")
        model.accounts = [account]
        let me = EmailAddress(name: "Alex Example", address: "alex@example.com")
        let ana = EmailAddress(name: "Ana Lee", address: "ana.lee@example.com")
        let al = EmailAddress(name: "Al Karimov", address: "al.karimov@example.com")
        let cc = [EmailAddress(name: "Bob Stone", address: "bob.stone@example.com"), EmailAddress(name: "Ben Ng", address: "ben.ng@example.com"),
                  EmailAddress(address: "dispatch@example.com")]
        let bcc = [EmailAddress(name: "Cy Young", address: "cy.young@example.com"), EmailAddress(name: "Operations", address: "ops@example.com")]
        let sentDate = Date(timeIntervalSince1970: 1_790_003_600)
        let original = OutgoingMessage(from: ana, to: [me, al], cc: [cc[0]], subject: "Rates for the Baku run",
                                       textBody: "Hello Alex,\n\nCould you send over the rates for the Baku run next week? Bob is copied.\n\nAna\n",
                                       messageID: "<rates-1@example.com>", date: Date(timeIntervalSince1970: 1_790_000_000))
        let reply = OutgoingMessage(from: me, to: [ana, al], cc: cc, bcc: bcc, subject: "Re: Rates for the Baku run",
                                    textBody: "Hello Ana,\n\nThe rates are below; Bob, Ben and dispatch are copied so they can book the trucks.\n\nAlex\n",
                                    inReplyTo: "<rates-1@example.com>", references: ["<rates-1@example.com>"],
                                    messageID: "<rates-reply-1@example.com>", date: sentDate)
        // What sending it writes down; what went out names no Bcc.
        model.outbox.sentBcc.record(messageID: reply.messageID, bcc: reply.bcc, at: sentDate)
        func summary(_ m: OutgoingMessage, uid: UInt32, folder: UUID) -> MessageSummary {
            let parsed = MIMEParser.parse(MIMEBuilder.build(m))
            let row = MessageSummary(accountID: account.id, folderID: folder, uid: uid, messageID: m.messageID, inReplyTo: m.inReplyTo ?? "",
                                     references: m.references, subject: m.subject, from: parsed.from, to: parsed.to, cc: parsed.cc,
                                     date: m.date, flags: [.seen], size: 2048, snippet: parsed.snippet, hasAttachments: false, hasBody: true,
                                     threadKey: "rates")
            model.snapshotBody(parsed, for: row.id)
            return row
        }
        let inbox = summary(original, uid: 1, folder: UUID())
        let sent = summary(reply, uid: 2, folder: UUID())
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // Queued just now, so that it is still in its ten seconds to undo as it is drawn.
        func queued() -> OutboxItem {
            var item = OutboxItem(accountID: account.id, subject: reply.subject, recipients: reply.allRecipients, sender: me.address,
                                  sendAt: Date().addingTimeInterval(5), undoWindow: 10)
            item.to = reply.to
            item.cc = reply.cc
            item.bcc = reply.bcc
            item.messageID = reply.messageID
            return item
        }
        var draft = ComposeDraft(accountID: account.id)
        draft.to = OutgoingRecipients.box(reply.to)
        draft.cc = OutgoingRecipients.box(reply.cc)
        draft.bcc = OutgoingRecipients.box(reply.bcc)
        draft.subject = reply.subject
        draft.body = reply.textBody
        let draftID = model.newDraft(draft)
        defer { model.drafts[draftID] = nil }
        for (name, appearance) in appearances {
            let pane = host(MessageReaderView(message: sent).environment(model).environmentObject(model.updates).themedRoot(),
                            size: NSSize(width: 1728 - OL.sidebarWidth - OL.listWidth, height: 420), appearance: appearance)
            captureWithMessages(pane, appearance: appearance, to: "\(directory)/sent-recipients-reading-\(name).png")
            let window = host(MessageWindowView(messageID: sent.id, message: sent).themedRoot().environment(model)
                                .environmentObject(model.updates),
                              size: NSSize(width: 917, height: 560), appearance: appearance, style: style)
            captureWithMessages(window, appearance: appearance, to: "\(directory)/sent-recipients-window-\(name).png")
            let stack = host(ConversationStackView(messages: [sent, inbox]).environment(model).environmentObject(model.updates).themedRoot(),
                             size: NSSize(width: 1728 - OL.sidebarWidth - OL.listWidth, height: 520), appearance: appearance)
            captureWithMessages(stack, appearance: appearance, to: "\(directory)/sent-recipients-stack-\(name).png")
            model.outboxItems = [queued()]
            render(OutboxView().environment(model).themedRoot(), size: NSSize(width: 900, height: 120), appearance: appearance,
                   to: "\(directory)/sent-recipients-outbox-\(name).png")
            render(VStack(spacing: 0) { Spacer(minLength: 0); StatusBar() }.environment(model).themedRoot(),
                   size: NSSize(width: 1728, height: 40), appearance: appearance, to: "\(directory)/sent-recipients-status-\(name).png")
            model.outboxItems = []
            let compose = host(ComposeView(draftID: draftID).themedRoot().environment(model).environmentObject(model.updates),
                               size: NSSize(width: OL.composeWindowWidth, height: 420), appearance: appearance, style: style)
            capture(compose, appearance: appearance, to: "\(directory)/sent-recipients-compose-\(name).png")
        }
    }

    /// A made-up conversation of fifty messages, each quoting all before it as Gmail does, stacked
    /// in the reading pane twice: read, as it opens with only the newest open, and unread, with
    /// all fifty opened as Expand all opens them. How long the main thread is held up is written
    /// to convstack-50-timing.txt: the first layout, and the longest the main thread went
    /// unanswered while every message loaded and was measured. The unread stack is drawn to convstack-50-light.png.
    @MainActor private static func longConversation(_ model: AppModel, to directory: String) {
        let account = AccountInfo(email: "alex@example.com", displayName: "Alex Example", provider: "imap",
                                  imapHost: "example.invalid", smtpHost: "example.invalid")
        model.accounts = [account]
        var report = ""
        for unread in [false, true] {
            let mail = LongConversationMail(accountID: account.id, unread: unread).messages
            for (message, parsed) in mail { model.snapshotBody(parsed, for: message.id) }
            let messages = mail.map(\.0)
            let started = Date()
            let pane = host(ConversationStackView(messages: messages, expandedAll: unread).environment(model)
                                .environmentObject(model.updates).themedRoot(),
                            size: NSSize(width: 1728 - OL.sidebarWidth - OL.listWidth, height: 840), appearance: .aqua)
            pane.layoutSubtreeIfNeeded()
            let firstLayout = Date().timeIntervalSince(started)
            // Every pass of the run loop is asked to last at most 5 ms; the longest one is the
            // longest the main thread was held up by the stack's own work.
            var longest: TimeInterval = 0
            var allMeasuredAfter: TimeInterval?
            let deadline = Date(timeIntervalSinceNow: 30)
            while Date() < deadline {
                let pass = Date()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
                pane.layoutSubtreeIfNeeded()
                longest = max(longest, Date().timeIntervalSince(pass))
                let webs = views(of: ReaderWebView.self, in: pane).filter(\.fitsContent)
                if allMeasuredAfter == nil, !webs.isEmpty, webs.allSatisfy(\.measured) {
                    allMeasuredAfter = Date().timeIntervalSince(started)
                }
                if let after = allMeasuredAfter, Date().timeIntervalSince(started) > after + 3 { break }
            }
            let open = views(of: ReaderWebView.self, in: pane).filter(\.fitsContent).count
            report += "\(unread ? "All 50 unread" : "All 50 read"): \(open) open message views; first layout "
                + "\(Int(firstLayout * 1000)) ms; all measured after \(allMeasuredAfter.map { "\(Int($0 * 1000)) ms" } ?? "never"); "
                + "longest main-thread pass \(Int(longest * 1000)) ms\n"
            if unread { captureWithMessages(pane, appearance: .aqua, to: "\(directory)/convstack-50-light.png") }
        }
        try? report.write(toFile: "\(directory)/convstack-50-timing.txt", atomically: true, encoding: .utf8)
    }

    /// As `capture`, for a view holding messages, which WebKit draws in another process where
    /// cacheDisplay cannot see them: once every message has loaded and been measured, and the
    /// stack has stood still for three seconds, each message's own picture is laid over the view's
    /// where it shows.
    @MainActor private static func captureWithMessages(_ view: NSView, appearance: NSAppearance.Name, to path: String) {
        let deadline = Date(timeIntervalSinceNow: 25)
        var stillSince: Date?
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            view.layoutSubtreeIfNeeded()
            let messages = views(of: ReaderWebView.self, in: view).filter(\.fitsContent)
            guard !messages.isEmpty, messages.allSatisfy(\.measured) else {
                stillSince = nil
                continue
            }
            let since = stillSince ?? Date()
            stillSince = since
            if Date().timeIntervalSince(since) > 3 { break }
        }
        guard let rep = image(of: view, appearance: appearance) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for web in views(of: ReaderWebView.self, in: view) {
            let shown = web.visibleRect.intersection(web.bounds)
            guard !shown.isEmpty, let picture = picture(of: web) else { continue }
            let inView = web.convert(shown, to: view)
            let target = view.isFlipped
                ? NSRect(x: inView.minX, y: view.bounds.height - inView.maxY, width: inView.width, height: inView.height) : inView
            let source = web.isFlipped
                ? NSRect(x: shown.minX, y: web.bounds.height - shown.maxY, width: shown.width, height: shown.height) : shown
            picture.draw(in: target, from: source, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        write(rep, to: path)
    }

    /// What WebKit has drawn of `web`, the size of its bounds. WebKit sometimes has nothing to
    /// give the first time it is asked, so it is asked a few times.
    @MainActor private static func picture(of web: WKWebView) -> NSImage? {
        for _ in 0..<5 {
            var result: NSImage?
            var done = false
            web.takeSnapshot(with: nil) { image, _ in
                result = image
                done = true
            }
            let deadline = Date(timeIntervalSinceNow: 5)
            while !done, Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
            if let result { return result }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        }
        return nil
    }

    /// A made-up message whose subject is far too long for the reading header's one line. Its
    /// account is none the model knows, so the reader finds no text for it and fetches none.
    private static var longSubject: MessageSummary {
        MessageSummary(accountID: UUID(), folderID: UUID(), uid: 1, messageID: "<snapshot@example.com>", inReplyTo: "",
                       references: [], subject: "Re: Quarterly freight schedule for the northern warehouses / Order 2026-0417 - "
                        + "pallets, customs papers and the revised delivery windows for every depot // Ref: NW-SCHED-26-Q4-FINAL",
                       from: EmailAddress(name: "Planning Desk", address: "planning@example.com"),
                       to: [EmailAddress(name: "Dispatch Team", address: "dispatch@example.com")], cc: [],
                       date: Date(timeIntervalSince1970: 1_790_000_000), flags: [.seen], size: 0,
                       snippet: "Please see the schedule below.", hasAttachments: false)
    }

    /// The Signatures pane with no signatures, offering to import them, and with one, its action
    /// menu beside + and −; the import sheet over made-up signatures from Outlook, one of them
    /// named as a signature already here, and from Gmail, with its logo; the sheet saying macOS
    /// refused; and the pane after the import, saying what it did. Nothing is read from Outlook
    /// or asked of Gmail: the signatures are written here, the logo drawn here.
    @MainActor private static func signatureImport(_ model: AppModel, to directory: String, prefix: String) {
        let alex = AccountInfo.google(email: "alex@example.com", displayName: "Alex Example")
        let office = AccountInfo(email: "office@example.org", displayName: "Example Office", provider: "imap",
                                 imapHost: "example.invalid", smtpHost: "example.invalid")
        model.accounts = [alex, office]
        var book = SignatureBook()
        let mine = book.add(startingWith: "Alex")
        book.rename(mine.id, to: "Test Signature")
        let logo = madeUpLogo()
        let outlook = [
            SignatureCandidate(name: "Test Signature", origin: .outlook(profile: "Main Profile"), html: madeUpWordSignature,
                               pictures: [MIMEAttachment(picture: logo, filename: "image001.jpg", mimeType: "image/jpeg",
                                                         contentID: "image001.jpg@01DD0000.00000000")],
                               defaultAddresses: ["alex@example.com", "office@example.org"]),
            SignatureCandidate(name: "Test Signature – short", origin: .outlook(profile: "Main Profile"),
                               html: "<p class=MsoNormal><span style='font-size:10.0pt;font-family:\"Helvetica Neue\"'>Alex</span></p>"),
        ]
        let gmailLogo = "https://lh3.example.com/logo.jpg"
        let gmail = SignatureCandidate(name: "Gmail – alex@example.com", origin: .gmail(account: "alex@example.com"),
                                       html: "<div dir=\"ltr\"><div><b>Alex Example</b></div><div>Operations Lead</div>"
                                           + "<img src=\"\(gmailLogo)\" width=\"96\" height=\"29\"></div>",
                                       defaultAddresses: ["alex@example.com"], defaultsKnown: true)
        for (name, appearance) in appearances {
            model.signatures = SignatureLibrary(book: SignatureBook())
            captureSettings(.signatures, model: model, active: true, appearance: appearance, to: "\(directory)/\(prefix)-pane-empty-\(name).png")
            model.signatures = SignatureLibrary(book: book)
            captureSettings(.signatures, model: model, active: true, appearance: appearance, to: "\(directory)/\(prefix)-pane-\(name).png")

            let session = SignatureImportSession(source: .outlook)
            session.origin = "From the Outlook profile “Main Profile”."
            session.defaultsKnown = false
            session.prepare(outlook, model: model, remote: [:])
            render(SignatureImportSheet(session: session, perform: {}, close: {}).environment(model).themedRoot(),
                   size: SignatureImportSheet.size, appearance: appearance, to: "\(directory)/\(prefix)-sheet-\(name).png")

            let fromGmail = SignatureImportSession(source: .gmail)
            fromGmail.origin = "From the Gmail settings of alex@example.com."
            fromGmail.prepare([gmail], model: model, remote: [gmailLogo: logo])
            render(SignatureImportSheet(session: fromGmail, perform: {}, close: {}).environment(model).themedRoot(),
                   size: SignatureImportSheet.size, appearance: appearance, to: "\(directory)/\(prefix)-gmail-sheet-\(name).png")

            let refused = SignatureImportSession(source: .outlook)
            refused.stage = .failed(SignatureImportSession.sentence(for: .notAllowed), privacy: true)
            render(SignatureImportSheet(session: refused, perform: {}, close: {}).environment(model).themedRoot(),
                   size: NSSize(width: SignatureImportSheet.size.width, height: SignatureImportSheet.shortHeight), appearance: appearance,
                   to: "\(directory)/\(prefix)-sheet-refused-\(name).png")

            // The import done, Test Signature replacing the one here: the sheet saying what it
            // did, then the pane with the line saying so.
            let library = SignatureLibrary(book: book)
            session.setClash(.replace, session.rows[0].id)
            let result = session.importChosen(into: library, accounts: model.accounts)
            render(SignatureImportSheet(session: session, perform: {}, close: {}).environment(model).themedRoot(),
                   size: NSSize(width: SignatureImportSheet.size.width, height: SignatureImportSheet.shortHeight), appearance: appearance,
                   to: "\(directory)/\(prefix)-sheet-done-\(name).png")
            model.signatures = library
            SignaturesSettings.snapshotImported = result.line
            captureSettings(.signatures, model: model, active: true, appearance: appearance, to: "\(directory)/\(prefix)-pane-after-\(name).png")
            SignaturesSettings.snapshotImported = nil
        }
        model.signatures = SignatureLibrary(book: SignatureBook())
        model.accounts = []
    }

    /// A made-up logo, 192 × 58 pixels, as a JPEG like the one Word keeps.
    private static func madeUpLogo() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 192, pixelsHigh: 58, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: 0.12, green: 0.22, blue: 0.39, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 192, height: 58).fill()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 58, height: 58).fill()
        ("EXAMPLE" as NSString).draw(at: NSPoint(x: 70, y: 18), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 20),
                                                                                 .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) ?? Data()
    }

    /// Word's HTML for a made-up signature, as Legacy Outlook keeps one: MsoNormal paragraphs in
    /// points, conditional comments, and its picture drawn by VML for Word beside an ordinary one.
    private static let madeUpWordSignature = """
        <html xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office" \
        xmlns="http://www.w3.org/TR/REC-html40"><head><style><!--
        p.MsoNormal, li.MsoNormal, div.MsoNormal {margin:0cm; font-size:12.0pt; font-family:"Calibri",sans-serif;}
        --></style><!--[if gte mso 9]><xml><o:shapedefaults v:ext="edit" spidmax="1026" /></xml><![endif]--></head>\
        <body lang=EN-GB link="#0563C1" vlink="#954F72"><div class=WordSection1><p class=MsoNormal><b><span \
        style='font-size:10.0pt;font-family:"Helvetica Neue";color:#1F3864'>Alex Example<o:p></o:p></span></b></p>\
        <p class=MsoNormal><span style='font-size:9.0pt;font-family:"Helvetica Neue";color:#444444'>Operations Lead | \
        Example Freight Ltd<o:p></o:p></span></p><p class=MsoNormal><span style='font-size:9.0pt;font-family:Helvetica;\
        color:black'>Tel: +44 20 7946 0000 | <a href="https://example.com/"><span style='color:#0563C1'>example.com</span>\
        </a><o:p></o:p></span></p><p class=MsoNormal><span style='font-size:10.0pt;color:black'><!--[if gte vml 1]><v:shape \
        id="Picture_x0020_1" style='width:72pt;height:21.75pt'><v:imagedata src="cid:image001.jpg@01DD0000.00000000" \
        o:title=""/></v:shape><![endif]--><![if !vml]><img width=96 height=29 style='width:1.0in;height:.302in' \
        src="cid:image001.jpg@01DD0000.00000000" v:shapes="Picture_x0020_1"><![endif]></span></p>\
        <p class=MsoNormal><o:p>&nbsp;</o:p></p></div></body></html>
        """

    /// A Settings window at `pane`, built as the app builds it but drawn as it looks in front
    /// when `active`.
    @MainActor private static func captureSettings(_ pane: SettingsPane?, model: AppModel, active: Bool,
                                                   appearance: NSAppearance.Name, to path: String) {
        let navigator = SettingsNavigator(pane: pane)
        let window = SettingsWindows.window(navigator: navigator, model: model, updates: model.updates)
        let root = SettingsRoot(navigator: navigator)
            .environment(\.controlActiveState, active ? .key : .inactive)
            .environment(model)
            .environmentObject(model.updates)
            .themedRoot()
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        window.contentView = host
        window.appearance = NSAppearance(named: appearance)
        guard let frame = window.contentView?.superview else { return }
        capture(frame, appearance: appearance, to: path)
    }

    /// As a release build shows it. The waiting data is what a real diagnostics centre makes of
    /// a few of the engine's failures and an alert, given as the engine gives them, kept in a
    /// temporary folder and never started on the network: it reads no crash reports, its session
    /// refuses every request, and it is stopped before its first upload is due a minute later.
    @MainActor private static func privacy(_ model: AppModel, to directory: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FalconMailSnapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let center = DiagnosticsCenter(
            directory: folder,
            gate: DiagnosticsGate(endpoint: URL(string: "https://example.invalid/exec"), key: "snapshot", isReleaseBuild: true,
                                  bundleIdentifier: DiagnosticsGate.releaseBundleIdentifier, userEnabled: true),
            environment: DiagnosticsEnvironment(app: DiagnosticsApp(version: "1.10.0", build: "123", channel: "release"),
                                                os: "macOS 26.6 (25G5023)", hardware: "MacBookPro18,3", locale: "en_GB",
                                                homePath: NSHomeDirectory()),
            crashReportsDirectory: nil,
            session: DiagnosticsUploader.makeSession(protocolClasses: [NoNetwork.self]))
        let logging = Log.isEnabled
        Log.isEnabled = false
        center.start()
        let account = AccountInfo.google(email: "alex@example.com", displayName: "Alex Example")
        let throttled = MailServiceError(kind: .throttled, account: account, detail: "BYE [THROTTLED] Account exceeded command or bandwidth limits.")
        for _ in 0..<3 {
            Log.failure("IMAP", throttled, "alex@example.com: throttled: \(throttled.detail)", account: account, logAs: "sync",
                        keeping: account.email)
        }
        let gone = MailServiceError(kind: .messageGone, account: account, detail: "UID 4127 not returned")
        Log.failure("Open", gone, "alex@example.com: opening a message in Clients/ACME failed: messageGone: \(gone.detail)",
                    account: account, names: ["Clients/ACME", "ACME"], logAs: "sync", keeping: account.email)
        Log.error("Alert", "The file “Invoice ACME.pdf” couldn’t be opened because there is no such file.")
        center.waitUntilIdle()
        let waiting = center.pendingDescription()
        center.stop()
        Log.isEnabled = logging

        DiagnosticsService.shared = DiagnosticsService(standInID: center.diagnosticsID)
        for (name, appearance) in appearances {
            render(DiagnosticsPendingSheet(text: waiting).background(Color(nsColor: .windowBackgroundColor)),
                   size: NSSize(width: 640, height: 520), appearance: appearance, to: "\(directory)/privacy-waiting-\(name).png")
        }
    }

    /// Fails every request, so nothing the snapshot builds can reach a network.
    private final class NoNetwork: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
        override func stopLoading() {}
    }

    @MainActor private static func signatures(_ model: AppModel, to directory: String) {
        let accounts = [
            AccountInfo(email: "alex@example.com", displayName: "Alex Example", provider: "imap",
                        imapHost: "example.invalid", smtpHost: "example.invalid"),
            AccountInfo(email: "office@example.com", displayName: "Example Office", provider: "imap",
                        imapHost: "example.invalid", smtpHost: "example.invalid"),
        ]
        model.accounts = accounts
        var book = SignatureBook()
        let formal = book.add()
        book.rename(formal.id, to: "Formal")
        book.setText(formalText(), of: formal.id)
        let short = book.add()
        book.rename(short.id, to: "Short")
        book.setText(NSAttributedString(string: "Alex", attributes: RichText.bodyAttributes), of: short.id,
                     plainIn: RichText.bodyAttributes)
        book.setDefault(formal.id, for: accounts[0].id, .newMessages)
        book.setDefault(short.id, for: accounts[0].id, .replies)
        // A new one as the pane's + makes it, named Untitled and holding the first account's name.
        let untitled = book.add(startingWith: accounts[0].displayName)
        let library = SignatureLibrary(book: book)
        for (name, appearance) in appearances {
            model.signatures = SignatureLibrary(book: { var shown = book; shown.remove(untitled.id); return shown }())
            captureSettings(.signatures, model: model, active: true, appearance: appearance, to: "\(directory)/signatures-\(name).png")
            model.signatures = SignatureLibrary(book: SignatureBook())
            captureSettings(.signatures, model: model, active: true, appearance: appearance,
                            to: "\(directory)/signatures-empty-\(name).png")
            let aside = URL(fileURLWithPath: "/signatures-unreadable-1790000000.json")
            model.signatures = SignatureLibrary(book: book, problem: .setAside(aside))
            captureSettings(.signatures, model: model, active: true, appearance: appearance,
                            to: "\(directory)/signatures-notice-\(name).png")
            for (id, file, marks) in [(formal.id, "signature-editor", false), (untitled.id, "signature-editor-new", false),
                                      (formal.id, "signature-editor-marks", true)] {
                guard let window = SignatureEditorWindows.window(for: id, library: library),
                      let frame = window.contentView?.superview else { continue }
                window.appearance = NSAppearance(named: appearance)
                if marks {
                    frame.layoutSubtreeIfNeeded()
                    (textView(in: frame)?.layoutManager as? SignatureLayoutManager)?.showsMarks = true
                }
                capture(frame, appearance: appearance, to: "\(directory)/\(file)-\(name).png")
            }
        }
    }

    /// The windows a message opens in and is written in, and where they go when minimised, all
    /// over made-up mail: a message window, a compose window of a reply, the tray holding one of
    /// each, and the status bar just after Discard.
    @MainActor private static func windows(_ model: AppModel, to directory: String) {
        let account = AccountInfo.google(email: "alex@example.com", displayName: "Alex Example")
        model.accounts = [account]
        let message = MessageSummary(
            accountID: account.id, folderID: UUID(), uid: 7, messageID: "<figures-7@example.com>", inReplyTo: "",
            references: [], subject: "Quarterly figures for the north office",
            from: EmailAddress(name: "Sam Taylor", address: "sam.taylor@example.com"),
            to: [EmailAddress(name: "Alex Example", address: "alex@example.com")], cc: [],
            date: Date(timeIntervalSince1970: 1_790_000_000), flags: [.seen], size: 2048,
            snippet: "Hello Alex, the figures for the quarter are in. North is up eight per cent on last year and "
                + "South held steady. I have put the full breakdown in the shared folder; the summary is below. "
                + "Could we go through it on Thursday before the board pack goes out?",
            hasAttachments: false)
        var reply = ComposeDraft(accountID: account.id)
        reply.to = "Sam Taylor <sam.taylor@example.com>"
        reply.subject = "Re: Quarterly figures for the north office"
        reply.body = "Thanks Sam, Thursday at ten works for me.\n\nAlex\n"
        let draftID = model.newDraft(reply)
        defer { model.drafts[draftID] = nil }
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        for (name, appearance) in appearances {
            let window = host(MessageWindowView(messageID: message.id, message: message)
                                .themedRoot().environment(model).environmentObject(model.updates),
                              size: NSSize(width: 917, height: 520), appearance: appearance, style: style)
            capture(window, appearance: appearance, to: "\(directory)/message-window-\(name).png")
            let compose = host(ComposeView(draftID: draftID).themedRoot().environment(model).environmentObject(model.updates),
                               size: NSSize(width: OL.composeWindowWidth, height: 420), appearance: appearance, style: style)
            capture(compose, appearance: appearance, to: "\(directory)/compose-window-\(name).png")
        }
        // Keys no window holds, so the tray keeps them as a launch puts back the ones minimised
        // at the last quit.
        WindowTray.shared.shelve(.message("snapshot-message"), title: "Quarterly figures for the north office")
        WindowTray.shared.shelve(.compose(UUID()), title: "Re: Site visit on Friday")
        let foot = NSSize(width: 1728, height: 64)
        for (name, appearance) in appearances {
            render(VStack(spacing: 0) { Spacer(minLength: 0); WindowTrayBar(); StatusBar() }.environment(model).themedRoot(),
                   size: foot, appearance: appearance, to: "\(directory)/tray-\(name).png")
        }
        model.discarded.discard(reply, now: Date())
        for (name, appearance) in appearances {
            render(VStack(spacing: 0) { Spacer(minLength: 0); StatusBar() }.environment(model).themedRoot(),
                   size: NSSize(width: 1728, height: 40), appearance: appearance, to: "\(directory)/discarded-\(name).png")
        }
        _ = model.discarded.undo(at: Date())
    }

    /// The mailbox window filling a 1728 × 1117 point screen, under the 37 point band a screen
    /// with a camera housing keeps at its top, as Outlook's was captured: a message window alone
    /// in the middle, at its own size, with a message and a message being written minimised to
    /// tabs in the status bar; then that message window and a compose window side by side, one
    /// tab left; and the status bar's tabs close up. The mailbox window and each window over it
    /// are drawn as the app draws them and put together where the layout places them, with the
    /// rounded corners, outline and shadow macOS gives a window, the green button off as it is
    /// there. All the mail is made up.
    @MainActor private static func fullScreen(_ model: AppModel, to directory: String) {
        let screen = NSSize(width: 1728, height: 1117)
        let mailbox = NSRect(x: 0, y: 0, width: screen.width, height: screen.height - 37)
        var area = mailbox
        area.origin.y += OL.fullScreenStatus
        area.size.height -= OL.fullScreenStatus

        let account = AccountInfo.google(email: "alex@example.com", displayName: "Alex Example")
        model.accounts = [account]
        let threads = ListSnapshotMail(accountID: account.id).threads
        model.threads = threads
        model.messages = threads.flatMap(\.messages)
        model.storedInSelection = model.messages.count
        model.rebuildRows()
        defer {
            model.threads = []
            model.messages = []
            model.rebuildRows()
        }
        let message = MessageSummary(
            accountID: account.id, folderID: UUID(), uid: 7, messageID: "<figures-7@example.com>", inReplyTo: "",
            references: [], subject: "Quarterly figures for the north office",
            from: EmailAddress(name: "Sam Taylor", address: "sam.taylor@example.com"),
            to: [EmailAddress(name: "Alex Example", address: "alex@example.com")], cc: [],
            date: Date(timeIntervalSince1970: 1_790_000_000), flags: [.seen], size: 2048,
            snippet: "Hello Alex, the figures for the quarter are in. North is up eight per cent on last year and "
                + "South held steady. I have put the full breakdown in the shared folder; the summary is below. "
                + "Could we go through it on Thursday before the board pack goes out?",
            hasAttachments: false)
        var reply = ComposeDraft(accountID: account.id)
        reply.to = "Sam Taylor <sam.taylor@example.com>"
        reply.subject = "Re: Quarterly figures for the north office"
        reply.body = "Thanks Sam, Thursday at ten works for me.\n\nAlex\n"
        let replyID = model.newDraft(reply)
        // What the tabs hold: a message minimised, and a message being written minimised.
        let delivery = "snapshot-delivery"
        model.messageWindowRows[delivery] = MessageSummary(
            accountID: account.id, folderID: UUID(), uid: 8, messageID: "<delivery-8@example.net>", inReplyTo: "", references: [],
            subject: "Delivery on Friday", from: EmailAddress(name: "Jordan Lee", address: "jordan@example.net"),
            to: [EmailAddress(name: "Alex Example", address: "alex@example.com")], cc: [], date: Date(timeIntervalSince1970: 1_790_003_600),
            flags: [.seen], size: 1024, hasAttachments: false)
        var site = ComposeDraft(accountID: account.id)
        site.subject = "Re: Site visit on Friday"
        let siteID = model.newDraft(site)
        defer {
            model.drafts[replyID] = nil
            model.drafts[siteID] = nil
            model.messageWindowRows[delivery] = nil
        }
        for entry in WindowTray.shared.book.tray { WindowTray.shared.close(entry.key) }

        let messageSize = FullScreenItems.openingSize(of: .message(message.id))
        let composeSize = FullScreenItems.openingSize(of: .compose(replyID))
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        for (name, appearance) in appearances {
            func messageWindow(_ frame: NSRect, inFront: Bool) -> NSBitmapImageRep? {
                itemWindow(MessageWindowView(messageID: message.id, message: message)
                            .themedRoot().environment(model).environmentObject(model.updates),
                           size: frame.size, appearance: appearance, style: style, inFront: inFront)
            }
            func mailboxWindow() -> NSBitmapImageRep? {
                image(of: host(MainWindow(snapshotFillsScreen: true).themedRoot().environment(model).environmentObject(model.updates),
                               size: mailbox.size, appearance: appearance),
                      appearance: appearance)
            }

            WindowTray.shared.shelve(.message(delivery), title: "Delivery on Friday")
            WindowTray.shared.shelve(.compose(siteID), title: "Re: Site visit on Friday")
            let alone = FullScreenLayout.frames(for: [messageSize], in: area)
            guard let backdrop = mailboxWindow(), let window = messageWindow(alone[0], inFront: true),
                  let one = screenImage(screen, mailbox: (backdrop, mailbox), windows: [(window, alone[0])], appearance: appearance)
            else { continue }
            write(one, to: "\(directory)/fullscreen-one-\(name).png")
            let foot = NSRect(x: 0, y: 0, width: screen.width, height: 96)
            write(draw([(one, NSRect(x: 0, y: 0, width: screen.width, height: screen.height))], size: foot.size),
                  to: "\(directory)/fullscreen-tabs-\(name).png")

            // The compose window's tab clicked: its window comes back beside the message window.
            WindowTray.shared.close(.compose(siteID))
            let pair = FullScreenLayout.frames(for: [messageSize, composeSize], in: area)
            // The compose window, just brought back, is in front.
            guard let backdropWithOneTab = mailboxWindow(), let left = messageWindow(pair[0], inFront: false),
                  let right = itemWindow(ComposeView(draftID: replyID).themedRoot().environment(model).environmentObject(model.updates),
                                         size: pair[1].size, appearance: appearance, style: style),
                  let two = screenImage(screen, mailbox: (backdropWithOneTab, mailbox), windows: [(left, pair[0]), (right, pair[1])],
                                        appearance: appearance)
            else { continue }
            write(two, to: "\(directory)/fullscreen-two-\(name).png")
            WindowTray.shared.close(.message(delivery))
        }
    }

    /// A message or compose window as it stands over the mailbox window filling the screen: its
    /// frame, traffic lights and all, the green button off, drawn as the window in front when
    /// `inFront` and as one behind otherwise.
    @MainActor private static func itemWindow(_ view: some View, size: NSSize, appearance: NSAppearance.Name,
                                              style: NSWindow.StyleMask, inFront: Bool = true) -> NSBitmapImageRep? {
        let frame = NSRect(origin: .zero, size: size)
        let window = inFront ? InFrontWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: style, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = NSHostingView(rootView: view)
        window.setFrame(frame, display: false)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        guard let themeFrame = window.contentView?.superview, let drawn = image(of: themeFrame, appearance: appearance) else { return nil }
        guard inFront else { return drawn }
        // AppKit draws the buttons lit only in an app that is active, which the snapshot never
        // is, so the close and minimise buttons of the window in front are lit here, where AppKit
        // put them.
        let lit: [(NSWindow.ButtonType, Int)] = [(.closeButton, 0xFF5F57), (.miniaturizeButton, 0xFEBC2E)]
        let circles = lit.compactMap { type, colour -> (NSRect, NSColor)? in
            guard let button = window.standardWindowButton(type) else { return nil }
            let box = button.convert(button.bounds, to: themeFrame)
            let side = min(box.width, box.height)
            return (NSRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side), NSColor(hex: colour))
        }
        guard let rep = draw([(drawn, frame)], size: size) else { return drawn }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (circle, colour) in circles {
            colour.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.black.withAlphaComponent(0.12).setStroke()
            let edge = NSBezierPath(ovalIn: circle.insetBy(dx: 0.25, dy: 0.25))
            edge.lineWidth = 0.5
            edge.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Drawn as the window in front, which a window never shown is not.
    private final class InFrontWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    /// A screen `size` points big: black where the camera housing's band is, the mailbox window
    /// in its frame, and each window over it in its own, rounded, outlined and shadowed as macOS
    /// draws a window.
    private static func screenImage(_ size: NSSize, mailbox: (NSBitmapImageRep, NSRect), windows: [(NSBitmapImageRep, NSRect)],
                                    appearance: NSAppearance.Name) -> NSBitmapImageRep? {
        guard let rep = bitmap(size) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()
        mailbox.0.draw(in: mailbox.1, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        let dark = appearance == .darkAqua
        for (window, frame) in windows {
            let outline = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.6 : 0.35)
            shadow.shadowBlurRadius = 28
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            NSColor.black.setFill()
            outline.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            window.draw(in: frame, from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            let edge = NSBezierPath(roundedRect: frame.insetBy(dx: 0.25, dy: 0.25), xRadius: 11.75, yRadius: 11.75)
            edge.lineWidth = 0.5
            (dark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.22)).setStroke()
            edge.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// A new message from an account whose signature for new messages has a logo, words typed
    /// above it, as its compose window shows it, and the message it sends, written beside the
    /// pictures as inline-sample.eml for Mail to open: the logo goes as an inline part in
    /// multipart/related, which the HTML shows by cid:. Nothing is sent or saved anywhere else.
    @MainActor private static func inlinePictures(_ model: AppModel, to directory: String) {
        let account = AccountInfo(email: "alex@example.com", displayName: "Alex Example", provider: "imap",
                                  imapHost: "example.invalid", smtpHost: "example.invalid")
        model.accounts = [account]
        var signature = Signature(name: "Formal")
        signature.setText(formalText())
        var draft = ComposeDraft.blank(account: account, signature: signature)
        draft.to = "Sam Sender <sam@example.com>"
        draft.subject = "Figures for this week"
        if let opened = RichText.attributed(from: draft.richBody) {
            let text = NSMutableAttributedString(attributedString: opened)
            text.insert(NSAttributedString(string: "Hello Sam,\n\nThe figures for this week are in the shared folder.", attributes: RichText.bodyAttributes),
                        at: 0)
            draft.richBody = RichText.body(of: text)
        }
        let id = model.newDraft(draft)
        defer { model.drafts[id] = nil }
        for (name, appearance) in appearances {
            let compose = host(ComposeView(draftID: id).themedRoot().environment(model).environmentObject(model.updates),
                               size: NSSize(width: OL.composeWindowWidth, height: 560), appearance: appearance,
                               style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
            capture(compose, appearance: appearance, to: "\(directory)/compose-signature-\(name).png")
        }
        if let message = try? draft.outgoing(from: account) {
            try? MIMEBuilder.build(message).write(to: URL(fileURLWithPath: "\(directory)/inline-sample.eml"))
        }
    }

    /// Replies as their compose windows show them: to a message from Outlook, its logo sent
    /// inline and shown by cid:, and to one from Gmail, whose signature's logo is fetched from
    /// the web, as an empty box with pictures from the web off and as the picture with them on.
    /// The picture is never fetched: the loader the model is given answers with one drawn here.
    /// The Outlook reply's message is written as reply-quote-sample.eml.
    @MainActor private static func replyQuotes(_ model: AppModel, to directory: String) {
        let account = AccountInfo(email: "alex@example.com", displayName: "Alex Example", provider: "imap",
                                  imapHost: "example.invalid", smtpHost: "example.invalid")
        model.accounts = [account]
        var signature = Signature(name: "Formal")
        signature.setText(formalText())
        let outlookLogo = picture("SAM & CO", colour: .systemIndigo, size: NSSize(width: 120, height: 36))
        let gmailLogo = picture("NORTHWIND", colour: .systemOrange, size: NSSize(width: 96, height: 30))
        let loader = model.remotePictureLoader
        model.remotePictureLoader = RemotePictureLoader { _ in gmailLogo }
        defer { model.remotePictureLoader = loader }
        let cases: [(String, Data, Bool)] = [("outlook", outlookMessage(logo: outlookLogo), false),
                                             ("gmail-off", gmailMessage(), false), ("gmail-on", gmailMessage(), true)]
        for (file, raw, fetching) in cases {
            let parsed = MIMEParser.parse(raw)
            let message = MessageSummary(accountID: account.id, folderID: UUID(), uid: 1, messageID: parsed.messageID, inReplyTo: "",
                                         references: [], subject: parsed.subject, from: parsed.from, to: parsed.to, cc: parsed.cc,
                                         date: parsed.date ?? Date(), flags: [.seen], size: raw.count, hasAttachments: false)
            var draft = ComposeDraft.reply(to: message, parsed: parsed, account: account, all: false, signature: signature)
            if let opened = RichText.attributed(from: draft.richBody) {
                let text = NSMutableAttributedString(attributedString: opened)
                text.insert(NSAttributedString(string: "Thanks, that is what I needed.", attributes: RichText.bodyAttributes), at: 0)
                draft.richBody = RichText.body(of: text)
            }
            let id = model.newDraft(draft)
            defer { model.drafts[id] = nil }
            for (name, appearance) in appearances {
                // As openCompose leaves it for the window, which fetches the pictures as it opens.
                if fetching { model.picturesToFetch.insert(id) }
                let compose = host(ComposeView(draftID: id).themedRoot().environment(model).environmentObject(model.updates),
                                   size: NSSize(width: OL.composeWindowWidth, height: 760), appearance: appearance,
                                   style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
                capture(compose, appearance: appearance, to: "\(directory)/reply-quote-\(file)-\(name).png")
            }
            if file == "outlook", let sent = try? model.drafts[id]?.outgoing(from: account) {
                try? MIMEBuilder.build(sent).write(to: URL(fileURLWithPath: "\(directory)/reply-quote-sample.eml"))
            }
        }
    }

    /// A reply to all to a made-up chain as Outlook for Windows sends it, with Outlook for Mac's
    /// and Outlook for Windows' headings, a Gmail reply in its blockquote, a signature table and a
    /// 5.5 point disclaimer, in the compose window and, as sent, in the reader, in both
    /// appearances; and the message it sends, as outlook-chain-reply.eml. The reader's page is
    /// drawn by WebKit as the reading pane draws it, the recolouring for dark appearance included.
    @MainActor private static func outlookChain(_ model: AppModel, to directory: String) {
        let account = AccountInfo(email: "alex@example.com", displayName: "Alex Example", provider: "imap",
                                  imapHost: "example.invalid", smtpHost: "example.invalid")
        model.accounts = [account]
        let parsed = MIMEParser.parse(outlookChainMessage())
        let message = MessageSummary(accountID: account.id, folderID: UUID(), uid: 1, messageID: parsed.messageID, inReplyTo: "",
                                     references: [], subject: parsed.subject, from: parsed.from, to: parsed.to, cc: parsed.cc,
                                     date: parsed.date ?? Date(), flags: [.seen], size: 40_000, hasAttachments: false)
        var draft = ComposeDraft.reply(to: message, parsed: parsed, account: account, all: true, signature: nil)
        if let opened = RichText.attributed(from: draft.richBody) {
            let text = NSMutableAttributedString(attributedString: opened)
            text.insert(NSAttributedString(string: "Hello Casey,\n\nThanks, both trucks are booked for Tuesday morning.\n\nKind regards,\nAlex",
                                           attributes: RichText.bodyAttributes), at: 0)
            draft.richBody = RichText.body(of: text)
        }
        let id = model.newDraft(draft)
        defer { model.drafts[id] = nil }
        for (name, appearance) in appearances {
            let compose = host(ComposeView(draftID: id).themedRoot().environment(model).environmentObject(model.updates),
                               size: NSSize(width: OL.composeWindowWidth, height: 900), appearance: appearance,
                               style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
            capture(compose, appearance: appearance, to: "\(directory)/outlook-chain-compose-\(name).png")
        }
        // The same window made narrower and then wider: the lines above the headings follow it.
        let resized = host(ComposeView(draftID: id).themedRoot().environment(model).environmentObject(model.updates),
                           size: NSSize(width: 760, height: 900), appearance: .aqua,
                           style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        capture(resized, appearance: .aqua, to: "\(directory)/outlook-chain-compose-760.png")
        resized.window?.setContentSize(NSSize(width: 1300, height: 900))
        resized.frame = NSRect(x: 0, y: 0, width: 1300, height: 900)
        capture(resized, appearance: .aqua, to: "\(directory)/outlook-chain-compose-1300.png")
        guard let sent = try? model.drafts[id]?.outgoing(from: account) else { return }
        let raw = MIMEBuilder.build(sent)
        try? raw.write(to: URL(fileURLWithPath: "\(directory)/outlook-chain-reply.eml"))
        // The HTML as sent, as a reader that adds nothing of its own lays it out at 600 and 1200.
        for width in [600, 1200] {
            webPage(sent.htmlBody ?? "", size: NSSize(width: width, height: 900), appearance: .aqua,
                    to: "\(directory)/outlook-chain-sent-\(width).png")
        }
        let received = MIMEParser.parse(raw)
        for (name, appearance) in appearances {
            let page = MessageRenderer.html(for: received, allowRemote: false, dark: appearance == .darkAqua, forceOriginal: false)
            webPage(page, size: NSSize(width: 900, height: 900), appearance: appearance, to: "\(directory)/outlook-chain-reader-\(name).png")
        }
    }

    /// `html` drawn by the reading pane's own web view, offscreen, `size` points big.
    @MainActor private static func webPage(_ html: String, size: NSSize, appearance: NSAppearance.Name, to path: String) {
        let view = WebViewPool.acquire()
        defer { WebViewPool.release(view) }
        _ = host(view, size: size, appearance: appearance)
        view.loadHTMLString(html, baseURL: nil)
        let deadline = Date(timeIntervalSinceNow: 20)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        while view.isLoading, Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        var done = false
        view.takeSnapshot(with: nil) { image, _ in
            if let tiff = image?.tiffRepresentation { write(NSBitmapImageRep(data: tiff), to: path) }
            done = true
        }
        while !done, Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
    }

    /// A made-up chain as Outlook for Windows sends it: Word's head and styles, a reply in
    /// Calibri with a signature table and a 5.5 point disclaimer, Outlook for Mac's heading above
    /// an earlier reply, Outlook for Windows' heading above a Gmail reply, and Gmail's blockquote.
    private static func outlookChainMessage() -> Data {
        let paragraph = { (text: String) in "<p class=MsoNormal><span style='font-size:11.0pt'>\(text)<o:p></o:p></span></p>" }
        let empty = "<p class=MsoNormal><span style='font-size:11.0pt'><o:p>&nbsp;</o:p></span></p>"
        let signature = """
            <table class=MsoNormalTable border=0 cellspacing=0 cellpadding=0 style='border-collapse:collapse'><tr>\
            <td width=376 valign=top style='width:281.95pt;padding:0cm 5.4pt 0cm 5.4pt'><p class=MsoNormal><b>\
            <span style='font-size:9.0pt;font-family:"Arial",sans-serif;color:black'>Casey Morgan / Operations<o:p></o:p></span></b></p>\
            <p class=MsoNormal><span style='font-size:9.0pt;font-family:"Arial",sans-serif;color:#595959'>A: 12 Harbour Road, \
            Portsmouth<o:p></o:p></span></p></td></tr></table><p class=MsoNormal><span style='font-size:5.5pt;\
            font-family:"Helvetica Neue",serif;color:#595959'>Disclaimer: this message is for the named recipient only. If it \
            reached you by mistake, please tell the sender and delete it.<o:p></o:p></span></p>
            """
        let body = paragraph("Dear Alex,") + empty + paragraph("The pallets for both trucks are ready. Can you confirm the loading "
            + "date for the second truck?") + empty + paragraph("Kind regards,") + signature + empty
            + "<div style='border:none;border-top:solid #B5C4DF 1.0pt;padding:3.0pt 0cm 0cm 0cm'><p class=MsoNormal><b>"
            + "<span style='color:black'>From: </span></b><span style='color:black'>Alex Example &lt;alex@example.com&gt;<br><b>Date: </b>"
            + "Tuesday, 22 September 2026 at 16:40<br><b>To: </b>Casey Morgan &lt;casey@example.com&gt;<br><b>Cc: </b>'Desk' "
            + "&lt;desk@example.com&gt;<br><b>Subject: </b>Re: Pallets for Tuesday<o:p></o:p></span></p></div>" + empty
            + paragraph("Casey, the first truck is booked. I will confirm the second one tomorrow.") + empty
            + "<div style='border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0cm 0cm 0cm'><p class=MsoNormal><b>"
            + "<span lang=EN-US style='font-size:11.0pt;font-family:\"Calibri\",sans-serif'>From:</span></b><span lang=EN-US "
            + "style='font-size:11.0pt;font-family:\"Calibri\",sans-serif'> Jordan Lee &lt;jordan@example.net&gt;<br><b>Sent:</b> "
            + "Monday, September 21, 2026 4:12 PM<br><b>To:</b> Casey Morgan &lt;casey@example.com&gt;<br><b>Subject:</b> Pallets "
            + "for Tuesday<o:p></o:p></span></p></div>" + empty
            + "<div><div dir=ltr>Hi Casey, can you send two trucks on Tuesday?</div><br><div class=gmail_quote><div dir=ltr "
            + "class=gmail_attr>On Mon, 21 Sept 2026 at 09:30, Rowan Hale &lt;rowan@example.org&gt; wrote:<br></div><blockquote "
            + "class=gmail_quote style='margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex'>"
            + "<div dir=ltr>Jordan, 27 pallets are waiting in Portsmouth.</div></blockquote></div></div>"
        let html = """
            <html xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office" \
            xmlns:w="urn:schemas-microsoft-com:office:word"><head><meta http-equiv=Content-Type content="text/html; charset=utf-8">\
            <style><!--
            @font-face {font-family:Calibri; panose-1:2 15 5 2 2 2 4 3 2 4;}
            p.MsoNormal, li.MsoNormal, div.MsoNormal {margin:0cm; font-size:12.0pt; font-family:"Calibri",sans-serif;}
            a:link, span.MsoHyperlink {color:#0563C1; text-decoration:underline;}
            div.WordSection1 {page:WordSection1;}
            --></style></head><body lang=EN-GB link="#0563C1" vlink="#954F72" style='word-wrap:break-word'>\
            <div class=WordSection1>\(body)</div></body></html>
            """
        let raw = """
            From: Casey Morgan <casey@example.com>\r
            To: Alex Example <alex@example.com>\r
            Cc: Desk <desk@example.com>, Jordan Lee <jordan@example.net>\r
            Subject: RE: Pallets for Tuesday\r
            Date: Wed, 23 Sep 2026 10:21:00 +0000\r
            Message-ID: <outlook-chain-sample@example.com>\r
            MIME-Version: 1.0\r
            Content-Type: multipart/alternative; boundary="alt"\r
            \r
            --alt\r
            Content-Type: text/plain; charset=utf-8\r
            \r
            \(HTMLText.plainText(from: html))\r
            --alt\r
            Content-Type: text/html; charset=utf-8\r
            Content-Transfer-Encoding: base64\r
            \r
            \(Data(html.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))\r
            --alt--\r
            """
        return Data(raw.utf8)
    }

    /// A message as Outlook for Windows sends one: its logo an inline part in multipart/related
    /// that its HTML shows by cid:, and its plain text saying [cid:…] where the logo stands.
    private static func outlookMessage(logo: Data) -> Data {
        let cid = "image001.png@01DC2E5A.3F1B7C40"
        let html = """
        <html xmlns:o="urn:schemas-microsoft-com:office:office"><head><meta http-equiv=Content-Type content="text/html; charset=utf-8">\
        <style>p.MsoNormal{margin:0cm;font-size:11.0pt;font-family:"Calibri",sans-serif;}</style></head>\
        <body lang=EN-GB link="#0563C1" vlink="#954F72"><div class=WordSection1><p class=MsoNormal>Hi Alex,</p>\
        <p class=MsoNormal>&nbsp;</p><p class=MsoNormal>The figures for this week are in the shared folder. \
        The <a href="https://example.com/report">full report</a> is there as well.</p><p class=MsoNormal>&nbsp;</p>\
        <p class=MsoNormal>Kind regards,</p><p class=MsoNormal><b>Sam Sender</b></p>\
        <p class=MsoNormal><span style="color:#595959">Operations | Sam &amp; Co</span></p>\
        <p class=MsoNormal><img width=120 height=36 style="width:1.25in;height:.375in" id="Picture_x0020_1" src="cid:\(cid)" alt="Sam &amp; Co"></p>\
        </div></body></html>
        """
        let raw = """
        From: Sam Sender <sam@example.com>\r
        To: Alex Example <alex@example.com>\r
        Subject: Figures for this week\r
        Date: Thu, 24 Sep 2026 16:05:00 +0100\r
        Message-ID: <outlook-sample@example.com>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/related; boundary="rel"; type="multipart/alternative"\r
        \r
        --rel\r
        Content-Type: multipart/alternative; boundary="alt"\r
        \r
        --alt\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Hi Alex,\r
        \r
        The figures for this week are in the shared folder. The full report<https://example.com/report> is there as well.\r
        \r
        Kind regards,\r
        Sam Sender\r
        Operations | Sam & Co\r
        [cid:\(cid)]\r
        --alt\r
        Content-Type: text/html; charset=utf-8\r
        \r
        \(html)\r
        --alt--\r
        --rel\r
        Content-Type: image/png; name="image001.png"\r
        Content-Description: image001.png\r
        Content-Disposition: inline; filename="image001.png"\r
        Content-ID: <\(cid)>\r
        Content-Transfer-Encoding: base64\r
        \r
        \(logo.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))\r
        --rel--\r
        """
        return Data(raw.utf8)
    }

    /// A message as Gmail sends one: its signature's logo fetched from the web, and its plain
    /// text saying [image: …] where the logo stands.
    private static func gmailMessage() -> Data {
        let logo = "https://lh3.example.invalid/mail-sig/AIorK4northwind=s96"
        let raw = """
        From: Jordan Lee <jordan@example.net>\r
        To: Alex Example <alex@example.com>\r
        Subject: Delivery on Friday\r
        Date: Thu, 24 Sep 2026 17:40:00 +0100\r
        Message-ID: <gmail-sample@example.net>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/alternative; boundary="alt"\r
        \r
        --alt\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        Hi Alex,\r
        \r
        The delivery is booked for Friday morning.\r
        \r
        --\r
        Jordan Lee\r
        Northwind Traders\r
        [image: Northwind Traders] <https://northwind.example/>\r
        --alt\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <div dir="ltr"><div>Hi Alex,</div><div><br></div><div>The delivery is booked for <b>Friday morning</b>.</div>\
        <div><br></div><span class="gmail_signature_prefix">-- </span><br><div dir="ltr" class="gmail_signature">\
        <div dir="ltr"><div>Jordan Lee</div><div>Northwind Traders</div><div><a href="https://northwind.example/" target="_blank">\
        <img src="\(logo)" alt="Northwind Traders" width="96" height="30"></a></div></div></div></div>\r
        --alt--\r
        """
        return Data(raw.utf8)
    }

    /// A logo drawn here, `size` points at twice that many pixels, as a PNG.
    @MainActor private static func picture(_ words: String, colour: NSColor, size: NSSize) -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return Data() }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        colour.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 5, yRadius: 5).fill()
        NSAttributedString(string: words, attributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white])
            .draw(at: NSPoint(x: 10, y: (size.height - 15) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }

    @MainActor private static func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for child in view.subviews {
            if let text = textView(in: child) { return text }
        }
        return nil
    }

    /// A signature with what the editor can do: a bold name, a coloured line, a link and a
    /// picture.
    @MainActor private static func formalText() -> NSAttributedString {
        let body = RichText.bodyAttributes
        let text = NSMutableAttributedString(string: "Alex Example\n", attributes: body.merging([
            .font: NSFontManager.shared.convert(RichText.defaultFont, toHaveTrait: .boldFontMask)]) { $1 })
        text.append(NSAttributedString(string: "Operations Manager, Example Ltd\n", attributes: body))
        text.append(NSAttributedString(string: "+44 20 7946 0000\n", attributes: body.merging([.foregroundColor: NSColor.systemBlue]) { $1 }))
        text.append(NSAttributedString(string: "example.com\n", attributes: body.merging([.link: URL(string: "https://example.com")!]) { $1 }))
        if let logo = logo() { text.append(NSAttributedString(attachment: logo)) }
        return text
    }

    @MainActor private static func logo() -> NSTextAttachment? {
        let size = NSSize(width: 96, height: 28)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemTeal.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 5, yRadius: 5).fill()
        NSAttributedString(string: "EXAMPLE", attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white])
            .draw(at: NSPoint(x: 18, y: 6))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let file = FileWrapper(regularFileWithContents: png)
        file.preferredFilename = "logo.png"
        return NSTextAttachment(fileWrapper: file)
    }

    @MainActor private static func ribbon(_ formatter: TextFormatter) -> some View {
        VStack(spacing: 0) {
            OLColor.chrome.frame(height: OL.titleRow)
            ComposeRibbon(tab: .constant(.message), formatter: formatter, showsBcc: .constant(false),
                          importance: .constant("normal"), canSend: false, onSend: {}, onDiscard: {}, onAttachFile: {},
                          onAttachFromDrive: {}, signatures: [], onInsertSignature: { _ in }, onEditSignatures: {},
                          onInsertTableDialog: {}, onCycleBackground: {})
            Rectangle().fill(OLColor.chromeLine).frame(height: 1)
            OLColor.sidebar
        }
    }

    /// The ribbon over the body a compose window writes in, ¶ turned on through the formatter
    /// before the body is attached to it, as when SwiftUI makes a body again: the button lit and
    /// the body's paragraph ends, spaces and tabs marked, down to the empty line after its last
    /// line break.
    @MainActor private static func composeWithMarks() -> some View {
        let formatter = TextFormatter()
        formatter.toggleFormattingMarks()
        let body = NSMutableAttributedString(string: "Hello Sam,\n\nThe figures for this week are below.\n", attributes: RichText.bodyAttributes)
        body.append(NSAttributedString(string: "North\t1,240\nSouth\t985\n\n", attributes: RichText.bodyAttributes))
        body.append(NSAttributedString(string: "The full report is at ", attributes: RichText.bodyAttributes))
        body.append(NSAttributedString(string: "example.com", attributes: RichText.bodyAttributes.merging([
            .link: URL(string: "https://example.com")!]) { $1 }))
        body.append(NSAttributedString(string: ".\n\nBest wishes,\nAlex\n", attributes: RichText.bodyAttributes))
        return VStack(spacing: 0) {
            OLColor.chrome.frame(height: OL.titleRow)
            ComposeRibbon(tab: .constant(.message), formatter: formatter, showsBcc: .constant(false),
                          importance: .constant("normal"), canSend: false, onSend: {}, onDiscard: {}, onAttachFile: {},
                          onAttachFromDrive: {}, signatures: [], onInsertSignature: { _ in }, onEditSignatures: {},
                          onInsertTableDialog: {}, onCycleBackground: {})
            Rectangle().fill(OLColor.chromeLine).frame(height: 1)
            RichTextEditor(body: .constant(RichText.body(of: body))) { view in
                Task { @MainActor in formatter.attach(view) }
            }
        }
        .background(OLColor.reading)
    }

    @MainActor private static func picker(hovering size: TableSize?, converts: Bool) -> some View {
        let selection = TableGridSelection()
        selection.hovered = size
        return TableGridPicker(selection: selection, insert: { _ in }, insertCustom: {}, convertText: converts ? {} : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The address suggestions as a compose window shows them: its own header with "kam" typed
    /// in To, and over it the list where the field hangs its window, placed by the field's own
    /// reckoning, since a child window is not drawn with the window it hangs from. The list holds
    /// a contact with a label and two recent addresses, the middle one highlighted, the last two
    /// too long for their columns. Cut twice to Outlook's captures: the list alone, framed from
    /// the outside of the To box's foot and left edge, and the list in context, that corner 67
    /// points in and 100 down.
    @MainActor private static func suggestions(_ model: AppModel, appearance: NSAppearance.Name, to directory: String, name: String) {
        var draft = ComposeDraft(accountID: UUID())
        draft.to = "kam"
        let id = model.newDraft(draft)
        defer { model.drafts[id] = nil }
        // Titled, with its content under the title bar, as a compose window is: the view dresses
        // its window's title bar, and a borderless window has none to dress.
        let compose = host(ComposeView(draftID: id).themedRoot().environment(model).environmentObject(model.updates),
                           size: NSSize(width: OL.composeWindowWidth, height: 480), appearance: appearance,
                           style: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        let rows = [
            RecipientSuggestion(name: "Kamal Muradov", email: "kamal.muradov@example.com", label: "Work"),
            RecipientSuggestion(name: "kamal-muradov-example", email: "notifications@example.com", isRecentAddress: true),
            RecipientSuggestion(name: "kamal-muradov-example/example-project-tools",
                                email: "example-project-tools@noreply.example.com", isRecentAddress: true),
        ]
        let list = NSHostingView(rootView: SuggestionList(rows: rows, highlighted: 1, accept: { _ in }, highlight: { _ in },
                                                          remove: { _ in }))
        let listSize = list.fittingSize
        guard let drawnWindow = image(of: compose, appearance: appearance),
              let drawnList = image(of: host(list, size: listSize, appearance: appearance), appearance: appearance),
              let box = views(of: RecipientSuggestions.AnchorView.self, in: compose)
                  .map({ $0.convert($0.bounds, to: nil) }).max(by: { $0.maxY < $1.maxY })
        else { return }
        // The content reaches under the title bar, so it is taller than asked for.
        let size = compose.bounds.size
        guard let shown = draw([(drawnWindow, NSRect(origin: .zero, size: size)),
                                (drawnList, RecipientSuggestions.panelFrame(under: box, size: listSize))], size: size)
        else { return }
        let corner = box.insetBy(dx: -SuggestionLook.boxBorderOutside, dy: -SuggestionLook.boxBorderOutside).origin
        let cuts = [("suggestions", NSRect(x: corner.x, y: corner.y - 148, width: 516, height: 148)),
                    ("suggestions-in-context", NSRect(x: corner.x - 67, y: corner.y - 10, width: 500, height: 110))]
        for (cut, rect) in cuts {
            write(draw([(shown, NSRect(x: -rect.minX, y: -rect.minY, width: size.width, height: size.height))], size: rect.size),
                  to: "\(directory)/\(cut)-\(name).png")
        }
    }

    @MainActor private static func describe(_ alert: NSAlert) -> String {
        let buttons = alert.buttons.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        let keys = buttons.map { button -> String in
            switch button.keyEquivalent {
            case "\r": return "\(button.title) (Return, default)"
            case "\u{1b}": return "\(button.title) (Escape)"
            default: return button.title
            }
        }
        return "\(alert.messageText)\n\(alert.informativeText)\nButtons, left to right: \(keys.joined(separator: ", "))\n"
            + "Panel \(Int(alert.window.frame.width)) × \(Int(alert.window.frame.height)) pt\n"
    }

    /// Every view of `type` under `view`.
    @MainActor private static func views<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? views(of: type, in: $0) }
    }

    /// Bitmaps laid over one another in a new one `size` points big, each in its rectangle.
    private static func draw(_ layers: [(NSBitmapImageRep, NSRect)], size: NSSize) -> NSBitmapImageRep? {
        guard let rep = bitmap(size) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (layer, rect) in layers {
            layer.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @MainActor private static func render(_ view: some View, size: NSSize, appearance: NSAppearance.Name, to path: String) {
        capture(host(view, size: size, appearance: appearance), appearance: appearance, to: path)
    }

    /// `view`, `size` points big, as the content of a window in `appearance` that is never shown.
    @MainActor private static func host<V: NSView>(_ view: V, size: NSSize, appearance: NSAppearance.Name,
                                                   style: NSWindow.StyleMask = [.borderless]) -> V {
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: style, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        return view
    }

    @MainActor private static func host(_ view: some View, size: NSSize, appearance: NSAppearance.Name,
                                        style: NSWindow.StyleMask = [.borderless]) -> NSView {
        host(NSHostingView(rootView: view), size: size, appearance: appearance, style: style)
    }

    @MainActor private static func capture(_ view: NSView, appearance: NSAppearance.Name, ground: NSColor? = nil, to path: String) {
        write(image(of: view, appearance: appearance, ground: ground), to: path)
    }

    @MainActor private static func image(of view: NSView, appearance: NSAppearance.Name, ground: NSColor? = nil) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        guard var rep = bitmap(size) else { return nil }
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        if let ground, let grounded = bitmap(size) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: grounded)
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                ground.setFill()
                NSRect(origin: .zero, size: size).fill()
                rep.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1,
                         respectFlipped: false, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
            rep = grounded
        }
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep?, to path: String) {
        try? rep?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func bitmap(_ size: NSSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }
}
/// Made-up mail for the message list's snapshot: every name, address and subject is invented.
private struct ListSnapshotMail {
    let accountID: UUID
    private let folderID = UUID()
    private let now = Date()

    private var startOfToday: Date { Calendar.current.startOfDay(for: now) }

    /// Earlier today, however soon after midnight the snapshot is drawn.
    private func today(_ share: Double) -> Date { startOfToday + now.timeIntervalSince(startOfToday) * share }

    private func daysAgo(_ days: Int, hour: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: startOfToday)! + Double(hour) * 3_600
    }

    private func message(_ uid: UInt32, _ name: String, _ address: String, _ subject: String, _ date: Date,
                         read: Bool = true, flagged: Bool = false, attachment: Bool = false, preview: String = "") -> MessageSummary {
        var flags: MessageFlags = read ? [.seen] : []
        if flagged { flags.insert(.flagged) }
        return MessageSummary(accountID: accountID, folderID: folderID, uid: uid, messageID: "<\(uid)@example.com>",
                              inReplyTo: "", references: [], subject: subject, from: EmailAddress(name: name, address: address),
                              to: [EmailAddress(name: "Alex Example", address: "alex@example.com")], cc: [], date: date,
                              flags: flags, size: 12_000, snippet: preview, hasAttachments: attachment)
    }

    var threads: [MessageThread] {
        let route = "ROUTE 14B - INVOICE 2231 - PO88K"
        let maya = ("Maya Lindqvist", "maya@example.com")
        let mayaLong = ("Maya Lindqvist-Barrington", "maya@example.com")
        let tom = ("Tom Okafor", "tom@example.net")
        let opened = MessageThread(messages: [
            message(101, maya.0, maya.1, route, today(0.95), read: false, preview: "Please find the corrected invoice attached."),
            message(100, tom.0, tom.1, "RE: " + route, today(0.9)),
            message(99, mayaLong.0, mayaLong.1, "RE: " + route, daysAgo(1, hour: 21)),
            message(98, tom.0, tom.1, "RE: " + route, daysAgo(1, hour: 18)),
            message(97, mayaLong.0, mayaLong.1, "RE: " + route, daysAgo(2, hour: 16)),
            message(96, tom.0, tom.1, "RE: " + route, daysAgo(2, hour: 15)),
            message(95, mayaLong.0, mayaLong.1, route, daysAgo(2, hour: 11)),
        ])
        let dock = MessageThread(messages: [
            message(90, "Ravi Patel", "ravi@example.org", "Dock schedule change from Monday", today(0.5), flagged: true,
                    preview: "Hi all, from Monday the dock opens at 06:00 instead of 07:00."),
        ])
        let pallets = MessageThread(messages: [
            message(82, "Priya Raman", "priya@example.com", "Pallet count for Tuesday", daysAgo(1, hour: 17), attachment: true,
                    preview: "Good afternoon, if you are going to file a claim for the damaged pallets, send the photos by Friday."),
            message(81, "Daniel Hughes", "daniel@example.net", "Pallet count for Tuesday", daysAgo(1, hour: 12)),
            message(80, "Priya Raman", "priya@example.com", "Pallet count for Tuesday", daysAgo(1, hour: 10)),
        ])
        let weekly = MessageThread(messages: [
            message(70, "'Northwind Weekly' via Example Group", "group@example.com",
                    "Northwind Weekly: your roundup of warehouse automation news", daysAgo(1, hour: 16),
                    preview: "September insights worth bookmarking before the peak season starts"),
        ])
        let order = MessageThread(messages: [
            message(62, "Oliver Brandt", "oliver@example.com", "Sales order 4471-B", daysAgo(1, hour: 15), read: false,
                    attachment: true, preview: "Sounds good, thank you for the update. -- Oliver"),
            message(61, "'Carmen Ortiz' via Example Group", "group@example.com", "Sales order 4471-B", daysAgo(1, hour: 14),
                    read: false),
            message(60, "Sam Lee", "sam@example.org", "Sales order 4471-B", daysAgo(1, hour: 9)),
        ])
        let harbour = MessageThread(messages: [
            message(50, "'Harbour Freight Lines' via Example Group", "group@example.com",
                    "On a tight timeline? Harbour Freight collects the same day", daysAgo(1, hour: 8),
                    preview: "Explore guaranteed LTL, exclusive-use equipment and more with one call."),
        ])
        let statement = MessageThread(messages: [
            message(40, "Alexandria Montgomery-Fitzgerald of Example Logistics International", "accounts@example.com",
                    "STATEMENT SUMMARY", daysAgo(3, hour: 9),
                    preview: "Dear customer, your statement for September is attached to this message."),
        ])
        let customs = MessageThread(messages: [
            message(31, "Hannah Weber", "hannah@example.net", "Customs paperwork for container 7", daysAgo(12, hour: 13)),
            message(30, "Ravi Patel", "ravi@example.org", "Customs paperwork for container 7", daysAgo(12, hour: 10)),
        ])
        return [opened, dock, pallets, weekly, order, harbour, statement, customs]
    }
}

/// Made-up mail for the conversation stack's snapshot: every name, address and word is invented.
/// Newest first: Maya's reply quoting Tom's as Gmail does, Tom's unread reply quoting Maya's in
/// plain text, Maya's question and Alex's first message.
private struct StackSnapshotMail {
    let accountID: UUID
    private let folderID = UUID()

    private let alex = EmailAddress(name: "Alex Example", address: "alex@example.com")
    private let maya = EmailAddress(name: "Maya Lindqvist", address: "maya@example.com")
    private let tom = EmailAddress(name: "Tom Okafor", address: "tom@example.net")
    private let priya = EmailAddress(name: "Priya Raman", address: "priya@example.org")
    private let subject = "Delivery windows for the north depot"

    private static func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute)) ?? Date()
    }

    private let firstText = "Hi Maya, Tom,\n\nFrom next week the north depot is closed on Mondays, so the deliveries need new "
        + "windows. Could you agree two with the carrier?\n\nThanks,\nAlex"
    private let questionText = "Hello Tom, could you ask the carrier for two delivery windows next week? The depot is closed "
        + "on Monday and the dock is busy after four.\n\nMaya"
    private let answerText = "Morning both,\n\nThe carrier can do Tuesday between 07:00 and 09:00, or Wednesday after 14:00. "
        + "They need to know by Friday noon. Which suits the depot?\n\nTom"

    var messages: [(MessageSummary, MIMEMessage)] {
        let quotedQuestion = questionText.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        let answer = answerText + "\n\nOn Thu, 24 Sept 2026 at 16:40, Maya Lindqvist <maya@example.com> wrote:\n\n" + quotedQuestion
        let replyHTML = """
            <div dir="ltr"><div>Hi Tom,</div><div><br></div><div>Tuesday 07:00 to 09:00 works for us. I have booked dock two \
            and told the night shift, so the driver can come straight in.</div><div><br></div><div>Priya, could you put it in \
            the depot calendar?</div><div><br></div><div>Maya</div></div><br><div class="gmail_quote gmail_quote_container">\
            <div dir="ltr" class="gmail_attr">On Fri, 25 Sept 2026 at 09:15, Tom Okafor &lt;tom@example.net&gt; wrote:<br></div>\
            <blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex">\
            <div dir="ltr">\(answerText.replacingOccurrences(of: "\n", with: "<br>"))</div></blockquote></div>
            """
        return [
            message(4, from: maya, to: [alex, tom], cc: [priya], at: Self.date(25, 10, 42), read: true, html: replyHTML),
            message(3, from: tom, to: [alex, maya], cc: [], at: Self.date(25, 9, 15), read: false, plain: answer),
            message(2, from: maya, to: [tom], cc: [alex], at: Self.date(24, 16, 40), read: true, plain: questionText),
            message(1, from: alex, to: [maya, tom], cc: [], at: Self.date(23, 11, 5), read: true, plain: firstText),
        ]
    }

    private func message(_ uid: UInt32, from: EmailAddress, to: [EmailAddress], cc: [EmailAddress], at date: Date, read: Bool,
                         plain: String? = nil, html: String? = nil) -> (MessageSummary, MIMEMessage) {
        let type = html == nil ? "text/plain" : "text/html"
        let raw = "From: \(from.rfc5322)\r\nSubject: \(uid == 1 ? subject : "Re: " + subject)\r\nMIME-Version: 1.0\r\n"
            + "Content-Type: \(type); charset=utf-8\r\n\r\n" + (html ?? plain ?? "")
        let parsed = MIMEParser.parse(Data(raw.utf8))
        let summary = MessageSummary(accountID: accountID, folderID: folderID, uid: uid, messageID: "<stack-\(uid)@example.com>",
                                     inReplyTo: "", references: [], subject: uid == 1 ? subject : "Re: " + subject, from: from,
                                     to: to, cc: cc, date: date, flags: read ? [.seen] : [], size: raw.utf8.count,
                                     snippet: parsed.snippet, hasAttachments: false, hasBody: true, threadKey: "stack")
        return (summary, parsed)
    }
}

/// Made-up mail for timing a long conversation: fifty messages among four invented people, each
/// a paragraph of its own over Gmail's quote of the one before, which quotes the one before it.
private struct LongConversationMail {
    let accountID: UUID
    let unread: Bool
    private let folderID = UUID()
    private let people = [
        EmailAddress(name: "Alex Example", address: "alex@example.com"),
        EmailAddress(name: "Maya Lindqvist", address: "maya@example.com"),
        EmailAddress(name: "Tom Okafor", address: "tom@example.net"),
        EmailAddress(name: "Priya Raman", address: "priya@example.org"),
    ]

    var messages: [(MessageSummary, MIMEMessage)] {
        let start = Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 8)) ?? Date()
        var previous: (html: String, from: EmailAddress, date: Date)?
        var out: [(MessageSummary, MIMEMessage)] = []
        for index in 1...50 {
            let from = people[index % people.count]
            let date = start.addingTimeInterval(Double(index) * 3_600 * 7)
            let own = "<div dir=\"ltr\"><div>Update \(index) on the north depot rota: the carrier confirmed slot \(index % 9 + 1), "
                + "the dock crew for shift \(index % 3 + 1) is booked, and the paperwork for load \(1_000 + index) went to "
                + "customs this morning. Please check the attached times and say if anything clashes.</div><div><br></div>"
                + "<div>\(from.name.split(separator: " ").first ?? "")</div></div>"
            var html = own
            if let previous {
                html += "<br><div class=\"gmail_quote gmail_quote_container\"><div dir=\"ltr\" class=\"gmail_attr\">On "
                    + previous.date.formatted(date: .abbreviated, time: .shortened) + ", \(previous.from.name) &lt;"
                    + "\(previous.from.address)&gt; wrote:<br></div><blockquote class=\"gmail_quote\" style=\"margin:0px 0px 0px "
                    + "0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex\">\(previous.html)</blockquote></div>"
            }
            previous = (html, from, date)
            let subject = index == 1 ? "North depot rota" : "Re: North depot rota"
            let raw = "From: \(from.rfc5322)\r\nSubject: \(subject)\r\nMIME-Version: 1.0\r\n"
                + "Content-Type: text/html; charset=utf-8\r\n\r\n" + html
            let parsed = MIMEParser.parse(Data(raw.utf8))
            let to = people.filter { $0 != from }
            let summary = MessageSummary(accountID: accountID, folderID: folderID, uid: UInt32(index),
                                         messageID: "<long-\(index)@example.com>", inReplyTo: "", references: [], subject: subject,
                                         from: from, to: to, cc: [], date: date, flags: unread ? [] : [.seen], size: raw.utf8.count,
                                         snippet: parsed.snippet, hasAttachments: false, hasBody: true, threadKey: "long")
            out.append((summary, parsed))
        }
        return out.reversed()
    }
}
#endif
