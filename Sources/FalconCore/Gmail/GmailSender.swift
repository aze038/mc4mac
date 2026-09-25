import Foundation

/// Sends a switched Google account's mail with Gmail's own `messages.send`. There is no SMTP
/// for such an account, and no falling back to it (open question 10).
///
/// Nothing is ever sent twice. Gmail's records are read only to confirm that a message went,
/// never to allow sending it again: an answer that leaves it unclear is looked for in the
/// history twice by the Outbox, and held for the owner if it is not found (§8.2). Only a failure
/// that came before any byte reached Gmail is tried again by itself.
public struct GmailSender: MessageSender {
    public let accountID: UUID
    public let email: String
    private let transport: any GmailTransport
    private let placer: (any GmailUploadPlacing)?
    private let deleteDraft: (@Sendable (String) async throws -> Void)?
    private let cursor: @Sendable () async -> HistoryID?
    private let wentOut: @Sendable () async -> Void
    private let keepsOwnMessageID: Bool

    /// Names the attempt in the upload, so it can be found in Gmail's records even if Gmail
    /// replaces the Message-ID. It is added to the upload only; the .eml in the Outbox is left
    /// as `MIMEBuilder` built it.
    public static let attemptHeader = "X-FalconMail-Attempt"
    /// Gmail takes at most 25 MB of attachments in a message, counted before encoding [S18].
    public static let attachmentLimit = 25 * 1024 * 1024
    /// And at most 35 MB for the whole upload, encoded [S13].
    public static let uploadLimit = 35 * 1024 * 1024
    static let lookedForHeaders = ["Message-ID", "X-Google-Original-Message-ID", attemptHeader]
    /// More messages than this added to Sent in the minutes of one look means something else is
    /// sending in bulk; the look stops there rather than fetch them all.
    static let mostLookedAt = 200

    /// - Parameters:
    ///   - placer: puts the sent message into Sent at once, from Gmail's answer; the engine.
    ///   - deleteDraft: deletes the Gmail draft a message was written in once it has gone,
    ///     through the account's drafts so they forget it too. Without it the draft is deleted
    ///     here.
    ///   - cursor: the engine's position in the history, which is never later than Gmail's.
    ///   - wentOut: told once a message has gone, so the engine can look for its echo.
    ///   - keepsOwnMessageID: whether Gmail keeps FalconMail's Message-ID on what it sends, as
    ///     G1's probe finds. Until that is known, one metadata call reads Gmail's, so that the
    ///     copy kept in Sent carries it and later replies thread.
    public init(accountID: UUID, email: String, transport: any GmailTransport, placer: (any GmailUploadPlacing)? = nil,
                deleteDraft: (@Sendable (String) async throws -> Void)? = nil, cursor: @escaping @Sendable () async -> HistoryID?,
                wentOut: @escaping @Sendable () async -> Void, keepsOwnMessageID: Bool = false) {
        self.accountID = accountID
        self.email = email
        self.transport = transport
        self.placer = placer
        self.deleteDraft = deleteDraft
        self.cursor = cursor
        self.wentOut = wentOut
        self.keepsOwnMessageID = keepsOwnMessageID
    }

    // MARK: - MessageSender

    public func send(accountID: UUID, from: String, recipients: [String], message: Data) async throws {
        let item = OutboxItem(accountID: accountID, subject: "", recipients: recipients, sender: from, sendAt: Date(), undoWindow: 0)
        _ = try await send(await prepare(item, message: message), message: message)
    }

