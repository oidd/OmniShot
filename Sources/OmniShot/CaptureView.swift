import AppKit
import CoreImage
import OmniShotCore

/// Style choices remembered across captures. Color and size are kept per tool, and saved across launches.
enum StyleMemory {
    private static let defaults = UserDefaults.standard

    static func color(for tool: Tool) -> NSColor {
        guard let rgba = (defaults.dictionary(forKey: "style.colors") as? [String: [Double]])?[tool.rawValue], rgba.count == 4 else {
            return StyleState.palette[0]
        }
        return NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
    }

    static func setColor(_ color: NSColor, for tool: Tool) {
        let c = color.usingColorSpace(.sRGB) ?? color
        var all = defaults.dictionary(forKey: "style.colors") as? [String: [Double]] ?? [:]
        all[tool.rawValue] = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map(Double.init)
        defaults.set(all, forKey: "style.colors")
    }

    static func style(for tool: Tool) -> ItemStyle {
        guard let data = defaults.data(forKey: "style.options"),
              let all = try? JSONDecoder().decode([String: ItemStyle].self, from: data) else { return ItemStyle() }
        return all[tool.rawValue] ?? ItemStyle()
    }

    static func setStyle(_ style: ItemStyle, for tool: Tool) {
        var all = (defaults.data(forKey: "style.options")).flatMap { try? JSONDecoder().decode([String: ItemStyle].self, from: $0) } ?? [:]
        all[tool.rawValue] = style
        defaults.set(try? JSONEncoder().encode(all), forKey: "style.options")
    }

    static var sizes: [Tool: CGFloat] {
        get {
            let raw = defaults.dictionary(forKey: "style.sizes") as? [String: Double] ?? [:]
            return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in Tool(rawValue: key).map { ($0, CGFloat(value)) } })
        }
        set { defaults.set(Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, Double($0.value)) }), forKey: "style.sizes") }
    }
    /// 框选 by default: a rectangle covers a stretch of text in one drag, where the brush needs several passes and
    /// is easy to leave a gap in. The brush is still there for odd shapes.
    static var mosaicMode: MosaicMode = .rect
    /// 毛玻璃 by default: pixelating a page of text leaves it legible at the edges of a cell, where a blur just
    /// looks like it was never there.
    static var mosaicEffect: MosaicEffect = .blur
    /// How coarse the next mosaic is drawn, as a multiple of the natural strength (1 = what it always was).
    /// 0.7 rather than 1: at 1 the picture is mosaic beyond what most people want (see `StyleBarView`).
    static var mosaicStrength: CGFloat = 0.7
    /// How opaque the highlight mask is. Every highlight in a picture shares one mask, so they share this too.
    static var highlightOpacity: CGFloat = 0.5
    /// Whether the next highlight is an ellipse instead of a rectangle.
    static var highlightEllipse = false
    /// Whether the 形状 tool draws a rectangle (the default) or a circle/ellipse. Colour, width and dash are the
    /// rectangle tool's: the two modes are one tool, so the only thing they do not share is the rounded-corner
    /// option (which the circle does not have).
    static var shapeMode: RectangleMode = .rect
    /// Whether the pen tool draws with a pencil (what the tool used to be) or a highlighter.
    static var penMode: PenMode = .pencil
    /// Which reading 识别内容 is set to: the text itself (what the X button has always done) or 扫码. Remembered
    /// for the session, like the other sub-modes.
    static var textReadingMode: TextReadingMode = .text
    /// Highlighter: right-angled block or capsule line, how the ink meets the picture, and the line width.
    static var highlighterMode: HighlighterMode = .line
    static var highlighterBlend: HighlighterBlend = .multiply
    /// 1...50, default 20 — the width the owner asked for. Only the line mode uses it.
    static var highlighterWidth: CGFloat = 20
    /// Pure yellow #FFFF00 — the default marker colour, as the owner specified. Kept as one constant so the
    /// palette's first swatch and the default can never drift apart.
    static let defaultHighlighterColor = NSColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
    /// The amber yellow that shipped briefly before the owner corrected it. A saved value equal to it reads as
    /// the new default, so anyone who never picked another colour sees the correction too.
    static var highlighterColor: NSColor {
        get {
            guard let parts = defaults.dictionary(forKey: "style.highlighterColor") as? [String: Double],
                  let r = parts["r"], let g = parts["g"], let b = parts["b"] else { return defaultHighlighterColor }
            if abs(r - 1) < 0.005, abs(g - 0.92) < 0.005, abs(b - 0.23) < 0.005 { return defaultHighlighterColor }
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
        set {
            let color = newValue.usingColorSpace(.sRGB) ?? newValue
            defaults.set(["r": color.redComponent, "g": color.greenComponent, "b": color.blueComponent],
                         forKey: "style.highlighterColor")
        }
    }
    static let highlighterPalette: [NSColor] = [
        defaultHighlighterColor,
        NSColor(srgbRed: 0.55, green: 0.95, blue: 0.42, alpha: 1), // green
        NSColor(srgbRed: 0.40, green: 0.80, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 1.00, green: 0.55, blue: 0.78, alpha: 1), // pink
        NSColor(srgbRed: 1.00, green: 0.68, blue: 0.30, alpha: 1), // orange
        NSColor(srgbRed: 0.72, green: 0.60, blue: 1.00, alpha: 1), // purple
    ]
    static var hexColor = true
    static var lastSelection: [CGDirectDisplayID: CGRect] = [:]

    static func size(for tool: Tool) -> CGFloat { sizes[tool] ?? tool.defaultSize }
}

private enum Drag {
    case none
    case selecting(CGPoint)
    case moving(CGPoint, CGRect)
    case resizing(ResizeHandle, CGRect, CGPoint)
    case drawing(CGPoint)
    case movingItem(CGPoint, AnnotationItem)
    case resizingItem(ItemHandle, AnnotationItem, CGPoint)
    /// A pencil stage with no tool chosen: the picture *is* the pin, so the drag moves the pin window.
    case movingPin(start: CGPoint, origin: CGPoint)
}

private enum TranslationState {
    case none
    case loading
    case shown([TranslatedBlock], CGRect)
    case hidden([TranslatedBlock], CGRect)
}

/// What a click in 自动识别 mode landed on: a target (masked or not), or a mask drawn by hand.
private struct AutoHit: Equatable {
    /// Nil for a mask the user drew themselves — it has no text behind it.
    var target: AutoMaskTarget?
    /// The annotation under the pointer, when the target is already masked.
    var itemID: UUID?
    var rect: CGRect

    var isMasked: Bool { itemID != nil }
}

enum OutputAction {
    case copy, save, saveAs
    /// Finish editing a pin: bake the annotations into it (in a normal capture this is the same as copy).
    case apply
}

/// A normal screenshot, or annotating a pin.
enum CaptureMode: Equatable {
    case screenshot
    /// Annotating a pin: the pin's image is the canvas, everything else stays live and untouched.
    case pinEdit
}

/// Transparent overlay for one display: dimming, selection, annotations, magnifier and toolbar.
/// The frozen screenshot itself is a layer underneath (see `CaptureRootView`), so this view never redraws it.
final class CaptureView: NSView {
    weak var session: CaptureSession?
    let displayID: CGDirectDisplayID

    private let snapshot: CGImage
    private let baseImage: NSImage
    private let windowRects: [CGRect]
    /// One mosaic picture per (effect, strength) actually used. Each of them is a whole screen at backing
    /// resolution, so the cache is capped and the oldest is dropped first — the strength slider walks through
    /// a couple of dozen values in one drag.
    private struct EffectKey: Hashable {
        var effect: MosaicEffect
        var strength: CGFloat
    }
    private static let effectCacheLimit = 4
    /// One context for the whole run. Building one sets up a renderer, and this is called from `draw`: the
    /// strength slider takes a cache miss per step, so a drag used to build a fresh context per frame.
    private static let ciContext = CIContext()
    private var effectImages: [EffectKey: NSImage] = [:]
    private var effectOrder: [EffectKey] = []
    private var renderer: ContentRenderer {
        ContentRenderer(base: baseImage, bounds: bounds, effect: { [unowned self] in self.effectImage(for: $0) })
    }

    /// Pixels per point of the frozen image.
    private var scale: CGFloat { CGFloat(snapshot.width) / bounds.width }

    // Selection
    private(set) var hasSelection = false
    private var selection = CGRect.zero
    private var hoverRect: CGRect?
    private var drag = Drag.none
    private var mouseDownPoint = CGPoint.zero
    private var didDrag = false
    private var shiftDown = false

    // Annotations
    private var items: [AnnotationItem] = []
    private var selectedID: UUID?
    private var hoveredID: UUID?
    private var draft: AnnotationItem?
    private var undoStack: [[AnnotationItem]] = []
    private var redoStack: [[AnnotationItem]] = []
    private var changeStart: [AnnotationItem]?
    private var coalesceWork: DispatchWorkItem?
    private var scrollAccumulator: CGFloat = 0
    private var tool: Tool?
    private var textEditor: TextEditorView?
    private var editingID: UUID?
    /// The number badge whose caption is being typed, reselected if the caption is left empty.
    private var captionedNumberID: UUID?
    private var editingColor = StyleMemory.color(for: .text)
    private var editingSize = StyleMemory.size(for: .text)
    private var editingStyle = StyleMemory.style(for: .text)

    // Translation
    private var recognition: (rect: CGRect, result: RecognitionResult)?
    private var translationState = TranslationState.none
    private var recognitionTask: Task<Void, Never>?
    /// Bumped by every translation so a replaced one can tell that it is stale and keep its hands off the screen.
    private var translationGeneration = 0
    private var pendingBlockRects: [CGRect] = []
    private var shimmerTimer: Timer?
    private var shimmerStart = Date()
    private var ocrBoxesVisible = false
    /// 识别内容's two readings: nil when neither panel is up and the style bar is not on 识别内容. Set for as
    /// long as the result panel is open, so the bar keeps pointing at the X button it came from.
    private var textReadingMode: TextReadingMode?
    /// A reading picked while another one was still running. The running one hands over when it lands, instead
    /// of the click being dropped: reading and scanning share one task handle.
    private var pendingReading: TextReadingMode?
    /// Whether the engine list under the chip is up. It is placed by `layoutEngineMenu`, not by the bar.
    private var engineMenuOpen = false

    // 自动识别（打码的第三种模式）
    /// What the last detection found, in this view's coordinates. Empty when the mode is off or nothing was
    /// found; the frames are only a suggestion, and every token stays clickable.
    private var autoTargets: [AutoMaskTarget] = []
    /// The selection the targets were measured for. A moved or resized selection has to be read again.
    private var autoTargetsRect: CGRect?
    /// 自动识别 reads the screen itself (in strips); this keeps that result for as long as the selection stands.
    private var autoRecognition: (rect: CGRect, result: RecognitionResult)?
    /// The modifiers the green frames and the guide follow. Kept in a property rather than read from
    /// `NSEvent.modifierFlags` while drawing, so a release always repaints with the state the user actually has.
    private var autoHoverFlags: NSEvent.ModifierFlags = []
    private var flagsMonitor: Any?
    private var autoMaskTask: Task<Void, Never>?
    /// Arrow-key nudges move the selection one point at a time; reading the screen on every press would run
    /// Vision dozens of times, so a moved selection is read once the key settles.
    private var autoMaskPendingWork: DispatchWorkItem?
    /// Bumped by every detection so a slow one that has been replaced cannot paint over the newer result.
    private var autoMaskGeneration = 0
    /// When the last detection was sent. Only consulted for a billed engine (百度 OCR), which must not be asked
    /// once per pause of a drag.
    private var lastAutoMaskRequest: Date?
    private var hoveredAuto: AutoHit?
    /// A click on a target held until mouse up, so a drag that starts on it still draws a manual box.
    private var pendingAutoClick: AutoHit?

    /// What the text on screen turned out to be, from the last recognition. Decides which way the
    /// translation goes and what the bar says.
    private var detectedLanguage = ScreenLanguage.other
    /// Set by the bar's swap button when the guess read the screen wrong: it pins the direction to the other
    /// way until the selection is cleared.
    private var directionFlipped = false
    /// The languages the user picked on the bar. nil is 自动 — the guess from the picture, and the settings'
    /// 「默认翻译为」. Either side can be pinned on its own: saying "this is English" should not also decide
    /// where it goes.
    private var sourceOverride: ScreenLanguage?
    private var targetOverride: String?

    /// The two language lists' contents. The source list is what `ScreenLanguage` can name; the target list is
    /// what a translator accepts, which is the same set 输入翻译 offers.
    private static let sourceLanguages: [ScreenLanguage] = [.chinese, .english, .japanese, .korean]
    private static let targetLanguages = SettingsModel.languages
    /// Which side of the bar's direction control opened the list underneath it.
    private enum LanguageMenuKind { case source, target }

    // Chrome
    private lazy var toolbar = ToolbarView(hides: mode == .pinEdit ? ToolbarAction.unavailableInPinEdit : []) {
        [unowned self] in self.handle($0)
    }
    private lazy var styleBar = StyleBarView { [unowned self] in self.applyStyle($0) }
    private let topBar = TopBarView()
    private let toast = ToastView()
    /// 截图翻译 的按钮（关闭和复制和贴图那几个是同一套 `GlyphButton`，连大小都一样）：关掉这次翻译，或者把
    /// 翻好的图复制走。以前复制只能按 ↩。钉住那颗是第三个，见下面。
    private lazy var closeButton: GlyphButton = {
        let button = GlyphButton(glyph: .close)
        button.handler = { [unowned self] in self.cancelCapture() }
        button.toolTip = "关闭（放弃这次翻译）"
        button.setAccessibilityLabel("关闭截图翻译")
        return button
    }()
    private lazy var copyButton: GlyphButton = {
        let button = GlyphButton(glyph: .copy)
        // 和按 ↩ 是同一条路：`finish(.apply)` 落成 `.copy`。
        button.handler = { [unowned self] in self.finish(.apply) }
        button.toolTip = "复制到剪贴板（↩）"
        button.setAccessibilityLabel("复制到剪贴板")
        return button
    }()
    /// 截图翻译 的第三个按钮，夹在关闭和复制中间：把**当前画面**（译文，或者切到原文时的原文）钉在屏幕上。
    /// 图钉先立起来、0.22 秒后才结束截图——不然按钮会随着覆盖层一起消失，动画根本看不见。
    private lazy var translatePinButton: ScanPinButton = {
        let button = ScanPinButton(style: .disc, standsUpOnPress: true) { [unowned self] in self.pinSelection() }
        button.toolTip = "钉住当前画面"
        button.setAccessibilityLabel("钉住当前画面")
        return button
    }()
    private lazy var translationBar = TranslationBarView()
    /// 悬浮条上那个引擎名点开后的列表。它挂在覆盖层上，不是挂在条上：条只有一行高，而列表长在条的
    /// 外面，挂在条上的话条以外的部分收不到点击（`hitTest` 先看父视图的 frame）。也不能用 `NSMenu`——
    /// 那是 AppKit 自己的窗口，层号 101，而覆盖层是 1000：菜单会被整个盖住，看不见也点不到。
    private lazy var engineMenu = EngineMenuView()
    /// The same list, for the two sides of the direction control — 原文语言 and 译文语言.
    private lazy var languageMenu = EngineMenuView()
    private var languageMenuKind: LanguageMenuKind?
    private lazy var translationPanel = TranslationPanelView { [unowned self] in self.closeTranslationPanel() }
    private lazy var ocrPanel = OCRPanelView { [unowned self] in self.closeTextReading() }
    /// 扫码's payloads, in its own box beside the selection. Only one of the two reading panels is up at a time.
    private lazy var scanPanel = ScanPanelView(pinned: false) { [unowned self] in self.pinScanResult() }
    /// 自动识别's operating guide, beside the selection. The highlighted row is the rule a click would use.
    private let autoGuide = AutoMaskGuideView()
    private lazy var magnifier = MagnifierView(snapshot: snapshot, viewSize: bounds.size)

    let mode: CaptureMode
    /// The pencil stage sits over a pin whose own rounded border stays visible through the transparent stage;
    /// the square selection border would be a second, differently-shaped outline on top of it.
    var hidesSelectionBorder = false
    /// 截图翻译：选区一确定就自己翻译，不用再按翻译按钮。
    var autoTranslate = false
    /// 文字识别：选区一确定就把文字复制到剪贴板，不弹识别面板。
    var autoOCR = false
    /// Replaceable for the self-checks, which translate without a network. The config comes in rather than
    /// being read from settings here, because the direction the user picked decides the target language.
    var translate: ([ChatTranslator.Item], TranslationConfig) async throws -> [Int: String] = { items, config in
        try await TranslationService.cache.translate(items, config: config) {
            try await Translator.translate($0, config: config)
        }
    }

