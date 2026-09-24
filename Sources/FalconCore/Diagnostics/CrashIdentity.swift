import Foundation

/// What a crash or hang report says went wrong and where, from which its signature and its title
/// are both made. Nothing in the signature is an address, an offset or any other number, so the
/// same crash reads the same in every build and on every Mac:
///
/// - **What**: the exception type and signal, `EXC_CRASH.SIGABRT`, or `mainThread` for a hang;
///   then an uncaught exception's name, `NSRangeException`, when the report gives one; and
///   `recursion` when the stack is a runaway recursion, a function calling itself until the stack
///   ran out.
/// - **Where**: FalconMail's first frame in the stack that failed, by its function when the report
///   names it, `FalconMail:MessageList.select`. A release build's own frames have no names, so
///   otherwise the named system function nearest above it, the one it called,
///   `Foundation:NSAssertionHandler.handleFailureInMethod`; when nothing above it has a name, the
///   nearest system function below, the one that called it, `FalconMail:calledFrom.NSApplication.sendAction`.
///   MetricKit names no function at all, so there the binary stands in: `libsqlite.dylib`. A
///   stack with no frame of FalconMail's own is placed by its first frame that is not crash
///   machinery.
/// - **Why**, only when FalconMail's own function is not known: the first words of the crash's
///   reason, `invalidParameterNotSatisfyingRow`, without anything quoted, numbered or pathed.
///
/// The title says all three in plain words (see `title`), the place always among them, so the
/// same exception raised in two places is two problems in the Issues tab with two titles.
struct CrashIdentity: Equatable {
    /// One frame of the stack, top first.
    struct Frame {
        var binary: String
        var symbol: String?
        /// In FalconMail itself.
        var own: Bool
        /// Where the frame is in its binary, the same text for every frame at the same place in one
        /// build, by which a recursion is found; nil when the report does not say.
        var address: String? = nil
    }

    struct Place: Equatable {
        /// The binary, as the report names it.
        var binary: String
        var function: String?
        /// When FalconMail's own nameless frame is at the top: the system function, or for
        /// MetricKit the binary, that called it.
        var caller: Caller?
        /// Whether the frame is FalconMail's own.
        var own: Bool
        /// Whether the report had a stack to place it by.
        var known = true

        enum Caller: Equatable {
            case function(String)
            case binary(String)

            var text: String {
                switch self {
                case .function(let name): return name
                case .binary(let name): return DiagnosticsSignature.word(name)
                }
            }

            var shown: String {
                switch self {
                case .function(let name): return name
                case .binary(let name): return CrashIdentity.shownName(name)
                }
            }
        }

        /// `Foundation:NSAssertionHandler.handleFailureInMethod`, for the signature.
        var text: String {
            var out = DiagnosticsSignature.word(binary)
            if let function { out += ":" + function }
            if let caller { out += ":calledFrom." + caller.text }
            return out
        }

        /// `in NSAssertionHandler.handleFailureInMethod`, for a title. `brief` 1 says `called from
        /// AppKit` rather than `in its own code, called from AppKit`, and 2 also leaves out a
        /// function's type: `in handleFailureInMethod`. A type stays when what would be left starts
        /// with a small letter and still has a dot, as `Array.subscript.read` does: `subscript.read`
        /// says less, and reads like a web address, which the diagnostics web app would show as
        /// `subscript[.]read`.
        func phrase(brief: Int = 0) -> String? {
            guard known else { return nil }
            func shown(_ name: String) -> String {
                let rest = name.split(separator: ".").dropFirst()
                guard brief >= 2, let first = rest.first?.first else { return name }
                return rest.count >= 2 && first.isLowercase ? name : rest.joined(separator: ".")
            }
            if let caller {
                let name: String
                if case .function(let function) = caller { name = shown(function) } else { name = caller.shown }
                return (brief >= 1 ? "" : "in its own code, ") + "called from \(name)"
            }
            if let function { return "in \(shown(function))" }
            return own ? "in its own code" : "in \(CrashIdentity.shownName(binary))"
        }
    }

    var kind: DiagnosticsKind
    var code: String
    var exception: String?
    var reason: [String]
    /// Whether the reason goes on past the words kept.
    var reasonCut: Bool
    var recursion: Bool
    var place: Place

