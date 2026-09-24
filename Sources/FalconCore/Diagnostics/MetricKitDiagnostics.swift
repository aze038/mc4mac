import Foundation

/// Events from a MetricKit diagnostic payload, read from `MXDiagnosticPayload.jsonRepresentation()`
/// so the mapping can be tested without MetricKit. Each diagnostic keeps its call-stack tree:
/// binary UUIDs and offsets, which the triage symbolicates with the release's dSYM.
public enum MetricKitDiagnostics {
    public struct Item: Sendable {
        public var event: DiagnosticsEvent
        public var app: DiagnosticsApp?
        public var os: String?
    }

    private static let sections: [(key: String, kind: DiagnosticsKind, area: String)] = [
        ("crashDiagnostics", .crash, "Crash"),
        ("hangDiagnostics", .hang, "Hang"),
        ("cpuExceptionDiagnostics", .cpu, "CPU"),
        ("diskWriteExceptionDiagnostics", .diskwrite, "DiskWrite"),
    ]

    public static func items(from json: Data, install: String, redactor: DiagnosticsRedactor, now: Date) -> [Item] {
        guard let payload = JSONValue.parse(json) else { return [] }
        let begin = CrashReportDigest.parseDate(payload["timeStampBegin"]?.stringValue) ?? now
        let end = CrashReportDigest.parseDate(payload["timeStampEnd"]?.stringValue) ?? begin
        var out: [Item] = []
        for section in sections {
            for diagnostic in payload[section.key]?.arrayValue ?? [] {
                out.append(item(diagnostic, kind: section.kind, area: section.area, begin: begin, end: end,
                                install: install, redactor: redactor))
            }
        }
        return out
    }

    private static func item(_ diagnostic: JSONValue, kind: DiagnosticsKind, area: String, begin: Date, end: Date,
                             install: String, redactor: DiagnosticsRedactor) -> Item {
        let meta = diagnostic["diagnosticMetaData"] ?? .object([:])
        let tree = attributedFirst(diagnostic["callStackTree"] ?? .null)
        let code: String
        var message: String
        switch kind {
        case .crash:
            let exception = meta["exceptionType"]?.intValue.flatMap { DiagnosticsSignature.exceptionNames[$0] }
            let signal = meta["signal"]?.intValue.flatMap { DiagnosticsSignature.signalNames[$0] }
            code = DiagnosticsSignature.crashCode(exception: exception, signal: signal)
            message = "FalconMail crashed (\(code.replacingOccurrences(of: ".", with: ", ")))"
            if let reason = meta["terminationReason"]?.stringValue { message += ": \(reason)" }
            if let objc = meta["objectiveCexceptionReason"]?["composedMessage"]?.stringValue { message += "\n" + objc }
        case .hang:
            code = "mainThread"
            message = "FalconMail did not respond for \(meta["hangDuration"]?.stringValue ?? "a while")"
        case .cpu:
            code = "exceeded"
            message = "FalconMail used \(meta["totalCPUTime"]?.stringValue ?? "a lot of") processor time in \(meta["totalSampledTime"]?.stringValue ?? "a short period")"
        default:
            code = "exceeded"
            message = "FalconMail wrote \(meta["writesCaused"]?.stringValue ?? "a lot") to disk"
        }
        var context: [String: JSONValue] = ["source": .string("metrickit"), "callStackTree": tree]
        context["diagnosticMetaData"] = .object((meta.objectValue ?? [:]).filter { $0.key != "pid" })
        let event = DiagnosticsEvent(id: DiagnosticsEvent.stableID("metrickit:\(install):\(String(decoding: diagnostic.serialised, as: UTF8.self))"),
                                     kind: kind, signature: DiagnosticsSignature.make(area: area, code: code, place: place(in: tree)),
                                     title: DiagnosticsTitle.make(kind: kind, area: area, code: code), area: area.lowercased(),
                                     firstAt: begin, lastAt: end, message: redactor.redact(message),
                                     context: redactor.redact(.object(context)))
        let app = meta["appVersion"]?.stringValue.map {
            DiagnosticsApp(version: $0, build: meta["appBuildVersion"]?.stringValue ?? "", channel: "release")
        }
        return Item(event: event, app: app, os: meta["osVersion"]?.stringValue)
    }

    /// The thread MetricKit blames first, then the others; each tree cut to a depth and
    /// breadth that fits, keeping the frames nearest the top of the stack.
    static func attributedFirst(_ tree: JSONValue) -> JSONValue {
        guard case .object(var o) = tree, let stacks = o["callStacks"]?.arrayValue else { return tree }
        let ordered = stacks.filter { $0["threadAttributed"]?.boolValue == true } + stacks.filter { $0["threadAttributed"]?.boolValue != true }
        o["callStacks"] = .array(ordered.map { stack in
            guard case .object(var s) = stack, let roots = s["callStackRootFrames"]?.arrayValue else { return stack }
            s["callStackRootFrames"] = .array(roots.prefix(4).map { pruned($0, depth: 0) })
            return .object(s)
        })
        return .object(o)
    }

    private static func pruned(_ frame: JSONValue, depth: Int) -> JSONValue {
        guard case .object(var f) = frame else { return frame }
        if let children = f["subFrames"]?.arrayValue {
            if depth >= 64 {
                f["subFrames"] = nil
            } else {
                let busiest = children.sorted { ($0["sampleCount"]?.intValue ?? 0) > ($1["sampleCount"]?.intValue ?? 0) }.prefix(3)
                f["subFrames"] = .array(busiest.map { pruned($0, depth: depth + 1) })
            }
        }
        return .object(f)
    }

    /// The binary of the top frame of the blamed thread that is not crash machinery.
    static func place(in tree: JSONValue) -> String {
        guard var frame = tree["callStacks"]?.arrayValue?.first?["callStackRootFrames"]?.arrayValue?.first else { return "FalconMail" }
        var first: String?
        while true {
            if let name = frame["binaryName"]?.stringValue {
                if first == nil { first = name }
                if !DiagnosticsSignature.machineryImages.contains(name) { return name }
            }
            guard let next = frame["subFrames"]?.arrayValue?.first else { break }
            frame = next
        }
        return first ?? "FalconMail"
    }
}
