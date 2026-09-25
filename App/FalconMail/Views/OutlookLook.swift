import SwiftUI
import AppKit

/// Legacy Outlook for Mac, measured.
///
/// Every number below was read off a capture of the real window at 1728 × 1084 points on a
/// Retina display, in dark appearance: region edges from colour changes along rows and columns,
/// text sizes from cap heights, colours from the pixels themselves. Nothing here is a guess, so
/// when a view disagrees with Outlook the view is wrong, not the number.
enum OL {
    // MARK: the chrome across the top: title row, tab row, ribbon, then a one point line

    static let titleRow: CGFloat = 28
    static let tabRow: CGFloat = 34
    static let ribbon: CGFloat = 74
    static var chromeHeight: CGFloat { titleRow + tabRow + ribbon }

    static let quickIconsStart: CGFloat = 95
    static let quickIcon: CGFloat = 14
    static let quickPitch: CGFloat = 27
    static let titleFont: CGFloat = 13
    static let searchWidth: CGFloat = 208
    static let searchHeight: CGFloat = 18
    static let searchRightInset: CGFloat = 12

    static let tabFont: CGFloat = 13.5
    static let tabInset: CGFloat = 12
    static let tabGap: CGFloat = 24
    static let tabTextTop: CGFloat = 10
    static let tabUnderlineTop: CGFloat = 29
    static let tabUnderline: CGFloat = 3

    static let ribbonInset: CGFloat = 8
    static let ribbonIconTop: CGFloat = 4
    static let ribbonIconBox: CGFloat = 28
    // A tile's glyph and chevron start five points below the separators and the small rows: in
    // Outlook's Home and Message ribbons alike both centre 85 points down the window.
    static let ribbonTileGlyphTop: CGFloat = 9
    static let ribbonIcon: CGFloat = 21
    static let ribbonLabelTop: CGFloat = 44
    static let ribbonLabelFont: CGFloat = 10.5
    static let ribbonLabelPitch: CGFloat = 10.5
    static let ribbonTilePad: CGFloat = 4
    static let ribbonTileGap: CGFloat = 1
    static let ribbonSeparatorPad: CGFloat = 8
    static let ribbonSeparatorHeight: CGFloat = 59
    static let ribbonMiniIcon: CGFloat = 16
    static let ribbonMiniFont: CGFloat = 12
    static let ribbonMiniRow: CGFloat = 30
    static let ribbonMiniGap: CGFloat = 4
    static let findFieldWidth: CGFloat = 101
    static let findFieldHeight: CGFloat = 20

    // A control with nothing to act on: its glyph at a third, its caption at a half (Send,
    // Cut and Copy of an empty compose window).
    static let ribbonGlyphDimmed: CGFloat = 0.35
    static let ribbonCaptionDimmed: CGFloat = 0.52
    // The compose ribbon's small-icon columns (Cut, Copy, Format Painter beside Paste; Pictures,
    // Signature, Link at the end): sixteen point glyphs one to a twenty-two point row, centred at
    // y 77, 99 and 121 of the window.
    static let ribbonSmallIcon: CGFloat = 16
    static let ribbonSmallRow: CGFloat = 22
    // Outlook gives the first groups a little more room than the generic tile spacing: Send's
    // line stands at 56, Paste's glyph starts sixteen points past it, Cut, Copy and Format
    // Painter sit at x 120–136 and the next line at 149.
    static let composeSendPad: CGFloat = 1.5
    static let composePasteLead: CGFloat = 3
    static let composeClipboardPad: CGFloat = 1

    // MARK: the three columns

    static let sidebarWidth: CGFloat = 270
    static let listWidth: CGFloat = 340
    static let divider: CGFloat = 1

    // MARK: sidebar rows

