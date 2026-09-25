import Foundation

/// Checks, once, the Gmail behaviour the engine depends on that Google does not document, on the
/// owner's own test account only.
///
/// Nothing in the app runs it: it is started by hand, and it refuses to go on unless the account
/// it is signed in to is the one it was told to probe. Its read-only part changes nothing. Its
/// write part runs only when the owner has approved it: it works only on messages it makes
/// itself, under a label of its own, never touches existing mail, and deletes everything it made
/// at the end. It never looks for Google's limits on requests at the same time or on bandwidth,
/// since finding them means being refused.
///
/// The report holds counts, yes-or-no findings and timings; never a subject, an address or text.
public struct GmailProbe: Sendable {
    public struct Timing: Codable, Sendable, Equatable {
        public var samples: Int
        public var medianMilliseconds: Int
        public var p95Milliseconds: Int
    }

    public struct Report: Codable, Sendable, Equatable {
        // The read-only part.
        public var snippetWithMetadata: Bool?
        public var snippetWithThreads: Bool?
        public var listNewestFirst: Bool?
        public var listNewestFirstWithLabel: Bool?
        public var beforeEpochMatchesInternalDate: Bool?
        public var messageAddedCarriesLabels: Bool?
        /// Whether a message's attachment ids came back the same from two fetches during the run.
        public var attachmentIDsStable: Bool?
        /// Whether the first fetch's attachment id still worked at the end, and after how long.
        public var earlierAttachmentIDWorks: Bool?
        public var attachmentIDAgeSeconds: Int?
        /// The batch address that answered, and those that did not.
        public var batchAddress: String?
        public var batchAddressesRefused: [String] = []
        public var labelTotalsCountJunkAndDeleted: Bool?
        public var profileTotalCountsJunkAndDeleted: Bool?
        public var listReturnsChats: Bool?
        /// Inline pictures per message, as counts only: pictures → messages with that many.
        public var inlinePictures: [Int: Int] = [:]
        public var listPage: Timing?
        public var metadataBatchOf25: Timing?
        public var fullMessage: Timing?
        public var historyPage: Timing?

        // The write part, when approved.
        public var writesRan = false
        public var batchModifyTrashMatchesTrash: Bool?
        public var sendKeepsMessageID: Bool?
        public var sendKeepsAttemptHeader: Bool?
        public var draftKeepsMessageID: Bool?
        public var draftKeepsDraftHeader: Bool?
        /// Every message, draft and the label the write part made are gone again.
        public var cleanedUp: Bool?

        /// Units the probe spent, which it keeps small.
        public var units = 0
    }

    public enum Refusal: Error, Equatable {
        /// Signed in to another account than the test account named: nothing was asked of it.
        case notTheTestAccount
    }

    public static let labelName = "FalconMail probe"

    private let transport: GmailHTTPTransport
    private let testAccount: String
    private let writesApproved: Bool
    private let now: @Sendable () -> Date
    /// Mailboxes larger than this are not counted in full, to keep the probe's cost small.
    private let countLimit: Int
    private let work = WorkClass.interactive

    public init(transport: GmailHTTPTransport, testAccount: String, writesApproved: Bool = false, countLimit: Int = 60_000,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.testAccount = testAccount
        self.writesApproved = writesApproved
        self.countLimit = countLimit
        self.now = now
    }

    public func run() async throws -> Report {
        let profile = try await transport.profile(work: work)
        guard profile.emailAddress.caseInsensitiveCompare(testAccount) == .orderedSame else {
            Log.info("probe", "stopped: signed in to another account than the test account")
            throw Refusal.notTheTestAccount
        }
        var report = Report()
        let firstAttachment = await attachmentSample()
        await readOnly(into: &report, profile: profile)
        if let firstAttachment { await compareAttachment(firstAttachment, into: &report) }
        if writesApproved { await writes(into: &report) }
        report.units = await transport.usage().totalUnits
        Log.info("probe", "finished: \(report.units) units")
        return report
    }

    // MARK: The read-only part