    init(frame: CGRect, snapshot: CGImage, windowRects: [CGRect], displayID: CGDirectDisplayID, mode: CaptureMode = .screenshot) {
        self.mode = mode
        self.snapshot = snapshot
        self.baseImage = NSImage(cgImage: snapshot, size: frame.size)
        self.windowRects = windowRects
        self.displayID = displayID
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view in [topBar, toolbar, styleBar, ocrPanel, scanPanel, translationPanel, magnifier, translationBar,
                     engineMenu, languageMenu, closeButton, translatePinButton, copyButton, autoGuide, toast] as [NSView] {
            view.isHidden = true
            addSubview(view)
        }
        translationBar.onSwap = { [weak self] in self?.swapTranslationDirection() }
        translationBar.onToggleOriginal = { [weak self] in self?.toggleTranslation() }
        translationBar.onShowFullText = { [weak self] in self?.openTranslationPanel() }
        translationBar.onOpenEngineMenu = { [weak self] in self?.toggleEngineMenu() }
        translationBar.onOpenSourceMenu = { [weak self] in self?.toggleLanguageMenu(.source) }
        translationBar.onOpenTargetMenu = { [weak self] in self?.toggleLanguageMenu(.target) }
        translationBar.onRetry = { [weak self] in self?.restartTranslation() }
        engineMenu.onPick = { [weak self] in self?.useTranslationEngine(at: $0) }
        languageMenu.onPick = { [weak self] in self?.useTranslationLanguage(at: $0) }
        scanPanel.onOpen = { [weak self] in self?.openScanURL($0) }
        topBar.onResize = { [weak self] in self?.resizeSelection(to: $0) }
        // Editing ends with Return, Tab or a click elsewhere; the keyboard belongs to the capture view again
        // either way, or the next single-key tool shortcut would go into a text field.
        topBar.onEditingEnded = { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self)
        }
        magnifier.showHex = StyleMemory.hexColor
        updateHistoryButtons()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        // 自动识别 follows ⌥ / ⇧ even when this view is not the first responder — the overlay can lose key
        // while the capture is still up. A local monitor is the only reliable place to see the release: a
        // `flagsChanged` that never arrives leaves the category frames lit after the key comes back up.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.setAutoHoverFlags(event.modifierFlags)
            return event
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var testing_selection: CGRect? { hasSelection ? selection : nil }

    func tearDown() {
        recognitionTask?.cancel()
        autoMaskTask?.cancel()
        autoMaskPendingWork?.cancel()
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        stopShimmer()
        coalesceWork?.cancel()
    }

    // MARK: - Drawing

    private var isSelecting: Bool {
        if case .selecting = drag, didDrag { return true }
        return false
    }

    private var isAdjustingSelection: Bool {
        switch drag {
        case .moving, .resizing: return true
        default: return false
        }
    }

    private var focusRect: CGRect? {
        if hasSelection || isSelecting { return selection.width > 0 ? selection : nil }
        return hoverRect
    }

    private var visibleTranslation: [TranslatedBlock] {
        if case let .shown(blocks, _) = translationState { return blocks }
        return []
    }

    /// Pin editing: the pin's rect is the canvas. `items` / `undo` / `redo` let a pencil session continue
    /// where the last one stopped, so the undo button reaches back through earlier sessions. `message` is nil
    /// for the pencil's stage, which needs no line of instructions over the picture.
    func startPinEdit(rect: CGRect, items: [AnnotationItem] = [], undo: [[AnnotationItem]] = [],
                      redo: [[AnnotationItem]] = [], message: String? = "在贴图上标注 · ✓ 或回车完成 · Esc 放弃") {
        selection = rect.intersection(bounds)
        self.items = items
        undoStack = undo
        redoStack = redo
        commitSelection()
        updateHistoryButtons()
        needsDisplay = true
        if let message { showToast(message, duration: 2.5) }
    }

    /// Hands a pencil session back to its pin: the picture with the annotations (and any translation) on it,
    /// plus the model the next session picks up. The base only changes when a translation was on screen —
    /// that has no undo step of its own, so it is folded into the picture before the session ends.
    func finishPinTools() -> (rep: NSBitmapImageRep?, bakedBase: NSBitmapImageRep?, items: [AnnotationItem],
                              undo: [[AnnotationItem]], redo: [[AnnotationItem]]) {
        commitText()
        endChange()
        let bakedBase = visibleTranslation.isEmpty ? nil
            : Exporter.render(renderer: renderer, selection: selection, scale: scale, items: [], translation: visibleTranslation)
        return (exportImage(), bakedBase, items, undoStack, redoStack)
    }

    /// What to highlight at `p` before anything is selected: the window under it.
    private func hoverTarget(at p: CGPoint) -> CGRect? {
        windowRects.first { $0.contains(p) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if mode == .pinEdit {
            // No dimming or handles: the pin is the canvas.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: selection).addClip()
            renderer.drawOverlays(items: items, draft: draft, hiddenID: editingID, translation: visibleTranslation)
            drawAutoMaskOverlay()
            if case .loading = translationState { drawShimmer() }
            NSGraphicsContext.restoreGraphicsState()
            if !hidesSelectionBorder {
                Settings.shared.themeColor.setStroke()
                let border = NSBezierPath(rect: selection.insetBy(dx: -0.75, dy: -0.75))
                border.lineWidth = 1.5
                border.stroke()
            }
            drawItemDecorations()
            return
        }
        let focus = focusRect
        let dim = NSBezierPath(rect: bounds)
        if let focus {
            dim.append(NSBezierPath(rect: focus))
            dim.windingRule = .evenOdd
        }
        if !testing_hidesDim {
            NSColor.black.withAlphaComponent(0.4).setFill()
            dim.fill()
        }
        guard let focus else { return }

        if hasSelection {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: focus).addClip()
            renderer.drawOverlays(items: items, draft: draft, hiddenID: editingID, translation: visibleTranslation)
            if ocrBoxesVisible, let recognition {
                for line in recognition.result.lines {
                    let box = NSBezierPath(roundedRect: line.rect.insetBy(dx: -2, dy: -1), xRadius: 3, yRadius: 3)
                    themeColor.withAlphaComponent(0.14).setFill()
                    box.fill()
                    themeColor.withAlphaComponent(0.55).setStroke()
                    box.lineWidth = 1
                    box.stroke()
                }
            }
            drawAutoMaskOverlay()
            if case .loading = translationState { drawShimmer() }
            NSGraphicsContext.restoreGraphicsState()
            drawItemDecorations()
        }

        // 选边框用的是设置里那个「边框线条颜色」（贴图的边框也用它），不是写死的蓝。
        let frameColor = Settings.shared.themeColor
        frameColor.setStroke()
        let border = NSBezierPath(rect: focus.insetBy(dx: -0.75, dy: -0.75))
        border.lineWidth = hasSelection || isSelecting ? 1.5 : 2.5
        border.stroke()

        if hasSelection {
            for handle in ResizeHandle.allCases {
                let p = handle.point(in: focus)
                let square = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                frameColor.setFill()
                square.fill()
                NSColor.white.setStroke()
                let outline = NSBezierPath(rect: square.insetBy(dx: 0.5, dy: 0.5))
                outline.lineWidth = 1
                outline.stroke()
            }
        }
    }

