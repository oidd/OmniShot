import CoreGraphics
import Foundation

/// What a piece of text looks like, when the auto-mask tool is deciding which click a ⇧ should stand for.
///
/// The category is not what decides a plain click (that is always "the same text"), it is what ⇧ acts on —
/// 「所有电话」.
public enum AutoMaskCategory: String, Sendable {
    case phone, email, idNumber, date, time, number, url, amount
}

/// One clickable target: a word, or a whole repeated line. Rects are in the capture view's coordinates.
public struct AutoMaskTarget: Equatable, Sendable {
    public var id: Int
    public var text: String
    public var rect: CGRect
    public var category: AutoMaskCategory?
    /// Same normalized text — the set one plain click masks together.
    public var groupKey: String
    /// How many places share that text.
    public var groupCount: Int
    /// How many places share the category. Zero when there is none.
    public var categoryCount: Int
    /// A whole repeated line or paragraph rather than a word or a phrase inside a line.
    public var isLine: Bool
}

/// Finds the units a click can act on in a screen of recognized text: words, repeated phrases, repeated lines
/// and repeated paragraphs.
///
/// Several levels are kept because no single one is right. A phone number is a word. 「Approved by admin」 is a
/// phrase inside two different rows. A watermark is a whole line. A sentence that wraps differently in its two
/// appearances is a paragraph. The pointer picks between them: a typed value wins over the phrase containing
/// it, and otherwise the largest repeated unit wins.
public enum AutoMaskDetector {
    /// `blocks` are the paragraphs the recogniser (or `TextBlockBuilder`) worked out. They are what catches a
    /// repeated sentence that wraps over two lines, which no single line can.
    public static func targets(from lines: [OCRLine], blocks: [TextBlock] = [],
                               in selection: CGRect) -> [AutoMaskTarget] {
        var lineTokens: [[Token]] = []
        for (lineIndex, line) in lines.enumerated() {
            var tokens = mergeSplitPhoneNumbers(tokenize(line, lineIndex: lineIndex))
            for index in tokens.indices { classify(&tokens[index]) }
            lineTokens.append(tokens)
        }
        let tokens = lineTokens.flatMap { $0 }

        var valueCounts: [String: Int] = [:]
        var categoryCounts: [AutoMaskCategory: Int] = [:]
        for token in tokens {
            valueCounts[token.normalized, default: 0] += 1
            if let category = token.category { categoryCounts[category, default: 0] += 1 }
        }

        var targets: [AutoMaskTarget] = []

        // Words: the finest unit, and what a typed value (a phone number inside a longer repeated line) wins
        // with when the pointer is over it.
        for token in tokens where !token.text.isEmpty {
            let rect = inflate(token.rect, in: selection)
            // A glyph box that falls entirely outside the selection (a line clipped at the edge) has nothing
            // left to mask.
            guard !rect.isNull, !rect.isEmpty else { continue }
            targets.append(AutoMaskTarget(
                id: 0, text: token.text, rect: rect,
                category: token.category,
                groupKey: "value:" + token.normalized,
                groupCount: valueCounts[token.normalized] ?? 1,
                categoryCount: token.category.map { categoryCounts[$0] ?? 0 } ?? 0,
                isLine: false))
        }

        // Phrases: the same stretch of words appearing inside two different lines — 「已通过审核」, 「Approved
        // by admin」 — which neither the word targets nor the whole-line target can express.
        targets.append(contentsOf: phraseTargets(lineTokens, in: selection))

        // Repeated whole lines.
        var lineCounts: [String: Int] = [:]
        for line in lines {
            let key = normalizedLine(line.text)
            guard !key.isEmpty else { continue }
            lineCounts[key, default: 0] += 1
        }
        for line in lines {
            let key = normalizedLine(line.text)
            guard !key.isEmpty, (lineCounts[key] ?? 0) >= 2 else { continue }
            let rect = inflate(line.rect, in: selection)
            guard !rect.isNull, !rect.isEmpty else { continue }
            targets.append(AutoMaskTarget(
                id: 0, text: line.text.trimmingCharacters(in: .whitespacesAndNewlines),
                rect: rect, category: nil,
                groupKey: "line:" + key, groupCount: lineCounts[key] ?? 1,
                categoryCount: 0, isLine: true))
        }

        // Repeated paragraphs: the same sentence or two somewhere else, even when it wraps differently.
        var blockCounts: [String: Int] = [:]
        for block in blocks where block.lines.count >= 2 {
            let key = normalizedLine(block.text)
            guard !key.isEmpty else { continue }
            blockCounts[key, default: 0] += 1
        }
        for block in blocks where block.lines.count >= 2 {
            let key = normalizedLine(block.text)
            guard !key.isEmpty, (blockCounts[key] ?? 0) >= 2 else { continue }
            let rect = inflate(block.rect, in: selection)
            guard !rect.isNull, !rect.isEmpty else { continue }
            targets.append(AutoMaskTarget(
                id: 0, text: block.text, rect: rect, category: nil,
                groupKey: "block:" + key, groupCount: blockCounts[key] ?? 1,
                categoryCount: 0, isLine: true))
        }

        // Reading order, and stable ids for the self-checks.
        targets.sort { a, b in
            let ay = (a.rect.minY / 6).rounded(.down), by = (b.rect.minY / 6).rounded(.down)
            return ay == by ? a.rect.minX < b.rect.minX : ay < by
        }
        for index in targets.indices { targets[index].id = index }
        return targets
    }

