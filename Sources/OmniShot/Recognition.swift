import AppKit
import CoreML
import OmniShotCore
import Vision

/// How the recognized lines are put back into paragraphs.
enum Segmentation: String {
    /// Our own ladder in `TextBlockBuilder` — five signals voted in order. Works on every macOS the app
    /// supports, and is tuned against the mistakes users actually reported.
    case lines
    /// Apple's `RecognizeDocumentsRequest` (macOS 26+), which hands back paragraphs, lists and tables itself.
    case document

    /// Which one to use. `OMNISHOT_SEGMENT=lines|document` forces one, for comparing them on a real screenshot
    /// (`--translate-image --segment …` runs both and prints them side by side).
    ///
    /// `document` is the default where it exists, on the evidence of that comparison: identical paragraphing on
    /// a numbered list, an airy paragraph and text down to 8 pt, and clearly better on a page containing a
    /// table — where the ladder merges across cells (`Where Engine Corner`) and the document reader keeps every
    /// cell separate. The ladder stays as the fallback, and as the thing to compare against when Apple changes
    /// its reader.
    static var current: Segmentation {
        guard let forced = ProcessInfo.processInfo.environment["OMNISHOT_SEGMENT"],
              let value = Segmentation(rawValue: forced) else {
            if #available(macOS 26.0, *) { return .document }
            return .lines
        }
        return value
    }
}

/// Which compute device Vision's text readers run on.
///
/// Left alone they run on the Neural Engine, and that runtime (E5RT) is the one that wedged for hours on
/// 2026-11-04 — every read failing until the process was restarted (see `OCRService`). Pinning the readers to
/// the GPU keeps text recognition off it. Speed is the same either way once the engine is warm (measured on a
/// 1578×728 page: GPU 0.13–0.6 s, ANE 0.1–0.2 s). This does **not** help the separate "the first read after an
/// idle spell takes 30 s" problem — that is device-independent, and the heartbeat in `AppDelegate` pays it.
/// The CPU is no use for the document reader (30 s), so a stage with no GPU device is left on the default.
///
/// `OMNISHOT_VISION_ANE=1` puts everything back on the default device, for comparing the two.
enum VisionCompute {
    private static var prefersGPU: Bool {
        ProcessInfo.processInfo.environment["OMNISHOT_VISION_ANE"] == nil
    }

    static func preferGPU(_ request: VNRequest) {
        guard prefersGPU, let stages = try? request.supportedComputeStageDevices else { return }
        for (stage, devices) in stages {
            if let gpu = devices.first(where: isGPU) { request.setComputeDevice(gpu, for: stage) }
        }
    }

    @available(macOS 26.0, *)
    static func preferGPU(_ request: inout RecognizeDocumentsRequest) {
        guard prefersGPU else { return }
        for (stage, devices) in request.supportedComputeStageDevices {
            if let gpu = devices.first(where: isGPU) { request.setComputeDevice(gpu, for: stage) }
        }
    }

    private static func isGPU(_ device: MLComputeDevice) -> Bool {
        if case .gpu = device { return true }
        return false
    }
}

struct RecognitionResult {
    var lines: [OCRLine]
    /// Paragraphs, when the recogniser worked them out itself (`Segmentation.document`). Nil means "group the
    /// lines with our own ladder".
    var blocks: [TextBlock]?
    /// Something about the recognition itself the user should hear — today, that the configured endpoint ran out
    /// of allowance and the other one answered. Nil when everything went as set.
    var notice: String?

    /// The blocks a translation is built from, and the order the text is read in.
    var translatedBlocks: [TextBlock] { blocks ?? TextBlockBuilder.group(lines) }

    /// Recognized text in reading order: one line per OCR line, paragraphs kept together.
    var plainText: String {
        translatedBlocks.map { $0.lines.map(\.text).joined(separator: "\n") }.joined(separator: "\n")
    }
}

