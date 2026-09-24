import Foundation

/// A JSON document read into flat lists, one entry for each value in the order it is written, with
/// a loop and a stack of its own instead of recursion: no input, however deep, can run the thread
/// out of stack, and a value of any depth can be walked, written and freed with loops too.
///
/// It reads what JSONDecoder read, the same way: a whole number, even one written `1.0` or `1e3`,
/// is an integer; the first of two equal keys wins; a comma may end a list or an object. A lone
/// UTF-16 surrogate or a malformed UTF-8 byte becomes U+FFFD rather than losing the whole report.
///
/// `JSONValue.parse` makes a `JSONValue` of it, flattened below `JSONValue.maxDepth`; MetricKit's
/// call stacks, nested a level per frame, are read from the document itself (see `CallTree`), so
/// a stack of any depth keeps its shape.
struct JSONDocument {
    enum Node {
        case scalar(JSONValue)
        case array([Int])
        /// Members in the order written, a repeated key included.
        case object([(key: String, node: Int)])
    }

    /// Every value, a list or object before what it holds: the document itself is 0.
    private(set) var nodes: [Node] = []
    /// How deep each value sits, the document itself being 1.
    private(set) var depths: [Int] = []
    /// The value `i` and what it holds are `i..<ends[i]`.
    private(set) var ends: [Int] = []

    init?(_ data: Data) {
        self.init(bytes: [UInt8](data))
    }

    init?(bytes: [UInt8]) {
        var reader = Reader(bytes: bytes)
        guard reader.read(into: &self) else { return nil }
    }

    var root: Int { 0 }

    // MARK: Reading values

    /// The scalar at `node`, or nil for a list or object.
    func scalar(_ node: Int) -> JSONValue? {
        if case .scalar(let value) = nodes[node] { return value }
        return nil
    }

    func isObject(_ node: Int) -> Bool {
        if case .object = nodes[node] { return true }
        return false
    }

    /// The items of the list at `node`, or nil when it is not a list.
    func items(_ node: Int) -> [Int]? {
        if case .array(let items) = nodes[node] { return items }
        return nil
    }

    /// The member `key` of the object at `node`, the first when the key is repeated.
    func member(_ node: Int, _ key: String) -> Int? {
        guard case .object(let members) = nodes[node] else { return nil }
        return members.first { $0.key == key }?.node
    }

    /// The members of the object at `node` that are neither lists nor objects, as a `JSONValue`
    /// object has them: the first of a repeated key wins, whatever it is.
    func scalarMembers(_ node: Int) -> [String: JSONValue] {
        guard case .object(let members) = nodes[node] else { return [:] }
        var seen = Set<String>()
        var out: [String: JSONValue] = [:]
        for (key, child) in members where seen.insert(key).inserted {
            if case .scalar(let value) = nodes[child] { out[key] = value }
        }
        return out
    }

    /// The value at `node` as a `JSONValue`, with any list or object that would sit more than
    /// `maxDepth` levels below it flattened (see `JSONValue.maxDepth`). Built from the deepest
    /// values up, with no recursion.
    func value(_ node: Int = 0, maxDepth: Int) -> JSONValue {
        let top = depths[node] - 1
        var built = [JSONValue?](repeating: nil, count: ends[node] - node)
        for i in (node..<ends[node]).reversed() {
            let depth = depths[i] - top
            if depth > maxDepth + 1 { continue }
            switch nodes[i] {
            case .scalar(let value):
                built[i - node] = value
            case _ where depth > maxDepth:
                built[i - node] = flattened(i)
            case .array(let items):
                var list: [JSONValue] = []
                list.reserveCapacity(items.count)
                for item in items {
                    list.append(built[item - node] ?? .null)
                    built[item - node] = nil
                }
                built[i - node] = .array(list)
            case .object(let members):
                var object: [String: JSONValue] = [:]
                for (key, child) in members {
                    if object[key] == nil { object[key] = built[child - node] ?? .null }
                    built[child - node] = nil
                }
                built[i - node] = .object(object)
            }
        }
        return built[0] ?? .null
    }

    /// `{"flattened": [...]}`: every object in the value at `node`, itself included, in the order
    /// they are written, each with only its members that are neither lists nor objects, the first
    /// of those for a repeated key.
    private func flattened(_ node: Int) -> JSONValue {
        var objects: [JSONValue] = []
        for i in node..<ends[node] {
            guard case .object(let members) = nodes[i] else { continue }
            var object: [String: JSONValue] = [:]
            for (key, child) in members where object[key] == nil {
                if case .scalar(let value) = nodes[child] { object[key] = value }
            }
            objects.append(.object(object))
        }
        return .object(["flattened": .array(objects)])
    }