    // MARK: - Repeated phrases

    private struct Occurrence {
        var line: Int
        var range: Range<Int>
    }

    private struct Position: Hashable {
        var line: Int
        var token: Int
    }

    /// Every repeated run of two or more words inside a single line. The longest runs win: 「Approved by admin」
    /// is one target, not that plus 「Approved by」 and 「by admin」. A run that covers the whole line in every
    /// occurrence is left to the line target, which already says the same thing.
    static func phraseTargets(_ lines: [[Token]], in selection: CGRect) -> [AutoMaskTarget] {
        var groups: [String: [Occurrence]] = [:]
        var sample: [String: [Token]] = [:]
        for (lineIndex, tokens) in lines.enumerated() {
            guard tokens.count >= 2 else { continue }
            for length in 2...min(tokens.count, 12) {
                for start in 0...(tokens.count - length) {
                    let slice = Array(tokens[start..<(start + length)])
                    let key = slice.map(\.normalized).joined(separator: "\u{1F}")
                    groups[key, default: []].append(Occurrence(line: lineIndex, range: start..<(start + length)))
                    if sample[key] == nil { sample[key] = slice }
                }
            }
        }

        func worth(_ key: String) -> Bool {
            guard let slice = sample[key] else { return false }
            let text = slice.map(\.text).joined()
            if text.contains(where: \.isNumber) { return true }
            if text.filter(isIdeograph).count >= 2 { return true }
            // Latin needs a real phrase. 「of the」 and 「in a」 repeat on every page and tell the user nothing.
            let latin = text.unicodeScalars.filter { $0.value < 0x80 && CharacterSet.letters.contains($0) }.count
            return latin >= 6
        }

        let ordered = groups
            .filter { key, occurrences in occurrences.count >= 2 && worth(key) }
            .sorted { $0.value[0].range.count > $1.value[0].range.count }

        var covered: Set<Position> = []
        var out: [AutoMaskTarget] = []
        for (key, occurrences) in ordered {
            let positions = occurrences.flatMap { occurrence in
                occurrence.range.map { Position(line: occurrence.line, token: $0) }
            }
            // A whole repeated line is already a target.
            if occurrences.allSatisfy({ $0.range.count == lines[$0.line].count }) {
                covered.formUnion(positions)
                continue
            }
            if positions.allSatisfy({ covered.contains($0) }) { continue }
            for occurrence in occurrences {
                let slice = Array(lines[occurrence.line][occurrence.range])
                let rect = inflate(slice.reduce(CGRect.null) { $0.union($1.rect) }, in: selection)
                guard !rect.isNull, !rect.isEmpty else { continue }
                out.append(AutoMaskTarget(
                    id: 0, text: join(slice), rect: rect, category: nil,
                    groupKey: "phrase:" + key, groupCount: occurrences.count,
                    categoryCount: 0, isLine: false))
            }
            covered.formUnion(positions)
        }
        return out
    }