enum TextRecognizer {
    /// Set by `--check baidu-ocr` so the check can drive the Baidu path offline, with a made-up key and an
    /// injected transport. Nil in the app: the engine then comes from 设置 → 文字识别.
    static var baiduOverride: (config: BaiduOCRConfig, transport: BaiduOCR.Transport?)?

    /// The Baidu configuration to use, or nil to stay on Vision. Every entry point below asks this, so the
    /// setting reaches the OCR panel, translation, a pin's text selection and 自动识别 alike.
    private static var baidu: (config: BaiduOCRConfig, transport: BaiduOCR.Transport?)? {
        if let baiduOverride { return baiduOverride }
        guard Settings.shared.ocrEngine == .baidu else { return nil }
        return (Settings.shared.baiduOCRConfig, nil)
    }

    /// Loads the recognition models in the background at launch. The first recognition by a new build compiles
    /// them, which took about 30 s here; afterwards it takes a tenth of a second, also in later launches.
    /// It has to be real text: a blank image, or a single mixed Chinese and English line, compiled only part of
    /// them and the first real page still took 14 s. One English line followed by one Chinese line covers it.
    /// Call on the main thread (the sample lines are drawn with AppKit); recognition runs in the background.
    static func warmUp() {
        // Vision's models are not touched when the user has picked Baidu, and compiling them costs half a minute.
        guard baidu == nil else { return }
        let samples = ["The quick brown fox jumps over the lazy dog", "截图里的文字会在本机识别"].compactMap(sampleLine)
        Task.detached(priority: .utility) {
            for image in samples {
                _ = try? await recognize(image, selection: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
        }
    }

    /// One short recognition, for the heartbeat that keeps Vision's engine from going cold.
    ///
    /// macOS 26/27 lets the recognition engine idle out: the next read anywhere then costs 15–35 s instead of
    /// 0.2 s. Measured here on 2026-11-05, on a single line and on a page, with the document reader and the
    /// line reader, on the ANE and pinned to the GPU, in a fresh process and in one that had been up for
    /// hours — every way round, the first read after a spell of no use paid ~30 s, the one after it 0.2 s,
    /// with E5RT errors in the log while it hung. Whatever process asks pays it; in the app that was the
    /// user's 文字识别, which sat on 「正在识别文字」 for half a minute. A tiny request every couple of minutes
    /// keeps the engine warm, so the cost lands on a background beat instead.
    static func keepWarm() {
        guard baidu == nil, let image = sampleLine("The quick brown fox jumps over the lazy dog") else { return }
        Task.detached(priority: .utility) {
            _ = try? await recognize(image, selection: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    /// One line of black text on white, at 2x.
    private static func sampleLine(_ text: String) -> CGImage? {
        let size = CGSize(width: 480, height: 48)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
            .draw(at: CGPoint(x: 12, y: 12))
        return rep.cgImage
    }

    private static func makeTextRequest(autoDetectsLanguage: Bool = true) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
        // Guessing the script helps ordinary pages, but on a dark Chinese table screenshot it decided that
        // 「业务员」 in a whole column was Korean and returned `뾰솎묘`, which made the column impossible to group.
        // Only the auto-mask pass turns it off (`recognizeForAutoMask`); everything else keeps it on.
        request.automaticallyDetectsLanguage = autoDetectsLanguage
        VisionCompute.preferGPU(request)
        return request
    }

    /// Recognizes the text of `image` (the pixels of `bounds`) with a box per character, for selecting it on a pin.
    static func layout(_ image: CGImage, bounds: CGRect) async throws -> TextLayout {
        if let baidu {
            let page = try await BaiduOCR.recognize(image: image, config: baidu.config, transport: baidu.transport)
            let lines = page.lines.map { line in
                GlyphLine(text: line.words, rect: pointRect(line.rect, in: bounds),
                          boxes: line.chars.map { Optional(pointRect($0.rect, in: bounds)) })
            }
            return TextLayout(lines)
        }
        return try await RecognitionEngine.layout(image, bounds: bounds)
    }

    /// The local reader for a pin's selectable text; runs in the engine process like everything else.
    static func layoutLocally(_ image: CGImage, bounds: CGRect) async throws -> TextLayout {
        return try await Task.detached(priority: .userInitiated) {
            let request = makeTextRequest()
            try VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { observation -> GlyphLine? in
                guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
                let text = candidate.string
                let boxes = text.indices.map { i -> CGRect? in
                    guard let box = try? candidate.boundingBox(for: i..<text.index(after: i))?.boundingBox else { return nil }
                    return VisionGeometry.rect(fromNormalized: box, in: bounds)
                }
                return GlyphLine(text: text, rect: VisionGeometry.rect(fromNormalized: observation.boundingBox, in: bounds), boxes: boxes)
            }
            return TextLayout(lines)
        }.value
    }

    /// Runs Vision text recognition on `image`, the pixels of `selection`.
    /// Returned line rects are in the same coordinate space as `selection`.
    ///
    /// Small glyphs are Vision's blind spot. A 2000×623 email whose text was about twelve pixels tall came back
    /// with twelve of its sixteen lines — and every missing line simply stayed in the picture, in English, while
    /// the rest was translated over it (user, 2026-10). The same picture at 2× came back complete. So when the
    /// first pass's lines are short, the picture is read once more at double size and the pass that found more
    /// lines wins. Boxes are normalized, so the scale never reaches the coordinate maths.
    static func recognize(_ image: CGImage, selection: CGRect,
                          segmentation: Segmentation = .current,
                          autoDetectsLanguage: Bool = true) async throws -> RecognitionResult {
        if let baidu {
            let page = try await BaiduOCR.recognize(image: image, config: baidu.config, transport: baidu.transport)
            let theirs = result(from: page, in: selection, config: baidu.config)
            return await fillHoles(in: theirs, image: image, selection: selection) ?? theirs
        }
        return try await RecognitionEngine.recognize(image, selection: selection, segmentation: segmentation,
                                                     autoDetectsLanguage: autoDetectsLanguage)
    }

    /// The local recogniser, with its "small text gets a second look" retry.
    ///
    /// This is what runs inside the engine process (`--ocr-service`, see `OCRService`); it is also the
    /// fallback for a machine where that process cannot be started at all.
    static func recognizeLocally(_ image: CGImage, selection: CGRect, segmentation: Segmentation,
                                 autoDetectsLanguage: Bool) async throws -> RecognitionResult {
        let first = try await recognizeOnce(image, selection: selection, segmentation: segmentation,
                                            autoDetectsLanguage: autoDetectsLanguage)
        guard let factor = upscaleFactor(for: first, image: image, selection: selection),
              let bigger = upscaled(image, by: factor),
              let second = try? await recognizeOnce(bigger, selection: selection, segmentation: segmentation,
                                                    autoDetectsLanguage: autoDetectsLanguage),
              second.lines.count > first.lines.count else { return first }
        return second
    }

    /// Baidu's text stands; the places it left empty are read locally and filled in.
    ///
    /// Measured on the same plain email: the same request came back with 14 lines one time and 15 the next —
    /// and never the same one missing — while the local recogniser read all sixteen. Its long lines were also
    /// miscopied ("American Amy", "curenty"). Scaling the upload further and switching precision or language did
    /// not change either. Losing a line is the visible one: the block underneath is translated without it and
    /// the rest stays in the picture, English. So one local pass fills the gaps — it costs a tenth of a second
    /// and no quota, and touches nothing Baidu did read.
    private static func fillHoles(in theirs: RecognitionResult, image: CGImage,
                                  selection: CGRect) async -> RecognitionResult? {
        guard let local = try? await RecognitionEngine.recognize(image, selection: selection, segmentation: .lines,
                                                                 autoDetectsLanguage: true) else { return nil }
        let added = local.lines.filter { line in
            !theirs.lines.contains { overlaps($0.rect, line.rect) }
        }
        guard !added.isEmpty else { return nil }
        var lines = theirs.lines + added
        // Reading order, the same rule `TextBlockBuilder.group` sorts by.
        lines.sort { a, b in
            let ay = (a.rect.minY / 4).rounded(.down), by = (b.rect.minY / 4).rounded(.down)
            return ay == by ? a.rect.minX < b.rect.minX : ay < by
        }
        // The paragraphs Baidu worked out do not cover the added lines, so the grouping ladder runs over the
        // merged lines instead.
        return RecognitionResult(lines: lines, blocks: nil)
    }

    /// Whether two line boxes are the same text: half of the smaller one shared is enough, because the two
    /// engines trim their boxes differently.
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.intersection(b)
        guard !shared.isNull, shared.width > 0, shared.height > 0 else { return false }
        let smaller = min(a.width * a.height, b.width * b.height)
        guard smaller > 0 else { return false }
        return shared.width * shared.height / smaller > 0.5
    }

    /// How much to grow the picture before a second look, or nil when the text is already big enough.
    ///
    /// "Short" is the median line box in pixels. Measured on that email: 23 px at 1× lost four rows, 35 px at
    /// 1.5× and 47 px at 2× lost none; a fixture with 31 px boxes reads the same at either size, so the line is
    /// drawn at 30 px. A retry that finds no more lines is thrown away, so a false alarm costs time, not text.
    private static func upscaleFactor(for result: RecognitionResult, image: CGImage,
                                      selection: CGRect) -> CGFloat? {
        guard !result.lines.isEmpty, image.height > 0, selection.height > 0 else { return nil }
        let pixelsPerPoint = CGFloat(image.height) / selection.height
        let heights = result.lines.map(\.rect.height).sorted()
        let median = heights[heights.count / 2] * pixelsPerPoint
        guard median < minimumLineHeightPixels else { return nil }
        // The second pass is a fully separate bitmap — a 4K capture doubled is a third of a gigabyte. Past a
        // 6000-pixel side there is nothing sensible left to do, and Vision would be reading a scaled-down copy
        // anyway.
        let longest = CGFloat(max(image.width, image.height))
        return min(2, 6000 / max(longest, 1))
    }

    /// Line boxes under this height (in pixels) are where Vision starts losing rows.
    private static let minimumLineHeightPixels: CGFloat = 30

    private static func upscaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        guard factor > 1.01 else { return nil }
        let width = Int(CGFloat(image.width) * factor)
        let height = Int(CGFloat(image.height) * factor)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// One read of the picture: the document reader where it exists, the line recognizer otherwise.
    private static func recognizeOnce(_ image: CGImage, selection: CGRect, segmentation: Segmentation,
                                      autoDetectsLanguage: Bool) async throws -> RecognitionResult {
        if segmentation == .document, #available(macOS 26.0, *) {
            // A failure here is not worth failing the capture over: the line path below still works.
            if let document = try? await recognizeDocument(image, selection: selection), !document.lines.isEmpty {
                return document
            }
        }
        return try await Task.detached(priority: .userInitiated) {
            let request = makeTextRequest(autoDetectsLanguage: autoDetectsLanguage)
            try VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRLine(text: candidate.string,
                               rect: VisionGeometry.rect(fromNormalized: observation.boundingBox, in: selection),
                               firstWordWidth: firstWordWidth(candidate, in: selection),
                               wordGap: wordGap(candidate, in: selection),
                               glyphs: glyphs(in: candidate.string, bounds: selection) {
                                   try? candidate.boundingBox(for: $0)?.boundingBox
                               })
            }
            return RecognitionResult(lines: lines, blocks: nil)
        }.value
    }

    /// 自动识别's own pass. Three differences from `recognize`, all measured on a 1973×1064 table screenshot:
    ///
    /// ① It reads in horizontal strips. In one pass Vision returned only the first five rows of the table and
    /// dropped the rest; two 532 pt halves returned every cell. 560 pt strips with a 60 pt overlap keep that
    /// result — smaller strips (300 pt, tried first) lost a couple of rows again.
    /// ② It uses the line recognizer rather than the document reader: the auto-mask tool wants words and
    /// boxes, and the strips would cut any paragraph structure anyway.
    /// ③ It turns language guessing off (`autoDetectsLanguage: false`). Guessing is useful for ordinary pages,
    /// but here it decided that 「业务员」 in a whole column was Korean and returned `뾰솎묘`, so the column
    /// could not be grouped at all.
    static func recognizeForAutoMask(_ image: CGImage, selection: CGRect) async throws -> RecognitionResult {
        // Baidu reads the whole picture in one request — the strips below exist because Vision drops rows,
        // and there are no rows for it to drop.
        if baidu != nil {
            return try await recognize(image, selection: selection, segmentation: .lines, autoDetectsLanguage: false)
        }
        return try await RecognitionEngine.recognizeForAutoMask(image, selection: selection)
    }

    /// The strip reader itself; runs inside the engine process.
    static func recognizeForAutoMaskLocally(_ image: CGImage, selection: CGRect) async throws -> RecognitionResult {
        let scale = CGFloat(image.width) / max(selection.width, 1)
        let strip: CGFloat = 560
        let overlap: CGFloat = 60
        guard selection.height > strip else {
            return try await recognize(image, selection: selection, segmentation: .lines, autoDetectsLanguage: false)
        }

        var strips: [CGRect] = []
        var top = selection.minY
        while top < selection.maxY - 0.5 {
            let bottom = min(top + strip, selection.maxY)
            strips.append(CGRect(x: selection.minX, y: top, width: selection.width, height: bottom - top))
            if bottom >= selection.maxY - 0.5 { break }
            top = bottom - overlap
        }

        var lines: [OCRLine] = []
        for rect in strips {
            let crop = CGRect(x: (rect.minX - selection.minX) * scale,
                              y: (rect.minY - selection.minY) * scale,
                              width: rect.width * scale,
                              height: rect.height * scale).integral
            guard crop.width >= 1, crop.height >= 1, let piece = image.cropping(to: crop) else { continue }
            let result = try await recognizeLocally(piece, selection: rect, segmentation: .lines, autoDetectsLanguage: false)
            for line in result.lines {
                // A line cut by a seam is incomplete; the overlapping strip has the whole one. The outermost
                // edges are the selection's own, so they are not seams.
                let cutTop = rect.minY > selection.minY + 0.5 && line.rect.minY < rect.minY + 2
                let cutBottom = rect.maxY < selection.maxY - 0.5 && line.rect.maxY > rect.maxY - 2
                guard !cutTop, !cutBottom else { continue }
                lines.append(line)
            }
        }

        // The strips overlap, so a line near a seam is read twice; keep the taller of the two boxes.
        var unique: [OCRLine] = []
        for line in lines {
            if let index = unique.firstIndex(where: {
                $0.text == line.text && overlapRatio($0.rect, line.rect) > 0.5
            }) {
                if line.rect.height > unique[index].rect.height { unique[index] = line }
            } else {
                unique.append(line)
            }
        }
        unique.sort { a, b in
            let ay = (a.rect.minY / 4).rounded(.down), by = (b.rect.minY / 4).rounded(.down)
            return ay == by ? a.rect.minX < b.rect.minX : ay < by
        }
        return RecognitionResult(lines: unique, blocks: nil)
    }

    /// How much of the smaller rect the two share, 0...1.
    private static func overlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        guard !shared.isNull, shared.width > 0, shared.height > 0 else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? shared.width * shared.height / smaller : 0
    }

