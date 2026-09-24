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
    private var healthInProgress = false
    private var loopTask: Task<Void, Never>?
    private var uploading = false
    private var pendingSave: DispatchWorkItem?
    private var markerActive = false

    struct Identity: Codable {
        var install: String
        var salt: Data
    }

    struct State: Codable {
        var lastHealthAt: Date?
        /// The date of the newest crash report looked at, where the next scan starts.
        var crashReportsCheckedUntil: Date?
        var seenMetricKit: [String] = []
        /// When the switch was last turned on. MetricKit's reports from before then are left out.
        var enabledAt: Date?
        var recentCrashes: [CrashNote] = []
        /// The counts for the next health report, kept across launches so it covers the whole day.
        var counters: DiagnosticsCounters?

        /// Dates are kept as the seconds a `Date` holds rather than as ISO 8601 text, which drops
        /// the fraction of a second a crash report's file date carries: the same report would
        /// then count as new at every launch.
        static func load(from url: URL) -> State? {
            AtomicFile.read(url).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        }

        func save(to url: URL) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(self) { try? AtomicFile.write(data, to: url) }
        }
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
        self.state = State.load(from: directory.appendingPathComponent("state.json")) ?? State()
        let now = clock.now()
        self.schedule = DiagnosticsSchedule(launchedAt: now)
        self.counters = state.counters ?? DiagnosticsCounters(since: now)
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
            pendingSave?.cancel()
            pendingSave = nil
        }
    }

    /// A normal quit: the next launch reports a clean exit.
    public func endSession() {
        work.sync {
            queue?.flush()
            if gate.allowsUpload { saveState() }
            if markerActive { marker.end() }
            markerActive = false
        }
    }

    /// The Settings switch. Off stops uploads and deletes everything waiting; on starts
    /// afresh, leaving out crashes, hangs and counts from while it was off.
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
                let now = clock.now()
                state.crashReportsCheckedUntil = max(state.crashReportsCheckedUntil ?? .distantPast, now)
                state.enabledAt = now
                counters = DiagnosticsCounters(since: now)
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
            scheduleSave()
        }
    }

    public func noteSyncPass() {
        work.async { [self] in
            guard gate.allowsUpload else { return }
            counters.syncPasses += 1
            scheduleSave()
        }
    }

    /// A MetricKit diagnostic payload, as `MXDiagnosticPayload.jsonRepresentation()` gives it.
    public func ingestMetricKit(_ json: Data) {
        work.async { [self] in
            guard gate.allowsUpload, let queue else { return }
            var urgent = false
            for item in MetricKitDiagnostics.items(from: json, install: identity.install, redactor: redactor, now: clock.now())
            where !state.seenMetricKit.contains(item.event.id) && !queue.contains(id: item.event.id) {
                state.seenMetricKit.append(item.event.id)
                // A payload covers a span, often a day, and says only that its reports fall
                // within it, so one that began before the switch went on is left out whole.
                if let enabledAt = state.enabledAt, item.event.firstAt < enabledAt { continue }
                let app = item.app ?? environment.app
                if item.event.kind == .crash,
                   !isNewCrash(CrashNote(source: .metricKit, from: item.event.firstAt, to: item.event.lastAt, app: app)) { continue }
                queue.add(DiagnosticsRecord(event: item.event, app: app, os: item.os ?? environment.os))
                urgent = urgent || item.event.kind.isUrgent
            }
            state.seenMetricKit = Array(state.seenMetricKit.suffix(200))
            saveState()
            if urgent { wakeForUrgent() }
        }
    }

    /// Everything of the record that is sent goes through the redactor first: the message,
    /// with the folder and file names the record says it holds, and the context. The signature
    /// and title are made only from the area, the code and the place in the code, and the code
    /// from a typed error where there is one, so no server's words can reach either.
    private func makeEvent(_ entry: LogRecord) -> DiagnosticsEvent {
        var names = entry.names
        // The folder or address a failure names; a folder list set aside is FalconMail's own file.
        if let failure = entry.error as? MailServiceError, let name = failure.name, failure.kind != .folderListUnreadable {
            names.append(name)
        }
        if let unreadable = entry.error as? FolderIndexUnreadable { names += unreadable.names }
        let message = redactor.redact(entry.message, naming: names)
        let code = entry.code.map(DiagnosticsSignature.word) ?? DiagnosticsSignature.code(for: entry.error, message: message)
        let kind: DiagnosticsKind = entry.level == .error ? .error : .warning
        var context: [String: JSONValue] = ["level": .string(entry.level.rawValue),
                                            "source": .string("\(DiagnosticsSignature.fileName(entry.file)):\(entry.line)")]
        if let error = entry.error {
            let ns = error as NSError
            context["errorType"] = .string(String(describing: type(of: error)))
            context["errorDomain"] = .string(ns.domain)
            context["errorCode"] = .int(Int64(ns.code))
        }
        if let failure = entry.error as? MailServiceError {
            context["failure"] = .string(failure.kind.rawValue)
        } else if let refusal = entry.error as? GoogleAPIError {
            context["failure"] = .string(refusal.kind.rawValue)
            if refusal.httpStatus > 0 { context["httpStatus"] = .int(Int64(refusal.httpStatus)) }
        }
        for (key, value) in entry.details where context[key] == nil { context[key] = .string(value) }
        return DiagnosticsEvent(kind: kind, signature: DiagnosticsSignature.make(area: entry.area, code: code, file: entry.file, function: entry.function),
                                title: DiagnosticsTitle.make(kind: kind, area: entry.area, code: code), area: entry.area,
                                firstAt: entry.date, message: message, context: redactor.redact(.object(context), naming: names),
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
        let scan = crashReports.scan(after: state.crashReportsCheckedUntil, now: clock.now())
        guard let checkedUntil = scan.checkedUntil else { return }
        // Never sent, but noted, so MetricKit's copy of the same crash is left out too.
        for report in scan.builtLocally {
            let time = CrashReportDigest.time(of: report)
            _ = isNewCrash(CrashNote(source: .report, from: time, to: time, app: CrashReportDigest.app(of: report) ?? environment.app))
        }
        var found = false
        for report in scan.reports {
            let (event, app, os) = CrashReportDigest.event(from: report, install: identity.install, redactor: redactor)
            let crashed = app ?? environment.app
            guard isNewCrash(CrashNote(source: .report, from: event.firstAt, to: event.firstAt, app: crashed)),
                  !queue.contains(id: event.id) else { continue }
            queue.add(DiagnosticsRecord(event: event, app: crashed, os: os ?? environment.os))
            found = true
        }
        state.crashReportsCheckedUntil = max(state.crashReportsCheckedUntil ?? .distantPast, checkedUntil)
        saveState()
        if found { schedule.urgent(at: clock.now()) }
    }

    /// Notes a crash and says whether to send it: not when the other source has already sent it.
    private func isNewCrash(_ note: CrashNote) -> Bool {
        if let i = state.recentCrashes.firstIndex(where: { $0.isSameCrash(as: note) }) {
            state.recentCrashes[i].matched = true
            return false
        }
        state.recentCrashes = Array((state.recentCrashes + [note]).suffix(50))
        return true
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
        // Cut short because the loop was restarted or stopped, which says nothing about the server.
        let cancelled = Task.isCancelled
        work.sync {
            uploading = false
            let now = clock.now()
            switch failure {
            case nil: schedule.succeeded(at: now)
            case _ where cancelled: break
            case .offline?: schedule.offline(at: now)
            default: schedule.failed(at: now, jitter: random())
            }
            if queue?.records.contains(where: { !$0.sealed && $0.event.kind.isUrgent }) == true { schedule.urgent(at: now) }
        }
        return failure.map { .failed($0) } ?? .sent(events: sent, duplicates: duplicates)
    }

    /// The daily health report, when a day has passed since the last. Gathering its figures
    /// takes a while, so the report is marked as under way first: a second caller in that time,
    /// such as a loop restarted for a crash, finds it so and leaves it.
    func recordHealthIfDue() async {
        let provider: (@Sendable () async -> DiagnosticsHealthInput)? = work.sync {
            guard gate.allowsUpload, queue != nil, !healthInProgress, let healthProvider else { return nil }
            if let last = state.lastHealthAt, clock.now().timeIntervalSince(last) < DiagnosticsCenter.healthInterval { return nil }
            healthInProgress = true
            return healthProvider
        }
        guard let provider else { return }
        let input = await provider()
        work.sync {
            healthInProgress = false
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
            guard !Task.isCancelled else { return }
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

    /// The order a person reads an upload in: whose it is first, then each event opening with
    /// its plain-language title and ending with its technical detail.
    static let readingOrder = ["install", "app", "os", "hw", "locale", "schema", "events",
                               "title", "provider", "kind", "host", "ref", "version", "build", "channel",
                               "area", "count", "firstAt", "lastAt", "message", "account", "signature", "id", "context"]

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
                return JSONValue.object(o).readable(order: DiagnosticsCenter.readingOrder)
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

    /// Writes the queue and the counts a moment later, so a burst of errors costs one write.
    private func scheduleSave() {
        guard pendingSave == nil else { return }
        let save = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingSave = nil
            guard gate.allowsUpload else { return }
            queue?.flush()
            saveState()
        }
        pendingSave = save
        work.asyncAfter(deadline: .now() + 2, execute: save)
    }

    private func saveState() {
        state.counters = counters
        state.save(to: directory.appendingPathComponent("state.json"))
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