    private static func join(_ tokens: [Token]) -> String {
        var result = ""
        for token in tokens {
            if result.isEmpty { result = token.text; continue }
            result += TextBlockBuilder.needsSpace(between: result, and: token.text)
                ? " " + token.text : token.text
        }
        return result
    }

    // MARK: - Tokens

    struct Token {
        var text: String
        var rect: CGRect
        var lineIndex: Int
        var category: AutoMaskCategory?
        var normalized = ""
    }

    /// Splits a line into words. The splits are whitespace, a change between CJK and Latin, label punctuation
    /// and a measured word gap — so 「手机号：13800138000」 becomes 「手机号」 and 「13800138000」 even though
    /// there is no space in it.
    ///
    /// Two recognisers feed this. The line recogniser gives one box per character, and its `string` sometimes
    /// drops the spaces (`Phone+8613800138001`). The document recogniser keeps the spaces but gives one box per
    /// *word*. When the glyph count matches the non-space characters, the characters of `line.text` are walked
    /// and each is given the next box — which reads both shapes correctly.
    static func tokenize(_ line: OCRLine, lineIndex: Int) -> [Token] {
        guard !line.glyphs.isEmpty else {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [Token(text: text, rect: line.rect, lineIndex: lineIndex)]
        }
        var tokens: [Token] = []
        var run: [OCRGlyph] = []
        var runIsCJK: Bool?
        var previous: OCRGlyph?
        // A word gap is an order of magnitude wider than the kern between two letters; a quarter of the line
        // height is the line between them.
        let gapLimit = max(2, line.rect.height * 0.22)

        func flush() {
            defer { run = []; runIsCJK = nil }
            guard !run.isEmpty else { return }
            var text = run.map(\.text).joined()
            while let first = text.first, isEdgePunctuation(first) { text.removeFirst() }
            while let last = text.last, isEdgePunctuation(last) { text.removeLast() }
            guard !text.isEmpty else { return }
            let rect = run.reduce(CGRect.null) { $0.union($1.rect) }
            tokens.append(Token(text: text, rect: rect, lineIndex: lineIndex))
        }

        let aligned = line.text.filter { !$0.isWhitespace }.count == line.glyphs.count
        let characters = aligned ? Array(line.text) : line.glyphs.map { $0.text.first ?? " " }
        var glyphIndex = 0
        for character in characters {
            if character.isWhitespace {
                // Walking the glyphs directly, the space has a box of its own and must be consumed; walking
                // `line.text`, the boxes line up with the non-space characters only.
                if !aligned { glyphIndex += 1 }
                flush()
                continue
            }
            guard glyphIndex < line.glyphs.count else { break }
            let glyph = line.glyphs[glyphIndex]
            glyphIndex += 1
            guard !isLabelPunctuation(character) else { flush(); continue }
            if let previous, gap(previous.rect, glyph.rect) > gapLimit { flush() }
            let isCJK = isIdeograph(character)
            if let current = runIsCJK, current != isCJK { flush() }
            if runIsCJK == nil { runIsCJK = isCJK }
            run.append(glyph)
            previous = glyph
        }
        flush()
        return tokens
    }

    /// `+86 138 0013 8000` is one number, but Vision hands it over in four pieces. Only runs that begin with a
    /// `+` or `(` are joined: without that guard a column of separate numbers on one line (a date written with
    /// spaces, say) would be fused into a phone number that is not there.
    static func mergeSplitPhoneNumbers(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        var index = 0
        while index < tokens.count {
            var current = tokens[index]
            let startsLikeNumber = current.text.hasPrefix("+") || current.text.hasPrefix("(")
            if startsLikeNumber, digitCount(current.text) >= 1 {
                while index + 1 < tokens.count,
                      tokens[index + 1].lineIndex == current.lineIndex,
                      digitCount(current.text) + digitCount(tokens[index + 1].text) <= 15,
                      tokens[index + 1].text.allSatisfy(isNumberFragment),
                      gap(current.rect, tokens[index + 1].rect) <= max(2, current.rect.height * 0.7) {
                    current.text += " " + tokens[index + 1].text
                    current.rect = current.rect.union(tokens[index + 1].rect)
                    index += 1
                }
            }
            out.append(current)
            index += 1
        }
        return out
    }

