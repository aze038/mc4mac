import XCTest
@testable import FalconCore

final class JSONParserTests: XCTestCase {
    /// JSONDecoder read diagnostics before; the parser that replaced it reads every well-formed
    /// document the same way, and refuses what it refused.
    func testItReadsWhatJSONDecoderRead() {
        let documents = [
            "1.0", "1e3", "-0", "-0.0", "1.5", "0.1e1", "1E2", "12345678901234567890", "9223372036854775807",
            "-9223372036854775808", "9223372036854775808", #""aé😀\n\t\"\\\/""#, "[1,]", #"{"a":1,"a":2}"#,
            #"{"a":1,}"#, "\u{FEFF}{\"a\":1}", " 3 ", "true", "false", "null", "[]", "{}",
            #"{"a":[1,{"b":null}],"c":"x","d":-2.5e-3,"e":[true,false]}"#,
            "\"tab\there\"", "nul", "[1 2]", "01", "-", "1.", ".5", "1e", #""\x""#, #"{"a" 1}"#, "true false", "[,]", "{,}",
            #""\u00""#, "[1,2]]", #"{"a":}"#, "", "NaN", "[1", #"{"a":1"#,
        ]
        for text in documents {
            let old = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            XCTAssertEqual(JSONValue.parse(text), old, text)
        }
    }

