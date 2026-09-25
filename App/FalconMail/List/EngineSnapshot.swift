#if DEBUG
import AppKit
import SwiftUI
import FalconCore

/// `-FalconMailSnapshot <directory> -FalconMailSnapshotOnly engine` draws what a Google account on
/// the Gmail API looks like, in dark and light, over a made-up account whose mail is invented and
/// held in memory: nothing is asked of Google or of any server, and no engine runs.
///
/// - `engine-list-*.png`: the Inbox's table at Outlook's list width, an opened conversation with
///   the owner's reply in Sent, rows with their text, and rows whose text is on its way drawn grey
///   with their unread dot, flag, clip and count already right, with the line saying rows are
///   loading;
/// - `engine-sidebar-*.png`: the account's folders with Outlook's names and order, Drafts counting
///   its drafts; `engine-sidebar-paused-*.png` with the hourglass while Gmail asks FalconMail to
///   wait;
/// - `engine-status-*.png`: the status bar with the folder's real Items and "All folders are up
///   to date.", while the mailbox is being listed, and while Gmail asks FalconMail to wait;
/// - `engine-window-*.png`: the mailbox window with all three.
@MainActor
enum EngineSnapshot {
    private static let appearances: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]

    static func render(_ model: AppModel, to directory: String) {
        let account = AccountInfo.google(email: "alex@example.com", displayName: "Alex Example")
        let folders = MadeUpGoogleAccount.folders(account.id)
        guard let inbox = folders.first(where: { $0.role == .inbox }) else { return }
        model.accounts = [account]
        model.folders = [account.id: folders]
        model.gmailEngineAccounts = [account.id]
        model.selection = .folder(inbox.id)
        model.accountStatus.apply(.health(accountID: account.id, .online))
        model.online[account.id] = true
        model.statusText = "Up to date"

        let mail = MadeUpGoogleAccount(accountID: account.id, inboxID: inbox.id)
        let source = MadeUpEngineSource(snapshot: mail.snapshot, footers: [.loading(email: account.email)])
        let list = model.engineList
        guard wait({ await list.snapshotShow(mail.snapshot.view, from: source, model: model, everyFolderListed: true) }) else { return }
        list.controller.content.insert(mail.contents)
        _ = wait {
            for _ in 0..<50 where list.controller.footers.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        MessageTableView.snapshotHasKeyboard = true
        MessageListView.snapshotListHasKeyboard = true
        defer {
            MessageTableView.snapshotHasKeyboard = false
            MessageListView.snapshotListHasKeyboard = nil
        }

        for (name, appearance) in appearances {
            // The list, its opened conversation's newest message selected.
            let listView = MessageListView().environment(model).environmentObject(model.updates).themedRoot()
            capture(host(listView, size: NSSize(width: OL.listWidth, height: 830), appearance: appearance), appearance: appearance,
                    selectRow: 2, to: "\(directory)/engine-list-\(name).png")

            let sidebar = SidebarView().environment(model).environmentObject(model.updates).themedRoot()
            capture(host(sidebar, size: NSSize(width: OL.sidebarWidth, height: 520), appearance: appearance), appearance: appearance,
                    to: "\(directory)/engine-sidebar-\(name).png")

            // Quiet: every folder listed, the Inbox's real total.
            statusBar(model, appearance: appearance, to: "\(directory)/engine-status-uptodate-\(name).png")
        }

        // Listing the mailbox.
        model.syncingAccounts = [account.id]
        model.statusText = "Syncing \(account.email): 12,000 of 55,000 messages"
        list.snapshotEveryFolderListed(false)
        for (name, appearance) in appearances {
            statusBar(model, appearance: appearance, to: "\(directory)/engine-status-listing-\(name).png")
        }

        // Gmail asked FalconMail to wait more than a minute.
        model.syncingAccounts = []
        let sentence = "Waiting a moment before loading more of \(account.email)'s messages."
        model.accountStatus.apply(.health(accountID: account.id, .apiPaused(until: Date().addingTimeInterval(600))))
        model.accountStatus.apply(.error(accountID: account.id, message: sentence))
        model.online[account.id] = false
        model.statusText = sentence
        for (name, appearance) in appearances {
            statusBar(model, appearance: appearance, to: "\(directory)/engine-status-paused-\(name).png")
            let sidebar = SidebarView().environment(model).environmentObject(model.updates).themedRoot()
            capture(host(sidebar, size: NSSize(width: OL.sidebarWidth, height: 230), appearance: appearance), appearance: appearance,
                    to: "\(directory)/engine-sidebar-paused-\(name).png")
        }

        // The whole mailbox window, quiet again.
        model.accountStatus.apply(.health(accountID: account.id, .online))
        model.online[account.id] = true
        model.statusText = "Up to date"
        list.snapshotEveryFolderListed(true)
        list.controller.setSelection(.none)
        for (name, appearance) in appearances {
            let window = MainWindow().themedRoot().environment(model).environmentObject(model.updates)
            capture(host(window, size: NSSize(width: 1440, height: 900), appearance: appearance), appearance: appearance,
                    to: "\(directory)/engine-window-\(name).png")
        }
        list.controller.stop()
    }

    private static func statusBar(_ model: AppModel, appearance: NSAppearance.Name, to path: String) {
        let bar = StatusBar().environment(model).environmentObject(model.updates).themedRoot()
        capture(host(bar, size: NSSize(width: 1200, height: OL.status), appearance: appearance), appearance: appearance, to: path)
    }

    // MARK: - Drawing offscreen

    /// Runs `body` on the main actor, turning the run loop until it finishes, as a snapshot has no
    /// other way to wait.
    private static func wait(_ body: @escaping @MainActor () async -> Void) -> Bool {
        var done = false
        Task { @MainActor in
            await body()
            done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !done, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return done
    }

    private static func host(_ view: some View, size: NSSize, appearance: NSAppearance.Name) -> NSView {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        return hosting
    }

    private static func capture(_ view: NSView, appearance: NSAppearance.Name, selectRow row: Int? = nil, to path: String) {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        if let row, let table = firstTable(in: view) { table.selectRowIndexes([row], byExtendingSelection: false) }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func firstTable(in view: NSView) -> MessageNSTableView? {
        if let table = view as? MessageNSTableView { return table }
        for child in view.subviews { if let table = firstTable(in: child) { return table } }
        return nil
    }
}

/// A made-up Google account on the Gmail API: its folders as the engine gives them, and an Inbox
/// of 54,218 messages of which the first screen is listed, some with their text and some without.
/// Every name, address and subject is invented.
private struct MadeUpGoogleAccount {
    let accountID: UUID
    let inboxID: UUID
    private let now = Date()

    static func folders(_ accountID: UUID) -> [FolderInfo] {
        func folder(_ path: String, _ name: String, _ role: FolderRole, _ label: GmailLabelID?, total: Int, unread: Int) -> FolderInfo {
            var made = FolderInfo(accountID: accountID, path: path, name: name, delimiter: "/", role: role, attributes: [], isSelectable: true)
            made.gmailLabelID = label
            made.totalCount = total
            made.unreadCount = unread
            return made
        }
        // In the order the engine gives them, labels last; the sidebar puts them in Outlook's.
        return [
            folder("INBOX", "Inbox", .inbox, .inbox, total: 54_218, unread: 12),
            folder("[Gmail]/Drafts", "Drafts", .drafts, .draft, total: 2, unread: 2),
            folder("[Gmail]/Archive", "Archive", .all, nil, total: 61_532, unread: 14),
            folder("[Gmail]/Sent", "Sent", .sent, .sent, total: 6_104, unread: 0),
            folder("[Gmail]/Deleted Items", "Deleted Items", .trash, .trash, total: 318, unread: 0),
            folder("[Gmail]/Junk Email", "Junk Email", .junk, .spam, total: 41, unread: 3),
            folder("[Gmail]/Important", "Important", .important, .important, total: 9_870, unread: 5),
            folder("[Gmail]/Starred", "Starred", .flagged, .starred, total: 27, unread: 0),
            folder("Shipments/Rotterdam", "Rotterdam", .other, GmailLabelID("Label_3"), total: 812, unread: 4),
            folder("Customs", "Customs", .other, GmailLabelID("Label_1"), total: 1_204, unread: 0),
            folder("Shipments", "Shipments", .other, GmailLabelID("Label_2"), total: 2_310, unread: 1)
        ]
    }

    private func key(_ i: Int) -> RowKey { .gmail(account: accountID, id: GmailMessageID(raw: 0x18a0_0000_0000_0000 + UInt64(i) * 16)) }
    private func record(_ i: Int, _ kind: DisplayKind, bits: DisplayBits = [], members: UInt16 = 1, unread: UInt16 = 0) -> DisplayRecord {
        DisplayRecord(key: 0x18a0_0000_0000_0000 + UInt64(i) * 16, slot: Int32(i), bits: bits, members: members, unread: unread, kind: kind)
    }

    var snapshot: ListSnapshot {
        let rows: ContiguousArray<DisplayRecord> = [
            record(1, .conversation, bits: [.unread, .expanded], members: 2, unread: 1),
            record(1, .child, bits: [.unread], unread: 1), record(2, .child), record(3, .child),
            record(4, .conversation, bits: [.hasAttachment, .attachmentKnown], members: 3, unread: 2),
            record(5, .message),
            record(6, .message, bits: [.flagged]),
            record(7, .conversation, members: 2),
            record(8, .message),
            // Not seen yet: grey, with what the index knows.
            record(9, .message, bits: [.unread], unread: 1),
            record(10, .conversation, bits: [.flagged], members: 4),
            record(11, .message, bits: [.hasAttachment, .attachmentKnown]),
            record(12, .message),
            record(13, .message, bits: [.unread], unread: 1)
        ]
        return ListSnapshot(view: ListView(scope: .folder(inboxID)), rows: rows, complete: true, itemCount: 54_218, sources: [accountID])
    }

    var contents: [RowKey: MessageRowContent] {
        let maya = EmailAddress(name: "Maya Lindqvist", address: "maya@example.com")
        let tom = EmailAddress(name: "Tom Okafor", address: "tom@example.com")
        let alex = EmailAddress(name: "Alex Example", address: "alex@example.com")
        let today = Calendar.current.startOfDay(for: now)
        var out: [RowKey: MessageRowContent] = [:]
        out[key(1)] = MessageRowContent(
            key: key(1), from: maya, to: [alex], subject: "Container booking for week 41", preview: "Can you confirm the slot for Tuesday",
            date: today.addingTimeInterval(9 * 3_600),
            conversation: ConversationContent(senders: [tom, alex, maya], messageCount: 3, newestDate: today.addingTimeInterval(9 * 3_600),
                                              members: [ConversationMember(key: key(3), from: tom, date: today.addingTimeInterval(7 * 3_600)),
                                                        ConversationMember(key: key(2), from: alex, date: today.addingTimeInterval(8 * 3_600),
                                                                           folderName: "Sent"),
                                                        ConversationMember(key: key(1), from: maya, date: today.addingTimeInterval(9 * 3_600))]))
        out[key(4)] = MessageRowContent(key: key(4), from: tom, to: [alex], subject: "Invoice 2026-114 and the customs papers",
                                        preview: "Attached are the invoice and the signed papers for the shipment",
                                        date: today.addingTimeInterval(8 * 3_600), hasAttachments: true,
                                        conversation: ConversationContent(senders: [maya, tom, tom], messageCount: 3,
                                                                          newestDate: today.addingTimeInterval(8 * 3_600)))
        out[key(5)] = MessageRowContent(key: key(5), from: EmailAddress(name: "Warehouse Rotterdam", address: "wh@example.com"), to: [alex],
                                        subject: "Delivery note", preview: "Your pallets were received at 07:40",
                                        date: today.addingTimeInterval(7 * 3_600))
        out[key(6)] = MessageRowContent(key: key(6), from: maya, to: [alex], subject: "Rates for Q4", preview: "The new rates start in October",
                                        date: today.addingTimeInterval(-20 * 3_600))
        out[key(7)] = MessageRowContent(key: key(7), from: tom, to: [alex], subject: "Re: Truck schedule",
                                        preview: "Thursday works for us", date: today.addingTimeInterval(-30 * 3_600),
                                        conversation: ConversationContent(senders: [alex, tom], messageCount: 2,
                                                                          newestDate: today.addingTimeInterval(-30 * 3_600)))
        out[key(8)] = MessageRowContent(key: key(8), from: EmailAddress(name: "Port Authority", address: "port@example.org"), to: [alex],
                                        subject: "Berth allocation", preview: "Berth 4 is allocated from 06:00",
                                        date: today.addingTimeInterval(-4 * 86_400))
        return out
    }
}

/// A source that answers with what it was given and asks nothing of anyone.
private final class MadeUpEngineSource: ListSourceExtras, @unchecked Sendable {
    let current: ListSnapshot
    let lines: [ListFooter]

    init(snapshot: ListSnapshot, footers: [ListFooter]) {
        current = snapshot
        lines = footers
    }

    func snapshot(of view: ListView) async -> ListSnapshot { current }
    func changes(of view: ListView) -> AsyncStream<ListDiff> { AsyncStream { _ in } }
    func requestRows(_ keys: [RowKey], priority: RowPriority) {}
    var rows: AsyncStream<[RowKey: MessageRowContent]> { AsyncStream { _ in } }
    func summary(for key: RowKey, in view: ListView) async -> RowAvailability { .unavailable(reason: "") }
    func setExpanded(_ keys: Set<RowKey>, in view: ListView) async {}
    func footers(of view: ListView) -> AsyncStream<[ListFooter]> {
        let lines = self.lines
        return AsyncStream { $0.yield(lines) }
    }
}
#endif