    static let sidebarRowTop: CGFloat = 30
    static let sidebarRowFolder: CGFloat = 24
    static let sidebarTopFont: CGFloat = 14
    static let sidebarFolderFont: CGFloat = 13
    static let sidebarCountFont: CGFloat = 12
    static let sidebarChevronX: CGFloat = 5
    static let sidebarTopTextX: CGFloat = 23.5
    static let sidebarLevelChevronX: CGFloat = 18
    static let sidebarLevelIconX: CGFloat = 37
    static let sidebarLevelTextX: CGFloat = 61
    static let sidebarIndent: CGFloat = 16
    static let sidebarIcon: CGFloat = 16
    static let sidebarCountRight: CGFloat = 16.5

    // MARK: message list

    static let listHeader: CGFloat = 43
    static let listHeaderFont: CGFloat = 13.5
    static let listHeaderRightInset: CGFloat = 10
    static let listLineFont: CGFloat = 13.5
    static let listSeparatorX: CGFloat = 16
    static let listIconRight: CGFloat = 25

    // MARK: message list rows
    //
    // Read off Outlook's list at its 340 point width, text sizes from the widths of whole words:
    // Outlook draws its list with font smoothing, which thickens every stroke but leaves widths
    // alone. x is from the list's left edge, y from the row's top, baselines as CoreText has them.

    /// Between the line under the list's header and the first row, inside the header's height.
    static let listTopInset: CGFloat = 5
    /// Senders, subject and date, preview.
    static let listRow: CGFloat = 70
    /// Without the preview: an expanded conversation's own row, or every row with previews off.
    static let listRowShort: CGFloat = 51
    /// One message of an expanded conversation.
    static let listChildRow: CGFloat = 28
    static let listSenderFont: CGFloat = 14
    static let listTextFont: CGFloat = 13
    static let listTextX: CGFloat = 42
    static let listBaseline: CGFloat = 21
    static let listLinePitch: CGFloat = 19
    /// Where the date and the preview end.
    static let listTextRight: CGFloat = 27
    /// Where the senders end when nothing stands at the end of their line.
    static let listSenderRight: CGFloat = 38
    /// Between the senders cut short and the first icon after them.
    static let listSenderGap: CGFloat = 16
    /// Between a subject or a name cut short and the date after it.
    static let listDateGap: CGFloat = 14
    static let listChildTextX: CGFloat = 62
    static let listChildBaseline: CGFloat = 19
    /// Where a child's date ends, counted from the left: its dates stand in a column rather than
    /// at the row's end.
    static let listChildDateEnd: CGFloat = 220
    static let listChildSeparatorX: CGFloat = 62
    static let listDotX: CGFloat = 29
    static let listDotY: CGFloat = 35.5
    static let listDot: CGFloat = 9
    static let listBadgeTop: CGFloat = 5
    static let listBadgeHeight: CGFloat = 14
    static let listBadgePadding: CGFloat = 7.25
    static let listBadgeFont: CGFloat = 10.5
    static let listClipTop: CGFloat = 5.25
    /// The paperclip's right edge when no count stands after it.
    static let listClipRight: CGFloat = 28
    static let listIconGap: CGFloat = 8.5

    // MARK: reading pane

    static let readingSubjectTop: CGFloat = 8
    static let readingSubjectFont: CGFloat = 22
    static let readingIconX: CGFloat = 25.5
    static let readingTextX: CGFloat = 72.5
    static let readingAvatar: CGFloat = 42
    static let readingAvatarX: CGFloat = 28
    static let readingAvatarTop: CGFloat = 46
    static let readingSenderX: CGFloat = 94.5
    static let readingSenderFont: CGFloat = 13
    static let readingMetaFont: CGFloat = 12
    /// Where the names of the reading header's To, Cc and Bcc lines start, after their labels:
    /// sixteen points after "To:", as measured, and the others' names under them.
    static let readingRecipientLabel: CGFloat = 34
    /// The same in a conversation card, twelve points after a label twenty wide.
    static let stackRecipientLabel: CGFloat = 32
    static let readingRightInset: CGFloat = 12
    static let readingNoticeTop: CGFloat = 108
    static let readingNotice: CGFloat = 20
    static let readingBodyX: CGFloat = 25
    static let readingQuoteBarX: CGFloat = 33

    // MARK: compose window (917 × 1006): the header band under the ribbon, y 137–219

