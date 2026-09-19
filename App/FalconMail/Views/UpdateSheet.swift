import SwiftUI
import AppKit
import FalconCore

struct UpdateSheet: View {
    @EnvironmentObject var updates: UpdateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: updates.isMandatory ? "exclamationmark.shield.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(updates.isMandatory ? Color.red : Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(updates.isMandatory ? "A required update is available" : "A new version of FalconMail is available")
                        .font(.title3.bold())
                    if let r = updates.release {
                        Text("FalconMail \(r.version.value.description) is ready to install. You have \(updates.currentVersion.description).")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if updates.isMandatory {
                Text("This update fixes a serious problem. FalconMail cannot be used until it is installed. Your open drafts, windows and selection are saved and restored after the update.")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if let notes = updates.release?.notes, !notes.trimmed.isEmpty {
                ScrollView {
                    Text(LocalizedStringKey(notes)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 180)
                .padding(8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            switch updates.phase {
            case .downloading(let p):
                ProgressView(value: p) { Text("Downloading \(updates.release?.assetName ?? "update")…") }
            case .installing:
                ProgressView { Text("FalconMail will close, install the update and reopen…") }
            case .failed(let message):
                Text(message).foregroundStyle(.red).font(.callout)
            default:
                EmptyView()
            }
            HStack {
                if let url = updates.release.flatMap({ URL(string: $0.htmlURL) }) {
                    Button("Release Notes") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                }
                Spacer()
                if updates.isMandatory {
                    Button("Quit FalconMail") { NSApp.terminate(nil) }
                } else {
                    Button("Skip This Version") { updates.skip() }
                    Button("Later") { updates.later() }
                }
                Button(buttonTitle) { updates.installNow() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(true)
    }

    private var isBusy: Bool {
        switch updates.phase {
        case .downloading, .installing: return true
        default: return false
        }
    }

    private var buttonTitle: String {
        if case .failed = updates.phase { return "Try Again" }
        return updates.isMandatory ? "Update Now" : "Quit, Install and Reopen"
    }
}

struct UpdateSettings: View {
    @EnvironmentObject var updates: UpdateManager
    @State private var token = ""
    @State private var tokenSaved = false

    var body: some View {
        Form {
            Section("Updates from GitHub Releases") {
                LabeledContent("Repository", value: updates.repository)
                LabeledContent("Installed version", value: updates.currentVersion.description)
                Toggle("Check for updates automatically", isOn: $updates.automaticChecks)
                Toggle("Include pre-releases", isOn: $updates.includePrereleases)
                HStack {
                    Button("Check Now") { Task { await updates.check(userInitiated: true) } }
                        .disabled(updates.phase == .checking)
                    if updates.phase == .checking { ProgressView().controlSize(.small) }
                    if let d = updates.lastChecked { Text("Last checked \(d.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                }
                if case .failed(let m) = updates.phase { Text(m).foregroundStyle(.red).font(.caption) }
                if updates.phase == .idle, updates.lastChecked != nil, updates.release == nil {
                    Text("FalconMail is up to date.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                SecureField("GitHub token (only for a private repository)", text: $token)
                HStack {
                    Spacer()
                    Button("Save Token") {
                        try? KeychainStore().save(Data(token.utf8), account: UpdateManager.tokenAccount)
                        tokenSaved = true
                    }
                }
                if tokenSaved { Text("Saved to the Keychain.").font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("A public repository needs no token. For a private repository create a fine-grained token with read access to Contents.")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            if let data = try? KeychainStore().load(account: UpdateManager.tokenAccount) { token = String(decoding: data, as: UTF8.self) }
        }
    }
}