    /// `reason` is the text of the crash's reason, already redacted; its first words are kept
    /// only when FalconMail's own function is not known.
    init(kind: DiagnosticsKind, code: String, exception: String?, reason: String?, frames: [Frame]) {
        self.kind = kind
        self.code = code.split(separator: ".").map { DiagnosticsSignature.word(String($0)) }.joined(separator: ".")
        self.exception = exception.map(DiagnosticsSignature.word).flatMap { $0 == "unknown" ? nil : $0 }
        let place = CrashIdentity.place(in: frames)
        self.place = place
        self.recursion = CrashIdentity.isRecursion(frames)
        let named = place.own && place.function != nil
        let why = named ? nil : reason.map { CrashIdentity.words($0, place: place) }
        self.reason = why?.words ?? []
        self.reasonCut = why?.cut ?? false
    }

    /// The grouping key: `Crash.EXC_CRASH.SIGABRT.NSRangeException@FalconMail:MessageList.select`,
    /// or with the reason's words when FalconMail's function is not known,
    /// `Crash.EXC_CRASH.SIGABRT.NSRangeException.indexBeyondBounds@CoreFoundation:NSArrayM.objectAtIndexedSubscript`.
    var signature: String {
        var what = [code]
        if let exception { what.append(exception) }
        if !reason.isEmpty { what.append(DiagnosticsSignature.word(CrashIdentity.camelCase(reason))) }
        if recursion { what.append("recursion") }
        return "\(kind == .hang ? "Hang" : "Crash").\(what.joined(separator: "."))@\(place.text)"
    }

    /// `FalconMail crashed on an internal error (NSRangeException: index beyond bounds, in
    /// NSArrayM.objectAtIndexedSubscript)`: the plain sentence every crash of its kind has, then in
    /// brackets what tells this one apart, in the words its signature holds: the exception and the
    /// reason's words, a runaway recursion, the place, and the exception type and signal when they
    /// are not the ones the sentence stands for. A title that would pass 120 characters says the
    /// same more briefly, a step at a time until it fits: "FalconMail crashed" for a crash on an
    /// internal error, whose exception says the rest, and "called from" for "in its own code,
    /// called from"; then the place's function without its type, unless what is left would start
    /// with a small letter and still have a dot (see `Place.phrase`); then the reason's last
    /// words, the cut marked "…", and then the reason altogether. If it is still too long, as a
    /// long sentence beside a long name can make it, the sentence gives way to its first words,
    /// "FalconMail crashed", with the exception type and signal it stood for, and the details
    /// beside the place make room. The signal is kept longest, then the exception, then a runaway
    /// recursion, and the exception type stands before the signal only while there is room for
    /// it: "FalconMail crashed (runaway recursion, called from
    /// CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION, SIGSEGV)". The place always
    /// stays, as it and the shortest sentence fit in 104 characters.
    /// The title never cuts a word; only a name longer than 60 characters is kept to its first 60,
    /// as it is in the signature (see `DiagnosticsSignature.word`).
    var title: String {
        let sentence = CrashIdentity.sentence(kind: kind, code: code, exception: exception != nil)
        /// The exception type and signal, `EXC_BAD_ACCESS/SIGBUS`, unless `lead` stands for them.
        func tag(saying lead: String) -> String? {
            CrashIdentity.usualCodes[lead] == code ? nil : code.replacingOccurrences(of: ".", with: "/")
        }
        /// What tells this crash apart, in the order a title gives it, with `words` of the reason
        /// (nil leaves the reason out) and the place said as `brief` asks.
        func details(words: Int?, brief: Int, tag: String?) -> [String] {
            var because = ""
            if let words {
                var shown = Array(reason.prefix(words))
                while words < reason.count, let last = shown.last, CrashIdentity.danglingWords.contains(last.lowercased()) {
                    shown.removeLast()
                }
                because = shown.joined(separator: " ")
                if !reason.isEmpty, reasonCut || shown.count < reason.count { because += "…" }
            }
            var out: [String] = []
            if let exception {
                out.append(because.isEmpty ? exception : "\(exception): \(because)")
            } else if !because.isEmpty {
                out.append(because)
            }
            if recursion { out.append("runaway recursion") }
            if let phrase = place.phrase(brief: brief) { out.append(phrase) }
            if let tag { out.append(tag) }
            return out
        }
        func make(_ lead: String, _ details: [String]) -> String {
            details.isEmpty ? lead : "\(lead) (\(details.joined(separator: ", ")))"
        }
        let limit = DiagnosticsEvent.maxTitle
        let usual = tag(saying: sentence)
        let lead = exception != nil ? "FalconMail crashed" : sentence
        var tries: [(lead: String, words: Int?, brief: Int)] = [(sentence, reason.count, 0), (lead, reason.count, 1), (lead, reason.count, 2)]
        tries += (0..<reason.count).reversed().map { (lead, $0, 2) }
        tries.append((lead, nil, 2))
        for (lead, words, brief) in tries {
            let title = make(lead, details(words: words, brief: brief, tag: usual))
            if title.count <= limit { return title }
        }
        // Still too long: the shortest sentence, the place, and as much beside it as fits, the
        // most telling first. Each way of saying it is tried in turn, from keeping everything to
        // keeping the place alone, which always fits.
        let shortest = CrashIdentity.shortSentence(sentence)
        let phrase = place.phrase(brief: 2)
        for keepsSignal in [true, false] {
            for shownException in exception.map({ [$0, nil] }) ?? [nil] {
                // Without its exception, a crash's title no longer says it was an internal error,
                // so its exception type and signal are given instead.
                let full = shownException != nil ? usual : tag(saying: shortest)
                if full == nil, !keepsSignal { continue }
                var tags: [String?] = [nil]
                if keepsSignal, let full {
                    let signal = full.split(separator: "/").last.map(String.init) ?? full
                    tags = signal == full ? [full] : [full, signal]
                }
                for recursive in recursion ? [true, false] : [false] {
                    for tag in tags {
                        let title = make(shortest, [shownException, recursive ? "runaway recursion" : nil, phrase, tag].compactMap { $0 })
                        if title.count <= limit { return title }
                    }
                }
            }
        }
        return make(shortest, [phrase].compactMap { $0 })
    }

