import Foundation

/// Events from a MetricKit diagnostic payload, read from `MXDiagnosticPayload.jsonRepresentation()`
/// so the mapping can be tested without MetricKit. Each diagnostic keeps its call stacks: binary
/// UUIDs and offsets, which the triage symbolicates with the release's dSYM.
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

    /// FalconMail's own binary, as MetricKit names it.
    static let appBinary = "FalconMail"

    public static func items(from json: Data, install: String, redactor: DiagnosticsRedactor, now: Date) -> [Item] {
        guard let document = JSONDocument(json) else { return [] }
        let payload = document.root
        func time(_ key: String) -> Date? {
            CrashReportDigest.parseDate(document.member(payload, key).flatMap(document.scalar)?.stringValue)
        }
        let begin = time("timeStampBegin") ?? now
        let end = time("timeStampEnd") ?? begin
        var out: [Item] = []
        for section in sections {
            for diagnostic in document.member(payload, section.key).flatMap(document.items) ?? [] {
                out.append(item(document, diagnostic, kind: section.kind, area: section.area, begin: begin, end: end,
                                install: install, redactor: redactor))
            }
        }
        return out
    }

    private static func item(_ document: JSONDocument, _ diagnostic: Int, kind: DiagnosticsKind, area: String, begin: Date, end: Date,
                             install: String, redactor: DiagnosticsRedactor) -> Item {
        let meta = document.member(diagnostic, "diagnosticMetaData").map { document.value($0, maxDepth: JSONValue.maxDepth) } ?? .object([:])
        let tree = document.member(diagnostic, "callStackTree")
        let stacks = threads(document, tree)
        let chain = stacks.first.map { thread in thread.tree.busiestChain().map { thread.tree.fields[$0] } } ?? []
        let signature: String
        let title: String
        var message: String
        switch kind {
        case .crash, .hang:
            var code = "mainThread"
            var exception: String?
            var reason: String?
            if kind == .crash {
                let type = meta["exceptionType"]?.intValue.flatMap { DiagnosticsSignature.exceptionNames[$0] }
                let signal = meta["signal"]?.intValue.flatMap { DiagnosticsSignature.signalNames[$0] }
                code = DiagnosticsSignature.crashCode(exception: type, signal: signal)
                message = "FalconMail crashed (\(code.replacingOccurrences(of: ".", with: ", ")))"
                if let reason = meta["terminationReason"]?.stringValue { message += ": \(reason)" }
                let objc = meta["objectiveCexceptionReason"]
                if let composed = objc?["composedMessage"]?.stringValue {
                    message += "\n" + composed
                    reason = redactor.redactCrashReport(composed)
                }
                exception = objc?["exceptionName"]?.stringValue
            } else {
                message = "FalconMail did not respond for \(meta["hangDuration"]?.stringValue ?? "a while")"
            }
            let frames = chain.map { fields -> CrashIdentity.Frame in
                let binary = fields["binaryName"]?.stringValue ?? "?"
                return CrashIdentity.Frame(binary: binary, symbol: nil, own: binary == appBinary, address: CallTree.place(of: fields))
            }
            let identity = CrashIdentity(kind: kind, code: code, exception: exception, reason: reason, frames: frames)
            signature = identity.signature
            title = identity.title
        default:
            let code = "exceeded"
            if kind == .cpu {
                message = "FalconMail used \(meta["totalCPUTime"]?.stringValue ?? "a lot of") processor time in \(meta["totalSampledTime"]?.stringValue ?? "a short period")"
            } else {
                message = "FalconMail wrote \(meta["writesCaused"]?.stringValue ?? "a lot") to disk"
            }
            // The binary of the top frame of the blamed thread that is not crash machinery.
            let binaries = chain.compactMap { $0["binaryName"]?.stringValue }
            let place = binaries.first { !DiagnosticsSignature.machineryImages.contains($0) } ?? binaries.first ?? appBinary
            signature = DiagnosticsSignature.make(area: area, code: code, place: place)
            title = DiagnosticsTitle.make(kind: kind, area: area, code: code)
        }
        // The diagnostic's whole text, written as JSONEncoder wrote it when JSONDecoder read the
        // payload: the same diagnostic MetricKit hands over again at a later launch, or after an
        // update, keeps its ID however deep its stacks are.
        let event = DiagnosticsEvent(id: DiagnosticsEvent.stableID("metrickit:\(install):\(document.serialised(diagnostic))"),
                                     kind: kind, signature: signature, title: title, area: area.lowercased(),
                                     firstAt: begin, lastAt: end, message: redactor.redactCrashReport(message),
                                     context: context(document, tree: tree, threads: stacks, meta: meta, redactor: redactor))
        let app = meta["appVersion"]?.stringValue.map {
            DiagnosticsApp(version: $0, build: meta["appBuildVersion"]?.stringValue ?? "", channel: "release")
        }
        return Item(event: event, app: app, os: meta["osVersion"]?.stringValue)
    }

    // MARK: Context

    /// What a diagnostic's context may take: the contract's 16 KB, less room for the backend
    /// counting the same JSON a little differently.
    static let budget = DiagnosticsEvent.maxContextBytes - 1_024
    /// How much of each thread goes when there is room: its first four root frames and the three
    /// busiest branches under each frame, as deep as the budget allows.
    static let maxRoots = 4
    static let maxBranches = 3

    /// One thread of the call-stack tree: its own fields, `threadAttributed` among them, and its frames.
    struct Thread {
        var shell: [String: JSONValue]
        var tree: CallTree
        var blamed: Bool { shell["threadAttributed"]?.boolValue == true }
    }

    /// The threads of a call-stack tree, the one MetricKit blames first (the crashed thread, or the
    /// main thread of a hang), then the others as MetricKit lists them.
    static func threads(_ document: JSONDocument, _ tree: Int?) -> [Thread] {
        guard let tree, let stacks = document.member(tree, "callStacks").flatMap(document.items) else { return [] }
        let threads = stacks.compactMap { stack -> Thread? in
            guard document.isObject(stack) else { return nil }
            let roots = document.member(stack, "callStackRootFrames").map { document.isObject($0) ? [$0] : document.items($0) ?? [] } ?? []
            return Thread(shell: document.scalarMembers(stack), tree: CallTree(document, roots: roots))
        }
        return threads.filter(\.blamed) + threads.filter { !$0.blamed }
    }

    /// The call stacks and metadata, redacted and cut until they fit. MetricKit nests each frame
    /// inside the one above it, a level per frame; what is sent lists each thread's frames in
    /// order instead, top first, under `frames`, so no stack's depth makes the context deep:
    ///
    /// - a stack that is one chain of calls, as a crashed thread always is, is listed as it is,
    ///   and a run of frames repeating the ones above it, as a runaway recursion leaves, becomes
    ///   `{"repeated": n, "cycle": k}`: n more frames, repeating the k above;
    /// - a sampled tree that branches, as a hang's may, gives each frame its `depth`, the root
    ///   frames being 0.
    ///
    /// When it is too large: first the threads MetricKit did not blame go, from the last; then all
    /// but the busiest branch of the blamed thread; then its deepest frames, a level at a time.
    /// What was left out is counted where it was: `callStacksOmitted` on the tree, `framesOmitted`
    /// on a thread for its other roots and branches, `{"omitted": n}` in a list of frames, and the
    /// context says `"trimmed": true`.
    static func context(_ document: JSONDocument, tree: Int?, threads: [Thread], meta: JSONValue, redactor: DiagnosticsRedactor) -> JSONValue {
        var cut = false
        let metaData = redactor.redactCrashReport(.object((meta.objectValue ?? [:]).filter { $0.key != "pid" }))
            .capped(strings: 600, lists: 8, cut: &cut)
        guard let tree, document.member(tree, "callStacks").flatMap(document.items) != nil else {
            let raw = tree.map { document.value($0, maxDepth: JSONValue.maxDepth) } ?? .null
            var context: [String: JSONValue] = ["source": .string("metrickit"), "callStackTree": redactor.redactCrashReport(raw),
                                                "diagnosticMetaData": metaData]
            if cut { context["trimmed"] = .bool(true) }
            return .object(context)
        }
        var strings: [String: String] = [:]
        func redacted(_ value: JSONValue) -> JSONValue {
            guard case .string(let s) = value else { return value }
            if let known = strings[s] { return .string(known) }
            let clean = redactor.redactCrashReport(s)
            strings[s] = clean
            return .string(clean)
        }
        let shell = document.scalarMembers(tree).mapValues(redacted)
        let prepared = threads.map { thread -> (shell: [String: JSONValue], tree: CallTree) in
            var tree = thread.tree
            tree.fields = tree.fields.map { $0.mapValues(redacted) }
            return (thread.shell.mapValues(redacted), tree)
        }
        let blamed = threads.prefix { $0.blamed }.count
        let others = threads.count - blamed
        let deepest = max((prepared.first?.tree.busiestChain().count ?? 1) - 1, 0)

        func make(_ step: Int) -> JSONValue {
            let dropped = min(step, others)
            let tighter = step - others
            let limits = CallTree.Limits(roots: tighter >= 1 ? 1 : maxRoots, branches: tighter >= 1 ? 1 : maxBranches,
                                         level: tighter >= 2 ? deepest - (tighter - 1) : .max)
            var trimmed = cut || dropped > 0
            let stacks = prepared.prefix(prepared.count - dropped).map { thread -> JSONValue in
                let listed = thread.tree.listed(limits)
                var stack = thread.shell
                stack["frames"] = .array(listed.frames)
                if listed.otherFrames > 0 { stack["framesOmitted"] = .int(Int64(listed.otherFrames)) }
                trimmed = trimmed || listed.trimmed
                return .object(stack)
            }
            var tree = shell
            tree["callStacks"] = .array(stacks)
            if dropped > 0 { tree["callStacksOmitted"] = .int(Int64(dropped)) }
            var context: [String: JSONValue] = ["source": .string("metrickit"), "callStackTree": .object(tree), "diagnosticMetaData": metaData]
            if trimmed { context["trimmed"] = .bool(true) }
            return .object(context)
        }
        if let fitted = JSONValue.smallestCut(upTo: others + 1 + deepest, maxBytes: budget, make) { return fitted.value }
        return .object(["source": .string("metrickit"), "trimmed": .bool(true),
                        "diagnosticMetaData": metaData.capped(strings: 100, lists: 4, cut: &cut)])
    }
}