    private func readOnly(into report: inout Report, profile: GmailProfile) async {
        let newest = (try? await transport.list(GmailListQuery(includeSpamTrash: false, maxResults: 50), work: work).refs) ?? []
        if let first = newest.first {
            let metadata = try? await transport.message(first.id, format: .row, work: work)
            report.snippetWithMetadata = metadata.map { $0.snippet != nil }
            let thread = try? await transport.thread(first.threadID, format: .row, work: work)
            report.snippetWithThreads = thread.map { ($0.messages ?? []).allSatisfy { $0.snippet != nil } }
        }
        report.listNewestFirst = await isNewestFirst(newest)
        let inbox = (try? await transport.list(GmailListQuery(labels: [.inbox], maxResults: 50), work: work).refs) ?? []
        report.listNewestFirstWithLabel = await isNewestFirst(inbox)
        report.beforeEpochMatchesInternalDate = await beforeMatches(newest)
        report.messageAddedCarriesLabels = await addedCarriesLabels(newest)
        (report.batchAddress, report.batchAddressesRefused) = await batchAddresses()
        report.labelTotalsCountJunkAndDeleted = await labelTotalsCountJunkAndDeleted()
        report.profileTotalCountsJunkAndDeleted = await profileTotalCountsJunkAndDeleted(profile)
        report.listReturnsChats = await listReturnsChats()
        report.inlinePictures = await inlinePictures(newest)
        await timings(into: &report, newest: newest)
    }

    private func dates(_ refs: [GmailRef]) async -> [Date]? {
        guard !refs.isEmpty else { return nil }
        let answers = try? await transport.batch(refs.map { .message($0.id, .minimal) }, work: work)
        guard let answers else { return nil }
        var out: [Date] = []
        for ref in refs {
            guard case .success(let answer)? = answers[.message(ref.id, .minimal)], let date = answer.message?.receivedDate else { return nil }
            out.append(date)
        }
        return out
    }

    private func isNewestFirst(_ refs: [GmailRef]) async -> Bool? {
        guard refs.count >= 2, let dates = await dates(refs) else { return nil }
        return zip(dates, dates.dropFirst()).allSatisfy { $0 >= $1 }
    }

    /// `before:` in epoch seconds just above a message's time finds it first, and just at it does not.
    private func beforeMatches(_ refs: [GmailRef]) async -> Bool? {
        guard refs.count >= 10, let dates = await dates(Array(refs.prefix(10))) else { return nil }
        let target = refs[5]
        let seconds = Int(dates[5].timeIntervalSince1970)
        let above = try? await transport.list(GmailListQuery(query: "before:\(seconds + 1)", maxResults: 10), work: work)
        let at = try? await transport.list(GmailListQuery(query: "before:\(seconds)", maxResults: 10), work: work)
        guard let above, let at else { return nil }
        let sameSecond = dates.contains { $0 != dates[5] && Int($0.timeIntervalSince1970) == seconds }
        guard !sameSecond else { return nil }
        return above.refs.contains(target) && !at.refs.contains(target)
    }

    private func addedCarriesLabels(_ refs: [GmailRef]) async -> Bool? {
        guard let oldest = refs.last,
              let message = try? await transport.message(oldest.id, format: .minimal, work: work),
              let history = message.history, history.raw > 1 else { return nil }
        let page = try? await transport.history(since: HistoryID(raw: history.raw - 1), types: [.messageAdded], label: nil,
                                                pageToken: nil, work: work)
        let added = page?.records.flatMap(\.messagesAdded) ?? []
        guard !added.isEmpty else { return nil }
        return added.allSatisfy { $0.labels != nil }
    }

    private func batchAddresses() async -> (String?, [String]) {
        var refused: [String] = []
        for url in transport.endpoints.batch {
            if await transport.probeBatchAddress(url, work: work) { return (url.absoluteString, refused) }
            refused.append(url.absoluteString)
        }
        return (nil, refused)
    }

