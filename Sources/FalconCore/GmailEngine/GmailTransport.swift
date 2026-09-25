import Foundation

/// Every Gmail API call the Gmail engine makes, for one account.
///
/// Each call names its class of work, which decides its place in the account's budget. Each books
/// its units before it is sent, and a batch books each of its parts, since Google counts every
/// part as a call. Everything thrown is a `GoogleAPIError`, classified from typed values only, or
/// a cancellation. Ids that Gmail sends and that do not parse are logged and left out, never
/// passed on.
public protocol GmailTransport: AnyObject, Sendable {
    var accountID: UUID { get }

    // MARK: The account

    /// The address, the totals and the history id to start from.
    func profile(work: WorkClass) async throws -> GmailProfile
    func labels(work: WorkClass) async throws -> [GmailLabel]
    /// One label with its counts.
    func label(_ id: GmailLabelID, work: WorkClass) async throws -> GmailLabel
    func createLabel(named name: String, work: WorkClass) async throws -> GmailLabel
    /// The addresses the account may send as, all of which count as the owner's own.
    func sendAs(work: WorkClass) async throws -> [GmailSendAs]

    // MARK: Reading

    /// One page of message ids, newest first.
    func list(_ query: GmailListQuery, work: WorkClass) async throws -> GmailListPage
    /// One page of changes after `start`. Throws `.historyExpired` when Gmail no longer keeps
    /// history that far back.
    func history(since start: HistoryID, types: Set<GmailHistoryType>, label: GmailLabelID?,
                 pageToken: String?, work: WorkClass) async throws -> GmailHistoryPage
    func message(_ id: GmailMessageID, format: GmailFormat, work: WorkClass) async throws -> GmailMessage
    func thread(_ id: GmailThreadID, format: GmailFormat, work: WorkClass) async throws -> GmailThread
    /// Many reads in HTTP batches, each part answered on its own: a message Gmail no longer has
    /// is that part's `.notFound`, and the rest still arrive. It throws only when the whole call
    /// failed, and then the error stands for every part.
    func batch(_ parts: [GmailBatchPart], work: WorkClass) async throws -> [GmailBatchPart: Result<GmailBatchAnswer, GoogleAPIError>]
    func attachment(_ attachmentID: String, of message: GmailMessageID, work: WorkClass) async throws -> Data

    // MARK: Changing

    /// Returns the message with the labels it has now.
    func modify(_ id: GmailMessageID, adding: Set<GmailLabelID>, removing: Set<GmailLabelID>,
                work: WorkClass) async throws -> GmailMessage
    /// At most 1,000 ids a call.
    func batchModify(_ ids: [GmailMessageID], adding: Set<GmailLabelID>, removing: Set<GmailLabelID>,
                     work: WorkClass) async throws
    /// Deletes for good, with nothing kept in Deleted Items. At most 1,000 ids a call.
    func batchDelete(_ ids: [GmailMessageID], work: WorkClass) async throws
    func trash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage
    func untrash(_ id: GmailMessageID, work: WorkClass) async throws -> GmailMessage

    // MARK: Uploading

