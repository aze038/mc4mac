import Foundation

/// What a crash or hang report says went wrong and where, from which its signature and its title
/// are both made, so every event of one signature has one title and different crashes do not share
/// either. Nothing in it is an address, an offset or any other number, so the same crash reads the
/// same in every build and on every Mac:
///
/// - **What**: the exception type and signal, `EXC_CRASH.SIGABRT`, or `mainThread` for a hang;
///   then an uncaught exception's name, `NSRangeException`, when the report gives one.
/// - **Where**: FalconMail's first frame in the stack that failed, by its function when the report
///   names it, `FalconMail:MessageList.select`. A release build's own frames have no names, so
///   otherwise the named system function nearest above it, the one it called,
///   `Foundation:NSAssertionHandler.handleFailureInMethod`; when nothing above it has a name, the
///   nearest system function below, the one that called it, `FalconMail:calledFrom.NSApplication.sendAction`.
///   MetricKit names no function at all, so there the binary stands in: `libsqlite3.dylib`. A
///   stack with no frame of FalconMail's own is placed by its first frame that is not crash
///   machinery.
/// - **Why**, only when FalconMail's own function is not known: the first words of the crash's
///   reason, `invalidParameterNotSatisfyingRow`, without anything quoted, numbered or pathed.
struct CrashIdentity: Equatable {
    /// One frame of the stack, top first.
    struct Frame {
        var binary: String
        var symbol: String?
        /// In FalconMail itself.
        var own: Bool
    }

    struct Place: Equatable {
        var binary: String
        var function: String?
        /// When FalconMail's own nameless frame is at the top: the system function, or for
        /// MetricKit the binary, that called it.
        var caller: String?
        /// Whether the frame is FalconMail's own.
        var own: Bool
        /// Whether the report had a stack to place it by.
        var known = true

        /// `Foundation:NSAssertionHandler.handleFailureInMethod`
        var text: String {
            var out = binary
            if let function { out += ":" + function }
            if let caller { out += ":calledFrom." + caller }
            return out
        }

        /// `in NSAssertionHandler.handleFailureInMethod`, for a title.
        var phrase: String? {
            guard known else { return nil }
            if let caller { return "in its own code, called from \(caller)" }
            if let function { return "in \(function)" }
            return own ? "in its own code" : "in \(binary)"
        }
    }

    var kind: DiagnosticsKind
    var code: String
    var exception: String?
    var reason: [String]
    var place: Place

    /// `reason` is the text of the crash's reason, already redacted; its first words are kept
    /// only when FalconMail's own function is not known.
    init(kind: DiagnosticsKind, code: String, exception: String?, reason: String?, frames: [Frame]) {
        self.kind = kind
        self.code = code
        self.exception = exception.map(DiagnosticsSignature.word).flatMap { $0 == "unknown" ? nil : $0 }
        self.place = CrashIdentity.place(in: frames)
        let named = place.own && place.function != nil
        self.reason = named ? [] : reason.map(CrashIdentity.words) ?? []
    }

    /// The grouping key: `Crash.EXC_CRASH.SIGABRT.NSRangeException@FalconMail:MessageList.select`,
    /// or with the reason's words when FalconMail's function is not known,
    /// `Crash.EXC_CRASH.SIGABRT.NSRangeException.indexBeyondBounds@CoreFoundation:NSArrayM.objectAtIndex`.
    var signature: String {
        var what = [code.split(separator: ".").map { DiagnosticsSignature.word(String($0)) }.joined(separator: ".")]
        if let exception { what.append(exception) }
        if !reason.isEmpty { what.append(DiagnosticsSignature.word(CrashIdentity.camelCase(reason))) }
        return "\(kind == .hang ? "Hang" : "Crash").\(what.joined(separator: "."))@\(place.text)"
    }

