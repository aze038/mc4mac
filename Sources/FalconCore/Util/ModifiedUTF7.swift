import Foundation

public enum ModifiedUTF7 {
    public static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&" {
                guard let end = s[i...].firstIndex(of: "-") else { out.append(c); i = s.index(after: i); continue }
                let inner = String(s[s.index(after: i)..<end])
                if inner.isEmpty {
                    out.append("&")
                } else {
                    var b64 = inner.replacingOccurrences(of: ",", with: "/")
                    while b64.count % 4 != 0 { b64.append("=") }
                    if let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf16BigEndian) {
                        out.append(text)
                    } else {
                        out.append("&" + inner + "-")
                    }
                }
                i = s.index(after: end)
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }

    public static func encode(_ s: String) -> String {
        var out = ""
        var pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            let data = pending.data(using: .utf16BigEndian) ?? Data()
            let b64 = data.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "/", with: ",")
            out += "&" + b64 + "-"
            pending = ""
        }
        for ch in s {
            if ch == "&" { flush(); out += "&-"; continue }
            if let a = ch.asciiValue, a >= 0x20, a <= 0x7E { flush(); out.append(ch) } else { pending.append(ch) }
        }
        flush()
        return out
    }
}
