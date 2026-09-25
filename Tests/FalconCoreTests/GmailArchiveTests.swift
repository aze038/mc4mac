import XCTest
@testable import FalconCore

/// The archive job on a switched Google account: its folders are labels, read through the Gmail
/// API, and removing archived mail takes it out of the archived folder only, as v1.10.0's
/// expunge does on Gmail.
final class GmailArchiveTests: XCTestCase {
    private var root: URL!
    private let owner = "owner@example.com"
    private let cutoff = ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")!
    private let longAgo = ISO8601DateFormatter().date(from: "2023-06-01T10:00:00Z")!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("falcon-gmail-archive-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Log.start(in: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func request(_ folders: [String], remove: Bool = true, olderThan: Date? = nil, name: String = "Old mail") -> ArchiveRequest {
        ArchiveRequest(accountID: UUID(), folderPaths: folders, olderThan: olderThan ?? cutoff, name: name, password: nil,
                       removeFromServer: remove, parentID: nil)
    }

    private var account: AccountInfo { AccountInfo(email: owner, displayName: "Owner") }

    private func storage() -> LocalFolderStorage {
        LocalFolderStorage(root: root.appendingPathComponent("Archives"))
    }

    private func entries(_ name: String = "Old mail") async throws -> [ArchiveEntry] {
        let reader = ArchiveReader(storage: storage(), rootID: root.appendingPathComponent("Archives/\(name).fmarchive").path)
        try await reader.loadIndex()
        return await reader.entries
    }

    func testRemovingALabelFolderLeavesTheInboxCopy() async throws {
        let mailbox = FakeGmail(email: owner)
        let clients = mailbox.addUserLabel(named: "Clients")
        let both = mailbox.add(subject: "In the Inbox too", labels: [.inbox, clients], date: longAgo)
        let only = mailbox.add(subject: "Only in Clients", labels: [clients], date: longAgo)
        let recent = mailbox.add(subject: "Too recent", labels: [clients], date: Date())
        let source = GmailArchiveSource(transport: mailbox, folders: ["Clients": clients])
        let outcome = try await ArchiveJob.run(request: request(["Clients"]), account: account, source: source, storage: storage()) { _ in }

        XCTAssertEqual(outcome.manifest.messageCount, 2)
        XCTAssertTrue(outcome.keptOnServer.isEmpty)
        XCTAssertEqual(mailbox.message(both.id)?.labels, [.inbox], "still in the Inbox, and only out of Clients")
        XCTAssertEqual(mailbox.message(only.id)?.labels, [], "still in Archive (All Mail)")
        XCTAssertEqual(mailbox.message(recent.id)?.labels, [clients], "newer than the cut-off, so not archived")
        XCTAssertFalse(mailbox.messages.contains { $0.labels.contains(.trash) }, "nothing goes to Deleted Items")
        XCTAssertEqual(mailbox.units[.messagesBatchModify], 50, "one call for the folder")
        XCTAssertNil(mailbox.calls[.messagesBatchDelete], "nothing is deleted for good")

        let archived = try await entries()
        XCTAssertEqual(Set(archived.map(\.subject)), ["In the Inbox too", "Only in Clients"])
        XCTAssertEqual(Set(archived.map(\.folder)), ["Clients"])
    }

    func testArchivingTheInboxTakesOnlyINBOXAndKeepsTheStar() async throws {
        let mailbox = FakeGmail(email: owner)
        let starred = mailbox.add(subject: "Starred", labels: [.inbox, .starred, .unread], date: longAgo)
        let source = GmailArchiveSource(transport: mailbox, folders: ["Inbox": .inbox])
        _ = try await ArchiveJob.run(request: request(["Inbox"]), account: account, source: source, storage: storage()) { _ in }
        XCTAssertEqual(mailbox.message(starred.id)?.labels, [.starred, .unread])
        let archived = try await entries()
        XCTAssertEqual(archived.first?.flags.sorted(), MessageFlags.flagged.archiveNames.sorted(), "unread and flagged, as Gmail had it")
    }

