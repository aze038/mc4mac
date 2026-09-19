import SwiftUI
import AppKit
import FalconCore

@MainActor
final class UpdateManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case available
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var release: ReleaseInfo?
    @Published var lastChecked: Date?
    @AppStorage("updates.skippedVersion") private var skippedVersion = ""
    @AppStorage("updates.remindAfter") private var remindAfter = 0.0
    @AppStorage("updates.automatic") var automaticChecks = true
    @AppStorage("updates.prereleases") var includePrereleases = false

    let repository: String
    var beforeRelaunch: (() async -> Void)?
    private var timer: Timer?
    private let checkInterval: TimeInterval = 6 * 3600

    static let tokenAccount = "github.releases.token"

    init() {
        repository = (Bundle.main.object(forInfoDictionaryKey: "FalconUpdateRepository") as? String) ?? "aze038/mc4mac"
    }

    var currentVersion: AppVersion {
        AppVersion((Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0")
    }

    var isMandatory: Bool { release?.isMandatory(currentVersion: currentVersion) ?? false }

    var shouldPrompt: Bool {
        guard let release, case .available = phase else {
            if case .downloading = phase { return true }
            if case .installing = phase { return true }
            if case .failed = phase, release != nil { return true }
            return false
        }
        if isMandatory { return true }
        if release.tag == skippedVersion { return false }
        return Date().timeIntervalSince1970 >= remindAfter
    }

    func start() {
        guard automaticChecks else { return }
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await check(userInitiated: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(userInitiated: false) }
        }
    }

    func check(userInitiated: Bool) async {
        if case .downloading = phase { return }
        if case .installing = phase { return }
        phase = .checking
        let token = try? KeychainStore().load(account: UpdateManager.tokenAccount).map { String(decoding: $0, as: UTF8.self) }
        let client = GitHubReleaseClient(repository: repository, token: token ?? nil)
        do {
            let latest = try await client.latestRelease(includePrerelease: includePrereleases)
            lastChecked = Date()
            if let latest, currentVersion < latest.version.value {
                release = latest
                if userInitiated { skippedVersion = ""; remindAfter = 0 }
                phase = .available
            } else {
                release = nil
                phase = .idle
            }
        } catch {
            phase = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    func skip() {
        guard let release, !isMandatory else { return }
        skippedVersion = release.tag
        phase = .idle
    }

    func later() {
        guard !isMandatory else { return }
        remindAfter = Date().addingTimeInterval(24 * 3600).timeIntervalSince1970
        phase = .idle
    }

    func installNow() {
        guard let release else { return }
        let token = try? KeychainStore().load(account: UpdateManager.tokenAccount).map { String(decoding: $0, as: UTF8.self) }
        let client = GitHubReleaseClient(repository: repository, token: token ?? nil)
        phase = .downloading(0)
        Task {
            do {
                let zip = try await UpdateInstaller.download(client.downloadRequest(for: release), expectedSHA256: release.sha256) { p in
                    Task { @MainActor in self.phase = .downloading(p) }
                }
                phase = .installing
                let newApp = try UpdateInstaller.extractApp(from: zip)
                if let v = UpdateInstaller.bundleVersion(of: newApp), AppVersion(v) < release.version.value {
                    throw FalconError.storage("Downloaded app reports version \(v), expected \(release.version.value)")
                }
                try UpdateInstaller.verifySignature(of: newApp)
                await beforeRelaunch?()
                let current = Bundle.main.bundleURL
                try UpdateInstaller.install(newApp: newApp, replacing: current)
                UpdateInstaller.relaunch(current)
                NSApp.terminate(nil)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