    // Legacy's window is 917 wide. FalconMail's is wider by the Discard tile the owner asked
    // for beside Send, which moves every later group 49 points right, so that Pictures,
    // Signature and Link still show at the ribbon's end.
    static let composeDiscardTile: CGFloat = 49
    static let composeWindowWidth: CGFloat = 917 + composeDiscardTile
    static let composeWindowHeight: CGFloat = 1006
    static let composeBandTop: CGFloat = 3
    static let composeBandBottom: CGFloat = 9
    static let composeRowPitch: CGFloat = 25
    static let composeField: CGFloat = 19
    static let composeLabelRight: CGFloat = 56
    static let composeFieldX: CGFloat = 68
    static let composeFieldRight: CGFloat = 50.5
    static let composeSubjectRight: CGFloat = 17.5
    static let composeBookGlyph: CGFloat = 16
    static let composeBookRight: CGFloat = 22
    static let composeLabelFont: CGFloat = 13

    // MARK: the bottom: module rail under the sidebar, status bar across the window

    static let rail: CGFloat = 36
    static let railIcon: CGFloat = 18
    static let railFirstCenter: CGFloat = 28
    static let railPitch: CGFloat = 54
    static let status: CGFloat = 27
    static let statusFont: CGFloat = 12
    static let statusLeftX: CGFloat = 25
    static let statusRightInset: CGFloat = 25.5

    // MARK: message window, the size a double-clicked message opens at

    static let messageWindowWidth: CGFloat = 917
    static let messageWindowHeight: CGFloat = 1006

    // MARK: full screen: the status bar holding a tab for each message or compose window
    // minimised, measured from Outlook filling a 1728 × 1117 point screen

    static let fullScreenStatus: CGFloat = 35.5
    static let fullScreenTab: CGFloat = 27
    static let fullScreenTabRadius: CGFloat = 4
    static let fullScreenStatusLeftX: CGFloat = 94
    static let fullScreenStatusRightInset: CGFloat = 47.5
}

