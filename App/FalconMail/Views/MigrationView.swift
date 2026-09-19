import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FalconCore

struct MigrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [URL] = []
    @State private var profile: OutlookProfile?
    @State private var outlookAccountIDs: Set<Int> = []
    @State private var source: (any MigrationSource)?
    @State private var sourceTitle = ""
    @State private var loadingSource = false
    @State private var targetAccountID: UUID?
    @State private var mapping: [String: MigrationTarget] = [:]
    @State private var includeTrashJunk = false
    @State private var labelMigrated = true
    @State private var connections = 5
    @State private var verifying = false
    @State private var useGmailAPI = true
    @State private var importsPerMinute = 220
    @State private var uploadedBytes = 0
    @State private var rateSamples: [(Date, Int)] = []
    @State private var running = false
    @State private var dryRun = false
    @State private var status = ""
    @State private var done = 0
    @State private var total = 0
    @State private var appended = 0
    @State private var existing = 0
    @State private var failed = 0
    @State private var log: [String] = []
    @State private var task: Task<Void, Never>?
    @State private var confirmStart = false
    @State private var confirmUndo = false
    @State private var undoAvailable = 0

    private var targetFolders: [FolderInfo] { targetAccountID.flatMap { model.folders[$0] } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Migrate mail to Google Workspace").font(.title2.bold())
            Text("Reads your Outlook for Mac mailbox or an .olm archive and uploads every message straight to the matching folder, using no disk space. Messages that already exist in the target are skipped, so it is safe to run again.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            sourceSection
            accountSection
            targetSection
            if source != nil { mappingTable }
            progressSection
            Divider()
            buttons
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 820, maxWidth: .infinity, minHeight: 560, idealHeight: 700, maxHeight: .infinity)
        .alert("Start the migration?", isPresented: $confirmStart) {
            Button("Start") { start(dryRun: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Up to \(plannedCount) messages from \(sourceTitle) will be uploaded into \(targetEmail). Messages already in the target are skipped. You can undo the upload afterwards.")
        }
        .alert("Remove migrated messages?", isPresented: $confirmUndo) {
            Button("Remove", role: .destructive) { undo() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(undoAvailable) messages uploaded by the last migration into \(targetEmail) will be permanently removed from that mailbox.")
        }
        .onChange(of: targetAccountID) { _, _ in refreshUndoAvailability() }
        .onAppear {
            profiles = OutlookProfile.discover()
            targetAccountID = model.keyboardAccountID ?? model.accounts.first?.id
            if let first = profiles.first { load(profile: first) }
        }
    }

    private var sourceSection: some View {
        HStack {
            Text("Source").frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
            if profiles.isEmpty {
                Text("No Outlook for Mac profile found on this Mac").foregroundStyle(.secondary)
            } else {
                Menu(sourceTitle.isEmpty ? "Choose…" : sourceTitle) {
                    ForEach(profiles, id: \.self) { url in
                        Button(url.deletingLastPathComponent().lastPathComponent) { load(profile: url) }
                    }
                }
                .fixedSize()
            }
            Button("Open .olm Archive…") { chooseOLM() }
            if loadingSource { ProgressView().controlSize(.small) }
            Spacer()
        }
    }

    @ViewBuilder private var accountSection: some View {
        if let profile, profile.accounts.count > 1 {
            HStack {
                Text("Accounts").frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
                Menu(outlookAccountsTitle) {
                    Button { outlookAccountIDs = []; applyOutlookAccounts() } label: {
                        Label("All accounts in this profile", systemImage: outlookAccountIDs.isEmpty ? "checkmark" : "")
                    }
                    Divider()
                    ForEach(profile.accounts) { a in
                        Button {
                            if outlookAccountIDs.contains(a.id) { outlookAccountIDs.remove(a.id) } else { outlookAccountIDs.insert(a.id) }
                            if outlookAccountIDs.count == profile.accounts.count { outlookAccountIDs = [] }
                            applyOutlookAccounts()
                        } label: {
                            Label("\(a.label) · \(a.messageCount) messages", systemImage: outlookAccountIDs.contains(a.id) ? "checkmark" : "")
                        }
                    }
                }
                .fixedSize()
                .disabled(running)
                Text("Tick one or more accounts, or leave all selected.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var outlookAccountsTitle: String {
        guard let profile, !outlookAccountIDs.isEmpty else { return "All accounts" }
        return profile.accounts.filter { outlookAccountIDs.contains($0.id) }.map(\.label).joined(separator: ", ")
    }

    private func applyOutlookAccounts() {
        guard let profile else { return }
        let selected = profile.selecting(outlookAccountIDs)
        source = selected
        sourceTitle = selected.title
        rebuildMapping()
        refreshUndoAvailability()
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Target").frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
                Picker("", selection: $targetAccountID) {
                    ForEach(model.accounts) { a in Text(a.email).tag(Optional(a.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                .onChange(of: targetAccountID) { _, _ in rebuildMapping() }
                Spacer()
            }
            HStack(spacing: 18) {
                Text("").frame(width: 60)
                Toggle("Include Deleted Items and Junk", isOn: $includeTrashJunk)
                    .onChange(of: includeTrashJunk) { _, _ in rebuildMapping() }
                Toggle("Label uploaded mail “Migrated”", isOn: $labelMigrated)
                if targetIsGoogle {
                    Toggle("Upload through the Gmail API", isOn: $useGmailAPI).disabled(running)
                }
                Stepper("\(connections) upload connections", value: $connections, in: 1...8)
                    .disabled(running)
                if targetIsGoogle && useGmailAPI {
                    Stepper("\(importsPerMinute) imports per minute", value: $importsPerMinute, in: 60...2400, step: 20)
                        .disabled(running)
                }
                Spacer()
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top) {
                Text("").frame(width: 60)
                Text(targetIsGoogle && useGmailAPI
                     ? "Messages go in through Gmail's import API, which has no daily upload cap, keeps original dates, and applies labels on the way in. Only one IMAP connection is used, for duplicate checks. Each import costs 25 quota units, so set imports per minute to your project's “Units per minute per user” quota ÷ 25 with some headroom: 220 for the default 6,000, 560 for 15,000."
                     : "Gmail caps IMAP uploads at 500 MB per day and allows 15 IMAP connections per mailbox, shared with this app's own sync and any other mail client on the account. Connections from a stopped run keep counting for a few minutes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var mappingTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Outlook folder").font(.caption).foregroundStyle(.secondary).frame(width: 300, alignment: .leading)
                Text("Messages").font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                Text("Google Workspace folder").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            List(source?.folders ?? []) { folder in
                HStack {
                    Label(folder.path, systemImage: icon(for: folder.kind)).frame(width: 300, alignment: .leading).lineLimit(1)
                    Text("\(folder.messageCount)").frame(width: 70, alignment: .trailing).foregroundStyle(.secondary)
                    targetPicker(folder)
                }
            }
            .frame(minHeight: 120)
            .frame(maxHeight: .infinity)
        }
    }

    private func targetPicker(_ folder: SourceFolder) -> some View {
        Picker("", selection: Binding(get: { mapping[folder.id] ?? .skip }, set: { mapping[folder.id] = $0 })) {
            Text("Skip").tag(MigrationTarget.skip)
            Divider()
            ForEach(targetFolders.filter { $0.isSelectable }) { f in
                Text(f.path).tag(MigrationTarget.existing(f.path))
            }
            let suggested = createPath(for: folder)
            if !targetFolders.contains(where: { $0.path == suggested }) {
                Divider()
                Text("Create “\(suggested)”").tag(MigrationTarget.create(suggested))
            }
        }
        .labelsHidden()
        .disabled(running)
    }

    @ViewBuilder private var progressSection: some View {
        if running || !status.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(status).font(.caption)
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                    Text(verifying
                         ? "\(done) of \(total) checked · \(existing) on server · \(failed) missing"
                         : "\(done) of \(total) · \(appended) \(dryRun ? "would be uploaded" : "uploaded") · \(existing) already present · \(failed) failed")
                        .font(.caption).foregroundStyle(.secondary)
                    if !dryRun, uploadedBytes > 0 {
                        Text("\(MigrationView.size(uploadedBytes)) uploaded · \(rateText)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !log.isEmpty {
                    ScrollView { Text(log.suffix(40).joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 90)
                }
            }
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button(running ? "Stop" : "Close") { running ? task?.cancel() : dismiss() }
            if undoAvailable > 0 {
                Button("Undo Last Migration (\(undoAvailable))") { confirmUndo = true }.disabled(running)
            }
            Button("Verify") { verify() }.disabled(!canStart)
            Button("Dry Run") { start(dryRun: true) }.keyboardShortcut(.defaultAction).disabled(!canStart)
            Button("Start Migration…") { confirmStart = true }.disabled(!canStart)
        }
    }

    private var targetEmail: String { model.accounts.first { $0.id == targetAccountID }?.email ?? "" }

    private var targetIsGoogle: Bool { model.accounts.first { $0.id == targetAccountID }?.provider == "google" }

    private func gmailImporter(for account: AccountInfo) async throws -> GmailImporter? {
        guard !dryRun, useGmailAPI, account.provider == "google" else { return nil }
        let importer = GmailImporter(tokens: model.tokens, accountID: account.id, importsPerMinute: importsPerMinute)
        if try await importer.hasRequiredScopes() { return importer }
        status = "Sign in to \(account.email) again to allow FalconMail to add mail to the mailbox…"
        try await model.addGoogleAccount(loginHint: account.email)
        guard try await importer.hasRequiredScopes() else {
            throw FalconError.invalidInput("Gmail import access was not granted. Sign in again and allow “Add emails into your Gmail mailbox”, or turn off “Upload through the Gmail API”.")
        }
        return importer
    }

    private var plannedCount: Int {
        (source?.folders ?? []).filter { mapping[$0.id]?.path != nil }.reduce(0) { $0 + $1.messageCount }
    }

    private func refreshUndoAvailability() {
        guard let source, let account = model.accounts.first(where: { $0.id == targetAccountID }) else { undoAvailable = 0; return }
        let url = MigrationRunner.stateURL(source: source, account: account, layout: model.layout)
        undoAvailable = MigrationState.load(url).appended.count
    }

    private var canStart: Bool {
        !running && source != nil && targetAccountID != nil && mapping.values.contains { $0 != .skip }
    }

    private func icon(for kind: SourceFolderKind) -> String {
        switch kind {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .trash: return "trash"
        case .junk: return "xmark.bin"
        case .archive: return "archivebox"
        case .outbox: return "tray.and.arrow.up"
        case .other: return "folder"
        case .system: return "gearshape"
        }
    }

    private func load(profile url: URL) {
        loadingSource = true
        status = ""
        Task.detached {
            let loaded = try? OutlookProfile(dataURL: url)
            await MainActor.run {
                loadingSource = false
                if let loaded {
                    profile = loaded
                    outlookAccountIDs = []
                    source = loaded
                    sourceTitle = loaded.title
                    rebuildMapping()
                    refreshUndoAvailability()
                } else {
                    status = "Could not read the Outlook profile at \(url.path)"
                }
            }
        }
    }

    private func chooseOLM() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "olm") ?? .archive]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadingSource = true
        Task.detached {
            let loaded = try? OLMArchive(url: url)
            await MainActor.run {
                loadingSource = false
                if let loaded {
                    profile = nil
                    outlookAccountIDs = []
                    source = loaded
                    sourceTitle = loaded.title
                    rebuildMapping()
                } else {
                    status = "Could not open \(url.lastPathComponent) as an Outlook archive"
                }
            }
        }
    }

    private func createPath(for folder: SourceFolder) -> String {
        let delimiter = targetFolders.first { !$0.delimiter.isEmpty }?.delimiter ?? "/"
        return folder.path.replacingOccurrences(of: "/", with: delimiter)
    }

    private func rebuildMapping() {
        guard let source else { return }
        var m: [String: MigrationTarget] = [:]
        for folder in source.folders { m[folder.id] = defaultTarget(for: folder) }
        mapping = m
    }

    private func defaultTarget(for folder: SourceFolder) -> MigrationTarget {
        func role(_ r: FolderRole) -> MigrationTarget? { targetFolders.first { $0.role == r }.map { .existing($0.path) } }
        switch folder.kind {
        case .inbox: return role(.inbox) ?? .create("INBOX")
        case .sent: return role(.sent) ?? .create(createPath(for: folder))
        case .drafts: return role(.drafts) ?? .create(createPath(for: folder))
        case .trash: return includeTrashJunk ? (role(.trash) ?? .skip) : .skip
        case .junk: return includeTrashJunk ? (role(.junk) ?? .skip) : .skip
        case .archive: return role(.all) ?? role(.archive) ?? .create("Archive")
        case .outbox, .system: return .skip
        case .other:
            if let match = targetFolders.first(where: { $0.path.caseInsensitiveCompare(createPath(for: folder)) == .orderedSame || $0.name.caseInsensitiveCompare(folder.name) == .orderedSame }) {
                return .existing(match.path)
            }
            return .create(createPath(for: folder))
        }
    }

    private func undo() {
        guard let source, let accountID = targetAccountID, let account = model.accounts.first(where: { $0.id == accountID }) else { return }
        running = true
        model.migrationInProgress = true
        status = "Connecting to \(account.email)"
        done = 0; total = 0
        task = Task {
            do {
                guard let syncer = await model.coordinator.syncer(for: accountID) else { throw FalconError.storage("The target account is not running") }
                let client = try await syncer.openArchiveSourceClient()
                let runner = MigrationRunner(source: source, account: account, client: client, reconnect: { try await syncer.openArchiveSourceClient() },
                                             existingFolders: targetFolders, mapping: [:], layout: model.layout)
                _ = try await runner.undo { p in
                    Task { @MainActor in
                        switch p {
                        case .status(let s), .folder(let s): status = s
                        case .count(let d, let t, _, _, _, _): done = d; total = t
                        case .log(let line): log.append(line)
                        }
                    }
                }
                await client.logout()
                model.syncNow()
                refreshUndoAvailability()
            } catch {
                status = "Undo failed: \(error.localizedDescription)"
            }
            running = false
            model.migrationInProgress = false
        }
    }

    private func verify() {
        guard let source, let accountID = targetAccountID, let account = model.accounts.first(where: { $0.id == accountID }) else { return }
        verifying = true
        dryRun = true
        running = true
        model.migrationInProgress = true
        status = "Connecting to \(account.email)"
        log = []
        done = 0; total = 0; appended = 0; existing = 0; failed = 0
        task = Task {
            do {
                guard let syncer = await model.coordinator.syncer(for: accountID) else { throw FalconError.storage("The target account is not running") }
                let client = try await syncer.openArchiveSourceClient()
                let runner = MigrationRunner(source: source, account: account, client: client, reconnect: { try await syncer.openArchiveSourceClient() },
                                             existingFolders: targetFolders, mapping: mapping, layout: model.layout)
                do {
                    let report = try await runner.verify { p in
                        Task { @MainActor in
                            switch p {
                            case .status(let s): status = s
                            case .folder(let f): status = f
                            case .count(let d, let t, _, let e, let x, _): done = d; total = t; existing = e; failed = x
                            case .log(let line): log.append(line)
                            }
                        }
                    }
                    await runner.persist()
                    await client.logout()
                    status = report.missing == 0
                        ? "Verified: all \(report.present) messages from the archive are on \(account.email)"
                        : "Verified: \(report.present) present, \(report.missing) missing. Press Start Migration… to upload the missing ones."
                    if report.unreadable > 0 { log.append("\(report.unreadable) messages could not be read from the archive") }
                } catch is CancellationError {
                    await runner.persist()
                    await client.logout()
                    status = "Stopped."
                }
            } catch {
                status = "Failed: \(error.localizedDescription)"
            }
            running = false
            model.migrationInProgress = false
        }
    }

    private func start(dryRun: Bool) {
        guard let source, let accountID = targetAccountID, let account = model.accounts.first(where: { $0.id == accountID }) else { return }
        self.dryRun = dryRun
        verifying = false
        running = true
        uploadedBytes = 0
        rateSamples = []
        model.migrationInProgress = true
        status = "Connecting to \(account.email)"
        log = []
        done = 0; total = 0; appended = 0; existing = 0; failed = 0
        let mapping = self.mapping
        let folders = targetFolders
        task = Task {
            do {
                guard let syncer = await model.coordinator.syncer(for: accountID) else { throw FalconError.storage("The target account is not running") }
                let importer = try await gmailImporter(for: account)
                status = "Connecting to \(account.email)"
                let client = try await syncer.openArchiveSourceClient()
                let runner = MigrationRunner(source: source, account: account, client: client, reconnect: { try await syncer.openArchiveSourceClient() },
                                             existingFolders: folders, mapping: mapping, layout: model.layout)
                var options = MigrationOptions()
                options.labelMigrated = labelMigrated
                options.uploaders = connections
                options.importsPerMinute = importsPerMinute
                await runner.setOptions(options)
                await runner.setGmailImporter(importer)
                do {
                    let report = try await runner.run(dryRun: dryRun) { p in
                        Task { @MainActor in
                            switch p {
                            case .status(let s): status = s
                            case .folder(let f): status = f
                            case .count(let d, let t, let a, let e, let x, let b): done = d; total = t; appended = a; existing = e; failed = x; noteBytes(b)
                            case .log(let line): log.append(line)
                            }
                        }
                    }
                    await runner.persist()
                    await client.logout()
                    status = dryRun
                        ? "Dry run: \(report.appended) messages would be uploaded, \(report.existing) already present"
                        : "Done: \(report.appended) uploaded (\(ByteCountFormatter.string(fromByteCount: Int64(report.bytesUploaded), countStyle: .file))), \(report.existing) already present, \(report.failed) failed" + (report.createdFolders.isEmpty ? "" : ", created \(report.createdFolders.count) folders")
                    if !dryRun { model.syncNow() }
                    refreshUndoAvailability()
                } catch is CancellationError {
                    await runner.persist()
                    await client.logout()
                    status = "Stopped. Run again to continue where it left off."
                }
            } catch is CancellationError {
                status = "Stopped."
            } catch {
                status = "Failed: \(error.localizedDescription)"
            }
            running = false
            model.migrationInProgress = false
        }
    }

    private var rateText: String {
        guard let first = rateSamples.first, let last = rateSamples.last, last.0.timeIntervalSince(first.0) >= 1 else { return "measuring…" }
        let bytesPerSecond = Double(last.1 - first.1) / last.0.timeIntervalSince(first.0)
        let megabits = bytesPerSecond * 8 / 1_000_000
        return String(format: "%.1f Mbps (%@/s)", megabits, MigrationView.size(Int(bytesPerSecond)))
    }

    private func noteBytes(_ bytes: Int) {
        uploadedBytes = bytes
        let now = Date()
        rateSamples.append((now, bytes))
        rateSamples.removeAll { now.timeIntervalSince($0.0) > 30 }
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