    /// A lone surrogate made JSONDecoder drop the whole report; one bad character is not worth that.
    func testALoneSurrogateBecomesAReplacementCharacter() {
        XCTAssertEqual(JSONValue.parse(#""\ud800x""#), .string("\u{FFFD}x"))
    }

    /// Nesting past `maxDepth` is flattened into the objects inside it, in order, each with only
    /// its members that are neither lists nor objects: a deep call stack becomes its frames in order.
    func testNestingPastTheLimitIsFlattenedIntoItsObjectsInOrder() throws {
        let depth = 1_000
        var text = #"{"name":"frame 0","offset":0}"#
        for level in 1..<depth { text = #"{"name":"frame \#(level)","offset":\#(level),"subFrames":["# + text + #"],"tags":[1,2]}"# }
        let value = try XCTUnwrap(JSONValue.parse(text))

        var cursor = value
        var nested = 0
        var levels = 1
        while let next = cursor["subFrames"]?.arrayValue?.first {
            if next["flattened"] != nil {
                cursor = next
                break
            }
            cursor = next
            nested += 1
            levels += 2
        }
        XCTAssertEqual(levels, JSONValue.maxDepth - 1, "every level up to the limit nests as it was")
        XCTAssertEqual(value["tags"], .array([.int(1), .int(2)]))
        let flattened = try XCTUnwrap(cursor["flattened"]?.arrayValue)
        XCTAssertEqual(flattened.count, depth - 1 - nested)
        XCTAssertEqual(flattened.first, .object(["name": .string("frame \(depth - 2 - nested)"), "offset": .int(Int64(depth - 2 - nested))]))
        XCTAssertEqual(flattened.last, .object(["name": .string("frame 0"), "offset": .int(0)]))
        XCTAssertEqual(flattened.map { $0["offset"]?.intValue }, (0..<(depth - 1 - nested)).reversed().map { Int64($0) },
                       "the frames in the order they were written, without their lists")
    }

    /// A crash report lists hundreds of images and a MetricKit payload thousands of frames: adding
    /// to a list or object must not copy what it already holds, which made a long one take minutes.
    func testALongListOrObjectIsReadInTimeProportionalToItsLength() throws {
        let list = "[" + (0..<100_000).map(String.init).joined(separator: ",") + "]"
        let object = "{" + (0..<50_000).map { #""k\#($0)":\#($0)"# }.joined(separator: ",") + "}"
        let start = Date()
        XCTAssertEqual(try XCTUnwrap(JSONValue.parse(list)).arrayValue?.count, 100_000)
        XCTAssertEqual(try XCTUnwrap(JSONValue.parse(object)).objectValue?.count, 50_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "a copy for each item takes about a minute here")
    }

    /// The diagnostics queue's thread has a 512 KB stack. JSONDecoder, a call deeper for each level,
    /// ran out of it at about 300 to 500 levels, crashing FalconMail, and refused anything deeper,
    /// losing the report. A document of any depth now reads, and what it reads is shallow enough
    /// to encode, compare and free there too.
    func testADocumentOfAnyDepthIsReadOnTheDiagnosticsQueuesStack() {
        for depth in [300, 20_000, 200_000] {
            let text = String(repeating: #"{"a":["#, count: depth) + "1" + String(repeating: "]}", count: depth)
            let summary = DiagnosticsFixtures.onQueueSizedStack { () -> String? in
                guard let value = JSONValue.parse(text) else { return nil }
                let encoded = (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "not encoded"
                return value == value && value.estimatedSize > 0 ? String(encoded.suffix(20)) : nil
            }
            XCTAssertNotNil(summary, "\(depth) levels")
        }
    }

    /// A document written back, as a MetricKit diagnostic is for its event ID, reads exactly as
    /// JSONEncoder wrote the value JSONDecoder read: keys sorted, the first of a repeated key, the
    /// same escapes and the same numbers. Checked on documents made at random, the same each run.
    func testItWritesWhatJSONEncoderWrote() throws {
        var seed: UInt64 = 0x5EED
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        // Written as they stand between the quotation marks of JSON text.
        let keys = ["a", "A", "b", "B", "_x", "a1", "a10", "a9", "aB", "a_b", "ab", "é", #"e\u0301"#, "ß", "日本", "😀", "Ａ", "a-b", "a.b",
                    "binaryUUID", "binaryName", "subFrames", "sampleCount", "offsetIntoBinaryTextSegment", "address", "", #"\"q\""#, #"\\"#]
        let strings = ["", "plain", #"q\"b\\s/"#, #"\/slash"#, #"\b\f\n\r\t"#, #"\u0001\u001f\u007f\u0080"#, #"é😀\u2028"#,
                       #"\ud83d\ude00"#, #"\u00e9"#, "Ａ", #"tab\there"#]
        let numbers = ["0", "-0", "1", "-1", "1.0", "1e3", "0.1", "-2.5e-3", "1e21", "1E-7", "123456789.123", "9223372036854775807",
                       "-9223372036854775808", "9223372036854775808", "12345678901234567890", "5e-324", "0.3333333333333333", "100.5"]
        func value(_ depth: Int) -> String {
            switch depth > 5 ? next(4) : next(7) {
            case 0: return "\"" + strings[next(strings.count)] + "\""
            case 1: return numbers[next(numbers.count)]
            case 2: return ["true", "false", "null"][next(3)]
            case 3: return numbers[next(numbers.count)]
            case 4, 5: return "[" + (0..<next(4)).map { _ in value(depth + 1) }.joined(separator: ",") + "]"
            default:
                return "{" + (0..<next(6)).map { _ in "\"" + keys[next(keys.count)] + "\":" + value(depth + 1) }.joined(separator: ",") + "}"
            }
        }
        for _ in 0..<400 {
            let text = value(0)
            let data = Data(text.utf8)
            let decoded = try XCTUnwrap(try? JSONDecoder().decode(JSONValue.self, from: data), text)
            XCTAssertEqual(try XCTUnwrap(JSONDocument(data)).serialised(), String(decoding: decoded.serialised, as: UTF8.self), text)
        }
    }

    /// A document of any depth is written back whole, with nothing flattened, on the diagnostics
    /// queue's 512 KB stack.
    func testADeepDocumentIsWrittenBackWhole() {
        let depth = 100_000
        let text = String(repeating: #"{"a":["#, count: depth) + #"1,{"b":"x"}"# + String(repeating: "]}", count: depth)
        let written = DiagnosticsFixtures.onQueueSizedStack { JSONDocument(Data(text.utf8))?.serialised() }
        XCTAssertTrue(written == text, "written back as it was read")
    }
}
