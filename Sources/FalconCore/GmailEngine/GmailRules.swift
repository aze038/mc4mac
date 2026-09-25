import Foundation

// Rules and mutes for a Google account, through the Gmail API. Rules are checked on the Mac with
// `RuleEngine`, as for every account, and their actions go to Gmail as label changes with no
// undo window. They act only on mail that arrived now and carries INBOX, received in the last 48
// hours and not from the owner's own addresses, so an import of old mail, or a message dated
// years ahead, never sets them off. A body condition uses the text the fetch of new mail already
// gave, so it costs nothing extra.

/// A message that just arrived, as the fetch of new mail gives it, for rules and mutes.
public struct GmailArrival: Hashable, Sendable {
    public var ref: GmailRef
    public var labels: Set<GmailLabelID>
    /// When Gmail received it.
    public var internalDate: Date
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var subject: String
    public var messageID: String
    public var inReplyTo: String
    public var references: [String]
    public var hasAttachments: Bool
    /// The text a body condition is checked against.
    public var bodyText: String

    public init(ref: GmailRef, labels: Set<GmailLabelID>, internalDate: Date, from: EmailAddress, to: [EmailAddress] = [],
                cc: [EmailAddress] = [], subject: String, messageID: String = "", inReplyTo: String = "",
                references: [String] = [], hasAttachments: Bool = false, bodyText: String = "") {
        self.ref = ref
        self.labels = labels
        self.internalDate = internalDate
        self.from = from
        self.to = to
        self.cc = cc
        self.subject = subject
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.hasAttachments = hasAttachments
        self.bodyText = bodyText
    }

    /// From a `format=full` answer, which gives the headers, the labels and the text at once.
    /// Nil when its ids or its receipt time do not parse.
    public init?(message: GmailMessage) {
        guard let ref = message.ref, let received = message.receivedDate else { return nil }
        let row = GmailServerRow.summary(for: message, accountID: UUID())
        let opened = GmailMessageContent.textStage(message)
        self.init(ref: ref, labels: message.labels, internalDate: received, from: row.from, to: row.to, cc: row.cc,
                  subject: row.subject, messageID: row.messageID, inReplyTo: row.inReplyTo, references: row.references,
                  hasAttachments: !opened.listedAttachments.isEmpty || row.hasAttachments, bodyText: opened.message.bestText)
    }

    /// A message kept on the Mac, for Run Rules Now.
    public init(cached: GmailCachedMessage, labels: Set<GmailLabelID>, body: GmailReducedBody?) {
        let text = body?.textPlain ?? body?.textHTML.map(GmailArrival.plainText(fromHTML:)) ?? cached.preview
        self.init(ref: GmailRef(id: cached.id, threadID: cached.threadID), labels: labels, internalDate: cached.date,
                  from: cached.from, to: cached.to, cc: cached.cc, subject: cached.subject, messageID: cached.messageID,
                  inReplyTo: cached.inReplyTo, references: cached.references, hasAttachments: cached.hasAttachments,
                  bodyText: text)
    }

    static func plainText(fromHTML html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    var ruleSubject: RuleSubject {
        let summary = MessageSummary(accountID: UUID(), folderID: UUID(), uid: 0, messageID: messageID, inReplyTo: inReplyTo,
                                     references: references, subject: subject, from: from, to: to, cc: cc, date: internalDate,
                                     flags: [], size: 0, hasAttachments: hasAttachments)
        return RuleSubject(summary: summary, body: bodyText)
    }
}

/// What rules and mutes did with new mail.
public struct GmailArrivalOutcome: Hashable, Sendable {
    /// Mail of muted conversations: filed away, and never announced.
    public var muted: Set<GmailMessageID>
    /// Mail a rule changed.
    public var ruled: Set<GmailMessageID>
    /// Mail a rule took out of the Inbox, which is not announced as new mail in it.
    public var filedAway: Set<GmailMessageID>

    public init(muted: Set<GmailMessageID> = [], ruled: Set<GmailMessageID> = [], filedAway: Set<GmailMessageID> = []) {
        self.muted = muted
        self.ruled = ruled
        self.filedAway = filedAway
    }
}

/// Rule actions in Gmail's terms.
public enum GmailRulePlanner {
    /// How long after Gmail received it new mail is still ruled on.
    public static let window: TimeInterval = 48 * 3600

