import XCTest
@testable import FalconCore

/// Moving a Google account from v1.10's IMAP engine to the Gmail engine and back (§12): the IMAP
/// actions still waiting go first, the owner's categories are re-keyed by Message-ID only when one
/// message agrees, switching off sends Gmail's waiting changes first, v1.10.3's files still load
/// after going back and forward, and the IMAP store is never touched.
final class GmailMigrationTests: XCTestCase {
    private var rigs: [CoordinatorRig] = []

    override func tearDown() async throws {
        for rig in rigs { await rig.finish() }
        rigs = []
    }

    private func rig(switches: MemoryGmailEngineSwitchStore = MemoryGmailEngineSwitchStore(), root: URL? = nil) throws -> CoordinatorRig {
        let made = try CoordinatorRig(root: root, switches: switches)
        rigs.append(made)
        return made
    }

    // MARK: - The switch

    func testEveryGoogleAccountSignedInWithGoogleIsOnTheGmailAPIUnlessTurnedOff() {
        let google = AccountInfo(email: "a@gmail.com", displayName: "A", authMethod: "oauth")
        let workspace = AccountInfo(email: "b@freight.example", displayName: "B", authMethod: nil)
        let appPassword = AccountInfo.custom(email: "c@gmail.com", displayName: "C", imapHost: "imap.gmail.com", imapPort: 993,
                                             smtpHost: "smtp.gmail.com", smtpPort: 465, username: "c@gmail.com")
        let other = AccountInfo.custom(email: "d@example.org", displayName: "D", imapHost: "imap.example.org", imapPort: 993,
                                       smtpHost: "smtp.example.org", smtpPort: 465, username: "d")
        let switches = MemoryGmailEngineSwitchStore()
        XCTAssertTrue(GmailEngineSwitch.isOn(google, in: switches), "on by default")
        XCTAssertTrue(GmailEngineSwitch.isOn(workspace, in: switches), "a Workspace account too")
        XCTAssertFalse(GmailEngineSwitch.isOn(appPassword, in: switches), "an app password has no Gmail API token")
        XCTAssertTrue(GmailEngineSwitch.usesGoogleIMAP(appPassword))
        XCTAssertEqual(GmailEngineSwitch.googleIMAPNotice(appPassword), "c@gmail.com uses Gmail through IMAP. Sign in with Google to use the Gmail API.")
        XCTAssertFalse(GmailEngineSwitch.isOn(other, in: switches))
        XCTAssertFalse(GmailEngineSwitch.usesGoogleIMAP(other))
        switches.setChoice(false, for: google.id)
        XCTAssertFalse(GmailEngineSwitch.isOn(google, in: switches), "the owner's fallback")
    }

    func testTheSwitchIsKeptInThePreferencesUnderTheAccount() throws {
        let suite = "com.falconmail.tests.switch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DefaultsGmailEngineSwitchStore(defaults: defaults)
        let id = UUID()
        XCTAssertNil(store.choice(for: id))
        store.setChoice(false, for: id)
        XCTAssertEqual(defaults.object(forKey: "gmailEngine.\(id.uuidString)") as? Bool, false)
        XCTAssertEqual(store.choice(for: id), false)
    }

