import SwiftUI
import AppKit
import FalconCore

struct ArchiveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var localExport = false

    @State private var accountID: UUID?
    @State private var selectedPaths = Set<String>()
    @State private var useCutoff = true
    @State private var cutoff = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var name = "Archive \(Calendar.current.component(.year, from: Date()))"
    @State private var encrypt = false
    @State private var password = ""
    @State private var passwordConfirm = ""
    @State private var removeFromServer = false
    @State private var localFolder: URL?
    @State private var running = false
    @State private var status = ""
    @State private var done = 0
    @State private var total = 0
    @State private var bytes = 0
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localExport ? "Export folders to a local archive" : "Archive mail to Google Drive").font(.title2.bold())
            Text(localExport
                 ? "Creates a .fmarchive folder of zipped .eml files that opens on Windows and macOS without FalconMail."
                 : "Messages are streamed straight to Google Drive. Nothing is stored on this Mac.")
                .foregroundStyle(.secondary)
            Form {
                sourceSection
                optionsSection
                if localExport { destinationRow }
            }
            .formStyle(.grouped)
            if running || !status.isEmpty { progressView }
            HStack {
                Spacer()
                Button(running ? "Stop" : "Cancel") {
                    if running { task?.cancel() } else { dismiss() }
                }
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            accountID = model.accounts.first?.id
            if case .folder(let id) = model.selection, let f = model.folder(id) { selectedPaths = [f.path]; accountID = f.accountID }
        }
    }

    private var sourceSection: some View {
        Section {
            Picker("Account", selection: $accountID) {
                ForEach(model.accounts) { a in Text(a.email).tag(Optional(a.id)) }
            }
            TextField("Archive name", text: $name)
            if let id = accountID {
                FolderChecklist(folders: (model.folders[id] ?? []).filter { $0.isSelectable }, selected: $selectedPaths)
            }
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("Only messages older than", isOn: $useCutoff)
            if useCutoff { DatePicker("Cutoff date", selection: $cutoff, displayedComponents: .date) }
            Toggle("Encrypt archive with a password", isOn: $encrypt)
            if encrypt {
                SecureField("Password", text: $password)
                SecureField("Confirm password", text: $passwordConfirm)
                Text("The password is never stored. If you lose it the archive cannot be opened.").font(.caption).foregroundStyle(.orange)
            }
            Toggle("Remove archived messages from the mail server", isOn: $removeFromServer)
        }
    }

    private var destinationRow: some View {
        HStack {
            Text(localFolder?.path ?? "Choose a destination folder")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(localFolder == nil ? Color.secondary : Color.primary)
            Spacer()
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                if panel.runModal() == .OK { localFolder = panel.url }
            }
        }
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(status).font(.caption)
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                Text("\(done) of \(total) messages, \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var canStart: Bool {
        guard !running, accountID != nil, !selectedPaths.isEmpty, !name.trimmed.isEmpty else { return false }
        if encrypt && (password.isEmpty || password != passwordConfirm) { return false }
        if localExport && localFolder == nil { return false }
        return true
    }

    private func start() {
        guard let id = accountID, let account = model.accounts.first(where: { $0.id == id }) else { return }
        running = true
        status = "Connecting"
        let request = ArchiveRequest(accountID: id, folderPaths: selectedPaths.sorted(), olderThan: useCutoff ? cutoff : nil,
                                     name: name.trimmed, password: encrypt ? password : nil, removeFromServer: removeFromServer, parentID: nil)
        task = Task {
            do {
                let storage: ArchiveStorage
                var parent: String?
                if localExport, let folder = localFolder {
                    storage = LocalFolderStorage(root: folder)
                } else {
                    let drive = GoogleDriveStorage(tokens: model.tokens, accountID: id)
                    parent = try await drive.findOrCreateFolder(name: "FalconMail Archives", parentID: nil)
                    storage = drive
                }
                var req = request
                req.parentID = parent
                guard let syncer = await model.coordinator.syncer(for: id) else { throw FalconError.storage("account is not running") }
                let outcome = try await ArchiveJob.run(request: req, account: account, source: syncer.archiveSource(),
                                                       storage: storage) { progress in
                    Task { @MainActor in
                        switch progress {
                        case .status(let s): status = s
                        case .count(let d, let t, let b): done = d; total = t; bytes = b
                        case .finished: status = "Archive complete"
                        case .failed(let s): status = s
                        }
                    }
                }
                let record = ArchiveRecord(name: outcome.manifest.name, accountID: id, storageKind: storage.kind, rootID: outcome.rootID,
                                           manifest: outcome.manifest)
                try await model.archives.add(record)
                await model.reloadArchives()
                if removeFromServer { model.syncNow() }
                if !outcome.keptOnServer.isEmpty {
                    model.statusText = "Archived. Mail in \(outcome.keptOnServer.joined(separator: ", ")) was also kept on the server, "
                        + "because another message there is marked for deletion or the folder changed during the archive."
                }
                running = false
                dismiss()
            } catch is CancellationError {
                status = "Stopped"
                running = false
            } catch {
                let failure = MailServiceError.classify(error, account: account)
                Log.failure("Archive", failure, "\(account.email): archive failed: \(failure.kind.rawValue): \(failure.detail)",
                            level: .error, account: account, logAs: "archive", keeping: account.email)
                status = "Failed: \(failure.sentence)"
                running = false
            }
        }
    }
}

