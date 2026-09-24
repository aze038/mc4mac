import SwiftUI
import AppKit
import FalconCore

struct SettingsRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 190
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .frame(width: labelWidth, alignment: .trailing)
            VStack(alignment: .leading, spacing: 7) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content() }
                .padding(.horizontal, 22)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.theme) private var theme = AccentTheme.blue.rawValue
    @AppStorage(Pref.transparency) private var transparency = true
    @AppStorage(Pref.textSize) private var textSize = 0
    @AppStorage(Pref.showAllAccountFolders) private var showAllFolders = true
    @AppStorage(Pref.hideLocalFolders) private var hideLocal = false
    @AppStorage(Pref.allowFolderReordering) private var allowReordering = true

    var body: some View {
        @Bindable var model = model
        return SettingsScroll {
            Text("Appearance settings apply to every account in this profile.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            Text(AccentTheme(rawValue: theme)?.title ?? "Blue (default)")
                .font(.system(size: 13))
                .padding(.leading, 202)

            SettingsRow(label: "Appearance:") {
                HStack(spacing: 18) {
                    ForEach(AppAppearance.allCases) { mode in
                        AppearanceCard(mode: mode, selected: model.appearance == mode.rawValue) {
                            model.appearance = mode.rawValue
                            AppAppearance.apply(mode.rawValue)
                        }
                    }
                }
            }

            SettingsRow(label: "Theme:") {
                HStack(spacing: 10) {
                    ForEach(AccentTheme.allCases) { item in
                        Button { theme = item.rawValue } label: {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(item.colour)
                                .frame(width: 58, height: 34)
                                .overlay {
                                    if theme == item.rawValue {
                                        Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(item.title)
                    }
                }
            }

            SettingsRow(label: "Transparency:") {
                Toggle("Blur the ribbon over the window behind", isOn: $transparency)
            }

            Divider()

            SettingsRow(label: "Density preference:") {
                HStack(spacing: 18) {
                    ForEach(ListDensity.allCases) { density in
                        DensityCard(density: density, selected: model.listDensity == density) {
                            model.listDensity = density
                        }
                    }
                }
            }

            SettingsRow(label: "Text display size:") {
                HStack(spacing: 10) {
                    Stepper(value: $textSize, in: -2...4) { EmptyView() }.labelsHidden()
                    Text(textSize == 0 ? "Default" : (textSize > 0 ? "Larger \(textSize)" : "Smaller \(-textSize)"))
                        .font(.system(size: 13))
                }
            }

            Divider()

            SettingsRow(label: "Sidebar:") {
                Toggle("Show all email account folders", isOn: $showAllFolders)
                Toggle("Hide On My Computer folders", isOn: $hideLocal)
                Toggle("Allow folder reordering", isOn: $allowReordering)
            }

            // Outlook leaves the Dock's badge to macOS; FalconMail draws its own, so whether to
            // show it at all is kept here, next to the rest of how the app looks.
            SettingsRow(label: "Dock:") {
                Toggle("Show unread count in the Dock", isOn: $model.dockBadge)
            }

            Divider()

            SearchSettingsRows()

            Divider()

            UpdateSettingsRows()
        }
    }
}

struct AppearanceCard: View {
    let mode: AppAppearance
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                preview
                    .frame(width: 96, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: selected ? 2.5 : 1))
                Text(mode.title).font(.system(size: 12))
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var preview: some View {
        switch mode {
        case .light: miniature(background: Color.white, panel: Color(white: 0.93), text: Color(white: 0.55))
        case .dark: miniature(background: Color(white: 0.16), panel: Color(white: 0.24), text: Color(white: 0.5))
        case .system:
            HStack(spacing: 0) {
                miniature(background: Color.white, panel: Color(white: 0.93), text: Color(white: 0.55)).frame(width: 48)
                miniature(background: Color(white: 0.16), panel: Color(white: 0.24), text: Color(white: 0.5)).frame(width: 48)
            }
        }
    }

    private func miniature(background: Color, panel: Color, text: Color) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.accentColor).frame(height: 12)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(text.opacity(0.7)).frame(width: 20, height: 3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(5)
                .background(panel)
                Rectangle().fill(background).frame(maxWidth: .infinity)
            }
        }
    }
}

struct DensityCard: View {
    let density: ListDensity
    let selected: Bool
    let action: () -> Void

