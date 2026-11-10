import AppKit
import OmniShotCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    /// True while the temporary menu is attached in `showStatusMenu`; keeps `performClick` from looping.
    private var isShowingStatusMenu = false
    private var captureItem: NSMenuItem!
    private var translateCaptureItem: NSMenuItem!
    private var textTranslateItem: NSMenuItem!
    private var ocrCaptureItem: NSMenuItem!
    private var pinClipboardItem: NSMenuItem!
    private var closePinsItem: NSMenuItem!
    private var togglePinsItem: NSMenuItem!
    private var scanItem: NSMenuItem!
    private var updateReadyItem: NSMenuItem!
    private var checkUpdatesItem: NSMenuItem!
    /// The recognition heartbeat (see `startEngineHeartbeat`); kept so it cannot be deallocated under us.
    private var heartbeatTimer: Timer?

    func applicationWillTerminate(_ notification: Notification) {
        // The engine process watches its parent and exits by itself; this just makes quitting prompt.
        OCRService.shared.shutdown()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // A template image at the system's menu bar size (16 pt tall), so it follows the menu bar's tint.
        statusItem.button?.image = Icon.image(.menuBar, size: 16)
        statusItem.button?.setAccessibilityLabel("OmniShot")
        // Deliberately **not** `statusItem.menu = menu`: with a menu attached both buttons open it and the
        // button's action never runs. The left click is a setting now (设置 → 通用), the right click opens the
        // menu through `statusItemClicked`, which attaches the menu for just that click.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let menu = NSMenu()
        menu.delegate = self
        updateReadyItem = item("", #selector(checkForUpdates))
        updateReadyItem.isHidden = true
        menu.addItem(updateReadyItem)
        captureItem = item("截图", #selector(capture))
        menu.addItem(captureItem)
        translateCaptureItem = item("截图翻译", #selector(translateCapture))
        menu.addItem(translateCaptureItem)
        textTranslateItem = item("输入翻译", #selector(textTranslate))
        menu.addItem(textTranslateItem)
        ocrCaptureItem = item("文字识别", #selector(ocrCapture))
        menu.addItem(ocrCaptureItem)
        scanItem = item("扫描屏幕上二维码/条形码", #selector(scanCodes))
        menu.addItem(scanItem)
        menu.addItem(.separator())
        pinClipboardItem = item("从剪贴板贴图", #selector(pinClipboard))
        menu.addItem(pinClipboardItem)
        togglePinsItem = item("隐藏全部贴图", #selector(togglePins))
        menu.addItem(togglePinsItem)
        closePinsItem = item("关闭全部贴图", #selector(closePins))
        menu.addItem(closePinsItem)
        menu.addItem(.separator())
        menu.addItem(item("设置…", #selector(openSettings), ","))
        menu.addItem(.separator())
        checkUpdatesItem = item("检查更新…", #selector(checkForUpdates))
        checkUpdatesItem.isHidden = !Updater.isAvailable
        menu.addItem(checkUpdatesItem)
        menu.addItem(NSMenuItem(title: "退出 OmniShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusMenu = menu

        registerHotKeys()
        let center = NotificationCenter.default
        center.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in self?.registerHotKeys() }
        center.addObserver(forName: .pauseHotKeys, object: nil, queue: .main) { _ in HotKeyCenter.shared.unregisterAll() }
        center.addObserver(forName: .resumeHotKeys, object: nil, queue: .main) { [weak self] _ in self?.registerHotKeys() }

        TextRecognizer.warmUp()
        startEngineHeartbeat()
        Updater.shared.start()

        if !CaptureEngine.hasPermission {
            CGRequestScreenCaptureAccess()
        }
    }

    /// Keeps Vision's text engine from going cold, and warms it again after the machine has slept.
    ///
    /// The engine unloads after a spell of no use and then takes 15–35 s for its next read anywhere (measured
    /// every way round — see `TextRecognizer.keepWarm`). No request can dodge that, so it is paid here: a
    /// one-line recognition every couple of minutes, which costs about 0.2 s of real work when the engine is
    /// already warm. That is what made 文字识别 sit on 「正在识别文字」 the first time it was used each day.
    private func startEngineHeartbeat() {
        let timer = Timer(timeInterval: 120, repeats: true) { _ in TextRecognizer.keepWarm() }
        // Slack costs nothing and lets the system line the wake-up up with other work.
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { _ in
            TextRecognizer.keepWarm()
        }
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Status item

    /// The menu bar icon was clicked. A right click (or ⌃-click) always opens the menu; a left click does
    /// whatever 设置 → 通用 →「单击菜单栏图标」 says (下拉菜单 by default).
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let rightClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        switch MenuBarClickAction.outcome(for: Settings.shared.menuBarClickAction, rightClick: rightClick) {
        case .menu: showStatusMenu()
        case .screenshot: capture()
        case .translateCapture: translateCapture()
        case .textTranslate: textTranslate()
        case .ocr: ocrCapture()
        }
    }

    /// Shows the menu under the icon. A menu only rides on the status item for this one click: attach it,
    /// let `performClick` show it (AppKit puts it in the right place and highlights the icon), and take it off
    /// again in `menuDidClose` so the next left click goes back to the button's action. Clearing it in
    /// `menuDidClose` rather than right after `performClick` also covers a menu that tracks asynchronously.
    private func showStatusMenu() {
        guard !isShowingStatusMenu else { return }
        isShowingStatusMenu = true
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu, statusItem.menu != nil else { return }
        statusItem.menu = nil
        isShowingStatusMenu = false
    }

    private func registerHotKeys() {
        let settings = Settings.shared
        let capture = settings.shortcut
        let ok = HotKeyCenter.shared.register(.capture, shortcut: capture) { CaptureSession.begin() }
        captureItem.title = ok ? "截图（\(capture.displayString)）" : "截图（快捷键 \(capture.displayString) 已被占用）"

        let translate = settings.translateCaptureShortcut
        let translateOK = HotKeyCenter.shared.register(.translateCapture, shortcut: translate) { CaptureSession.begin(autoTranslate: true) }
        translateCaptureItem.title = "截图翻译" + (translate.map { translateOK ? "（\($0.displayString)）" : "（快捷键 \($0.displayString) 已被占用）" } ?? "")

        let text = settings.textTranslateShortcut
        let textOK = HotKeyCenter.shared.register(.textTranslate, shortcut: text) { TextTranslationWindow.show() }
        textTranslateItem.title = "输入翻译" + (text.map { textOK ? "（\($0.displayString)）" : "（快捷键 \($0.displayString) 已被占用）" } ?? "")

        let ocr = settings.ocrCaptureShortcut
        let ocrOK = HotKeyCenter.shared.register(.ocrCapture, shortcut: ocr) { CaptureSession.begin(autoOCR: true) }
        ocrCaptureItem.title = "文字识别" + (ocr.map { ocrOK ? "（\($0.displayString)）" : "（快捷键 \($0.displayString) 已被占用）" } ?? "")

        let pin = settings.pinClipboardShortcut
        let pinOK = HotKeyCenter.shared.register(.pinClipboard, shortcut: pin) { PinManager.shared.pinClipboard() }
        if let pin {
            pinClipboardItem.title = pinOK ? "从剪贴板贴图（\(pin.displayString)）" : "从剪贴板贴图（快捷键 \(pin.displayString) 已被占用）"
        } else {
            pinClipboardItem.title = "从剪贴板贴图"
        }

        let toggle = settings.togglePinsShortcut
        let toggleOK = HotKeyCenter.shared.register(.togglePins, shortcut: toggle) { PinManager.shared.toggleHidden() }
        togglePinsShortcutLabel = toggle.map { toggleOK ? "（\($0.displayString)）" : "（快捷键 \($0.displayString) 已被占用）" } ?? ""

        let closePins = settings.closePinsShortcut
        let closeOK = HotKeyCenter.shared.register(.closePins, shortcut: closePins) { PinManager.shared.closeAll() }
        closePinsShortcutLabel = closePins.map { closeOK ? "（\($0.displayString)）" : "（快捷键 \($0.displayString) 已被占用）" } ?? ""
        registerScanHotKey()
    }

    private var togglePinsShortcutLabel = ""
    private var closePinsShortcutLabel = ""

    private func registerScanHotKey() {
        let scan = Settings.shared.scanCodeShortcut
        let ok = HotKeyCenter.shared.register(.scanCode, shortcut: scan) { CodeScanner.scanScreens() }
        scanItem.title = "扫描屏幕上二维码/条形码" + (scan.map { ok ? "（\($0.displayString)）" : "（快捷键 \($0.displayString) 已被占用）" } ?? "")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let pins = PinManager.shared
        closePinsItem.isEnabled = pins.hasPins
        togglePinsItem.isEnabled = pins.hasPins
        closePinsItem.title = "关闭全部贴图" + closePinsShortcutLabel
        togglePinsItem.title = (pins.isHidingAll ? "显示全部贴图" : "隐藏全部贴图") + togglePinsShortcutLabel
        let pending = Updater.shared.pendingVersion
        updateReadyItem.isHidden = pending == nil
        updateReadyItem.title = "有新版本 \(pending ?? "")…"
    }

    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }

    @objc private func capture() {
        // Let the menu close before the screen is frozen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { CaptureSession.begin() }
    }

    /// 截图翻译：截完直接翻译，不用再按翻译按钮。
    @objc private func translateCapture() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { CaptureSession.begin(autoTranslate: true) }
    }

    /// 输入翻译：翻译剪贴板里或手动输入的文字。
    @objc private func textTranslate() {
        TextTranslationWindow.show()
    }

    /// 文字识别：框选完直接把识别到的文字送进剪贴板，不弹识别面板。
    @objc private func ocrCapture() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { CaptureSession.begin(autoOCR: true) }
    }

    @objc private func scanCodes() {
        // Let the menu close first so it doesn't cover a code.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { CodeScanner.scanScreens() }
    }

    @objc private func pinClipboard() { PinManager.shared.pinClipboard() }
    @objc private func closePins() { PinManager.shared.closeAll() }
    @objc private func togglePins() { PinManager.shared.toggleHidden() }

    @objc private func openSettings() {
        SettingsWindowController.shared.present()
    }

    /// Accessory apps still need an Edit menu, or ⌘C/⌘V/⌘A do nothing in text fields.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "退出 OmniShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
