import Foundation

/// Whether this copy of FalconMail may send diagnostics. Every condition must hold: an
/// endpoint and key built into the Info.plist, a Release build, the real app's bundle
/// identifier, and the person's switch on. Debug, snapshot and test builds therefore never
/// send, whatever else they do.
public struct DiagnosticsGate: Sendable, Equatable {
    public static let releaseBundleIdentifier = "com.falconmail.app"

    public var endpoint: URL?
    public var key: String
    public var isReleaseBuild: Bool
    public var bundleIdentifier: String?
    public var userEnabled: Bool

    public init(endpoint: URL?, key: String, isReleaseBuild: Bool, bundleIdentifier: String?, userEnabled: Bool) {
        self.endpoint = endpoint
        self.key = key
        self.isReleaseBuild = isReleaseBuild
        self.bundleIdentifier = bundleIdentifier
        self.userEnabled = userEnabled
    }

    /// Everything but the switch: whether this build could ever send.
    public var buildMaySend: Bool {
        guard let endpoint, endpoint.scheme?.lowercased() == "https", endpoint.host?.isEmpty == false else { return false }
        return !key.trimmed.isEmpty && isReleaseBuild && bundleIdentifier == DiagnosticsGate.releaseBundleIdentifier
    }

    public var allowsUpload: Bool { buildMaySend && userEnabled }
}

/// The facts about this Mac and build that every upload carries.
public struct DiagnosticsEnvironment: Sendable, Equatable {
    public var app: DiagnosticsApp
    public var os: String
    public var hardware: String
    public var locale: String
    public var homePath: String

    public init(app: DiagnosticsApp, os: String, hardware: String, locale: String, homePath: String) {
        self.app = app
        self.os = os
        self.hardware = hardware
        self.locale = locale
        self.homePath = homePath
    }

    public static func current(bundle: Bundle, channel: String) -> DiagnosticsEnvironment {
        let info = bundle.infoDictionary ?? [:]
        let locale = Locale.current.identifier.split(separator: "@").first.map(String.init) ?? "en"
        return DiagnosticsEnvironment(
            app: DiagnosticsApp(version: info["CFBundleShortVersionString"] as? String ?? "0.0.0",
                                build: info["CFBundleVersion"] as? String ?? "0", channel: channel),
            os: ProcessMetrics.osDescription(), hardware: ProcessMetrics.hardwareModel(), locale: locale,
            homePath: NSHomeDirectory())
    }
}

public enum DiagnosticsUploadOutcome: Equatable, Sendable {
    case notAllowed
    case busy
    case nothingToSend
    case sent(events: Int, duplicates: Int)
    case failed(DiagnosticsUploadError)
}

/// Collects warnings, errors, crashes, hangs and a daily health report, redacts them, keeps
/// them in a queue on disk and uploads them in the background. Nothing it does blocks the
/// caller: logged lines are handed to its own queue, and uploads run in a task of their own.
///
/// It keeps its files in one folder: `install.json` (this install's ID and the salt of its
/// references, which never leaves the Mac), `state.json`, `queue.jsonl` and `session.marker`.
public final class DiagnosticsCenter: @unchecked Sendable {
    public static let healthInterval: TimeInterval = 24 * 60 * 60

    public let directory: URL
    private let work = DispatchQueue(label: "falconmail.diagnostics", qos: .utility)
    private let environment: DiagnosticsEnvironment
    private let crashReports: CrashReportScanner?
    private let session: URLSession
    private let clock: DiagnosticsClock
    private let random: @Sendable () -> Double
    private let identity: Identity
    private let marker: SessionMarker

    // The gate is read from any thread, the main one included, so it sits behind a lock
    // rather than on `work`, where a crash-report scan could keep a reader waiting.
    private let gateLock = NSLock()
    private var storedGate: DiagnosticsGate
    private var started = false

