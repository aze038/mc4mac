import Foundation

/// FalconMail's own crash reports as macOS writes them to ~/Library/Logs/DiagnosticReports:
/// `FalconMail-<date>-<time>.ips`, a one-line JSON header followed by the report's JSON.
public struct CrashReportScanner: Sendable {
    public static let bundleIdentifier = "com.falconmail.app"
    /// On the first run there is no last report, so only this much history is looked at.
    public static let firstRunWindow: TimeInterval = 7 * 24 * 60 * 60
    static let maxPerScan = 10
    static let maxFileSize = 8_000_000

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    public struct Report: Sendable {
        public var url: URL
        public var modified: Date
        public var header: JSONValue
        public var body: JSONValue
    }

    /// What one look at the folder found.
    public struct Scan: Sendable {
        /// The installed app's crashes, oldest first: the newest ten of them.
        public var reports: [Report] = []
        /// Crashes of a FalconMail run from Xcode's build folder, which are never sent.
        public var builtLocally: [Report] = []
        /// The date of the newest file looked at, where the next scan starts.
        public var checkedUntil: Date?
    }

    /// FalconMail's crash reports newer than `after`. Each file is looked at once, newest first:
    /// its one-line header before anything else, and only a report whose header names exactly
    /// this app's bundle identifier is read on, so a snapshot build's crash is never taken for
    /// the real app's, and ten of another build's can never crowd out a real one. A Debug build
    /// shares the identifier, so a report whose app ran from Xcode's build folder is set aside
    /// too; one copied elsewhere first cannot be told apart.
    public func scan(after: Date?, now: Date) -> Scan {
        let fm = FileManager.default
        let cutoff = after ?? now.addingTimeInterval(-CrashReportScanner.firstRunWindow)
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let candidates = names.filter { $0.hasPrefix("FalconMail-") && $0.hasSuffix(".ips") }.compactMap { name -> (URL, Date, Int)? in
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date, modified > cutoff else { return nil }
            return (url, modified, (attributes[.size] as? Int) ?? 0)
        }.sorted { $0.1 > $1.1 }
        var scan = Scan(checkedUntil: candidates.first?.1)
        for (url, modified, size) in candidates where scan.reports.count < CrashReportScanner.maxPerScan {
            guard size <= CrashReportScanner.maxFileSize,
                  CrashReportScanner.header(of: url)?["bundleID"]?.stringValue == CrashReportScanner.bundleIdentifier,
                  let report = CrashReportScanner.report(at: url, modified: modified) else { continue }
            if CrashReportScanner.ranFromBuildFolder(report.body) {
                scan.builtLocally.append(report)
            } else {
                scan.reports.append(report)
            }
        }
        scan.reports.reverse()
        return scan
    }

    private static func header(of url: URL) -> JSONValue? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let start = try? handle.read(upToCount: 16_384), let newline = start.firstIndex(of: 0x0A) else { return nil }
        return JSONValue.parse(Data(start[start.startIndex..<newline]))
    }

    private static func report(at url: URL, modified: Date) -> Report? {
        guard let data = try? Data(contentsOf: url), let newline = data.firstIndex(of: 0x0A),
              let header = JSONValue.parse(Data(data[data.startIndex..<newline])),
              let body = JSONValue.parse(Data(data[data.index(after: newline)...])) else { return nil }
        return Report(url: url, modified: modified, header: header, body: body)
    }

    /// Xcode builds into `…/Build/Products/Debug`, in DerivedData or wherever `-derivedDataPath`
    /// points; a copy people use is never run from there.
    static func ranFromBuildFolder(_ body: JSONValue) -> Bool {
        let path = body["procPath"]?.stringValue ?? ""
        return path.contains("/Build/Products/") || path.contains("/DerivedData/")
    }
}

/// A crash report made into an event: what the triage needs to symbolicate and group it, with
/// every string redacted. A report macOS writes runs to 50–200 KB, ten times what an event's
/// context may hold, so only this goes, still shaped as an .ips so the triage's tools read it:
///
/// - the exception, its type, codes and signal, and its reason (`asi`), with how the app ended;
/// - the crashed thread, its frames and a few registers, and the backtrace an uncaught exception
///   was raised from (`lastExceptionBacktrace`), when there is one;
/// - the images those frames are in, with only their UUID, name, load address and architecture,
///   renumbered in the order the frames use them.
///
/// When that is still too large, frames go, least useful first, until it fits (see `dropOrder`).
/// Each run of frames left out becomes `{"omitted": n}` where it was, and the context says
/// `"trimmed": true`. Nothing else about the Mac or its user is kept.
public enum CrashReportDigest {
    /// What a crash's context may take: the contract's 16 KB, less room for the backend counting
    /// the same JSON a little differently.
    static let budget = DiagnosticsEvent.maxContextBytes - 1_024

