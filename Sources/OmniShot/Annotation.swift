import AppKit
import CoreText
import OmniShotCore

enum Tool: String, CaseIterable {
    case rectangle, arrow, pen, mosaic, magnifier, text, number, highlight

    var title: String {
        switch self {
        case .rectangle: return "形状"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .mosaic: return "打码"
        case .magnifier: return "放大镜"
        case .text: return "文字"
        case .number: return "序号"
        case .highlight: return "聚光灯"
        }
    }

    /// Single-key shortcut out of the box, 1 to 8 in toolbar order; the user can change it from the toolbar's hover card (see `ToolbarKeys`).
    var defaultKey: String {
        switch self {
        case .rectangle: return "1"
        case .arrow: return "2"
        case .pen: return "3"
        case .mosaic: return "4"
        case .magnifier: return "5"
        case .text: return "6"
        case .number: return "7"
        case .highlight: return "8"
        }
    }

    /// What "size" means differs per tool: stroke width, brush width, font size or badge diameter.
    var sizeRange: ClosedRange<CGFloat> {
        switch self {
        case .mosaic: return 6...120
        case .magnifier: return 1...10
        case .text: return 10...120
        case .number: return 14...80
        default: return 1...40
        }
    }

    var sizePresets: [CGFloat] {
        switch self {
        case .mosaic: return [12, 24, 48]
        case .magnifier: return [2, 3, 5]
        case .text: return [14, 20, 32]
        case .number: return [20, 26, 36]
        default: return [2, 4, 8]
        }
    }

    var defaultSize: CGFloat { sizePresets[1] }

    /// These tools always start a new annotation, even when the drag begins on an existing one: a brush stroke
    /// is drawn over what is already there, and a highlight is usually framed around it.
    var alwaysStartsNew: Bool { self == .pen || self == .mosaic || self == .highlight }
}

/// How the mosaic tool lays ink down: freehand, a rectangle, or 自动识别 — click a recognized word and every
/// place with the same text is masked at once.
enum MosaicMode: String { case brush, rect, auto }

/// The pen tool's two sub-tools: a freehand pencil, or a highlighter.
enum PenMode: String { case pencil, highlighter }

/// The highlighter's two kinds of stroke: a right-angled block, or a capsule line.
enum HighlighterMode: String { case rect, line }

/// How highlighter ink meets what is under it. Multiply is what a real marker does — it darkens the paper and
/// leaves black text readable. Translucent is a lighter veil for dark screens, where multiply nearly vanishes
/// because there is little brightness left to multiply.
enum HighlighterBlend: String, Codable {
    case multiply, translucent

    /// The ink's own opacity. Multiply is full strength: white becomes the ink colour and black stays black —
    /// that is what makes it read as multiply. Translucent is deliberately lighter.
    var alpha: CGFloat { self == .multiply ? 1 : 0.32 }
}

/// The 形状 tool's two outlines. Everything else about them — colour, width, dash — is shared: they are one
/// tool, and the rectangle's rounded-corner option is the only thing the circle does not get.
enum RectangleMode: String { case rect, ellipse }

/// Stroke pattern for rectangles, arrows and the pen.
enum DashStyle: String, Codable, CaseIterable { case solid, dashed, dotted }

/// Arrow look: the tapered filled arrow, a plain line with an open head, or heads at both ends.
enum ArrowHead: String, Codable, CaseIterable { case tapered, open, double }

/// How text stands out from what is under it.
enum TextDecoration: String, Codable, CaseIterable { case plain, background, outline }

/// The optional looks an annotation can have beyond color and size.
struct ItemStyle: Equatable, Codable {
    var dash: DashStyle = .solid
    var arrowHead: ArrowHead = .tapered
    var rounded = false
    var text: TextDecoration = .plain
}
enum MosaicEffect: String, Codable {
    case pixelate, blur
    /// Fill the region in from what surrounds it, instead of hiding what is under it (MI-GAN). No strength:
    /// the model decides how strong the reconstruction is.
    case erase
}

enum Shape: Hashable, Codable {
    case rectangle(CGRect)
    /// The 形状 tool's circle/ellipse, inscribed in the rect. Same stroke, dash and handles as a rectangle.
    case ellipse(CGRect)
    case arrow(CGPoint, CGPoint)
    case pen([CGPoint])
    /// Highlighter, rectangle mode: a right-angled block of ink.
    case highlighterRect(CGRect)
    /// Highlighter, line mode: a capsule stroke between two points, as wide as the item's `size`.
    case highlighterLine(CGPoint, CGPoint)
    case mosaicRect(CGRect)
    case mosaicBrush([CGPoint])
    /// Text origin is the top-left of the first line; lines wrap at `width`.
    case text(String, CGPoint, width: CGFloat)
    case number(CGPoint)
    /// A circle of radius `radius` around `source`, shown enlarged in a lens centered at `target`.
    case magnifier(source: CGPoint, target: CGPoint, radius: CGFloat)
    /// A region the picture keeps its colors and brightness in; everything else is masked (see `drawHighlightMask`).
    case highlight(CGRect, ellipse: Bool)
}

