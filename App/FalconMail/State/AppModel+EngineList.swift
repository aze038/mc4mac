import Foundation
import FalconCore

// The message table's side of the app (see EngineList): which sidebar selections it shows, and
// the selection it reads into the app's own, which the reading pane, the ribbon, the menus, the
// keys and reading by mail work on.

extension AppModel {
    /// Whether the table shows this selection: every folder of a Google account on the Gmail API,
    /// and All Inboxes, the smart folders and a search once any account is on it. Accounts on IMAP
    /// keep their stored list, and so does every view while no account is on the Gmail API.
    func showsInTable(_ selection: SidebarSelection?) -> Bool {
        switch selection {
        case .folder(let id)?:
            guard let accountID = folder(id)?.accountID else { return false }
            return usesGmailEngine(accountID)
        case .unified?, .smart?:
            return !gmailEngineAccounts.isEmpty
        default:
            return false
        }
    }

    /// The account a selection belongs to, when it is one account's folder.
    func tableAccount(for selection: SidebarSelection?) -> UUID? {
        guard case .folder(let id)? = selection else { return nil }
        return folder(id)?.accountID
    }

    /// Shows the sidebar selection in the table when the table shows it; false when the app's own
    /// list shows it, from the stored rows.
    func reloadEngineList() async -> Bool {
        await engineList.reload(self)
    }

    /// What the table has selected, read into messages: the app's threads are the selected rows'
    /// and its selection their ids, so everything that acts on the selection acts on them.
    func adoptTableSelection(_ threads: [MessageThread], ids: [String]) {
        self.threads = threads
        messages = threads.flatMap(\.messages)
        rebuildRows()
        let wanted = Set(ids)
        if selectedMessageIDs != wanted { selectedMessageIDs = wanted }
    }

    /// Whether the table shows the list now.
    var tableShowsList: Bool { engineList.isShown }

    // MARK: - Message windows

    /// A message window's message. A Google message on the Gmail API comes from its engine, as
    /// the folder it was opened from sees it: its window stays open while the Mac is offline or
    /// Gmail asks FalconMail to wait, and closes only once Gmail says the message is gone. Any
    /// other message comes from the stored rows, as before.
    func windowMessage(_ id: String) async -> RowAvailability {
        guard usesGmailEngine(messageID: id), let key = RowKey(string: id) else {
            if let found = await message(id: id) { return .available(found) }
            return .gone
        }
        // A window an earlier FalconMail left open for the account's old IMAP copy, which is kept
        // only for going back and is never read.
        guard key.isGmail else { return .gone }
        return await summary(for: key, in: engineList.windowView(for: id, model: self))
    }

    /// The messages of the conversation a window was opened for, newest first, as far as they can
    /// be read now.
    func windowConversation(_ ids: [String], newest: MessageSummary) async -> [MessageSummary] {
        var list: [MessageSummary] = []
        for id in ids {
            if id == newest.id {
                list.append(newest)
            } else if case .available(let found) = await windowMessage(id) {
                list.append(found)
            }
        }
        return list
    }

    /// What a window says while its Google message cannot be read: offline, or Gmail asked
    /// FalconMail to wait.
    func windowWaitingSentence(_ id: String) -> String {
        if let account = RowKey(string: id)?.accountID, case .apiPaused? = accountStatus.health[account] {
            return "Waiting a moment for Gmail. This message opens by itself."
        }
        return "You're offline, and this message is not kept on this Mac. It opens by itself when you're back online."
    }

    /// Whether anything is selected in the list, in the table above 1,000 rows too.
    var hasSelection: Bool {
        engineList.isShown ? engineList.selectionCount > 0 : !selectedMessageIDs.isEmpty
    }

    /// Runs a command on the selection. Above 1,000 rows selected in the table, nothing is handed
    /// on as a part of the selection: the command acts on the whole view where it can, and
    /// otherwise the status line says to select fewer. It never acts on the first thousand and
    /// quietly leaves the rest.
    func onSelection(_ command: ListCommand, _ body: () -> Void) {
        guard engineList.isShown, engineList.selectionCount > ActionTargets.largestItemList else {
            body()
            return
        }
        switch engineList.targets(for: command) {
        case .refused(let sentence):
            statusText = sentence
        case .items:
            body()
        case .wholeView(let except):
            actOnWholeView(command, except: except)
        }
    }

    /// A command on every message of the view shown but `except`, as after Select All, which the
    /// Gmail engine takes as one piece of bulk work described by the view.
    func actOnWholeView(_ command: ListCommand, except: [ActionItem]) {
        guard let view = engineList.controller.view, let verb = command.wholeViewVerb, let accountID = wholeViewAccount(view) else {
            statusText = ListStatusText.tooManySelected
            return
        }
        let request = MailActionRequest(verb: verb, targets: .wholeView(except: except), context: view)
        Task {
            do {
                let receipt = try await coordinator.perform(request, accountID: accountID)
                if let notice = receipt.notice { statusText = notice }
            } catch {
                showAlert(for: error)
            }
        }
    }

    /// A whole view is one account's folder: All Inboxes over several accounts is acted on by
    /// selecting fewer.
    private func wholeViewAccount(_ view: ListView) -> UUID? {
        guard case .folder(let id) = view.scope, let accountID = folder(id)?.accountID, usesGmailEngine(accountID) else { return nil }
        return accountID
    }
}
