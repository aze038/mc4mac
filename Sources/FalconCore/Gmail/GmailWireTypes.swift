import Foundation

// Gmail's JSON as it goes over the wire, and its reading into the engine's typed values. Every id
// Gmail sends is parsed here once; one that does not parse is logged and left out, so nothing
// further on ever holds a message id that Gmail would not recognise when it is sent back.

/// `labels.list`.
struct GmailLabelsReply: Decodable {
    var labels: [GmailLabel]?
}

/// `users.settings.sendAs.list`.
struct GmailSendAsReply: Decodable {
    var sendAs: [GmailSendAs]?
}

/// `messages.attachments.get`.
struct GmailAttachmentReply: Decodable {
    var data: String?
    var size: Int?
}

/// A message as a list, a history record or a change answers with it: its ids, and its labels
/// when Gmail gives them.
struct GmailWireMessage: Decodable {
    var id: String
    var threadId: String
    var labelIds: [String]?
}

/// `history.list`.
struct GmailHistoryReply: Decodable {
    struct Change: Decodable {
        var message: GmailWireMessage
        /// For a label change, the labels it added or removed.
        var labelIds: [String]?
    }

    struct Record: Decodable {
        var id: String
        var messagesAdded: [Change]?
        var messagesDeleted: [Change]?
        var labelsAdded: [Change]?
        var labelsRemoved: [Change]?
    }

    var history: [Record]?
    var nextPageToken: String?
    var historyId: String?
}

/// The body of `messages.modify`.
struct GmailModifyBody: Encodable {
    var addLabelIds: [String]
    var removeLabelIds: [String]
}

/// The body of `messages.batchModify`.
struct GmailBatchModifyBody: Encodable {
    var ids: [String]
    var addLabelIds: [String]
    var removeLabelIds: [String]
}

/// The body of `messages.batchDelete`.
struct GmailIDsBody: Encodable {
    var ids: [String]
}

/// The body of `labels.create`: shown in the label list and on its messages, as a folder the
/// owner makes in Outlook is.
struct GmailNewLabelBody: Encodable {
    var name: String
    var labelListVisibility = "labelShow"
    var messageListVisibility = "show"
}

/// The JSON part of an upload to `messages.send`, `messages.import` or `messages.insert`.
struct GmailUploadMetadata: Encodable {
    var threadId: String?
    var labelIds: [String]?
}

/// The JSON part of an upload to `drafts.create` or `drafts.update`.
struct GmailDraftUploadMetadata: Encodable {
    struct Message: Encodable {
        var threadId: String?
    }

    var id: String?
    var message: Message
}

enum GmailWire {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func encode<T: Encodable>(_ value: T) -> Data {
        // These bodies hold only strings and arrays of them, which always encode.
        (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, method: GmailMethod) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GoogleAPIError(kind: .other, httpStatus: 200, reason: "undecodable",
                                 detail: "undecodable \(method.rawValue) reply of \(data.count) bytes")
        }
    }

    static func ref(_ id: String, _ thread: String, in context: String) -> GmailRef? {
        guard let messageID = GmailMessageID.fromGmail(id, in: context),
              let threadID = GmailThreadID.fromGmail(thread, in: context) else { return nil }
        return GmailRef(id: messageID, threadID: threadID)
    }

    /// A page of `messages.list`, with the ids that did not parse counted, so a count check can
    /// allow for them rather than list the label again and again.
    static func listPage(_ reply: GmailMessageList) -> GmailListPage {
        var refs: [GmailRef] = []
        var refused = 0
        for message in reply.messages ?? [] {
            if let ref = ref(message.id, message.threadId, in: "messages.list") {
                refs.append(ref)
            } else {
                refused += 1
            }
        }
        return GmailListPage(refs: refs, nextPageToken: reply.nextPageToken?.nilIfEmpty,
                             resultSizeEstimate: reply.resultSizeEstimate ?? 0, refusedIDs: refused)
    }

    /// A page of `history.list`. The cursor moves to the mailbox's history id when Gmail gives
    /// it; without one, to the last record read, which is never past a change not yet seen.
    static func historyPage(_ reply: GmailHistoryReply, since start: HistoryID) -> GmailHistoryPage {
        var records: [GmailHistoryRecord] = []
        for record in reply.history ?? [] {
            guard let id = HistoryID(record.id) else {
                Log.info("gmail", "left out a history record whose id of \(record.id.count) characters is not a number")
                continue
            }
            func labels(_ ids: [String]?) -> [GmailLabelID]? {
                ids.map { $0.map { GmailLabelID($0) } }
            }
            func message(_ change: GmailHistoryReply.Change) -> GmailHistoryMessage? {
                guard let found = ref(change.message.id, change.message.threadId, in: "history.list") else { return nil }
                return GmailHistoryMessage(ref: found, labels: labels(change.message.labelIds))
            }
            func messages(_ changes: [GmailHistoryReply.Change]?) -> [GmailHistoryMessage] {
                (changes ?? []).compactMap(message)
            }
            func labelChanges(_ changes: [GmailHistoryReply.Change]?) -> [GmailLabelChange] {
                (changes ?? []).compactMap { change in
                    message(change).map { GmailLabelChange(message: $0, labels: labels(change.labelIds) ?? []) }
                }
            }
            records.append(GmailHistoryRecord(id: id, messagesAdded: messages(record.messagesAdded),
                                              messagesDeleted: messages(record.messagesDeleted),
                                              labelsAdded: labelChanges(record.labelsAdded),
                                              labelsRemoved: labelChanges(record.labelsRemoved)))
        }
        let latest = records.map(\.id).max() ?? start
        let current = reply.historyId.flatMap(HistoryID.init) ?? latest
        return GmailHistoryPage(records: records, nextPageToken: reply.nextPageToken?.nilIfEmpty, historyID: max(current, latest))
    }

    static func labelIDs(_ labels: Set<GmailLabelID>) -> [String] { labels.map(\.value).sorted() }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