    static func classify(_ token: inout Token) {
        let text = halfWidth(token.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let digits = text.filter(\.isNumber)
        let bareNumber = text.filter { !" ()-+".contains($0) }

        if isEmail(lower) {
            token.category = .email
            token.normalized = lower
        } else if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") {
            token.category = .url
            token.normalized = lower
        } else if single(text, #"^\d{17}[\dXx]$"#) || single(text, #"^\d{15}$"#) {
            token.category = .idNumber
            token.normalized = digits
        } else if single(text, #"^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}$"#)
                    || single(text, #"^\d{4}年\d{1,2}月(\d{1,2}日?)?$"#) {
            token.category = .date
            token.normalized = text
        } else if single(text, #"^\d{1,2}:\d{2}(:\d{2})?$"#) {
            token.category = .time
            token.normalized = text
        } else if single(bareNumber, #"^\+?\d{7,15}$"#) {
            // Keep the leading + out of the group key: `+86 138…` and `138…` are the same number to a person.
            token.category = .phone
            token.normalized = digits
        } else if single(text, #"^[¥$€￥]\s?\d{1,3}(,\d{3})*(\.\d{1,2})?$"#)
                    || single(text, #"^\d{1,3}(,\d{3})+(\.\d{1,2})?$"#)
                    || single(text, #"^\d+\.\d{2}$"#) {
            token.category = .amount
            token.normalized = text.filter { $0 != "," && !$0.isWhitespace }
        } else if single(text, #"^\d{4,}$"#) {
            token.category = .number
            token.normalized = digits
        } else {
            token.category = nil
            token.normalized = normalizedLine(text)
        }
    }

    // MARK: - What is worth a frame

    // MARK: - Helpers

    /// A little air around the recognized box: blur and pixels at the very edge of a tight box can leave a
    /// readable sliver of the original.
    static func inflate(_ rect: CGRect, in selection: CGRect) -> CGRect {
        let pad = min(3, max(1.5, rect.height * 0.12))
        return rect.insetBy(dx: -pad, dy: -pad).intersection(selection)
    }

    static func normalizedLine(_ text: String) -> String {
        halfWidth(text).trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func halfWidth(_ text: String) -> String {
        text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
    }

    static let labelPunctuation: Set<Character> = [
        "，", "。", "、", "；", "：", "！", "？", "（", "）", "【", "】", "《", "》", "〈", "〉",
        "「", "」", "『", "』", "〔", "〕", "“", "”", "‘", "’", "…", "·",
        "(", ")", "[", "]", "{", "}", ";", "!", "?", "\"", "'",
    ]

    /// Punctuation that can trim the ends of a run but never splits it: a colon is part of `10:30`, a slash part
    /// of a URL, and `@ . _ - + ,` are all inside things people want to mask.
    static let edgePunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "。", "，", "；", "：", "！", "？"]

    static func isLabelPunctuation(_ character: Character) -> Bool { labelPunctuation.contains(character) }
    static func isEdgePunctuation(_ character: Character) -> Bool { edgePunctuation.contains(character) }

    static func isIdeograph(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }

    static func isNumberFragment(_ character: Character) -> Bool {
        character.isNumber || "+()- ".contains(character)
    }

    static func digitCount(_ text: String) -> Int { text.filter(\.isNumber).count }

    static func single(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func isEmail(_ text: String) -> Bool {
        guard let at = text.firstIndex(of: "@"), at != text.startIndex else { return false }
        let domain = text[text.index(after: at)...]
        return !domain.isEmpty && domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
            && !text.contains(where: \.isWhitespace)
    }

    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX))
        let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
        return max(dx, dy)
    }
}
