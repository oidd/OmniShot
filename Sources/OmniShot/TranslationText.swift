import AppKit
import CoreText
import OmniShotCore

/// The text a translation is drawn with. Layout and drawing both go through here, so what gets measured
/// is exactly what gets drawn.
enum TranslationText {
    /// BCP-47 tag for the language the user translates into: it tells CoreText which glyph shapes to use
    /// (and which CJK punctuation forms), which a font name alone does not.
    static func languageTag(for target: String) -> String {
        switch target {
        case "繁體中文": return "zh-Hant"
        case "English": return "en"
        case "日本語": return "ja"
        case "한국어": return "ko"
        default: return "zh-Hans"
        }
    }

    /// The system's own UI font for that language, so a translation looks like it was always there.
    static func font(size: CGFloat, bold: Bool, language: String) -> NSFont {
        let name: String?
        switch language {
        case "zh-Hans": name = bold ? "PingFangSC-Semibold" : "PingFangSC-Regular"
        case "zh-Hant": name = bold ? "PingFangTC-Semibold" : "PingFangTC-Regular"
        case "ja": name = bold ? "HiraginoSans-W6" : "HiraginoSans-W3"
        case "ko": name = bold ? "AppleSDGothicNeo-Bold" : "AppleSDGothicNeo-Regular"
        default: name = nil
        }
        if let name, let font = NSFont(name: name, size: size) { return font }
        return .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    static func attributes(size: CGFloat, bold: Bool, language: String, color: NSColor? = nil) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font(size: size, bold: bold, language: language)]
        attributes[NSAttributedString.Key(kCTLanguageAttributeName as String)] = language
        if let color { attributes[.foregroundColor] = color }
        return attributes
    }

    static func color(_ c: RGBA) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    /// Breaks `text` into the lines CoreText would draw at that width.
    static func lines(_ text: String, _ attributes: [NSAttributedString.Key: Any], width: CGFloat) -> [CTLine] {
        let string = NSAttributedString(string: text, attributes: attributes)
        guard string.length > 0 else { return [] }
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var result: [CTLine] = []
        var start = 0
        while start < string.length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(max(width, 1))))
            result.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: min(count, string.length - start))))
            start += count
        }
        return result
    }

    /// Line width without the trailing whitespace, which is what the eye aligns against.
    static func width(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CTLineGetTrailingWhitespaceWidth(line)
    }

    /// Height of the wrapped text, with the original line spacing between the lines.
    static func height(_ lines: [CTLine], pitch: CGFloat) -> CGFloat {
        guard let first = lines.first else { return 0 }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(first, &ascent, &descent, &leading)
        return CGFloat(lines.count - 1) * pitch + ascent + descent + leading
    }

    /// Cuts `text` down to what fits, ending with an ellipsis: a translation that cannot shrink any further
    /// is better shortened than spilled over the text below it.
    static func truncate(_ text: String, _ attributes: [NSAttributedString.Key: Any], width: CGFloat,
                         height: CGFloat, pitch: CGFloat) -> String {
        let characters = Array(text)
        var low = 0, high = characters.count
        var best = "…"
        while low <= high {
            let middle = (low + high) / 2
            let candidate = String(characters.prefix(middle)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
            if self.height(lines(candidate, attributes, width: width), pitch: pitch) <= height {
                best = candidate
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best
    }
}