    private var rows: Int {
        switch density {
        case .roomy: return 2
        case .cozy: return 3
        case .compact: return 4
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                VStack(spacing: 5) {
                    ForEach(0..<rows, id: \.self) { _ in
                        Capsule().fill(Color.secondary.opacity(0.55)).frame(height: density == .roomy ? 13 : (density == .cozy ? 9 : 7))
                    }
                }
                .padding(8)
                .frame(width: 104, height: 72)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: selected ? 2.5 : 1))
                Text(density.title).font(.system(size: 12))
            }
        }
        .buttonStyle(.plain)
    }
}

struct ReadingSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.showPreview) private var showPreview = true
    @AppStorage(Pref.showSenderImage) private var showSenderImage = true
    @AppStorage(Pref.showEventRSVP) private var showRSVP = true
    @AppStorage(Pref.showGroupHeaders) private var showGroupHeaders = true
    @AppStorage(Pref.focusedInbox) private var focusedInbox = false
    @AppStorage(Pref.autoExpandConversation) private var autoExpand = true
    @AppStorage(Pref.showSentInConversations) private var showSent = true
    @AppStorage(Pref.leftSwipe) private var leftSwipe = SwipeAction.archive.rawValue
    @AppStorage(Pref.rightSwipe) private var rightSwipe = SwipeAction.none.rawValue
    @AppStorage(Pref.openInOfficeApps) private var openInOffice = false
    @AppStorage(Pref.quickActions) private var quickActions = QuickAction.defaults

    var body: some View {
        @Bindable var model = model
        return SettingsScroll {
            SettingsRow(label: "Message list:") {
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 7) {
                        Toggle("Show message preview", isOn: $showPreview)
                        Toggle("Show sender image", isOn: $showSenderImage)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Toggle("Show event RSVP", isOn: $showRSVP)
                        Toggle("Show group headers", isOn: Binding(get: { model.showInGroups }, set: { model.showInGroups = $0; showGroupHeaders = $0 }))
                    }
                }
            }

            Divider()

            SettingsRow(label: "Focused Inbox:") {
                Toggle("Sort Messages into Focused and Other", isOn: $focusedInbox)
            }

            SettingsRow(label: "Conversations:") {
                Toggle("Show email grouped by conversation", isOn: $model.groupByThread)
                Toggle("Automatically expand a conversation when selected", isOn: $autoExpand)
                Toggle("Show sent messages in conversations", isOn: $showSent)
            }

            Divider()

            SettingsRow(label: "Left swipe:") {
                Picker("", selection: $leftSwipe) {
                    ForEach(SwipeAction.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 220)
            }
            SettingsRow(label: "Right swipe:") {
                Picker("", selection: $rightSwipe) {
                    ForEach(SwipeAction.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 220)
            }

            Divider()

            SettingsRow(label: "Mark email as read:") {
                Picker("", selection: $model.markReadPolicy) {
                    ForEach(MarkReadPolicy.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                if model.markReadPolicy == MarkReadPolicy.delay.rawValue {
                    HStack(spacing: 8) {
                        Text("Wait").font(.system(size: 13))
                        Picker("", selection: $model.markReadDelaySeconds) {
                            ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0)").tag($0) }
                        }
                        .labelsHidden().frame(width: 70)
                        Text("seconds").font(.system(size: 13))
                    }
                }
                Picker("After archiving, deleting or moving", selection: $model.advanceAfterAction) {
                    ForEach(AdvanceAfterAction.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .frame(width: 420)
            }

            Divider()

            SettingsRow(label: "Download external images:") {
                Picker("", selection: Binding(get: { model.loadRemoteImages }, set: { model.loadRemoteImages = $0 })) {
                    Text("Ask before downloading").tag(false)
                    Text("Download automatically").tag(true)
                }
                .labelsHidden().frame(width: 300)
            }

            SettingsRow(label: "Attachments:") {
                Toggle("Open files in their usual app whenever possible", isOn: $openInOffice)
            }

            Divider()

            SettingsRow(label: "Quick Actions:") {
                QuickActionPreview(selected: QuickAction.enabled())
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 7) {
                    ForEach(QuickAction.allCases) { action in
                        Toggle(isOn: Binding(
                            get: { quickActions.split(separator: ",").contains(Substring(action.rawValue)) },
                            set: { on in
                                var list = quickActions.split(separator: ",").map(String.init)
                                if on { if !list.contains(action.rawValue) { list.append(action.rawValue) } }
                                else { list.removeAll { $0 == action.rawValue } }
                                quickActions = list.joined(separator: ",")
                            })) {
                            Label(action.title, systemImage: action.symbol)
                        }
                    }
                }
                .frame(width: 460)
            }
        }
    }
}

struct QuickActionPreview: View {
    let selected: [QuickAction]

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.secondary.opacity(0.4)).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 80, height: 6)
                Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 150, height: 6)
                Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 110, height: 6)
            }
            Spacer()
            ForEach(selected) { action in
                Image(systemName: action.symbol).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: 440)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ComposingSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.indentOriginal) private var indentOriginal = false
    @AppStorage(Pref.attributionMode) private var attribution = AttributionMode.standard.rawValue
    @AppStorage(Pref.attributionFormat) private var attributionFormat = "On [DATE], \"[NAME]\" <[ADDRESS]> wrote:"
    @AppStorage(Pref.replyUsesOriginalFormat) private var replyUsesOriginal = true
    @AppStorage(Pref.closeOriginalAfterReply) private var closeOriginal = true
    @AppStorage(Pref.autoCopySelf) private var autoCopySelf = false
    @AppStorage(Pref.autoCopyMode) private var autoCopyMode = "bcc"
    @AppStorage(Pref.showCcByDefault) private var showCc = false
    @AppStorage(Pref.showBccByDefault) private var showBcc = false
    @AppStorage(Pref.replyToSelectedText) private var replyToSelection = false
    @AppStorage(Pref.composeInWindow) private var composeInWindow = true

    var body: some View {
        @Bindable var model = model
        return SettingsScroll {
            SettingsRow(label: "Replies and Forwards:") {
                Toggle("Indent each line of the original message", isOn: $indentOriginal)
            }

            SettingsRow(label: "Attribution of original message:") {
                Picker("", selection: $attribution) {
                    ForEach(AttributionMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                TextField("", text: $attributionFormat)
                    .frame(width: 420)
                    .disabled(attribution != AttributionMode.custom.rawValue)
                Text("Use [DATE], [NAME] and [ADDRESS] where the details of the original sender belong.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            SettingsRow(label: "Undo Send:") {
                Text("You can cancel a message after you have selected Send.").font(.system(size: 13))
                HStack(spacing: 8) {
                    Text("Wait to send messages for").font(.system(size: 13))
                    Stepper(value: $model.undoSendSeconds, in: 0...60, step: 5) { EmptyView() }.labelsHidden()
                    Text("\(model.undoSendSeconds) seconds").font(.system(size: 13))
                }
            }

            Divider()

            SettingsRow(label: "Format:") {
                Toggle("When replying or forwarding, use the format of the original message", isOn: $replyUsesOriginal)
                Toggle("Close the original message window after replying or forwarding", isOn: $closeOriginal)
                HStack(spacing: 8) {
                    Toggle("When sending messages, automatically Cc or Bcc myself", isOn: $autoCopySelf)
                    Picker("", selection: $autoCopyMode) {
                        Text("CC").tag("cc")
                        Text("BCC").tag("bcc")
                    }
                    .labelsHidden().frame(width: 80).disabled(!autoCopySelf)
                }
                Toggle("Show CC field by default", isOn: $showCc)
                Toggle("Show BCC field by default", isOn: $showBcc)
                Toggle("Only reply to selected text", isOn: $replyToSelection)
                Toggle("Open new messages and replies in a separate window", isOn: $composeInWindow)
            }
        }
    }
}

struct CategoriesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selected: MailCategory?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(Color.accentColor).frame(width: 26, height: 26)
                        .overlay(Text("OM").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                    Text("On my Computer").font(.system(size: 13))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.08))
                Spacer()
            }
            .frame(width: 240)

            VStack(spacing: 0) {
                Table(model.categories, selection: Binding(get: { selected?.id }, set: { id in selected = model.categories.first { $0.id == id } })) {
                    TableColumn("Colour") { category in
                        Image(systemName: "tag.fill").foregroundStyle(category.swatch)
                    }
                    .width(60)
                    TableColumn("Name") { category in
                        Text(category.name)
                    }
                }
                HStack(spacing: 0) {
                    Button { add() } label: { Image(systemName: "plus").frame(width: 26, height: 20) }
                    Divider().frame(height: 14)
                    Button { remove() } label: { Image(systemName: "minus").frame(width: 26, height: 20) }
                        .disabled(selected == nil)
                    Divider().frame(height: 14)
                    if let selected {
                        Picker("", selection: Binding(get: { selected.colour }, set: { recolour(selected, $0) })) {
                            ForEach(MailCategory.palette, id: \.self) { name in
                                Text(name.capitalized).tag(name)
                            }
                        }
                        .labelsHidden().frame(width: 130)
                    }
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
                .background(Color.primary.opacity(0.05))
            }
        }
    }

    private func add() {
        var list = model.categories
        var name = "New Category"
        var suffix = 2
        while list.contains(where: { $0.name == name }) {
            name = "New Category \(suffix)"
            suffix += 1
        }
        list.append(MailCategory(name: name, colour: MailCategory.palette.randomElement() ?? "blue"))
        model.categories = list
    }

    private func remove() {
        guard let selected else { return }
        model.categories = model.categories.filter { $0.id != selected.id }
        self.selected = nil
    }

    private func recolour(_ category: MailCategory, _ colour: String) {
        guard let index = model.categories.firstIndex(where: { $0.id == category.id }) else { return }
        var list = model.categories
        list[index].colour = colour
        model.categories = list
        selected = list[index]
    }
}

