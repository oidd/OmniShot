import CoreGraphics
import Foundation

/// The writing system a piece of text is written in: decides which ink ratio turns into a font size.
public enum TextScript: Equatable, Sendable {
    case latin, cjk, kana

    /// The script most of `text` belongs to. A line is Japanese when kana outnumber everything else: that is
    /// when its glyphs are shorter than kanji, which is what the ratio difference is for.
    public static func of(_ text: String) -> TextScript {
        var latin = 0, han = 0, kana = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            case 0x3040...0x30FF: kana += 1 // hiragana + katakana
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF: han += 1 // CJK ideographs + hangul
            default: break
            }
        }
        if kana > han + latin { return .kana }
        return han > latin ? .cjk : .latin
    }

    /// Letters, digits and ascenders reach the cap height; only x-height letters (acemnorsuvwxz) don't.
    /// The dots of i and j sit up there too, which is the only ink a line like "minimum" has above the waist.
    static func reachesCapHeight(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x30...0x39: return true // A-Z, 0-9
            case 0x62, 0x64, 0x66, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x74: return true // b d f h i j k l t
            case 0x4E00...0x9FFF, 0x3040...0x30FF, 0xAC00...0xD7AF: return true // CJK has no x-height
            default: break
            }
        }
        return false
    }
}

/// What the pixels of one text block say about how it was typeset.
public struct InkMetrics: Equatable, Sendable {
    public var background: RGBA
    public var foreground: RGBA
    /// The ring around the block is one flat color, so the original text can be erased with a plain fill.
    public var backgroundIsSolid: Bool
    /// Ink body top / baseline / bottom, in pixels from the top of the image.
    public var bodyTop: Double
    public var baseline: Double
    public var bodyBottom: Double
    public var inkLeft: Double
    public var inkRight: Double
    /// Mean horizontal ink run, i.e. the typical stem thickness, in pixels.
    public var strokeWidth: Double
    /// Font size in pixels, or nil when there was too little ink to measure (the caller falls back to
    /// the line box height, which is far noisier but better than nothing).
    public var fontSize: Double?
    /// Horizontal space from the block to its container's edge, in pixels; nil when it runs to the image edge.
    /// Only a whole block knows these: they are measured across the container the text sits in.
    public var leftMargin: Int? = nil
    public var rightMargin: Int? = nil

    /// Where a replacement line should sit vertically: the middle of the ink, which for Latin means the
    /// middle of the x-height and for CJK the middle of the glyph body.
    public func visualCenter(_ script: TextScript) -> Double {
        switch script {
        case .latin: return (bodyTop + baseline) / 2
        case .cjk, .kana: return (bodyTop + bodyBottom) / 2
        }
    }

    /// Text in the middle of its container (a button, a centered title) should stay centered.
    public var isCentered: Bool {
        guard let l = leftMargin, let r = rightMargin else { return false }
        return abs(l - r) <= max(6, (l + r) / 5)
    }

    /// Whether the original was set in a bold face. A stem is thick relative to the size of the letters it
    /// belongs to, which is why the size has to come from the ink first: against the line box every weight
    /// looks the same.
    public var isBold: Bool {
        guard let size = fontSize, size > 0 else { return false }
        return (strokeWidth - 0.1) / size > InkReader.boldStrokeRatio
    }
}

/// Measures a text block from the pixels it was drawn with. This is what makes a translation look like it
/// belongs in the original: a line's box from the OCR is far too loose to derive a font size from
/// (it varies by 0.8–1.8× of the real size), while the ink inside it is what the eye compares against.
public enum InkReader {
    /// Coverage below this share of the ink peak is anti-aliasing residue, not strokes.
    static let gridFloor = 0.25
    /// A row/column joins the ink run while the gap it leaves is no wider than this share of the body height.
    static let maxGapRatio = 0.15
    /// How far the ink may break horizontally (word and glyph gaps) before it stops being one span.
    static let columnGapRatio = 0.35
    /// Columns this full are rules (table borders, dividers), not glyphs.
    static let ruleFraction = 0.85
    /// Background colors this close (per channel) count as the same color.
    public static let solidTolerance = 12