    public func prepare(_ item: OutboxItem, message: Data) async -> OutboxItem {
        var item = item
        if item.attemptID != nil, item.gmailSentID == nil, case .sent(let id) = await confirm(item) {
            // An earlier attempt failed in a way taken to mean it never reached Gmail, or the
            // owner is sending a held message again. A connection dropped during an upload can
            // look like the first, and Gmail can take a message in minutes after it was held, so
            // the earlier attempt is looked for before anything is sent again.
            item.gmailSentID = id ?? item.gmailSentID
            return item
        }
        item.attemptID = UUID()
        if item.messageID?.isEmpty ?? true {
            item.messageID = AddressParser.messageIDs(MIMEParser.parseHeaders(message).first("Message-ID")).first
        }
        if let known = await cursor() {
            item.preSendHistoryID = known
        } else {
            // Gmail's position now is no later than the send, so the look after it still sees
            // it. Without it, the look falls back to searching Sent by Message-ID.
            item.preSendHistoryID = try? await transport.profile(work: .interactive).historyID
        }
        return item
    }

    public func send(_ item: OutboxItem, message: Data) async throws -> OutboxItem {
        // Found in Gmail's records while the attempt was readied: it went already.
        if item.gmailSentID != nil { return item }
        let upload = try GmailSender.upload(message, for: item)
        let answer: GmailMessage
        do {
            answer = try await transport.send(upload, threadID: item.gmailThreadID, work: .interactive)
        } catch let refusal as GoogleAPIError where refusal.kind == .notFound && item.gmailThreadID != nil {
            // The conversation is gone from Gmail, which refused the send, so nothing went. It
            // goes on its own; its In-Reply-To and References still thread it for the recipients.
            do {
                answer = try await transport.send(upload, threadID: nil, work: .interactive)
            } catch {
                throw failure(error, item)
            }
        } catch {
            throw failure(error, item)
        }
        var sent = item
        sent.gmailSentID = GmailMessageID.fromGmail(answer.id, in: "messages.send")
        await placeSent(answer, upload: upload, item: item)
        await wentOut()
        return sent
    }

    public func confirm(_ item: OutboxItem) async -> SendConfirmation {
        do {
            if let start = item.preSendHistoryID {
                do {
                    let added = try await addedToSent(since: start)
                    return try await firstMatch(in: added, for: item).map { .sent($0) } ?? .notFound
                } catch let refusal as GoogleAPIError where refusal.kind == .historyExpired {
                    // Gmail no longer keeps the history that far back: Sent is searched instead.
                }
            }
            guard let wanted = GmailSender.bare(item.messageID) else { return .notFound }
            let page = try await transport.list(GmailListQuery(query: "rfc822msgid:\(wanted) in:sent", maxResults: 10), work: .interactive)
            return page.refs.first.map { .sent($0.id) } ?? .notFound
        } catch {
            Log.info("send", "\(email): could not look in Gmail's records for Outbox item \(item.id): \(error.localizedDescription)")
            return .lookFailed
        }
    }

    public func finish(_ item: OutboxItem) async -> OutboxItem {
        guard let draftID = item.gmailDraftID else { return item }
        var finished = item
        do {
            if let deleteDraft {
                try await deleteDraft(draftID)
            } else {
                try await transport.deleteDraft(draftID, work: .interactive)
            }
            finished.gmailDraftID = nil
        } catch let refusal as GoogleAPIError where refusal.kind == .notFound {
            // Already gone, sent or deleted from another device.
            finished.gmailDraftID = nil
        } catch {
            Log.info("send", "\(email): the draft of Outbox item \(item.id) was not deleted yet: \(error.localizedDescription)")
        }
        return finished
    }

    // MARK: - The upload

