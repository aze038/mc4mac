import XCTest
@testable import FalconCore

final class RecipientTextTests: XCTestCase {
    private let kamal = EmailAddress(name: "Kamal Muradov", address: "kamal@example.com")

    func testLastFragmentIsWhatFollowsTheLastSeparator() {
        XCTAssertEqual(RecipientText.lastFragment(of: ""), "")
        XCTAssertEqual(RecipientText.lastFragment(of: "kam"), "kam")
        XCTAssertEqual(RecipientText.lastFragment(of: "ann@example.com, kam"), "kam")
        XCTAssertEqual(RecipientText.lastFragment(of: "ann@example.com;le "), "le")
        XCTAssertEqual(RecipientText.lastFragment(of: "ann@example.com, "), "")
    }

    func testSeparatorsInsideQuotesOrBracketsDoNotSplit() {
        XCTAssertEqual(RecipientText.lastFragment(of: "\"Muradov, Kamal\" <kamal@example.com>, le"), "le")
        XCTAssertEqual(RecipientText.lastFragment(of: "\"Muradov, Ka"), "\"Muradov, Ka")
        XCTAssertEqual(RecipientText.lastFragment(of: "Ann <ann,x@example.com"), "Ann <ann,x@example.com")
    }

    func testCompletingReplacesOnlyTheLastFragment() {
        XCTAssertEqual(RecipientText.completing("kam", with: kamal), "Kamal Muradov <kamal@example.com>, ")
        XCTAssertEqual(RecipientText.completing("", with: kamal), "Kamal Muradov <kamal@example.com>, ")
        XCTAssertEqual(RecipientText.completing("ann@example.com, ka", with: kamal),
                       "ann@example.com, Kamal Muradov <kamal@example.com>, ")
        XCTAssertEqual(RecipientText.completing("ann@example.com;ka", with: EmailAddress(address: "kasia@example.org")),
                       "ann@example.com; kasia@example.org, ")
    }

    func testCompletingKeepsEarlierRecipientsExactly() {
        let earlier = "\"Muradov,Kamal\"   <kamal@example.com>,"
        let completed = RecipientText.completing(earlier + "le", with: EmailAddress(name: "Leyla", address: "leyla@example.com"))
        XCTAssertTrue(completed.hasPrefix(earlier))
        let parsed = AddressParser.parse(completed)
        XCTAssertEqual(parsed.map(\.address), ["kamal@example.com", "leyla@example.com"])
        XCTAssertEqual(parsed.first?.name, "Muradov,Kamal")
    }

    private func contact(_ name: String, _ email: String, uses: Int) -> ContactInfo {
        ContactInfo(id: email, accountID: UUID(), name: name, email: email, source: "test", useCount: uses)
    }

    func testTheAddressTypedInFullComesFirstHoweverRarelyUsed() {
        let jordan = contact("Jordan Lee", "jordan@acme.com", uses: 40)
        let dan = contact("Dan Brown", "dan@acme.com", uses: 1)
        XCTAssertEqual(RecipientText.suggestions(from: [jordan, dan], for: "dan@acme.com").map(\.email),
                       ["dan@acme.com", "jordan@acme.com"])
        XCTAssertEqual(RecipientText.suggestions(from: [jordan, dan], for: "DAN@Acme.com").first, dan)
        XCTAssertEqual(RecipientText.suggestions(from: [jordan, dan], for: "Dan <dan@acme.com>"), [dan])
    }

    func testWhatStartsWithTheFragmentOutranksWhatMerelyContainsIt() {
        let jordan = contact("Jordan Lee", "jordan@acme.com", uses: 40)
        let byName = contact("Dan Brown", "dbrown@acme.com", uses: 1)
        let byAddress = contact("", "danielle@acme.com", uses: 2)
        let bySurname = contact("Sue Danvers", "sue@acme.com", uses: 5)
        XCTAssertEqual(RecipientText.suggestions(from: [jordan, byName, byAddress, bySurname], for: "dan"),
                       [bySurname, byAddress, byName, jordan])
    }

    func testOneRowPerAddress() {
        let synced = contact("Dan Brown", "dan@acme.com", uses: 0)
        let recent = contact("", "Dan@Acme.com", uses: 3)
        XCTAssertEqual(RecipientText.suggestions(from: [synced, recent], for: "dan"), [recent])
        XCTAssertEqual(RecipientText.suggestions(from: [synced], for: "  "), [])
    }

    func testAnAddressTypedInFullIsNeverCompletedToAnother() {
        let jordan = contact("Jordan Lee", "jordan@acme.com", uses: 40)
        let offered = RecipientText.suggestions(from: [jordan], for: "dan@acme.com")
        XCTAssertEqual(offered, [jordan])
        XCTAssertFalse(RecipientText.mayComplete("dan@acme.com", with: offered[0].email))
        XCTAssertFalse(RecipientText.mayComplete("Dan <dan@acme.com>", with: "jordan@acme.com"))
        XCTAssertFalse(RecipientText.mayComplete("dan@acme.co", with: "dan@acme.com"))
        XCTAssertTrue(RecipientText.mayComplete("dan@acme.com", with: "Dan@ACME.com"))
    }

