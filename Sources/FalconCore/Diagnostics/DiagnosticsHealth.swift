import Foundation
import Darwin

/// What the app knows that the daily health report needs, gathered by the app at the time.
public struct DiagnosticsHealthInput: Sendable {
    public struct Account: Sendable {
        public var info: AccountInfo
        public var folders: Int
        public var messages: Int
        public var bytesDownToday: Int

        public init(info: AccountInfo, folders: Int, messages: Int, bytesDownToday: Int) {
            self.info = info
            self.folders = folders
            self.messages = messages
            self.bytesDownToday = bytesDownToday
        }
    }

    public var accounts: [Account]
    public var storeBytes: Int
    /// From the process starting to the mailbox window appearing.
    public var launchSeconds: Double?

    public init(accounts: [Account], storeBytes: Int, launchSeconds: Double? = nil) {
        self.accounts = accounts
        self.storeBytes = storeBytes
        self.launchSeconds = launchSeconds
    }
}

/// Counts kept between health reports.
struct DiagnosticsCounters: Sendable {
    var syncPasses = 0
    var throttles = 0
    var errors = 0
    var warnings = 0
    var since: Date
}

enum DiagnosticsHealth {
    static func event(input: DiagnosticsHealthInput, counters: DiagnosticsCounters, app: DiagnosticsApp,
                      redactor: DiagnosticsRedactor, now: Date) -> DiagnosticsEvent {
        var byProvider: [String: JSONValue] = [:]
        var byKind: [String: JSONValue] = [:]
        var perAccount: [JSONValue] = []
        for account in input.accounts {
            let ref = DiagnosticsAccount(account.info, redactor: redactor)
            byProvider[ref.provider] = .int((byProvider[ref.provider]?.intValue ?? 0) + 1)
            byKind[ref.kind] = .int((byKind[ref.kind]?.intValue ?? 0) + 1)
            perAccount.append(.object([
                "ref": .string(ref.ref), "provider": .string(ref.provider), "kind": .string(ref.kind), "host": .string(ref.host),
                "enabled": .bool(account.info.isEnabled), "folders": .int(Int64(account.folders)),
                "messages": .int(Int64(account.messages)), "bytesDownToday": .int(Int64(account.bytesDownToday)),
            ]))
        }
        let started = ProcessMetrics.startDate()
        var context: [String: JSONValue] = [
            "version": .string(app.version), "build": .string(app.build),
            "accounts": .object(["total": .int(Int64(input.accounts.count)), "byProvider": .object(byProvider), "byKind": .object(byKind)]),
            "perAccount": .array(perAccount),
            "storeBytes": .int(Int64(input.storeBytes)),
            "syncPasses": .int(Int64(counters.syncPasses)), "throttles": .int(Int64(counters.throttles)),
            "errors": .int(Int64(counters.errors)), "warnings": .int(Int64(counters.warnings)),
            "since": .string(DiagnosticsJSON.iso(counters.since)),
        ]
        if let started {
            context["launchedAt"] = .string(DiagnosticsJSON.iso(started))
            context["uptimeSeconds"] = .int(Int64(max(0, now.timeIntervalSince(started))))
        }
        if let launch = input.launchSeconds { context["launchSeconds"] = .double((launch * 10).rounded() / 10) }
        if let memory = ProcessMetrics.memoryFootprint() { context["memoryBytes"] = .int(Int64(memory)) }
        let messages = input.accounts.reduce(0) { $0 + $1.messages }
        let formatter = ByteCountFormatter()
        let message = "\(input.accounts.count) accounts, \(messages) messages on this Mac (\(formatter.string(fromByteCount: Int64(input.storeBytes)))), "
            + "\(counters.syncPasses) sync passes, \(counters.throttles) throttled, \(counters.errors) errors and \(counters.warnings) warnings since the last report"
        return DiagnosticsEvent(kind: .health, signature: DiagnosticsSignature.make(area: "Health", code: "daily", place: "FalconMail"),
                                title: DiagnosticsTitle.make(kind: .health, area: "health", code: "daily"), area: "health",
                                firstAt: counters.since, lastAt: now, message: message, context: .object(context))
    }
}

/// Whether the last session ended with the app quitting, found from a marker file written at
/// launch and removed on a normal quit: a marker still there at the next launch means the
/// app crashed, was forced to quit or the Mac lost power.
struct SessionMarker {
    enum PreviousExit: String { case clean, unclean, first }

    struct Contents: Codable {
        var startedAt: Date
        var version: String
    }

    let url: URL
    let seenFile: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("session.marker")
        seenFile = directory.appendingPathComponent("session.previous")
    }

    func begin(version: String, now: Date) -> (PreviousExit, Contents?) {
        let fm = FileManager.default
        let previous = AtomicFile.readJSON(Contents.self, from: url)
        let exit: PreviousExit
        if fm.fileExists(atPath: url.path) {
            exit = .unclean
        } else {
            exit = fm.fileExists(atPath: seenFile.path) ? .clean : .first
        }
        try? AtomicFile.writeJSON(Contents(startedAt: now, version: version), to: url)
        if exit == .first { try? AtomicFile.write(Data(), to: seenFile) }
        return (exit, previous)
    }

    func end() {
        try? FileManager.default.removeItem(at: url)
    }
}

public enum ProcessMetrics {
    /// The physical footprint, the figure Activity Monitor shows as Memory.
    public static func memoryFootprint() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : nil
    }

    public static func startDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// `MacBookPro18,3`.
    public static func hardwareModel() -> String {
        sysctlString("hw.model") ?? "Mac"
    }

    /// `macOS 26.6 (25G5023)`.
    public static func osDescription() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        return sysctlString("kern.osversion").map { "macOS \(version) (\($0))" } ?? "macOS \(version)"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