    /// A Baidu page in the capture view's own coordinates.
    ///
    /// Baidu's boxes are normalized with the origin at the top left; `bounds` is the selection, or the whole
    /// picture when selecting text on a pin. Paragraphs are only taken when the service grouped *every* line —
    /// a partial grouping would silently drop the rest from the text the OCR panel shows.
    private static func result(from page: BaiduOCRPage, in bounds: CGRect,
                               config: BaiduOCRConfig) -> RecognitionResult {
        let lines = page.lines.map { line in
            OCRLine(text: line.words,
                    rect: pointRect(line.rect, in: bounds),
                    glyphs: line.chars.map { OCRGlyph(text: $0.text, rect: pointRect($0.rect, in: bounds)) })
        }
        var blocks: [TextBlock] = []
        let covered = Set(page.paragraphs.flatMap { $0 })
        if !page.paragraphs.isEmpty, covered.count == lines.count {
            for (id, paragraph) in page.paragraphs.enumerated() {
                let paragraphLines = paragraph.compactMap { lines.indices.contains($0) ? lines[$0] : nil }
                guard !paragraphLines.isEmpty else { continue }
                blocks.append(TextBlock(id: id, lines: paragraphLines))
            }
        }
        // The quota fallback is worth one sentence, on the call that discovered it — the next screenshot uses the
        // other endpoint quietly, so this does not become a line of noise on every capture.
        var notice: String?
        if page.fellBack, let used = page.usedPrecision {
            notice = "百度 OCR 的\(config.precision.title)免费额度用完了，这次改用\(used.title)"
        }
        return RecognitionResult(lines: lines, blocks: blocks.isEmpty ? nil : blocks, notice: notice)
    }

