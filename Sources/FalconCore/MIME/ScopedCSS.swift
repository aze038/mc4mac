import Foundation

/// A style sheet made to reach only inside one element, as a quoted original's rules must: a
/// message's own `<style>` applies to the whole message it is quoted in, so an original's
/// `p { margin: 2em }` or `body { font-family: Times }` would restyle the reply written above it.
///
/// Every rule's selectors are put under `scope`, a selector for the element holding the quote;
/// the original's `html`, `:root` and `body` become that element itself, as its body's own
/// attributes do. Rules inside `@media` and `@supports` are scoped in turn. Rules that name no
/// element, as Word's `@font-face`, `@page` and `@list`, and anything the sheet cannot be read
/// as, are kept as they were; `@import`, which would fetch from the web, and `@charset` are left
/// out. Comments go and runs of white space become one, which changes nothing a reader draws.
public enum ScopedCSS {
    public static func scope(_ css: String, to scope: String) -> String {
        let chars = Array(compacted(css))
        var output = ""
        rules(chars, from: 0, to: chars.count, scope: scope, into: &output)
        return output
    }

    /// Gmail reads no more than 16 KB of any one `<style>` element, and a Word original's sheet,
    /// its lists and fonts included, can be longer; so a sheet goes out as several elements,
    /// each under `limit` bytes, split between whole rules. A rule longer than that on its own
    /// is an element of its own.
    public static func sheets(_ css: String, under limit: Int = 15_000) -> [String] {
        guard css.utf8.count > limit else { return css.isEmpty ? [] : [css] }
        var sheets: [String] = []
        var current = ""
        var currentBytes = 0
        var rule = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        func close() {
            let bytes = rule.utf8.count
            if currentBytes > 0, currentBytes + bytes > limit {
                sheets.append(current)
                current = ""
                currentBytes = 0
            }
            current += rule
            currentBytes += bytes
            rule = ""
        }
        for ch in css {
            rule.append(ch)
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'": quote = ch
            case "{": depth += 1
            case "}":
                depth = max(0, depth - 1)
                if depth == 0 { close() }
            case ";" where depth == 0: close()
            default: break
            }
        }
        if !rule.isEmpty { close() }
        if !current.isEmpty { sheets.append(current) }
        return sheets
    }

    /// The at-rules whose blocks hold rules of their own, which are scoped in turn.
    private static let grouping: Set<String> = ["media", "supports", "document", "-moz-document", "container", "layer"]

    private static func rules(_ c: [Character], from start: Int, to end: Int, scope: String, into output: inout String) {
        var i = start
        while i < end {
            while i < end, c[i] == " " || c[i] == ";" { i += 1 }
            guard i < end else { return }
            if c[i] == "@" {
                let (prelude, stop) = readPrelude(c, from: i, to: end)
                let name = String(prelude.dropFirst().prefix { $0.isLetter || $0 == "-" }).lowercased()
                if stop >= end || c[stop] == ";" {
                    if name != "import" && name != "charset" { output += prelude.trimmed + ";" }
                    i = stop + 1
                    continue
                }
                let close = matchingBrace(c, open: stop, end: end)
                if grouping.contains(name) {
                    output += prelude.trimmed + "{"
                    rules(c, from: stop + 1, to: close, scope: scope, into: &output)
                    output += "}"
                } else {
                    output += prelude.trimmed + "{" + String(c[(stop + 1)..<close]).trimmed + "}"
                }
                i = close + 1
                continue
            }
            let (prelude, stop) = readPrelude(c, from: i, to: end)
            guard stop < end, c[stop] == "{" else { return }
            let close = matchingBrace(c, open: stop, end: end)
            let selectors = scoped(selectors: prelude.trimmed, to: scope)
            if !selectors.isEmpty {
                output += selectors + "{" + String(c[(stop + 1)..<close]).trimmed + "}"
            }
            i = close + 1
        }
    }

    /// Everything up to the `{` or `;` that ends a rule's prelude, outside strings, brackets
    /// and parentheses, and where it stopped.
    private static func readPrelude(_ c: [Character], from start: Int, to end: Int) -> (String, Int) {
        var i = start
        var depth = 0
        var quote: Character?
        while i < end {
            let ch = c[i]
            if let q = quote {
                if ch == "\\" { i += 2; continue }
                if ch == q { quote = nil }
            } else if ch == "\\" {
                i += 2
                continue
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "(" || ch == "[" {
                depth += 1
            } else if ch == ")" || ch == "]" {
                depth = max(0, depth - 1)
            } else if depth == 0, ch == "{" || ch == ";" {
                return (String(c[start..<i]), i)
            }
            i += 1
        }
        return (String(c[start..<min(i, end)]), end)
    }

    /// The `}` closing the block opened at `open`, or `end` for a block never closed.
    private static func matchingBrace(_ c: [Character], open: Int, end: Int) -> Int {
        var depth = 0
        var quote: Character?
        var i = open
        while i < end {
            let ch = c[i]
            if let q = quote {
                if ch == "\\" { i += 2; continue }
                if ch == q { quote = nil }
            } else if ch == "\\" {
                i += 2
                continue
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return end
    }

    /// Each selector of a comma-separated list under `scope`.
    static func scoped(selectors list: String, to scope: String) -> String {
        split(list, at: ",").map { scoped(selector: $0.trimmed, to: scope) }.filter { !$0.isEmpty }.joined(separator: ",")
    }

    static func scoped(selector: String, to scope: String) -> String {
        guard !selector.isEmpty else { return "" }
        var rest = Substring(selector)
        // The original's document and body are the element holding the quote.
        let first = firstCompound(of: rest)
        let lower = first.lowercased()
        if isType("html", lower) || lower.hasPrefix(":root") {
            rest = rest.dropFirst(first.count).drop { $0 == " " || $0 == ">" }
            if rest.isEmpty { return scope }
            let next = firstCompound(of: rest)
            if isType("body", next.lowercased()) {
                return scope + String(next.dropFirst(4)) + String(rest.dropFirst(next.count))
            }
            return scope + " " + rest
        }
        if isType("body", lower) {
            return scope + String(first.dropFirst(4)) + String(rest.dropFirst(first.count))
        }
        return scope + " " + rest
    }

    /// Whether a compound selector starts with the element `name`: `body`, `body.x`, not `bodyx`.
    private static func isType(_ name: String, _ compound: String) -> Bool {
        guard compound.hasPrefix(name) else { return false }
        guard let next = compound.dropFirst(name.count).first else { return true }
        return ".#:[".contains(next)
    }

    /// The selector's first compound, up to its first combinator.
    private static func firstCompound(of selector: Substring) -> Substring {
        var depth = 0
        for index in selector.indices {
            let ch = selector[index]
            if ch == "(" || ch == "[" { depth += 1 }
            if ch == ")" || ch == "]" { depth = max(0, depth - 1) }
            if depth == 0, ch == " " || ch == ">" || ch == "+" || ch == "~" { return selector[..<index] }
        }
        return selector
    }

    /// `text` split at `separator` where it stands outside strings, brackets and parentheses.
    private static func split(_ text: String, at separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "(" || ch == "[" {
                depth += 1
            } else if ch == ")" || ch == "]" {
                depth = max(0, depth - 1)
            } else if ch == separator, depth == 0 {
                parts.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        parts.append(current)
        return parts
    }

    /// The sheet without comments, the `<!--` and `-->` that hide it from very old readers, and
    /// with every run of white space outside strings made one space, and none beside braces,
    /// semicolons and commas.
    static func compacted(_ css: String) -> String {
        let c = Array(css)
        var out: [Character] = []
        out.reserveCapacity(c.count)
        var i = 0
        var quote: Character?
        var pendingSpace = false
        func emit(_ ch: Character) {
            if pendingSpace {
                if let last = out.last, !"{};,".contains(last), !"{};,".contains(ch) { out.append(" ") }
                pendingSpace = false
            }
            out.append(ch)
        }
        while i < c.count {
            let ch = c[i]
            if let q = quote {
                out.append(ch)
                if ch == "\\", i + 1 < c.count {
                    out.append(c[i + 1])
                    i += 2
                    continue
                }
                if ch == q { quote = nil }
                i += 1
                continue
            }
            if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
                var j = i + 2
                while j + 1 < c.count, !(c[j] == "*" && c[j + 1] == "/") { j += 1 }
                i = j + 2
                pendingSpace = true
                continue
            }
            if ch == "<", i + 3 < c.count, c[i + 1] == "!", c[i + 2] == "-", c[i + 3] == "-" {
                i += 4
                pendingSpace = true
                continue
            }
            if ch == "-", i + 2 < c.count, c[i + 1] == "-", c[i + 2] == ">" {
                i += 3
                pendingSpace = true
                continue
            }
            if ch.isWhitespace {
                pendingSpace = !out.isEmpty
                i += 1
                continue
            }
            if ch == "\\", i + 1 < c.count {
                emit(ch)
                out.append(c[i + 1])
                i += 2
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch }
            emit(ch)
            i += 1
        }
        return String(out)
    }
}