    public static func event(from report: CrashReportScanner.Report, install: String,
                             redactor: DiagnosticsRedactor) -> (DiagnosticsEvent, DiagnosticsApp?, String?) {
        let header = report.header
        let body = report.body
        let exception = body["exception"]
        let code = DiagnosticsSignature.crashCode(exception: exception?["type"]?.stringValue, signal: exception?["signal"]?.stringValue)
        let incident = header["incident_id"]?.stringValue ?? body["incident"]?.stringValue ?? report.url.lastPathComponent
        let when = time(of: report)
        var message = "FalconMail crashed (\(code.replacingOccurrences(of: ".", with: ", ")))"
        if let indicator = body["termination"]?["indicator"]?.stringValue { message += ": \(indicator)" }
        if let reason = applicationSpecificInformation(body) { message += "\n" + reason }
        let identity = self.identity(header: header, body: body, code: code, redactor: redactor)
        let context = digest(header: header, body: body, redactor: redactor)
        let event = DiagnosticsEvent(id: DiagnosticsEvent.stableID("ips:\(install):\(incident)"), kind: .crash,
                                     signature: identity.signature, title: identity.title,
                                     area: "crash", firstAt: when, message: redactor.redactCrashReport(message), context: context)
        return (event, app(of: report), header["os_version"]?.stringValue)
    }

    /// When the crash happened, to the second the report gives.
    static func time(of report: CrashReportScanner.Report) -> Date {
        parseDate(report.body["captureTime"]?.stringValue ?? report.header["timestamp"]?.stringValue) ?? report.modified
    }

    /// The build that crashed, which may be older than the one reading the report.
    static func app(of report: CrashReportScanner.Report) -> DiagnosticsApp? {
        report.header["app_version"]?.stringValue.map {
            DiagnosticsApp(version: $0, build: report.header["build_version"]?.stringValue ?? "", channel: "release")
        }
    }

    /// What went wrong and where, from the stack that failed: the backtrace an uncaught exception
    /// was raised from, or else the crashed thread. The exception's name and reason come from the
    /// report's application-specific information, redacted first.
    static func identity(header: JSONValue, body: JSONValue, code: String, redactor: DiagnosticsRedactor) -> CrashIdentity {
        let images = body["usedImages"]?.arrayValue ?? []
        let own = ownImages(header: header, body: body)
        let stack = body["lastExceptionBacktrace"]?.arrayValue ?? crashedThread(body)?["frames"]?.arrayValue ?? []
        let frames = stack.compactMap { frame -> CrashIdentity.Frame? in
            guard let index = frame["imageIndex"]?.intValue, images.indices.contains(Int(index)),
                  let name = images[Int(index)]["name"]?.stringValue else { return nil }
            return CrashIdentity.Frame(binary: name, symbol: frame["symbol"]?.stringValue, own: own.contains(Int(index)))
        }
        let lines = applicationSpecificInformationLines(body).map(redactor.redactCrashReport)
        let (exception, reason) = CrashIdentity.reason(inApplicationSpecificInformation: lines)
        return CrashIdentity(kind: .crash, code: code, exception: exception, reason: reason, frames: frames)
    }

    /// Where FalconMail itself is among the report's images.
    static func ownImages(header: JSONValue, body: JSONValue) -> Set<Int> {
        let appName = body["procName"]?.stringValue ?? header["app_name"]?.stringValue ?? "FalconMail"
        return Set((body["usedImages"]?.arrayValue ?? []).enumerated().compactMap { index, image -> Int? in
            image["name"]?.stringValue == appName || image["CFBundleIdentifier"]?.stringValue == CrashReportScanner.bundleIdentifier ? index : nil
        })
    }

    static func crashedThread(_ body: JSONValue) -> JSONValue? {
        crashedThreadIndex(body).flatMap { body["threads"]?.arrayValue?[$0] }
    }

    static func crashedThreadIndex(_ body: JSONValue) -> Int? {
        let threads = body["threads"]?.arrayValue ?? []
        if let index = body["faultingThread"]?.intValue, threads.indices.contains(Int(index)) { return Int(index) }
        return threads.firstIndex { $0["triggered"]?.boolValue == true }
    }

