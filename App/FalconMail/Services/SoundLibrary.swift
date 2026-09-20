import AppKit

enum MailSound: String, CaseIterable, Identifiable {
    case newMail, sent, error, reminder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newMail: return "New mail"
        case .sent: return "Message sent"
        case .error: return "Error"
        case .reminder: return "Reminder"
        }
    }

    var outlookFile: String {
        switch self {
        case .newMail: return "newmail"
        case .sent: return "mailsent"
        case .error: return "mailerror"
        case .reminder: return "reminder"
        }
    }

    var systemName: String {
        switch self {
        case .newMail: return "Glass"
        case .sent: return "Pop"
        case .error: return "Basso"
        case .reminder: return "Ping"
        }
    }
}

enum SoundPreset: String, CaseIterable, Identifiable {
    case falcon, outlook, silent, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .falcon: return "FalconMail"
        case .outlook: return "Outlook"
        case .silent: return "Silent"
        case .custom: return "Custom"
        }
    }

    var detail: String {
        switch self {
        case .falcon: return "The macOS alert sounds FalconMail ships with."
        case .outlook: return "Plays the sounds from Microsoft Outlook on this Mac. Nothing is copied into FalconMail, so the sounds disappear if Outlook is removed."
        case .silent: return "No sounds at all. Banners and badges still appear."
        case .custom: return "Pick a macOS sound for each event yourself."
        }
    }
}

enum SoundLibrary {
    static let presetKey = "soundPreset"
    static let none = SystemSounds.none

    private static let outlookRoots = [
        "/Applications/Microsoft Outlook.app/Contents/Resources",
        "/Applications/Microsoft Outlook.app/Contents/Frameworks/OutlookCore.framework/Versions/A/Resources"
    ]

    static var outlookAvailable: Bool {
        MailSound.allCases.contains { outlookURL(for: $0) != nil }
    }

    static func outlookURL(for sound: MailSound) -> URL? {
        for root in outlookRoots {
            let url = URL(fileURLWithPath: root).appendingPathComponent(sound.outlookFile + ".wav")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static var preset: SoundPreset {
        get { SoundPreset(rawValue: Preferences.string(presetKey, default: SoundPreset.falcon.rawValue)) ?? .falcon }
        set { Preferences.set(newValue.rawValue, presetKey) }
    }

    static func customKey(_ sound: MailSound) -> String { "sound.\(sound.rawValue)" }

    static func customName(_ sound: MailSound) -> String {
        Preferences.string(customKey(sound), default: sound.systemName)
    }

    /// Plays the sound for an event under the chosen preset. Outlook's own files are read from the
    /// installed copy of Outlook and never bundled.
    static func play(_ sound: MailSound) {
        switch preset {
        case .silent:
            return
        case .outlook:
            if let url = outlookURL(for: sound), let player = NSSound(contentsOf: url, byReference: true) {
                player.play()
                return
            }
            SystemSounds.play(sound.systemName)
        case .falcon:
            SystemSounds.play(sound.systemName)
        case .custom:
            SystemSounds.play(customName(sound))
        }
    }

    static func preview(_ sound: MailSound, preset: SoundPreset) {
        let saved = SoundLibrary.preset
        SoundLibrary.preset = preset
        play(sound)
        SoundLibrary.preset = saved
    }
}