    private static func pointRect(_ normalized: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + normalized.minX * bounds.width,
               y: bounds.minY + normalized.minY * bounds.height,
               width: normalized.width * bounds.width,
               height: normalized.height * bounds.height)
    }

    /// Apple's document reader: it hands back paragraphs, lists (with their markers) and tables as structure,
    /// so nothing here has to guess where one paragraph ends and the next begins.
    @available(macOS 26.0, *)
    private static func recognizeDocument(_ image: CGImage, selection: CGRect) async throws -> RecognitionResult? {
        try await Task.detached(priority: .userInitiated) {
            var request = RecognizeDocumentsRequest()
            request.textRecognitionOptions.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
                .map { Locale.Language(identifier: $0) }
            request.textRecognitionOptions.useLanguageCorrection = true
            request.textRecognitionOptions.automaticallyDetectLanguage = true
            VisionCompute.preferGPU(&request)
            guard let document = try await ImageRequestHandler(image).perform(request).first?.document
            else { return nil }

            var blocks: [TextBlock] = []
            var lines: [OCRLine] = []
            /// The text containers nest: a list item and a table cell each hold content of their own, and the
            /// enclosing container's `paragraphs` already includes them. Two consequences, both measured:
            /// walking the lists as well sees the same paragraph two or three times (a three-item list came
            /// back as nine paragraphs), so paragraphs are keyed by where they are; and the tree is deep enough
            /// to be effectively cyclic, so the walk is bounded — without that it recursed until the stack blew
            /// (SIGBUS, "could not determine thread index for stack guard region").
            var seen: Set<String> = []
            func collect(_ container: DocumentObservation.Container, level: Int) {
                guard level < 3 else { return }
                for paragraph in container.paragraphs {
                    let rect = paragraph.boundingRegion.boundingBox
                    let key = "\(Int(rect.origin.x * 1000)):\(Int(rect.origin.y * 1000)):\(Int(rect.width * 1000))"
                    guard seen.insert(key).inserted else { continue }
                    let paragraphLines = paragraph.lines.compactMap { line -> OCRLine? in
                        guard let candidate = line.topCandidates(1).first else { return nil }
                        return OCRLine(text: candidate.string,
                                       rect: VisionGeometry.rect(fromNormalized: normalized(line.boundingRegion.boundingBox),
                                                                 in: selection),
                                       firstWordWidth: firstWordWidth(candidate.string, in: selection) { range in
                                           candidate.boundingBox(for: range).map { normalized($0) }
                                       },
                                       wordGap: wordGap(candidate.string, in: selection) { range in
                                           candidate.boundingBox(for: range).map { normalized($0) }
                                       },
                                       glyphs: glyphs(in: candidate.string, bounds: selection) { range in
                                           candidate.boundingBox(for: range).map { normalized($0) }
                                       })
                    }
                    guard !paragraphLines.isEmpty else { continue }
                    blocks.append(TextBlock(id: blocks.count, lines: paragraphLines))
                    lines.append(contentsOf: paragraphLines)
                }
                for list in container.lists { for item in list.items { collect(item.content, level: level + 1) } }
                for table in container.tables {
                    for row in table.rows { for cell in row { collect(cell.content, level: level + 1) } }
                }
            }
            collect(document, level: 0)
            return blocks.isEmpty ? nil : RecognitionResult(lines: lines, blocks: blocks)
        }.value
    }

    /// One box per character, in the same space as `bounds`. The auto-mask tool cuts lines into words with
    /// these: Vision's line box alone cannot say where 「手机号：13800138000」 turns from label to number.
    private static func glyphs(in text: String, bounds: CGRect,
                               box: (Range<String.Index>) -> CGRect?) -> [OCRGlyph] {
        var out: [OCRGlyph] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if let normalized = box(index..<next) {
                out.append(OCRGlyph(text: String(text[index..<next]),
                                    rect: VisionGeometry.rect(fromNormalized: normalized, in: bounds)))
            }
            index = next
        }
        return out
    }

    /// How wide the line's first word is, in points. `TextBlockBuilder` asks whether that word could have fitted
    /// at the end of the line above: if it could, the line above ended on purpose instead of running out of room.
    /// On a line that opens a list item this is the marker (`1.`, `•`), which is how the indent of that item's
    /// continuations is measured rather than guessed.
    private static func firstWordWidth(_ candidate: VNRecognizedText, in bounds: CGRect) -> CGFloat? {
        firstWordWidth(candidate.string, in: bounds) { try? candidate.boundingBox(for: $0)?.boundingBox }
    }

    private static func firstWordWidth(_ text: String, in bounds: CGRect,
                                       box: (Range<String.Index>) -> CGRect?) -> CGFloat? {
        guard let first = text.first, !first.isWhitespace else { return nil }
        // A script without spaces is measured a character at a time: one character is the unit that either fits
        // at the end of the line above or does not.
        let end = TextBlockBuilder.isCJK(first) ? text.index(after: text.startIndex) : wordEnd(text, from: text.startIndex)
        guard let normalized = box(text.startIndex..<end) else { return nil }
        return VisionGeometry.rect(fromNormalized: normalized, in: bounds).width
    }

    /// The median gap between the words of a line, in points: how wide a space is in this text. The page takes
    /// the median of these as the unit its tolerances are expressed in, which beats guessing from the line
    /// height. Nil for a line with fewer than two words — Chinese runs have no spaces at all.
    private static func wordGap(_ candidate: VNRecognizedText, in bounds: CGRect) -> CGFloat? {
        wordGap(candidate.string, in: bounds) { try? candidate.boundingBox(for: $0)?.boundingBox }
    }

    private static func wordGap(_ text: String, in bounds: CGRect,
                                box: (Range<String.Index>) -> CGRect?) -> CGFloat? {
        var boxes: [CGRect] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            guard index < text.endIndex else { break }
            let end = wordEnd(text, from: index)
            if let normalized = box(index..<end) {
                boxes.append(VisionGeometry.rect(fromNormalized: normalized, in: bounds))
            }
            index = end
        }
        guard boxes.count > 1 else { return nil }
        let gaps = zip(boxes, boxes.dropFirst()).map { $1.minX - $0.maxX }.sorted()
        return gaps[gaps.count / 2]
    }

    private static func wordEnd(_ text: String, from start: String.Index) -> String.Index {
        var end = start
        while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
        return end
    }

    /// The document reader hands back `NormalizedRect`, which is the same shape in the same coordinate space as
    /// the `CGRect` `VisionGeometry` already takes.
    @available(macOS 26.0, *)
    private static func normalized(_ rect: NormalizedRect) -> CGRect {
        CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    /// A word's box, from the four corners the document reader reports instead of a rect.
    @available(macOS 26.0, *)
    private static func normalized(_ observation: RectangleObservation) -> CGRect {
        let xs = [observation.topLeft.x, observation.topRight.x, observation.bottomLeft.x, observation.bottomRight.x]
        let ys = [observation.topLeft.y, observation.topRight.y, observation.bottomLeft.y, observation.bottomRight.y]
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

enum CodeScanner {
    /// Payloads found in `images`, in order, without duplicates.
    static func scan(_ images: [CGImage]) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            var found: [String] = []
            for image in images {
                let request = VNDetectBarcodesRequest()
                try? VNImageRequestHandler(cgImage: image).perform([request])
                for payload in (request.results ?? []).compactMap(\.payloadStringValue) where !found.contains(payload) {
                    found.append(payload)
                }
            }
            return found
        }.value
    }

    /// Captures every screen, scans it, copies what was found and offers to open a link.
    static func scanScreens() {
        guard CaptureEngine.hasPermission else {
            CaptureSession.requestPermission()
            return
        }
        Task { @MainActor in
            do {
                let images = try await CaptureEngine.captureScreens().map(\.image)
                let codes = await scan(images)
                present(codes)
            } catch {
                HUD.show("扫码失败：\(error.localizedDescription)")
            }
        }
    }

    static func present(_ codes: [String]) {
        guard !codes.isEmpty else {
            HUD.show("屏幕上没有找到二维码或条形码")
            return
        }
        let text = codes.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let links = codes.compactMap { URL(string: $0) }.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        guard let link = links.first else {
            HUD.show(codes.count == 1 ? "已复制：\(text)" : "找到 \(codes.count) 个码，已全部复制")
            return
        }
        let alert = NSAlert()
        alert.messageText = codes.count == 1 ? "识别到链接，已复制" : "识别到 \(codes.count) 个码，已全部复制"
        alert.informativeText = link.absoluteString
        alert.addButton(withTitle: "在浏览器中打开")
        alert.addButton(withTitle: "好")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(link) }
    }
}

