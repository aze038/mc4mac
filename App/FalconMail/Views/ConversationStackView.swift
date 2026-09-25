import SwiftUI
import AppKit
import WebKit
import FalconCore

/// A conversation in the reading pane, or in a window or tab of its own, as the owner chose it
/// from Gmail: every message one under another, newest at the top, each with its own sender,
/// recipients and date and a line between them. The newest and the unread are open; the others
/// are one line each, sender, first words and date, and open on a click. Only an open card
/// fetches its message's text, and the quoted history in it of the messages below it is hidden
/// behind •••. A conversation of one message is shown by MessageReaderView, as it always was.
struct ConversationStackView: View {
    @Environment(AppModel.self) private var model
    let messages: [MessageSummary]
    var context: ReaderContext = .pane
    /// Run once a card's reply or forward is open, as a message window closes after one.
    var afterReplying: (() -> Void)? = nil
    /// Whether a subject too long for its line starts shown whole; only the snapshot hook sets it.
    var subjectExpanded = false

    @State private var stack: ConversationStack
    @State private var originalColours = false

    init(messages: [MessageSummary], context: ReaderContext = .pane, afterReplying: (() -> Void)? = nil,
         subjectExpanded: Bool = false) {
        self.messages = messages
        self.context = context
        self.afterReplying = afterReplying
        self.subjectExpanded = subjectExpanded
        _stack = State(initialValue: ConversationStack(messages))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical) {
                // Lazy, so that a long conversation with many messages open makes a message view
                // only for those scrolled near, instead of fifty at once.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(stack.messages.enumerated()), id: \.element.id) { index, message in
                        VStack(alignment: .leading, spacing: 0) {
                            if index > 0 {
                                Rectangle().fill(OLColor.divider).frame(height: 1)
                                    .padding(.leading, OL.readingBodyX).padding(.trailing, OL.readingRightInset)
                            }
                            ConversationCard(message: message, expanded: stack.isExpanded(message.id), isNewest: index == 0,
                                             earlier: stack.older(than: message.id), context: context,
                                             originalColours: originalColours,
                                             toggle: { toggle(message) }, act: { perform($0, from: message.id) })
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .background(OLColor.reading)
        .onChange(of: messages) { _, latest in stack.update(latest) }
    }

    /// The reading header's first line, once for the whole conversation: the subject in twenty-two
    /// point beside the conversation glyph, Expand all or Collapse all, and the sun switch, which
    /// shows every message in its own colours.
    private var header: some View {
        let subject = stack.newest?.subject ?? ""
        return HStack(alignment: .top, spacing: 0) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(OLColor.icon)
                .frame(width: 36, height: 22)
                .padding(.leading, OL.readingIconX)
                .padding(.top, OL.readingSubjectTop + 3)
            ReadingSubject(subject.isEmpty ? "(no subject)" : subject, expanded: subjectExpanded)
                .id(stack.newest?.id)
                .padding(.leading, OL.readingTextX - OL.readingIconX - 36)
                .padding(.top, OL.readingSubjectTop)
            Spacer(minLength: 8)
            Button { stack.toggleAll() } label: {
                Text(stack.allExpanded ? "Collapse all" : "Expand all")
                    .font(.system(size: 11))
                    .foregroundStyle(OLColor.text)
                    .padding(.horizontal, 8)
                    .frame(height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(OLColor.buttonBorder, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .padding(.trailing, 10)
            .padding(.top, OL.readingSubjectTop + 4)
            .help(stack.allExpanded ? "Fold every message but the newest to one line" : "Show every message of this conversation in full")
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
            .help(originalColours ? "Show these messages on FalconMail's background" : "Show these messages in their own colours")
        }
        .frame(minHeight: OL.readingAvatarTop, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A click on a card's header or folded line. A message opened this way is read, as one
    /// opened in the list is.
    private func toggle(_ message: MessageSummary) {
        let opening = !stack.isExpanded(message.id)
        stack.toggle(message.id)
        if opening, !message.isRead { model.markReadOnExpanding(message) }
    }

    /// A card's own Reply, Reply All and Forward, on that card's message.
    private func perform(_ action: ConversationCard.Action, from id: String) {
        guard let message = stack.target(of: .card(id)) else { return }
        switch action {
        case .reply(let all): model.reply(to: message, all: all, then: afterReplying)
        case .forward: model.forward(message, then: afterReplying)
        }
    }
}

/// One message of the conversation stack: open, with the reading header's avatar, sender, date,
/// recipients and the message itself, or folded to one line.
struct ConversationCard: View {
    enum Action { case reply(all: Bool), forward }

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    let message: MessageSummary
    let expanded: Bool
    let isNewest: Bool
    /// The messages below this one, whose text its quote may repeat.
    let earlier: [MessageSummary]
    let context: ReaderContext
    let originalColours: Bool
    let toggle: () -> Void
    let act: (Action) -> Void

    @State private var parsed: MIMEMessage?
    @State private var rendered: String?
    @State private var loading = false
    @State private var allowRemoteImages = false
    @State private var hasRemote = false
    @State private var showDetails = false
    @State private var serverProblem: String?
    @State private var attempt = 0
    /// Whether the message quotes what the cards below it say, hidden unless `showQuoted`.
    @State private var hasQuote = false
    @State private var showQuoted = false
    @State private var bodyHeight: CGFloat = 0
    @State private var hovering = false
    /// Open when the stack opened, rather than opened later by a click.
    @State private var openedWithStack: Bool

    init(message: MessageSummary, expanded: Bool, isNewest: Bool, earlier: [MessageSummary], context: ReaderContext,
         originalColours: Bool, toggle: @escaping () -> Void, act: @escaping (Action) -> Void) {
        self.message = message
        self.expanded = expanded
        self.isNewest = isNewest
        self.earlier = earlier
        self.context = context
        self.originalColours = originalColours
        self.toggle = toggle
        self.act = act
        _openedWithStack = State(initialValue: expanded)
    }

    private var renderKey: String {
        "\(message.id)|\(expanded)|\(allowRemoteImages)|\(model.loadRemoteImages)|\(originalColours)|\(colorScheme == .dark)|\(attempt)|\(showQuoted)"
    }

    var body: some View {
        Group {
            if expanded { openCard } else { foldedLine }
        }
        .task(id: renderKey) { if expanded { await load() } }
    }

    // MARK: Open

    private var openCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                AvatarView(name: message.from.displayName, address: message.from.address, size: OL.readingAvatar)
                    .padding(.leading, OL.readingAvatarX)
                senderBlock
                    .padding(.leading, OL.readingSenderX - OL.readingAvatarX - OL.readingAvatar)
                    .padding(.trailing, OL.readingRightInset)
            }
            .padding(.top, isNewest ? 0 : 14)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .contextMenu { menu }
            if message.isServerOnly {
                if parsed != nil, !model.serverAttachments(for: message).isEmpty {
                    ServerAttachmentStrip(message: message, stubs: model.serverAttachments(for: message))
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
                    model.remotePicturesLoaded.insert(message.id)
                }, loadAlways: { model.loadRemoteImages = true })
                    .padding(.horizontal, OL.readingBodyX)
                    .padding(.top, 10)
            }
            messageText
                .padding(.top, 8)
            if hasQuote, rendered != nil {
                Button { showQuoted.toggle() } label: {
                    Text("•••")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(OLColor.textMuted)
                        .padding(.horizontal, 7)
                        .frame(height: 14)
                        .background(OLColor.notice, in: RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 29)
                .help(showQuoted ? "Hide the quoted text" : "Show the quoted text")
            }
        }
        .padding(.bottom, 12)
    }

    private var senderLine: String {
        message.from.name.isEmpty ? message.from.address : "\(message.from.name) <\(message.from.address)>"
    }

    private var senderBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                // Blue while unread, as the list shows it, until reading it marks it read.
                Text(senderLine)
                    .font(.system(size: OL.readingSenderFont, weight: .semibold))
                    .foregroundStyle(message.isRead ? OLColor.text : OLColor.unread)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(message.date.formatted(date: .complete, time: .shortened))
                    .font(.system(size: OL.readingSenderFont))
                    .foregroundStyle(OLColor.textMuted)
                    .lineLimit(1)
                    .fixedSize()
                actions
            }
            .frame(minHeight: 24)
            recipients("To:", message.to)
                .padding(.top, 6)
            if !message.cc.isEmpty {
                recipients("Cc:", message.cc)
                    .padding(.top, 3)
            }
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

    private func recipients(_ label: LocalizedStringKey, _ list: [EmailAddress]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(.system(size: OL.readingMetaFont, weight: .semibold))
                .foregroundStyle(OLColor.text)
                .frame(minWidth: 20, alignment: .leading)
            Text(showDetails ? list.map(\.rfc5322).joined(separator: ", ") : list.map(\.displayName).joined(separator: ", "))
                .font(.system(size: OL.readingMetaFont))
                .foregroundStyle(OLColor.textMuted)
                .lineLimit(showDetails ? nil : 1)
                .textSelection(.enabled)
                .padding(.leading, 12)
        }
        .contentShape(Rectangle())
        .onTapGesture { showDetails.toggle() }
        .help(showDetails ? "Click to hide the details" : "Click to see every recipient, the folder and the full date")
    }