    // Everything below is touched on `work` only.
    private var redactor: DiagnosticsRedactor
    private var queue: DiagnosticsQueue?
    private var state: State
    private var schedule: DiagnosticsSchedule
    private var counters: DiagnosticsCounters
    private var healthProvider: (@Sendable () async -> DiagnosticsHealthInput)?
    private var loopTask: Task<Void, Never>?
    private var uploading = false
    private var flushPending = false
    private var markerActive = false

    struct Identity: Codable {
        var install: String
        var salt: Data
    }

    struct State: Codable {
        var lastHealthAt: Date?
        var lastCrashReportAt: Date?
        var seenMetricKit: [String] = []
    }

    public init(directory: URL, gate: DiagnosticsGate, environment: DiagnosticsEnvironment,
                crashReportsDirectory: URL? = CrashReportScanner.defaultDirectory,
                session: URLSession = DiagnosticsUploader.makeSession(),
                clock: DiagnosticsClock = SystemDiagnosticsClock(),
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.directory = directory
        self.storedGate = gate
        self.environment = environment
        self.crashReports = crashReportsDirectory.map(CrashReportScanner.init(directory:))
        self.session = session
        self.clock = clock
        self.random = random
        self.identity = DiagnosticsCenter.loadIdentity(in: directory)
        self.marker = SessionMarker(directory: directory)
        self.redactor = DiagnosticsRedactor(salt: identity.salt, homePath: environment.homePath)
        self.state = AtomicFile.readJSON(State.self, from: directory.appendingPathComponent("state.json")) ?? State()
        let now = clock.now()
        self.schedule = DiagnosticsSchedule(launchedAt: now)
        self.counters = DiagnosticsCounters(since: now)
    }

    /// The random UUID that tells this install's uploads apart from other Macs'.
    public var installID: String { identity.install }

    /// What Settings shows, enough to find this Mac's rows in the sheet.
    public var diagnosticsID: String { String(identity.install.prefix(8)) }

    public var buildMaySend: Bool { gate.buildMaySend }
    public var isSending: Bool { gate.allowsUpload }
    public var nextUploadDate: Date { work.sync { schedule.nextAttempt } }
    private var gate: DiagnosticsGate { gateLock.withLock { storedGate } }
    var queueURL: URL { directory.appendingPathComponent("queue.jsonl") }

    // MARK: Life cycle

    /// Begins capturing: notes how the last session ended, picks up new crash reports,
    /// listens to warnings and errors, and starts the upload schedule.
    public func start(healthProvider: (@Sendable () async -> DiagnosticsHealthInput)? = nil) {
        let first: Bool = gateLock.withLock {
            defer { started = true }
            return !started
        }
        guard first else { return }
        work.async { [self] in
            self.healthProvider = healthProvider
            schedule = DiagnosticsSchedule(launchedAt: clock.now())
            let gate = self.gate
            if gate.allowsUpload {
                openQueue()
                recordLaunch()
                scanCrashReports()
            } else if gate.buildMaySend {
                DiagnosticsQueue(url: queueURL).clear()
            }
        }
        Log.observer = { [weak self] record in self?.record(record) }
        restartLoop()
    }

    /// Stops listening and uploading, for tests and for an app that is going away.
    public func stop() {
        Log.observer = nil
        work.sync {
            loopTask?.cancel()
            loopTask = nil
        }
    }

    /// A normal quit: the next launch reports a clean exit.
    public func endSession() {
        work.sync {
            queue?.flush()
            if markerActive { marker.end() }
            markerActive = false
        }
    }