    func testArchivingArchiveItselfMovesTheMailToDeletedItems() async throws {
        let mailbox = FakeGmail(email: owner)
        let a = mailbox.add(subject: "Old one", labels: [.inbox], date: longAgo)
        let b = mailbox.add(subject: "Old two", labels: [], date: longAgo)
        let source = GmailArchiveSource(transport: mailbox, folders: ["Archive": GmailLabelID?.none])
        let outcome = try await ArchiveJob.run(request: request(["Archive"]), account: account, source: source, storage: storage()) { _ in }
        XCTAssertEqual(outcome.manifest.messageCount, 2)
        XCTAssertTrue(mailbox.message(a.id)?.labels.contains(.trash) ?? false)
        XCTAssertTrue(mailbox.message(b.id)?.labels.contains(.trash) ?? false)
        XCTAssertNotNil(mailbox.message(a.id), "in Deleted Items, where Gmail keeps it 30 days, not deleted for good")
    }

    func testSentDraftsDeletedItemsAndJunkEmailAreKeptOnGmail() async throws {
        let mailbox = FakeGmail(email: owner)
        let sent = mailbox.add(subject: "Sent long ago", labels: [.sent], date: longAgo)
        let junk = mailbox.add(subject: "Junk long ago", labels: [.spam], date: longAgo)
        let deleted = mailbox.add(subject: "Deleted long ago", labels: [.trash], date: longAgo)
        let source = GmailArchiveSource(transport: mailbox, folders: ["Sent": .sent, "Junk Email": .spam, "Deleted Items": .trash])
        let outcome = try await ArchiveJob.run(request: request(["Sent", "Junk Email", "Deleted Items"]), account: account, source: source,
                                               storage: storage()) { _ in }
        XCTAssertEqual(outcome.manifest.messageCount, 3, "all three are archived")
        XCTAssertEqual(Set(outcome.keptOnServer), ["Sent", "Junk Email", "Deleted Items"])
        XCTAssertEqual(mailbox.message(sent.id)?.labels, [.sent])
        XCTAssertEqual(mailbox.message(junk.id)?.labels, [.spam], "never brought back out of Junk Email")
        XCTAssertEqual(mailbox.message(deleted.id)?.labels, [.trash], "never brought back out of Deleted Items")
        XCTAssertNil(mailbox.calls[.messagesBatchModify])
    }

    func testNothingIsRemovedUntilTheArchiveIsWritten() async throws {
        let mailbox = FakeGmail(email: owner)
        let kept = mailbox.add(subject: "Kept", labels: [.inbox], date: longAgo)
        let source = GmailArchiveSource(transport: mailbox, folders: ["Inbox": .inbox])
        do {
            _ = try await ArchiveJob.run(request: request(["Inbox"]), account: account, source: source, storage: FailingManifestStorage(storage())) { _ in }
            XCTFail("the manifest could not be written")
        } catch {}
        XCTAssertEqual(mailbox.message(kept.id)?.labels, [.inbox])
        XCTAssertNil(mailbox.calls[.messagesBatchModify])
    }

    func testAMessageDeletedSinceTheListingIsSkippedAndNotRemoved() async throws {
        let transport = ScriptedGmailTransport(FakeGmail(email: owner))
        let mailbox = transport.mailbox
        let gone = mailbox.add(subject: "Deleted meanwhile", labels: [.inbox], date: longAgo)
        let stays = mailbox.add(subject: "Archived", labels: [.inbox], date: longAgo)
        let gate = transport.hold(.messagesGet)
        let source = GmailArchiveSource(transport: transport, folders: ["Inbox": .inbox])
        let storage = storage()
        let account = account
        let job = Task { try await ArchiveJob.run(request: self.request(["Inbox"]), account: account, source: source, storage: storage) { _ in } }
        await assertEventually { gate.arrivals == 1 }
        mailbox.delete(gone.id)
        gate.open()
        let outcome = try await job.value
        XCTAssertEqual(outcome.manifest.messageCount, 1)
        XCTAssertEqual(mailbox.message(stays.id)?.labels, [])
    }

