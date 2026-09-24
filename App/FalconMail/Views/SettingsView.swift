import SwiftUI
import FalconCore

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, accounts, notifications, categories, fonts, autoCorrect, spelling
    case reading, composing, signatures, rules, junk, search
    case calendar, contacts, privacy, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .accounts: return "Accounts"
        case .notifications: return "Notifications & Sounds"
        case .categories: return "Categories"
        case .fonts: return "Fonts"
        case .autoCorrect: return "AutoCorrect"
        case .spelling: return "Spelling & Grammar"
        case .reading: return "Reading"
        case .composing: return "Composing"
        case .signatures: return "Signatures"
        case .rules: return "Rules"
        case .junk: return "Junk"
        case .search: return "Search"
        case .calendar: return "Calendar"
        case .contacts: return "Contacts"
        case .privacy: return "Privacy"
        case .updates: return "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "switch.2"
        case .accounts: return "person.crop.square.filled.and.at.rectangle"
        case .notifications: return "alarm"
        case .categories: return "square.grid.2x2"
        case .fonts: return "textformat"
        case .autoCorrect: return "text.badge.checkmark"
        case .spelling: return "checkmark.bubble"
        case .reading: return "envelope.open"
        case .composing: return "square.and.pencil"
        case .signatures: return "signature"
        case .rules: return "arrow.triangle.branch"
        case .junk: return "xmark.bin"
        case .search: return "magnifyingglass"
        case .calendar: return "calendar"
        case .contacts: return "person.2"
        case .privacy: return "lock.shield"
        case .updates: return "arrow.down.circle"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .accounts: return .blue
        case .notifications: return .blue
        case .categories: return .orange
        case .fonts: return .blue
        case .autoCorrect: return .orange
        case .spelling: return .green
        case .reading: return .blue
        case .composing: return .yellow
        case .signatures: return .purple
        case .rules: return .purple
        case .junk: return .red
        case .search: return .teal
        case .calendar: return .red
        case .contacts: return .blue
        case .privacy: return .blue
        case .updates: return .green
        }
    }

    var keywords: String {
        switch self {
        case .general: return "appearance theme density text size sidebar transparency"
        case .accounts: return "email imap smtp password google sign in"
        case .notifications: return "sound alert badge vip banner"
        case .categories: return "colour label tag"
        case .fonts: return "typeface size compose reading"
        case .autoCorrect: return "replace capitalise autoformat text completion"
        case .spelling: return "grammar writing style check"
        case .reading: return "preview conversation swipe mark read images quick actions"
        case .composing: return "reply forward attribution undo send cc bcc format"
        case .signatures: return "signature default new reply"
        case .rules: return "filter mute automation"
        case .junk: return "spam blocked safe senders"
        case .search: return "results mailbox folder saved"
        case .calendar: return "work week reminder time zone weather"
        case .contacts: return "people address book sync"
        case .privacy: return "remote images tracking telemetry"
        case .updates: return "version release install"
        }
    }

    static let personal: [SettingsPane] = [.general, .accounts, .notifications, .categories, .fonts, .autoCorrect, .spelling]
    static let email: [SettingsPane] = [.reading, .composing, .signatures, .rules, .junk, .search]
    static let other: [SettingsPane] = [.calendar, .contacts, .privacy, .updates]
}

/// Lets another window open Settings at a pane, the way Outlook's Signatures… opens its
/// preferences at Signatures.
@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var requested: SettingsPane?
}

struct SettingsView: View {
    @State private var pane: SettingsPane?
    @State private var query = ""
    private let router = SettingsRouter.shared

