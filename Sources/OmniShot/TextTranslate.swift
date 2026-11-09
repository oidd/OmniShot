import AppKit
import OmniShotCore

/// 输入翻译: a window for text that isn't on screen — paste or type it, get the translation.
///
/// Laid out like a translation app rather than a form: 原文 in a card, the language bar under it, 译文 in
/// another card below with the engine's name on top. There is no translate button — Return does it, and ⌘↩
/// is the one that puts a newline in, which is the rarer of the two in a window you paste into.
///
/// It has no title bar: the frame is drawn, and the top row holds a red close disc on the left, whatever the
/// window has to say, and 置顶 on the right.
///
/// It shares the engines and the cache with the capture flow, and opening it translates whatever is on the
/// clipboard right away: 复制 → 快捷键 → 读译文.
final class TextTranslationWindow: NSWindow, NSWindowDelegate {
    private static var current: TextTranslationWindow?

    private let sourceCard = TranslationCard(placeholder: "原文")
    private let resultCard = TranslationCard(placeholder: "译文")
    /// Under 原文: what to press while there is something to send, what the text turned out to be once sent.
    private let chip = ChipView()
    /// The window's one line of text, and it only exists while there is something to say. There is no title
    /// bar to put a subtitle in, so it is drawn in the top row instead.
    private let statusLabel = NSTextField(labelWithString: "")
    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// What is doing the translating. It used to sit on top of 译文, where it read as part of the translation.
    private let enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var swapButton = ChromeButton(image: Icon.image(.swap, size: 14), tooltip: "对调翻译方向",
                                               size: 24) { [weak self] in self?.swapDirection() }
    private lazy var copyButton = ChromeButton(image: Icon.image(.copyText, size: 15), tooltip: "复制",
                                               size: 24) { [weak self] in self?.copyResult() }
    private lazy var clearButton = ChromeButton(image: Icon.image(.clearText, size: 15), tooltip: "清空",
                                                size: 24) { [weak self] in self?.clearSource() }
    private lazy var pinButton = ChromeButton(image: Icon.image(.pinRow, size: 15), tooltip: "置顶",
                                              size: 24) { [weak self] in self?.togglePin() }
    private let closeButton = CloseButton()

    private var sourceView: SourceTextView { sourceCard.textView }
    private var resultView: SourceTextView { resultCard.textView }

    private var translationTask: Task<Void, Never>?
    /// Takes the transient "已复制译文" line back down again.
    private var statusClear: DispatchWorkItem?
    /// The clipboard's change count the last time this window took its text. A counter rather than the text:
    /// copying the same thing again counts as new, and closing the window clears it — so reopening never
    /// looks like the panel remembered the last translation, which is what the clipboard made it look like.
    private static var seenChangeCount = -1

    /// What the text in 原文 looks like: 简体中文 / English / 日本語 / 한국어, or `.other` when there is
    /// nothing to go on. Only shown, never acted on — the popups say what to do with it.
    private var detectedLanguage = ScreenLanguage.other
    /// 自动检测, or a language the user pinned. The popups are the source of truth; this is their state.
    private var sourceChoice = TranslationConfig.autoSource
    /// 自动选择, or a language the user pinned.
    private var targetChoice = TextTranslationWindow.autoTarget
    /// Whether what is in 原文 has been sent yet. Until it has, the chip is a reminder of the two keys.
    private var hasTranslated = false

    private static let windowTitle = "输入翻译"
    static let autoTarget = "自动选择"
    /// The languages both popups offer, in the words the rest of the app uses for them.
    private static let languages = ["简体中文", "繁體中文", "English", "日本語", "한국어"]

    /// Replaceable for the self-checks, which translate without a network.
    var translate: ([ChatTranslator.Item], TranslationConfig) async throws -> [Int: String] = { items, config in
        try await TranslationService.cache.translate(items, config: config) {
            try await Translator.translate($0, config: config)
        }
    }

    /// The one window, created on first use. Closed windows are dropped, so the next open is fresh.
    static func shared() -> TextTranslationWindow {
        if let current { return current }
        let window = TextTranslationWindow()
        current = window
        return window
    }

    /// The window only if it is already up. Never creates one: a capture asking which windows to keep must not
    /// conjure a window into existence.
    static var existing: TextTranslationWindow? { current }

    /// Opens the window; with text on the clipboard it translates that text at once.
    static func show() {
        let window = shared()
        window.present()
    }