    /// The .eml as the Outbox keeps it, with the headers only Gmail's upload carries: the attempt,
    /// and Bcc. `MIMEBuilder` writes no Bcc, and Gmail takes the recipients from the headers; it
    /// leaves Bcc out of what it delivers and keeps it in the sender's Sent copy. Refused here,
    /// before anything is uploaded, if Gmail would refuse it for its size.
    static func upload(_ message: Data, for item: OutboxItem) throws -> Data {
        let parsed = MIMEParser.parse(message)
        let attached = parsed.attachments.reduce(0) { $0 + $1.size }
        if attached > attachmentLimit || message.count > uploadLimit {
            throw SendFailure(next: .fail, sentence: GmailSender.tooLargeSentence, code: "tooLarge")
        }
        let shown = Set((parsed.to + parsed.cc + AddressParser.parse(parsed.headers.first("Bcc"))).map { $0.address.lowercased() })
        var seen = Set<String>()
        let blind = item.recipients.filter { !shown.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
        var fields: [(name: String, value: String)] = []
        if let attempt = item.attemptID { fields.append((attemptHeader, attempt.uuidString.lowercased())) }
        var names: Set<String> = [attemptHeader]
        if !blind.isEmpty {
            let existing = AddressParser.parse(parsed.headers.first("Bcc")).map(\.address)
            fields.append(("Bcc", (existing + blind).joined(separator: ", ")))
            names.insert("Bcc")
        }
        return RawHeaders.setting(fields, removing: names, in: message)
    }

    static let tooLargeSentence = "Gmail can't send more than 25 MB of attachments in one message. Remove some, or share them from Google Drive."

    // MARK: - The Sent row

    private func placeSent(_ answer: GmailMessage, upload: Data, item: OutboxItem) async {
        guard let placer else { return }
        let labels = answer.labels.isEmpty ? [.sent] : answer.labels
        await placer.placeUploaded(answer, labels: labels, raw: upload, replacing: nil, messageID: nil)
        guard !keepsOwnMessageID, let id = GmailMessageID.fromGmail(answer.id, in: "messages.send") else { return }
        do {
            let read = try await transport.message(id, format: .metadata(headers: ["Message-ID"]), work: .interactive)
            if let gmails = read.header("Message-ID"), GmailSender.bare(gmails) != GmailSender.bare(item.messageID) {
                await placer.placeUploaded(answer, labels: labels, raw: upload, replacing: nil, messageID: gmails)
            }
        } catch {
            // The copy keeps FalconMail's Message-ID until the message is next fetched.
            Log.info("send", "\(email): could not read the Message-ID Gmail gave a sent message: \(error.localizedDescription)")
        }
    }

    // MARK: - Looking in Gmail's records

    private func addedToSent(since start: HistoryID) async throws -> [GmailMessageID] {
        var added: [GmailMessageID] = []
        var token: String?
        repeat {
            let page = try await transport.history(since: start, types: [.messageAdded], label: .sent, pageToken: token,
                                                   work: .interactive)
            for record in page.records {
                for m in record.messagesAdded where !added.contains(m.ref.id) { added.append(m.ref.id) }
            }
            token = page.nextPageToken
        } while token != nil && added.count < GmailSender.mostLookedAt
        return Array(added.prefix(GmailSender.mostLookedAt))
    }

    /// The first of `ids` that is this attempt, or this message: by the attempt header, by its
    /// Message-ID, or by the Message-ID Gmail may have kept aside when it gave one of its own.
    private func firstMatch(in ids: [GmailMessageID], for item: OutboxItem) async throws -> GmailMessageID? {
        let wanted = GmailSender.bare(item.messageID)
        let attempt = item.attemptID?.uuidString.lowercased()
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + 25, ids.count)])
            let parts = chunk.map { GmailBatchPart.message($0, .metadata(headers: GmailSender.lookedForHeaders)) }
            let answers = try await transport.batch(parts, work: .interactive)
            for (id, part) in zip(chunk, parts) {
                // A part Gmail could not answer, such as a message deleted since, is not this one.
                guard case .success(let answer)? = answers[part], let m = answer.message else { continue }
                if let attempt, m.header(GmailSender.attemptHeader)?.trimmed.lowercased() == attempt { return id }
                if let wanted, GmailSender.bare(m.header("Message-ID")) == wanted { return id }
                if let wanted, GmailSender.bare(m.header("X-Google-Original-Message-ID")) == wanted { return id }
            }
            start += 25
        }
        return nil
    }

    /// A Message-ID without its angle brackets, lower-cased, as Gmail's `rfc822msgid:` takes it.
    static func bare(_ messageID: String?) -> String? {
        guard let text = messageID?.trimmed, !text.isEmpty else { return nil }
        let inner = AddressParser.messageIDs(text).first.map { String($0.dropFirst().dropLast()) } ?? text
        let bare = inner.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased()
        return bare.isEmpty ? nil : bare
    }

    // MARK: - What a failure means

    /// What the Outbox must do after `error`. Only a failure that came before any byte reached
    /// Gmail is sent again by itself; a refusal is Gmail's answer, so it did not go either; and
    /// anything else may have gone, and is only ever confirmed.
    func failure(_ error: Error, _ item: OutboxItem) -> SendFailure {
        switch error {
        case let local as SendFailure:
            return local
        case is CancellationError:
            // Stopped mid-flight, as at quit: Gmail may have it.
            return SendFailure(next: .confirm, sentence: "", code: "cancelled")
        case let refusal as GoogleAPIError:
            return failure(refusal, item)
        default:
            return SendFailure(next: .confirm, sentence: "", code: "network")
        }
    }

    private func failure(_ refusal: GoogleAPIError, _ item: OutboxItem) -> SendFailure {
        func wait(_ seconds: TimeInterval) -> Date { Date().addingTimeInterval(max(1, seconds)) }
        func at(_ date: Date) -> String { GoogleAPIError.timeText(date) }
        switch refusal.kind {
        case .offline where refusal.delivery == .unknown:
            // The connection was there and dropped during the upload: Gmail may have the message.
            return SendFailure(next: .confirm, sentence: "", cause: refusal)
        case .offline:
            // No connection could be made, so Gmail never saw the message.
            return SendFailure(next: .retry, sentence: "FalconMail couldn't reach Gmail. It sends the message by itself once it can.",
                               cause: refusal)
        case .temporary:
            return SendFailure(next: .confirm, sentence: "", cause: refusal)
        case .rateLimited:
            let until = wait(refusal.retryAfter ?? 60)
            return SendFailure(next: .wait(until: until),
                               sentence: "Gmail asked FalconMail to wait before sending from \(email). The message goes at \(at(until)).",
                               cause: refusal)
        case .sendingLimit:
            let sentence = "Gmail's daily sending limit for \(email) was reached. The message stays in the Outbox."
            guard let seconds = refusal.retryAfter else { return SendFailure(next: .hold, sentence: sentence, cause: refusal) }
            return SendFailure(next: .wait(until: wait(seconds)), sentence: sentence, cause: refusal)
        case .uploadLimit:
            // Gmail's upload allowance is shared by every app using the account, an import in
            // olm2cloud among them, and a refusal can last hours.
            let until = wait(refusal.retryAfter ?? 3_600)
            return SendFailure(next: .wait(until: until),
                               sentence: "Gmail has paused uploads for \(email) until \(at(until)); an import may be using the allowance. The message stays in the Outbox.",
                               cause: refusal)
        case .downloadLimit:
            let until = wait(refusal.retryAfter ?? 3_600)
            return SendFailure(next: .wait(until: until), sentence: "Gmail asked FalconMail to wait until \(at(until)). The message stays in the Outbox.",
                               cause: refusal)
        case .quotaExhausted:
            let until = GoogleAPIError.quotaReset()
            return SendFailure(next: .wait(until: until),
                               sentence: "Today's Gmail allowance for FalconMail is used up until \(at(until)). The message stays in the Outbox and goes then.",
                               cause: refusal)
        case .apiDisabled:
            return SendFailure(next: .wait(until: wait(600)),
                               sentence: "Google has turned off FalconMail's access to Gmail for now. FalconMail will try again later. The message stays in the Outbox.", cause: refusal)
        case .tooLarge:
            return SendFailure(next: .fail, sentence: GmailSender.tooLargeSentence, cause: refusal)
        case .needsSignIn:
            return SendFailure(next: .fail, sentence: "\(email) needs you to sign in again. Then send the message again.", cause: refusal)
        case .clientRejected:
            return SendFailure(next: .fail, sentence: "Google didn't accept FalconMail's sign-in for \(email). Sign in again, then send the message again.",
                               cause: refusal)
        case .insufficientPermissions:
            return SendFailure(next: .fail, sentence: "FalconMail was not given permission to send from \(email) through Gmail. Sign in again to allow it.",
                               cause: refusal)
        case .domainPolicy:
            return SendFailure(next: .fail, sentence: "The Workspace administrator has turned off Gmail access for apps like FalconMail for \(email).",
                               cause: refusal)
        case .gmailNotEnabled:
            return SendFailure(next: .fail, sentence: "Gmail isn't turned on for \(email).", cause: refusal)
        case .notFound, .historyExpired:
            return SendFailure(next: .fail, sentence: "Gmail refused this message. Details are in the log.", cause: refusal)
        case .other:
            guard (400..<500).contains(refusal.httpStatus) else {
                // No answer from Gmail that says what became of it.
                return SendFailure(next: .confirm, sentence: "", cause: refusal)
            }
            if let address = GmailSender.unlikelyAddress(in: item.recipients) {
                return SendFailure(next: .fail, sentence: "Gmail refused the address \(address).", cause: refusal)
            }
            return SendFailure(next: .fail, sentence: "Gmail refused this message. Details are in the log.", cause: refusal)
        }
    }

    /// The first recipient that cannot be an address, which is what Gmail's 400 on a send
    /// usually means. Gmail's own words are never read to find it.
    static func unlikelyAddress(in recipients: [String]) -> String? {
        recipients.first { address in
            let parts = address.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else {
                return true
            }
            return address.contains { $0.isWhitespace || "<>(),;:\"[]\\".contains($0) }
        }
    }
}