    // MARK: Writing

    /// The value at `node` written exactly as `JSONValue.serialised` writes the value it reads as:
    /// compact, keys sorted, the first of a repeated key only. A value of any depth is written,
    /// with no recursion and nothing flattened, so its text, and anything made from it such as a
    /// MetricKit diagnostic's event ID, stays what it was when JSONDecoder read it whole.
    func serialised(_ node: Int = 0) -> String {
        enum Step {
            case value(Int)
            case text(String)
        }
        var out = ""
        var work: [Step] = [.value(node)]
        while let step = work.popLast() {
            switch step {
            case .text(let text):
                out += text
            case .value(let i):
                switch nodes[i] {
                case .scalar(let value):
                    out += JSONDocument.serialised(value)
                case .array(let items):
                    out += "["
                    work.append(.text("]"))
                    for (index, item) in items.enumerated().reversed() {
                        work.append(.value(item))
                        if index > 0 { work.append(.text(",")) }
                    }
                case .object(let members):
                    var seen = Set<String>()
                    let kept = members.filter { seen.insert($0.key).inserted }
                        .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
                    out += "{"
                    work.append(.text("}"))
                    for (index, member) in kept.enumerated().reversed() {
                        work.append(.value(member.node))
                        work.append(.text((index > 0 ? "," : "") + JSONDocument.quoted(member.key) + ":"))
                    }
                }
            }
        }
        return out
    }

    /// A scalar as JSONEncoder writes it.
    static func serialised(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d):
            let text = (d.isFinite ? d : 0).description
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        case .string(let s): return quoted(s)
        case .array, .object: return String(decoding: value.serialised, as: UTF8.self)
        }
    }

    /// A string as JSONEncoder writes it without escaping slashes: the quotation mark, the
    /// backslash and control characters escaped, everything else as it is.
    static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: Parsing

    fileprivate mutating func add(_ node: Node, depth: Int) -> Int {
        nodes.append(node)
        depths.append(depth)
        ends.append(nodes.count)
        return nodes.count - 1
    }

    fileprivate mutating func close(_ node: Int, as value: Node) {
        nodes[node] = value
        ends[node] = nodes.count
    }
}

/// Reads JSON text into a `JSONDocument`.
private struct Reader {
    private let bytes: [UInt8]
    private var i = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// A list or object still open, innermost last.
    private enum Open {
        case array
        case object(key: String?)
    }

    /// What may come next.
    private enum Expect {
        case value
        /// Just after `[` or a comma in a list.
        case valueOrEnd
        /// Just after `{` or a comma in an object.
        case keyOrEnd
        /// Just after a value inside a list or object.
        case commaOrEnd
    }