/// One thread's call-stack tree, held as flat lists so that a stack of any depth, a stack
/// overflow's included, is walked with loops rather than recursion: each frame's own fields, and
/// the frames under it. MetricKit lists the top of the stack first, as the root, and each caller
/// under the frame it called.
struct CallTree {
    /// Each frame's fields that are not lists or objects: `binaryName`, `binaryUUID`,
    /// `offsetIntoBinaryTextSegment`, `address`, `sampleCount`.
    var fields: [[String: JSONValue]] = []
    var children: [[Int]] = []
    var roots: [Int] = []
    /// How many frames each frame's subtree holds, itself included.
    private(set) var sizes: [Int] = []

    /// The frames under `roots` in `document`, each with the frames in its `subFrames`, at any depth.
    init(_ document: JSONDocument, roots: [Int]) {
        var work: [(value: Int, parent: Int?)] = roots.reversed().map { ($0, nil) }
        while let (value, parent) = work.popLast() {
            guard document.isObject(value) else { continue }
            let node = add(document.scalarMembers(value), under: parent)
            if let below = document.member(value, "subFrames") {
                let frames = document.isObject(below) ? [below] : document.items(below) ?? []
                work.append(contentsOf: frames.reversed().map { ($0, node) })
            }
        }
        sizes = Array(repeating: 1, count: fields.count)
        // A frame is always added after the frame above it.
        for node in fields.indices.reversed() { sizes[node] += children[node].reduce(0) { $0 + sizes[$1] } }
    }