    /// Stem width (less one pixel of anti-aliasing) as a share of the font size, above which text counts as
    /// bold. Measured in `InkMetricsTests.boldStemsAreToldApartFromRegular`: regular faces land at 0.19–0.22
    /// and bold or semibold ones at 0.25 and up.
    ///
    /// CJK lands lower at both weights (regular 0.15, semibold 0.16) and the two are too close to tell apart
    /// at UI sizes, so a Chinese heading comes out regular. Guessing there would just as often make plain
    /// body text bold, which looks worse.
    public static let boldStrokeRatio = 0.235

    /// Measures a paragraph: every line on its own, then the median of what the lines say.
    ///
    /// Measuring the whole block in one go does not work. The box around a four-line paragraph spans the gaps
    /// between its lines, those gaps are narrower than the band's tolerance, so the ink band bridges them and
    /// the paragraph reads as one enormous line — the translation then comes out two to three times too big.
    public static func measure(_ buffer: PixelBuffer, lines: [OCRLine], ring: Int = 2) -> InkMetrics {
        let content = lines.map(\.rect).reduce(CGRect.null) { $0.union($1) }.integral.intersection(
            CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height))
        guard content.width >= 2, content.height >= 2 else { return empty(buffer) }

        let ringPixels = ColorSampler.ringPixels(buffer, rect: content, ring: ring)
        let background = ColorSampler.median(ringPixels)
        let solid = !ringPixels.isEmpty
            && Double(ringPixels.filter { channelDistance($0, background) <= solidTolerance }.count) / Double(ringPixels.count) >= 0.9
        let margins = ColorSampler.margins(buffer, content, background)

