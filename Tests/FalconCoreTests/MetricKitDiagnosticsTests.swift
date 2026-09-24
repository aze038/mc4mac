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
        XCTAssertEqual(crash.event.signature, "Crash.EXC_BAD_ACCESS.SIGSEGV@FalconMail")
        XCTAssertEqual(crash.event.title, "FalconMail crashed: it used memory it should not have")
        XCTAssertEqual(crash.app, DiagnosticsApp(version: "1.9.0", build: "45", channel: "release"))
        XCTAssertEqual(crash.os, "macOS 26.6 (25G5023)")
        XCTAssertTrue(crash.event.message.contains("Segmentation fault"))
        XCTAssertFalse(crash.event.message.contains("ana@example.com"))
        XCTAssertFalse(crash.event.message.contains("kmuradoff"))

        let stacks = try XCTUnwrap(crash.event.context["callStackTree"]?["callStacks"]?.arrayValue)
        XCTAssertEqual(stacks.first?["threadAttributed"], .bool(true), "the blamed thread comes first")
        let root = try XCTUnwrap(stacks.first?["callStackRootFrames"]?.arrayValue?.first)
        XCTAssertEqual(root["binaryUUID"], .string("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        XCTAssertEqual(root["subFrames"]?.arrayValue?.first?["offsetIntoBinaryTextSegment"], .int(165304))
        XCTAssertEqual(root["address"], .int(7170766264), "addresses stay for symbolication")
        XCTAssertNil(crash.event.context["diagnosticMetaData"]?["pid"])
        XCTAssertEqual(crash.event.context["source"], .string("metrickit"))
        XCTAssertFalse(String(decoding: crash.event.context.serialised, as: UTF8.self).contains("kmuradoff"))

        XCTAssertEqual(items[1].event.signature, "Hang.mainThread@AppKit")
        XCTAssertEqual(items[1].event.title, "FalconMail stopped responding for a while")
        XCTAssertTrue(items[1].event.message.contains("4.5 sec"))
        XCTAssertEqual(items[2].event.signature, "CPU.exceeded@FalconMail")
        XCTAssertEqual(items[3].event.signature, "DiskWrite.exceeded@FalconMail")
        XCTAssertTrue(items[3].event.message.contains("2,147.48 MB"))
        for item in items { XCTAssertLessThanOrEqual(item.event.context.serialised.count, DiagnosticsEvent.maxContextBytes) }
    }

    func testTheSamePayloadGivesTheSameIDs() {
        let a = MetricKitDiagnostics.items(from: Data(Self.payload.utf8), install: "INSTALL", redactor: redactor, now: now)
        let b = MetricKitDiagnostics.items(from: Data(Self.payload.utf8), install: "INSTALL", redactor: redactor, now: now.addingTimeInterval(99))
        XCTAssertEqual(a.map(\.event.id), b.map(\.event.id))
        XCTAssertEqual(Set(a.map(\.event.id)).count, 4)
    }

    func testDeepStacksAreCutFromTheBottom() {
        var frame = JSONValue.object(["binaryName": .string("FalconMail"), "offsetIntoBinaryTextSegment": .int(0)])
        for depth in 1...300 {
            frame = .object(["binaryName": .string("FalconMail"), "offsetIntoBinaryTextSegment": .int(Int64(depth)), "subFrames": .array([frame])])
        }
        let tree = JSONValue.object(["callStacks": .array([.object(["threadAttributed": .bool(true), "callStackRootFrames": .array([frame])])])])
        let pruned = MetricKitDiagnostics.attributedFirst(tree)
        var depth = 0
        var cursor = pruned["callStacks"]?.arrayValue?.first?["callStackRootFrames"]?.arrayValue?.first
        XCTAssertEqual(cursor?["offsetIntoBinaryTextSegment"], .int(300), "the top of the stack is kept")
        while let next = cursor?["subFrames"]?.arrayValue?.first { cursor = next; depth += 1 }
        XCTAssertEqual(depth, 64)
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