    /// The labels a message ends with once its rules' actions have run, as one change: each
    /// action is applied in turn to the labels it has, and one that files the message away ends
    /// its actions, as v1.10.0 does. `destination` resolves a folder a rule names; an action whose
    /// folder cannot be used is skipped, and why is returned.
    public static func change(for labels: Set<GmailLabelID>, actions: [RuleAction],
                              destination: (String) -> Result<GmailMoveDestination, GmailActionError>)
        -> (add: Set<GmailLabelID>, remove: Set<GmailLabelID>, skipped: [GmailActionError]) {
        var now = labels
        var skipped: [GmailActionError] = []
        func applying(_ plan: GmailActionPlan?) {
            guard case .labels(let rule, _, _)? = plan, let delta = rule.delta(for: now) else { return }
            now.formUnion(delta.add)
            now.subtract(delta.remove)
        }
        for action in actions {
            let before = now
            switch action.kind {
            case .markRead: applying(try? GmailActionRules.plan(.markRead, in: .inbox))
            case .flag: applying(try? GmailActionRules.plan(.flag, in: .inbox))
            case .delete: applying(try? GmailActionRules.plan(.delete, in: .inbox))
            case .archive: applying(try? GmailActionRules.plan(.archive, in: .inbox))
            case .moveToFolder, .copyToFolder:
                guard !action.value.isEmpty else { continue }
                let target: GmailMoveDestination
                switch destination(action.value) {
                case .success(let found): target = found
                case .failure(let why):
                    skipped.append(why)
                    continue
                }
                let verb: MailActionRequest.Verb = action.kind == .moveToFolder ? .move(to: UUID()) : .copy(to: UUID())
                applying(try? GmailActionRules.plan(verb, in: .inbox, to: target))
            case .stopProcessing:
                return (now.subtracting(labels), labels.subtracting(now), skipped)
            }
            // Filed away: out of the Inbox, or into Deleted Items or Junk Email.
            let filed = (before.contains(.inbox) && !now.contains(.inbox)) || (!before.contains(.trash) && now.contains(.trash))
            if filed { break }
        }
        return (now.subtracting(labels), labels.subtracting(now), skipped)
    }

    /// The folder a rule names, by its path. Rules store the path they were made with, often an
    /// IMAP one, so a user label is found by its name, and Gmail's own folders by the names they
    /// had over IMAP as well as Outlook's.
    public static func destination(forPath path: String, folders: [FolderInfo],
                                   labels: [GmailLabelEntry]) -> Result<GmailMoveDestination, GmailActionError> {
        func usable(_ folder: FolderInfo) -> Result<GmailMoveDestination, GmailActionError> {
            do {
                return .success(try GmailActionRules.destination(for: folder))
            } catch {
                let sentence = "A rule puts mail in “\(folder.name)”, which Gmail doesn't let apps do, so that part of the rule was skipped."
                return .failure(GmailActionError(.notAvailable, sentence, names: [folder.name]))
            }
        }
        if let folder = folders.first(where: { $0.path == path }), GmailActionFolder(folder: folder) != nil {
            return usable(folder)
        }
        if let entry = labels.first(where: { $0.kind == .user && $0.name.caseInsensitiveCompare(path) == .orderedSame }) {
            return .success(.label(entry.id))
        }
        var name = path
        for group in ["[Gmail]/", "[Google Mail]/"] where name.hasPrefix(group) { name = String(name.dropFirst(group.count)) }
        switch name.lowercased() {
        case "inbox": return .success(.label(.inbox))
        case "important": return .success(.label(.important))
        case "starred", "flagged": return .success(.starred)
        case "all mail", "archive": return .success(.archive)
        case "spam", "junk", "junk email", "junk e-mail": return .success(.junkEmail)
        case "trash", "bin", "deleted items", "deleted messages": return .success(.deletedItems)
        default:
            // A folder shown in the sidebar under its Outlook name.
            if let folder = folders.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
               GmailActionFolder(folder: folder) != nil {
                return usable(folder)
            }
            let sentence = "A rule names the folder “\(path)”, which this Gmail account doesn't have, so that part of the rule was skipped."
            return .failure(GmailActionError(.unknownFolder, sentence, names: [path]))
        }
    }
}

extension GmailActions {
    /// Runs mutes, then rules, on mail that arrived now. The engine calls it for every check that
    /// brought new mail, before it announces any: mail in `muted` or `filedAway` is not announced.
    /// Muted mail loses INBOX and UNREAD and runs no rules. Changes go to Gmail at once, with no
    /// undo window, and are retried like any other change until Gmail has them.
    public func handleArrivals(_ arrivals: [GmailArrival]) async -> GmailArrivalOutcome {
        let now = clock.now()
        let own = Set((await host?.ownAddresses() ?? []).map { $0.lowercased() })
        let eligible = arrivals.filter { arrival in
            arrival.labels.contains(.inbox) && !arrival.labels.contains(.spam) && !arrival.labels.contains(.trash)
                && now.timeIntervalSince(arrival.internalDate) <= GmailRulePlanner.window
                && arrival.internalDate.timeIntervalSince(now) <= 24 * 3600
                && !own.contains(arrival.from.address.lowercased())
        }
        guard !eligible.isEmpty else { return GmailArrivalOutcome() }
        var outcome = GmailArrivalOutcome()
        let muted = await mutedArrivals(eligible)
        if !muted.isEmpty {
            outcome.muted = Set(muted.map(\.ref.id))
            // Read mail loses only INBOX, unread mail UNREAD as well: one group for each.
            let rule = GmailLabelRule(remove: [.inbox, .unread])
            var groups: [Set<GmailLabelID>: [GmailMessageID]] = [:]
            for arrival in muted {
                if let change = rule.delta(for: arrival.labels) { groups[change.remove, default: []].append(arrival.ref.id) }
            }
            await performAutomatically("mute", deltas: groups.sorted { $0.key.count > $1.key.count }
                .map { PendingGmailOp.Delta(add: [], remove: $0.key, ids: $0.value) })
            Log.info("gmail", "filed \(muted.count) new messages of muted conversations")
        }
        let rest = eligible.filter { !outcome.muted.contains($0.ref.id) }
        let ruled = await applyRules(to: rest)
        outcome.ruled = ruled.changed
        outcome.filedAway = ruled.filedAway
        return outcome
    }

