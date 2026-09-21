# Legacy Outlook for Mac, measured

Reference: the real window captured at 1728 × 1084 points on a Retina display, dark appearance,
`INBOX · kamal@solidshape.com`, 21 September 2026. Every value is in points; colours are the pixels.
The numbers live in code in `App/FalconMail/Views/OutlookLook.swift` (`OL`, `OLColor`).

## Chrome (y 0–136, #1b1b1b, then a 1 pt #000000 line)
- Title row 0–28: quick icons 14 pt (#a7a6a6) from x 95 at a 27 pt pitch; window title 13 pt (#d7d7d7) centred;
  search field 208 × 18 at the right (12 pt inset), fill #484848.
- Tab row 28–62: "Home / Organise / Tools" 13.5 pt from x 12, 24 pt apart; selected white (#e6e6e6) with a 3 pt
  #dcdcdc line at y 57–60, others #919292.
- Ribbon 62–136: icons 28 × ~20 (#8b8a8b) at y 66–94; captions 11 pt (#a7a6a6), lines 10.5 pt apart from y 106;
  tiles as wide as the caption + 6 pt each side, 2 pt apart; separators 1 pt #525252, y 66–125, 12 pt margins;
  chevrons 6 pt beside the icon; "Find a Contact" field 101 × 20 (#222222); mini rows 30 pt (Meeting / Attachment).

## Columns
- Sidebar x 0–270 (#323232), divider 1 pt #545454 at x 270; list x 271–610 (#1e1e1e), divider at 611; reading pane
  from 612 (#1e1e1e).

## Sidebar
- "All Accounts", accounts, "Smart Folders", "On my Computer": 30 pt rows, 14 pt text at x 23.5, chevron at x 5.
- Folders: 24 pt rows, 13 pt text; level 1 icon at x 37, text at 61; each level +16; disclosure chevron at x 18.
- Selected folder: full-width #464647. Unread count 12 pt #629ff8, right edge 16.5 pt from the divider.
- Inbox icon blue #52a3e0; other icons #e1e1e1, 16 pt.

## Message list
- Header 43 pt: "By: Conversations ˅" 13.5 pt (#dddddd) right-aligned, direction arrow at the far right.
- Rows 70 pt: name 15 pt (#e7e7e6) baseline +21; subject 13.5 pt (#e6e7e6) baseline +40, date 13.5 pt (#b4b4b3)
  right-aligned 26.5 pt from the edge; preview 13.5 pt (#b4b3b4) baseline +59; text from x 42.5; conversation
  chevron at x 8; icons (paperclip 16 pt #cdcdcd) 20 pt from the edge on the name line.
- Selected row #454646 full width; between other rows a 1 pt #545454 line from x 14.

## Reading pane
- Subject 22 pt semibold (#e6e6e6) at x 72.5, cap top y 12 (from the pane top); conversation glyph at x 25.5;
  options glyph at the right (13 pt inset).
- Sender circle 42 pt at x 28, y 46; sender name + <address> 13 pt semibold at x 94.5, baseline 60;
  date 13 pt (#b3b3b3) right-aligned 12 pt from the edge; "To:" 12 pt semibold, address 12 pt (#b3b3b3), baseline 85.
- Notice band (You replied … / Show Reply): y 108–128, #323232, glyph at x 6, text 12 pt at x 30.5, bordered button
  (#707070, 16 pt tall) 10 pt from the edge. Quote bar 1 pt #cccccc at x 33. Body text from x 25.

## Bottom
- Module rail 36 pt (#323232) under the sidebar only, 1 pt #545454 line above; icons 18 pt at x centres 28, 82, 136,
  190, 244 (Mail blue #52a3e0 when chosen).
- Status bar 27 pt (#282828) with a 1 pt #000000 line above; "Items: N" 12 pt white at x 25; right text 12 pt,
  25.5 pt inset: "All folders are up to date.  Connected to: …".

## Deliberately not copied
- The "Legacy Outlook" switch in the title row: it toggles Microsoft's two interfaces and has no meaning here.
- Microsoft's icon artwork: SF Symbols are drawn at the same size, weight and colour instead.
