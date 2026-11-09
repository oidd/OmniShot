import CoreGraphics
import Foundation

/// One character and where it is, as Vision reports it. The auto-mask tool needs these to cut a line like
/// 「手机号：13800138000」 into the label and the number: Vision only gives line boxes otherwise, and Chinese
/// has no spaces to split on.
public struct OCRGlyph: Equatable, Sendable {
    public var text: String
    public var rect: CGRect
    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

/// One line of text recognized by Vision, in a top-left-origin coordinate space (points).
public struct OCRLine: Equatable, Sendable {
    public var text: String
    public var rect: CGRect
    /// One box per character, when the recogniser measured them. Empty for synthetic lines and for the checks
    /// that build a line by hand; `AutoMaskDetector` then falls back to the whole line as one word.
    public var glyphs: [OCRGlyph]

    /// Width of this line's first word, when the recogniser could measure one.
    ///
    /// It answers Tesseract's `FirstWordWouldHaveFit`: if that word could have sat at the end of the line above,
    /// the line above ended on purpose rather than running out of room. On a line that opens a list item it is
    /// the *marker* (`1.`, `(2)`, `•`), which is how the indent of that item's continuations is measured rather
    /// than guessed. Optional because synthetic lines (tests, the checks) have no word boxes, and a line with no
    /// measured word simply doesn't use those rules.
    public var firstWordWidth: CGFloat?
    /// Median gap between the words on this line, measured the same way. `TextBlockBuilder` takes the median of
    /// these across the page as the width of a space — the unit every tolerance in the ladder is expressed in.
    /// Nil for a line whose text has no spaces (Chinese, or a single word), which is why the page keeps a
    /// fallback.
    public var wordGap: CGFloat?

    public init(text: String, rect: CGRect, firstWordWidth: CGFloat? = nil, wordGap: CGFloat? = nil,
                glyphs: [OCRGlyph] = []) {
        self.text = text
        self.rect = rect
        self.firstWordWidth = firstWordWidth
        self.wordGap = wordGap
        self.glyphs = glyphs
    }
}

public enum VisionGeometry {
    /// Converts a Vision `boundingBox` (normalized 0...1, origin bottom-left)
    /// into a rect inside `bounds`, which uses a top-left origin.
    public static func rect(fromNormalized b: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + b.minX * bounds.width,
               y: bounds.minY + (1 - b.maxY) * bounds.height,
               width: b.width * bounds.width,
               height: b.height * bounds.height)
    }
}

/// A paragraph made of one or more adjacent OCR lines; the unit that gets translated.
public struct TextBlock: Equatable, Sendable {
    public var id: Int
    public var lines: [OCRLine]

    public init(id: Int, lines: [OCRLine]) {
        self.id = id
        self.lines = lines
    }

    public var rect: CGRect {
        lines.reduce(CGRect.null) { $0.union($1.rect) }
    }

    public var lineHeight: CGFloat {
        guard !lines.isEmpty else { return 0 }
        return lines.reduce(0) { $0 + $1.rect.height } / CGFloat(lines.count)
    }

    /// Lines joined into one string. A trailing hyphen is treated as a word break, and two CJK lines are joined
    /// without a space — Chinese has no word spaces, and putting one in shows up as「自动检查更新 保存到下载」.
    public var text: String {
        var result = ""
        for line in lines {
            let t = line.text.trimmingCharacters(in: .whitespaces)
            guard !result.isEmpty else {
                result = t
                continue
            }
            if result.hasSuffix("-"), Self.joinsAcrossHyphen(t, after: result) {
                result.removeLast()
                result += t
            } else if TextBlockBuilder.needsSpace(between: result, and: t) {
                result += " " + t
            } else {
                result += t
            }
        }
        return result
    }

    /// Whether what follows a line-final hyphen carries on the same word. Lowercase and digits are the obvious
    /// cases; a capital joins when the letter *before* the hyphen is lowercase, which is how `Table-Former` and
    /// `iOS-` read as one word (docling's rule, and it covers the `Table-Former` case ours used to split).
    ///
    /// Takes the text so far rather than reading `self.text`: this runs *inside* that property's own body, and
    /// asking for it again recursed until the process died.
    private static func joinsAcrossHyphen(_ next: String, after soFar: String) -> Bool {
        guard let first = next.first else { return false }
        if first.isLowercase || first.isNumber { return true }
        guard first.isUppercase, let before = soFar.dropLast().last else { return false }
        return before.isLowercase
    }
}

