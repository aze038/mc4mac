import Foundation

/// Conversation summaries: for each conversation with a message among the kept 1,000, its
/// senders, size and newest date, so its row paints from disk, at no cost and offline, and
/// expands without asking Gmail.
///
/// A summary is made from the kept rows when every message of the conversation is kept, and
/// otherwise by the engine from one `threads.get`. Kept messages keep it current: a new member
/// joins it when it is kept, a deleted one leaves it, and it goes when none of its conversation's
/// messages is kept any more.
final class GmailThreadSummaryStore {
    private let file: GmailRecordFile<GmailThreadSummary>
    private(set) var byThread: [UInt64: GmailThreadSummary] = [:]

    init(files: GmailFiles, io: GmailDiskIO) {
        file = GmailRecordFile(snapshot: files.threadSummaries, journal: files.threadSummariesJournal, io: io,
                               what: "Gmail conversation summaries")
    }

    /// Reads what was saved, keeping only conversations `keep` says still have a kept message.
    func load(keeping keep: (GmailThreadID) -> Bool) {
        var dropped: [String] = []
        for (key, summary) in file.load() {
            guard let thread = GmailThreadID(hex: key), thread == summary.threadID, keep(thread) else {
                dropped.append(key)
                continue
            }
            byThread[thread.raw] = summary
        }
        if !dropped.isEmpty { try? file.remove(dropped) }
    }

    func summaries(_ ids: [GmailThreadID]) -> [GmailThreadID: GmailThreadSummary] {
        var out: [GmailThreadID: GmailThreadSummary] = [:]
        for id in ids { out[id] = byThread[id.raw] }
        return out
    }

    func summary(_ id: GmailThreadID) -> GmailThreadSummary? { byThread[id.raw] }

    func save(_ summaries: [GmailThreadSummary]) throws {
        let changed = summaries.filter { byThread[$0.threadID.raw] != $0 }
        guard !changed.isEmpty else { return }
        for summary in changed {
            try file.set(summary.threadID.hex, summary)
            byThread[summary.threadID.raw] = summary
        }
    }

    func remove(_ ids: [GmailThreadID]) throws {
        let present = ids.filter { byThread[$0.raw] != nil }
        guard !present.isEmpty else { return }
        for id in present { byThread[id.raw] = nil }
        try file.remove(present.map(\.hex))
    }

    func compact() throws {
        try file.write(Dictionary(uniqueKeysWithValues: byThread.values.map { ($0.threadID.hex, $0) }))
    }

    var needsCompaction: Bool { file.shouldCompact(count: byThread.count) }
}

extension GmailThreadSummary {
    /// A summary made from a conversation's messages, when every one of them is at hand.
    static func made(from messages: [GmailCachedMessage]) -> GmailThreadSummary? {
        guard let first = messages.first else { return nil }
        let members = messages.map { GmailThreadMember(id: $0.id, from: $0.from, date: $0.date) }
            .sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        return GmailThreadSummary(threadID: first.threadID, senders: GmailThreadSummary.senders(of: members),
                                  messageCount: members.count, newestDate: members.last?.date ?? first.date, members: members)
    }

    /// The summary with `message` in it, as when new mail arrives in the conversation. Unchanged
    /// when it is already a member.
    func adding(_ message: GmailCachedMessage) -> GmailThreadSummary {
        guard !members.contains(where: { $0.id == message.id }) else { return self }
        var out = self
        let member = GmailThreadMember(id: message.id, from: message.from, date: message.date)
        let at = out.members.firstIndex { ($0.date, $0.id) > (member.date, member.id) } ?? out.members.count
        out.members.insert(member, at: at)
        out.messageCount = max(messageCount + 1, out.members.count)
        out.newestDate = max(newestDate, message.date)
        if members.isEmpty {
            if !out.senders.contains(where: { $0.address.caseInsensitiveCompare(message.from.address) == .orderedSame }) {
                out.senders.append(message.from)
            }
        } else {
            out.senders = GmailThreadSummary.senders(of: out.members)
        }
        return out
    }

    /// The summary without `id`, as when a message of the conversation is deleted; nil when
    /// nothing is left of it. Unchanged when `id` is not a member it lists.
    func removing(_ id: GmailMessageID) -> GmailThreadSummary? {
        guard let at = members.firstIndex(where: { $0.id == id }) else { return self }
        var out = self
        out.members.remove(at: at)
        out.messageCount = max(out.members.count, messageCount - 1)
        guard out.messageCount > 0 else { return nil }
        if !out.members.isEmpty {
            out.senders = GmailThreadSummary.senders(of: out.members)
            if out.members.count == out.messageCount, let last = out.members.last { out.newestDate = last.date }
        }
        return out
    }

    /// Each sender once, in the order they first wrote, oldest first.
    static func senders(of members: [GmailThreadMember]) -> [EmailAddress] {
        var seen = Set<String>()
        var out: [EmailAddress] = []
        for member in members where seen.insert(member.from.address.lowercased()).inserted {
            out.append(member.from)
        }
        return out
    }
}
