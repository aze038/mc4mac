import XCTest
@testable import FalconCore

/// A debug build of Swift 6.2 miscompiles an async closure given as a default argument, and
/// calling it brings the app down ("freed pointer was not the last allocation"). Every such
/// closure is therefore passed explicitly (`GmailWait` has the real waits); these tests read
/// the sources and fail if the pattern comes back.
final class NoAsyncClosureDefaultsTests: XCTestCase {
    /// The repository's root, found from this file's own path.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // FalconCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()

    /// `async [throws] -> T = {` on one line: an async closure type followed by a closure default.
    private static let asyncDefault = try! NSRegularExpression(pattern: #"\basync\b(\s+throws)?\s*->[^={}\n]*=\s*\{"#)
    /// A stored property's initial value is not a default argument, so it is allowed.
    private static let declaration = try! NSRegularExpression(
        pattern: #"^\s*(@\w+\s+)*((public|private|internal|fileprivate|open)(\(set\))?\s+)*((static|lazy|nonisolated)\s+)*(var|let)\s"#)

    private func swiftFiles(under folder: String) -> [URL] {
        let base = Self.root.appendingPathComponent(folder, isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The text with comments blanked out, keeping line numbers.
    static func withoutComments(_ text: String) -> String {
        var out = ""
        var inBlock = false
        for line in text.components(separatedBy: "\n") {
            var kept = ""
            var rest = Substring(line)
            while !rest.isEmpty {
                if inBlock {
                    guard let end = rest.range(of: "*/") else { rest = ""; break }
                    rest = rest[end.upperBound...]
                    inBlock = false
                } else if let open = rest.range(of: "/*"), rest.range(of: "//").map({ open.lowerBound < $0.lowerBound }) ?? true {
                    kept += rest[..<open.lowerBound]
                    rest = rest[open.upperBound...]
                    inBlock = true
                } else if let slash = rest.range(of: "//") {
                    kept += rest[..<slash.lowerBound]
                    rest = ""
                } else {
                    kept += rest
                    rest = ""
                }
            }
            out += kept + "\n"
        }
        return out
    }

    /// Each place in `text` where an async closure is a default argument, as "line: text".
    static func asyncClosureDefaults(in text: String) -> [String] {
        let lines = withoutComments(text).components(separatedBy: "\n")
        var found: [String] = []
        for (number, line) in lines.enumerated() {
            let whole = NSRange(line.startIndex..., in: line)
            guard asyncDefault.firstMatch(in: line, range: whole) != nil,
                  declaration.firstMatch(in: line, range: whole) == nil else { continue }
            found.append("\(number + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
        return found
    }

    func testTheGuardFindsTheMiscompiledPatternAndLetsStoredPropertiesBe() {
        let parameters = """
        public init(sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
        init(cursor: @escaping @Sendable () async -> HistoryID? = { nil },
                    wentOut: @escaping @Sendable () async -> Void = {}, keeps: Bool = false) {
        func run(allowance: @escaping @Sendable (_ bytes: Int) async throws -> Bool = { _ in false }) {}
        """
        XCTAssertEqual(Self.asyncClosureDefaults(in: parameters).count, 4)
        let allowed = """
        public var deleteCopy: @MainActor (Copy) async throws -> Void = { _ in }
            public static let sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        init(sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {}
        // init(sleep: @escaping () async -> Void = {}) in a comment
        let now: @Sendable () -> Date = { Date() }
        """
        XCTAssertEqual(Self.asyncClosureDefaults(in: allowed), [])
    }

    func testNoAsyncClosureIsADefaultArgumentInFalconCoreOrTheApp() throws {
        let files = swiftFiles(under: "Sources/FalconCore") + swiftFiles(under: "App")
        XCTAssertGreaterThan(files.count, 100, "the sources were found from \(Self.root.path)")
        var found: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let relative = String(file.path.dropFirst(Self.root.path.count + 1))
            found += Self.asyncClosureDefaults(in: text).map { "\(relative):\($0)" }
        }
        XCTAssertEqual(found, [], "pass these closures explicitly (see GmailWait); a debug build of Swift 6.2 crashes calling them")
    }

    func testNoQuotaLimiterIsMadeByADefaultArgument() throws {
        // `GmailQuotaLimiter`'s wait is an async closure, so a limiter made as a default would
        // carry whatever the caller did not choose.
        let pattern = try NSRegularExpression(pattern: #":\s*GmailQuotaLimiter\s*=\s*GmailQuotaLimiter\("#)
        var found: [String] = []
        for file in swiftFiles(under: "Sources/FalconCore") + swiftFiles(under: "App") {
            let text = Self.withoutComments(try String(contentsOf: file, encoding: .utf8))
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { found.append(file.lastPathComponent) }
        }
        XCTAssertEqual(found, [])
    }

    /// What the owner reads when Google has turned Gmail off for FalconMail names nothing they
    /// cannot act on: no "API", "build" or "project".
    func testTheGmailEngineAndSenderSentencesUseNoDeveloperWords() throws {
        let literal = try NSRegularExpression(pattern: #""([^"\\\n]|\\.)*""#)
        let jargon = try NSRegularExpression(pattern: #"\b(API|build|project)\b"#)
        var found: [String] = []
        for path in ["Sources/FalconCore/GmailEngine/GmailPollSchedule.swift", "Sources/FalconCore/Gmail/GmailSender.swift"] {
            let text = Self.withoutComments(try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8))
            for match in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let sentence = String(text[range])
                if jargon.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) != nil { found.append(sentence) }
            }
        }
        XCTAssertEqual(found, [])
    }
}
