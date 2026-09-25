#if DEBUG
import SwiftUI
import AppKit
import FalconCore

/// `-FalconMailSnapshot <directory> -FalconMailSnapshotOnly gmail-switch` draws Settings →
/// Accounts' Gmail section for made-up accounts, in dark and light: a Google account on the
/// Gmail API, the same while its switch waits for IMAP actions to go, one turned back to IMAP,
/// and a Gmail account set up with an app password, offered Sign in with Google. Nothing is
/// signed in, contacted or saved: the accounts exist in memory only, and the one switch turned
/// off for the drawing is put back as it was.
enum GmailSwitchSnapshot {
    @MainActor static func render(_ model: AppModel, to directory: String) {
        let google = AccountInfo(email: "alex@example.com", displayName: "Alex Example", authMethod: "oauth")
        let off = AccountInfo(email: "sam@example.com", displayName: "Sam Example", authMethod: "oauth")
        let appPassword = AccountInfo.custom(email: "kim@gmail.com", displayName: "Kim Example", imapHost: "imap.gmail.com", imapPort: 993,
                                             smtpHost: "smtp.gmail.com", smtpPort: 465, username: "kim@gmail.com")
        model.accounts = [google, off, appPassword]
        let key = DefaultsGmailEngineSwitchStore.key(off.id)
        let before = UserDefaults.standard.object(forKey: key)
        model.coordinator.switches.setChoice(false, for: off.id)
        defer {
            if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        var lines: [String] = []
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            model.engineSwitchNotices = [:]
            draw(google, model: model, appearance: appearance, to: "\(directory)/gmail-switch-on-\(name).png")
            model.engineSwitchNotices[google.id] = GmailEngineSwitch.waitingNotice(google.email)
            draw(google, model: model, appearance: appearance, to: "\(directory)/gmail-switch-waiting-\(name).png")
            draw(off, model: model, appearance: appearance, to: "\(directory)/gmail-switch-off-\(name).png")
            draw(appPassword, model: model, appearance: appearance, to: "\(directory)/gmail-switch-app-password-\(name).png")
        }
        lines.append("on: \(model.gmailEngineChoice(for: google)) off: \(model.gmailEngineChoice(for: off)) "
                     + "app password eligible: \(GmailEngineSwitch.isEligible(appPassword)) uses Google IMAP: \(GmailEngineSwitch.usesGoogleIMAP(appPassword))")
        try? (lines.joined(separator: "\n") + "\n").write(toFile: "\(directory)/gmail-switch.txt", atomically: true, encoding: .utf8)
    }

    @MainActor private static func draw(_ account: AccountInfo, model: AppModel, appearance: NSAppearance.Name, to path: String) {
        let form = Form { GmailEngineSection(account: account) }
            .formStyle(.grouped)
            .environment(model)
            .frame(width: 520, height: 230)
        let host = NSHostingView(rootView: form)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 230)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
        host.layoutSubtreeIfNeeded()
        let size = host.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
