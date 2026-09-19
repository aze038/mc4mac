import Foundation

public struct MIMEHeaders: Sendable, Hashable {
    public private(set) var fields: [(name: String, value: String)] = []

    public init() {}

    public static func == (lhs: MIMEHeaders, rhs: MIMEHeaders) -> Bool {
        lhs.fields.map { $0.name + ":" + $0.value } == rhs.fields.map { $0.name + ":" + $0.value }
    }

    public func hash(into hasher: inout Hasher) {
        for f in fields { hasher.combine(f.name); hasher.combine(f.value) }
    }

    public func first(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func all(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map { $0.value }
    }

    public mutating func add(_ name: String, _ value: String) {
        fields.append((name, value))
    }

    public static func parse(_ data: Data) -> MIMEHeaders {
        var h = MIMEHeaders()
        let text = data.utf8Lossy
        var current: (String, String)?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty { break }
            if line.first == " " || line.first == "\t" {
                if current != nil { current!.1 += " " + line.trimmed }
                continue
            }
            if let c = current { h.fields.append((c.0, c.1)) }
            current = nil
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmed
            let value = String(line[line.index(after: colon)...]).trimmed
            current = (name, value)
        }
        if let c = current { h.fields.append((c.0, c.1)) }
        return h
    }
}

public struct ContentType: Sendable, Hashable {
    public var type: String
    public var subtype: String
    public var params: [String: String]

    public var mimeType: String { "\(type)/\(subtype)" }
    public var isMultipart: Bool { type == "multipart" }
    public var isText: Bool { type == "text" }
    public var charset: String? { params["charset"] }
    public var boundary: String? { params["boundary"] }

    public static func parse(_ raw: String?) -> ContentType {
        guard let raw, !raw.isEmpty else { return ContentType(type: "text", subtype: "plain", params: [:]) }
        let (value, params) = HeaderParams.parse(raw)
        let pieces = value.lowercased().split(separator: "/", maxSplits: 1).map(String.init)
        let type = pieces.first ?? "text"
        let subtype = pieces.count > 1 ? pieces[1] : "plain"
        return ContentType(type: type, subtype: subtype, params: params)
    }
}

public enum HeaderParams {
    public static func parse(_ raw: String) -> (String, [String: String]) {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        var prev: Character = " "
        for ch in raw {
            if ch == "\"" && prev != "\\" { inQuotes.toggle() }
            if ch == ";" && !inQuotes { segments.append(current); current = "" } else { current.append(ch) }
            prev = ch
        }
        segments.append(current)
        let value = segments.first?.trimmed ?? ""
        var params: [String: String] = [:]
        var continuations: [String: [(Int, String, Bool)]] = [:]
        for seg in segments.dropFirst() {
            let s = seg.trimmed
            guard let eq = s.firstIndex(of: "=") else { continue }
            var key = String(s[..<eq]).trimmed.lowercased()
            var val = String(s[s.index(after: eq)...]).trimmed
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            var extended = false
            if key.hasSuffix("*") { key.removeLast(); extended = true }
            if let star = key.firstIndex(of: "*"), let n = Int(key[key.index(after: star)...]) {
                let base = String(key[..<star])
                continuations[base, default: []].append((n, val, extended))
                continue
            }
            params[key] = extended ? decodeExtended(val) : val
        }
        for (key, parts) in continuations {
            let sorted = parts.sorted { $0.0 < $1.0 }
            var charset = "utf-8"
            var joined = ""
            for (i, p) in sorted.enumerated() {
                if p.2 {
                    var v = p.1
                    if i == 0, let first = v.firstIndex(of: "'"), let second = v[v.index(after: first)...].firstIndex(of: "'") {
                        charset = String(v[..<first])
                        v = String(v[v.index(after: second)...])
                    }
                    joined += v.removingPercentEncoding(charset: charset)
                } else {
                    joined += p.1
                }
            }
            params[key] = joined
        }
        return (value, params)
    }

    static func decodeExtended(_ v: String) -> String {
        guard let first = v.firstIndex(of: "'"), let second = v[v.index(after: first)...].firstIndex(of: "'") else {
            return v.removingPercentEncoding(charset: "utf-8")
        }
        let charset = String(v[..<first])
        return String(v[v.index(after: second)...]).removingPercentEncoding(charset: charset)
    }
}

