import SwiftUI
import FalconCore

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
                            .foregroundStyle(!a.isEnabled ? Color.secondary : (model.online[a.id] == false ? Color.orange : Theme.accent))
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
    @State private var showVIPs = false

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
            GmailEngineSection(account: account)
            // Which new mail each account announces, which Outlook's Notifications and Sounds
            // pane has no place for.
            Section("New mail alerts") {
                Picker("Notify me about", selection: Binding(get: { model.notificationPolicy.mode(for: account.id) },
                                                             set: { model.setNotifyMode($0, for: account.id) })) {
                    ForEach(NotifyMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Only new mail arriving in an inbox is announced. Mail a rule files away is silent.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("VIPs…") { showVIPs = true }
                }
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
        .sheet(isPresented: $showVIPs) { VIPSheet().environment(model) }
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
                try await AccountProbe.test(settings, existingAccount: true)
                try await model.tokens.savePassword(newPassword, for: account.id)
                await model.coordinator.start(account: account)
                newPassword = ""
                message = "Password updated and verified."
            } catch {
                Log.warning("SignIn", "Checking a new password failed: \(AccountProbe.logDescription(of: error))", error: error, account: account)
                message = error.localizedDescription
            }
        }
    }

    private func reauthorize() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.addGoogleAccount(loginHint: account.email)
                message = "Google authorization renewed."
            } catch {
                Log.warning("SignIn", "Renewing Google sign-in failed: \(error.localizedDescription)", error: error, account: account)
                message = error.localizedDescription
            }
        }
    }
}

/// The VIPs every account's "Only from VIPs" listens for.
struct VIPSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newVIP = ""
    @State private var selectedVIP: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VIPs").font(.system(size: 13, weight: .bold))
            List(model.notificationPolicy.vip, id: \.self, selection: $selectedVIP) { entry in
                Text(entry)
            }
            .frame(height: 160)
            .overlay {
                if model.notificationPolicy.vip.isEmpty {
                    Text("No VIPs yet. Add an address, or a whole domain written as @example.com.")
                        .font(.caption).foregroundStyle(.secondary).padding()
                }
            }
            HStack {
                TextField("name@example.com or @example.com", text: $newVIP).onSubmit { add() }
                Button { add() } label: { Image(systemName: "plus") }
                    .disabled(!newVIP.contains("@"))
                Button { remove() } label: { Image(systemName: "minus") }
                    .disabled(selectedVIP == nil)
            }
            Text("VIP addresses are shared by all accounts.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func add() {
        guard newVIP.contains("@") else { return }
        model.addVIP(newVIP)
        newVIP = ""
    }

    private func remove() {
        guard let entry = selectedVIP else { return }
        model.removeVIP(entry)
        selectedVIP = nil
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