    func testAGoogleAccountWithNoWaitingIMAPActionsMovesAtOnceWithoutAnyIMAPConnection() async throws {
        let rig = try rig()
        let account = rig.googleAccount()
        rig.gmail(for: account).add(subject: "Hello")
        let before = try rig.writePreviousRelease(account)
        let digest = rig.imapStoreDigest(account)
        try await rig.launch()
        try await rig.backfilled(account)
        let routed = await rig.coordinator.usesGmail(account.id)
        XCTAssertTrue(routed)
        let syncer = await rig.coordinator.syncer(for: account.id)
        XCTAssertNil(syncer, "never an AccountSyncer")
        XCTAssertTrue(rig.connector.calls.isEmpty)
        XCTAssertEqual(rig.imap.loginCount, 0)
        let record = GmailMigrationFile(files: GmailFiles(layout: rig.layout, accountID: account.id)).load()
        XCTAssertNotNil(record.switchedAt)
        XCTAssertEqual(record.spotlightCleared, true)
        // The folders keep v1.10's ids by role, so rules, move targets and the selection survive.
        let inbox = try await rig.folder(.inbox, of: account)
        XCTAssertEqual(inbox.id, before.inbox.id)
        let sealed = await rig.store.isSealed(account.id)
        XCTAssertTrue(sealed, "the IMAP store is left as it is")
        await rig.quit()
        XCTAssertEqual(rig.imapStoreDigest(account), digest, "nothing outside Gmail/ changed")
    }

    func testWaitingIMAPActionsAreSentBeforeTheSwitchAsTheAccountsLastUseOfIMAP() async throws {
        let rig = try rig()
        let account = rig.googleAccount()
        rig.gmail(for: account).add(subject: "Hello")
        let previous = try rig.writePreviousRelease(account)
        let uid = rig.imap.add(Data("Subject: Waiting\r\nMessage-ID: <w@x>\r\n\r\nbody".utf8), to: "INBOX")
        // v1.10 marked a message read and quit before the server had it.
        await rig.pending.add(PendingServerOperation(accountID: account.id, folderID: previous.inbox.id, verb: .store, uids: [uid],
                                                     uidValidity: rig.imap.uidValidity(of: "INBOX"), flagNames: ["\\Seen"]))
        try await rig.launch()
        try await rig.backfilled(account)
        XCTAssertEqual(rig.connector.calls, [account.email], "one IMAP connection, to send what waited")
        XCTAssertTrue(rig.imap.commands.contains { $0.contains("STORE") && $0.contains("\\Seen") }, "the waiting action reached the server")
        let left = await rig.pending.all()
        XCTAssertTrue(left.isEmpty)
        let routed = await rig.coordinator.usesGmail(account.id)
        XCTAssertTrue(routed, "then the account moved")
        let logins = rig.imap.loginCount
        let assembly = try await rig.assembly(account)
        _ = await assembly.engine.check(reason: .sendAndReceive)
        XCTAssertEqual(rig.imap.loginCount, logins, "and never used IMAP again")
    }

    func testAnAccountWhoseIMAPActionsCannotBeSentStaysOnIMAPUntilTheyHaveGone() async throws {
        let rig = try rig()
        let account = rig.googleAccount()
        rig.gmail(for: account).add(subject: "Hello")
        let previous = try rig.writePreviousRelease(account)
        let uid = rig.imap.add(Data("Subject: Waiting\r\n\r\nbody".utf8), to: "INBOX")
        let action = PendingServerOperation(accountID: account.id, folderID: previous.inbox.id, verb: .store, uids: [uid],
                                            uidValidity: rig.imap.uidValidity(of: "INBOX"), flagNames: ["\\Flagged"])
        await rig.pending.add(action)
        rig.connector.refuses = true
        try await rig.launch()
        let routed = await rig.coordinator.usesGmail(account.id)
        XCTAssertFalse(routed, "not switched while its IMAP actions wait")
        let roster = await rig.coordinator.roster
        XCTAssertEqual(roster.notices[account.id], "\(account.email) has changes waiting to reach Gmail. It will switch once they have gone.")
        XCTAssertNil(roster.running[account.id])
        let record = GmailMigrationFile(files: GmailFiles(layout: rig.layout, accountID: account.id)).load()
        XCTAssertNil(record.switchedAt)
        let still = await rig.pending.all()
        XCTAssertEqual(still.map(\.id), [action.id], "nothing the owner did is dropped")
        // Back online, the IMAP engine sends it, and the account then moves.
        rig.connector.refuses = false
        await rig.coordinator.networkChanged()
        try await eventually(timeout: 20, "the account switches") { await rig.coordinator.usesGmail(account.id) }
        let sent = await rig.pending.all()
        XCTAssertTrue(sent.isEmpty)
    }

