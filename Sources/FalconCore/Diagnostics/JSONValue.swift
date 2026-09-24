import Foundation

/// Any JSON value, for the parts of a diagnostic whose shape FalconMail does not own: a crash
/// report, a MetricKit call-stack tree, the counts in a health report.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 9e18: return Int64(d)
        case .string(let s): return Int64(s)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// The value `data` holds, or nil when it is not JSON. Any depth parses: see `maxDepth`.
    public static func parse(_ data: Data) -> JSONValue? {
        JSONDocument(data)?.value(maxDepth: maxDepth)
    }

    public static func parse(_ text: String) -> JSONValue? {
        parse(Data(text.utf8))
    }

    /// The deepest a parsed value nests. Everything done with a value afterwards (redacting it,
    /// measuring it, encoding it with JSONEncoder, even freeing it) goes one call deeper for each
    /// level, and on the diagnostics queue's thread, whose stack is 512 KB, JSONEncoder runs out
    /// of stack at about 160 levels. So `parse` reads without recursion (see `JSONDocument`), and a
    /// list or object that would sit deeper than this is flattened: it becomes
    /// `{"flattened": [...]}`, every object inside it in the order they appear, each keeping only
    /// its members that are neither lists nor objects. MetricKit's call stacks, which nest a level
    /// per frame, are read from the `JSONDocument` instead and keep their shape at any depth.
    public static let maxDepth = 64

    /// Compact UTF-8 JSON, keys sorted so the same value always reads the same.
    public var serialised: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d.isFinite ? d : 0)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Fitting a value into a size limit

extension JSONValue {
    /// Close to the length of `serialised`, cheap enough to ask of every subtree.
    public var estimatedSize: Int {
        switch self {
        case .null: return 4
        case .bool(let b): return b ? 4 : 5
        case .int(let i): return String(i).utf8.count
        case .double(let d): return String(d).utf8.count
        case .string(let s): return JSONValue.quotedSize(s)
        case .array(let a): return 2 + max(0, a.count - 1) + a.reduce(0) { $0 + $1.estimatedSize }
        case .object(let o):
            return 2 + max(0, o.count - 1) + o.reduce(0) { $0 + JSONValue.quotedSize($1.key) + 1 + $1.value.estimatedSize }
        }
    }

    private static func quotedSize(_ s: String) -> Int {
        var n = 2
        for u in s.utf8 {
            switch u {
            case 0x22, 0x5C, 0x08, 0x0C, 0x0A, 0x0D, 0x09: n += 2
            case 0..<0x20: n += 6
            default: n += 1
            }
        }
        return n
    }

    /// The value cut down until it serialises to at most `maxBytes`: the largest lists lose their
    /// tails first, then the longest strings are shortened, so the start of every list, which is
    /// where a crash's own thread and frames sit, is what survives. A value that had to be cut
    /// says so with `"truncated": true`.
    public func fitted(to maxBytes: Int) -> JSONValue {
        var value = self
        var trimmed = false
        var budget = maxBytes - 20
        if estimatedSize <= budget { return self }
        for _ in 0..<4 {
            var steps = 0
            while steps < 2_000, value.estimatedSize > budget, let next = value.trimmedOnce() {
                value = next
                trimmed = true
                steps += 1
            }
            if trimmed, case .object(var o) = value {
                o["truncated"] = .bool(true)
                value = .object(o)
            }
            if value.serialised.count <= maxBytes { return value }
            budget -= max(64, maxBytes / 8)
        }
        return .object(["truncated": .bool(true)])
    }

    /// The smallest of the cuts `0...cuts` whose value serialises to at most `maxBytes`, found by
    /// halving, with that value; nil when even the largest cut is too big. `make` must give a
    /// value no larger for a larger cut.
    static func smallestCut(upTo cuts: Int, maxBytes: Int, _ make: (Int) -> JSONValue) -> (cut: Int, value: JSONValue)? {
        let whole = make(0)
        if whole.serialised.count <= maxBytes { return (0, whole) }
        var low = 1, high = cuts
        var best: (cut: Int, value: JSONValue)?
        while low <= high {
            let middle = (low + high) / 2
            let value = make(middle)
            if value.serialised.count <= maxBytes {
                best = (middle, value)
                high = middle - 1
            } else {
                low = middle + 1
            }
        }
        return best
    }

    /// Every string cut to `maxCharacters` and every list to `maxItems`, with `cut` set when
    /// anything had to go.
    func capped(strings maxCharacters: Int, lists maxItems: Int = .max, cut: inout Bool) -> JSONValue {
        switch self {
        case .string(let s) where s.count > maxCharacters:
            cut = true
            return .string(String(s.prefix(maxCharacters - 1)) + "…")
        case .array(let a):
            if a.count > maxItems { cut = true }
            var out: [JSONValue] = []
            for item in a.prefix(maxItems) { out.append(item.capped(strings: maxCharacters, lists: maxItems, cut: &cut)) }
            return .array(out)
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (key, value) in o { out[key] = value.capped(strings: maxCharacters, lists: maxItems, cut: &cut) }
            return .object(out)
        default:
            return self
        }
    }