/// Outlook's colours, dark ones measured, light ones the same surfaces in Outlook's light look.
enum OLColor {
    static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark))
    }

    static func dynamicNS(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    static let chrome = dynamic(light: 0xF6F6F6, dark: 0x1B1B1B)
    static let chromeLine = dynamic(light: 0xC4C4C4, dark: 0x000000)
    static let sidebar = dynamic(light: 0xE8E8E8, dark: 0x323232)
    static let sidebarSelected = dynamic(light: 0xD0D0D0, dark: 0x464647)
    static let list = Color(nsColor: OLListColor.background)
    static let listSelected = Color(nsColor: OLListColor.selection)
    static let reading = dynamic(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let notice = dynamic(light: 0xEFEFEF, dark: 0x323232)
    static let status = dynamic(light: 0xEDEDED, dark: 0x282828)
    /// The status bar while the mailbox window fills the screen, and its tabs. Outlook's light
    /// one was not captured, so the light ones are the same surfaces in its light look.
    static let fullScreenStatus = dynamic(light: 0xD4D4D4, dark: 0x464646)
    static let fullScreenTab = dynamic(light: 0xF6F6F6, dark: 0x1E1E1E)
    static let fullScreenTabHover = dynamic(light: 0xFFFFFF, dark: 0x2A2A2A)
    static let divider = Color(nsColor: OLListColor.separator)
    static let text = Color(nsColor: OLListColor.text)
    static let textMuted = dynamic(light: 0x5E5E5E, dark: 0xB4B4B4)
    static let textDim = dynamic(light: 0x7A7A7A, dark: 0x8E8E8E)
    static let title = dynamic(light: 0x3C3C3C, dark: 0xD7D7D7)
    static let tab = dynamic(light: 0x6E6E6E, dark: 0x919292)
    static let tabSelected = dynamic(light: 0x1E1E1E, dark: 0xE6E6E6)
    static let tabUnderline = dynamic(light: 0x1E1E1E, dark: 0xDCDCDC)
    static let ribbonIcon = dynamic(light: 0x5A5A5A, dark: 0x8B8A8B)
    static let ribbonLabel = dynamic(light: 0x505050, dark: 0xA7A6A6)
    static let ribbonSeparator = dynamic(light: 0xD0D0D0, dark: 0x525252)
    /// The modern ribbon's group cards.
    static let ribbonCard = dynamic(light: 0xFFFFFF, dark: 0x262626)
    static let ribbonCardLine = dynamic(light: 0xE4E4E4, dark: 0x343434)
    static let field = dynamic(light: 0xFFFFFF, dark: 0x484848)
    static let fieldText = dynamic(light: 0x7A7A7A, dark: 0xA0A0A0)
    static let ribbonField = dynamic(light: 0xFFFFFF, dark: 0x222222)
    static let unread = Color(nsColor: OLListColor.unread)
    static let inbox = dynamic(light: 0x1E7AD0, dark: 0x52A3E0)
    static let icon = dynamic(light: 0x4A4A4A, dark: 0xE1E1E1)
    static let buttonBorder = dynamic(light: 0xB0B0B0, dark: 0x707070)
    static let quoteBar = dynamic(light: 0x8A8A8A, dark: 0xCCCCCC)
    static let fieldBorder = dynamic(light: 0xC8C8C8, dark: 0x343434)
    static let fieldBandLine = dynamic(light: 0xB8B8B8, dark: 0x585858)
    static let hover = Color.primary.opacity(0.08)
    /// The square behind a format button that is on, as Outlook's compose ribbon puts one behind
    /// its chosen alignment.
    static let ribbonChosen = dynamic(light: 0xDADADA, dark: 0x4E4E4D)

    // Ribbon icon accents, the colours Outlook draws into its otherwise grey glyphs.
    static let replyPurple = dynamic(light: 0x8E44AD, dark: 0xB56AD8)
    static let forwardBlue = dynamic(light: 0x2F6FBF, dark: 0x4A90D9)
    static let archiveGreen = dynamic(light: 0x2E8B4A, dark: 0x3DA35D)
    static let junkRed = dynamic(light: 0xC0392B, dark: 0xD9534F)
    static let flagRed = Color(nsColor: OLListColor.flag)
    static let categoryOrange = dynamic(light: 0xC77A1F, dark: 0xD68B2E)
    static let sendGreen = archiveGreen
}

/// The message list's colours as its rows draw them, with CoreText rather than SwiftUI; the
/// window's other surfaces take theirs from here too. Measured in dark. Outlook's light list was
/// not captured, so the light ones are the same surfaces in its light look.
enum OLListColor {
    static let background = OLColor.dynamicNS(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let text = OLColor.dynamicNS(light: 0x1E1E1E, dark: 0xE6E6E6)
    /// Dates and previews.
    static let secondary = OLColor.dynamicNS(light: 0x5F5F5F, dark: 0xB3B3B3)
    /// A sender on a message's own line under its conversation, brighter than the rest.
    static let childName = OLColor.dynamicNS(light: 0x000000, dark: 0xFFFFFF)
    static let unread = OLColor.dynamicNS(light: 0x0F6CBD, dark: 0x629FF8)
    static let separator = OLColor.dynamicNS(light: 0xC4C4C4, dark: 0x545454)
    /// The selected row while the list does not have the keyboard, or its window is behind.
    static let selection = OLColor.dynamicNS(light: 0xDCDCDC, dark: 0x454646)
    /// The selected row while the list has the keyboard; its words are then in `unread`'s blue.
    static let focusedSelection = OLColor.dynamicNS(light: 0xCCE3F8, dark: 0x102F79)
    static let chevron = OLColor.dynamicNS(light: 0x404040, dark: 0xD2D2D2)
    static let paperclip = OLColor.dynamicNS(light: 0x5C5C5C, dark: 0xC1C1C1)
    static let badge = OLColor.dynamicNS(light: 0xC8C8C8, dark: 0xB3B3B3)
    static let badgeText = NSColor.black
    static let flag = OLColor.dynamicNS(light: 0xC0392B, dark: 0xD64541)
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