struct FontsSettings: View {
    @AppStorage("composeFontFamily") private var composeFamily = "System"
    @AppStorage("composeFontSize") private var composeSize = 14.0
    @AppStorage("readingFontFamily") private var readingFamily = "System"
    @AppStorage("readingFontSize") private var readingSize = 14.0
    @AppStorage("listFontSize") private var listSize = 13.0

    var body: some View {
        SettingsScroll {
            SettingsRow(label: "New messages:") {
                fontPair(family: $composeFamily, size: $composeSize)
                sample(family: composeFamily, size: composeSize)
            }
            Divider()
            SettingsRow(label: "Reading messages:") {
                fontPair(family: $readingFamily, size: $readingSize)
                sample(family: readingFamily, size: readingSize)
                Text("Plain text messages use this font. Messages that carry their own formatting keep it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            SettingsRow(label: "Message list:") {
                HStack(spacing: 8) {
                    Stepper(value: $listSize, in: 10...20, step: 1) { EmptyView() }.labelsHidden()
                    Text("\(Int(listSize)) point").font(.system(size: 13))
                }
            }
        }
    }

    private func fontPair(family: Binding<String>, size: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: family) {
                ForEach(TextFormatter.families, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 200)
            Picker("", selection: size) {
                ForEach(TextFormatter.sizes, id: \.self) { Text("\(Int($0))").tag(Double($0)) }
            }
            .labelsHidden().frame(width: 80)
        }
    }

