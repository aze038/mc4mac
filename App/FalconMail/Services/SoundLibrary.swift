import AppKit
import FalconCore

extension MailSoundEvent {
    /// As Outlook's Notifications and Sounds pane names them.
    var title: String {
        switch self {
        case .newMessage: return "New message"
        case .messageSent: return "Message sent"
        case .reminder: return "Reminder"
        case .syncError: return "Mailbox sync error"
        case .noNewMessages: return "No new messages"
        case .welcome: return "Welcome"
        }
    }

    /// The built-in set's file in the app bundle.
    var fileName: String {
        switch self {
        case .newMessage: return "newmail"
        case .messageSent: return "mailsent"
        case .reminder: return "reminder"
        case .syncError: return "mailerror"
        case .noNewMessages: return "nomail"
        case .welcome: return "welcome"
        }
    }

    /// The macOS alert sound the FalconMail set plays.
    var systemName: String {
        switch self {
        case .newMessage: return "Glass"
        case .messageSent: return "Pop"
        case .reminder: return "Ping"
        case .syncError: return "Basso"
        case .noNewMessages: return "Tink"
        case .welcome: return "Hero"
        }
    }
}

/// The Sound set pop-up's choices. The raw values are those earlier builds stored, so a choice
/// made there carries over: "outlook" once played the sounds of an installed Outlook and now
/// plays the same sounds from the app itself, and "silent" is Outlook's None.
enum SoundSet: String, CaseIterable, Identifiable {
    case outlook, falcon, custom, silent

    var id: String { rawValue }

    /// Outlook calls its own set Default, and so it is here.
    var title: String {
        switch self {
        case .outlook: return "Default"
        case .falcon: return "FalconMail"
        case .custom: return "Custom"
        case .silent: return "None"
        }
    }
}

enum SoundLibrary {
    static let setKey = "soundPreset"

    static var soundSet: SoundSet {
        get { SoundSet(rawValue: Preferences.string(setKey, default: SoundSet.outlook.rawValue)) ?? .outlook }
        set { Preferences.set(newValue.rawValue, setKey) }
    }

    static func enabledKey(_ sound: MailSoundEvent) -> String { "sound.on.\(sound.rawValue)" }

    static func isEnabled(_ sound: MailSoundEvent) -> Bool {
        Preferences.bool(enabledKey(sound), default: sound.isOnByDefault)
    }

    static func setEnabled(_ on: Bool, _ sound: MailSoundEvent) {
        Preferences.set(on, enabledKey(sound))
    }

    /// Earlier builds had one "Notify about new mail" switch for the banner and its sound alike.
    /// Outlook keeps the sound apart, so someone who had turned that switch off keeps the new
    /// message sound off too, once, instead of hearing it again after the update.
    static func carryOverEarlierChoices() {
        let key = "sound.carriedOver"
        guard !Preferences.bool(key, default: false) else { return }
        if UserDefaults.standard.object(forKey: AlertPrefs.desktopAlert) as? Bool == false,
           UserDefaults.standard.object(forKey: enabledKey(.newMessage)) == nil {
            setEnabled(false, .newMessage)
        }
        Preferences.set(true, key)
    }

    static func customKey(_ sound: MailSoundEvent) -> String { "sound.\(sound.rawValue)" }

    static func customName(_ sound: MailSoundEvent) -> String {
        Preferences.string(customKey(sound), default: sound.systemName)
    }

    /// Loaded once each, so a burst of new mail does not read the file again every time.
    @MainActor private static var loaded: [MailSoundEvent: NSSound] = [:]

    /// The event's sound in the chosen set, whether or not the event's box is ticked: the pane's
    /// play buttons and the sound gate both come here.
    @MainActor static func play(_ sound: MailSoundEvent) {
        switch soundSet {
        case .silent:
            return
        case .outlook:
            guard let player = bundled(sound) else { return SystemSounds.play(sound.systemName) }
            player.stop()
            player.play()
        case .falcon:
            SystemSounds.play(sound.systemName)
        case .custom:
            SystemSounds.play(customName(sound))
        }
    }

    @MainActor private static func bundled(_ sound: MailSoundEvent) -> NSSound? {
        if let player = loaded[sound] { return player }
        guard let url = Bundle.main.url(forResource: sound.fileName, withExtension: "wav"),
              let player = NSSound(contentsOf: url, byReference: true) else { return nil }
        loaded[sound] = player
        return player
    }
}
