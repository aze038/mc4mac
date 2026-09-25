import SwiftUI
import AppKit
import FalconCore

@MainActor
final class KeyRouter {
    enum Code {
        static let returnKey: UInt16 = 36
        static let tab: UInt16 = 48
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let escape: UInt16 = 53
        static let keypadEnter: UInt16 = 76
        static let forwardDelete: UInt16 = 117
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
        static let one: UInt16 = 18
        static let two: UInt16 = 19
        static let three: UInt16 = 20
        static let zero: UInt16 = 29
    }

    var model: AppModel

    private var chordStartedAt: Date?
    private var chordTask: Task<Void, Never>?
    private let chordWindow: TimeInterval = 1.0

    init(model: AppModel) {
        self.model = model
    }

    func handle(_ event: NSEvent, responder: NSResponder?) -> Bool {
        guard isActive(responder: responder), !carriesCommandKeys(event) else { return false }
        if event.keyCode == Code.escape { return escape() }
        if chordIsPending {
            if passesThrough(event) {
                cancelChord()
                return false
            }
            resolveChord(event)
            return true
        }
        if passesThrough(event) { return false }
        perform(event)
        return true
    }

    private func isActive(responder: NSResponder?) -> Bool {
        guard Preferences.bool(AppModel.singleKeyShortcutsKey, default: true) else { return false }
        guard model.activeTab == nil, !model.showsMovePalette, model.showsMessageList else { return false }
        return !(responder is NSText)
    }

    private func carriesCommandKeys(_ event: NSEvent) -> Bool {
        let blocking: NSEvent.ModifierFlags = [.command, .control, .option]
        return !event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: blocking)
    }

    private func passesThrough(_ event: NSEvent) -> Bool {
        if event.keyCode == Code.delete || event.keyCode == Code.forwardDelete { return false }
        let free: Set<UInt16> = [Code.returnKey, Code.keypadEnter, Code.tab, Code.space]
        if free.contains(event.keyCode) { return true }
        return event.modifierFlags.contains(.function)
    }

    private func escape() -> Bool {
        if chordIsPending {
            cancelChord()
            return true
        }
        if !model.searchText.isEmpty {
            model.clearSearch()
            return true
        }
        guard !model.filters.isEmpty else { return false }
        model.clearFilters()
        return true
    }

    /// The keys that act on the selection wait for the rows the table shows selected to be read
    /// into the app's selection (see `AppModel.afterSelectionRead`), so Delete pressed just after
    /// moving down a row deletes that row, never the one selected before.
    private func perform(_ event: NSEvent) {
        let model = self.model
        let shift = event.modifierFlags.contains(.shift)
        let trashKey = event.keyCode == Code.delete || event.keyCode == Code.forwardDelete || (event.keyCode == Code.three && shift)
        if trashKey {
            model.afterSelectionRead {
                let selected = model.selectedMessages
                guard !selected.isEmpty else { return }
                model.delete(selected)
            }
            return
        }
        if event.characters == "!" {
            model.afterSelectionRead {
                guard !model.selectedMessages.isEmpty else { return }
                model.toggleJunkOnSelection()
            }
            return
        }
        if !shift, applyFilterKey(event.keyCode) { return }
        guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else { return }
        switch key {
        case "j": model.selectNextThread()
        case "k": model.selectPreviousThread()
        case "n": model.selectNextUnread()
        case "p": model.selectPreviousUnread()
        case "c": model.composeNew()
        case "r": model.afterSelectionRead { model.replyToSelection(all: shift) }
        case "a": model.afterSelectionRead { model.replyToSelection(all: true) }
        case "f": model.afterSelectionRead { model.forwardSelection() }
        case "/": model.focusSearch()
        case "g": beginChord()
        default:
            model.afterSelectionRead { [weak self] in
                self?.performOnSelection(key, shift: shift, selected: model.selectedMessages)
            }
        }
    }

    private func performOnSelection(_ key: String, shift: Bool, selected: [MessageSummary]) {
        guard !selected.isEmpty else { return }
        switch key {
        case "e": model.archive(selected)
        case "u": if shift { model.markRead(selected, false) } else { model.toggleReadOnSelection() }
        case "i": if shift { model.markRead(selected, true) }
        case "s": model.toggleFlagOnSelection()
        case "m": model.muteSelection()
        case "v": if shift { model.moveToLastTarget() } else { model.openMovePalette() }
        default: break
        }
    }

    private func applyFilterKey(_ code: UInt16) -> Bool {
        switch code {
        case Code.one: model.toggleFilter(.unread)
        case Code.two: model.toggleFilter(.flagged)
        case Code.zero: model.clearFilters()
        default: return false
        }
        return true
    }

    private var chordIsPending: Bool {
        guard let started = chordStartedAt else { return false }
        return Date().timeIntervalSince(started) < chordWindow
    }

    private func beginChord() {
        chordTask?.cancel()
        chordStartedAt = Date()
        model.keyChordHint = "g"
        chordTask = Task { [weak self] in
            _ = try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.cancelChord()
        }
    }

    private func cancelChord() {
        chordTask?.cancel()
        chordTask = nil
        chordStartedAt = nil
        model.keyChordHint = nil
    }

    private func resolveChord(_ event: NSEvent) {
        cancelChord()
        if event.keyCode == Code.three {
            model.jump(to: .trash)
            return
        }
        guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else { return }
        switch key {
        case "i": model.jumpToAllInboxes()
        case "t": model.jump(to: .sent)
        case "d": model.jump(to: .drafts)
        case "a": model.jump(to: .archive)
        case "j": model.jump(to: .junk)
        default: break
        }
    }
}

struct KeyRouterView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> RouterView {
        let view = RouterView()
        view.router = KeyRouter(model: model)
        return view
    }

    func updateNSView(_ nsView: RouterView, context: Context) {
        nsView.router?.model = model
    }

    final class RouterView: NSView {
        var router: KeyRouter?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.attachedSheet == nil else { return event }
                guard let router = self.router else { return event }
                let consumed = MainActor.assumeIsolated { router.handle(event, responder: window.firstResponder) }
                return consumed ? nil : event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