    func testTheJobKeepsToItsPaceAndHoldsAtItsAllowance() async throws {
        let mailbox = FakeGmail(email: owner)
        for i in 0..<25 { mailbox.add(subject: "Old \(i)", labels: [.inbox], date: longAgo.addingTimeInterval(Double(i))) }
        let clock = TestClock(Date())
        let sleeps = SleepLog()
        let asked = SleepLog()
        let source = GmailArchiveSource(transport: mailbox, folders: ["Inbox": .inbox],
                                        allowance: { bytes in asked.append(TimeInterval(bytes)); return false }, perMinute: 10,
                                        now: clock.reading, sleep: { seconds in sleeps.append(seconds); clock.advance(seconds) })
        let outcome = try await ArchiveJob.run(request: request(["Inbox"], remove: false), account: account, source: source,
                                               storage: storage()) { _ in }
        XCTAssertEqual(outcome.manifest.messageCount, 25)
        XCTAssertEqual(sleeps.all.count, 2, "10 a minute: two waits for 25")
        XCTAssertEqual(asked.all.count, 3, "the allowance is asked before every batch of 10")
        XCTAssertEqual(asked.all.first, 0)
        XCTAssertGreaterThan(asked.all.last ?? 0, 0, "with what the batch before it took")
        XCTAssertEqual(mailbox.units[.messagesGet], 25 * 20, "format=raw, 20 units each")
        XCTAssertEqual(mailbox.units[.messagesList], 5, "one page")
    }

    func testTheJobCarriesOnAfterADroppedConnectionAndAPause() async throws {
        let mailbox = FakeGmail(email: owner)
        for i in 0..<3 { mailbox.add(subject: "Old \(i)", labels: [.inbox], date: longAgo.addingTimeInterval(Double(i))) }
        mailbox.fail(nil, with: GoogleAPIError(kind: .offline, detail: "URLError -1009"))
        let sleeps = SleepLog()
        // The job's waits move the transport's clock too, so the pause Gmail asked for is over when it tries again.
        let source = GmailArchiveSource(transport: mailbox, folders: ["Inbox": .inbox], sleep: {
            sleeps.append($0)
            mailbox.clock.advance($0)
        })
        mailbox.fail(.messagesList, with: GoogleAPIError(kind: .downloadLimit, httpStatus: 429, retryAfter: 900))
        let outcome = try await ArchiveJob.run(request: request(["Inbox"], remove: false), account: account, source: source,
                                               storage: storage()) { _ in }
        XCTAssertEqual(outcome.manifest.messageCount, 3)
        XCTAssertEqual(sleeps.all.sorted(), [2, 900], "a short wait after the dropped connection, Gmail's own for its pause")
    }

    func testAFolderWithNoGmailLabelIsRefusedBeforeAnythingIsWritten() async throws {
        let mailbox = FakeGmail(email: owner)
        let source = GmailArchiveSource(transport: mailbox, folders: [:])
        do {
            _ = try await ArchiveJob.run(request: request(["Nowhere"]), account: account, source: source, storage: storage()) { _ in }
            XCTFail("unknown folder")
        } catch let failure as MailServiceError {
            XCTAssertEqual(failure.kind, .folderGone)
            XCTAssertEqual(failure.name, "Nowhere")
        }
    }
}

/// Storage that writes everything but the manifest, as a disk that fills up at the end would.
private struct FailingManifestStorage: ArchiveStorage {
    let inner: LocalFolderStorage

    init(_ inner: LocalFolderStorage) {
        self.inner = inner
    }

    var kind: String { inner.kind }

    func createFolder(name: String, parentID: String?) async throws -> String { try await inner.createFolder(name: name, parentID: parentID) }
    func list(parentID: String?) async throws -> [RemoteFile] { try await inner.list(parentID: parentID) }
    func find(name: String, parentID: String?) async throws -> RemoteFile? { try await inner.find(name: name, parentID: parentID) }

    func upload(name: String, parentID: String, data: Data, mimeType: String) async throws -> String {
        if name == "manifest.json" { throw CocoaError(.fileWriteOutOfSpace) }
        return try await inner.upload(name: name, parentID: parentID, data: data, mimeType: mimeType)
    }

    func beginUpload(name: String, parentID: String, mimeType: String) async throws -> ArchiveUploadSession {
        try await inner.beginUpload(name: name, parentID: parentID, mimeType: mimeType)
    }

    func read(fileID: String, range: Range<Int>?) async throws -> Data { try await inner.read(fileID: fileID, range: range) }
    func delete(fileID: String) async throws { try await inner.delete(fileID: fileID) }
}
