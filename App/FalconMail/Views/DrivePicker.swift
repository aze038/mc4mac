import SwiftUI
import UniformTypeIdentifiers
import FalconCore

struct DriveEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let isFolder: Bool
    let size: Int?
}

@MainActor
@Observable
final class DriveBrowser {
    var entries: [DriveEntry] = []
    var path: [(id: String, name: String)] = [(id: "root", name: "My Drive")]
    var loading = false
    var failure: String?

    private let storage: GoogleDriveStorage

    init(tokens: TokenStore, accountID: UUID) {
        storage = GoogleDriveStorage(tokens: tokens, accountID: accountID)
    }

    var currentID: String { path.last?.id ?? "root" }

    func load() async {
        loading = true
        failure = nil
        defer { loading = false }
        do {
            let files = try await storage.list(parentID: currentID)
            entries = files
                .map { DriveEntry(id: $0.id, name: $0.name, isFolder: $0.isFolder, size: $0.size) }
                .sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
        } catch {
            failure = error.localizedDescription
        }
    }

    func open(_ entry: DriveEntry) async {
        guard entry.isFolder else { return }
        path.append((id: entry.id, name: entry.name))
        await load()
    }

    func jump(to index: Int) async {
        guard index < path.count else { return }
        path = Array(path.prefix(index + 1))
        await load()
    }

    func download(_ entry: DriveEntry) async throws -> Data {
        try await storage.read(fileID: entry.id, range: nil)
    }

    func upload(name: String, data: Data, mimeType: String) async throws {
        _ = try await storage.upload(name: name, parentID: currentID, data: data, mimeType: mimeType)
    }
}

struct DrivePicker: View {
    enum Mode { case attach, save }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let accountID: UUID
    let mode: Mode
    var savingName: String = ""
    var savingData: Data?
    var savingMime: String = "application/octet-stream"
    var onPick: (String, Data) -> Void = { _, _ in }

    @State private var browser: DriveBrowser?
    @State private var selection: DriveEntry?
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .attach ? "Attach from Google Drive" : "Save to Google Drive")
                .font(.title3.bold())

            if let browser {
                breadcrumbs(browser)
                list(browser)
                if let message = browser.failure {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if mode == .attach {
                Text("FalconMail can open the files it created in Drive, such as saved attachments and archives. Google keeps the rest of your Drive private to apps that ask for full access.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(mode == .attach ? "Attach" : "Save Here") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (mode == .attach && (selection == nil || selection?.isFolder == true)))
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .task {
            let made = DriveBrowser(tokens: model.tokens, accountID: accountID)
            browser = made
            await made.load()
        }
    }

    private func breadcrumbs(_ browser: DriveBrowser) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(browser.path.enumerated()), id: \.offset) { index, item in
                if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                Button(item.name) { Task { await browser.jump(to: index) } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: index == browser.path.count - 1 ? .semibold : .regular))
            }
            Spacer()
            if browser.loading { ProgressView().controlSize(.small) }
        }
    }

    private func list(_ browser: DriveBrowser) -> some View {
        List(browser.entries, selection: $selection) { entry in
            HStack(spacing: 8) {
                Image(systemName: entry.isFolder ? "folder" : "doc")
                    .foregroundStyle(entry.isFolder ? Color.accentColor : Color.secondary)
                Text(entry.name).lineLimit(1)
                Spacer()
                if let size = entry.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .tag(entry)
            .onTapGesture(count: 2) { Task { await browser.open(entry) } }
        }
        .listStyle(.bordered)
        .overlay {
            if !browser.loading && browser.entries.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "folder")
            }
        }
    }

    private func commit() {
        guard let browser else { return }
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                switch mode {
                case .attach:
                    guard let entry = selection, !entry.isFolder else { return }
                    let data = try await browser.download(entry)
                    onPick(entry.name, data)
                case .save:
                    guard let data = savingData else { return }
                    try await browser.upload(name: savingName, data: data, mimeType: savingMime)
                }
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