    /// The plain sentence a title starts with.
    static func sentence(kind: DiagnosticsKind, code: String, exception: Bool) -> String {
        if kind == .hang { return "FalconMail stopped responding for a while" }
        return exception ? "FalconMail crashed on an internal error" : DiagnosticsTitle.crashSentence(code)
    }

    /// A sentence's first words, for a title too long to say it whole: `FalconMail crashed`,
    /// `FalconMail was stopped` or `FalconMail stopped responding`.
    static func shortSentence(_ sentence: String) -> String {
        for short in ["FalconMail stopped responding", "FalconMail was stopped"] where sentence.hasPrefix(short) { return short }
        return "FalconMail crashed"
    }

    /// The exception type and signal each sentence stands for, which its title leaves unsaid. Any
    /// other is added to the title, so two crashes that differ only there still read apart.
    static let usualCodes: [String: String] = [
        "FalconMail stopped responding for a while": "mainThread",
        "FalconMail stopped responding": "mainThread",
        "FalconMail crashed on an internal error": "EXC_CRASH.SIGABRT",
        "FalconMail crashed: it used memory it should not have": "EXC_BAD_ACCESS.SIGSEGV",
        "FalconMail crashed: a safety check in its code failed": "EXC_BREAKPOINT.SIGTRAP",
        "FalconMail crashed: it stopped itself after an internal error": "EXC_CRASH.SIGABRT",
        "FalconMail was stopped for using too many resources": "EXC_RESOURCE.SIGKILL",
        "FalconMail crashed: it misused a protected system resource": "EXC_GUARD.SIGKILL",
        "FalconMail crashed: a calculation went wrong": "EXC_ARITHMETIC.SIGFPE",
        "FalconMail was stopped by macOS": "EXC_CRASH.SIGKILL",
        "FalconMail crashed": "unknown",
    ]

    /// A binary's name as a title shows it, `libsqlite3.dylib`: only letters, digits, dots,
    /// dashes, underscores and pluses.
    static func shownName(_ binary: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+")
        let kept = String(String.UnicodeScalarView(binary.unicodeScalars.filter(allowed.contains)))
        return kept.isEmpty ? "unknown" : String(kept.prefix(60))
    }

    // MARK: Recursion

    /// How many frames must repeat the ones above them for a stack to be a runaway recursion: far
    /// more than any recursion FalconMail means to make, far fewer than a stack overflow leaves.
    static let runawayFrames = 100

