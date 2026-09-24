import XCTest
@testable import FalconCore

/// A stored file that cannot be decoded is moved aside whole and never written over, and
/// nothing is quietly emptied or made again in its place.
final class StoredFileTests: XCTestCase {
    private var root: URL!
    private var layout: FileLayout { FileLayout(root: root) }

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-stored-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Log.start(in: root)
        _ = StoredFileNotices.take()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func setAside(beside url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".unreadable-") }
    }

    private let garbage = Data("{\"this\": is not what was written".utf8)

    func testUndecodableFolderListIsSetAsideAndNothingIsRecreated() async throws {
        let server = try EngineHarness.gmailServer()
        server.add(FakeIMAPServer.message("one"), to: "INBOX")
        let first = try await EngineHarness(server: server, root: root)
        try await first.syncOnce()
        let inbox = try await first.folder("INBOX")
        await first.syncer.stop()
        let foldersFile = layout.foldersFile(first.account.id)
        let folderDirectory = layout.folderDirectory(accountID: first.account.id, folderID: inbox.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderDirectory.path))
        try garbage.write(to: foldersFile)
        await assertEventually { server.openConnections == 0 }
        server.resetCounters()

        let second = try await EngineHarness(server: server, root: root)
        let aside = try setAside(beside: foldersFile)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: aside[0]), garbage, "moved whole, not rewritten")
        let problem = await second.store.folderListProblem(second.account.id)
        XCTAssertEqual(problem?.fileName, aside.first?.lastPathComponent)
        XCTAssertTrue(StoredFileNotices.take().contains("the folder list for owner@example.com"))

        await second.syncer.start()
        await assertEventually { await second.events.healths.contains { if case .blocked = $0 { return true }; return false } }
        let shown = await second.events.errors.last ?? ""
        XCTAssertTrue(shown.contains("could not read the folder list for owner@example.com"), shown)
        do {
            _ = try await second.store.reconcileFolders(accountID: second.account.id, listed: [])
            XCTFail("a new folder list must not be written over the one set aside")
        } catch {}
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: foldersFile.path), "no new folders.json")
        XCTAssertTrue(server.commands.isEmpty, "the account is left alone: \(server.commands)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderDirectory.path), "the stored folder is not orphaned or removed")
        await second.finish()
    }

    func testUndecodablePendingActionsAreSetAsideNotEmptied() async throws {
        let file = layout.pendingActionsFile
        try garbage.write(to: file)
        let store = PendingActionStore(layout: layout)
        let loaded = await store.all()
        XCTAssertTrue(loaded.isEmpty)
        let aside = try setAside(beside: file)
        XCTAssertEqual(aside.count, 1)
        await store.add(PendingServerOperation(accountID: UUID(), folderID: UUID(), verb: .store, uids: [1]))
        XCTAssertEqual(try Data(contentsOf: aside[0]), garbage, "the new file never overwrites the one set aside")
        XCTAssertEqual(AtomicFile.readJSON([PendingServerOperation].self, from: file)?.count, 1)
    }

    func testUndecodableFolderIndexIsSetAsideAndItsMessagesAreFetchedAgain() async throws {
        let server = try EngineHarness.gmailServer()
        for n in 1...3 { server.add(FakeIMAPServer.message("m\(n)"), to: "INBOX") }
        let first = try await EngineHarness(server: server, root: root)
        try await first.syncOnce()
        let inbox = try await first.folder("INBOX")
        await first.store.flushAll()
        await first.syncer.stop()
        let index = layout.folderDirectory(accountID: first.account.id, folderID: inbox.id).appendingPathComponent("index.plist")
        try garbage.write(to: index)

        let second = try await EngineHarness(server: server, root: root)
        let reopened = try await second.folder("INBOX")
        let empty = try await second.uids(in: "INBOX")
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(try setAside(beside: index).count, 1)
        let reset = try await second.folder("INBOX")
        XCTAssertEqual(reset.lastSyncedUID, 0, "the next sync lists the folder again from the server")
        XCTAssertEqual(reopened.id, inbox.id)
        try await second.syncOnce()
        let refetched = try await second.uids(in: "INBOX")
        XCTAssertEqual(refetched, [1, 2, 3])
        await second.finish()
    }

    /// The index of a folder nobody has opened is first loaded by the sync pass itself.
    func testASetAsideIndexOfAFolderNotYetOpenedIsListedAgainByTheSync() async throws {
        let server = try EngineHarness.gmailServer()
        for n in 1...3 { server.add(FakeIMAPServer.message("sent-\(n)", from: "owner@example.com", to: "ana@example.com"), to: "[Gmail]/Sent Mail") }
        let first = try await EngineHarness(server: server, root: root)
        try await first.syncOnce()
        let sent = try await first.folder("[Gmail]/Sent Mail")
        await first.store.flushAll()
        await first.syncer.stop()
        let index = layout.folderDirectory(accountID: first.account.id, folderID: sent.id).appendingPathComponent("index.plist")
        try garbage.write(to: index)

        let second = try await EngineHarness(server: server, root: root)
        try await second.syncOnce()
        XCTAssertEqual(try setAside(beside: index).count, 1)
        let listed = try await second.uids(in: "[Gmail]/Sent Mail")
        XCTAssertEqual(listed, [1, 2, 3])
        let record = try await second.folder("[Gmail]/Sent Mail")
        XCTAssertEqual(record.lastSyncedUID, 3)
        XCTAssertEqual(record.oldestSyncedUID, 1)
        await second.finish()
    }

    func testTheSyncLoopListsAgainAFolderWhoseIndexWasSetAside() async throws {
        let server = try EngineHarness.gmailServer()
        for n in 1...3 { server.add(FakeIMAPServer.message("m\(n)"), to: "INBOX") }
        let first = try await EngineHarness(server: server, root: root)
        try await first.syncOnce()
        let inbox = try await first.folder("INBOX")
        await first.store.flushAll()
        await first.syncer.stop()
        let index = layout.folderDirectory(accountID: first.account.id, folderID: inbox.id).appendingPathComponent("index.plist")
        try garbage.write(to: index)
        server.add(FakeIMAPServer.message("m4"), to: "INBOX")

        let second = try await EngineHarness(server: server, root: root)
        await second.syncer.start()
        // Nothing here may load the folder's store before the pass does, as the list on screen
        // would: the pass has to find the reset by itself.
        await assertEventually { await second.events.all.contains { if case .finished = $0 { return true }; return false } }
        let listed = try await second.uids(in: "INBOX")
        XCTAssertEqual(listed, [1, 2, 3, 4])
        let record = try await second.folder("INBOX")
        XCTAssertEqual(record.oldestSyncedUID, 1)
        XCTAssertEqual(record.lastSyncedUID, 4)
        let announced = await second.events.all.contains { if case .newMessages = $0 { return true }; return false }
        XCTAssertFalse(announced, "mail listed again is not new mail")
        await second.finish()
    }

    func testCountingAFolderKeepsTheCursorsItsSetAsideIndexReset() async throws {
        let server = try EngineHarness.gmailServer()
        for n in 1...3 { server.add(FakeIMAPServer.message("m\(n)"), to: "INBOX") }
        let first = try await EngineHarness(server: server, root: root)
        try await first.syncOnce()
        let inbox = try await first.folder("INBOX")
        await first.store.flushAll()
        await first.syncer.stop()
        try garbage.write(to: layout.folderDirectory(accountID: first.account.id, folderID: inbox.id).appendingPathComponent("index.plist"))

        let store = MailStore(layout: layout)
        try await store.load()
        try await store.refreshCounts(folderID: inbox.id)
        let counted = await store.folder(inbox.id)
        XCTAssertEqual(counted?.lastSyncedUID, 0, "counting loaded the store; the reset it made must stay")
        XCTAssertEqual(counted?.oldestSyncedUID, 0)
        XCTAssertEqual(counted?.totalCount, 0)
        server.stop()
    }

    func testFilesSetAsideDuringAPassAreNotedBeforeItFinishes() async throws {
        let server = try EngineHarness.gmailServer()
        server.add(FakeIMAPServer.message("sent-1", from: "owner@example.com"), to: "[Gmail]/Sent Mail")
        let first = try await EngineHarness(server: server, root: root)
        try await first.syncOnce()
        let sent = try await first.folder("[Gmail]/Sent Mail")
        await first.store.flushAll()
        await first.syncer.stop()
        try garbage.write(to: layout.folderDirectory(accountID: first.account.id, folderID: sent.id).appendingPathComponent("index.plist"))
        try garbage.write(to: layout.pendingActionsFile)

        let second = try await EngineHarness(server: server, root: root)
        XCTAssertTrue(StoredFileNotices.take().isEmpty, "neither file has been read yet at launch")
        await second.syncer.start()
        await assertEventually { await second.events.all.contains { if case .finished = $0 { return true }; return false } }
        let noted = StoredFileNotices.take()
        XCTAssertTrue(noted.contains("the actions waiting to reach the server"), "\(noted)")
        XCTAssertTrue(noted.contains { $0.contains("[Gmail]/Sent Mail") }, "\(noted)")
        await second.finish()
    }

    func testAnAccountListSetAsideIsNeverReplacedByNewAccounts() async throws {
        let server = try EngineHarness.gmailServer()
        let first = try await EngineHarness(server: server, root: root)
        let accountDirectory = layout.accountDirectory(first.account.id)
        try await first.syncOnce()
        await first.syncer.stop()
        try garbage.write(to: layout.accountsFile)
        _ = StoredFileNotices.take()

        for launch in 1...2 {
            let store = MailStore(layout: layout)
            try await store.load()
            let accounts = await store.allAccounts()
            XCTAssertTrue(accounts.isEmpty)
            XCTAssertTrue(StoredFileNotices.take().contains("the account list"), "launch \(launch)")
            do {
                try await store.saveAccount(AccountInfo(email: "owner@example.com", displayName: "Owner"))
                XCTFail("launch \(launch): a new account would get a new id and orphan the old one's mail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("accounts.json.unreadable-"), error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: layout.accountsFile.path), "launch \(launch): no new accounts.json")
        }
        let aside = try setAside(beside: layout.accountsFile)
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: aside[0]), garbage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: accountDirectory.path), "the old account's mail is still there")
        server.stop()
    }

    func testAnAccountWhoseFolderListWasSetAsideStaysPausedAfterARelaunch() async throws {
        let server = try EngineHarness.gmailServer()
        server.add(FakeIMAPServer.message("one"), to: "INBOX")
        let first = try await EngineHarness(server: server, root: root)
        try await first.syncOnce()
        await first.syncer.stop()
        let foldersFile = layout.foldersFile(first.account.id)
        try garbage.write(to: foldersFile)
        let setAsideNow = try await EngineHarness(server: server, root: root)
        let problem = await setAsideNow.store.folderListProblem(setAsideNow.account.id)
        XCTAssertNotNil(problem)
        await setAsideNow.syncer.stop()
        await assertEventually { server.openConnections == 0 }
        server.resetCounters()
        _ = StoredFileNotices.take()

        let relaunched = try await EngineHarness(server: server, root: root)
        let stillThere = await relaunched.store.folderListProblem(relaunched.account.id)
        XCTAssertEqual(stillThere?.fileName, try setAside(beside: foldersFile).first?.lastPathComponent)
        XCTAssertTrue(StoredFileNotices.take().contains("the folder list for owner@example.com"))
        await relaunched.syncer.start()
        await assertEventually { await relaunched.events.healths.contains { if case .blocked = $0 { return true }; return false } }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(server.commands.isEmpty, "\(server.commands)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: foldersFile.path), "no new folder list")
        await relaunched.finish()
    }

    func testUnreadableAccountListIsLeftInPlaceAndNeverWrittenOver() async throws {
        let file = layout.accountsFile
        let original = Data("[]".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let store = MailStore(layout: layout)
        try await store.load()
        do {
            try await store.saveAccount(AccountInfo(email: "owner@example.com", displayName: "Owner"))
            XCTFail("an account list that could not be read must not be replaced")
        } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(try setAside(beside: file).isEmpty)
    }

    func testRulesAndMutesThatCannotBeDecodedAreKept() async throws {
        try garbage.write(to: layout.rulesFile)
        try garbage.write(to: layout.mutedFile)
        let rules = RuleStore(layout: layout)
        let mutes = MuteStore(layout: layout)
        let noRules = await rules.all()
        let noMutes = await mutes.all()
        XCTAssertTrue(noRules.isEmpty)
        XCTAssertTrue(noMutes.isEmpty)
        XCTAssertEqual(try setAside(beside: layout.rulesFile).count, 1)
        XCTAssertEqual(try setAside(beside: layout.mutedFile).count, 1)
        let notices = StoredFileNotices.take()
        XCTAssertTrue(notices.contains("the rules"), "\(notices)")
        XCTAssertTrue(notices.contains("the muted conversations"), "\(notices)")
    }

    func testTwoFilesSetAsideTheSameSecondKeepBoth() throws {
        let file = root.appendingPathComponent("state.json")
        try Data("one".utf8).write(to: file)
        let first = try XCTUnwrap(AtomicFile.setAside(file))
        try Data("two".utf8).write(to: file)
        let second = try XCTUnwrap(AtomicFile.setAside(file))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("two".utf8))
    }

    /// Files as the previous release (f591fae) writes them load unchanged in this one.
    func testFilesFromThePreviousReleaseLoad() async throws {
        let account = UUID(uuidString: "6D1E2A10-0000-4000-8000-000000000001")!
        let folder = UUID(uuidString: "6D1E2A10-0000-4000-8000-000000000002")!
        try Data("""
            [{"authMethod":"oauth","createdAt":"2026-09-01T08:00:00Z","displayName":"Owner","email":"owner@example.com","id":"\(account.uuidString)",\
            "imapHost":"imap.gmail.com","imapPort":993,"isEnabled":true,"provider":"google","signature":"","smtpHost":"smtp.gmail.com","smtpPort":465}]
            """.utf8).write(to: layout.accountsFile)
        try FileManager.default.createDirectory(at: layout.accountDirectory(account), withIntermediateDirectories: true)
        try Data("""
            [{"accountID":"\(account.uuidString)","attributes":["\\\\HasNoChildren"],"delimiter":"/","id":"\(folder.uuidString)","isSelectable":true,\
            "lastSyncDate":"2026-09-22T10:04:29Z","lastSyncedUID":30920,"name":"INBOX","oldestSyncedUID":29814,"path":"INBOX","role":"inbox",\
            "totalCount":1031,"uidNext":30921,"uidValidity":1,"unreadCount":4}]
            """.utf8).write(to: layout.foldersFile(account))
        try Data("""
            [{"accountID":"\(account.uuidString)","date":"2026-09-22T10:20:00Z","destinationPath":"","enabled":true,"flagNames":["\\\\Seen"],\
            "folderID":"\(folder.uuidString)","id":"\(UUID().uuidString)","uidValidity":1,"uids":[30911],"verb":"store"}]
            """.utf8).write(to: layout.pendingActionsFile)

        let store = MailStore(layout: layout)
        try await store.load()
        let accounts = await store.allAccounts()
        XCTAssertEqual(accounts.map(\.email), ["owner@example.com"])
        let inbox = await store.folder(folder)
        XCTAssertEqual(inbox?.lastSyncedUID, 30920)
        XCTAssertEqual(inbox?.oldestSyncedUID, 29814)
        let problem = await store.folderListProblem(account)
        XCTAssertNil(problem)
        let pending = await PendingActionStore(layout: layout).all()
        XCTAssertEqual(pending.first?.uids, [30911])
        XCTAssertTrue(StoredFileNotices.take().isEmpty)
    }
}
