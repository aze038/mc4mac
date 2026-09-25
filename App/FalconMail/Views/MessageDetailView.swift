import SwiftUI
import AppKit
import WebKit
import FalconCore

enum ReaderContext {
    case pane, tab, window
}

struct MessageReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let message: MessageSummary
    var conversation: MessageThread? = nil
    var context: ReaderContext = .pane
    var onDidAct: (() -> Void)? = nil
    /// Whether a subject too long for its line starts shown whole; only the snapshot hook sets it.
    var subjectExpanded = false

    @State private var parsed: MIMEMessage?
    @State private var rendered: String?
    @State private var loading = false
    @State private var allowRemoteImages = false
    @State private var hasRemote = false
    @State private var showDetails = false
    @State private var originalColours = false
    /// Why a message found only on the server could not be fetched, shown in place of its text.
    @State private var serverProblem: String?
    @State private var attempt = 0
    @Environment(\.colorScheme) private var colorScheme

    private var renderKey: String { "\(message.id)|\(allowRemoteImages)|\(model.loadRemoteImages)|\(originalColours)|\(colorScheme == .dark)|\(attempt)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .background(OLColor.reading)
        .task(id: renderKey) { await load() }
    }

    /// Outlook's reading header, measured: the subject in twenty-two point beside the
    /// conversation glyph, the sender's circle at forty-six points, the bold name with address, the
    /// date at the right, "To:" beneath, and the conversation notice as a grey band.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Image(systemName: (conversation?.messages.count ?? 1) > 1 ? "bubble.left.and.bubble.right" : "envelope")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(OLColor.icon)
                    .frame(width: 36, height: 22)
                    .padding(.leading, OL.readingIconX)
                    .padding(.top, OL.readingSubjectTop + 3)
                ReadingSubject(message.subject.isEmpty ? "(no subject)" : message.subject, expanded: subjectExpanded)
                    .id(message.id)
                    .padding(.leading, OL.readingTextX - OL.readingIconX - 36)
                    .padding(.top, OL.readingSubjectTop)
                Spacer(minLength: 8)
                Button { originalColours.toggle() } label: {
                    Image(systemName: originalColours ? "sun.max.fill" : "sun.max")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(OLColor.icon)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 13)
                .padding(.top, OL.readingSubjectTop + 1)
                .help(originalColours ? "Show this message on FalconMail's background" : "Show this message in its own colours")
            }
            .frame(minHeight: OL.readingAvatarTop, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .contextMenu { moreMenu }
            HStack(alignment: .top, spacing: 0) {
                AvatarView(name: message.from.displayName, address: message.from.address, size: OL.readingAvatar)
                    .padding(.leading, OL.readingAvatarX)
                senderBlock
                    .padding(.leading, OL.readingSenderX - OL.readingAvatarX - OL.readingAvatar)
                    .padding(.trailing, OL.readingRightInset)
            }
            if model.fetchesAttachmentsFromGmail(message) {
                if !serverAttachments.isEmpty {
                    ServerAttachmentStrip(message: message, stubs: serverAttachments)
                        .padding(.horizontal, OL.readingBodyX)
                        .padding(.top, 10)
                }
            } else if let parsed, !parsed.attachments.isEmpty {
                AttachmentStrip(attachments: parsed.attachments, html: parsed.textHTML, accountID: message.accountID)
                    .padding(.horizontal, OL.readingBodyX)
                    .padding(.top, 10)
            }
            if !model.loadRemoteImages && !allowRemoteImages && hasRemote {
                RemoteImagesBanner(loadOnce: {
                    allowRemoteImages = true
                    // A reply or forward then quotes the message with its pictures too.
                    model.remotePicturesLoaded.insert(message.id)
                }, loadAlways: { model.loadRemoteImages = true })
                    .padding(.horizontal, OL.readingBodyX)
                    .padding(.top, 10)
            }
        }
        .padding(.bottom, 12)
    }

    /// Known once the text has been fetched; each downloads only when it is opened or saved.
    private var serverAttachments: [GmailAttachmentStub] {
        parsed == nil ? [] : model.serverAttachments(for: message)
    }

    private var senderLine: String {
        message.from.name.isEmpty ? message.from.address : "\(message.from.name) <\(message.from.address)>"
    }

    private var senderBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(senderLine)
                    .font(.system(size: OL.readingSenderFont, weight: .semibold))
                    .foregroundStyle(OLColor.text)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(message.date.formatted(date: .complete, time: .shortened))
                    .font(.system(size: OL.readingSenderFont))
                    .foregroundStyle(OLColor.textMuted)
                    .lineLimit(1)
                    .fixedSize()
            }
            // As Outlook's: To, then Cc whenever there is one, then, on a message the owner sent,
            // Bcc; each a line of names, whole with every address once clicked.
            VStack(alignment: .leading, spacing: 4) {
                let lines = model.recipientLines(of: message, parsed: parsed)
                if !lines.to.isEmpty || (lines.cc.isEmpty && lines.bcc.isEmpty) {
                    recipientRow("To:", lines.to)
                }
                if !lines.cc.isEmpty {
                    recipientRow("Cc:", lines.cc)
                }
                if !lines.bcc.isEmpty {
                    recipientRow("Bcc:", lines.bcc)
                }
            }
            .padding(.top, 12)
            .contentShape(Rectangle())
            .onTapGesture { showDetails.toggle() }
            .help(showDetails ? "Click to hide the details" : "Click to see every recipient, the folder and the full date")
            if showDetails {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.date.formatted(date: .complete, time: .standard))
                    if let folder = model.folder(message.folderID) {
                        Text("Folder: " + folder.path)
                    }
                }
                .font(.system(size: OL.readingMetaFont))
                .foregroundStyle(OLColor.textMuted)
                .padding(.top, 6)
            }
        }
    }

    private func recipientRow(_ label: LocalizedStringKey, _ list: [EmailAddress]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(.system(size: OL.readingMetaFont, weight: .semibold))
                .foregroundStyle(OLColor.text)
                .frame(width: OL.readingRecipientLabel, alignment: .leading)
            Text(recipientLine(list))
                .font(.system(size: OL.readingMetaFont))
                .foregroundStyle(OLColor.textMuted)
                .lineLimit(showDetails ? nil : 1)
                .textSelection(.enabled)
        }
    }

    private func recipientLine(_ list: [EmailAddress]) -> String {
        showDetails ? list.map { $0.rfc5322 }.joined(separator: ", ") : list.map { $0.displayName }.joined(separator: ", ")
    }

    private var actions: some View {
        HStack(spacing: 2) {
            ReaderActionButton("Reply", "arrowshape.turn.up.left") { reply(all: false) }
            ReaderActionButton("Reply All", "arrowshape.turn.up.left.2") { reply(all: true) }
            ReaderActionButton("Forward", "arrowshape.turn.up.right") { forward() }
            ReaderActionButton(message.isFlagged ? "Unflag" : "Flag", message.isFlagged ? "flag.fill" : "flag") { model.setFlagged([message], !message.isFlagged) }
                .disabled(message.isServerOnly)
            Menu { moreMenu } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
        }
    }

    @ViewBuilder private var moreMenu: some View {
        Toggle("Show original colours", isOn: $originalColours)
            .help("Render this message on its own white background instead of FalconMail's")
        Divider()
        // A message found only on the server has no stored original to attach or save.
        Button("Forward as Attachment") { model.forwardAsAttachment([message]) }
            .disabled(message.isServerOnly)
        Divider()
        Group {
            Button("Archive") { model.archive([message]); onDidAct?() }
            Button("Delete") { model.delete([message]); onDidAct?() }
            Button(message.isFlagged ? "Unflag" : "Flag") { model.setFlagged([message], !message.isFlagged) }
            Button(message.isRead ? "Mark as Unread" : "Mark as Read") { model.markRead([message], !message.isRead) }
            if context == .pane {
                Button("Move to Folder…") { model.openMovePalette() }
            }
            Button(model.isInJunk([message]) ? "Not Junk" : "Move to Junk") { model.toggleJunk([message]) }
            Button(model.isMuted(thread) ? "Unmute Conversation" : "Mute Conversation") { model.toggleMute(thread) }
        }
        .disabled(message.isServerOnly)
        Divider()
        if context != .tab { Button("Open in Tab") { model.openMessageTab(message) } }
        if context != .window { Button("Open in Separate Window") { model.showMessageWindow(message.id) { openWindow(value: $0) } } }
        Divider()
        Button("Save as .eml…") { saveAsEML() }
            .disabled(message.isServerOnly)
    }

    private var thread: MessageThread { conversation ?? MessageThread(messages: [message]) }

    @ViewBuilder private var content: some View {
        if let rendered {
            HTMLView(html: rendered, sender: message.from)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OLColor.reading)
        } else if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let serverProblem {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                            Text(serverProblem).fixedSize(horizontal: false, vertical: true)
                            Button("Try Again") {
                                self.serverProblem = nil
                                attempt += 1
                            }
                            .buttonStyle(.link)
                        }
                        .font(.system(size: OL.statusFont))
                        .foregroundStyle(OLColor.textMuted)
                    }
                    Text(message.snippet).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func load() async {
        if parsed == nil {
            loading = true
            parsed = message.isServerOnly ? await openFromServer() : await model.parsedBody(for: message)
            loading = false
        }
        guard let parsed else { return }
        await render(parsed)
        // A message opened from the server shows its text first; small inline pictures follow.
        if message.isServerOnly, let richer = await model.serverBodyWithInlineImages(message) {
            self.parsed = richer
            await render(richer)
        }
    }

    /// Gmail's refusal shows as a line in the pane instead of an alert, so moving through results
    /// while Gmail is busy never stacks up alerts. Only the reading pane, whose selection the
    /// arrow keys move, waits to see whether the reader stays; a window, a tab and Try Again
    /// open at once.
    private func openFromServer() async -> MIMEMessage? {
        let trigger: GmailOpener.Trigger = context == .pane && attempt == 0 ? .selectionMoved : .asked
        do {
            let body = try await model.openServerMessage(message, trigger: trigger)
            serverProblem = nil
            return body
        } catch let error as GoogleAPIError {
            serverProblem = error.localizedDescription
        } catch {
            // Cancelled: the reader moved on before the fetch began or ended.
        }
        return nil
    }

    private func render(_ parsed: MIMEMessage) async {
        let allow = model.loadRemoteImages || allowRemoteImages
        let dark = colorScheme == .dark
        let original = originalColours
        let result = await Task.detached(priority: .userInitiated) {
            (MessageRenderer.html(for: parsed, allowRemote: allow, dark: dark, forceOriginal: original),
             MessageRenderer.hasRemoteImages(parsed))
        }.value
        rendered = result.0
        hasRemote = result.1
    }

    private func reply(all: Bool) {
        model.reply(to: message, all: all)
    }

    private func forward() {
        model.forward(message)
    }

    private func saveAsEML() {
        MessageFile.saveAsEML(message, model: model)
    }
}

