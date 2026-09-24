import SwiftUI
import AppKit

/// Settings → Privacy: the switch for sending diagnostics, in one paragraph what is and is not
/// sent, this Mac's diagnostics ID, and a look at what is waiting to go.
struct DiagnosticsPrivacySection: View {
    @State private var showsPending = false
    @State private var copied = false

    private var service: DiagnosticsService { DiagnosticsService.shared }

    static let explanation = "When something goes wrong, FalconMail tells the FalconMail team so it can be fixed quickly. "
        + "It sends errors, crashes, moments when the app stopped responding, counts such as how many accounts and "
        + "messages it keeps, and the versions of FalconMail and macOS. It never sends your messages, subjects, "
        + "contacts, e-mail addresses or passwords."

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider()
            SettingsRow(label: "Diagnostics:") {
                Toggle("Send diagnostic data to the FalconMail team",
                       isOn: Binding(get: { service.isEnabled }, set: { service.setEnabled($0) }))
                Text(DiagnosticsPrivacySection.explanation)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(width: 440, alignment: .leading)
                if !service.buildMaySend {
                    Text("This copy of FalconMail was not built to send diagnostics, so nothing leaves this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("Diagnostics ID: \(service.diagnosticsID)")
                        .font(.system(size: 12)).textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy") { copyID() }
                        .controlSize(.small)
                        .help("Copies the ID, so the FalconMail team can find this Mac's reports")
                }
                Button("Show Data Waiting to Be Sent…") { showsPending = true }
            }
        }
        .sheet(isPresented: $showsPending) {
            DiagnosticsPendingSheet(text: service.pendingText())
        }
    }

    private func copyID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(service.diagnosticsID, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}

/// Everything waiting to be sent, exactly as it will read on the server, for reading only.
struct DiagnosticsPendingSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Data Waiting to Be Sent").font(.system(size: 14, weight: .semibold))
            // Verbatim, or the codes in angle brackets would be read as Markdown links.
            Text(verbatim: text.isEmpty
                 ? "Nothing is waiting. FalconMail sends what it has collected about once an hour."
                 : "This is what FalconMail will send next. Codes such as <addr:…> and <label:…> stand in for addresses and folder names.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !text.isEmpty {
                ReadOnlyTextView(text: text)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: text.isEmpty ? 150 : 520)
    }
}

/// A plain text view for a document too long for SwiftUI's `Text` to lay out quickly.
struct ReadOnlyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.textContainerInset = NSSize(width: 6, height: 6)
            view.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }
}
