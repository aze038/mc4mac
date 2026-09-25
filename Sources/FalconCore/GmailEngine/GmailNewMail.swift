import Foundation

// Which mail is new (§4.3, §4.7). A message is new when Gmail received it since the last check,
// by Gmail's own clock; where it sits in the list does not matter. So imported mail, or a message
// dated years ahead, can never stop notifications, and a message Gmail took a while to scan still
// counts.

/// The rules, as pure functions, so each can be tested on its own.
public enum GmailArrivalRule {
    /// Covers a large message Gmail took longer to scan, which can reach the history after a
    /// later one.
    public static let scanSlack: TimeInterval = 10 * 60
    /// An imported message dated further ahead than this is old mail, and can never make later
    /// mail look old.
    public static let furthestAhead: TimeInterval = 24 * 3600
    public static let announceWindow: TimeInterval = 24 * 3600
    public static let rulesWindow: TimeInterval = 48 * 3600

    /// The earliest receipt time that counts as arriving now. After sleep the last check was
    /// before the sleep, so mail that came in meanwhile counts. During a flood, mail dated before
    /// the flood began is the other app's import, not new mail.
    public static func windowStart(lastCheckStart: Date, floodBegan: Date?) -> Date {
        let start = lastCheckStart.addingTimeInterval(-scanSlack)
        guard let floodBegan else { return start }
        return max(start, floodBegan)
    }

    public static func arrivedNow(internalDate: Date, windowStart: Date, gmailNow: Date, importedByFalconMail: Bool) -> Bool {
        !importedByFalconMail && internalDate >= windowStart && internalDate <= gmailNow.addingTimeInterval(furthestAhead)
    }

    /// Whether mail that arrived now is announced with a notification and the New message sound:
    /// delivered to the Inbox, not Junk Email or Deleted Items, received in the last day, not
    /// from one of the owner's own addresses, and not in a muted conversation.
    public static func announces(labels: Set<GmailLabelID>, internalDate: Date, from: String, gmailNow: Date,
                                 ownAddresses: Set<String>, muted: Bool) -> Bool {
        labels.contains(.inbox) && labels.isDisjoint(with: [.spam, .trash])
            && internalDate >= gmailNow.addingTimeInterval(-announceWindow)
            && !ownAddresses.contains(from.lowercased()) && !muted
    }

    /// Rules and mutes act on the same mail with a window of two days, so a rule still files mail
    /// that came in over a weekend the Mac slept through most of.
    public static func runsRules(labels: Set<GmailLabelID>, internalDate: Date, from: String, gmailNow: Date,
                                 ownAddresses: Set<String>) -> Bool {
        labels.contains(.inbox) && labels.isDisjoint(with: [.spam, .trash])
            && internalDate >= gmailNow.addingTimeInterval(-rulesWindow) && !ownAddresses.contains(from.lowercased())
    }
}

/// Another app importing into the account, seen from the history: many messages added deep in the
/// order, which FalconMail did not import itself (§4.3 step 5). Such mail shares Google's per-user
/// budget with FalconMail, so while it lasts FalconMail uses less, stops fetching those messages
/// one by one, and lists the mailbox again every half hour and once when it ends.
public struct GmailFloodDetector: Sendable, Equatable {
    public static let deepInOneCheck = 50
    public static let deepInWindow = 200
    public static let window: TimeInterval = 10 * 60
    public static let relistEvery: TimeInterval = 30 * 60
    public static let quietToEnd: TimeInterval = 30 * 60

    public private(set) var began: Date?
    public private(set) var lastDeep: Date?
    public private(set) var lastRelist: Date?
    private var recent: [(at: Date, count: Int)] = []

    public init() {}

    public var isActive: Bool { began != nil }

    public enum Step: Equatable { case began, relist, ended }

    /// A check found `count` deep messages that were not FalconMail's own imports.
    public mutating func noteDeep(_ count: Int, at now: Date) -> Step? {
        recent.removeAll { now.timeIntervalSince($0.at) > Self.window }
        guard count > 0 else { return nil }
        recent.append((now, count))
        lastDeep = now
        guard began == nil else { return nil }
        let inWindow = recent.reduce(0) { $0 + $1.count }
        guard count > Self.deepInOneCheck || inWindow > Self.deepInWindow else { return nil }
        began = now
        lastRelist = now
        return .began
    }

    /// Whether a relisting is due, or the flood is over, which also wants one last relisting.
    public mutating func tick(at now: Date) -> Step? {
        guard began != nil else { return nil }
        if now.timeIntervalSince(lastDeep ?? began ?? now) >= Self.quietToEnd {
            began = nil
            lastRelist = nil
            recent.removeAll()
            return .ended
        }
        if now.timeIntervalSince(lastRelist ?? .distantPast) >= Self.relistEvery {
            lastRelist = now
            return .relist
        }
        return nil
    }

