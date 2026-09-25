import XCTest
import AppKit
@testable import FalconCore

/// Imported signatures join the signatures already here: a name already taken is asked about
/// (kept beside it, put in its place, or left out), and each account the signature is for starts
/// its new messages, replies and forwards with it. Gmail's signatures come from each address's
/// Gmail settings, through the fake Gmail only, with their pictures from the web fetched once.
final class SignatureImportTests: XCTestCase {
    private let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
    private let alex = AccountInfo(email: "alex@example.com", displayName: "Alex Example")
    private let office = AccountInfo(email: "office@example.org", displayName: "Example Office", provider: "imap")

    private func imported(_ name: String, words: String) -> Signature {
        var signature = Signature(name: name)
        signature.setText(NSAttributedString(string: words, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
        return signature
    }

    // MARK: - Names already taken

    func testANameNotTakenComesInAsItIsAndStartsTheAccountsMessages() {
        var book = SignatureBook()
        let outcome = book.importing([SignatureImportItem(signature: imported("Test Signature", words: "Alex Example"),
                                                          defaultFor: [alex.id])])
        XCTAssertEqual(book.signatures.map(\.name), ["Test Signature"])
        XCTAssertEqual(outcome.added, [book.signatures[0].id])
        XCTAssertEqual(book.signature(for: alex.id, .newMessages)?.name, "Test Signature")
        XCTAssertEqual(book.signature(for: alex.id, .replies)?.name, "Test Signature")
        XCTAssertNil(book.signature(for: office.id, .newMessages))
        XCTAssertEqual(outcome.defaults, [.init(accountID: alex.id, signatureID: book.signatures[0].id)])
    }

    func testKeepBothImportsItUnderTheNextFreeName() {
        var book = SignatureBook()
        let mine = book.add(startingWith: "Mine")
        book.rename(mine.id, to: "Test Signature")
        book.setDefault(mine.id, for: office.id, .newMessages)
        book.importing([SignatureImportItem(signature: imported("test signature", words: "Imported"), clash: .keepBoth)])
        XCTAssertEqual(book.sorted.map(\.name), ["Test Signature", "test signature 2"])
        XCTAssertEqual(book.signature(mine.id)?.plain, "Mine")
        XCTAssertEqual(book.defaultID(for: office.id, .newMessages), mine.id)
    }

    func testReplacePutsTheTextInPlaceOfTheOneHereWhichKeepsItsPlaceAsADefault() throws {
        var book = SignatureBook()
        let mine = book.add(startingWith: "Old words")
        book.rename(mine.id, to: "Test Signature")
        book.setDefault(mine.id, for: office.id, .replies)
        let incoming = imported("Test Signature", words: "New words")
        let outcome = book.importing([SignatureImportItem(signature: incoming, clash: .replace, defaultFor: [alex.id])])
        XCTAssertEqual(book.signatures.count, 1)
        XCTAssertEqual(outcome.replaced, [mine.id])
        XCTAssertTrue(outcome.added.isEmpty)
        let replaced = try XCTUnwrap(book.signature(mine.id))
        XCTAssertEqual(replaced.name, "Test Signature")
        XCTAssertEqual(replaced.plain, "New words")
        XCTAssertEqual(replaced.rich, incoming.rich)
        XCTAssertEqual(book.defaultID(for: office.id, .replies), mine.id)
        XCTAssertEqual(book.defaultID(for: alex.id, .newMessages), mine.id)
        XCTAssertEqual(book.defaultID(for: alex.id, .replies), mine.id)
    }

    func testSkipLeavesItOutAndChangesNoDefault() {
        var book = SignatureBook()
        let mine = book.add(startingWith: "Mine")
        book.rename(mine.id, to: "Test Signature")
        let outcome = book.importing([SignatureImportItem(signature: imported("Test Signature", words: "Imported"), clash: .skip,
                                                          defaultFor: [alex.id])])
        XCTAssertEqual(book.signatures.map(\.plain), ["Mine"])
        XCTAssertEqual(outcome.skipped, ["Test Signature"])
        XCTAssertTrue(outcome.isEmpty)
        XCTAssertNil(book.defaultID(for: alex.id, .newMessages))
    }

    func testTwoOfOneNameInOneImportBothComeInAndNeitherIsAskedAbout() {
        var book = SignatureBook()
        XCTAssertFalse(book.hasSignature(named: "Main"))
        book.importing([SignatureImportItem(signature: imported("Main", words: "One"), clash: .skip),
                        SignatureImportItem(signature: imported("Main", words: "Two"), clash: .skip)])
        XCTAssertEqual(book.sorted.map(\.name), ["Main", "Main 2"])
        XCTAssertEqual(book.sorted.map(\.plain), ["One", "Two"])
    }

    @MainActor
    func testAnImportedSignatureStartsTheAccountsMessagesRepliesAndForwardsWithItsPicture() throws {
        let logo = OutlookFixture.jpeg(192, 58)
        let candidate = SignatureCandidate(name: "Test Signature", origin: .outlook(profile: "Main Profile"), html: OutlookFixture.wordHTML(),
                                           pictures: [MIMEAttachment(picture: logo, filename: "image001.jpg", mimeType: "image/jpeg",
                                                                     contentID: OutlookFixture.contentID)],
                                           defaultAddresses: ["alex@example.com"])
        let imported = try XCTUnwrap(candidate.signature(attributes: body))
        var book = SignatureBook()
        let other = book.add(startingWith: "Office")
        book.setDefault(other.id, for: office.id, .newMessages)
        book.importing([SignatureImportItem(signature: imported, defaultFor: candidate.defaultAccounts(in: [alex, office]))])
        // Kept as the signatures file keeps it, then read back as the app reads it at launch.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("signatures-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try SignatureStore(file: file).save(book)
        book = SignatureStore(file: file).open().book

        // A new message from the account.
        let new = try XCTUnwrap(book.signature(for: alex.id, .newMessages))
        XCTAssertEqual(new.name, "Test Signature")
        let opened = ComposedBody.opening(lead: "\n\n", signature: new, tail: "", attributes: body)
        let rich = try XCTUnwrap(opened.rich)
        XCTAssertEqual(InlinePictures.attachmentLocations(in: rich).count, 1)
        XCTAssertTrue(rich.string.hasPrefix("\n\n-- \nAlex Example\n"), rich.string)

        // A reply or forward: the signature above the quoted original, with its picture.
        let reply = try XCTUnwrap(book.signature(for: alex.id, .replies))
        XCTAssertEqual(reply.id, new.id)
        let quote = NSAttributedString(string: "From: Sam\nThe figures\n", attributes: body)
        let replying = ComposedBody.opening(lead: "\n\n", signature: reply, quote: quote, attributes: body)
        let picture = try XCTUnwrap(InlinePictures.attachmentLocations(in: replying.rich).first?.0)
        XCTAssertLessThan(picture, (replying.plain as NSString).range(of: "From: Sam").location)

        // Another account keeps its own; changing From to it swaps to that one.
        XCTAssertEqual(book.signature(for: office.id, .newMessages)?.id, other.id)
        XCTAssertNil(book.signature(for: office.id, .replies))
    }

    // MARK: - Gmail

    private func candidates(from mailbox: FakeGmailMailbox, account: String) async throws -> [SignatureCandidate] {
        let client = GmailTestKit.client(mailbox)
        return SignatureCandidate.gmail(try await client.sendAs(), account: account)
    }

    func testEachGmailAddressWithASignatureIsOfferedForThatAddress() async throws {
        let mailbox = FakeGmailMailbox(email: "alex@example.com")
        mailbox.sendAs = [
            ["sendAsEmail": "alex@example.com", "displayName": "Alex Example", "isPrimary": true, "isDefault": true,
             "signature": "<div dir=\"ltr\"><b>Alex Example</b><br>Operations</div>"],
            ["sendAsEmail": "office@example.org", "displayName": "Example Office", "signature": "<div>Example Office</div>"],
            ["sendAsEmail": "quiet@example.com", "signature": "  "],
            ["sendAsEmail": "none@example.com"],
        ]
        let offered = try await candidates(from: mailbox, account: "alex@example.com")
        XCTAssertEqual(offered.map(\.name), ["Gmail – alex@example.com", "Gmail – office@example.org"])
        XCTAssertEqual(offered.map(\.origin), [.gmail(account: "alex@example.com"), .gmail(account: "alex@example.com")])
        XCTAssertEqual(offered.map(\.defaultAddresses), [["alex@example.com"], ["office@example.org"]])
        XCTAssertTrue(offered.allSatisfy(\.defaultsKnown))
        XCTAssertEqual(offered[0].defaultAccounts(in: [office, alex]), [alex.id])
        XCTAssertEqual(offered[1].defaultAccounts(in: [office, alex]), [office.id])
        XCTAssertEqual(mailbox.units, [.sendAsList: 1], "one call, priced as Google prices it")
    }

    func testAGmailAccountWithoutSignaturesOffersNone() async throws {
        let mailbox = FakeGmailMailbox(email: "alex@example.com")
        mailbox.sendAs = [["sendAsEmail": "alex@example.com", "isPrimary": true]]
        let offered = try await candidates(from: mailbox, account: "alex@example.com")
        XCTAssertTrue(offered.isEmpty)
    }

    func testARefusalFromGmailIsThrownAsGooglesError() async throws {
        let mailbox = FakeGmailMailbox(email: "alex@example.com")
        mailbox.always(.status(403, reason: "insufficientPermissions"), for: .sendAsList)
        let client = GmailTestKit.client(mailbox)
        do {
            _ = try await client.sendAs()
            XCTFail("a refusal was taken as no addresses")
        } catch let error as GoogleAPIError {
            XCTAssertEqual(error.kind, .insufficientPermissions)
        }
    }

    @MainActor
    func testAGmailSignaturesLogoFromTheWebIsFetchedOnceAndSentEmbedded() async throws {
        let logo = OutlookFixture.jpeg(120, 40)
        let address = "https://lh3.example.com/logo.jpg"
        let mailbox = FakeGmailMailbox(email: "alex@example.com")
        mailbox.sendAs = [["sendAsEmail": "alex@example.com", "isPrimary": true,
                           "signature": "<div dir=\"ltr\"><div>Alex Example</div><img src=\"\(address)\" width=\"60\" height=\"20\"><img src=\"\(address)\" width=\"60\" height=\"20\"></div>"]]
        let offered = try await candidates(from: mailbox, account: "alex@example.com")
        let candidate = try XCTUnwrap(offered.first)
        XCTAssertEqual(candidate.remoteAddresses, [address])
        let fetches = Counter()
        let loader = RemotePictureLoader { url in
            await fetches.add(url.absoluteString)
            return logo
        }
        let fetched = await loader.fetch(offered.flatMap(\.remoteAddresses))
        let fetchedAddresses = await fetches.seen
        XCTAssertEqual(fetchedAddresses, [address])
        let signature = try XCTUnwrap(candidate.signature(remote: fetched, attributes: body))
        XCTAssertEqual(signature.name, "Gmail – alex@example.com")
        let pictures = InlinePictures.attachmentLocations(in: signature.text)
        XCTAssertEqual(pictures.count, 2)
        XCTAssertTrue(pictures.allSatisfy { RemotePictures.placeholder(of: $0.1) == nil }, "the logo stayed a box")

        let opened = ComposedBody.opening(lead: "\n\n", signature: signature, tail: "", attributes: body)
        let content = ComposedHTML.content(rich: opened.rich, plain: opened.plain, historyPlain: "", historyHTML: "")
        XCTAssertEqual(content.pictures.count, 1, "the logo shown twice is sent once")
        XCTAssertEqual(content.pictures.first?.mimeType, "image/jpeg")
        XCTAssertFalse(content.html.contains(address), "the logo is still fetched from the web: \(content.html)")
        XCTAssertTrue(content.html.contains("<img width=\"60\" height=\"20\""), content.html)
    }

    @MainActor
    func testALogoThatCouldNotBeFetchedIsSentFromItsAddressAsGmailSendsIt() async throws {
        let address = "https://lh3.example.com/missing.png"
        let candidate = SignatureCandidate(name: "Gmail – alex@example.com", origin: .gmail(account: "alex@example.com"),
                                           html: "<div>Alex</div><img src=\"\(address)\" width=\"50\" height=\"20\">",
                                           defaultAddresses: ["alex@example.com"], defaultsKnown: true)
        let signature = try XCTUnwrap(candidate.signature(remote: [:], attributes: body))
        let box = try XCTUnwrap(InlinePictures.attachmentLocations(in: signature.text).first?.1)
        XCTAssertEqual(RemotePictures.placeholder(of: box)?.address, address)
        let content = ComposedHTML.content(rich: ComposedBody.opening(lead: "", signature: signature, tail: "", attributes: body).rich,
                                           plain: "", historyPlain: "", historyHTML: "")
        XCTAssertTrue(content.html.contains("src=\"\(address)\""), content.html)
        XCTAssertTrue(content.pictures.isEmpty)
    }

    private actor Counter {
        private(set) var seen: [String] = []
        func add(_ address: String) { seen.append(address) }
    }
}
