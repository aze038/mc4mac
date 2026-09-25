import XCTest
@testable import FalconCore

/// Rules and mutes of a Google account, through the Gmail API: which new mail they act on, what
/// each rule action becomes in labels, folders a rule names by an IMAP path, Run Rules Now, and
/// muted conversations, whose Unmute leaves no twin record behind.
final class GmailRulesTests: XCTestCase {
    private var fixtures: [ActionsFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { await fixture.cleanUp() }
        fixtures = []
    }

    private func fixture(undoWindow: TimeInterval = 60) async throws -> ActionsFixture {
        let made = try await ActionsFixture(undoWindow: undoWindow)
        fixtures.append(made)
        return made
    }

    private func rule(_ name: String, on field: RuleCondition.Field = .subject, _ value: String,
                      _ actions: [RuleAction]) -> RuleDefinition {
        RuleDefinition(name: name, conditions: [RuleCondition(field: field, op: .contains, value: value)], actions: actions)
    }

    /// New mail as the fetch of new mail gives it, placed in the index as the engine would.
    private func arrival(_ f: ActionsFixture, subject: String, from: String = "Ana <ana@example.com>",
                         labels: Set<GmailLabelID> = [.inbox, .unread], thread: GmailThreadID? = nil, messageID: String? = nil,
                         received: Date? = nil, body: String = "") async throws -> GmailArrival {
        let ref = try await f.add(subject, labels: labels, thread: thread, from: from, messageID: messageID)
        let sender = AddressParser.parse(from).first ?? EmailAddress(address: from)
        return GmailArrival(ref: ref, labels: labels, internalDate: received ?? f.clock.now, from: sender, subject: subject,
                            messageID: messageID ?? "<\(ref.id.hex)@mail.example.com>", bodyText: body)
    }

    // MARK: - Which mail rules act on

    func testRulesActOnlyOnNewInboxMailFromOthers() async throws {
        let f = try await fixture()
        try await f.rules.save([rule("Invoices", "invoice", [RuleAction(kind: .moveToFolder, value: "Clients")])])
        f.host.own = ["owner@example.com"]
        let fresh = try await arrival(f, subject: "Invoice 12")
        let old = try await arrival(f, subject: "Invoice 11", received: f.clock.now.addingTimeInterval(-49 * 3600))
        let mine = try await arrival(f, subject: "Invoice copy", from: "Owner <OWNER@example.com>")
        let notInbox = try await arrival(f, subject: "Invoice sent", labels: [.sent])
        let future = try await arrival(f, subject: "Invoice 2037", received: f.clock.now.addingTimeInterval(11 * 365 * 86_400))
        let outcome = await f.actions.handleArrivals([fresh, old, mine, notInbox, future])
        XCTAssertEqual(outcome.ruled, [fresh.ref.id])
        XCTAssertEqual(outcome.filedAway, [fresh.ref.id], "not announced in the Inbox it has left")
        XCTAssertTrue(outcome.muted.isEmpty)
        let shown = await f.shown(fresh.ref)
        XCTAssertEqual(shown, [.unread, f.label("Clients")], "shown at once")
        let flushed = await f.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(f.gmailLabels(fresh.ref), [.unread, f.label("Clients")])
        for untouched in [old, mine, future] { XCTAssertEqual(f.gmailLabels(untouched.ref), [.inbox, .unread]) }
        XCTAssertEqual(f.gmailLabels(notInbox.ref), [.sent])
        XCTAssertEqual(f.gmail.calls[.messagesModify], 1, "5 units for the rule, no IMAP anywhere")
    }

    func testARuleChangeHasNoUndoWindow() async throws {
        let f = try await fixture(undoWindow: 600)
        try await f.rules.save([rule("Flag boss", on: .from, "boss@", [RuleAction(kind: .flag)])])
        let mail = try await arrival(f, subject: "Now", from: "Boss <boss@example.com>")
        _ = await f.actions.handleArrivals([mail])
        let sent = await f.eventually { f.gmailLabels(mail.ref)?.contains(.starred) == true }
        XCTAssertTrue(sent, "sent at once, while a manual change would still wait")
    }