    private enum Step: Hashable { case key(String), index(Int) }

    private enum Cut { case halveArray, shortenString, emptyArray }

    private func trimmedOnce() -> JSONValue? {
        var best: (path: [Step], size: Int, cut: Cut)?
        var single: (path: [Step], size: Int)?
        func visit(_ v: JSONValue, _ path: [Step]) {
            switch v {
            case .array(let a):
                let size = v.estimatedSize
                if a.count >= 2 {
                    if size > (best?.size ?? -1) { best = (path, size, .halveArray) }
                } else if a.count == 1, size > (single?.size ?? -1) {
                    single = (path, size)
                }
                for (i, child) in a.enumerated() { visit(child, path + [.index(i)]) }
            case .object(let o):
                for (k, child) in o { visit(child, path + [.key(k)]) }
            case .string(let s) where s.utf8.count > 256:
                let size = v.estimatedSize
                if size > (best?.size ?? -1) { best = (path, size, .shortenString) }
            default:
                break
            }
        }
        visit(self, [])
        if let best { return replacing(at: best.path[...], with: best.cut) }
        if let single { return replacing(at: single.path[...], with: .emptyArray) }
        return nil
    }

    private func replacing(at path: ArraySlice<Step>, with cut: Cut) -> JSONValue {
        guard let step = path.first else {
            switch (self, cut) {
            case (.array(let a), .halveArray): return .array(Array(a.prefix(a.count / 2)))
            case (.array, .emptyArray): return .array([])
            case (.string(let s), .shortenString): return .string(String(s.prefix(s.count / 2)) + "…")
            default: return self
            }
        }
        switch (self, step) {
        case (.array(var a), .index(let i)) where a.indices.contains(i):
            a[i] = a[i].replacing(at: path.dropFirst(), with: cut)
            return .array(a)
        case (.object(var o), .key(let k)):
            o[k] = o[k]?.replacing(at: path.dropFirst(), with: cut)
            return .object(o)
        default:
            return self
        }
    }
}

// MARK: - Text for people to read

extension JSONValue {
    /// Indented JSON that reads well: an object or list short enough for one line stays on it,
    /// and the keys named in `order` come first, in that order, the rest after them A to Z.
    public func readable(order: [String] = [], width: Int = 88) -> String {
        var out = ""
        write(to: &out, indent: 0, column: 0, rank: Dictionary(order.enumerated().map { ($1, $0) }) { a, _ in a }, width: width)
        return out
    }

    private func write(to out: inout String, indent: Int, column: Int, rank: [String: Int], width: Int) {
        if estimatedSize + column <= width {
            let line = oneLine(rank)
            if line.count + column <= width {
                out += line
                return
            }
        }
        let pad = String(repeating: " ", count: indent + 2)
        switch self {
        case .array(let a) where !a.isEmpty:
            out += "[\n"
            for (i, value) in a.enumerated() {
                out += pad
                value.write(to: &out, indent: indent + 2, column: indent + 2, rank: rank, width: width)
                out += i < a.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: " ", count: indent) + "]"
        case .object(let o) where !o.isEmpty:
            out += "{\n"
            let keys = JSONValue.ordered(o.keys, rank)
            for (i, key) in keys.enumerated() {
                let label = JSONValue.quoted(key) + ": "
                out += pad + label
                o[key]?.write(to: &out, indent: indent + 2, column: indent + 2 + label.count, rank: rank, width: width)
                out += i < keys.count - 1 ? ",\n" : "\n"
            }
            out += String(repeating: " ", count: indent) + "}"
        default:
            out += oneLine(rank)
        }
    }

    private func oneLine(_ rank: [String: Int]) -> String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d): return d.isFinite ? String(d) : "0"
        case .string(let s): return JSONValue.quoted(s)
        case .array(let a): return a.isEmpty ? "[]" : "[ " + a.map { $0.oneLine(rank) }.joined(separator: ", ") + " ]"
        case .object(let o):
            guard !o.isEmpty else { return "{}" }
            return "{ " + JSONValue.ordered(o.keys, rank).map { JSONValue.quoted($0) + ": " + (o[$0]?.oneLine(rank) ?? "null") }
                .joined(separator: ", ") + " }"
        }
    }

    private static func ordered(_ keys: Dictionary<String, JSONValue>.Keys, _ rank: [String: Int]) -> [String] {
        keys.sorted { a, b in
            switch (rank[a], rank[b]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a < b
            }
        }
    }

    private static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