extension String {
    func removingPercentEncoding(charset: String) -> String {
        var bytes: [UInt8] = []
        let chars = Array(utf8)
        var i = 0
        while i < chars.count {
            if chars[i] == 0x25, i + 2 < chars.count, let b = UInt8(String(decoding: chars[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                bytes.append(b); i += 3
            } else {
                bytes.append(chars[i]); i += 1
            }
        }
        return Charsets.decode(Data(bytes), charset: charset)
    }
}

public enum Charsets {
    public static func decode(_ data: Data, charset: String?) -> String {
        let cs = (charset ?? "utf-8").lowercased().trimmed
        if cs.isEmpty || cs == "utf-8" || cs == "utf8" || cs == "us-ascii" || cs == "ascii" {
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
        if cfEncoding != kCFStringEncodingInvalidId {
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            if let s = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) { return s }
        }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }
}

public enum RFC2047 {
    private static let pattern = try! NSRegularExpression(pattern: "=\\?([^?\\s]+)\\?([BbQq])\\?([^?\\s]*)\\?=", options: [])

    public static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        let ns = input as NSString
        let matches = pattern.matches(in: input, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }
        var out = ""
        var cursor = 0
        var lastWasEncoded = false
        for m in matches {
            let between = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            if !(lastWasEncoded && between.trimmed.isEmpty) { out += between }
            let charset = ns.substring(with: m.range(at: 1))
            let encoding = ns.substring(with: m.range(at: 2)).uppercased()
            let payload = ns.substring(with: m.range(at: 3))
            let data: Data
            if encoding == "B" {
                data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data()
            } else {
                data = TransferDecoding.quotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8), isHeader: true)
            }
            let cleanCharset = charset.split(separator: "*").first.map(String.init) ?? charset
            out += Charsets.decode(data, charset: cleanCharset)
            cursor = m.range.location + m.range.length
            lastWasEncoded = true
        }
        out += ns.substring(from: cursor)
        return out
    }

    public static func encode(_ input: String) -> String {
        guard input.contains(where: { !$0.isASCII || $0 == "\r" || $0 == "\n" }) else { return input }
        let words = input.utf8.count > 40 ? chunked(input, 40) : [input]
        return words.map { "=?utf-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    private static func chunked(_ s: String, _ limit: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in s {
            if current.utf8.count + String(ch).utf8.count > limit { out.append(current); current = "" }
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

public enum TransferDecoding {
    public static func base64(_ data: Data) -> Data {
        Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? Data()
    }

    public static func quotedPrintable(_ data: Data, isHeader: Bool = false) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D {
                if i + 1 < bytes.count, bytes[i + 1] == 0x0D { i += (i + 2 < bytes.count && bytes[i + 2] == 0x0A) ? 3 : 2; continue }
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 2; continue }
                if i + 2 < bytes.count, let v = UInt8(String(decoding: bytes[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                    out.append(v); i += 3; continue
                }
                out.append(b); i += 1
                continue
            }
            out.append(b)
            i += 1
        }
        return out
    }

    public static func decode(_ data: Data, encoding: String?) -> Data {
        switch (encoding ?? "").lowercased().trimmed {
        case "base64": return base64(data)
        case "quoted-printable": return quotedPrintable(data)
        default: return data
        }
    }
}

public enum AddressParser {
    public static func parse(_ raw: String?) -> [EmailAddress] {
        guard let raw, !raw.isEmpty else { return [] }
        var out: [EmailAddress] = []
        var current = ""
        var inQuotes = false
        var depth = 0
        var prev: Character = " "
        func flush() {
            let s = current.trimmed
            if !s.isEmpty, let a = parseOne(s) { out.append(a) }
            current = ""
        }
        for ch in raw {
            if ch == "\"" && prev != "\\" { inQuotes.toggle() }
            if !inQuotes {
                if ch == "<" { depth += 1 } else if ch == ">" { depth = max(0, depth - 1) }
                if ch == "," && depth == 0 { flush(); prev = ch; continue }
                if ch == ";" && depth == 0 { flush(); prev = ch; continue }
            }
            current.append(ch)
            prev = ch
        }
        flush()
        return out
    }

    static func parseOne(_ s: String) -> EmailAddress? {
        if let lt = s.lastIndex(of: "<"), let gt = s[lt...].firstIndex(of: ">") {
            let address = String(s[s.index(after: lt)..<gt]).trimmed
            var name = String(s[..<lt]).trimmed
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            name = RFC2047.decode(name).replacingOccurrences(of: "\\\"", with: "\"")
            if let colon = name.lastIndex(of: ":"), !name.contains("\"") { name = String(name[name.index(after: colon)...]).trimmed }
            return EmailAddress(name: name, address: address)
        }
        var addr = s.trimmed
        if let colon = addr.firstIndex(of: ":"), let at = addr.firstIndex(of: "@"), colon < at {
            addr = String(addr[addr.index(after: colon)...]).trimmed
        }
        if addr.isEmpty { return nil }
        if let paren = addr.firstIndex(of: "("), let close = addr[paren...].firstIndex(of: ")") {
            let name = String(addr[addr.index(after: paren)..<close]).trimmed
            let a = String(addr[..<paren]).trimmed
            return EmailAddress(name: RFC2047.decode(name), address: a)
        }
        return EmailAddress(name: "", address: addr)
    }

    public static func messageIDs(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        var out: [String] = []
        var current = ""
        var inside = false
        for ch in raw {
            if ch == "<" { inside = true; current = "<"; continue }
            if ch == ">" && inside { current.append(">"); out.append(current); inside = false; continue }
            if inside { current.append(ch) }
        }
        return out
    }
}