/// Header fields of a whole message, changed without touching anything else in it: the body,
/// its encoding and its line endings stay byte for byte as they were.
enum RawHeaders {
    /// `raw` with every top-level field named in `removing` taken out, continuation lines and
    /// all, and `fields` put first.
    static func setting(_ fields: [(name: String, value: String)], removing names: Set<String>, in raw: Data) -> Data {
        let dropped = Set(names.map { $0.lowercased() })
        let end = headerEnd(raw)
        var out = Data()
        for field in fields { out.append(Data("\(field.name): \(field.value)\r\n".utf8)) }
        var dropping = false
        var lineStart = raw.startIndex
        while lineStart < end {
            let lineEnd = raw[lineStart..<end].firstIndex(of: 0x0A).map { $0 + 1 } ?? end
            let first = raw[lineStart]
            if first == 0x20 || first == 0x09 {
                if !dropping { out.append(raw[lineStart..<lineEnd]) }
            } else {
                let colon = raw[lineStart..<lineEnd].firstIndex(of: 0x3A)
                let name = colon.map { String(decoding: raw[lineStart..<$0], as: UTF8.self).trimmed.lowercased() } ?? ""
                dropping = dropped.contains(name)
                if !dropping { out.append(raw[lineStart..<lineEnd]) }
            }
            lineStart = lineEnd
        }
        out.append(raw[end...])
        return out
    }

    /// Where the header ends: just after the line break of its last field, so the blank line
    /// and the body follow.
    static func headerEnd(_ raw: Data) -> Data.Index {
        if raw.starts(with: [0x0D, 0x0A]) || raw.starts(with: [0x0A]) { return raw.startIndex }
        let crlf = raw.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))
        let lf = raw.range(of: Data([0x0A, 0x0A]))
        switch (crlf, lf) {
        case let (c?, l?): return min(c.lowerBound + 2, l.lowerBound + 1)
        case let (c?, nil): return c.lowerBound + 2
        case let (nil, l?): return l.lowerBound + 1
        default: return raw.endIndex
        }
    }
}
