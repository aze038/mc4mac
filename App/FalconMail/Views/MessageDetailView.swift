import SwiftUI
import AppKit
import WebKit
import FalconCore

struct MessageDetailView: View {
    @EnvironmentObject var model: AppModel
    let thread: MessageThread

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(thread.latest.subject.isEmpty ? "(no subject)" : thread.latest.subject)
                    .font(.title3.bold())
                    .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                ForEach(Array(thread.messages.reversed().enumerated()), id: \.element.id) { index, message in
                    MessageCard(message: message, expanded: index == thread.messages.count - 1 || thread.messages.count == 1)
                    Divider()
                }
            }
        }
        .id(thread.id)
    }
}

struct MessageCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let message: MessageSummary
    @State var expanded: Bool
    @State private var parsed: MIMEMessage?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.from.displayName).font(.headline)
                    if !message.from.name.isEmpty { Text(message.from.address).font(.caption).foregroundStyle(.secondary) }
                    if expanded {
                        Text("To: " + message.to.map { $0.displayName }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        if !message.cc.isEmpty { Text("Cc: " + message.cc.map { $0.displayName }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
                Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            .contextMenu {
                Button("Open in New Window") { openWindow(value: message.id) }
            }
            if expanded {
                if let parsed {
                    if !parsed.attachments.isEmpty { AttachmentStrip(attachments: parsed.attachments) }
                    HTMLView(html: MessageRenderer.html(for: parsed, allowRemote: model.loadRemoteImages))
                        .frame(minHeight: 200)
                } else if loading {
                    ProgressView().padding()
                } else {
                    Text(message.snippet).foregroundStyle(.secondary)
                }
            } else {
                Text(message.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .task(id: expanded) {
            guard expanded, parsed == nil else { return }
            loading = true
            parsed = await model.parsedBody(for: message)
            loading = false
        }
    }
}

struct MessageWindowView: View {
    @EnvironmentObject var model: AppModel
    let messageID: String
    @State private var message: MessageSummary?

    var body: some View {
        Group {
            if let message {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                            .font(.title3.bold())
                            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                        MessageCard(message: message, expanded: true)
                    }
                }
                .navigationTitle(message.subject.isEmpty ? "Message" : message.subject)
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .task { message = try? await model.store.message(id: messageID) }
    }
}

struct AttachmentStrip: View {
    let attachments: [MIMEAttachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments.filter { !$0.isInline || $0.contentID == nil }) { a in
                    Button {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = a.filename
                        if panel.runModal() == .OK, let url = panel.url { try? a.data.write(to: url) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc")
                            VStack(alignment: .leading) {
                                Text(a.filename).font(.caption).lineLimit(1)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(6)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .onDrag { AttachmentTempFiles.itemProvider(filename: a.filename, data: a.data) }
                    .help("Drag into a compose window or onto the Desktop")
                }
            }
        }
    }
}

enum MessageRenderer {
    static func html(for parsed: MIMEMessage, allowRemote: Bool) -> String {
        let csp = allowRemote
            ? "default-src 'none'; img-src * data: cid:; style-src 'unsafe-inline'; font-src *;"
            : "default-src 'none'; img-src data:; style-src 'unsafe-inline';"
        let style = "<style>body{font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px;line-height:1.45;color:-apple-system-label;margin:0;padding:4px 0;word-wrap:break-word;} pre{white-space:pre-wrap;font-family:inherit;} img{max-width:100%;height:auto;} blockquote{border-left:2px solid #ccc;margin:0;padding-left:10px;color:#666;} a{color:#0a66c2;}</style>"
        let head = "<meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">\(style)"
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

struct HTMLView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            view.loadHTMLString(html, baseURL: nil)
        }
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