    /// Reads the whole text into `document`, or gives false when it is not JSON. What an open list
    /// or object holds so far is kept apart, in `lists` and `members`, so that adding to it changes
    /// it in place rather than copying it each time.
    mutating func read(into document: inout JSONDocument) -> Bool {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        var open: [Open] = []
        var openNodes: [Int] = []
        var lists: [[Int]] = []
        var members: [[(key: String, node: Int)]] = []
        var expect = Expect.value

        /// Puts the value just begun, `node`, into the list or object it is in.
        func attach(_ node: Int) -> Bool {
            switch open.last {
            case nil: return node == 0
            case .array?: lists[lists.count - 1].append(node)
            case .object(let key?)?:
                members[members.count - 1].append((key, node))
                open[open.count - 1] = .object(key: nil)
            case .object(nil)?: return false
            }
            return true
        }

        /// Closes the innermost list or object with `byte`, which must match it.
        func close(_ byte: UInt8) -> Bool {
            guard let last = open.popLast(), let node = openNodes.popLast() else { return false }
            switch (last, byte) {
            case (.array, UInt8(ascii: "]")): document.close(node, as: .array(lists.removeLast()))
            case (.object(nil), UInt8(ascii: "}")): document.close(node, as: .object(members.removeLast()))
            default: return false
            }
            return true
        }

        while true {
            skipWhitespace()
            guard i < bytes.count else { return false }
            let byte = bytes[i]

            switch expect {
            case .commaOrEnd:
                i += 1
                if byte == UInt8(ascii: ",") {
                    if case .array? = open.last { expect = .valueOrEnd } else { expect = .keyOrEnd }
                    continue
                }
                guard close(byte) else { return false }
            case .keyOrEnd:
                if byte == UInt8(ascii: "}") {
                    i += 1
                    guard close(byte) else { return false }
                } else {
                    guard byte == UInt8(ascii: "\""), let key = string() else { return false }
                    skipWhitespace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":"), case .object? = open.last else { return false }
                    i += 1
                    open[open.count - 1] = .object(key: key)
                    expect = .value
                    continue
                }
            case .valueOrEnd where byte == UInt8(ascii: "]"):
                i += 1
                guard close(byte) else { return false }
            case .value, .valueOrEnd:
                if byte == UInt8(ascii: "[") || byte == UInt8(ascii: "{") {
                    i += 1
                    let node = document.add(.scalar(.null), depth: open.count + 1)
                    guard attach(node) else { return false }
                    openNodes.append(node)
                    if byte == UInt8(ascii: "{") {
                        open.append(.object(key: nil))
                        members.append([])
                        expect = .keyOrEnd
                    } else {
                        open.append(.array)
                        lists.append([])
                        expect = .valueOrEnd
                    }
                    continue
                }
                guard let value = scalar() else { return false }
                guard attach(document.add(.scalar(value), depth: open.count + 1)) else { return false }
            }

            // A value is complete: the document, or one inside a list or object.
            if open.isEmpty {
                skipWhitespace()
                return i == bytes.count
            }
            expect = .commaOrEnd
        }
    }

    private mutating func skipWhitespace() {
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    private mutating func scalar() -> JSONValue? {
        switch bytes[i] {
        case UInt8(ascii: "\""): return string().map(JSONValue.string)
        case UInt8(ascii: "t"): return literal("true", .bool(true))
        case UInt8(ascii: "f"): return literal("false", .bool(false))
        case UInt8(ascii: "n"): return literal("null", .null)
        default: return number()
        }
    }

    private mutating func literal(_ word: String, _ value: JSONValue) -> JSONValue? {
        let expected = Array(word.utf8)
        guard bytes.count - i >= expected.count, Array(bytes[i..<i + expected.count]) == expected else { return nil }
        i += expected.count
        return value
    }

    /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`, an integer when it is a whole number
    /// that fits one, as JSONDecoder read it.
    private mutating func number() -> JSONValue? {
        let start = i
        func digits() -> Int {
            let from = i
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
            return i - from
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard i < bytes.count else { return nil }
        if bytes[i] == UInt8(ascii: "0") {
            i += 1
        } else if digits() == 0 {
            return nil
        }
        var whole = true
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            guard digits() > 0 else { return nil }
            whole = false
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { return nil }
            whole = false
        }
        let text = String(decoding: bytes[start..<i], as: UTF8.self)
        if whole, let integer = Int64(text) { return .int(integer) }
        guard let double = Double(text), double.isFinite else { return nil }
        if double.rounded() == double, double >= -9.223372036854775808e18, double < 9.223372036854775808e18 {
            return .int(Int64(double))
        }
        return .double(double)
    }

    /// The string starting at the opening quote, with its escapes read. A raw control character
    /// is not allowed in JSON text, and JSONDecoder refused it too.
    private mutating func string() -> String? {
        i += 1
        let start = i
        while i < bytes.count, bytes[i] != UInt8(ascii: "\""), bytes[i] != UInt8(ascii: "\\") {
            guard bytes[i] >= 0x20 else { return nil }
            i += 1
        }
        guard i < bytes.count else { return nil }
        if bytes[i] == UInt8(ascii: "\"") {
            i += 1
            return String(decoding: bytes[start..<i - 1], as: UTF8.self)
        }
        var out = Array(bytes[start..<i])
        while i < bytes.count {
            let byte = bytes[i]
            i += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard i < bytes.count else { return nil }
                let escape = bytes[i]
                i += 1
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escape)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard let unit = hex4() else { return nil }
                    var scalar = Unicode.Scalar(unit)
                    if (0xD800..<0xDC00).contains(unit), bytes.count - i >= 6, bytes[i] == UInt8(ascii: "\\"),
                       bytes[i + 1] == UInt8(ascii: "u") {
                        let mark = i
                        i += 2
                        if let low = hex4(), (0xDC00..<0xE000).contains(low) {
                            scalar = Unicode.Scalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00))
                        } else {
                            i = mark
                        }
                    }
                    out.append(contentsOf: Array(String(Character(scalar ?? "\u{FFFD}")).utf8))
                default:
                    return nil
                }
            default:
                guard byte >= 0x20 else { return nil }
                out.append(byte)
            }
        }
        return nil
    }

    private mutating func hex4() -> UInt16? {
        guard bytes.count - i >= 4 else { return nil }
        var unit: UInt16 = 0
        for byte in bytes[i..<i + 4] {
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: return nil
            }
            unit = unit << 4 | UInt16(digit)
        }
        i += 4
        return unit
    }
}

extension JSONValue {
    /// Neither a list nor an object.
    var isScalar: Bool {
        switch self {
        case .array, .object: return false
        default: return true
        }
    }
}
