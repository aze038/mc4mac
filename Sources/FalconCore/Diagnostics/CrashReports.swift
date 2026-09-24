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

    /// Reports newer than `after`, oldest first. Only files named for FalconMail are opened,
    /// and only those whose header names exactly this app's bundle identifier are read on, so
    /// a test or snapshot build's crash is never taken for the real app's.
    public func reports(after: Date?, now: Date) -> [Report] {
        let fm = FileManager.default
        let cutoff = after ?? now.addingTimeInterval(-CrashReportScanner.firstRunWindow)
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let candidates = names.filter { $0.hasPrefix("FalconMail-") && $0.hasSuffix(".ips") }.compactMap { name -> (URL, Date)? in
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date, modified > cutoff,
                  ((attributes[.size] as? Int) ?? 0) <= CrashReportScanner.maxFileSize else { return nil }
            return (url, modified)
        }
        return candidates.sorted { $0.1 < $1.1 }.suffix(CrashReportScanner.maxPerScan).compactMap { url, modified in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let newline = data.firstIndex(of: 0x0A) ?? data.endIndex
            guard let header = JSONValue.parse(Data(data[data.startIndex..<newline])),
                  header["bundleID"]?.stringValue == CrashReportScanner.bundleIdentifier,
                  newline < data.endIndex,
                  let body = JSONValue.parse(Data(data[data.index(after: newline)...])) else { return nil }
            return Report(url: url, modified: modified, header: header, body: body)
        }
    }
}

/// A crash report made into an event: what the triage needs to symbolicate and group it,
/// the crashed thread's frames above all, with every string redacted.
public enum CrashReportDigest {
    public static func event(from report: CrashReportScanner.Report, install: String,
                             redactor: DiagnosticsRedactor) -> (DiagnosticsEvent, DiagnosticsApp?, String?) {
        let header = report.header
        let body = report.body
        let exception = body["exception"]
        let code = DiagnosticsSignature.crashCode(exception: exception?["type"]?.stringValue, signal: exception?["signal"]?.stringValue)
        let signature = DiagnosticsSignature.make(area: "Crash", code: code, place: place(in: body))
        let incident = header["incident_id"]?.stringValue ?? body["incident"]?.stringValue ?? report.url.lastPathComponent
        let when = parseDate(body["captureTime"]?.stringValue ?? header["timestamp"]?.stringValue) ?? report.modified
        var message = "FalconMail crashed (\(code.replacingOccurrences(of: ".", with: ", ")))"
        if let indicator = body["termination"]?["indicator"]?.stringValue { message += ": \(indicator)" }
        if let reason = applicationSpecificInformation(body) { message += "\n" + reason }
        let context = redactor.redact(digest(header: header, body: body))
        let event = DiagnosticsEvent(id: DiagnosticsEvent.stableID("ips:\(install):\(incident)"), kind: .crash,
                                     signature: signature, title: DiagnosticsTitle.make(kind: .crash, area: "crash", code: code),
                                     area: "crash", firstAt: when, message: redactor.redact(message), context: context)
        let app = header["app_version"]?.stringValue.map {
            DiagnosticsApp(version: $0, build: header["build_version"]?.stringValue ?? "", channel: "release")
        }
        return (event, app, header["os_version"]?.stringValue)
    }

    /// The image of the first frame of the crashed thread that is not the machinery every
    /// crash goes through.
    static func place(in body: JSONValue) -> String {
        let images = body["usedImages"]?.arrayValue ?? []
        let backtrace = body["lastExceptionBacktrace"]?.arrayValue
        let thread = crashedThread(body)
        let frames = backtrace ?? thread?["frames"]?.arrayValue ?? []
        var first: String?
        for frame in frames {
            guard let index = frame["imageIndex"]?.intValue, images.indices.contains(Int(index)),
                  let name = images[Int(index)]["name"]?.stringValue else { continue }
            if first == nil { first = name }
            if !DiagnosticsSignature.machineryImages.contains(name) { return name }
        }
        return first ?? "FalconMail"
    }

    static func crashedThread(_ body: JSONValue) -> JSONValue? {
        let threads = body["threads"]?.arrayValue ?? []
        if let index = body["faultingThread"]?.intValue, threads.indices.contains(Int(index)) { return threads[Int(index)] }
        return threads.first { $0["triggered"]?.boolValue == true }
    }

