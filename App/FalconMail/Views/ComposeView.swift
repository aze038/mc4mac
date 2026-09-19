import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FalconCore

struct ComposeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let draftID: UUID
    @State private var draft: ComposeDraft?
    @State private var showCcBcc = false
    @State private var showSchedule = false
    @State private var scheduleDate = Date().addingTimeInterval(3600)
    @State private var error: String?
    @State private var dropTargeted = false
    @State private var editSessions: [UUID: AttachmentEditSession] = [:]

    var body: some View {
        Group {
            if draft != nil { form } else { ProgressView() }
        }
        .frame(minWidth: 600, minHeight: 480)
        .onAppear { draft = model.drafts[draftID] }
        .onDisappear { editSessions.values.forEach { $0.stop() } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                for url in await AttachmentTempFiles.fileURLs(from: providers) {
                    if let a = AttachmentTempFiles.attachment(from: url) { draft?.attachments.append(a) }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.06)).padding(4)
                    .overlay(Text("Drop to attach").font(.title3).foregroundStyle(Color.accentColor))
                    .allowsHitTesting(false)
            }
        }
        .alert("Cannot send", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var form: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack {
                    Picker("From", selection: binding(\.accountID)) {
                        ForEach(model.accounts) { a in Text(a.email).tag(a.id) }
                    }
                    Spacer()
                    Button(showCcBcc ? "Hide Cc/Bcc" : "Cc/Bcc") { showCcBcc.toggle() }.buttonStyle(.link)
                }
                RecipientField(label: "To", text: binding(\.to))
                if showCcBcc || !(draft?.cc.isEmpty ?? true) || !(draft?.bcc.isEmpty ?? true) {
                    RecipientField(label: "Cc", text: binding(\.cc))
                    RecipientField(label: "Bcc", text: binding(\.bcc))
                }
                HStack {
                    Text("Subject").frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
                    TextField("", text: binding(\.subject)).textFieldStyle(.plain)
                }
                if let attachments = draft?.attachments, !attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(attachments) { a in
                                HStack(spacing: 4) {
                                    Image(systemName: editSessions[a.id] != nil ? "pencil.circle.fill" : "paperclip")
                                        .foregroundStyle(editSessions[a.id] != nil ? Color.accentColor : Color.primary)
                                    Text(a.filename).font(.caption)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(a.data.count), countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                                    Menu {
                                        Button(editSessions[a.id] == nil ? "Edit in Default App" : "Reopen in Default App") { edit(a) }
                                        if editSessions[a.id] != nil { Button("Stop Watching for Changes") { editSessions[a.id]?.stop(); editSessions[a.id] = nil } }
                                        Button("Save As…") {
                                            let panel = NSSavePanel()
                                            panel.nameFieldStringValue = a.filename
                                            if panel.runModal() == .OK, let url = panel.url { try? a.data.write(to: url) }
                                        }
                                        Divider()
                                        Button("Remove", role: .destructive) { editSessions[a.id]?.stop(); editSessions[a.id] = nil; draft?.attachments.removeAll { $0.id == a.id } }
                                    } label: { Image(systemName: "chevron.down.circle") }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
                                }
                                .padding(4).background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                                .help(editSessions[a.id] != nil ? "Open in \(a.filename.split(separator: ".").last.map { String($0).uppercased() } ?? "the editor"). Saves are picked up automatically." : a.filename)
                            }
                        }
                    }
                }
            }
            .padding(12)
            Divider()
            TextEditor(text: binding(\.body))
                .font(.system(size: 14))
                .padding(8)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(role: .destructive) { discard() } label: { Label("Discard", systemImage: "trash") }
                Button { attach() } label: { Label("Attach", systemImage: "paperclip") }
                Button { showSchedule = true } label: { Label("Schedule", systemImage: "clock") }
                    .popover(isPresented: $showSchedule) {
                        VStack(alignment: .leading, spacing: 12) {
                            DatePicker("Send at", selection: $scheduleDate, in: Date()...)
                            HStack {
                                Button("Cancel") { showSchedule = false }
                                Spacer()
                                Button("Schedule Send") {
                                    draft?.scheduledAt = scheduleDate
                                    showSchedule = false
                                    send()
                                }.keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(16).frame(width: 320)
                    }
                Button { send() } label: { Label("Send", systemImage: "paperplane.fill") }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .navigationTitle(draft?.subject.isEmpty == false ? draft!.subject : "New Message")
    }

    private func binding<T>(_ path: WritableKeyPath<ComposeDraft, T>) -> Binding<T> {
        Binding(get: { draft![keyPath: path] }, set: { draft?[keyPath: path] = $0; if let d = draft { model.drafts[d.id] = d } })
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            draft?.attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: type, data: data))
        }
    }

    private func edit(_ a: OutgoingAttachment) {
        editSessions[a.id]?.stop()
        editSessions[a.id] = AttachmentEditSession(attachment: a) { data in
            guard let i = draft?.attachments.firstIndex(where: { $0.id == a.id }) else { return }
            draft?.attachments[i].data = data
        }
    }

    private func discard() {
        editSessions.values.forEach { $0.stop() }
        model.drafts[draftID] = nil
        dismiss()
    }

    private func send() {
        guard let d = draft else { return }
        editSessions.values.forEach { $0.stop() }
        do {
            try model.send(d)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RecipientField: View {
    @EnvironmentObject var model: AppModel
    let label: String
    @Binding var text: String
    @State private var suggestions: [ContactInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .onChange(of: text) { _, new in
                        let last = new.split(separator: ",").last.map { String($0).trimmed } ?? ""
                        suggestions = last.count >= 2 ? model.contactList.suggest(last) : []
                    }
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions.prefix(6)) { c in
                        Button {
                            var parts = text.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
                            if !parts.isEmpty { parts.removeLast() }
                            parts.append(EmailAddress(name: c.name, address: c.email).rfc5322)
                            text = parts.joined(separator: ", ") + ", "
                            suggestions = []
                        } label: {
                            HStack {
                                Text(c.name.isEmpty ? c.email : c.name)
                                if !c.name.isEmpty { Text(c.email).foregroundStyle(.secondary) }
                                Spacer()
                            }
                            .padding(.vertical, 3).padding(.horizontal, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .padding(.leading, 66)
            }
        }
    }
}

extension Array where Element == ContactInfo {
    func suggest(_ prefix: String) -> [ContactInfo] {
        let q = prefix.lowercased()
        var seen = Set<String>()
        return filter { $0.email.lowercased().contains(q) || $0.name.lowercased().contains(q) }
            .sorted { ($0.useCount, $0.lastUsed ?? .distantPast) > ($1.useCount, $1.lastUsed ?? .distantPast) }
            .filter { seen.insert($0.email.lowercased()).inserted }
    }
}
