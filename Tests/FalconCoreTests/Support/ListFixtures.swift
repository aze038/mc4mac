import Foundation
@testable import FalconCore

/// Indexes built straight in memory for the list's tests: a store would take seconds to place
/// 200,000 messages one by one, and the list only ever reads the index's immutable snapshot.
enum ListFixtures {
    static let baseID: UInt64 = 0x18a0_0000_0000_0000

    struct Message {
        var labels: Set<GmailLabelID>
        var thread: Int
        var attributes: GmailRecordAttributes = []
    }

    /// An index of `messages`, newest first: the first is the newest in the account's order.
    static func index(_ messages: [Message], userSlots: [GmailLabelID: Int] = [:],
                      overflow: [GmailLabelID: Set<Int>] = [:]) -> GmailIndexSnapshot {
        var slots = Dictionary(uniqueKeysWithValues: GmailLabelID.fixedSlots.enumerated().map { ($0.element, $0.offset) })
        slots.merge(userSlots) { a, _ in a }
        var records = ContiguousArray<GmailIndexRecord>()
        records.reserveCapacity(messages.count)
        var slotByID: [UInt64: Int32] = [:]
        slotByID.reserveCapacity(messages.count)
        let count = messages.count
        for (i, m) in messages.enumerated() {
            var bits: UInt64 = 0
            for label in m.labels { if let slot = slots[label] { bits |= 1 << UInt64(slot) } }
            let id = id(i)
            records.append(GmailIndexRecord(id: id, threadID: GmailThreadID(raw: baseID + UInt64(m.thread) * 16 + 1),
                                            labelBits: bits, order: UInt32(count - i) * GmailIndexRecord.orderStep,
                                            attributes: m.attributes))
            slotByID[id.raw] = Int32(i)
        }
        let byOrder = ContiguousArray((0..<Int32(count)).reversed())
        var lists: [GmailLabelID: ContiguousArray<Int32>] = [:]
        for (label, members) in overflow { lists[label] = ContiguousArray(members.sorted().map(Int32.init)) }
        return GmailIndexSnapshot(records: records, byOrder: byOrder, slotByID: slotByID, labelSlots: slots, overflow: lists)
    }

    static func id(_ i: Int) -> GmailMessageID { GmailMessageID(raw: baseID + UInt64(i) * 16) }

    /// A large mailbox as the owner's looks: 40% of the mail in two-message conversations, a
    /// third in the Inbox with its categories, a tenth unread, some flagged, sent, junk and
    /// deleted.
    static func large(_ count: Int = 200_000) -> [Message] {
        var out: [Message] = []
        out.reserveCapacity(count)
        let paired = count * 2 / 5
        for i in 0..<count {
            var labels: Set<GmailLabelID> = []
            switch i % 10 {
            case 0, 1, 2: labels.insert(.inbox)
            case 3: labels.insert(.sent)
            default: break
            }
            if i % 100 == 7 { labels = [.trash] }
            if i % 100 == 8 { labels = [.spam] }
            if i % 10 == 1 { labels.insert(.unread) }
            if i % 50 == 2 { labels.insert(.starred) }
            if labels.contains(.inbox) { labels.insert(i % 3 == 0 ? .categoryPromotions : .categoryPersonal) }
            let thread = i < paired ? i / 2 : paired / 2 + (i - paired)
            out.append(Message(labels: labels, thread: thread))
        }
        return out
    }

    static func account(_ index: GmailIndexSnapshot, id: UUID = UUID(), email: String = "owner@example.com",
                        labels: [GmailLabelEntry]? = nil, archive: UUID = UUID(), anchors: [GmailDateAnchor] = [],
                        complete: Bool = true, total: Int? = nil) -> ListIndexAccount {
        ListIndexAccount(accountID: id, email: email, index: index, labels: labels ?? systemLabels(), archiveFolderID: archive,
                         allMailComplete: complete, allMailTotal: total, anchors: anchors, attachmentsKnown: true,
                         sizesKnown: true)
    }

    static let folderIDs: [GmailLabelID: UUID] = Dictionary(uniqueKeysWithValues: GmailLabelID.fixedSlots.map { ($0, UUID()) })

    static func systemLabels() -> [GmailLabelEntry] {
        GmailLabelID.fixedSlots.enumerated().map { i, label in
            GmailLabelEntry(id: label, name: label.value, kind: .system, isShown: true, folderID: folderIDs[label]!, slot: i,
                            isComplete: true)
        }
    }
}

/// The first value of `stream` that `matches`, or nil after `timeout` seconds, so a test whose
/// change never comes fails instead of waiting for ever.
func firstValue<T: Sendable>(of stream: AsyncStream<T>, timeout: TimeInterval = 5,
                             where matches: @escaping @Sendable (T) -> Bool = { _ in true }) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await value in stream where matches(value) { return value }
            return nil
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// The keys of rows arriving on `stream` until there are `count`, or `timeout` seconds pass.
func arrivingKeys(_ stream: AsyncStream<[RowKey: MessageRowContent]>, count: Int, timeout: TimeInterval = 5) async -> Set<RowKey> {
    await withTaskGroup(of: Set<RowKey>?.self) { group in
        group.addTask {
            var keys = Set<RowKey>()
            for await rows in stream {
                keys.formUnion(rows.keys)
                if keys.count >= count { return keys }
            }
            return keys
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? []
    }
}