    /// Every id of a list, or nil once there are more than the probe counts.
    private func allIDs(_ query: GmailListQuery) async -> Set<GmailMessageID>? {
        var query = query
        query.maxResults = 500
        var ids = Set<GmailMessageID>()
        repeat {
            guard let page = try? await transport.list(query, work: work) else { return nil }
            ids.formUnion(page.refs.map(\.id))
            guard ids.count <= countLimit else { return nil }
            query.pageToken = page.nextPageToken
        } while query.pageToken != nil
        return ids
    }

    /// Finds a label with a message in Deleted Items or Junk Email, and compares its
    /// `messagesTotal` with its listing with and without them.
    private func labelTotalsCountJunkAndDeleted() async -> Bool? {
        for place in [GmailLabelID.trash, .spam] {
            guard let page = try? await transport.list(GmailListQuery(labels: [place], maxResults: 20), work: work),
                  let answers = try? await transport.batch(page.refs.map { .message($0.id, .minimal) }, work: work) else { continue }
            let labels = answers.values.compactMap { try? $0.get().message?.labels }.flatMap { $0 }
            guard let label = labels.first(where: { $0.isUserLabel || $0 == .starred || $0 == .important }) else { continue }
            guard let counts = try? await transport.label(label, work: work), let total = counts.messagesTotal,
                  total <= countLimit,
                  let with = await allIDs(GmailListQuery(labels: [label], includeSpamTrash: true)),
                  let without = await allIDs(GmailListQuery(labels: [label], includeSpamTrash: false)),
                  with.count != without.count else { continue }
            if total == with.count { return true }
            if total == without.count { return false }
        }
        return nil
    }

    /// Compares `getProfile`'s total with the listing of everything with and without Junk Email
    /// and Deleted Items. Chats that the listing leaves out may be in the total either way, so
    /// both are allowed for.
    private func profileTotalCountsJunkAndDeleted(_ profile: GmailProfile) async -> Bool? {
        guard let total = profile.messagesTotal, total <= countLimit,
              let with = await allIDs(GmailListQuery(includeSpamTrash: true)),
              let without = await allIDs(GmailListQuery(includeSpamTrash: false)), with.count != without.count else { return nil }
        let chats = await allIDs(GmailListQuery(labels: [.chat], includeSpamTrash: true)) ?? []
        let unlisted = chats.subtracting(with).count
        if total == with.count || total == with.count + unlisted { return true }
        if total == without.count || total == without.count + unlisted { return false }
        return nil
    }

    /// Whether a chat, listed by its label, is also in the listing of everything around its time.
    private func listReturnsChats() async -> Bool? {
        guard let chats = try? await transport.list(GmailListQuery(labels: [.chat], maxResults: 5), work: work),
              let chat = chats.refs.first, let date = await dates([chat])?.first else { return nil }
        let seconds = Int(date.timeIntervalSince1970)
        let around = try? await transport.list(GmailListQuery(query: "after:\(seconds - 1) before:\(seconds + 2)", includeSpamTrash: true,
                                                              maxResults: 100), work: work)
        return around.map { $0.refs.contains(chat) }
    }

    private func inlinePictures(_ refs: [GmailRef]) async -> [Int: Int] {
        guard let answers = try? await transport.batch(refs.prefix(30).map { .message($0.id, .full) }, work: work) else { return [:] }
        var histogram: [Int: Int] = [:]
        for case .success(let answer) in answers.values {
            guard let payload = answer.message?.payload else { continue }
            histogram[GmailProbe.inlinePictureCount(payload), default: 0] += 1
        }
        return histogram
    }

    static func inlinePictureCount(_ part: GmailPart) -> Int {
        let own = (part.mimeType ?? "").lowercased().hasPrefix("image/") && part.header("Content-ID") != nil ? 1 : 0
        return own + (part.parts ?? []).reduce(0) { $0 + inlinePictureCount($1) }
    }

