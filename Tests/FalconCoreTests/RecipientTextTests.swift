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

    func testCompletedNamesThatNeedQuotingParseBack() {
        let completed = RecipientText.completing("mur", with: EmailAddress(name: "Muradov, Kamal", address: "kamal@example.com"))
        XCTAssertEqual(completed, "\"Muradov, Kamal\" <kamal@example.com>, ")
        XCTAssertEqual(RecipientText.lastFragment(of: completed), "")
        XCTAssertEqual(AddressParser.parse(completed), [EmailAddress(name: "Muradov, Kamal", address: "kamal@example.com")])
    }
}