struct AnnotationItem: Equatable {
    var id = UUID()
    var shape: Shape
    var color: NSColor
    var size: CGFloat
    var effect: MosaicEffect = .pixelate
    /// How coarse the mosaic is, as a multiple of its natural strength — 1 is what the tool has always drawn,
    /// and the slider in the style bar goes from there. Per annotation, like `opacity` below, and a new one
    /// starts from whatever the style bar is set to.
    var mosaicStrength: CGFloat = StyleMemory.mosaicStrength
    var style = ItemStyle()
    /// How opaque the highlight mask is, 0.1...1. Only highlights use it, and they all share one mask, so the
    /// style bar writes the same value to every highlight in the picture.
    var opacity: CGFloat = StyleMemory.highlightOpacity
    /// Highlighter only: how the ink meets the picture. New strokes start from the style bar's memory.
    var highlighterBlend: HighlighterBlend = StyleMemory.highlighterBlend

    var tool: Tool {
        switch shape {
        case .rectangle, .ellipse: return .rectangle
        case .arrow: return .arrow
        case .pen, .highlighterRect, .highlighterLine: return .pen
        case .mosaicRect, .mosaicBrush: return .mosaic
        case .text: return .text
        case .number: return .number
        case .magnifier: return .magnifier
        case .highlight: return .highlight
        }
    }

    /// Whether this is a circle/ellipse drawn with the 形状 tool.
    var isEllipseShape: Bool {
        if case .ellipse = shape { return true }
        return false
    }

    /// Whether this is one of the highlighter's two strokes.
    var isHighlighter: Bool {
        switch shape {
        case .highlighterRect, .highlighterLine: return true
        default: return false
        }
    }

    /// The highlighter's stroke mode, for the style bar.
    var highlighterMode: HighlighterMode? {
        switch shape {
        case .highlighterRect: return .rect
        case .highlighterLine: return .line
        default: return nil
        }
    }
}

extension Shape {
    /// The rect a 形状 outline is built from, for switching a selected annotation between rectangle and circle.
    var outlineRect: CGRect? {
        switch self {
        case let .rectangle(r), let .ellipse(r): return r
        default: return nil
        }
    }
}

/// Whether `p` is inside the ellipse inscribed in `r`.
private func pointInsideEllipse(_ p: CGPoint, in r: CGRect) -> Bool {
    guard r.width > 0, r.height > 0 else { return false }
    let dx = (p.x - r.midX) / (r.width / 2), dy = (p.y - r.midY) / (r.height / 2)
    return dx * dx + dy * dy <= 1
}

/// Resize handles of a rectangle, in a flipped (top-left origin) space.
enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// Moves the edges this handle controls by `d`. Dragging past the opposite edge flips the rect.
    func resize(_ r: CGRect, by d: CGPoint) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if [.topLeft, .left, .bottomLeft].contains(self) { minX += d.x }
        if [.topRight, .right, .bottomRight].contains(self) { maxX += d.x }
        if [.topLeft, .top, .topRight].contains(self) { minY += d.y }
        if [.bottomLeft, .bottom, .bottomRight].contains(self) { maxY += d.y }
        return CGRect(corners: CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
    }

    /// The point of `r` this handle leaves where it is while it is dragged: the corner, or the middle of the
    /// side, on the far side — the mirror of `point(in:)`. The pin's proportional resize hangs off this, the
    /// screenshot's selection flips it instead (see `resize(_:by:)`).
    func anchor(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: r.maxX, y: r.maxY)
        case .top: return CGPoint(x: r.midX, y: r.maxY)
        case .topRight: return CGPoint(x: r.minX, y: r.maxY)
        case .right: return CGPoint(x: r.minX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.minX, y: r.minY)
        case .bottom: return CGPoint(x: r.midX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.maxX, y: r.minY)
        case .left: return CGPoint(x: r.maxX, y: r.midY)
        }
    }

    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch self {
            case .topLeft: position = .topLeft
            case .top: position = .top
            case .topRight: position = .topRight
            case .right: position = .right
            case .bottomRight: position = .bottomRight
            case .bottom: position = .bottom
            case .bottomLeft: position = .bottomLeft
            case .left: position = .left
            }
            return .frameResize(position: position, directions: .all)
        }
        switch self {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }
}