struct FolderChecklist: View {
    let folders: [FolderInfo]
    @Binding var selected: Set<String>

    var body: some View {
        VStack(alignment: .leading) {
            Text("Folders")
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(folders) { f in
                        Toggle(f.path, isOn: binding(for: f.path))
                    }
                }
            }
            .frame(height: 140)
            .padding(6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(get: { selected.contains(path) }, set: { on in if on { selected.insert(path) } else { selected.remove(path) } })
    }
}

struct OpenArchiveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var accountID: UUID?
    @State private var found: [RemoteFile] = []
    @State private var loading = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open an archive").font(.title2.bold())
            Picker("Google Drive account", selection: $accountID) {
                ForEach(model.accounts) { a in Text(a.email).tag(Optional(a.id)) }
            }
            HStack {
                Button("Search Google Drive") { search() }.disabled(accountID == nil || loading)
                Button("Open Local .fmarchive Folder…") { openLocal() }
                if loading { ProgressView().controlSize(.small) }
            }
            List(found) { f in
                HStack {
                    Label(f.name, systemImage: "archivebox")
                    Spacer()
                    Button("Add") { add(f) }
                }
            }
            .frame(height: 220)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 520)
        .onAppear { accountID = model.accounts.first?.id }
    }

    private func search() {
        guard let id = accountID else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                found = try await GoogleDriveStorage(tokens: model.tokens, accountID: id).listArchives()
                status = found.isEmpty ? "No archives found. Only archives created by FalconMail are visible." : ""
            } catch {
                Log.warning("Archive", "Listing archives on Google Drive failed: \(error.localizedDescription)", error: error)
                status = error.localizedDescription
            }
        }
    }

    private func add(_ f: RemoteFile) {
        guard let id = accountID else { return }
        Task {
            do {
                let storage = GoogleDriveStorage(tokens: model.tokens, accountID: id)
                let manifest = try await ArchiveReader(storage: storage, rootID: f.id).open()
                try await model.archives.add(ArchiveRecord(name: manifest.name, accountID: id, storageKind: storage.kind, rootID: f.id, manifest: manifest))
                await model.reloadArchives()
                status = manifest.isEncrypted ? "Added \(manifest.name). Enter its password when you open it." : "Added \(manifest.name)"
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func openLocal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let storage = LocalFolderStorage(root: url.deletingLastPathComponent())
                let reader = ArchiveReader(storage: storage, rootID: url.path)
                let manifest = try await reader.open()
                try await model.archives.add(ArchiveRecord(name: manifest.name, accountID: nil, storageKind: "local", rootID: url.path, manifest: manifest))
                await model.reloadArchives()
                status = "Added \(manifest.name)"
            } catch { status = error.localizedDescription }
        }
    }
}

