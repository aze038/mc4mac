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
    @Environment(\.openSettings) private var openSettings
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
    @State private var showTableDialog = false
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
        // Outermost, so the drop target and every other wrapper span the window's full height,
        // title band included; a wrapper that stops at the safe area clips the title row.
        .ignoresSafeArea(.container, edges: embedded ? [] : .top)
    }

    private var form: some View {
        composer
            .sheet(isPresented: $showTableDialog) {
                InsertTableSheet { formatter.insertTable(rows: $0.rows, columns: $0.columns) }
            }
            .alert("Did you forget an attachment?", isPresented: $showAttachmentWarning) {
                Button("Add Attachment") { attach() }.keyboardShortcut(.defaultAction)
                Button("Send Anyway") { sendPending() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This message mentions an attachment but none is attached.")
            }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if embedded {
                inlineActionBar
                Divider()
            } else {
                titleRow
                ribbon
                Rectangle().fill(OLColor.chromeLine).frame(height: 1)
            }
            headerFields
            Rectangle().fill(OLColor.fieldBandLine).frame(height: 1)
            if embedded {
                InlineFormatBar(formatter: formatter)
                Divider()
            }
            RichTextEditor(rtf: binding(\.bodyRTF), plain: binding(\.body)) { view in
                Task { @MainActor in
                    formatter.attach(view)
                    view.isContinuousSpellCheckingEnabled = Preferences.bool(Pref.checkSpelling, default: true)
                    view.isGrammarCheckingEnabled = Preferences.bool(Pref.checkGrammar, default: true)
                    view.isAutomaticQuoteSubstitutionEnabled = Preferences.bool(Pref.smartQuotes, default: true)
                    view.isAutomaticDashSubstitutionEnabled = Preferences.bool(Pref.smartQuotes, default: true)
                    view.isAutomaticLinkDetectionEnabled = Preferences.bool(Pref.smartLinks, default: true)
                    #if DEBUG
                    ComposeRibbonDemo.prepare(view, formatter: formatter, editSignatures: { editSignatures() })
                    #endif
                }
            }
        }
        .background(OLColor.reading)
        .navigationTitle(draft?.subject.isEmpty == false ? draft!.subject : "New Message")
    }

    /// Outlook's compose title row: quick actions after the traffic lights, "Untitled · account".
    private var titleRow: some View {
        let account = model.accounts.first { $0.id == draft?.accountID }?.email ?? ""
        let subject = draft?.subject.isEmpty == false ? draft!.subject : "Untitled"
        return ZStack {
            Text(account.isEmpty ? subject : "\(subject) • \(account)")
                .font(.system(size: OL.titleFont))
                .foregroundStyle(OLColor.title)
                .lineLimit(1)
                .padding(.horizontal, 200)
            HStack(spacing: OL.quickPitch - 20) {
                RibbonQuickButton(symbol: "square.and.arrow.down", title: "Save draft") { commitDraft() }
                RibbonQuickButton(symbol: "arrow.uturn.backward", title: "Undo") { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                RibbonQuickButton(symbol: "arrow.uturn.forward", title: "Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                RibbonQuickButton(symbol: "paperclip", title: "Attach a file") { attach() }
                Spacer()
            }
            .padding(.leading, OL.quickIconsStart)
        }
        .frame(height: OL.titleRow)
        .background(OLColor.chrome, ignoresSafeAreaEdges: [])
    }

    private var ribbon: some View {
        ComposeRibbon(tab: $tab,
                      formatter: formatter,
                      showsBcc: $showBcc,
                      importance: binding(\.importance),
                      canSend: !(draft?.to.isEmpty ?? true),
                      onSend: { send() },
                      onAttachFile: { attach() },
                      onAttachFromDrive: { attachFromDrive() },
                      signatures: signatureChoices,
                      onInsertSignature: { formatter.insertSignature($0.block) },
                      onEditSignatures: { editSignatures() },
                      onInsertTableDialog: { showTableDialog = true },
                      onCycleBackground: { model.cycleAppearance() })
    }

    private var inlineActionBar: some View {
        HStack(spacing: 14) {
            InlineAction(title: "Send", symbol: "paperplane", prominent: true, enabled: !(draft?.to.isEmpty ?? true)) { send() }
            InlineAction(title: "Discard", symbol: "trash") { discard() }
            InlineAction(title: "Attach", symbol: "paperclip") { attach() }
            InlineMenuAction(title: "Signature", symbol: "signature") {
                SignatureMenuItems(choices: signatureChoices, insert: { formatter.insertSignature($0.block) }, edit: { editSignatures() })
            }
            Menu {
                Button("Schedule Send…") { showSchedule = true }
                Button("Attach from Google Drive…") { attachFromDrive() }
                Button("Insert Table…") { showTableDialog = true }
                Button("Insert Link…") { formatter.insertLink() }
                Divider()
                Toggle("Show Cc", isOn: $showCc)
                Toggle("Show Bcc", isOn: $showBcc)
                Divider()
                Button("Check Spelling") { formatter.checkSpelling() }
                Button("Edit Signatures…") { editSignatures() }
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

    /// Outlook's header band: From only when there is a choice, To, Cc, Bcc on request, Subject;
    /// the address book glyph at the right of the recipient rows.
    private var headerFields: some View {
        VStack(spacing: 0) {
            if model.accounts.count > 1 {
                ComposeFieldRow(label: "From:") {
                    Menu {
                        ForEach(model.accounts) { a in
                            Button(a.displayName.isEmpty ? a.email : "\(a.displayName) (\(a.email))") { draft?.accountID = a.id; commitDraft() }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(model.accounts.first { $0.id == draft?.accountID }?.email ?? "")
                                .font(.system(size: OL.composeLabelFont))
                                .foregroundStyle(OLColor.text)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(OLColor.icon)
                        }
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                } trailing: {
                    Color.clear.frame(width: OL.composeSubjectRight, height: 1)
                }
            }
            ComposeFieldRow(label: "To:") {
                RecipientField(label: "", text: binding(\.to))
            } trailing: {
                bookButton
            }
            ComposeFieldRow(label: "Cc:") {
                RecipientField(label: "", text: binding(\.cc))
            } trailing: {
                bookButton
            }
            if showBcc {
                ComposeFieldRow(label: "Bcc:") {
                    RecipientField(label: "", text: binding(\.bcc))
                } trailing: {
                    bookButton
                }
            }
            ComposeFieldRow(label: "Subject:") {
                TextField("", text: binding(\.subject)).textFieldStyle(.plain)
            } trailing: {
                Color.clear.frame(width: OL.composeSubjectRight, height: 1)
            }
            scheduleBanner
            attachmentStrip
        }
        .padding(.top, OL.composeBandTop)
        .padding(.bottom, OL.composeBandBottom - (OL.composeRowPitch - OL.composeField))
        .background(OLColor.sidebar)
    }

    private var bookButton: some View {
        AddressBookButton { model.showModule(.people) }
            .padding(.leading, OL.composeFieldRight - OL.composeBookRight - OL.composeBookGlyph)
            .padding(.trailing, OL.composeBookRight)
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

    private var signatureChoices: [SignatureChoice] {
        SignatureChoice.choices(from: model.accounts, preferring: draft?.accountID)
    }

    /// Signatures…: Settings, opened at the pane where signatures are written.
    private func editSignatures() {
        SettingsRouter.shared.requested = .signatures
        openSettings()
    }

    private func load() {
        let stored = model.drafts[draftID]
        draft = stored
        formatter.history = stored?.historyPlain ?? ""
        // A window restored for a draft that no longer exists has nothing to show.
        if stored == nil, !embedded { dismiss() }
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

/// A To, Cc or Bcc field. Completions float in their own window under the field's box, so the
/// field and the rows below it stay exactly where they are while the list is open.
struct RecipientField: View {
    @Environment(AppModel.self) private var model
    let label: String
    @Binding var text: String
    @State private var suggestions: [ContactInfo] = []
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            if !label.isEmpty { Text(label).frame(width: 60, alignment: .trailing).foregroundStyle(.secondary) }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .background {
                    // Stretched over the header field's box, so the list hangs from the box's corner.
                    RecipientSuggestions(contacts: suggestions, text: text,
                                         accept: { completed in
                                             suggestions = []
                                             text = completed
                                         },
                                         dismiss: { suggestions = [] })
                        .padding(.horizontal, -OL.composeTextInset)
                        .frame(height: OL.composeField)
                }
                .onChange(of: text) { _, new in suggest(for: new) }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { suggestions = [] }
                }
        }
    }

    private func suggest(for text: String) {
        let fragment = RecipientText.lastFragment(of: text)
        guard focused, fragment.count >= 2 else {
            suggestions = []
            return
        }
        suggestions = Array(RecipientText.suggestions(from: model.contactList, for: fragment).prefix(RecipientSuggestions.maxRows))
    }
}
