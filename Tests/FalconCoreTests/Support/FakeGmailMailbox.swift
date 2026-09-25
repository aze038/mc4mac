import Foundation
@testable import FalconCore

/// An in-memory Gmail mailbox that answers the read endpoints of the Gmail API the way Google
/// does, closely enough for FalconMail's client: message and thread ids, labels, a history id
/// that moves on every change, search with a subset of Gmail's operators, pagination, and
/// injected refusals. It counts quota units per endpoint with Google's cost table.
final class FakeGmailMailbox: @unchecked Sendable {
    struct Attachment {
        var filename: String
        var mimeType: String
        var data: Data
        var contentID: String?
    }

    struct Message {
        var id: String
        var threadID: String
        var labels: Set<String>
        var date: Date
        var from: String
        var to: String
        var cc: String
        var subject: String
        var messageID: String
        var text: String
        var html: String?
        var attachments: [Attachment]
        var historyID: UInt64
    }

    enum Fault {
        case status(Int, reason: String?, retryAfter: String? = nil)
        case timeout
        case offline
    }

    private let lock = NSLock()
    private var store: [Message] = []
    private var nextID: UInt64 = 0x18a0_0000_0000_0000
    private var faults: [(method: GmailMethod?, fault: Fault)] = []
    private var standing: [GmailMethod: Fault] = [:]
    private var _units: [GmailMethod: Int] = [:]
    private var _calls: [GmailMethod: Int] = [:]
    private var _attempts: [GmailMethod: Int] = [:]
    private var _bytes: [GmailMethod: Int] = [:]
    private var _queries: [String] = []
    private var _rawQueries: [String] = []
    private(set) var historyID: UInt64 = 1_000
    let email: String
    var userLabels: [String: String] = [:]
    /// Tokens the fake accepts; nil accepts any.
    var acceptedTokens: Set<String>?
    /// The addresses the account sends from, as users.settings.sendAs.list answers them.
    var sendAs: [[String: Any]] = []

    init(email: String = "owner@example.com") {
        self.email = email
    }

    var units: [GmailMethod: Int] { lock.withLock { _units } }
    var calls: [GmailMethod: Int] { lock.withLock { _calls } }
    /// Every request that reached the fake, answered or refused.
    var attempts: [GmailMethod: Int] { lock.withLock { _attempts } }
    var bytesServed: [GmailMethod: Int] { lock.withLock { _bytes } }
    /// Decoded `q` values of every list call.
    var queries: [String] { lock.withLock { _queries } }
    /// The percent-encoded query strings exactly as they arrived.
    var rawQueries: [String] { lock.withLock { _rawQueries } }
    var messages: [Message] { lock.withLock { store } }

    @discardableResult
    func add(subject: String, from: String = "Ana <ana@example.com>", to: String = "owner@example.com", cc: String = "",
             text: String = "Hello", html: String? = nil, labels: Set<String> = ["INBOX"], date: Date = Date(),
             messageID: String? = nil, threadID: String? = nil, attachments: [Attachment] = []) -> Message {
        lock.withLock {
            nextID += 1
            historyID += 1
            let id = String(nextID, radix: 16)
            let message = Message(id: id, threadID: threadID ?? id, labels: labels, date: date, from: from, to: to, cc: cc,
                                  subject: subject, messageID: messageID ?? "<\(id)@mail.example.com>", text: text, html: html,
                                  attachments: attachments, historyID: historyID)
            store.append(message)
            return message
        }
    }

    func setLabels(_ labels: Set<String>, on id: String) {
        lock.withLock {
            guard let i = store.firstIndex(where: { $0.id == id }) else { return }
            historyID += 1
            store[i].labels = labels
            store[i].historyID = historyID
        }
    }

    /// Refuses the next `times` calls to `method` (any method when nil) with `fault`.
    func inject(_ fault: Fault, for method: GmailMethod? = nil, times: Int = 1) {
        lock.withLock { for _ in 0..<times { faults.append((method, fault)) } }
    }

    /// Refuses every call to `method` with `fault` until cleared.
    func always(_ fault: Fault?, for method: GmailMethod) {
        lock.withLock { standing[method] = fault }
    }

