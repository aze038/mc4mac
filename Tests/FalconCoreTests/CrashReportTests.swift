import XCTest
@testable import FalconCore

final class CrashReportTests: XCTestCase {
    private var directory: URL!
    private var reports: URL!
    private var centers: [DiagnosticsCenter] = []
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        directory = DiagnosticsFixtures.temporaryDirectory("crash-center")
        reports = DiagnosticsFixtures.temporaryDirectory("crash-reports")
        Log.isEnabled = false
    }

    override func tearDown() {
        centers.forEach { $0.stop() }
        Log.observer = nil
        Log.isEnabled = true
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: reports)
    }

    /// A report shaped like the ones macOS writes: a one-line header, then the body.
    static func ips(bundle: String = "com.falconmail.app", incident: String = UUID().uuidString, threads: Int = 3,
                    framesPerThread: Int = 20, home: String = "/Users/kmuradoff",
                    appPath: String = "/Applications/FalconMail.app", asi: String? = nil) -> String {
        let header = """
        {"app_name":"FalconMail","timestamp":"2026-09-20 10:11:12.00 +0100","app_version":"1.9.0","slice_uuid":"0B1C2D3E-0000-1111-2222-333344445555","build_version":"45","platform":1,"bundleID":"\(bundle)","share_with_app_devs":0,"is_first_party":0,"bug_type":"309","os_version":"macOS 26.6 (25G5023)","roots_installed":0,"name":"FalconMail","incident_id":"\(incident)"}
        """
        let images = """
        [{"source":"P","arch":"arm64","base":4294967296,"size":9437184,"uuid":"70B89F27-1634-3580-A695-57CDB41D7743","path":"\(home)/Applications/FalconMail.app/Contents/MacOS/FalconMail","name":"FalconMail","CFBundleIdentifier":"com.falconmail.app","CFBundleShortVersionString":"1.9.0","CFBundleVersion":"45"},
         {"source":"P","arch":"arm64e","base":6442450944,"size":245760,"uuid":"11111111-2222-3333-4444-555555555555","path":"/usr/lib/system/libsystem_kernel.dylib","name":"libsystem_kernel.dylib"},
         {"source":"P","arch":"arm64e","base":6443450944,"size":5000000,"uuid":"66666666-7777-8888-9999-000000000000","path":"/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit","name":"AppKit","CFBundleIdentifier":"com.apple.AppKit"},
         {"source":"P","arch":"arm64e","base":6444450944,"size":5000000,"uuid":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","path":"/usr/lib/swift/libswiftCore.dylib","name":"libswiftCore.dylib"}]
        """
        func frames(crashed: Bool) -> String {
            var list: [String] = []
            if crashed {
                list.append(#"{"imageOffset":12345,"symbol":"__pthread_kill","symbolLocation":8,"imageIndex":1}"#)
                list.append(#"{"imageOffset":2048,"symbol":"swift_unexpectedError","symbolLocation":4,"imageIndex":3}"#)
            }
            for i in 0..<framesPerThread {
                list.append(#"{"imageOffset":\#(1000 + i * 16),"imageIndex":\#(i % 3 == 0 ? 2 : 0)}"#)
            }
            return "[" + list.joined(separator: ",") + "]"
        }
        let threadList = (0..<threads).map { i -> String in
            let crashed = i == 1
            let state = crashed ? #","threadState":{"x":[{"value":0},{"value":1}],"pc":{"value":4295012345},"lr":{"value":4295000000},"far":{"value":0},"esr":{"value":4060086272,"description":"(Breakpoint) brk 1"},"flavor":"ARM_THREAD_STATE64"}"# : ""
            return #"{"id":\#(1000 + i),"queue":"com.apple.main-thread"\#(crashed ? #","triggered":true"# : "")\#(state),"frames":\#(frames(crashed: crashed))}"#
        }.joined(separator: ",")
        let body = """
        {"uptime":1200,"procRole":"Foreground","version":2,"userID":501,"deployVersion":210,"modelCode":"MacBookPro18,3",
         "coalitionID":1234,"osVersion":{"train":"macOS 26.6","build":"25G5023","releaseType":"User"},
         "captureTime":"2026-09-20 10:11:12.3456 +0100","incident":"\(incident)","pid":4242,"cpuType":"ARM-64",
         "procLaunch":"2026-09-20 09:51:12.0000 +0100","procPath":"\(appPath)/Contents/MacOS/FalconMail",
         "bundleInfo":{"CFBundleShortVersionString":"1.9.0","CFBundleVersion":"45","CFBundleIdentifier":"\(bundle)"},
         "crashReporterKey":"D4F2E1C0-SECRET-KEY","sleepWakeUUID":"ABCDEF","bootSessionUUID":"123456",
         "exception":{"codes":"0x0000000000000001, 0x0000000000000000","rawCodes":[1,0],"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
         "termination":{"flags":0,"code":5,"namespace":"SIGNAL","indicator":"Trace/BPT trap: 5","byProc":"exc handler","byPid":4242},
         "asi":\(asi ?? #"{"libswiftCore.dylib":["FalconMail/AppModel.swift:42: Fatal error: no account for ana@example.com in \#(home)/Library/x"]}"#),
         "faultingThread":1,"threads":[\(threadList)],"usedImages":\(images),
         "sharedCache":{"base":6442450944,"size":4000000000,"uuid":"99999999-8888-7777-6666-555555555555"},
         "vmSummary":"ReadOnly portion of Libraries: Total=1.5G resident=0K(0%) swapped_out_or_unallocated=1.5G(100%)",
         "legacyInfo":{"threadTriggered":{"queue":"com.apple.main-thread"}}}
        """
        return header + "\n" + body.replacingOccurrences(of: "\n", with: "")
    }

    /// A report the size macOS writes for a real crash, about 170 KB: an uncaught exception on the
    /// main thread with the backtrace it was raised from, thirty threads of symbolicated frames and
    /// the two hundred and fifty images a Mac app loads, each with its full path.
    static func fullIPS(backtrace: Bool = true, crashedFrames: Int = 60) -> String {
        let header = """
        {"app_name":"FalconMail","timestamp":"2026-09-20 10:11:12.00 +0100","app_version":"1.9.0","slice_uuid":"70B89F27-1634-3580-A695-57CDB41D7743","build_version":"45","platform":1,"bundleID":"com.falconmail.app","share_with_app_devs":0,"is_first_party":0,"bug_type":"309","os_version":"macOS 26.6 (25G5023)","roots_installed":0,"name":"FalconMail","incident_id":"33333333-3333-3333-3333-333333333333"}
        """
        var images = [#"{"source":"P","arch":"arm64","base":4294967296,"size":9437184,"uuid":"70B89F27-1634-3580-A695-57CDB41D7743","path":"/Applications/FalconMail.app/Contents/MacOS/FalconMail","name":"FalconMail","CFBundleIdentifier":"com.falconmail.app","CFBundleShortVersionString":"1.9.0","CFBundleVersion":"45"}"#]
        for i in 1..<250 {
            let uuid = String(format: "%08X-0000-4000-8000-%012X", i, i * 7919)
            let name = i % 3 == 0 ? "libsystem_framework_\(i).dylib" : "SystemFramework\(i)"
            let path = i % 3 == 0 ? "/usr/lib/system/\(name)" : "/System/Library/PrivateFrameworks/\(name).framework/Versions/A/\(name)"
            images.append(#"{"source":"P","arch":"arm64e","base":\#(6_442_450_944 + i * 1_048_576),"size":1048576,"uuid":"\#(uuid)","path":"\#(path)","name":"\#(name)","CFBundleIdentifier":"com.apple.\#(name)","CFBundleShortVersionString":"6.9","CFBundleVersion":"2575.40.101"}"#)
        }
        func frame(_ i: Int, thread: Int) -> String {
            // Every fifth frame is FalconMail's own, unsymbolicated as in a release build.
            if i % 5 == 2 { return #"{"imageOffset":\#(100_000 + i * 64 + thread),"imageIndex":0}"# }
            let image = 1 + (i * 7 + thread * 13) % 249
            return #"{"imageOffset":\#(20_000 + i * 32),"symbol":"-[NSSomeLongSystemClassName performSomethingWithObject:context:\#(i)]","symbolLocation":\#(i * 4),"imageIndex":\#(image)}"#
        }
        func frames(_ count: Int, thread: Int) -> String { "[" + (0..<count).map { frame($0, thread: thread) }.joined(separator: ",") + "]" }
        let threads = (0..<30).map { t -> String in
            let crashed = t == 0
            let state = crashed ? #","threadState":{"x":[{"value":0},{"value":1},{"value":2}],"pc":{"value":4295012345},"lr":{"value":4295000000},"sp":{"value":6100000000},"fp":{"value":6100000100},"far":{"value":0},"esr":{"value":1442840704,"description":"(Syscall)"},"cpsr":{"value":1073741824},"flavor":"ARM_THREAD_STATE64"}"# : ""
            return #"{"id":\#(9_000 + t)\#(crashed ? #","triggered":true,"queue":"com.apple.main-thread""# : #","name":"Worker \#(t)""#)\#(state),"frames":\#(frames(crashed ? crashedFrames : 20, thread: t))}"#
        }.joined(separator: ",")
        let reason = "*** Terminating app due to uncaught exception 'NSInternalInconsistencyException', reason: 'Invalid parameter not satisfying: row >= 0'"
        let body = """
        {"uptime":1200,"procRole":"Foreground","version":2,"userID":501,"deployVersion":210,"modelCode":"MacBookPro18,3",
         "osVersion":{"train":"macOS 26.6","build":"25G5023","releaseType":"User"},"captureTime":"2026-09-20 10:11:12.3456 +0100",
         "incident":"33333333-3333-3333-3333-333333333333","pid":4242,"cpuType":"ARM-64","translated":false,"procName":"FalconMail",
         "procLaunch":"2026-09-20 09:51:12.0000 +0100","procPath":"/Applications/FalconMail.app/Contents/MacOS/FalconMail",
         "bundleInfo":{"CFBundleShortVersionString":"1.9.0","CFBundleVersion":"45","CFBundleIdentifier":"com.falconmail.app"},
         "crashReporterKey":"D4F2E1C0-SECRET-KEY","sleepWakeUUID":"ABCDEF","bootSessionUUID":"123456",
         "exception":{"codes":"0x0000000000000000, 0x0000000000000000","rawCodes":[0,0],"type":"EXC_CRASH","signal":"SIGABRT"},
         "termination":{"flags":0,"code":6,"namespace":"SIGNAL","indicator":"Abort trap: 6","byProc":"FalconMail","byPid":4242},
         "asi":{"CoreFoundation":["\(reason)"],"libsystem_c.dylib":["abort() called"]},
         \(backtrace ? #""lastExceptionBacktrace":\#(frames(45, thread: 99)),"# : "")
         "faultingThread":0,"threads":[\(threads)],"usedImages":[\(images.joined(separator: ","))],
         "sharedCache":{"base":6442450944,"size":4000000000,"uuid":"99999999-8888-7777-6666-555555555555"},
         "vmSummary":"\(String(repeating: "ReadOnly portion of Libraries: Total=1.5G resident=0K(0%) swapped_out_or_unallocated=1.5G(100%) ", count: 40))",
         "legacyInfo":{"threadTriggered":{"queue":"com.apple.main-thread"}}}
        """
        return header + "\n" + body.replacingOccurrences(of: "\n", with: "")
    }

    /// A small report of one crash. Its images are FalconMail (0), CoreFoundation (1),
    /// libobjc.A.dylib (2), Foundation (3) and AppKit (4), and each frame is an image with, when
    /// the report names it, a symbol. `build` moves every UUID, load address and offset, as another
    /// build of the same code would; `home` is the Mac's user. Each frame is at an offset of its
    /// own, or the crashed thread's at `offsets`, where a recursion's frames repeat.
    static func crashIPS(type: String = "EXC_CRASH", signal: String = "SIGABRT", asi: [String] = [],
                         backtrace: [(image: Int, symbol: String?)]? = nil, crashed: [(image: Int, symbol: String?)],
                         offsets: [Int]? = nil,
                         build: Int = 0, home: String = "/Users/kmuradoff", incident: String = UUID().uuidString) -> String {
        let names = ["FalconMail", "CoreFoundation", "libobjc.A.dylib", "Foundation", "AppKit"]
        let images = names.enumerated().map { index, name -> JSONValue in
            let path = index == 0 ? "\(home)/Applications/FalconMail.app/Contents/MacOS/FalconMail" : "/System/Library/\(name)"
            return .object(["name": .string(name), "path": .string(path), "arch": .string("arm64e"),
                            "base": .int(Int64(4_294_967_296 + index * 16_777_216 + (index == 0 ? build * 65_536 : 0))),
                            "uuid": .string(String(format: "%08X-1634-3580-A695-%012X", index == 0 ? 0x70B8_9F27 + build : index, index))])
        }
        func frames(_ list: [(image: Int, symbol: String?)], offsets: [Int]? = nil) -> JSONValue {
            .array(list.enumerated().map { position, frame in
                let offset = offsets.map { $0[position] } ?? 10_000 + position * 64
                var f: [String: JSONValue] = ["imageIndex": .int(Int64(frame.image)),
                                              "imageOffset": .int(Int64(offset + (frame.image == 0 ? build * 4_096 : 0)))]
                if let symbol = frame.symbol { f["symbol"] = .string(symbol) }
                return .object(f)
            })
        }
        let header: JSONValue = .object(["app_name": .string("FalconMail"), "app_version": .string("1.9.\(build)"), "build_version": .string("\(45 + build)"),
                                         "bundleID": .string("com.falconmail.app"), "bug_type": .string("309"), "incident_id": .string(incident),
                                         "os_version": .string("macOS 26.6 (25G5023)"), "timestamp": .string("2026-09-20 10:11:12.00 +0100")])
        var body: [String: JSONValue] = [
            "procName": .string("FalconMail"), "procPath": .string("\(home)/Applications/FalconMail.app/Contents/MacOS/FalconMail"),
            "captureTime": .string("2026-09-20 10:11:12.3456 +0100"), "incident": .string(incident),
            "exception": .object(["type": .string(type), "signal": .string(signal)]), "faultingThread": .int(0),
            "threads": .array([.object(["triggered": .bool(true), "queue": .string("com.apple.main-thread"), "frames": frames(crashed, offsets: offsets)])]),
            "usedImages": .array(images),
        ]
        if !asi.isEmpty { body["asi"] = .object(["CoreFoundation": .array(asi.map(JSONValue.string))]) }
        if let backtrace { body["lastExceptionBacktrace"] = frames(backtrace) }
        return String(decoding: header.serialised, as: UTF8.self) + "\n" + String(decoding: JSONValue.object(body).serialised, as: UTF8.self)
    }

    /// How an uncaught exception reaches the crashed thread: abort, called from the runtime's
    /// handler for exceptions nobody caught.
    static let aborted: [(image: Int, symbol: String?)] = [(1, "__pthread_kill"), (1, "abort"), (2, "_objc_terminate()"), (4, "-[NSApplication run]")]

    static func uncaught(_ name: String, _ reason: String) -> [String] {
        ["*** Terminating app due to uncaught exception '\(name)', reason: '\(reason)'"]
    }

    /// The crash the report describes, as it would be queued.
    private func crash(_ text: String) throws -> DiagnosticsEvent {
        let newline = try XCTUnwrap(text.firstIndex(of: "\n"))
        let report = CrashReportScanner.Report(url: reports.appendingPathComponent("FalconMail-2026-09-20-101112.ips"), modified: now,
                                               header: try XCTUnwrap(JSONValue.parse(String(text[..<newline]))),
                                               body: try XCTUnwrap(JSONValue.parse(String(text[text.index(after: newline)...]))))
        let redactor = DiagnosticsRedactor(salt: Data(repeating: 5, count: 32), homePath: "/Users/kmuradoff")
        return CrashReportDigest.event(from: report, install: "INSTALL", redactor: redactor).0
    }

    /// Every uncaught exception once went under one signature ending `@Foundation` and one
    /// title, so different crashes shared a row. Each is now told apart by its exception, the
    /// system function FalconMail called that raised it and the first words of its reason.
    func testCrashesAreToldApartByTheirExceptionAndWhereItWasRaised() throws {
        let assertion = try crash(Self.crashIPS(
            asi: Self.uncaught("NSInternalInconsistencyException", "Invalid parameter not satisfying: row >= 0"),
            backtrace: [(1, "__exceptionPreprocess"), (2, "objc_exception_throw"),
                        (3, "-[NSAssertionHandler handleFailureInMethod:object:file:lineNumber:description:]"), (0, nil), (4, "-[NSTableView reloadData]")],
            crashed: Self.aborted))
        let range = try crash(Self.crashIPS(
            asi: Self.uncaught("NSRangeException", "*** -[__NSArrayM objectAtIndexedSubscript:]: index 3 beyond bounds [0 .. 2]"),
            backtrace: [(1, "__exceptionPreprocess"), (2, "objc_exception_throw"), (1, "-[__NSArrayM objectAtIndexedSubscript:]"), (0, nil), (0, nil)],
            crashed: Self.aborted))
        let layout = try crash(Self.crashIPS(
            asi: Self.uncaught("NSInternalInconsistencyException", "The window has been marked as needing another Update Constraints in Window pass"),
            backtrace: [(1, "__exceptionPreprocess"), (2, "objc_exception_throw"), (4, "-[NSWindow(NSConstraintBasedLayout) _postWindowNeedsUpdateConstraints]"), (0, nil)],
            crashed: Self.aborted))

        XCTAssertEqual(assertion.signature, "Crash.EXC_CRASH.SIGABRT.NSInternalInconsistencyException.invalidParameterNotSatisfyingRow"
                       + "@Foundation:NSAssertionHandler.handleFailureInMethod")
        // Too long to say whole, so said more briefly: "FalconMail crashed", the method without its class.
        XCTAssertEqual(assertion.title, "FalconMail crashed (NSInternalInconsistencyException: Invalid parameter not satisfying row, in handleFailureInMethod)")
        // The method in the reason is the place already, so the reason's words start after it.
        XCTAssertEqual(range.signature, "Crash.EXC_CRASH.SIGABRT.NSRangeException.indexBeyondBounds@CoreFoundation:NSArrayM.objectAtIndexedSubscript")
        XCTAssertEqual(range.title, "FalconMail crashed on an internal error (NSRangeException: index beyond bounds, in NSArrayM.objectAtIndexedSubscript)")
        XCTAssertEqual(layout.signature, "Crash.EXC_CRASH.SIGABRT.NSInternalInconsistencyException.theWindowHasBeenMarkedAsNeeding"
                       + "@AppKit:NSWindow._postWindowNeedsUpdateConstraints")
        XCTAssertEqual(layout.title, "FalconMail crashed (NSInternalInconsistencyException: The window has been marked…, in _postWindowNeedsUpdateConstraints)")
        let events = [assertion, range, layout]
        XCTAssertEqual(Set(events.map(\.signature)).count, 3)
        XCTAssertEqual(Set(events.map(\.title)).count, 3)
        for event in events {
            XCTAssertLessThanOrEqual(event.title.count, DiagnosticsEvent.maxTitle, event.title)
            XCTAssertFalse(event.title.contains(where: \.isNumber), event.title)
        }
    }

    /// Another build moves every offset, UUID and load address, and another Mac has another user:
    /// none of it may split one crash into two problems.
    func testTheSameCrashReadsTheSameInEveryBuildAndOnEveryMac() throws {
        func report(build: Int, home: String) throws -> DiagnosticsEvent {
            try crash(Self.crashIPS(
                asi: Self.uncaught("NSInvalidArgumentException", "-[NSNull length]: unrecognized selector sent to instance 0x6000037a4ce0"),
                backtrace: [(1, "__exceptionPreprocess"), (2, "objc_exception_throw"), (1, "-[NSObject(NSObject) doesNotRecognizeSelector:]"),
                            (1, "___forwarding___"), (1, "_CF_forwarding_prep_0"), (0, nil), (4, "-[NSApplication sendAction:to:from:]")],
                crashed: Self.aborted, build: build, home: home))
        }
        let first = try report(build: 0, home: "/Users/kmuradoff")
        let later = try report(build: 7, home: "/Users/ana.lima")
        XCTAssertEqual(first.signature, "Crash.EXC_CRASH.SIGABRT.NSInvalidArgumentException.NSNullLengthUnrecognizedSelectorSentToInstance"
                       + "@CoreFoundation:CF_forwarding_prep")
        XCTAssertEqual(later.signature, first.signature)
        XCTAssertEqual(later.title, first.title)
        XCTAssertEqual(first.title, "FalconMail crashed (NSInvalidArgumentException: NSNull length unrecognized selector sent…, in CF_forwarding_prep)")
        XCTAssertFalse(first.signature.contains(where: \.isNumber), first.signature)
        XCTAssertFalse(first.signature.contains("kmuradoff"))
    }

    /// When the report names FalconMail's own function, that is the place, and the reason's words,
    /// which could vary, are not needed.
    func testAFunctionTheReportNamesPlacesTheCrash() throws {
        let event = try crash(Self.crashIPS(
            asi: Self.uncaught("NSRangeException", "*** -[__NSArrayM objectAtIndexedSubscript:]: index 3 beyond bounds [0 .. 2]"),
            backtrace: [(1, "__exceptionPreprocess"), (2, "objc_exception_throw"), (1, "-[__NSArrayM objectAtIndexedSubscript:]"),
                        (0, "closure #1 in MessageList.select(_:)"), (0, nil)],
            crashed: Self.aborted))
        XCTAssertEqual(event.signature, "Crash.EXC_CRASH.SIGABRT.NSRangeException@FalconMail:MessageList.select")
        XCTAssertEqual(event.title, "FalconMail crashed on an internal error (NSRangeException, in MessageList.select)")
    }

    /// A trap in FalconMail's own code, a force-unwrapped nil in a release build say, is at the top
    /// of the stack with no name and nothing above it: what called it is the nearest named place.
    func testATrapInFalconMailsOwnCodeIsPlacedByWhatCalledIt() throws {
        let event = try crash(Self.crashIPS(type: "EXC_BREAKPOINT", signal: "SIGTRAP",
                                            crashed: [(0, nil), (0, nil), (4, "-[NSApplication(NSResponder) sendAction:to:from:]"), (4, "-[NSApplication run]")]))
        XCTAssertEqual(event.signature, "Crash.EXC_BREAKPOINT.SIGTRAP@FalconMail:calledFrom.NSApplication.sendAction")
        XCTAssertEqual(event.title, "FalconMail crashed: a safety check in its code failed (in its own code, called from NSApplication.sendAction)")
    }

    /// The same exception with the same reason, raised from two AppKit methods FalconMail called,
    /// is two problems. Their signatures told them apart, but their titles left the place out
    /// whenever there was a reason, so the Issues tab had two rows with the same text.
    func testTheSameExceptionFromTwoPlacesHasTwoTitles() throws {
        func raised(in method: String) throws -> DiagnosticsEvent {
            try crash(Self.crashIPS(
                asi: Self.uncaught("NSInternalInconsistencyException", "Invalid parameter not satisfying: row >= 0"),
                backtrace: [(1, "__exceptionPreprocess"), (2, "objc_exception_throw"),
                            (3, "-[NSAssertionHandler handleFailureInMethod:object:file:lineNumber:description:]"),
                            (4, "-[NSTableView \(method):withAnimation:]"), (0, nil), (4, "-[NSApplication run]")],
                crashed: Self.aborted))
        }
        let removing = try raised(in: "removeRowsAtIndexes")
        let inserting = try raised(in: "insertRowsAtIndexes")
        XCTAssertNotEqual(removing.signature, inserting.signature)
        XCTAssertNotEqual(removing.title, inserting.title)
        XCTAssertEqual(removing.title, "FalconMail crashed (NSInternalInconsistencyException: Invalid parameter not satisfying row, in removeRowsAtIndexes)")
        XCTAssertEqual(inserting.title, "FalconMail crashed (NSInternalInconsistencyException: Invalid parameter not satisfying row, in insertRowsAtIndexes)")
        for event in [removing, inserting] { XCTAssertLessThanOrEqual(event.title.count, DiagnosticsEvent.maxTitle, event.title) }
    }

    /// Five words cut a reason off wherever they ended: `Range out`, `Database schema is newer
    /// than`. The title reads the reason's first clause, without the method that is the place
    /// already, and marks a reason that goes on.
    func testAReasonInATitleReadsAsAPhrase() throws {
        let range = try crash(Self.crashIPS(
            asi: Self.uncaught("NSRangeException", "*** -[__NSCFString substringWithRange:]: Range {10, 5} out of bounds; string length 3"),
            backtrace: [(1, "__exceptionPreprocess"), (2, "objc_exception_throw"), (3, "-[NSString substringWithRange:]"), (0, nil)],
            crashed: Self.aborted))
        XCTAssertEqual(range.title, "FalconMail crashed on an internal error (NSRangeException: Range out of bounds, in NSString.substringWithRange)")
        let schema = try crash(Self.crashIPS(type: "EXC_BREAKPOINT", signal: "SIGTRAP",
                                             asi: ["Store.swift:88: Fatal error: Database schema is newer than this build supports (v12 > v10)"],
                                             crashed: [(0, nil), (4, "-[NSApplication(NSResponder) sendAction:to:from:]")]))
        // A word short of fitting whole, so the reason goes back to a word that ends a phrase.
        XCTAssertEqual(schema.title, "FalconMail crashed: a safety check in its code failed (Database schema is newer…, called from sendAction)")
        XCTAssertEqual(schema.signature, "Crash.EXC_BREAKPOINT.SIGTRAP.databaseSchemaIsNewerThanThisBuild@FalconMail:calledFrom.NSApplication.sendAction")
    }

    /// The plain sentence stands for its usual exception type and signal; another one is added to
    /// the title, so a bus error and a segmentation fault in the same place read apart as their
    /// signatures do.
    func testAnUnusualSignalIsNamedInTheTitle() throws {
        let stack: [(image: Int, symbol: String?)] = [(2, "objc_msgSend"), (0, nil), (4, "-[NSApplication run]")]
        let segv = try crash(Self.crashIPS(type: "EXC_BAD_ACCESS", signal: "SIGSEGV", crashed: stack))
        let bus = try crash(Self.crashIPS(type: "EXC_BAD_ACCESS", signal: "SIGBUS", crashed: stack))
        XCTAssertEqual(segv.title, "FalconMail crashed: it used memory it should not have (in objc_msgSend)")
        XCTAssertEqual(bus.title, "FalconMail crashed: it used memory it should not have (in objc_msgSend, EXC_BAD_ACCESS/SIGBUS)")
        XCTAssertNotEqual(segv.signature, bus.signature)
    }

    /// A stack overflow: FalconMail's own code calling itself until the stack ran out. Its
    /// signature and title say so, so it is not taken for any other bad memory access in the same
    /// place.
    func testARunawayRecursionIsToldApartFromAnyOtherCrashInThePlace() throws {
        let recursion = Array(repeating: [(image: 0, symbol: String?.none), (image: 0, symbol: String?.none)], count: 250).flatMap { $0 }
        let overflow = try crash(Self.crashIPS(type: "EXC_BAD_ACCESS", signal: "SIGSEGV", crashed: recursion + [(4, "-[NSApplication run]")],
                                               offsets: recursion.indices.map { 2_000 + $0 % 2 * 40 } + [9_000]))
        let other = try crash(Self.crashIPS(type: "EXC_BAD_ACCESS", signal: "SIGSEGV", crashed: [(0, nil), (0, nil), (4, "-[NSApplication run]")]))
        XCTAssertEqual(overflow.signature, "Crash.EXC_BAD_ACCESS.SIGSEGV.recursion@FalconMail:calledFrom.NSApplication.run")
        XCTAssertEqual(overflow.title, "FalconMail crashed: it used memory it should not have (runaway recursion, called from NSApplication.run)")
        XCTAssertEqual(other.signature, "Crash.EXC_BAD_ACCESS.SIGSEGV@FalconMail:calledFrom.NSApplication.run")
        XCTAssertNotEqual(other.title, overflow.title)
    }

    /// A title still too long once the reason's words were gone was cut wherever 120 characters
    /// ended, in the place or the signal: `called from CFRUNLOOP_IS_CALLING_OUT_TO_A_BLO…`,
    /// `EXC_BAD_A…`. Now the sentence gives way to `FalconMail crashed` and the exception type and
    /// signal it stood for, then whole details beside the place go, the longest first, and the
    /// place and the signal are never cut.
    func testALongTitleNeverCutsThePlaceOrTheSignal() {
        let recursion = (0..<250).map { CrashIdentity.Frame(binary: "FalconMail", symbol: nil, own: true, address: "\(2_000 + $0 % 2 * 40)") }
        let runLoop = CrashIdentity.Frame(binary: "CoreFoundation", symbol: "__CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__", own: false)
        let overflow = CrashIdentity(kind: .crash, code: "EXC_BAD_ACCESS.SIGSEGV", exception: nil, reason: nil, frames: recursion + [runLoop])
        XCTAssertEqual(overflow.title, "FalconMail crashed (runaway recursion, called from CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK, EXC_BAD_ACCESS/SIGSEGV)")
        let raised = CrashIdentity(kind: .crash, code: "EXC_BAD_ACCESS.SIGBUS", exception: "NSInternalInconsistencyException",
                                   reason: "Invalid parameter not satisfying: row >= 0", frames: recursion + [runLoop])
        XCTAssertEqual(raised.title, "FalconMail crashed (runaway recursion, called from CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK, EXC_BAD_ACCESS/SIGBUS)")

        // Every name at its 60-character limit: the place still stands whole, and nothing ends mid-word.
        let long = String(repeating: "Abcdefghij", count: 6)
        let ownFrame = CrashIdentity.Frame(binary: "FalconMail", symbol: nil, own: true)
        let caller = CrashIdentity.Frame(binary: "AppKit", symbol: "-[\(long) \(long):]", own: false)
        let named = CrashIdentity.Frame(binary: "FalconMail", symbol: "\(long).\(long)()", own: true)
        let binary = CrashIdentity.Frame(binary: long + ".dylib", symbol: nil, own: false)
        let codes = ["EXC_BAD_ACCESS.SIGBUS", "\(long).\(long)", "mainThread"]
        var wrong: [String] = []
        for kind in [DiagnosticsKind.crash, .hang] {
            for code in codes {
                for exception in [nil, long] {
                    for frames in [[ownFrame, caller], recursion + [caller], [named], [binary], []] {
                        let identity = CrashIdentity(kind: kind, code: code, exception: exception,
                                                     reason: "Could not find the row for the index in the table view", frames: frames)
                        let title = identity.title
                        let whole = title.hasSuffix(")") || !title.contains(" (")
                        let placed = identity.place.phrase(brief: 2).map(title.contains) ?? true
                        if title.count > DiagnosticsEvent.maxTitle || !whole || !placed { wrong.append(title) }
                    }
                }
            }
        }
        XCTAssertEqual(wrong, [], "titles too long, cut mid-word or without their place")
    }

    @discardableResult
    private func write(_ name: String, _ text: String, modified: Date) throws -> URL {
        let url = reports.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func makeCenter(clock: ManualClock) -> DiagnosticsCenter {
        let center = DiagnosticsCenter(directory: directory, gate: DiagnosticsFixtures.gate(),
                                       environment: DiagnosticsFixtures.environment(home: "/Users/kmuradoff"),
                                       crashReportsDirectory: reports, session: FakeDiagnosticsServer.session(), clock: clock)
        centers.append(center)
        return center
    }

    func testOnlyFalconMailsOwnNewReportsArePickedUp() throws {
        try write("FalconMail-2026-09-20-101112.ips", Self.ips(incident: "11111111-1111-1111-1111-111111111111"), modified: now.addingTimeInterval(-3_600))
        try write("FalconMail-2026-09-20-111112.ips", Self.ips(bundle: "com.falconmail.app.snapshot"), modified: now.addingTimeInterval(-1_800))
        try write("OtherApp-2026-09-20-101112.ips", Self.ips(), modified: now.addingTimeInterval(-1_800))
        try write("FalconMail-2026-09-01-101112.ips", Self.ips(), modified: now.addingTimeInterval(-20 * 86_400))
        try write("FalconMail-2026-09-20-121212.ips", "not a report", modified: now.addingTimeInterval(-600))

        let clock = ManualClock(now)
        let center = makeCenter(clock: clock)
        center.start()
        let crashes = center.pendingRecords.filter { $0.event.kind == .crash }
        XCTAssertEqual(crashes.count, 1)
        let crash = try XCTUnwrap(crashes.first)
        XCTAssertEqual(crash.event.id, DiagnosticsEvent.stableID("ips:\(center.installID):11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(crash.app.version, "1.9.0", "sent under the version that crashed")
        XCTAssertEqual(crash.app.build, "45")
        XCTAssertLessThanOrEqual(center.nextUploadDate, now.addingTimeInterval(60), "a crash goes out within a minute")
        center.stop()

        let again = makeCenter(clock: ManualClock(now.addingTimeInterval(60)))
        again.start()
        XCTAssertEqual(again.pendingRecords.filter { $0.event.kind == .crash }.count, 1, "not picked up a second time")
        again.stop()

        try write("FalconMail-2026-09-21-080000.ips", Self.ips(incident: "22222222-2222-2222-2222-222222222222"), modified: now.addingTimeInterval(120))
        let later = makeCenter(clock: ManualClock(now.addingTimeInterval(300)))
        later.start()
        XCTAssertEqual(later.pendingRecords.filter { $0.event.kind == .crash }.map(\.event.id).last,
                       DiagnosticsEvent.stableID("ips:\(later.installID):22222222-2222-2222-2222-222222222222"))
    }

    /// A crash file's date has a fraction of a second; the next launch must still know it has
    /// been reported, even after the upload emptied the queue.
    func testAReportIsSentOnceEvenAfterTheQueueIsEmpty() async throws {
        try write("FalconMail-2026-09-20-101112.ips", Self.ips(), modified: now.addingTimeInterval(-3_600.37))
        FakeDiagnosticsServer.respond { _, _ in DiagnosticsFixtures.okReply }
        defer { FakeDiagnosticsServer.reset() }
        let first = makeCenter(clock: ManualClock(now))
        first.start()
        XCTAssertEqual(first.pendingRecords.filter { $0.event.kind == .crash }.count, 1)
        _ = await first.uploadNow()
        XCTAssertEqual(first.pendingCount, 0)
        first.endSession()
        first.stop()

        let next = makeCenter(clock: ManualClock(now.addingTimeInterval(600)))
        next.start()
        XCTAssertEqual(next.pendingRecords.filter { $0.event.kind == .crash }.count, 0, "not sent again")
    }

    /// Ten newer reports of other builds must not hide a real one, nor be read again.
    func testOtherBuildsReportsNeverCrowdOutTheRealOne() throws {
        try write("FalconMail-2026-09-20-080000.ips", Self.ips(incident: "11111111-1111-1111-1111-111111111111"),
                  modified: now.addingTimeInterval(-7_200))
        for i in 0..<10 {
            try write("FalconMail-2026-09-20-09000\(i).ips", Self.ips(bundle: "com.falconmail.app.snapshot"),
                      modified: now.addingTimeInterval(-3_600 + Double(i)))
        }
        for i in 0..<10 {
            try write("FalconMail-2026-09-20-10000\(i).ips", Self.ips(appPath: "/tmp/agent-dd/Build/Products/Debug/FalconMail.app"),
                      modified: now.addingTimeInterval(-1_800 + Double(i)))
        }
        let center = makeCenter(clock: ManualClock(now))
        center.start()
        let crashes = center.pendingRecords.filter { $0.event.kind == .crash }
        XCTAssertEqual(crashes.map(\.event.id), [DiagnosticsEvent.stableID("ips:\(center.installID):11111111-1111-1111-1111-111111111111")],
                       "only the installed app's crash, not the snapshot's or a build run from Xcode's build folder")
    }

    /// MetricKit's crash diagnostic of the same crash, with its window given in UTC so the test
    /// reads the same in every time zone.
    private static let metricKitPayload = MetricKitDiagnosticsTests.payload
        .replacingOccurrences(of: "2026-09-20 00:00:00", with: "2026-09-20 00:00:00 +0000")
        .replacingOccurrences(of: "2026-09-20 23:59:00", with: "2026-09-20 23:59:00 +0000")

    /// macOS writes a crash report and MetricKit reports the same crash again. It is sent once,
    /// from the report, which says more.
    func testACrashBothSourcesReportIsSentOnce() throws {
        try write("FalconMail-2026-09-20-101112.ips", Self.ips(), modified: now.addingTimeInterval(-3_600))
        let center = makeCenter(clock: ManualClock(now))
        center.start()
        center.ingestMetricKit(Data(Self.metricKitPayload.utf8))
        center.waitUntilIdle()
        XCTAssertEqual(center.pendingRecords.filter { $0.event.kind == .crash }.map { $0.event.context["source"] }, [.string("ips")])
        XCTAssertEqual(center.pendingRecords.filter { $0.event.kind == .hang }.count, 1, "MetricKit's hangs still go")
    }

    func testADebugBuildsCrashIsSentFromNeitherSource() throws {
        let debug = "/Users/kmuradoff/Library/Developer/Xcode/DerivedData/FalconMail-abc/Build/Products/Debug/FalconMail.app"
        try write("FalconMail-2026-09-20-101112.ips", Self.ips(appPath: debug), modified: now.addingTimeInterval(-3_600))
        let center = makeCenter(clock: ManualClock(now))
        center.start()
        center.ingestMetricKit(Data(Self.metricKitPayload.utf8))
        center.waitUntilIdle()
        XCTAssertEqual(center.pendingRecords.filter { $0.event.kind == .crash }.count, 0)
    }

    func testReportIsRedactedAndKeepsWhatSymbolicationNeeds() throws {
        try write("FalconMail-2026-09-20-101112.ips", Self.ips(), modified: now.addingTimeInterval(-60))
        let center = makeCenter(clock: ManualClock(now))
        center.start()
        let crash = try XCTUnwrap(center.pendingRecords.first { $0.event.kind == .crash }?.event)
        // FalconMail's frames name nothing, so the Swift runtime function it called, with the
        // first words of the fatal error; the address and the path in it never reach either.
        XCTAssertEqual(crash.signature, "Crash.EXC_BREAKPOINT.SIGTRAP.noAccount@libswiftCore.dylib:swift_unexpectedError")
        XCTAssertEqual(crash.title, "FalconMail crashed: a safety check in its code failed (no account…, in swift_unexpectedError)")
        XCTAssertTrue(crash.message.contains("Trace/BPT trap: 5"))

        let text = String(decoding: crash.context.serialised, as: UTF8.self) + crash.message
        for secret in ["kmuradoff", "ana@example.com", "D4F2E1C0", "crashReporterKey", "sleepWakeUUID", "bootSessionUUID", "userID", "vmSummary"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        let context = crash.context
        XCTAssertEqual(context["source"], .string("ips"))
        XCTAssertEqual(context["faultingThread"], .int(1))
        XCTAssertEqual(context["exception"]?["type"], .string("EXC_BREAKPOINT"))
        XCTAssertEqual(context["header"]?["bundleID"], .string("com.falconmail.app"))
        let threads = try XCTUnwrap(context["threads"]?.arrayValue)
        XCTAssertEqual(threads.count, 1, "only the crashed thread")
        XCTAssertEqual(threads[0]["index"], .int(1), "numbered as in the report")
        XCTAssertEqual(threads[0]["frames"]?.arrayValue?.count, 22, "the crashed thread keeps every frame")
        XCTAssertEqual(threads[0]["threadState"]?["far"]?["value"], .int(0))
        XCTAssertNil(threads[0]["threadState"]?["x"], "general registers are left out")
        XCTAssertNil(context["trimmed"], "nothing had to be left out")
        let images = try XCTUnwrap(context["usedImages"]?.arrayValue)
        XCTAssertEqual(Set(images.compactMap { $0["name"]?.stringValue }), ["FalconMail", "AppKit", "libsystem_kernel.dylib", "libswiftCore.dylib"])
        XCTAssertTrue(images.allSatisfy { $0["uuid"] != nil && $0["base"] != nil && $0["arch"] != nil && $0["path"] == nil })
        let first = try XCTUnwrap(threads[0]["frames"]?.arrayValue?.first)
        let image = try XCTUnwrap(first["imageIndex"]?.intValue)
        XCTAssertEqual(images[Int(image)]["name"], .string("libsystem_kernel.dylib"), "frames point at the renumbered images")
    }

    /// An uncaught exception's name and reason are what the triage reads first, in the message
    /// and in the report alike; the addresses and paths inside them still go.
    func testAnUncaughtExceptionKeepsItsNameAndReason() throws {
        let reason = "*** Terminating app due to uncaught exception 'NSInternalInconsistencyException', "
            + "reason: 'Invalid parameter not satisfying: row >= 0 for ana@example.com in /Users/kmuradoff/Library/x'"
        try write("FalconMail-2026-09-20-101112.ips", Self.ips(asi: #"{"CoreFoundation":["\#(reason)"]}"#), modified: now.addingTimeInterval(-60))
        let center = makeCenter(clock: ManualClock(now))
        center.start()
        let crash = try XCTUnwrap(center.pendingRecords.first { $0.event.kind == .crash }?.event)
        let kept = "*** Terminating app due to uncaught exception 'NSInternalInconsistencyException', "
            + "reason: 'Invalid parameter not satisfying: row >= 0 for <addr:"
        XCTAssertTrue(crash.message.contains(kept), crash.message)
        XCTAssertTrue(crash.message.contains(" in ~/Library/x'"), crash.message)
        let line = try XCTUnwrap(crash.context["asi"]?["CoreFoundation"]?.arrayValue?.first?.stringValue)
        XCTAssertTrue(line.hasPrefix(kept), line)
        let text = String(decoding: crash.context.serialised, as: UTF8.self) + crash.message
        XCTAssertFalse(text.contains("ana@example.com"))
        XCTAssertFalse(text.contains("kmuradoff"))
    }

    /// A real report is ten times the contract's 16 KB for a context. What goes is only what the
    /// triage needs, still valid JSON that reads as an .ips: the exception, the crashed thread and
    /// the exception's backtrace, and the images their frames use, with what had to be left out
    /// marked where it was.
    func testAFullSizeReportIsCutToWhatTheTriageNeeds() throws {
        let ips = Self.fullIPS()
        XCTAssertGreaterThan(ips.utf8.count, 120_000)
        try write("FalconMail-2026-09-20-101112.ips", ips, modified: now.addingTimeInterval(-60))
        let center = makeCenter(clock: ManualClock(now))
        center.start()
        let crash = try XCTUnwrap(center.pendingRecords.first { $0.event.kind == .crash }?.event)
        let context = crash.context
        XCTAssertLessThanOrEqual(context.serialised.count, DiagnosticsEvent.maxContextBytes - 1_024, "room to spare under the contract's 16 KB")
        XCTAssertEqual(JSONValue.parse(context.serialised), context, "valid JSON")
        XCTAssertNil(context["truncated"], "never cut blindly")
        XCTAssertEqual(context["trimmed"], .bool(true), "and it says frames were left out")

        XCTAssertEqual(context["exception"]?["type"], .string("EXC_CRASH"))
        XCTAssertEqual(context["exception"]?["codes"], .string("0x0000000000000000, 0x0000000000000000"))
        XCTAssertEqual(context["asi"]?["CoreFoundation"]?.arrayValue?.first?.stringValue?.hasSuffix("reason: 'Invalid parameter not satisfying: row >= 0'"), true)
        XCTAssertEqual(context["faultingThread"], .int(0))

        let threads = try XCTUnwrap(context["threads"]?.arrayValue)
        XCTAssertEqual(threads.count, 1, "only the crashed thread")
        XCTAssertEqual(threads[0]["triggered"], .bool(true))
        XCTAssertEqual(threads[0]["index"], .int(0))
        let images = try XCTUnwrap(context["usedImages"]?.arrayValue)
        XCTAssertTrue(images.allSatisfy { Set($0.objectValue?.keys.map { $0 } ?? []) == ["uuid", "name", "base", "arch"] })

        for (list, total) in [(threads[0]["frames"], 60), (context["lastExceptionBacktrace"], 45)] {
            let frames = try XCTUnwrap(list?.arrayValue)
            let omitted = frames.compactMap { $0["omitted"]?.intValue }.reduce(0, +)
            let kept = frames.filter { $0["omitted"] == nil }
            XCTAssertEqual(kept.count + Int(omitted), total, "every frame left out is counted where it was")
            XCTAssertEqual(kept.prefix(8).compactMap { $0["imageOffset"]?.intValue }.count, 8)
            XCTAssertEqual(frames.prefix(8).filter { $0["omitted"] != nil }.count, 0, "the top of the stack is kept whole")
            for frame in kept {
                let index = try XCTUnwrap(frame["imageIndex"]?.intValue)
                XCTAssertTrue(images.indices.contains(Int(index)), "every frame points at an image that was sent")
            }
            let own = kept.filter { $0["imageIndex"]?.intValue.map { images[Int($0)]["name"] } == .string("FalconMail") }
            XCTAssertEqual(own.count, total / 5 + (total % 5 > 2 ? 1 : 0), "FalconMail's own frames outlast the libraries' ")
        }
        let referenced = Set(([threads[0]["frames"], context["lastExceptionBacktrace"]]).flatMap { $0?.arrayValue ?? [] }
            .compactMap { $0["imageIndex"]?.intValue })
        XCTAssertEqual(referenced.count, images.count, "no image is sent that no frame uses")
        for gone in ["vmSummary", "sharedCache", "crashReporterKey", "procPath", "bundleInfo", "legacyInfo", "userID"] {
            XCTAssertNil(context[gone], gone)
        }
    }

    /// The contexts the app sends for a full-size crash from each source, which
    /// tools/diagnostics/test reads to check that symbolicate.py understands them. After a change
    /// to what is sent, run the tests once with FALCON_UPDATE_FIXTURES=1 to write them again.
    func testTheTriageToolsReadWhatTheAppSends() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/diagnostics/test/fixtures/trimmed-contexts.json")
        let redactor = DiagnosticsRedactor(salt: Data(repeating: 5, count: 32), homePath: "/Users/tester")
        let text = Self.fullIPS()
        let newline = try XCTUnwrap(text.firstIndex(of: "\n"))
        let header = try XCTUnwrap(JSONValue.parse(String(text[..<newline])))
        let body = try XCTUnwrap(JSONValue.parse(String(text[text.index(after: newline)...])))
        let metricKit = try XCTUnwrap(MetricKitDiagnostics.items(from: MetricKitDiagnosticsTests.fullCrashPayload(), install: "INSTALL",
                                                                 redactor: redactor, now: now).first?.event.context)
        let ips = CrashReportDigest.digest(header: header, body: body, redactor: redactor)
        let sent = JSONValue.object(["ips": ips, "metrickit": metricKit])
        if ProcessInfo.processInfo.environment["FALCON_UPDATE_FIXTURES"] == "1" {
            // Both laid out for reading, each MetricKit frame on a line of its own.
            func laidOut(_ value: JSONValue, width: Int) -> String { value.readable(width: width).replacingOccurrences(of: "\n", with: "\n  ") }
            let text = "{\n  \"ips\": " + laidOut(ips, width: 100) + ",\n  \"metrickit\": " + laidOut(metricKit, width: 200) + "\n}\n"
            try Data(text.utf8).write(to: fixture)
        }
        let stored = try XCTUnwrap(JSONValue.parse(Data(contentsOf: fixture)), "\(fixture.path) is missing or not JSON")
        XCTAssertEqual(stored, sent, "what the app sends has changed: run the tests with FALCON_UPDATE_FIXTURES=1 and check the tools' tests")
    }

    /// A report with room to spare keeps every frame of its crashed thread, and is not marked trimmed.
    func testASmallReportKeepsEveryFrame() throws {
        try write("FalconMail-2026-09-20-101112.ips", Self.fullIPS(backtrace: false, crashedFrames: 12), modified: now.addingTimeInterval(-60))
        let center = makeCenter(clock: ManualClock(now))
        center.start()
        let context = try XCTUnwrap(center.pendingRecords.first { $0.event.kind == .crash }?.event.context)
        XCTAssertNil(context["trimmed"])
        XCTAssertNil(context["lastExceptionBacktrace"])
        XCTAssertEqual(context["threads"]?.arrayValue?.first?["frames"]?.arrayValue?.count, 12)
    }

    func testAHugeReportStillFitsAnEvent() throws {
        try write("FalconMail-2026-09-20-101112.ips", Self.ips(threads: 120, framesPerThread: 400), modified: now.addingTimeInterval(-60))
        let center = makeCenter(clock: ManualClock(now))
        center.start()
        let crash = try XCTUnwrap(center.pendingRecords.first { $0.event.kind == .crash }?.event)
        XCTAssertLessThanOrEqual(crash.context.serialised.count, DiagnosticsEvent.maxContextBytes)
        XCTAssertEqual(crash.context["trimmed"], .bool(true))
        let crashed = try XCTUnwrap(crash.context["threads"]?.arrayValue?.first)
        XCTAssertEqual(crashed["index"], .int(1))
        XCTAssertGreaterThanOrEqual(crashed["frames"]?.arrayValue?.count ?? 0, 48, "the crashed thread's frames survive the cut")
    }
}