    /// The Settings switch. Off stops uploads and deletes everything waiting; on starts
    /// afresh, leaving out crashes from while it was off.
    public func setEnabled(_ on: Bool) {
        let changed: Bool = gateLock.withLock {
            guard storedGate.userEnabled != on else { return false }
            storedGate.userEnabled = on
            return started
        }
        guard changed else { return }
        // Acts on the value switched to rather than the gate's value by the time this runs,
        // so off and on again in quick succession still deletes what was waiting.
        work.async { [self] in
            if on {
                guard gate.buildMaySend else { return }
                state.lastCrashReportAt = max(state.lastCrashReportAt ?? .distantPast, clock.now())
                saveState()
                openQueue()
                _ = marker.begin(version: environment.app.version, now: clock.now())
                markerActive = true
                schedule = DiagnosticsSchedule(launchedAt: clock.now())
            } else {
                loopTask?.cancel()
                loopTask = nil
                (queue ?? DiagnosticsQueue(url: queueURL)).clear()
                queue = nil
                if markerActive { marker.end() }
                markerActive = false
            }
        }
        restartLoop()
    }

    /// Server names and folder names, so the redactor keeps the former and takes out the latter.
    public func updateRedaction(serverHosts: Set<String>, labels: [String]) {
        work.async { [self] in
            redactor.serverHosts = Set(serverHosts.map { $0.lowercased() })
            redactor.labels = labels
        }
    }

    /// Waits for everything handed to the centre so far, for tests.
    public func waitUntilIdle() {
        work.sync {}
    }

    // MARK: Capture

    public func record(_ entry: LogRecord) {
        work.async { [self] in
            guard gate.allowsUpload, let queue else { return }
            let event = makeEvent(entry)
            switch event.kind {
            case .error: counters.errors += 1
            default: counters.warnings += 1
            }
            if event.signature.contains(".throttled@") { counters.throttles += 1 }
            queue.add(DiagnosticsRecord(event: event, app: environment.app, os: environment.os))
            scheduleFlush()
        }
    }

    public func noteSyncPass() {
        work.async { [self] in counters.syncPasses += 1 }
    }

    /// A MetricKit diagnostic payload, as `MXDiagnosticPayload.jsonRepresentation()` gives it.
    public func ingestMetricKit(_ json: Data) {
        work.async { [self] in
            guard gate.allowsUpload, let queue else { return }
            var urgent = false
            for item in MetricKitDiagnostics.items(from: json, install: identity.install, redactor: redactor, now: clock.now())
            where !state.seenMetricKit.contains(item.event.id) && !queue.contains(id: item.event.id) {
                queue.add(DiagnosticsRecord(event: item.event, app: item.app ?? environment.app, os: item.os ?? environment.os))
                state.seenMetricKit.append(item.event.id)
                urgent = urgent || item.event.kind.isUrgent
            }
            state.seenMetricKit = Array(state.seenMetricKit.suffix(200))
            saveState()
            if urgent { wakeForUrgent() }
        }
    }

    private func makeEvent(_ entry: LogRecord) -> DiagnosticsEvent {
        let message = redactor.redact(entry.message)
        let code = DiagnosticsSignature.code(for: entry.error, message: message)
        let kind: DiagnosticsKind = entry.level == .error ? .error : .warning
        var context: [String: JSONValue] = ["level": .string(entry.level.rawValue)]
        if let error = entry.error {
            let ns = error as NSError
            context["errorType"] = .string(String(describing: type(of: error)))
            context["errorDomain"] = .string(ns.domain)
            context["errorCode"] = .int(Int64(ns.code))
        }
        return DiagnosticsEvent(kind: kind, signature: DiagnosticsSignature.make(area: entry.area, code: code, file: entry.file, line: entry.line),
                                title: DiagnosticsTitle.make(kind: kind, area: entry.area, code: code), area: entry.area,
                                firstAt: entry.date, message: message, context: redactor.redact(.object(context)),
                                account: entry.account.map { DiagnosticsAccount($0, redactor: redactor) })
    }