    func testAPartlyTypedNameOrAddressStillCompletes() {
        let kamal = contact("Kamal Muradov", "kamal@example.com", uses: 1)
        let nakamura = contact("Rin Nakamura", "rin@example.net", uses: 9)
        let offered = RecipientText.suggestions(from: [nakamura, kamal], for: "kam")
        XCTAssertEqual(offered.first, kamal)
        XCTAssertTrue(RecipientText.mayComplete("kam", with: kamal.email))
        XCTAssertEqual(RecipientText.completing("ann@example.com, kam", with: EmailAddress(name: kamal.name, address: kamal.email)),
                       "ann@example.com, Kamal Muradov <kamal@example.com>, ")
        XCTAssertEqual(RecipientText.suggestions(from: [nakamura, kamal], for: "mur"), [kamal, nakamura])
        for partial in ["kamal", "kamal@", "kamal@example", "kamal@example.", "kamal@example.c"] {
            XCTAssertTrue(RecipientText.mayComplete(partial, with: kamal.email), partial)
        }
    }

    func testCompleteAddressIsOnlyAWholeOne() {
        XCTAssertEqual(RecipientText.completeAddress(in: "dan@acme.com"), "dan@acme.com")
        XCTAssertEqual(RecipientText.completeAddress(in: " Dan Brown <dan@acme.co.uk> "), "dan@acme.co.uk")
        for fragment in ["", "dan", "dan@", "@acme.com", "dan@acme", "dan@acme.", "dan@acme.c", "dan@acme..com",
                         "dan@@acme.com", "dan brown@acme.com", "Dan <dan@acme.com", "\"Brown, Dan"] {
            XCTAssertNil(RecipientText.completeAddress(in: fragment), fragment)
        }
    }

    private func entry(_ name: String, _ email: String, source: String, uses: Int = 1, label: String? = nil) -> ContactInfo {
        ContactInfo(id: source + ":" + email, accountID: UUID(), name: name, email: email, source: source, useCount: uses, label: label)
    }

    func testRowsCarryTheContactListsLabelAndMarkOnlyRecentAddresses() {
        let kamal = entry("Kamal Muradov", "kamal@example.com", source: "google", uses: 5, label: "Work")
        let bot = entry("kamal-bot", "notifications@example.org", source: ContactInfo.recentSource, uses: 3)
        let rows = RecipientText.suggestionRows(from: [bot, kamal], for: "kam", limit: 8)
        XCTAssertEqual(rows, [
            RecipientSuggestion(name: "Kamal Muradov", email: "kamal@example.com", label: "Work", isRecentAddress: false),
            RecipientSuggestion(name: "kamal-bot", email: "notifications@example.org", label: "", isRecentAddress: true),
        ])
    }

    func testAnAddressInAContactListIsNotARecentOneEvenWhenItsRecentEntryRanksFirst() {
        let listed = entry("Dan Brown", "dan@acme.com", source: "google", uses: 0, label: "Home")
        let recent = entry("", "Dan@Acme.com", source: ContactInfo.recentSource, uses: 9)
        let rows = RecipientText.suggestionRows(from: [recent, listed], for: "dan", limit: 8)
        XCTAssertEqual(rows, [RecipientSuggestion(name: "Dan Brown", email: "Dan@Acme.com", label: "Home", isRecentAddress: false)])
    }

    func testRowsKeepTheSuggestionOrderAndLimit() {
        let people = (1...12).map { entry("Kam \($0)", "kam\($0)@example.com", source: "google", uses: $0) }
        let rows = RecipientText.suggestionRows(from: people, for: "kam", limit: 8)
        XCTAssertEqual(rows.map(\.email), RecipientText.suggestions(from: people, for: "kam").prefix(8).map(\.email))
        XCTAssertEqual(RecipientText.suggestionRows(from: people, for: " ", limit: 8), [])
    }

    func testForgettingARecentAddressLeavesContactsAndOtherAddresses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContactStore(layout: FileLayout(root: directory))
        let account = UUID(), other = UUID()
        try await store.replace(accountID: account, source: "google",
                                with: [ContactInfo(id: "g:dan", accountID: account, name: "Dan", email: "dan@acme.com", source: "google")])
        try await store.recordUse(accountID: account, addresses: [EmailAddress(address: "bot@example.org"), EmailAddress(address: "ann@example.org")])
        try await store.recordUse(accountID: other, addresses: [EmailAddress(address: "BOT@example.org"), EmailAddress(address: "dan@acme.com")])

        try await store.forgetRecent("bot@EXAMPLE.org")
        try await store.forgetRecent("dan@acme.com")

        let left = await store.all().map { "\($0.source) \($0.email.lowercased())" }.sorted()
        XCTAssertEqual(left, ["google dan@acme.com", "recent ann@example.org"])
        let reopened = await ContactStore(layout: FileLayout(root: directory)).all().map { $0.email.lowercased() }.sorted()
        XCTAssertEqual(reopened, ["ann@example.org", "dan@acme.com"])
    }

    func testContactsSavedBeforeLabelsStillLoad() throws {
        let saved = #"[{"id":"g:1","accountID":"8E0C4E2B-0D5C-4C1B-9A3A-6F2B7F0C1D2E","name":"Ann","email":"ann@example.com","source":"google","useCount":2}]"#
        let decoded = try JSONDecoder().decode([ContactInfo].self, from: Data(saved.utf8))
        XCTAssertEqual(decoded.first?.label, nil)
        XCTAssertEqual(decoded.first?.isRecentAddress, false)
    }

    func testCompletedNamesThatNeedQuotingParseBack() {
        let completed = RecipientText.completing("mur", with: EmailAddress(name: "Muradov, Kamal", address: "kamal@example.com"))
        XCTAssertEqual(completed, "\"Muradov, Kamal\" <kamal@example.com>, ")
        XCTAssertEqual(RecipientText.lastFragment(of: completed), "")
        XCTAssertEqual(AddressParser.parse(completed), [EmailAddress(name: "Muradov, Kamal", address: "kamal@example.com")])
    }
}