    /// Reply, Reply All and Forward on this message, and the rest in a menu, as small as the
    /// header they sit in.
    private var actions: some View {
        HStack(spacing: 0) {
            CardActionButton("Reply", "arrowshape.turn.up.left", tint: OLColor.replyPurple) { act(.reply(all: false)) }
            CardActionButton("Reply All", "arrowshape.turn.up.left.2", tint: OLColor.replyPurple) { act(.reply(all: true)) }
            CardActionButton("Forward", "arrowshape.turn.up.right", tint: OLColor.forwardBlue) { act(.forward) }
            Menu { menu } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(OLColor.icon)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 26, height: 24)
            .help("More actions for this message")
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Reply") { act(.reply(all: false)) }
        Button("Reply All") { act(.reply(all: true)) }
        Button("Forward") { act(.forward) }
        // A message found only on the server has no stored original to attach, save or change.
        Button("Forward as Attachment") { model.forwardAsAttachment([message]) }
            .disabled(message.isServerOnly)
        Divider()
        Group {
            Button(message.isRead ? "Mark as Unread" : "Mark as Read") { model.markRead([message], !message.isRead) }
            Button(message.isFlagged ? "Unflag" : "Flag") { model.setFlagged([message], !message.isFlagged) }
        }
        .disabled(message.isServerOnly)
        Divider()
        Button("Open in Separate Window") { model.showMessageWindow(message.id) { openWindow(value: $0) } }
        Button("Save as .eml…") { MessageFile.saveAsEML(message, model: model) }
            .disabled(message.isServerOnly)
    }