    private func recordLaunch() {
        let now = clock.now()
        let (exit, previous) = marker.begin(version: environment.app.version, now: now)
        markerActive = true
        var context: [String: JSONValue] = ["previousExit": .string(exit.rawValue)]
        if let previous {
            context["previousVersion"] = .string(previous.version)
            context["previousStartedAt"] = .string(DiagnosticsJSON.iso(previous.startedAt))
        }
        let message: String
        switch exit {
        case .clean: message = "The previous session ended normally"
        case .unclean: message = "The previous session ended without FalconMail quitting: it crashed, was forced to quit or the Mac lost power"
        case .first: message = "The first launch with diagnostics switched on"
        }
        let event = DiagnosticsEvent(kind: .launch, signature: DiagnosticsSignature.make(area: "Launch", code: exit.rawValue, place: "FalconMail"),
                                     title: DiagnosticsTitle.make(kind: .launch, area: "launch", code: exit.rawValue), area: "launch",
                                     firstAt: now, message: message, context: .object(context))
        queue?.add(DiagnosticsRecord(event: event, app: environment.app, os: environment.os))
    }

    private func scanCrashReports() {
        guard let crashReports, let queue else { return }
        let reports = crashReports.reports(after: state.lastCrashReportAt, now: clock.now())
        guard !reports.isEmpty else { return }
        for report in reports {
            let (event, app, os) = CrashReportDigest.event(from: report, install: identity.install, redactor: redactor)
            if !queue.contains(id: event.id) {
                queue.add(DiagnosticsRecord(event: event, app: app ?? environment.app, os: os ?? environment.os))
            }
            state.lastCrashReportAt = max(state.lastCrashReportAt ?? .distantPast, report.modified)
        }
        saveState()
        schedule.urgent(at: clock.now())
    }

    // MARK: Uploading

    /// Sends everything waiting, batch by batch, and takes each batch out of the queue only
    /// once the server has confirmed it. A batch that fails stays, sealed, to be sent again
    /// under the same event IDs.
    public func uploadNow() async -> DiagnosticsUploadOutcome {
        enum Plan { case done(DiagnosticsUploadOutcome), send([DiagnosticsUpload], DiagnosticsUploader) }
        let plan: Plan = work.sync {
            guard gate.allowsUpload, let url = gate.endpoint, let queue else { return .done(.notAllowed) }
            guard !uploading else { return .done(.busy) }
            queue.flush()
            let now = clock.now()
            guard !queue.isEmpty else {
                schedule.succeeded(at: now)
                return .done(.nothingToSend)
            }
            uploading = true
            let key = gate.key
            let uploads = DiagnosticsUploader.batches(queue.records) { app, os, events in
                DiagnosticsUpload(key: key, install: identity.install, app: app, os: os, hw: environment.hardware,
                                  locale: environment.locale, sentAt: now, events: events)
            }
            queue.seal(Set(queue.records.map(\.event.id)))
            return .send(uploads, DiagnosticsUploader(endpoint: DiagnosticsEndpoint(url: url, key: key), session: session))
        }
        let uploads: [DiagnosticsUpload]
        let uploader: DiagnosticsUploader
        switch plan {
        case .done(let outcome): return outcome
        case .send(let batches, let sender): (uploads, uploader) = (batches, sender)
        }
        var sent = 0
        var duplicates = 0
        var failure: DiagnosticsUploadError?
        for upload in uploads {
            do {
                let receipt = try await uploader.send(upload)
                work.sync { queue?.remove(Set(upload.events.map(\.id))) }
                sent += upload.events.count
                duplicates += receipt.duplicates
            } catch let error as DiagnosticsUploadError {
                failure = error
                break
            } catch {
                failure = .network("cancelled")
                break
            }
        }
        work.sync {
            uploading = false
            let now = clock.now()
            switch failure {
            case nil: schedule.succeeded(at: now)
            case .offline?: schedule.offline(at: now)
            default: schedule.failed(at: now, jitter: random())
            }
            if queue?.records.contains(where: { !$0.sealed && $0.event.kind.isUrgent }) == true { schedule.urgent(at: now) }
        }
        return failure.map { .failed($0) } ?? .sent(events: sent, duplicates: duplicates)
    }