    static func applicationSpecificInformation(_ body: JSONValue) -> String? {
        let lines = applicationSpecificInformationLines(body)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func applicationSpecificInformationLines(_ body: JSONValue) -> [String] {
        guard let asi = body["asi"]?.objectValue else { return [] }
        return asi.keys.sorted().flatMap { key in (asi[key]?.arrayValue ?? []).compactMap(\.stringValue) }
    }

    static let keptHeader = ["app_version", "build_version", "bug_type", "os_version", "bundleID"]
    /// The exception and how the app ended, each with how many characters of text it may keep.
    static let keptBody: [(key: String, characters: Int)] = [
        ("exception", 300), ("termination", 300), ("ktriageinfo", 600), ("vmRegionInfo", 600),
        ("faultingThread", 0), ("cpuType", 40), ("translated", 0),
    ]
    static let keptFrame: Set<String> = ["imageIndex", "imageOffset", "symbol", "symbolLocation", "inline", "sourceFile", "sourceLine"]
    static let keptImage: Set<String> = ["uuid", "name", "base", "arch"]
    static let keptRegisters: Set<String> = ["pc", "lr", "sp", "fp", "far", "esr", "cpsr", "flavor"]
    /// Where a stack failed: its top frames, which go last of all.
    static let topFrames = 8

    /// A frame of one of the stacks sent: 0 the crashed thread, 1 the exception's backtrace.
    private struct FrameRef: Hashable {
        var stack: Int
        var index: Int
    }

    /// One stack's frames, already redacted, and which of them are in FalconMail itself.
    private struct Stack {
        var frames: [[String: JSONValue]]
        var own: [Bool]
    }

    static func digest(header: JSONValue, body: JSONValue, redactor: DiagnosticsRedactor) -> JSONValue {
        let images = (body["usedImages"]?.arrayValue ?? []).map { image -> JSONValue in
            redactor.redactCrashReport(.object((image.objectValue ?? [:]).filter { keptImage.contains($0.key) }))
        }
        let ownImages = ownImages(header: header, body: body)
        func stack(_ list: [JSONValue]) -> Stack {
            let frames = list.map { frame -> [String: JSONValue] in
                redactor.redactCrashReport(.object((frame.objectValue ?? [:]).filter { keptFrame.contains($0.key) })).objectValue ?? [:]
            }
            return Stack(frames: frames, own: frames.map { $0["imageIndex"]?.intValue.map { ownImages.contains(Int($0)) } ?? false })
        }

        // Redacted before anything is cut, so a cut never leaves half of something the redactor
        // would have recognised whole.
        var cut = false
        var base: [String: JSONValue] = ["source": .string("ips")]
        base["header"] = redactor.redactCrashReport(.object((header.objectValue ?? [:]).filter { keptHeader.contains($0.key) }))
            .capped(strings: 100, cut: &cut)
        for (key, characters) in keptBody {
            base[key] = body[key].map { redactor.redactCrashReport($0).capped(strings: max(characters, 1), lists: 8, cut: &cut) }
        }
        if let asi = body["asi"]?.objectValue {
            let kept = asi.keys.sorted().prefix(4)
            if kept.count < asi.count { cut = true }
            base["asi"] = .object(Dictionary(uniqueKeysWithValues: kept.map { key in
                (key, redactor.redactCrashReport(asi[key] ?? .null).capped(strings: 500, lists: 3, cut: &cut))
            }))
        }

        let threads = body["threads"]?.arrayValue ?? []
        let crashedIndex = crashedThreadIndex(body)
        var shell: [String: JSONValue]?
        var stacks: [Stack] = []
        if let crashedIndex {
            let thread = threads[crashedIndex]
            var t: [String: JSONValue] = ["triggered": .bool(true), "index": .int(Int64(crashedIndex))]
            for key in ["queue", "name"] { t[key] = thread[key].map { redactor.redactCrashReport($0).capped(strings: 100, cut: &cut) } }
            if let state = thread["threadState"]?.objectValue {
                t["threadState"] = redactor.redactCrashReport(.object(state.filter { keptRegisters.contains($0.key) })).capped(strings: 100, cut: &cut)
            }
            shell = t
            stacks.append(stack(thread["frames"]?.arrayValue ?? []))
        } else {
            stacks.append(Stack(frames: [], own: []))
        }
        let backtrace = body["lastExceptionBacktrace"]?.arrayValue
        if let backtrace { stacks.append(stack(backtrace)) }

        let order = dropOrder(stacks)
        let fitted = JSONValue.smallestCut(upTo: order.count, maxBytes: budget) { count in
            assemble(base: base, shell: shell, stacks: stacks, hasBacktrace: backtrace != nil, images: images,
                     dropped: Set(order.prefix(count)), cut: cut)
        }
        if let fitted { return fitted.value }
        // Only an exception with pages of text could get here; its type and signal still go.
        var minimal = cut
        let exception = redactor.redactCrashReport(body["exception"] ?? .null).capped(strings: 100, lists: 4, cut: &minimal)
        return .object(["source": .string("ips"), "exception": exception, "trimmed": .bool(true)])
    }

    /// Frames in the order they go when the report is too large, least useful first:
    ///
    /// 1. frames in other binaries below the top eight, from the bottom of the stack up: the run
    ///    loop and start-up code every stack passes through;
    /// 2. FalconMail's own frames below the top eight, from the bottom up;
    /// 3. the top eight, where the stack failed, from the bottom up.
    ///
    /// At each step the crashed thread's frames go before the backtrace's: when an exception was
    /// raised, the backtrace shows where, and the crashed thread only how it ended the app.
    private static func dropOrder(_ stacks: [Stack]) -> [FrameRef] {
        var order: [FrameRef] = []
        for step in 0..<3 {
            for (s, stack) in stacks.enumerated() {
                for i in stack.frames.indices.reversed() {
                    let rank = i < topFrames ? 2 : stack.own[i] ? 1 : 0
                    if rank == step { order.append(FrameRef(stack: s, index: i)) }
                }
            }
        }
        return order
    }

    /// The context with the frames in `dropped` left out, each run of them counted where it was,
    /// and the images renumbered to those the remaining frames use.
    private static func assemble(base: [String: JSONValue], shell: [String: JSONValue]?, stacks: [Stack], hasBacktrace: Bool,
                                 images: [JSONValue], dropped: Set<FrameRef>, cut: Bool) -> JSONValue {
        var renumbered: [Int: Int] = [:]
        var used: [JSONValue] = []
        func frames(_ s: Int) -> JSONValue {
            var out: [JSONValue] = []
            var gap = 0
            for (i, frame) in stacks[s].frames.enumerated() {
                if dropped.contains(FrameRef(stack: s, index: i)) {
                    gap += 1
                    continue
                }
                if gap > 0 { out.append(.object(["omitted": .int(Int64(gap))])) }
                gap = 0
                var f = frame
                if let index = f["imageIndex"]?.intValue, images.indices.contains(Int(index)) {
                    let old = Int(index)
                    if renumbered[old] == nil {
                        renumbered[old] = used.count
                        used.append(images[old])
                    }
                    f["imageIndex"] = .int(Int64(renumbered[old]!))
                } else {
                    f["imageIndex"] = nil
                }
                out.append(.object(f))
            }
            if gap > 0 { out.append(.object(["omitted": .int(Int64(gap))])) }
            return .array(out)
        }
        var out = base
        if var thread = shell {
            thread["frames"] = frames(0)
            out["threads"] = .array([.object(thread)])
        } else {
            out["threads"] = .array([])
        }
        if hasBacktrace { out["lastExceptionBacktrace"] = frames(1) }
        out["usedImages"] = .array(used)
        if cut || !dropped.isEmpty { out["trimmed"] = .bool(true) }
        return .object(out)
    }

    static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss.SSSS Z", "yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }
}

/// A crash already reported, kept a while so the same crash arriving from the other source,
/// macOS's crash report or MetricKit's, is sent once. MetricKit gives no exact time, only the
/// span its payload covers, so a crash of the same build within that span counts as the same.
struct CrashNote: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case report, metricKit }

    /// The two sources stamp the same crash a little apart: the report when it was written,
    /// MetricKit to its payload's rounded span.
    static let slack: TimeInterval = 10 * 60

    var source: Source
    var from: Date
    var to: Date
    var app: DiagnosticsApp
    /// Set once the other source's copy has been matched to it, so it stands for one crash only.
    var matched = false

    func isSameCrash(as other: CrashNote) -> Bool {
        source != other.source && !matched && !other.matched
            && app.version == other.app.version && app.build == other.app.build
            && from.addingTimeInterval(-CrashNote.slack) <= other.to && other.from.addingTimeInterval(-CrashNote.slack) <= to
    }
}
