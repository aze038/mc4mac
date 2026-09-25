import Foundation

// Muted conversations of a Google account. They stay in `muted.json` as v1.10.0 keeps them, and
// are never rewritten: a record made before the switch keeps its IMAP thread key, and a second
// record for the same conversation would make Unmute leave its twin behind. New Gmail mail is
// matched to a record by its Gmail thread (`gm:<threadHex>`), or by its Message-ID and References
// against the record's message ids, which the fetch of new mail already gives. Unmute removes
// every record of the account that matches the conversation either way.

extension GmailActions {
    /// Records the conversations of `ids` as muted, from what the Mac already knows so the rows
    /// change at once. Returns the thread keys of conversations that were not muted before, which
    /// Undo unmutes again. A conversation none of whose messages is kept on the Mac is recorded by
    /// its thread alone, and its subject and Message-ID are filled in afterwards.
    func mute(_ ids: [GmailMessageID], snapshot: GmailIndexSnapshot) async -> [String] {
        let threads = GmailActions.threads(of: ids, in: snapshot)
        guard !threads.isEmpty else { return [] }
        let existing = await mutes.all()
        var added: [String] = []
        var needDetails: [(thread: GmailThreadID, message: GmailMessageID)] = []
        for (thread, members) in threads {
            let key = thread.threadKey
            let cached = await store.cachedMessages(members)
            let newest = cached.values.max { ($0.date, $0.id) < ($1.date, $1.id) }
            let messageIDs = Set(cached.values.map(\.messageID).filter { !$0.isEmpty })
            let subject = newest?.subject ?? ""
            let already = existing.contains { $0.accountID == accountID && $0.threadKey == key }
            await mutes.mute(MutedThread(accountID: accountID, threadKey: key, messageIDs: messageIDs,
                                         normalizedSubject: ConversationThreader.normalizedSubject(subject), subject: subject,
                                         mutedAt: clock.now()))
            if !already { added.append(key) }
            if cached.isEmpty, let first = members.first { needDetails.append((thread, first)) }
        }
        if !needDetails.isEmpty {
            awaitingMuteDetails.formUnion(needDetails.map(\.thread.threadKey))
            Task { await self.fillMuteDetails(needDetails) }
        }
        return added
    }

    /// The subject and Message-IDs of muted conversations the Mac keeps nothing of, so the muted
    /// list can name them and replies that start a new Gmail thread are still caught.
    private func fillMuteDetails(_ wanted: [(thread: GmailThreadID, message: GmailMessageID)]) async {
        for (thread, message) in wanted {
            guard let answer = try? await transport.message(message, format: .metadata(headers: GmailActions.muteHeaders),
                                                            work: .interactive) else {
                awaitingMuteDetails.remove(thread.threadKey)
                continue
            }
            let subject = RFC2047.decode(answer.header("Subject") ?? "")
            let ids = GmailActions.messageIDs(of: answer)
            // Only if it is still muted: an Undo in the meantime must not bring the record back.
            guard awaitingMuteDetails.remove(thread.threadKey) != nil else { continue }
            await mutes.mute(MutedThread(accountID: accountID, threadKey: thread.threadKey, messageIDs: ids,
                                         normalizedSubject: ConversationThreader.normalizedSubject(subject), subject: subject,
                                         mutedAt: clock.now()))
        }
    }

    /// Unmutes the conversations of `ids`: every record of the account whose thread key or
    /// message ids match, so no twin record keeps the conversation muted. Returns how many
    /// conversations had a record.
    func unmute(_ ids: [GmailMessageID], snapshot: GmailIndexSnapshot) async -> Int {
        let threads = GmailActions.threads(of: ids, in: snapshot)
        guard !threads.isEmpty else { return 0 }
        var unmuted = 0
        for (thread, members) in threads {
            var messageIDs = Set(await store.cachedMessages(members).values.map(\.messageID).filter { !$0.isEmpty })
            if messageIDs.isEmpty, let first = members.first,
               let answer = try? await transport.message(first, format: .metadata(headers: GmailActions.muteHeaders),
                                                         work: .interactive) {
                messageIDs = GmailActions.messageIDs(of: answer)
            }
            let records = await mutes.all().filter { record in
                record.accountID == accountID
                    && (record.threadKey == thread.threadKey || !record.messageIDs.isDisjoint(with: messageIDs))
            }
            for record in records {
                awaitingMuteDetails.remove(record.threadKey)
                await mutes.unmute(accountID: accountID, threadKey: record.threadKey)
            }
            if !records.isEmpty { unmuted += 1 }
        }
        return unmuted
    }

    /// Undo of a Mute: the records this change added go again. A conversation that was muted
    /// before stays muted.
    func unmuteAdded(_ op: PendingGmailOp) async {
        for key in op.mutedThreadKeys {
            awaitingMuteDetails.remove(key)
            await mutes.unmute(accountID: accountID, threadKey: key)
        }
    }

    /// New mail that belongs to a muted conversation. Its Message-ID is remembered with the
    /// record, so a reply to it that Gmail files in a new thread is caught too.
    func mutedArrivals(_ arrivals: [GmailArrival]) async -> [GmailArrival] {
        let records = await mutes.all()
        guard !records.isEmpty else { return [] }
        var muted: [GmailArrival] = []
        for arrival in arrivals {
            guard let hit = MuteStore.match(in: records, accountID: accountID, threadKey: arrival.ref.threadID.threadKey,
                                            messageID: arrival.messageID, references: arrival.references,
                                            inReplyTo: arrival.inReplyTo) else { continue }
            muted.append(arrival)
            await mutes.remember(messageID: arrival.messageID, accountID: hit.accountID, threadKey: hit.threadKey)
        }
        return muted
    }

    static let muteHeaders = ["Subject", "Message-ID", "In-Reply-To", "References"]

    static func messageIDs(of message: GmailMessage) -> Set<String> {
        let own = AddressParser.messageIDs(message.header("Message-ID"))
        let parents = AddressParser.messageIDs(message.header("In-Reply-To")) + AddressParser.messageIDs(message.header("References"))
        return Set((own + parents).filter { !$0.isEmpty })
    }

    /// The conversations `ids` belong to, each with every member the index holds, newest first,
    /// for finding what the Mac keeps of them.
    static func threads(of ids: [GmailMessageID], in snapshot: GmailIndexSnapshot) -> [(GmailThreadID, [GmailMessageID])] {
        var order: [UInt64] = []
        var wanted: Set<UInt64> = []
        var fallback: [UInt64: GmailMessageID] = [:]
        for id in ids {
            guard let record = snapshot.record(for: id) else { continue }
            if wanted.insert(record.threadID).inserted {
                order.append(record.threadID)
                fallback[record.threadID] = id
            }
        }
        guard !order.isEmpty else { return [] }
        var members: [UInt64: [GmailMessageID]] = [:]
        for slot in snapshot.byOrder.reversed() {
            let record = snapshot.records[Int(slot)]
            guard wanted.contains(record.threadID) else { continue }
            members[record.threadID, default: []].append(record.gmailID)
        }
        return order.map { thread in
            (GmailThreadID(raw: thread), members[thread] ?? fallback[thread].map { [$0] } ?? [])
        }
    }
}