    private func sample(family: String, size: Double) -> some View {
        Text("The quick brown fox jumps over the lazy dog.")
            .font(family == "System" ? .system(size: size) : .custom(family, size: size))
            .padding(8)
            .frame(width: 420, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct AutoCorrectSettings: View {
    enum Tab: String, CaseIterable, Identifiable {
        case correct, format, completion
        var id: String { rawValue }
        var title: String {
            switch self {
            case .correct: return "Auto-correct"
            case .format: return "Auto-format"
            case .completion: return "Text Completion"
            }
        }
    }

    @State private var tab = Tab.correct
    @AppStorage(Pref.replaceAsYouType) private var replaceAsYouType = true
    @AppStorage(Pref.fixTwoCapitals) private var fixTwoCapitals = true
    @AppStorage(Pref.capitaliseSentences) private var capitaliseSentences = true
    @AppStorage(Pref.capitaliseDays) private var capitaliseDays = true
    @AppStorage(Pref.replacements) private var replacementsRaw = TextReplacement.defaultsEncoded
    @AppStorage("autoBulletedLists") private var autoBullets = true
    @AppStorage("autoNumberedLists") private var autoNumbers = true
    @AppStorage("autoBorders") private var autoBorders = true
    @AppStorage(Pref.smartQuotes) private var smartQuotes = true
    @AppStorage("smartDashes") private var smartDashes = true
    @AppStorage("markdownEmphasis") private var markdownEmphasis = true
    @AppStorage(Pref.smartLinks) private var smartLinks = true
    @AppStorage("autoCompleteTips") private var autoCompleteTips = true
    @State private var selected: TextReplacement?

    var body: some View {
        VStack(spacing: 16) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 420)
            .padding(.top, 18)

            Group {
                switch tab {
                case .correct: correctTab
                case .format: formatTab
                case .completion: completionTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
    }

    private var replacements: [TextReplacement] {
        get { TextReplacement.decode(replacementsRaw) }
        nonmutating set { replacementsRaw = TextReplacement.encode(newValue) }
    }

    private var correctTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Replace text as you type", isOn: $replaceAsYouType)
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 0) {
                    Table(replacements, selection: Binding(get: { selected?.id }, set: { id in selected = replacements.first { $0.id == id } })) {
                        TableColumn("Replace") { Text($0.from) }
                        TableColumn("With") { Text($0.to) }
                    }
                    .frame(height: 260)
                    HStack(spacing: 0) {
                        Button { addReplacement() } label: { Image(systemName: "plus").frame(width: 26, height: 20) }
                        Divider().frame(height: 14)
                        Button { removeReplacement() } label: { Image(systemName: "minus").frame(width: 26, height: 20) }
                            .disabled(selected == nil)
                        Spacer()
                    }
                    .buttonStyle(.borderless).padding(4).background(Color.primary.opacity(0.05))
                }
                .frame(width: 340)
                .disabled(!replaceAsYouType)

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Correct TWo INitial CApitals", isOn: $fixTwoCapitals)
                    Toggle("Capitalise first letter of sentences", isOn: $capitaliseSentences)
                    Toggle("Capitalise names of days", isOn: $capitaliseDays)
                }
            }
        }
    }

    private var formatTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Apply as you type").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Automatic bulleted lists", isOn: $autoBullets)
                Toggle("Automatic numbered lists", isOn: $autoNumbers)
                Toggle("Borders", isOn: $autoBorders)
            }
            .padding(.leading, 14)

            Text("Replace as you type").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Dashes with en dashes and em dashes", isOn: $smartDashes)
                Toggle("*Bold* and _italic_ with real formatting", isOn: $markdownEmphasis)
                Toggle("Internet and network paths with links", isOn: $smartLinks)
                Toggle("\"Straight quotation marks\" with smart quotation marks", isOn: $smartQuotes)
            }
            .padding(.leading, 14)
        }
    }

    private var completionTab: some View {
        Toggle("Show AutoComplete tip for addresses and dates", isOn: $autoCompleteTips)
    }

    private func addReplacement() {
        var list = replacements
        list.append(TextReplacement(from: "", to: ""))
        replacements = list
    }

    private func removeReplacement() {
        guard let selected else { return }
        replacements = replacements.filter { $0.id != selected.id }
        self.selected = nil
    }
}