/// A draggable control point of an annotation.
enum ItemHandle: Equatable {
    case rect(ResizeHandle)
    case start
    case end
}

// MARK: - Geometry

extension AnnotationItem {
    static func textFont(size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .medium)
    }

    static func textAttributes(color: NSColor, size: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: textFont(size: size), .foregroundColor: color, .paragraphStyle: paragraph]
    }

    static func textSize(_ text: String, size: CGFloat, width: CGFloat) -> CGSize {
        let measured = NSAttributedString(string: text.isEmpty ? " " : text, attributes: textAttributes(color: .black, size: size))
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return CGSize(width: ceil(measured.width), height: ceil(measured.height))
    }

    /// Visual bounds, including stroke width.
    var bounds: CGRect {
        let pad = size / 2 + 1
        switch shape {
        case let .rectangle(r), let .ellipse(r):
            return r.insetBy(dx: -pad, dy: -pad)
        case let .mosaicRect(r), let .highlight(r, _):
            return r
        case let .highlighterRect(r):
            return r
        case let .highlighterLine(a, b):
            return CGRect(corners: a, b).insetBy(dx: -size / 2, dy: -size / 2)
        case let .arrow(a, b):
            let head = Self.arrowHeadWidth(size) / 2
            return CGRect(corners: a, b).insetBy(dx: -head, dy: -head)
        case let .pen(points), let .mosaicBrush(points):
            return points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -pad, dy: -pad)
        case let .text(text, origin, width):
            let r = CGRect(origin: origin, size: Self.textSize(text, size: size, width: width))
            return style.text == .background ? r.insetBy(dx: -Self.textPadding(size), dy: -Self.textPadding(size) / 2) : r
        case let .number(center):
            return CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        case let .magnifier(source, target, radius):
            let lens = radius * Self.magnification
            return CGRect(x: source.x - radius, y: source.y - radius, width: radius * 2, height: radius * 2)
                .union(CGRect(x: target.x - lens, y: target.y - lens, width: lens * 2, height: lens * 2))
                .insetBy(dx: -pad, dy: -pad)
        }
    }

    /// Whether a click at `p` lands on this annotation. Outlined shapes are hit on their stroke only,
    /// so a new shape can still be drawn inside an existing rectangle.
    func contains(_ p: CGPoint) -> Bool {
        let tolerance = max(5, size / 2 + 3)
        switch shape {
        case let .rectangle(r):
            let outer = r.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = r.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(p) && (inner.isEmpty || !inner.contains(p))
        case let .ellipse(r):
            // Like a rectangle, only the stroke takes the click: the inside stays free for a new shape.
            let outer = r.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = r.insetBy(dx: tolerance, dy: tolerance)
            return pointInsideEllipse(p, in: outer) && (inner.isEmpty || !pointInsideEllipse(p, in: inner))
        case let .mosaicRect(r), let .highlight(r, _):
            return r.contains(p)
        case let .highlighterRect(r):
            return r.contains(p)
        case let .highlighterLine(a, b):
            return distance(p, a, b) <= size / 2 + tolerance
        case let .arrow(a, b):
            return distance(p, a, b) <= max(tolerance, Self.arrowHeadWidth(size) / 2)
        case let .pen(points), let .mosaicBrush(points):
            if points.count == 1 { return hypot(p.x - points[0].x, p.y - points[0].y) <= tolerance }
            return zip(points, points.dropFirst()).contains { distance(p, $0, $1) <= tolerance }
        case .text:
            return bounds.insetBy(dx: -4, dy: -4).contains(p)
        case let .number(c):
            return hypot(p.x - c.x, p.y - c.y) <= size / 2 + 3
        case let .magnifier(source, target, radius):
            return hypot(p.x - target.x, p.y - target.y) <= radius * Self.magnification + tolerance
                || abs(hypot(p.x - source.x, p.y - source.y) - radius) <= tolerance
        }
    }

    var handles: [(ItemHandle, CGPoint)] {
        switch shape {
        case let .rectangle(r), let .ellipse(r), let .mosaicRect(r), let .highlight(r, _):
            return ResizeHandle.allCases.map { (.rect($0), $0.point(in: r)) }
        case let .highlighterRect(r):
            return ResizeHandle.allCases.map { (.rect($0), $0.point(in: r)) }
        case let .arrow(a, b):
            return [(.start, a), (.end, b)]
        case let .highlighterLine(a, b):
            return [(.start, a), (.end, b)]
        case let .magnifier(source, target, _):
            return [(.start, source), (.end, target)]
        default:
            return []
        }
    }

    func moved(by d: CGPoint) -> AnnotationItem {
        var copy = self
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.x, y: p.y + d.y) }
        switch shape {
        case let .rectangle(r): copy.shape = .rectangle(r.offsetBy(dx: d.x, dy: d.y))
        case let .ellipse(r): copy.shape = .ellipse(r.offsetBy(dx: d.x, dy: d.y))
        case let .mosaicRect(r): copy.shape = .mosaicRect(r.offsetBy(dx: d.x, dy: d.y))
        case let .highlighterRect(r): copy.shape = .highlighterRect(r.offsetBy(dx: d.x, dy: d.y))
        case let .highlighterLine(a, b): copy.shape = .highlighterLine(m(a), m(b))
        case let .highlight(r, ellipse): copy.shape = .highlight(r.offsetBy(dx: d.x, dy: d.y), ellipse: ellipse)
        case let .arrow(a, b): copy.shape = .arrow(m(a), m(b))
        case let .pen(points): copy.shape = .pen(points.map(m))
        case let .mosaicBrush(points): copy.shape = .mosaicBrush(points.map(m))
        case let .text(text, origin, width): copy.shape = .text(text, m(origin), width: width)
        case let .number(c): copy.shape = .number(m(c))
        case let .magnifier(source, target, radius): copy.shape = .magnifier(source: m(source), target: m(target), radius: radius)
        }
        return copy
    }

    func resized(_ handle: ItemHandle, by d: CGPoint) -> AnnotationItem {
        var copy = self
        switch (shape, handle) {
        case let (.rectangle(r), .rect(h)): copy.shape = .rectangle(h.resize(r, by: d))
        case let (.ellipse(r), .rect(h)): copy.shape = .ellipse(h.resize(r, by: d))
        case let (.mosaicRect(r), .rect(h)): copy.shape = .mosaicRect(h.resize(r, by: d))
        case let (.highlighterRect(r), .rect(h)): copy.shape = .highlighterRect(h.resize(r, by: d))
        case let (.highlight(r, ellipse), .rect(h)): copy.shape = .highlight(h.resize(r, by: d), ellipse: ellipse)
        case let (.arrow(a, b), .start): copy.shape = .arrow(CGPoint(x: a.x + d.x, y: a.y + d.y), b)
        case let (.arrow(a, b), .end): copy.shape = .arrow(a, CGPoint(x: b.x + d.x, y: b.y + d.y))
        case let (.highlighterLine(a, b), .start):
            copy.shape = .highlighterLine(CGPoint(x: a.x + d.x, y: a.y + d.y), b)
        case let (.highlighterLine(a, b), .end):
            copy.shape = .highlighterLine(a, CGPoint(x: b.x + d.x, y: b.y + d.y))
        case let (.magnifier(source, target, radius), .start):
            copy.shape = .magnifier(source: CGPoint(x: source.x + d.x, y: source.y + d.y), target: target, radius: radius)
        case let (.magnifier(source, target, radius), .end):
            copy.shape = .magnifier(source: source, target: CGPoint(x: target.x + d.x, y: target.y + d.y), radius: radius)
        default: break
        }
        return copy
    }

    var isMeaningful: Bool {
        switch shape {
        case let .rectangle(r), let .ellipse(r), let .mosaicRect(r), let .highlight(r, _): return r.width >= 3 && r.height >= 3
        case let .highlighterRect(r): return r.width >= 3 && r.height >= 3
        case let .highlighterLine(a, b): return hypot(a.x - b.x, a.y - b.y) >= 3
        case let .arrow(a, b): return hypot(a.x - b.x, a.y - b.y) >= 3
        case let .pen(points): return points.count >= 2
        case let .mosaicBrush(points): return !points.isEmpty
        case let .text(text, _, _): return !text.isEmpty
        case .number: return true
        case let .magnifier(_, _, radius): return radius >= 4
        }
    }

    static let magnification: CGFloat = 2

    /// Where the lens goes for a new magnifier: beside the circle, inside `bounds` if possible.
    static func lensCenter(source: CGPoint, radius: CGFloat, in bounds: CGRect) -> CGPoint {
        let lens = radius * magnification, gap = radius * 0.6
        var x = source.x + radius + gap + lens
        if x + lens > bounds.maxX { x = source.x - radius - gap - lens }
        let y = min(max(source.y, bounds.minY + lens), bounds.maxY - lens)
        return CGPoint(x: x, y: y)
    }

    static func textPadding(_ size: CGFloat) -> CGFloat { max(4, size * 0.35) }
    static func cornerRadius(for r: CGRect, size: CGFloat) -> CGFloat { min(8 + size * 2, min(r.width, r.height) / 2) }

    static func arrowHeadWidth(_ size: CGFloat) -> CGFloat { size * 3 + 10 }
    static func arrowHeadLength(_ size: CGFloat) -> CGFloat { size * 3 + 12 }
}