enum MessageFile {
    /// Save as .eml: the message as it came, under its subject.
    @MainActor static func saveAsEML(_ message: MessageSummary, model: AppModel) {
        let panel = NSSavePanel()
        let safe = message.subject.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
        panel.nameFieldStringValue = (safe.isEmpty ? "message" : String(safe.prefix(60))) + ".eml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let raw = await model.rawBody(for: message) { try? raw.write(to: url) }
        }
    }
}

struct ReaderActionButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 26)
                .background(hovering ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// A message in its own window, the way Outlook opens one on a double-click: its own title row,
/// a Message ribbon whose every action works on this message, then the message. Opened from a
/// conversation's row, the window is its newest message's and shows every message of the
/// conversation as the reading pane does. It minimises into the tray as a compose window does.
struct MessageWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let messageID: String
    @State private var message: MessageSummary?
    /// The conversation the window was opened for, all its messages; empty for a single message.
    @State private var conversation: [MessageSummary]
    @State private var conversationIDs: [String]
    /// Whether the conversation's messages have been read, until when the window waits for them
    /// rather than showing its newest message alone for a moment.
    @State private var conversationRead: Bool
    /// Why a Google message on the Gmail API cannot be read yet, offline or while Gmail asks
    /// FalconMail to wait; the window stays open and fills in by itself.
    @State private var waitingSentence: String?

    /// `message` and `conversation` are given only by the debug snapshots, which have no store to
    /// read them from.
    init(messageID: String, message: MessageSummary? = nil, conversation: [MessageSummary] = []) {
        self.messageID = messageID
        _message = State(initialValue: message)
        _conversation = State(initialValue: conversation)
        _conversationIDs = State(initialValue: conversation.map(\.id))
        _conversationRead = State(initialValue: !conversation.isEmpty)
    }

    var body: some View {
        Group {
            if let message {
                VStack(spacing: 0) {
                    titleRow(message)
                    MessageWindowRibbon(message: message, close: { dismiss() })
                    Rectangle().fill(OLColor.chromeLine).frame(height: 1)
                    if conversation.count > 1 {
                        ConversationStackView(messages: conversation, context: .window, afterReplying: { closeAfterReplying() })
                    } else if !conversationRead, (model.conversationWindows[messageID]?.count ?? 0) > 1 {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        MessageReaderView(message: message, context: .window)
                    }
                }
                .background(OLColor.reading)
                .overlay {
                    if model.showsMovePalette, model.movePaletteWindow == messageID {
                        MovePalette(onMoved: { dismiss() })
                    }
                }
                .navigationTitle(message.subject.isEmpty ? "(no subject)" : message.subject)
            } else if let waitingSentence {
                ContentUnavailableView {
                    Label("This message isn't on this Mac", systemImage: "icloud.slash")
                } description: {
                    Text(waitingSentence)
                }
                .background(OLColor.reading)
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(PopupWindowAccessor(key: .message(messageID)))
        // Read again whenever stored messages change, so Read/Unread and Follow Up show, and
        // toggle, what the message is now.
        .task(id: model.openMessagesRevision) { await load() }
        .onAppear {
            model.openMessageWindows.insert(messageID)
            if let message { model.messageWindowRows[messageID] = message }
        }
        .onDisappear {
            model.openMessageWindows.remove(messageID)
            model.messageWindowRows[messageID] = nil
            model.conversationWindows[messageID] = nil
            if model.movePaletteWindow == messageID { model.closeMovePalette() }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private func load() async {
        if model.usesGmailEngine(messageID: messageID) {
            await loadFromEngine()
            return
        }
        if let current = await model.message(id: messageID) {
            message = current
            if model.openMessageWindows.contains(messageID) { model.messageWindowRows[messageID] = current }
            if let ids = model.conversationWindows[messageID] { conversationIDs = ids }
            if conversationIDs.count > 1 { conversation = await model.conversationMessages(conversationIDs, newest: current) }
        } else if message == nil {
            // A window brought back for a message that is no longer stored has nothing to show.
            dismiss()
        }
        conversationRead = true
    }

    /// A Google message on the Gmail API, opened by its Gmail id. The window closes only when
    /// Gmail says the message is gone; offline, or while Gmail asks FalconMail to wait, it stays
    /// open with what it has, and tries again every quarter of a minute until it can read it.
    private func loadFromEngine() async {
        while !Task.isCancelled {
            switch await model.windowMessage(messageID) {
            case .available(let current):
                waitingSentence = nil
                message = current
                if model.openMessageWindows.contains(messageID) { model.messageWindowRows[messageID] = current }
                if let ids = model.conversationWindows[messageID] { conversationIDs = ids }
                if conversationIDs.count > 1 { conversation = await model.windowConversation(conversationIDs, newest: current) }
                conversationRead = true
                return
            case .gone:
                if RowKey(string: messageID)?.isGmail == true {
                    model.statusText = "This message was moved or deleted on another device."
                }
                dismiss()
                return
            case .unavailable:
                conversationRead = true
                if message == nil { waitingSentence = model.windowWaitingSentence(messageID) }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    /// Settings → Composing: "Close the original message window after replying or forwarding",
    /// for a card's own Reply, Reply All and Forward as for the ribbon's.
    private func closeAfterReplying() {
        if Preferences.bool(Pref.closeOriginalAfterReply, default: true) { dismiss() }
    }

    private func titleRow(_ message: MessageSummary) -> some View {
        let account = model.accounts.first { $0.id == message.accountID }?.email ?? ""
        let subject = message.subject.isEmpty ? "(no subject)" : message.subject
        return ZStack {
            Text(account.isEmpty ? subject : "\(subject) • \(account)")
                .font(.system(size: OL.titleFont))
                .foregroundStyle(OLColor.title)
                .lineLimit(1)
                .padding(.horizontal, 200)
            HStack(spacing: OL.quickPitch - 20) {
                RibbonQuickButton(symbol: "square.and.arrow.down", title: "Save as .eml", enabled: !message.isServerOnly) {
                    MessageFile.saveAsEML(message, model: model)
                }
                RibbonQuickButton(symbol: "arrow.uturn.backward", title: "Undo", enabled: model.canUndoAction) { model.undoLastAction() }
                RibbonQuickButton(symbol: "arrow.uturn.forward", title: "Redo", enabled: false) {}
                RibbonQuickButton(symbol: "envelope.badge.shield.half.filled", title: "Mark all as read", enabled: model.unifiedUnreadCount > 0) {
                    model.markAllReadEverywhere()
                }
                Spacer()
            }
            .padding(.leading, OL.quickIconsStart)
        }
        .frame(height: OL.titleRow)
        .background(OLColor.chrome, ignoresSafeAreaEdges: [])
    }
}

/// The ribbon of an opened message: Outlook's Message tab, the same tiles as the Home ribbon,
/// each acting on this message alone, whatever the mailbox window has selected. An action that
/// takes the message out of its folder closes the window, as Outlook's does.
struct MessageWindowRibbon: View {
    @Environment(AppModel.self) private var model
    let message: MessageSummary
    let close: () -> Void
    @State private var tab = 0
    @AppStorage(Pref.closeOriginalAfterReply) private var closeAfterReply = true

    /// A message found only on the server can be read and replied to, not changed.
    private var canChange: Bool { !message.isServerOnly }

    var body: some View {
        VStack(spacing: 0) {
            RibbonTabStrip(tabs: [(0, "Message")], selection: $tab)
                .padding(.horizontal, OL.tabInset)
            RibbonBody {
                RibbonTile(title: "Delete", symbol: "trash", enabled: canChange) { model.delete([message]); close() }
                RibbonTile(title: "Archive", symbol: "archivebox", tint: OLColor.archiveGreen, enabled: canChange) { model.archive([message]); close() }
                RibbonSeparator()
                RibbonTile(title: "Reply", symbol: "arrowshape.turn.up.left", tint: OLColor.replyPurple) { reply(all: false) }
                RibbonTile(title: "Reply\nto All", symbol: "arrowshape.turn.up.left.2", tint: OLColor.replyPurple) { reply(all: true) }
                RibbonTile(title: "Forward", symbol: "arrowshape.turn.up.right", tint: OLColor.forwardBlue) { forward() }
                RibbonMiniColumn {
                    RibbonMiniItem(title: "Meeting", symbol: "calendar.badge.plus") {
                        model.showModule(.calendar)
                        NotificationCenter.default.post(name: .falconNewMeeting, object: nil)
                    }
                    RibbonMiniItem(title: "Attachment", symbol: "paperclip", enabled: canChange) { model.forwardAsAttachment([message]) }
                }
                RibbonSeparator()
                RibbonSplitTile(title: "Move", symbol: "arrow.down.to.line.compact", tint: OLColor.forwardBlue, enabled: canChange,
                                action: { model.openMovePalette(for: message) }) {
                    Button("Move to Folder…") { model.openMovePalette(for: message) }
                    Button("Archive") { model.archive([message]); close() }
                }
                RibbonSplitTile(title: "Junk", symbol: "person.crop.circle.badge.xmark", tint: OLColor.junkRed, enabled: canChange,
                                action: { junk() }) {
                    Button(model.isInJunk([message]) ? "Not Junk" : "Move to Junk") { junk() }
                }
                RibbonMenuTile(title: "Rules", symbol: "envelope.open.badge.clock") {
                    Button("Run Rules Now") { model.runRulesNow() }
                }
                RibbonSeparator()
                RibbonTile(title: "Read/Unread", symbol: message.isRead ? "envelope" : "envelope.open", enabled: canChange) { model.markRead([message], !message.isRead) }
                RibbonMenuTile(title: "Categorise", symbol: "square.grid.2x2", tint: OLColor.categoryOrange, enabled: canChange) {
                    ForEach(model.categories) { category in
                        Toggle(category.name, isOn: Binding(
                            get: { model.categories(for: message).contains(category) },
                            set: { _ in model.toggleCategory(category, on: [message]) }))
                    }
                }
                RibbonSplitTile(title: "Follow\nUp", symbol: "flag", tint: OLColor.flagRed, enabled: canChange, action: { model.setFlagged([message], !message.isFlagged) }) {
                    Button(message.isFlagged ? "Clear Flag" : "Flag Message") { model.setFlagged([message], !message.isFlagged) }
                }
            }
        }
        .background(OLColor.chrome, ignoresSafeAreaEdges: [])
    }

    /// Junk and Not Junk both take the message to another folder.
    private func junk() {
        model.toggleJunk([message])
        close()
    }

    private func reply(all: Bool) {
        // Settings → Composing: "Close the original message window after replying or forwarding".
        model.reply(to: message, all: all) { if closeAfterReply { close() } }
    }

    private func forward() {
        model.forward(message) { if closeAfterReply { close() } }
    }
}

struct RemoteImagesBanner: View {
    let loadOnce: () -> Void
    let loadAlways: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo").foregroundStyle(.secondary)
            Text("Remote images are blocked in this message.").font(.callout)
            Spacer()
            Button("Load Images", action: loadOnce).controlSize(.small)
            Button("Always Load", action: loadAlways).controlSize(.small)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

enum MessageRenderer {
    static func hasRemoteImages(_ parsed: MIMEMessage) -> Bool {
        guard let html = parsed.textHTML?.lowercased() else { return false }
        return html.contains("src=\"http") || html.contains("src='http") || html.contains("url(http") || html.contains("src=http")
    }

    /// A message that paints its own canvas keeps it; a plain one adopts the app's colours.
    static func designsItsOwnCanvas(_ parsed: MIMEMessage) -> Bool {
        guard let html = parsed.textHTML?.lowercased(), !html.trimmed.isEmpty else { return false }
        for marker in ["bgcolor", "background-color", "background:", "<table"] where html.contains(marker) { return true }
        return false
    }

    /// The page the reader's web view shows for `parsed` (see ReadingHTML): the message on its
    /// own ground, recoloured as Outlook does in dark appearance unless `forceOriginal`, the sun
    /// switch, shows it as it was written. `inStack` for a card of the conversation stack, which
    /// leaves less room under the text.
    static func html(for parsed: MIMEMessage, allowRemote: Bool, dark: Bool, forceOriginal: Bool, inStack: Bool = false) -> String {
        if let html = parsed.textHTML, !html.trimmed.isEmpty {
            return ReadingHTML.page(body: html, parts: parsed.attachments, allowRemote: allowRemote, dark: dark, ownColours: forceOriginal,
                                    inStack: inStack)
        }
        return ReadingHTML.page(body: "<pre>" + HTMLLinkify.escapeAndLink(parsed.textPlain ?? "") + "</pre>", plain: true,
                                parts: [], allowRemote: allowRemote, dark: dark, ownColours: forceOriginal, inStack: inStack)
    }
}

@MainActor
enum WebViewPool {
    private static var free: [ReaderWebView] = []
    private static let processPool = WKProcessPool()
    /// Remote images and whatever else a message loads are kept for this session only, in
    /// memory, never under ~/Library nor in WebKit's disk cache with its browser-sized limit.
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    static func acquire() -> ReaderWebView {
        if let v = free.popLast() { return v }
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.websiteDataStore = dataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = ReaderWebView(frame: .zero, configuration: config)
        view.underPageBackgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: 0x1E1E1E) : .white
        }
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    static func release(_ view: ReaderWebView) {
        view.navigationDelegate = nil
        view.fitsContent = false
        view.loadHTMLString("", baseURL: nil)
        if free.count < 4 { free.append(view) }
    }
}

/// Outlook's reading subject: one line ending in "…" when it is too long for it. A click on a
/// subject cut short shows it whole, wrapped over as many lines as it needs with the rest of the
/// header moved down, and another click folds it back to one line. The whole subject is its
/// tooltip, and it is no link, so the pointer stays an arrow.
struct ReadingSubject: View {
    let subject: String
    @State private var expanded: Bool
    /// The subject's width on one line, and that line's height, measured from a hidden copy.
    @State private var natural = CGSize.zero
    /// The size the subject was last laid out at.
    @State private var shown = CGSize.zero

    init(_ subject: String, expanded: Bool = false) {
        self.subject = subject
        _expanded = State(initialValue: expanded)
    }

    private var font: Font { .system(size: OL.readingSubjectFont, weight: .semibold) }
    private var cutShort: Bool { natural.width > shown.width + 0.5 }

    var body: some View {
        Text(subject)
            .font(font)
            .foregroundStyle(OLColor.text)
            .lineLimit(expanded ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { shown = $0 }
            .background {
                Text(subject)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { natural = $0 }
            }
            // Shown whole, it is as tall as it was last laid out, so a narrow width the window
            // asks about in passing never makes the header a word a line tall.
            .frame(height: expanded ? max(shown.height, natural.height) : nil, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture { if expanded || cutShort { expanded.toggle() } }
            .help(cutShort ? subject : "")
            // The lines added below the first push the sender down by as much as they take, so
            // the gap under the last line stays the one under a single line.
            .padding(.bottom, expanded ? max(0, OL.readingAvatarTop - OL.readingSubjectTop - natural.height) : 0)
    }
}

struct HTMLView: NSViewRepresentable {
    let html: String
    var sender: EmailAddress? = nil
    /// Given for a card of the conversation stack: the message is then as tall as its text, told
    /// here, and scrolls with the stack instead of on its own.
    var onHeight: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ReaderWebView {
        let view = MainActor.assumeIsolated { WebViewPool.acquire() }
        view.navigationDelegate = context.coordinator
        view.fitsContent = onHeight != nil
        view.onHeight = onHeight
        context.coordinator.lastHTML = ""
        context.coordinator.sender = sender
        return view
    }

    func updateNSView(_ view: ReaderWebView, context: Context) {
        context.coordinator.sender = sender
        view.onHeight = onHeight
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            view.willLoad()
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    static func dismantleNSView(_ view: ReaderWebView, coordinator: Coordinator) {
        MainActor.assumeIsolated { WebViewPool.release(view) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""
        var sender: EmailAddress?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { (webView as? ReaderWebView)?.didLoad() }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                decisionHandler(.cancel)
                let sender = self.sender
                Task { @MainActor in LinkGuard.open(url, from: sender) }
                return
            }
            decisionHandler(.allow)
        }
    }
}