    private init() {
        // No `.titled`: the frame is drawn here and the only chrome is the close disc and 置顶.
        let frame = CGRect(x: 0, y: 0, width: 560, height: 580)
        super.init(contentRect: frame, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        title = Self.windowTitle
        isReleasedWhenClosed = false
        delegate = self
        minSize = CGSize(width: 440, height: 400)
        // A clear window whose content is a rounded panel: that is what gives it its shape and its shadow.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true

        let content = WindowFrameView(frame: frame)
        content.autoresizesSubviews = true
        for card in [sourceCard, resultCard] { content.addSubview(card) }

        for view in [sourceView, resultView] {
            view.font = .systemFont(ofSize: 13)
            view.isRichText = false
            view.drawsBackground = false
            view.textContainerInset = CGSize(width: 6, height: 8)
            view.autoresizingMask = [.width]
            view.isSelectable = true
        }
        sourceView.isEditable = true
        resultView.isEditable = false
        // Return translates and ⌘↩ puts the newline in, which is the opposite of the usual pair — see
        // `SourceTextView` for why.
        sourceCard.onReturn = { [weak self] in self?.runTranslation() }
        sourceCard.textView.onTextChange = { [weak self] in self?.sourceEdited() }

        // 原文 card footer: the chip, which starts as a reminder of the two keys, and 清空 on the right.
        chip.isHidden = true
        sourceCard.footer.addSubview(chip)
        clearButton.tint = .secondaryLabelColor
        sourceCard.footer.addSubview(clearButton)
        // 译文 card footer: the copy button on the right, and nothing else.
        copyButton.tint = .secondaryLabelColor
        resultCard.footer.addSubview(copyButton)

        closeButton.onClick = { [weak self] in self?.close() }
        content.addSubview(closeButton)
        pinButton.tint = .secondaryLabelColor
        content.addSubview(pinButton)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(statusLabel)

        sourcePopup.addItems(withTitles: [TranslationConfig.autoSource] + Self.languages)
        targetPopup.addItems(withTitles: [Self.autoTarget] + Self.languages)
        for popup in [sourcePopup, targetPopup] {
            popup.target = self
            popup.action = #selector(languageChanged)
            content.addSubview(popup)
        }
        updateEnginePopup()
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        content.addSubview(enginePopup)
        // The buttons ship with size constraints, which is right in a stack and wrong here.
        for button in [pinButton, swapButton, copyButton, clearButton] {
            button.translatesAutoresizingMaskIntoConstraints = true
        }
        swapButton.tint = .secondaryLabelColor
        content.addSubview(swapButton)

        contentView = content
        layoutContent()
        center()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Window

    private func present() {
        // The 大模型 entries may have been added or renamed in the settings window since the last time.
        updateEnginePopup()
        // A self-check opens this window to drive its keys; park it off screen and leave the user's focus alone.
        // (It used to flash in front of whatever they were doing, which is how "偶尔会自动跳出输入翻译的界面"
        // got reported while the installed app was running untouched.)
        if SelfCheck.isRunning {
            setFrameOrigin(CGPoint(x: -9000, y: -9000))
            makeKeyAndOrderFront(nil)
        } else {
            NSApp.activate()
            makeKeyAndOrderFront(nil)
            // `activate()` only asks, and a menu bar app is usually not active when its menu item is picked.
            // Without this the window comes up behind whatever is in front of it.
            orderFrontRegardless()
        }
        let pasteboard = NSPasteboard.general
        let clip = Settings.shared.autoReadClipboard
            ? (pasteboard.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        if !clip.isEmpty, pasteboard.changeCount != Self.seenChangeCount {
            Self.seenChangeCount = pasteboard.changeCount
            sourceView.string = clip
            sourceEdited()
            runTranslation()
        } else {
            sourceEdited()
            makeFirstResponder(sourceView)
        }
    }

    func windowDidResize(_ notification: Notification) {
        layoutContent()
        invalidateShadow()
    }

    // A borderless window cannot become key unless it says so, and a window that is not key hands no
    // keystrokes to its text views — which is why 原文 took no typing at all once the title bar went away.
    // Every other borderless window here (`OverlayWindow`, `PinWindow`) overrides these for the same reason.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// A self-check parks this window off screen. AppKit's own constrainment would drag it back into view the
    /// moment it is ordered front — parking it was not enough on its own, and it still flashed in the middle
    /// of the user's screen. Only the checks skip the constrainment; a real window always stays reachable.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        SelfCheck.isRunning ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    /// There is no title bar, so there is no standard Close item either; ⌘W has to be caught here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func windowWillClose(_ notification: Notification) {
        translationTask?.cancel()
        translationTask = nil
        // Nothing is kept: the next open is a clean sheet, which is what closing and reopening should mean.
        sourceView.string = ""
        resultView.string = ""
        TextTranslationWindow.current = nil
    }

    private func layoutContent() {
        guard let content = contentView else { return }
        let width = content.bounds.width, height = content.bounds.height
        let margin: CGFloat = 14, gap: CGFloat = 8
        let header: CGFloat = 26, bar: CGFloat = 30
        let inner = width - margin * 2

        // Top row: the close disc, whatever the window has to say, and 置顶 at the far end.
        var top = height - margin
        closeButton.frame = CGRect(x: margin, y: top - header + (header - 14) / 2, width: 14, height: 14)
        pinButton.frame = CGRect(x: width - margin - 24, y: top - header + 1, width: 24, height: 24)
        let statusText = statusLabel.stringValue
        let statusWidth = statusText.isEmpty ? 0 : min(ceil(statusLabel.fittingSize.width), inner * 0.5)
        statusLabel.frame = CGRect(x: margin + 14 + gap, y: top - header + 5, width: statusWidth, height: 16)
        top -= header + gap

        let cardHeight = max(90, (top - margin - bar - gap * 2) / 2)
        sourceCard.frame = CGRect(x: margin, y: top - cardHeight, width: inner, height: cardHeight)
        top -= cardHeight + gap

        // The bar: the two languages on the left with the arrow between them as the button that swaps them,
        // and the engine on the right — it belongs with the controls, not on top of the translation.
        let engineWidth = min(150, inner * 0.3)
        let popupWidth = min(132, (inner - 24 - gap * 2 - engineWidth - gap) / 2)
        let barY = top - bar
        sourcePopup.frame = CGRect(x: margin, y: barY, width: popupWidth, height: bar)
        swapButton.frame = CGRect(x: sourcePopup.frame.maxX + gap, y: barY + 3, width: 24, height: 24)
        targetPopup.frame = CGRect(x: swapButton.frame.maxX + gap, y: barY, width: popupWidth, height: bar)
        enginePopup.frame = CGRect(x: width - margin - engineWidth, y: barY, width: engineWidth, height: bar)
        top -= bar + gap

        resultCard.frame = CGRect(x: margin, y: margin, width: inner, height: max(80, top - margin))

        // Inside the cards: the chip on the left of 原文's footer, the copy button on the right of 译文's.
        let chipWidth = chip.isHidden ? 0 : ceil(chip.fittingSize.width)
        chip.frame = CGRect(x: 8, y: 5, width: chipWidth, height: 20)
        chip.needsLayout = true
        copyButton.frame = CGRect(x: resultCard.bounds.width - 8 - 24, y: 3, width: 24, height: 24)
        clearButton.frame = CGRect(x: sourceCard.bounds.width - 8 - 24, y: 3, width: 24, height: 24)
    }

    // MARK: - Language

    /// Called whenever 原文 changes: what is typed is what the chip talks about, and nothing has been sent.
    private func sourceEdited() {
        hasTranslated = false
        detectedLanguage = ScreenLanguage.detect(in: [sourceView.string])
        updateChip()
        updateLanguagePopups()
    }

    /// The chip under 原文: the two keys while there is something waiting to be sent, then what the text
    /// turned out to be.
    private func updateChip() {
        let typed = !sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let name = Self.languageName(for: detectedLanguage)
        if typed, !hasTranslated {
            chip.setText("↩翻译 · ⌘↩ 换行", tinting: ["↩", "⌘"])
        } else {
            chip.setText(name.isEmpty ? "" : "识别为 \(name)", tinting: [])
        }
        chip.isHidden = chip.text.isEmpty
        layoutContent()
    }

    /// The detected language in the same words the popups use. `.other` has nothing worth saying.
    private static func languageName(for language: ScreenLanguage) -> String {
        switch language {
        case .chinese: return "简体中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .other: return ""
        }
    }

    private static func isChinese(_ language: String) -> Bool {
        language == "简体中文" || language == "繁體中文"
    }

    /// Whether the translation goes into English rather than into the language from settings — the rule the
    /// capture flow uses too. 自动选择 means "the other one": Chinese goes to English, everything else goes to
    /// the language from settings.
    private var translatesIntoEnglish: Bool {
        guard targetChoice == Self.autoTarget else { return targetChoice == "English" }
        return sourceChoice == TranslationConfig.autoSource
            ? detectedLanguage.translatesIntoEnglish
            : Self.isChinese(sourceChoice)
    }

    private var resolvedTarget: String {
        targetChoice == Self.autoTarget ? (translatesIntoEnglish ? "English" : Settings.shared.targetLanguage) : targetChoice
    }

    /// The engines this window can use: the free one, then every saved 大模型 entry under the name the user
    /// gave it (unnamed ones read「自定义大模型」). The ids line up with the popup's items, one offset in.
    private var engineIDs: [String] = []

    private func updateEnginePopup() {
        let configs = Settings.shared.llmConfigs
        engineIDs = configs.map(\.id)
        enginePopup.removeAllItems()
        enginePopup.addItems(withTitles: ["免费翻译"] + LLMConfig.labels(for: configs))
        if Settings.shared.engine == .free {
            enginePopup.selectItem(at: 0)
        } else if let index = engineIDs.firstIndex(of: Settings.shared.selectedLLMConfigID) {
            enginePopup.selectItem(at: index + 1)
        }
    }

    /// Picking an engine here is picking the app's engine — and, for the LLM, which saved entry to use. It is
    /// the same state the 设置 window shows, so the capture flow follows along rather than the two disagreeing.
    @objc private func engineChanged() {
        let index = enginePopup.indexOfSelectedItem
        if index <= 0 {
            Settings.shared.engine = .free
        } else {
            Settings.shared.selectedLLMConfigID = engineIDs[index - 1]
            Settings.shared.engine = .llm
        }
        runTranslation()
    }

    /// The arrow between the two popups. With both on auto there is nothing to exchange, so it pins whatever
    /// the guess worked out and swaps *that* — which is what the user means by pressing it ("it read it the
    /// wrong way round") and leaves both popups showing what it did.
    private func swapDirection() {
        let source = sourceChoice == TranslationConfig.autoSource ? Self.languageName(for: detectedLanguage) : sourceChoice
        guard !source.isEmpty else { return }   // nothing recognised, nothing to swap
        let target = resolvedTarget
        sourceChoice = target
        targetChoice = source
        updateLanguagePopups(resolved: true)
        runTranslation()
    }

    @objc private func languageChanged() {
        sourceChoice = sourcePopup.titleOfSelectedItem ?? TranslationConfig.autoSource
        targetChoice = targetPopup.titleOfSelectedItem ?? Self.autoTarget
        runTranslation()
    }

    /// `resolved` shows what the translation is actually using rather than the two 自动 entries — which is
    /// what the user wants to see once it has run. The choices behind them are untouched: a name shown this
    /// way still means "work it out", so the next text is read on its own merits.
    private func updateLanguagePopups(resolved: Bool = false) {
        let detected = Self.languageName(for: detectedLanguage)
        let source = resolved && sourceChoice == TranslationConfig.autoSource && !detected.isEmpty
            ? detected : sourceChoice
        let target = resolved && targetChoice == Self.autoTarget ? resolvedTarget : targetChoice
        sourcePopup.selectItem(withTitle: source)
        targetPopup.selectItem(withTitle: target)
    }

    // MARK: - Translating

    private func runTranslation() {
        let text = sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var config = Settings.shared.translationConfig
        config.targetLanguage = resolvedTarget
        config.sourceLanguage = sourceChoice
        guard config.engine == .free || !config.apiKey.isEmpty else {
            setStatus("还没有填写 API Key，请在设置 → 翻译 中填写")
            return
        }
        translationTask?.cancel()
        // Sent, so the chip can stop telling the user which key to press and start saying what the text is.
        hasTranslated = true
        updateChip()
        setStatus("正在翻译…")
        // The 译文 placeholder has done its job the moment there is something on the way.
        resultView.placeholder = ""
        resultView.string = ""
        updateLanguagePopups(resolved: true)

        translationTask = Task { @MainActor in
            do {
                let translations = try await translate([ChatTranslator.Item(id: 0, text: text)], config)
                guard !Task.isCancelled else { return }
                guard let result = translations[0], !result.isEmpty else {
                    setStatus("翻译服务没有返回译文，再试一次")
                    return
                }
                resultView.string = result
                // Nothing on success: the translation in the card below says it better than a line of text.
                setStatus("")
            } catch is CancellationError {
                // Replaced by a newer translation; the window is already showing that one's state.
            } catch {
                guard !Task.isCancelled else { return }
                setStatus((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func setStatus(_ text: String) {
        statusClear?.cancel()
        statusLabel.stringValue = text
        layoutContent()
    }

    /// Empties 原文 so the next thing typed starts from nothing. 译文 goes with it: a translation of text that
    /// is no longer there would be a lie.
    @objc private func clearSource() {
        translationTask?.cancel()
        translationTask = nil
        sourceView.string = ""
        resultView.string = ""
        resultView.placeholder = "译文"
        sourceEdited()
        setStatus("")
        makeFirstResponder(sourceView)
    }

    @objc private func copyResult() {
        let text = resultView.string
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setStatus("已复制译文")
        // Copies have no other visible effect, so this one says its piece and then goes.
        let work = DispatchWorkItem { [weak self] in self?.setStatus("") }
        statusClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    @objc private func togglePin() {
        let pinned = level != .floating
        level = pinned ? .floating : .normal
        // The pin lies over until it is pinned and stands up when it is: the icon says what the button did,
        // the way a real pushpin does. Phosphor has the upright one (`push-pin-simple`) — same family, so no
        // rotating the tilted one and losing its needle off the corner.
        pinButton.image = Icon.image(pinned ? .pinUpright : .pinRow, size: 15)
        pinButton.isActive = pinned
        pinButton.toolTip = pinned ? "取消置顶" : "置顶"
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return close() }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    // MARK: - Self-checks

    var testing_source: String { sourceView.string }
    var testing_result: String { resultView.string }
    var testing_status: String { statusLabel.stringValue }
    var testing_visible: Bool { isVisible }
    var testing_direction: (source: String, target: String) { (sourceChoice, resolvedTarget) }
    var testing_targetChoice: String { targetChoice }
    var testing_popups: (source: String, target: String) {
        (sourcePopup.titleOfSelectedItem ?? "", targetPopup.titleOfSelectedItem ?? "")
    }
    var testing_chip: String { chip.isHidden ? "" : chip.label.stringValue }
    var testing_engine: String { enginePopup.titleOfSelectedItem ?? "" }
    var testing_sourceView: NSResponder { sourceView }
    func testing_chooseEngine(_ title: String) {
        enginePopup.selectItem(withTitle: title)
        engineChanged()
    }

    func testing_setSource(_ text: String) {
        sourceView.string = text
        sourceEdited()
    }

    /// Types the way a keyboard does, through the text system, so `didChangeText` and everything hanging off
    /// it actually run. `testing_setSource` bypasses all of that.
    func testing_type(_ text: String) {
        sourceView.insertText(text, replacementRange: sourceView.selectedRange())
    }

    func testing_copy() { copyResult() }
    func testing_clear() { clearSource() }
    func testing_togglePin() { togglePin() }
    var testing_pinned: Bool { level == .floating }
    func testing_swapDirection() { swapDirection() }
    func testing_pressReturn(command: Bool) { sourceCard.textView.testing_pressReturn(command: command) }

    func testing_chooseLanguages(source: String, target: String) {
        sourceChoice = source
        targetChoice = target
        updateLanguagePopups()
        runTranslation()
    }

    /// The window itself, so a capture can put it back in the picture — see `CaptureEngine`.
    var capturableWindowNumbers: [CGWindowID] {
        isVisible ? [CGWindowID(windowNumber)] : []
    }
}

/// The window's own frame: a rounded panel, since there is no title bar to draw one, and the shape the
/// window's shadow is derived from.
final class WindowFrameView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }
}

/// The window's only traffic light. It is drawn rather than borrowed from the system: there is no title bar
/// to put a real one in, and the system's close button is the red disc people already know.
final class CloseButton: NSView {
    var onClick: (() -> Void)?
    private var hovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // The system's own close red, which does not change with the appearance either.
        NSColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        guard hovering else { return }
        let inset = bounds.width * 0.3
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: inset, y: inset))
        cross.line(to: CGPoint(x: bounds.maxX - inset, y: bounds.maxY - inset))
        cross.move(to: CGPoint(x: inset, y: bounds.maxY - inset))
        cross.line(to: CGPoint(x: bounds.maxX - inset, y: inset))
        cross.lineWidth = 1.4
        cross.lineCapStyle = .round
        NSColor(white: 0.25, alpha: 1).setStroke()
        cross.stroke()
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

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One of the window's two rounded panels: a scrolling text area with a strip along the bottom for a chip or
/// a button, which is how 原文 and 译文 are laid out.
final class TranslationCard: NSView {
    let textView = SourceTextView()
    let scroll = NSScrollView()
    let footer = NSView()
    private let footerHeight: CGFloat = 30

    /// Return translates; the card hands that up to the window.
    var onReturn: (() -> Void)? {
        get { textView.onReturn }
        set { textView.onReturn = newValue }
    }

    init(placeholder: String) {
        super.init(frame: .zero)
        wantsLayer = true
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        addSubview(scroll)
        addSubview(footer)
        textView.placeholder = placeholder
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // A card has to be visible against the window behind it, and naming a colour does not get you that:
        // on this system `windowBackgroundColor`, `controlBackgroundColor` and `textBackgroundColor` all
        // resolve to the same one, so the cards came out invisible. A few percent of the label colour over
        // the window is lighter on dark and darker on light, which is how the system's own surfaces read.
        let fill = NSColor.windowBackgroundColor.blended(withFraction: 0.07, of: .labelColor) ?? .windowBackgroundColor
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutCard()
    }

    override func layout() {
        super.layout()
        layoutCard()
    }

    private func layoutCard() {
        footer.frame = CGRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: footerHeight)
        scroll.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - footerHeight))
    }
}

/// The text view inside a card, which also draws the card's placeholder: NSTextView has none of its own, and
/// 「原文」/「译文」 saying what each box is for beats an empty rectangle.
final class SourceTextView: NSTextView {
    var onReturn: (() -> Void)?
    /// Called after the text changes by typing. `sourceEdited` used to be reachable only from the window's
    /// own entry points — the clipboard, the clear button, the self-checks — so typing updated nothing: the
    /// chip never offered the two keys, and the detected language stayed whatever it had been.
    var onTextChange: (() -> Void)?

    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        (placeholder as NSString).draw(at: CGPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                                                   y: textContainerInset.height),
                                       withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onTextChange?()
    }

    override func keyDown(with event: NSEvent) {
        // While an input method is composing, both keys belong to it: Return picks a candidate and Esc drops
        // the composition, and neither is a request to translate or to close the window.
        guard isEditable, !hasMarkedText() else { return super.keyDown(with: event) }
        guard event.keyCode == 36 || event.keyCode == 76 else { return super.keyDown(with: event) }  // ↩ and ⌤
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            insertText("\n", replacementRange: selectedRange())
        } else if flags.isEmpty {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return super.cancelOperation(sender) }
        window?.close()
    }