public enum TextBlockBuilder {
    /// Whether a line joins the block above it. The indentation cases carry the indent the continuation sits
    /// at **relative to the block's first line**, which is the origin `bodyIndent` is kept in.
    enum Continuation: Equatable {
        case flush
        case hyphen
        case margin(CGFloat)
        case indent(CGFloat)
    }

    /// What the ladder needs to know about the page rather than about the two lines in hand.
    struct Context {
        var metrics: PageMetrics
        /// Where this line's column ends.
        var columnRight: CGFloat
        /// The first line of the block being extended.
        var blockFirst: OCRLine
        /// The indent that block's continuations sit at, once one has been seen.
        var bodyIndent: CGFloat?
    }

    /// The page-wide numbers every tolerance is expressed in.
    struct PageMetrics {
        /// Width of a space here: the median of the *measured* interword gaps, or a quarter of the median line
        /// height when nothing could be measured (synthetic lines, a page of Chinese). Tesseract takes this from
        /// the OCR engine; measuring it is what lets the tolerances be 4/5 of a real space instead of a guess.
        var space: CGFloat
        /// This page's own line pitch, as the ink gap between two neighbouring lines. Zero when a page is too
        /// small to tell, which leaves the absolute cap in charge.
        var pitch: CGFloat
        let lines: [OCRLine]

        init(_ lines: [OCRLine]) {
            self.lines = lines
            let gaps = lines.compactMap(\.wordGap)
            space = gaps.isEmpty ? Self.median(lines.map(\.rect.height)) * 0.25 : Self.median(gaps)
            pitch = Self.median(Self.verticalGaps(lines))
        }

        /// Where the column this line sits in ends: the upper quartile of the right edges of the lines it
        /// overlaps horizontally, never less than its own.
        ///
        /// A quartile rather than the maximum: one line running wider than everything else — a heading over
        /// two columns, a long URL — would otherwise put the margin out of reach and rule 4 would call every
        /// full line "not full". Local rather than page-wide for the same reason: the page maximum is usually
        /// some sidebar, and every line of the main column would then look short.
        func columnRight(of index: Int) -> CGFloat {
            let line = lines[index]
            let sharing = lines.enumerated().compactMap { other -> CGFloat? in
                let shared = min(line.rect.maxX, other.element.rect.maxX) - max(line.rect.minX, other.element.rect.minX)
                guard shared > 0, shared >= min(line.rect.width, other.element.rect.width) * 0.5 else { return nil }
                return other.element.rect.maxX
            }
            guard !sharing.isEmpty else { return line.rect.maxX }
            return max(line.rect.maxX, Self.percentile(sharing, 0.75))
        }

        /// Ink gaps between a line and the next one down in the same column — this page's leading.
        static func verticalGaps(_ lines: [OCRLine]) -> [CGFloat] {
            var gaps: [CGFloat] = []
            for (index, line) in lines.enumerated() where index + 1 < lines.count {
                for other in lines[(index + 1)...] {
                    let shared = min(line.rect.maxX, other.rect.maxX) - max(line.rect.minX, other.rect.minX)
                    guard shared > 0, shared >= min(line.rect.width, other.rect.width) * 0.5 else { continue }
                    let gap = other.rect.minY - line.rect.maxY
                    // Only plausible leading: half a page of white is a section break, not a line spacing.
                    if gap >= -line.rect.height * 0.3, gap < line.rect.height * 2 { gaps.append(gap) }
                    break
                }
            }
            return gaps
        }

        static func median(_ values: [CGFloat]) -> CGFloat {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let middle = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        }

