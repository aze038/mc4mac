import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FalconCore

struct ComposeView: View {
    @State private var formatter = TextFormatter()
    @State private var tab = ComposeTab.message
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let draftID: UUID
    var embedded = false
    var onClose: (() -> Void)? = nil
    @State private var draft: ComposeDraft?
    @State private var showCc = Preferences.bool(Pref.showCcByDefault, default: false)
    @State private var showBcc = Preferences.bool(Pref.showBccByDefault, default: false)
    @State private var showSchedule = false
    @State private var scheduleDate = Date().addingTimeInterval(3600)
    @State private var error: String?
    @State private var dropTargeted = false
    @State private var editSessions: [UUID: AttachmentEditSession] = [:]
    @State private var showAttachmentWarning = false
    @State private var showDrivePicker = false
    @FocusState private var bodyFocused: Bool
    @AppStorage(AttachmentWarning.enabledKey) private var warnAboutAttachments = true
    @AppStorage(AttachmentWarning.keywordsKey) private var attachmentKeywords = AttachmentWarning.defaultKeywords

    var body: some View {
        Group {
            if draft != nil { form } else { ProgressView() }
        }
        .frame(minWidth: 600, minHeight: embedded ? 0 : 480)
        .background(embedded ? nil : PopupWindowAccessor())
        .onAppear { load() }
        .onDisappear {
            editSessions.values.forEach { $0.stop() }
            if !embedded { model.saveDraftToServer(draftID) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                for url in await AttachmentTempFiles.fileURLs(from: providers) {
                    if let a = AttachmentTempFiles.attachment(from: url) { draft?.attachments.append(a) }
                }
                commitDraft()
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
        .sheet(isPresented: $showDrivePicker) {
            if let account = draft?.accountID ?? model.accounts.first?.id {
                DrivePicker(accountID: account, mode: .attach) { name, data in
                    let type = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    draft?.attachments.append(OutgoingAttachment(filename: name, mimeType: type, data: data))
                    commitDraft()
                }
                .environment(model)
            }
        }
        .alert("Cannot send", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var form: some View {
        composer.alert("Did you forget an attachment?", isPresented: $showAttachmentWarning) {
            Button("Add Attachment") { attach() }.keyboardShortcut(.defaultAction)
            Button("Send Anyway") { sendPending() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This message mentions an attachment but none is attached.")
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if embedded { inlineActionBar } else { ribbon }
            Divider()
            headerFields
            Divider()
            if embedded {
                InlineFormatBar(formatter: formatter)
                Divider()
            }
            RichTextEditor(rtf: binding(\.bodyRTF), plain: binding(\.body)) { view in
                Task { @MainActor in
                    formatter.editor = view
                    view.isContinuousSpellCheckingEnabled = Preferences.bool(Pref.checkSpelling, default: true)
                    view.isGrammarCheckingEnabled = Preferences.bool(Pref.checkGrammar, default: true)
                    view.isAutomaticQuoteSubstitutionEnabled = Preferences.bool(Pref.smartQuotes, default: true)
                    view.isAutomaticDashSubstitutionEnabled = Preferences.bool(Pref.smartQuotes, default: true)
                    view.isAutomaticLinkDetectionEnabled = Preferences.bool(Pref.smartLinks, default: true)
                }
            }
        }
        .navigationTitle(draft?.subject.isEmpty == false ? draft!.subject : "New Message")
    }

    private var ribbon: some View {
        ComposeRibbon(tab: $tab,
                      formatter: formatter,
                      showsBcc: $showBcc,
                      canSend: !(draft?.to.isEmpty ?? true),
                      onSend: { send() },
                      onAttachFile: { attach() },
                      onAttachFromDrive: { attachFromDrive() },
                      onInsertSignature: { insertSignature() },
                      onEditSignatures: { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) },
                      onCycleBackground: { model.cycleAppearance() })
    }

    private var inlineActionBar: some View {
        HStack(spacing: 14) {
            InlineAction(title: "Send", symbol: "paperplane", prominent: true, enabled: !(draft?.to.isEmpty ?? true)) { send() }
            InlineAction(title: "Discard", symbol: "trash") { discard() }
            InlineAction(title: "Attach", symbol: "paperclip") { attach() }
            InlineAction(title: "Signature", symbol: "signature") { insertSignature() }
            Menu {
                Button("Schedule Send…") { showSchedule = true }
                Button("Attach from Google Drive…") { attachFromDrive() }
                Button("Insert Table") { formatter.insertTable() }
                Button("Insert Link…") { formatter.insertLink() }
                Divider()
                Toggle("Show Cc", isOn: $showCc)
                Toggle("Show Bcc", isOn: $showBcc)
                Divider()
                Button("Check Spelling") { formatter.checkSpelling() }
                Button("Edit Signatures…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .popover(isPresented: $showSchedule) { schedulePopover }
            Spacer()
            Button { popOut() } label: { Image(systemName: "macwindow.on.rectangle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Open in a separate window")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var headerFields: some View {
        VStack(spacing: 0) {
            ComposeFieldRow(label: "From:") {
                Picker("", selection: binding(\.accountID)) {
                    ForEach(model.accounts) { a in
                        Text(a.displayName.isEmpty ? a.email : "\(a.displayName) (\(a.email))").tag(a.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            } trailing: {
                HStack(spacing: 10) {
                    Button { model.cycleAppearance() } label: { Image(systemName: "sun.max") }
                        .buttonStyle(.plain).help("Switch background")
                    Button { withAnimation(.easeInOut(duration: 0.15)) { showCc.toggle(); showBcc = showCc ? showBcc : false } } label: {
                        Image(systemName: showCc ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain).help(showCc ? "Hide Cc and Bcc" : "Show Cc and Bcc")
                    Button { popOut() } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(.plain).help("Open in a separate window")
                }
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            }

            ComposeFieldRow(label: "To:") {
                RecipientField(label: "", text: binding(\.to))
            } trailing: {
                HStack(spacing: 8) {
                    if !showCc {
                        Button("Cc") { showCc = true }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
                    }
                    if !showBcc {
                        Button("Bcc") { showBcc = true; showCc = true }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
                    }
                    AddressBookButton { model.showModule(.people) }
                }
            }

            if showCc {
                ComposeFieldRow(label: "Cc:") {
                    RecipientField(label: "", text: binding(\.cc))
                } trailing: {
                    AddressBookButton { model.showModule(.people) }
                }
            }
            if showBcc {
                ComposeFieldRow(label: "Bcc:") {
                    RecipientField(label: "", text: binding(\.bcc))
                } trailing: {
                    AddressBookButton { model.showModule(.people) }
                }
            }

            ComposeFieldRow(label: "Subject:") {
                TextField("", text: binding(\.subject)).textFieldStyle(.plain)
            } trailing: {
                Menu {
                    Picker("Importance", selection: binding(\.importance)) {
                        Text("Low").tag("low")
                        Text("Normal").tag("normal")
                        Text("High").tag("high")
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("Importance").font(.system(size: 12))
                }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
            }

            scheduleBanner
            attachmentStrip
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var attachmentStrip: some View {
        if let attachments = draft?.attachments, !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(attachments) { a in
                        ComposeAttachmentChip(
                            attachment: a,
                            isEditing: editSessions[a.id] != nil,
                            onEdit: { edit(a) },
                            onStopWatching: { stopWatching(a.id) },
                            onRemove: { remove(a.id) })
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder private var scheduleBanner: some View {
        if let date = draft?.scheduledAt, date > Date() {
            HStack(spacing: 6) {
                Image(systemName: "clock").font(.caption)
                Text("Scheduled for \(date.formatted())").font(.caption)
                Spacer()
                Button("Clear Schedule") { clearSchedule() }
                    .buttonStyle(.link).font(.caption)
                    .help("Send as soon as you press Send")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var schedulePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("Send at", selection: $scheduleDate, in: Date()...)
            HStack {
                Button("Cancel") { showSchedule = false }
                Spacer()
                Button("Schedule Send") {
                    showSchedule = false
                    send(scheduling: scheduleDate)
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 320)
    }

    private func insertSignature() {
        guard let account = model.accounts.first(where: { $0.id == draft?.accountID }) ?? model.accounts.first else { return }
        let text = ComposeDraft.signatureBlock(account)
        guard !text.isEmpty, let editor = formatter.editor else { return }
        editor.insertText(text, replacementRange: editor.selectedRange())
        editor.didChangeText()
    }

    private func load() {
        let stored = model.drafts[draftID]
        draft = stored
        if let date = stored?.scheduledAt, date > Date() { scheduleDate = date }
        guard !(stored?.to.isEmpty ?? true) else { return }
        Task { @MainActor in bodyFocused = true }
    }

    private func clearSchedule() {
        draft?.scheduledAt = nil
        commitDraft()
    }

    private func commitDraft() {
        guard let d = draft else { return }
        model.drafts[d.id] = d
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func popOut() {
        editSessions.values.forEach { $0.stop() }
        model.tabs.removeAll { $0 == .compose(draftID) }
        if model.activeTab == .compose(draftID) { model.activeTab = nil }
        openWindow(value: draftID)
    }

    private func binding<T>(_ path: WritableKeyPath<ComposeDraft, T>) -> Binding<T> {
        Binding(get: { draft![keyPath: path] }, set: { draft?[keyPath: path] = $0; commitDraft() })
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
        commitDraft()
    }

    private func attachFromDrive() {
        showDrivePicker = true
    }

    private func edit(_ a: OutgoingAttachment) {
        editSessions[a.id]?.stop()
        editSessions[a.id] = AttachmentEditSession(attachment: a) { data in
            guard let i = draft?.attachments.firstIndex(where: { $0.id == a.id }) else { return }
            draft?.attachments[i].data = data
            commitDraft()
        }
    }

    private func stopWatching(_ id: UUID) {
        editSessions[id]?.stop()
        editSessions[id] = nil
    }

    private func remove(_ id: UUID) {
        stopWatching(id)
        draft?.attachments.removeAll { $0.id == id }
        commitDraft()
    }

    private func discard() {
        editSessions.values.forEach { $0.stop() }
        model.drafts[draftID] = nil
        close()
    }

    private func send(scheduling date: Date? = nil) {
        if let date {
            draft?.scheduledAt = date
            commitDraft()
        }
        guard let d = draft else { return }
        guard !needsAttachmentWarning(d) else {
            showAttachmentWarning = true
            return
        }
        deliver(d)
    }

    private func sendPending() {
        guard let d = draft else { return }
        deliver(d)
    }

    private func deliver(_ d: ComposeDraft) {
        editSessions.values.forEach { $0.stop() }
        do {
            try model.send(d)
            close()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func needsAttachmentWarning(_ d: ComposeDraft) -> Bool {
        guard warnAboutAttachments, d.attachments.isEmpty else { return false }
        return AttachmentReminder.mentionsAttachment(subject: d.subject, body: d.body, historyPlain: d.historyPlain,
                                                     keywords: AttachmentReminder.keywords(from: attachmentKeywords))
    }
}

enum AttachmentWarning {
    static let enabledKey = "attachmentWarning"
    static let keywordsKey = "attachmentKeywords"

    static var defaultKeywords: String {
        String(localized: "attached, attaching, attachment, attachments, enclosed, see attached, in the attachment, please find, anbei, anhang, angehängt, beigefügt, beiliegend, вложение, вложении, прикреплен, прикреплён, прикрепляю, прилагается, прилагаю, ekte, ektedir, ekli, ek olarak, ekledim, iliştirdim, əlavədə, əlavə edirəm, əlavə edilib, əlavə olunub, qoşma, qoşulub")
    }
}

struct ComposeAttachmentChip: View {
    let attachment: OutgoingAttachment
    let isEditing: Bool
    let onEdit: () -> Void
    let onStopWatching: () -> Void
    let onRemove: () -> Void

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isEditing ? "pencil.circle.fill" : "paperclip")
                .foregroundStyle(isEditing ? Color.accentColor : Color.primary)
            Text(attachment.filename).font(.caption)
            Text(sizeText).font(.caption2).foregroundStyle(.secondary)
            Menu {
                Button(isEditing ? "Reopen in Default App" : "Edit in Default App", action: onEdit)
                if isEditing { Button("Stop Watching for Changes", action: onStopWatching) }
                Button("Save As…", action: saveAs)
                Divider()
                Button("Remove", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
        }
        .padding(4)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .help(isEditing ? "Saves in the external editor are picked up automatically." : attachment.filename)
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        if panel.runModal() == .OK, let url = panel.url { try? attachment.data.write(to: url) }
    }
}

struct RecipientField: View {
    @Environment(AppModel.self) private var model
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