    /// Drives the same path a key press takes, for the self-checks.
    func testing_pressReturn(command: Bool) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? .command : [],
                                           timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
                                           characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                                           keyCode: 36) else { return }
        keyDown(with: event)
    }
}

/// A small rounded label, for 「识别为 简体中文」 and the two-key reminder.
final class ChipView: NSView {
    let label = NSTextField(labelWithString: "")

    /// The plain text, whatever colour the pieces are drawn in.
    var text: String { label.stringValue }

    /// Sets the label, drawing any of `symbols` it contains in the app's blue so a key reads as a key rather
    /// than as part of the sentence. Light mode gets a darker blue: the app's own is made for the dark
    /// capture overlay and would be almost invisible on a pale chip.
    func setText(_ text: String, tinting symbols: [String]) {
        let keyColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? themeColor : (themeColor.blended(withFraction: 0.4, of: .black) ?? themeColor)
        }
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        for symbol in symbols {
            var search = text.startIndex..<text.endIndex
            while let found = text.range(of: symbol, range: search) {
                let location = text.distance(from: text.startIndex, to: found.lowerBound)
                attributed.addAttribute(.foregroundColor, value: keyColor,
                                        range: NSRange(location: location, length: (symbol as NSString).length))
                search = found.upperBound..<text.endIndex
            }
        }
        label.attributedStringValue = attributed
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func layout() {
        super.layout()
        let size = label.fittingSize
        label.frame = CGRect(x: 9, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    override var fittingSize: NSSize {
        let size = label.fittingSize
        return NSSize(width: ceil(size.width) + 18, height: 20)
    }
}
