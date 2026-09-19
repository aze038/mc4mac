import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FalconCore

struct MigrationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [URL] = []
    @State private var source: (any MigrationSource)?
    @State private var sourceTitle = ""
    @State private var loadingSource = false
    @State private var targetAccountID: UUID?
    @State private var mapping: [String: MigrationTarget] = [:]
    @State private var includeTrashJunk = false
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

    private var targetFolders: [FolderInfo] { targetAccountID.flatMap { model.folders[$0] } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Migrate mail to Google Workspace").font(.title2.bold())
            Text("Reads your Outlook for Mac mailbox or an .olm archive and uploads every message to the matching folder. Messages that already exist in the target are skipped, so it is safe to run again.")
                .foregroundStyle(.secondary)
            sourceSection
            targetSection
            if source != nil { mappingTable }
            progressSection
            buttons
        }
        .padding(24)
        .frame(width: 760, height: 640)
        .onAppear {
            profiles = OutlookProfile.discover()
            targetAccountID = model.accounts.first?.id
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

    private var targetSection: some View {
        HStack {
            Text("Target").frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
            Picker("", selection: $targetAccountID) {
                ForEach(model.accounts) { a in Text(a.email).tag(Optional(a.id)) }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            .onChange(of: targetAccountID) { _, _ in rebuildMapping() }
            Toggle("Include Deleted Items and Junk", isOn: $includeTrashJunk)
                .onChange(of: includeTrashJunk) { _, _ in rebuildMapping() }
            Spacer()
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
            .frame(minHeight: 200)
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
                    Text("\(done) of \(total) · \(appended) \(dryRun ? "would be uploaded" : "uploaded") · \(existing) already present · \(failed) failed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !log.isEmpty {
                    ScrollView { Text(log.suffix(40).joined(separator: "\n")).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 70)
                }
            }
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button(running ? "Stop" : "Close") { running ? task?.cancel() : dismiss() }
            Button("Dry Run") { start(dryRun: true) }.disabled(!canStart)
            Button("Start Migration") { start(dryRun: false) }.keyboardShortcut(.defaultAction).disabled(!canStart)
        }
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
                    source = loaded
                    sourceTitle = loaded.title
                    rebuildMapping()
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

    private func start(dryRun: Bool) {
        guard let source, let accountID = targetAccountID, let account = model.accounts.first(where: { $0.id == accountID }) else { return }
        self.dryRun = dryRun
        running = true
        status = "Connecting to \(account.email)"
        log = []
        done = 0; total = 0; appended = 0; existing = 0; failed = 0
        let mapping = self.mapping
        let folders = targetFolders
        task = Task {
            do {
                guard let syncer = await model.coordinator.syncer(for: accountID) else { throw FalconError.storage("The target account is not running") }
                let client = try await syncer.openArchiveSourceClient()
                let runner = MigrationRunner(source: source, account: account, client: client, existingFolders: folders, mapping: mapping, layout: model.layout)
                do {
                    let report = try await runner.run(dryRun: dryRun) { p in
                        Task { @MainActor in
                            switch p {
                            case .status(let s): status = s
                            case .folder(let f): status = f
                            case .count(let d, let t, let a, let e, let x): done = d; total = t; appended = a; existing = e; failed = x
                            case .log(let line): log.append(line)
                            }
                        }
                    }
                    await runner.persist()
                    await client.logout()
                    status = dryRun
                        ? "Dry run: \(report.appended) messages would be uploaded, \(report.existing) already present"
                        : "Done: \(report.appended) uploaded, \(report.existing) already present, \(report.failed) failed" + (report.createdFolders.isEmpty ? "" : ", created \(report.createdFolders.count) folders")
                    if !dryRun { model.syncNow() }
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
        }
    }
}
