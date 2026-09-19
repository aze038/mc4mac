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

    private var renderKey: String { "\(message.id)|\(allowRemoteImages)|\(model.loadRemoteImages)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: renderKey) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                .font(.system(size: 20, weight: .semibold))
                .textSelection(.enabled)
            HStack(alignment: .top, spacing: 12) {
                AvatarView(name: message.from.displayName, address: message.from.address, size: 40)
                senderBlock
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(message.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    actions
                }
            }
            conversationHint
            if let parsed, !parsed.attachments.isEmpty { AttachmentStrip(attachments: parsed.attachments, html: parsed.textHTML) }
            if !model.loadRemoteImages && !allowRemoteImages && hasRemote {
                RemoteImagesBanner(loadOnce: { allowRemoteImages = true }, loadAlways: { model.loadRemoteImages = true })
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var senderBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.from.displayName).font(.system(size: 14, weight: .semibold))
            if !message.from.name.isEmpty {
                Text(message.from.address).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 4) {
                Text("To: " + recipientLine(message.to))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(showDetails ? nil : 1)
                Button(showDetails ? "Hide" : "Details") { showDetails.toggle() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            if showDetails {
                if !message.cc.isEmpty {
                    Text("Cc: " + recipientLine(message.cc)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text(message.date.formatted(date: .complete, time: .standard)).font(.system(size: 12)).foregroundStyle(.secondary)
                if let folder = model.folder(message.folderID) {
                    Text("Folder: " + folder.path).font(.system(size: 12)).foregroundStyle(.secondary)
                }
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

    @ViewBuilder private var conversationHint: some View {
        if let conversation, conversation.messages.count > 1, !model.isExpanded(conversation), context == .pane {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                Text("\(conversation.messages.count) messages in this conversation. Showing the latest.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Show all") { model.expand(conversation) }.buttonStyle(.link).font(.system(size: 12))
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder private var content: some View {
        if let rendered {
            HTMLView(html: rendered)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
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
        let result = await Task.detached(priority: .userInitiated) {
            (MessageRenderer.html(for: parsed, allowRemote: allow), MessageRenderer.hasRemoteImages(parsed))
        }.value
        rendered = result.0
        hasRemote = result.1
    }

    private func reply(all: Bool) {
        guard let account = model.account(for: message) else { return }
        Task {
            let parsed = await model.parsedBody(for: message)
            model.openCompose(.reply(to: message, parsed: parsed, account: account, all: all))
        }
    }

    private func forward() {
        guard let account = model.account(for: message) else { return }
        Task {
            let parsed = await model.parsedBody(for: message)
            model.openCompose(.forward(message, parsed: parsed, account: account))
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

struct MessageWindowView: View {
    @Environment(AppModel.self) private var model
    let messageID: String
    @State private var message: MessageSummary?

    var body: some View {
        Group {
            if let message {
                MessageReaderView(message: message, context: .window)
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

    static func html(for parsed: MIMEMessage, allowRemote: Bool) -> String {
        let csp = allowRemote
            ? "default-src 'none'; img-src * data: cid: blob:; style-src 'unsafe-inline' *; font-src *;"
            : "default-src 'none'; img-src data:; style-src 'unsafe-inline';"
        let style = "<style>:root{color-scheme:light;} html,body{background:#ffffff;margin:0;} body{font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px;line-height:1.5;color:#1d1d1f;padding:16px 22px 28px 22px;word-wrap:break-word;overflow-wrap:anywhere;} pre{white-space:pre-wrap;font-family:inherit;} img{max-width:100%;height:auto;} table{max-width:100%;} blockquote{border-left:2px solid #c7c7cc;margin:0;padding-left:10px;color:#3a3a3c;} a{color:#0a66c2;}</style>"
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
            body = "<pre>" + HTMLText.escape(parsed.textPlain ?? "") + "</pre>"
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
        view.underPageBackgroundColor = .white
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = MainActor.assumeIsolated { WebViewPool.acquire() }
        view.navigationDelegate = context.coordinator
        context.coordinator.lastHTML = ""
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
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

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