    /// Run Rules Now: the rules over the Inbox's messages kept on the Mac, whenever they came.
    /// Returns how many messages a rule changed.
    @discardableResult
    public func runRulesOnInbox() async throws -> Int {
        let snapshot = await store.index()
        let ids = await store.cachedIDs().filter { id in
            guard let slot = snapshot.slotByID[id.raw] else { return false }
            let has: (GmailLabelID) -> Bool = { snapshot.record(atSlot: slot, has: $0) }
            return has(.inbox) && !has(.spam) && !has(.trash)
        }
        guard !ids.isEmpty else { return 0 }
        let cached = await store.cachedMessages(Array(ids))
        var arrivals: [GmailArrival] = []
        for (id, message) in cached {
            guard let slot = snapshot.slotByID[id.raw] else { continue }
            let body = try? await store.body(of: id)
            arrivals.append(GmailArrival(cached: message, labels: snapshot.labels(atSlot: slot), body: body ?? nil))
        }
        arrivals.sort { ($0.internalDate, $0.ref.id) > ($1.internalDate, $1.ref.id) }
        return await applyRules(to: arrivals).changed.count
    }

    /// Rules' actions as label changes, grouped by what each message gains and loses.
    private func applyRules(to arrivals: [GmailArrival]) async -> (changed: Set<GmailMessageID>, filedAway: Set<GmailMessageID>) {
        guard let rules, !arrivals.isEmpty else { return ([], []) }
        let definitions = await rules.all().filter(\.isEnabled)
        guard !definitions.isEmpty else { return ([], []) }
        let folders = await host?.folders().filter { $0.accountID == accountID } ?? []
        let labels = await store.labelTable()
        struct Key: Hashable { var add: [GmailLabelID]; var remove: [GmailLabelID] }
        var order: [Key] = []
        var grouped: [Key: [GmailMessageID]] = [:]
        var changed: Set<GmailMessageID> = []
        var filedAway: Set<GmailMessageID> = []
        var skipped: [GmailActionError] = []
        for arrival in arrivals {
            let actions = RuleEngine.actions(for: definitions, accountID: accountID, subject: arrival.ruleSubject)
            guard !actions.isEmpty else { continue }
            let change = GmailRulePlanner.change(for: arrival.labels, actions: actions) { path in
                GmailRulePlanner.destination(forPath: path, folders: folders, labels: labels)
            }
            for why in change.skipped where !skipped.contains(why) { skipped.append(why) }
            guard !change.add.isEmpty || !change.remove.isEmpty else { continue }
            let key = Key(add: change.add.sorted(), remove: change.remove.sorted())
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(arrival.ref.id)
            changed.insert(arrival.ref.id)
            if change.remove.contains(.inbox) || change.add.contains(.trash) || change.add.contains(.spam) {
                filedAway.insert(arrival.ref.id)
            }
        }
        for why in skipped {
            Log.info("gmail", "a rule action was skipped: \(why.kind.rawValue)")
            await host?.notice(why.sentence, names: why.names)
        }
        guard !order.isEmpty else { return (changed, filedAway) }
        await performAutomatically("rule", deltas: order.map {
            PendingGmailOp.Delta(add: Set($0.add), remove: Set($0.remove), ids: grouped[$0] ?? [])
        })
        Log.info("gmail", "rules changed \(changed.count) messages")
        return (changed, filedAway)
    }
}
