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
                    framesPerThread: Int = 20, home: String = "/Users/kmuradoff") -> String {
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
         "procLaunch":"2026-09-20 09:51:12.0000 +0100","procPath":"\(home)/Applications/FalconMail.app/Contents/MacOS/FalconMail",
         "bundleInfo":{"CFBundleShortVersionString":"1.9.0","CFBundleVersion":"45","CFBundleIdentifier":"\(bundle)"},
         "crashReporterKey":"D4F2E1C0-SECRET-KEY","sleepWakeUUID":"ABCDEF","bootSessionUUID":"123456",
         "exception":{"codes":"0x0000000000000001, 0x0000000000000000","rawCodes":[1,0],"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
         "termination":{"flags":0,"code":5,"namespace":"SIGNAL","indicator":"Trace/BPT trap: 5","byProc":"exc handler","byPid":4242},
         "asi":{"libswiftCore.dylib":["FalconMail/AppModel.swift:42: Fatal error: no account for ana@example.com in \(home)/Library/x"]},
         "faultingThread":1,"threads":[\(threadList)],"usedImages":\(images),
         "sharedCache":{"base":6442450944,"size":4000000000,"uuid":"99999999-8888-7777-6666-555555555555"},
         "vmSummary":"ReadOnly portion of Libraries: Total=1.5G resident=0K(0%) swapped_out_or_unallocated=1.5G(100%)",
         "legacyInfo":{"threadTriggered":{"queue":"com.apple.main-thread"}}}
        """
        return header + "\n" + body.replacingOccurrences(of: "\n", with: "")
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

    func testReportIsRedactedAndKeepsWhatSymbolicationNeeds() throws {
        try write("FalconMail-2026-09-20-101112.ips", Self.ips(), modified: now.addingTimeInterval(-60))
        let center = makeCenter(clock: ManualClock(now))
        center.start()
        let crash = try XCTUnwrap(center.pendingRecords.first { $0.event.kind == .crash }?.event)
        XCTAssertEqual(crash.signature, "Crash.EXC_BREAKPOINT.SIGTRAP@AppKit", "past the kernel and Swift runtime frames")
        XCTAssertEqual(crash.title, "FalconMail crashed: a safety check in its code failed")
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
        XCTAssertEqual(threads.count, 3)
        XCTAssertEqual(threads[1]["frames"]?.arrayValue?.count, 22, "the crashed thread keeps every frame")
        XCTAssertEqual(threads[1]["threadState"]?["far"]?["value"], .int(0))
        XCTAssertNil(threads[1]["threadState"]?["x"], "general registers are left out")
        XCTAssertEqual(threads[0]["frames"]?.arrayValue?.count, 8, "other threads keep their top frames")
        let images = try XCTUnwrap(context["usedImages"]?.arrayValue)
        XCTAssertEqual(Set(images.compactMap { $0["name"]?.stringValue }), ["FalconMail", "AppKit", "libsystem_kernel.dylib", "libswiftCore.dylib"])
        XCTAssertTrue(images.allSatisfy { $0["uuid"] != nil && $0["base"] != nil && $0["path"] == nil })
        let first = try XCTUnwrap(threads[1]["frames"]?.arrayValue?.first)
        let image = try XCTUnwrap(first["imageIndex"]?.intValue)
        XCTAssertEqual(images[Int(image)]["name"], .string("libsystem_kernel.dylib"), "frames point at the renumbered images")
    }

    func testAHugeReportStillFitsAnEvent() throws {
        try write("FalconMail-2026-09-20-101112.ips", Self.ips(threads: 120, framesPerThread: 400), modified: now.addingTimeInterval(-60))
        let center = makeCenter(clock: ManualClock(now))
        center.start()
        let crash = try XCTUnwrap(center.pendingRecords.first { $0.event.kind == .crash }?.event)
        XCTAssertLessThanOrEqual(crash.context.serialised.count, DiagnosticsEvent.maxContextBytes)
        let crashed = try XCTUnwrap(crash.context["threads"]?.arrayValue?[1])
        XCTAssertGreaterThanOrEqual(crashed["frames"]?.arrayValue?.count ?? 0, 48, "the crashed thread's frames survive the cut")
    }
}