    static func applicationSpecificInformation(_ body: JSONValue) -> String? {
        guard let asi = body["asi"]?.objectValue else { return nil }
        let lines = asi.keys.sorted().flatMap { key in (asi[key]?.arrayValue ?? []).compactMap(\.stringValue) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static let keptHeader = ["app_version", "build_version", "bug_type", "os_version", "bundleID", "timestamp", "name"]
    static let keptBody = ["uptime", "procRole", "version", "modelCode", "osVersion", "captureTime", "procLaunch", "cpuType",
                           "translated", "bundleInfo", "exception", "termination", "asi", "ktriageinfo", "vmRegionInfo",
                           "legacyInfo", "faultingThread", "os_fault"]
    static let keptRegisters = ["pc", "lr", "sp", "fp", "far", "esr", "cpsr", "flavor"]

    /// The report cut to what fits an event: the crashed thread with all its frames, the
    /// first frames of the others, the exception's backtrace, and only the images those
    /// frames use, renumbered so the report still reads as an .ips. Identifiers of this Mac
    /// or its user are not kept.
    static func digest(header: JSONValue, body: JSONValue) -> JSONValue {
        let crashed = Int(body["faultingThread"]?.intValue ?? -1)
        let images = body["usedImages"]?.arrayValue ?? []
        for (crashedFrames, otherFrames, otherThreads) in [(128, 8, 40), (64, 3, 20), (48, 0, 0)] {
            var used: [Int: Int] = [:]
            var kept: [JSONValue] = []
            func frames(_ list: [JSONValue], limit: Int) -> [JSONValue] {
                list.prefix(limit).map { frame in
                    guard case .object(var f) = frame else { return frame }
                    if let index = f["imageIndex"]?.intValue, images.indices.contains(Int(index)) {
                        let old = Int(index)
                        if used[old] == nil { used[old] = used.count; kept.append(image(images[old])) }
                        f["imageIndex"] = .int(Int64(used[old]!))
                    }
                    return .object(f.filter { ["imageIndex", "imageOffset", "symbol", "symbolLocation", "inline"].contains($0.key) })
                }
            }
            var threads: [JSONValue] = []
            for (i, thread) in (body["threads"]?.arrayValue ?? []).enumerated() {
                let isCrashed = i == crashed || (crashed < 0 && thread["triggered"]?.boolValue == true)
                guard isCrashed || threads.count < otherThreads || i < crashed else {
                    if crashed >= 0 { break } else { continue }
                }
                var t: [String: JSONValue] = [:]
                for key in ["triggered", "queue", "name"] { t[key] = thread[key] }
                t["frames"] = .array(frames(thread["frames"]?.arrayValue ?? [], limit: isCrashed ? crashedFrames : otherFrames))
                if isCrashed, let state = thread["threadState"]?.objectValue {
                    t["threadState"] = .object(state.filter { keptRegisters.contains($0.key) })
                }
                threads.append(.object(t))
            }
            var out: [String: JSONValue] = ["source": .string("ips")]
            out["header"] = .object((header.objectValue ?? [:]).filter { keptHeader.contains($0.key) })
            for key in keptBody { out[key] = body[key] }
            if case .string(let region)? = out["vmRegionInfo"] { out["vmRegionInfo"] = .string(String(region.prefix(600))) }
            if case .object(let asi)? = out["asi"] {
                out["asi"] = .object(asi.mapValues { lines in .array((lines.arrayValue ?? []).prefix(4).map { .string(String(($0.stringValue ?? "").prefix(1_000))) }) })
            }
            out["threads"] = .array(threads)
            if let backtrace = body["lastExceptionBacktrace"]?.arrayValue {
                out["lastExceptionBacktrace"] = .array(frames(backtrace, limit: crashedFrames))
            }
            out["usedImages"] = .array(kept)
            let value = JSONValue.object(out.compactMapValues { $0 })
            if value.estimatedSize <= DiagnosticsEvent.maxContextBytes - 512 { return value }
        }
        return .object(["source": .string("ips"), "exception": body["exception"] ?? .null, "truncated": .bool(true)])
    }

    private static func image(_ value: JSONValue) -> JSONValue {
        guard case .object(let o) = value else { return value }
        return .object(o.filter { ["uuid", "base", "size", "name", "arch", "CFBundleShortVersionString", "CFBundleIdentifier"].contains($0.key) })
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
