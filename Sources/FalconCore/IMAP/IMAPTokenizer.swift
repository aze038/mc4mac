import Foundation

enum IMAPRawPart {
    case text(String)
    case literal(Data)
}

enum IMAPToken: Equatable {
    case atom(String)
    case string(Data)
    case open
    case close
    case nilToken
}

public indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case nilValue

    public var stringValue: String? {
        switch self {
        case .atom(let s): return s
        case .string(let d): return d.utf8Lossy
        default: return nil
        }
    }

    public var dataValue: Data? {
        switch self {
        case .atom(let s): return Data(s.utf8)
        case .string(let d): return d
        default: return nil
        }
    }

    public var intValue: Int? {
        if case .atom(let s) = self { return Int(s) }
        return nil
    }

    public var listValue: [IMAPValue]? {
        if case .list(let l) = self { return l }
        return nil
    }
}

struct IMAPTokenizer {
    static func tokenize(_ parts: [IMAPRawPart]) throws -> [IMAPToken] {
        var tokens: [IMAPToken] = []
        var partIndex = 0
        while partIndex < parts.count {
            guard case .text(let text) = parts[partIndex] else {
                if case .literal(let d) = parts[partIndex] { tokens.append(.string(d)) }
                partIndex += 1
                continue
            }
            let chars = Array(text.utf8)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c == 0x20 || c == 0x09 { i += 1; continue }
                if c == 0x28 { tokens.append(.open); i += 1; continue }
                if c == 0x29 { tokens.append(.close); i += 1; continue }
                if c == 0x22 {
                    var j = i + 1
                    var bytes: [UInt8] = []
                    while j < chars.count && chars[j] != 0x22 {
                        if chars[j] == 0x5C && j + 1 < chars.count { bytes.append(chars[j + 1]); j += 2 } else { bytes.append(chars[j]); j += 1 }
                    }
                    tokens.append(.string(Data(bytes)))
                    i = j + 1
                    continue
                }
                if c == 0x7B {
                    var j = i + 1
                    while j < chars.count && chars[j] != 0x7D { j += 1 }
                    if partIndex + 1 < parts.count, case .literal(let d) = parts[partIndex + 1] {
                        tokens.append(.string(d))
                        partIndex += 1
                    } else {
                        throw FalconError.protocolError("IMAP literal without data")
                    }
                    i = j + 1
                    continue
                }
                if c == 0x5B {
                    var depth = 0
                    var j = i
                    var bytes: [UInt8] = []
                    while j < chars.count {
                        let cj = chars[j]
                        bytes.append(cj)
                        if cj == 0x5B { depth += 1 } else if cj == 0x5D { depth -= 1; if depth == 0 { j += 1; break } }
                        j += 1
                    }
                    let s = String(decoding: bytes, as: UTF8.self)
                    if i > 0, chars[i - 1] != 0x20, let last = tokens.last, case .atom(let a) = last {
                        tokens[tokens.count - 1] = .atom(a + s)
                    } else {
                        tokens.append(.atom(s))
                    }
                    i = j
                    continue
                }
                var j = i
                var bytes: [UInt8] = []
                while j < chars.count {
                    let cj = chars[j]
                    if cj == 0x20 || cj == 0x28 || cj == 0x29 || cj == 0x7B || cj == 0x22 || cj == 0x5B { break }
                    bytes.append(cj)
                    j += 1
                }
                let s = String(decoding: bytes, as: UTF8.self)
                if s.hasPrefix("<"), i > 0, chars[i - 1] == 0x5D, let last = tokens.last, case .atom(let a) = last {
                    tokens[tokens.count - 1] = .atom(a + s)
                } else if s.uppercased() == "NIL" {
                    tokens.append(.nilToken)
                } else if !s.isEmpty {
                    tokens.append(.atom(s))
                }
                i = max(j, i + 1)
            }
            partIndex += 1
        }
        return tokens
    }

    static func values(from tokens: [IMAPToken]) throws -> [IMAPValue] {
        var pos = 0
        var out: [IMAPValue] = []
        while pos < tokens.count {
            out.append(try parseValue(tokens, &pos))
        }
        return out
    }

    private static func parseValue(_ tokens: [IMAPToken], _ pos: inout Int) throws -> IMAPValue {
        let t = tokens[pos]
        pos += 1
        switch t {
        case .atom(let s): return .atom(s)
        case .string(let d): return .string(d)
        case .nilToken: return .nilValue
        case .open:
            var items: [IMAPValue] = []
            while pos < tokens.count {
                if tokens[pos] == .close { pos += 1; return .list(items) }
                items.append(try parseValue(tokens, &pos))
            }
            return .list(items)
        case .close:
            return .list([])
        }
    }
}
