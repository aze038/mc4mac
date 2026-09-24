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
        let event = DiagnosticsEvent(id: DiagnosticsEvent.stableID("metrickit:\(install):\(String(decoding: diagnostic.serialised, as: UTF8.self))"),
                                     kind: kind, signature: DiagnosticsSignature.make(area: area, code: code, place: place(in: tree)),
                                     title: DiagnosticsTitle.make(kind: kind, area: area, code: code), area: area.lowercased(),
                                     firstAt: begin, lastAt: end, message: redactor.redactCrashReport(message),
                                     context: context(tree: diagnostic["callStackTree"] ?? .null, meta: meta, redactor: redactor))
        let app = meta["appVersion"]?.stringValue.map {
            DiagnosticsApp(version: $0, build: meta["appBuildVersion"]?.stringValue ?? "", channel: "release")
        }
        return Item(event: event, app: app, os: meta["osVersion"]?.stringValue)
    }

    /// What a diagnostic's context may take: the contract's 16 KB, less room for the backend
    /// counting the same JSON a little differently.
    static let budget = DiagnosticsEvent.maxContextBytes - 1_024
    /// How much of each thread's tree goes when there is room: its first four root frames, the
    /// three busiest branches under each frame and sixty-four levels below the root, the frames
    /// nearest the top of the stack. Past that a thread in a crash is start-up code.
    static let maxRoots = 4
    static let maxBranches = 3
    static let maxLevel = 64

    /// The diagnostic's call-stack tree and metadata, redacted, cut until they fit: first the
    /// threads MetricKit did not blame, from the last; then all but the busiest branch of the
    /// blamed thread; then its deepest frames, a level at a time, down to its root frames. What
    /// was left out is counted where it was, `callStacksOmitted` in the tree, `framesOmitted` on
    /// a thread and `subFramesOmitted` on a frame, and the context says `"trimmed": true`.
    static func context(tree raw: JSONValue, meta: JSONValue, redactor: DiagnosticsRedactor) -> JSONValue {
        var cut = false
        let metaData = redactor.redactCrashReport(.object((meta.objectValue ?? [:]).filter { $0.key != "pid" }))
            .capped(strings: 600, lists: 8, cut: &cut)
        let tree = redactor.redactCrashReport(ordered(raw))
        guard case .object(let shell) = tree, let stacks = shell["callStacks"]?.arrayValue else {
            var context: [String: JSONValue] = ["source": .string("metrickit"), "callStackTree": tree, "diagnosticMetaData": metaData]
            if cut { context["trimmed"] = .bool(true) }
            return .object(context)
        }
        let blamed = stacks.prefix { $0["threadAttributed"]?.boolValue == true }.count
        let others = stacks.count - blamed
        func make(_ step: Int) -> JSONValue {
            let dropped = min(step, others)
            let tighter = step - others
            let limits = Limits(roots: tighter >= 1 ? 1 : maxRoots, branches: tighter >= 1 ? 1 : maxBranches,
                                level: tighter >= 2 ? maxLevel - (tighter - 1) : maxLevel)
            var trimmed = cut || dropped > 0
            var t = shell
            t["callStacks"] = .array(stacks.prefix(stacks.count - dropped).map { pruned(stack: $0, limits, &trimmed) })
            if dropped > 0 { t["callStacksOmitted"] = .int(Int64(dropped)) }
            var context: [String: JSONValue] = ["source": .string("metrickit"), "callStackTree": .object(t), "diagnosticMetaData": metaData]
            if trimmed { context["trimmed"] = .bool(true) }
            return .object(context)
        }
        if let fitted = JSONValue.smallestCut(upTo: others + 1 + maxLevel, maxBytes: budget, make) { return fitted.value }
        return .object(["source": .string("metrickit"), "trimmed": .bool(true),
                        "diagnosticMetaData": metaData.capped(strings: 100, lists: 4, cut: &cut)])
    }

    /// The thread MetricKit blames first, the crashed thread or the main thread of a hang, then
    /// the others as MetricKit lists them.
    static func ordered(_ tree: JSONValue) -> JSONValue {
        guard case .object(var o) = tree, let stacks = o["callStacks"]?.arrayValue else { return tree }
        o["callStacks"] = .array(stacks.filter { $0["threadAttributed"]?.boolValue == true } + stacks.filter { $0["threadAttributed"]?.boolValue != true })
        return .object(o)
    }

    /// The tree ordered and cut to the most that ever goes, keeping the frames nearest the top of
    /// each stack.
    static func attributedFirst(_ tree: JSONValue) -> JSONValue {
        guard case .object(var o) = ordered(tree), let stacks = o["callStacks"]?.arrayValue else { return tree }
        var trimmed = false
        o["callStacks"] = .array(stacks.map { pruned(stack: $0, Limits(roots: maxRoots, branches: maxBranches, level: maxLevel), &trimmed) })
        return .object(o)
    }

    private struct Limits {
        var roots: Int
        var branches: Int
        /// The deepest level kept, the root frames being level 0.
        var level: Int
    }

    private static func pruned(stack: JSONValue, _ limits: Limits, _ trimmed: inout Bool) -> JSONValue {
        guard case .object(var s) = stack, let roots = s["callStackRootFrames"]?.arrayValue else { return stack }
        let omitted = roots.dropFirst(limits.roots).reduce(0) { $0 + frameCount($1) }
        s["callStackRootFrames"] = .array(roots.prefix(limits.roots).map { pruned(frame: $0, level: 0, limits, &trimmed) })
        if omitted > 0 {
            s["framesOmitted"] = .int(Int64(omitted))
            trimmed = true
        }
        return .object(s)
    }

    private static func pruned(frame: JSONValue, level: Int, _ limits: Limits, _ trimmed: inout Bool) -> JSONValue {
        guard case .object(var f) = frame, let children = f["subFrames"]?.arrayValue, !children.isEmpty else { return frame }
        let kept = level >= limits.level ? [] : Array(children.sorted { ($0["sampleCount"]?.intValue ?? 0) > ($1["sampleCount"]?.intValue ?? 0) }
            .prefix(limits.branches))
        let omitted = children.reduce(0) { $0 + frameCount($1) } - kept.reduce(0) { $0 + frameCount($1) }
        f["subFrames"] = kept.isEmpty ? nil : .array(kept.map { pruned(frame: $0, level: level + 1, limits, &trimmed) })
        if omitted > 0 {
            f["subFramesOmitted"] = .int(Int64(omitted))
            trimmed = true
        }
        return .object(f)
    }

    /// The frame and every frame below it.
    private static func frameCount(_ frame: JSONValue) -> Int {
        1 + (frame["subFrames"]?.arrayValue ?? []).reduce(0) { $0 + frameCount($1) }
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