    private mutating func add(_ frame: [String: JSONValue], under parent: Int?) -> Int {
        fields.append(frame)
        children.append([])
        let node = fields.count - 1
        if let parent { children[parent].append(node) } else { roots.append(node) }
        return node
    }

    /// The frames under `node`, busiest first.
    func busiest(under node: Int) -> [Int] {
        children[node].sorted { (fields[$0]["sampleCount"]?.intValue ?? 0) > (fields[$1]["sampleCount"]?.intValue ?? 0) }
    }

    /// The first root and, under each frame, its busiest branch, top first.
    func busiestChain() -> [Int] {
        guard var node = roots.first else { return [] }
        var chain = [node]
        while let next = busiest(under: node).first {
            chain.append(next)
            node = next
        }
        return chain
    }

    struct Limits {
        var roots: Int
        var branches: Int
        /// The deepest level kept, the root frames being level 0.
        var level: Int
    }

    /// The frames kept under `limits`, listed top first (see `MetricKitDiagnostics.context`), and
    /// how many frames of other roots and branches were left out.
    func listed(_ limits: Limits) -> (frames: [JSONValue], otherFrames: Int, trimmed: Bool) {
        let keptRoots = Array(roots.prefix(limits.roots))
        var otherFrames = roots.dropFirst(limits.roots).reduce(0) { $0 + sizes[$1] }

        // One chain of calls: listed as it is, with repeated runs folded.
        var chain: [Int] = []
        var cutBelow = 0
        var node = keptRoots.count == 1 ? keptRoots.first : nil
        while let current = node {
            chain.append(current)
            let under = children[current].reduce(0) { $0 + sizes[$1] }
            if chain.count - 1 >= limits.level {
                cutBelow = under
                break
            }
            let below = busiest(under: current).prefix(limits.branches)
            if below.count > 1 {
                chain = []
                break
            }
            otherFrames += under - (below.first.map { sizes[$0] } ?? 0)
            node = below.first
        }
        if !chain.isEmpty {
            var frames = CallTree.folded(chain, same: sameFrame).map { item -> JSONValue in
                switch item {
                case .frame(let node): return .object(fields[node])
                case .repeated(let count, let cycle): return .object(["repeated": .int(Int64(count)), "cycle": .int(Int64(cycle))])
                }
            }
            if cutBelow > 0 { frames.append(.object(["omitted": .int(Int64(cutBelow))])) }
            return (frames, otherFrames, otherFrames > 0 || cutBelow > 0)
        }
        otherFrames = roots.dropFirst(limits.roots).reduce(0) { $0 + sizes[$1] }

        // A tree that branches: every frame with its depth, and what was left out under a frame
        // counted just after the frames kept under it.
        enum Step { case visit(Int, Int), omitted(Int, Int) }
        var frames: [JSONValue] = []
        var trimmed = otherFrames > 0
        var work: [Step] = keptRoots.reversed().map { .visit($0, 0) }
        while let step = work.popLast() {
            switch step {
            case .visit(let node, let level):
                var frame = fields[node]
                frame["depth"] = .int(Int64(level))
                frames.append(.object(frame))
                let below = level >= limits.level ? [] : Array(busiest(under: node).prefix(limits.branches))
                let left = busiest(under: node).dropFirst(below.count).reduce(0) { $0 + sizes[$1] }
                if left > 0 { work.append(.omitted(left, level + 1)) }
                work.append(contentsOf: below.reversed().map { .visit($0, level + 1) })
            case .omitted(let count, let level):
                frames.append(.object(["omitted": .int(Int64(count)), "depth": .int(Int64(level))]))
                trimmed = true
            }
        }
        return (frames, otherFrames, trimmed)
    }