    func testARuleIsNotHeldUpByTheUndoWindowOfAnotherChange() async throws {
        let f = try await fixture(undoWindow: 600)
        try await f.rules.save([rule("Read receipts", "receipt", [RuleAction(kind: .markRead)])])
        let archived = try await f.add("Archive me")
        try await f.perform(.archive, [archived], in: "Inbox")
        let mail = try await arrival(f, subject: "Read receipt")
        _ = await f.actions.handleArrivals([mail])
        let sent = await f.eventually { f.gmailLabels(mail.ref) == [.inbox] }
        XCTAssertTrue(sent)
        XCTAssertEqual(f.gmailLabels(archived), [.inbox, .unread], "the archive still waits in its window")
    }

    // MARK: - What each action becomes

    func testEachRuleActionInLabels() async throws {
        let f = try await fixture()
        try await f.rules.save([
            rule("Read", "read-me", [RuleAction(kind: .markRead)]),
            rule("Flag", "flag-me", [RuleAction(kind: .flag)]),
            rule("Delete", "delete-me", [RuleAction(kind: .delete)]),
            rule("Archive", "archive-me", [RuleAction(kind: .archive)]),
            rule("Copy", "copy-me", [RuleAction(kind: .copyToFolder, value: "Projects")]),
            rule("Move", "move-me", [RuleAction(kind: .moveToFolder, value: "Clients")])
        ])
        let read = try await arrival(f, subject: "read-me")
        let flag = try await arrival(f, subject: "flag-me")
        let delete = try await arrival(f, subject: "delete-me")
        let archive = try await arrival(f, subject: "archive-me")
        let copy = try await arrival(f, subject: "copy-me")
        let move = try await arrival(f, subject: "move-me")
        let outcome = await f.actions.handleArrivals([read, flag, delete, archive, copy, move])
        XCTAssertEqual(outcome.ruled.count, 6)
        XCTAssertEqual(outcome.filedAway, [delete.ref.id, archive.ref.id, move.ref.id])
        _ = await f.flush()
        XCTAssertEqual(f.gmailLabels(read.ref), [.inbox])
        XCTAssertEqual(f.gmailLabels(flag.ref), [.inbox, .unread, .starred])
        XCTAssertEqual(f.gmailLabels(delete.ref), [.inbox, .unread, .trash])
        XCTAssertEqual(f.gmailLabels(archive.ref), [.unread])
        XCTAssertEqual(f.gmailLabels(copy.ref), [.inbox, .unread, f.label("Projects")])
        XCTAssertEqual(f.gmailLabels(move.ref), [.unread, f.label("Clients")])
    }

    func testSeveralActionsBecomeOneChangeAndFilingAwayEndsThem() async throws {
        let f = try await fixture()
        try await f.rules.save([
            rule("Supplier", on: .from, "supplier", [RuleAction(kind: .markRead), RuleAction(kind: .flag),
                                                  RuleAction(kind: .moveToFolder, value: "Clients"),
                                                  RuleAction(kind: .copyToFolder, value: "Projects")])
        ])
        let mail = try await arrival(f, subject: "Stock", from: "Supplier <supplier@example.com>")
        _ = await f.actions.handleArrivals([mail])
        _ = await f.flush()
        XCTAssertEqual(f.gmailLabels(mail.ref), [.starred, f.label("Clients")], "the copy after the move does not run, as in v1.10.0")
        XCTAssertEqual(f.gmail.calls[.messagesModify], 1, "one call for every action on the message")
    }

    func testStopProcessingEndsTheRules() async throws {
        let f = try await fixture()
        try await f.rules.save([
            rule("First", "urgent", [RuleAction(kind: .flag), RuleAction(kind: .stopProcessing)]),
            rule("Second", "urgent", [RuleAction(kind: .markRead)])
        ])
        let mail = try await arrival(f, subject: "urgent")
        _ = await f.actions.handleArrivals([mail])
        _ = await f.flush()
        XCTAssertEqual(f.gmailLabels(mail.ref), [.inbox, .unread, .starred])
    }

