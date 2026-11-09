import AppKit
import CoreImage
import CoreText
import OmniShotCore

/// Lays translated paragraphs over the screenshot they came from.
///
/// Everything here is about matching the original: the size comes from the ink the text was drawn with
/// (an OCR line box varies by 0.8–1.8× of the real font size), the first line sits on the original ink's
/// visual center, the color is the original ink nudged up to a readable contrast, and the background is
/// either the flat color behind the text or a blurred plate of whatever was under it.
enum TranslationLayout {
    static let minimumFontSize: CGFloat = 9
    static let maximumFontSize: CGFloat = 96
    /// How far a translation may shrink before it is ellipsized instead of shrinking any further.
    ///
    /// This used to stop at 75%, and anything that still did not fit was cut short with an ellipsis behind the
    /// 全文 button. Missing text is worse than small text: a paragraph at 60% can still be read on screen,
    /// while「…」only says that something was lost (user, 2026-10). The shrink only goes as far as the block
    /// needs, so almost everything is drawn at the original size.
    static let minimumScale: CGFloat = 0.6
    /// No translation is drawn smaller than this, whatever `minimumScale` works out to.
    static let smallestFontSize: CGFloat = 8
    static let minimumContrast: Double = 3
    static let plateOutset: CGFloat = 6
    static let plateRadius: CGFloat = 6
    static let plateBlurRadius: CGFloat = 10
    static let plateAlpha: CGFloat = 0.74
    /// Line spacing for a translation that has to wrap: a single-line original has no pitch of its own.
    static let wrappedPitchRatio: CGFloat = 1.3
    /// The tightest leading a multi-line translation may keep from the original. Under about 1.2× the font size
    /// CJK glyphs touch between lines.
    static let minimumPitchRatio: CGFloat = 1.25
    /// How many extra lines a translation may add below the original before it is ellipsized instead.
    static let maximumExtraLines = 4

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// `blocks` come from `TextBlockBuilder`, in the same coordinate space as `selection`; `crop` is the
    /// selection's pixels.
    static func layout(blocks: [TextBlock], translations: [Int: String], crop: CGImage, selection: CGRect,
                       targetLanguage: String = Settings.shared.targetLanguage) -> [TranslatedBlock] {
        guard let buffer = PixelBuffer(image: crop), selection.width > 0, selection.height > 0 else { return [] }
        let scale = CGFloat(crop.width) / selection.width
        // The language tag is the *translated* one, not the one from settings: 截图翻译 turns around and goes
        // into English on a Chinese screen, and the font and glyph shaping have to follow it.
        let language = TranslationText.languageTag(for: targetLanguage)

        return blocks.compactMap { block in
            guard let text = translations[block.id], !text.isEmpty, !block.lines.isEmpty else { return nil }
            let script = TextScript.of(block.text)
            let pixelLines = block.lines.map { OCRLine(text: $0.text, rect: pixel($0.rect, selection: selection, scale: scale)) }
            let metrics = InkReader.measure(buffer, lines: pixelLines, ring: max(2, Int(scale * 2)))

            // The source's own line spacing, measured before the size: it is the only honest ceiling on how tall
            // this text can be (see `size`).
            let sourcePitch = block.lines.count > 1 ? medianPitch(block) : nil
            let fontSize = size(metrics, lineHeight: block.lineHeight, scale: scale, cap: sourcePitch)
            let bold = metrics.isBold
            let foreground = TranslationText.color(metrics.foreground.ensuringContrast(minimumContrast, against: metrics.background))
            let isSolid = metrics.backgroundIsSolid
            let background = TranslationText.color(metrics.background)
            if ProcessInfo.processInfo.environment["OMNISHOT_DEBUG_LAYOUT"] != nil {
                print("  #\(block.id) box \(block.rect.integral) lines \(block.lines.count) ink "
                      + (metrics.fontSize.map { String(format: "%.1f px → %.1f pt", $0, $0 / scale) } ?? "unreadable")
                      + " size \(fontSize) bold \(bold) stroke \(String(format: "%.2f", metrics.strokeWidth)) "
                      + "\(isSolid ? "solid" : "plate") "
                      + "ink \(metrics.inkLeft)...\(metrics.inkRight) base \(metrics.baseline) body \(metrics.bodyTop)...\(metrics.bodyBottom)")
            }

            // Erase the original with a little room around it, so ascenders and descenders go too.
            let pad = max(2, block.lineHeight * 0.1)
            let erase = block.lines.map { $0.rect.insetBy(dx: -pad, dy: -pad).intersection(selection) }.filter { !$0.isNull }
            let original = block.rect
            let alignment = alignment(metrics)

            // Keep the original's leading when it is comfortable, but never tighter than the translation's own
            // font needs. Latin sits inside its em box, so a source set at 1.14× is fine and the translation
            // can follow it line for line; Chinese glyphs fill the box, and at that pitch the lines touch — this
            // email's paragraph came out as a solid block (user, 2026-10).
            let pitch = sourcePitch.map { max($0, fontSize * minimumPitchRatio) } ?? fontSize * wrappedPitchRatio
            let box = grow(original, alignment: alignment, singleLine: block.lines.count == 1, isSolid: isSolid,
                           metrics: metrics, buffer: buffer, background: metrics.background, selection: selection,
                           scale: scale, pitch: pitch)
            let fit = fit(text, from: fontSize, in: box, pitch: pitch, language: language, bold: bold)

            let backgroundFill: TranslationBackground
            if isSolid {
                backgroundFill = .solid(background)
            } else if let image = plateImage(crop: crop, selection: selection, scale: scale, erase: erase,
                                             text: box, background: metrics.background) {
                backgroundFill = .plate(image: image, rect: box.union(erase.reduce(CGRect.null) { $0.union($1) })
                                            .insetBy(dx: -plateOutset, dy: -plateOutset),
                                        color: background, alpha: plateAlpha, radius: plateRadius)
            } else {
                // No plate could be cut (the block runs off the image): a flat fill still beats leaving the
                // original text showing through.
                backgroundFill = .solid(background)
            }

            return TranslatedBlock(rect: original, erase: erase, wrapWidth: box.width, text: fit.text,
                                   sourceText: block.text, fullText: text, fontSize: fit.fontSize,
                                   bold: bold, alignment: alignment,
                                   firstCenterY: CGFloat(metrics.visualCenter(script)) / scale + selection.minY,
                                   pitch: pitch, background: backgroundFill, foreground: foreground, language: language)
        }
    }

