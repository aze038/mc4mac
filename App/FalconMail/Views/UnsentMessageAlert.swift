import SwiftUI
import AppKit
import FalconCore

/// Legacy Outlook's alert on closing a message that has not been sent: the app's icon, the
/// question in bold, and Save as Draft, Discard Changes and Continue Writing stacked full width,
/// Return taking the first and Escape the last.
@MainActor
enum UnsentMessageAlert {
    static func make() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = UnsentMessage.alertTitle
        alert.informativeText = UnsentMessage.alertMessage
        for choice in UnsentMessage.Choice.allCases {
            alert.addButton(withTitle: choice.title).keyEquivalent = choice.keyEquivalent
        }
        return alert
    }

    /// Puts the alert up as a sheet on `window`, or on its own when there is no window showing
    /// to hold it, and hands over the answer.
    static func ask(over window: NSWindow?, answer: @escaping @MainActor (UnsentMessage.Choice) -> Void) {
        let alert = make()
        let choices = UnsentMessage.Choice.allCases
        let choose = { (response: NSApplication.ModalResponse) in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            answer(choices.indices.contains(index) ? choices[index] : .continueWriting)
        }
        if let window, window.isVisible {
            // A sheet already up, this alert among them, is answered first.
            guard window.attachedSheet == nil else { return }
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { choose(response) } }
        } else {
            choose(alert.runModal())
        }
    }
}

/// Gives the window this sits in a close guard, and takes it away again when the view leaves.
struct CloseGuardInstaller: NSViewRepresentable {
    let shouldClose: @MainActor (NSWindow) -> Bool

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView()
        view.shouldClose = shouldClose
        return view
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.shouldClose = shouldClose
        view.install()
    }

    final class GuardView: NSView {
        var shouldClose: @MainActor (NSWindow) -> Bool = { _ in true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { window?.closeGuard = nil }
            super.viewWillMove(toWindow: newWindow)
        }

        func install() {
            window?.closeGuard = { [weak self] window in self?.shouldClose(window) ?? true }
        }
    }
}
