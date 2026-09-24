import SwiftUI
import FalconCore

/// Legacy Outlook's Notifications and Sounds pane, laid out at its measured positions: the
/// alert for new messages, the sound set with a play button and a box for each of the six
/// sounds, the Dock badge's count, and Reset Alerts. Which accounts' mail is announced, and the
/// VIPs, are the Accounts pane's; whether the Dock shows a count at all is the General pane's.
struct NotificationsSettings: View {
    @AppStorage(AlertPrefs.desktopAlert) private var desktopAlert = true
    @AppStorage(AlertPrefs.showsPreview) private var showsPreview = true
    @AppStorage(AlertPrefs.bounceDock) private var bounceDock = false
    @AppStorage(SoundLibrary.setKey) private var soundSet = SoundSet.outlook.rawValue
    @State private var choosingSounds = false

    static let size = CGSize(width: 640, height: 596 - SettingsWindows.titleBarHeight)

    var body: some View {
        Placements(width: Self.size.width, height: Self.size.height) {
            ClassicText("Message arrival", weight: .bold).at(x: 42.1, baseline: 38)
            ClassicText("For new messages:").at(x: 84.6, baseline: 66)
            ClassicCheckbox("Display an alert on my desktop", isOn: $desktopAlert).at(x: 208, baseline: 66)
            Group {
                ClassicRadio(title: "Show message subject only", selected: !showsPreview) { showsPreview = false }
                    .at(x: 233, baseline: 92)
                ClassicRadio(title: "Show message subject and preview", selected: showsPreview) { showsPreview = true }
                    .at(x: 233, baseline: 112)
            }
            .disabled(!desktopAlert)
            ClassicCheckbox("Bounce FalconMail icon in Dock", isOn: $bounceDock).at(x: 208, baseline: 141)

            ClassicText("Sounds", weight: .bold).at(x: 42.1, baseline: 177)
            ClassicText("Sound set:").at(x: 81.9, baseline: 205)
            ClassicPopUp(title: "Sound set", items: SoundSet.allCases.map { ($0.title, $0.rawValue) }, selection: $soundSet)
                .frame(width: 228, height: ClassicPopUp<String>.regularHeight)
                .at(x: 155, y: 190)
            if soundSet == SoundSet.custom.rawValue {
                ClassicButton(title: "Choose Sounds…", width: 128) { choosingSounds = true }.at(x: 395, y: 190)
            }
            ClassicBox(width: 474, height: 96).at(x: 83, y: 221)
            ForEach(Array(MailSoundEvent.allCases.enumerated()), id: \.element) { index, sound in
                SoundRow(sound: sound)
                    .at(x: index < 3 ? 103 : 334, baseline: 252 + CGFloat(index % 3) * 26)
            }

            ClassicText("Badge count", weight: .bold).at(x: 42.1, baseline: 350)
            ClassicRadio(title: "For all accounts, include all unread messages", selected: true) {}
                .at(x: 82, baseline: 379)
            // FalconMail's Focused Inbox only filters the list and keeps no Focused count, and it
            // has no delegate inboxes, so these stay as Outlook shows them but cannot be chosen.
            Group {
                ClassicRadio(title: "For accounts that have Focused Inbox, include only Focused messages", selected: false) {}
                    .at(x: 82, baseline: 399)
                ClassicCheckbox("Include delegate inboxes", isOn: .constant(false)).at(x: 112, baseline: 421)
            }
            .disabled(true)

            ClassicText("Alerts", weight: .bold).at(x: 42.1, baseline: 457)
            ClassicText("Clear all \"Don't show this message again\" checkboxes").at(x: 81.9, baseline: 485)
            ClassicButton(title: "Reset Alerts", width: 203) { AlertSuppressions.reset() }.at(x: 83, y: 499)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $choosingSounds) { CustomSoundsSheet() }
    }
}

/// A sound's play button, its box and its name.
private struct SoundRow: View {
    let sound: MailSoundEvent
    @State private var on: Bool

    init(sound: MailSoundEvent) {
        self.sound = sound
        _on = State(initialValue: SoundLibrary.isEnabled(sound))
    }

    var body: some View {
        // The play button's top two points above the box's, the label's baseline twelve below it.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ClassicPlayButton(title: "Play \(sound.title)") { SoundLibrary.play(sound) }
                .alignmentGuide(.firstTextBaseline) { _ in 14 }
            ClassicCheckbox(sound.title, isOn: Binding(get: { on }, set: { on = $0; SoundLibrary.setEnabled($0, sound) }))
        }
    }
}

/// The Custom set: a macOS alert sound, or none, for each of the six.
private struct CustomSoundsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var names: [MailSoundEvent: String] = Dictionary(uniqueKeysWithValues: MailSoundEvent.allCases.map { ($0, SoundLibrary.customName($0)) })

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Custom sounds").font(.system(size: 13, weight: .bold))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(MailSoundEvent.allCases) { sound in
                    GridRow {
                        Text(sound.title).gridColumnAlignment(.trailing)
                        Picker(sound.title, selection: Binding(get: { names[sound] ?? sound.systemName }, set: {
                            names[sound] = $0
                            Preferences.set($0, SoundLibrary.customKey(sound))
                            SystemSounds.play($0)
                        })) {
                            Text("None").tag(SystemSounds.none)
                            ForEach(SystemSounds.names, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