    @ViewBuilder private var messageText: some View {
        if let rendered {
            HTMLView(html: rendered, sender: message.from, onHeight: { bodyHeight = $0 })
                .frame(height: max(bodyHeight, 24))
                .frame(maxWidth: .infinity)
        } else if loading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 48)
        } else {
            VStack(alignment: .leading, spacing: 8) {
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
            .padding(.horizontal, 29)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Folded

    /// Sender, first words and date on one line, the sender blue while it is unread.
    private var foldedLine: some View {
        let avatar: CGFloat = 28
        let avatarX = OL.readingAvatarX + (OL.readingAvatar - avatar) / 2
        return HStack(alignment: .center, spacing: 0) {
            AvatarView(name: message.from.displayName, address: message.from.address, size: avatar)
                .padding(.leading, avatarX)
            Text(message.from.displayName)
                .font(.system(size: OL.readingSenderFont, weight: message.isRead ? .semibold : .bold))
                .foregroundStyle(message.isRead ? OLColor.text : OLColor.unread)
                .lineLimit(1)
                .layoutPriority(1)
                .padding(.leading, OL.readingSenderX - avatarX - avatar)
            Text(ConversationStack.preview(of: message))
                .font(.system(size: OL.readingSenderFont))
                .foregroundStyle(OLColor.textMuted)
                .lineLimit(1)
                .padding(.leading, 10)
            Spacer(minLength: 12)
            Text(message.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: OL.readingMetaFont))
                .foregroundStyle(OLColor.textMuted)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, OL.readingRightInset + 4)
        }
        .frame(height: 44)
        .background(hovering ? OLColor.hover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: toggle)
        .contextMenu { menu }
        .help("Click to show this message")
    }

    // MARK: Loading

    private func load() async {
        if parsed == nil {
            // In the reading pane only the newest waits for the selection to settle; the others
            // opened with it wait as long, so that arrowing past a conversation fetches nothing.
            if message.isServerOnly, context == .pane, openedWithStack, !isNewest, attempt == 0 {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
            }
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

    private func openFromServer() async -> MIMEMessage? {
        let trigger: GmailOpener.Trigger = context == .pane && isNewest && openedWithStack && attempt == 0 ? .selectionMoved : .asked
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
        let whole = showQuoted
        // The first words of the messages below, then the whole of those opened this session:
        // turning a message into words takes time, so it is done here only when needed.
        let snippets = earlier.map(\.snippet)
        let opened = earlier.compactMap { model.openedBody(of: $0) }
        let result = await Task.detached(priority: .userInitiated) {
            let texts = [AnySequence(snippets), AnySequence(opened.lazy.map(\.bestText))].joined()
            let trimmed = QuotedHistory.trimmed(parsed, repeating: texts)
            let shown = whole ? parsed : trimmed ?? parsed
            return (MessageRenderer.html(for: shown, allowRemote: allow, dark: dark, forceOriginal: original, inStack: true),
                    MessageRenderer.hasRemoteImages(shown), trimmed != nil)
        }.value
        rendered = result.0
        hasRemote = result.1
        hasQuote = result.2
    }
}

/// A card's Reply, Reply All or Forward: the ribbon's glyph in its colour, small.
struct CardActionButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    init(_ title: LocalizedStringKey, _ symbol: String, tint: Color, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 26, height: 24)
                .background(hovering ? OLColor.hover : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
    }
}

