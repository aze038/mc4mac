import XCTest
@testable import FalconCore

final class MetricKitDiagnosticsTests: XCTestCase {
    /// Shaped like `MXDiagnosticPayload.jsonRepresentation()` on macOS: one crash, one hang, one
    /// CPU exception and one disk-write exception, each with its call-stack tree.
    static let payload = """
    {
      "timeStampBegin" : "2026-09-20 00:00:00",
      "timeStampEnd" : "2026-09-20 23:59:00",
      "crashDiagnostics" : [
        {
          "version" : "1.0.0",
          "callStackTree" : {
            "callStackPerThread" : true,
            "callStacks" : [
              {
                "threadAttributed" : false,
                "callStackRootFrames" : [
                  { "binaryUUID" : "11111111-2222-3333-4444-555555555555", "offsetIntoBinaryTextSegment" : 4000, "sampleCount" : 1,
                    "binaryName" : "libsystem_kernel.dylib", "address" : 6442454944 }
                ]
              },
              {
                "threadAttributed" : true,
                "callStackRootFrames" : [
                  { "binaryUUID" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "offsetIntoBinaryTextSegment" : 123, "sampleCount" : 1,
                    "binaryName" : "libobjc.A.dylib", "address" : 7170766264,
                    "subFrames" : [
                      { "binaryUUID" : "70B89F27-1634-3580-A695-57CDB41D7743", "offsetIntoBinaryTextSegment" : 165304, "sampleCount" : 1,
                        "binaryName" : "FalconMail", "address" : 4295132600,
                        "subFrames" : [
                          { "binaryUUID" : "70B89F27-1634-3580-A695-57CDB41D7743", "offsetIntoBinaryTextSegment" : 99000, "sampleCount" : 1,
                            "binaryName" : "FalconMail", "address" : 4295066296 }
                        ] }
                    ] }
                ]
              }
            ]
          },
          "diagnosticMetaData" : {
            "appBuildVersion" : "45", "appVersion" : "1.9.0", "regionFormat" : "GB", "exceptionType" : 1,
            "osVersion" : "macOS 26.6 (25G5023)", "deviceType" : "MacBookPro18,3", "signal" : 11, "exceptionCode" : 0,
            "platformArchitecture" : "arm64e", "pid" : 4242,
            "virtualMemoryRegionInfo" : "0 is not in any region. Bytes before following region: 4294967296",
            "terminationReason" : "Namespace SIGNAL, Code 11 Segmentation fault: 11",
            "objectiveCexceptionReason" : { "composedMessage" : "*** -[NSPathStore2 stringByAppendingPathComponent:] for /Users/kmuradoff/Mail and ana@example.com",
                                            "exceptionName" : "NSInvalidArgumentException", "className" : "NSPathStore2", "exceptionType" : "ObjC",
                                            "formatString" : "%@", "arguments" : [] }
          }
        }
      ],
      "hangDiagnostics" : [
        {
          "version" : "1.0.0",
          "callStackTree" : { "callStackPerThread" : true, "callStacks" : [ { "threadAttributed" : true, "callStackRootFrames" : [
            { "binaryUUID" : "11111111-2222-3333-4444-555555555555", "offsetIntoBinaryTextSegment" : 4000, "sampleCount" : 20,
              "binaryName" : "libsystem_kernel.dylib", "address" : 6442454944,
              "subFrames" : [ { "binaryUUID" : "66666666-7777-8888-9999-000000000000", "offsetIntoBinaryTextSegment" : 800, "sampleCount" : 20,
                                "binaryName" : "AppKit", "address" : 6443451744 } ] } ] } ] },
          "diagnosticMetaData" : { "appBuildVersion" : "46", "appVersion" : "1.10.0", "hangDuration" : "4.5 sec",
                                   "osVersion" : "macOS 26.6 (25G5023)", "deviceType" : "MacBookPro18,3", "regionFormat" : "GB" }
        }
      ],
      "cpuExceptionDiagnostics" : [
        {
          "version" : "1.0.0",
          "callStackTree" : { "callStackPerThread" : false, "callStacks" : [ { "threadAttributed" : true, "callStackRootFrames" : [
            { "binaryUUID" : "70B89F27-1634-3580-A695-57CDB41D7743", "offsetIntoBinaryTextSegment" : 5000, "sampleCount" : 300,
              "binaryName" : "FalconMail", "address" : 4295000000 } ] } ] },
          "diagnosticMetaData" : { "appBuildVersion" : "46", "appVersion" : "1.10.0", "totalCPUTime" : "90 sec", "totalSampledTime" : "180 sec",
                                   "osVersion" : "macOS 26.6 (25G5023)", "deviceType" : "MacBookPro18,3", "regionFormat" : "GB" }
        }
      ],
      "diskWriteExceptionDiagnostics" : [
        {
          "version" : "1.0.0",
          "callStackTree" : { "callStackPerThread" : false, "callStacks" : [ { "threadAttributed" : true, "callStackRootFrames" : [
            { "binaryUUID" : "70B89F27-1634-3580-A695-57CDB41D7743", "offsetIntoBinaryTextSegment" : 7000, "sampleCount" : 12,
              "binaryName" : "FalconMail", "address" : 4295002000 } ] } ] },
          "diagnosticMetaData" : { "appBuildVersion" : "46", "appVersion" : "1.10.0", "writesCaused" : "2,147.48 MB",
                                   "osVersion" : "macOS 26.6 (25G5023)", "deviceType" : "MacBookPro18,3", "regionFormat" : "GB" }
        }
      ]
    }
    """