    /// Two frames at the same place in the same binary, as every frame of a recursion is.
    private func sameFrame(_ a: Int, _ b: Int) -> Bool {
        let x = fields[a], y = fields[b]
        return CallTree.placeFields.allSatisfy { x[$0] == y[$0] }
    }

    /// What says where a frame is: its binary and the offset into it.
    static let placeFields = ["binaryUUID", "binaryName", "offsetIntoBinaryTextSegment", "address"]

    /// Where a frame is, as text two frames can be compared by, the same for every frame at the
    /// same place in one build.
    static func place(of frame: [String: JSONValue]) -> String {
        placeFields.map { frame[$0].map(JSONDocument.serialised) ?? "-" }.joined(separator: " ")
    }

    enum Folded: Equatable {
        case frame(Int)
        /// `count` more frames repeating the `cycle` frames just above.
        case repeated(count: Int, cycle: Int)
    }

    /// The longest cycle a recursion is looked for in: 64 frames, far more than a function
    /// calling itself through a few others takes.
    static let maxCycle = 64

    /// A chain with every run that repeats the frames just above it folded: of `A B A B A B C`,
    /// `A B`, then 4 frames repeating those 2, then `C`. The shortest cycle that covers the most
    /// frames wins, and a run is folded only once it repeats a whole cycle.
    static func folded(_ chain: [Int], same: (Int, Int) -> Bool) -> [Folded] {
        var out: [Folded] = []
        var i = 0
        while i < chain.count {
            var best: (cycle: Int, count: Int)?
            var cycle = 1
            while cycle <= maxCycle, i + 2 * cycle <= chain.count {
                var count = 0
                while i + cycle + count < chain.count, same(chain[i + cycle + count], chain[i + count]) { count += 1 }
                if count >= cycle, cycle + count > (best.map { $0.cycle + $0.count } ?? 0) { best = (cycle, count) }
                cycle += 1
            }
            if let best {
                out.append(contentsOf: chain[i..<i + best.cycle].map(Folded.frame))
                out.append(.repeated(count: best.count, cycle: best.cycle))
                i += best.cycle + best.count
            } else {
                out.append(.frame(chain[i]))
                i += 1
            }
        }
        return out
    }
}