    init(pane: SettingsPane? = nil) {
        _pane = State(initialValue: pane)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let pane, query.isEmpty {
                    detail(pane)
                } else {
                    grid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { showRequestedPane() }
        .onChange(of: router.requested) { showRequestedPane() }
    }

    private func showRequestedPane() {
        guard let requested = router.requested else { return }
        pane = requested
        query = ""
        router.requested = nil
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(pane == nil || !query.isEmpty ? "FalconMail Settings" : pane!.title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if pane != nil {
                Button("Show All") { pane = nil; query = "" }
                    .controlSize(.regular)
            }
            SettingsSearchField(text: $query)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var matches: [SettingsPane] {
        let needle = query.trimmed.lowercased()
        guard !needle.isEmpty else { return SettingsPane.allCases }
        return SettingsPane.allCases.filter {
            $0.title.lowercased().contains(needle) || $0.keywords.contains(needle)
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                group("Personal Settings", SettingsPane.personal)
                group("Email", SettingsPane.email)
                group("Other", SettingsPane.other)
            }
            .padding(.bottom, 20)
        }
        .overlay {
            if matches.isEmpty {
                ContentUnavailableView("Nothing matches “\(query)”", systemImage: "magnifyingglass")
            }
        }
    }

    @ViewBuilder private func group(_ title: String, _ panes: [SettingsPane]) -> some View {
        let shown = panes.filter { matches.contains($0) }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 18).padding(.top, 14)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), alignment: .leading, spacing: 14) {
                    ForEach(shown) { item in
                        SettingsTile(pane: item) { pane = item; query = "" }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03))
            Divider()
        }
    }

    @ViewBuilder private func detail(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettings()
        case .accounts: AccountSettings()
        case .notifications: NotificationSettings()
        case .categories: CategoriesSettings()
        case .fonts: FontsSettings()
        case .autoCorrect: AutoCorrectSettings()
        case .spelling: SpellingSettings()
        case .reading: ReadingSettings()
        case .composing: ComposingSettings()
        case .signatures: SignaturesSettings()
        case .rules: RulesSettings()
        case .junk: JunkSettings()
        case .search: SearchSettings()
        case .calendar: CalendarSettings()
        case .contacts: ContactsSettings()
        case .privacy: PrivacySettings()
        case .updates: UpdateSettings()
        }
    }
}

struct SettingsTile: View {
    let pane: SettingsPane
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(pane.tint)
                    .frame(height: 30)
                Text(pane.title)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 92, height: 76)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SettingsSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .frame(width: 150)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: focused ? 2 : 1))
    }
}

struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selected: UUID?
    @State private var showAdd = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(model.accounts, selection: $selected) { a in
                    HStack(spacing: 10) {
                        Image(systemName: a.isEnabled ? (a.usesPassword ? "server.rack" : "g.circle.fill") : "pause.circle")
                            .font(.title2)
                            .foregroundStyle(!a.isEnabled ? Color.secondary : (model.online[a.id] == false ? Color.orange : Color.accentColor))
                        VStack(alignment: .leading) {
                            Text(a.displayName.isEmpty ? a.email : a.displayName).font(.headline)
                            Text(a.email).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(a.id)
                }
                .overlay {
                    if model.accounts.isEmpty {
                        ContentUnavailableView("No accounts yet", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    Button { showAdd = true } label: { Image(systemName: "plus").frame(width: 24, height: 22) }
                    Divider().frame(height: 16)
                    Button { if let a = model.accounts.first(where: { $0.id == selected }) { model.removeAccount(a); selected = nil } } label: {
                        Image(systemName: "minus").frame(width: 24, height: 22)
                    }
                    .disabled(selected == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(minWidth: 220, maxWidth: 260)
            Group {
                if let account = model.accounts.first(where: { $0.id == selected }) {
                    AccountDetail(account: account)
                } else {
                    VStack(spacing: 12) {
                        ContentUnavailableView(model.accounts.isEmpty ? "Add your first account" : "Select an account", systemImage: "person.crop.circle")
                        Button("Add Account…") { showAdd = true }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $showAdd) { AddAccountSheet().environment(model) }
        .onAppear { if selected == nil { selected = model.accounts.first?.id } }
    }
}

struct AccountDetail: View {
    @Environment(AppModel.self) private var model
    let account: AccountInfo
    @State private var displayName = ""
    @State private var newPassword = ""
    @State private var busy = false
    @State private var message: String?

    private var downloadedText: String {
        let bytes = model.downloadedToday[account.id] ?? 0
        let used = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return "\(used) of a safe daily allowance. Google suspends IMAP access past 2.5 GB a day, so FalconMail stops copying mail for offline reading well before that."
    }

    private var statusText: String {
        if !account.isEnabled { return "Paused" }
        return model.online[account.id] == false ? "Offline or sign-in needed" : "Connected"
    }

    var body: some View {
        Form {
            Section("Account") {
                TextField("Name", text: $displayName)
                LabeledContent("Email", value: account.email)
                LabeledContent("Sign-in", value: account.usesPassword ? "Username and password" : "Google account")
                LabeledContent("Status", value: statusText)
                LabeledContent("Downloaded today", value: downloadedText)
                Toggle("Keep this account in sync", isOn: Binding(get: { account.isEnabled },
                                                                 set: { model.setAccountSyncing(account, $0) }))
                Text(account.isEnabled
                     ? "Turn this off to stop FalconMail contacting this mailbox. Mail already downloaded stays available offline. Useful when Google has paused access after a large download, so the app waits quietly instead of retrying."
                     : "Paused. FalconMail is not contacting this mailbox at all. Turn it back on when you want mail to flow again.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Servers") {
                LabeledContent("Incoming (IMAP)", value: "\(account.imapHost):\(account.imapPort) SSL/TLS")
                LabeledContent("Outgoing (SMTP)", value: "\(account.smtpHost):\(account.smtpPort) SSL/TLS")
                if account.usesPassword { LabeledContent("Username", value: account.loginName) }
            }
            Section(account.usesPassword ? "Password" : "Google authorization") {
                if account.usesPassword {
                    SecureField("New password", text: $newPassword)
                    Button("Update Password") { updatePassword() }.disabled(newPassword.isEmpty || busy)
                } else {
                    Text("Mail, Drive, Calendar and Contacts are authorized through your Google account. Sign in again if Google revoked access or the password changed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Sign in with Google Again") { reauthorize() }.disabled(busy)
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Remove Account", role: .destructive) { model.removeAccount(account) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Save") {
                    var a = account
                    a.displayName = displayName
                    model.saveAccount(a)
                    message = "Saved."
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
        .onChange(of: account.id) { _, _ in load() }
    }

    private func load() {
        displayName = account.displayName
        newPassword = ""
        message = nil
    }

    private func updatePassword() {
        busy = true
        let settings = CustomServerSettings(imapHost: account.imapHost, imapPort: account.imapPort, smtpHost: account.smtpHost,
                                            smtpPort: account.smtpPort, username: account.loginName, password: newPassword)
        Task {
            defer { busy = false }
            do {
                try await AccountProbe.test(settings)
                try await model.tokens.savePassword(newPassword, for: account.id)
                await model.coordinator.start(account: account)
                newPassword = ""
                message = "Password updated and verified."
            } catch { message = error.localizedDescription }
        }
    }

    private func reauthorize() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.addGoogleAccount(loginHint: account.email)
                message = "Google authorization renewed."
            } catch { message = error.localizedDescription }
        }
    }
}

struct RulesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var rules: [RuleDefinition] = []
    @State private var selected: UUID?

    var body: some View {
        VStack(spacing: 0) {
            splitView
            Divider()
            mutedSection
        }
        .task { rules = await model.rules.all() }
    }

    private var splitView: some View {
        HSplitView {
            VStack {
                List(rules, selection: $selected) { r in
                    HStack {
                        Toggle("", isOn: Binding(get: { r.isEnabled }, set: { v in update(r.id) { $0.isEnabled = v } })).labelsHidden()
                        Text(r.name)
                    }.tag(r.id)
                }
                HStack {
                    Button { let r = RuleDefinition(name: "New rule", conditions: [RuleCondition(field: .from, op: .contains, value: "")], actions: [RuleAction(kind: .markRead)]); rules.append(r); selected = r.id; save() } label: { Image(systemName: "plus") }
                    Button { rules.removeAll { $0.id == selected }; selected = nil; save() } label: { Image(systemName: "minus") }.disabled(selected == nil)
                    Spacer()
                    Button("Run on Inbox Now") { model.runRulesNow() }.disabled(rules.isEmpty)
                }.padding(6)
            }
            .frame(width: 220)
            if let id = selected, let index = rules.firstIndex(where: { $0.id == id }) {
                RuleEditor(rule: $rules[index], folders: model.folders.values.flatMap { $0 }, onChange: save)
                    .padding()
            } else {
                ContentUnavailableView("Select a rule", systemImage: "line.3.horizontal.decrease.circle").frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var mutedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Muted conversations").font(.headline)
            if model.mutedThreads.isEmpty {
                Text("Nothing is muted. Select a conversation and press m, or use Message → Mute Conversation.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                mutedList
            }
            Text("Muting happens on this Mac. Other devices still show the conversation.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    private var mutedList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(model.mutedThreads.sorted { $0.mutedAt > $1.mutedAt }) { muted in
                    mutedRow(muted)
                }
            }
        }
        .frame(height: 110)
    }

    private func mutedRow(_ muted: MutedThread) -> some View {
        HStack {
            Text(muted.subject.isEmpty ? "(no subject)" : muted.subject).lineLimit(1)
            Spacer()
            Text(muted.mutedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
            Button("Remove") { model.unmute(muted) }.buttonStyle(.link)
        }
        .padding(.vertical, 2)
    }

    private func update(_ id: UUID, _ change: (inout RuleDefinition) -> Void) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        change(&rules[i])
        save()
    }

    private func save() {
        let list = rules
        Task { try? await model.rules.save(list) }
    }
}

struct RuleEditor: View {
    @Binding var rule: RuleDefinition
    let folders: [FolderInfo]
    let onChange: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Rule name", text: $rule.name).onChange(of: rule.name) { _, _ in onChange() }
                Picker("When", selection: $rule.matchAll) {
                    Text("all conditions match").tag(true)
                    Text("any condition matches").tag(false)
                }.onChange(of: rule.matchAll) { _, _ in onChange() }
                Text("Conditions").font(.headline)
                ForEach($rule.conditions) { $c in
                    HStack {
                        Picker("", selection: $c.field) { ForEach(RuleCondition.Field.allCases, id: \.self) { Text(label($0)).tag($0) } }.frame(width: 130)
                        Picker("", selection: $c.op) { ForEach(RuleCondition.Operator.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 130)
                        TextField("value", text: $c.value)
                        Button { rule.conditions.removeAll { $0.id == c.id }; onChange() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                    .onChange(of: c) { _, _ in onChange() }
                }
                Button("Add condition") { rule.conditions.append(RuleCondition(field: .subject, op: .contains, value: "")); onChange() }
                Text("Actions").font(.headline)
                ForEach($rule.actions) { $a in
                    HStack {
                        Picker("", selection: $a.kind) { ForEach(RuleAction.Kind.allCases, id: \.self) { Text(label($0)).tag($0) } }.frame(width: 160)
                        if a.kind == .moveToFolder || a.kind == .copyToFolder {
                            Picker("", selection: $a.value) {
                                Text("Choose folder").tag("")
                                ForEach(folders) { f in Text(f.path).tag(f.path) }
                            }
                        }
                        Button { rule.actions.removeAll { $0.id == a.id }; onChange() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                    .onChange(of: a) { _, _ in onChange() }
                }
                Button("Add action") { rule.actions.append(RuleAction(kind: .markRead)); onChange() }
            }
        }
    }

    private func label(_ f: RuleCondition.Field) -> String {
        switch f {
        case .from: return "From"
        case .to: return "To"
        case .cc: return "Cc"
        case .subject: return "Subject"
        case .anyRecipient: return "Any recipient"
        case .body: return "Body"
        case .hasAttachment: return "Has attachment"
        }
    }

    private func label(_ k: RuleAction.Kind) -> String {
        switch k {
        case .moveToFolder: return "Move to folder"
        case .copyToFolder: return "Copy to folder (label)"
        case .markRead: return "Mark as read"
        case .flag: return "Flag"
        case .delete: return "Move to trash"
        case .archive: return "Archive"
        case .stopProcessing: return "Stop processing rules"
        }
    }
}

struct NotificationSettings: View {
    @State private var soundPresetToken = 0
    @Environment(AppModel.self) private var model
    @AppStorage("notificationSound") private var notificationSound = "Ping"
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @State private var newVIP = ""
    @State private var selectedVIP: String?

    var body: some View {
        Form {
            soundsSection
            dockSection
            accountsSection.disabled(!notificationsEnabled)
            vipSection.disabled(!notificationsEnabled)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var soundsSection: some View {
        Section("Notifications") {
            Toggle("Notify about new mail", isOn: $notificationsEnabled)
            Picker("Sound preset", selection: Binding(get: { SoundLibrary.preset }, set: { SoundLibrary.preset = $0; soundPresetToken += 1 })) {
                ForEach(SoundPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                        .disabled(preset == .outlook && !SoundLibrary.outlookAvailable)
                }
            }
            .pickerStyle(.segmented)
            Text(SoundLibrary.preset == .outlook && !SoundLibrary.outlookAvailable
                 ? "Microsoft Outlook is not installed on this Mac, so FalconMail falls back to its own sounds."
                 : SoundLibrary.preset.detail)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(MailSound.allCases) { sound in
                HStack {
                    if SoundLibrary.preset == .custom {
                        Picker(sound.title, selection: Binding(get: { SoundLibrary.customName(sound) },
                                                               set: { Preferences.set($0, SoundLibrary.customKey(sound)); soundPresetToken += 1 })) {
                            Text("None").tag(SystemSounds.none)
                            ForEach(SystemSounds.names, id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        LabeledContent(sound.title, value: soundDescription(sound))
                    }
                    Button { SoundLibrary.play(sound) } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless)
                        .disabled(SoundLibrary.preset == .silent)
                }
            }
            .id(soundPresetToken)
        }
    }

    private func soundDescription(_ sound: MailSound) -> String {
        switch SoundLibrary.preset {
        case .silent: return "Silent"
        case .outlook: return SoundLibrary.outlookURL(for: sound) != nil ? "Outlook \(sound.outlookFile)" : sound.systemName
        case .falcon: return sound.systemName
        case .custom: return SoundLibrary.customName(sound)
        }
    }

    private var dockSection: some View {
        @Bindable var model = model
        return Section("Dock") {
            Toggle("Show unread count in the Dock", isOn: $model.dockBadge)
            Text("Counts unread messages across every inbox, whether or not banners are on.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var accountsSection: some View {
        Section("Notify me about") {
            if model.accounts.isEmpty {
                Text("Add an account to choose what it notifies you about.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.accounts) { account in modePicker(account) }
            }
            Text("Only new mail arriving in an inbox is announced. Mail a rule files away is silent.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func modePicker(_ account: AccountInfo) -> some View {
        Picker(account.email, selection: Binding(get: { model.notificationPolicy.mode(for: account.id) },
                                                 set: { model.setNotifyMode($0, for: account.id) })) {
            ForEach(NotifyMode.allCases) { mode in Text(mode.title).tag(mode) }
        }
    }

    private var vipSection: some View {
        Section("VIPs") {
            vipList
            vipEntry
            Text("VIP addresses are shared by all accounts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var vipList: some View {
        List(model.notificationPolicy.vip, id: \.self, selection: $selectedVIP) { entry in
            Text(entry)
        }
        .frame(height: 120)
        .overlay {
            if model.notificationPolicy.vip.isEmpty {
                Text("No VIPs yet. Add an address, or a whole domain written as @example.com.")
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
        }
    }

    private var vipEntry: some View {
        HStack {
            TextField("name@example.com or @example.com", text: $newVIP).onSubmit { addVIP() }
            Button { addVIP() } label: { Image(systemName: "plus") }
                .disabled(!newVIP.contains("@"))
            Button { removeSelectedVIP() } label: { Image(systemName: "minus") }
                .disabled(selectedVIP == nil)
        }
    }

    private func addVIP() {
        guard newVIP.contains("@") else { return }
        model.addVIP(newVIP)
        newVIP = ""
    }

    private func removeSelectedVIP() {
        guard let entry = selectedVIP else { return }
        model.removeVIP(entry)
        selectedVIP = nil
    }
}

struct GoogleSettings: View {
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Google sign-in", value: OAuthConfigLoader.isBuiltIn ? "Built into this app" : (OAuthConfigLoader.load() == nil ? "Not configured" : "Using developer override"))
            } footer: {
                Text("Release builds carry a Google native-app client ID, which is public by design and has no secret. The override below is for developers building from source; a Desktop-type client with a secret uses a local loopback redirect instead.")
            }
            Section("Developer override") {
                TextField("OAuth client ID", text: $clientID)
                SecureField("OAuth client secret", text: $clientSecret)
                HStack {
                    Button("Clear Override") { OAuthConfigLoader.clearOverride(); clientID = ""; clientSecret = ""; saved = false }
                    Spacer()
                    Button("Save") {
                        try? OAuthConfigLoader.save(OAuthClientConfig(clientID: clientID.trimmed, clientSecret: clientSecret.trimmed))
                        saved = true
                    }.disabled(clientID.trimmed.isEmpty)
                }
                if saved { Text("Saved to the Keychain.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            if let c = try? OAuthConfigLoader.keychain.loadCodable(OAuthClientConfig.self, account: OAuthConfigLoader.keychainAccount) {
                clientID = c.clientID
                clientSecret = c.clientSecret ?? ""
            }
        }
    }
}
