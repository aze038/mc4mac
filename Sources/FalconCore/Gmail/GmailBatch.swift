import Foundation

// Gmail's HTTP batches: many reads in one request, as `multipart/mixed` with one nested HTTP
// request in each part, answered the same way. Google counts every part as a call of its own,
// may answer the parts in any order, and names each answer by its part's Content-ID with
// "response-" in front, which is how answers are matched to what was asked.

/// How reads are grouped into HTTP batches.
public enum GmailBatchPlan {
    /// A screen of rows goes in one batch of up to 25.
    public static let rowParts = 25
    /// Whole messages and background work go at most 10 at a time: `full` and `raw` answers are
    /// large, and background work must never crowd a click out of the parts in flight.
    public static let largeParts = 10

    /// Whether a part's answer is a whole message rather than a row's worth.
    static func isLarge(_ part: GmailBatchPart) -> Bool {
        switch part {
        case .message(_, let format), .thread(_, let format):
            return format == .full || format == .raw
        case .label:
            return false
        }
    }

    /// Splits `parts`, in their order, into batches that each fit the class's share of parts in
    /// flight and the units the bucket can give at once, and hold at most 25 parts, or 10 once a
    /// whole message is among them or the work is not for a click.
    public static func split(_ parts: [GmailBatchPart], work: WorkClass, maxParts: Int, maxUnits: Int) -> [[GmailBatchPart]] {
        let classCap = work.isDeferrable ? largeParts : rowParts
        var batches: [[GmailBatchPart]] = []
        var current: [GmailBatchPart] = []
        var units = 0
        var cap = min(classCap, maxParts)
        for part in parts {
            let partCap = min(isLarge(part) ? min(cap, largeParts) : cap, maxParts)
            let price = part.method.units
            if !current.isEmpty, current.count + 1 > partCap || units + price > maxUnits {
                batches.append(current)
                current = []
                units = 0
                cap = min(classCap, maxParts)
            }
            current.append(part)
            units += price
            if isLarge(part) { cap = min(cap, largeParts) }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}

/// One batch request as it goes over the wire.
struct GmailBatchRequest {
    let boundary: String
    /// Each part under the Content-ID it is sent with.
    let parts: [(contentID: String, part: GmailBatchPart)]
    let body: Data

    var contentType: String { "multipart/mixed; boundary=\(boundary)" }

    /// `basePath` is the path every call follows, such as `/gmail/v1/users/me`.
    init(parts: [GmailBatchPart], basePath: String) {
        boundary = "batch_falconmail_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var numbered: [(String, GmailBatchPart)] = []
        var text = ""
        for (index, part) in parts.enumerated() {
            let contentID = "p\(index + 1)"
            numbered.append((contentID, part))
            text += "--\(boundary)\r\n"
            text += "Content-Type: application/http\r\n"
            text += "Content-ID: <\(contentID)>\r\n\r\n"
            text += "GET \(GmailBatchRequest.path(for: part, basePath: basePath)) HTTP/1.1\r\n\r\n"
        }
        text += "--\(boundary)--\r\n"
        self.parts = numbered
        body = Data(text.utf8)
    }

    /// The nested request's path and query. Only the path goes in a batch, never a whole URL.
    static func path(for part: GmailBatchPart, basePath: String) -> String {
        let base = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        switch part {
        case .message(let id, let format):
            return base + "/messages/" + id.hex + query(format)
        case .thread(let id, let format):
            return base + "/threads/" + id.hex + query(format)
        case .label(let id):
            return base + "/labels/" + id.value.urlQueryEncoded
        }
    }

    static func query(_ format: GmailFormat) -> String {
        let items = GmailFormatQuery.items(format)
        return "?" + items.map { "\($0.name)=\(($0.value ?? "").urlQueryEncoded)" }.joined(separator: "&")
    }
}

/// How a format is asked for in a query.
enum GmailFormatQuery {
    static func items(_ format: GmailFormat) -> [URLQueryItem] {
        switch format {
        case .minimal: return [URLQueryItem(name: "format", value: "minimal")]
        case .full: return [URLQueryItem(name: "format", value: "full")]
        case .raw: return [URLQueryItem(name: "format", value: "raw")]
        case .metadata(let headers):
            return [URLQueryItem(name: "format", value: "metadata")] + headers.map { URLQueryItem(name: "metadataHeaders", value: $0) }
        }
    }
}

/// One nested answer of a batch.
struct GmailBatchAnswerPart: Equatable {
    var status: Int
    /// Header names lower-cased.
    var headers: [String: String]
    var body: Data
}

enum GmailBatchResponse {
    /// The nested answers by the Content-ID of the part each answers, with Google's "response-"
    /// and the angle brackets taken off. Answers without a Content-ID are keyed by their place.
    static func parse(_ data: Data, contentType: String?) throws -> [String: GmailBatchAnswerPart] {
        guard let boundary = contentType.flatMap(MultipartText.boundary) else {
            throw GoogleAPIError(kind: .other, httpStatus: 200, reason: "undecodable", detail: "batch reply without a boundary")
        }
        var out: [String: GmailBatchAnswerPart] = [:]
        for (index, part) in MultipartText.parts(of: data, boundary: boundary).enumerated() {
            let (outer, nested) = MultipartText.splitHead(part)
            let outerHeaders = MultipartText.headers(outer)
            var key = "#\(index)"
            if let raw = outerHeaders["content-id"] {
                var id = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
                if id.lowercased().hasPrefix("response-") { id = String(id.dropFirst("response-".count)) }
                key = id
            }
            let (head, body) = MultipartText.splitHead(nested)
            let lines = head.utf8Lossy.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            guard let statusLine = lines.first(where: { !$0.trimmed.isEmpty }) else { continue }
            let fields = statusLine.split(separator: " ")
            guard fields.count >= 2, let status = Int(fields[1]) else { continue }
            let headers = MultipartText.headers(Data(lines.drop { $0 != statusLine }.dropFirst().joined(separator: "\r\n").utf8))
            out[key] = GmailBatchAnswerPart(status: status, headers: headers, body: MultipartText.trimmingTrailingNewline(body))
        }
        return out
    }
}

/// The plain-text multipart framing both batches and uploads use.
enum MultipartText {
    static func boundary(in contentType: String) -> String? {
        for piece in contentType.split(separator: ";") {
            let pair = piece.trimmingCharacters(in: .whitespaces)
            guard pair.lowercased().hasPrefix("boundary=") else { continue }
            return String(pair.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// The bodies between the delimiters, without the delimiter lines.
    static func parts(of data: Data, boundary: String) -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        var parts: [Data] = []
        var cursor = data.startIndex
        var start: Data.Index?
        while let range = data.range(of: delimiter, in: cursor..<data.endIndex) {
            if let begin = start {
                parts.append(trimmingTrailingNewline(data[begin..<range.lowerBound]))
            }
            var next = range.upperBound
            if data[next...].starts(with: Data("--".utf8)) { break }
            // Skip the rest of the delimiter line.
            while next < data.endIndex, data[next] != 0x0A { next = data.index(after: next) }
            if next < data.endIndex { next = data.index(after: next) }
            start = next
            cursor = next
        }
        return parts
    }

    /// Splits at the first blank line: the headers, then everything after.
    static func splitHead(_ data: Data) -> (head: Data, body: Data) {
        for separator in [Data("\r\n\r\n".utf8), Data("\n\n".utf8)] {
            if let range = data.range(of: separator) {
                return (Data(data[data.startIndex..<range.lowerBound]), Data(data[range.upperBound...]))
            }
        }
        return (Data(data), Data())
    }

    /// Header lines as a dictionary with lower-cased names. A colon is taken as optional, as one
    /// of Google's own examples leaves it out.
    static func headers(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        for raw in data.utf8Lossy.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard !line.trimmed.isEmpty else { continue }
            let name: Substring
            let value: Substring
            if let colon = line.firstIndex(of: ":") {
                name = line[..<colon]
                value = line[line.index(after: colon)...]
            } else if let space = line.firstIndex(of: " ") {
                name = line[..<space]
                value = line[line.index(after: space)...]
            } else {
                continue
            }
            out[name.trimmingCharacters(in: .whitespaces).lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    static func trimmingTrailingNewline(_ data: Data) -> Data {
        var end = data.endIndex
        if end > data.startIndex, data[data.index(before: end)] == 0x0A { end = data.index(before: end) }
        if end > data.startIndex, data[data.index(before: end)] == 0x0D { end = data.index(before: end) }
        return Data(data[data.startIndex..<end])
    }
}