        let measured = lines.compactMap { measure(buffer, line: $0.rect, text: $0.text, background: background, ring: ring) }
        if ProcessInfo.processInfo.environment["OMNISHOT_DEBUG_INK"] != nil {
            print("   BLOCK \(lines.count) lines: sizes \(measured.compactMap(\.fontSize)) strokes \(measured.map { (($0.strokeWidth - 0.1) / ($0.fontSize ?? 1) * 1000).rounded() / 1000 })")
        }
        guard let first = measured.first else { return empty(buffer, background: background, solid: solid) }
        return InkMetrics(background: background,
                          foreground: median(measured.map(\.foreground)),
                          backgroundIsSolid: solid,
                          bodyTop: first.bodyTop, baseline: first.baseline, bodyBottom: first.bodyBottom,
                          inkLeft: first.inkLeft, inkRight: first.inkRight,
                          strokeWidth: median(measured.map(\.strokeWidth)),
                          fontSize: median(measured.compactMap(\.fontSize)),
                          leftMargin: margins.0, rightMargin: margins.1)
    }

    private static func median(_ values: [RGBA]) -> RGBA {
        values.isEmpty ? .black : ColorSampler.median(values)
    }

    private static func median(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.sorted()[values.count / 2]
    }

    private static func median(_ values: [Double?]) -> Double? {
        let sizes = values.compactMap { $0 }.sorted()
        return sizes.isEmpty ? nil : sizes[sizes.count / 2]
    }

    /// One line of text: where its ink starts and ends, how thick the strokes are, what color they are.
    static func measure(_ buffer: PixelBuffer, line: CGRect, text: String, background: RGBA, ring: Int) -> InkMetrics? {
        let content = line.integral.intersection(CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height))
        guard content.width >= 2, content.height >= 2 else { return nil }

        // Search a little outside the line box: Vision trims glyph edges, so the ink often sticks out.
        let pad = max(2, (content.height * 0.25).rounded())
        let window = content.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height))
        guard var grid = coverageGrid(buffer, window: window, background: background) else { return nil }
        grid.clearNeighbouringLines()

        let rowGap = max(1, Int((Double(grid.height) * maxGapRatio).rounded()))
        let rows = band(grid.rows, around: grid.height / 2, gap: rowGap, floor: floor(grid.rows))
        if ProcessInfo.processInfo.environment["OMNISHOT_DEBUG_INK"] != nil {
            print("   INK window \(window) \(grid.width)x\(grid.height) pad \(pad) gap \(rowGap) floor \(floor(grid.rows))")
            print("   INK rows \(grid.rows.map { Int($0) })")
        }
        guard let rows, rows.count >= 2, rows.upperBound - rows.lowerBound >= 2 else { return nil }
        let bodyTop = rows.lowerBound, bodyBottom = rows.upperBound - 1

        let baseline = baselineRow(grid, top: bodyTop, bottom: bodyBottom)
        let bodyHeight = Double(bodyBottom - bodyTop + 1)

        // Rules first: they must not count as strokes, and must not extend the ink span. Only worth looking
        // for in a band tall enough to be text — a 4 px synthetic bar is not a table border.
        var columns = grid.columns
        let bandHeight = bodyBottom - bodyTop + 1
        for x in 0..<grid.width where bandHeight >= 8 {
            var drawn = 0
            for y in bodyTop...bodyBottom where grid.coverage[y * grid.width + x] > 0.5 { drawn += 1 }
            if Double(drawn) >= ruleFraction * Double(bandHeight) {
                for y in 0..<grid.height { grid.coverage[y * grid.width + x] = 0 }
                columns[x] = 0
            }
        }

        let span = band(columns, around: grid.width / 2, gap: max(2, Int((bodyHeight * columnGapRatio).rounded())), floor: floor(columns))
        guard let span, span.count >= 2 else { return nil }

        let strokeWidth = strokeWidth(grid, rows: bodyTop...bodyBottom, columns: span.lowerBound..<span.upperBound)
        let foreground = inkColor(grid, buffer, window: window, rows: bodyTop...bodyBottom, columns: span.lowerBound..<span.upperBound, background: background)
        let script = TextScript.of(text)

        return InkMetrics(background: background, foreground: foreground, backgroundIsSolid: true,
                          bodyTop: Double(bodyTop + Int(window.minY)), baseline: Double(baseline + Int(window.minY)),
                          bodyBottom: Double(bodyBottom + Int(window.minY)),
                          inkLeft: Double(span.lowerBound + Int(window.minX)), inkRight: Double(span.upperBound + Int(window.minX)),
                          strokeWidth: strokeWidth, fontSize: fontSize(script, text: text, top: bodyTop, baseline: baseline, bottom: bodyBottom))
    }

    /// Font size in pixels from the ink: how tall the letters actually are, not how tall their box is.
    static func fontSize(_ script: TextScript, text: String, top: Int, baseline: Int, bottom: Int) -> Double? {
        let cap = Double(baseline - top)
        let body = Double(bottom - top + 1)
        let size: Double
        switch script {
        case .latin:
            // Cap height is ~0.72 em; when the line only has x-height letters, x-height is ~0.53 em.
            size = TextScript.reachesCapHeight(text) ? cap / 0.72 : cap / 0.53
        case .cjk:
            size = body / 0.86
        case .kana:
            size = body / 0.80
        }
        // Ink this short cannot be trusted: at 9 pt on a 2x screen the cap is 13 px, below that it is noise.
        return size >= 6 ? size : nil
    }

    /// Whether `rect` (pixels) is empty background. A translation may only grow into space that passes
    /// this, so it can never end up covering something else.
    public static func isBlank(_ buffer: PixelBuffer, rect: CGRect, background: RGBA, tolerance: Int = solidTolerance) -> Bool {
        let area = rect.integral.intersection(CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height))
        guard area.width >= 2, area.height >= 2 else { return false }
        var ink = 0, total = 0
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
                total += 1
                if channelDistance(buffer.pixel(x: x, y: y), background) > tolerance { ink += 1 }
            }
        }
        return total > 0 && Double(ink) / Double(total) < 0.005
    }

    // MARK: - Pixels

    private struct Grid {
        var coverage: [Double]
        var width: Int
        var height: Int
        var rows: [Double]
        var columns: [Double]

        mutating func sums() {
            rows = [Double](repeating: 0, count: height)
            columns = [Double](repeating: 0, count: width)
            for y in 0..<height {
                for x in 0..<width {
                    rows[y] += coverage[y * width + x]
                    columns[x] += coverage[y * width + x]
                }
            }
        }

        /// Drops ink connected to the window's top or bottom edge: in a tightly set paragraph the line boxes
        /// overlap, so the line above and the line below stick into this line's window, and their ink would
        /// otherwise be read as part of it — which made a real email's paragraphs measure twice their size.
        /// The left and right edges are where this line's own first and last glyphs are, so they stay.
        mutating func clearNeighbouringLines() {
            var stack: [Int] = []
            for x in 0..<width {
                for y in [0, height - 1] where coverage[y * width + x] > 0 { stack.append(y * width + x) }
            }
            while let index = stack.popLast() {
                guard coverage[index] > 0 else { continue }
                coverage[index] = 0
                let y = index / width, x = index % width
                for neighbour in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                    where neighbour.0 >= 0 && neighbour.0 < width && neighbour.1 >= 0 && neighbour.1 < height {
                    let next = neighbour.1 * width + neighbour.0
                    if coverage[next] > 0 { stack.append(next) }
                }
            }
            sums()
        }
    }

    /// Coverage is the distance from the background color, normalized to the image's own ink peak, so both
    /// black-on-white and gray-on-white measure the same way.
    private static func coverageGrid(_ buffer: PixelBuffer, window: CGRect, background: RGBA) -> Grid? {
        let width = Int(window.width), height = Int(window.height)
        var distance = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                distance[y * width + x] = Double(channelDistance(buffer.pixel(x: Int(window.minX) + x, y: Int(window.minY) + y), background))
            }
        }
        let peak = percentile(distance, 0.99)
        guard peak >= 24 else { return nil } // No ink here, just noise.
        var coverage = distance.map { $0 / peak }
        for i in coverage.indices where coverage[i] < gridFloor { coverage[i] = 0 }
        for i in coverage.indices where coverage[i] > 1 { coverage[i] = 1 }

        var rows = [Double](repeating: 0, count: height)
        var columns = [Double](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width {
                rows[y] += coverage[y * width + x]
                columns[x] += coverage[y * width + x]
            }
        }
        return Grid(coverage: coverage, width: width, height: height, rows: rows, columns: columns)
    }

    /// The row with the largest single-row drop in coverage: descenders carry little ink, so the biggest
    /// fall marks the baseline rather than the bottom of the box. The drop at the band's own bottom edge
    /// counts too — a line whose ink ends exactly at the baseline has its sharpest fall there.
    private static func baselineRow(_ grid: Grid, top: Int, bottom: Int) -> Int {
        let start = top + (bottom - top) / 2
        var best = start, drop = -Double.infinity
        for y in start...min(bottom, grid.rows.count - 2) {
            let d = grid.rows[y] - grid.rows[y + 1]
            if d > drop { drop = d; best = y + 1 }
        }
        return min(best, bottom)
    }

    /// Ink rows are those carrying a noticeable share of what a typical row of this line carries. Relative to
    /// the *densest* row instead, the tail of a long line (descenders, thin strokes) falls below the bar on
    /// some lines and above it on others, which makes the measured size jitter from line to line.
    private static func floor(_ sums: [Double]) -> Double {
        let drawn = sums.filter { $0 > 0 }.sorted()
        guard let middle = drawn.isEmpty ? nil : drawn[drawn.count / 2] else { return 0 }
        return 0.04 * middle
    }

    /// Stem width from the ink's area and its perimeter: a stroke `w` wide and `L` long has area `w·L` and
    /// exposes about `L` of its edge to the background, so the ratio is the width — whatever the glyphs are.
    ///
    /// Earlier attempts measured the length of horizontal runs. That fails both ways round: a run along the
    /// crossbar of an "e" is as wide as the letter (so "Settings" measured half again as heavy as "Name"),
    /// and in a CJK glyph heavy strokes merge into blobs and disappear into the same filter. Area against
    /// perimeter has neither problem.
    private static func strokeWidth(_ grid: Grid, rows: ClosedRange<Int>, columns: Range<Int>) -> Double {
        var area = 0.0
        var edge = 0.0
        for y in rows {
            for x in columns {
                let coverage = grid.coverage[y * grid.width + x]
                guard coverage > 0 else { continue }
                area += coverage
                let around = (neighbour(grid, y - 1, x) + neighbour(grid, y + 1, x)
                              + neighbour(grid, y, x - 1) + neighbour(grid, y, x + 1)) / 4
                edge += max(0, coverage - around)
            }
        }
        return edge > 0 ? area / edge : 0
    }

    private static func neighbour(_ grid: Grid, _ y: Int, _ x: Int) -> Double {
        guard y >= 0, y < grid.height, x >= 0, x < grid.width else { return 0 }
        return grid.coverage[y * grid.width + x]
    }

    /// The median of the strongest ink pixels: an average would drag the color toward the background through
    /// the anti-aliased edges, which is what makes a translation look washed out.
    private static func inkColor(_ grid: Grid, _ buffer: PixelBuffer, window: CGRect,
                                 rows: ClosedRange<Int>, columns: Range<Int>, background: RGBA) -> RGBA {
        var distances: [Double] = []
        for y in rows { for x in columns { distances.append(grid.coverage[y * grid.width + x]) } }
        guard let strongest = distances.max(), strongest > 0 else { return .black }
        let cutoff = strongest * 0.9
        var colors: [RGBA] = []
        for y in rows {
            for x in columns where grid.coverage[y * grid.width + x] >= cutoff {
                colors.append(buffer.pixel(x: Int(window.minX) + x, y: Int(window.minY) + y))
            }
        }
        return colors.isEmpty ? .black : ColorSampler.median(colors)
    }

    /// The run of rows/columns around `start` that hold ink, bridging gaps no wider than `gap`.
    private static func band(_ sums: [Double], around start: Int, gap: Int, floor: Double) -> Range<Int>? {
        let threshold = max(0.5, floor)
        let seed = (start..<sums.count).first { sums[$0] >= threshold } ?? (0..<start).last { sums[$0] >= threshold }
        guard let seed else { return nil }
        var low = seed, high = seed, missed = 0
        var y = seed
        while y > 0 {
            y -= 1
            if sums[y] >= threshold { low = y; missed = 0 } else if missed >= gap { break } else { missed += 1 }
        }
        missed = 0
        y = seed
        while y < sums.count - 1 {
            y += 1
            if sums[y] >= threshold { high = y; missed = 0 } else if missed >= gap { break } else { missed += 1 }
        }
        return low..<(high + 1)
    }

    private static func channelDistance(_ a: RGBA, _ b: RGBA) -> Int {
        max(abs(Int(a.r) - Int(b.r)), max(abs(Int(a.g) - Int(b.g)), abs(Int(a.b) - Int(b.b))))
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    private static func empty(_ buffer: PixelBuffer, background: RGBA = .white, solid: Bool = true) -> InkMetrics {
        InkMetrics(background: background, foreground: .black, backgroundIsSolid: solid,
                   bodyTop: 0, baseline: 0, bodyBottom: 0, inkLeft: 0, inkRight: 0, strokeWidth: 0, fontSize: nil)
    }
}