/// The web view every message is drawn in. On a card of the conversation stack it is as tall as
/// its message and scrolls with the stack: the wheel and the scrolling keys (space, Page Up and
/// Down, Home, End and the up and down arrows) move the stack, and its height is measured again
/// whenever it is loaded or its width changes.
final class ReaderWebView: WKWebView {
    var fitsContent = false {
        didSet {
            guard !fitsContent else { return }
            onHeight = nil
            toldHeight = 0
            afterLoad.forEach { $0.cancel() }
            afterResize.forEach { $0.cancel() }
            afterLoad = []
            afterResize = []
        }
    }
    var onHeight: ((CGFloat) -> Void)?
    /// Whether its page has loaded and been measured; the debug snapshots wait for it.
    private(set) var measured = false
    private var loaded = false
    private var measuredWidth: CGFloat = 0
    /// Measurements to come after a load, and after the width last changed; a new load or a new
    /// width replaces only its own.
    private var afterLoad: [DispatchWorkItem] = []
    private var afterResize: [DispatchWorkItem] = []

    /// The bottom of everything in the page, with the body's own padding under it. It reads
    /// the layout only, and runs although the message's own scripts never do.
    private static let heightScript = """
        (function(){var b=document.body;if(!b)return 0;var r=document.createRange();r.selectNodeContents(b);\
        var s=getComputedStyle(b);return Math.ceil(r.getBoundingClientRect().bottom+window.scrollY\
        +parseFloat(s.paddingBottom||0)+parseFloat(s.marginBottom||0));})()
        """

