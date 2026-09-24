import XCTest
@testable import FalconCore

/// Replying to a thread whose newest message is the owner's own must not address the owner.
final class ReplyAddressingTests: XCTestCase {
    private let own: Set<String> = ["owner@example.com", "sales@example.com"]

    private func message(from: String, to: [String], cc: [String] = []) -> MessageSummary {
        MessageSummary(accountID: UUID(), folderID: UUID(), uid: 1, messageID: "<m@example.com>", inReplyTo: "", references: [],
                       subject: "Plans", from: EmailAddress(name: "", address: from), to: to.map { EmailAddress(address: $0) },
                       cc: cc.map { EmailAddress(address: $0) }, date: Date(), flags: [], size: 1, hasAttachments: false)
    }

    private func addresses(_ list: [EmailAddress]) -> [String] { list.map(\.address) }

    func testReplyToSomeoneElseGoesToTheSender() {
        let m = message(from: "ana@example.com", to: ["owner@example.com", "bo@example.com"], cc: ["cy@example.com"])
        let reply = ReplyAddressing.recipients(for: m, replyTo: [], own: own, all: false)
        XCTAssertEqual(addresses(reply.to), ["ana@example.com"])
        XCTAssertTrue(reply.cc.isEmpty)
        let all = ReplyAddressing.recipients(for: m, replyTo: [], own: own, all: true)
        XCTAssertEqual(addresses(all.to), ["ana@example.com"])
        XCTAssertEqual(addresses(all.cc), ["bo@example.com", "cy@example.com"], "everyone else, never the owner")
    }

    func testReplyToOwnMessageGoesToItsRecipients() {
        let m = message(from: "Owner@Example.com", to: ["ana@example.com", "owner@example.com"], cc: ["cy@example.com"])
        let reply = ReplyAddressing.recipients(for: m, replyTo: [], own: own, all: false)
        XCTAssertEqual(addresses(reply.to), ["ana@example.com"])
        XCTAssertTrue(reply.cc.isEmpty)
    }

    func testReplyAllToOwnMessageKeepsItsCcWithoutTheOwner() {
        let m = message(from: "owner@example.com", to: ["ana@example.com"], cc: ["cy@example.com", "owner@example.com", "ANA@example.com"])
        let all = ReplyAddressing.recipients(for: m, replyTo: [], own: own, all: true)
        XCTAssertEqual(addresses(all.to), ["ana@example.com"])
        XCTAssertEqual(addresses(all.cc), ["cy@example.com"])
    }

    func testANoteToSelfStaysOne() {
        let m = message(from: "owner@example.com", to: ["owner@example.com"])
        let reply = ReplyAddressing.recipients(for: m, replyTo: [], own: own, all: true)
        XCTAssertEqual(addresses(reply.to), ["owner@example.com"])
        XCTAssertTrue(reply.cc.isEmpty)
    }

    func testReplyToHeaderIsWhereTheReplyGoes() {
        let m = message(from: "news@list.example.com", to: ["owner@example.com", "bo@example.com"])
        let replyTo = [EmailAddress(name: "The list", address: "list@example.com")]
        let reply = ReplyAddressing.recipients(for: m, replyTo: replyTo, own: own, all: false)
        XCTAssertEqual(addresses(reply.to), ["list@example.com"])
        let all = ReplyAddressing.recipients(for: m, replyTo: replyTo, own: own, all: true)
        XCTAssertEqual(addresses(all.cc), ["bo@example.com"])
    }

    func testReplyToPointingAtTheOwnerCountsAsTheOwnersMessage() {
        let m = message(from: "owner@example.com", to: ["ana@example.com"])
        let reply = ReplyAddressing.recipients(for: m, replyTo: [EmailAddress(address: "sales@example.com")], own: own, all: false)
        XCTAssertEqual(addresses(reply.to), ["ana@example.com"])
    }

    func testMessageSentFromAnAliasIsTheOwners() {
        let m = message(from: "sales@example.com", to: ["ana@example.com"], cc: ["owner@example.com", "bo@example.com"])
        let all = ReplyAddressing.recipients(for: m, replyTo: [], own: own, all: true)
        XCTAssertEqual(addresses(all.to), ["ana@example.com"])
        XCTAssertEqual(addresses(all.cc), ["bo@example.com"], "neither the alias nor the main address is copied")
    }

    func testOwnAddressesIncludeASignInNameThatIsAnAddress() {
        let custom = AccountInfo.custom(email: "info@example.org", displayName: "Info", imapHost: "imap.example.org", imapPort: 993,
                                        smtpHost: "smtp.example.org", smtpPort: 465, username: "Kamal@Example.org")
        XCTAssertEqual(custom.ownAddresses, ["info@example.org", "kamal@example.org"])
        let plain = AccountInfo.custom(email: "info@example.org", displayName: "Info", imapHost: "imap.example.org", imapPort: 993,
                                       smtpHost: "smtp.example.org", smtpPort: 465, username: "kamal")
        XCTAssertEqual(plain.ownAddresses, ["info@example.org"])
    }
}
