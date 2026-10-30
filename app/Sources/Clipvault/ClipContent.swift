import AppKit

enum ClipAction {
    case paste, pastePlain, copy
}

/// Helpers that interpret decrypted pasteboard representations.
enum ClipContent {
    static let textType = "public.utf8-plain-text"
    static let rtfType = "public.rtf"
    static let htmlType = "public.html"
    static let fileURLType = "public.file-url"
    static let imageTypes = ["public.png", "public.tiff", "public.jpeg", "com.compuserve.gif"]

    /// Plain text for "Paste as Plain Text" and previews: file paths, plain text, or text
    /// extracted from RTF/HTML. `nil` for images.
    @MainActor
    static func plainText(_ reps: [ClipRep]) -> String? {
        let paths = reps.filter { $0.uti == fileURLType }.compactMap { rep -> String? in
            guard let s = String(data: rep.data, encoding: .utf8) else { return nil }
            return URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\0"))))?.path
        }
        if !paths.isEmpty { return paths.joined(separator: "\n") }
        if let rep = reps.first(where: { $0.uti == textType }), let s = String(data: rep.data, encoding: .utf8) {
            return s
        }
        if let rep = reps.first(where: { $0.uti == rtfType }),
           let a = NSAttributedString(rtf: rep.data, documentAttributes: nil) {
            return a.string
        }
        if let rep = reps.first(where: { $0.uti == htmlType }),
           let a = NSAttributedString(html: rep.data, documentAttributes: nil) {
            return a.string
        }
        return nil
    }

    static func image(_ reps: [ClipRep]) -> NSImage? {
        for type in imageTypes {
            if let rep = reps.first(where: { $0.uti == type }), let image = NSImage(data: rep.data) { return image }
        }
        return nil
    }

    /// An http(s) URL if the text is nothing but a link.
    static func link(in text: String) -> URL? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count < 2048, !s.contains(where: \.isWhitespace),
              let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// A color if the text is a CSS-style hex (`#rgb`, `#rrggbb`, `#rrggbbaa`) or `rgb()/rgba()` value.
    static func color(in text: String) -> NSColor? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            guard [3, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            if hex.count == 6 { hex += "ff" }
            guard let v = UInt32(hex, radix: 16) else { return nil }
            return NSColor(srgbRed: CGFloat(v >> 24 & 0xFF) / 255, green: CGFloat(v >> 16 & 0xFF) / 255,
                           blue: CGFloat(v >> 8 & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
        }
        for prefix in ["rgba(", "rgb("] where s.hasPrefix(prefix) && s.hasSuffix(")") {
            let parts = s.dropFirst(prefix.count).dropLast()
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            let rgb = parts.prefix(3).compactMap { Double($0) }
            guard rgb.count == 3, rgb.allSatisfy({ (0...255).contains($0) }) else { return nil }
            var alpha = 1.0
            if parts.count == 4 {
                let a = parts[3]
                guard let v = a.hasSuffix("%") ? Double(a.dropLast()).map({ $0 / 100 }) : Double(a),
                      (0...1).contains(v) else { return nil }
                alpha = v
            }
            return NSColor(srgbRed: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255, alpha: alpha)
        }
        return nil
    }
}