    /// The height last told through `onHeight`.
    private var toldHeight: CGFloat = 0

    func willLoad() {
        loaded = false
        measured = false
        toldHeight = 0
    }

    /// Measured at once, and again as pictures that take longer come in: a picture from the web
    /// on a slow line can take many seconds, and until it is measured again the end of the
    /// message would be cut off out of reach, since the message does not scroll on its own. A
    /// measurement that finds the height unchanged costs nothing further.
    func didLoad() {
        guard fitsContent else { return }
        loaded = true
        afterLoad.forEach { $0.cancel() }
        afterLoad = measure(after: [0, 0.3, 1, 2.5, 6, 15, 40])
    }

    override func layout() {
        super.layout()
        guard fitsContent, loaded, abs(bounds.width - measuredWidth) > 0.5 else { return }
        measuredWidth = bounds.width
        afterResize.forEach { $0.cancel() }
        afterResize = measure(after: [0.05, 0.4])
    }

    private func measure(after delays: [Double]) -> [DispatchWorkItem] {
        delays.map { delay in
            let work = DispatchWorkItem { [weak self] in self?.measureNow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func measureNow() {
        guard fitsContent else { return }
        measuredWidth = bounds.width
        evaluateJavaScript(Self.heightScript) { [weak self] value, _ in
            guard let self, self.fitsContent, let height = (value as? NSNumber)?.doubleValue, height > 0 else { return }
            self.measured = true
            // Told only of a new height, so that a long conversation is not laid out again for
            // every measurement that finds what the last one did.
            guard CGFloat(height) != self.toldHeight else { return }
            self.toldHeight = CGFloat(height)
            self.onHeight?(CGFloat(height))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard fitsContent, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), let scroll = enclosingScrollView else {
            return super.scrollWheel(with: event)
        }
        // Scrolled over, it is measured again at most once a second, in case something in it
        // grew after the last measurement.
        if loaded, Date().timeIntervalSince(scrolledMeasure) > 1 {
            scrolledMeasure = Date()
            measureNow()
        }
        scroll.scrollWheel(with: event)
    }

    private var scrolledMeasure = Date.distantPast

    override func keyDown(with event: NSEvent) {
        guard fitsContent, let scroll = enclosingScrollView, let y = Self.scrolled(scroll, by: event) else {
            return super.keyDown(with: event)
        }
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Where a scrolling key takes the stack, or nil for any other key.
    private static func scrolled(_ scroll: NSScrollView, by event: NSEvent) -> CGFloat? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let clip = scroll.contentView
        let page = max(clip.bounds.height - 40, 40)
        let line: CGFloat = 40
        let delta: CGFloat
        switch (event.keyCode, flags) {
        case (KeyRouter.Code.space, []): delta = page
        case (KeyRouter.Code.space, [.shift]): delta = -page
        case (121, []): delta = page
        case (116, []): delta = -page
        case (KeyRouter.Code.downArrow, []): delta = line
        case (KeyRouter.Code.upArrow, []): delta = -line
        case (119, []): delta = .greatestFiniteMagnitude
        case (115, []): delta = -.greatestFiniteMagnitude
        default: return nil
        }
        guard let document = scroll.documentView else { return nil }
        let bottom = max(0, document.frame.height - clip.bounds.height)
        let down = document.isFlipped ? clip.bounds.origin.y : bottom - clip.bounds.origin.y
        let moved = min(max(down + delta, 0), bottom)
        return document.isFlipped ? moved : bottom - moved
    }
}

extension AppModel {
    /// The messages of the conversation a window or tab was opened for, the newest as given and
    /// the others read again, from this Mac or from the search that found them; those gone since
    /// are left out.
    func conversationMessages(_ ids: [String], newest: MessageSummary) async -> [MessageSummary] {
        var list: [MessageSummary] = []
        for id in ids {
            if id == newest.id {
                list.append(newest)
            } else if let found = await message(id: id) {
                list.append(found)
            }
        }
        return list
    }
}