    func testTurningTheSwitchOffSendsWaitingGmailChangesFirstAndKeepsTheGmailFiles() async throws {
        let rig = try rig()
        let account = rig.googleAccount()
        let gmail = rig.gmail(for: account)
        let message = gmail.add(subject: "Archive me")
        try rig.writePreviousRelease(account)
        try await rig.launch(undoWindow: 60)
        try await rig.backfilled(account)
        let inbox = try await rig.folder(.inbox, of: account)
        let key = RowKey.gmail(account: account.id, id: message.id)
        let receipt = try await rig.coordinator.perform(MailActionRequest(verb: .archive, targets: .items([.message(key)]),
                                                                          context: ListView(scope: .folder(inbox.id))), accountID: account.id)
        XCTAssertNotNil(receipt.heldUntil, "held for its undo window")
        XCTAssertEqual(gmail.message(message.id)?.labels.contains(.inbox), true, "not sent yet")
        let files = GmailFiles(layout: rig.layout, accountID: account.id)
        let refused = await rig.coordinator.setGmailEngine(false, for: account)
        XCTAssertNil(refused)
        XCTAssertEqual(gmail.message(message.id)?.labels.contains(.inbox), false, "Gmail had the archive before IMAP came back")
        let routed = await rig.coordinator.usesGmail(account.id)
        XCTAssertFalse(routed)
        XCTAssertEqual(rig.switches.choice(for: account.id), false)
        try await eventually(timeout: 20, "IMAP connects again") { rig.imap.loginCount > 0 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.indexSnapshot.path)
                      || FileManager.default.fileExists(atPath: files.indexJournal.path), "Gmail/ is kept for the next time")
        let record = GmailMigrationFile(files: files).load()
        XCTAssertNil(record.switchedAt)
        XCTAssertNotNil(record.switchedOffAt)
        let sealed = await rig.store.isSealed(account.id)
        XCTAssertFalse(sealed)
        XCTAssertFalse(TransportGuard.shared.blocks(user: account.email))
    }

    func testTheSwitchStaysOnWhileWaitingChangesCannotReachGmail() async throws {
        let rig = try rig()
        let account = rig.googleAccount()
        let gmail = rig.gmail(for: account)
        let message = gmail.add(subject: "Archive me")
        try rig.writePreviousRelease(account)
        try await rig.launch(undoWindow: 60)
        try await rig.backfilled(account)
        let inbox = try await rig.folder(.inbox, of: account)
        gmail.failAlways(.messagesModify, with: GoogleAPIError(kind: .offline))
        _ = try await rig.coordinator.perform(MailActionRequest(verb: .archive, targets: .items([.message(.gmail(account: account.id, id: message.id))]),
                                                                context: ListView(scope: .folder(inbox.id))), accountID: account.id)
        let refused = await rig.coordinator.setGmailEngine(false, for: account)
        XCTAssertEqual(refused, "\(account.email) has changes waiting to reach Gmail. Try again when you're online.")
        let routed = await rig.coordinator.usesGmail(account.id)
        XCTAssertTrue(routed, "still on the Gmail API")
        XCTAssertNotEqual(rig.switches.choice(for: account.id), false)
        XCTAssertEqual(rig.imap.loginCount, 0, "IMAP never came back to undo the archive")
        gmail.failAlways(.messagesModify, with: nil)
    }

    // MARK: - Re-keying by Message-ID

    func testCategoriesAreReKeyedOnlyWhereOneGmailMessageAgreesAndOldKeysStay() async throws {
        let rig = try rig()
        let account = rig.googleAccount()
        let gmail = rig.gmail(for: account)
        let rows = [
            PreviousRelease.Row(uid: 1, messageID: "invoice-7@supplier.example", subject: "Invoice 7", date: Date(timeIntervalSince1970: 1_789_000_000)),
            PreviousRelease.Row(uid: 2, messageID: "weekly@news.example", subject: "Weekly news", date: Date(timeIntervalSince1970: 1_789_100_000)),
            PreviousRelease.Row(uid: 3, messageID: "", subject: "No id", date: Date(timeIntervalSince1970: 1_789_200_000)),
            PreviousRelease.Row(uid: 4, messageID: "gone@nowhere.example", subject: "Gone", date: Date(timeIntervalSince1970: 1_789_300_000)),
            PreviousRelease.Row(uid: 5, messageID: "x", subject: "Broken id", date: Date(timeIntervalSince1970: 1_789_400_000))
        ]
        let previous = try rig.writePreviousRelease(account, inbox: rows)
        // A sender reused the invoice's Message-ID a year later for another message: only the one
        // whose subject agrees is it.
        let invoice = gmail.add(subject: "Invoice 7", date: rows[0].date, messageID: "<invoice-7@supplier.example>")
        gmail.add(subject: "Something else", date: rows[0].date.addingTimeInterval(365 * 86_400), messageID: "<invoice-7@supplier.example>")
        // Two copies of the newsletter agree: nothing is guessed.
        gmail.add(subject: "Weekly news", date: rows[1].date, messageID: "<weekly@news.example>")
        gmail.add(subject: "Weekly news", date: rows[1].date, messageID: "<weekly@news.example>")
        let assignments = [
            previous.key(uid: 1): ["Manager"], previous.key(uid: 2): ["Travel"], previous.key(uid: 3): ["Team"],
            previous.key(uid: 4): ["Family"], previous.key(uid: 5): ["Friends"],
            "\(UUID().uuidString):\(UUID().uuidString):9": ["Other account"]
        ]
        let rekeyer = GmailCategoryRekeyer(accountID: account.id, reader: LegacyStoreReader(layout: rig.layout, accountID: account.id),
                                           matcher: GmailMessageMatcher(accountID: account.id, transport: gmail))
        XCTAssertEqual(Set(rekeyer.keysToRekey(in: assignments, done: [])), Set((1...5).map { previous.key(uid: UInt32($0)) }))
        let result = await rekeyer.rekey(assignments, done: [])
        let newKey = RowKey.gmail(account: account.id, id: invoice.id).stringValue
        XCTAssertEqual(result.added, [newKey: ["Manager"]])
        XCTAssertEqual(Set(result.legacy), Set([2, 3, 4, 5].map { previous.key(uid: UInt32($0)) }))
        XCTAssertEqual(Set(result.done), Set((1...5).map { previous.key(uid: UInt32($0)) }))
        XCTAssertFalse(result.interrupted)
        let merged = GmailCategoryRekeyer.merged(assignments, with: result)
        for (key, names) in assignments { XCTAssertEqual(merged[key], names, "old keys stay for going back") }
        XCTAssertEqual(merged[newKey], ["Manager"])
        XCTAssertEqual(rekeyer.keysToRekey(in: merged, done: Set(result.done)), [], "each old key is looked at once")
    }

    func testReKeyingThatCannotReachGmailStopsAndCarriesOnLater() async throws {
        let rig = try rig()
        let account = rig.googleAccount()
        let gmail = rig.gmail(for: account)
        let previous = try rig.writePreviousRelease(account)
        gmail.failAlways(.messagesList, with: GoogleAPIError(kind: .offline))
        let rekeyer = GmailCategoryRekeyer(accountID: account.id, reader: LegacyStoreReader(layout: rig.layout, accountID: account.id),
                                           matcher: GmailMessageMatcher(accountID: account.id, transport: gmail,
                                                                        work: .interactive))
        let result = await rekeyer.rekey([previous.key(uid: 101): ["Manager"]], done: [])
        XCTAssertTrue(result.interrupted)
        XCTAssertTrue(result.done.isEmpty, "tried again later rather than taken for no match")
        XCTAssertTrue(result.legacy.isEmpty)
        gmail.failAlways(.messagesList, with: nil)
    }

    func testTheIMAPStoreIsReadWithoutBeingWritten() throws {
        let rig = try rig()
        let account = rig.googleAccount()
        let previous = try rig.writePreviousRelease(account)
        let digest = rig.imapStoreDigest(account)
        let reader = LegacyStoreReader(layout: rig.layout, accountID: account.id)
        XCTAssertEqual(reader.folders().map(\.id), previous.folders.map(\.id))
        let flagged = try XCTUnwrap(reader.message(id: previous.key(uid: 101)))
        XCTAssertTrue(flagged.isFlagged, "the journal's flag change is applied")
        XCTAssertEqual(flagged.messageID, "invoice-7@supplier.example")
        XCTAssertNotNil(reader.message(id: previous.key(uid: 103)), "a row only the journal holds")
        XCTAssertNil(reader.message(id: "\(UUID().uuidString):\(previous.inbox.id.uuidString):101"), "another account's key")
        XCTAssertEqual(rig.imapStoreDigest(account), digest)
    }

    // MARK: - The session

    func testTheSessionKeepsGmailRowsOutOfWhatAnEarlierFalconMailReadsAndCarriesItsEntriesForward() {
        let switched = UUID()
        let other = UUID()
        let gmailRow = RowKey.gmail(account: switched, id: GmailMessageID(raw: 0x1a2b)).stringValue
        let oldRow = "\(switched.uuidString):\(UUID().uuidString):7"
        let otherRow = "\(other.uuidString):\(UUID().uuidString):9"
        let split = SessionCarryForward.split([gmailRow, "child:" + gmailRow, otherRow])
        XCTAssertEqual(split.earlier, [otherRow])
        XCTAssertEqual(split.gmail, [gmailRow, "child:" + gmailRow])
        XCTAssertEqual(SessionCarryForward.carried([oldRow, otherRow, gmailRow], engineAccounts: [switched]), [oldRow])
        XCTAssertEqual(SessionCarryForward.earlierList([gmailRow, otherRow], previous: [oldRow, otherRow], engineAccounts: [switched]),
                       [otherRow, oldRow], "the window v1.10 had open for the account comes back after going back")
    }

    // MARK: - v1.10.3's files, going back and forward

    func testV1103FilesLoadAfterUpgradeAfterGoingBackAndAfterUpgradingAgain() async throws {
        let rig = try rig()
        let account = rig.googleAccount()
        let gmail = rig.gmail(for: account)
        for i in 0..<30 { gmail.add(subject: "Message \(i)", date: Date(timeIntervalSince1970: 1_789_000_000 + Double(i) * 3_600)) }
        try rig.writePreviousRelease(account)
        let layout = rig.layout
        // v1.10.3's other files: a mute, a held Outbox item.
        let mute = PreviousRelease.MutedThread(accountID: account.id, threadKey: "rates@carrier.example", messageIDs: ["rates@carrier.example"],
                                               normalizedSubject: "rates for october", subject: "Rates for October",
                                               mutedAt: Date(timeIntervalSince1970: 1_789_500_000))
        try PreviousRelease.encoder().encode([mute]).write(to: layout.mutedFile, options: .atomic)
        let itemID = UUID()
        let held = PreviousRelease.OutboxItem(id: itemID, accountID: account.id, subject: "Quote", recipients: ["ben@example.com"],
                                              sender: account.email, sendAt: Date(timeIntervalSince1970: 1_789_600_000),
                                              createdAt: Date(timeIntervalSince1970: 1_789_600_000), status: .failed,
                                              error: "FalconMail stopped while this was being sent", undoUntil: Date(timeIntervalSince1970: 1_789_600_010),
                                              attempts: 1, heldBack: true, sendBegan: nil)
        try FileManager.default.createDirectory(at: layout.outboxDirectory, withIntermediateDirectories: true)
        try PreviousRelease.encoder().encode(held).write(to: layout.outboxDirectory.appendingPathComponent("\(itemID.uuidString).json"),
                                                         options: .atomic)
        try Data("Subject: Quote\r\n\r\nbody".utf8).write(to: layout.outboxDirectory.appendingPathComponent("\(itemID.uuidString).eml"))
        let digest = rig.imapStoreDigest(account)

        // 1. Upgrade: this build reads every file, and the account moves to the Gmail API.
        try await rig.launch()
        try await rig.backfilled(account)
        let accounts = await rig.store.allAccounts()
        XCTAssertEqual(accounts.map(\.id), [account.id])
        let mutes = await rig.mutes.all()
        XCTAssertEqual(mutes.map(\.threadKey), ["rates@carrier.example"])
        let items = await rig.outbox.snapshot()
        XCTAssertEqual(items.first { $0.id == itemID }?.isHeld, true, "the held send stays held")
        let listed = gmail.calls[.messagesList] ?? 0
        await rig.quit()
        XCTAssertEqual(rig.imapStoreDigest(account), digest, "the IMAP store is as v1.10.3 left it")

        // 2. Going back: v1.10.3 reads every file it knows, as it decodes them.
        let decoder = PreviousRelease.decoder()
        let back = try decoder.decode([PreviousRelease.AccountInfo].self, from: Data(contentsOf: layout.accountsFile))
        XCTAssertEqual(back.map(\.id), [account.id])
        XCTAssertEqual(back.first?.provider, "google")
        XCTAssertEqual(back.first?.imapHost, account.imapHost, "the same hosts, for its IMAP engine")
        XCTAssertNoThrow(try decoder.decode([PreviousRelease.FolderInfo].self, from: Data(contentsOf: layout.foldersFile(account.id))))
        XCTAssertNoThrow(try decoder.decode([PreviousRelease.MutedThread].self, from: Data(contentsOf: layout.mutedFile)))
        for file in try FileManager.default.contentsOfDirectory(at: layout.outboxDirectory, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" && !file.lastPathComponent.contains(".draft.") {
            XCTAssertNoThrow(try decoder.decode(PreviousRelease.OutboxItem.self, from: Data(contentsOf: file)), file.lastPathComponent)
        }
        if let data = try? Data(contentsOf: layout.pendingActionsFile) {
            XCTAssertNoThrow(try decoder.decode([PreviousRelease.PendingServerOperation].self, from: data))
        }
        let store = layout.folderDirectory(accountID: account.id, folderID: LegacyStoreReader(layout: layout, accountID: account.id).folders()[0].id)
        let plist = try Data(contentsOf: store.appendingPathComponent("index.plist"))
        XCTAssertNoThrow(try PropertyListDecoder().decode([PreviousRelease.MessageSummary].self, from: plist))
        // v1.10.3 syncs the account over IMAP meanwhile, which the fake stands in for by leaving
        // its store as it was.

        // 3. Upgrading again: the account carries on from its Gmail files, without listing again.
        let again = try self.rig(switches: rig.switches, root: rig.root)
        again.gmail(for: account, mailbox: gmail.mailbox)
        try await again.launch()
        let assembly = try await again.assembly(account)
        let report = await assembly.engine.check(reason: .wake)
        XCTAssertNil(report.failure)
        let state = await assembly.engine.state
        XCTAssertEqual(state.backfill?.phase, .complete, "carried on from the index and cursor on disk")
        XCTAssertLessThanOrEqual((again.gmail(for: account).calls[.messagesList] ?? 0), listed + 2, "nothing listed again")
        let items2 = await again.outbox.snapshot()
        XCTAssertEqual(items2.first { $0.id == itemID }?.isHeld, true)
        await again.quit()
        XCTAssertEqual(again.imapStoreDigest(account), digest)
    }
}