    /// Sends an RFC 822 message. Gmail answers with its id, thread and labels.
    func send(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailMessage
    func importMessage(_ raw: Data, labels: Set<GmailLabelID>, options: GmailImportOptions,
                       work: WorkClass) async throws -> GmailMessage
    func createDraft(_ raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft
    /// Gmail gives the draft a new message id at every update and deletes the old one.
    func updateDraft(_ draftID: String, raw: Data, threadID: GmailThreadID?, work: WorkClass) async throws -> GmailDraft
    /// For good: Gmail keeps nothing in Deleted Items.
    func deleteDraft(_ draftID: String, work: WorkClass) async throws
    func drafts(pageToken: String?, work: WorkClass) async throws -> GmailDraftList

    // MARK: The budget

    /// Another app is importing into the account, which shares Google's per-user budget: stay
    /// lower until it stops.
    func setFloodMode(_ on: Bool) async
    /// Background work takes less while the owner is doing something.
    func noteOwnerActivity(at date: Date) async
    /// Until when Google has asked FalconMail to wait, and why; nil when it has not.
    func pause() async -> GmailPause?
    /// Units, calls and bytes so far, for the daily report.
    func usage() async -> GmailUsage
}

/// How much of a message a read returns.
public enum GmailFormat: Hashable, Sendable {
    /// Ids, labels, dates and size only.
    case minimal
    /// The named headers and the snippet.
    case metadata(headers: [String])
    /// The structure with the text parts; attachments come as ids only.
    case full
    /// The whole RFC 822 message.
    case raw

    /// What a list row needs.
    public static let row = GmailFormat.metadata(headers: GmailAPIClient.rowHeaders)
}

public struct GmailListQuery: Hashable, Sendable {
    /// A message must carry every one of these.
    public var labels: [GmailLabelID]
    /// Gmail search syntax. Dates are given in epoch seconds, which Gmail reads exactly; a date
    /// such as 2026/09/25 would be read as midnight Pacific time.
    public var query: String?
    public var includeSpamTrash: Bool
    public var maxResults: Int
    public var pageToken: String?

    public init(labels: [GmailLabelID] = [], query: String? = nil, includeSpamTrash: Bool = false,
                maxResults: Int = 500, pageToken: String? = nil) {
        self.labels = labels
        self.query = query
        self.includeSpamTrash = includeSpamTrash
        self.maxResults = maxResults
        self.pageToken = pageToken
    }
}

public struct GmailListPage: Hashable, Sendable {
    /// Newest first.
    public var refs: [GmailRef]
    /// Nil on the last page.
    public var nextPageToken: String?
    public var resultSizeEstimate: Int
    /// Ids on the page that did not parse, which a count check has to allow for.
    public var refusedIDs: Int

    public init(refs: [GmailRef], nextPageToken: String? = nil, resultSizeEstimate: Int = 0, refusedIDs: Int = 0) {
        self.refs = refs
        self.nextPageToken = nextPageToken
        self.resultSizeEstimate = resultSizeEstimate
        self.refusedIDs = refusedIDs
    }
}

public enum GmailHistoryType: String, Hashable, Sendable, CaseIterable {
    case messageAdded, messageDeleted, labelAdded, labelRemoved
}

/// One history record, as Gmail writes them: records come in the order the changes were made,
/// and one page can add a message and delete it again.
public struct GmailHistoryRecord: Hashable, Sendable {
    public var id: HistoryID
    public var messagesAdded: [GmailHistoryMessage]
    public var messagesDeleted: [GmailHistoryMessage]
    public var labelsAdded: [GmailLabelChange]
    public var labelsRemoved: [GmailLabelChange]

    public init(id: HistoryID, messagesAdded: [GmailHistoryMessage] = [], messagesDeleted: [GmailHistoryMessage] = [],
                labelsAdded: [GmailLabelChange] = [], labelsRemoved: [GmailLabelChange] = []) {
        self.id = id
        self.messagesAdded = messagesAdded
        self.messagesDeleted = messagesDeleted
        self.labelsAdded = labelsAdded
        self.labelsRemoved = labelsRemoved
    }

    public var isEmpty: Bool {
        messagesAdded.isEmpty && messagesDeleted.isEmpty && labelsAdded.isEmpty && labelsRemoved.isEmpty
    }
}

public struct GmailHistoryMessage: Hashable, Sendable {
    public var ref: GmailRef
    /// The message's labels when Gmail gives them. Whether it does for every added message is
    /// not documented, so nothing may count on it.
    public var labels: [GmailLabelID]?

    public init(ref: GmailRef, labels: [GmailLabelID]? = nil) {
        self.ref = ref
        self.labels = labels
    }
}

public struct GmailLabelChange: Hashable, Sendable {
    public var message: GmailHistoryMessage
    /// The labels added or removed by this change.
    public var labels: [GmailLabelID]

    public init(message: GmailHistoryMessage, labels: [GmailLabelID]) {
        self.message = message
        self.labels = labels
    }
}

public struct GmailHistoryPage: Hashable, Sendable {
    public var records: [GmailHistoryRecord]
    public var nextPageToken: String?
    /// The mailbox's history id when Gmail answered. Once every page is applied, the cursor
    /// moves here, past changes of kinds that were not asked for.
    public var historyID: HistoryID

    public init(records: [GmailHistoryRecord], nextPageToken: String? = nil, historyID: HistoryID) {
        self.records = records
        self.nextPageToken = nextPageToken
        self.historyID = historyID
    }
}

/// One part of an HTTP batch.
public enum GmailBatchPart: Hashable, Sendable {
    case message(GmailMessageID, GmailFormat)
    case thread(GmailThreadID, GmailFormat)
    /// `labels.get`, with the label's counts.
    case label(GmailLabelID)

    public var method: GmailMethod {
        switch self {
        case .message: return .messagesGet
        case .thread: return .threadsGet
        case .label: return .labelsGet
        }
    }
}

public enum GmailBatchAnswer: Sendable {
    case message(GmailMessage)
    case thread(GmailThread)
    case label(GmailLabel)

    public var message: GmailMessage? {
        if case .message(let m) = self { return m }
        return nil
    }

    public var thread: GmailThread? {
        if case .thread(let t) = self { return t }
        return nil
    }

    public var label: GmailLabel? {
        if case .label(let l) = self { return l }
        return nil
    }
}

/// How `messages.import` files a message.
public struct GmailImportOptions: Hashable, Sendable {
    public enum DateSource: String, Hashable, Sendable {
        /// From the message's own Date header, so old mail sorts among old mail.
        case dateHeader
        case receivedTime
    }

    public var internalDateSource: DateSource
    /// Keeps imported mail out of Junk Email.
    public var neverMarkSpam: Bool
    public var processForCalendar: Bool

    public init(internalDateSource: DateSource = .dateHeader, neverMarkSpam: Bool = true, processForCalendar: Bool = false) {
        self.internalDateSource = internalDateSource
        self.neverMarkSpam = neverMarkSpam
        self.processForCalendar = processForCalendar
    }
}

public struct GmailPause: Equatable, Sendable {
    public var until: Date
    /// Google's refusal that asked for it.
    public var refusal: GoogleAPIError

    public init(until: Date, refusal: GoogleAPIError) {
        self.until = until
        self.refusal = refusal
    }
}

public struct GmailUsage: Hashable, Sendable {
    public var units: [GmailMethod: Int]
    public var calls: [GmailMethod: Int]
    public var bytesDown: Int
    public var bytesUp: Int

    public init(units: [GmailMethod: Int] = [:], calls: [GmailMethod: Int] = [:], bytesDown: Int = 0, bytesUp: Int = 0) {
        self.units = units
        self.calls = calls
        self.bytesDown = bytesDown
        self.bytesUp = bytesUp
    }

    public var totalUnits: Int { units.values.reduce(0, +) }
}

// MARK: - Answers Gmail sends as they are

/// `threads.get`: a conversation's messages, oldest first.
public struct GmailThread: Decodable, Sendable, Hashable {
    public var id: String
    public var historyId: String?
    public var messages: [GmailMessage]?

    public init(id: String, historyId: String? = nil, messages: [GmailMessage]? = nil) {
        self.id = id
        self.historyId = historyId
        self.messages = messages
    }

    public var threadID: GmailThreadID? { GmailThreadID(hex: id) }
}

public struct GmailDraft: Decodable, Sendable, Hashable {
    public var id: String
    /// After a create or update, the message the draft is now, with its labels. In a list, its
    /// id and thread only.
    public var message: GmailMessage?

    public init(id: String, message: GmailMessage? = nil) {
        self.id = id
        self.message = message
    }
}

public struct GmailDraftList: Decodable, Sendable, Hashable {
    public var drafts: [GmailDraft]?
    public var nextPageToken: String?
    public var resultSizeEstimate: Int?

    public init(drafts: [GmailDraft]? = nil, nextPageToken: String? = nil, resultSizeEstimate: Int? = nil) {
        self.drafts = drafts
        self.nextPageToken = nextPageToken
        self.resultSizeEstimate = resultSizeEstimate
    }
}

/// `users.settings.sendAs.list`: an address the account may send as, with the signature Gmail
/// puts under messages sent from it, as HTML.
public struct GmailSendAs: Decodable, Sendable, Hashable {
    public var sendAsEmail: String
    public var displayName: String?
    public var replyToAddress: String?
    public var signature: String?
    public var isPrimary: Bool?
    public var isDefault: Bool?
    public var verificationStatus: String?

    public init(sendAsEmail: String, displayName: String? = nil, replyToAddress: String? = nil, signature: String? = nil,
                isPrimary: Bool? = nil, isDefault: Bool? = nil, verificationStatus: String? = nil) {
        self.sendAsEmail = sendAsEmail
        self.displayName = displayName
        self.replyToAddress = replyToAddress
        self.signature = signature
        self.isPrimary = isPrimary
        self.isDefault = isDefault
        self.verificationStatus = verificationStatus
    }
}

// MARK: - Typed readings of Gmail's answers

extension GmailMessage {
    public var gmailID: GmailMessageID? { GmailMessageID(hex: id) }
    public var gmailThreadID: GmailThreadID? { GmailThreadID(hex: threadId) }
    public var ref: GmailRef? {
        guard let id = gmailID, let thread = gmailThreadID else { return nil }
        return GmailRef(id: id, threadID: thread)
    }
    public var labels: Set<GmailLabelID> { Set((labelIds ?? []).map { GmailLabelID($0) }) }
    public var history: HistoryID? { historyId.flatMap(HistoryID.init) }
    /// The whole message of a `format=raw` answer.
    public var rawData: Data? { raw.flatMap { Data(base64URL: $0) } }
}

extension GmailProfile {
    public var historyID: HistoryID? { historyId.flatMap(HistoryID.init) }
}

extension GmailLabel {
    public var labelID: GmailLabelID { GmailLabelID(id) }
    public var isUserLabel: Bool { type == "user" }
}