private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

extension CGRect {
    init(corners a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

// MARK: - Rendering

/// Which edge of the original the translated text lines up with.
enum TranslationAlignment {
    case leading, center, trailing
}

/// What the translation sits on: the flat color that was behind the original text, or a plate cut from the
/// pixels underneath it when that background was not flat.
enum TranslationBackground {
    case solid(NSColor)
    case plate(image: CGImage, rect: CGRect, color: NSColor, alpha: CGFloat, radius: CGFloat)
}

/// One translated paragraph, laid out and ready to draw over the original text.
struct TranslatedBlock {
    /// Where the original text was: the translated text lines up with this.
    var rect: CGRect
    /// The original lines to wipe, a little wider than the text so ascenders and descenders go too.
    var erase: [CGRect]
    /// Width the translation wraps at, which may reach past `rect` into blank space.
    var wrapWidth: CGFloat
    var text: String
    /// What the text said before it was translated, so「全文」can label which block each full translation
    /// belongs to.
    var sourceText: String
    /// The translation as it came back, before it was shrunk and cut to fit. Equal to `text` unless the
    /// block had to be ellipsized to stay inside the picture — in which case this is what「全文」shows,
    /// because the rest of it has nowhere to go: 复制 / 保存 / 贴图 all render the selection and nothing
    /// outside it, so a translation that spilled past the edge would simply be lost.
    var fullText: String
    var fontSize: CGFloat
    var bold: Bool
    var alignment: TranslationAlignment
    /// The original ink's visual center, which the first translated line centers on.
    var firstCenterY: CGFloat
    /// Baseline-to-baseline distance, taken from the original paragraph.
    var pitch: CGFloat
    var background: TranslationBackground
    var foreground: NSColor
    /// BCP-47 tag of the translated text, so CoreText picks the right glyph shapes.
    var language: String
}

/// Draws annotations and translations over the frozen screen, in a flipped (top-left origin) context.
/// Shared by the on-screen view and the exporter so the saved image matches what was on screen.
struct ContentRenderer {
    let base: NSImage
    let bounds: CGRect
    /// The picture as it should look inside a mosaic item, and where that image goes. 格子 / 毛玻璃 are a
    /// whole-canvas filter (so `rect` is `bounds`); 智能擦除 is a crop around the shape, and keeping it a crop
    /// instead of a full canvas is what makes several erases in one picture affordable.
    struct EffectImage {
        var image: NSImage
        var rect: CGRect
    }

    let effect: (AnnotationItem) -> EffectImage

    func draw(items: [AnnotationItem], translation: [TranslatedBlock]) {
        drawBase()
        drawOverlays(items: items, draft: nil, hiddenID: nil, translation: translation)
    }

    func drawBase() {
        base.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Translations go first so annotations stay on top of them.
    /// On screen the overlay is a transparent layer above the screenshot, which is a separate layer.
    func drawOverlays(items: [AnnotationItem], draft: AnnotationItem?, hiddenID: UUID?, translation: [TranslatedBlock]) {
        // The mask goes under the translations and the annotations, so what the user drew on top of it stays
        // readable; only the picture itself is dimmed.
        drawHighlightMask(items, draft: draft)
        for block in translation { Self.draw(block) }
        var number = 0
        for item in items {
            if case .number = item.shape { number += 1 }
            if item.id != hiddenID { draw(item, number: number) }
        }
        if let draft {
            if case .number = draft.shape { number += 1 }
            draw(draft, number: number)
        }
    }

    /// Dims everything the highlights are not on: the whole area gets a black wash at the highlight's opacity,
    /// then the original picture is drawn again inside each highlight, so those parts keep the colors and
    /// brightness they had. One mask for the picture, which is why they all share an opacity.
    ///
    /// Redrawing the picture, rather than punching holes with an even-odd path, also means overlapping
    /// highlights need no special case: the same pixels are simply drawn twice.
    private func drawHighlightMask(_ items: [AnnotationItem], draft: AnnotationItem?) {
        let highlights = (items + [draft].compactMap { $0 }).filter { if case .highlight = $0.shape { true } else { false } }
        guard let opacity = highlights.first?.opacity, let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        cg.setFillColor(NSColor.black.withAlphaComponent(opacity).cgColor)
        cg.fill(bounds)
        for item in highlights {
            guard case let .highlight(rect, ellipse) = item.shape else { continue }
            cg.saveGState()
            cg.addPath(ellipse ? CGPath(ellipseIn: rect, transform: nil) : CGPath(rect: rect, transform: nil))
            cg.clip()
            base.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            cg.restoreGState()
        }
        cg.restoreGState()
    }

    /// A highlighter stroke. `CGBlendMode.multiply` cannot do the job here: on screen this renderer draws into
    /// the transparent overlay above the frozen screenshot, so a multiply would multiply against nothing and
    /// read as a plain tint. A transparency layer lets the picture be redrawn inside the stroke and the ink
    /// multiplied into it — black stays black, white becomes the ink colour — and the result then composites
    /// as one opaque image. The translucent mode is simply a lighter fill over the picture.
    private func drawHighlighter(_ item: AnnotationItem, path: (CGContext) -> Void) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        path(cg)
        cg.clip()
        if item.highlighterBlend == .translucent {
            item.color.withAlphaComponent(item.highlighterBlend.alpha).setFill()
            cg.fill(bounds)
        } else {
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            drawBase()
            cg.setBlendMode(.multiply)
            item.color.withAlphaComponent(item.highlighterBlend.alpha).setFill()
            cg.fill(bounds)
            cg.endTransparencyLayer()
        }
        cg.restoreGState()
    }

    /// Wipes the original text and puts the translation's background back: either the flat color that was
    /// behind it, or a blurred plate of what was there when the background was not flat.
    static func draw(_ block: TranslatedBlock) {        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        drawBackground(block, in: cg)
        drawText(block, in: cg)
    }

    private static func drawBackground(_ block: TranslatedBlock, in cg: CGContext) {
        switch block.background {
        case let .solid(color):
            cg.saveGState()
            cg.setShouldAntialias(false) // crisp edges, like the fill the original text sat on
            cg.setFillColor(color.cgColor)
            for rect in block.erase { cg.fill(rect) }
            cg.restoreGState()
        case let .plate(image, rect, color, alpha, radius):
            cg.saveGState()
            cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            cg.clip()
            cg.interpolationQuality = .high
            cg.draw(image, in: rect)
            cg.setFillColor(color.withAlphaComponent(alpha).cgColor)
            cg.fill(rect)
            cg.restoreGState()
        }
    }

    /// CoreText lines on their own baselines: the first line's visual center sits where the original ink's
    /// center was, and the rest follow the original line spacing.
    private static func drawText(_ block: TranslatedBlock, in cg: CGContext) {
        let attributes = TranslationText.attributes(size: block.fontSize, bold: block.bold, language: block.language,
                                                    color: block.foreground)
        let lines = TranslationText.lines(block.text, attributes, width: block.wrapWidth)
        guard !lines.isEmpty else { return }
        let font = TranslationText.font(size: block.fontSize, bold: block.bold, language: block.language)
        let centerOffset = TextScript.of(block.text) == .latin ? font.capHeight / 2 : (font.ascender + font.descender) / 2
        var baseline = block.firstCenterY + centerOffset

        cg.saveGState()
        cg.setShouldAntialias(true)
        cg.setShouldSmoothFonts(false)
        for line in lines {
            let lineWidth = TranslationText.width(line)
            let x: CGFloat
            switch block.alignment {
            case .leading: x = block.rect.minX
            case .center: x = block.rect.midX - lineWidth / 2
            case .trailing: x = block.rect.maxX - lineWidth
            }
            cg.saveGState()
            // The context is flipped (top-left origin), so undo that locally for the glyphs.
            cg.textMatrix = .identity
            cg.translateBy(x: x, y: baseline)
            cg.scaleBy(x: 1, y: -1)
            cg.textPosition = .zero
            CTLineDraw(line, cg)
            cg.restoreGState()
            baseline += block.pitch
        }
        cg.restoreGState()
    }

    func draw(_ item: AnnotationItem, number: Int) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setStrokeColor(item.color.cgColor)
        cg.setFillColor(item.color.cgColor)
        cg.setLineWidth(item.size)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        Self.applyDash(item.style.dash, size: item.size, to: cg)

        switch item.shape {
        case .highlight:
            // Nothing to draw where the highlight is: it is a hole in the mask, which `drawHighlightMask` puts
            // under everything else.
            break
        case let .rectangle(r):
            if item.style.rounded {
                let radius = AnnotationItem.cornerRadius(for: r, size: item.size)
                cg.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
                cg.strokePath()
            } else {
                cg.setLineJoin(.miter)
                cg.stroke(r)
            }
        case let .ellipse(r):
            cg.strokeEllipse(in: r)
        case let .highlighterRect(r):
            drawHighlighter(item) { cg in cg.addRect(r) }
        case let .highlighterLine(a, b):
            drawHighlighter(item) { cg in
                cg.move(to: a)
                cg.addLine(to: b)
                cg.setLineDash(phase: 0, lengths: [])
                cg.setLineCap(.round)
                cg.setLineWidth(item.size)
                cg.replacePathWithStrokedPath()
            }
        case let .arrow(a, b):
            if item.style.arrowHead == .tapered, item.style.dash == .solid {
                if let path = Self.arrowPath(from: a, to: b, size: item.size) {
                    cg.addPath(path)
                    cg.fillPath()
                }
            } else {
                Self.drawArrow([a, b], head: item.style.arrowHead, size: item.size, in: cg)
            }
        case let .pen(points):
            cg.addPath(Self.smoothPath(points))
            cg.strokePath()
        case let .mosaicRect(r):
            let layer = effect(item)
            cg.clip(to: r)
            layer.image.draw(in: layer.rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        case let .mosaicBrush(points):
            cg.addPath(Self.smoothPath(points.count == 1 ? [points[0], points[0]] : points))
            cg.replacePathWithStrokedPath()
            cg.clip()
            let layer = effect(item)
            layer.image.draw(in: layer.rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        case let .text(text, origin, width):
            var attributes = AnnotationItem.textAttributes(color: item.color, size: item.size)
            switch item.style.text {
            case .plain:
                break
            case .background:
                // A pill in the chosen color, with black or white text on it.
                let box = item.bounds
                cg.addPath(CGPath(roundedRect: box, cornerWidth: min(6, box.height / 2), cornerHeight: min(6, box.height / 2), transform: nil))
                cg.fillPath()
                attributes[.foregroundColor] = Self.contrastingTextColor(for: item.color)
            case .outline:
                // Negative stroke width strokes and fills, so the letters keep their color with a contrasting edge.
                attributes[.strokeColor] = Self.contrastingTextColor(for: item.color)
                attributes[.strokeWidth] = -max(2.5, 30 / item.size)
            }
            NSAttributedString(string: text, attributes: attributes)
                .draw(with: CGRect(x: origin.x, y: origin.y, width: width, height: 100_000), options: [.usesLineFragmentOrigin])
        case let .magnifier(source, target, radius):
            let lens = radius * AnnotationItem.magnification
            let dx = target.x - source.x, dy = target.y - source.y, distance = max(hypot(dx, dy), 0.001)
            // Connector between the two circles' edges.
            if distance > radius + lens {
                cg.strokeLineSegments(between: [CGPoint(x: source.x + dx / distance * radius, y: source.y + dy / distance * radius),
                                                CGPoint(x: target.x - dx / distance * lens, y: target.y - dy / distance * lens)])
            }
            cg.strokeEllipse(in: CGRect(x: source.x - radius, y: source.y - radius, width: radius * 2, height: radius * 2))
            let lensRect = CGRect(x: target.x - lens, y: target.y - lens, width: lens * 2, height: lens * 2)
            cg.saveGState()
            cg.addEllipse(in: lensRect)
            cg.clip()
            // Map the lens back onto the source circle, enlarged.
            cg.translateBy(x: target.x, y: target.y)
            cg.scaleBy(x: AnnotationItem.magnification, y: AnnotationItem.magnification)
            cg.translateBy(x: -source.x, y: -source.y)
            cg.interpolationQuality = .none
            drawBase()
            cg.restoreGState()
            cg.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            cg.strokeEllipse(in: lensRect)
        case let .number(c):
            let d = item.size
            let circle = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            cg.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
            cg.fillEllipse(in: circle)
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            cg.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            cg.setLineWidth(max(1.5, d / 16))
            cg.strokeEllipse(in: circle.insetBy(dx: 0.75, dy: 0.75))
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: d * (number >= 10 ? 0.46 : 0.56), weight: .bold),
                .foregroundColor: Self.contrastingTextColor(for: item.color),
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2))
        }
    }