    /// A flood that was under way at the last quit keeps the time it began.
    mutating func restore(began: Date) {
        self.began = began
    }

    public static func == (a: GmailFloodDetector, b: GmailFloodDetector) -> Bool {
        a.began == b.began && a.lastDeep == b.lastDeep && a.lastRelist == b.lastRelist
            && a.recent.map(\.at) == b.recent.map(\.at) && a.recent.map(\.count) == b.recent.map(\.count)
    }
}

/// Mail that arrived now, as rules and mutes need it (§7.6). The body a rule may look at comes from
/// the `format=full` fetch the arrival already made, so it costs nothing more. The engine makes one
/// for each message that arrived now, and the actions make them from a full answer or a copy kept
/// on the Mac, for Run Rules Now.
public struct GmailArrival: Sendable, Hashable {
    public var ref: GmailRef
    public var summary: MessageSummary
    public var labels: Set<GmailLabelID>
    /// When Gmail received it.
    public var internalDate: Date
    public var textPlain: String?
    /// Announced as new mail: the Inbox, the last day, not the owner's, not muted.
    public var isAnnounced: Bool
    /// Within the two days rules act on.
    public var runsRules: Bool

    public init(ref: GmailRef, summary: MessageSummary, labels: Set<GmailLabelID>, internalDate: Date, textPlain: String?,
                isAnnounced: Bool, runsRules: Bool) {
        self.ref = ref
        self.summary = summary
        self.labels = labels
        self.internalDate = internalDate
        self.textPlain = textPlain
        self.isAnnounced = isAnnounced
        self.runsRules = runsRules
    }

    /// An arrival described by its headers alone. The rules and mutes still decide for themselves
    /// which mail they act on, so it is marked as mail they may act on.
    public init(ref: GmailRef, labels: Set<GmailLabelID>, internalDate: Date, from: EmailAddress, to: [EmailAddress] = [],
                cc: [EmailAddress] = [], subject: String, messageID: String = "", inReplyTo: String = "",
                references: [String] = [], hasAttachments: Bool = false, bodyText: String = "") {
        var summary = MessageSummary(accountID: UUID(), folderID: UUID(), uid: 0, messageID: messageID, inReplyTo: inReplyTo,
                                     references: references, subject: subject, from: from, to: to, cc: cc, date: internalDate,
                                     flags: [], size: 0, hasAttachments: hasAttachments, threadKey: ref.threadID.threadKey)
        summary.gmailID = ref.id
        summary.gmailThreadID = ref.threadID
        summary.internalDate = internalDate
        self.init(ref: ref, summary: summary, labels: labels, internalDate: internalDate, textPlain: bodyText,
                  isAnnounced: labels.contains(.inbox), runsRules: true)
    }

    public var from: EmailAddress {
        get { summary.from }
        set { summary.from = newValue }
    }
    public var to: [EmailAddress] {
        get { summary.to }
        set { summary.to = newValue }
    }
    public var cc: [EmailAddress] {
        get { summary.cc }
        set { summary.cc = newValue }
    }
    public var subject: String {
        get { summary.subject }
        set { summary.subject = newValue }
    }
    public var messageID: String {
        get { summary.messageID }
        set { summary.messageID = newValue }
    }
    public var inReplyTo: String {
        get { summary.inReplyTo }
        set { summary.inReplyTo = newValue }
    }
    public var references: [String] {
        get { summary.references }
        set { summary.references = newValue }
    }
    public var hasAttachments: Bool {
        get { summary.hasAttachments }
        set { summary.hasAttachments = newValue }
    }
    /// The text a body condition is checked against.
    public var bodyText: String {
        get { textPlain ?? "" }
        set { textPlain = newValue }
    }
}

/// Rows, summaries and cached copies built from Gmail's answers.
public enum GmailMessageBuilder {
    /// The headers a row, a reply and a forward need, asked for with `format=metadata`.
    public static let headers = GmailAPIClient.rowHeaders + ["Reply-To", "Bcc"]

    /// A Google row's summary, keyed `"<account>:gm:<hex>"`, as the list, windows, notifications
    /// and actions pass it around. Its folder is the view it is seen in, never a stored one.
    public static func summary(_ message: GmailMessage, accountID: UUID, folderID: UUID) -> MessageSummary? {
        guard let ref = message.ref else { return nil }
        var summary = GmailServerRow.summary(for: message, accountID: accountID)
        summary.id = RowKey.gmail(account: accountID, id: ref.id).stringValue
        summary.folderID = folderID
        summary.threadKey = ref.threadID.threadKey
        summary.gmailID = ref.id
        summary.gmailThreadID = ref.threadID
        summary.labelIDs = message.labels.sorted()
        summary.internalDate = message.receivedDate
        let bcc = AddressParser.parse(message.header("Bcc"))
        summary.bcc = bcc.isEmpty ? nil : bcc
        let replyTo = AddressParser.parse(message.header("Reply-To"))
        summary.replyTo = replyTo.isEmpty ? nil : replyTo
        if message.payload?.parts != nil || message.payload?.body?.attachmentId != nil {
            summary.hasAttachments = !GmailMessageContent.textStage(message).listedAttachments.isEmpty
        }
        return summary
    }