/// Translates the text in an image and draws the translation over the original, like `Y` in a capture.
enum ImageTranslator {
    enum Failure: LocalizedError {
        case nothingToTranslate
        var errorDescription: String? { "没有找到需要翻译的外文" }
    }

    /// `send` translates the paragraphs; by default the configured model, through the shared cache.
    static func translate(_ rep: NSBitmapImageRep,
                          send: (([ChatTranslator.Item]) async throws -> [Int: String])? = nil) async throws -> NSBitmapImageRep {
        guard let cg = rep.cgImage else { throw CocoaError(.featureUnsupported) }
        let bounds = CGRect(origin: .zero, size: rep.size)
        let result = try await TextRecognizer.recognize(cg, selection: bounds)
        let blocks = result.translatedBlocks.filter { TextBlockBuilder.shouldTranslate($0.text) }
        guard !blocks.isEmpty else { throw Failure.nothingToTranslate }
        let items = blocks.map { ChatTranslator.Item(id: $0.id, text: $0.text) }
        let translations: [Int: String]
        if let send {
            translations = try await send(items)
        } else {
            let config = Settings.shared.translationConfig
            translations = try await TranslationService.cache.translate(items, config: config) { try await Translator.translate($0, config: config) }
        }
        let laidOut = TranslationLayout.layout(blocks: blocks, translations: translations, crop: cg, selection: bounds)
        let base = NSImage(cgImage: cg, size: rep.size)
        let renderer = ContentRenderer(base: base, bounds: bounds, effect: { _ in ContentRenderer.EffectImage(image: base, rect: bounds) })
        guard let out = Exporter.render(renderer: renderer, selection: bounds, scale: CGFloat(cg.width) / rep.size.width, items: [],
                                        translation: laidOut)
        else { throw CocoaError(.fileWriteUnknown) }
        return out
    }
}