    private func timings(into report: inout Report, newest: [GmailRef]) async {
        func timing(_ samples: [TimeInterval]) -> Timing? {
            guard !samples.isEmpty else { return nil }
            let sorted = samples.sorted()
            let median = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
            return Timing(samples: sorted.count, medianMilliseconds: Int(median * 1000), p95Milliseconds: Int(p95 * 1000))
        }
        func measure(_ times: Int, _ body: () async throws -> Void) async -> [TimeInterval] {
            var out: [TimeInterval] = []
            for _ in 0..<times {
                let start = now()
                do {
                    try await body()
                    out.append(now().timeIntervalSince(start))
                } catch {
                    continue
                }
            }
            return out
        }
        report.listPage = timing(await measure(5) { _ = try await transport.list(GmailListQuery(includeSpamTrash: true), work: work) })
        let rows = Array(newest.prefix(25))
        if !rows.isEmpty {
            report.metadataBatchOf25 = timing(await measure(4) { _ = try await transport.batch(rows.map { .message($0.id, .row) }, work: work) })
        }
        if let first = newest.first {
            report.fullMessage = timing(await measure(10) { _ = try await transport.message(first.id, format: .full, work: work) })
        }
        if let history = try? await transport.profile(work: work).historyID {
            report.historyPage = timing(await measure(5) {
                _ = try await transport.history(since: history, types: Set(GmailHistoryType.allCases), label: nil, pageToken: nil, work: work)
            })
        }
    }

    // MARK: Attachment ids

    private struct AttachmentSample {
        var message: GmailMessageID
        var attachmentID: String
        var at: Date
    }

    private func attachmentSample() async -> AttachmentSample? {
        guard let page = try? await transport.list(GmailListQuery(query: "has:attachment", maxResults: 5), work: work) else { return nil }
        for ref in page.refs {
            guard let full = try? await transport.message(ref.id, format: .full, work: work),
                  let id = full.payload.flatMap(GmailProbe.firstAttachmentID) else { continue }
            return AttachmentSample(message: ref.id, attachmentID: id, at: now())
        }
        return nil
    }

    private static func firstAttachmentID(_ part: GmailPart) -> String? {
        if let id = part.body?.attachmentId, !(part.filename ?? "").isEmpty { return id }
        return (part.parts ?? []).lazy.compactMap(firstAttachmentID).first
    }

    private func compareAttachment(_ sample: AttachmentSample, into report: inout Report) async {
        let again = try? await transport.message(sample.message, format: .full, work: work)
        report.attachmentIDsStable = again?.payload.flatMap(GmailProbe.firstAttachmentID).map { $0 == sample.attachmentID }
        report.earlierAttachmentIDWorks = (try? await transport.attachment(sample.attachmentID, of: sample.message, work: work)) != nil
        report.attachmentIDAgeSeconds = Int(now().timeIntervalSince(sample.at))
    }

    // MARK: The write part

