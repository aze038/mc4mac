import XCTest
@testable import FalconCore

/// "Show All Gmail Labels", from the sidebar's account menu or Settings → Accounts: a label hidden
/// before the switch becomes a folder with every message it holds listed, and turned off again
/// the labels Gmail hides from its own list go from the sidebar. No message changes either way.
@MainActor
final class GmailLabelsShownTests: XCTestCase {
    private var rigs: [CoordinatorRig] = []

    override func tearDown() async throws {
        for rig in rigs { await rig.finish() }
        rigs = []
    }

    private let longAgo = Date(timeIntervalSince1970: 1_700_000_000)

    func testShowAllGmailLabelsMakesAHiddenLabelAFolderAndHidesItAgain() async throws {
        let rig = try CoordinatorRig()
        rigs.append(rig)
        let account = rig.googleAccount()
        let gmail = rig.gmail(for: account)
        let shown = gmail.addUserLabel(named: "Clients")
        let hidden = gmail.addUserLabel(named: "Receipts", visibility: "labelHide")
        for i in 0..<5 { gmail.add(subject: "Receipt \(i)", labels: [.inbox, hidden], date: longAgo.addingTimeInterval(Double(i) * 60)) }
        gmail.add(subject: "Contract", labels: [.inbox, shown], date: longAgo)
        // v1.10's folders show Clients, as the owner's IMAP settings did, and not Receipts.
        try rig.writePreviousRelease(account)
        try await rig.launch()
        try await rig.backfilled(account)
        let engine = try await rig.assembly(account).engine
        func folder(_ label: GmailLabelID) async -> FolderInfo? { await engine.folders().first { $0.gmailLabelID == label } }
        let clients = await folder(shown)
        XCTAssertNotNil(clients)
        let receiptsAtFirst = await folder(hidden)
        XCTAssertNil(receiptsAtFirst, "a label hidden before the switch is not a folder")

        await rig.coordinator.setShowsAllLabels(true, accountID: account.id)
        try await eventually(timeout: 20, "the hidden label is a folder, listed in full") {
            await folder(hidden)?.totalCount == 5
        }
        let assembly = try await rig.assembly(account)
        let found = await folder(hidden)
        let receipts = try XCTUnwrap(found)
        let list = ListController()
        await list.show(ListView(scope: .folder(receipts.id), conversations: false), from: assembly.list)
        XCTAssertEqual(list.itemCount, 5, "its messages are in its list")
        list.stop()

        await rig.coordinator.setShowsAllLabels(false, accountID: account.id)
        try await eventually(timeout: 20, "hidden again") { await folder(hidden) == nil }
        let stillShown = await folder(shown)
        XCTAssertNotNil(stillShown, "a label Gmail shows stays")
        XCTAssertEqual(gmail.messages.filter { $0.labels.contains(hidden) }.count, 5, "no message changes")
        XCTAssertEqual(rig.settings(of: account)?.showsAllLabels, false, "the engine started before the owner turned it on")

        // At the next launch the app tells the coordinator before any engine starts.
        await rig.coordinator.setShowsAllLabels(true, accountID: account.id)
        try await eventually(timeout: 20, "shown again") { await folder(hidden) != nil }
        await rig.quit()
        let relaunched = try CoordinatorRig(root: rig.root, switches: rig.switches)
        rigs.append(relaunched)
        relaunched.gmail(for: account, mailbox: gmail.mailbox)
        try await relaunched.launch { await $0.setShowsAllLabels(true, accountID: account.id) }
        XCTAssertEqual(relaunched.settings(of: account)?.showsAllLabels, true, "the engine starts with the owner's choice")
        let folders = try await relaunched.assembly(account).engine.folders()
        XCTAssertEqual(folders.first { $0.gmailLabelID == hidden }?.totalCount, 5, "and the folder is there from its files")
    }
}
