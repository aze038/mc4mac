import SwiftUI
import FalconCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gear") }
            AccountSettings().tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            RulesSettings().tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease.circle") }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell.badge") }
            GoogleSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 680, height: 520)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AttachmentWarning.enabledKey) private var warnAboutAttachments = true
    @AppStorage(AttachmentWarning.keywordsKey) private var attachmentKeywords = AttachmentWarning.defaultKeywords

    var body: some View {
        form.task { await model.refreshCacheSize() }
    }

    private var form: some View {
        @Bindable var model = model
        return Form {
            Section("Appearance") {
                Picker("Theme", selection: $model.appearance) {
                    ForEach(AppAppearance.allCases) { a in Text(a.title).tag(a.rawValue) }
                }
                .pickerStyle(.segmented)
                Text("Language follows the macOS setting in System Settings → General → Language & Region.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Offline and storage") {
                Picker("Keep offline copies per folder", selection: $model.offlineBodies) {
                    Text("Online only").tag(0)
                    Text("50 newest").tag(50)
                    Text("150 newest").tag(150)
                    Text("500 newest").tag(500)
                    Text("2,000 newest").tag(2000)
                }
                Picker("Skip offline copies larger than", selection: $model.maxOfflineMB) {
                    Text("1 MB").tag(1)
                    Text("5 MB").tag(5)
                    Text("20 MB").tag(20)
                    Text("No limit").tag(10_000)
                }
                HStack {
                    Text("Offline copies on this Mac: \(ByteCountFormatter.string(fromByteCount: Int64(model.cacheSizeBytes), countStyle: .file))")
                    Spacer()
                    Button("Clear") { model.clearCache() }
                }
                Text("Older copies are removed automatically as new mail arrives. Headers and the search index stay, about 200 bytes per message. Sent mail waits in the Outbox until you are online.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            readingSection
            triageSection
            keyboardSection
            composingSection
            Section("Sending") {
                Picker("Undo send window", selection: $model.undoSendSeconds) {
                    ForEach([0, 5, 10, 20, 30], id: \.self) { Text($0 == 0 ? "Off" : "\($0) seconds").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var readingSection: some View {
        @Bindable var model = model
        return Section("Reading") {
            Toggle("Group messages by conversation", isOn: $model.groupByThread)
            Toggle("Open messages in a separate window instead of a tab", isOn: $model.openInWindowOnDoubleClick)
            Toggle("Load remote images in messages", isOn: $model.loadRemoteImages)
            Picker("Mark messages as read", selection: $model.markReadPolicy) {
                ForEach(MarkReadPolicy.allCases) { policy in Text(policy.title).tag(policy.rawValue) }
            }
            if model.markReadPolicy == MarkReadPolicy.delay.rawValue {
                Picker("Delay", selection: $model.markReadDelaySeconds) {
                    ForEach([1, 2, 3, 5, 10], id: \.self) { Text($0 == 1 ? "1 second" : "\($0) seconds").tag($0) }
                }
            }
            Picker("After archiving, deleting or moving", selection: $model.advanceAfterAction) {
                ForEach(AdvanceAfterAction.allCases) { action in Text(action.title).tag(action.rawValue) }
            }
            Text("Choose Never to keep unread counts intact while you scan.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var keyboardSection: some View {
        @Bindable var model = model
        return Section("Keyboard") {
            Toggle("Use single-key shortcuts in the message list", isOn: $model.singleKeyShortcuts)
            Text("e archive, Delete trash, ! junk or not junk, m mute, u read or unread, s flag, v move, Shift+V move again, j and k next and previous conversation, n and p next and previous unread, c new message, r reply, a reply all, f forward, / search, and g followed by i, t, d, a or j to jump to a mailbox.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Every one of these also has a menu item, so they can be rebound in System Settings → Keyboard → Keyboard Shortcuts → App Shortcuts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var composingSection: some View {
        Section("Composing") {
            Toggle("Warn when a message mentions an attachment but has none", isOn: $warnAboutAttachments)
            TextField("Words that suggest an attachment", text: $attachmentKeywords, axis: .vertical)
                .lineLimit(2...5)
                .disabled(!warnAboutAttachments)
            Text("Separate the words with commas. Only what you type is checked, never the quoted reply or your signature.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var triageSection: some View {
        @Bindable var model = model
        return Section("Triage") {
            Picker("Undo window for archive, delete and move", selection: $model.undoActionSeconds) {
                ForEach([0, 3, 5, 10], id: \.self) { Text($0 == 0 ? "Off" : "\($0) seconds").tag($0) }
            }
            Text("Actions apply on this Mac straight away and reach the server when the window ends. Press Command+Z while the capsule is showing to take one back.")
                .font(.caption).foregroundStyle(.secondary)
        }
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
    @State private var signature = ""
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
            Section("Signature") {
                TextEditor(text: $signature).font(.body).frame(minHeight: 100)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Remove Account", role: .destructive) { model.removeAccount(account) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Save") {
                    var a = account
                    a.displayName = displayName
                    a.signature = signature
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
        signature = account.signature
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
        @Bindable var model = model
        return Section("Notifications") {
            Toggle("Notify about new mail", isOn: $notificationsEnabled)
            HStack {
                Picker("Notification sound", selection: $notificationSound) {
                    Text("None").tag(SystemSounds.none)
                    ForEach(SystemSounds.names, id: \.self) { Text($0).tag($0) }
                }
                Button { SystemSounds.play(notificationSound) } label: { Image(systemName: "play.circle") }
                    .disabled(notificationSound == SystemSounds.none)
            }
            HStack {
                Picker("Sent mail sound", selection: $model.sentSound) {
                    Text("None").tag(SystemSounds.none)
                    ForEach(SystemSounds.names, id: \.self) { Text($0).tag($0) }
                }
                Button { SystemSounds.play(model.sentSound) } label: { Image(systemName: "play.circle") }
                    .disabled(model.sentSound == SystemSounds.none)
            }
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