    static func contrastingTextColor(for color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    /// Quadratic curves through the midpoints of consecutive samples: smooth, but passes near every sample.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            for p in points.dropFirst() { path.addLine(to: p) }
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    static func applyDash(_ dash: DashStyle, size: CGFloat, to cg: CGContext) {
        switch dash {
        case .solid: break
        case .dashed: cg.setLineDash(phase: 0, lengths: [max(4, size * 3), max(3, size * 2)])
        case .dotted:
            // Zero-length dashes with round caps are dots.
            cg.setLineCap(.round)
            cg.setLineDash(phase: 0, lengths: [0.01, max(3, size * 2)])
        }
    }

    /// A stroked shaft through `points` with filled heads: at the end, or at both ends for `.double`,
    /// or open V heads for `.open`.
    static func drawArrow(_ points: [CGPoint], head: ArrowHead, size: CGFloat, in cg: CGContext) {
        guard let tip = points.last, let beforeTip = points.dropLast().last(where: { hypot($0.x - tip.x, $0.y - tip.y) > 1 }) else { return }
        var shaft = points
        func trim(_ end: CGPoint, from previous: CGPoint) -> CGPoint {
            // Stop the stroke inside the head, so the round cap doesn't poke out of the tip.
            let length = hypot(end.x - previous.x, end.y - previous.y)
            let head = min(AnnotationItem.arrowHeadLength(size), length * 0.6) * 0.8
            return CGPoint(x: end.x - (end.x - previous.x) / length * head, y: end.y - (end.y - previous.y) / length * head)
        }
        if head != .open { shaft[shaft.count - 1] = trim(tip, from: beforeTip) }
        let start = points[0]
        let afterStart = points.dropFirst().first(where: { hypot($0.x - start.x, $0.y - start.y) > 1 })
        if head == .double, let afterStart { shaft[0] = trim(start, from: afterStart) }
        cg.addLines(between: shaft)
        cg.strokePath()
        cg.setLineDash(phase: 0, lengths: [])
        switch head {
        case .tapered:
            cg.addPath(arrowHeadPath(from: beforeTip, to: tip, size: size))
            cg.fillPath()
        case .double:
            cg.addPath(arrowHeadPath(from: beforeTip, to: tip, size: size))
            if let afterStart { cg.addPath(arrowHeadPath(from: afterStart, to: start, size: size)) }
            cg.fillPath()
        case .open:
            let dx = tip.x - beforeTip.x, dy = tip.y - beforeTip.y
            let length = max(hypot(dx, dy), 0.001)
            let ux = dx / length, uy = dy / length
            let arm = min(AnnotationItem.arrowHeadLength(size), length * 0.6)
            let spread = arm * 0.6
            let base = CGPoint(x: tip.x - ux * arm, y: tip.y - uy * arm)
            cg.addLines(between: [CGPoint(x: base.x - uy * spread, y: base.y + ux * spread), tip,
                                  CGPoint(x: base.x + uy * spread, y: base.y - ux * spread)])
            cg.strokePath()
        }
    }

    /// A plain triangular head at `tip`, pointing away from `tail`; used by arrows whose shaft is a stroke.
    static func arrowHeadPath(from tail: CGPoint, to tip: CGPoint, size: CGFloat) -> CGPath {
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length
        let headLength = min(AnnotationItem.arrowHeadLength(size), length * 0.6)
        let headHalf = min(AnnotationItem.arrowHeadWidth(size) / 2, headLength * 0.7)
        let base = CGPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x - uy * headHalf, y: base.y + ux * headHalf))
        path.addLine(to: CGPoint(x: base.x + uy * headHalf, y: base.y - ux * headHalf))
        path.closeSubpath()
        return path
    }

    /// A filled arrow whose shaft widens from the tail towards the head, like WeChat's and QQ's.
    static func arrowPath(from tail: CGPoint, to tip: CGPoint, size: CGFloat) -> CGPath? {
        let dx = tip.x - tail.x, dy = tip.y - tail.y
        let length = hypot(dx, dy)
        guard length > 1 else { return nil }
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let headLength = min(AnnotationItem.arrowHeadLength(size), length * 0.6)
        let headHalf = min(AnnotationItem.arrowHeadWidth(size) / 2, headLength * 0.7)
        let tailHalf = max(0.5, size * 0.15)
        let neckHalf = min(max(size * 0.6, 1.5), headHalf * 0.6)
        let base = CGPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)

        func p(_ o: CGPoint, _ half: CGFloat) -> CGPoint { CGPoint(x: o.x + nx * half, y: o.y + ny * half) }
        let path = CGMutablePath()
        path.move(to: p(tail, tailHalf))
        path.addLine(to: p(base, neckHalf))
        path.addLine(to: p(base, headHalf))
        path.addLine(to: tip)
        path.addLine(to: p(base, -headHalf))
        path.addLine(to: p(base, -neckHalf))
        path.addLine(to: p(tail, -tailHalf))
        path.closeSubpath()
        return path
    }
}