    // MARK: - Original size and weight

    /// The font size the original was drawn at, in points. The ink says how tall the letters are; when there
    /// was too little of it to measure, the line box stands in (loose, but better than nothing).
    ///
    /// `cap` is the source paragraph's line spacing. A line of text cannot be taller than the distance to the
    /// line under it, so when the ink of two tightly set lines runs together and the measurement reads them as
    /// one — this email's two-line paragraphs came out at 21 pt on 12.5 pt leading — the spacing is the honest
    /// answer. Without it the translation was drawn at twice the original size and had to be cut short, which is
    /// what「全文」was being pressed for (user, 2026-10).
    static func size(_ metrics: InkMetrics, lineHeight: CGFloat, scale: CGFloat, cap: CGFloat? = nil) -> CGFloat {
        let estimate = metrics.fontSize.map { CGFloat($0) / scale } ?? lineHeight * 0.85
        let unclamped = min(maximumFontSize, max(minimumFontSize, estimate.rounded()))
        guard let cap, cap > 0 else { return unclamped }
        return min(unclamped, cap)
    }

    /// Center of the gap between the ink and its container edge: a button label stays centered, a right
    /// aligned column stays right aligned.
    static func alignment(_ metrics: InkMetrics) -> TranslationAlignment {
        if metrics.isCentered { return .center }
        if let left = metrics.leftMargin, let right = metrics.rightMargin,
           right <= max(6, (left + right) / 5), left > right * 2 {
            return .trailing
        }
        return .leading
    }

