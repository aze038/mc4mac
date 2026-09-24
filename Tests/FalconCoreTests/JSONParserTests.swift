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
}
