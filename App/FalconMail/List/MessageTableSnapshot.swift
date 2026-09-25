#if DEBUG
import AppKit
import SwiftUI
import FalconCore

/// `-FalconMailSnapshot <directory>` also draws the message table over made-up mail, at Outlook's
/// list width, in dark and light: a date header, an opened conversation with the owner's reply in
/// Sent, conversations with previews, a count and a paperclip, and rows whose text has not arrived
/// yet drawn grey with their dot, flag and clip already right, with the footer that says rows are
/// loading; then again offline, with the line that says how many older messages are on Gmail. It
/// writes down beside them how long the table takes to lay out a frame's rows during a fling over
/// 200,000. With `-FalconMailSnapshotOnly table` it draws the table alone. Nothing is ever put on
/// screen, and nothing is asked of any server: the rows' source is made up in memory.
@MainActor
enum MessageTableSnapshot {
    private static let appearances: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]

    static func render(to directory: String) {
        let account = UUID()
        let mail = MadeUpMail(account: account)
        MessageTableView.snapshotHasKeyboard = true
        defer { MessageTableView.snapshotHasKeyboard = false }
        for (footers, suffix) in [([ListFooter.loading(email: "alex@example.com")], ""),
                                  ([ListFooter.offline(hidden: 54_210)], "-offline")] {
            for (name, appearance) in appearances {
                let controller = ListController()
                let source = MadeUpSource(snapshot: mail.snapshot(offline: !suffix.isEmpty), footers: footers)
                let shown = expectation { await controller.show(mail.view, from: source) }
                guard shown else { continue }
                controller.content.insert(mail.contents(offline: !suffix.isEmpty))
                controller.setSelection(ListSelection(rows: [2]))
                let footerShown = expectation {
                    for _ in 0..<50 where controller.footers.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
                }
                _ = footerShown
                let table = MessageTableView(controller: controller, showsPreview: true, quickActions: [.delete, .flag])
                    .frame(width: OL.listWidth, height: 830)
                    .background(Color(nsColor: OLListColor.background))
                // The opened conversation's newest message selected, as Outlook's list was captured.
                capture(NSHostingView(rootView: table), size: NSSize(width: OL.listWidth, height: 830), appearance: appearance,
                        select: 2, to: "\(directory)/table\(suffix)-\(name).png")
            }
        }
        timing(to: "\(directory)/table-timing.txt")
        stored(to: directory)
    }

    /// An account that is not Google, through the same table: a made-up Inbox in a store in a
    /// temporary folder, its rows' text asked for as the table scrolls, and a message arriving
    /// while it is shown. What happened is written down beside the pictures.
    private static func stored(to directory: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FalconMailTableSnapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var report: [String] = []
        let store = MailStore(layout: FileLayout(root: root))
        let controller = ListController()
        var inboxID: UUID?
        var accountID = UUID()
        let ready = expectation {
            do {
                // Written as a synced account's files are, then read as at a launch.
                let layout = FileLayout(root: root)
                let account = AccountInfo(email: "sam@example.org", displayName: "Sam", provider: "imap",
                                          imapHost: "example.invalid", smtpHost: "example.invalid")
                accountID = account.id
                let inbox = FolderInfo(accountID: account.id, path: "INBOX", name: "Inbox", delimiter: "/", role: .inbox,
                                       attributes: [], isSelectable: true)
                try layout.ensureDirectory(layout.accountDirectory(account.id))
                try AtomicFile.writeJSON([account], to: layout.accountsFile)
                try AtomicFile.writeJSON([inbox], to: layout.foldersFile(account.id))
                try await store.load()
                inboxID = inbox.id
                let now = Date()
                var messages: [MessageSummary] = []
                for i in 0..<12 {
                    var message = MessageSummary(
                        accountID: account.id, folderID: inbox.id, uid: UInt32(i + 1), messageID: "<\(i)@example.org>", inReplyTo: "",
                        references: [], subject: i < 3 ? "Quarterly figures" : "Note \(i)",
                        from: EmailAddress(name: ["Ruth Ade", "Ken Ito", "Lea Moss"][i % 3], address: "p\(i % 3)@example.org"),
                        to: [EmailAddress(address: account.email)], cc: [], date: now.addingTimeInterval(-Double(i) * 3_000),
                        flags: i % 4 == 0 ? [] : [.seen], size: 2_000, snippet: "Words of message \(i)", hasAttachments: i == 5)
                    if i < 3 { message.threadKey = "<0@example.org>" }
                    messages.append(message)
                }
                try await store.folderStore(inbox).upsert(messages)
            } catch {
                report.append("could not make the store: \(error.localizedDescription)")
            }
        }
        guard ready, let inboxID else {
            report.append("the store was not ready")
            try? report.joined(separator: "\n").write(toFile: "\(directory)/table-stored.txt", atomically: true, encoding: .utf8)
            return
        }
        let source = StoreListSource(store: store)
        let view = ListView(scope: .folder(inboxID))
        _ = expectation { await controller.show(view, from: source) }
        report.append("rows shown: \(controller.rowCount), Items: \(controller.itemCount)")
        controller.scrolled(visible: 0..<controller.rowCount)
        _ = expectation {
            for _ in 0..<100 where controller.content.count < controller.rowCount { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        report.append("rows with their text: \(controller.content.count) of \(controller.rowCount)")
        report.append("first row: \(controller.rowContent(at: 0)?.conversation?.messageCount ?? 1) messages, \(controller.record(at: 0)?.displayKind == .conversation ? "a conversation" : "one message")")
        _ = expectation {
            let arrived = MessageSummary(accountID: accountID, folderID: inboxID, uid: 99, messageID: "<99@example.org>", inReplyTo: "",
                                         references: [], subject: "Just arrived", from: EmailAddress(name: "New Sender", address: "n@example.org"),
                                         to: [], cc: [], date: Date(), flags: [], size: 100, hasAttachments: false)
            try? await store.folderStore(store.folder(inboxID)!).upsert([arrived])
            await store.notifyMessagesChanged(folderID: inboxID)
            for _ in 0..<100 where controller.itemCount < 13 { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        report.append("after a message arrived: rows \(controller.rowCount), Items \(controller.itemCount), top row \(controller.key(at: 0)?.stringValue.hasSuffix(":99") == true ? "is the new message" : "is not the new message")")
        controller.scrolled(visible: 0..<controller.rowCount)
        _ = expectation { try? await Task.sleep(nanoseconds: 200_000_000) }
        MessageTableView.snapshotHasKeyboard = true
        let table = MessageTableView(controller: controller, showsPreview: true)
            .frame(width: OL.listWidth, height: 600)
            .background(Color(nsColor: OLListColor.background))
        capture(NSHostingView(rootView: table), size: NSSize(width: OL.listWidth, height: 600), appearance: .darkAqua,
                select: 0, to: "\(directory)/table-stored-dark.png")
        MessageTableView.snapshotHasKeyboard = false
        controller.stop()
        try? (report.joined(separator: "\n") + "\n").write(toFile: "\(directory)/table-stored.txt", atomically: true, encoding: .utf8)
    }

    /// How long a frame's worth of rows takes to lay out during a fling over 200,000: the table
    /// asks for about ten new rows a frame at 120 Hz, each built from the controller at once.
    private static func timing(to path: String) {
        let account = UUID()
        let controller = ListController()
        let count = 200_000
        var rows = ContiguousArray<DisplayRecord>()
        rows.reserveCapacity(count)
        for i in 0..<count {
            rows.append(DisplayRecord(key: UInt64(0x18a0_0000_0000_0000 + i * 16), slot: Int32(i),
                                      bits: i % 7 == 0 ? [.unread] : [], members: i % 3 == 0 ? 2 : 1,
                                      kind: i % 3 == 0 ? .conversation : .message))
        }
        let snapshot = ListSnapshot(view: ListView(scope: .allInboxes), rows: rows, complete: true, itemCount: count, sources: [account])
        guard expectation({ await controller.show(snapshot.view, from: MadeUpSource(snapshot: snapshot, footers: [])) }) else { return }
        for i in stride(from: 0, to: count, by: 97) {
            if let key = snapshot.rowKey(at: i) {
                controller.content.insert(MessageRowContent(key: key, from: EmailAddress(name: "Sender \(i)", address: "s\(i)@example.com"),
                                                            to: [], subject: "Subject \(i)", preview: "Opening words", date: Date()),
                                          for: key)
            }
        }
        let container = MessageTableContainer(frame: NSRect(x: 0, y: 0, width: OL.listWidth, height: 830))
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = container
        let coordinator = MessageTableView.Coordinator(MessageTableView(controller: controller))
        coordinator.attach(container)
        container.layoutSubtreeIfNeeded()
        let table = container.table
        let clip = container.scrollView.contentView
        guard let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
        // A fling at 120 Hz moving ten rows a frame: the table lays out the rows scrolled in, and
        // they are drawn, as the screen would.
        var layout: [Double] = []
        var drawn: [Double] = []
        var y: CGFloat = 0
        for frame in 0..<600 {
            y += 10 * OL.listRow
            let start = DispatchTime.now().uptimeNanoseconds
            clip.scroll(to: NSPoint(x: 0, y: y))
            container.scrollView.reflectScrolledClipView(clip)
            table.layoutSubtreeIfNeeded()
            let laid = DispatchTime.now().uptimeNanoseconds
            if frame % 6 == 0 { container.cacheDisplay(in: container.bounds, to: bitmap) }
            let end = DispatchTime.now().uptimeNanoseconds
            layout.append(Double(laid - start) / 1_000_000)
            if frame % 6 == 0 { drawn.append(Double(end - start) / 1_000_000) }
        }
        func percentile(_ values: [Double], _ p: Int) -> Double {
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, sorted.count * p / 100)]
        }
        let text = String(format: """
            A fling over 200,000 rows at 120 Hz, ten rows a frame, debug build (the target, for the release build, is under 8 ms a frame):
            laying out the rows scrolled in: median %.3f ms, 99th percentile %.3f ms a frame;
            laying them out and drawing the whole list: median %.3f ms, 99th percentile %.3f ms a frame.

            """, percentile(layout, 50), percentile(layout, 99), percentile(drawn, 50), percentile(drawn, 99))
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        coordinator.detach()
    }

    /// Runs `body` on the main actor, turning the run loop until it finishes, as a snapshot run
    /// has no other way to wait.
    private static func expectation(_ body: @escaping @MainActor () async -> Void) -> Bool {
        var done = false
        Task { @MainActor in
            await body()
            done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !done, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return done
    }

    private static func capture(_ view: NSView, size: NSSize, appearance: NSAppearance.Name, select row: Int? = nil,
                                to path: String) {
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        if let row, let table = firstTable(in: view) { table.selectRowIndexes([row], byExtendingSelection: false) }
        view.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

extension MessageTableSnapshot {
    fileprivate static func firstTable(in view: NSView) -> MessageNSTableView? {
        if let table = view as? MessageNSTableView { return table }
        for child in view.subviews { if let table = firstTable(in: child) { return table } }
        return nil
    }
}

/// Made-up mail for the table's snapshots.
private struct MadeUpMail {
    let account: UUID
    let view = ListView(scope: .allInboxes, conversations: true, dateGroups: true)
    private let now = Date()

    private func key(_ i: Int) -> RowKey { .gmail(account: account, id: GmailMessageID(raw: 0x18a0_0000_0000_0000 + UInt64(i) * 16)) }
    private func record(_ i: Int, _ kind: DisplayKind, bits: DisplayBits = [], members: UInt16 = 1, unread: UInt16 = 0) -> DisplayRecord {
        DisplayRecord(key: 0x18a0_0000_0000_0000 + UInt64(i) * 16, slot: Int32(i), bits: bits, members: members, unread: unread,
                      kind: kind)
    }

    /// Today's header, an opened conversation with three messages, three conversations and
    /// messages with text, and five whose text is on its way; offline, only those with text.
    func snapshot(offline: Bool) -> ListSnapshot {
        var rows: ContiguousArray<DisplayRecord> = [
            .header(group: 0),
            record(1, .conversation, bits: [.unread, .expanded], members: 2, unread: 1),
            record(1, .child, bits: [.unread], unread: 1), record(2, .child), record(3, .child),
            record(4, .conversation, bits: [.hasAttachment, .attachmentKnown], members: 3, unread: 2),
            record(5, .message),
            record(6, .message, bits: [.flagged]),
            .header(group: 1),
            record(7, .conversation, members: 2)
        ]
        if !offline {
            rows += [record(8, .message, bits: [.unread], unread: 1), record(9, .conversation, bits: [.flagged], members: 4),
                     record(10, .message, bits: [.hasAttachment, .attachmentKnown]), record(11, .message),
                     record(12, .message, bits: [.unread], unread: 1)]
        }
        return ListSnapshot(view: view, rows: rows, headers: [0: "Today", 1: "Yesterday"], complete: true,
                            itemCount: offline ? 54_218 : 13, sources: [account])
    }

    func contents(offline: Bool) -> [RowKey: MessageRowContent] {
        let maya = EmailAddress(name: "Maya Lindqvist", address: "maya@example.com")
        let tom = EmailAddress(name: "Tom Okafor", address: "tom@example.com")
        let alex = EmailAddress(name: "Alex Example", address: "alex@example.com")
        let today = Calendar.current.startOfDay(for: now)
        var out: [RowKey: MessageRowContent] = [:]
        out[key(1)] = MessageRowContent(
            key: key(1), from: maya, to: [alex], subject: "Container booking for week 41", preview: "Can you confirm the slot",
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
        out[key(6)] = MessageRowContent(key: key(6), from: maya, to: [alex], subject: "Rates for Q4", preview: "",
                                        date: today.addingTimeInterval(6 * 3_600))
        out[key(7)] = MessageRowContent(key: key(7), from: tom, to: [alex], subject: "Re: Truck schedule",
                                        preview: "Thursday works for us", date: today.addingTimeInterval(-5 * 3_600),
                                        conversation: ConversationContent(senders: [alex, tom], messageCount: 2,
                                                                          newestDate: today.addingTimeInterval(-5 * 3_600)))
        return out
    }
}

/// A source that answers with what it was given and asks nothing of anyone.
private final class MadeUpSource: ListSourceExtras, @unchecked Sendable {
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
    func summary(for key: RowKey, in view: ListView) async -> RowAvailability { .gone }
    func setExpanded(_ keys: Set<RowKey>, in view: ListView) async {}
    func footers(of view: ListView) -> AsyncStream<[ListFooter]> {
        let lines = self.lines
        return AsyncStream { $0.yield(lines) }
    }
}
#endif
