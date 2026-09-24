import Foundation

/// Reads JSON into a `JSONValue` with a loop and a stack of its own instead of recursion, so no
/// input can run the thread out of stack, and flattens whatever nests deeper than `maxDepth` (see
/// `JSONValue.maxDepth`). It reads what JSONDecoder read, the same way: a whole number, even one
/// written `1.0` or `1e3`, is an integer; the first of two equal keys wins; a comma may end a list
/// or an object. A lone UTF-16 surrogate or a malformed UTF-8 byte becomes U+FFFD rather than
/// losing the whole report.
struct JSONParser {
    private let bytes: [UInt8]
    private let maxDepth: Int
    private var i = 0

    init(bytes: [UInt8], maxDepth: Int) {
        self.bytes = bytes
        self.maxDepth = maxDepth
    }

    /// A list or object still open, innermost last. What a list or object holds so far is kept
    /// apart, in `lists` and `objects`, so that adding to it changes it in place rather than
    /// copying it each time.
    private enum Open {
        case array
        case object(key: String?)
        /// Inside the flattened part: a list, whose items are not kept.
        case flatArray
        /// Inside the flattened part: an object, at this place in `flattened`.
        case flatObject(Int, key: String?)
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

    private var open: [Open] = []
    private var lists: [[JSONValue]] = []
    private var objects: [[String: JSONValue]] = []
    /// The objects found in the flattened part so far, and how deep it starts.
    private var flattened: [[String: JSONValue]] = []
    private var flatFrom: Int?

    mutating func document() -> JSONValue? {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        var expect = Expect.value

        while true {
            skipWhitespace()
            guard i < bytes.count else { return nil }
            let byte = bytes[i]
            var done: JSONValue?

            switch expect {
            case .commaOrEnd:
                i += 1
                if byte == UInt8(ascii: ",") {
                    switch open.last {
                    case .array?, .flatArray?: expect = .valueOrEnd
                    default: expect = .keyOrEnd
                    }
                    continue
                }
                guard close(byte, &done) else { return nil }
                if done == nil {
                    expect = .commaOrEnd
                    continue
                }
            case .keyOrEnd:
                if byte == UInt8(ascii: "}") {
                    i += 1
                    guard close(byte, &done) else { return nil }
                    if done == nil {
                        expect = .commaOrEnd
                        continue
                    }
                } else {
                    guard byte == UInt8(ascii: "\""), let key = string() else { return nil }
                    skipWhitespace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
                    i += 1
                    switch open.last {
                    case .object?: open[open.count - 1] = .object(key: key)
                    case .flatObject(let at, _)?: open[open.count - 1] = .flatObject(at, key: key)
                    default: return nil
                    }
                    expect = .value
                    continue
                }
            case .valueOrEnd where byte == UInt8(ascii: "]"):
                i += 1
                guard close(byte, &done) else { return nil }
                if done == nil {
                    expect = .commaOrEnd
                    continue
                }
            case .value, .valueOrEnd:
                if byte == UInt8(ascii: "[") || byte == UInt8(ascii: "{") {
                    i += 1
                    let isObject = byte == UInt8(ascii: "{")
                    if flatFrom == nil, open.count + 1 > maxDepth {
                        flatFrom = open.count
                        flattened = []
                    }
                    if flatFrom != nil {
                        if isObject {
                            open.append(.flatObject(flattened.count, key: nil))
                            flattened.append([:])
                        } else {
                            open.append(.flatArray)
                        }
                    } else if isObject {
                        open.append(.object(key: nil))
                        objects.append([:])
                    } else {
                        open.append(.array)
                        lists.append([])
                    }
                    expect = isObject ? .keyOrEnd : .valueOrEnd
                    continue
                }
                guard let scalar = scalar() else { return nil }
                done = scalar
            }

            // A value is complete: it goes into the list or object it is in, or it is the document.
            guard let value = done else { return nil }
            guard let parent = open.last else {
                skipWhitespace()
                return i == bytes.count ? value : nil
            }
            switch parent {
            case .array:
                lists[lists.count - 1].append(value)
            case .object(let key?):
                if objects[objects.count - 1][key] == nil { objects[objects.count - 1][key] = value }
                open[open.count - 1] = .object(key: nil)
            case .flatObject(let at, let key?):
                if flattened[at][key] == nil, value.isScalar { flattened[at][key] = value }
                open[open.count - 1] = .flatObject(at, key: nil)
            case .flatArray:
                break
            default:
                return nil
            }
            expect = .commaOrEnd
        }
    }

    /// Closes the innermost list or object with `byte`, which must match it. `done` is what closed,
    /// or nil for a list or object inside the flattened part, which is kept only in `flattened`.
    private mutating func close(_ byte: UInt8, _ done: inout JSONValue?) -> Bool {
        guard let last = open.popLast() else { return false }
        switch (last, byte) {
        case (.array, UInt8(ascii: "]")):
            done = .array(lists.removeLast())
        case (.object(nil), UInt8(ascii: "}")):
            done = .object(objects.removeLast())
        case (.flatArray, UInt8(ascii: "]")), (.flatObject(_, nil), UInt8(ascii: "}")):
            if let from = flatFrom, open.count == from {
                done = .object(["flattened": .array(flattened.map(JSONValue.object))])
                flattened = []
                flatFrom = nil
            } else if case .flatObject(let at, _)? = open.last {
                // It was the value of a member, which the flattened object leaves out.
                open[open.count - 1] = .flatObject(at, key: nil)
            }
        default:
            return false
        }
        return true
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
