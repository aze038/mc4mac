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

    @State private var parsed: MIMEMessage?
    @State private var rendered: String?
    @State private var loading = false
    @State private var allowRemoteImages = false
    @State private var hasRemote = false
    @State private var showDetails = false
    @State private var originalColours = false
    @Environment(\.colorScheme) private var colorScheme

    private var renderKey: String { "\(message.id)|\(allowRemoteImages)|\(model.loadRemoteImages)|\(originalColours)|\(colorScheme == .dark)" }

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
                Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .font(.system(size: OL.readingSubjectFont, weight: .semibold))
                    .foregroundStyle(OLColor.text)
                    .lineLimit(1)
                    .textSelection(.enabled)
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
            .frame(height: OL.readingAvatarTop, alignment: .top)
            .contextMenu { moreMenu }
            HStack(alignment: .top, spacing: 0) {
                AvatarView(name: message.from.displayName, address: message.from.address, size: OL.readingAvatar)
                    .padding(.leading, OL.readingAvatarX)
                senderBlock
                    .padding(.leading, OL.readingSenderX - OL.readingAvatarX - OL.readingAvatar)
                    .padding(.trailing, OL.readingRightInset)
            }
            conversationHint
            if let parsed, !parsed.attachments.isEmpty {
                AttachmentStrip(attachments: parsed.attachments, html: parsed.textHTML, accountID: message.accountID)
                    .padding(.horizontal, OL.readingBodyX)
                    .padding(.top, 10)
            }
            if !model.loadRemoteImages && !allowRemoteImages && hasRemote {
                RemoteImagesBanner(loadOnce: { allowRemoteImages = true }, loadAlways: { model.loadRemoteImages = true })
                    .padding(.horizontal, OL.readingBodyX)
                    .padding(.top, 10)
            }
        }
        .padding(.bottom, 12)
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
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("To:")
                    .font(.system(size: OL.readingMetaFont, weight: .semibold))
                    .foregroundStyle(OLColor.text)
                Text(recipientLine(message.to))
                    .font(.system(size: OL.readingMetaFont))
                    .foregroundStyle(OLColor.textMuted)
                    .lineLimit(showDetails ? nil : 1)
                    .textSelection(.enabled)
                    .padding(.leading, 16)
            }
            .padding(.top, 12)
            .contentShape(Rectangle())
            .onTapGesture { showDetails.toggle() }
            .help(showDetails ? "Click to hide the details" : "Click to see every recipient, the folder and the full date")
            if showDetails {
                VStack(alignment: .leading, spacing: 4) {
                    if !message.cc.isEmpty {
                        Text("Cc: " + recipientLine(message.cc))
                    }
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

    private func recipientLine(_ list: [EmailAddress]) -> String {
        showDetails ? list.map { $0.rfc5322 }.joined(separator: ", ") : list.map { $0.displayName }.joined(separator: ", ")
    }

    private var actions: some View {
        HStack(spacing: 2) {
            ReaderActionButton("Reply", "arrowshape.turn.up.left") { reply(all: false) }
            ReaderActionButton("Reply All", "arrowshape.turn.up.left.2") { reply(all: true) }
            ReaderActionButton("Forward", "arrowshape.turn.up.right") { forward() }
            ReaderActionButton(message.isFlagged ? "Unflag" : "Flag", message.isFlagged ? "flag.fill" : "flag") { model.setFlagged([message], !message.isFlagged) }
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
        Button("Forward as Attachment") { model.forwardAsAttachment([message]) }
        Divider()
        Button("Archive") { model.archive([message]); onDidAct?() }
        Button("Delete") { model.delete([message]); onDidAct?() }
        Button(message.isFlagged ? "Unflag" : "Flag") { model.setFlagged([message], !message.isFlagged) }
        Button(message.isRead ? "Mark as Unread" : "Mark as Read") { model.markRead([message], !message.isRead) }
        if context == .pane {
            Button("Move to Folder…") { model.openMovePalette() }
        }
        Button(model.isInJunk([message]) ? "Not Junk" : "Move to Junk") { model.toggleJunk([message]) }
        Button(model.isMuted(thread) ? "Unmute Conversation" : "Mute Conversation") { model.toggleMute(thread) }
        Divider()
        if context != .tab { Button("Open in Tab") { model.openMessageTab(message) } }
        if context != .window { Button("Open in Separate Window") { openWindow(value: message.id) } }
        Divider()
        Button("Save as .eml…") { saveAsEML() }
    }

    private var thread: MessageThread { conversation ?? MessageThread(messages: [message]) }

    /// Outlook's grey notice band under the header, here for a folded conversation.
    @ViewBuilder private var conversationHint: some View {
        if let conversation, conversation.messages.count > 1, !model.isExpanded(conversation), context == .pane {
            HStack(spacing: 0) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 11))
                    .foregroundStyle(OLColor.replyPurple)
                    .frame(width: 16, height: 16)
                    .padding(.leading, 6)
                Text("\(conversation.messages.count) messages in this conversation. Showing the latest.")
                    .font(.system(size: OL.readingMetaFont))
                    .foregroundStyle(OLColor.text)
                    .lineLimit(1)
                    .padding(.leading, 8.5)
                Spacer(minLength: 8)
                Button { model.expand(conversation) } label: {
                    Text("Show All")
                        .font(.system(size: 11))
                        .foregroundStyle(OLColor.text)
                        .padding(.horizontal, 8)
                        .frame(height: 16)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(OLColor.buttonBorder, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
            }
            .frame(height: OL.readingNotice)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OLColor.notice)
            .padding(.top, 19)
        }
    }

    @ViewBuilder private var content: some View {
        if let rendered {
            HTMLView(html: rendered, sender: message.from)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OLColor.reading)
        } else if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                Text(message.snippet).foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func load() async {
        if parsed == nil {
            loading = true
            parsed = await model.parsedBody(for: message)
            loading = false
        }
        guard let parsed else { return }
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
        guard let account = model.account(for: message) else { return }
        Task {
            let parsed = await model.parsedBody(for: message)
            model.openCompose(.reply(to: message, parsed: parsed, account: account, all: all,
                                     signature: model.signature(for: account, .replies)))
        }
    }

    private func forward() {
        guard let account = model.account(for: message) else { return }
        Task {
            let parsed = await model.parsedBody(for: message)
            model.openCompose(.forward(message, parsed: parsed, account: account, signature: model.signature(for: account, .replies)))
        }
    }

    private func saveAsEML() {
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
/// a Message ribbon, then the message.
struct MessageWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let messageID: String
    @State private var message: MessageSummary?

    var body: some View {
        Group {
            if let message {
                VStack(spacing: 0) {
                    titleRow(message)
                    MessageWindowRibbon(message: message, close: { dismiss() })
                    Rectangle().fill(OLColor.chromeLine).frame(height: 1)
                    MessageReaderView(message: message, context: .window)
                }
                .background(OLColor.reading)
                .navigationTitle(message.subject.isEmpty ? "Message" : message.subject)
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(PopupWindowAccessor())
        .task { message = try? await model.store.message(id: messageID) }
        .onAppear { model.openMessageWindows.insert(messageID) }
        .onDisappear { model.openMessageWindows.remove(messageID) }
        .ignoresSafeArea(.container, edges: .top)
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
                RibbonQuickButton(symbol: "square.and.arrow.down", title: "Save as .eml") { NotificationCenter.default.post(name: .falconExport, object: nil) }
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

/// The ribbon of an opened message: Outlook's Message tab, the same tiles as the Home ribbon
/// that act on one message.
struct MessageWindowRibbon: View {
    @Environment(AppModel.self) private var model
    let message: MessageSummary
    let close: () -> Void
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            RibbonTabStrip(tabs: [(0, "Message")], selection: $tab)
                .padding(.horizontal, OL.tabInset)
            RibbonBody {
                RibbonTile(title: "Delete", symbol: "trash") { model.delete([message]); close() }
                RibbonTile(title: "Archive", symbol: "archivebox", tint: OLColor.archiveGreen) { model.archive([message]); close() }
                RibbonSeparator()
                RibbonTile(title: "Reply", symbol: "arrowshape.turn.up.left", tint: OLColor.replyPurple) { reply(all: false) }
                RibbonTile(title: "Reply\nto All", symbol: "arrowshape.turn.up.left.2", tint: OLColor.replyPurple) { reply(all: true) }
                RibbonTile(title: "Forward", symbol: "arrowshape.turn.up.right", tint: OLColor.forwardBlue) { forward() }
                RibbonMiniColumn {
                    RibbonMiniItem(title: "Meeting", symbol: "calendar.badge.plus") {
                        model.showModule(.calendar)
                        NotificationCenter.default.post(name: .falconNewMeeting, object: nil)
                    }
                    RibbonMiniItem(title: "Attachment", symbol: "paperclip") { model.forwardAsAttachment([message]) }
                }
                RibbonSeparator()
                RibbonSplitTile(title: "Move", symbol: "arrow.down.to.line.compact", tint: OLColor.forwardBlue, action: { model.openMovePalette() }) {
                    Button("Move to Folder…") { model.openMovePalette() }
                    Button("Archive") { model.archive([message]); close() }
                }
                RibbonSplitTile(title: "Junk", symbol: "person.crop.circle.badge.xmark", tint: OLColor.junkRed, action: { model.toggleJunk([message]) }) {
                    Button(model.isInJunk([message]) ? "Not Junk" : "Move to Junk") { model.toggleJunk([message]) }
                }
                RibbonMenuTile(title: "Rules", symbol: "envelope.open.badge.clock") {
                    Button("Run Rules Now") { model.runRulesNow() }
                }
                RibbonSeparator()
                RibbonTile(title: "Read/Unread", symbol: message.isRead ? "envelope" : "envelope.open") { model.markRead([message], !message.isRead) }
                RibbonMenuTile(title: "Categorise", symbol: "square.grid.2x2", tint: OLColor.categoryOrange) {
                    ForEach(model.categories) { category in
                        Button(category.name) { model.toggleCategory(category, on: [message]) }
                    }
                }
                RibbonSplitTile(title: "Follow\nUp", symbol: "flag", tint: OLColor.flagRed, action: { model.setFlagged([message], !message.isFlagged) }) {
                    Button(message.isFlagged ? "Clear Flag" : "Flag Message") { model.setFlagged([message], !message.isFlagged) }
                }
            }
        }
        .background(OLColor.chrome, ignoresSafeAreaEdges: [])
    }

    private func reply(all: Bool) {
        guard let account = model.account(for: message) else { return }
        Task {
            let parsed = await model.parsedBody(for: message)
            model.openCompose(.reply(to: message, parsed: parsed, account: account, all: all,
                                     signature: model.signature(for: account, .replies)))
        }
    }

    private func forward() {
        guard let account = model.account(for: message) else { return }
        Task {
            let parsed = await model.parsedBody(for: message)
            model.openCompose(.forward(message, parsed: parsed, account: account, signature: model.signature(for: account, .replies)))
        }
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

    static func html(for parsed: MIMEMessage, allowRemote: Bool, dark: Bool, forceOriginal: Bool) -> String {
        let csp = allowRemote
            ? "default-src 'none'; img-src * data: cid: blob:; style-src 'unsafe-inline' *; font-src *;"
            : "default-src 'none'; img-src data:; style-src 'unsafe-inline';"
        // Outlook puts every message on its own ground and leaves the message's colours to the
        // sun switch; a message that paints its own canvas is not an exception.
        let ownCanvas = forceOriginal
        // In dark appearance the message is laid out in its own light colours and the whole page
        // is then inverted, pictures inverted back: black text on white becomes Outlook's light
        // grey on #1e1e1e, and a message that hard-codes its colours stays readable. The sun
        // switch shows it un-inverted, as it was written.
        let inverted = dark && !ownCanvas
        let background = "#ffffff"
        let text = "#1d1d1f"
        let quote = "#1d1d1f"
        let rule = "#333333"
        let link = "#0a66c2"
        let inversion = inverted
            ? " html{filter:invert(0.885) hue-rotate(180deg);} img,video,canvas,svg,picture{filter:invert(1) hue-rotate(180deg);}"
            : ""
        let style = "<style>:root{color-scheme:light;} html,body{background:\(background);margin:0;}\(inversion) body{font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.2;color:\(text);padding:12px 29px 30px 29px;word-wrap:break-word;overflow-wrap:anywhere;} p{margin:0 0 16px;} pre{white-space:pre-wrap;font-family:inherit;} img{max-width:100%;height:auto;} table{max-width:100%;} blockquote{border-left:1px solid \(rule);margin:0 0 0 4px;padding-left:6px;color:\(quote);} a{color:\(link);}</style>"
        let head = "<meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">\(style)"
        var body: String
        if let html = parsed.textHTML, !html.trimmed.isEmpty {
            body = html
            for a in parsed.attachments {
                guard let cid = a.contentID else { continue }
                let dataURL = "data:\(a.mimeType);base64,\(a.data.base64EncodedString())"
                body = body.replacingOccurrences(of: "cid:\(cid)", with: dataURL, options: .caseInsensitive)
            }
            body = body.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: "", options: .regularExpression)
        } else {
            body = "<pre>" + HTMLLinkify.escapeAndLink(parsed.textPlain ?? "") + "</pre>"
        }
        if let range = body.range(of: "<head>", options: .caseInsensitive) {
            body.insert(contentsOf: head, at: range.upperBound)
            return body
        }
        return "<html><head>\(head)</head><body>\(body)</body></html>"
    }
}

@MainActor
enum WebViewPool {
    private static var free: [WKWebView] = []
    private static let processPool = WKProcessPool()

    static func acquire() -> WKWebView {
        if let v = free.popLast() { return v }
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.underPageBackgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: 0x1E1E1E) : .white
        }
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    static func release(_ view: WKWebView) {
        view.navigationDelegate = nil
        view.loadHTMLString("", baseURL: nil)
        if free.count < 4 { free.append(view) }
    }
}

struct HTMLView: NSViewRepresentable {
    let html: String
    var sender: EmailAddress? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = MainActor.assumeIsolated { WebViewPool.acquire() }
        view.navigationDelegate = context.coordinator
        context.coordinator.lastHTML = ""
        context.coordinator.sender = sender
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.sender = sender
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        MainActor.assumeIsolated { WebViewPool.release(view) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""
        var sender: EmailAddress?

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