struct TextReplacement: Codable, Hashable, Identifiable {
    var id: String { from }
    var from: String
    var to: String

    static let builtIn: [TextReplacement] = [
        TextReplacement(from: "(c)", to: "©"),
        TextReplacement(from: "(e)", to: "€"),
        TextReplacement(from: "(r)", to: "®"),
        TextReplacement(from: "(tm)", to: "™"),
        TextReplacement(from: "...", to: "…"),
        TextReplacement(from: "I\"m", to: "I’m"),
        TextReplacement(from: "teh", to: "the"),
        TextReplacement(from: "adn", to: "and")
    ]

    static var defaultsEncoded: String { encode(builtIn) }

    static func encode(_ list: [TextReplacement]) -> String {
        guard let data = try? JSONEncoder().encode(list) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ raw: String) -> [TextReplacement] {
        guard let data = raw.data(using: .utf8), let list = try? JSONDecoder().decode([TextReplacement].self, from: data) else {
            return builtIn
        }
        return list
    }
}

struct SpellingSettings: View {
    @AppStorage(Pref.checkSpelling) private var checkSpelling = true
    @AppStorage(Pref.checkGrammar) private var checkGrammar = true
    @AppStorage(Pref.correctAutomatically) private var correctAutomatically = false
    @AppStorage(Pref.writingStyle) private var writingStyle = "grammar"