    // MARK: - Serving

    func handle(_ request: URLRequest) -> Result<(HTTPURLResponse, Data), URLError> {
        guard let url = request.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(URLError(.badURL))
        }
        let path = comps.path.components(separatedBy: "/users/me/").last ?? ""
        let segments = path.split(separator: "/").map(String.init)
        let method: GmailMethod
        switch segments.count {
        case 1 where segments[0] == "profile": method = .profile
        case 1 where segments[0] == "labels": method = .labelsList
        case 1 where segments[0] == "messages": method = .messagesList
        case 2 where segments[0] == "messages": method = .messagesGet
        case 4 where segments[0] == "messages" && segments[2] == "attachments": method = .attachmentsGet
        case 2 where segments[0] == "settings" && segments[1] == "sendAs": method = .sendAsList
        default: return .success(respond(url, 404, ["error": ["code": 404, "message": "Not Found"]]))
        }
        let query = Dictionary(grouping: comps.queryItems ?? [], by: \.name).mapValues { $0.compactMap(\.value) }
        return lock.withLock { () -> Result<(HTTPURLResponse, Data), URLError> in
            _attempts[method, default: 0] += 1
            if method == .messagesList {
                _rawQueries.append(comps.percentEncodedQuery ?? "")
                _queries.append(query["q"]?.first ?? "")
            }
            if let fault = takeFault(for: method) { return serve(fault, url: url) }
            if let accepted = acceptedTokens {
                let token = request.value(forHTTPHeaderField: "Authorization")?.removingPrefix("Bearer ") ?? ""
                guard accepted.contains(token) else {
                    return .success(respond(url, 401, ["error": ["code": 401, "message": "Invalid Credentials", "status": "UNAUTHENTICATED",
                                                                 "errors": [["reason": "authError", "message": "Invalid Credentials"]]]]))
                }
            }
            let answer: (Int, Any)
            switch method {
            case .profile:
                answer = (200, ["emailAddress": email, "messagesTotal": store.count, "threadsTotal": Set(store.map(\.threadID)).count,
                                "historyId": String(historyID)])
            case .labelsList:
                let system = ["INBOX", "SENT", "DRAFT", "SPAM", "TRASH", "STARRED", "IMPORTANT", "UNREAD"].map { ["id": $0, "name": $0, "type": "system"] }
                answer = (200, ["labels": system + userLabels.map { ["id": $0.key, "name": $0.value, "type": "user"] }])
            case .messagesList:
                answer = list(query)
            case .messagesGet:
                answer = get(segments[1], query)
            case .attachmentsGet:
                answer = attachment(segments[1], segments[3])
            case .sendAsList:
                answer = (200, ["sendAs": sendAs])
            }
            let response = respond(url, answer.0, answer.1)
            if answer.0 == 200 {
                _units[method, default: 0] += method.units
                _calls[method, default: 0] += 1
                _bytes[method, default: 0] += response.1.count
            }
            return .success(response)
        }
    }

    private func takeFault(for method: GmailMethod) -> Fault? {
        if let i = faults.firstIndex(where: { $0.method == nil || $0.method == method }) {
            return faults.remove(at: i).fault
        }
        return standing[method]
    }

    private func serve(_ fault: Fault, url: URL) -> Result<(HTTPURLResponse, Data), URLError> {
        switch fault {
        case .timeout: return .failure(URLError(.timedOut))
        case .offline: return .failure(URLError(.notConnectedToInternet))
        case .status(let code, let reason, let retryAfter):
            var error: [String: Any] = ["code": code, "message": "Refused by the fake (\(reason ?? "none"))"]
            if let reason { error["errors"] = [["reason": reason, "domain": "usageLimits", "message": "Refused"]] }
            if reason == "SERVICE_DISABLED" {
                error["errors"] = nil
                error["status"] = "PERMISSION_DENIED"
                error["details"] = [["@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "SERVICE_DISABLED"]]
            }
            return .success(respond(url, code, ["error": error], headers: retryAfter.map { ["Retry-After": $0] } ?? [:]))
        }
    }

    private func respond(_ url: URL, _ status: Int, _ body: Any, headers: [String: String] = [:]) -> (HTTPURLResponse, Data) {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        var all = headers
        all["Content-Type"] = "application/json; charset=UTF-8"
        return (HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: all)!, data)
    }

    // MARK: - Endpoints

    private func list(_ query: [String: [String]]) -> (Int, Any) {
        let q = query["q"]?.first ?? ""
        let labelIDs = Set(query["labelIds"] ?? [])
        let includeSpamTrash = query["includeSpamTrash"]?.first == "true"
        let maxResults = min(500, Int(query["maxResults"]?.first ?? "") ?? 100)
        let offset = Int(query["pageToken"]?.first ?? "") ?? 0
        let terms = FakeGmailMailbox.terms(q)
        let wantsSpamTrash = includeSpamTrash || terms.contains { ["in:spam", "in:trash", "in:anywhere"].contains($0.lowercased()) }
        let hits = store
            .filter { labelIDs.isSubset(of: $0.labels) }
            .filter { wantsSpamTrash || ($0.labels.isDisjoint(with: ["SPAM", "TRASH"])) }
            .filter { m in terms.allSatisfy { matches(m, $0) } }
            .sorted { $0.date > $1.date }
        let page = hits.dropFirst(offset).prefix(maxResults)
        var body: [String: Any] = ["resultSizeEstimate": hits.count]
        if !page.isEmpty { body["messages"] = page.map { ["id": $0.id, "threadId": $0.threadID] } }
        if offset + page.count < hits.count { body["nextPageToken"] = String(offset + page.count) }
        return (200, body)
    }

    private func matches(_ m: Message, _ term: String) -> Bool {
        let lower = term.lowercased()
        func value(_ prefix: String) -> String? {
            lower.hasPrefix(prefix) ? String(term.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) : nil
        }
        if let v = value("in:") {
            switch v.lowercased() {
            case "inbox": return m.labels.contains("INBOX")
            case "sent": return m.labels.contains("SENT")
            case "drafts": return m.labels.contains("DRAFT")
            case "spam": return m.labels.contains("SPAM")
            case "trash": return m.labels.contains("TRASH")
            default: return true
            }
        }
        if let v = value("is:") {
            switch v.lowercased() {
            case "starred": return m.labels.contains("STARRED")
            case "unread": return m.labels.contains("UNREAD")
            case "important": return m.labels.contains("IMPORTANT")
            default: return false
            }
        }
        if let v = value("label:") {
            let wanted = v.lowercased()
            return m.labels.contains { id in
                let name = (userLabels[id] ?? id).lowercased()
                return name == wanted || name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-") == wanted
            }
        }
        if let v = value("from:") { return m.from.lowercased().contains(v.lowercased()) }
        if let v = value("to:") { return m.to.lowercased().contains(v.lowercased()) }
        if let v = value("subject:") { return m.subject.lowercased().contains(v.lowercased()) }
        if let v = value("rfc822msgid:") { return m.messageID.lowercased().contains(v.lowercased()) }
        if lower == "has:attachment" { return !m.attachments.isEmpty }
        let needle = lower.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return [m.subject, m.from, m.to, m.text, m.html ?? ""].contains { $0.lowercased().contains(needle) }
    }

    static func terms(_ q: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        for ch in q {
            if ch == "\"" { quoted.toggle(); current.append(ch); continue }
            if ch == " " && !quoted {
                if !current.isEmpty { out.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private func get(_ id: String, _ query: [String: [String]]) -> (Int, Any) {
        guard let m = store.first(where: { $0.id == id }) else {
            return (404, ["error": ["code": 404, "message": "Requested entity was not found.", "status": "NOT_FOUND",
                                    "errors": [["reason": "notFound"]]]])
        }
        var body: [String: Any] = [
            "id": m.id, "threadId": m.threadID, "labelIds": m.labels.sorted(), "historyId": String(m.historyID),
            "internalDate": String(Int64(m.date.timeIntervalSince1970 * 1000)),
            "snippet": FakeGmailMailbox.escape(String(m.text.prefix(100))),
            "sizeEstimate": m.text.utf8.count + (m.html?.utf8.count ?? 0) + m.attachments.reduce(0) { $0 + $1.data.count }
        ]
        let format = query["format"]?.first ?? "full"
        var headers: [[String: String]] = [
            ["name": "From", "value": m.from], ["name": "To", "value": m.to], ["name": "Subject", "value": m.subject],
            ["name": "Date", "value": RFC5322Date.format(m.date)], ["name": "Message-Id", "value": m.messageID],
            ["name": "Content-Type", "value": FakeGmailMailbox.contentType(m)]
        ]
        if !m.cc.isEmpty { headers.append(["name": "Cc", "value": m.cc]) }
        switch format {
        case "metadata":
            let wanted = Set((query["metadataHeaders"] ?? []).map { $0.lowercased() })
            let kept = wanted.isEmpty ? headers : headers.filter { wanted.contains($0["name"]!.lowercased()) }
            body["payload"] = ["mimeType": String(FakeGmailMailbox.contentType(m).prefix { $0 != ";" }), "headers": kept]
        case "minimal":
            break
        default:
            body["payload"] = fullPayload(m, headers: headers)
        }
        return (200, body)
    }

    private func fullPayload(_ m: Message, headers: [[String: String]]) -> [String: Any] {
        func textPart(_ partID: String, _ type: String, _ text: String) -> [String: Any] {
            let data = Data(text.utf8)
            return ["partId": partID, "mimeType": type, "filename": "",
                    "headers": [["name": "Content-Type", "value": "\(type); charset=UTF-8"]],
                    "body": ["size": data.count, "data": data.base64URL]]
        }
        var textParts: [[String: Any]] = [textPart("0.0", "text/plain", m.text)]
        if let html = m.html { textParts.append(textPart("0.1", "text/html", html)) }
        let body: [String: Any] = textParts.count == 1 ? textParts[0]
            : ["partId": "0", "mimeType": "multipart/alternative", "filename": "", "headers": [["name": "Content-Type", "value": "multipart/alternative; boundary=b2"]],
               "body": ["size": 0], "parts": textParts]
        guard !m.attachments.isEmpty else {
            var single = body
            single["partId"] = ""
            single["headers"] = headers.filter { $0["name"] != "Content-Type" } + ((single["headers"] as? [[String: String]]) ?? [])
            return single
        }
        let attachmentParts: [[String: Any]] = m.attachments.enumerated().map { index, a in
            var partHeaders = [["name": "Content-Type", "value": "\(a.mimeType); name=\"\(a.filename)\""],
                               ["name": "Content-Disposition", "value": "\(a.contentID == nil ? "attachment" : "inline"); filename=\"\(a.filename)\""]]
            if let cid = a.contentID { partHeaders.append(["name": "Content-ID", "value": "<\(cid)>"]) }
            return ["partId": String(index + 1), "mimeType": a.mimeType, "filename": a.filename, "headers": partHeaders,
                    "body": ["attachmentId": "att-\(m.id)-\(index)", "size": a.data.count]]
        }
        return ["partId": "", "mimeType": "multipart/mixed", "filename": "", "headers": headers, "body": ["size": 0],
                "parts": [body] + attachmentParts]
    }

    private func attachment(_ messageID: String, _ attachmentID: String) -> (Int, Any) {
        guard let m = store.first(where: { $0.id == messageID }),
              let index = Int(attachmentID.split(separator: "-").last ?? ""), m.attachments.indices.contains(index),
              attachmentID == "att-\(m.id)-\(index)" else {
            return (404, ["error": ["code": 404, "message": "Not Found", "errors": [["reason": "notFound"]]]])
        }
        let data = m.attachments[index].data
        return (200, ["size": data.count, "data": data.base64URL])
    }

    static func contentType(_ m: Message) -> String {
        if !m.attachments.isEmpty { return "multipart/mixed; boundary=b1" }
        return m.html == nil ? "text/plain; charset=UTF-8" : "multipart/alternative; boundary=b2"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