    /// Whether the stack is a runaway recursion: a run of at least `runawayFrames` frames
    /// repeating the ones just above them, as a function calling itself, directly or through a
    /// few others, leaves.
    static func isRecursion(_ frames: [Frame]) -> Bool {
        guard frames.count > runawayFrames else { return false }
        let folded = CallTree.folded(Array(frames.indices)) { a, b in
            frames[a].address != nil && frames[a].address == frames[b].address
        }
        return folded.contains { item in
            if case .repeated(let count, _) = item { return count >= runawayFrames }
            return false
        }
    }

    // MARK: Where

    static func place(in frames: [Frame]) -> Place {
        guard !frames.isEmpty else { return Place(binary: "FalconMail", own: true, known: false) }
        guard let first = frames.firstIndex(where: \.own) else {
            let frame = frames.first { !DiagnosticsSignature.machineryImages.contains($0.binary) } ?? frames[0]
            return Place(binary: frame.binary, function: function(frame.symbol), own: false)
        }
        let ownFrame = frames[first]
        if let name = function(ownFrame.symbol) { return Place(binary: ownFrame.binary, function: name, own: true) }
        for frame in frames[..<first].reversed() {
            if let name = function(frame.symbol) { return Place(binary: frame.binary, function: name, own: false) }
        }
        if first > 0 { return Place(binary: frames[first - 1].binary, own: false) }
        let below = frames[(first + 1)...].filter { !$0.own }
        if let caller = below.lazy.compactMap({ function($0.symbol) }).first.map(Place.Caller.function)
            ?? below.first.map({ Place.Caller.binary($0.binary) }) {
            return Place(binary: ownFrame.binary, caller: caller, own: true)
        }
        return Place(binary: ownFrame.binary, own: true)
    }

    /// A symbol as a crash report writes it, down to its type and function:
    /// `NSAssertionHandler.handleFailureInMethod` from
    /// `-[NSAssertionHandler handleFailureInMethod:object:file:lineNumber:description:]`,
    /// `AppModel.openMessage` from `closure #1 @Sendable () -> () in AppModel.openMessage(id:)`.
    /// Arguments, generic parameters, closures and their types, specialisations and offsets go, so
    /// every build reads the same. A thunk, which only passes a call on, names no function.
    static func function(_ symbol: String?) -> String? {
        guard var s = symbol?.trimmingCharacters(in: .whitespaces), s.contains(where: \.isLetter) else { return nil }
        let ns = s as NSString
        if let m = objcMethod.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            s = demangledClass(ns.substring(with: m.range(at: 1))) + "." + ns.substring(with: m.range(at: 2))
        } else {
            s = withoutGenericParameters(s).replacingOccurrences(of: "::", with: ".")
            // `(1) suspend resume partial function for …`, an async function's part.
            s = s.replacingOccurrences(of: #"^\(\d+\)\s+"#, with: "", options: .regularExpression)
            if thunk.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil { return nil }
            var conformer: String?
            if let r = s.range(of: " in conformance ") {
                conformer = s[r.upperBound...].split(separator: " ").first.map(String.init)
                s = String(s[..<r.lowerBound])
            }
            // A closure, a defer block or a local function, with its own type written before
            // " in ": the function it is in.
            if let r = s.range(of: " in ", options: .backwards) { s = String(s[r.upperBound...]) }
            if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
            s = s.split(separator: " ").last { $0.contains(where: \.isLetter) }.map(String.init) ?? s
            // A protocol's requirement, placed on the type that met it: `MessageList.body.getter`
            // from `protocol witness for View.body.getter in conformance MessageList`.
            if let conformer { s = conformer + "." + s.split(separator: ".").dropFirst().joined(separator: ".") }
        }
        let name = DiagnosticsSignature.word(s.split(separator: ".").suffix(3).joined(separator: "."))
        return name == "unknown" ? nil : name
    }

