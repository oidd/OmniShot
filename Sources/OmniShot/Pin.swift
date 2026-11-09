import AppKit
import OmniShotCore

extension NSWindow.Level {
    /// Pins stay one step above Quick Look. Its `QLPreviewPanel` is at level 9 (measured on macOS 27), so a
    /// `.floating` pin (3) ended up underneath the Finder preview — pinning a piece of the preview looked like
    /// nothing had happened until the preview was closed. 10 is still below the Dock (20) and the menu bar (24):
    /// a pin belongs over documents and previews, not over system UI. Both `PinWindow` and the scan result's
    /// pin window use it; `--check pin-layer` guards them.
    static let pinned = NSWindow.Level(rawValue: 10)
}

/// Keeps track of open pins, and whether they are all hidden.
final class PinManager {
    static let shared = PinManager()

    private(set) var pins: [PinWindow] = []
    /// Hidden pins stay open; showing them again brings back every one.
    private(set) var isHidingAll = false

    var hasPins: Bool { !pins.isEmpty }

    /// Shows `rep` as a floating pin; `frame` is in global screen coordinates at 100% zoom.
    @discardableResult
    func pin(_ rep: NSBitmapImageRep, frame: CGRect) -> PinWindow {
        // A new pin while the others are hidden brings them back, so nothing is left hidden by surprise.
        if isHidingAll {
            isHidingAll = false
            refreshVisibility()
        }
        let window = PinWindow(rep: rep, frame: frame)
        pins.append(window)
        window.orderFrontRegardless()
        window.makeKey()
        window.prepareText()
        return window
    }

    func isShown(_ pin: PinWindow) -> Bool { !isHidingAll }

    /// The pins a screenshot may include: the ones actually on screen right now. A pin being edited is
    /// ordered out while the editor is up, and hidden ones are gone until they are shown again.
    var capturableWindowNumbers: [CGWindowID] {
        guard !isHidingAll else { return [] }
        return pins.filter { $0.isVisible }.map { CGWindowID($0.windowNumber) }
    }

    private func refreshVisibility() {
        for pin in pins {
            if isHidingAll { pin.orderOut(nil) } else if !pin.isVisible { pin.orderFrontRegardless() }
        }
    }

    /// Pins the images on the clipboard (image data, or image files copied in Finder), centered on the mouse.
    /// Returns false when there is no image.
    @discardableResult
    func pinClipboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let images = ClipboardPinSource.read(pasteboard)
        guard !images.isEmpty else {
            HUD.show("剪贴板里没有图片")
            return false
        }
        // Several image files fan out from the cursor so they don't cover each other exactly.
        for (i, rep) in images.enumerated() {
            let offset = CGFloat(i) * 24
            pin(rep, centeredAt: CGPoint(x: mouse.x + offset, y: mouse.y - offset), on: screen)
        }
        return true
    }

    /// Places a pin centered on `center`, kept inside the screen and scaled down if it is larger than the screen.
    @discardableResult
    func pin(_ rep: NSBitmapImageRep, centeredAt center: CGPoint, on screen: NSScreen?) -> PinWindow {
        let size = rep.size
        var frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        var fit: CGFloat = 1
        if let visible = screen?.visibleFrame {
            fit = min(1, visible.width * 0.9 / max(size.width, 1), visible.height * 0.9 / max(size.height, 1))
            let shown = CGSize(width: size.width * fit, height: size.height * fit)
            frame.origin.x = min(max(center.x - shown.width / 2, visible.minX), max(visible.minX, visible.maxX - shown.width))
            frame.origin.y = min(max(center.y - shown.height / 2, visible.minY), max(visible.minY, visible.maxY - shown.height))
        }
        // Whole-point origin: a half-point one makes the window server grow the window by a point.
        frame.origin = CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded())
        let window = pin(rep, frame: frame)
        if fit < 1 {
            window.setZoom(fit, anchor: frame.origin)
        }
        return window
    }

    func closeAll() {
        for pin in pins { pin.closePin() }
        isHidingAll = false
    }

    /// Hides every pin, or shows them again if they are hidden. Deliberately silent: the pins going away and
    /// coming back says it better than a line of text in the middle of the screen did.
    func toggleHidden() {
        if isHidingAll {
            isHidingAll = false
            refreshVisibility()
        } else {
            guard !pins.isEmpty else {
                HUD.show("当前没有贴图")
                return
            }
            // A pencil stage over a pin that is about to disappear would be left hanging over the desktop.
            if pins.contains(where: \.isEditing) { CaptureSession.current?.foldPinToolsIfOpen() }
            isHidingAll = true
            refreshVisibility()
        }
    }

    fileprivate func didClose(_ pin: PinWindow) {
        pins.removeAll { $0 === pin }
    }
}

/// What a pin's pencil sessions keep between one another: the picture before any annotations, the annotations
/// themselves, and the undo/redo stacks. Keeping the picture and the items apart is what lets the second
/// session undo what the first one drew — a flattened picture would have nothing left to take back. `rep` on
/// the pin is always `base` + `items`, so the pin shows the edits while the toolbar is closed.
struct PinEditHistory {
    var base: NSBitmapImageRep
    var items: [AnnotationItem] = []
    var undo: [[AnnotationItem]] = []
    var redo: [[AnnotationItem]] = []
}