    var body: some View {
        SettingsScroll {
            SettingsRow(label: "Spelling settings:") {
                Toggle("Check spelling as you type", isOn: $checkSpelling)
                Toggle("Correct spelling automatically", isOn: $correctAutomatically)
            }
            Divider()
            SettingsRow(label: "Grammar settings:") {
                Toggle("Check grammar as you type", isOn: $checkGrammar)
                HStack(spacing: 10) {
                    Text("Writing style:").font(.system(size: 13))
                    Picker("", selection: $writingStyle) {
                        Text("Grammar").tag("grammar")
                        Text("Grammar and refinements").tag("refined")
                    }
                    .labelsHidden().frame(width: 230).disabled(!checkGrammar)
                    Button("Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Text") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .help("Grammar refinements follow the macOS text settings")
                }
            }
        }
    }
}

/// Search's settings, which Outlook's grid has no pane for; they sit in General.
struct SearchSettingsRows: View {
    @AppStorage("searchShowTopResults") private var topResults = true
    @AppStorage("searchIncludeDeleted") private var includeDeleted = true
    @AppStorage("searchScope") private var scope = "smart"
    @AppStorage("showSavedSearches") private var savedSearches = true

    var body: some View {
        SettingsRow(label: "Search results:") {
            Toggle("Show top results", isOn: $topResults)
            Toggle("Include Deleted Items", isOn: $includeDeleted)
        }
        SettingsRow(label: "Search in:") {
            Picker("", selection: $scope) {
                Text("All Mailboxes").tag("all")
                Text("Current Mailbox").tag("mailbox")
                Text("Current Folder when searching from a folder, the whole mailbox from the Inbox, and every mailbox from All Inboxes").tag("smart")
                Text("Current Folder").tag("folder")
                Text("Subfolders").tag("subfolders")
            }
            .pickerStyle(.radioGroup).labelsHidden()
            .frame(width: 460, alignment: .leading)
        }
        SettingsRow(label: "Saved Searches:") {
            Toggle("Show Saved Searches folders", isOn: $savedSearches)
        }
    }
}