    /// `thunk for @escaping @callee_guaranteed () -> ()`, `reabstraction thunk helper from …`,
    /// `partial apply for thunk for …`: code the compiler writes to pass a call on.
    private static let thunk = try! NSRegularExpression(pattern: #"^(?:partial apply for |merged |@objc )*(?:reabstraction |dispatch |merged )?thunk\b|\bthunk (?:for|helper)\b"#)

    /// `-[NSView(Layout) layout:]`: the class, without its category, and the selector's first part.
    /// Found anywhere in the symbol, so a block's, `__35-[NSWindow _layout:]_block_invoke`, is its method's.
    private static let objcMethod = try! NSRegularExpression(pattern: #"[-+]\[([^\s(\]\[]+)(?:\([^)]*\))?\s+([^\s:\]]+)"#)

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

    /// At most this many of a reason's words are kept, and at most this many characters of them.
    static let maxReasonWords = 7
    static let maxReasonCharacters = 64

    /// The first words of a reason's first clause, letters only, and whether the reason goes on
    /// past them. What is quoted, anything holding a digit or a slash (an address, an ID, a size, a
    /// path) and a placeholder such as `<addr:…>` go first, and so does an Objective-C method at
    /// the start that is the crash's place already: of `-[__NSArrayM objectAtIndexedSubscript:]:
    /// index 3 beyond bounds [0 .. 2]` at `NSArrayM.objectAtIndexedSubscript`, `index beyond
    /// bounds`. The clause ends at a semicolon, a full stop or a bracket after a space, and a word
    /// such as "for" is never left dangling at the end.
    static func words(_ reason: String, place: Place? = nil) -> (words: [String], cut: Bool) {
        var text = DiagnosticsRedactor.blankingQuoted(reason)
        let ns = text as NSString
        if let m = leadingMethod.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            let bare = CharacterSet(charactersIn: "_")
            let selector = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: bare)
            let rest = ns.substring(from: m.range.location + m.range.length)
            if let name = place?.function?.split(separator: "."), selector == name.last?.trimmingCharacters(in: bare) {
                text = rest
            } else {
                // The class and the selector's first part, `NSNull length`, not every part of it.
                let type = demangledClass(ns.substring(with: m.range(at: 1)).components(separatedBy: "(")[0])
                text = type + " " + selector + " " + rest
            }
        }
        text = text.replacingOccurrences(of: #"<[^<>]*>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\S*[\d/]\S*"#, with: " ", options: .regularExpression)
        if let first = text.firstIndex(where: { $0.isASCII && $0.isLetter }),
           let end = text.range(of: #";|\s[\[(]|\.(?=\s|$)"#, options: .regularExpression, range: first..<text.endIndex) {
            text = String(text[..<end.lowerBound])
        }
        // Letters, and an apostrophe inside a word, as in couldn’t.
        let apostrophes = CharacterSet(charactersIn: "'’")
        let all = text.split(whereSeparator: { !(($0.isASCII && $0.isLetter) || $0 == "'" || $0 == "’") })
            .map { $0.trimmingCharacters(in: apostrophes) }
            .filter { $0.filter(\.isLetter).count > 1 }
            .map { String($0.prefix(30)) }
        var words: [String] = []
        var length = -1
        for word in all.prefix(maxReasonWords) {
            if length + 1 + word.count > maxReasonCharacters { break }
            words.append(word)
            length += 1 + word.count
        }
        var cut = words.count < all.count
        while let last = words.last, danglingWords.contains(last.lowercased()) {
            words.removeLast()
            cut = true
        }
        return (words, cut)
    }

    /// `*** -[__NSArrayM objectAtIndexedSubscript:]:`, with the class and the selector's first part.
    private static let leadingMethod = try! NSRegularExpression(pattern: #"^\s*(?:\*+\s*)?[-+]\[([^\s\]]+)\s+([A-Za-z_][A-Za-z0-9_]*)[^\]]*\]\s*:?"#)

    /// Words a phrase cut short must not end on.
    static let danglingWords: Set<String> = [
        "for", "in", "at", "of", "to", "from", "with", "into", "onto", "and", "or", "but", "the", "an", "this", "these",
        "those", "that", "which", "its", "on", "by", "is", "are", "was", "were", "be", "been", "has", "have", "had",
        "than", "as", "while", "when", "if", "not", "no",
    ]

    /// `invalidParameterNotSatisfyingRow`, with a word such as `NSArrayM` kept as it is.
    static func camelCase(_ words: [String]) -> String {
        words.enumerated().map { index, word in
            if index > 0 { return word.prefix(1).uppercased() + word.dropFirst() }
            let plain = word.dropFirst().allSatisfy(\.isLowercase)
            return plain ? word.prefix(1).lowercased() + word.dropFirst() : word
        }.joined()
    }
}