    /// The daily health report, when a day has passed since the last.
    func recordHealthIfDue() async {
        let provider: (@Sendable () async -> DiagnosticsHealthInput)? = work.sync {
            guard gate.allowsUpload, queue != nil else { return nil }
            if let last = state.lastHealthAt, clock.now().timeIntervalSince(last) < DiagnosticsCenter.healthInterval { return nil }
            return healthProvider
        }
        guard let provider else { return }
        let input = await provider()
        work.sync {
            guard gate.allowsUpload, let queue else { return }
            let now = clock.now()
            let event = DiagnosticsHealth.event(input: input, counters: counters, app: environment.app, redactor: redactor, now: now)
            queue.add(DiagnosticsRecord(event: event, app: environment.app, os: environment.os))
            counters = DiagnosticsCounters(since: now)
            state.lastHealthAt = now
            saveState()
        }
    }

    private func restartLoop() {
        work.async { [self] in
            loopTask?.cancel()
            guard gate.allowsUpload else {
                loopTask = nil
                return
            }
            loopTask = Task.detached(priority: .utility) { [weak self] in await self?.loop() }
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            let wait: TimeInterval? = work.sync { gate.allowsUpload ? schedule.nextAttempt.timeIntervalSince(clock.now()) : nil }
            guard let wait else { return }
            if wait > 0 {
                do { try await clock.sleep(seconds: wait) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await recordHealthIfDue()
            _ = await uploadNow()
        }
    }

    /// A crash or hang was found: upload within a minute. The loop is restarted to wait the
    /// shorter time, unless an upload is under way, which reschedules when it ends.
    private func wakeForUrgent() {
        schedule.urgent(at: clock.now())
        guard !uploading, gate.allowsUpload else { return }
        loopTask?.cancel()
        loopTask = Task.detached(priority: .utility) { [weak self] in await self?.loop() }
    }

    // MARK: What is waiting

    /// Everything waiting, as it would be sent, for the person to read. The ingest key is left
    /// out; it is the same for every copy of FalconMail and says nothing about this one.
    public func pendingDescription() -> String {
        work.sync {
            guard let records = queue?.records, !records.isEmpty else { return "" }
            let now = clock.now()
            let uploads = DiagnosticsUploader.batches(records) { app, os, events in
                DiagnosticsUpload(key: "", install: identity.install, app: app, os: os, hw: environment.hardware,
                                  locale: environment.locale, sentAt: now, events: events)
            }
            return uploads.compactMap { upload -> String? in
                guard let data = try? DiagnosticsJSON.encoder.encode(upload), case .object(var o)? = JSONValue.parse(data) else { return nil }
                o["key"] = nil
                o["sentAt"] = nil
                return (try? DiagnosticsJSON.prettyEncoder.encode(JSONValue.object(o))).map { String(decoding: $0, as: UTF8.self) }
            }.joined(separator: "\n\n")
        }
    }

    public var pendingCount: Int {
        work.sync { queue?.records.count ?? 0 }
    }

    var pendingRecords: [DiagnosticsRecord] {
        work.sync { queue?.records ?? [] }
    }

    // MARK: Files

    private func openQueue() {
        if queue == nil { queue = DiagnosticsQueue(url: queueURL) }
    }

    private func scheduleFlush() {
        guard queue?.needsFlush == true, !flushPending else { return }
        flushPending = true
        work.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.flushPending = false
            self?.queue?.flush()
        }
    }

    private func saveState() {
        try? AtomicFile.writeJSON(state, to: directory.appendingPathComponent("state.json"))
    }

    private static func loadIdentity(in directory: URL) -> Identity {
        let url = directory.appendingPathComponent("install.json")
        if let stored = AtomicFile.readJSON(Identity.self, from: url), UUID(uuidString: stored.install) != nil, stored.salt.count >= 16 {
            return stored
        }
        let fresh = Identity(install: UUID().uuidString, salt: Data.random(count: 32))
        try? AtomicFile.writeJSON(fresh, to: url)
        return fresh
    }
}
