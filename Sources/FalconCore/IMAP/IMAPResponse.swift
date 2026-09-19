import Foundation

public enum IMAPStatus: String, Sendable {
    case ok = "OK", no = "NO", bad = "BAD", bye = "BYE", preauth = "PREAUTH"
}

public struct IMAPFolderInfo: Sendable, Hashable {
    public var path: String
    public var displayName: String
    public var delimiter: String
    public var attributes: [String]

    public var isSelectable: Bool { !attributes.contains { $0.lowercased() == "\\noselect" } }

    public var role: FolderRole {
        if path.uppercased() == "INBOX" { return .inbox }
        for a in attributes {
            switch a.lowercased() {
            case "\\sent": return .sent
            case "\\drafts": return .drafts
            case "\\trash": return .trash
            case "\\junk": return .junk
            case "\\archive": return .archive
            case "\\all": return .all
            case "\\flagged": return .flagged
            case "\\important": return .important
            default: continue
            }
        }
        return .other
    }
}

public struct IMAPMailboxStatus: Sendable {
    public var exists: Int = 0
    public var recent: Int = 0
    public var uidValidity: UInt32 = 0
    public var uidNext: UInt32 = 0
    public var unseen: Int = 0
    public var flags: [String] = []
    public var readOnly = false
}

public struct IMAPFetchItem: Sendable {
    public var sequence: Int
    public var uid: UInt32?
    public var flags: [String]?
    public var size: Int?
    public var internalDate: String?
    public var sections: [String: Data]

    public var body: Data? {
        sections.first { $0.key.hasPrefix("BODY[]") || $0.key.hasPrefix("RFC822") }?.value
    }
    public var headerSection: Data? {
        sections.first { $0.key.hasPrefix("BODY[HEADER") }?.value
    }
}

public enum IMAPResponse: Sendable {
    case tagged(tag: String, status: IMAPStatus, code: String?, text: String)
    case untaggedStatus(status: IMAPStatus, code: String?, text: String)
    case continuation(String)
    case capability([String])
    case list(IMAPFolderInfo)
    case exists(Int)
    case recent(Int)
    case expunge(Int)
    case fetch(IMAPFetchItem)
    case search([UInt32])
    case flags([String])
    case status(mailbox: String, items: [String: Int])
    case other(String)
}

struct IMAPResponseParser {
    static func parse(_ parts: [IMAPRawPart]) throws -> IMAPResponse {
        guard case .text(let first)? = parts.first else { throw FalconError.protocolError("empty response") }
        let words = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard let w0 = words.first else { throw FalconError.protocolError("empty line") }

        if w0 == "+" {
            return .continuation(words.dropFirst().joined(separator: " "))
        }

        if w0 == "*" {
            guard words.count >= 2 else { return .other(first) }
            let w1 = words[1].uppercased()
            if let status = IMAPStatus(rawValue: w1) {
                let (code, text) = splitCode(words.count > 2 ? words[2] : "")
                return .untaggedStatus(status: status, code: code, text: text)
            }
            if let n = Int(words[1]), words.count > 2 {
                let kind = words[2].split(separator: " ", maxSplits: 1).map(String.init)
                switch kind.first?.uppercased() {
                case "EXISTS": return .exists(n)
                case "RECENT": return .recent(n)
                case "EXPUNGE": return .expunge(n)
                case "FETCH":
                    let values = try IMAPTokenizer.values(from: try IMAPTokenizer.tokenize(parts))
                    return .fetch(try parseFetch(sequence: n, values: values))
                default: return .other(first)
                }
            }
            switch w1 {
            case "CAPABILITY":
                return .capability(first.split(separator: " ").dropFirst(2).map(String.init))
            case "SEARCH":
                return .search(first.split(separator: " ").dropFirst(2).compactMap { UInt32($0) })
            case "FLAGS":
                let values = try IMAPTokenizer.values(from: try IMAPTokenizer.tokenize(parts))
                let list = values.last?.listValue ?? []
                return .flags(list.compactMap { $0.stringValue })
            case "LIST", "LSUB", "XLIST":
                let values = try IMAPTokenizer.values(from: try IMAPTokenizer.tokenize(parts))
                guard values.count >= 5 else { return .other(first) }
                let attrs = values[2].listValue?.compactMap { $0.stringValue } ?? []
                let delim = values[3].stringValue ?? ""
                let rawPath = values[4].stringValue ?? ""
                let path = ModifiedUTF7.decode(rawPath)
                let name = delim.isEmpty ? path : (path.components(separatedBy: delim).last ?? path)
                return .list(IMAPFolderInfo(path: rawPath, displayName: name, delimiter: delim, attributes: attrs))
            case "STATUS":
                let values = try IMAPTokenizer.values(from: try IMAPTokenizer.tokenize(parts))
                guard values.count >= 4, let list = values[3].listValue else { return .other(first) }
                var items: [String: Int] = [:]
                var i = 0
                while i + 1 < list.count {
                    if let k = list[i].stringValue, let v = list[i + 1].intValue { items[k.uppercased()] = v }
                    i += 2
                }
                return .status(mailbox: values[2].stringValue ?? "", items: items)
            default:
                return .other(first)
            }
        }

        guard words.count >= 2, let status = IMAPStatus(rawValue: words[1].uppercased()) else {
            return .other(first)
        }
        let (code, text) = splitCode(words.count > 2 ? words[2] : "")
        return .tagged(tag: w0, status: status, code: code, text: text)
    }

    static func splitCode(_ rest: String) -> (String?, String) {
        guard rest.hasPrefix("["), let end = rest.firstIndex(of: "]") else { return (nil, rest) }
        let code = String(rest[rest.index(after: rest.startIndex)..<end])
        let text = String(rest[rest.index(after: end)...]).trimmed
        return (code, text)
    }

    private static func parseFetch(sequence: Int, values: [IMAPValue]) throws -> IMAPFetchItem {
        guard let list = values.last?.listValue else { throw FalconError.protocolError("FETCH without list") }
        var item = IMAPFetchItem(sequence: sequence, uid: nil, flags: nil, size: nil, internalDate: nil, sections: [:])
        var i = 0
        while i + 1 < list.count {
            guard let key = list[i].stringValue?.uppercased() else { i += 1; continue }
            let value = list[i + 1]
            switch key {
            case "UID": item.uid = value.intValue.map { UInt32($0) }
            case "FLAGS": item.flags = value.listValue?.compactMap { $0.stringValue } ?? []
            case "RFC822.SIZE": item.size = value.intValue
            case "INTERNALDATE": item.internalDate = value.stringValue
            default:
                if let d = value.dataValue { item.sections[key] = d } else if case .nilValue = value { item.sections[key] = Data() }
            }
            i += 2
        }
        return item
    }
}