    /// What a list row shows.
    public static func row(_ message: GmailMessage, accountID: UUID) -> MessageRowContent? {
        guard let ref = message.ref else { return nil }
        let summary = GmailServerRow.summary(for: message, accountID: accountID)
        return MessageRowContent(key: .gmail(account: accountID, id: ref.id), from: summary.from, to: summary.to,
                                 subject: summary.subject, preview: String(summary.snippet.prefix(100)), date: summary.date,
                                 size: message.sizeEstimate, hasAttachments: summary.hasAttachments)
    }

    public static func row(_ cached: GmailCachedMessage, accountID: UUID) -> MessageRowContent {
        MessageRowContent(key: .gmail(account: accountID, id: cached.id), from: cached.from, to: cached.to,
                          subject: cached.subject, preview: cached.preview, date: cached.date, size: cached.size,
                          hasAttachments: cached.hasAttachments)
    }

    /// A message kept on the Mac from its `format=full` answer, with its text and HTML and any inline
    /// pictures already fetched. Attachments stay stubs.
    public static func cached(_ message: GmailMessage, opened: GmailOpenedMessage? = nil, now: Date)
        -> (message: GmailCachedMessage, body: GmailReducedBody)? {
        guard let ref = message.ref else { return nil }
        let opened = opened ?? GmailMessageContent.textStage(message)
        let mime = opened.message
        let preview = GmailServerRow.decodeEntities(message.snippet ?? mime.snippet)
        let listed = opened.listedAttachments
        let attachments = opened.attachments.map {
            GmailCachedAttachment(partID: $0.id, attachmentID: $0.attachmentID, filename: $0.filename, mimeType: $0.mimeType,
                                  size: $0.size, contentID: $0.contentID, isInline: $0.isInline)
        }
        let cachedMessage = GmailCachedMessage(
            id: ref.id, threadID: ref.threadID, from: mime.from, to: mime.to, cc: mime.cc,
            bcc: AddressParser.parse(mime.headers.first("Bcc")), replyTo: mime.replyTo, subject: mime.subject,
            preview: String(preview.prefix(100)), date: message.receivedDate ?? mime.date ?? now,
            size: message.sizeEstimate ?? 0, hasAttachments: !listed.isEmpty, messageID: mime.messageID,
            inReplyTo: mime.inReplyTo, references: mime.references, attachments: attachments, cachedAt: now)
        let pictures = mime.attachments.compactMap { part -> GmailInlineImage? in
            guard let cid = part.contentID, part.mimeType.hasPrefix("image/"), part.data.count <= 100_000 else { return nil }
            return GmailInlineImage(contentID: cid, mimeType: part.mimeType, data: part.data)
        }
        return (cachedMessage, GmailReducedBody(textPlain: mime.textPlain, textHTML: mime.textHTML, inlineImages: pictures))
    }

    /// A conversation's summary from its messages as `threads.get` gives them, oldest first.
    public static func threadSummary(_ thread: GmailThread) -> GmailThreadSummary? {
        guard let id = thread.threadID else { return nil }
        let members = (thread.messages ?? []).compactMap { m -> GmailThreadMember? in
            guard let mid = m.gmailID else { return nil }
            let from = AddressParser.parse(m.header("From")).first ?? EmailAddress(address: "")
            return GmailThreadMember(id: mid, from: from, date: m.receivedDate ?? .distantPast)
        }.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        guard let newest = members.last else { return nil }
        return GmailThreadSummary(threadID: id, senders: senders(members.map(\.from)), messageCount: members.count,
                                  newestDate: newest.date, members: members)
    }

    /// A conversation's summary from its cached messages, when every member is kept on the Mac.
    public static func threadSummary(_ id: GmailThreadID, cached: [GmailCachedMessage]) -> GmailThreadSummary? {
        let members = cached.map { GmailThreadMember(id: $0.id, from: $0.from, date: $0.date) }.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        guard let newest = members.last else { return nil }
        return GmailThreadSummary(threadID: id, senders: senders(members.map(\.from)), messageCount: members.count,
                                  newestDate: newest.date, members: members)
    }

    /// Each sender once, in the order they first wrote, as Outlook lists a conversation's senders.
    static func senders(_ all: [EmailAddress]) -> [EmailAddress] {
        var seen: Set<String> = []
        return all.filter { seen.insert($0.address.lowercased()).inserted }
    }
}