    func testABodyConditionUsesTheFetchedText() async throws {
        let f = try await fixture()
        try await f.rules.save([rule("Tracking", on: .body, "tracking number", [RuleAction(kind: .flag)])])
        let hit = try await arrival(f, subject: "Shipped", body: "Your tracking number is 12")
        let miss = try await arrival(f, subject: "Shipped", body: "On its way")
        _ = await f.actions.handleArrivals([hit, miss])
        _ = await f.flush()
        XCTAssertEqual(f.gmailLabels(hit.ref), [.inbox, .unread, .starred])
        XCTAssertEqual(f.gmailLabels(miss.ref), [.inbox, .unread])
        XCTAssertNil(f.gmail.calls[.messagesGet], "the text came with the fetch of new mail")
    }

    func testFoldersARuleNamesByTheirIMAPPaths() async throws {
        let f = try await fixture()
        try await f.rules.save([
            rule("Trash", "to-trash", [RuleAction(kind: .moveToFolder, value: "[Gmail]/Trash")]),
            rule("Spam", "to-spam", [RuleAction(kind: .moveToFolder, value: "[Gmail]/Spam")]),
            rule("All Mail", "to-all", [RuleAction(kind: .moveToFolder, value: "[Gmail]/All Mail")]),
            rule("Starred", "to-starred", [RuleAction(kind: .moveToFolder, value: "[Google Mail]/Starred")]),
            rule("Case", "to-clients", [RuleAction(kind: .moveToFolder, value: "clients")])
        ])
        let trash = try await arrival(f, subject: "to-trash")
        let spam = try await arrival(f, subject: "to-spam")
        let all = try await arrival(f, subject: "to-all")
        let starred = try await arrival(f, subject: "to-starred")
        let clients = try await arrival(f, subject: "to-clients")
        _ = await f.actions.handleArrivals([trash, spam, all, starred, clients])
        _ = await f.flush()
        XCTAssertEqual(f.gmailLabels(trash.ref), [.inbox, .unread, .trash])
        XCTAssertEqual(f.gmailLabels(spam.ref), [.unread, .spam])
        XCTAssertEqual(f.gmailLabels(all.ref), [.unread])
        XCTAssertEqual(f.gmailLabels(starred.ref), [.inbox, .unread, .starred])
        XCTAssertEqual(f.gmailLabels(clients.ref), [.unread, f.label("Clients")])
    }

    func testAFolderNoLabelMatchesSkipsOnlyThatAction() async throws {
        let f = try await fixture()
        try await f.rules.save([
            rule("Old", "report", [RuleAction(kind: .moveToFolder, value: "Reports/2019"), RuleAction(kind: .flag)]),
            rule("Sent", "report", [RuleAction(kind: .moveToFolder, value: "[Gmail]/Sent Mail")])
        ])
        let mail = try await arrival(f, subject: "report")
        _ = await f.actions.handleArrivals([mail])
        _ = await f.flush()
        XCTAssertEqual(f.gmailLabels(mail.ref), [.inbox, .unread, .starred])
        XCTAssertEqual(f.host.notices, [
            "A rule names the folder “Reports/2019”, which this Gmail account doesn't have, so that part of the rule was skipped.",
            "A rule puts mail in “Sent”, which Gmail doesn't let apps do, so that part of the rule was skipped."
        ])
    }

    func testRulesOfAnotherAccountAreLeftAlone() async throws {
        let f = try await fixture()
        try await f.rules.save([RuleDefinition(name: "Elsewhere", accountID: UUID(),
                                               conditions: [RuleCondition(field: .subject, op: .contains, value: "x")],
                                               actions: [RuleAction(kind: .flag)])])
        let mail = try await arrival(f, subject: "x")
        let outcome = await f.actions.handleArrivals([mail])
        XCTAssertTrue(outcome.ruled.isEmpty)
    }

