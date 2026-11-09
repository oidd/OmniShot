import AppKit
import OmniShotCore

/// Borderless full-screen window that can take keyboard focus.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Window content: the frozen screenshot as a static layer, with the interactive overlay on top.
/// Keeping the screenshot in its own layer means mouse movement never redraws it.
final class CaptureRootView: NSView {
    let captureView: CaptureView

    init(frame: CGRect, snapshot: CGImage, captureView: CaptureView) {
        self.captureView = captureView
        super.init(frame: frame)
        wantsLayer = true
        let base = NSView(frame: bounds)
        base.wantsLayer = true
        base.layer?.contents = snapshot
        base.layer?.contentsGravity = .resize
        base.autoresizingMask = [.width, .height]
        addSubview(base)
        captureView.frame = bounds
        captureView.autoresizingMask = [.width, .height]
        addSubview(captureView)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// One screenshot: an overlay per screen, of which at most one owns the selection.
final class CaptureSession {
    private(set) static var current: CaptureSession?
    private static var isStarting = false

    private var windows: [OverlayWindow] = []
    private var views: [CaptureView] = []
    private weak var owner: CaptureView?
    private let previousApp: NSRunningApplication?
    private(set) var isFinished = false

    /// `autoTranslate` is the 截图翻译 hotkey: the selection translates itself as soon as it is made.
    /// `autoOCR` is the 文字识别 hotkey: its text goes straight to the clipboard, with no OCR panel.
    static func begin(autoTranslate: Bool = false, autoOCR: Bool = false) {
        guard !isStarting else { return }
        // With an overlay already up, the hotkey should start a fresh capture rather than do nothing. That
        // also means a session that somehow never came down can always be cleared by pressing the key again
        // — otherwise its full-screen window stays over everything and the app looks broken from the outside
        // (设置 included: the panel opens, behind the overlay). A pin's pencil session is folded back into its
        // pin first, so the annotations drawn since the last fold are not lost.
        current?.finishForNewCapture()
        guard current == nil else { return }
        guard CaptureEngine.hasPermission else {
            requestPermission()
            return
        }
        isStarting = true
        let previousApp = NSWorkspace.shared.frontmostApplication
        // Read window frames before anything of ours appears on screen.
        let windowFrames = CaptureEngine.windowFrames()
        Task { @MainActor in
            defer { isStarting = false }
            do {
                let snapshots = try await CaptureEngine.captureScreens(includingPins: CaptureEngine.includesPins)
                guard !snapshots.isEmpty else { return }
                let session = CaptureSession(snapshots: snapshots, windowFrames: windowFrames, previousApp: previousApp,
                                             autoTranslate: autoTranslate, autoOCR: autoOCR)
                current = session
                session.show()
            } catch {
                let alert = NSAlert()
                alert.messageText = "截图失败"
                alert.informativeText = error.localizedDescription
                NSApp.activate()
                alert.runModal()
            }
        }
    }

    static func requestPermission() {
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在「系统设置 → 隐私与安全性 → 屏幕与系统录音」中允许 OmniShot，然后重新打开 OmniShot。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Pin editing

    private weak var editingPin: PinWindow?
    private var editingPinZoom: CGFloat = 1
    /// The pencil's toolbar sits over a pin that never leaves the screen. Its 退出 / 保存 / 复制 buttons end the
    /// pin — `CaptureView` reads this to make those three do that — while ✓ finishes the edit and folds the
    /// stage away, leaving the pin where it is: it is the control people press expecting "done", and a pin that
    /// vanished there was a surprise with no undo.
    private(set) var closesPin = false

    /// The pin's pencil: the screenshot toolbar on a stage over the pin's picture, while the pin itself stays
    /// where it is. The stage stops at the picture's right edge, so the pin's own three buttons — ×, pencil and
    /// the dots — remain visible and clickable for the whole session.
    ///
    /// Editing is done at 100% (the pin visibly goes back to its natural size), which keeps the annotation model
    /// in the picture's own points: that is what lets one session's undo stack be replayed in the next one.
    /// `stage` overrides the computed window frame (offscreen checks; it also keeps the window off the screen).
    @discardableResult
    static func beginPinTools(_ pin: PinWindow, in stage: CGRect? = nil) -> CaptureSession? {
        guard current == nil, !isStarting else { return nil }
        let zoom = pin.zoom
        let pictureBefore = PinView.pictureFrame(in: pin.frame)
        pin.setZoom(1, anchor: CGPoint(x: pictureBefore.minX, y: pictureBefore.maxY), flash: false)
        guard let screen = pin.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(pin.frame) }) ?? NSScreen.main else {
            return nil
        }
        let picture = PinView.pictureFrame(in: pin.frame)
        let stageFrame = stage ?? stageFrame(for: picture, visible: screen.frame)
        let local = CGRect(x: picture.minX - stageFrame.minX, y: stageFrame.maxY - picture.maxY,
                           width: picture.width, height: picture.height)
        let image = pinCanvas(pin.editHistory.base, at: local, screenSize: stageFrame.size,
                              scale: screen.backingScaleFactor)

        let session = CaptureSession(previousApp: NSWorkspace.shared.frontmostApplication)
        let window = OverlayWindow(screen: screen)
        window.setFrame(stageFrame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        session.editingPin = pin
        session.editingPinZoom = zoom
        session.closesPin = true
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        session.install(window: window, image: image, displayID: displayID, mode: .pinEdit)
        current = session
        pin.setEditing(true)
        let history = pin.editHistory
        session.views[0].hidesSelectionBorder = true
        session.views[0].startPinEdit(rect: local, items: history.items, undo: history.undo, redo: history.redo,
                                      message: nil)
        if stage == nil { session.show() }
        return session
    }

    /// The window a pencil session lives on: everything to the left of the picture's right edge, with room
    /// below and above for the toolbar, style bar and hover cards. It is deliberately **not** full-screen —
    /// the pin's button column lives to the right of that edge and must stay clickable.
    static func stageFrame(for picture: CGRect, visible: CGRect) -> CGRect {
        // One point past the picture for its border; the buttons start 4pt further right.
        let right = min(picture.maxX + 1, visible.maxX)
        let wanted = max(picture.width + 24, 520)
        let left = max(visible.minX, right - wanted)
        let height = min(max(picture.height + 270, 320), visible.height)
        let top = min(max(picture.maxY + 90, visible.minY + height), visible.maxY)
        return CGRect(x: left, y: top - height, width: max(1, right - left), height: height)
    }

    /// Keeps the stage under the picture while the pin is dragged by its dots. The stage's frame does not
    /// change, so the annotations (laid out in the stage's coordinates) stay exactly on the picture. Called
    /// from `PinWindow.setFrameOrigin`, so the two windows move in the same event rather than a frame apart.
    func pinMoved(by delta: CGPoint) {
        guard editingPin != nil, !isFinished, delta != .zero, let stage = windows.first else { return }
        stage.setFrameOrigin(CGPoint(x: stage.frame.origin.x + delta.x, y: stage.frame.origin.y + delta.y))
    }

    /// A drag on a pencil stage's picture with no tool chosen: the picture **is** the pin, so the pin window
    /// moves and the stage follows through `pinMoved`.
    func beginEditingPinDrag() -> CGPoint? { editingPin?.frame.origin }

    func moveEditingPin(to origin: CGPoint) { editingPin?.setFrameOrigin(origin) }

    /// Whether this session is the pencil's stage rather than an ordinary capture. The two share `CaptureView`
    /// but not every gesture: on the stage the picture is the pin, so dragging it with no tool moves the pin.
    var isPinStage: Bool { editingPin != nil }

    func isEditingPin(_ pin: PinWindow) -> Bool { editingPin === pin }

    /// Hiding every pin while a pencil stage is open would leave the stage hanging over nothing.
    func foldPinToolsIfOpen() {
        guard editingPin != nil else { return }
        finishPinTools()
    }

    /// The pencil is pressed again: fold what is on the stage into the pin and put the stage away, keeping the
    /// pin (and its annotation model, undo history included) for the next time the pencil is used.
    ///
    /// `copying` also puts the finished picture on the clipboard — the pin toolbar's ✓, which says 复制到剪贴板
    /// and is, for most people, the way out of the editor.
    func finishPinTools(copying: Bool = false) {
        guard let pin = editingPin, let view = views.first else { return endSession(closingPin: false) }
        let result = view.finishPinTools()
        if let rep = result.rep {
            pin.commitEdit(rep, bakedBase: result.bakedBase, items: result.items, undo: result.undo, redo: result.redo)
            if copying {
                Exporter.copy(rep)
                HUD.show("已复制到剪贴板", on: windows.first?.screen)
            }
        }
        endSession(closingPin: false)
    }

    /// The pin was closed while its pencil session was open (×, ⌘W, 关闭全部贴图): take the stage down too.
    func pinClosed(_ pin: PinWindow) {
        guard !isFinished, editingPin === pin else { return }
        endSession(closingPin: true)
    }

    /// A new capture is starting while a pin's pencil is open: keep the pin and its edits rather than dropping
    /// everything the user drew since the last time the pencil was folded away.
    func finishForNewCapture() {
        if editingPin != nil {
            finishPinTools()
        } else {
            finish()
        }
    }

    /// A transparent screen-size image with the pin drawn where it sits.
    private static func pinCanvas(_ rep: NSBitmapImageRep, at rect: CGRect, screenSize: CGSize, scale: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(screenSize.width * scale), height: Int(screenSize.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        if let cg = rep.cgImage {
            // CG's origin is bottom-left.
            ctx.draw(cg, in: CGRect(x: rect.minX * scale, y: (screenSize.height - rect.maxY) * scale, width: rect.width * scale, height: rect.height * scale))
        }
        return ctx.makeImage()!
    }

    func applyPinEdit(_ rep: NSBitmapImageRep) {
        // The pencil toolbar ends with the pin gone; redrawing the old window with the edited picture first
        // would only burn a repaint on a window that is about to be ordered out.
        if !closesPin { editingPin?.replaceImage(rep) }
        endSession(closingPin: closesPin)
    }

    private func install(window: OverlayWindow, image: CGImage, displayID: CGDirectDisplayID, mode: CaptureMode) {
        let local = CGRect(origin: .zero, size: window.frame.size)
        let view = CaptureView(frame: local, snapshot: image, windowRects: [], displayID: displayID, mode: mode)
        view.session = self
        window.contentView = CaptureRootView(frame: local, snapshot: image, captureView: view)
        windows = [window]
        views = [view]
    }

    var testing_views: [CaptureView] { views }

    private init(previousApp: NSRunningApplication?) {
        self.previousApp = previousApp
    }

    private init(snapshots: [ScreenSnapshot], windowFrames: [CGRect], previousApp: NSRunningApplication?,
                 autoTranslate: Bool = false, autoOCR: Bool = false) {
        self.previousApp = previousApp
        for snapshot in snapshots {
            let frame = snapshot.screen.frame
            let local = CGRect(origin: .zero, size: frame.size)
            // Global Cocoa rects → this view's flipped coordinates.
            let rects = windowFrames.compactMap { r -> CGRect? in
                let v = CGRect(x: r.minX - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
                let clipped = v.intersection(local)
                return clipped.isNull || clipped.width < 20 || clipped.height < 20 ? nil : clipped
            }
            let displayID = (snapshot.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let window = OverlayWindow(screen: snapshot.screen)
            let view = CaptureView(frame: local, snapshot: snapshot.image, windowRects: rects, displayID: displayID)
            view.session = self
            view.autoTranslate = autoTranslate
            view.autoOCR = autoOCR
            window.contentView = CaptureRootView(frame: local, snapshot: snapshot.image, captureView: view)
            windows.append(window)
            views.append(view)
        }
    }

    private func show() {
        NSApp.activate()
        for window in windows { window.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let active = windows.first { $0.frame.contains(mouse) } ?? windows.first
        active?.makeKeyAndOrderFront(nil)
        if let index = active.flatMap({ windows.firstIndex(of: $0) }) {
            active?.makeFirstResponder(views[index])
            views[index].primeCursor()
        }
        NSCursor.crosshair.set()
    }

    func canInteract(_ view: CaptureView) -> Bool {
        owner == nil || owner === view
    }

    func didSelect(_ view: CaptureView) {
        owner = view
    }

    func didClearSelection(_ view: CaptureView) {
        if owner === view { owner = nil }
    }

    /// Hides the overlay while a standard save panel is up; brings it back if the user cancels.
    func presentSavePanel(rep: NSBitmapImageRep, format: ImageFormat) {
        let owner = self.owner
        for window in windows { window.orderOut(nil) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .png ? .png : .jpeg]
        panel.nameFieldStringValue = Exporter.defaultFileName(format: format)
        panel.canCreateDirectories = true
        let directory = Settings.shared.saveDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        panel.directoryURL = directory
        NSApp.activate()
        panel.begin { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                do {
                    try Exporter.write(rep, format: format, to: url)
                    self.finish()
                    HUD.show("已保存到 \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                } catch {
                    self.finish()
                    let alert = NSAlert(error: error)
                    alert.runModal()
                }
            } else {
                NSApp.activate()
                for window in self.windows { window.orderFrontRegardless() }
                if let owner, let window = owner.window {
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(owner)
                }
            }
        }
    }

    /// Ends the session without producing anything. In the pencil flow its 退出截图 button (and Esc) close the
    /// pin; anywhere else there is no pin to keep or close.
    func cancel() {
        endSession(closingPin: closesPin)
    }

    /// Plain teardown that leaves the pin where it was (a capture path calling it directly has no pin at all).
    func finish() {
        endSession(closingPin: false)
    }

    private func endSession(closingPin: Bool) {
        isFinished = true
        if let pin = editingPin {
            editingPin = nil
            pin.setEditing(false)
            if closingPin {
                // 退出截图 / 保存 / 复制到剪贴板 and Esc all end the pin in the pencil flow; the picture itself
                // was already copied or saved where that was what the user asked for.
                pin.closePin()
            } else {
                if abs(editingPinZoom - 1) > 0.001 {
                    // Anchored on the picture's top-left corner, not the window's: the window carries a wider
                    // margin above and to the right now (the buttons live there), and the pin should come back
                    // where it was.
                    let picture = PinView.pictureFrame(in: pin.frame)
                    pin.setZoom(editingPinZoom, anchor: CGPoint(x: picture.minX, y: picture.maxY), flash: false)
                }
                pin.makeKey()
            }
        }
        for view in views { view.tearDown() }
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        views.removeAll()
        CaptureSession.current = nil
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
        NSCursor.arrow.set()
        if let previousApp, previousApp != NSRunningApplication.current {
            previousApp.activate()
        }
    }
}