    private func writes(into report: inout Report) async {
        report.writesRan = true
        var made: [GmailMessageID] = []
        var draftID: String?
        var label: GmailLabelID?
        do {
            let probeLabel = try await ownLabel()
            label = probeLabel
            // Two messages of its own: one to Deleted Items by messages.trash, one by +TRASH.
            let a = try await transport.insertMessage(sample(subject: "trash"), labels: [probeLabel, .inbox], work: work)
            let b = try await transport.insertMessage(sample(subject: "batchModify"), labels: [probeLabel, .inbox], work: work)
            let ids = [a, b].compactMap(\.gmailID)
            made += ids
            if ids.count == 2 {
                let trashed = try await transport.trash(ids[0], work: work)
                try await transport.batchModify([ids[1]], adding: [.trash], removing: [], work: work)
                let modified = try await transport.message(ids[1], format: .minimal, work: work)
                report.batchModifyTrashMatchesTrash = trashed.labels == modified.labels
            }
            // One message sent to the account itself.
            let messageID = "<probe-\(UUID().uuidString.lowercased())@falconmail.invalid>"
            let attempt = UUID().uuidString.lowercased()
            let sent = try await transport.send(sample(subject: "send", messageID: messageID, extra: ["X-FalconMail-Attempt": attempt]),
                                                threadID: nil, work: work)
            if let id = sent.gmailID {
                made.append(id)
                _ = try? await transport.modify(id, adding: [probeLabel], removing: [], work: work)
                let headers = try await transport.message(id, format: .metadata(headers: ["Message-ID", "X-FalconMail-Attempt"]), work: work)
                report.sendKeepsMessageID = headers.header("Message-ID") == messageID
                report.sendKeepsAttemptHeader = headers.header("X-FalconMail-Attempt") == attempt
            }
            // One draft, created then updated.
            let draftMessageID = "<probe-draft-\(UUID().uuidString.lowercased())@falconmail.invalid>"
            let local = UUID().uuidString.lowercased()
            let draft = try await transport.createDraft(sample(subject: "draft", messageID: draftMessageID, extra: ["X-FalconMail-Draft": local]),
                                                        threadID: nil, work: work)
            draftID = draft.id
            let updated = try await transport.updateDraft(draft.id, raw: sample(subject: "draft, saved again", messageID: draftMessageID,
                                                                                extra: ["X-FalconMail-Draft": local]),
                                                          threadID: nil, work: work)
            if let id = updated.message?.gmailID {
                let headers = try await transport.message(id, format: .metadata(headers: ["Message-ID", "X-FalconMail-Draft"]), work: work)
                report.draftKeepsMessageID = headers.header("Message-ID") == draftMessageID
                report.draftKeepsDraftHeader = headers.header("X-FalconMail-Draft") == local
            }
        } catch {
            Log.info("probe", "the write part stopped early: \(GmailHTTPTransport.refusal(for: error).kind.rawValue)")
        }
        report.cleanedUp = await cleanUp(messages: made, draft: draftID, label: label)
    }

    /// Deletes what the write part made, and only that.
    private func cleanUp(messages: [GmailMessageID], draft: String?, label: GmailLabelID?) async -> Bool {
        var clean = true
        if let draft {
            do { try await transport.deleteDraft(draft, work: work) } catch { clean = false }
        }
        if !messages.isEmpty {
            do { try await transport.batchDelete(messages, work: work) } catch { clean = false }
        }
        if let label {
            do { try await transport.deleteLabel(label, work: work) } catch { clean = false }
        }
        return clean
    }

    private func ownLabel() async throws -> GmailLabelID {
        if let existing = try await transport.labels(work: work).first(where: { $0.name == GmailProbe.labelName }) {
            return existing.labelID
        }
        return try await transport.createLabel(named: GmailProbe.labelName, work: work).labelID
    }

    private func sample(subject: String, messageID: String? = nil, extra: [String: String] = [:]) -> Data {
        var lines = ["From: \(testAccount)", "To: \(testAccount)", "Subject: FalconMail probe: \(subject)",
                     "Date: \(RFC5322Date.format(now()))",
                     "Message-ID: \(messageID ?? "<probe-\(UUID().uuidString.lowercased())@falconmail.invalid>")", "MIME-Version: 1.0"]
        for (name, value) in extra.sorted(by: { $0.key < $1.key }) { lines.append("\(name): \(value)") }
        lines.append("Content-Type: text/plain; charset=UTF-8")
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\nMade by FalconMail's probe, and deleted by it at the end.\r\n").utf8)
    }
}

extension GmailHTTPTransport {
    /// Whether a batch address answers a one-part batch, asked of that address alone. Only the
    /// probe asks; the transport itself moves on from an address that answers 404.
    func probeBatchAddress(_ address: URL, work: WorkClass) async -> Bool {
        let request = GmailBatchRequest(parts: [.label(.inbox)], basePath: endpoints.base.path)
        let call = Call(.labelsGet, url: address, work: work, httpMethod: "POST", body: request.body, contentType: request.contentType,
                        booking: GmailBooking(work: work, calls: [.labelsGet: 1], direction: .download))
        guard let reply = try? await perform(call),
              let answers = try? GmailBatchResponse.parse(reply.data, contentType: reply.response.value(forHTTPHeaderField: "Content-Type")) else {
            return false
        }
        return answers.values.contains { $0.status == 200 }
    }
}