/// Turning a pinned picture a quarter turn. One direction only — counter-clockwise, the way the pin's arrow
/// points — so pressing the button four times always brings the picture back.
enum PinImage {
    /// The picture turned 90° counter-clockwise: the top-left corner of the old one ends up at the bottom-left.
    /// The reported size is swapped with the pixels, so the pin keeps its point size and its zoom.
    static func rotatedCounterClockwise(_ rep: NSBitmapImageRep) -> NSBitmapImageRep? {
        guard let cg = rep.cgImage else { return nil }
        let width = cg.width, height = cg.height
        guard let context = CGContext(data: nil, width: height, height: width, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        // Positive rotation in CoreGraphics' y-up space is counter-clockwise on screen; the translate is what
        // puts the turned picture back into the canvas' positive quadrant.
        context.translateBy(x: CGFloat(height), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let turned = context.makeImage() else { return nil }
        let result = NSBitmapImageRep(cgImage: turned)
        result.size = NSSize(width: rep.size.height, height: rep.size.width)
        return result
    }
}

/// A screenshot floating above other windows. Scroll to zoom, ⌥-scroll for opacity, Esc to close.
final class PinWindow: NSPanel {
    private(set) var rep: NSBitmapImageRep

    /// The annotation model behind the picture; empty until the pencil is used. Resets whenever the picture is
    /// replaced by something other than the pencil (翻译, 旋转), because those edits belong to another picture.
    private(set) var editHistory: PinEditHistory

    private func refreshImage() {
        pinView.image = image(from: rep)
    }

    private var baseSize: CGSize
    private(set) var zoom: CGFloat = 1
    private let pinView = PinView()
    private var scrollAccumulator: CGFloat = 0
    private var isClosing = false

    init(rep: NSBitmapImageRep, frame: CGRect) {
        self.rep = rep
        self.editHistory = PinEditHistory(base: rep)
        self.baseSize = frame.size
        // The window is a little bigger than the picture: room for the border, its glow, and the buttons.
        super.init(contentRect: PinView.windowFrame(for: frame),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // After `isFloatingPanel`: turning that on sends the panel back to `.floating` (3), which is exactly the
        // level Quick Look sits above.
        level = .pinned
        hidesOnDeactivate = false
        // The same line the capture overlay has, and for the same reason: without it the window gets no
        // `mouseMoved` events at all. The resize grips say what they are with the cursor, and that was stuck on
        // the open hand until the pin was clicked — the click made the window key, and only then did the moves
        // start arriving.
        acceptsMouseMovedEvents = true
        // No system shadow: it is always black, so it drew a dark rim around the border and drowned the glow
        // below it — and the pin's edge is supposed to be the colour the user picked (`PinView.draw`).
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pinView.window_ = self
        pinView.image = image(from: rep)
        contentView = pinView
    }

    override var canBecomeKey: Bool { true }

    /// The pencil's stage sits over the pin's picture; when the dots drag the pin, the stage has to travel with
    /// it, or the annotations would stay behind. Done here, synchronously, rather than through
    /// `NSWindow.didMoveNotification`, which can arrive a frame late on a quick drag.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let old = frame.origin
        super.setFrameOrigin(newOrigin)
        CaptureSession.current?.pinMoved(by: CGPoint(x: newOrigin.x - old.x, y: newOrigin.y - old.y))
    }

    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        // The pointer is already where it is: a pin is created under it, so no mouse-moved event is on the way
        // and the cursor would stay whatever the last window left there until the pin was dragged to shake it
        // loose. This is the moment to put the right one up.
        pinView.applyCursorForPointer()
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        pinView.applyCursorForPointer()
    }

    override func becomeKey() {
        super.becomeKey()
        pinView.needsDisplay = true
        // A click here is what used to make the grips' cursors start working; put the right one up straight
        // away rather than waiting for the next mouse move.
        pinView.applyCursorForPointer()
        prepareText()
    }

    override func resignKey() {
        super.resignKey()
        pinView.needsDisplay = true
    }

    private func image(from rep: NSBitmapImageRep) -> NSImage {
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Zoom and opacity

    func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil, flash: Bool = true) {
        let clamped = min(max(newZoom, 0.1), 8)
        let anchor = anchor ?? CGPoint(x: frame.midX, y: frame.midY)
        // Anchored on the picture, not the window: the margins around it are not the same on every side.
        let picture = PinView.pictureFrame(in: frame)
        let rx = (anchor.x - picture.minX) / max(picture.width, 1)
        let ry = (anchor.y - picture.minY) / max(picture.height, 1)
        let size = CGSize(width: max(8, baseSize.width * clamped), height: max(8, baseSize.height * clamped))
        let origin = CGPoint(x: anchor.x - rx * size.width, y: anchor.y - ry * size.height)
        zoom = clamped
        setFrame(PinView.windowFrame(for: CGRect(origin: origin, size: size)), display: true)
        pinView.layoutButtons()
        if flash { pinView.flash("\(Int((clamped * 100).rounded()))%") }
    }

    func setOpacity(_ value: CGFloat) {
        alphaValue = min(max(value, 0.2), 1)
        pinView.flash("透明度 \(Int((alphaValue * 100).rounded()))%")
    }

    override func scrollWheel(with event: NSEvent) {
        scrollAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        guard abs(scrollAccumulator) >= 1 else { return }
        let steps = scrollAccumulator.rounded(.towardZero)
        scrollAccumulator -= steps
        if event.modifierFlags.contains(.option) {
            setOpacity(alphaValue + steps * 0.05)
        } else {
            setZoom(zoom * pow(1.1, steps), anchor: NSEvent.mouseLocation)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let arrows: [UInt16: CGPoint] = [123: CGPoint(x: -1, y: 0), 124: CGPoint(x: 1, y: 0), 125: CGPoint(x: 0, y: -1), 126: CGPoint(x: 0, y: 1)]
        if flags == .command && key == "w" {
            closePin()
        } else if event.keyCode == 53 {
            cancelOperation(nil)
        } else if flags.isEmpty, key == " " {
            editWithTools()
        } else if flags.isEmpty, key == "y" {
            toggleTranslation()
        } else if flags.subtracting(.shift).isEmpty, key == "=" || key == "+" {
            setZoom(zoom * 1.1)
        } else if flags.isEmpty, key == "-" {
            setZoom(zoom / 1.1)
        } else if flags == .command && key == "c" {
            if pinView.selectedText != nil { copySelectedText() } else { copyImage() }
        } else if flags == .command && key == "s" {
            saveImage()
        } else if (flags.isEmpty || flags == .command) && key == "0" {
            setZoom(1)
        } else if let d = arrows[event.keyCode], flags.isEmpty || flags == .shift {
            let step: CGFloat = flags == .shift ? 10 : 1
            setFrameOrigin(CGPoint(x: frame.minX + d.x * step, y: frame.minY + d.y * step))
            pinView.layoutButtons()
        } else {
            super.keyDown(with: event)
        }
    }

    /// `Esc` first drops a text selection, then closes the pin.
    override func cancelOperation(_ sender: Any?) {
        if pinView.textSelection != nil {
            pinView.textSelection = nil
        } else {
            closePin()
        }
    }

    // MARK: Actions

    @objc func copyImage() {
        Exporter.copy(rep)
        pinView.flash("已复制")
    }

    @objc func copySelectedText() {
        guard let text = pinView.selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pinView.flash("已复制文字")
    }

    @objc func saveImage() {
        do {
            let url = try Exporter.save(rep, format: Settings.shared.imageFormat, directory: Settings.shared.saveDirectory)
            pinView.flash("已保存")
            HUD.show("已保存到 \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        } catch {
            pinView.flash("保存失败")
        }
    }

    @objc func zoomMenuItem(_ sender: NSMenuItem) { setZoom(CGFloat(sender.tag) / 100) }
    @objc func opacityMenuItem(_ sender: NSMenuItem) { setOpacity(CGFloat(sender.tag) / 100) }
    @objc func closeFromMenu() { closePin() }

    // MARK: Rotation

    /// Turns the picture 90° counter-clockwise.
    ///
    /// The button column rides on the picture's **top-right** corner (`PinView.buttonFrames`), so that corner is
    /// the pivot: the window keeps it and only swaps width and height. The rotate button therefore stays exactly
    /// under the pointer, which is what makes pressing it four times in a row possible at all. The visible
    /// consequence — the picture swings around that corner instead of its centre — is the price of a button that
    /// does not run away from the click that just happened.
    ///
    /// Not while the pencil's stage is open: the annotations are pinned to the picture in its old orientation.
    @objc func rotateImage() {
        guard !isEditing else { return }
        // A press while the picture is still swinging lands that turn straight away, so four quick presses turn
        // it four times instead of swallowing three.
        pinView.finishRotation()
        guard let turned = PinImage.rotatedCounterClockwise(rep), let current = pinView.image else { return }
        let old = PinView.pictureFrame(in: frame)
        let size = CGSize(width: old.height, height: old.width)
        // The column is pushed up when the picture is too short to hold it (`PinView.buttonFrames`), so a taller
        // picture would let it slide back down — 6pt for a 200×100 pin. Move the whole pin by that difference
        // instead: the button under the pointer is the one thing that must not move.
        func columnTop(_ size: CGSize) -> CGFloat {
            PinView.buttonFrames(picture: CGRect(x: PinView.borderInset, y: PinView.buttonInset,
                                                 width: size.width, height: size.height)).close.minY
        }
        let shift = columnTop(size) - columnTop(old.size)
        let picture = CGRect(origin: CGPoint(x: old.maxX - size.width, y: old.maxY - size.height + shift), size: size)
        var finalWindow = PinView.windowFrame(for: picture)
        // A wide picture becomes a tall one and can end up off the display. Moving is the lesser evil: the
        // buttons travel with it, which only means the next click has to find them again. A pin that was
        // already off every screen is left alone — it is parked there on purpose.
        if let visible = PinView.screen(containing: old)?.visibleFrame, old.intersects(visible),
           !visible.contains(finalWindow) {
            finalWindow.origin.x = min(max(finalWindow.minX, visible.minX), max(visible.minX, visible.maxX - finalWindow.width))
            finalWindow.origin.y = min(max(finalWindow.minY, visible.minY), max(visible.minY, visible.maxY - finalWindow.height))
        }

        // The turn itself: the picture spins about its own centre while that centre travels to where the turned
        // picture sits — the rigid motion that carries the old rect exactly onto the new one. The window grows
        // to everything the spin sweeps, so nothing is cut off on the way round, and the column is laid out
        // against the old picture for the length of it, so it holds still under the pointer.
        let fromCenter = CGPoint(x: old.midX, y: old.midY)
        let toCenter = CGPoint(x: picture.midX, y: picture.midY)
        let radius = hypot(old.width, old.height) / 2
        let swept = CGRect(x: min(fromCenter.x, toCenter.x) - radius,
                           y: min(fromCenter.y, toCenter.y) - radius,
                           width: abs(toCenter.x - fromCenter.x) + radius * 2,
                           height: abs(toCenter.y - fromCenter.y) + radius * 2)
        let stage = CGRect(x: swept.minX - PinView.borderInset, y: swept.minY - PinView.borderInset,
                           width: swept.width + PinView.borderInset + PinView.buttonInset,
                           height: swept.height + PinView.borderInset + PinView.buttonInset)
        let fromInView = CGPoint(x: fromCenter.x - stage.minX, y: stage.maxY - fromCenter.y)
        let toInView = CGPoint(x: toCenter.x - stage.minX, y: stage.maxY - toCenter.y)
        let pictureInView = CGRect(x: fromInView.x - old.width / 2, y: fromInView.y - old.height / 2,
                                   width: old.width, height: old.height)
        pinView.beginRotation(image: current, pictureRect: pictureInView,
                              fromCenter: fromInView, toCenter: toInView) { [weak self] in
            guard let self, !self.isClosing else { return }
            if let pair = self.translationPair {
                // Both halves, or pressing Y after the turn brings back the picture the wrong way round.
                self.translationPair = (PinImage.rotatedCounterClockwise(pair.original) ?? pair.original,
                                        PinImage.rotatedCounterClockwise(pair.translated) ?? pair.translated)
            }
            self.rep = turned
            self.baseSize = CGSize(width: self.baseSize.height, height: self.baseSize.width)
            // The annotations belonged to the picture in its old orientation.
            self.editHistory = PinEditHistory(base: turned)
            self.refreshImage()
            self.pictureChanged()
            self.setFrame(finalWindow, display: true)
            self.pinView.layoutButtons()
        }
        setFrame(stage, display: true)
    }

    // MARK: Text selection

    /// The picture the text layout was (or is being) recognized from.
    private var textSource: NSBitmapImageRep?
    private var textTask: Task<Void, Never>?

    /// Recognizes the pin's text in the background so it can be selected with the mouse; once per picture.
    func prepareText() { prepareText(after: .zero) }

    /// `after` lets a burst of picture changes — the rotate button pressed three times — settle into one
    /// recognition instead of three. 百度 OCR is billed per picture, and three of them for one turn is waste.
    private func prepareText(after delay: Duration) {
        guard textSource !== rep, let cg = rep.cgImage else { return }
        let source = rep
        textSource = source
        pinView.textLayout = nil
        textTask?.cancel()
        textTask = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let layout = try? await TextRecognizer.layout(cg, bounds: CGRect(origin: .zero, size: source.size))
            guard let self, !Task.isCancelled, self.rep === source else { return }
            self.pinView.textLayout = layout
        }
    }

    /// The picture changed (replaced, translated, rotated): the old text layout no longer fits.
    private func pictureChanged() {
        textSource = nil
        pinView.textLayout = nil
        prepareText(after: .milliseconds(350))
    }

    // MARK: Translation

    /// The untranslated and translated pictures once translated; `Y` switches between them.
    private var translationPair: (original: NSBitmapImageRep, translated: NSBitmapImageRep)?
    private(set) var showsTranslation = false
    private var isTranslating = false
    /// Replaceable for the self-checks, which translate without a network.
    var translate: (NSBitmapImageRep) async throws -> NSBitmapImageRep = { try await ImageTranslator.translate($0) }

    @objc func toggleTranslation() {
        if let pair = translationPair {
            showsTranslation.toggle()
            swapImage(showsTranslation ? pair.translated : pair.original)
            pinView.flash(showsTranslation ? "译文" : "原文")
            return
        }
        guard !isTranslating else { return }
        // Only the LLM engine needs the key.
        if translateUsesDefault, Settings.shared.translationConfig.engine == .llm, Settings.shared.apiKey.isEmpty {
            pinView.flash("请先在设置里填写翻译的 API Key")
            return
        }
        isTranslating = true
        pinView.flash("正在翻译…")
        let original = rep
        Task { @MainActor in
            defer { isTranslating = false }
            do {
                let translated = try await translate(original)
                translationPair = (original, translated)
                showsTranslation = true
                swapImage(translated)
                pinView.flash("已翻译 · Y 切换原文")
            } catch {
                pinView.flash((error as? LocalizedError)?.errorDescription ?? "翻译失败")
            }
        }
    }

    /// Whether `translate` is still the real translator (then engine requirements apply).
    var translateUsesDefault = true

    /// Shows another picture of the same size without resetting zoom or position.
    private func swapImage(_ newRep: NSBitmapImageRep) {
        rep = newRep
        // The picture itself changed (a translation, or back to the original): annotations drawn on the old one
        // no longer describe it, and neither does their undo stack.
        editHistory = PinEditHistory(base: newRep)
        refreshImage()
        pictureChanged()
    }

    /// Replaces the picture after annotating; the pin keeps its place and zoom.
    func replaceImage(_ newRep: NSBitmapImageRep) {
        translationPair = nil
        showsTranslation = false
        editHistory = PinEditHistory(base: newRep)
        show(newRep)
    }

    /// Applies a pencil session's result. Unlike `replaceImage` this keeps the base and the undo stacks, so the
    /// next pencil session can still take the previous ones back.
    func commitEdit(_ newRep: NSBitmapImageRep, bakedBase: NSBitmapImageRep?,
                    items: [AnnotationItem], undo: [[AnnotationItem]], redo: [[AnnotationItem]]) {
        if let bakedBase { editHistory.base = bakedBase }
        editHistory.items = items
        editHistory.undo = undo
        editHistory.redo = redo
        translationPair = nil
        showsTranslation = false
        show(newRep)
    }

    /// Redraws the pin around a new picture of the same point size; the pin keeps its place and zoom.
    private func show(_ newRep: NSBitmapImageRep) {
        let zoomNow = zoom
        rep = newRep
        baseSize = newRep.size
        refreshImage()
        pictureChanged()
        setZoom(zoomNow, anchor: CGPoint(x: frame.minX, y: frame.maxY), flash: false)
    }

    /// The pencil button, and the menu's 编辑: the screenshot toolbar over the pin, with the pin itself staying
    /// on screen so its buttons stay clickable. Pressing it again folds the toolbar away and keeps the edits
    /// (undo included); the toolbar's own 退出 / 保存 / 复制 end the pin (`CaptureSession.closesPin`), while ✓
    /// copies the picture and folds the toolbar away too.
    @objc func editWithTools() {
        if let session = CaptureSession.current, session.isEditingPin(self) {
            session.finishPinTools()
        } else {
            CaptureSession.beginPinTools(self)
        }
    }

    /// Whether the pencil is open. The buttons stay up for the whole session (`PinView.layoutButtons`), and the
    /// pencil wears its blue active face.
    var isEditing: Bool { pinView.isEditing }

    func setEditing(_ editing: Bool) {
        pinView.setEditing(editing)
    }

    var testing_view: PinView { pinView }

    @objc func closeAllFromMenu() { PinManager.shared.closeAll() }

    func closePin() {
        guard !isClosing else { return }
        isClosing = true
        // An open pencil session belongs to this pin; without this its stage would be left behind with nothing
        // under it.
        CaptureSession.current?.pinClosed(self)
        PinManager.shared.didClose(self)
        orderOut(nil)
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "", tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.tag = tag
            return item
        }
        if pinView.selectedText != nil {
            menu.addItem(item("复制选中文字", #selector(copySelectedText), "c"))
            menu.addItem(item("复制图片", #selector(copyImage)))
        } else {
            menu.addItem(item("复制", #selector(copyImage), "c"))
        }
        menu.addItem(item("保存", #selector(saveImage), "s"))
        menu.addItem(item("编辑", #selector(editWithTools), " "))
        menu.items.last?.keyEquivalentModifierMask = []
        let translateItem = item(translationPair == nil ? "翻译" : (showsTranslation ? "显示原文" : "显示译文"), #selector(toggleTranslation), "y")
        translateItem.keyEquivalentModifierMask = []
        menu.addItem(translateItem)
        let rotateItem = item("逆时针旋转 90°", #selector(rotateImage))
        rotateItem.isEnabled = !isEditing
        menu.addItem(rotateItem)
        menu.addItem(.separator())

        let zoomItem = NSMenuItem(title: "缩放", action: nil, keyEquivalent: "")
        let zoomMenu = NSMenu()
        for percent in [25, 50, 100, 150, 200, 300] {
            let i = item("\(percent)%", #selector(zoomMenuItem(_:)), tag: percent)
            i.state = abs(zoom * 100 - CGFloat(percent)) < 0.5 ? .on : .off
            zoomMenu.addItem(i)
        }
        zoomItem.submenu = zoomMenu
        menu.addItem(zoomItem)

        let opacityItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for percent in [100, 80, 60, 40, 20] {
            let i = item("\(percent)%", #selector(opacityMenuItem(_:)), tag: percent)
            i.state = abs(alphaValue * 100 - CGFloat(percent)) < 0.5 ? .on : .off
            opacityMenu.addItem(i)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(.separator())
        menu.addItem(item("关闭", #selector(closeFromMenu), "w"))
        menu.addItem(item("关闭全部贴图", #selector(closeAllFromMenu)))
        return menu
    }
}

/// The dots button under the close button. Pointing at it opens it into a 2×3 grid of dots, and that grid is
/// a handle for moving the pin: a screenshot that is all text has no blank pixel to grab, and this always has
/// some. It is a view of its own for the same reason the close button is — a click on it must not reach
/// `PinView`, which would take it for a text selection or for a drag starting on the picture.
final class PinHandleButton: NSView {
    static let diameter: CGFloat = 22
    /// The grid it opens into: two columns, three rows, sized to be grabbed without aiming.
    ///
    /// The width stays the folded button's — a plate that gets *wider* on hover reads as a different button
    /// next to the close button above it; growing taller alone reads as the same button opened.
    static let expandedSize = CGSize(width: 22, height: 34)

    /// Dragging is `PinView`'s job — it already knows how a pin follows the mouse.
    weak var pinView: PinView?

    private(set) var isExpanded = false
    /// True from the press to the release. The dots are then the view tracking a drag, and a drag dies with the
    /// view it started in — so nothing may fold them or hide them until the mouse comes up (see `mouseExited`
    /// and `PinView.layoutButtons`).
    private(set) var isDragging = false
    /// Where the button sits while it is folded; the grid grows from this frame's top-right corner.
    private var baseFrame: CGRect = .zero
    private var hovering = false
    private var pressed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        baseFrame = frame
        toolTip = "按住拖动贴图（截图里全是文字时不用找空白处）"
        setAccessibilityLabel("拖动贴图")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The folded frame. The open grid hangs down and to the left of the same top-right corner, so it stays
    /// outside the picture instead of growing over it.
    func setBase(frame: CGRect) {
        baseFrame = frame
        self.frame = isExpanded ? expandedFrame(from: frame) : frame
    }

    private func expandedFrame(from base: CGRect) -> CGRect {
        var frame = CGRect(x: base.maxX - Self.expandedSize.width, y: base.minY,
                           width: Self.expandedSize.width, height: Self.expandedSize.height)
        // Last line of defence for a pin too short to hold the whole column (`buttonFrames` already reserves the
        // room): keep the grid inside the pin rather than letting the window's bottom cut it in half. Only a pin
        // under about 24pt tall ever gets here, and then the grid may sit over the close button — moving the
        // pointer off the dots collapses it, so the × is still reachable.
        if let height = superview?.bounds.height, frame.maxY > height {
            frame.origin.y = max(0, height - frame.height)
        }
        return frame
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        frame = expanded ? expandedFrame(from: baseFrame) : baseFrame
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = .zero
        shadow.set()
        NSColor.black.withAlphaComponent(hovering || pressed ? 0.72 : 0.55).setFill()
        // Rounded square folded as well as open, at the same 6.5 pt corner as the close button above it: circles
        // sat in a column with a square read as two shapes, which is what got this sent back.
        let plate = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: GlyphButton.cornerRadius, yRadius: GlyphButton.cornerRadius)
        plate.fill()
        NSGraphicsContext.restoreGraphicsState()

        let spacing = isExpanded ? CGSize(width: 7, height: 9) : CGSize(width: 5.4, height: 5.6)
        let radius: CGFloat = isExpanded ? 2.2 : 1.5
        NSColor.white.setFill()
        for column in 0..<2 {
            for row in 0..<3 {
                let x = bounds.midX + (CGFloat(column) - 0.5) * spacing.width
                let y = bounds.midY + (CGFloat(row) - 1) * spacing.height
                NSBezierPath(ovalIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)).fill()
            }
        }
    }

    /// The grid opens as soon as the pointer is on it, so it is already the size of a handle by the time the
    /// user presses — opening it on the press meant the first attempt grabbed the small button instead.
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        setExpanded(true)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        // Not while dragging. The window chases the pointer and is always a frame or two behind it, so on a
        // quick flick the pointer steps off the dots — folding them then would pull the handle out from under
        // the hand in the middle of the gesture.
        if !isDragging { setExpanded(false) }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        isDragging = true
        needsDisplay = true
        guard let window, let pinView else { return }
        guard pinView.usesNativeDrag else {
            pinView.beginDrag()
            return
        }
        pinView.beginNativeDrag(with: event, in: window)
    }

    override func mouseDragged(with event: NSEvent) {
        pinView?.drag(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        endNativeDrag()
    }

    /// Back to the folded look. Called by the mouse-up when one arrives, and by the pin when the window server
    /// swallows it.
    func endNativeDrag() {
        guard pressed || isDragging else { return }
        pressed = false
        isDragging = false
        needsDisplay = true
        pinView?.endDrag()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// Draws the pinned image with a thin border that shows whether this pin is the active one.
final class PinView: NSView {
    weak var window_: PinWindow?
    var image: NSImage? { didSet { needsDisplay = true } }

    /// A quarter turn in flight: the picture swinging round, where it sits in the temporarily enlarged view,
    /// and when the swing started. The window grows for the length of the turn (the old picture sweeps a
    /// quarter circle), the buttons are laid out against `pictureRect` so they hold still, and the model change
    /// happens in `completion` when the turn lands.
    private struct Rotation {
        var image: NSImage
        /// Where the old picture draws, which is also where `fromCenter` is.
        var pictureRect: CGRect
        var fromCenter: CGPoint
        /// Where the turned picture's centre ends up. The turn is the rigid motion that carries the old rect
        /// onto the new one: spin about the centre while that centre travels — exactly the rotation about the
        /// one fixed point the two rects share, but easier to reason about.
        var toCenter: CGPoint
        var started: Date
        var duration: TimeInterval
        var timer: Timer?
        var completion: () -> Void
    }
    private var rotation: Rotation?
    var isRotating: Bool { rotation != nil }
    /// Watches for the button coming up that ends a window-server drag — the mouse-up may never reach this view.
    private var nativeDragWatch: Timer?
    private let label = ToastView()
    private let closeButton = GlyphButton(glyph: .close)
    /// The pencil between the × and the dots: the screenshot's toolbar over this pin (`editWithTools`).
    private let toolsButton = GlyphButton(glyph: .edit)
    /// The counter-clockwise arrow under the pencil. It turns the picture 90° (`PinWindow.rotateImage`), and
    /// because the rotation pivots on the picture's top-right corner this button stays exactly under the pointer
    /// for the next click.
    private let rotateButton = GlyphButton(glyph: .rotate)
    private let handleButton = PinHandleButton(frame: .zero)
    /// Where the drag started: the mouse and the window's origin.
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    /// The picture's recognized text, in image points; nil until recognized or when there is none.
    var textLayout: TextLayout? { didSet { textSelection = nil } }
    var textSelection: TextSpan? { didSet { needsDisplay = true } }
    private var selectingText = false
    /// Whether the pointer is over the pin at all (picture, margin or buttons).
    private var pointerInside = false
    /// Whether the pointer is over the **picture**. The two buttons sit outside it, and this is what shows them.
    private var pointerOnPicture = false
    /// Whether the pointer is anywhere in the buttons' strip — the gaps included, see `buttonStripRect`.
    private var pointerOnButtonStrip = false
    /// The picture's and the button strip's tracking areas, rebuilt with the view's geometry.
    private var pictureTracking: NSTrackingArea?
    private var stripTracking: NSTrackingArea?
    private var stripRect: CGRect = .null
    /// The grips' tracking areas, rebuilt whenever the view's geometry changes (`updateTrackingAreas`).
    private var gripTracking: [NSTrackingArea] = []

    /// Whether the pencil's toolbar is open over this pin. The buttons stay visible for the whole session —
    /// they are the only way back out of it — and the picture itself is covered by the editing stage, so the
    /// pin's own drag, text selection and resize grips stand down.
    private(set) var isEditing = false

    func setEditing(_ editing: Bool) {
        guard editing != isEditing else { return }
        isEditing = editing
        toolsButton.isActive = editing
        toolsButton.toolTip = editing ? "完成编辑（保存到贴图）" : "编辑贴图（标注工具）"
        toolsButton.setAccessibilityLabel(editing ? "完成编辑" : "编辑贴图")
        layoutButtons()
        needsDisplay = true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(label)
        closeButton.isHidden = true
        closeButton.handler = { [weak self] in self?.window_?.closePin() }
        closeButton.toolTip = "关闭贴图（Esc）"
        closeButton.setAccessibilityLabel("关闭贴图")
        addSubview(closeButton)
        toolsButton.isHidden = true
        toolsButton.handler = { [weak self] in self?.window_?.editWithTools() }
        toolsButton.toolTip = "编辑贴图（标注工具）"
        toolsButton.setAccessibilityLabel("编辑贴图")
        addSubview(toolsButton)
        rotateButton.isHidden = true
        rotateButton.handler = { [weak self] in self?.window_?.rotateImage() }
        rotateButton.toolTip = "逆时针旋转 90°"
        rotateButton.setAccessibilityLabel("逆时针旋转 90°")
        addSubview(rotateButton)
        handleButton.isHidden = true
        handleButton.pinView = self
        addSubview(handleButton)
        layoutButtons()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Starts the quarter turn. `pictureRect` is where the old picture sits in this (already enlarged) view,
    /// `fromCenter` is its centre and `toCenter` where that centre ends up. Eased out: quick to answer the
    /// press, then settling instead of stopping dead.
    func beginRotation(image: NSImage, pictureRect: CGRect, fromCenter: CGPoint, toCenter: CGPoint,
                       duration: TimeInterval = 0.2, completion: @escaping () -> Void) {
        rotation?.timer?.invalidate()
        var state = Rotation(image: image, pictureRect: pictureRect, fromCenter: fromCenter, toCenter: toCenter,
                             started: Date(), duration: duration, timer: nil, completion: completion)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, let current = self.rotation else { timer.invalidate(); return }
            if Date().timeIntervalSince(current.started) >= current.duration {
                self.finishRotation()
            } else {
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        state.timer = timer
        rotation = state
        needsDisplay = true
    }

    /// Lands the turn now. Called by the timer, and by a second press on the rotate button — four quick presses
    /// have to turn the picture four times, not swallow three of them.
    func finishRotation() {
        guard let state = rotation else { return }
        state.timer?.invalidate()
        rotation = nil
        needsDisplay = true
        state.completion()
    }

    /// 0…1, eased out.
    private var rotationProgress: CGFloat {
        guard let rotation else { return 0 }
        let t = min(1, max(0, Date().timeIntervalSince(rotation.started) / rotation.duration))
        return CGFloat(1 - pow(1 - t, 3))
    }

    /// Where the buttons' picture is while a turn is in flight: the old one, held at the corner it is turning
    /// around, so the column does not slide out from under the pointer.
    private var layoutPictureRect: CGRect { rotation?.pictureRect ?? imageRect }

    /// Distance between a button and the picture, and between the two buttons.
    static let buttonGap: CGFloat = 4

    /// Whether the buttons fit on screen beside the picture. There is only ever one place for them — a column
    /// just outside the picture's right edge. Moving them above the picture was tried and taken out again: a
    /// pin against the right edge of the display usually sticks out of the *top* as well, so they only moved
    /// from one off-screen spot to another. A pin pushed off the right edge now simply takes its buttons with
    /// it, and they come back when it is dragged back in.
    ///
    /// Pure, so `--check pin-buttons` can drive every case without putting a window on screen.
    static func showsButtons(picture: CGRect, visible: CGRect) -> Bool {
        visible.maxX - picture.maxX >= GlyphButton.diameter + buttonGap
    }

    /// Where the buttons go beside a picture at `rect`, in that view's flipped coordinates: × on top, the
    /// pencil, the rotate arrow, the dots handle at the bottom, all outside the picture. `rotate` is nil when
    /// the picture is too short to hold four.
    struct ButtonLayout {
        var close: CGRect
        var tools: CGRect
        var rotate: CGRect?
        var handle: CGRect
    }

    /// The button frames for a picture at `rect`.
    ///
    /// Top-aligned with the picture; pushed up when the picture is too short to hold the column beside it, but
    /// never past the top of the view, which would clip them. The room reserved is for the *open* handle, not
    /// the folded one: pointing at the dots grows them into a 2×3 grid that hangs 12pt below the folded size.
    ///
    /// Four buttons need 100pt of folded height, and the window offers the picture's height plus 40 — so a pin
    /// under ~60pt tall would have its dots hanging out of the window, half cut off and impossible to grab. On
    /// those pins the rotate arrow gives way (it is the newest button, and the right-click menu still turns the
    /// picture): the three-button column fits down to ~34pt, which is where this worked before rotation existed.
    /// Shorter still, the dots are pushed up inside the window, over the button above — `PinHandleButton`'s
    /// expanded grid already does the same in that corner of the layout.
    static func buttonFrames(picture rect: CGRect) -> ButtonLayout {
        let size = GlyphButton.diameter
        let x = rect.maxX + buttonGap
        let area = CGRect(x: 0, y: 0, width: rect.maxX + buttonInset, height: rect.maxY + borderInset)
        let expandedExtra = PinHandleButton.expandedSize.height - size

        /// The column's top for `count` buttons: the picture's top when it fits there, otherwise as far up as
        /// it can go without leaving the window.
        func columnTop(_ count: Int) -> CGFloat {
            let needed = size * CGFloat(count) + buttonGap * CGFloat(count - 1) + expandedExtra + 4
            return min(rect.minY, max(area.maxY - needed, area.minY))
        }

        let fourTop = columnTop(4)
        let showsRotate = fourTop + size * 4 + buttonGap * 3 <= area.maxY + 0.5
        let count = showsRotate ? 4 : 3
        let top = columnTop(count)
        let close = CGRect(x: x, y: top, width: size, height: size)
        let tools = close.offsetBy(dx: 0, dy: size + buttonGap)
        let rotate = showsRotate ? tools.offsetBy(dx: 0, dy: size + buttonGap) : nil
        var handle = CGRect(x: x, y: top + CGFloat(count - 1) * (size + buttonGap), width: size, height: size)
        handle.origin.y = min(handle.minY, max(area.minY, area.maxY - size))
        return ButtonLayout(close: close, tools: tools, rotate: rotate, handle: handle)
    }

    /// The screen the picture is on. A pin sitting off every screen (the offscreen windows the checks use)
    /// falls back to the main one, which leaves it in the default placement.
    static func screen(containing picture: CGRect) -> NSScreen? {
        let centre = CGPoint(x: picture.midX, y: picture.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(centre) }) { return screen }
        func overlap(_ screen: NSScreen) -> CGFloat {
            let part = screen.frame.intersection(picture)
            return part.isNull ? 0 : part.width * part.height
        }
        return NSScreen.screens.max { overlap($0) < overlap($1) } ?? NSScreen.main
    }

    /// Puts the three buttons where they belong for where the pin is right now, and keeps them out of sight when
    /// the pointer is elsewhere or when the pin has been dragged off the right edge of the display.
    func layoutButtons() {
        guard let window = window_ else { return }
        let picture = PinView.pictureFrame(in: window.frame)
        let visible = PinView.screen(containing: picture)?.visibleFrame ?? window.frame
        let frames = PinView.buttonFrames(picture: layoutPictureRect)
        closeButton.frame = frames.close
        toolsButton.frame = frames.tools
        rotateButton.frame = frames.rotate ?? .zero
        handleButton.setBase(frame: frames.handle)
        let visibleOnScreen = PinView.showsButtons(picture: picture, visible: visible)
        // The one thing that outranks "the pointer is elsewhere": a drag that started on the dots. Hiding the
        // view a drag started in ends the drag, and the pointer is off the dots for a frame or two on every
        // quick flick — that is the pin stopping halfway with the pointer running on without it.
        let draggingHandle = handleButton.isDragging
        // The buttons come with the pointer being over the picture, and stay while it is anywhere in their strip.
        // The strip — not the buttons themselves: there is a gap between the picture and the buttons and another
        // between any two of them, and the pointer crosses both on its way to a click. Counting only the buttons
        // made them vanish from under the pointer exactly in those gaps.
        let showButtons = visibleOnScreen && (isEditing || pointerOnPicture || pointerOnButtonStrip)
        closeButton.isHidden = !showButtons
        toolsButton.isHidden = !showButtons
        // No room for four: the rotate arrow steps aside rather than pushing the dots out of the window.
        rotateButton.isHidden = !showButtons || frames.rotate == nil
        // Turning the picture while the pencil's stage is open would leave every annotation pointing at the old
        // corner. Dimmed, not hidden: the column keeps its shape and the button is still a thing that exists.
        rotateButton.isEnabled = !isEditing
        handleButton.isHidden = !showButtons && !draggingHandle
        if !draggingHandle, !pointerInside || !visibleOnScreen { handleButton.setExpanded(false) }
        // The strip moves with the buttons (a drag, a zoom), so its tracking area has to follow; rebuilding on
        // every layout pass would be wasteful, and rebuilding when it actually moved is free.
        if buttonStripRect() != stripRect { updateTrackingAreas() }
    }

    /// The pin is zoomed by resizing it, so the buttons have to follow.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutButtons()
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Blank space on the left and at the bottom of the picture: enough for the border to sit outside it and
    /// for the glow that spreads from the border (see `draw`).
    static let borderInset: CGFloat = 10

    /// Blank space on the right and at the top: the close, edit and dots buttons live outside the picture, so
    /// the window has to reserve room for them. They are the first thing to go when there is no room on screen —
    /// see `placement`.
    static let buttonInset: CGFloat = GlyphButton.diameter + buttonGap + 4

    /// Where the picture sits inside the view. Not centred: the buttons need more room than the glow does.
    var imageRect: CGRect {
        CGRect(x: bounds.minX + Self.borderInset, y: bounds.minY + Self.buttonInset,
               width: bounds.width - Self.borderInset - Self.buttonInset,
               height: bounds.height - Self.borderInset - Self.buttonInset)
    }

    /// The window frame that shows `picture` with its border, glow and buttons around it.
    static func windowFrame(for picture: CGRect) -> CGRect {
        CGRect(x: picture.minX - borderInset, y: picture.minY - borderInset,
               width: picture.width + borderInset + buttonInset,
               height: picture.height + borderInset + buttonInset)
    }

    /// The picture inside a window (or view) frame — the inverse of `windowFrame(for:)`.
    static func pictureFrame(in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + borderInset, y: frame.minY + borderInset,
               width: frame.width - borderInset - buttonInset,
               height: frame.height - borderInset - buttonInset)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let rotation { return drawRotation(rotation) }
        let rect = imageRect
        NSGraphicsContext.current?.imageInterpolation = (window_?.zoom ?? 1) >= 2 ? .none : .high
        image?.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        if let textSelection, let textLayout {
            themeColor.withAlphaComponent(0.3).setFill()
            for line in textLayout.rects(for: textSelection) { NSBezierPath(rect: viewRect(line)).fill() }
        }
        // The border keeps the colour the user picked whether or not the pin is focused. It is there to make the
        // picture tell itself apart from the desktop; a grey outline stopped doing that the moment the user
        // clicked anywhere else.
        let color = Settings.shared.themeColor
        let width: CGFloat = 1.5
        // The border hugs the picture from the outside and follows its rounded corners — the radius was baked
        // into the pixels in image points, so at anything but 100% it has to be scaled with the picture.
        let radius = Settings.shared.cornerRadius * (window_?.zoom ?? 1)
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: -width / 2, dy: -width / 2),
                                  xRadius: radius + width / 2, yRadius: radius + width / 2)
        border.lineWidth = width

        // Glow: rings laid outside the border, each fainter than the last. Overlapping is the point — two
        // neighbours cover every spot, so the alpha stacks up into a halo that fades with distance instead of
        // reading as one more outline.
        //
        // Not `NSShadow`: blurring a hairline leaves almost no ink, so it came out as a second thin outline
        // instead of light. And it is clipped to *outside* the picture — a centred stroke would also paint
        // inwards and tint the screenshot's own border pixels, which is exactly what the user wants to keep.
        // The window's own system shadow is off as well (`PinWindow.init`): it is black, so it drew a dark rim
        // around the border and drowned the glow.
        //
        // A second, additive (`plusLighter`) pass was tried, to make the halo show on a dark desktop: a
        // translucent copy of the colour can only *tint* what is behind it, so on black it comes out nearly
        // black. It worked, but the user found the result too strong and asked for this strength back.
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius))
        outside.windingRule = .evenOdd
        outside.addClip()
        for step in 0..<8 {
            let spread = width / 2 + CGFloat(step) * 0.9
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -spread, dy: -spread),
                                    xRadius: radius + spread, yRadius: radius + spread)
            ring.lineWidth = 1.8
            color.withAlphaComponent(0.20 * pow(0.78, Double(step))).setStroke()
            ring.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        color.setStroke()
        border.stroke()
    }

    /// The zoom percentage, over the picture's top-right corner. It used to sit on the window's bottom-right
    /// corner, which is the picture's bottom edge plus the border margin — half on the picture, half on the
    /// border, and not where anyone looks for it.
    func flash(_ text: String) {
        label.show(text, duration: 1.2, maxWidth: max(120, bounds.width))
        let inset: CGFloat = 8
        let picture = imageRect
        label.setFrameOrigin(CGPoint(x: max(picture.minX, picture.maxX - label.frame.width - inset),
                                     y: picture.minY + inset))
    }

    override func mouseDown(with event: NSEvent) {
        // The editing stage sits over the picture; a press that still reaches this view (on the margins
        // around it) must not start a drag or a text selection under the toolbar.
        if isEditing { return }
        window?.makeKey()
        let p = convert(event.locationInWindow, from: nil)
        // The grips reach only outside the picture, so this can never take a press away from the text.
        if beginResize(at: p) { return }
        if event.clickCount >= 2 {
            // Closing is Esc's job; double-click selects a word, triple-click the line.
            if let layout = textLayout, textPosition(at: p) != nil {
                textSelection = event.clickCount == 2 ? layout.word(at: imagePoint(p)) : layout.line(at: imagePoint(p))
            }
            return
        }
        // Pressing on text selects it, like a text field; anywhere else drags the pin.
        if let position = textPosition(at: p) {
            if event.modifierFlags.contains(.shift), let current = textSelection {
                textSelection = TextSpan(anchor: current.anchor, focus: position)
            } else {
                textSelection = TextSpan(anchor: position, focus: position)
            }
            selectingText = true
            return
        }
        textSelection = nil
        guard let window else { return }
        guard usesNativeDrag else {
            dragStart = (NSEvent.mouseLocation, window.frame.origin)
            return
        }
        beginNativeDrag(with: event, in: window)
    }

    /// Whether a drag should be handed to the window server.
    ///
    /// Two cases keep the hand-driven path. The self-checks feed fake events, and the server's drag would sit
    /// waiting for a mouse-up that never comes from them. And while the pencil's stage is open, the stage has to
    /// travel with the pin in the same event — that sync hangs off `setFrameOrigin`, which a server drag never
    /// calls, and a stage a frame behind the picture reads as a gap between them.
    var usesNativeDrag: Bool { !SelfCheck.isRunning && !isEditing }

    /// Drags the pin the way a title bar does, through the window server.
    ///
    /// Not with `setFrameOrigin` per mouse event: since macOS 14 AppKit paces window frame changes with the
    /// display, and a window moved by hand that way runs a frame or two behind the pointer — the whole drag
    /// reads as laggy. The window server's own drag is what every window uses, and it is smooth at any size.
    /// It returns straight away and the drag carries on in the server; a mouse-up may never reach this view, so
    /// a local monitor is what tells us the gesture is over.
    func beginNativeDrag(with event: NSEvent, in window: NSWindow) {
        window.performDrag(with: event)
        // The server runs the drag from here and a mouse-up may never reach this view, so the physical button is
        // watcher enough — and it costs nothing while the button is still down.
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if NSEvent.pressedMouseButtons & 1 == 0 { self.finishNativeDrag() }
        }
        RunLoop.main.add(timer, forMode: .common)
        nativeDragWatch = timer
    }

    private func finishNativeDrag() {
        guard nativeDragWatch != nil else { return }
        nativeDragWatch?.invalidate()
        nativeDragWatch = nil
        handleButton.endNativeDrag()
        endDrag()
    }

    override func mouseDragged(with event: NSEvent) {
        if resize != nil {
            resizeDrag(to: NSEvent.mouseLocation)
            return
        }
        if selectingText {
            extendTextSelection(to: convert(event.locationInWindow, from: nil))
            return
        }
        drag(to: NSEvent.mouseLocation)
    }

    // MARK: Text

    var selectedText: String? {
        guard let textSelection, let textLayout else { return nil }
        let text = textLayout.text(for: textSelection)
        return text.isEmpty ? nil : text
    }

    private var imageSize: CGSize { image?.size ?? imageRect.size }

    private func imagePoint(_ p: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: (p.x - rect.minX) * imageSize.width / max(rect.width, 1),
                       y: (p.y - rect.minY) * imageSize.height / max(rect.height, 1))
    }

    /// The picture on its way round: spun about its own centre while that centre travels to where the turned
    /// picture sits, which is the rotation that carries the old rect exactly onto the new one — no jump when it
    /// lands. The border turns with it so the picture never looks bare; the glow is left out for two tenths of
    /// a second rather than composited through a rotation.
    private func drawRotation(_ state: Rotation) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let progress = rotationProgress
        // Negative turns the picture counter-clockwise on screen: this view is flipped, so a positive rotation
        // here reads as clockwise.
        let angle = -CGFloat.pi / 2 * progress
        let center = CGPoint(x: state.fromCenter.x + (state.toCenter.x - state.fromCenter.x) * progress,
                             y: state.fromCenter.y + (state.toCenter.y - state.fromCenter.y) * progress)
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        ctx.translateBy(x: -state.fromCenter.x, y: -state.fromCenter.y)
        NSGraphicsContext.current?.imageInterpolation = .high
        state.image.draw(in: state.pictureRect, from: .zero, operation: .copy, fraction: 1,
                         respectFlipped: true, hints: nil)
        let width: CGFloat = 1.5
        let radius = Settings.shared.cornerRadius * (window_?.zoom ?? 1)
        Settings.shared.themeColor.setStroke()
        let border = NSBezierPath(roundedRect: state.pictureRect.insetBy(dx: -width / 2, dy: -width / 2),
                                  xRadius: radius + width / 2, yRadius: radius + width / 2)
        border.lineWidth = width
        border.stroke()
    }

    private func viewRect(_ r: CGRect) -> CGRect {
        let rect = imageRect
        let sx = rect.width / max(imageSize.width, 1), sy = rect.height / max(imageSize.height, 1)
        return CGRect(x: rect.minX + r.minX * sx, y: rect.minY + r.minY * sy, width: r.width * sx, height: r.height * sy)
    }

    /// The caret under a view point when it is on recognized text.
    func textPosition(at p: CGPoint) -> TextPosition? {
        textLayout?.hitTest(imagePoint(p))
    }

    func extendTextSelection(to p: CGPoint) {
        guard let textLayout, let position = textLayout.nearestPosition(to: imagePoint(p)) else { return }
        textSelection?.focus = position
    }

    override func mouseEntered(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        window_?.prepareText()
        pointerInside = true
        // A drag that never got its mouseUp — the pin was hidden while the dots were held, say — would keep the
        // dots pinned open for good, since the handle outranks "the pointer is elsewhere". Coming back onto the
        // pin with no button down means that drag is over.
        if NSEvent.pressedMouseButtons == 0 { endDrag() }
        // The buttons depend on where the pin is on screen, and it may have been dragged since the last time
        // they were shown.
        updatePointerZone(at: p)
        layoutButtons()
        // Entering one of the grips: say so with the pointer. There is no mouse-moved event to do it — see
        // `updateTrackingAreas`.
        if resizeHandle(at: p) != nil { applyCursor(at: p) }
    }

    /// Leaving the pin is the only thing this has to notice: the grips sit *inside* this view and each of them
    /// has an exit event of its own, so stepping from the band onto the picture is not leaving anything. It used
    /// to be taken for one, which folded the dots and — while the buttons still hid with the pointer — made the
    /// pin look dead the moment the pointer was over the picture.
    override func mouseExited(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Off the picture (onto the margin, say) takes the buttons with it — unless the pointer lands on one of
        // them, which is what `hoveringClose` / `hoveringHandle` are for.
        updatePointerZone(at: p)
        guard !bounds.contains(p) else {
            // Off a grip, still on the pin: just say what the pointer is over now (no mouse-moved event is
            // coming to do it — see `updateTrackingAreas`).
            applyCursor(at: p)
            return
        }
        pointerInside = false
        layoutButtons()
    }

    /// One tracking area per grip, so the pointer turns into a resize cursor the moment it crosses into one.
    /// Not `mouseMoved` (only the key window is sent those) and not cursor rects (an inactive app does not get
    /// to set the cursor): a pin is a `.nonactivatingPanel` and the capture flow hands activation back to the
    /// previous app, so a freshly pinned window is neither key nor frontmost. `activeAlways` tracking areas are
    /// the one mechanism that works either way — the dots' expand-on-hover has always relied on it, which is
    /// why the handle grows without a click while the cursor never changed.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in gripTracking { removeTrackingArea(area) }
        gripTracking = []
        if let pictureTracking { removeTrackingArea(pictureTracking) }
        if let stripTracking { removeTrackingArea(stripTracking) }
        // The picture and the buttons' strip: the buttons are shown by the pointer being over one of them, and
        // that has to work while the pin is neither key nor frontmost — the same reason the grips have areas.
        let picture = NSTrackingArea(rect: imageRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(picture)
        pictureTracking = picture
        stripRect = buttonStripRect()
        let strip = NSTrackingArea(rect: stripRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(strip)
        stripTracking = strip
        for handle in ResizeHandle.allCases {
            for rect in gripRects(handle) {
                let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
                addTrackingArea(area)
                gripTracking.append(area)
            }
        }
    }

    var testing_closeButton: GlyphButton { closeButton }
    var testing_toolsButton: GlyphButton { toolsButton }
    var testing_rotateButton: GlyphButton { rotateButton }
    /// The turn in flight, for the self-checks: 0…1 eased, and the angle it is drawn at (negative is the
    /// counter-clockwise direction this view reads as).
    var testing_rotationProgress: CGFloat? { rotation == nil ? nil : rotationProgress }
    var testing_rotationAngle: CGFloat? { rotation == nil ? nil : -CGFloat.pi / 2 * rotationProgress }
    func testing_finishRotation() { finishRotation() }
    var testing_handleButton: PinHandleButton { handleButton }
    /// Whether the four buttons are on screen right now (the pencil keeps them up for its whole session).
    var testing_buttonsVisible: Bool {
        !closeButton.isHidden && !toolsButton.isHidden && !rotateButton.isHidden && !handleButton.isHidden
    }
    /// Whether the pin thinks the pointer is on it — what the buttons' visibility hangs on.
    var testing_pointerInside: Bool { pointerInside }
    /// The areas the grips are tracked in, for the self-check to compare against `gripRects`.
    var testing_gripTrackingRects: [CGRect] { gripTracking.map(\.rect) }

    override func mouseMoved(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// Points the cursor at what is under `p`: a grip says so with a resize cursor, the way a window edge does,
    /// text says so with an I-beam, everything else is an open hand. Nothing is drawn for the grips — the pin's
    /// border and glow are the owner's, and eight dots sitting on them would be a different-looking pin.
    func applyCursor(at p: CGPoint) {
        updatePointerZone(at: p)
        if let handle = resizeHandle(at: p) { return handle.cursor.set() }
        (textPosition(at: p) != nil ? NSCursor.iBeam : NSCursor.openHand).set()
    }

    /// The whole strip the two buttons live in: from the picture's right edge to the window's, spanning both
    /// buttons, the gap between them and the gap that separates them from the picture. Every one of those gaps
    /// is on the way to a click, so all of them have to keep the buttons up.
    private func buttonStripRect() -> CGRect {
        guard window_ != nil else { return .null }
        let column = closeButton.frame.union(toolsButton.frame).union(handleButton.frame)
        // The dots grow downward on hover; the strip has to cover where they will be, not only where they are.
        let growth = PinHandleButton.expandedSize.height - GlyphButton.diameter
        return CGRect(x: layoutPictureRect.maxX, y: column.minY,
                      width: max(0, bounds.maxX - layoutPictureRect.maxX), height: column.height + growth)
    }

    /// Keeps "the pointer is over the picture, or in the buttons' strip" up to date — the only two things that
    /// show the buttons. Called from the tracking areas and from wherever the cursor is set: a pin that is not
    /// the key window gets no mouse-moved events to lean on (see `updateTrackingAreas`), and a pin appears under a
    /// pointer that may already be over the picture without ever crossing its edge.
    private func updatePointerZone(at p: CGPoint) {
        let onPicture = imageRect.contains(p)
        let onStrip = buttonStripRect().contains(p)
        guard onPicture != pointerOnPicture || onStrip != pointerOnButtonStrip else { return }
        pointerOnPicture = onPicture
        pointerOnButtonStrip = onStrip
        layoutButtons()
    }

    /// The cursor for where the pointer is right now. A pin appears *under* a pointer that has not moved, so no
    /// mouse-moved event is coming: without this a freshly pinned window kept whatever cursor was there until
    /// it was dragged, which is exactly how the grips felt like they did not work.
    func applyCursorForPointer() {
        guard let window, window.isVisible else { return }
        applyCursor(at: convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

    override func resetCursorRects() {
        // The grips go in as cursor rects as well as being set from `mouseMoved`: AppKit applies these itself
        // the moment the pointer is in one — including as a window is ordered in under a standing pointer.
        for handle in ResizeHandle.allCases {
            for rect in gripRects(handle) { addCursorRect(rect, cursor: handle.cursor) }
        }
        addCursorRect(bounds, cursor: .openHand)
    }

    func drag(to mouse: CGPoint) {
        guard let dragStart, let window else { return }
        window.setFrameOrigin(CGPoint(x: dragStart.origin.x + mouse.x - dragStart.mouse.x, y: dragStart.origin.y + mouse.y - dragStart.mouse.y))
        // Dragging can push the pin against a screen edge, which moves the buttons (see `placement`).
        layoutButtons()
    }

    /// The window gives the view its real bounds when it installs it, and the grips' cursor rects are computed
    /// from where the picture sits inside those bounds: ask for them again once the view is really in place.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    /// Starts a drag from where the mouse is now — the dots handle uses this, since it has no drag of its own.
    func beginDrag() {
        guard let window else { return }
        dragStart = (NSEvent.mouseLocation, window.frame.origin)
    }

    // MARK: Resizing

    /// How far outside the picture the grips reach, measured away from it. Past that the pin moves as it always
    /// did: the right and top margins are 30 pt wide because the buttons live there, and dragging *those*
    /// should not resize.
    private static let resizeBand: CGFloat = 8
    /// How far a corner reaches *back* along the two sides that meet there. A corner is a small target to aim
    /// at: the pointer lands a dozen points along one of its sides at least as often as it lands on the corner
    /// itself, and an 8×8 square was small enough that the four corners read as "not resizable at all". The
    /// reach is measured along the bands the sides already have, so it does not depend on how much blank
    /// margin that side of the pin happens to have (the left and bottom have only 10 pt to give).
    private static let cornerReach: CGFloat = 20
    /// …and how far *inside* the picture the grips reach. The band used to stop dead at the border line, which
    /// meant aiming exactly at a hairline; coming at the edge from inside the picture is just as natural, and
    /// that is what this takes. Small on purpose: every point inside is a point of screenshot that no longer
    /// starts a text selection. Capped at a quarter of the picture so a tiny pin does not turn into all grips.
    private static let resizeInner: CGFloat = 6

    /// What one grip covers, in this view's coordinates. The picture's edge runs through the middle of every
    /// grip: `resizeBand` outside it, `resizeInner` inside. A side gets one band; a corner gets a square over
    /// the corner plus two arms reaching `cornerReach` back along the sides that meet there.
    ///
    /// Every piece stops where the next one begins, so no two grips overlap: the cursor rects and the tracking
    /// areas can be built in any order and still agree with the hit test.
    func gripRects(_ handle: ResizeHandle) -> [CGRect] {
        let r = imageRect
        let band = Self.resizeBand, reach = Self.cornerReach
        let inner = min(Self.resizeInner, min(r.width, r.height) / 4)
        // The bands straddling each edge: from `band` outside to `inner` inside.
        let left = r.minX - band, right = r.maxX - inner
        let top = r.minY - band, bottom = r.maxY - inner
        let across = band + inner
        // How far the arms run past the corner's square.
        let arm = max(0, reach - inner)
        switch handle {
        case .topLeft:
            return [CGRect(x: left, y: top, width: across, height: across),
                    CGRect(x: left, y: r.minY + inner, width: across, height: arm),
                    CGRect(x: r.minX + inner, y: top, width: arm, height: across)]
        case .topRight:
            return [CGRect(x: right, y: top, width: across, height: across),
                    CGRect(x: right, y: r.minY + inner, width: across, height: arm),
                    CGRect(x: r.maxX - reach, y: top, width: arm, height: across)]
        case .bottomRight:
            return [CGRect(x: right, y: bottom, width: across, height: across),
                    CGRect(x: right, y: r.maxY - reach, width: across, height: arm),
                    CGRect(x: r.maxX - reach, y: bottom, width: arm, height: across)]
        case .bottomLeft:
            return [CGRect(x: left, y: bottom, width: across, height: across),
                    CGRect(x: left, y: r.maxY - reach, width: across, height: arm),
                    CGRect(x: r.minX + inner, y: bottom, width: arm, height: across)]
        case .top:
            return [CGRect(x: r.minX + reach, y: top, width: max(0, r.width - 2 * reach), height: across)]
        case .right:
            return [CGRect(x: right, y: r.minY + reach, width: across, height: max(0, r.height - 2 * reach))]
        case .bottom:
            return [CGRect(x: r.minX + reach, y: bottom, width: max(0, r.width - 2 * reach), height: across)]
        case .left:
            return [CGRect(x: left, y: r.minY + reach, width: across, height: max(0, r.height - 2 * reach))]
        }
    }


    /// The grip under a point, or nil. The grips are the same eight `ResizeHandle`s the screenshot's
    /// selection has. They straddle the picture's edge — see `gripRects`, which is the only thing that decides
    /// where a grip is: the picture's inside is not off limits any more, its last few points belong to the
    /// grips so that coming at the edge from inside works.
    func resizeHandle(at p: CGPoint) -> ResizeHandle? {
        // While the pencil is open the picture is being edited, not resized; the stage covers most of the
        // grips anyway, and a zoom would leave the annotations behind.
        guard !isEditing, bounds.contains(p) else { return nil }
        return ResizeHandle.allCases.first { handle in gripRects(handle).contains { $0.contains(p) } }
    }

    /// A resize in progress: the point that stays put and where the grip was, both in screen coordinates — the
    /// space mouse events arrive in, and the space the window's own frame lives in.
    private struct Resize {
        var anchor: CGPoint
        var grip: CGPoint
        var startZoom: CGFloat
    }
    private var resize: Resize?

    /// A point in this (flipped) view as screen coordinates.
    private func screenPoint(_ p: CGPoint) -> CGPoint {
        guard let window else { return p }
        return CGPoint(x: window.frame.minX + p.x, y: window.frame.maxY - p.y)
    }

    /// Starts a resize from the grip under `p`. `mouseDown` asks; the self-checks call it with a point they
    /// choose, since a drag needs a mouse position no offscreen test can move.
    ///
    /// The anchor comes out of `ResizeHandle.anchor(in:)`, which speaks *this view's* flipped coordinates — the
    /// window's own frame has y the other way up, so both points are converted once, here, and nothing after
    /// this has to know which space it is in.
    @discardableResult
    func beginResize(at p: CGPoint) -> Bool {
        guard !isEditing else { return false }
        // The pin's own window, not `NSView.window`: `NSWindow` has a `zoom` of its own, and it is a method.
        guard let handle = resizeHandle(at: p), let window = window_ else { return false }
        resize = Resize(anchor: screenPoint(handle.anchor(in: imageRect)),
                        grip: screenPoint(p),
                        startZoom: window.zoom)
        return true
    }

    /// Scales the pin so that the grabbed grip follows the pointer. The factor is how far the pointer is from
    /// the anchor, measured *along the direction the grip lies in* — the width for a side grip, the height for
    /// the top or bottom one, the diagonal for a corner. One formula, so all eight behave the same way.
    func resizeDrag(to mouse: CGPoint) {
        guard let resize, let window = window_ else { return }
        let span = hypot(resize.grip.x - resize.anchor.x, resize.grip.y - resize.anchor.y)
        guard span > 1 else { return }
        let along = ((mouse.x - resize.anchor.x) * (resize.grip.x - resize.anchor.x)
                     + (mouse.y - resize.anchor.y) * (resize.grip.y - resize.anchor.y)) / span
        // Past the anchor the ratio would go negative, which is a pin of no size; `setZoom` clamps the rest.
        window.setZoom(resize.startZoom * max(along / span, 0.01), anchor: resize.anchor)
    }

    /// Ends a resize (the mouse came up, or a press landed somewhere else).
    func endResize() {
        resize = nil
    }

    /// The dots handle's own `mouseUp` never reaches this view, so it says when the drag is over. Until then the
    /// handle was being held open whatever the pointer did; now the buttons go back to depending on where it is,
    /// which by then may be nowhere near the pin.
    func endDrag() {
        dragStart = nil
        layoutButtons()
    }

    override func mouseUp(with event: NSEvent) {
        endResize()
        dragStart = nil
        if selectingText, textSelection?.isEmpty == true { textSelection = nil }
        selectingText = false
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle click: back to 100%.
        window_?.setZoom(1)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeKey()
        guard let menu = window_?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}


/// The window 扫码 leaves on the desktop. It is not a `PinWindow` — that one pins a picture, and what has to
/// stay in sight here is live text whose rows still carry 复制 / 访问. It hosts the very same `ScanPanelView`
/// the capture shows, which is what keeps 钉住 from turning into a second interface.
final class ScanResultPinWindow: NSPanel {
    private(set) var panel: ScanPanelView!

    init(codes: [String], frame: CGRect) {
        super.init(contentRect: CGRect(origin: frame.origin, size: ScanPanelView.size(codeCount: codes.count)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // After `isFloatingPanel`: turning that on sends the panel back to `.floating` (3), which is exactly the
        // level Quick Look sits above.
        level = .pinned
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        // The panel draws its border itself; the window server draws the shadow around its rounded alpha, which
        // is what the panel has in a capture too.
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel = ScanPanelView(pinned: true) { [weak self] in self?.close() }
        panel.show(codes: codes)
        panel.frame = CGRect(origin: .zero, size: ScanPanelView.size(codeCount: codes.count))
        panel.movesWindowOnDrag = true
        panel.closesOnEscape = true
        // A single window shadow around the rounded panel: the layer shadow is clipped at the window's edge.
        panel.layer?.shadowOpacity = 0
        contentView = panel
    }

    override var canBecomeKey: Bool { true }

    // A click on a row's button can leave something other than the panel as first responder; Esc has to work
    // from wherever the key went.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        ScanResultPins.remove(self)
        super.close()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The window is ordered in first, then the pin stands up: the press is seen happening in the same place
    /// the capture's panel was.
    func playPinAppearance() { panel.playPinAppearance() }

    var testing_panel: ScanPanelView { panel }
}

/// Keeps the pinned results alive; a window with no strong reference would be deallocated while still on screen.
@MainActor
enum ScanResultPins {
    private(set) static var windows: [ScanResultPinWindow] = []

    static func show(codes: [String], frame: CGRect) {
        let window = ScanResultPinWindow(codes: codes, frame: frame)
        windows.append(window)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(window.panel)
        // One runloop turn later, so the window has been put up with the pin still lying down: the press is seen
        // standing it up, rather than first appearing already pinned.
        DispatchQueue.main.async { window.playPinAppearance() }
    }

    fileprivate static func remove(_ window: ScanResultPinWindow) {
        windows.removeAll { $0 === window }
    }
}
