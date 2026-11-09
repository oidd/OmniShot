import AppKit
import ServiceManagement
import OmniShotCore
import SwiftUI

enum ShortcutTarget: Equatable { case capture, translateCapture, textTranslate, ocrCapture, pinClipboard, togglePins, scanCode }

/// Every change is written through right away; there is no save button.
final class SettingsModel: ObservableObject {
    private let settings = Settings.shared

    @Published var engine = Settings.shared.engine { didSet { settings.engine = engine; testResult = nil } }
    @Published var targetLanguage = Settings.shared.targetLanguage { didSet { settings.targetLanguage = targetLanguage } }
    @Published var autoReadClipboard = Settings.shared.autoReadClipboard { didSet { settings.autoReadClipboard = autoReadClipboard } }
    @Published var dismissTranslationCapture = Settings.shared.dismissTranslationCapture {
        didSet { settings.dismissTranslationCapture = dismissTranslationCapture }
    }

    // 大模型：一份是列表，一份是「当前选中那条」的字段副本——设置页编辑的是这份副本，改动照样立即写回。
    @Published var configs: [LLMConfig] = Settings.shared.llmConfigs { didSet { settings.llmConfigs = configs } }
    @Published var selectedConfigID = Settings.shared.selectedLLMConfigID { didSet { selectedConfigChanged() } }
    @Published var configName = "" { didSet { updateSelected { $0.name = configName } } }
    @Published var provider = Settings.shared.selectedLLMConfig.provider { didSet { updateSelected { $0.provider = provider } } }
    @Published var baseURL = "" { didSet { updateSelected { $0.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines) } } }
    @Published var model = "" { didSet { updateSelected { $0.model = model.trimmingCharacters(in: .whitespacesAndNewlines) } } }
    @Published var systemPrompt = "" { didSet { updateSelected { $0.setPrompt(systemPrompt) } } }
    @Published var apiKey = "" {
        didSet {
            guard !isLoadingConfig, loadsSecrets else { return }
            settings.setAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: selectedConfigID)
        }
    }
    // 文字识别：引擎 + 百度的那份凭证。两个密钥和 API Key 一样，装填字段副本时不能反过来写回去。
    @Published var ocrEngine = Settings.shared.ocrEngine { didSet { settings.ocrEngine = ocrEngine; testResult = nil } }
    /// 扫码后自动复制 lives on 文字识别's page, next to the engine that reads the codes.
    @Published var scanAutoCopy = Settings.shared.scanAutoCopy { didSet { settings.scanAutoCopy = scanAutoCopy } }
    @Published var baiduPrecision = Settings.shared.baiduOCRPrecision { didSet { settings.baiduOCRPrecision = baiduPrecision } }
    @Published var baiduLanguage = Settings.shared.baiduOCRLanguage { didSet { settings.baiduOCRLanguage = baiduLanguage } }
    @Published var baiduAPIKey = "" {
        didSet {
            guard !isLoadingConfig, loadsSecrets else { return }
            settings.baiduOCRAPIKey = baiduAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    @Published var baiduSecretKey = "" {
        didSet {
            guard !isLoadingConfig, loadsSecrets else { return }
            settings.baiduOCRSecretKey = baiduSecretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    @Published var saveDirectory = Settings.shared.saveDirectory { didSet { settings.saveDirectory = saveDirectory } }
    @Published var imageFormat = Settings.shared.imageFormat { didSet { settings.imageFormat = imageFormat } }
    @Published var hidesPinsWhileCapturing = Settings.shared.hidesPinsWhileCapturing { didSet { settings.hidesPinsWhileCapturing = hidesPinsWhileCapturing } }
    @Published var menuBarClickAction = Settings.shared.menuBarClickAction { didSet { settings.menuBarClickAction = menuBarClickAction } }
    // SwiftUI's colour well needs a `Color`; the setting keeps an `NSColor`.
    @Published var themeColor = Color(nsColor: Settings.shared.themeColor) { didSet { settings.themeColor = NSColor(themeColor) } }
    @Published var cornerRadius = Settings.shared.cornerRadius { didSet { settings.cornerRadius = cornerRadius } }
    @Published var shortcut = Settings.shared.shortcut { didSet { settings.shortcut = shortcut; shortcutsChanged() } }
    @Published var translateCaptureShortcut = Settings.shared.translateCaptureShortcut { didSet { settings.translateCaptureShortcut = translateCaptureShortcut; shortcutsChanged() } }
    @Published var textTranslateShortcut = Settings.shared.textTranslateShortcut { didSet { settings.textTranslateShortcut = textTranslateShortcut; shortcutsChanged() } }
    @Published var ocrCaptureShortcut = Settings.shared.ocrCaptureShortcut { didSet { settings.ocrCaptureShortcut = ocrCaptureShortcut; shortcutsChanged() } }
    @Published var pinShortcut = Settings.shared.pinClipboardShortcut { didSet { settings.pinClipboardShortcut = pinShortcut; shortcutsChanged() } }
    @Published var togglePinsShortcut = Settings.shared.togglePinsShortcut { didSet { settings.togglePinsShortcut = togglePinsShortcut; shortcutsChanged() } }
    @Published var scanCodeShortcut = Settings.shared.scanCodeShortcut { didSet { settings.scanCodeShortcut = scanCodeShortcut; shortcutsChanged() } }
    @Published var recording: ShortcutTarget?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled { didSet { applyLaunchAtLogin() } }
    @Published var loginItemError: String?
    @Published var automaticallyChecksForUpdates = Updater.shared.automaticallyChecks { didSet { Updater.shared.automaticallyChecks = automaticallyChecksForUpdates } }
    @Published var testResult: String?
    @Published var isTesting = false

    static let languages = ["简体中文", "繁體中文", "English", "日本語", "한국어"]
    private let loadsSecrets: Bool
    /// True while the field copies are being filled from the selected entry, so their observers don't write
    /// the very same values straight back (and don't rewrite the key file on every reload).
    private var isLoadingConfig = false

    /// `loadSecrets` false leaves the API key alone (the self-checks don't need it).
    init(loadSecrets: Bool = true) {
        loadsSecrets = loadSecrets
        loadSelectedConfig()
        loadBaidu()
    }

    var config: TranslationConfig { settings.translationConfig }

    /// The entry the fields belong to.
    var selectedConfig: LLMConfig { configs.first { $0.id == selectedConfigID } ?? configs[0] }

    /// The last entry stays: with none left there is nothing for the pickers to show.
    var canDeleteConfig: Bool { configs.count > 1 }

    /// The names the 大模型 picker shows, by id.
    var configLabels: [String: String] {
        Dictionary(uniqueKeysWithValues: zip(configs.map(\.id), LLMConfig.labels(for: configs)))
    }

    // MARK: - 大模型

    func addConfig() {
        let config = LLMConfig()
        configs.append(config)
        selectedConfigID = config.id
    }

    func deleteSelectedConfig() {
        guard canDeleteConfig, let index = configs.firstIndex(where: { $0.id == selectedConfigID }) else { return }
        let removed = configs.remove(at: index)
        settings.setAPIKey("", for: removed.id)
        selectedConfigID = configs[min(index, configs.count - 1)].id
    }

    /// 「恢复默认提示词」— writing the built-in text back is the same as clearing it (`LLMConfig.setPrompt`).
    func resetPrompt() { systemPrompt = TranslationConfig.defaultSystemPrompt }

    private func selectedConfigChanged() {
        settings.selectedLLMConfigID = selectedConfigID
        loadSelectedConfig()
    }

    private func loadSelectedConfig() {
        let config = selectedConfig
        isLoadingConfig = true
        configName = config.name
        provider = config.provider
        baseURL = config.baseURL
        model = config.model
        systemPrompt = config.effectiveSystemPrompt
        apiKey = loadsSecrets ? settings.apiKey(for: config.id) : ""
        isLoadingConfig = false
    }

    /// The two Baidu secrets, filled the same way and under the same guard — writing them back as they are
    /// loaded would rewrite the key files on every visit to the page.
    private func loadBaidu() {
        isLoadingConfig = true
        baiduAPIKey = loadsSecrets ? settings.baiduOCRAPIKey : ""
        baiduSecretKey = loadsSecrets ? settings.baiduOCRSecretKey : ""
        isLoadingConfig = false
    }

    /// Applies a change to the selected entry and lets the list write itself through.
    private func updateSelected(_ change: (inout LLMConfig) -> Void) {
        guard !isLoadingConfig, let index = configs.firstIndex(where: { $0.id == selectedConfigID }) else { return }
        var config = configs[index]
        change(&config)
        guard config != configs[index] else { return }
        configs[index] = config
    }

    /// Re-registers the global hotkeys; while one is being recorded they stay paused until it is done.
    private func shortcutsChanged() {
        guard recording == nil else { return }
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }

    func testConnection() {
        isTesting = true
        testResult = nil
        let config = self.config
        Task { @MainActor in
            defer { isTesting = false }
            do {
                let result = try await Translator.translate([.init(id: 0, text: "Take a screenshot and translate it in place.")], config: config)
                testResult = result[0].map { "连接成功：\($0)" } ?? "连接成功，但没有返回译文"
            } catch {
                testResult = "失败：" + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// 测试识别 — one small picture through the configured Baidu application, the same way 测试连接 works on
    /// the translation page. It is the only way to find out that a key is wrong before a screenshot fails.
    func testOCR() {
        isTesting = true
        testResult = nil
        let config = settings.baiduOCRConfig
        Task { @MainActor in
            defer { isTesting = false }
            guard let image = Self.sampleOCRImage else {
                testResult = "失败：做不出测试图片"
                return
            }
            do {
                let page = try await BaiduOCR.recognize(image: image, config: config)
                let text = page.lines.map(\.words).joined(separator: " ")
                testResult = text.isEmpty ? "连接成功，但没有识别到文字" : "连接成功：\(text)"
            } catch {
                testResult = "失败：" + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// One line of black-on-white Chinese and English at 2x — the smallest picture that can tell a working key
    /// from a wrong one.
    private static var sampleOCRImage: CGImage? {
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
        NSAttributedString(string: "OmniShot 文字识别 OCR",
                           attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
            .draw(at: CGPoint(x: 12, y: 12))
        return rep.cgImage
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveDirectory
        if panel.runModal() == .OK, let url = panel.url { saveDirectory = url }
    }

    /// Registers or removes the login item. Only works from the built app bundle, not `swift run`.
    private func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        guard launchAtLogin != (service.status == .enabled) else { return }
        do {
            if launchAtLogin, service.status != .enabled {
                try service.register()
            } else if !launchAtLogin, service.status == .enabled {
                try service.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "设置开机启动失败：\(error.localizedDescription)"
            launchAtLogin = service.status == .enabled
        }
    }

    private var monitor: Any?

    func startRecording(_ target: ShortcutTarget) {
        if recording != nil { stopRecordingShortcut() }
        recording = target
        NotificationCenter.default.post(name: .pauseHotKeys, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc cancels recording
                self.stopRecordingShortcut()
                return nil
            }
            if let shortcut = Shortcut(event: event) {
                switch self.recording {
                case .capture: self.shortcut = shortcut
                case .translateCapture: self.translateCaptureShortcut = shortcut
                case .textTranslate: self.textTranslateShortcut = shortcut
                case .ocrCapture: self.ocrCaptureShortcut = shortcut
                case .pinClipboard: self.pinShortcut = shortcut
                case .togglePins: self.togglePinsShortcut = shortcut
                case .scanCode: self.scanCodeShortcut = shortcut
                case nil: break
                }
                self.stopRecordingShortcut()
            }
            return nil
        }
    }

    func stopRecordingShortcut() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        NotificationCenter.default.post(name: .resumeHotKeys, object: nil)
    }
}

extension Notification.Name {
    static let pauseHotKeys = Notification.Name("OmniShotPauseHotKey")
    static let resumeHotKeys = Notification.Name("OmniShotResumeHotKey")
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    /// The size the window opens at, and the size it is put back to every time it is shown.
    static let contentSize = CGSize(width: 860, height: 600)
    private var model = SettingsModel()
    /// Remembered between openings so the window comes back to the page you were last on. None until
    /// the first open, which lands on 权限设置 when something is still not granted.
    private var lastPane: SettingsPane?

    private init() {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.contentSize),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentMinSize = CGSize(width: 720, height: 520)
        // No title bar text: the page name at the top of the content is the title.
        window.title = "OmniShot 设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        // Reload so the window reflects what is stored now.
        model = SettingsModel()
        let pane = lastPane ?? (PermissionCenter.shared.screenRecording ? .shortcuts : .permissions)
        lastPane = pane
        install(pane: pane)
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // `activate()` only asks to become the active app, and a menu bar app is usually not active at the
        // moment its menu item is picked. Without this the window is ordered front but stays *behind*
        // whatever is in front of it — it is on screen, it is just underneath, which reads as "clicking
        // 设置 did nothing at all".
        window?.orderFrontRegardless()
    }

    /// Puts the settings view in the window and gives the window its size back.
    ///
    /// The size has to be set again *after* `contentViewController` is assigned. With the controller's
    /// `sizingOptions` cleared, the window takes the SwiftUI view's own fitting size — and a view with no
    /// frame of its own reports almost nothing, so the window came back as a 1×1 pixel square parked in
    /// the middle of the screen. That is invisible, and reads exactly like「设置点了没反应」. Keeping the
    /// size here rather than relying on the view means a future edit to `SettingsView` can't bring it back.
    ///
    /// Split out of `present()` so `--check settings` can run it without putting a window on screen.
    @discardableResult
    func install(pane: SettingsPane) -> CGSize {
        let controller = NSHostingController(rootView: SettingsView(model: model, pane: pane) { [weak self] in
            self?.lastPane = $0
        })
        controller.sizingOptions = []
        window?.contentViewController = controller
        window?.setContentSize(Self.contentSize)
        return window?.contentView?.frame.size ?? .zero
    }

    /// The settings window is the one window of ours that belongs in a screenshot — it is part of what the
    /// user sees, unlike the pins (a setting) or the capture overlay (not up yet). `CaptureEngine` feeds
    /// these back in through `exceptingWindows`; without it the panel looks like it hid itself the moment
    /// the capture hotkey is pressed.
    var capturableWindowNumbers: [CGWindowID] {
        guard let window, window.isVisible else { return [] }
        return [CGWindowID(window.windowNumber)]
    }

    func windowWillClose(_ notification: Notification) {
        if model.recording != nil { model.stopRecordingShortcut() }
    }
}