    /// `FalconMail crashed on an internal error (NSInternalInconsistencyException: Invalid parameter
    /// not satisfying row)`: the plain sentence every crash of its kind has, then what tells this
    /// one apart, in the words its signature holds.
    var title: String {
        let sentence: String
        if kind == .hang {
            sentence = "FalconMail stopped responding for a while"
        } else if exception != nil {
            sentence = "FalconMail crashed on an internal error"
        } else {
            sentence = DiagnosticsTitle.crashSentence(code)
        }
        var details: [String] = []
        let because = reason.joined(separator: " ")
        if let exception {
            details.append(because.isEmpty ? exception : "\(exception): \(because)")
        } else if !because.isEmpty {
            details.append(because)
        }
        if because.isEmpty, let phrase = place.phrase { details.append(phrase) }
        let title = details.isEmpty ? sentence : "\(sentence) (\(details.joined(separator: ", ")))"
        return title.count <= DiagnosticsEvent.maxTitle ? title : String(title.prefix(DiagnosticsEvent.maxTitle - 1)) + "…"
    }

    // MARK: Where

    static func place(in frames: [Frame]) -> Place {
        guard !frames.isEmpty else { return Place(binary: "FalconMail", own: true, known: false) }
        func binary(_ frame: Frame) -> String { DiagnosticsSignature.word(frame.binary) }
        guard let first = frames.firstIndex(where: \.own) else {
            let frame = frames.first { !DiagnosticsSignature.machineryImages.contains($0.binary) } ?? frames[0]
            return Place(binary: binary(frame), function: function(frame.symbol), own: false)
        }
        let ownFrame = frames[first]
        if let name = function(ownFrame.symbol) { return Place(binary: binary(ownFrame), function: name, own: true) }
        for frame in frames[..<first].reversed() {
            if let name = function(frame.symbol) { return Place(binary: binary(frame), function: name, own: false) }
        }
        if first > 0 { return Place(binary: binary(frames[first - 1]), own: false) }
        let below = frames[(first + 1)...].filter { !$0.own }
        if let caller = below.lazy.compactMap({ function($0.symbol) }).first ?? below.first.map(binary) {
            return Place(binary: binary(ownFrame), caller: caller, own: true)
        }
        return Place(binary: binary(ownFrame), own: true)
    }

