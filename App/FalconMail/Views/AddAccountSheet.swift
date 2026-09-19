import SwiftUI
import FalconCore

struct AddAccountSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Step { case email, choose, google, custom }
    enum Kind { case google, custom }

    @State private var step: Step = .email
    @State private var email = ""
    @State private var kind: Kind = .google
    @State private var displayName = ""
    @State private var settings = CustomServerSettings(imapHost: "", smtpHost: "", username: "", password: "")
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            switch step {
            case .email: emailStep
            case .choose: chooseStep
            case .google: googleStep
            case .custom: customStep
            }
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
                Text(step == .email ? "Start with your email address." : email).foregroundStyle(.secondary)
            }
        }
    }

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("name@company.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .onSubmit { continueFromEmail() }
            Text("Google Workspace and Gmail sign in with Google. Any other mailbox connects with IMAP and SMTP.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How does this mailbox connect?").font(.headline)
            ProviderChoice(title: "Google Workspace or Gmail", detail: "Sign in with your Google account. No passwords are stored in FalconMail.",
                           icon: "g.circle.fill", selected: kind == .google) { kind = .google }
            ProviderChoice(title: "Custom settings", detail: "IMAP and SMTP with a username and password. Works with any mail server that uses SSL/TLS.",
                           icon: "server.rack", selected: kind == .custom) { kind = .custom }
        }
    }

    private var googleStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in with Google").font(.headline)
            Text("Your browser opens Google's sign-in page for \(email). Approve access and come back here. Mail, Drive, Calendar and Contacts are connected in one step.")
                .foregroundStyle(.secondary)
            if !OAuthConfigLoader.isBuiltIn && OAuthConfigLoader.load() == nil {
                Text("This build of FalconMail has no Google sign-in configured. Builds from GitHub Releases include it; a local build needs the values in Settings → Advanced.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var customStep: some View {
        Form {
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
        .frame(height: 360)
    }

    private var footer: some View {
        HStack {
            if step != .email {
                Button("Back") { error = nil; step = step == .choose ? .email : .choose }
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }
            Button(primaryTitle) { primaryAction() }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || !primaryEnabled)
        }
    }

    private var primaryTitle: String {
        switch step {
        case .email, .choose: return "Continue"
        case .google: return "Continue with Google"
        case .custom: return "Test and Add"
        }
    }

    private var primaryEnabled: Bool {
        switch step {
        case .email: return email.contains("@") && email.contains(".")
        case .choose, .google: return true
        case .custom: return !settings.imapHost.isEmpty && !settings.smtpHost.isEmpty && !settings.username.isEmpty && !settings.password.isEmpty
        }
    }

    private func primaryAction() {
        error = nil
        switch step {
        case .email: continueFromEmail()
        case .choose: step = kind == .google ? .google : .custom
        case .google: signInWithGoogle()
        case .custom: testAndAddCustom()
        }
    }

    private func continueFromEmail() {
        let trimmed = email.trimmed.lowercased()
        guard trimmed.contains("@") else { return }
        email = trimmed
        settings = CustomServerSettings.guess(for: trimmed)
        if displayName.isEmpty { displayName = trimmed.split(separator: "@").first.map(String.init) ?? "" }
        kind = CustomServerSettings.looksLikeGoogle(trimmed) ? .google : kind
        step = .choose
    }

    private func signInWithGoogle() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await model.addGoogleAccount(loginHint: email)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func testAndAddCustom() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await AccountProbe.test(settings)
                try await model.addCustomAccount(email: email, displayName: displayName, settings: settings)
                dismiss()
            } catch {
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
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(12)
            .background(selected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}
