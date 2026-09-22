#if DEBUG
import SwiftUI
import AppKit
import FalconCore

/// Debug launch arguments that put the compose header on screen with no account behind it, so
/// address completion can be checked against Outlook by eye and by pixel. Launch with an empty
/// home (CFFIXED_USER_HOME); the demo only runs for a profile that has never held an account.
///
///     -FalconMailDemoCompose      a compose window over a stand-in address book
///     -FalconMailDemoEmbedded     the compose view as the mailbox window embeds it, instead
///     -FalconMailDemoTo <keys>    then types <keys> into To: one key at a time through the event
///                                 queue, as the keyboard would; {down} {up} {return} {tab}
///                                 {shift-tab} and {escape} press those keys, {click3} clicks the
///                                 third suggestion
///
/// The window is built here rather than through the app's scenes, and the app runs as an
/// accessory with its window behind every other: the scenes wait for the app to be activated, and
/// a demo must never take the keyboard from whoever is using the Mac. An accessory's window also
/// joins a full-screen Space, and window captures do not mind what covers it.
@MainActor
enum RecipientDemo {
    private static var window: NSWindow?

    static func startIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-FalconMailDemoCompose") else { return }
        let model = AppModel()
        guard !FileManager.default.fileExists(atPath: model.layout.accountsFile.path) else { return }
        NSApp.setActivationPolicy(.accessory)
        AppAppearance.apply(model.appearance)
        let account = UUID()
        model.contactList = standIns(account)
        let draftID = model.newDraft(ComposeDraft(accountID: account))
        let compose = ComposeView(draftID: draftID, embedded: arguments.contains("-FalconMailDemoEmbedded"))
            .themedRoot().environment(model).environmentObject(model.updates)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: OL.composeWindowWidth, height: OL.composeWindowHeight),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSHostingView(rootView: compose)
        content.sizingOptions = [.minSize]
        window.contentView = content
        window.setContentSize(NSSize(width: OL.composeWindowWidth, height: OL.composeWindowHeight))
        window.center()
        window.orderBack(nil)
        self.window = window
        guard let i = arguments.firstIndex(of: "-FalconMailDemoTo"), i + 1 < arguments.count else { return }
        let script = arguments[i + 1]
        Task { await type(script, into: window) }
    }

    private static func type(_ script: String, into window: NSWindow) async {
        guard let field = await firstRecipientField(in: window) else { return }
        window.makeFirstResponder(field)
        for key in keys(script) {
            // A pause per key, so each keystroke's view update lands before the next one arrives.
            try? await Task.sleep(nanoseconds: 150_000_000)
            events(for: key, in: window).forEach { NSApp.postEvent($0, atStart: false) }
        }
    }

    /// To: is the topmost unlabelled text field, once the window is on screen with its header laid
    /// out. A window on a Space nobody is looking at takes no typing, so the demo waits for it.
    private static func firstRecipientField(in window: NSWindow) async -> NSTextField? {
        for _ in 0..<6000 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard isOnScreen(window), let content = window.contentView else { continue }
            let fields = textFields(in: content).filter {
                $0.isEditable && !$0.isHiddenOrHasHiddenAncestor && !($0 is NSSearchField) && !($0 is NSComboBox)
                    && ($0.placeholderString ?? "").isEmpty && $0.placeholderAttributedString == nil
            }
            if let top = fields.max(by: { $0.convert($0.bounds, to: nil).maxY < $1.convert($1.bounds, to: nil).maxY }) { return top }
        }
        return nil
    }

    private static func isOnScreen(_ window: NSWindow) -> Bool {
        let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]]
        return info?.first?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? textFields(in: $0) }
    }

    private static func standIns(_ account: UUID) -> [ContactInfo] {
        let people: [(String, String, Int)] = [
            ("Kamal Muradov", "kamal.muradov@example.com", 12),
            ("Kamila Aliyeva", "kamila.aliyeva@example.org", 9),
            ("Nadia Kaminski", "nadia.kaminski@example.net", 7),
            ("", "kampala.office@example.com", 6),
            ("Karim Haddad", "karim.haddad@example.com", 5),
            ("Katerina Novak", "k.novak@example.org", 5),
            ("Akash Mehta", "akash.mehta@example.net", 4),
            ("Mikael Lindqvist", "mikael@example.com", 3),
            ("Kasia Wrona", "kasia.wrona@example.org", 2),
            ("Leyla Hasanova", "leyla.hasanova@example.com", 2),
            ("Orkhan Mammadov", "orkhan@example.org", 1),
        ]
        return people.map { ContactInfo(id: "demo:" + $0.1, accountID: account, name: $0.0, email: $0.1, source: "demo", useCount: $0.2) }
    }

    private static func keys(_ script: String) -> [String] {
        var keys: [String] = []
        var rest = Substring(script)
        while let first = rest.first {
            if first == "{", let close = rest.firstIndex(of: "}") {
                keys.append(String(rest[rest.startIndex...close]))
                rest = rest[rest.index(after: close)...]
            } else {
                keys.append(String(first))
                rest = rest.dropFirst()
            }
        }
        return keys
    }

    private static func events(for key: String, in window: NSWindow) -> [NSEvent] {
        guard key.hasPrefix("{click"), let row = Int(key.dropFirst(6).dropLast()) else { return keyDown(key, in: window).map { [$0] } ?? [] }
        guard let list = window.childWindows?.first(where: \.isVisible) else { return [] }
        let y = list.frame.height - RecipientSuggestions.listInset - (CGFloat(row) - 0.5) * RecipientSuggestions.rowHeight
        return [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap {
            NSEvent.mouseEvent(with: $0, location: NSPoint(x: 40, y: y), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: list.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
    }

    private static func keyDown(_ key: String, in window: NSWindow) -> NSEvent? {
        let named: [String: (code: UInt16, character: Int, flags: NSEvent.ModifierFlags)] = [
            "{down}": (KeyRouter.Code.downArrow, NSDownArrowFunctionKey, [.numericPad, .function]),
            "{up}": (KeyRouter.Code.upArrow, NSUpArrowFunctionKey, [.numericPad, .function]),
            "{return}": (KeyRouter.Code.returnKey, 0x0D, []),
            "{tab}": (KeyRouter.Code.tab, 0x09, []),
            "{shift-tab}": (KeyRouter.Code.tab, NSBackTabCharacter, [.shift]),
            "{escape}": (KeyRouter.Code.escape, 0x1B, []),
        ]
        let special = named[key]
        let characters = special.flatMap { UnicodeScalar($0.character).map { String(Character($0)) } } ?? key
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: special?.flags ?? [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                isARepeat: false, keyCode: special?.code ?? 0)
    }
}
#endif
