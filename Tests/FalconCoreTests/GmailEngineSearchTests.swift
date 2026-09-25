import XCTest
@testable import FalconCore

final class GmailEngineSearchTests: XCTestCase {
    private func mailbox() async throws -> (MemoryGmailTransport, MemoryGmailStore, GmailListSource) {
        let transport = MemoryGmailTransport()
        let store = MemoryGmailStore(accountID: transport.accountID)
        _ = try await store.saveLabelTable(ListFixtures.systemLabels())
        var refs: [GmailRef] = []
        for i in 0..<120 {
            let subject = i % 3 == 0 ? "Freight invoice for March \(i)" : "Weekly update \(i)"
            refs.append(transport.add(subject: subject, text: "Body \(i)", labels: [.inbox], date: Date().addingTimeInterval(-Double(i) * 60)))
        }
        try await store.commit(GmailJournalBatch(changes: refs.enumerated().map { i, ref in
            .place(ref, order: UInt32(120 - i) * 16, labels: [.inbox], attributes: [])
        }))
        let source = GmailListSource(accountID: transport.accountID, email: transport.email, store: store, transport: transport,
                                     archiveFolderID: UUID())
        return (transport, store, source)
    }

    /// Typing "freight invoice march" a word at a time, pausing between words but never for a
    /// second and a half, asks Gmail only for ids.
    func testTypingAThreeWordSearchSlowlyCostsOnlyIDLookups() async throws {
        let (transport, store, source) = try await mailbox()
        var plan = SearchTypingPlan()
        var search: GmailEngineSearch?
        var time = 0.0
        var lookups = 0
        func run(_ steps: [SearchTypingPlan.Step]) async {
            for step in steps {
                switch step {
                case .matchLocally:
                    break
                case .lookUpIDs(let query):
                    lookups += 1
                    await search?.end()
                    let next = GmailEngineSearch(query: query, source: source, store: store, transport: transport)
                    search = next
                    await next.lookUp()
                case .fetchRows:
                    await search?.fetchRows()
                }
            }
        }
        for word in ["freight", " invoice", " march"] {
            var typed = await search?.query ?? ""
            for character in word {
                typed.append(character)
                if typed.hasSuffix(" ") == false { await run(plan.typed(String(typed.drop { $0 == " " }), at: time)) }
                time += 0.2
                await run(plan.tick(at: time))
            }
            // A pause to think of the next word: more than 0.6 s, less than 1.5 s.
            time += 0.9
            await run(plan.tick(at: time))
            typed = ""
        }
        XCTAssertEqual(lookups, 3, "one lookup of ids after each word")
        XCTAssertEqual(transport.units[.messagesList], 15)
        XCTAssertEqual(transport.units[.messagesGet] ?? 0, 0, "no row's text was fetched while typing")
        XCTAssertEqual(transport.units[.threadsGet] ?? 0, 0)

        // Return fetches the text of the first hits, in one landing of at most 25.
        let rows = source.rows
        await run(plan.submitted(at: time))
        let hits = await search?.hitIDs ?? []
        XCTAssertEqual(hits.count, 40)
        let arrived = await arrivingKeys(rows, count: 25)
        XCTAssertEqual(arrived.count, 25)
        XCTAssertEqual(transport.units[.messagesGet], 25 * 20)
        XCTAssertEqual(transport.units[.messagesList], 15, "Return needed no new lookup")
    }

    func testTheRowsOfASearchAreTheIndexsOwnSoEveryActionWorksOnThem() async throws {
        let (transport, store, source) = try await mailbox()
        let search = GmailEngineSearch(query: "invoice", source: source, store: store, transport: transport)
        await search.lookUp()
        let snapshot = await source.snapshot(of: ListView(scope: .search(search.id), conversations: false))
        XCTAssertEqual(snapshot.rows.count, 40)
        let key = snapshot.rowKey(at: 0)
        XCTAssertEqual(key?.accountID, transport.accountID)
        XCTAssertEqual(key?.isGmail, true, "an engine row, keyed by its Gmail id, not a read-only server row")
    }

    func testOfflineTheSearchCoversTheMessagesKeptOnTheMac() async throws {
        let (transport, store, source) = try await mailbox()
        let kept = transport.messages.prefix(5)
        for m in kept {
            try await store.cache(GmailCachedMessage(id: m.ref.id, threadID: m.ref.threadID, from: EmailAddress(address: "ana@example.com"),
                                                     subject: m.headers.first { $0.name == "Subject" }!.value, preview: m.text,
                                                     date: m.date, size: m.size, hasAttachments: false, messageID: "", cachedAt: Date()),
                                  body: nil)
        }
        transport.failAlways(.messagesList, with: GoogleAPIError(kind: .offline))
        let search = GmailEngineSearch(query: "invoice", source: source, store: store, transport: transport)
        let hits = await search.lookUp()
        let fallback = await search.fallback
        XCTAssertEqual(fallback?.kind, .offline)
        XCTAssertEqual(Set(hits), Set(kept.filter { $0.headers.contains { $0.value.contains("invoice") } }.map(\.ref.id)))
    }

    func testThePlanWaitsForThreeCharactersAndAPause() {
        var plan = SearchTypingPlan()
        XCTAssertEqual(plan.typed("fr", at: 0), [.matchLocally("fr")])
        XCTAssertEqual(plan.tick(at: 2), [], "two characters ask nothing of Gmail")
        _ = plan.typed("fre", at: 2)
        XCTAssertEqual(plan.tick(at: 2.5), [])
        XCTAssertEqual(plan.nextDeadline, 2.6)
        XCTAssertEqual(plan.tick(at: 2.6), [.lookUpIDs("fre")])
        XCTAssertEqual(plan.tick(at: 3.0), [])
        XCTAssertEqual(plan.tick(at: 3.5), [.fetchRows("fre")])
        XCTAssertNil(plan.nextDeadline)
        _ = plan.typed("freight", at: 4)
        XCTAssertEqual(plan.submitted(at: 4.1), [.lookUpIDs("freight"), .fetchRows("freight")])
        XCTAssertEqual(plan.tick(at: 9), [])
    }
}