    /// Baseline-to-baseline distance of the original paragraph.
    static func medianPitch(_ block: TextBlock) -> CGFloat {
        let sorted = block.lines.map(\.rect).sorted { $0.minY < $1.minY }
        guard sorted.count > 1 else { return block.lineHeight }
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.minY - $0.minY }.sorted()
        return max(1, gaps[gaps.count / 2])
    }

    // MARK: - Room to grow

    /// A translation is rarely the same length as the original, so before shrinking it may take blank space
    /// around the block. Only into space that is really blank: the margins are measured on the original's
    /// middle row, and the space below is checked pixel by pixel, so nothing else gets covered.
    private static func grow(_ rect: CGRect, alignment: TranslationAlignment, singleLine: Bool, isSolid: Bool,
                             metrics: InkMetrics, buffer: PixelBuffer, background: RGBA, selection: CGRect,
                             scale: CGFloat, pitch: CGFloat) -> CGRect {
        guard isSolid else { return rect }
        var box = rect
        if singleLine {
            // Room to the left and right. A margin of nil means the background ran to the edge of the image,
            // which is not a limit at all: the blank space simply continues, so the selection's edge is it.
            let leftRoom = metrics.leftMargin.map { CGFloat($0) / scale } ?? (rect.minX - selection.minX)
            let rightRoom = metrics.rightMargin.map { CGFloat($0) / scale } ?? (selection.maxX - rect.maxX)
            // Keep a margin of our own from whatever the space ends at.
            let left = max(0, leftRoom - max(3, leftRoom / 4))
            let right = max(0, rightRoom - max(3, rightRoom / 4))
            switch alignment {
            case .leading: box.size.width += right
            case .trailing: box.origin.x -= left; box.size.width += left
            case .center: box.origin.x -= left; box.size.width += left + right
            }
        }
        for _ in 0..<maximumExtraLines {
            let below = CGRect(x: box.minX, y: box.maxY, width: box.width, height: pitch)
            guard below.maxY <= selection.maxY, InkReader.isBlank(buffer, rect: pixel(below, selection: selection, scale: scale),
                                                                  background: background) else { break }
            box.size.height += pitch
        }
        return box.intersection(selection)
    }

    // MARK: - Fitting

    struct Fit {
        var text: String
        var fontSize: CGFloat
    }

    /// Bigger while there is room, smaller when the translation is longer, ellipsized when even the smallest
    /// size does not fit — so a translation never runs over the line below it.
    ///
    /// The first line is measured against *its own* height, not the OCR box's. A box hugs the ink and is often
    /// shorter than the line the original was set on (Vision's varies 0.8–1.8×, Baidu's is tighter still), and
    /// measuring against it shaved every translation by half a point — one list item coming out visibly smaller
    /// than its neighbours — and collapsed a short heading to a bare「…」 (4 points of text reported as 全文).
    /// A single line at the ink's size is exactly what the original occupied, so it always fits.
    static func fit(_ text: String, from size: CGFloat, in box: CGRect, pitch: CGFloat, language: String, bold: Bool) -> Fit {
        let slack = size * 0.3
        func room(for lines: [CTLine]) -> CGFloat {
            max(box.height, TranslationText.height(Array(lines.prefix(1)), pitch: pitch)) + slack
        }
        let floor = max(size * minimumScale, smallestFontSize)
        var candidate = size
        while candidate >= floor {
            let attributes = TranslationText.attributes(size: candidate, bold: bold, language: language)
            let lines = TranslationText.lines(text, attributes, width: box.width)
            if TranslationText.height(lines, pitch: pitch) <= room(for: lines) {
                return Fit(text: text, fontSize: candidate)
            }
            candidate -= 0.5
        }
        let smallest = floor.rounded()
        let attributes = TranslationText.attributes(size: smallest, bold: bold, language: language)
        let lines = TranslationText.lines(text, attributes, width: box.width)
        let cut = TranslationText.truncate(text, attributes, width: box.width, height: room(for: lines), pitch: pitch)
        return Fit(text: cut, fontSize: smallest)
    }

    // MARK: - Background plate

    /// Cuts the pixels under the block, wipes the original ink off them, blurs what is left and hands the
    /// result back: the translation then sits on its own background instead of on a rectangle of whatever
    /// color happened to be most common around it.
    private static func plateImage(crop: CGImage, selection: CGRect, scale: CGFloat, erase: [CGRect],
                                   text: CGRect, background: RGBA) -> CGImage? {
        let union = erase.reduce(CGRect.null) { $0.union($1) }.union(text).insetBy(dx: -plateOutset, dy: -plateOutset)
        let rect = pixel(union, selection: selection, scale: scale).integral.intersection(
            CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        guard rect.width >= 2, rect.height >= 2,
              let context = CGContext(data: nil, width: Int(rect.width), height: Int(rect.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // CGImage cropping is in top-left pixel coordinates, like the buffer.
        guard let patch = crop.cropping(to: rect) else { return nil }
        context.draw(patch, in: CGRect(origin: .zero, size: CGSize(width: rect.width, height: rect.height)))
        // The original ink would ghost through the blur.
        context.setFillColor(TranslationText.color(background).cgColor)
        for line in erase {
            let local = pixel(line, selection: selection, scale: scale).offsetBy(dx: -rect.minX, dy: -rect.minY)
            context.fill(local)
        }
        guard let wiped = context.makeImage() else { return nil }

        let blurred = CIImage(cgImage: wiped)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: plateBlurRadius * scale])
            .cropped(to: CIImage(cgImage: wiped).extent)
        return ciContext.createCGImage(blurred, from: blurred.extent)
    }

    /// A rect in the crop's pixel space (top-left origin).
    static func pixel(_ rect: CGRect, selection: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: (rect.minX - selection.minX) * scale, y: (rect.minY - selection.minY) * scale,
               width: rect.width * scale, height: rect.height * scale)
    }
}