    func testRunRulesNowCoversTheInboxKeptOnTheMac() async throws {
        let f = try await fixture()
        try await f.rules.save([rule("Old invoices", "invoice", [RuleAction(kind: .archive)])])
        let kept = try await f.add("Invoice from last month", date: f.clock.now.addingTimeInterval(-30 * 86_400))
        let notKept = try await f.add("Invoice never opened")
        let archived = try await f.add("Invoice archived", labels: [.unread])
        for ref in [kept, archived] {
            let message = GmailCachedMessage(id: ref.id, threadID: ref.threadID, from: EmailAddress(name: "Ana", address: "ana@example.com"),
                                             subject: ref == kept ? "Invoice from last month" : "Invoice archived", preview: "Hello",
                                             date: f.clock.now.addingTimeInterval(-30 * 86_400), size: 10, hasAttachments: false,
                                             messageID: "<\(ref.id.hex)@x>", cachedAt: f.clock.now)
            try await f.store.cache(message, body: GmailReducedBody(textPlain: "Hello", textHTML: nil))
        }
        let changed = try await f.actions.runRulesOnInbox()
        XCTAssertEqual(changed, 1)
        _ = await f.flush()
        XCTAssertEqual(f.gmailLabels(kept), [.unread], "a month old, and still ruled on when the owner asks")
        XCTAssertEqual(f.gmailLabels(notKept), [.inbox, .unread], "only the messages kept on the Mac")
        XCTAssertEqual(f.gmailLabels(archived), [.unread])
    }

    func testAnArrivalReadFromAFullMessage() async throws {
        let gmail = FakeGmail()
        let ref = gmail.add(subject: "Order 7", from: "Shop <shop@example.com>", cc: "Ben <ben@example.com>", text: "Tracking 123",
                            labels: [.inbox, .unread, .categoryUpdates], messageID: "<order-7@shop.example.com>")
        let full = try await gmail.message(ref.id, format: .full, work: .checks)
        let arrival = try XCTUnwrap(GmailArrival(message: full))
        XCTAssertEqual(arrival.ref, ref)
        XCTAssertEqual(arrival.labels, [.inbox, .unread, .categoryUpdates])
        XCTAssertEqual(arrival.from.address, "shop@example.com")
        XCTAssertEqual(arrival.cc.map(\.address), ["ben@example.com"])
        XCTAssertEqual(arrival.subject, "Order 7")
        XCTAssertEqual(arrival.messageID, "<order-7@shop.example.com>")
        XCTAssertEqual(arrival.bodyText.trimmingCharacters(in: .whitespacesAndNewlines), "Tracking 123")
    }

    // MARK: - Mutes

    func testNewMailOfAMutedConversationIsFiledAndNotAnnounced() async throws {
        let f = try await fixture()
        try await f.rules.save([rule("Flag all", "Re:", [RuleAction(kind: .flag)])])
        let first = try await f.add("Plans", labels: [.inbox])
        _ = try await f.actions.perform(MailActionRequest(verb: .mute, targets: .items([.conversation(f.key(first))]),
                                                          context: f.view("Inbox")))
        _ = await f.flush()
        let reply = try await arrival(f, subject: "Re: Plans", thread: first.threadID, messageID: "<reply-1@example.com>")
        let outcome = await f.actions.handleArrivals([reply])
        XCTAssertEqual(outcome.muted, [reply.ref.id])
        XCTAssertTrue(outcome.ruled.isEmpty, "muted mail runs no rules")
        _ = await f.flush()
        XCTAssertEqual(f.gmailLabels(reply.ref), [])
        let record = await f.mutes.all().first
        XCTAssertTrue(record?.messageIDs.contains("<reply-1@example.com>") ?? false, "remembered, for replies Gmail threads apart")
    }

    func testAReplyInANewGmailThreadIsCaughtByItsReferences() async throws {
        let f = try await fixture()
        let first = try await f.add("Plans", labels: [.inbox], messageID: "<plans-root@example.com>")
        try await f.store.cache(GmailCachedMessage(id: first.id, threadID: first.threadID, from: EmailAddress(address: "ana@example.com"),
                                                   subject: "Plans", preview: "", date: f.clock.now, size: 1, hasAttachments: false,
                                                   messageID: "<plans-root@example.com>", cachedAt: f.clock.now), body: nil)
        _ = try await f.actions.perform(MailActionRequest(verb: .mute, targets: .items([.conversation(f.key(first))]),
                                                          context: f.view("Inbox")))
        var reply = try await arrival(f, subject: "Re: Plans (changed subject)", messageID: "<new-thread@example.com>")
        reply.references = ["<plans-root@example.com>"]
        let outcome = await f.actions.handleArrivals([reply])
        XCTAssertEqual(outcome.muted, [reply.ref.id])
        let muted = await f.mutes.all()
        XCTAssertEqual(muted.count, 1)
        XCTAssertEqual(muted[0].subject, "Plans")
    }

