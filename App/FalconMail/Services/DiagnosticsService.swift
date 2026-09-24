import Foundation
import MetricKit
import Observation
import FalconCore

/// FalconMail's side of diagnostics: builds the centre from the Info.plist and the Settings
/// switch, hands it MetricKit's reports and the model's figures, and tells it when the app
/// quits normally. What is sent, and when, is described in docs/DIAGNOSTICS.md.
@MainActor
@Observable
final class DiagnosticsService {
    /// A variable only so the debug snapshots can show a stand-in.
    static var shared = DiagnosticsService()
    static let enabledKey = "sendDiagnostics"

    /// Only a Release build sends; Debug, snapshot and test builds never do.
    static var isReleaseBuild: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    private(set) var isEnabled: Bool
    /// False for any build that can never send, whatever the switch says.
    let buildMaySend: Bool
    let diagnosticsID: String
    @ObservationIgnored private let center: DiagnosticsCenter?
    @ObservationIgnored private var metrics: MetricKitReceiver?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var launchSeconds: Double?

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        let enabled = defaults.object(forKey: DiagnosticsService.enabledKey) as? Bool ?? true
        let text = (bundle.object(forInfoDictionaryKey: "FalconDiagnosticsURL") as? String)?.trimmed ?? ""
        let gate = DiagnosticsGate(endpoint: text.isEmpty ? nil : URL(string: text),
                                   key: bundle.object(forInfoDictionaryKey: "FalconDiagnosticsKey") as? String ?? "",
                                   isReleaseBuild: DiagnosticsService.isReleaseBuild, bundleIdentifier: bundle.bundleIdentifier,
                                   userEnabled: enabled)
        let center = DiagnosticsCenter(directory: FileLayout().diagnosticsDirectory, gate: gate,
                                       environment: .current(bundle: bundle, channel: DiagnosticsService.isReleaseBuild ? "release" : "debug"))
        self.center = center
        isEnabled = enabled
        buildMaySend = gate.buildMaySend
        diagnosticsID = center.diagnosticsID
    }

    #if DEBUG
    /// Looks like a release build with the switch on, and sends nothing.
    init(standInID: String) {
        center = nil
        isEnabled = true
        buildMaySend = true
        diagnosticsID = standInID
    }
    #endif

    func start() {
        center?.start { [weak self] in
            await self?.healthInput() ?? DiagnosticsHealthInput(accounts: [], storeBytes: 0)
        }
        updateMetricKit()
    }

    /// The mailbox window is up: the health report can count its accounts from now on, and
    /// folder names are taken out of anything logged.
    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        if let started = ProcessMetrics.startDate() { launchSeconds = Date().timeIntervalSince(started) }
        followRedactionInputs()
    }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: DiagnosticsService.enabledKey)
        center?.setEnabled(on)
        updateMetricKit()
    }

    func noteSyncPass() {
        center?.noteSyncPass()
    }

    /// A normal quit, so the next launch does not count this session as a crash.
    func endSession() {
        center?.endSession()
    }

    func pendingText() -> String {
        center?.pendingDescription() ?? ""
    }

    private func updateMetricKit() {
        if center?.isSending == true, metrics == nil, let center {
            metrics = MetricKitReceiver(center: center)
        } else if center?.isSending != true {
            metrics?.stop()
            metrics = nil
        }
    }

    private func followRedactionInputs() {
        guard let model, let center else { return }
        withObservationTracking {
            let hosts = Set(model.accounts.flatMap { [$0.imapHost, $0.smtpHost] })
            let labels = model.folders.values.flatMap { $0.flatMap { [$0.path, $0.name] } }
            center.updateRedaction(serverHosts: hosts, labels: labels)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followRedactionInputs() }
        }
    }

    private func healthInput() async -> DiagnosticsHealthInput {
        guard let model else { return DiagnosticsHealthInput(accounts: [], storeBytes: 0, launchSeconds: launchSeconds) }
        var accounts: [DiagnosticsHealthInput.Account] = []
        for account in model.accounts {
            let folders = model.folders[account.id] ?? []
            accounts.append(DiagnosticsHealthInput.Account(info: account, folders: folders.count,
                                                           messages: folders.reduce(0) { $0 + $1.totalCount },
                                                           bytesDownToday: await BandwidthMeter.shared.spentToday(account.id)))
        }
        let root = model.layout.root
        let storeBytes = await Task.detached(priority: .utility) { DiagnosticsService.size(of: root) }.value
        return DiagnosticsHealthInput(accounts: accounts, storeBytes: storeBytes, launchSeconds: launchSeconds)
    }

    nonisolated private static func size(of directory: URL) -> Int {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total = 0
        while let url = files.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += values.totalFileAllocatedSize ?? 0
        }
        return total
    }
}

/// Crash, hang, CPU and disk-write reports from MetricKit, which delivers them once a day or
/// at the next launch, each as JSON the centre maps to events.
private final class MetricKitReceiver: NSObject, MXMetricManagerSubscriber {
    private let center: DiagnosticsCenter

    init(center: DiagnosticsCenter) {
        self.center = center
        super.init()
        MXMetricManager.shared.add(self)
        for payload in MXMetricManager.shared.pastDiagnosticPayloads {
            center.ingestMetricKit(payload.jsonRepresentation())
        }
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { center.ingestMetricKit(payload.jsonRepresentation()) }
    }
}