struct JunkSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("junkLevel") private var level = "low"
    @AppStorage("junkTrustContacts") private var trustContacts = true

    var body: some View {
        SettingsScroll {
            SettingsRow(label: "Junk filtering:") {
                Picker("", selection: $level) {
                    Text("Off, the server decides").tag("off")
                    Text("Low, only obvious junk").tag("low")
                    Text("High, more aggressive").tag("high")
                }
                .pickerStyle(.radioGroup).labelsHidden()
                Text("Google already filters junk on the server. FalconMail only moves mail you mark yourself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            SettingsRow(label: "Safe senders:") {
                Toggle("Never treat mail from my contacts as junk", isOn: $trustContacts)
                Text("\(model.contactList.count) contacts are synced from Google.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CalendarSettings: View {
    @AppStorage(Pref.workDayStart) private var start = 9
    @AppStorage(Pref.workDayEnd) private var end = 17
    @AppStorage(Pref.workWeek) private var workWeek = "1,2,3,4,5"
    @AppStorage(Pref.firstWeekday) private var firstWeekday = 2
    @AppStorage(Pref.defaultReminder) private var reminderOn = true
    @AppStorage(Pref.reminderMinutes) private var reminderMinutes = 15
    @AppStorage(Pref.showWeekNumbers) private var weekNumbers = false
    @AppStorage(Pref.proposeNewTime) private var proposeNewTime = true

    private let dayLetters = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        SettingsScroll {
            Text("Work schedule").font(.system(size: 14, weight: .semibold))
            SettingsRow(label: "Work day starts:", labelWidth: 160) {
                Picker("", selection: $start) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            SettingsRow(label: "Work day ends:", labelWidth: 160) {
                Picker("", selection: $end) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            SettingsRow(label: "Work week:", labelWidth: 160) {
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { index in
                        Button { toggleDay(index) } label: {
                            Text(dayLetters[index])
                                .font(.system(size: 13))
                                .frame(width: 34, height: 26)
                                .background(isWorkDay(index) ? Color.primary.opacity(0.18) : Color.primary.opacity(0.05))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
            }
            SettingsRow(label: "First day of week:", labelWidth: 160) {
                Picker("", selection: $firstWeekday) {
                    ForEach(1...7, id: \.self) { index in
                        Text(Calendar.current.weekdaySymbols[index - 1]).tag(index)
                    }
                }
                .labelsHidden().frame(width: 180)
            }

            Text("Calendar options").font(.system(size: 14, weight: .semibold))
            HStack(spacing: 10) {
                Toggle("Default reminder:", isOn: $reminderOn)
                Picker("", selection: $reminderMinutes) {
                    ForEach([0, 5, 10, 15, 30, 60], id: \.self) { value in
                        Text(value == 0 ? "At the time" : "\(value) minutes").tag(value)
                    }
                }
                .labelsHidden().frame(width: 150).disabled(!reminderOn)
            }
            .padding(.leading, 202)
            Toggle("Show week numbers", isOn: $weekNumbers).padding(.leading, 202)

            Text("Time zones").font(.system(size: 14, weight: .semibold))
            SettingsRow(label: "Default time zone:", labelWidth: 160) {
                Text(TimeZone.current.identifier).font(.system(size: 13))
                Text("New events use the time zone of this Mac.").font(.caption).foregroundStyle(.secondary)
            }

            Text("Propose New Time").font(.system(size: 14, weight: .semibold))
            Toggle("Allow attendees to propose another time for meetings", isOn: $proposeNewTime)
                .padding(.leading, 202)
        }
    }

    private func isWorkDay(_ index: Int) -> Bool {
        workWeek.split(separator: ",").contains(Substring(String(index)))
    }

    private func toggleDay(_ index: Int) {
        var days = Set(workWeek.split(separator: ",").map(String.init))
        let key = String(index)
        if days.contains(key) { days.remove(key) } else { days.insert(key) }
        workWeek = days.sorted().joined(separator: ",")
    }
}

struct ContactsSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("contactsSortByLastName") private var sortByLastName = false
    @AppStorage("contactsAutoComplete") private var autoComplete = true

    var body: some View {
        SettingsScroll {
            SettingsRow(label: "Address book:") {
                Toggle("Suggest addresses while typing recipients", isOn: $autoComplete)
                Toggle("Sort by last name", isOn: $sortByLastName)
            }
            Divider()
            SettingsRow(label: "Google Contacts:") {
                Text("\(model.contactList.count) contacts synced.").font(.system(size: 13))
                Button("Sync Now") { Task { await model.syncContacts() } }
            }
        }
    }
}

struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("stripTrackingPixels") private var stripTracking = true
    @State private var contacts: [String] = []
    @State private var domains: [String] = []
    @State private var newTrust = ""

    var body: some View {
        @Bindable var model = model
        return SettingsScroll {
            SettingsRow(label: "Remote content:") {
                Toggle("Load remote images in messages", isOn: $model.loadRemoteImages)
                Toggle("Block known tracking pixels even when images load", isOn: $stripTracking)
                Text("Remote images tell the sender when a message was opened and roughly from where. FalconMail blocks them until you ask.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            SettingsRow(label: "Links in messages:") {
                Text("Every link is clickable, but one from a sender you have not trusted asks first and shows where it really goes. A link written to look like a different address always asks, even from a trusted sender.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .frame(width: 440, alignment: .leading)

                HStack(spacing: 6) {
                    TextField("person@example.com or example.com", text: $newTrust)
                        .frame(width: 280)
                        .onSubmit { addTrust() }
                    Button("Trust") { addTrust() }.disabled(newTrust.trimmed.isEmpty)
                }

                TrustList(title: "Trusted senders", entries: contacts, empty: "No senders trusted yet.") { entry in
                    LinkGuard.forget(contact: entry)
                    reload()
                }
                TrustList(title: "Trusted domains", entries: domains, empty: "No domains trusted yet.") { entry in
                    LinkGuard.forget(domain: entry)
                    reload()
                }
            }
        }
        .onAppear { reload() }
    }

    private func addTrust() {
        let entry = newTrust.trimmed.lowercased()
        guard !entry.isEmpty else { return }
        if entry.contains("@") {
            LinkGuard.trustedContacts.insert(entry)
        } else {
            LinkGuard.trustedDomains.insert(entry)
        }
        newTrust = ""
        reload()
    }

    private func reload() {
        contacts = LinkGuard.trustedContacts.sorted()
        domains = LinkGuard.trustedDomains.sorted()
    }
}

struct TrustList: View {
    let title: String
    let entries: [String]
    let empty: String
    let onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium))
            if entries.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(entries, id: \.self) { entry in
                            HStack {
                                Text(entry).font(.system(size: 12))
                                Spacer()
                                Button("Remove") { onRemove(entry) }
                                    .buttonStyle(.link).font(.caption)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                        }
                    }
                }
                .frame(width: 440, height: min(CGFloat(entries.count) * 24 + 8, 120))
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
