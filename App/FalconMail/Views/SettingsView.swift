import SwiftUI
import FalconCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gear") }
            AccountSettings().tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            RulesSettings().tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease.circle") }
            GoogleSettings().tabItem { Label("Google", systemImage: "key") }
        }
        .frame(width: 620, height: 460)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Group messages by conversation", isOn: $model.groupByThread)
            Toggle("Load remote images in messages", isOn: $model.loadRemoteImages)
            Picker("Undo send window", selection: $model.undoSendSeconds) {
                ForEach([0, 5, 10, 20, 30], id: \.self) { Text($0 == 0 ? "Off" : "\($0) seconds").tag($0) }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AccountSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: UUID?
    @State private var signature = ""
    @State private var displayName = ""

    var body: some View {
        HSplitView {
            List(model.accounts, selection: $selected) { a in
                VStack(alignment: .leading) {
                    Text(a.displayName).font(.headline)
                    Text(a.email).font(.caption).foregroundStyle(.secondary)
                }.tag(a.id)
            }
            .frame(width: 220)
            VStack(alignment: .leading, spacing: 12) {
                if let id = selected, let account = model.accounts.first(where: { $0.id == id }) {
                    TextField("Display name", text: $displayName)
                    Text("Signature").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $signature).font(.body).frame(minHeight: 140)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    HStack {
                        Button("Remove Account", role: .destructive) { model.removeAccount(account); selected = nil }
                        Spacer()
                        Button("Save") {
                            var a = account
                            a.signature = signature
                            a.displayName = displayName
                            model.saveAccount(a)
                        }.keyboardShortcut(.defaultAction)
                    }
                    .onAppear { signature = account.signature; displayName = account.displayName }
                    .onChange(of: selected) { _, _ in
                        if let a = model.accounts.first(where: { $0.id == selected }) { signature = a.signature; displayName = a.displayName }
                    }
                } else {
                    ContentUnavailableView("Select an account", systemImage: "person.crop.circle")
                }
            }
            .padding()
        }
    }
}

struct RulesSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var rules: [RuleDefinition] = []
    @State private var selected: UUID?

    var body: some View {
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
        .task { rules = await model.rules.all() }
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
                        if a.kind == .moveToFolder {
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
                TextField("OAuth client ID", text: $clientID)
                SecureField("OAuth client secret", text: $clientSecret)
                HStack {
                    Spacer()
                    Button("Save") {
                        try? OAuthConfigLoader.save(OAuthClientConfig(clientID: clientID.trimmed, clientSecret: clientSecret.trimmed))
                        saved = true
                    }.disabled(clientID.trimmed.isEmpty)
                }
                if saved { Text("Saved to the Keychain.").font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Google Cloud credentials")
            } footer: {
                Text("Create a Desktop app OAuth client in Google Cloud Console and enable the Gmail, Drive, Calendar and People APIs. See docs/SETUP.md.")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            if let c = OAuthConfigLoader.load() { clientID = c.clientID; clientSecret = c.clientSecret ?? "" }
        }
    }
}
