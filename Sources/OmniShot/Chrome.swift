import AppKit

/// The app's accent colour: the selection frame, the active tool, the size chip, a pin's border, the buttons
/// that ask to be pressed — everything that used to be one fixed blue. Chosen by the user in 设置 → 通用 → 主题色.
///
/// Looked up through `Settings` on every use rather than cached in a global: it costs a dictionary read, and a
/// cache would have to be invalidated both from the settings window and from every self-check that sets the
/// colour directly — which is exactly the kind of thing that rots.
var themeColor: NSColor { Settings.shared.themeColor }

/// Rounded panel drawn to match the system appearance, with an optional caret pointing
/// at the control it belongs to. The caret sits outside `contentRect`.
class PanelView: NSView {
    enum CaretEdge {
        case top, bottom, left, right
        var isVertical: Bool { self == .top || self == .bottom }
    }

    static let caretHeight: CGFloat = 6
    var fill: NSColor = .windowBackgroundColor { didSet { needsDisplay = true } }
    var radius: CGFloat = 9
    /// Edge and position along it (x for top/bottom, y for left/right).
    var caret: (edge: CaretEdge, offset: CGFloat)? {
        didSet {
            needsDisplay = true
            caretDidChange()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// A panel hosted in a window of its own (the pinned 扫码 result) drags that window when its background is
    /// used. In a capture the panel sits in the overlay, where this stays off.
    var movesWindowOnDrag = false

    // Swallow clicks in the padding so they don't reach the capture view.
    override func mouseDown(with event: NSEvent) {
        if movesWindowOnDrag { window?.performDrag(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    func caretDidChange() {}

    var contentRect: CGRect {
        var r = bounds
        if let caret {
            switch caret.edge {
            case .top: r.origin.y += Self.caretHeight; r.size.height -= Self.caretHeight
            case .bottom: r.size.height -= Self.caretHeight
            case .left: r.origin.x += Self.caretHeight; r.size.width -= Self.caretHeight
            case .right: r.size.width -= Self.caretHeight
            }
        }
        return r
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = contentRect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        if let caret {
            let tri = NSBezierPath()
            let h = Self.caretHeight
            if caret.edge.isVertical {
                let x = min(max(caret.offset, body.minX + radius + 6), body.maxX - radius - 6)
                let base = caret.edge == .top ? body.minY + 1 : body.maxY - 1
                let tip = caret.edge == .top ? body.minY - h + 0.5 : body.maxY + h - 0.5
                tri.move(to: CGPoint(x: x - 7, y: base))
                tri.line(to: CGPoint(x: x, y: tip))
                tri.line(to: CGPoint(x: x + 7, y: base))
            } else {
                let y = min(max(caret.offset, body.minY + radius + 6), body.maxY - radius - 6)
                let base = caret.edge == .left ? body.minX + 1 : body.maxX - 1
                let tip = caret.edge == .left ? body.minX - h + 0.5 : body.maxX + h - 0.5
                tri.move(to: CGPoint(x: base, y: y - 7))
                tri.line(to: CGPoint(x: tip, y: y))
                tri.line(to: CGPoint(x: base, y: y + 7))
            }
            tri.close()
            path.append(tri)
        }
        fill.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

/// Borderless button that runs a closure, with hover and "active" states.
final class ChromeButton: NSButton {
    private let handler: () -> Void
    private var hovering = false
    /// Pure white, not `.labelColor`: every one of these buttons sits on one of the dark panels, and
    /// `.labelColor` is only about 85% white there, which made the whole toolbar look washed out.
    var tint: NSColor = .white { didSet { needsDisplay = true } }
    /// Drawn in the app's accent colour rather than in `tint` (the ✓ button is). Looked up while drawing: the
    /// theme can be changed between two captures, so a colour stored at construction would go stale.
    var tintedWithTheme = false { didSet { needsDisplay = true } }
    /// Called when the pointer enters (true) or leaves (false); the toolbar shows its hover card with it.
    var onHover: ((Bool) -> Void)?

    var isActive = false {
        didSet { needsDisplay = true }
    }

    /// `tooltip` nil leaves the system tooltip off, for buttons that show their own hover card.
    init(image: NSImage, tooltip: String?, size: CGFloat = 30, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        self.image = image
        toolTip = tooltip
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
        NSCursor.arrow.set()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
        onHover?(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background: NSColor? = isActive ? themeColor.withAlphaComponent(0.18)
            : hovering && isEnabled ? NSColor.labelColor.withAlphaComponent(0.08) : nil
        if let background {
            background.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        contentTintColor = isActive || tintedWithTheme ? themeColor : tint
        super.draw(dirtyRect)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private func separator(height: CGFloat = 18) -> NSView {
    let line = NSBox()
    line.boxType = .separator
    line.translatesAutoresizingMaskIntoConstraints = false
    line.widthAnchor.constraint(equalToConstant: 1).isActive = true
    line.heightAnchor.constraint(equalToConstant: height).isActive = true
    return line
}

enum ToolbarAction: Hashable {
    case tool(Tool), undo, ocr, translate, pin, longCapture, cancel, save, done

    /// The tools a pin's editor does not offer. 识别内容 is what the pin already does by itself when the pointer
    /// is on it, 长截图 starts a new capture, and 贴在屏幕上 is what the picture already is — none of them has a
    /// meaning while editing a pin.
    static let unavailableInPinEdit: Set<ToolbarAction> = [.ocr, .longCapture, .pin]

    /// Buttons with a single key can have it changed; undo, save, cancel and done keep the shortcuts everyone knows.
    var keyID: String? {
        switch self {
        case let .tool(t): return t.rawValue
        case .ocr: return "ocr"
        case .translate: return "translate"
        case .pin: return "pin"
        case .longCapture: return "longCapture"
        default: return nil
        }
    }

    /// Shown in the hover card.
    var shortcut: String {
        if let keyID { return ToolbarKeys.key(for: keyID).uppercased() }
        switch self {
        case .undo: return "⌘Z"
        case .cancel: return "Esc"
        case .save: return "⌘S"
        case .done: return "↩"
        default: return ""
        }
    }

    var title: String {
        switch self {
        case let .tool(t): return t.title
        case .undo: return "撤销"
        case .ocr: return "识别内容"
        case .translate: return "翻译到原位"
        case .pin: return "贴到屏幕上"
        case .longCapture: return "长截图"
        case .cancel: return "退出截图"
        case .save: return "保存"
        case .done: return "复制到剪贴板"
        }
    }

    /// An extra line under the name, for what isn't obvious from the title.
    var note: String? {
        switch self {
        case .ocr: return "可识别文字与二维码"
        case .translate: return "可在原文与译文间切换"
        case .pin: return "双击图片快捷贴图"
        case .longCapture: return "在选区内滚动鼠标截长屏"
        case .save: return "⇧⌘S 另存为"
        default: return nil
        }
    }

    /// Every button that has a single key, in toolbar order.
    static let keyed: [ToolbarAction] = Tool.allCases.map { .tool($0) } + [.ocr, .translate, .pin, .longCapture]

    /// Every button on the toolbar, in the order they appear there; the self-checks draw the icon sheet from it.
    static let displayOrder: [ToolbarAction] = Tool.allCases.map { .tool($0) }
        + [.undo, .ocr, .translate, .pin, .longCapture, .cancel, .save, .done]

    /// The button an unmodified key press triggers.
    static func action(forKey key: String) -> ToolbarAction? {
        keyed.first { $0.keyID.map(ToolbarKeys.key(for:)) == key }
    }
}

/// The toolbar's single-key shortcuts, remembered across launches. A key belongs to one button at a time.
enum ToolbarKeys {
    private static let storageKey = "toolbar.keys"
    static let defaults: [String: String] = Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0.rawValue, $0.defaultKey) })
        .merging(["ocr": "x", "translate": "y", "pin": "t", "longCapture": "s"]) { a, _ in a }

    private static var stored: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    static func key(for id: String) -> String { stored[id] ?? defaults[id] ?? "" }

    /// Letters and digits, typed without modifiers.
    static func isAllowed(_ key: String) -> Bool {
        key.count == 1 && key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// Gives `key` to `id`. The button that had it takes `id`'s old key, so no two share one; returns that button's id.
    @discardableResult
    static func assign(_ key: String, to id: String) -> String? {
        let old = self.key(for: id)
        guard key != old else { return nil }
        var all = defaults.merging(stored) { _, new in new }
        let other = all.first { $0.key != id && $0.value == key }?.key
        all[id] = key
        if let other { all[other] = old }
        stored = all
        return other
    }

    static func reset() { stored = [:] }
}

/// How long the pointer must rest on a button before its hover card appears. Shared by the main toolbar and
/// the style bar so the two answer at the same speed — 0.5 s (the toolbar's old value) read as lag next to the
/// style bar's own hints; 0.25 s still ignores a pointer sweeping across the row.
enum HoverCardTiming {
    static let reveal: TimeInterval = 0.25
    /// Grace after the pointer leaves, so it can travel onto the card and read it.
    static let hideGrace: TimeInterval = 0.4
}

/// Bottom toolbar: plain icons in one row, like iShot's. A button's name and shortcut appear in a card
/// once the pointer rests on it for `HoverCardTiming.reveal`.
/// Turns vertical when there is no room under the selection, to sit beside it instead.
final class ToolbarView: PanelView {
    /// The size every toolbar glyph is drawn at. Also used when the 形状 icon swaps between square and circle.
    static let buttonIconSize: CGFloat = 19
    private(set) var toolButtons: [Tool: ChromeButton] = [:]
    private(set) var translateButton: ChromeButton!
    private(set) var undoButton: ChromeButton!
    /// Every button by what it does; a pin's editor leaves some of them out (`hides`).
    private(set) var actionButtons: [ToolbarAction: ChromeButton] = [:]
    private let stack = NSStackView()
    private(set) var isVertical = false
    /// Sizes of the horizontal and vertical layouts, measured once.
    private(set) var horizontalSize = CGSize.zero
    private(set) var verticalSize = CGSize.zero
    /// Sits in the toolbar's superview so it can extend past the toolbar.
    let hoverCard = HoverCardView()

    /// `hides` are buttons this toolbar does not offer at all — a pin's editor has no use for 识别内容,
    /// 长截图 or 贴在屏幕上. They still exist (the keyboard dispatcher and the icon sheet know them), but a
    /// hidden arranged subview takes no room in the stack, so the measured sizes already account for it.
    init(hides: Set<ToolbarAction> = [], handler: @escaping (ToolbarAction) -> Void) {
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 4
        addSubview(stack)

        func add(_ action: ToolbarAction, _ image: NSImage) -> ChromeButton {
            let button = ChromeButton(image: image, tooltip: nil, size: 32) { handler(action) }
            button.isHidden = hides.contains(action)
            actionButtons[action] = button
            button.onHover = { [unowned self, unowned button] inside in
                inside ? self.scheduleShow(for: action, at: button) : self.scheduleHide()
            }
            stack.addArrangedSubview(button)
            return button
        }
        // One icon family for the whole row, from `Icons.swift`. Drawn at 19 pt in a 30 pt button: at 16 the
        // strokes looked thin and the row read as small.
        let iconSize = Self.buttonIconSize
        for tool in Tool.allCases {
            toolButtons[tool] = add(.tool(tool), Icon.image(for: .tool(tool), size: iconSize))
        }
        undoButton = add(.undo, Icon.image(for: .undo, size: iconSize))
        _ = add(.ocr, Icon.image(for: .ocr, size: iconSize))
        translateButton = add(.translate, Icon.image(for: .translate, size: iconSize))
        _ = add(.pin, Icon.image(for: .pin, size: iconSize))
        _ = add(.longCapture, Icon.image(for: .longCapture, size: iconSize))
        _ = add(.cancel, Icon.image(for: .cancel, size: iconSize))
        _ = add(.save, Icon.image(for: .save, size: iconSize))
        add(.done, Icon.image(for: .done, size: iconSize)).tintedWithTheme = true
        setVertical(true)
        verticalSize = frame.size
        setVertical(false)
        horizontalSize = frame.size
        hoverCard.onHover = { [unowned self] inside in
            if inside { self.cancelHide() } else if !self.hoverCard.isRecording { self.scheduleHide() }
        }
        hoverCard.onPick = { [unowned self] key in
            guard let action = self.cardAction, let id = action.keyID else { return }
            let other = ToolbarKeys.assign(key, to: id)
            let swapped = other.flatMap { id in ToolbarAction.keyed.first { $0.keyID == id } }
            self.hoverCard.configure(title: action.title, shortcut: action.shortcut, editable: true,
                                     note: swapped.map { "已和「\($0.title)」互换，它现在是 \($0.shortcut)" } ?? action.note)
            self.placeCard()
        }
    }

    /// The button the card is showing.
    private var cardAction: ToolbarAction?
    private weak var cardButton: ChromeButton?
    private var hideWork: DispatchWorkItem?
    private var showWork: DispatchWorkItem?

    /// Once a card is up, moving to the next button switches it at once, like system tooltips.
    private func scheduleShow(for action: ToolbarAction, at button: ChromeButton) {
        cancelShow()
        if !hoverCard.isHidden {
            showCard(for: action, at: button)
            return
        }
        let work = DispatchWorkItem { [weak self, weak button] in
            guard let self, let button else { return }
            self.showCard(for: action, at: button)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HoverCardTiming.reveal, execute: work)
    }

    private func cancelShow() {
        showWork?.cancel()
        showWork = nil
    }

    /// Leaves time to move the pointer from the button onto the card.
    private func scheduleHide() {
        cancelShow()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hoverCard.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HoverCardTiming.hideGrace, execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    func setVertical(_ vertical: Bool) {
        isVertical = vertical
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .centerX : .centerY
        stack.edgeInsets = vertical ? NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6) : NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        setFrameSize(stack.fittingSize)
        stack.frame = bounds
        // Lay out now: the style bar's caret uses the button positions before the toolbar is first drawn.
        stack.layoutSubtreeIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hoverCard.removeFromSuperview()
        superview?.addSubview(hoverCard)
    }

    // The card belongs to the button under the pointer; any move or hide of the toolbar drops it.
    override var isHidden: Bool {
        didSet { if isHidden { cancelShow(); hoverCard.hide() } }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        if newOrigin != frame.origin { cancelShow(); hoverCard.hide() }
        super.setFrameOrigin(newOrigin)
    }

    /// Above the button for a row (below if there's no room); for a column, on whichever side has room.
    func showCard(for action: ToolbarAction, at button: ChromeButton) {
        guard superview != nil else { return }
        cancelShow()
        cancelHide()
        hoverCard.hide()
        cardAction = action
        cardButton = button
        hoverCard.configure(title: action.title, shortcut: action.shortcut, editable: action.keyID != nil, note: action.note)
        placeCard()
        hoverCard.isHidden = false
    }

    /// Positions the card for its button; again whenever its size changes.
    private func placeCard() {
        guard let container = superview, let button = cardButton else { return }
        let size = hoverCard.frame.size
        let b = button.convert(button.bounds, to: container)
        let bounds = container.bounds
        var origin: CGPoint
        if isVertical {
            origin = CGPoint(x: frame.maxX + 8, y: b.midY - size.height / 2)
            if origin.x + size.width > bounds.maxX - 4 { origin.x = frame.minX - 8 - size.width }
        } else {
            // The container is flipped: smaller y is higher on screen.
            origin = CGPoint(x: b.midX - size.width / 2, y: frame.minY - 8 - size.height)
            if origin.y < 4 { origin.y = frame.maxY + 8 }
        }
        origin.x = min(max(4, origin.x), bounds.maxX - size.width - 4)
        origin.y = min(max(4, origin.y), bounds.maxY - size.height - 4)
        hoverCard.setFrameOrigin(origin)
    }

    func setActiveTool(_ tool: Tool?) {
        for (t, button) in toolButtons { button.isActive = t == tool }
    }

    /// 识别内容 is an action rather than a tool, but while its row is open its button is lit the same way — the
    /// style bar and the icon below it are the same thing.
    func setActiveAction(_ action: ToolbarAction, _ active: Bool) {
        actionButtons[action]?.isActive = active
    }

    /// The 形状 tool wears the icon of what it is about to draw: a square while it draws rectangles, a circle
    /// while it draws circles. Read from `StyleMemory.shapeMode` on every layout.
    func setShapeMode(_ mode: RectangleMode) {
        guard shapeModeShown != mode else { return }
        shapeModeShown = mode
        guard let button = toolButtons[.rectangle] else { return }
        button.image = Icon.image(mode == .ellipse ? .circle : .square, size: Self.buttonIconSize)
        button.needsDisplay = true
    }

    /// The same for 识别内容: its button wears the 扫码 icon once 扫码 is the reading that pressing it (or X) runs.
    /// `--check scan-code` reads the image back.
    func setTextReadingMode(_ mode: TextReadingMode) {
        guard textReadingModeShown != mode else { return }
        textReadingModeShown = mode
        guard let button = actionButtons[.ocr] else { return }
        button.image = Icon.image(mode == .scan ? .qrCode : .scanText, size: Self.buttonIconSize)
        button.needsDisplay = true
    }
    private var textReadingModeShown: TextReadingMode?
    var testing_textReadingMode: TextReadingMode? { textReadingModeShown }

    var testing_shapeMode: RectangleMode? { shapeModeShown }
    private var shapeModeShown: RectangleMode?

    /// The 画笔 tool wears the icon of its sub-tool: a pencil, or a highlighter.
    func setPenMode(_ mode: PenMode) {
        guard penModeShown != mode, let button = toolButtons[.pen] else { return }
        penModeShown = mode
        button.image = Icon.image(mode == .highlighter ? .highlighter : .pencilSimple, size: Self.buttonIconSize)
        button.needsDisplay = true
    }

    var testing_penMode: PenMode? { penModeShown }
    private var penModeShown: PenMode?

    /// The 打码 tool's icon follows the effect it will apply: pixelate's checkerboard, the blur drop, or the
    /// eraser for 智能擦除.
    func setMosaicEffect(_ effect: MosaicEffect) {
        guard mosaicEffectShown != effect, let button = toolButtons[.mosaic] else { return }
        mosaicEffectShown = effect
        let asset: Icon.Asset = effect == .pixelate ? .checkerboard : effect == .blur ? .drop : .eraser
        button.image = Icon.image(asset, size: Self.buttonIconSize)
        button.needsDisplay = true
    }

    var testing_mosaicEffect: MosaicEffect? { mosaicEffectShown }
    private var mosaicEffectShown: MosaicEffect?

    func setCanUndo(_ canUndo: Bool) {
        undoButton.isEnabled = canUndo
        undoButton.alphaValue = canUndo ? 1 : 0.35
    }

    /// Whether this toolbar offers `action` — the self-checks use it to guard a pin editor's three exceptions.
    func shows(_ action: ToolbarAction) -> Bool { actionButtons[action]?.isHidden == false }

    /// Center of a tool button's icon, in toolbar coordinates.
    func anchor(for tool: Tool) -> CGPoint? {
        guard let button = toolButtons[tool] else { return nil }
        return center(of: button)
    }

    /// The same for a button that is not a tool — 识别内容's style bar points its caret at the X button.
    func anchor(for action: ToolbarAction) -> CGPoint? {
        guard let button = actionButtons[action] else { return nil }
        return center(of: button)
    }

    private func center(of button: NSView) -> CGPoint {
        let frame = button.convert(button.bounds, to: self)
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}

/// Dark card with a button's name and its key on the first line, and an optional note under them, like iShot's.
/// Clicking the key cap of a single-key button waits for a new key.
final class HoverCardView: PanelView {
    private let title = NSTextField(labelWithString: "")
    private let keyCap = NSView()
    private let key = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private var editable = false
    private var shortcut = ""
    private var noteText: String?
    private(set) var isRecording = false
    var onHover: ((Bool) -> Void)?
    /// A new key (lowercase letter or digit) was pressed while recording.
    var onPick: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        fill = NSColor(white: 0.16, alpha: 0.96)
        radius = 8
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        // Small enough to sit beside the 13 pt name without swelling the first line — the cap used to have a
        // row of its own (with a 「快捷键」 label) and read as the loudest thing in the card.
        key.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        key.textColor = .black
        key.alignment = .center
        keyCap.wantsLayer = true
        keyCap.layer?.cornerRadius = 4
        keyCap.addSubview(key)
        note.font = .systemFont(ofSize: 11)
        note.textColor = NSColor.white.withAlphaComponent(0.55)
        for view in [title, keyCap, note] { addSubview(view) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { isRecording }

    /// A click elsewhere takes the keyboard back: stop waiting for a key.
    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            layoutContent()
            onHover?(false)
        }
        return true
    }

    func configure(title text: String, shortcut: String, editable: Bool, note noteText: String?) {
        self.shortcut = shortcut
        self.editable = editable
        self.noteText = noteText
        title.stringValue = text
        layoutContent()
    }

    private func layoutContent() {
        key.stringValue = isRecording ? "按下新按键" : shortcut
        keyCap.layer?.backgroundColor = (isRecording ? themeColor : NSColor.white).cgColor
        // Black or white, whichever reads on the colour the user picked: white on the default light blue is only
        // 1.4:1, and on a dark theme the label would vanish into the cap.
        key.textColor = isRecording ? ContentRenderer.contrastingTextColor(for: themeColor) : .black
        // Only the recording line is left: the name and the key share the first line, and the old
        // 「点击按键可修改」 line is gone — the cap still takes a click, with a pointing hand and its own help.
        // An empty note counts as no note: otherwise it still takes a row and leaves a blank line under the
        // title (the 形状 tool's two mode hints are title-only).
        let lines = [isRecording ? "Esc 取消" : noteText].compactMap { $0 }.filter { !$0.isEmpty }
        note.stringValue = lines.joined(separator: "\n")
        note.isHidden = lines.isEmpty
        // A hint card (the style bar's mosaic effects) has no key: the title and the note are the whole card.
        let showsKey = editable || !shortcut.isEmpty
        keyCap.isHidden = !showsKey
        let pad: CGFloat = 12
        let t = title.fittingSize, k = key.fittingSize, n = note.fittingSize
        title.frame = CGRect(x: pad, y: 9, width: t.width, height: t.height)
        var lineBottom = title.frame.maxY
        var width = t.width
        if showsKey {
            let capSize = CGSize(width: max(19, k.width + 9), height: 16)
            keyCap.frame = CGRect(x: title.frame.maxX + 6, y: title.frame.midY - capSize.height / 2,
                                  width: capSize.width, height: capSize.height)
            key.frame = CGRect(x: 0, y: (capSize.height - k.height) / 2, width: capSize.width, height: k.height)
            lineBottom = max(lineBottom, keyCap.frame.maxY)
            width = keyCap.frame.maxX - pad
        }
        var height = lineBottom + 8
        if !lines.isEmpty {
            note.frame = CGRect(x: pad, y: height - 3, width: n.width, height: n.height)
            height = note.frame.maxY + 9
            width = max(width, n.width)
        }
        setFrameSize(CGSize(width: ceil(width + pad * 2), height: ceil(height)))
    }

    /// What the card is saying; the self-checks read it to guard the style bar's hints.
    var testing_text: (title: String, note: String) { (title.stringValue, note.stringValue) }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        (editable && keyCap.frame.contains(p) ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard editable, !isRecording, keyCap.frame.insetBy(dx: -4, dy: -4).contains(p) else { return }
        startRecording()
    }

    func startRecording() {
        isRecording = true
        layoutContent()
        window?.makeFirstResponder(self)
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        layoutContent()
        // Hand the keyboard back to the capture view.
        if window?.firstResponder === self { window?.makeFirstResponder(superview) }
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        let typed = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard flags.isEmpty, ToolbarKeys.isAllowed(typed) else {
            NSSound.beep()
            return
        }
        isRecording = false
        onPick?(typed)
        if window?.firstResponder === self { window?.makeFirstResponder(superview) }
    }

    func hide() {
        stopRecording()
        isHidden = true
    }
}

/// The guide that sits beside the selection while 自动识别 is on: one row per gesture, no sentence more than a
/// line. It is chrome, not a control — the whole point is to be read once and then ignored.
final class AutoMaskGuideView: PanelView {
    private let rows: [(key: String, note: String)] = [
        ("点击", "相同内容一起打码"),
        ("⌥ 点击", "只打这一处"),
        ("⇧ 点击", "同类全部打码"),
        ("拖动", "手动补一块"),
        ("再点一次", "取消打码"),
    ]
    private var keyLabels: [NSTextField] = []
    private var noteLabels: [NSTextField] = []
    private let padding: CGFloat = 11
    private let rowHeight: CGFloat = 15
    private let rowGap: CGFloat = 3
    /// Which row is lit. The first rule is lit by default; a modifier moves the light.
    private(set) var activeRule = 0

    init() {
        super.init(frame: .zero)
        fill = NSColor(white: 0.16, alpha: 0.96)
        radius = 8
        for row in rows {
            let key = NSTextField(labelWithString: row.key)
            key.font = .systemFont(ofSize: 11, weight: .semibold)
            key.textColor = .white
            let note = NSTextField(labelWithString: row.note)
            note.font = .systemFont(ofSize: 11)
            note.textColor = NSColor.white.withAlphaComponent(0.7)
            addSubview(key)
            addSubview(note)
            keyLabels.append(key)
            noteLabels.append(note)
        }
        applyColors()
        layoutContent()
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Lights the row the current gesture would use. Only one row is lit at a time.
    func setActiveRule(_ rule: Int) {
        let clamped = min(max(rule, 0), rows.count - 1)
        guard clamped != activeRule else { return }
        activeRule = clamped
        applyColors()
        needsDisplay = true
    }

    private func applyColors() {
        for (index, label) in keyLabels.enumerated() {
            label.textColor = index == activeRule ? .systemGreen : .white
            noteLabels[index].textColor = index == activeRule ? .systemGreen : NSColor.white.withAlphaComponent(0.7)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard keyLabels.indices.contains(activeRule) else { return }
        let row = keyLabels[activeRule].frame
        let pill = CGRect(x: padding - 4, y: row.minY - 2,
                          width: bounds.width - (padding - 4) * 2, height: row.height + 4)
        NSColor.systemGreen.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
    }

    private func layoutContent() {
        let keyWidth = ceil((keyLabels.map { $0.fittingSize.width }.max() ?? 0)) + 12
        let noteWidth = ceil(noteLabels.map { $0.fittingSize.width }.max() ?? 0)
        for (index, _) in rows.enumerated() {
            let y = padding + CGFloat(index) * (rowHeight + rowGap)
            keyLabels[index].frame = CGRect(x: padding, y: y, width: keyWidth - 12, height: rowHeight)
            noteLabels[index].frame = CGRect(x: padding + keyWidth, y: y, width: noteWidth + 2, height: rowHeight)
        }
        let width = padding * 2 + keyWidth + noteWidth
        let height = padding * 2 + CGFloat(rows.count) * rowHeight + CGFloat(rows.count - 1) * rowGap
        setFrameSize(CGSize(width: width.rounded(.up), height: height.rounded(.up)))
    }
}

/// 识别内容's two readings. It is not a `Tool`: neither one draws anything, and both are one-shot actions on the
/// selection. The mode still gets the tool row's treatment — two buttons at the left of the style bar, the active
/// one tinted — because that is how every other tool with a sub-mode says what it is about to do.
enum TextReadingMode: String {
    case text, scan

    var title: String {
        switch self {
        case .text: return "识别文字"
        case .scan: return "扫码"
        }
    }

    var note: String {
        switch self {
        case .text: return "读出选区里的文字，结果可以编辑和复制"
        case .scan: return "识别选区里的二维码和条形码"
        }
    }
}

struct StyleState {
    static let palette: [NSColor] = [
        NSColor(srgbRed: 0.96, green: 0.23, blue: 0.19, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.55, blue: 0.10, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.10, alpha: 1), // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // green
        NSColor(srgbRed: 0.12, green: 0.56, blue: 0.95, alpha: 1), // blue
        NSColor(srgbRed: 0.62, green: 0.32, blue: 0.95, alpha: 1), // purple
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
    ]

    /// Nil while 识别内容's row is on show: that row configures an action, not an annotation tool.
    var tool: Tool?
    /// Set only for 识别内容's row (when `tool` is nil): which of its two readings is active.
    var textReadingMode: TextReadingMode? = nil
    var color: NSColor
    var size: CGFloat
    var mosaicMode: MosaicMode
    var mosaicEffect: MosaicEffect
    /// Mosaic only: how coarse the next one is, as a multiple of the natural strength.
    var mosaicStrength: CGFloat = 1
    var options = ItemStyle()
    /// Highlight only: the shape the next one will be, and how opaque the mask they all share is.
    var highlightEllipse = false
    var highlightOpacity: CGFloat = 0.5
    /// 形状 only: whether the selected or next one is a circle/ellipse instead of a rectangle.
    var shapeEllipse = false
    /// Whether an annotation is selected — the only time there is something for the style bar's trash to delete.
    var canDelete = false
    /// 画笔 only: which sub-tool is showing, and — for the highlighter — its stroke and blend.
    var penMode: PenMode = .pencil
    var highlighterMode: HighlighterMode = .line
    var highlighterBlend: HighlighterBlend = .multiply
}

enum StyleAction {
    case size(CGFloat), color(NSColor), customColor, mosaicMode(MosaicMode), mosaicEffect(MosaicEffect)
    case mosaicStrength(CGFloat)
    case shapeMode(RectangleMode)
    case penMode(PenMode), highlighterMode(HighlighterMode), highlighterBlend(HighlighterBlend)
    case highlighterWidth(CGFloat)
    case highlightEllipse(Bool), highlightOpacity(CGFloat)
    /// 识别内容's two readings: 识别文字 and 扫码.
    case textReadingMode(TextReadingMode)
    /// Changes dash, arrowhead, rounded corners or text decoration.
    case options((inout ItemStyle) -> Void)
    /// The bin at the end of the bar: deletes the selected annotation.
    case delete
}

/// Small template icons for the style options, drawn so each one shows exactly what it does.
enum OptionIcon {
    static func dash(_ dash: DashStyle) -> NSImage {
        icon { rect in
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 1, y: rect.midY))
            path.line(to: CGPoint(x: rect.maxX - 1, y: rect.midY))
            path.lineWidth = 2
            switch dash {
            case .solid: break
            case .dashed: path.setLineDash([4, 2.5], count: 2, phase: 0)
            case .dotted:
                path.lineCapStyle = .round
                path.setLineDash([0.01, 3.5], count: 2, phase: 0)
            }
            path.stroke()
        }
    }

    static func rounded(_ on: Bool) -> NSImage {
        icon { rect in
            let r = rect.insetBy(dx: 2, dy: 3)
            let path = on ? NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4) : NSBezierPath(rect: r)
            path.lineWidth = 1.6
            path.stroke()
        }
    }

    /// The highlighter's line mode: a thin capsule on a 45° diagonal, pointing up and to the right (1:30).
    static func highlighterLine() -> NSImage {
        icon { _ in
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 4, y: 3))
            path.line(to: CGPoint(x: 12, y: 11))
            path.lineWidth = 3.6
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    /// The highlighter's rectangle mode: a rounded box with thin diagonal hatching inside, so it reads as a
    /// covered block rather than an empty outline.
    static func highlighterRect() -> NSImage {
        icon { rect in
            let box = rect.insetBy(dx: 1.5, dy: 1.5)
            let outline = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.4
            outline.stroke()
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            let hatch = NSBezierPath()
            for offset in stride(from: -box.height, through: box.width, by: 3.2) {
                hatch.move(to: CGPoint(x: box.minX + offset, y: box.minY))
                hatch.line(to: CGPoint(x: box.minX + offset + box.height, y: box.maxY))
            }
            hatch.lineWidth = 1.1
            hatch.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Two overlapping swatches for the highlighter's blend: multiply reads darker where they cross, translucent
    /// reads as a lighter veil.
    static func blend(_ mode: HighlighterBlend) -> NSImage {
        icon { rect in
            let w = rect.width * 0.62, h = rect.height * 0.72
            let left = CGRect(x: rect.minX + 0.5, y: rect.midY - h / 2, width: w, height: h)
            let right = CGRect(x: rect.maxX - w - 0.5, y: rect.midY - h / 2, width: w, height: h)
            let base: CGFloat = mode == .multiply ? 0.62 : 0.32
            let overlap: CGFloat = mode == .multiply ? 1.0 : 0.55
            NSColor.black.withAlphaComponent(base).setFill()
            NSBezierPath(roundedRect: left, xRadius: 2, yRadius: 2).fill()
            NSBezierPath(roundedRect: right, xRadius: 2, yRadius: 2).fill()
            NSColor.black.withAlphaComponent(overlap).setFill()
            NSBezierPath(roundedRect: left.intersection(right), xRadius: 2, yRadius: 2).fill()
        }
    }

    static func arrow(_ head: ArrowHead) -> NSImage {
        icon { rect in
            let a = CGPoint(x: 2, y: 3), b = CGPoint(x: rect.maxX - 2, y: rect.maxY - 3)
            let shaft = NSBezierPath()
            shaft.move(to: a)
            shaft.line(to: b)
            shaft.lineWidth = 1.6
            shaft.stroke()
            func drawHead(at tip: CGPoint, from tail: CGPoint, filled: Bool) {
                let angle = atan2(tip.y - tail.y, tip.x - tail.x)
                let p = NSBezierPath()
                p.move(to: CGPoint(x: tip.x - 6 * cos(angle - 0.5), y: tip.y - 6 * sin(angle - 0.5)))
                p.line(to: tip)
                p.line(to: CGPoint(x: tip.x - 6 * cos(angle + 0.5), y: tip.y - 6 * sin(angle + 0.5)))
                p.lineWidth = 1.6
                if filled {
                    p.close()
                    p.fill()
                } else {
                    p.stroke()
                }
            }
            drawHead(at: b, from: a, filled: head != .open)
            if head == .double { drawHead(at: a, from: b, filled: true) }
        }
    }

    static func text(_ decoration: TextDecoration) -> NSImage {
        icon { rect in
            let font = NSFont.systemFont(ofSize: 12, weight: .heavy)
            if decoration == .background {
                NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 1), xRadius: 3, yRadius: 3).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            if decoration == .outline {
                attributes[.strokeWidth] = 4
                attributes[.strokeColor] = NSColor.black
            }
            let a = NSAttributedString(string: "A", attributes: attributes)
            let size = a.size()
            a.draw(at: CGPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
        }
    }

    private static func icon(_ draw: @escaping (CGRect) -> Void) -> NSImage {
        let image = NSImage(size: CGSize(width: 16, height: 14), flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            draw(rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The button a pin and 截图翻译 both put next to what they own: a dark rounded square, the owner's icon drawn
/// white on it, a pointing-hand cursor, brighter while the pointer is on it. **22 pt — the size a pin's buttons
/// have always used**, so the pin's own layout arithmetic is unchanged.
///
/// The plate is a rounded square rather than a circle, which is what the owner asked for once the two sat in a
/// column: squares line up as a stack, circles read as beads. The corner is the same 6.5 pt the panels use. Each
/// caller sets its own `toolTip` and accessibility label——「关闭贴图」 and 「关闭（放弃这次翻译）」 are not the same
/// thing to say.
final class GlyphButton: NSView {
    /// What goes in the middle. The first three are the owner's own icons, drawn from a 1024×1024 canvas and at
    /// the same size on purpose — they were drawn to match each other. The rotate arrow is Phosphor's, which is
    /// the same white-on-dark shape at the same weight.
    enum Glyph {
        /// The pin's and 截图翻译's ×.
        case close
        /// Two sheets, for 复制到剪贴板.
        case copy
        /// The pin's pencil: open the annotation toolbar over the pinned picture.
        case edit
        /// The pin's counter-clockwise arrow: turn the picture 90°.
        case rotate

        var icon: Icon.Asset {
            switch self {
            case .close: return .closeDisc
            case .copy: return .copyDisc
            case .edit: return .editDisc
            case .rotate: return .rotateCounterClockwise
            }
        }
    }

    /// How big an icon is drawn on the plate.
    static let iconSize: CGFloat = 15

    static let diameter: CGFloat = 22
    /// The plate's corner: the same 6.5 pt the panels use, so a column of these sits with the app's other chrome.
    static let cornerRadius: CGFloat = 6.5
    private let glyph: Glyph
    var handler: () -> Void = {}
    private var hovering = false
    private var pressed = false
    /// The pin's pencil while the toolbar it opened is up: a blue plate with the same blue glyph, so the button
    /// says both "this is the one you pressed" and "it is still on". A pin's other two buttons never use it.
    var isActive = false { didSet { needsDisplay = true } }

    /// A button that cannot be used right now — the pin's rotate while the pencil is open, where turning the
    /// picture would leave every annotation pointing at the wrong corner. It dims rather than disappearing, so
    /// the column keeps its shape and the button does not seem to have been taken away.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    /// A slight grow of the glyph while the pointer is on the button — enough to say "yes, this one", not a
    /// bounce. The plate stays put, so the stack does not look like it is moving.
    private static let hoverGlyphScale: CGFloat = 1.12
    private static let glyphScaleDuration: TimeInterval = 0.12
    private var glyphScale: CGFloat = 1
    private var scaleFrom: CGFloat = 1
    private var scaleTimer: Timer?

    /// Where the glyph is in its grow/shrink animation; the self-checks watch it.
    var testing_glyphScale: CGFloat { glyphScale }

    private func animateGlyphScale(to target: CGFloat) {
        scaleTimer?.invalidate()
        scaleTimer = nil
        guard abs(target - glyphScale) > 0.001 else { return }
        let from = glyphScale
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, Date().timeIntervalSince(start) / Self.glyphScaleDuration)
            // Ease-out: quick to answer the pointer, settles instead of stopping dead.
            let eased = 1 - pow(1 - t, 3)
            self.glyphScale = from + (target - from) * eased
            self.needsDisplay = true
            if t >= 1 {
                timer.invalidate()
                self.scaleTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scaleTimer = timer
    }

    init(glyph: Glyph, frame: CGRect = .zero) {
        self.glyph = glyph
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// A pin is usually not the key window, and without this the first click on the button would only
    /// activate the pin — closing it took two clicks.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.35) }
        // The shadow needs a state of its own: it would tint everything drawn after it otherwise.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        shadow.set()
        NSColor.black.withAlphaComponent(hovering || pressed ? 0.72 : 0.55).setFill()
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.cornerRadius,
                                 yRadius: Self.cornerRadius)
        plate.fill()
        NSGraphicsContext.restoreGraphicsState()

        // The active face is the toolbar's own: the theme colour at 18% over the dark chrome, with the glyph
        // drawn in the theme colour (`ChromeButton.draw` does exactly this). Read while drawing, so changing
        // 通用 → 主题色 changes it too.
        if isActive {
            themeColor.withAlphaComponent(0.18).setFill()
            plate.fill()
        }

        // Drawn from the cached 15 pt raster and scaled in the rect: asking `Icon` for every intermediate size
        // would add a cache entry per animation frame.
        let side = Self.iconSize * glyphScale
        let icon = isActive ? Icon.image(glyph.icon, size: Self.iconSize, tint: themeColor) : Icon.whiteImage(glyph.icon, size: Self.iconSize)
        icon.draw(in: CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        animateGlyphScale(to: Self.hoverGlyphScale)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        animateGlyphScale(to: 1)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = false
        needsDisplay = true
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        handler()
    }

    override func resetCursorRects() {
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Does what a click does, for the self-checks (the click itself is covered by `--check pin-close`).
    func testing_press() { handler() }
}

/// Size, color and mosaic options for the active tool or the selected annotation.
final class StyleBarView: PanelView {
    private let stack = NSStackView()
    private var sizeButtons: [(CGFloat, ChromeButton)] = []
    private var colorButtons: [(NSColor, ChromeButton)] = []
    private let sizeLabel = NSTextField(labelWithString: "")
    private var modeButtons: [MosaicMode: ChromeButton] = [:]
    private var effectButtons: [MosaicEffect: ChromeButton] = [:]
    private var shapeButtons: [RectangleMode: ChromeButton] = [:]
    private var penModeButtons: [PenMode: ChromeButton] = [:]
    private var highlighterModeButtons: [HighlighterMode: ChromeButton] = [:]
    private var highlighterBlendButtons: [HighlighterBlend: ChromeButton] = [:]
    /// 识别内容's 识别文字 / 扫码 buttons; empty for every actual tool.
    private var textReadingButtons: [TextReadingMode: ChromeButton] = [:]
    private var highlighterSlider: NSSlider?
    private let highlighterLabel = NSTextField(labelWithString: "")
    private var highlightShapeButtons: [Bool: ChromeButton] = [:]
    private var highlightSlider: NSSlider?
    private let highlightLabel = NSTextField(labelWithString: "")
    private var mosaicSlider: NSSlider?
    private let mosaicLabel = NSTextField(labelWithString: "")
    private var customButton: ChromeButton?
    private var dashButtons: [DashStyle: ChromeButton] = [:]
    private var headButtons: [ArrowHead: ChromeButton] = [:]
    private var textButtons: [TextDecoration: ChromeButton] = [:]
    /// The bin at the end of the bar while an annotation is selected; nil otherwise. The self-check reads it.
    var testing_deleteButton: ChromeButton? { deleteButton }
    private var roundedButton: ChromeButton?
    private var deleteButton: ChromeButton?
    /// Whether the last rebuild had the bin: selecting an annotation of the already-active tool changes nothing
    /// else, so this is the one thing that has to be compared to put the bin up and take it down.
    private var configuredCanDelete = false
    private let handler: (StyleAction) -> Void
    private(set) var configuredTool: Tool?
    private var configuredMode: MosaicMode?
    /// The mosaic effect the row was built for: 智能擦除 has no strength slider, so switching to or away from it
    /// has to rebuild the controls.
    private var configuredEffect: MosaicEffect?
    /// Whether the 形状 row was built for a rectangle or a circle: the circle has no rounded-corner button, so
    /// that switch has to rebuild the row too.
    private var configuredShapeEllipse: Bool?
    /// The pen's sub-tool and the highlighter's stroke mode, for the same reason: each changes the controls.
    private var configuredPenMode: PenMode?
    private var configuredHighlighterMode: HighlighterMode?
    /// Which reading of 识别内容 the row was built for. Both have one button, so switching only changes which is
    /// tinted — but the row is built from nothing for this action, so the state has to be compared too.
    private var configuredTextReadingMode: TextReadingMode?

    /// A short card for the mosaic effects, the same `HoverCardView` the toolbar uses. The style bar's other
    /// buttons keep their system tooltips; these three got a card because the icons alone do not say what
    /// 智能擦除 does — and a system tooltip is not reliable over the capture overlay (see the translation bar).
    let hoverCard = HoverCardView()
    private weak var hintButton: ChromeButton?
    private var hint: (title: String, note: String)?
    private var showHintWork: DispatchWorkItem?
    private var hideHintWork: DispatchWorkItem?

    init(handler: @escaping (StyleAction) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        addSubview(stack)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .center
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        highlightLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        highlightLabel.textColor = .secondaryLabelColor
        highlightLabel.alignment = .right
        highlightLabel.translatesAutoresizingMaskIntoConstraints = false
        highlightLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
        mosaicLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        mosaicLabel.textColor = .secondaryLabelColor
        mosaicLabel.alignment = .right
        mosaicLabel.translatesAutoresizingMaskIntoConstraints = false
        mosaicLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
        highlighterLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        highlighterLabel.textColor = .secondaryLabelColor
        highlighterLabel.alignment = .right
        highlighterLabel.translatesAutoresizingMaskIntoConstraints = false
        highlighterLabel.widthAnchor.constraint(equalToConstant: 34).isActive = true
        hoverCard.onHover = { [weak self] inside in
            if inside { self?.hideHintWork?.cancel() } else { self?.scheduleHintHide() }
        }
    }

    @objc private func opacitySliderChanged(_ sender: NSSlider) {
        handler(.highlightOpacity(CGFloat(sender.doubleValue)))
    }

    @objc private func mosaicSliderChanged(_ sender: NSSlider) {
        handler(.mosaicStrength(CGFloat(sender.doubleValue)))
    }

    @objc private func highlighterSliderChanged(_ sender: NSSlider) {
        handler(.highlighterWidth(CGFloat(sender.doubleValue)))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds the controls when the tool (or a sub-mode / blend-changing mode) changes, otherwise just
    /// refreshes state.
    func configure(_ state: StyleState) {
        guard configuredTool != state.tool
            || configuredCanDelete != state.canDelete
            || (state.tool == nil && configuredTextReadingMode != state.textReadingMode)
            || (state.tool == .mosaic && (configuredMode != state.mosaicMode || configuredEffect != state.mosaicEffect))
            || (state.tool == .rectangle && configuredShapeEllipse != state.shapeEllipse)
            || (state.tool == .pen && (configuredPenMode != state.penMode
                || (state.penMode == .highlighter && configuredHighlighterMode != state.highlighterMode))) else {
            update(state)
            return
        }
        // The controls are about to be replaced; a card pointing at one of them is stale.
        cancelHintShow()
        hideHintWork?.cancel()
        hoverCard.hide()
        configuredTool = state.tool
        configuredCanDelete = state.canDelete
        configuredMode = state.mosaicMode
        configuredEffect = state.mosaicEffect
        configuredShapeEllipse = state.shapeEllipse
        configuredPenMode = state.penMode
        configuredHighlighterMode = state.highlighterMode
        configuredTextReadingMode = state.textReadingMode
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sizeButtons = []
        colorButtons = []
        modeButtons = [:]
        effectButtons = [:]
        shapeButtons = [:]
        penModeButtons = [:]
        highlighterModeButtons = [:]
        highlighterBlendButtons = [:]
        textReadingButtons = [:]
        highlighterSlider = nil
        highlightShapeButtons = [:]
        highlightSlider = nil
        mosaicSlider = nil
        customButton = nil
        dashButtons = [:]
        headButtons = [:]
        textButtons = [:]
        roundedButton = nil
        deleteButton = nil

        if state.tool == nil {
            // 识别内容's row is only these two buttons: it has no colour, width or style of its own, because it
            // does not draw. 识别文字 first — it is what the toolbar button has always done and what most people
            // press it for — and 扫码 beside it, exactly like 形状 / 画笔 / 打码 put their sub-modes on the left.
            for (mode, asset, title, note) in [(TextReadingMode.text, Icon.Asset.scanText, "识别文字", TextReadingMode.text.note),
                                                (.scan, .qrCode, "扫码", TextReadingMode.scan.note)] {
                let b = ChromeButton(image: Icon.image(asset, size: 15), tooltip: nil, size: 28) { [unowned self] in
                    self.handler(.textReadingMode(mode))
                }
                attachHint(b, title: title, note: note)
                textReadingButtons[mode] = b
                stack.addArrangedSubview(b)
            }
        } else if state.tool == .highlight {
            // Shape on the left, how opaque the mask is on the right; a highlight has no color or size of its own.
            for (ellipse, asset, tip) in [(false, Icon.Asset.square, "矩形高亮"), (true, .circle, "椭圆高亮")] {
                let b = ChromeButton(image: Icon.image(asset, size: 15), tooltip: tip, size: 28) { [unowned self] in
                    self.handler(.highlightEllipse(ellipse))
                }
                highlightShapeButtons[ellipse] = b
                stack.addArrangedSubview(b)
            }
            stack.addArrangedSubview(separator(height: 16))
            let slider = NSSlider(value: Double(state.highlightOpacity), minValue: 0.1, maxValue: 1,
                                  target: self, action: #selector(opacitySliderChanged))
            slider.isContinuous = true
            slider.controlSize = .small
            // The track on the filled side follows the theme; the knob is drawn by AppKit in the system accent
            // and cannot be recoloured.
            slider.trackFillColor = themeColor
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 76).isActive = true
            highlightSlider = slider
            stack.addArrangedSubview(slider)
            stack.addArrangedSubview(highlightLabel)
        } else if state.tool == .pen {
            // 画笔: the pencil it has always been, or a highlighter. The highlighter has its own stroke modes,
            // width, colours and blend, so the pencil's size / dash / palette step aside.
            for (mode, asset, title, note) in [(PenMode.pencil, Icon.Asset.pencilSimple, "铅笔", "自由画线"),
                                                (.highlighter, .highlighter, "荧光笔", "像记号笔一样盖上一层颜色")] {
                let b = ChromeButton(image: Icon.image(asset, size: 15), tooltip: nil, size: 28) { [unowned self] in self.handler(.penMode(mode)) }
                attachHint(b, title: title, note: note)
                penModeButtons[mode] = b
                stack.addArrangedSubview(b)
            }
            stack.addArrangedSubview(separator(height: 16))
            if state.penMode == .pencil {
                addSizeButtons(.pen)
                addOptionButtons(.pen, shapeEllipse: false)
                stack.addArrangedSubview(separator(height: 16))
                addColorButtons()
            } else {
                for (mode, image, title, note) in [(HighlighterMode.rect, OptionIcon.highlighterRect(), "矩形", "拖一个直角范围，整块盖上荧光色"),
                                                    (.line, OptionIcon.highlighterLine(), "线条", "拖一条胶囊形状的荧光笔迹")] {
                    let b = ChromeButton(image: image, tooltip: nil, size: 28) { [unowned self] in self.handler(.highlighterMode(mode)) }
                    attachHint(b, title: title, note: note)
                    highlighterModeButtons[mode] = b
                    stack.addArrangedSubview(b)
                }
                if state.highlighterMode == .line {
                    stack.addArrangedSubview(separator(height: 16))
                    let slider = NSSlider(value: Double(state.size), minValue: 1, maxValue: 50,
                                          target: self, action: #selector(highlighterSliderChanged))
                    slider.isContinuous = true
                    slider.controlSize = .small
                    slider.trackFillColor = themeColor
                    slider.translatesAutoresizingMaskIntoConstraints = false
                    slider.widthAnchor.constraint(equalToConstant: 76).isActive = true
                    highlighterSlider = slider
                    stack.addArrangedSubview(slider)
                    stack.addArrangedSubview(highlighterLabel)
                }
                stack.addArrangedSubview(separator(height: 16))
                addColorButtons(StyleMemory.highlighterPalette)
                stack.addArrangedSubview(separator(height: 16))
                for (blend, title, note) in [(HighlighterBlend.multiply, "正片叠底", "像真的荧光笔：压住底色，文字仍然清楚"),
                                              (.translucent, "半透明", "更轻的一层颜色，适合深色画面")] {
                    let b = ChromeButton(image: OptionIcon.blend(blend), tooltip: nil, size: 28) { [unowned self] in self.handler(.highlighterBlend(blend)) }
                    attachHint(b, title: title, note: note)
                    highlighterBlendButtons[blend] = b
                    stack.addArrangedSubview(b)
                }
            }
        } else if state.tool == .rectangle {
            // 形状: rectangle or circle first, exactly like the mosaic tool's two modes. The circle keeps the
            // same colour, width, dash and size presets — it only loses the rounded-corner option. The hint is
            // the title alone: 「矩形」 and 「圆形」 say everything.
            for (mode, asset, title) in [(RectangleMode.rect, Icon.Asset.square, "矩形"),
                                          (.ellipse, .circle, "圆形")] {
                let b = ChromeButton(image: Icon.image(asset, size: 15), tooltip: nil, size: 28) { [unowned self] in self.handler(.shapeMode(mode)) }
                attachHint(b, title: title, note: "")
                shapeButtons[mode] = b
                stack.addArrangedSubview(b)
            }
            stack.addArrangedSubview(separator(height: 16))
            if let tool = state.tool {
                addSizeButtons(tool)
                addOptionButtons(tool, shapeEllipse: state.shapeEllipse)
            }
            stack.addArrangedSubview(separator(height: 16))
            addColorButtons()
        } else if state.tool == .mosaic {
            // The effect comes first and is the tool's face: the toolbar icon follows it (像素块 / 模糊 /
            // 智能擦除), the same way 形状 and 画笔 change theirs. Brush / rectangle below is only how the ink
            // is laid down.
            for (effect, asset, title, note) in [(MosaicEffect.pixelate, Icon.Asset.checkerboard, "像素块", "把这块打成马赛克格子"),
                                                  (.blur, .drop, "模糊", "把这块糊掉，看不出原来的字"),
                                                  (.erase, .eraser, "智能擦除", "用周围的像素把这块补上，像那里本来就没有内容")] {
                // No system tooltip: it would show up late (or not at all above the overlay), after this card.
                let b = ChromeButton(image: Icon.image(asset, size: 15), tooltip: nil, size: 28) { [unowned self] in self.handler(.mosaicEffect(effect)) }
                attachHint(b, title: title, note: note)
                effectButtons[effect] = b
                stack.addArrangedSubview(b)
            }
            stack.addArrangedSubview(separator(height: 16))
            for (mode, asset, title, note) in [(MosaicMode.brush, Icon.Asset.paintBrush, "画笔涂抹", "按住拖过要去掉的地方"),
                                                (.rect, .selection, "框选区域", "拖一个框整块盖住"),
                                                (.auto, .autoMask, "自动识别", "点一下，相同的内容一起打码")] {
                let b = ChromeButton(image: Icon.image(asset, size: 15), tooltip: nil, size: 28) { [unowned self] in self.handler(.mosaicMode(mode)) }
                attachHint(b, title: title, note: note)
                modeButtons[mode] = b
                stack.addArrangedSubview(b)
            }
            // How coarse it is. Both modes get it — the brush has a width of its own to pick, the rectangle has
            // nothing else at all. The range leans fine on purpose: 1× is what the tool has always drawn, and
            // that is already more mosaic than most people want, so the useful half of the travel is below it.
            // Not lower than 0.2 either — under that the cell is thinner than a point and the bottom of the
            // slider is a stretch where nothing visibly changes.
            // 智能擦除没有强度：补出来的样子由模型和周围像素决定，摆一条滑条只会让人以为能调。
            if state.mosaicEffect != .erase {
                stack.addArrangedSubview(separator(height: 16))
                let slider = NSSlider(value: Double(state.mosaicStrength), minValue: 0.2, maxValue: 2,
                                      target: self, action: #selector(mosaicSliderChanged))
                slider.isContinuous = true
                slider.controlSize = .small
                slider.trackFillColor = themeColor
                slider.translatesAutoresizingMaskIntoConstraints = false
                slider.widthAnchor.constraint(equalToConstant: 76).isActive = true
                mosaicSlider = slider
                stack.addArrangedSubview(slider)
                stack.addArrangedSubview(mosaicLabel)
            }
            if state.mosaicMode == .brush, let tool = state.tool {
                stack.addArrangedSubview(separator(height: 16))
                addSizeButtons(tool)
            }
        } else if let tool = state.tool {
            addSizeButtons(tool)
            addOptionButtons(tool, shapeEllipse: false)
            stack.addArrangedSubview(separator(height: 16))
            addColorButtons()
        }
        // 删除 sits at the far right and only while something is selected: it is the one control here that
        // changes the picture instead of the next stroke, and it is the visible half of the ⌫ that used to be
        // the only way to do it.
        if state.canDelete {
            stack.addArrangedSubview(separator(height: 16))
            let b = ChromeButton(image: Icon.image(.trash, size: 15), tooltip: nil, size: 28) { [unowned self] in
                self.handler(.delete)
            }
            attachHint(b, title: "删除", note: "也可以按退格键")
            deleteButton = b
            stack.addArrangedSubview(b)
        }
        update(state)

        stack.layoutSubtreeIfNeeded()
        let content = stack.fittingSize
        let caretSize = caret == nil ? 0 : PanelView.caretHeight
        let sideways = caret.map { !$0.edge.isVertical } ?? false
        setFrameSize(CGSize(width: content.width + 16 + (sideways ? caretSize : 0), height: content.height + 8 + (sideways ? 0 : caretSize)))
        layoutStack()
    }

    /// Line style, arrowheads, rounded corners or text decoration, depending on the tool.
    private func addOptionButtons(_ tool: Tool, shapeEllipse: Bool) {
        func add(_ image: NSImage, _ tip: String, _ change: @escaping (inout ItemStyle) -> Void) -> ChromeButton {
            let b = ChromeButton(image: image, tooltip: tip, size: 26) { [unowned self] in self.handler(.options(change)) }
            stack.addArrangedSubview(b)
            return b
        }
        if tool == .arrow {
            stack.addArrangedSubview(separator(height: 16))
            for (head, tip) in [(ArrowHead.tapered, "实心箭头"), (.open, "线条箭头"), (.double, "双向箭头")] {
                headButtons[head] = add(OptionIcon.arrow(head), tip) { $0.arrowHead = head }
            }
        }
        if [.rectangle, .arrow, .pen].contains(tool) {
            stack.addArrangedSubview(separator(height: 16))
            for (dash, tip) in [(DashStyle.solid, "实线"), (.dashed, "虚线"), (.dotted, "点线")] {
                dashButtons[dash] = add(OptionIcon.dash(dash), tip) { $0.dash = dash }
            }
        }
        // A circle cannot be rounded: there is no corner to round, so the 形状 tool only offers this for the
        // rectangle.
        if tool == .rectangle, !shapeEllipse {
            roundedButton = add(OptionIcon.rounded(true), "圆角矩形") { $0.rounded.toggle() }
        }
        if tool == .text {
            stack.addArrangedSubview(separator(height: 16))
            for (decoration, tip) in [(TextDecoration.plain, "普通文字"), (.background, "文字加底色"), (.outline, "文字描边")] {
                textButtons[decoration] = add(OptionIcon.text(decoration), tip) { $0.text = decoration }
            }
        }
    }

    /// Colour swatches and the custom-colour well; the palette is the tool's own (the highlighter has its own).
    private func addColorButtons(_ palette: [NSColor] = StyleState.palette) {
        for color in palette {
            let b = ChromeButton(image: swatch(color), tooltip: "颜色", size: 24) { [unowned self] in self.handler(.color(color)) }
            colorButtons.append((color, b))
            stack.addArrangedSubview(b)
        }
        let custom = ChromeButton(image: rainbowSwatch(), tooltip: "自定义颜色", size: 24) { [unowned self] in self.handler(.customColor) }
        customButton = custom
        stack.addArrangedSubview(custom)
    }

    private func addSizeButtons(_ tool: Tool) {
        for (i, value) in tool.sizePresets.enumerated() {
            let dot = CGFloat([4, 7, 11][i])
            let image = NSImage(size: CGSize(width: 14, height: 14), flipped: false) { _ in
                NSColor.black.setFill()
                NSBezierPath(ovalIn: CGRect(x: (14 - dot) / 2, y: (14 - dot) / 2, width: dot, height: dot)).fill()
                return true
            }
            image.isTemplate = true
            let b = ChromeButton(image: image, tooltip: ["小", "中", "大"][i] + "（滚轮可微调）", size: 26) { [unowned self] in self.handler(.size(value)) }
            sizeButtons.append((value, b))
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(sizeLabel)
    }

    /// The mosaic strength slider, for `--check mosaic-strength` — nil whenever the tool on show has no such
    /// control, which is most of them.
    var testing_mosaicSlider: NSSlider? { mosaicSlider }
    /// The three mosaic effect buttons; `--check mosaic-hints` drives their `onHover` callbacks.
    var testing_effectButtons: [MosaicEffect: ChromeButton] { effectButtons }
    /// The two mosaic mode buttons (画笔 / 框选), for the same check.
    var testing_modeButtons: [MosaicMode: ChromeButton] { modeButtons }
    /// The 形状 tool's rectangle / circle buttons, for `--check shape-tool`.
    var testing_shapeButtons: [RectangleMode: ChromeButton] { shapeButtons }
    /// 识别内容's two readings, for `--check scan-code`.
    var testing_textReadingButtons: [TextReadingMode: ChromeButton] { textReadingButtons }
    /// The pen's sub-tools and the highlighter's controls, for `--check highlighter`.
    var testing_penModeButtons: [PenMode: ChromeButton] { penModeButtons }
    var testing_highlighterModeButtons: [HighlighterMode: ChromeButton] { highlighterModeButtons }
    var testing_highlighterBlendButtons: [HighlighterBlend: ChromeButton] { highlighterBlendButtons }
    var testing_highlighterSlider: NSSlider? { highlighterSlider }
    var testing_highlighterLabel: String { highlighterLabel.stringValue }
    /// The swatches currently on the bar (the pencil's or the highlighter's palette) and the custom-colour well.
    var testing_colorButtons: [(NSColor, ChromeButton)] { colorButtons }
    var testing_customColorButton: ChromeButton? { customButton }
    /// The rounded-corner button: present for a rectangle, absent for a circle.
    var testing_roundedButton: ChromeButton? { roundedButton }
    /// What the style bar's hint card is saying, or nil while it is hidden.
    var testing_hint: (title: String, note: String)? { hoverCard.isHidden ? nil : hoverCard.testing_text }

    // MARK: - Mosaic effect hints

    /// One helper for every button in this bar that has a hint card, so they cannot drift apart.
    private func attachHint(_ button: ChromeButton, title: String, note: String) {
        button.onHover = { [weak self, weak button] inside in
            guard let self, let button else { return }
            if inside { self.scheduleHint((title, note), from: button) } else { self.scheduleHintHide() }
        }
    }

    /// Shows after a short rest on the button, at the same speed as the toolbar's card — sweeping across the
    /// bar shows nothing.
    private func scheduleHint(_ hint: (title: String, note: String), from button: ChromeButton) {
        cancelHintShow()
        hideHintWork?.cancel()
        hintButton = button
        self.hint = hint
        // Once a card is up, moving to the next effect switches it at once.
        if !hoverCard.isHidden { showHint(); return }
        let work = DispatchWorkItem { [weak self] in self?.showHint() }
        showHintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HoverCardTiming.reveal, execute: work)
    }

    private func showHint() {
        guard !isHidden, superview != nil, let hint else { return }
        cancelHintShow()
        hoverCard.configure(title: hint.title, shortcut: "", editable: false, note: hint.note)
        hoverCard.isHidden = false
        placeHint()
    }

    /// Leaves time to move from the button onto the card.
    private func scheduleHintHide() {
        cancelHintShow()
        hideHintWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hoverCard.hide() }
        hideHintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + HoverCardTiming.hideGrace, execute: work)
    }

    private func cancelHintShow() {
        showHintWork?.cancel()
        showHintWork = nil
    }

    /// Puts the card on the side of the style bar away from the toolbar. The style bar sits below the toolbar
    /// in most layouts, but a selection near the bottom of the screen turns that around — and the card must
    /// not land on the toolbar's buttons.
    private func placeHint() {
        guard let container = superview, let button = hintButton else { return }
        let size = hoverCard.frame.size
        let b = button.convert(button.bounds, to: container)
        let bounds = container.bounds
        let toolbar = container.subviews.compactMap { $0 as? ToolbarView }.first
        let toolbarIsBelow = toolbar.map { $0.frame.midY >= frame.midY } ?? false
        var origin = CGPoint(x: b.midX - size.width / 2,
                             y: toolbarIsBelow ? frame.minY - 8 - size.height : frame.maxY + 8)
        if origin.y < 4 { origin.y = frame.maxY + 8 }
        if origin.y + size.height > bounds.maxY - 4 { origin.y = frame.minY - 8 - size.height }
        origin.x = min(max(4, origin.x), bounds.maxX - size.width - 4)
        origin.y = min(max(4, origin.y), bounds.maxY - size.height - 4)
        hoverCard.setFrameOrigin(origin)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hoverCard.removeFromSuperview()
        superview?.addSubview(hoverCard)
    }

    override var isHidden: Bool {
        didSet {
            if isHidden {
                cancelHintShow()
                hideHintWork?.cancel()
                hoverCard.hide()
            }
        }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        if newOrigin != frame.origin {
            cancelHintShow()
            hoverCard.hide()
        }
        super.setFrameOrigin(newOrigin)
    }

    func update(_ state: StyleState) {
        sizeLabel.stringValue = "\(Int(state.size.rounded()))"
        for (value, b) in sizeButtons { b.isActive = abs(value - state.size) < 0.5 }
        var matched = false
        for (color, b) in colorButtons {
            b.isActive = color.isApproximately(state.color)
            matched = matched || b.isActive
        }
        customButton?.isActive = !matched
        for (dash, b) in dashButtons { b.isActive = dash == state.options.dash }
        for (head, b) in headButtons { b.isActive = head == state.options.arrowHead }
        for (decoration, b) in textButtons { b.isActive = decoration == state.options.text }
        roundedButton?.isActive = state.options.rounded
        for (mode, b) in modeButtons { b.isActive = mode == state.mosaicMode }
        for (effect, b) in effectButtons { b.isActive = effect == state.mosaicEffect }
        for (mode, b) in shapeButtons { b.isActive = (mode == .ellipse) == state.shapeEllipse }
        for (mode, b) in textReadingButtons { b.isActive = mode == state.textReadingMode }
        for (mode, b) in penModeButtons { b.isActive = mode == state.penMode }
        for (mode, b) in highlighterModeButtons { b.isActive = mode == state.highlighterMode }
        for (blend, b) in highlighterBlendButtons { b.isActive = blend == state.highlighterBlend }
        highlighterSlider?.doubleValue = Double(state.size)
        highlighterLabel.stringValue = "\(Int(state.size.rounded()))"
        for (ellipse, b) in highlightShapeButtons { b.isActive = ellipse == state.highlightEllipse }
        highlightSlider?.doubleValue = Double(state.highlightOpacity)
        highlightLabel.stringValue = "\(Int((state.highlightOpacity * 100).rounded()))%"
        mosaicSlider?.doubleValue = Double(state.mosaicStrength)
        mosaicLabel.stringValue = String(format: "%.1f×", state.mosaicStrength)
    }

    override func caretDidChange() {
        layoutStack()
    }

    private func layoutStack() {
        let r = contentRect.insetBy(dx: 8, dy: 4)
        // Not sized yet (the caret can be set before the first configure).
        guard r.width > 0, r.height > 0 else { return }
        stack.frame = r
    }

    private func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill()
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            path.fill()
            NSColor.gray.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }

    private func rainbowSwatch() -> NSImage {
        NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
            let gradient = NSGradient(colors: [.systemRed, .systemYellow, .systemGreen, .systemBlue, .systemPurple])
            gradient?.draw(in: NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)), angle: 45)
            return true
        }
    }
}

extension NSColor {
    func isApproximately(_ other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }
}

/// 「中文 ⇄ English」: which way the translation goes. Each side is a picker and the arrow in the middle
/// swaps them.
///
/// The two sides used to be plain labels with only the arrow to press, which meant the bar could say the
/// screen was Japanese and there was no way to tell it otherwise — the arrow can only flip the guess, not name
/// the language. Now each side opens a list (the capture overlay cannot use `NSMenu`; see `EngineMenuView`).
final class DirectionControl: NSView {
    var onSwap: (() -> Void)?
    /// The source side was clicked; the bar opens its language list under it.
    var onPickSource: (() -> Void)?
    /// The same for the target side.
    var onPickTarget: (() -> Void)?

    /// White on the dark capture panels, `.labelColor` in a window.
    var tint: NSColor = .white { didSet { applyTint() } }

    private lazy var sourceButton = DirectionControl.makeChip { [weak self] in self?.onPickSource?() }
    private lazy var targetButton = DirectionControl.makeChip { [weak self] in self?.onPickTarget?() }
    private lazy var swapButton = ChromeButton(image: Icon.image(.swap, size: 14), tooltip: "对调翻译方向",
                                               size: DirectionControl.buttonSize) { [weak self] in self?.onSwap?() }

    private static let buttonSize: CGFloat = 22
    private static let gap: CGFloat = 6
    private static let height: CGFloat = 24

    /// A language name that opens a list: the caret is what says so, the same way the engine chip says it.
    private static func makeChip(_ handler: @escaping () -> Void) -> ChromeTextButton {
        let button = ChromeTextButton(title: "", handler: handler)
        button.translatesAutoresizingMaskIntoConstraints = true
        button.image = Icon.image(.caretDown, size: 9)
        button.imagePosition = .imageTrailing
        button.imageScaling = .scaleNone
        return button
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Fixed frames, not Auto Layout: the capture bar sizes itself by hand, and this has to fit both.
        sourceButton.translatesAutoresizingMaskIntoConstraints = true
        swapButton.translatesAutoresizingMaskIntoConstraints = true
        targetButton.translatesAutoresizingMaskIntoConstraints = true
        sourceButton.toolTip = "原文语言"
        targetButton.toolTip = "译文语言"
        addSubview(sourceButton)
        addSubview(swapButton)
        addSubview(targetButton)
        applyTint()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyTint() {
        sourceButton.contentTintColor = tint
        targetButton.contentTintColor = tint
        swapButton.tint = tint
    }

    func configure(source: String, target: String) {
        sourceButton.text = source
        targetButton.text = target
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(sourceButton.fittingSize.width + Self.gap + Self.buttonSize + Self.gap
                           + targetButton.fittingSize.width),
               height: Self.height)
    }

    override func layout() {
        super.layout()
        let source = sourceButton.fittingSize, target = targetButton.fittingSize
        var x: CGFloat = 0
        let y = ((bounds.height - source.height) / 2).rounded()
        sourceButton.frame = CGRect(x: x, y: y, width: source.width, height: source.height)
        x += source.width + Self.gap
        swapButton.frame = CGRect(x: x, y: ((bounds.height - Self.buttonSize) / 2).rounded(),
                                  width: Self.buttonSize, height: Self.buttonSize)
        x += Self.buttonSize + Self.gap
        targetButton.frame = CGRect(x: x, y: y, width: target.width, height: target.height)
    }

    var testing_names: (source: String, target: String) { (sourceButton.title, targetButton.title) }
    /// Where the two pickers are, inside this control, so the bar can hang a list off them.
    var sourceChipFrame: CGRect { sourceButton.frame }
    var targetChipFrame: CGRect { targetButton.frame }
    /// The checks press the sides the way a mouse would.
    func testing_pressSource() { sourceButton.performClick(nil) }
    func testing_pressTarget() { targetButton.performClick(nil) }
    func testing_pressSwap() { swapButton.performClick(nil) }
}

/// One of the size chip's two numbers.
///
/// A control normally ignores the click that activates the window, so a chip over a window that is not key
/// would need two clicks to start editing. The capture overlay is nearly always key, but "nearly" is not a
/// reason to make the first click do nothing.
private final class SizeField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Blue bar above the selection showing its size in points.
///
/// Both numbers are editable. Click one and it selects itself, so the next keystroke replaces it rather than
/// appending to it; type a number and the selection resizes to match, growing or shrinking away from the
/// top-left corner the chip is sitting on, so that corner stays put under the pointer. The region can then be
/// dragged anywhere as usual.
final class TopBarView: PanelView {
    /// The smallest region the chip will ask for. Nobody wants a 1pt selection, and it is not something the
    /// selection handles could be dragged back out of either.
    static let minimumSide: CGFloat = 2
    /// More digits than any display has pixels, so a pasted novel can't get in.
    private static let maximumDigits = 5

    /// The size the two numbers spell out, while they are being typed and again when editing ends.
    var onResize: ((CGSize) -> Void)?
    /// Editing finished, so the capture view can have the keyboard back and the region can be dragged.
    var onEditingEnded: (() -> Void)?

    private let widthField = TopBarView.makeField()
    private let heightField = TopBarView.makeField()
    private let times = TopBarView.makeTimes()
    /// What the selection really is, as opposed to whatever is currently typed over it. Esc puts it back.
    private var shownSize = CGSize.zero
    private var sizeBeforeEditing: CGSize?

    override init(frame: CGRect) {
        super.init(frame: frame)
        radius = 6
        layer?.shadowOpacity = 0
        for field in [widthField, heightField] {
            field.delegate = self
            addSubview(field)
        }
        // Tab goes from one number to the other and back, rather than wandering out of the chip.
        widthField.nextKeyView = heightField
        heightField.nextKeyView = widthField
        addSubview(times)
        setSize(.zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 底色和字色现算，不在构造时算一次存着：主题色能被设置窗口在两块选区之间改掉，存下来的颜色会馊掉
    /// （自检 `--check theme-color` 就是这么发现的）。字色跟着底色走，所以深色主题下数字依然是亮的。
    private func applyTheme() {
        fill = themeColor
        let onFill = ContentRenderer.contrastingTextColor(for: themeColor)
        widthField.textColor = onFill
        heightField.textColor = onFill
        times.textColor = onFill.withAlphaComponent(0.75)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    func setSize(_ size: CGSize) {
        applyTheme()
        shownSize = size
        // Never write over a number being typed: the size echoes back here as the selection changes under it,
        // and the echo would fight the typing.
        if widthField.currentEditor() == nil { widthField.stringValue = "\(Int(size.width.rounded()))" }
        if heightField.currentEditor() == nil { heightField.stringValue = "\(Int(size.height.rounded()))" }
        relayout()
    }

    private static func makeField() -> NSTextField {
        let field = SizeField(string: "0")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        // Dark on the light blue fill; white would be lost on it.
        field.textColor = ContentRenderer.contrastingTextColor(for: themeColor)
        field.alignment = .center
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        return field
    }

    private static func makeTimes() -> NSTextField {
        let label = NSTextField(labelWithString: "×")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = ContentRenderer.contrastingTextColor(for: themeColor).withAlphaComponent(0.75)
        return label
    }

    /// The pill hugs whatever is in it, the way it did when it was one label.
    private func relayout() {
        let height: CGFloat = 24
        let padding: CGFloat = 9
        let gap: CGFloat = 3
        let parts: [(NSView, CGSize)] = [(widthField, measure(widthField)),
                                         (times, times.fittingSize),
                                         (heightField, measure(heightField))]
        setFrameSize(CGSize(width: ceil(parts.reduce(padding * 2) { $0 + $1.1.width } + gap * 2), height: height))
        var x = padding
        for (view, size) in parts {
            view.frame = CGRect(x: x, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + gap
        }
    }

    /// `fittingSize` is no use on a borderless editable field: it comes back four points wide whatever is in
    /// it, so the numbers were being clipped to nothing. Measure the text against its own font instead, plus
    /// a couple of points — the cell draws a shade wider than the advance width, and a clipped last digit
    /// ("80C") is worse than a pill a pixel too wide.
    private func measure(_ field: NSTextField) -> CGSize {
        let size = (field.stringValue as NSString).size(withAttributes: [.font: field.font ?? .systemFont(ofSize: 12)])
        return CGSize(width: ceil(size.width) + 3, height: ceil(size.height))
    }

    /// The size the two numbers spell out, or nil while either of them is unusable.
    private var typedSize: CGSize? {
        guard let width = Int(widthField.stringValue), let height = Int(heightField.stringValue),
              CGFloat(width) >= Self.minimumSide, CGFloat(height) >= Self.minimumSide else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Applies what has been typed so far. A number that is not usable yet — empty, or the lone "1" on the way
    /// to "1000" — is left alone rather than clamped, so the field never argues with the typing.
    private func publish() {
        guard let size = typedSize else { return }
        onResize?(size)
    }

    // MARK: - Testing

    /// Drives a field the way the field editor would, without needing a keyboard.
    func testing_type(_ text: String, intoWidth width: Bool) {
        let field = width ? widthField : heightField
        field.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    func testing_beginEditing() {
        controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: widthField))
    }

    func testing_endEditing(cancelled: Bool = false) {
        let movement: NSTextMovement = cancelled ? .cancel : .return
        controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: widthField,
                                              userInfo: ["NSTextMovement": movement.rawValue]))
    }

    var testing_fields: (width: String, height: String) { (widthField.stringValue, heightField.stringValue) }
}

extension TopBarView: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ notification: Notification) {
        // Select what is there, so the first keystroke replaces the number instead of appending to it.
        (notification.object as? NSTextField)?.currentEditor()?.selectAll(nil)
        sizeBeforeEditing = shownSize
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        // Digits only: these are pixel counts.
        let digits = String(field.stringValue.filter(\.isNumber).prefix(Self.maximumDigits))
        if digits != field.stringValue {
            field.stringValue = digits
            field.currentEditor()?.selectedRange = NSRange(location: digits.count, length: 0)
        }
        relayout()
        publish()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let movement = (notification.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        if movement == .cancel, let before = sizeBeforeEditing {
            onResize?(before)   // Esc: the selection goes back to the size it had before editing started
        } else {
            publish()
        }
        sizeBeforeEditing = nil
        // Either way the numbers end up saying what the selection actually is — an emptied field or a lone
        // "1" left behind would be a lie the user has no way to notice.
        setSize(shownSize)
        onEditingEnded?()
    }
}

/// Borderless text button for the chrome panels: the label is the button, with the same hover wash
/// `ChromeButton` draws behind its icon.
final class ChromeTextButton: NSButton {
    private let handler: () -> Void
    private var hovering = false

    /// Painted in the selection blue, for the one button that is asking to be pressed. It also takes a
    /// little padding of its own, so the pill has room around the label instead of hugging it.
    var isProminent = false {
        didSet {
            guard isProminent != oldValue else { return }
            // The label follows the fill: white on the default light blue is only 1.4:1, and a pale theme colour
            // would swallow it completely.
            contentTintColor = isProminent ? ContentRenderer.contrastingTextColor(for: themeColor) : .white
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private let horizontalPadding: CGFloat = 5

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        guard isProminent else { return size }
        return NSSize(width: size.width + horizontalPadding * 2, height: size.height + 2)
    }

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        font = .systemFont(ofSize: 12, weight: .medium)
        contentTintColor = .white
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }

    /// The label says what clicking does, so it is read as a verb and not as a state.
    var text: String {
        get { title }
        set {
            title = newValue
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isProminent {
            (hovering ? themeColor.blended(withFraction: 0.15, of: .white) ?? themeColor : themeColor).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The 大模型 list, drawn on the capture overlay instead of handed to `NSMenu`.
///
/// A real menu is a window AppKit owns, and it comes up at level 101 — under the capture overlay, which is at
/// `screenSaver` (1000). The click reached the chip and the menu opened; it was simply never visible, which is
/// how「下拉框点不动」gets reported. (The colour panel has the same problem and solves it by asking for
/// `screenSaver + 1`; a menu cannot be asked.) So the list is drawn here, inside the overlay, like the rest of
/// the chrome — and because it is, a self-check can screenshot it and see that it is really there.
///
/// Rows: the engine's name, with a tick in the accent colour on the one in use. One view rather than one view
/// per row, because the rows are a fixed pitch and nothing in them is interactive on its own.
final class EngineMenuView: PanelView {
    static let rowHeight: CGFloat = 24
    private static let tickColumn: CGFloat = 18
    private static let padding = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 11)

    /// The engine at this row is now the one to use.
    var onPick: ((Int) -> Void)?

    private var titles: [String] = []
    private var current = 0
    private var hovered = -1
    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The hover card's fill rather than the bar's: this one has to be read, so it is nearly opaque.
        fill = NSColor(white: 0.16, alpha: 0.96)
        radius = 8
        isHidden = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(titles: [String], current: Int) {
        self.titles = titles
        self.current = current
        hovered = -1
        var width = Self.padding.left + Self.tickColumn + Self.padding.right
        for title in titles {
            width = max(width, Self.padding.left + Self.tickColumn + ceil(textWidth(title)) + Self.padding.right)
        }
        let height = Self.padding.top + CGFloat(titles.count) * Self.rowHeight + Self.padding.bottom
        setFrameSize(CGSize(width: ceil(width), height: ceil(height)))
        needsDisplay = true
    }

    private func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (index, title) in titles.enumerated() {
            let row = rowRect(index)
            if index == hovered {
                NSColor.white.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
            }
            // The tick is the accent colour, the way the toolbar marks the tool in use — read here rather than
            // stored, because the theme can be changed between two captures.
            if index == current {
                let side: CGFloat = 10
                Icon.image(.check, size: side, tint: themeColor)
                    .draw(in: CGRect(x: row.minX + Self.padding.left, y: row.midY - side / 2, width: side, height: side))
            }
            let text = NSAttributedString(string: title, attributes: [
                .font: font,
                .foregroundColor: index == current ? .white : NSColor.white.withAlphaComponent(0.85),
            ])
            let size = text.size()
            text.draw(at: CGPoint(x: row.minX + Self.padding.left + Self.tickColumn, y: row.midY - size.height / 2))
        }
    }

    /// The row at a point, or nil when the point is in the padding.
    func row(at point: CGPoint) -> Int? {
        let y = point.y - Self.padding.top
        guard y >= 0 else { return nil }
        let index = Int(y / Self.rowHeight)
        return titles.indices.contains(index) ? index : nil
    }

    private func rowRect(_ index: Int) -> CGRect {
        CGRect(x: bounds.minX, y: Self.padding.top + CGFloat(index) * Self.rowHeight,
               width: bounds.width, height: Self.rowHeight)
    }

    override func mouseMoved(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil)) ?? -1
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = -1
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = row(at: convert(event.locationInWindow, from: nil)) else { return }
        onPick?(index)
    }

    var testing_rows: (titles: [String], current: Int) { (titles, current) }
    func testing_pick(_ index: Int) { onPick?(index) }
    func testing_hover(_ index: Int) { hovered = index; needsDisplay = true }
}

/// Translation controls, floating above the selection: which way the translation is going, which engine is
/// doing the translating, and whether the picture underneath is showing the translation or the original.
///
/// The direction is a label pair with a swap button between them — `中文 ⇄ English` — rather than a menu,
/// because the two states are all there is and the common move is to flip it back and forth while looking
/// at the result. The button is the arrow in the middle, which is where the eye already is.
///
/// The engine chip and the 重新翻译 button next to it are one group: picking a 大模型 is picking who translates,
/// and the point of picking is to see what it says — the capture view re-translates the moment one is chosen, so
/// the name on the bar is always the name of the engine the text underneath came from.
///
/// Both of them are words, not icons. The bar's other controls are words, and a bare ↻ icon would have to explain
/// itself in a tooltip — which is one of the windows AppKit puts *under* the capture overlay, so it never
/// shows. The button says what it does, and says 正在翻译中… while it is doing it.
final class TranslationBarView: PanelView {
    /// Everything the bar draws. One value rather than eight parameters: the call is read as a description of
    /// what is on screen, which is what it is.
    struct Content {
        var source: String
        var target: String
        var showingOriginal: Bool
        var showsFullText: Bool
        /// Every engine the menu offers — 免费翻译 first, then the saved 大模型 — and which one is in use.
        var engines: [String]
        var engineIndex: Int
        /// A translation is on its way: 重新翻译 says so, and does not take a second press.
        var translating: Bool
    }

    var onSwap: (() -> Void)?
    var onToggleOriginal: (() -> Void)?
    var onShowFullText: (() -> Void)?
    /// The engine chip was clicked: open the list under it. The capture view owns that list — it is a subview
    /// of the overlay, not of the bar, so that a point outside the bar's own frame can still reach a row.
    var onOpenEngineMenu: (() -> Void)?
    var onRetry: (() -> Void)?
    /// One side of the direction control was clicked: open its language list under it.
    var onOpenSourceMenu: (() -> Void)?
    var onOpenTargetMenu: (() -> Void)?

    private let direction = DirectionControl()
    /// The engine in use. Typed as a chip rather than an icon because the name is the answer to "who translated
    /// this?", which is half the reason the control is there at all — the caret is there so it reads as
    /// something that opens.
    private lazy var engineButton: ChromeTextButton = {
        let button = ChromeTextButton(title: "") { [weak self] in self?.onOpenEngineMenu?() }
        button.image = Icon.image(.caretDown, size: 9)
        button.imagePosition = .imageTrailing
        button.imageScaling = .scaleNone
        return button
    }()
    private lazy var retryButton = ChromeTextButton(title: "重新翻译") { [weak self] in self?.onRetry?() }
    private lazy var originalButton = ChromeTextButton(title: "显示原文") { [weak self] in self?.onToggleOriginal?() }
    /// Only there when something had to be cut to fit — nothing was lost, so there is nothing to show.
    /// Blue, because it is the one thing on the bar the user has to notice: without it the rest of the
    /// translation is simply gone, and nothing on screen says so.
    private lazy var fullTextButton: ChromeTextButton = {
        let button = ChromeTextButton(title: "全文") { [weak self] in self?.onShowFullText?() }
        button.isProminent = true
        return button
    }()
    private let stack = NSStackView()
    private var engines: [String] = []
    private var engineIndex = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Same dark fill as the toast: both sit over whatever the user was looking at, and the picture
        // behind them is arbitrary.
        fill = NSColor(white: 0.1, alpha: 0.85)
        radius = 7
        layer?.shadowOpacity = 0.28

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [direction, separator(height: 14), engineButton, retryButton, separator(height: 14),
                     originalButton, fullTextButton] as [NSView] {
            stack.addArrangedSubview(view)
        }
        direction.onSwap = { [weak self] in self?.onSwap?() }
        direction.onPickSource = { [weak self] in self?.onOpenSourceMenu?() }
        direction.onPickTarget = { [weak self] in self?.onOpenTargetMenu?() }
        // Two words that both end in 翻译 with the ordinary 6pt between them read as one run of text; the extra
        // gap is what tells the eye that the second one is a button of its own. The caret already marks the
        // first as the one that opens.
        stack.setCustomSpacing(14, after: engineButton)
        fullTextButton.isHidden = true
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        return label
    }

    func configure(_ content: Content) {
        direction.configure(source: content.source, target: content.target)
        originalButton.text = content.showingOriginal ? "显示译文" : "显示原文"
        fullTextButton.isHidden = !content.showsFullText
        engines = content.engines
        engineIndex = content.engineIndex
        engineButton.text = Self.shortName(engines.indices.contains(engineIndex) ? engines[engineIndex] : "")
        // The button says what it does and, while it is doing it, that it is doing it: a word is the one piece
        // of the chrome that can carry both without a tooltip. It is off while a translation is on its way —
        // pressing again would only throw away the request that is running and start the wait over.
        retryButton.text = content.translating ? "正在翻译中…" : "重新翻译"
        retryButton.isEnabled = !content.translating
        layoutSubtreeIfNeeded()
        setFrameSize(stack.fittingSize)
        stack.frame = bounds
    }

    /// The bar is one row over the picture, so a name the user typed out in full is cut rather than allowed
    /// to stretch it across the screen. A little over a hundred points holds 「公司内部 DeepSeek 网关…」, which
    /// is about as much of a name as anyone needs to know which entry they are on. The menu spells them out.
    private static func shortName(_ name: String, limit: CGFloat = 120) -> String {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        guard width(name) > limit else { return name }
        var text = name
        while !text.isEmpty, width(text + "…") > limit { text.removeLast() }
        return text + "…"
    }

    /// Where the chip is inside this bar, for the capture view to hang the 大模型 list off.
    var engineChipFrame: CGRect { engineButton.frame }
    func testing_pressSource() { direction.testing_pressSource() }
    func testing_pressTarget() { direction.testing_pressTarget() }
    func testing_pressSwap() { direction.testing_pressSwap() }
    /// The same for the two language pickers.
    var sourceChipFrame: CGRect { direction.convert(direction.sourceChipFrame, to: self) }
    var targetChipFrame: CGRect { direction.convert(direction.targetChipFrame, to: self) }

    var testing_text: (source: String, target: String, action: String, hasFullText: Bool) {
        (direction.testing_names.source, direction.testing_names.target, originalButton.title, !fullTextButton.isHidden)
    }

    /// The engine the bar is showing, the whole list behind it, and what the 重新翻译 button says.
    var testing_engine: (shown: String, all: [String], retry: String) {
        (engineButton.title, engines, retryButton.title)
    }

    var testing_retryEnabled: Bool { retryButton.isEnabled }
    /// Where the two controls are, inside this bar, so a check can click them the way a mouse would.
    var testing_engineFrame: CGRect { engineButton.frame }
    var testing_retryFrame: CGRect { retryButton.frame }
    /// What the chip's list would offer, and which row it would tick.
    var testing_menu: (titles: [String], checked: Int) { (engines, engineIndex) }
    func testing_pressRetry() {
        guard retryButton.isEnabled else { return }
        retryButton.performClick(nil)
    }
}

/// Short status message.
final class ToastView: PanelView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        fill = NSColor(white: 0.1, alpha: 0.85)
        radius = 7
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.maximumNumberOfLines = 4
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    /// `duration` nil keeps the message until the next one.
    func show(_ text: String, duration: TimeInterval? = 2.5, maxWidth: CGFloat) {
        hideWork?.cancel()
        label.stringValue = text
        label.preferredMaxLayoutWidth = min(380, max(120, maxWidth - 24))
        let size = label.fittingSize
        label.frame = CGRect(x: 12, y: 7, width: size.width, height: size.height)
        setFrameSize(CGSize(width: size.width + 24, height: size.height + 14))
        isHidden = false
        alphaValue = 1
        if let duration {
            let work = DispatchWorkItem { [weak self] in
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    self?.animator().alphaValue = 0
                }, completionHandler: { self?.isHidden = true })
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        isHidden = true
    }
}

/// The complete translation of every block that had to be cut down to fit, next to the selection.
///
/// A translation is not allowed past the edge of the selection: 复制 / 保存 / 贴图 all render exactly the
/// selection and nothing outside it, so text that spilled over would be visible on screen and missing from
/// the picture the user actually keeps. When it genuinely does not fit — an English translation of a small
/// Chinese block is the usual case — the rest of it lands here instead of being lost to an ellipsis.
final class TranslationPanelView: PanelView {
    private let textView = NSTextView(frame: .zero)
    private let scroll = NSScrollView()
    private let title = NSTextField(labelWithString: "完整译文")
    private let copyButton = NSButton(title: "复制译文", target: nil, action: nil)
    private var closeButton: ChromeButton!
    /// Just the translations, for the copy button.
    private var translations: [String] = []

    init(onClose: @escaping () -> Void) {
        super.init(frame: CGRect(x: 0, y: 0, width: 340, height: 240))
        radius = 12

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = CGRect(x: 14, y: 11, width: 260, height: 18)
        addSubview(title)

        closeButton = ChromeButton(image: Icon.image(.xmark, size: 12), tooltip: "关闭", size: 22, handler: onClose)
        closeButton.translatesAutoresizingMaskIntoConstraints = true
        closeButton.frame = CGRect(x: 340 - 32, y: 9, width: 22, height: 22)
        addSubview(closeButton)

        textView.isEditable = false
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = CGSize(width: 4, height: 6)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 7
        addSubview(scroll)

        copyButton.bezelStyle = .push
        copyButton.target = self
        copyButton.action = #selector(copyTranslations)
        addSubview(copyButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `blocks` are the ones that were cut, as (what was on screen, the whole translation).
    func show(_ blocks: [(original: String, translation: String)]) {
        translations = blocks.map(\.translation)
        title.stringValue = blocks.count == 1 ? "完整译文" : "完整译文 · \(blocks.count) 段"

        let body = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { body.append(NSAttributedString(string: "\n\n")) }
            // The original's first line, dimmed, as a label for which block this is.
            let original = block.original.split(separator: "\n").first.map(String.init) ?? block.original
            body.append(NSAttributedString(string: original + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            body.append(NSAttributedString(string: block.translation, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]))
        }
        textView.textStorage?.setAttributedString(body)
        copyButton.title = "复制译文"

        // Tall enough for what is in it, within reason; the rest scrolls. The text view's own insets and a
        // couple of points of slack are on top of the measured height, or the last line comes out clipped.
        let textWidth: CGFloat = 340 - 24 - 8
        let measured = ceil(body.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin]).height)
        let scrollHeight = min(max(90, measured + 20), 300)
        let height = 38 + scrollHeight + 44
        setFrameSize(CGSize(width: 340, height: height))
        scroll.frame = CGRect(x: 12, y: 38, width: 340 - 24, height: scrollHeight)
        copyButton.frame = CGRect(x: 340 - 12 - 90, y: height - 36, width: 90, height: 28)
        closeButton.frame = CGRect(x: 340 - 32, y: 9, width: 22, height: 22)
    }

    @objc private func copyTranslations() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translations.joined(separator: "\n\n"), forType: .string)
        copyButton.title = "已复制"
    }

    var testing_text: String { textView.string }
}

/// Editable OCR result next to the selection.
final class OCRPanelView: PanelView {
    let textView: NSTextView
    private let scroll = NSScrollView()
    private let title = NSTextField(labelWithString: "识别结果")
    private static let copyTitle = "复制 (C)"
    private let copyButton = NSButton(title: copyTitle, target: nil, action: nil)
    private var closeButton: ChromeButton!
    private var resetWork: DispatchWorkItem?

    init(onClose: @escaping () -> Void) {
        textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        super.init(frame: CGRect(x: 0, y: 0, width: 340, height: 262))
        radius = 12

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = CGRect(x: 14, y: 11, width: 260, height: 18)
        addSubview(title)

        closeButton = ChromeButton(image: Icon.image(.xmark, size: 12), tooltip: "关闭", size: 22, handler: onClose)
        closeButton.translatesAutoresizingMaskIntoConstraints = true
        closeButton.frame = CGRect(x: 340 - 32, y: 9, width: 22, height: 22)
        addSubview(closeButton)

        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = CGSize(width: 4, height: 6)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 7
        scroll.frame = CGRect(x: 12, y: 38, width: 316, height: 178)
        addSubview(scroll)

        copyButton.bezelStyle = .push
        copyButton.frame = CGRect(x: 340 - 12 - 90, y: 224, width: 90, height: 28)
        copyButton.target = self
        copyButton.action = #selector(copyText)
        addSubview(copyButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(text: String, lineCount: Int) {
        textView.string = text
        title.stringValue = "识别结果 · \(lineCount) 行"
        resetWork?.cancel()
        copyButton.title = Self.copyTitle
    }

    @objc func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        flashCopied()
    }

    private func flashCopied() {
        copyButton.title = "已复制 ✓"
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.copyButton.title = Self.copyTitle }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

/// One payload in 扫码's list: the code, and — once the pointer is on the row — 复制 and, for a link, 访问.
/// The two buttons are laid out all the time and only hidden, so hovering never reflows the text.
final class ScanResultRow: NSView {
    static let height: CGFloat = 36
    private static let actionWidth: CGFloat = 40
    private static let actionGap: CGFloat = 2
    private static let inset: CGFloat = 8
    let code: String
    private let url: URL?
    private let label = NSTextField(labelWithString: "")
    private lazy var copyButton = ChromeTextButton(title: "复制") { [weak self] in self?.copyCode() }
    private lazy var visitButton: ChromeTextButton? = url.map { url in
        ChromeTextButton(title: "访问") { [weak self] in self?.onOpen?(url) }
    }
    var onOpen: ((URL) -> Void)?
    private var hovering = false { didSet { updateActions() } }
    private var resetWork: DispatchWorkItem?

    init(code: String) {
        self.code = code
        self.url = Self.link(code)
        super.init(frame: .zero)
        label.stringValue = code
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        var buttons = [copyButton]
        if let visitButton { buttons.append(visitButton) }
        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = true
            button.contentTintColor = .secondaryLabelColor
            button.isHidden = true
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    var hasLink: Bool { url != nil }
    var actionsVisible: Bool { !copyButton.isHidden }

    /// In the pinned window the row is a handle too — the text there is not selectable, so dragging it moves the
    /// window. The capture's own panel sits in the overlay, where the same drag must do nothing to any window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === label ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        guard window is ScanResultPinWindow else { return }
        window?.performDrag(with: event)
    }

    private static func link(_ code: String) -> URL? {
        guard let url = URL(string: code),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let buttonHeight: CGFloat = 22
        var x = bounds.width - Self.inset
        if let visitButton {
            x -= Self.actionWidth
            visitButton.frame = CGRect(x: x, y: (height - buttonHeight) / 2,
                                       width: Self.actionWidth, height: buttonHeight)
            x -= Self.actionGap
        }
        x -= Self.actionWidth
        copyButton.frame = CGRect(x: x, y: (height - buttonHeight) / 2,
                                  width: Self.actionWidth, height: buttonHeight)
        label.frame = CGRect(x: 10, y: (height - 18) / 2,
                             width: max(10, x - Self.actionGap - 10), height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func updateActions() {
        copyButton.isHidden = !hovering
        visitButton?.isHidden = !hovering
        needsDisplay = true
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copyButton.text = "已复制"
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.copyButton.text = "复制" }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    var testing_actionsVisible: Bool { actionsVisible }
    func testing_hover(_ inside: Bool) { hovering = inside }
    func testing_pressCopy() { copyCode() }
    func testing_pressVisit() { if let url { onOpen?(url) } }
}

/// The list of payloads. The box beside the selection and the pinned window both use it, so the two are the same
/// UI rather than two drawings of one.
final class ScanResultListView: NSView {
    static let rowGap: CGFloat = 2
    private let scroll = NSScrollView()
    private let document = ScanListDocument()
    private(set) var rows: [ScanResultRow] = []
    var onOpen: ((URL) -> Void)?

    static func height(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * ScanResultRow.height + CGFloat(count - 1) * rowGap
    }

    init() {
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        layoutRows()
    }

    func setCodes(_ codes: [String]) {
        rows.forEach { $0.removeFromSuperview() }
        rows = codes.map { code in
            let row = ScanResultRow(code: code)
            row.onOpen = { [weak self] in self?.onOpen?($0) }
            document.addSubview(row)
            return row
        }
        layoutRows()
    }

    private func layoutRows() {
        let width = bounds.width
        var y: CGFloat = 0
        for row in rows {
            row.frame = CGRect(x: 0, y: y, width: width, height: ScanResultRow.height)
            y += ScanResultRow.height + Self.rowGap
        }
        // At least as tall as the list so the empty space under the last row is still a drag handle in the
        // pinned window (the document view's mouse-down moves it).
        document.frame = CGRect(x: 0, y: 0, width: width, height: max(bounds.height, y - Self.rowGap))
    }
}

private final class ScanListDocument: NSView {
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard window is ScanResultPinWindow else { return }
        window?.performDrag(with: event)
    }
}

/// The 扫码 panel's pin. Two Phosphor pushpins — the lying one and the standing one the 输入翻译 window uses —
/// cross-fade while turning, so pressing it reads as the pin standing up rather than as an icon swap.
final class ScanPinButton: NSView {
    /// Where the button lives. `.panel` is the 扫码 result panel's own chrome (an icon that needs no plate);
    /// `.disc` is the dark plate 截图翻译's close / copy buttons use, white glyph and all, so the three sit in
    /// one column. The lying / standing pins and the stand-up are the same in both.
    enum Style { case panel, disc }

    static let size: CGFloat = 22
    private static let iconSize: CGFloat = 15
    private static let duration: TimeInterval = 0.22
    /// How far each pin turns while the two cross-fade, in radians.
    private static let turn: CGFloat = .pi / 4

    private let lyingLayer = CALayer()
    private let uprightLayer = CALayer()
    private let style: Style
    private let standsUpOnPress: Bool
    private let onPress: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private(set) var isPinned = false
    private(set) var isAnimating = false
    private var animationGeneration = 0
    /// The disc style grows its glyph under the pointer, exactly like the two `GlyphButton`s beside it. The
    /// panel style has no such move — it is a lone icon in a bar, with nothing to line up with.
    private static let hoverGlyphScale: CGFloat = 1.12
    private static let glyphScaleDuration: TimeInterval = 0.12
    private var glyphScale: CGFloat = 1
    private var scaleTimer: Timer?

    init(style: Style = .panel, standsUpOnPress: Bool = false, onPress: @escaping () -> Void) {
        self.style = style
        self.standsUpOnPress = standsUpOnPress
        self.onPress = onPress
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        toolTip = "钉住"
        setAccessibilityRole(.button)
        setAccessibilityLabel("钉住")
        for layer in [lyingLayer, uprightLayer] {
            let inset = (Self.size - Self.iconSize) / 2
            layer.frame = CGRect(x: inset, y: inset, width: Self.iconSize, height: Self.iconSize)
            layer.contentsGravity = .resizeAspect
            layer.contentsScale = 2
            self.layer?.addSublayer(layer)
        }
        updateImages()
        applyState(animated: false)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { scaleTimer?.invalidate() }

    /// The icons are painted bitmaps (a layer cannot tint a template), so a change of appearance has to repaint
    /// the resting colour.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateImages()
    }

    /// Lies down or stands up; when animated, `completion` runs once the move is over.
    func setPinned(_ pinned: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        guard pinned != isPinned else {
            completion?()
            return
        }
        isPinned = pinned
        isAnimating = animated
        updateImages()
        applyState(animated: animated)
        needsDisplay = true
        toolTip = pinned ? "取消钉住" : "钉住"
        setAccessibilityLabel(pinned ? "取消钉住" : "钉住")
        animationGeneration += 1
        guard animated else {
            completion?()
            return
        }
        let generation = animationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { [weak self] in
            guard let self, generation == self.animationGeneration else { return }
            self.isAnimating = false
            completion?()
        }
    }

    private func press() {
        guard !isAnimating else { return }
        // Pinned: lie the pin down first, then close. Not pinned in 扫码: the capture ends at once, and the
        // window that takes its place plays the stand-up itself (`ScanPanelView.playPinAppearance`). Not pinned
        // in 截图翻译: there is no window to hand over to, so the button stands up first and the capture ends
        // after it.
        if isPinned {
            setPinned(false, animated: true) { [weak self] in self?.onPress() }
        } else if standsUpOnPress {
            setPinned(true, animated: true) { [weak self] in self?.onPress() }
        } else {
            onPress()
        }
    }

    private func updateImages() {
        let tint: NSColor
        let lying: Icon.Asset
        let upright: Icon.Asset
        switch style {
        case .panel:
            // Outline pins, like the input-translation window's own.
            tint = isPinned ? themeColor : .secondaryLabelColor
            lying = .pinRow
            upright = .pinUpright
        case .disc:
            // Phosphor's own pins carry a 16/256 stroke; the two owner-drawn glyphs beside this one are 24/256
            // (9.4%), so at 15 pt the pin read thinner and greyer (owner, 2026-11). These are the same shapes
            // with the stroke widened to 24.
            tint = isPinned ? themeColor : .white
            lying = .discPinRow
            upright = .discPinUpright
        }
        lyingLayer.contents = Icon.image(lying, size: Self.iconSize, tint: tint)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        uprightLayer.contents = Icon.image(upright, size: Self.iconSize, tint: tint)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func applyState(animated: Bool) {
        let lyingOpacity: Float = isPinned ? 0 : 1
        let uprightOpacity: Float = isPinned ? 1 : 0
        let lyingTransform = targetTransform(rotation: isPinned ? Self.turn : 0)
        let uprightTransform = targetTransform(rotation: isPinned ? 0 : -Self.turn)
        if animated {
            // Explicit animations rather than the implicit ones: a view's backing layer has its own actions
            // disabled, and this should not depend on what happens to be inherited here.
            animate(lyingLayer, "opacity", from: lyingLayer.opacity, to: lyingOpacity)
            animate(lyingLayer, "transform", from: lyingLayer.transform, to: lyingTransform)
            animate(uprightLayer, "opacity", from: uprightLayer.opacity, to: uprightOpacity)
            animate(uprightLayer, "transform", from: uprightLayer.transform, to: uprightTransform)
        }
        lyingLayer.opacity = lyingOpacity
        lyingLayer.transform = lyingTransform
        uprightLayer.opacity = uprightOpacity
        uprightLayer.transform = uprightTransform
    }

    /// Rotation for the stand-up, times the hover scale.
    private func targetTransform(rotation: CGFloat) -> CATransform3D {
        CATransform3DScale(CATransform3DMakeRotation(rotation, 0, 0, 1), glyphScale, glyphScale, 1)
    }

    /// The per-frame part of the hover grow. Opacity is left alone (the stand-up may be animating it).
    private func setLayerTransforms() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lyingLayer.transform = targetTransform(rotation: isPinned ? Self.turn : 0)
        uprightLayer.transform = targetTransform(rotation: isPinned ? 0 : -Self.turn)
        CATransaction.commit()
    }

    private func animateGlyphScale(to target: CGFloat) {
        scaleTimer?.invalidate()
        scaleTimer = nil
        guard abs(target - glyphScale) > 0.001 else { return }
        let from = glyphScale
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, Date().timeIntervalSince(start) / Self.glyphScaleDuration)
            let eased = 1 - pow(1 - t, 3)
            self.glyphScale = from + (target - from) * eased
            self.setLayerTransforms()
            if t >= 1 {
                timer.invalidate()
                self.scaleTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scaleTimer = timer
    }

    private func animate(_ layer: CALayer, _ keyPath: String, from: Any?, to: Any) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = Self.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: keyPath)
    }

    override func draw(_ dirtyRect: NSRect) {
        switch style {
        case .panel:
            let background: NSColor? = isPinned ? themeColor.withAlphaComponent(0.18)
                : hovering ? NSColor.labelColor.withAlphaComponent(0.08) : nil
            if let background {
                background.setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
            }
        case .disc:
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            // The shadow gets a state of its own, or it tints everything drawn after it.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = .zero
            shadow.set()
            NSColor.black.withAlphaComponent(hovering ? 0.72 : 0.55).setFill()
            let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                     xRadius: GlyphButton.cornerRadius, yRadius: GlyphButton.cornerRadius)
            plate.fill()
            NSGraphicsContext.restoreGraphicsState()
            if isPinned {
                themeColor.withAlphaComponent(0.18).setFill()
                plate.fill()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        if style == .disc { animateGlyphScale(to: Self.hoverGlyphScale) }
        NSCursor.arrow.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if style == .disc { animateGlyphScale(to: 1) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        press()
    }

    var testing_isPinned: Bool { isPinned }
    var testing_isAnimating: Bool { isAnimating }
    var testing_glyphScale: CGFloat { glyphScale }
    func testing_hover(_ inside: Bool) {
        hovering = inside
        if style == .disc { animateGlyphScale(to: inside ? Self.hoverGlyphScale : 1) }
    }
    func testing_press() { press() }
}

/// 扫码's result: a title, a pin at the top-right and one row per code. The same view is the box beside the
/// selection and the window left on the desktop after 钉住 — one UI, not two. There is deliberately no ✕: the
/// pin is the way out, and while capturing Esc steps back to the screenshot.
final class ScanPanelView: PanelView {
    static let width: CGFloat = 340
    static let listWidth: CGFloat = 316
    static let headerHeight: CGFloat = 40
    static let bottomPadding: CGFloat = 12
    /// Taller than this and the list scrolls.
    static let maximumListHeight: CGFloat = 260

    private let title = NSTextField(labelWithString: "扫码结果")
    private let pinButton: ScanPinButton
    private let list = ScanResultListView()
    private let pinned: Bool
    private let onPinAction: () -> Void
    private(set) var codes: [String] = []
    var onOpen: ((URL) -> Void)?
    /// Set on the pinned window's copy: there the panel is the whole UI, so Esc closes it.
    var closesOnEscape = false

    static func size(codeCount: Int) -> CGSize {
        let listHeight = min(ScanResultListView.height(for: codeCount), maximumListHeight)
        return CGSize(width: width, height: headerHeight + listHeight + bottomPadding)
    }

    init(pinned: Bool, onPin: @escaping () -> Void) {
        self.pinned = pinned
        onPinAction = onPin
        pinButton = ScanPinButton { onPin() }
        super.init(frame: CGRect(origin: .zero, size: Self.size(codeCount: 1)))
        radius = 12
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = CGRect(x: 14, y: 11, width: Self.width - 60, height: 18)
        addSubview(title)
        pinButton.frame = CGRect(x: Self.width - 12 - ScanPinButton.size, y: 9,
                                 width: ScanPinButton.size, height: ScanPinButton.size)
        addSubview(pinButton)
        // The capture has to end before a browser can be used (the overlay floats above everything); the pinned
        // window has nobody to tell, so it opens the link itself.
        list.onOpen = { [weak self] url in
            guard let self else { return }
            if let onOpen { onOpen(url) } else { NSWorkspace.shared.open(url) }
        }
        addSubview(list)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The pinned window's pin starts lying and stands up once the window is on screen — the capture's own pin
    /// closes immediately, so this is where the pressed pin is seen standing up.
    func playPinAppearance() {
        guard pinned else { return }
        pinButton.setPinned(true, animated: true)
    }

    /// The title is a label: a drag on it belongs to the panel (and, when pinned, moves the window).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === title ? self : hit
    }

    override func keyDown(with event: NSEvent) {
        if closesOnEscape, event.keyCode == 53 {
            onPinAction()
            return
        }
        super.keyDown(with: event)
    }

    func show(codes: [String]) {
        self.codes = codes
        title.stringValue = codes.count == 1 ? "扫码结果" : "扫码结果 · \(codes.count) 个"
        let size = Self.size(codeCount: codes.count)
        list.frame = CGRect(x: 12, y: Self.headerHeight, width: Self.listWidth,
                            height: size.height - Self.headerHeight - Self.bottomPadding)
        list.setCodes(codes)
        setFrameSize(size)
        list.layoutSubtreeIfNeeded()
    }

    /// Everything on the panel, one code per line — what 自动复制 and the C key put on the clipboard.
    func copyAll() {
        let text = codes.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var testing_codes: [String] { codes }
    var testing_pinButton: ScanPinButton { pinButton }
    var testing_rowCount: Int { list.rows.count }
    func testing_rowHasVisit(_ index: Int) -> Bool { list.rows.indices.contains(index) && list.rows[index].hasLink }
    func testing_rowShowsActions(_ index: Int) -> Bool {
        list.rows.indices.contains(index) && list.rows[index].testing_actionsVisible
    }
    func testing_hoverRow(_ index: Int, _ inside: Bool) {
        guard list.rows.indices.contains(index) else { return }
        list.rows[index].testing_hover(inside)
    }
    func testing_pressCopyRow(_ index: Int) {
        guard list.rows.indices.contains(index) else { return }
        list.rows[index].testing_pressCopy()
    }
    func testing_pressVisitRow(_ index: Int) {
        guard list.rows.indices.contains(index) else { return }
        list.rows[index].testing_pressVisit()
    }
}