struct ArchiveBrowserView: View {
    @Environment(AppModel.self) private var model
    let record: ArchiveRecord
    @State private var reader: ArchiveReader?
    @State private var entries: [ArchiveEntry] = []
    @State private var query = ""
    @State private var selected: ArchiveEntry?
    @State private var parsed: MIMEMessage?
    @State private var status = "Loading index…"
    @State private var password = ""
    @State private var needsPassword = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search archive", text: $query).textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await runSearch() } }
                    Button("Remove from list") {
                        Task { try? await model.archives.remove(record.id); await model.reloadArchives(); model.select(.unified) }
                    }
                }
                .padding(8)
                Divider()
                if needsPassword {
                    VStack(spacing: 8) {
                        Text("This archive is encrypted.")
                        SecureField("Password", text: $password).frame(width: 240).onSubmit { Task { await load() } }
                        Button("Open") { Task { await load() } }
                    }
                    .padding()
                }
                List(entries, selection: $selected) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(e.fromName.isEmpty ? e.from : e.fromName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(e.date.formatted(date: .numeric, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(e.subject.isEmpty ? "(no subject)" : e.subject).font(.system(size: 13)).lineLimit(1)
                        HStack {
                            Text(e.folder).font(.caption).foregroundStyle(.secondary)
                            if e.hasAttachments { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .tag(e)
                }
                Divider()
                Text(status).font(.caption).foregroundStyle(.secondary).padding(6)
            }
            .frame(minWidth: 320)
            Group {
                if let parsed, let selected {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(parsed.subject).font(.title3.bold())
                            Text("From: \(parsed.from.rfc5322)").font(.caption)
                            Text("To: \(parsed.to.map { $0.rfc5322 }.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                            Text(selected.date.formatted()).font(.caption).foregroundStyle(.secondary)
                            if !parsed.attachments.isEmpty { AttachmentStrip(attachments: parsed.attachments, html: parsed.textHTML) }
                            HTMLView(html: MessageRenderer.html(for: parsed, allowRemote: model.loadRemoteImages, dark: true, forceOriginal: false), sender: parsed.from).frame(minHeight: 300)
                        }
                        .padding(20)
                    }
                } else {
                    ContentUnavailableView("Select an archived message", systemImage: "archivebox")
                }
            }
            .frame(minWidth: 400)
        }
        .task(id: record.id) { await load() }
        .onChange(of: selected) { _, new in
            parsed = nil
            guard let new, let reader else { return }
            Task {
                do {
                    let raw = try await reader.message(new)
                    parsed = MIMEParser.parse(raw)
                } catch { status = error.localizedDescription }
            }
        }
    }

    private func makeStorage() -> ArchiveStorage? {
        if record.storageKind == "local" {
            return LocalFolderStorage(root: URL(fileURLWithPath: record.rootID).deletingLastPathComponent())
        }
        guard let id = record.accountID else { return nil }
        return GoogleDriveStorage(tokens: model.tokens, accountID: id)
    }

    private func load() async {
        guard let storage = makeStorage() else { status = "Account for this archive is missing"; return }
        let r = ArchiveReader(storage: storage, rootID: record.rootID, password: password.isEmpty ? nil : password)
        do {
            status = "Loading index…"
            try await r.loadIndex()
            reader = r
            needsPassword = false
            entries = await r.entries
            status = "\(entries.count) messages"
        } catch {
            if error.localizedDescription.contains("encrypted") || error.localizedDescription.contains("password") {
                needsPassword = true
                status = error.localizedDescription
            } else {
                Log.warning("Archive", "Opening an archive failed: \(error.localizedDescription)", error: error)
                status = error.localizedDescription
            }
        }
    }

    private func runSearch() async {
        guard let reader else { return }
        entries = await reader.search(query)
        status = "\(entries.count) messages"
    }
}