        static func percentile(_ values: [CGFloat], _ fraction: CGFloat) -> CGFloat {
            guard let first = values.sorted().first else { return 0 }
            let sorted = values.sorted()
            guard sorted.count > 1 else { return first }
            let position = fraction * CGFloat(sorted.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, sorted.count - 1)
            return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - CGFloat(lower))
        }
    }

    /// Groups lines into paragraphs: a line joins the last block it can, otherwise it opens one.
    ///
    /// The ladder in `continuation` is a small version of what Tesseract's `paragraphs.cpp` does with paragraph
    /// models fitted across a whole page: several weak signals voted in order, strongest first, rather than one
    /// geometric test. The single test we had ("similar height, close together, left edges aligned") cannot tell
    /// a list's *indented continuation*, which should join, from the *next list item*, which should not — and
    /// those two are the mistakes users see.
    public static func group(_ lines: [OCRLine]) -> [TextBlock] {
        let sorted = lines.sorted {
            $0.rect.minY != $1.rect.minY ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX
        }
        let metrics = PageMetrics(sorted)
        var groups: [[OCRLine]] = []
        /// The indent each block's continuations sit at, learned from the first one that joined by indentation.
        var bodyIndents: [CGFloat?] = []
        for (index, line) in sorted.enumerated() {
            var target: Int?
            var reason: Continuation?
            for candidate in groups.indices.reversed() {
                let context = Context(metrics: metrics, columnRight: metrics.columnRight(of: index),
                                      blockFirst: groups[candidate][0], bodyIndent: bodyIndents[candidate])
                if let found = continuation(groups[candidate][groups[candidate].count - 1], line, context: context) {
                    target = candidate
                    reason = found
                    break
                }
            }
            guard let target else {
                groups.append([line])
                bodyIndents.append(nil)
                continue
            }
            if case let .indent(offset)? = reason, bodyIndents[target] == nil { bodyIndents[target] = offset }
            groups[target].append(line)
        }
        return groups.enumerated().map { TextBlock(id: $0.offset, lines: $0.element) }
    }

    /// Whether `lower` carries on `upper`, and why. The ladder, strongest first:
    ///
    /// 0. the two lines have to look like the same kind of text, and sit no further apart than this page's own
    ///    leading allows;
    /// 1. a line that opens a list item never joins the one above it, however tight the leading is;
    /// 2. flush left — the ordinary wrapped line, tolerance 4/5 of a *measured* space (Tesseract's `Epsilon`);
    /// 3. `upper` ends on a hyphen, so a word is broken across the two;
    /// 4. `upper` ran into the column's right margin, so it was cut off rather than ended — Tesseract's "would
    ///    the first word of this line have fitted on the previous one?", which holds however far the
    ///    continuation is indented;
    /// 5. the sentence is not over and `lower` is indented the way this kind of line is indented: a Latin line
    ///    carrying on a sentence starts lowercase, a list item's continuation lines up with its own text, and
    ///    anything else gets up to 1.6 line heights.
    static func continuation(_ upper: OCRLine, _ lower: OCRLine, context: Context) -> Continuation? {
        let small = min(upper.rect.height, lower.rect.height)
        let large = max(upper.rect.height, lower.rect.height)
        // Same font, different glyphs: Vision's box runs from the top of the tallest glyph to the bottom of the
        // lowest, so a line of capitals measures a lot shorter than one with descenders — 13 against 19 pt in a
        // fixture rendered from one font size, 1.46. A heading against body text is 1.86 and up. 1.6 sits
        // between the two with room on both sides; the old 1.4 sat inside the first group and split paragraphs
        // whose second line happened to have a `p` in it.
        guard small > 0, large / small < 1.6 else { return nil }

        // Two lines of one paragraph are never more than 1.2 line heights apart, nor much further than this
        // page's own leading. A flat 0.8 broke airy text apart — 1.8x leading puts an ordinary line gap over 0.8
        // already — while letting tight list items merge.
        let gap = lower.rect.minY - upper.rect.maxY
        let limit = min(small * 1.2, max(context.metrics.pitch * 1.5, small * 0.6))
        guard gap >= -small * 0.3, gap < limit else { return nil }

        if startsListItem(lower.text) { return nil }

        let space = context.metrics.space
        let offset = lower.rect.minX - upper.rect.minX
        // Rule 5 measures against the block's *first* line, not the line just above: a continuation of line
        // five is indented the same as a continuation of line one, and that is what `bodyIndent` holds.
        let fromBlockStart = lower.rect.minX - context.blockFirst.rect.minX
        if abs(offset) <= max(2, space * 0.8) { return .flush }
        if endsWithHyphen(upper.text) { return .hyphen }
        // Everything below needs the sentence to be unfinished: a line that ends a thought ends its paragraph.
        guard !endsSentence(upper.text) else { return nil }

        if let word = lower.firstWordWidth, context.columnRight - upper.rect.maxX < word { return .margin(fromBlockStart) }
        if startsLowercase(lower.text), fromBlockStart >= -space, fromBlockStart <= small * 2.5 { return .indent(fromBlockStart) }
        if let expected = expectedIndent(context), abs(fromBlockStart - expected) <= space * 2 { return .indent(fromBlockStart) }
        if fromBlockStart >= -space, fromBlockStart <= small * 1.6 { return .indent(fromBlockStart) }
        return nil
    }

    /// Where this block's continuation lines are expected to start, relative to its first line.
    ///
    /// A list item's text starts one marker plus one space in, and the marker's width was *measured* — which is
    /// what makes a nested list work without a notion of levels: `a)` is narrower than `1.`, so each item's
    /// continuations line up under their own marker. Failing that, it is whatever the first continuation that
    /// joined turned out to be.
    static func expectedIndent(_ context: Context) -> CGFloat? {
        if let learned = context.bodyIndent { return learned }
        guard startsListItem(context.blockFirst.text), let marker = context.blockFirst.firstWordWidth else { return nil }
        return marker + context.metrics.space
    }

    /// Whether a line starts like a sentence carrying on. Chinese has no case, so this only ever fires for Latin
    /// text — which is where "no full stop above, lowercase below" is nearly decisive.
    static func startsLowercase(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).first?.isLowercase ?? false
    }

    /// A line that opens a list item: `1.`, `2)`, `(3)`, `A.`, `iv.`, `•`, `-`, `第 3 条`, `一、`.
    ///
    /// The marker has to be followed by a space (or be the whole line) so that a decimal like `1.5 GHz` at the
    /// start of a line is not mistaken for item 1.
    static func startsListItem(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        let patterns = [
            #"^([0-9]+|[A-Za-z]|[ivxIVX]{1,4}|[0-9]+\.[0-9]+)[.)](?=\s|$)"#,  // 1.  2)  A.  iv.  3.5.
            #"^[（(]\s*([0-9]+|[A-Za-z]|[ivxIVX]{1,4})\s*[）)](?=\s|$)"#,      // (2)  （三）
            #"^[-–—•·*‣▪◦●○]\s"#,                                             // bullets
            #"^第\s*[0-9一二三四五六七八九十百千]+\s*[条点章节项]"#,              // 第 3 条
            #"^[一二三四五六七八九十]+\s*[、.](?=\s|$)"#,                        // 一、
        ]
        return patterns.contains { t.range(of: $0, options: [.regularExpression]) != nil }
    }

    /// Whether the line ends a thought. A colon or a semicolon does not count: both mean the sentence carries on,
    /// and a list item often breaks right after one. Trailing quotes and brackets are looked through, so
    /// `…选择 "Download as PNG"。` counts as ended.
    static func endsSentence(_ text: String) -> Bool {
        let closers = "\"'”’)）]】》」』"
        var t = text.trimmingCharacters(in: .whitespaces)
        while let last = t.last, closers.contains(last) { t.removeLast() }
        guard let last = t.last else { return false }
        return ".!?。！？…؟".contains(last)
    }

    static func endsWithHyphen(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.hasSuffix("-") || t.hasSuffix("\u{AD}")
    }

    /// Whether a space belongs between two lines being joined. Not between two CJK characters: Chinese has no
    /// word spaces, and one put in on every join showed up as「自动检查更新 保存到下载」.
    public static func needsSpace(between left: String, and right: String) -> Bool {
        guard let a = left.last, let b = right.first else { return false }
        return !(isCJK(a) && isCJK(b))
    }

    /// CJK characters, their punctuation and fullwidth forms: no space goes between two of these, and one of
    /// them is a word as far as `firstWordWidth` is concerned.
    public static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
                return true
            default:
                return false
            }
        }
    }

    /// Whether a block is worth sending for translation: it must be written in the language the translation
    /// is going *from*, and must not be a bare URL, path or number.
    ///
    /// `source` is that language — normally the foreign one, but on a Chinese screen the translation turns
    /// around and it is the Chinese blocks that get sent. Defaults to the foreign case, which is what the
    /// app did before it could turn around.
    public static func shouldTranslate(_ text: String, from source: ScreenLanguage = .english) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var latin = 0
        var cjk = 0
        for scalar in t.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF: cjk += 1
            default: break
            }
        }
        switch source {
        case .chinese, .japanese, .korean:
            // The three CJK languages are written from the same character ranges, and kana and hangul are both
            // counted as CJK here — that is what `ScreenLanguage.detect` leaned on to tell them apart. Asking
            // Japanese or Korean text for two *Latin* letters dropped every block on those screens, so 截图翻译
            // said 「没有找到需要翻译的外文」 about a screen it had just called 日文.
            //
            // Deliberately looser than the foreign case: any real CJK in the block makes it text in that
            // language. A product name or a shortcut sitting inside the sentence is normal, and missing a line
            // the user asked to translate costs more than sending one that comes back unchanged.
            guard cjk >= 2 else { return false }
        default:
            guard latin >= 2, cjk < latin else { return false }
        }
        let skipPatterns = [
            #"^(https?://|www\.)\S+$"#,   // URL
            #"^[~/.]?[\w.-]*/[\w./-]*$"#,  // file path
            #"^[\w.+-]+@[\w-]+\.[\w.]+$"#, // email
            #"^v?\d+(\.\d+)+[a-z]?$"#,     // version number
        ]
        return !skipPatterns.contains { t.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}