    /// A symbol as a crash report writes it, down to its type and function:
    /// `NSAssertionHandler.handleFailureInMethod` from
    /// `-[NSAssertionHandler handleFailureInMethod:object:file:lineNumber:description:]`,
    /// `AppModel.openMessage` from `closure #1 in AppModel.openMessage(id:)`. Arguments, generic
    /// parameters, closures, specialisations and offsets go, so every build reads the same.
    static func function(_ symbol: String?) -> String? {
        guard var s = symbol?.trimmingCharacters(in: .whitespaces), s.contains(where: \.isLetter) else { return nil }
        let ns = s as NSString
        if let m = objcMethod.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            s = demangledClass(ns.substring(with: m.range(at: 1))) + "." + ns.substring(with: m.range(at: 2))
        } else {
            s = withoutGenericParameters(s).replacingOccurrences(of: "::", with: ".")
            var conformer: String?
            if let r = s.range(of: " in conformance ") {
                conformer = s[r.upperBound...].split(separator: " ").first.map(String.init)
                s = String(s[..<r.lowerBound])
            }
            if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
            s = s.split(separator: " ").last { $0.contains(where: \.isLetter) }.map(String.init) ?? s
            // A protocol's requirement, placed on the type that met it: `MessageList.body.getter`
            // from `protocol witness for View.body.getter in conformance MessageList`.
            if let conformer { s = conformer + "." + s.split(separator: ".").dropFirst().joined(separator: ".") }
        }
        let name = DiagnosticsSignature.word(s.split(separator: ".").suffix(3).joined(separator: "."))
        return name == "unknown" ? nil : name
    }

    /// `-[NSView(Layout) layout:]`: the class, without its category, and the selector's first part.
    private static let objcMethod = try! NSRegularExpression(pattern: #"^[-+]\[([^\s(\]]+)(?:\([^)]*\))?\s+([^\s:\]]+)"#)

    /// `AppDelegate` from the Swift class name `_TtC10FalconMail11AppDelegate`.
    static func demangledClass(_ name: String) -> String {
        guard name.hasPrefix("_TtC") else { return name }
        var rest = Substring(name.dropFirst(4))
        var parts: [Substring] = []
        while let length = Int(rest.prefix { $0.isASCII && $0.isNumber }), length > 0 {
            rest = rest.drop { $0.isASCII && $0.isNumber }
            guard rest.count >= length else { return name }
            parts.append(rest.prefix(length))
            rest = rest.dropFirst(length)
        }
        return parts.count >= 2 && rest.isEmpty ? parts.dropFirst().joined(separator: ".") : name
    }

    private static func withoutGenericParameters(_ text: String) -> String {
        var out = ""
        var depth = 0
        for character in text {
            if character == "<" {
                depth += 1
            } else if character == ">", depth > 0 {
                depth -= 1
            } else if depth == 0 {
                out.append(character)
            }
        }
        return out
    }

    // MARK: Why

    /// The exception's name and the reason's text in an .ips report's application-specific
    /// information (`asi`), already redacted: `*** Terminating app due to uncaught exception
    /// 'NSRangeException', reason: '…'`, or Swift's `AppModel.swift:42: Fatal error: …`. Other
    /// lines, such as `abort() called`, say only how the app ended.
    static func reason(inApplicationSpecificInformation lines: [String]) -> (exception: String?, reason: String?) {
        for line in lines {
            let ns = line as NSString
            if let m = uncaughtException.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let reason = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2))
                return (ns.substring(with: m.range(at: 1)), reason)
            }
        }
        for line in lines {
            let ns = line as NSString
            if let m = swiftRuntimeError.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                return (nil, m.range(at: 1).location == NSNotFound ? nil : ns.substring(with: m.range(at: 1)))
            }
        }
        return (nil, lines.first { !ignoredLines.contains($0.trimmingCharacters(in: .whitespaces)) })
    }

    private static let uncaughtException = try! NSRegularExpression(pattern: #"uncaught exception '([^'\r\n]*)'(?:, reason: '(.*)')?"#)
    private static let swiftRuntimeError = try! NSRegularExpression(pattern: #"(?:Fatal error|Precondition failed|Assertion failed)(?::\s*(.*))?$"#)
    private static let ignoredLines: Set<String> = ["abort() called"]

    /// The first five words of a reason, letters only: what is quoted, anything holding a digit or
    /// a slash (an address, an ID, a size, a path) and a placeholder such as `<addr:…>` go first,
    /// and so do words such as "for" left dangling at the end.
    static func words(_ reason: String) -> [String] {
        var text = DiagnosticsRedactor.blankingQuoted(reason)
        text = text.replacingOccurrences(of: #"<[^<>]*>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\S*[\d/]\S*"#, with: " ", options: .regularExpression)
        var words = text.split(whereSeparator: { !($0.isASCII && $0.isLetter) }).filter { $0.count > 1 }
            .prefix(5).map { String($0.prefix(30)) }
        while let last = words.last, danglingWords.contains(last.lowercased()) { words.removeLast() }
        return words
    }

    private static let danglingWords: Set<String> = ["for", "in", "at", "of", "to", "from", "with", "and", "or", "the", "an", "on", "by", "is", "was"]

    /// `invalidParameterNotSatisfyingRow`, with a word such as `NSArrayM` kept as it is.
    static func camelCase(_ words: [String]) -> String {
        words.enumerated().map { index, word in
            if index > 0 { return word.prefix(1).uppercased() + word.dropFirst() }
            let plain = word.dropFirst().allSatisfy(\.isLowercase)
            return plain ? word.prefix(1).lowercased() + word.dropFirst() : word
        }.joined()
    }
}