    private func drawItemDecorations() {
        if let editor = textEditor {
            dashedRect(editor.frame.insetBy(dx: -5, dy: -3))
        }
        if let hovered = item(hoveredID), hovered.id != selectedID, editingID != hovered.id {
            dashedRect(hovered.bounds.insetBy(dx: -3, dy: -3), alpha: 0.5)
        }
        guard let item = item(selectedID), editingID != item.id else { return }
        if case let .mosaicRect(r) = item.shape {
            // 框选的马赛克：虚线框就画在它自己的边上。往外挪 3pt（下面那两种情况）的话，框和模糊之间会
            // 露出一圈没被盖住的原图，看着像马赛克没铺满框——用户就是这么报的。
            dashedRect(r)
        } else if item.handles.isEmpty || item.tool == .mosaic {
            // 画笔马赛克和没有手柄的标注（笔迹、放大镜）按外扩 3pt 的包围盒画：那里本来就没有一条能对齐的边。
            dashedRect(item.bounds.insetBy(dx: -3, dy: -3))
        }
        for (_, p) in item.handles {
            let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
            NSColor.white.setFill()
            dot.fill()
            themeColor.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }

    private func dashedRect(_ rect: CGRect, alpha: CGFloat = 1) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.8 * alpha).setStroke()
        path.stroke()
        path.setLineDash([4, 3], count: 2, phase: 0)
        themeColor.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private func drawShimmer() {
        let t = Date().timeIntervalSince(shimmerStart)
        for (i, rect) in pendingBlockRects.enumerated() {
            let wave = 0.5 + 0.5 * sin(t * 5 - Double(i) * 0.6)
            themeColor.withAlphaComponent(0.10 + 0.16 * wave).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -1.5), xRadius: 3, yRadius: 3).fill()
        }
    }

    /// The whole picture with 格子 or 毛玻璃 applied. 智能擦除 does not come through here — it is a different
    /// thing altogether, see `effectImage(for:)` below.
    private func filteredImage(_ effect: MosaicEffect, strength: CGFloat) -> NSImage {
        let key = EffectKey(effect: effect, strength: strength)
        if let cached = effectImages[key] { return cached }
        let input = CIImage(cgImage: snapshot)
        let output: CIImage?
        switch effect {
        case .erase:
            return baseImage
        case .pixelate:
            let filter = CIFilter(name: "CIPixellate")!
            filter.setValue(input, forKey: kCIInputImageKey)
            // The floor is deliberately low: it used to be 8px, which quietly pinned everything below 0.44× to
            // the same cell and left the bottom of the strength slider doing nothing.
            filter.setValue(max(2, 9 * scale * strength), forKey: kCIInputScaleKey)
            filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
            output = filter.outputImage
        case .blur:
            let filter = CIFilter(name: "CIGaussianBlur")!
            filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
            filter.setValue(9 * scale * strength, forKey: kCIInputRadiusKey)
            output = filter.outputImage
        }
        guard let output, let cg = Self.ciContext.createCGImage(output.cropped(to: input.extent), from: input.extent)
        else { return baseImage }
        let image = NSImage(cgImage: cg, size: bounds.size)
        // Only the last few: one of these is a whole screen at backing resolution (tens of megabytes), and the
        // strength slider can walk through a couple of dozen of them in one drag.
        effectImages[key] = image
        effectOrder.append(key)
        while effectOrder.count > Self.effectCacheLimit {
            effectImages.removeValue(forKey: effectOrder.removeFirst())
        }
        return image
    }

    // MARK: - 智能擦除

    /// One MI-GAN result per erase annotation, kept until its shape changes: moving or resizing an erase changes
    /// the pixels around it, so the old answer no longer belongs there. `rect` is where the crop goes in the
    /// picture; the image is crop-sized, not canvas-sized.
    private var erased: [UUID: (signature: Int, image: NSImage, rect: CGRect)] = [:]
    private var eraseTasks: [UUID: Task<Void, Never>] = [:]

    /// The picture inside a mosaic item. 格子/毛玻璃 share one whole-canvas filter; 智能擦除 needs the model, and
    /// until it has answered the region is blurred — the user asked for those pixels to go away, and a hole
    /// would be worse than a blur.
    private func effectImage(for item: AnnotationItem) -> ContentRenderer.EffectImage {
        switch item.effect {
        case .pixelate, .blur:
            return ContentRenderer.EffectImage(image: filteredImage(item.effect, strength: item.mosaicStrength),
                                               rect: bounds)
        case .erase:
            if let ready = erased[item.id], ready.signature == eraseSignature(item) {
                return ContentRenderer.EffectImage(image: ready.image, rect: ready.rect)
            }
            return ContentRenderer.EffectImage(image: filteredImage(.blur, strength: 1), rect: bounds)
        }
    }

    private func eraseSignature(_ item: AnnotationItem) -> Int {
        var hasher = Hasher()
        hasher.combine(item.shape)
        hasher.combine(item.size)
        return hasher.finalize()
    }

    /// Runs the model for every erase whose shape has changed. Called when a change settles, not from `draw`:
    /// the model takes tens of milliseconds and a drag would ask for it on every frame.
    private func updateErased() {
        let live = Set(items.map(\.id))
        erased = erased.filter { live.contains($0.key) }
        for item in items where item.effect == .erase && item.tool == .mosaic {
            let signature = eraseSignature(item)
            if erased[item.id]?.signature == signature || eraseTasks[item.id] != nil { continue }
            guard let job = eraseJob(for: item) else { continue }
            eraseTasks[item.id] = Task { [weak self] in
                let made = await Task.detached(priority: .userInitiated) {
                    Inpainting.inpaint(crop: job.crop, mask: job.mask)
                }.value
                guard let self else { return }
                self.eraseTasks[item.id] = nil
                guard let made else { return }
                // The shape may have moved on while the model was busy: that answer is for the old one.
                guard let current = self.item(item.id), self.eraseSignature(current) == signature else { return }
                self.erased[item.id] = (signature, NSImage(cgImage: made, size: job.rect.size), job.rect)
                self.invalidate(current.bounds, margin: 4)
            }
        }
    }

    /// The model cannot wait for a background task when the picture is copied or saved, and shipping the blur
    /// placeholder would bake it into the file.
    private func materializeErased() {
        for item in items where item.effect == .erase && item.tool == .mosaic {
            let signature = eraseSignature(item)
            if erased[item.id]?.signature == signature { continue }
            guard let job = eraseJob(for: item), let made = Inpainting.inpaint(crop: job.crop, mask: job.mask) else { continue }
            erased[item.id] = (signature, NSImage(cgImage: made, size: job.rect.size), job.rect)
        }
    }

    /// The pixels around an erase and its mask. The network only ever sees 512×512, so the crop is the shape
    /// plus as much context as it can get — context is the only thing it has to fill from.
    private func eraseJob(for item: AnnotationItem) -> (crop: CGImage, mask: CGImage, rect: CGRect)? {
        let painted = item.bounds.intersection(bounds)
        guard painted.width > 1, painted.height > 1 else { return nil }
        let context = max(32, max(painted.width, painted.height) * 0.75)
        let rect = painted.insetBy(dx: -context, dy: -context).intersection(bounds)
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                            width: rect.width * scale, height: rect.height * scale).integral
        guard let crop = snapshot.cropping(to: pixels), crop.width > 1, crop.height > 1 else { return nil }

        // The mask in the model's own convention: white everywhere the pixels stay, black across the shape.
        guard let mask = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        mask.setFillColor(gray: 1, alpha: 1)
        mask.fill(CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        mask.setFillColor(gray: 0, alpha: 1)
        mask.setStrokeColor(gray: 0, alpha: 1)
        mask.setLineCap(.round)
        mask.setLineJoin(.round)
        mask.translateBy(x: 0, y: CGFloat(crop.height))
        mask.scaleBy(x: scale, y: -scale)
        mask.translateBy(x: -rect.minX, y: -rect.minY)
        switch item.shape {
        case let .mosaicRect(r):
            mask.fill(r)
        case let .mosaicBrush(points):
            mask.setLineWidth(item.size)
            mask.addPath(ContentRenderer.smoothPath(points.count == 1 ? [points[0], points[0]] : points))
            mask.replacePathWithStrokedPath()
            mask.fillPath()
        default:
            return nil
        }
        guard let maskImage = mask.makeImage() else { return nil }
        if ProcessInfo.processInfo.environment["OMNISHOT_DEBUG_ERASE"] != nil {
            // Debug: exactly the two pictures the model is about to be given.
            for (image, name) in [(crop, "crop"), (maskImage, "mask")] {
                if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/omnishot-erase-\(name).png"))
                }
            }
        }
        return (crop, maskImage, rect)
    }

    /// Marks the area around `rects` for redraw; used on hot paths instead of redrawing the whole screen.
    private func invalidate(_ rects: CGRect..., margin: CGFloat = 12) {
        let union = rects.filter { !$0.isNull }.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return }
        // The highlight mask covers the whole view, so while one is around — or being dragged — every change
        // has to redraw all of it. Redrawing just the changed part leaves the mask showing as a thick
        // translucent frame around the region, which is not what anyone drew.
        let masked = items.contains { $0.shape.isHighlight } || draft?.shape.isHighlight == true
        let area = masked ? bounds : union.insetBy(dx: -margin, dy: -margin)
        testing_lastRedraw = area
        setNeedsDisplay(area)
    }

    /// What the last invalidation covered; the self-checks use it to keep the mask redrawing the whole view.
    private(set) var testing_lastRedraw: CGRect?

    // MARK: - Items

    private func item(_ id: UUID?) -> AnnotationItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return items.firstIndex { $0.id == selectedID }
    }

    private func hitItem(at p: CGPoint) -> AnnotationItem? {
        guard selection.insetBy(dx: -6, dy: -6).contains(p) else { return nil }
        // A freehand tool always paints, so strokes can be layered without selecting what is underneath.
        if let tool, tool.alwaysStartsNew { return nil }
        return items.reversed().first { $0.id != editingID && $0.contains(p) }
    }

    private func itemHandle(at p: CGPoint) -> ItemHandle? {
        guard let item = item(selectedID) else { return nil }
        return item.handles.first { abs($0.1.x - p.x) <= 7 && abs($0.1.y - p.y) <= 7 }?.0
    }

    private func select(_ id: UUID?) {
        guard selectedID != id else { return }
        let old = item(selectedID)?.bounds ?? .null
        selectedID = id
        invalidate(old, item(id)?.bounds ?? .null, margin: 14)
        layoutChrome()
    }

    private func replaceItem(_ item: AnnotationItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        let old = items[i].bounds
        items[i] = item
        invalidate(old, item.bounds, margin: max(14, item.size))
    }

    // MARK: - Undo

    private func beginChange() {
        if changeStart == nil { changeStart = items }
    }

    private func endChange() {
        coalesceWork?.cancel()
        coalesceWork = nil
        guard let start = changeStart else { return }
        changeStart = nil
        if start != items {
            undoStack.append(start)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        updateHistoryButtons()
        updateErased()
    }

    /// Groups rapid changes (scrolling, arrow nudges, color panel drags) into one undo step.
    private func coalescedChange(_ body: () -> Void) {
        beginChange()
        body()
        coalesceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endChange() }
        coalesceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func mutate(_ body: () -> Void) {
        beginChange()
        body()
        endChange()
    }

    private func updateHistoryButtons() {
        toolbar.setCanUndo(!undoStack.isEmpty || isTranslationShown)
    }

    private var isTranslationShown: Bool {
        if case .shown = translationState { return true }
        return false
    }

    @objc func undo(_ sender: Any?) {
        commitText()
        endChange()
        if let previous = undoStack.popLast() {
            redoStack.append(items)
            items = previous
            if item(selectedID) == nil { selectedID = nil }
        } else if case let .shown(blocks, rect) = translationState {
            translationState = .hidden(blocks, rect)
            toolbar.translateButton.isActive = false
        }
        updateErased()
        updateHistoryButtons()
        layoutChrome()
        needsDisplay = true
    }

    @objc func redo(_ sender: Any?) {
        commitText()
        endChange()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        if item(selectedID) == nil { selectedID = nil }
        updateHistoryButtons()
        updateErased()
        layoutChrome()
        needsDisplay = true
    }

    @objc func copy(_ sender: Any?) {
        if hasSelection { finish(.copy) }
    }

    // MARK: - Mouse

    private func point(_ event: NSEvent) -> CGPoint {
        clampToBounds(convert(event.locationInWindow, from: nil))
    }

    /// The event's location in screen coordinates — the space the pin's window frame lives in.
    private func screenPoint(_ event: NSEvent) -> CGPoint {
        guard let window else { return NSEvent.mouseLocation }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func clampToBounds(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX - 0.01), y: min(max(p.y, bounds.minY), bounds.maxY - 0.01))
    }

    /// Positions the magnifier and hover state for the current mouse location; called when the overlay appears.
    func primeCursor() {
        guard let window else { return }
        handleMouseMoved(at: clampToBounds(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    override func mouseMoved(with event: NSEvent) {
        handleMouseMoved(at: point(event))
    }

    private func handleMouseMoved(at p: CGPoint) {
        guard session?.canInteract(self) ?? true else {
            magnifier.isHidden = true
            return
        }
        setAutoHoverFlags(NSEvent.modifierFlags)
        // 自动识别: the pointer is a picker, not a drawing cursor — except on the selection's own handles.
        if isAutoMaskMode {
            if let handle = selectionHandle(at: p) {
                setHoveredAuto(nil)
                handle.cursor.set()
                return
            }
            let hit = autoHit(at: p)
            setHoveredAuto(hit)
            if hit != nil { NSCursor.pointingHand.set() }
            else if selection.contains(p) { NSCursor.crosshair.set() }
            else { NSCursor.arrow.set() }
            return
        }
        if hoveredAuto != nil { setHoveredAuto(nil) }
        if !hasSelection {
            let hover = hoverTarget(at: p)
            if hover != hoverRect {
                let old = hoverRect ?? .null
                hoverRect = hover
                invalidate(old, hover ?? .null, margin: 4)
                layoutChrome()
            }
            showMagnifier(at: p, sizeText: nil)
            NSCursor.crosshair.set()
            return
        }

        let hovered = textEditor == nil ? hitItem(at: p)?.id : nil
        if hovered != hoveredID {
            let old = item(hoveredID)?.bounds ?? .null
            hoveredID = hovered
            invalidate(old, item(hovered)?.bounds ?? .null)
        }

        if let handle = itemHandle(at: p) {
            if case let .rect(h) = handle { h.cursor.set() } else { NSCursor.crosshair.set() }
        } else if hovered != nil {
            NSCursor.openHand.set()
        } else if let handle = selectionHandle(at: p) {
            handle.cursor.set()
        } else if selection.contains(p) {
            if let tool {
                (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
            } else {
                NSCursor.openHand.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }

    private func showMagnifier(at p: CGPoint, sizeText: String?) {
        magnifier.sizeText = sizeText
        magnifier.update(cursor: p, in: bounds)
        magnifier.isHidden = false
    }

    var testing_magnifierVisible: Bool { !magnifier.isHidden }
    var testing_magnifier: MagnifierView { magnifier }

    private func sizeText(_ r: CGRect) -> String {
        "\(Int(r.width.rounded())) × \(Int(r.height.rounded()))"
    }

    override func mouseDown(with event: NSEvent) {
        guard session?.canInteract(self) ?? true else { return }
        window?.makeKey()
        let p = point(event)
        mouseDownPoint = p
        didDrag = false
        pendingOutsideCancel = false
        setAutoHoverFlags(event.modifierFlags)
        if textEditor != nil {
            let wasCaption = captionedNumberID != nil
            commitText()
            // With the number tool, the click that ends a caption also places the next number.
            guard wasCaption, tool == .number else { return }
            select(nil)
        }
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }

        // 打开着的引擎列表先吃掉这一次点击：点外面就是把它关掉，别顺手又起了新选区、或者按「点外侧退出」
        // 这条设置退出这次截图 —— 那都不是用户点这一下的意思。
        if engineMenuOpen || languageMenuKind != nil {
            closeEngineMenu()
            closeLanguageMenu()
            return
        }

        guard hasSelection else {
            drag = .selecting(p)
            return
        }

        // 截图翻译：选区外面的一"击"（而不是拖拽）按设置退出。这里只记下来，等 mouse up 看指针动没动——
        // 拖拽也是从 mouse down 开始的，而"外侧拖拽重新框选"这条必须保住。
        pendingDismiss = autoTranslate && mode == .screenshot && !selection.contains(p) && dismissesOnClick(event.clickCount)

        let hit = hitItem(at: p)
        if event.clickCount == 2 {
            if let hit, case .text = hit.shape {
                beginTextEditing(existing: hit)
                return
            }
            if hit == nil, tool == nil, selection.contains(p) {
                // 双击选区直接钉在屏幕上；编辑贴图时再冒出一个新贴图就说不通了，那边保持老行为（复制）。
                // 铅笔舞台上连复制都不要：那里双击空处多半是接着拖动，关掉贴图绝不是这一下的意思。
                if mode == .screenshot { pinSelection() } else if session?.isPinStage != true { finish(.copy) }
                return
            }
        }
        if let item = item(selectedID), let handle = itemHandle(at: p) {
            beginChange()
            drag = .resizingItem(handle, item, p)
            return
        }
        if hit == nil, mode == .screenshot, let handle = selectionHandle(at: p) {
            drag = .resizing(handle, selection, p)
            return
        }
        // 自动识别: the press toggles, but it also starts a manual box — a drag that begins on a target means
        // "put a box here", and mouseUp keeps that box only if the pointer actually moved.
        if let target = autoHit(at: p) {
            pendingAutoClick = target
            setHoveredAuto(nil)
            beginAnnotation(.mosaic, at: p)
            return
        }
        if let hit {
            select(hit.id)
            beginChange()
            drag = .movingItem(p, hit)
            NSCursor.closedHand.set()
            return
        }
        select(nil)
        if mode == .pinEdit, session?.isPinStage == true {
            // The pencil stage's picture is the pin itself. With no tool chosen a drag moves the pin (the
            // stage follows through `CaptureSession.pinMoved`); outside the picture there is nothing to do —
            // above all it must not start a new selection, which would leave the stage framing something else.
            if let tool, selection.contains(p) {
                beginAnnotation(tool, at: p)
            } else if selection.contains(p), let origin = session?.beginEditingPinDrag() {
                drag = .movingPin(start: screenPoint(event), origin: origin)
                NSCursor.closedHand.set()
            }
        } else if let tool, selection.contains(p) {
            beginAnnotation(tool, at: p)
        } else if selection.contains(p), mode == .screenshot {
            drag = .moving(p, selection)
            NSCursor.closedHand.set()
        } else if mode == .screenshot, !autoTranslate {
            // A press outside the selection. A click ends the capture; a drag on an untouched selection starts a
            // new one. Which it was is only known on mouse-up (`pendingOutsideCancel`).
            pendingOutsideCancel = true
            if items.isEmpty, case .none = translationState {
                resetSelection()
                drag = .selecting(p)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        setAutoHoverFlags(event.modifierFlags)
        if !didDrag, hypot(p.x - mouseDownPoint.x, p.y - mouseDownPoint.y) > 2 {
            didDrag = true
            if isAutoMaskMode { refreshAutoGuide() }
        }
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            return
        case let .selecting(start):
            guard didDrag else { return }
            let old = selection
            var end = p
            if shift {
                let side = max(abs(p.x - start.x), abs(p.y - start.y))
                end = clampToBounds(CGPoint(x: start.x + (p.x >= start.x ? side : -side), y: start.y + (p.y >= start.y ? side : -side)))
            }
            selection = CGRect(corners: start, end)
            if hoverRect != nil {
                hoverRect = nil
                needsDisplay = true
            }
            invalidate(old, selection)
            showMagnifier(at: end, sizeText: sizeText(selection))
            layoutChrome()
        case let .moving(start, original):
            let old = selection
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.minX, 0), bounds.width - r.width)
            r.origin.y = min(max(r.minY, 0), bounds.height - r.height)
            selection = r
            invalidate(old, selection)
            layoutChrome()
        case let .resizing(handle, original, start):
            let old = selection
            selection = handle.resize(original, by: CGPoint(x: p.x - start.x, y: p.y - start.y)).intersection(bounds)
            invalidate(old, selection)
            showMagnifier(at: p, sizeText: sizeText(selection))
            layoutChrome()
        case let .drawing(start):
            let old = draft?.bounds ?? .null
            updateDraft(from: start, to: clampToSelection(p), shift: shift)
            invalidate(old, draft?.bounds ?? .null, margin: 4 + (draft?.size ?? 0))
        case let .movingItem(start, original):
            replaceItem(original.moved(by: CGPoint(x: p.x - start.x, y: p.y - start.y)))
        case let .resizingItem(handle, original, start):
            replaceItem(original.resized(handle, by: CGPoint(x: p.x - start.x, y: p.y - start.y)))
        case let .movingPin(start, origin):
            let mouse = screenPoint(event)
            session?.moveEditingPin(to: CGPoint(x: origin.x + mouse.x - start.x, y: origin.y + mouse.y - start.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        let finished = drag
        drag = .none
        setAutoHoverFlags(event.modifierFlags)
        if isAutoMaskMode { refreshAutoGuide() }
        if let pending = pendingAutoClick {
            pendingAutoClick = nil
            if !didDrag {
                // A click, not a drag: the zero-size draft goes away and the masks toggle.
                draft = nil
                handleAutoClick(pending, at: mouseDownPoint, flags: event.modifierFlags)
                return
            }
            // It was a drag: fall through to `.drawing`, which keeps the manual box.
        }
        if pendingDismiss {
            pendingDismiss = false
            // 指针没动过才算"点了一下"；拖了就是重新框选，走到下面去。
            if !didDrag {
                cancelCapture()
                return
            }
        }
        if pendingOutsideCancel {
            pendingOutsideCancel = false
            // 点一下选区外面就退出这次截图；拖出去仍然是重新框选。
            if !didDrag {
                cancelCapture()
                return
            }
        }
        switch finished {
        case .none:
            return
        case .selecting:
            if didDrag {
                guard selection.width >= 4, selection.height >= 4 else {
                    selection = .zero
                    layoutChrome()
                    needsDisplay = true
                    return
                }
            } else {
                // A click picks the window under the cursor, or the whole screen.
                selection = hoverRect?.intersection(bounds) ?? bounds
            }
            commitSelection()
        case .moving, .resizing:
            if selection.width < 4 || selection.height < 4 {
                selection = CGRect(x: selection.minX, y: selection.minY, width: max(4, selection.width), height: max(4, selection.height))
            }
            magnifier.isHidden = true
            layoutChrome()
            needsDisplay = true
            // 截图翻译：选区改了，译文跟着重翻一次。
            autoTranslateIfNeeded()
            // 自动识别：框住的还是那块画面，但框住的字变了。
            autoMaskSelectionChanged()
        case .drawing:
            if let draft, draft.isMeaningful {
                mutate { items.append(draft) }
                selectedID = draft.id
            }
            let bounds = draft?.bounds ?? .null
            draft = nil
            invalidate(bounds, margin: 16)
            layoutChrome()
        case .movingItem, .resizingItem:
            endChange()
            handleMouseMoved(at: point(event))
        case .movingPin:
            NSCursor.openHand.set()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if textEditor != nil {
            commitText()
        } else if !hasSelection {
            session?.cancel()
        } else if selectedID != nil {
            select(nil)
        } else if mode == .pinEdit {
            return
        } else if tool != nil {
            setTool(nil)
        } else if items.isEmpty, case .none = translationState {
            resetSelection()
            primeCursor()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard hasSelection, let tool = textEditor != nil ? .text : selectedTool ?? tool else { return }
        if tool == .mosaic {
            let brush = item(selectedID).map { $0.shape.isMosaicBrush } ?? (StyleMemory.mosaicMode == .brush)
            guard brush else { return }
        }
        scrollAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 6 : event.scrollingDeltaY
        guard abs(scrollAccumulator) >= 1 else { return }
        let steps = scrollAccumulator.rounded(.towardZero)
        scrollAccumulator -= steps
        // The highlighter's line width has its own slider and its own range; the wheel walks the same values.
        // Its rectangle mode has nothing to adjust, so the wheel must not fall through to the pencil's size.
        if tool == .pen, let style = currentStyle, style.penMode == .highlighter {
            guard style.highlighterMode == .line else { return }
            applyStyle(.highlighterWidth(style.size + steps), coalesce: true)
            return
        }
        let unit: CGFloat = tool == .mosaic || tool == .text || tool == .number ? 2 : 1
        let current = currentStyle?.size ?? tool.defaultSize
        applyStyle(.size(current + steps * unit), coalesce: true)
    }

    private func selectionHandle(at p: CGPoint) -> ResizeHandle? {
        ResizeHandle.allCases.first {
            let h = $0.point(in: selection)
            return abs(h.x - p.x) <= 8 && abs(h.y - p.y) <= 8
        }
    }

    private func clampToSelection(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, selection.minX), selection.maxX), y: min(max(p.y, selection.minY), selection.maxY))
    }

    private func commitSelection() {
        hasSelection = true
        hoverRect = nil
        magnifier.isHidden = true
        session?.didSelect(self)
        // 文字识别快捷键：选区一定就收起整个界面，工具栏连摆都不摆——摆了也是一闪而过。
        if autoOCR, mode == .screenshot {
            autoOCRIfNeeded()
            return
        }
        layoutChrome()
        needsDisplay = true
        autoTranslateIfNeeded()
    }

    private func resetSelection() {
        commitText()
        stopAutoMask()
        recognitionTask?.cancel()
        recognitionTask = nil
        stopShimmer()
        hasSelection = false
        selection = .zero
        tool = nil
        toolbar.setActiveTool(nil)
        items = []
        undoStack = []
        redoStack = []
        selectedID = nil
        hoveredID = nil
        recognition = nil
        translationState = .none
        // A new selection is new content: let the direction be guessed again rather than carrying over an
        // override the user made about the last one.
        detectedLanguage = .other
        directionFlipped = false
        sourceOverride = nil
        targetOverride = nil
        closeLanguageMenu()
        toolbar.translateButton.isActive = false
        hideReadingPanels()
        closeTranslationPanel()
        toast.hide()
        session?.didClearSelection(self)
        updateHistoryButtons()
        layoutChrome()
        needsDisplay = true
    }

    // MARK: - Drawing annotations

    private func setTool(_ newTool: Tool?) {
        commitText()
        tool = newTool
        // Picking a tool moves on from 识别内容: its row belongs to the X button, and an annotation tool has its
        // own. A result panel that is already open stays — it is something to read while drawing.
        if newTool != nil { textReadingMode = nil }
        select(nil)
        toolbar.setActiveTool(tool)
        if newTool == .mosaic, StyleMemory.mosaicMode == .auto {
            startAutoMaskDetection()
        } else {
            stopAutoMask()
        }
        layoutChrome()
    }

    private func beginAnnotation(_ tool: Tool, at p: CGPoint) {
        let color = StyleMemory.color(for: tool)
        let size = StyleMemory.size(for: tool)
        let style = StyleMemory.style(for: tool)
        switch tool {
        case .text:
            beginTextEditing(at: p)
        case .number:
            let item = AnnotationItem(shape: .number(p), color: color, size: size, style: style)
            mutate { items.append(item) }
            invalidate(item.bounds, margin: 16)
            // A number is usually followed by its explanation, so start typing right beside it.
            beginTextEditing(at: CGPoint(x: p.x + size / 2 + 6, y: p.y))
            captionedNumberID = item.id
        case .pen:
            if StyleMemory.penMode == .highlighter {
                let blend = StyleMemory.highlighterBlend
                switch StyleMemory.highlighterMode {
                case .rect:
                    draft = AnnotationItem(shape: .highlighterRect(CGRect(origin: p, size: .zero)),
                                           color: StyleMemory.highlighterColor, size: 0, style: style,
                                           highlighterBlend: blend)
                case .line:
                    draft = AnnotationItem(shape: .highlighterLine(p, p),
                                           color: StyleMemory.highlighterColor, size: StyleMemory.highlighterWidth,
                                           style: style, highlighterBlend: blend)
                }
            } else {
                draft = AnnotationItem(shape: .pen([p]), color: color, size: size, style: style)
            }
            drag = .drawing(p)
        case .magnifier:
            draft = AnnotationItem(shape: .magnifier(source: p, target: p, radius: 0), color: color, size: size)
            drag = .drawing(p)
        case .mosaic:
            let effect = StyleMemory.mosaicEffect
            let strength = StyleMemory.mosaicStrength
            if StyleMemory.mosaicMode == .brush {
                let item = AnnotationItem(shape: .mosaicBrush([p]), color: color, size: size, effect: effect, mosaicStrength: strength)
                draft = item
                invalidate(item.bounds)
            } else {
                draft = AnnotationItem(shape: .mosaicRect(CGRect(origin: p, size: .zero)), color: color, size: size,
                                       effect: effect, mosaicStrength: strength)
            }
            drag = .drawing(p)
        case .rectangle:
            let r = CGRect(origin: p, size: .zero)
            let shape: Shape = StyleMemory.shapeMode == .ellipse ? .ellipse(r) : .rectangle(r)
            draft = AnnotationItem(shape: shape, color: color, size: size, style: style)
            drag = .drawing(p)
        case .highlight:
            draft = AnnotationItem(shape: .highlight(CGRect(origin: p, size: .zero), ellipse: StyleMemory.highlightEllipse),
                                   color: color, size: size, opacity: StyleMemory.highlightOpacity)
            drag = .drawing(p)
        case .arrow:
            draft = AnnotationItem(shape: .arrow(p, p), color: color, size: size, style: style)
            drag = .drawing(p)
        }
    }

    private func updateDraft(from start: CGPoint, to p: CGPoint, shift: Bool) {
        guard var item = draft else { return }
        switch item.shape {
        case var .pen(points):
            if shift, let first = points.first {
                points = [first, p]
            } else if let last = points.last, hypot(p.x - last.x, p.y - last.y) >= 1 {
                points.append(p)
            }
            item.shape = .pen(points)
        case var .mosaicBrush(points):
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) >= 1 { points.append(p) }
            item.shape = .mosaicBrush(points)
        case .rectangle, .ellipse, .mosaicRect, .highlight, .highlighterRect:
            var end = p
            if shift {
                let side = max(abs(p.x - start.x), abs(p.y - start.y))
                end = CGPoint(x: start.x + (p.x >= start.x ? side : -side), y: start.y + (p.y >= start.y ? side : -side))
            }
            let r = CGRect(corners: start, end)
            switch item.shape {
            case .rectangle: item.shape = .rectangle(r)
            case .ellipse: item.shape = .ellipse(r)
            case .mosaicRect: item.shape = .mosaicRect(r)
            case .highlighterRect: item.shape = .highlighterRect(r)
            case let .highlight(_, ellipse): item.shape = .highlight(r, ellipse: ellipse)
            default: break
            }
        case .arrow:
            var end = p
            if shift {
                // Snap to 45° steps.
                let angle = (atan2(p.y - start.y, p.x - start.x) / (.pi / 4)).rounded() * (.pi / 4)
                let length = hypot(p.x - start.x, p.y - start.y)
                end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
            }
            item.shape = .arrow(start, end)
        case .highlighterLine:
            var end = p
            if shift {
                // A straight highlighter stroke snaps to 45° steps, like the arrow.
                let angle = (atan2(p.y - start.y, p.x - start.x) / (.pi / 4)).rounded() * (.pi / 4)
                let length = hypot(p.x - start.x, p.y - start.y)
                end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
            }
            if case let .highlighterLine(origin, _) = item.shape { item.shape = .highlighterLine(origin, end) }
        case .magnifier:
            let radius = hypot(p.x - start.x, p.y - start.y)
            item.shape = .magnifier(source: start, target: AnnotationItem.lensCenter(source: start, radius: radius, in: selection), radius: radius)
        case .text, .number:
            break
        }
        draft = item
    }

    private func deleteSelectedItem() {
        guard let id = selectedID else { return }
        mutate { items.removeAll { $0.id == id } }
        selectedID = nil
        hoveredID = nil
        // Numbers after the deleted one shift down, so redraw everything.
        needsDisplay = true
        layoutChrome()
    }

    // MARK: - Text

    private func beginTextEditing(at p: CGPoint? = nil, existing: AnnotationItem? = nil) {
        commitText()
        beginChange()
        var origin = p ?? .zero
        var text = ""
        if let existing, case let .text(t, o, _) = existing.shape {
            origin = o
            text = t
            editingColor = existing.color
            editingSize = existing.size
            editingStyle = existing.style
            editingID = existing.id
            selectedID = nil
        } else {
            editingColor = StyleMemory.color(for: .text)
            editingSize = StyleMemory.size(for: .text)
            editingStyle = StyleMemory.style(for: .text)
            origin.y -= editingSize * 0.6
        }
        let wrap = max(60, selection.maxX - origin.x - 6)
        let editor = TextEditorView(origin: origin, wrapWidth: wrap, color: editingColor, size: editingSize)
        editor.string = text
        editor.apply(color: editingColor, size: editingSize)
        editor.onCommit = { [unowned self] in self.commitText() }
        editor.onResize = { [unowned self] in self.needsDisplay = true }
        addSubview(editor, positioned: .below, relativeTo: topBar)
        textEditor = editor
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        layoutChrome()
        needsDisplay = true
    }

    private func commitText() {
        guard let editor = textEditor else { return }
        textEditor = nil
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let shape = Shape.text(text, editor.frame.origin, width: editor.wrapWidth)
        if let id = editingID, let i = items.firstIndex(where: { $0.id == id }) {
            if text.isEmpty {
                items.remove(at: i)
            } else {
                items[i].shape = shape
                items[i].color = editingColor
                items[i].size = editingSize
                items[i].style = editingStyle
                selectedID = id
            }
        } else if !text.isEmpty {
            let item = AnnotationItem(shape: shape, color: editingColor, size: editingSize, style: editingStyle)
            items.append(item)
            selectedID = item.id
        }
        if let id = captionedNumberID, text.isEmpty, items.contains(where: { $0.id == id }) {
            selectedID = id
        }
        captionedNumberID = nil
        editingID = nil
        editor.removeFromSuperview()
        endChange()
        window?.makeFirstResponder(self)
        layoutChrome()
        needsDisplay = true
    }

    // MARK: - Style

    private var selectedTool: Tool? { item(selectedID)?.tool }

    private var currentStyle: StyleState? {
        if textEditor != nil {
            return StyleState(tool: .text, color: editingColor, size: editingSize,
                              mosaicMode: StyleMemory.mosaicMode, mosaicEffect: StyleMemory.mosaicEffect,
                              mosaicStrength: StyleMemory.mosaicStrength, options: editingStyle)
        }
        if let item = item(selectedID) {
            return StyleState(tool: item.tool, color: item.color, size: item.size,
                              mosaicMode: item.shape.isMosaicBrush ? .brush : .rect, mosaicEffect: item.effect,
                              mosaicStrength: item.mosaicStrength, options: item.style,
                              highlightEllipse: item.shape.highlightEllipse, highlightOpacity: item.opacity,
                              shapeEllipse: item.isEllipseShape,
                              canDelete: true,
                              penMode: item.isHighlighter ? .highlighter : .pencil,
                              highlighterMode: item.highlighterMode ?? StyleMemory.highlighterMode,
                              highlighterBlend: item.highlighterBlend)
        }
        // 识别内容 has a bar of its own even though it is not a tool: two readings, the same way 形状 / 画笔 /
        // 打码 put their sub-modes at the left of the bar. It goes away as soon as a tool is picked.
        if let textReadingMode, tool == nil, mode == .screenshot {
            return StyleState(tool: nil, textReadingMode: textReadingMode,
                              color: StyleMemory.color(for: .text), size: StyleMemory.size(for: .text),
                              mosaicMode: StyleMemory.mosaicMode, mosaicEffect: StyleMemory.mosaicEffect,
                              mosaicStrength: StyleMemory.mosaicStrength, options: StyleMemory.style(for: .text))
        }
        guard let tool else { return nil }
        let highlighter = tool == .pen && StyleMemory.penMode == .highlighter
        return StyleState(tool: tool,
                          color: highlighter ? StyleMemory.highlighterColor : StyleMemory.color(for: tool),
                          size: highlighter ? StyleMemory.highlighterWidth : StyleMemory.size(for: tool),
                          mosaicMode: StyleMemory.mosaicMode, mosaicEffect: StyleMemory.mosaicEffect,
                          mosaicStrength: StyleMemory.mosaicStrength,
                          options: StyleMemory.style(for: tool),
                          highlightEllipse: StyleMemory.highlightEllipse, highlightOpacity: StyleMemory.highlightOpacity,
                          shapeEllipse: StyleMemory.shapeMode == .ellipse,
                          penMode: StyleMemory.penMode,
                          highlighterMode: StyleMemory.highlighterMode,
                          highlighterBlend: StyleMemory.highlighterBlend)
    }

    private func applyStyle(_ action: StyleAction) {
        if case .delete = action { return deleteSelectedItem() }
        // The opacity slider and the wheel send a stream of values; one undo step per drag is enough.
        if case .highlightOpacity = action { return applyStyle(action, coalesce: true) }
        if case .highlighterWidth = action { return applyStyle(action, coalesce: true) }
        applyStyle(action, coalesce: false)
    }

    var testing_items: [AnnotationItem] { items }
    var testing_tool: Tool? { tool }
    /// Website shots: skip the dimming outside the selection so the product can sit on white.
    var testing_hidesDim = false
    /// Website shots: drop the annotation selection but keep the tool and its style bar.
    func testing_deselectItem() { select(nil) }
    /// 工具栏是不是已经摆出来了；文字识别快捷键进去时不应该摆（摆了就是一闪而过的那一下）。
    var testing_toolbarVisible: Bool { !toolbar.isHidden }
    /// 工具条上有没有这个按钮；贴图编辑时的三个「例外」靠它守着。
    func testing_toolbarShows(_ action: ToolbarAction) -> Bool { toolbar.shows(action) }
    /// 横排工具条的宽度；藏起来的按钮不该继续占位置。
    var testing_toolbarWidth: CGFloat { toolbar.horizontalSize.width }
    /// 工具条上的撤销是不是亮的（跨会话的撤销历史靠它验证）。
    var testing_canUndo: Bool { toolbar.undoButton.isEnabled }
    /// 截图翻译 那三个按钮在哪儿；普通截图里它们不该出现，所以是 optional。
    var testing_closeButtonFrame: CGRect? { closeButton.isHidden ? nil : closeButton.frame }
    var testing_translatePinFrame: CGRect? { translatePinButton.isHidden ? nil : translatePinButton.frame }
    var testing_copyButtonFrame: CGRect? { copyButton.isHidden ? nil : copyButton.frame }
    var testing_translatePinPinned: Bool { translatePinButton.testing_isPinned }
    var testing_translatePinAnimating: Bool { translatePinButton.testing_isAnimating }
    var testing_translatePinGlyphScale: CGFloat { translatePinButton.testing_glyphScale }
    /// 这次截图是不是被放弃掉了（Esc / 关闭按钮 / 点选外面）。自检驱动的 view 没有 session，只能看这个。
    private(set) var testing_finished = false
    /// 按下 截图翻译 那三个按钮。
    func testing_pressCloseButton() { closeButton.testing_press() }
    func testing_pressTranslatePin() { translatePinButton.testing_press() }
    func testing_hoverTranslatePin(_ inside: Bool) { translatePinButton.testing_hover(inside) }
    func testing_pressCopyButton() { copyButton.testing_press() }

    /// 这次截图产出了什么（复制 / 保存）。自检驱动的 view 没有 session，靠它看按钮走没走到收尾那一步。
    private(set) var testing_output: OutputAction?

    /// Lets the offscreen UI demo press style-bar buttons.
    func testing_applyStyle(_ action: StyleAction) {
        applyStyle(action)
    }

    private func applyStyle(_ action: StyleAction, coalesce: Bool) {
        if case .customColor = action {
            openColorPanel()
            return
        }
        // 识别内容's two readings: not an annotation, so none of the guards below apply. Switching reading scans again.
        if case let .textReadingMode(mode) = action {
            runTextReading(mode)
            return
        }
        guard let styleTool = textEditor != nil ? .text : selectedTool ?? tool else { return }
        var clampedSize: CGFloat?
        if case let .size(value) = action {
            let range = styleTool.sizeRange
            clampedSize = min(max(value, range.lowerBound), range.upperBound)
        }

        // Remember the choice for the next annotation of this kind.
        switch action {
        case .size: StyleMemory.sizes[styleTool] = clampedSize
        case let .color(c):
            // The highlighter keeps its own ink; picking a marker colour must not recolour the pencil.
            if currentStyle?.penMode == .highlighter { StyleMemory.highlighterColor = c }
            else { StyleMemory.setColor(c, for: styleTool) }
        case let .mosaicMode(m): StyleMemory.mosaicMode = m
        case let .mosaicEffect(e): StyleMemory.mosaicEffect = e
        case let .mosaicStrength(s): StyleMemory.mosaicStrength = s
        case let .shapeMode(m): StyleMemory.shapeMode = m
        case let .penMode(m): StyleMemory.penMode = m
        case let .highlighterMode(m): StyleMemory.highlighterMode = m
        case let .highlighterBlend(b): StyleMemory.highlighterBlend = b
        case let .highlighterWidth(w): StyleMemory.highlighterWidth = min(max(w.rounded(), 1), 50)
        case let .highlightEllipse(e): StyleMemory.highlightEllipse = e
        case let .highlightOpacity(o): StyleMemory.highlightOpacity = o
        case .options: break
        case .textReadingMode: break   // handled above: it runs a reading instead of changing a style
        case .customColor: break
        case .delete: break   // handled before the tool guard: it needs no tool to remember anything for
        }
        // 自动识别 comes and goes with this switch; the frames are read only while it is on.
        if case .mosaicMode = action {
            if StyleMemory.mosaicMode == .auto { startAutoMaskDetection() } else { stopAutoMask() }
        }
        // Choosing the pen's pencil / highlighter or the highlighter's box / line is about the next stroke: a
        // pencil scribble cannot become a highlighter, so let go of the selected item instead of pretending to
        // convert it. (The 形状 tool can convert because a rectangle and a circle share one rect.)
        if case .penMode = action, selectedID != nil { select(nil) }
        if case .highlighterMode = action, selectedID != nil { select(nil) }
        var newOptions: ItemStyle?
        if case let .options(change) = action, var options = currentStyle?.options {
            change(&options)
            newOptions = options
            StyleMemory.setStyle(options, for: styleTool)
        }

        if let editor = textEditor {
            if let clampedSize { editingSize = clampedSize }
            if case let .color(c) = action { editingColor = c }
            if let newOptions { editingStyle = newOptions }
            editor.apply(color: editingColor, size: editingSize)
        } else if let index = selectedIndex {
            let change = {
                var item = self.items[index]
                if let clampedSize { item.size = clampedSize }
                if case let .color(c) = action { item.color = c }
                if case let .mosaicEffect(e) = action { item.effect = e }
                if case let .mosaicStrength(s) = action { item.mosaicStrength = s }
                if case let .shapeMode(mode) = action, let r = item.shape.outlineRect {
                    item.shape = mode == .ellipse ? .ellipse(r) : .rectangle(r)
                }
                if case let .highlighterBlend(blend) = action, item.isHighlighter { item.highlighterBlend = blend }
                if case let .highlighterWidth(w) = action, case .highlighterLine = item.shape {
                    item.size = min(max(w.rounded(), 1), 50)
                }
                if case let .highlightEllipse(ellipse) = action, case let .highlight(r, _) = item.shape {
                    item.shape = .highlight(r, ellipse: ellipse)
                }
                if let newOptions { item.style = newOptions }
                self.replaceItem(item)
            }
            if coalesce { coalescedChange(change) } else { mutate(change) }
            if case .mosaicEffect = action { needsDisplay = true }
            if case .mosaicStrength = action { needsDisplay = true }
        }
        // In 自动识别 a click toggles masks instead of selecting one, so the effect and the strength have to
        // reach every mask in the picture at once — otherwise turning 模糊 into 像素块 means twelve clicks.
        if isAutoMaskMode, case .mosaicEffect = action {
            let change = {
                for index in self.items.indices where self.items[index].tool == .mosaic {
                    self.items[index].effect = StyleMemory.mosaicEffect
                }
            }
            mutate(change)
            needsDisplay = true
        }
        if isAutoMaskMode, case .mosaicStrength = action {
            let change = {
                for index in self.items.indices where self.items[index].tool == .mosaic {
                    self.items[index].mosaicStrength = StyleMemory.mosaicStrength
                }
            }
            if coalesce { coalescedChange(change) } else { mutate(change) }
            needsDisplay = true
        }
        // Every highlight shares the one mask, so moving the opacity slider moves all of them together.
        if case let .highlightOpacity(value) = action {
            let change = {
                for index in self.items.indices where self.items[index].shape.isHighlight {
                    self.items[index].opacity = value
                }
            }
            if coalesce { coalescedChange(change) } else { mutate(change) }
            needsDisplay = true
        }
        layoutChrome()
    }

    private func openColorPanel() {
        let panel = NSColorPanel.shared
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = currentStyle?.color ?? StyleMemory.color(for: tool ?? .rectangle)
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        applyStyle(.color(sender.color), coalesce: true)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = Int(event.keyCode)
        let arrows: [Int: CGPoint] = [123: CGPoint(x: -1, y: 0), 124: CGPoint(x: 1, y: 0), 125: CGPoint(x: 0, y: 1), 126: CGPoint(x: 0, y: -1)]

        if code == 53 {
            handleEscape()
            return
        }

        guard hasSelection else {
            if let d = arrows[code] {
                let step: CGFloat = flags.contains(.shift) ? 10 : 1
                warpCursor(by: CGPoint(x: d.x * step, y: d.y * step))
            } else if code == 36 || code == 76 {
                selection = hoverRect?.intersection(bounds) ?? bounds
                commitSelection()
            } else if flags.isEmpty, key == "r" {
                restoreLastSelection()
            } else if flags.isEmpty, key == "c" {
                copyPixelColor()
            }
            return
        }

        if code == 36 || code == 76 {
            finish(.apply)
            return
        }
        if code == 51 || code == 117 {
            deleteSelectedItem()
            return
        }
        if let d = arrows[code] {
            handleArrow(d, flags: flags)
            return
        }
        if flags == .command {
            switch key {
            case "z": undo(nil)
            case "c": finish(.copy)
            case "s": finish(.save)
            case "t": handle(.pin)
            default: super.keyDown(with: event)
            }
            return
        }
        if flags == [.command, .shift] {
            switch key {
            case "z": redo(nil)
            case "s": finish(.saveAs)
            default: super.keyDown(with: event)
            }
            return
        }
        guard flags.isEmpty else { return }
        // While a reading panel is open, C copies what it shows; this wins over any toolbar key bound to C.
        // 识别文字 also closes its panel, as it always has. 扫码's panel stays — 钉住 is the way it ends.
        if key == "c", !ocrPanel.isHidden || !scanPanel.isHidden {
            if !ocrPanel.isHidden {
                ocrPanel.copyText()
                closeTextReading()
                showToast("已复制文字", duration: 1.5)
            } else {
                scanPanel.copyAll()
                showToast("已复制扫码结果", duration: 1.5)
            }
            return
        }
        if let action = ToolbarAction.action(forKey: key) {
            handle(action)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        handleEscape()
    }

    /// Esc steps back one level at a time; it only closes the capture when there is nothing left to back out of.
    private func handleEscape() {
        if engineMenuOpen {
            closeEngineMenu()
        } else if textEditor != nil {
            commitText()
        } else if !translationPanel.isHidden {
            closeTranslationPanel()
        } else if !ocrPanel.isHidden || !scanPanel.isHidden || textReadingMode != nil {
            closeTextReading()
        } else if selectedID != nil {
            select(nil)
        } else if tool != nil {
            setTool(nil)
        } else {
            cancelCapture()
        }
    }

    /// Ends the capture without producing anything — Esc, the close button and a click outside all come here.
    ///
    /// `session` is nil when the self-checks drive the view on its own, so the flag is what they observe.
    private func cancelCapture() {
        testing_finished = true
        session?.cancel()
    }

    /// A click outside the selection that may end 截图翻译, once the mouse comes back up. Held rather than acted on
    /// at mouse down, because a drag starts with the same mouse down and must still re-frame the selection.
    private var pendingDismiss = false

    /// A press outside the selection: a click ends the capture, while a drag still re-frames it. Like
    /// `pendingDismiss`, the mouse-down cannot tell the two apart yet, so the decision waits for the mouse-up.
    private var pendingOutsideCancel = false

    /// Whether a click outside the selection ends 截图翻译, per the setting: never, on one click, or on the
    /// second of two. `clickCount` is AppKit's own, so the double-click case needs no timer of ours — the first
    /// click of a double click simply does nothing.
    private func dismissesOnClick(_ clickCount: Int) -> Bool {
        switch Settings.shared.dismissTranslationCapture {
        case .none: return false
        case .singleClick: return clickCount >= 1
        case .doubleClick: return clickCount >= 2
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        if shift, !shiftDown, !magnifier.isHidden, case .none = drag {
            StyleMemory.hexColor.toggle()
            magnifier.showHex = StyleMemory.hexColor
        }
        shiftDown = shift
        // 自动识别: the modifier picks the rule, so both the guide and the green frames follow the key while
        // it is held — and let go when it is released.
        setAutoHoverFlags(event.modifierFlags)
    }

    /// Arrow keys: nudge the selected annotation, or move / expand (⌘) / shrink (⇧) the selection by 1pt.
    private func handleArrow(_ d: CGPoint, flags: NSEvent.ModifierFlags) {
        if let index = selectedIndex {
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            coalescedChange { replaceItem(items[index].moved(by: CGPoint(x: d.x * step, y: d.y * step))) }
            return
        }
        let old = selection
        if flags.isEmpty {
            var r = selection.offsetBy(dx: d.x, dy: d.y)
            r.origin.x = min(max(r.minX, 0), bounds.width - r.width)
            r.origin.y = min(max(r.minY, 0), bounds.height - r.height)
            selection = r
        } else if flags == .command || flags == .shift {
            // ⌘ pushes the edge in the arrow's direction outward; ⇧ pulls that same edge inward.
            let outward: CGFloat = flags == .command ? 1 : -1
            var minX = selection.minX, maxX = selection.maxX, minY = selection.minY, maxY = selection.maxY
            if d.x < 0 { minX -= outward }
            if d.x > 0 { maxX += outward }
            if d.y < 0 { minY -= outward }
            if d.y > 0 { maxY += outward }
            let r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
            guard r.width >= 4, r.height >= 4 else { return }
            selection = r
        } else {
            return
        }
        invalidate(old, selection)
        layoutChrome()
        autoMaskSelectionChanged()
    }

    private func warpCursor(by d: CGPoint) {
        guard let window, let primary = NSScreen.screens.first else { return }
        let current = clampToBounds(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        let target = clampToBounds(CGPoint(x: current.x + d.x, y: current.y + d.y))
        let onScreen = window.convertPoint(toScreen: convert(target, to: nil))
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.x, y: primary.frame.maxY - onScreen.y))
        CGAssociateMouseAndMouseCursorPosition(1)
        handleMouseMoved(at: target)
    }

    private func restoreLastSelection() {
        guard let last = StyleMemory.lastSelection[displayID]?.intersection(bounds), last.width >= 4, last.height >= 4 else {
            showToast("还没有上一次的选区")
            return
        }
        selection = last
        commitSelection()
    }

    private func copyPixelColor() {
        let value = magnifier.colorString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showToast("已复制颜色 \(value)", duration: 1.5)
    }

    // MARK: - Chrome

    private func layoutChrome() {
        // The 形状 tool's icon follows whether it is drawing rectangles or circles; the 画笔 tool's follows
        // whether it is a pencil or a highlighter.
        toolbar.setShapeMode(StyleMemory.shapeMode)
        toolbar.setPenMode(StyleMemory.penMode)
        toolbar.setMosaicEffect(StyleMemory.mosaicEffect)
        toolbar.setTextReadingMode(StyleMemory.textReadingMode)
        toolbar.setActiveAction(.ocr, textReadingMode != nil)
        // Configured first so its height is known before anything above the selection is placed.
        let hasBar = showsTranslationBar
        translationBar.isHidden = !hasBar
        var barHeight: CGFloat = 0
        if hasBar {
            translationBar.configure(TranslationBarView.Content(
                source: translationSourceName, target: translationTarget,
                showingOriginal: !isTranslationShown, showsFullText: !truncatedBlocks.isEmpty,
                engines: translationEngines.names, engineIndex: translationEngines.index,
                translating: isTranslating))
            barHeight = translationBar.frame.height
        }
        // Whether the bar will fit above the selection decides how much room the size chip has up there. The
        // two have to agree, or the chip is pushed off the top and lands inside the picture.
        let barAbove = hasBar && selection.minY - barHeight - 6 >= 4

        // The size chip is for measuring a region before you commit to it. 截图翻译 and 文字识别 are not that
        // — one translates what is inside, the other just reads it out — so the readout is nothing but
        // something else in the corner of the eye, and it stays off in both.
        //
        // Its own position is worked out here rather than read back off the view, because the toolbar below
        // needs to know the top of the free space above the selection, and a hidden chip keeps whatever
        // frame it had last time.
        let sizeRect: CGRect? = hasSelection || isSelecting ? (selection.width > 0 ? selection : nil) : hoverRect
        var chipTop: CGFloat?
        if let sizeRect, !autoTranslate, !autoOCR, mode != .pinEdit {
            topBar.setSize(sizeRect.size)
            // The chip stacks above the translation bar when there is one. When there is no room for it up
            // there it steps aside instead of dropping into the selection: the chip is the least useful of
            // the two, and chrome over the picture is what this whole layout is arranged to avoid. (It used
            // to fall back to the selection's top-left corner, which covers the first line of a translation.)
            let reserved = barAbove ? barHeight + 4 : 0
            let top = sizeRect.minY - topBar.frame.height - 6 - reserved
            if top >= 4 { chipTop = top }
        }
        topBar.isHidden = chipTop == nil
        if let chipTop, let sizeRect {
            topBar.setFrameOrigin(CGPoint(x: min(max(4, sizeRect.minX), bounds.maxX - topBar.frame.width - 4), y: chipTop))
        }

        // 截图翻译 needs no toolbar: the flow is pick a region and read the result, and a bar of tools parked
        // over the selection is in the way of exactly that. Its keys still work — ↩ saves, ⌘C copies, Esc
        // backs out — and a plain screenshot still gets the tools.
        toolbar.isHidden = !hasSelection || isAdjustingSelection || autoTranslate
        if !hasSelection {
            ocrPanel.isHidden = true
            scanPanel.isHidden = true
        }
        let style = currentStyle
        styleBar.isHidden = toolbar.isHidden || style == nil
        guard hasSelection else {
            autoGuide.isHidden = true
            positionToast()
            return
        }

        // 截图翻译 的三个按钮：关闭在上、钉住在中间、复制在下，竖排在选区右边外面（和贴图那一列一个摆法），
        // 与选区顶部对齐（上方留给翻译悬浮条）。贴着屏幕右边缘没地方放时退回选区内部右上角——它们是这条
        // 路上唯一的可点入口，不能像贴图那两个按钮那样干脆藏起来。矮到竖排不下时整列往上让，但不许出画面。
        closeButton.isHidden = !autoTranslate || isAdjustingSelection || mode == .pinEdit
        translatePinButton.isHidden = closeButton.isHidden
        copyButton.isHidden = closeButton.isHidden
        if !closeButton.isHidden {
            let side = GlyphButton.diameter
            let gap: CGFloat = 4
            let stack = side * 3 + gap * 2
            // 8pt 而不是贴图那 4pt：选区的角上是 7pt 的缩放手柄，让开一点才不跟它叠在一起。
            let outside = selection.maxX + 8 + side <= bounds.maxX - 4
            let x = outside ? selection.maxX + 8 : selection.maxX - side - 8
            let top = min(selection.minY, max(bounds.maxY - 4 - stack, 4))
            closeButton.frame = CGRect(x: x, y: top, width: side, height: side)
            translatePinButton.frame = CGRect(x: x, y: top + side + gap, width: side, height: side)
            copyButton.frame = CGRect(x: x, y: top + (side + gap) * 2, width: side, height: side)
        }

        // Under the selection; without room there, a column beside it (right, then left); failing both,
        // a row above it, then a column inside its right edge, then a row inside its bottom edge.
        //
        // A bar wider than the whole stage goes to the column route as well: a pin's pencil lives on a stage
        // that stops at the picture's right edge (the pin's buttons are there), so a pin near the left edge of
        // the screen can leave less width than the flat toolbar needs.
        let flat = toolbar.horizontalSize, column = toolbar.verticalSize
        var bar = CGPoint(x: selection.maxX - flat.width, y: selection.maxY + 8)
        var below = true
        var side: PanelView.CaretEdge? = nil
        var inside = false
        if bar.y + flat.height > bounds.maxY - 4 || flat.width > bounds.width - 8 {
            let aboveTop = chipTop.map { min($0, selection.minY) } ?? selection.minY
            if column.height <= bounds.height - 8 {
                if selection.maxX + 8 + column.width <= bounds.maxX - 4 {
                    side = .right
                } else if selection.minX - 8 - column.width >= 4 {
                    side = .left
                } else if aboveTop - flat.height - 8 < 4, selection.width > column.width * 3 {
                    side = .right
                    inside = true
                }
            }
            if let side {
                bar.x = inside ? selection.maxX - 8 - column.width
                    : side == .right ? selection.maxX + 8 : selection.minX - 8 - column.width
                // Bottom-aligned with the selection, like the horizontal bar hangs off its bottom-right corner.
                bar.y = min(max(4, selection.maxY - column.height), bounds.maxY - column.height - 4)
            } else {
                bar.y = aboveTop - flat.height - 8
                below = false
                if bar.y < 4 {
                    bar.y = selection.maxY - flat.height - 8
                    below = true
                }
            }
        }
        if toolbar.isVertical != (side != nil) { toolbar.setVertical(side != nil) }
        let size = toolbar.frame.size
        if side == nil { bar.x = min(max(4, bar.x), bounds.maxX - size.width - 4) }
        toolbar.setFrameOrigin(bar)

        if let style, !styleBar.isHidden {
            // 识别内容's row has no tool button: its caret points at the X it came from.
            let icon = style.tool.flatMap { toolbar.anchor(for: $0) }
                ?? toolbar.anchor(for: .ocr) ?? CGPoint(x: size.width / 2, y: size.height / 2)
            if let side {
                // Beside the column, on the selection side, with the caret pointing at the tool.
                styleBar.caret = (side == .right ? .right : .left, 0)
                styleBar.configure(style)
                let styleSize = styleBar.frame.size
                let x = side == .right ? bar.x - styleSize.width - 4 : bar.x + size.width + 4
                let anchor = bar.y + icon.y
                let y = min(max(4, anchor - styleSize.height / 2), bounds.maxY - styleSize.height - 4)
                styleBar.setFrameOrigin(CGPoint(x: min(max(4, x), bounds.maxX - styleSize.width - 4), y: y))
                styleBar.caret = (side == .right ? .right : .left, anchor - y)
            } else {
                // Put the style bar next to the toolbar with a caret pointing at the tool it configures.
                var styleBelow = below
                let expectedHeight: CGFloat = 42
                if styleBelow, bar.y + size.height + 4 + expectedHeight > bounds.maxY - 4 { styleBelow = false }
                if !styleBelow, bar.y - 4 - expectedHeight < 4 { styleBelow = true }
                styleBar.caret = (styleBelow ? .top : .bottom, 0)
                styleBar.configure(style)
                let anchor = bar.x + icon.x
                let styleSize = styleBar.frame.size
                let x = min(max(4, anchor - 26), bounds.maxX - styleSize.width - 4)
                let y = styleBelow ? bar.y + size.height + 4 : bar.y - styleSize.height - 4
                styleBar.setFrameOrigin(CGPoint(x: x, y: y))
                styleBar.caret = (styleBelow ? .top : .bottom, anchor - x)
            }
        }

        // Panels that live beside the selection all get the same treatment: to its right, clear of a toolbar
        // column that ended up there, flipping to the left when there is no room, clamped to the screen. A
        // hidden toolbar is no obstacle, whatever its frame still says.
        let toolbarVisible = !toolbar.isHidden
        let right = toolbarVisible && side == .right && !inside ? toolbar.frame.maxX : selection.maxX
        let left = toolbarVisible && side == .left ? toolbar.frame.minX : selection.minX
        func placeBesideSelection(_ view: NSView) {
            let panelSize = view.frame.size
            var origin = CGPoint(x: right + 10, y: selection.minY)
            if origin.x + panelSize.width > bounds.maxX - 4 { origin.x = left - panelSize.width - 10 }
            if origin.x < 4 { origin.x = bounds.maxX - panelSize.width - 4 }
            origin.y = min(max(4, origin.y), bounds.maxY - panelSize.height - 4)
            view.setFrameOrigin(origin)
        }
        placeBesideSelection(ocrPanel)
        placeBesideSelection(scanPanel)
        if !translationPanel.isHidden { placeBesideSelection(translationPanel) }

        // The translation bar goes last: its fallback needs to know where the toolbar ended up.
        if !translationBar.isHidden {
            let bar = translationBar.frame.size
            let x = min(max(4, selection.midX - bar.width / 2), bounds.maxX - bar.width - 4)
            var y = selection.minY - bar.height - 6
            if y < 4 {
                // No room above the selection: go under it, and under the toolbar if that is where it went.
                let toolbarIsBelow = !toolbar.isHidden && toolbar.frame.minY >= selection.maxY
                y = (toolbarIsBelow ? toolbar.frame.maxY : selection.maxY) + 6
                y = min(y, bounds.maxY - bar.height - 4)
            }
            translationBar.setFrameOrigin(CGPoint(x: x, y: y))
        }
        layoutEngineMenu()
        layoutLanguageMenu()
        layoutAutoGuide()

        positionToast()
    }

    /// The 大模型 list hangs under the engine chip the way a menu does — the chip is where the click was, so the
    /// list belongs there — and flips above the bar when the bottom of the screen is close. It can end up over
    /// the selection: a menu lies on whatever it drops on, and this one is about to replace exactly that. The
    /// alternative (hanging it beside the selection, as the 全文 panel does) puts it a screen away from the
    /// chip that opened it, which is worse for something you are picking from mid-gesture.
    private func layoutEngineMenu() {
        let hasBar = !translationBar.isHidden
        engineMenu.isHidden = !engineMenuOpen || !hasBar || isAdjustingSelection
        guard !engineMenu.isHidden else { return }
        layoutMenu(engineMenu, under: translationBar.convert(translationBar.engineChipFrame, to: self))
    }

    /// The same, hanging off one side of the direction control.
    private func layoutLanguageMenu() {
        let hasBar = !translationBar.isHidden
        languageMenu.isHidden = languageMenuKind == nil || !hasBar || isAdjustingSelection
        guard !languageMenu.isHidden, let kind = languageMenuKind else { return }
        let chip = kind == .source ? translationBar.sourceChipFrame : translationBar.targetChipFrame
        layoutMenu(languageMenu, under: translationBar.convert(chip, to: self))
    }

    /// A list hangs under the control that opened it — that is where the click was — and flips above the bar
    /// when the bottom of the screen is close. It can end up over the selection: a menu lies on whatever it
    /// drops on, and this one is about to replace exactly that.
    private func layoutMenu(_ menu: NSView, under anchor: CGRect) {
        let bar = translationBar.frame
        let size = menu.frame.size
        var y = bar.maxY + 4
        if y + size.height > bounds.maxY - 4 { y = bar.minY - size.height - 4 }
        menu.setFrameOrigin(CGPoint(x: min(max(4, anchor.minX), bounds.maxX - size.width - 4),
                                    y: min(max(4, y), bounds.maxY - size.height - 4)))
    }

    /// Opens one side's language list, or closes it when that side is the one already open.
    private func toggleLanguageMenu(_ kind: LanguageMenuKind) {
        guard showsTranslationBar else { return }
        closeEngineMenu()
        guard languageMenuKind != kind else { return closeLanguageMenu() }
        languageMenuKind = kind
        switch kind {
        case .source:
            let titles = [TranslationConfig.autoSource] + Self.sourceLanguages.map(\.name)
            // Tick what the bar is actually translating from — the guess when there is no override. Opening the
            // list should answer "what does it think this is?" before it asks "what should it be?".
            let current = Self.sourceLanguages.firstIndex(of: effectiveSource).map { $0 + 1 } ?? 0
            languageMenu.configure(titles: titles, current: current)
        case .target:
            let titles = [TextTranslationWindow.autoTarget] + Self.targetLanguages
            let current = Self.targetLanguages.firstIndex(of: translationTarget).map { $0 + 1 } ?? 0
            languageMenu.configure(titles: titles, current: current)
        }
        layoutChrome()
    }

    private func closeLanguageMenu() {
        guard languageMenuKind != nil else { return }
        languageMenuKind = nil
        languageMenu.isHidden = true
    }

    /// Picking a language is about this capture, not a preference (unlike the engine): it pins one side, and the
    /// screen is translated again because what is underneath came from the other direction.
    private func useTranslationLanguage(at index: Int) {
        guard let kind = languageMenuKind else { return }
        closeLanguageMenu()
        switch kind {
        case .source:
            guard index <= Self.sourceLanguages.count else { return }
            sourceOverride = index == 0 ? nil : Self.sourceLanguages[index - 1]
        case .target:
            guard index <= Self.targetLanguages.count else { return }
            targetOverride = index == 0 ? nil : Self.targetLanguages[index - 1]
        }
        restartTranslation()
    }

    /// Opens the 大模型 list, or closes it when it is already open — the same button does both.
    private func toggleEngineMenu() {
        guard showsTranslationBar else { return }
        closeLanguageMenu()
        guard !engineMenuOpen else { return closeEngineMenu() }
        let choice = translationEngines
        engineMenu.configure(titles: choice.names, current: choice.index)
        engineMenuOpen = true
        layoutChrome()
    }

    private func closeEngineMenu() {
        guard engineMenuOpen else { return }
        engineMenuOpen = false
        engineMenu.isHidden = true
    }

    /// Outside the selection, never inside it: the whole point of these messages is that the user is
    /// reading the picture underneath, and a toast across the translation defeats it. Above the selection
    /// by preference — clear of the translation bar and the size chip, which live there too — and below it,
    /// clear of the toolbar, when the selection is against the top of the screen.
    private func positionToast() {
        let anchor = hasSelection ? selection : CGRect(x: bounds.midX, y: 40, width: 0, height: 0)
        var y = anchor.minY - toast.frame.height - 6
        if !translationBar.isHidden { y = min(y, translationBar.frame.minY - toast.frame.height - 6) }
        if !engineMenu.isHidden { y = min(y, engineMenu.frame.minY - toast.frame.height - 6) }
        if y < 4 {
            var below = anchor.maxY
            if !translationBar.isHidden { below = max(below, translationBar.frame.maxY) }
            if !engineMenu.isHidden { below = max(below, engineMenu.frame.maxY) }
            if !toolbar.isHidden { below = max(below, toolbar.frame.maxY) }
            y = min(below + 6, bounds.maxY - toast.frame.height - 4)
        }
        toast.setFrameOrigin(CGPoint(x: min(max(4, anchor.midX - toast.frame.width / 2), bounds.maxX - toast.frame.width - 4),
                                     y: max(4, y)))
    }

    /// The size typed into the size chip.
    ///
    /// The region keeps its top-left corner — the corner the chip sits on, so it stays put under the pointer
    /// while the rest grows or shrinks — and slides only when the new size would otherwise run off the screen.
    /// A size bigger than the display is cut down to what fits, and the chip is told the truth afterwards, so
    /// the number that stays on screen is the number you actually get.
    private func resizeSelection(to size: CGSize) {
        guard hasSelection, mode == .screenshot else { return }
        let wanted = CGSize(width: min(max(TopBarView.minimumSide, size.width.rounded()), bounds.width),
                            height: min(max(TopBarView.minimumSide, size.height.rounded()), bounds.height))
        let origin = CGPoint(x: min(max(bounds.minX, selection.minX), bounds.maxX - wanted.width),
                             y: min(max(bounds.minY, selection.minY), bounds.maxY - wanted.height))
        let old = selection
        selection = CGRect(origin: origin, size: wanted)
        invalidate(old, selection)
        layoutChrome()
        autoMaskSelectionChanged()
    }

    private func showToast(_ text: String, duration: TimeInterval? = 2.5) {
        toast.show(text, duration: duration, maxWidth: hasSelection ? max(220, selection.width) : 400)
        positionToast()
    }

    /// Progress and success chatter about a translation. 截图翻译 keeps quiet through both: the shimmer over
    /// the selection is the progress, the result is drawn on the screen, and a line of text on top of that
    /// is one more thing between the user and the picture. What it still says out loud is anything the user
    /// has to act on — nothing found to translate, a failure, a missing API key. Those stay.
    private func showTranslationProgress(_ text: String, duration: TimeInterval? = 2) {
        guard !autoTranslate else { return }
        showToast(text, duration: duration)
    }

    private func handle(_ action: ToolbarAction) {
        // The pin's editor leaves these three off the bar; their single keys must not run them either (T would
        // otherwise "apply", X would open an OCR panel the pin does not need, S would start a long capture).
        guard mode != .pinEdit || !ToolbarAction.unavailableInPinEdit.contains(action) else { return }
        commitText()
        switch action {
        case let .tool(t):
            setTool(tool == t ? nil : t)
        case .undo:
            undo(nil)
        case .ocr:
            runTextReading()
        case .translate:
            runTranslation()
        case .pin:
            if mode == .pinEdit { finish(.apply) } else { pinSelection() }
        case .longCapture:
            if mode == .screenshot { startLongCapture() } else { showToast("这里不能长截图") }
        case .cancel:
            session?.cancel()
        case .save:
            finish(NSEvent.modifierFlags.contains(.shift) ? .saveAs : .save)
        case .done:
            finish(.apply)
        }
    }

    // MARK: - OCR and translation

    private func cropSelection() -> CGImage? {
        let r = CGRect(x: selection.minX * scale, y: selection.minY * scale,
                       width: selection.width * scale, height: selection.height * scale).integral
        return snapshot.cropping(to: r)
    }

    /// Runs Vision once per selection rect; OCR and translation share the result.
    private func recognize() async throws -> RecognitionResult {
        if let recognition, recognition.rect == selection { return recognition.result }
        guard let crop = cropSelection() else { throw CocoaError(.featureUnsupported) }
        let rect = selection
        let result = try await TextRecognizer.recognize(crop, selection: rect)
        recognition = (rect, result)
        return result
    }

    /// 自动识别's own pass: the line recognizer in overlapping strips (`TextRecognizer.recognizeForAutoMask`).
    /// It cannot share `recognition` with OCR and translation — that one keeps paragraphs for translation, and
    /// on a tall table it drops whole rows. Cached per selection so leaving the mode and coming back is free.
    private func recognizeForAutoMask() async throws -> RecognitionResult {
        if let autoRecognition, autoRecognition.rect == selection { return autoRecognition.result }
        guard let crop = cropSelection() else { throw CocoaError(.featureUnsupported) }
        let rect = selection
        let result = try await TextRecognizer.recognizeForAutoMask(crop, selection: rect)
        autoRecognition = (rect, result)
        return result
    }

    /// Takes both reading panels down and stops the 识别内容 row. The selection stays.
    private func hideReadingPanels() {
        textReadingMode = nil
        pendingReading = nil
        ocrPanel.isHidden = true
        scanPanel.isHidden = true
        if ocrBoxesVisible {
            ocrBoxesVisible = false
            invalidate(selection)
        }
    }

    /// The panel's own ×, Esc and C all end the same way: the result goes away, the selection stays, and the
    /// style bar stops pointing at 识别内容.
    private func closeTextReading() {
        hideReadingPanels()
        window?.makeFirstResponder(self)
        layoutChrome()
    }

    /// The X button and the two readings in its style bar. X runs whichever reading was used last; the bar's
    /// buttons switch reading and run it at once.
    private func runTextReading(_ mode: TextReadingMode? = nil) {
        let mode = mode ?? textReadingMode ?? StyleMemory.textReadingMode
        textReadingMode = mode
        StyleMemory.textReadingMode = mode
        // A reading is not a drawing tool: pressing X while the arrow is selected must not leave the arrow
        // armed behind the result panel.
        if tool != nil {
            setTool(nil)
        } else {
            layoutChrome()
        }
        // A translation in flight is a different kind of task: it owns `recognitionTask`, has its own progress
        // state, and would never hand over to a reading. Drop it the way 重新翻译 does, and invalidate its
        // generation so its completion cannot clear the reading's task.
        if case .loading = translationState {
            recognitionTask?.cancel()
            recognitionTask = nil
            translationGeneration += 1
            stopShimmer()
            translationState = .none
            toolbar.translateButton.isActive = false
            layoutChrome()
        }
        // Reading and scanning share one task; a click that arrives mid-flight is handed over, not dropped.
        guard recognitionTask == nil else {
            pendingReading = mode
            return
        }
        startReading(mode)
    }

    private func startReading(_ mode: TextReadingMode) {
        switch mode {
        case .text: runOCR()
        case .scan: runScan()
        }
    }

    /// Ends whichever reading was running. The next one starts only after this task is out of the way, so the
    /// two never share `recognitionTask`.
    private func finishReading() {
        recognitionTask = nil
        guard let pending = pendingReading else { return }
        pendingReading = nil
        startReading(pending)
    }

    /// Recognizes the selection's text and shows it in an editable panel beside the selection; its button copies it.
    private func runOCR() {
        guard recognitionTask == nil else { return }
        showToast("正在识别文字…", duration: nil)
        // The engine can take half a minute to come back after a long idle (see `TextRecognizer.keepWarm`);
        // say so instead of leaving 「正在识别文字」 sitting there looking hung.
        let slowHint = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, recognitionTask != nil else { return }
            showToast("正在准备文字识别引擎，这次会慢一些…", duration: nil)
        }
        recognitionTask = Task { @MainActor in
            defer {
                slowHint.cancel()
                finishReading()
            }
            do {
                let result = try await recognize()
                let text = result.plainText
                // Closed (or switched to 扫码) while the request was out: this answer is no longer wanted.
                guard textReadingMode == .text else { return }
                guard !text.isEmpty else {
                    showToast("没有识别到文字")
                    return
                }
                scanPanel.isHidden = true
                ocrPanel.show(text: text, lineCount: result.lines.count)
                ocrPanel.isHidden = false
                ocrBoxesVisible = true
                invalidate(selection)
                layoutChrome()
                // 高精度 ran out mid-month and 标准 answered instead: say so once, where the result is.
                if let notice = result.notice {
                    showToast(notice, duration: 4)
                } else {
                    toast.hide()
                }
            } catch {
                showToast("文字识别失败：\(error.localizedDescription)")
            }
        }
    }

    /// 扫码: reads the selection for QR codes and barcodes and puts what it finds in the panel beside it.
    private func runScan() {
        guard recognitionTask == nil else { return }
        showToast("正在扫码…", duration: nil)
        recognitionTask = Task { @MainActor in
            defer { finishReading() }
            guard let crop = cropSelection() else {
                showToast("扫码失败：选区无效")
                return
            }
            let codes = await CodeScanner.scan([crop])
            // Closed or switched on the way: the panel would be for a reading the user has moved on from.
            guard textReadingMode == .scan else { return }
            guard !codes.isEmpty else {
                showToast("没有找到二维码或条形码")
                return
            }
            ocrPanel.isHidden = true
            if ocrBoxesVisible {
                ocrBoxesVisible = false
                invalidate(selection)
            }
            scanPanel.show(codes: codes)
            scanPanel.isHidden = false
            layoutChrome()
            toast.hide()
            // 自动复制 (设置 → 文字识别, on by default) writes the result as soon as it is read; the panel stays
            // up so the codes can still be pinned or opened.
            if Settings.shared.scanAutoCopy { scanPanel.copyAll() }
        }
    }

    /// The panel's 钉住: closes the capture and leaves the same result panel floating on the desktop. The window
    /// takes the panel's exact place, so 钉住 changes nothing on screen except that the screenshot goes away.
    private func pinScanResult() {
        let codes = scanPanel.codes
        guard !codes.isEmpty else { return }
        // The self-checks drive this same button; a real window here would land on the user's screen.
        if SelfCheck.isRunning {
            testing_pinnedScanCodes = codes
            testing_finished = true
            return
        }
        let frame = window.map { $0.convertToScreen(scanPanel.convert(scanPanel.bounds, to: nil as NSView?)) }
            ?? CGRect(origin: .zero, size: scanPanel.frame.size)
        session?.finish()
        ScanResultPins.show(codes: codes, frame: frame)
    }

    /// A row's 访问. The capture overlay sits above every other window, so a browser opened behind it could not
    /// be used: a visit ends the capture first, then hands the link over.
    private func openScanURL(_ url: URL) {
        if SelfCheck.isRunning {
            testing_openedScanURL = url
            return
        }
        if mode == .screenshot { session?.finish() }
        NSWorkspace.shared.open(url)
    }

    var testing_ocrText: String? { ocrPanel.isHidden ? nil : ocrPanel.textView.string }
    /// 扫码's payloads while its panel is up, and where the panel landed (the self-check uses the frame to prove
    /// it steps to the left of the selection when there is no room on the right).
    var testing_scanCodes: [String]? { scanPanel.isHidden ? nil : scanPanel.codes }
    var testing_scanPanelFrame: CGRect? { scanPanel.isHidden ? nil : scanPanel.frame }
    var testing_scanPanel: ScanPanelView { scanPanel }
    var testing_textReadingMode: TextReadingMode? { textReadingMode }
    private(set) var testing_pinnedScanCodes: [String]?
    private(set) var testing_openedScanURL: URL?

    // MARK: - 自动识别

    /// 打码 → 自动识别: the mode is on, a tool is chosen and there is a region to read.
    private var isAutoMaskMode: Bool {
        hasSelection && tool == .mosaic && StyleMemory.mosaicMode == .auto && textEditor == nil
    }

    /// Reads the selection and builds the targets. One pass per selection; entering the mode again (or
    /// switching back from 框选) reuses the cached result through `recognize()`.
    ///
    /// A third-party engine is billed per picture and rate-limited, so the Baidu path asks less often: a
    /// selection that moved by a few points keeps the boxes it already has (they are inflated by 3 pt anyway),
    /// and two requests are never closer than a second apart.
    private func startAutoMaskDetection() {
        guard isAutoMaskMode else {
            stopAutoMask()
            return
        }
        let baidu = Settings.shared.ocrEngine == .baidu
        if let rect = autoTargetsRect, !autoTargets.isEmpty, rect == selection || (baidu && nearlySame(rect, selection)) {
            return
        }
        if baidu, let last = lastAutoMaskRequest {
            let wait = 1 - Date().timeIntervalSince(last)
            if wait > 0 {
                autoMaskPendingWork?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.startAutoMaskDetection() }
                autoMaskPendingWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
                return
            }
        }
        if baidu { lastAutoMaskRequest = Date() }
        autoMaskPendingWork?.cancel()
        autoMaskPendingWork = nil
        autoMaskGeneration += 1
        let generation = autoMaskGeneration
        autoMaskTask?.cancel()
        let rect = selection
        autoTargets = []
        autoTargetsRect = nil
        setHoveredAuto(nil)
        needsDisplay = true
        showToast("正在识别可打码的内容…", duration: nil)
        autoMaskTask = Task { @MainActor in
            defer { if generation == autoMaskGeneration { autoMaskTask = nil } }
            do {
                let result = try await recognizeForAutoMask()
                guard generation == autoMaskGeneration, selection == rect else { return }
                let found = AutoMaskDetector.targets(from: result.lines, blocks: result.translatedBlocks, in: rect)
                autoTargets = found
                autoTargetsRect = rect
                if found.isEmpty {
                    showToast("没有找到可以自动打码的内容，可以直接拖动框选", duration: 2.5)
                } else {
                    toast.hide()
                }
            } catch {
                guard generation == autoMaskGeneration else { return }
                showToast("识别失败：\(error.localizedDescription)")
            }
            needsDisplay = true
            layoutChrome()
        }
    }

    private func stopAutoMask() {
        autoMaskPendingWork?.cancel()
        autoMaskPendingWork = nil
        autoMaskGeneration += 1
        let wasReading = autoMaskTask != nil
        autoMaskTask?.cancel()
        autoMaskTask = nil
        autoTargets = []
        autoTargetsRect = nil
        pendingAutoClick = nil
        hoveredAuto = nil
        autoGuide.isHidden = true
        autoGuide.setActiveRule(0)
        if wasReading { toast.hide() }
        needsDisplay = true
    }

    /// The selection moved or was resized: the old boxes no longer frame the same words. A billed engine waits
    /// longer, so one drag settles into one request instead of one per pause.
    private func autoMaskSelectionChanged() {
        guard isAutoMaskMode else { return }
        autoMaskPendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startAutoMaskDetection() }
        autoMaskPendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (Settings.shared.ocrEngine == .baidu ? 0.6 : 0.2), execute: work)
    }

    /// Whether two selections are close enough that the boxes found for one still fit the other.
    private func nearlySame(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 6) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Whether a target already has a mask. Masks are made from the target's own rect, so the rect is the link —
    /// no state to keep in sync with undo, and a mask removed by ⌘Z simply becomes a target again. Matched with
    /// a little tolerance: reading the screen again after the selection was resized can move a box by a pixel,
    /// and an exact comparison would then miss a word that is already covered.
    private func isAutoMasked(_ target: AutoMaskTarget) -> Bool {
        items.contains { $0.shape.mosaicRect.map { Self.sameRect($0, target.rect) } ?? false }
    }

    private static func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1.5 && abs(a.minY - b.minY) < 1.5
            && abs(a.width - b.width) < 1.5 && abs(a.height - b.height) < 1.5
    }

    /// What is under `p`. Several targets can overlap — a word inside a phrase inside a line — so:
    /// an already masked one wins (a click must always be able to undo); then a typed value (an email inside a
    /// repeated sentence is what the user is after); then the largest repeated unit (hovering 「Approved」 in
    /// 「Approved by admin」 should offer the phrase, not the word); then the smallest.
    private func autoHit(at p: CGPoint) -> AutoHit? {
        guard isAutoMaskMode, selection.contains(p) else { return nil }
        let candidates = autoTargets.filter { $0.rect.contains(p) }
        func area(_ target: AutoMaskTarget) -> CGFloat { target.rect.width * target.rect.height }
        let masked = candidates.filter(isAutoMasked).min { area($0) < area($1) }
        let typed = candidates.filter { $0.category != nil }.min { area($0) < area($1) }
        let repeated = candidates.filter { $0.groupCount > 1 }.max { area($0) < area($1) }
        let target = masked ?? typed ?? repeated ?? candidates.min { area($0) < area($1) }
        if let target {
            let item = items.reversed().first { item in
                item.shape.mosaicRect.map { Self.sameRect($0, target.rect) } ?? false
            }
            return AutoHit(target: target, itemID: item?.id, rect: target.rect)
        }
        if let item = items.reversed().first(where: { $0.tool == .mosaic && $0.contains(p) }) {
            return AutoHit(target: nil, itemID: item.id, rect: item.bounds)
        }
        return nil
    }

    private func setHoveredAuto(_ hit: AutoHit?) {
        guard hit != hoveredAuto else { return }
        // The frames that have to be erased can be anywhere: the whole group of the old target, and the whole
        // group of the new one. Invalidating only the pointer's own rect left every other green frame behind.
        let old = autoHoverTargets(flags: autoHoverFlags).map(\.rect) + (hoveredAuto.map { [$0.rect] } ?? [])
        hoveredAuto = hit
        let new = autoHoverTargets(flags: autoHoverFlags).map(\.rect) + (hit.map { [$0.rect] } ?? [])
        let union = (old + new).reduce(CGRect.null) { $0.union($1) }
        if !union.isNull { invalidate(union, margin: 12) }
        refreshAutoGuide()
    }

    /// Follows ⌥ / ⇧. The frames and the guide both repaint on a change; when the same keys come back up the
    /// category frames disappear with them.
    private func setAutoHoverFlags(_ flags: NSEvent.ModifierFlags) {
        let relevant = flags.intersection([.shift, .option])
        guard relevant != autoHoverFlags.intersection([.shift, .option]) else { return }
        autoHoverFlags = flags
        guard isAutoMaskMode else { return }
        refreshAutoGuide()
        needsDisplay = true
    }

    /// Exactly the targets a click at the pointer would touch, under the modifier held right now.
    private func autoHoverTargets(flags: NSEvent.ModifierFlags) -> [AutoMaskTarget] {
        guard let target = hoveredAuto?.target else { return [] }
        if flags.contains(.shift), let category = target.category {
            return autoTargets.filter { $0.category == category }
        }
        if flags.contains(.option) { return [target] }
        return autoTargets.filter { $0.groupKey == target.groupKey }
    }

    /// Which guide row is lit: the modifier decides, then a manual drag in progress, then hovering something
    /// already masked (where the same click cancels).
    private func autoGuideRule(flags: NSEvent.ModifierFlags) -> Int {
        if flags.contains(.option) { return 1 }
        if flags.contains(.shift) { return 2 }
        if case .drawing = drag, didDrag { return 3 }
        if hoveredAuto?.isMasked == true { return 4 }
        return 0
    }

    private func refreshAutoGuide() {
        guard isAutoMaskMode else { return }
        autoGuide.setActiveRule(autoGuideRule(flags: autoHoverFlags))
    }

    /// A click toggles masks. Plain: every place with the same text. ⌥: this one place. ⇧: every place of the
    /// same kind (all phone numbers, all dates). One undo step either way.
    private func handleAutoClick(_ hit: AutoHit, at p: CGPoint, flags: NSEvent.ModifierFlags) {
        if let target = hit.target {
            let set: [AutoMaskTarget]
            if flags.contains(.shift), let category = target.category {
                set = autoTargets.filter { $0.category == category }
            } else if flags.contains(.option) {
                set = [target]
            } else {
                set = autoTargets.filter { $0.groupKey == target.groupKey }
            }
            let rects = set.map(\.rect)
            let union = rects.reduce(CGRect.null) { $0.union($1) }
            // Clicking a masked thing takes the set off; clicking an unmasked one puts the set on. The two
            // cannot be decided by "is anything in the set masked": after ⌥ leaving one place out, clicking a
            // *different* place must add, not silently remove the one that was already there. ⇧ on a whole
            // category is the exception — it only turns off once every place of that kind is on.
            let removing = flags.contains(.shift) && target.category != nil
                ? set.allSatisfy(isAutoMasked)
                : isAutoMasked(target)
            let toAdd = set.filter { !isAutoMasked($0) }
            mutate {
                if removing {
                    items.removeAll { item in
                        guard let r = item.shape.mosaicRect else { return false }
                        return rects.contains { Self.sameRect($0, r) }
                    }
                } else {
                    for t in toAdd {
                        items.append(AnnotationItem(shape: .mosaicRect(t.rect),
                                                    color: StyleMemory.color(for: .mosaic),
                                                    size: StyleMemory.size(for: .mosaic),
                                                    effect: StyleMemory.mosaicEffect,
                                                    mosaicStrength: StyleMemory.mosaicStrength))
                    }
                }
            }
            invalidate(union, margin: 12)
        } else if let id = hit.itemID {
            let area = item(id)?.bounds ?? hit.rect
            mutate { items.removeAll { $0.id == id } }
            invalidate(area, margin: 12)
        }
        // The pointer has not moved, but what is under it has: it may now be a mask, and the guide says so.
        hoveredAuto = autoHit(at: p)
        refreshAutoGuide()
        needsDisplay = true
        layoutChrome()
    }

    /// Only what the pointer is over: green dashed frames around every target the click would touch. Nothing is
    /// drawn when the pointer is elsewhere, so the picture stays clean until the user asks it a question.
    private func drawAutoMaskOverlay() {
        guard isAutoMaskMode, hoveredAuto != nil else { return }
        let green = NSColor.systemGreen
        for target in autoHoverTargets(flags: autoHoverFlags) {
            let box = NSBezierPath(roundedRect: target.rect, xRadius: 3, yRadius: 3)
            green.withAlphaComponent(0.16).setFill()
            box.fill()
            green.withAlphaComponent(0.95).setStroke()
            box.lineWidth = 1.5
            box.setLineDash([4, 3], count: 2, phase: 0)
            box.stroke()
        }
    }

    /// The guide sits to the left of the selection, top-aligned. When the selection is against the left edge it
    /// moves to the right; failing both, it steps inside the selection rather than disappearing — the gestures
    /// are not discoverable on their own.
    private func layoutAutoGuide() {
        autoGuide.isHidden = !(isAutoMaskMode && !isAdjustingSelection)
        guard !autoGuide.isHidden else { return }
        refreshAutoGuide()
        let size = autoGuide.frame.size
        func overlapsChrome(_ r: CGRect) -> Bool {
            [toolbar, styleBar, translationBar].contains { !$0.isHidden && $0.frame.intersects(r) }
        }
        let top = min(max(4, selection.minY), bounds.maxY - size.height - 4)
        var origin = CGPoint(x: selection.minX - 10 - size.width, y: top)
        if origin.x < 4 || overlapsChrome(CGRect(origin: origin, size: size)) {
            let right = CGPoint(x: selection.maxX + 10, y: top)
            if right.x + size.width <= bounds.maxX - 4 && !overlapsChrome(CGRect(origin: right, size: size)) {
                origin = right
            } else {
                origin = CGPoint(x: min(max(4, selection.minX + 12), bounds.maxX - size.width - 4),
                                 y: min(max(4, selection.minY + 12), bounds.maxY - size.height - 4))
            }
        }
        autoGuide.setFrameOrigin(origin)
    }

    // MARK: - Self-check hooks for 自动识别

    var testing_autoTargets: [AutoMaskTarget] { autoTargets }
    /// 自检用：再读一次屏幕，验证同一个引擎下同一块选区不会重复请求。
    func testing_restartAutoMaskDetection() { startAutoMaskDetection() }
    var testing_autoGuideFrame: CGRect? { autoGuide.isHidden ? nil : autoGuide.frame }
    var testing_autoGuideRule: Int { autoGuide.activeRule }
    /// What the pointer at `p` would touch under `flags`; nil means there is nothing there.
    func testing_autoHoverTargets(at p: CGPoint, flags: NSEvent.ModifierFlags) -> [AutoMaskTarget] {
        let saved = hoveredAuto
        defer { hoveredAuto = saved }
        hoveredAuto = autoHit(at: p)
        return autoHoverTargets(flags: flags)
    }
    /// Which guide row `flags` would light with the pointer at `p`.
    func testing_autoGuideRule(at p: CGPoint, flags: NSEvent.ModifierFlags) -> Int {
        let saved = hoveredAuto
        defer { hoveredAuto = saved }
        hoveredAuto = autoHit(at: p)
        return autoGuideRule(flags: flags)
    }
    /// Puts the pointer somewhere for the drawing, or takes it away with nil.
    func testing_setAutoHover(at p: CGPoint?) {
        setHoveredAuto(p.flatMap { autoHit(at: $0) })
    }
    /// Holds or releases ⌥ / ⇧ for the drawing and the guide, as a real key press would.
    func testing_setAutoModifiers(_ flags: NSEvent.ModifierFlags) {
        setAutoHoverFlags(flags)
    }
    var testing_autoMode: Bool { isAutoMaskMode }
    var testing_mosaicMaskCount: Int { items.filter { $0.tool == .mosaic }.count }

    /// What the translation bar is showing, or nil when it is not up.
    var testing_translationBar: (source: String, target: String, action: String, hasFullText: Bool)? {
        translationBar.isHidden ? nil : translationBar.testing_text
    }
    var testing_translationBarFrame: CGRect? { translationBar.isHidden ? nil : translationBar.frame }
    /// The engine chip, the list behind it and the 重新翻译 button — nil while the bar is down.
    var testing_barEngine: (shown: String, all: [String], retry: String)? {
        translationBar.isHidden ? nil : translationBar.testing_engine
    }
    var testing_barMenu: (titles: [String], checked: Int)? {
        translationBar.isHidden ? nil : translationBar.testing_menu
    }
    var testing_barRetryEnabled: Bool { translationBar.testing_retryEnabled }
    /// Where the chip and the 重新翻译 button are, in this view's coordinates.
    var testing_barEngineFrame: CGRect? {
        translationBar.isHidden ? nil : translationBar.convert(translationBar.testing_engineFrame, to: self)
    }
    var testing_barRetryFrame: CGRect? {
        translationBar.isHidden ? nil : translationBar.convert(translationBar.testing_retryFrame, to: self)
    }
    /// The open list: where it is and what is in it, or nil while it is closed.
    var testing_engineMenu: (frame: CGRect, titles: [String], current: Int)? {
        engineMenu.isHidden ? nil : (engineMenu.frame, engineMenu.testing_rows.titles, engineMenu.testing_rows.current)
    }
    func testing_openEngineMenu() { toggleEngineMenu() }
    func testing_hoverEngineRow(_ index: Int) { engineMenu.testing_hover(index) }
    func testing_pressBarRetry() { translationBar.testing_pressRetry() }
    /// 自检用：清掉当前选区，等于重新框一次。
    func testing_resetSelection() { resetSelection() }
    /// The two language pickers and the list under whichever one is open.
    var testing_barLanguageFrames: (source: CGRect, target: CGRect)? {
        guard !translationBar.isHidden else { return nil }
        return (translationBar.convert(translationBar.sourceChipFrame, to: self),
                translationBar.convert(translationBar.targetChipFrame, to: self))
    }
    func testing_pressSourceLanguage() { translationBar.testing_pressSource() }
    func testing_pressTargetLanguage() { translationBar.testing_pressTarget() }
    func testing_pressSwapDirection() { translationBar.testing_pressSwap() }
    var testing_languageMenu: (titles: [String], checked: Int, frame: CGRect)? {
        guard languageMenuKind != nil, !languageMenu.isHidden else { return nil }
        return (languageMenu.testing_rows.titles, languageMenu.testing_rows.current, languageMenu.frame)
    }
    func testing_pickLanguage(_ index: Int) { useTranslationLanguage(at: index) }
    func testing_hoverLanguageRow(_ index: Int) { languageMenu.testing_hover(index) }
    func testing_pickBarEngine(_ index: Int) { engineMenu.testing_pick(index) }
    /// What a real click at this point would land on. `hitTest` wants the point in the superview's coordinates,
    /// so this goes through the window's content view — the way a click really arrives.
    func testing_hitTest(_ point: CGPoint) -> NSView? {
        guard let root = window?.contentView else { return nil }
        return root.hitTest(root.convert(point, from: self))
    }
    var testing_toastFrame: CGRect? { toast.isHidden ? nil : toast.frame }
    var testing_sizeChipFrame: CGRect? { topBar.isHidden ? nil : topBar.frame }
    var testing_translationPanelFrame: CGRect? { translationPanel.isHidden ? nil : translationPanel.frame }
    var testing_translationPanelText: String? { translationPanel.isHidden ? nil : translationPanel.testing_text }
    func testing_swapDirection() { swapTranslationDirection() }
    func testing_showFullText() { openTranslationPanel() }
    func testing_showToast(_ text: String) { showToast(text, duration: nil) }

    /// The translation drawn on the selection, empty while there is none (or while it is loading).
    var testing_translation: [TranslatedBlock] { visibleTranslation }
    var testing_translating: Bool { isTranslating }

    /// A translation is on its way: the shimmer runs over the blocks it will land in, and the bar's button says 正在翻译中…
    private var isTranslating: Bool {
        if case .loading = translationState { return true }
        return false
    }

    // MARK: Translation direction

    /// Which way this translation goes. The rule lives in `TranslationDirection`, shared with 输入翻译 so the
    /// two can't drift apart.
    private var translationDirection: TranslationDirection {
        TranslationDirection(detected: detectedLanguage, flipped: directionFlipped)
    }

    /// What the guess said, unless the user named the language on the bar. Everything downstream — which
    /// blocks are sent, what the bar says, what the engine is told — reads these two, so picking a side is one
    /// fact rather than a flag every call site has to remember.
    private var effectiveSource: ScreenLanguage {
        sourceOverride ?? translationDirection.source
    }

    private var translationTarget: String {
        if let targetOverride { return targetOverride }
        // The rule the app has always had: Chinese goes to English, everything else to 「默认翻译为」.
        return effectiveSource.translatesIntoEnglish ? "English" : Settings.shared.targetLanguage
    }

    private var translationSourceName: String { effectiveSource.name }

    /// The bar is up whenever it has something to control: 截图翻译 mode as soon as there is a selection, or
    /// any time a translation is on screen (or on its way).
    private var showsTranslationBar: Bool {
        guard mode == .screenshot, hasSelection, !isAdjustingSelection else { return false }
        if autoTranslate { return true }
        if case .none = translationState { return false }
        return true
    }

    /// The blocks whose translation did not fit and had to be cut. This is what the bar's「全文」button and
    /// the panel behind it are for.
    private var truncatedBlocks: [(original: String, translation: String)] {
        visibleTranslation.compactMap { block in
            guard block.text != block.fullText else { return nil }
            return (block.sourceText, block.fullText)
        }
    }

    private func openTranslationPanel() {
        let blocks = truncatedBlocks
        guard !blocks.isEmpty else { return }
        hideReadingPanels()
        translationPanel.show(blocks)
        translationPanel.isHidden = false
        layoutChrome()
    }

    private func closeTranslationPanel() {
        translationPanel.isHidden = true
    }

    private func swapTranslationDirection() {
        let source = effectiveSource
        let target = translationTarget
        // Exchange the two sides as they are written on the bar. After this the user has said which way round
        // it is, so both are pinned instead of one flag flipping a guess. A side that cannot be named as a
        // language (外文, or a target outside the list) falls back to the old flip.
        if let newSource = Self.screenLanguage(forTarget: target),
           let newTarget = Self.translationLanguage(source) {
            sourceOverride = newSource
            targetOverride = newTarget
        } else {
            directionFlipped.toggle()
        }
        restartTranslation()
    }

    /// The name a translator understands for `language` — the list 输入翻译 offers, not the bar's short names.
    private static func translationLanguage(_ language: ScreenLanguage) -> String? {
        switch language {
        case .chinese: return "简体中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .other: return nil
        }
    }

    private static func screenLanguage(forTarget name: String) -> ScreenLanguage? {
        switch name {
        case "简体中文", "繁體中文": return .chinese
        case "English": return .english
        case "日本語": return .japanese
        case "한국어": return .korean
        default: return nil
        }
    }

    /// The engines the bar's menu offers, 免费翻译 first, and which of them is doing the translating. Read
    /// fresh on every layout pass: the settings window can add, rename or delete a 大模型 between two captures.
    private var translationEngines: (names: [String], index: Int) {
        let configs = Settings.shared.llmConfigs
        let names = ["免费翻译"] + LLMConfig.labels(for: configs)
        // An id that no longer names an entry reads as the first, exactly as the settings' own pickers do.
        let selected = configs.firstIndex { $0.id == Settings.shared.selectedLLMConfigID } ?? 0
        return (names, Settings.shared.engine == .free ? 0 : selected + 1)
    }

    /// Picking an engine is a preference, not an override for this one capture: it goes into the settings, so
    /// every later capture uses it too. That is also why the screen is translated again straight away — the bar
    /// naming an engine the text underneath did not come from would be a lie.
    private func useTranslationEngine(at index: Int) {
        closeEngineMenu()
        let configs = Settings.shared.llmConfigs
        if index <= 0 {
            Settings.shared.engine = .free
        } else {
            guard index <= configs.count else { return }
            Settings.shared.engine = .llm
            Settings.shared.selectedLLMConfigID = configs[index - 1].id
        }
        restartTranslation()
    }

    /// Translates the selection again with whatever the settings now say — the bar's 重新翻译, and where picking
    /// a different 大模型 lands. Whatever was running is the stale one now, exactly as when the direction flips.
    private func restartTranslation() {
        guard mode == .screenshot, hasSelection else { return }
        recognitionTask?.cancel()
        recognitionTask = nil
        stopShimmer()
        startTranslation(refresh: true)
    }

    private func runTranslation() {
        if toggleTranslation() { return }
        startTranslation()
    }

    /// Flips between the translation and the original, for the translate button and the bar's 显示原文.
    /// False when there was nothing to flip, so `runTranslation` knows to start one instead.
    @discardableResult
    private func toggleTranslation() -> Bool {
        switch translationState {
        case .loading:
            return true
        case let .shown(blocks, rect) where rect == selection:
            translationState = .hidden(blocks, rect)
            toolbar.translateButton.isActive = false
            // The panel is the rest of the translation; with the original on screen there is nothing to
            // complete, so it goes away with it.
            closeTranslationPanel()
            updateHistoryButtons()
            invalidate(selection)
            return true
        case let .hidden(blocks, rect) where rect == selection:
            translationState = .shown(blocks, rect)
            toolbar.translateButton.isActive = true
            updateHistoryButtons()
            invalidate(selection)
            return true
        default:
            return false
        }
    }

    /// 文字识别的自动识别：选区一确定就收起整个截图界面，识别在后台跑完把文字送进剪贴板，
    /// 提示落在刚框的那块中间（不是屏幕底部），免得把注意力拽到别处。
    /// 裁剪和选区在屏幕上的位置都要在收起之前取好，之后的识别不再依赖这个视图。
    private func autoOCRIfNeeded() {
        guard autoOCR, mode == .screenshot, hasSelection, let crop = cropSelection() else { return }
        let rect = selection
        let area = selectionOnScreen
        StyleMemory.lastSelection[displayID] = rect
        session?.finish()
        Task { @MainActor in
            do {
                let result = try await TextRecognizer.recognize(crop, selection: rect)
                let text = result.plainText
                guard !text.isEmpty else { return HUD.show("没有识别到文字", at: area) }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                if let notice = result.notice {
                    HUD.show("已复制到剪贴板 · \(notice)", at: area, duration: 3)
                } else {
                    HUD.show("已复制到剪贴板", at: area, duration: 1)
                }
            } catch {
                HUD.show("文字识别失败：\(error.localizedDescription)", at: area, duration: 3)
            }
        }
    }

    /// The selection the translation on screen belongs to; nil while there is nothing (or nothing yet).
    private var translationRect: CGRect? {
        switch translationState {
        case .none, .loading: return nil
        case let .shown(_, rect), let .hidden(_, rect): return rect
        }
    }

    /// 截图翻译的自动翻译：选区定下来就翻，之后调整选区再翻一次。
    private func autoTranslateIfNeeded() {
        guard autoTranslate, mode == .screenshot, hasSelection, translationRect != selection else { return }
        // A translation of the previous selection may still be running: it is the stale one now.
        if case .loading = translationState {
            recognitionTask?.cancel()
            recognitionTask = nil
            stopShimmer()
            translationState = .none
        }
        startTranslation()
    }

    /// Translates the current selection, replacing whatever is on screen.
    ///
    /// `refresh` is the bar's 重新翻译 and picking a different engine: send the text again even if the cache has
    /// an answer for it. Going through the cache there would hand back the translation that is already on
    /// screen — instantly, with nothing moving — which is what a button that does nothing looks like. It is
    /// also the whole point of the button after a timeout: the only way out is a request that goes out again.
    private func startTranslation(refresh: Bool = false) {
        guard recognitionTask == nil else { return }
        let engine = Settings.shared.translationConfig
        guard engine.engine == .free || !engine.apiKey.isEmpty else {
            showToast("还没有填写 API Key。请按 Esc 退出截图，在菜单栏 OmniShot → 设置 中填写。", duration: 5)
            // The bar's chip is already showing the engine that was picked — it is a setting, and it was
            // written before we got here. Lay it out so the name on screen matches what the settings now say.
            layoutChrome()
            return
        }
        // A cancelled translation is never what gets restored: putting the view back into 正在翻译 would leave
        // the shimmer running at a request that no longer exists, and the bar saying 正在翻译中… forever.
        var previous = translationState
        if case .loading = previous { previous = .none }
        translationState = .loading
        // Whatever the panel was showing belongs to the translation being replaced.
        closeTranslationPanel()
        toolbar.translateButton.isActive = true
        showTranslationProgress("正在识别文字…", duration: nil)
        layoutChrome()
        let rect = selection
        translationGeneration += 1
        let generation = translationGeneration
        let slowHint = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, generation == translationGeneration, case .loading = translationState else { return }
            showTranslationProgress("正在准备识别引擎，这次会慢一些…", duration: nil)
        }

        recognitionTask = Task { @MainActor in
            defer {
                slowHint.cancel()
                // A newer translation owns `recognitionTask` (and the screen) by now.
                if generation == translationGeneration {
                    recognitionTask = nil
                    stopShimmer()
                }
            }
            do {
                let result = try await recognize()
                guard generation == translationGeneration else { return }
                // Which way to translate is decided by what is actually on screen, so it can only be worked
                // out once the text has been read.
                detectedLanguage = ScreenLanguage.detect(in: result.lines.map(\.text))
                let blocks = result.translatedBlocks
                    .filter { TextBlockBuilder.shouldTranslate($0.text, from: effectiveSource) }
                guard !blocks.isEmpty else {
                    translationState = previous
                    toolbar.translateButton.isActive = false
                    showToast(effectiveSource.translatesIntoEnglish ? "没有找到需要翻译的中文" : "没有找到需要翻译的外文")
                    layoutChrome()
                    return
                }
                pendingBlockRects = blocks.map(\.rect)
                startShimmer()
                showTranslationProgress("正在翻译 \(blocks.count) 段…", duration: nil)
                layoutChrome()
                let items = blocks.map { ChatTranslator.Item(id: $0.id, text: $0.text) }
                var config = Settings.shared.translationConfig
                config.targetLanguage = translationTarget
                // Only a language the user pinned is passed on: a guess that turns out wrong should not be
                // forced onto an engine that can read the text itself, and the automatic path has always let
                // it. Picking 英文 on the bar and having the request still say 「自动识别」would be a lie.
                config.sourceLanguage = sourceOverride.flatMap(Self.translationLanguage) ?? TranslationConfig.autoSource
                if refresh {
                    for item in items { TranslationService.cache.forget(item.text, config: config) }
                }
                let translations = try await translate(items, config)
                guard generation == translationGeneration else { return }
                guard let crop = cropSelection(), rect == selection else {
                    translationState = previous
                    toolbar.translateButton.isActive = false
                    showToast("选区已改变，请重新翻译")
                    return
                }
                let laidOut = TranslationLayout.layout(blocks: blocks, translations: translations, crop: crop,
                                                       selection: rect, targetLanguage: translationTarget)
                translationState = .shown(laidOut, rect)
                let missing = blocks.count - laidOut.count
                let direction = "\(translationSourceName) → \(translationTarget)"
                showTranslationProgress(missing > 0 ? "\(direction) · 已翻译 \(laidOut.count) 段，\(missing) 段没有返回译文"
                                          : "\(direction) · 已翻译 \(laidOut.count) 段 · Y 切换原文",
                                  duration: missing > 0 ? 3 : 2)
                updateHistoryButtons()
                invalidate(selection)
                layoutChrome()
            } catch is CancellationError {
                if generation == translationGeneration { translationState = previous }
            } catch {
                guard generation == translationGeneration else { return }
                translationState = previous
                toolbar.translateButton.isActive = isTranslationShown
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                // 截图翻译 没有工具条，那条路上指「翻译按钮」等于指一个不在屏幕上的东西。
                showToast("翻译失败：\(message)\n" + (autoTranslate ? "点悬浮条上的「重新翻译」可以重试。" : "再按一次翻译按钮可以重试。"),
                          duration: 6)
                invalidate(selection)
                layoutChrome()
            }
        }
    }

    private func startShimmer() {
        shimmerStart = Date()
        shimmerTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.invalidate(self.pendingBlockRects.reduce(CGRect.null) { $0.union($1) }, margin: 4)
        }
        RunLoop.main.add(timer, forMode: .common)
        shimmerTimer = timer
    }

    private func stopShimmer() {
        shimmerTimer?.invalidate()
        shimmerTimer = nil
        if !pendingBlockRects.isEmpty {
            invalidate(pendingBlockRects.reduce(CGRect.null) { $0.union($1) }, margin: 4)
            pendingBlockRects = []
        }
    }

    // MARK: - Output

    /// The image that copy/save would produce right now.
    func exportImage() -> NSBitmapImageRep? {
        materializeErased()
        return Exporter.render(renderer: renderer, selection: selection, scale: scale, items: items, translation: visibleTranslation)
    }

    /// The selection in global screen coordinates.
    var selectionOnScreen: CGRect? {
        guard let window else { return nil }
        return CGRect(x: window.frame.minX + selection.minX, y: window.frame.maxY - selection.maxY,
                      width: selection.width, height: selection.height)
    }

    /// Floats the current selection (with annotations and translation) above other windows, where it was captured.
    private func pinSelection() {
        commitText()
        endChange()
        guard hasSelection, let frame = selectionOnScreen, let rep = exportImage() else { return }
        StyleMemory.lastSelection[displayID] = selection
        session?.finish()
        PinManager.shared.pin(rep, frame: frame)
    }

    /// Hands the selected region to the long-screenshot controller. Annotations are not carried over.
    private func startLongCapture() {
        guard hasSelection, let rect = selectionOnScreen, let screen = window?.screen else { return }
        guard selection.height >= 60 else {
            showToast("选区太矮了，长截图需要至少 60pt 高的滚动区域")
            return
        }
        StyleMemory.lastSelection[displayID] = selection
        session?.finish()
        ScrollCaptureController.start(rect: rect, screen: screen)
    }

    /// Bakes the annotations into the pin; ⌘C and ⌘S also copy or save the result.
    private func finishPinEdit(_ output: OutputAction) {
        guard let rep = exportImage() else {
            showToast("导出图片失败")
            return
        }
        switch output {
        case .copy:
            Exporter.copy(rep)
            HUD.show("已复制到剪贴板", on: window?.screen)
        case .save, .saveAs:
            let settings = Settings.shared
            if let url = try? Exporter.save(rep, format: settings.imageFormat, directory: settings.saveDirectory) {
                HUD.show("已保存到 \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))", on: window?.screen)
            }
        case .apply:
            break
        }
        session?.applyPinEdit(rep)
    }

    private func finish(_ output: OutputAction) {
        commitText()
        endChange()
        guard hasSelection, selection.width >= 1, selection.height >= 1 else { return }
        if mode == .pinEdit {
            // ✓ on a pin's toolbar is the button people press to be done: it copies the picture — what the button
            // promises — and folds the stage away, leaving the pin where it is. Closing the pin there left the
            // user with nothing to double-click, and few people work out that the pencil is the way back in.
            // 保存 / 复制 / 退出截图 still end the pin (`CaptureSession.closesPin`).
            if output == .apply {
                session?.finishPinTools(copying: true)
                return
            }
            finishPinEdit(output)
            return
        }
        StyleMemory.lastSelection[displayID] = selection
        let output: OutputAction = output == .apply ? .copy : output
        // 记录落成之后的那一个（↩ 和工具栏的 ✓ 都走 `.apply`，实际做的是复制），自检看这个。
        testing_output = output
        let settings = Settings.shared
        let format: ImageFormat = output == .copy ? .png : settings.imageFormat
        guard let rep = exportImage() else {
            showToast("导出图片失败")
            return
        }
        let screen = window?.screen
        switch output {
        case .copy:
            Exporter.copy(rep)
            session?.finish()
            HUD.show("已复制到剪贴板", on: screen)
        case .save:
            do {
                let url = try Exporter.save(rep, format: format, directory: settings.saveDirectory)
                session?.finish()
                HUD.show("已保存到 \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))", on: screen)
            } catch {
                showToast("保存失败：\(error.localizedDescription)", duration: 5)
            }
        case .saveAs:
            session?.presentSavePanel(rep: rep, format: format)
        case .apply:
            break // mapped to .copy above
        }
    }
}

extension Shape {
    var isMosaicBrush: Bool {
        if case .mosaicBrush = self { return true }
        return false
    }

    /// The rect of a rectangular mosaic, or nil for every other shape.
    var mosaicRect: CGRect? {
        if case let .mosaicRect(rect) = self { return rect }
        return nil
    }

    var isHighlight: Bool {
        if case .highlight = self { return true }
        return false
    }

    /// The ellipse flag of a highlight; false for every other shape.
    var highlightEllipse: Bool {
        if case let .highlight(_, ellipse) = self { return ellipse }
        return false
    }
}

enum TranslationService {
    static let cache = TranslationCache()
}
