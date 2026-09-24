import SwiftUI
import FalconCore

struct AddAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Step { case choose, custom }

    @State private var step: Step = .choose
    @State private var email = ""
    @State private var displayName = ""
    @State private var settings = CustomServerSettings(imapHost: "", smtpHost: "", username: "", password: "")
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if step == .choose { chooseStep } else { customStep }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            footer
        }
        .padding(28)
        .frame(width: 520)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.badge.person.crop").font(.system(size: 34)).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading) {
                Text("Add an email account").font(.title2.bold())
                Text(step == .choose ? "Choose how this mailbox connects." : email).foregroundStyle(.secondary)
            }
        }
    }

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProviderChoice(title: "Google Workspace or Gmail",
                           detail: "Opens Google in your browser. Sign in and approve; that is all.",
                           icon: "g.circle.fill", selected: false) { signInWithGoogle() }
            ProviderChoice(title: "Other email (IMAP)",
                           detail: "Any mail server with a username and password over SSL/TLS.",
                           icon: "server.rack", selected: false) { step = .custom }
            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Google sign-in in your browser…").font(.callout).foregroundStyle(.secondary)
                }
            }
            if OAuthConfigLoader.load() == nil {
                Text("This build of FalconMail has no Google sign-in configured. Builds from GitHub Releases include it once the repository secrets are set; a local build needs the values in Settings → Advanced.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var customStep: some View {
        Form {
            TextField("Email address", text: $email)
                .onChange(of: email) { _, new in
                    let guess = CustomServerSettings.guess(for: new.trimmed.lowercased())
                    if settings.imapHost.isEmpty || settings.imapHost.hasPrefix("imap.") { settings.imapHost = guess.imapHost }
                    if settings.smtpHost.isEmpty || settings.smtpHost.hasPrefix("smtp.") { settings.smtpHost = guess.smtpHost }
                    if settings.username.isEmpty || settings.username.contains("@") { settings.username = new.trimmed }
                    if displayName.isEmpty { displayName = new.split(separator: "@").first.map(String.init) ?? "" }
                }
            TextField("Your name", text: $displayName)
            Section("Incoming mail (IMAP, SSL/TLS)") {
                TextField("Server", text: $settings.imapHost)
                TextField("Port", value: $settings.imapPort, format: .number)
            }
            Section("Outgoing mail (SMTP, SSL/TLS)") {
                TextField("Server", text: $settings.smtpHost)
                TextField("Port", value: $settings.smtpPort, format: .number)
            }
            Section("Login") {
                TextField("Username", text: $settings.username)
                SecureField("Password", text: $settings.password)
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }

    private var footer: some View {
        HStack {
            if step == .custom { Button("Back") { error = nil; step = .choose } }
            Spacer()
            if busy && step == .custom { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }
            if step == .custom {
                Button("Test and Add") { testAndAddCustom() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || !customReady)
            }
        }
    }

    private var customReady: Bool {
        email.contains("@") && !settings.imapHost.isEmpty && !settings.smtpHost.isEmpty && !settings.username.isEmpty && !settings.password.isEmpty
    }

    private func signInWithGoogle() {
        guard !busy else { return }
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.addGoogleAccount()
                dismiss()
            } catch {
                Log.warning("SignIn", "Adding a Google account failed: \(error.localizedDescription)", error: error)
                self.error = error.localizedDescription
            }
        }
    }

    private func testAndAddCustom() {
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                try await AccountProbe.test(settings)
                try await model.addCustomAccount(email: email.trimmed.lowercased(), displayName: displayName, settings: settings)
                dismiss()
            } catch {
                Log.warning("SignIn", "Adding an account on \(settings.imapHost) failed: \(AccountProbe.logDescription(of: error))", error: error)
                self.error = error.localizedDescription
            }
        }
    }
}

struct ProviderChoice: View {
    let title: String
    let detail: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 26)).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(12)
            .background(selected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