    func testMuteRecordsAConversationTheMacKeepsNothingOf() async throws {
        let f = try await fixture()
        let first = try await f.add("Quarterly numbers", labels: [.inbox], messageID: "<q3@example.com>")
        _ = try await f.actions.perform(MailActionRequest(verb: .mute, targets: .items([.conversation(f.key(first))]),
                                                          context: f.view("Inbox")))
        let filled = await f.eventually { await f.mutes.all().first?.subject == "Quarterly numbers" }
        XCTAssertTrue(filled)
        let record = await f.mutes.all().first
        XCTAssertEqual(record?.messageIDs, ["<q3@example.com>"])
        XCTAssertEqual(record?.threadKey, first.threadID.threadKey)
    }

    func testMutingAConversationAlreadyFiledIsUndoneByItsRecordAlone() async throws {
        let f = try await fixture()
        let first = try await f.add("Filed", labels: [])
        let receipt = try await f.actions.perform(MailActionRequest(verb: .mute, targets: .items([.conversation(f.key(first))]),
                                                                    context: f.view("Archive")))
        XCTAssertEqual(receipt.messageCount, 0)
        XCTAssertTrue(receipt.isUndoable)
        var muted = await f.mutes.all()
        XCTAssertEqual(muted.count, 1)
        let undone = await f.actions.undo(receipt.id)
        XCTAssertTrue(undone)
        muted = await f.mutes.all()
        XCTAssertTrue(muted.isEmpty)
    }

    func testUnmuteLeavesNoTwin() async throws {
        let f = try await fixture()
        let first = try await f.add("Supplier call", labels: [], messageID: "<call-1@example.com>")
        let second = try await f.add("Re: Supplier call", labels: [], thread: first.threadID, messageID: "<call-2@example.com>")
        try await f.store.cache(GmailCachedMessage(id: second.id, threadID: second.threadID, from: EmailAddress(address: "ana@example.com"),
                                                   subject: "Re: Supplier call", preview: "", date: f.clock.now, size: 1,
                                                   hasAttachments: false, messageID: "<call-2@example.com>", cachedAt: f.clock.now), body: nil)
        // v1.10.0 muted it over IMAP under its own thread key; the Gmail engine muted it again.
        await f.mutes.mute(MutedThread(accountID: f.accountID, threadKey: "<call-1@example.com>",
                                       messageIDs: ["<call-1@example.com>", "<call-2@example.com>"],
                                       normalizedSubject: "supplier call", subject: "Supplier call"))
        await f.mutes.mute(MutedThread(accountID: f.accountID, threadKey: first.threadID.threadKey, messageIDs: [],
                                       normalizedSubject: "supplier call", subject: "Supplier call"))
        let other = MutedThread(accountID: f.accountID, threadKey: "<unrelated@example.com>", messageIDs: ["<unrelated@example.com>"],
                                normalizedSubject: "lunch", subject: "Lunch")
        await f.mutes.mute(other)
        let receipt = try await f.actions.perform(MailActionRequest(verb: .unmute, targets: .items([.conversation(f.key(first))]),
                                                                    context: f.view("Archive")))
        XCTAssertEqual(receipt.messageCount, 1)
        let left = await f.mutes.all()
        XCTAssertEqual(left.map(\.threadKey), [other.threadKey], "both records of the conversation went; nothing else did")
        let reply = try await arrival(f, subject: "Re: Supplier call", thread: first.threadID, messageID: "<call-3@example.com>")
        let outcome = await f.actions.handleArrivals([reply])
        XCTAssertTrue(outcome.muted.isEmpty, "its new mail shows again")
    }

    func testUnmuteFindsATwinByMessageIDWhenNothingIsKept() async throws {
        let f = try await fixture()
        let first = try await f.add("Tender", labels: [], messageID: "<tender@example.com>")
        await f.mutes.mute(MutedThread(accountID: f.accountID, threadKey: "<tender@example.com>", messageIDs: ["<tender@example.com>"],
                                       normalizedSubject: "tender", subject: "Tender"))
        _ = try await f.actions.perform(MailActionRequest(verb: .unmute, targets: .items([.message(f.key(first))]),
                                                          context: f.view("Archive")))
        let left = await f.mutes.all()
        XCTAssertTrue(left.isEmpty)
    }
}