    private let redactor = DiagnosticsRedactor(salt: Data(repeating: 3, count: 32), homePath: "/Users/kmuradoff")
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testEveryDiagnosticBecomesAnEvent() throws {
        let items = MetricKitDiagnostics.items(from: Data(Self.payload.utf8), install: "INSTALL", redactor: redactor, now: now)
        XCTAssertEqual(items.map(\.event.kind), [.crash, .hang, .cpu, .diskwrite])

        let crash = items[0]
        // FalconMail's frame names nothing in MetricKit, so the binary it called stands in.
        XCTAssertEqual(crash.event.signature,
                       "Crash.EXC_BAD_ACCESS.SIGSEGV.NSInvalidArgumentException.stringByAppendingPathComponent@libobjc.A.dylib")
        XCTAssertEqual(crash.event.title, "FalconMail crashed on an internal error (NSInvalidArgumentException: stringByAppendingPathComponent)")
        XCTAssertEqual(crash.app, DiagnosticsApp(version: "1.9.0", build: "45", channel: "release"))
        XCTAssertEqual(crash.os, "macOS 26.6 (25G5023)")
        XCTAssertTrue(crash.event.message.contains("Segmentation fault"))
        XCTAssertFalse(crash.event.message.contains("ana@example.com"))
        XCTAssertFalse(crash.event.message.contains("kmuradoff"))

        let stacks = try XCTUnwrap(crash.event.context["callStackTree"]?["callStacks"]?.arrayValue)
        XCTAssertEqual(stacks.first?["threadAttributed"], .bool(true), "the blamed thread comes first")
        let frames = try XCTUnwrap(stacks.first?["frames"]?.arrayValue, "each thread's frames are listed, top first")
        XCTAssertEqual(frames.map { $0["offsetIntoBinaryTextSegment"] }, [.int(123), .int(165304), .int(99000)])
        XCTAssertEqual(frames[0]["binaryUUID"], .string("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        XCTAssertEqual(frames[0]["address"], .int(7170766264), "addresses stay for symbolication")
        XCTAssertNil(frames[0]["depth"], "a chain of calls needs no depths")
        XCTAssertNil(frames[0]["subFrames"])
        XCTAssertNil(crash.event.context["diagnosticMetaData"]?["pid"])
        XCTAssertEqual(crash.event.context["source"], .string("metrickit"))
        XCTAssertFalse(String(decoding: crash.event.context.serialised, as: UTF8.self).contains("kmuradoff"))

        XCTAssertEqual(items[1].event.signature, "Hang.mainThread@AppKit")
        XCTAssertEqual(items[1].event.title, "FalconMail stopped responding for a while (in AppKit)")
        XCTAssertTrue(items[1].event.message.contains("4.5 sec"))
        XCTAssertEqual(items[2].event.signature, "CPU.exceeded@FalconMail")
        XCTAssertEqual(items[3].event.signature, "DiskWrite.exceeded@FalconMail")
        XCTAssertTrue(items[3].event.message.contains("2,147.48 MB"))
        for item in items { XCTAssertLessThanOrEqual(item.event.context.serialised.count, DiagnosticsEvent.maxContextBytes) }
        XCTAssertNil(crash.event.context["trimmed"], "a small tree goes whole")
    }

    /// A crash diagnostic the size MetricKit gives for a real crash: thirty threads, each a chain
    /// of sixty frames, the crashed one fourth.
    static func fullCrashPayload(threads: Int = 30, crashed: Int = 3, depth: Int = 60, crashedDepth: Int = 60) -> Data {
        func chain(_ thread: Int, _ depth: Int) -> JSONValue {
            var frame = JSONValue.object(["binaryUUID": .string("11111111-2222-3333-4444-555555555555"), "binaryName": .string("dyld"),
                                          "offsetIntoBinaryTextSegment": .int(4_000), "sampleCount": .int(1), "address": .int(6_442_454_944)])
            for level in stride(from: depth - 2, through: 0, by: -1) {
                let own = level % 4 == 1
                frame = .object([
                    "binaryUUID": .string(own ? "70B89F27-1634-3580-A695-57CDB41D7743" : String(format: "%08X-0000-4000-8000-%012X", level, thread)),
                    "binaryName": .string(own ? "FalconMail" : "SystemFramework\(level)"),
                    "offsetIntoBinaryTextSegment": .int(Int64(100_000 + thread * 1_000 + level)), "sampleCount": .int(1),
                    "address": .int(Int64(4_295_000_000 + thread * 1_000 + level)), "subFrames": .array([frame]),
                ])
            }
            return frame
        }
        let stacks = (0..<threads).map { thread -> JSONValue in
            .object(["threadAttributed": .bool(thread == crashed), "callStackRootFrames": .array([chain(thread, thread == crashed ? crashedDepth : depth)])])
        }
        let payload = JSONValue.object([
            "timeStampBegin": .string("2026-09-20 00:00:00 +0000"), "timeStampEnd": .string("2026-09-20 23:59:00 +0000"),
            "crashDiagnostics": .array([.object([
                "callStackTree": .object(["callStackPerThread": .bool(true), "callStacks": .array(stacks)]),
                "diagnosticMetaData": .object(["appVersion": .string("1.9.0"), "appBuildVersion": .string("45"), "exceptionType": .int(1),
                                               "signal": .int(11), "pid": .int(4242), "osVersion": .string("macOS 26.6 (25G5023)")]),
            ])]),
        ])
        return payload.serialised
    }

    /// Ten times the contract's 16 KB: the other threads go, from the last, and the crashed
    /// thread comes first and whole, still valid JSON that says what was left out.
    func testAFullSizeCrashTreeIsCutToTheCrashedThreadFirst() throws {
        let payload = Self.fullCrashPayload()
        XCTAssertGreaterThan(payload.count, 150_000)
        let crash = try XCTUnwrap(MetricKitDiagnostics.items(from: payload, install: "INSTALL", redactor: redactor, now: now).first)
        let context = crash.event.context
        XCTAssertLessThanOrEqual(context.serialised.count, DiagnosticsEvent.maxContextBytes - 1_024)
        XCTAssertEqual(JSONValue.parse(context.serialised), context, "valid JSON")
        XCTAssertNil(context["truncated"], "never cut blindly")
        XCTAssertEqual(context["trimmed"], .bool(true))
        XCTAssertNil(context["diagnosticMetaData"]?["pid"])
        let tree = try XCTUnwrap(context["callStackTree"])
        let stacks = try XCTUnwrap(tree["callStacks"]?.arrayValue)
        XCTAssertEqual(stacks.first?["threadAttributed"], .bool(true), "the crashed thread first")
        XCTAssertEqual(Int(tree["callStacksOmitted"]?.intValue ?? 0) + stacks.count, 30, "the threads left out are counted")
        let frames = try XCTUnwrap(stacks.first?["frames"]?.arrayValue)
        XCTAssertEqual(frames.count, 60, "every frame of the crashed thread")
        XCTAssertEqual(frames.first?["offsetIntoBinaryTextSegment"], .int(103_000))
        XCTAssertEqual(crash.event.signature, "Crash.EXC_BAD_ACCESS.SIGSEGV@SystemFramework")
        XCTAssertEqual(crash.event.title, "FalconMail crashed: it used memory it should not have (in SystemFramework)")
    }

    /// A crashed thread too deep to go whole loses its deepest frames, the start-up code, and
    /// says how many where they were.
    func testACrashedThreadTooDeepToFitLosesItsBottomFrames() throws {
        let payload = Self.fullCrashPayload(threads: 2, crashed: 1, crashedDepth: 200)
        let items = MetricKitDiagnostics.items(from: payload, install: "INSTALL", redactor: redactor, now: now)
        let context = try XCTUnwrap(items.first?.event.context)
        XCTAssertLessThanOrEqual(context.serialised.count, DiagnosticsEvent.maxContextBytes - 1_024)
        XCTAssertEqual(context["trimmed"], .bool(true))
        let stacks = try XCTUnwrap(context["callStackTree"]?["callStacks"]?.arrayValue)
        XCTAssertEqual(stacks.count, 1, "the other thread went first")
        let frames = try XCTUnwrap(stacks[0]["frames"]?.arrayValue)
        XCTAssertEqual(frames.first?["offsetIntoBinaryTextSegment"], .int(101_000), "the top of the stack stays")
        let kept = frames.filter { $0["omitted"] == nil }.count
        XCTAssertGreaterThan(kept, 64, "as many frames as the budget has room for")
        XCTAssertEqual(frames.last?.objectValue?.keys.sorted(), ["omitted"])
        XCTAssertEqual(kept + Int(frames.last?["omitted"]?.intValue ?? 0), 200, "the frames left out are counted at the cut")
    }

    func testTheSamePayloadGivesTheSameIDs() {
        let a = MetricKitDiagnostics.items(from: Data(Self.payload.utf8), install: "INSTALL", redactor: redactor, now: now)
        let b = MetricKitDiagnostics.items(from: Data(Self.payload.utf8), install: "INSTALL", redactor: redactor, now: now.addingTimeInterval(99))
        XCTAssertEqual(a.map(\.event.id), b.map(\.event.id))
        XCTAssertEqual(Set(a.map(\.event.id)).count, 4)
    }

    // MARK: Deep stacks

    /// A frame as MetricKit writes it.
    struct Frame {
        var binary: String
        var offset: Int
        var uuid: String?
        var samples = 1

        static func own(_ offset: Int, build: String = "70B89F27-1634-3580-A695-57CDB41D7743") -> Frame {
            Frame(binary: "FalconMail", offset: offset, uuid: build)
        }

        static func system(_ binary: String, _ offset: Int) -> Frame {
            let tag = binary.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
            return Frame(binary: binary, offset: offset, uuid: "11111111-2222-3333-4444-\(String(format: "%012X", tag))")
        }

        /// Its members, without the braces around them.
        var members: String {
            #""binaryUUID":"\#(uuid ?? "00000000-0000-0000-0000-000000000000")","offsetIntoBinaryTextSegment":\#(offset),"#
                + #""sampleCount":\#(samples),"binaryName":"\#(binary)","address":\#(4_295_000_000 + offset)"#
        }
    }

    /// A payload with one diagnostic whose blamed thread is `frames`, top first, nested as
    /// MetricKit nests them, a level per frame. It is written as text, since a value that deep is
    /// more than JSONEncoder could write.
    static func payload(_ section: String = "crashDiagnostics", frames: [Frame], meta: String = #""exceptionType":1,"signal":11"#) -> Data {
        let opens = frames.dropLast().map { "{" + $0.members + #","subFrames":["# }.joined()
        let chain = opens + "{" + (frames.last?.members ?? "") + "}" + String(repeating: "]}", count: max(frames.count - 1, 0))
        let text = #"{"timeStampBegin":"2026-09-20 00:00:00 +0000","timeStampEnd":"2026-09-20 23:59:00 +0000","\#(section)":[{"#
            + #""callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[\#(chain)]}]},"#
            + #""diagnosticMetaData":{"appVersion":"1.9.0","appBuildVersion":"45",\#(meta)}}]}"#
        return Data(text.utf8)
    }

    private func item(_ payload: Data) throws -> MetricKitDiagnostics.Item {
        try XCTUnwrap(MetricKitDiagnostics.items(from: payload, install: "INSTALL", redactor: redactor, now: now).first)
    }

    private func frames(_ item: MetricKitDiagnostics.Item) throws -> [JSONValue] {
        try XCTUnwrap(item.event.context["callStackTree"]?["callStacks"]?.arrayValue?.first?["frames"]?.arrayValue)
    }

    /// Sixty-four levels was once all a stack kept; now it keeps what the budget has room for.
    func testAStackDeeperThanSixtyFourFramesGoesWholeWhenItFits() throws {
        let stack = (0..<85).map { $0 % 3 == 1 ? Frame.own(100_000 + $0) : Frame.system("SystemFramework\($0)", 20_000 + $0) }
        let item = try item(Self.payload(frames: stack))
        let frames = try frames(item)
        XCTAssertEqual(frames.count, 85)
        XCTAssertEqual(frames.map { $0["offsetIntoBinaryTextSegment"]?.intValue.map(Int.init) }, stack.map(\.offset))
        XCTAssertNil(item.event.context["trimmed"], "nothing was left out")
        XCTAssertLessThanOrEqual(item.event.context.serialised.count, MetricKitDiagnostics.budget)
    }

    /// A stack overflow: a function calling itself thousands of times until the stack ran out.
    /// Its payload nests thousands of levels deep, once too deep to read at all. The recursion is
    /// folded to one turn of it and a count, so the whole stack fits, the bottom that started it
    /// included.
    func testARecursionCrashKeepsItsWholeStackWithTheRepeatsFolded() throws {
        let top = [Frame.system("libsystem_malloc.dylib", 700), Frame.own(5_000)]
        let turn = [Frame.own(6_000), Frame.system("Foundation", 800), Frame.own(7_000)]
        let bottom = [Frame.own(8_000), Frame.system("AppKit", 900), Frame.system("dyld", 1_000)]
        let stack = top + Array(repeating: turn, count: 2_000).flatMap { $0 } + bottom
        let item = try item(Self.payload(frames: stack))
        let frames = try frames(item)
        XCTAssertEqual(frames.map { $0["offsetIntoBinaryTextSegment"]?.intValue ?? -1 }, [700, 5_000, 6_000, 800, 7_000, -1, 8_000, 900, 1_000])
        XCTAssertEqual(frames[5], .object(["repeated": .int(5_997), "cycle": .int(3)]), "the rest of the recursion, counted")
        XCTAssertNil(item.event.context["trimmed"], "nothing was left out: every frame is there or counted")
        XCTAssertEqual(item.event.signature, "Crash.EXC_BAD_ACCESS.SIGSEGV@libsystem_malloc.dylib")
    }

    /// The diagnostics queue runs on a thread with a 512 KB stack. Reading, cutting, identifying
    /// and encoding a deep diagnostic there must never run it out of stack, which would crash
    /// FalconMail itself.
    func testADeepPayloadIsReadOnTheDiagnosticsQueuesStack() throws {
        for depth in [200, 5_000] {
            let stack = (0..<depth).map { $0 % 2 == 0 ? Frame.own(100_000 + $0) : Frame.system("SwiftUI", 30_000 + $0) }
            let payload = Self.payload(frames: stack)
            let (count, context) = DiagnosticsFixtures.onQueueSizedStack { () -> (Int, Data?) in
                let items = MetricKitDiagnostics.items(from: payload, install: "INSTALL", redactor: self.redactor, now: self.now)
                let event = items.first?.event
                return (items.count, event.flatMap { try? DiagnosticsJSON.encoder.encode($0) })
            }
            XCTAssertEqual(count, 1, "\(depth) frames")
            XCTAssertLessThanOrEqual(try XCTUnwrap(context).count, 20_000, "\(depth) frames")
        }
    }

    /// A hang's tree branches where samples differ: every frame then says how deep it is.
    func testABranchingHangTreeListsEachFrameWithItsDepth() throws {
        let text = #"""
        {"hangDiagnostics":[{"callStackTree":{"callStackPerThread":true,"callStacks":[{"threadAttributed":true,"callStackRootFrames":[
          {"binaryName":"libsystem_kernel.dylib","binaryUUID":"K","offsetIntoBinaryTextSegment":1,"sampleCount":10,"subFrames":[
            {"binaryName":"libsqlite3.dylib","binaryUUID":"S","offsetIntoBinaryTextSegment":2,"sampleCount":7,"subFrames":[
              {"binaryName":"FalconMail","binaryUUID":"F","offsetIntoBinaryTextSegment":3,"sampleCount":7}]},
            {"binaryName":"CFNetwork","binaryUUID":"N","offsetIntoBinaryTextSegment":4,"sampleCount":3}]}]}]},
         "diagnosticMetaData":{"hangDuration":"3 sec"}}]}
        """#
        let item = try item(Data(text.utf8))
        let frames = try frames(item)
        XCTAssertEqual(frames.map { $0["depth"] }, [.int(0), .int(1), .int(2), .int(1)])
        XCTAssertEqual(frames.map { $0["binaryName"] }, [.string("libsystem_kernel.dylib"), .string("libsqlite3.dylib"),
                                                          .string("FalconMail"), .string("CFNetwork")], "the busiest branch first")
        XCTAssertEqual(item.event.signature, "Hang.mainThread@libsqlite.dylib", "the binary FalconMail waited in, without its number")
        XCTAssertEqual(item.event.title, "FalconMail stopped responding for a while (in libsqlite.dylib)")
    }

    // MARK: Telling crashes and hangs apart

    /// Two crashes of the same kind with different exceptions are two problems, each with a title
    /// of its own, and the same crash in another build, with every offset and UUID changed, is
    /// still the same one.
    func testCrashesAreToldApartAndTheSameCrashReadsTheSameInEveryBuild() throws {
        func crash(_ name: String, _ message: String, build: String, shift: Int) throws -> DiagnosticsEvent {
            let stack = [Frame.system("CoreFoundation", 10 + shift), Frame.system("libobjc.A.dylib", 20 + shift),
                         Frame.system("Foundation", 30 + shift), Frame.own(4_000 + shift, build: build), Frame.system("AppKit", 50 + shift)]
            let meta = #""exceptionType":10,"signal":6,"objectiveCexceptionReason":{"exceptionName":"\#(name)","composedMessage":"\#(message)"}"#
            return try item(Self.payload(frames: stack, meta: meta)).event
        }
        let range = try crash("NSRangeException", "*** -[__NSArrayM objectAtIndex:]: index 7 beyond bounds [0 .. 3]",
                              build: "70B89F27-1634-3580-A695-57CDB41D7743", shift: 0)
        let sameInAnotherBuild = try crash("NSRangeException", "*** -[__NSArrayM objectAtIndex:]: index 12 beyond bounds [0 .. 9]",
                                           build: "0C0FFEE0-1634-3580-A695-57CDB41D7743", shift: 4_096)
        let other = try crash("NSInternalInconsistencyException", "Invalid parameter not satisfying: row >= 0",
                              build: "70B89F27-1634-3580-A695-57CDB41D7743", shift: 0)
        XCTAssertEqual(range.signature, "Crash.EXC_CRASH.SIGABRT.NSRangeException.NSArrayMObjectAtIndexIndexBeyondBounds@Foundation")
        XCTAssertEqual(range.title, "FalconMail crashed on an internal error (NSRangeException: NSArrayM objectAtIndex index beyond bounds)")
        XCTAssertEqual(sameInAnotherBuild.signature, range.signature)
        XCTAssertEqual(sameInAnotherBuild.title, range.title)
        XCTAssertNotEqual(other.signature, range.signature)
        XCTAssertNotEqual(other.title, range.title)
        XCTAssertEqual(other.title, "FalconMail crashed on an internal error (NSInternalInconsistencyException: Invalid parameter not satisfying row)")
        for event in [range, other] { XCTAssertFalse(event.signature.contains(where: \.isNumber), event.signature) }
    }

    /// A hang in FalconMail's own code, with nothing above it, is placed by what called it.
    func testAHangInFalconMailsOwnCodeIsPlacedByItsCaller() throws {
        let stack = [Frame.own(9_000), Frame.own(9_100), Frame.system("AppKit", 300), Frame.system("dyld", 400)]
        let item = try item(Self.payload("hangDiagnostics", frames: stack, meta: #""hangDuration":"6 sec""#))
        XCTAssertEqual(item.event.signature, "Hang.mainThread@FalconMail:calledFrom.AppKit")
        XCTAssertEqual(item.event.title, "FalconMail stopped responding for a while (in its own code, called from AppKit)")
    }

    func testCentreQueuesEachDiagnosticOnceAndSoon() async throws {
        let directory = DiagnosticsFixtures.temporaryDirectory("metrickit")
        defer { try? FileManager.default.removeItem(at: directory) }
        Log.isEnabled = false
        defer { Log.isEnabled = true }
        let clock = ManualClock(now)
        let center = DiagnosticsCenter(directory: directory, gate: DiagnosticsFixtures.gate(), environment: DiagnosticsFixtures.environment(),
                                       crashReportsDirectory: nil, session: FakeDiagnosticsServer.session(), clock: clock)
        defer {
            center.stop()
            FakeDiagnosticsServer.reset()
        }
        center.start()
        FakeDiagnosticsServer.respond { _, _ in DiagnosticsFixtures.okReply }
        _ = await center.uploadNow()
        XCTAssertEqual(center.nextUploadDate, clock.now().addingTimeInterval(3_600))
        center.ingestMetricKit(Data(Self.payload.utf8))
        center.ingestMetricKit(Data(Self.payload.utf8))
        center.waitUntilIdle()
        let kinds = center.pendingRecords.map(\.event.kind)
        XCTAssertEqual(kinds.filter { $0 != .launch }, [.crash, .hang, .cpu, .diskwrite])
        XCTAssertEqual(center.nextUploadDate, clock.now().addingTimeInterval(60), "a crash or hang goes within a minute")
        XCTAssertEqual(center.pendingRecords.first { $0.event.kind == .hang }?.app.version, "1.10.0")
    }
}
