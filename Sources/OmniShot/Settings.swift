import AppKit
import Carbon.HIToolbox
import OmniShotCore

/// A global keyboard shortcut in Carbon terms, plus the key label shown in the UI.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyLabel: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(optionKey), keyLabel: "A")
    static let defaultTranslateCapture = Shortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(optionKey | shiftKey), keyLabel: "A")
    static let defaultTextTranslate = Shortcut(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(optionKey | shiftKey), keyLabel: "T")
    static let defaultOCRCapture = Shortcut(keyCode: UInt32(kVK_ANSI_O), carbonModifiers: UInt32(optionKey | shiftKey), keyLabel: "O")
    static let defaultPinClipboard = Shortcut(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(optionKey | shiftKey), keyLabel: "V")
    static let defaultTogglePins = Shortcut(keyCode: UInt32(kVK_ANSI_H), carbonModifiers: UInt32(optionKey | shiftKey), keyLabel: "H")
    static let defaultClosePins = Shortcut(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(optionKey | shiftKey), keyLabel: "C")

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        let functionKeyName = Self.functionKeys[Int(event.keyCode)]
        let isFunctionKey = functionKeyName != nil
        // A plain letter without modifiers would swallow normal typing everywhere.
        guard carbon != 0 || isFunctionKey else { return nil }
        let label: String
        if isFunctionKey {
            label = functionKeyName!
        } else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty, chars != " " {
            label = chars.uppercased()
        } else if event.keyCode == UInt16(kVK_Space) {
            label = "Space"
        } else {
            label = "Key \(event.keyCode)"
        }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbon, keyLabel: label)
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

/// What ends 截图翻译 — the hotkey route that translates as soon as the region is picked.
///
/// That route hides the toolbar (a bar of tools over the selection is in the way of reading the translation),
/// so Esc was the only way out. These are the two click gestures users asked for instead; `none` is the old
/// behaviour, where clicking outside a translated selection does nothing at all.
enum DismissAction: String, CaseIterable, Identifiable {
    case none, singleClick, doubleClick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "无操作"
        case .singleClick: return "单击截图外侧"
        case .doubleClick: return "双击截图外侧"
        }
    }
}

/// What a **left** click on the menu bar icon does. The right click (and ⌃-click) always opens the menu, so the
/// rest of the app — 设置 included — stays reachable whatever this is set to.
enum MenuBarClickAction: String, CaseIterable, Identifiable {
    case menu, screenshot, translateCapture, textTranslate, ocr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menu: return "下拉菜单"
        case .screenshot: return "截图"
        case .translateCapture: return "截图翻译"
        case .textTranslate: return "输入翻译"
        case .ocr: return "文字识别"
        }
    }

    /// What this click should do. A right click wins over the setting; a left click does what it says.
    /// Pure, so `--check menubar-click` can drive every combination without a menu bar.
    static func outcome(for setting: MenuBarClickAction, rightClick: Bool) -> MenuBarClickAction {
        rightClick ? .menu : setting
    }
}

/// App settings. Everything lives in UserDefaults except the API key, which has its own file (see `SecretFile`).
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("OmniShotSettingsDidChange")

    private let defaults = UserDefaults.standard

    private init() {
        // First thing, before anything reads a setting: bring over what the app saved under its earlier name.
        LegacyMigration.run(into: defaults)
    }

    /// Existing users who already set up an API key keep the LLM; everyone else starts on the free engine.
    var engine: TranslationEngine {
        get {
            if let raw = defaults.string(forKey: "translate.engine"), let engine = TranslationEngine(rawValue: raw) { return engine }
            return hasAnyAPIKey ? .llm : .free
        }
        set { defaults.set(newValue.rawValue, forKey: "translate.engine") }
    }

    /// Per-install id sent to the free translation service.
    var clientKey: String {
        if let key = defaults.string(forKey: "translate.clientKey") { return key }
        let key = "browser-chrome-110.0.0-Mac OS-\(UUID().uuidString.lowercased())-\(Int(Date().timeIntervalSince1970 * 1000))"
        defaults.set(key, forKey: "translate.clientKey")
        return key
    }

    var targetLanguage: String {
        get { defaults.string(forKey: "translate.targetLanguage") ?? TranslationConfig.defaultTargetLanguage }
        set { defaults.set(newValue, forKey: "translate.targetLanguage") }
    }

    /// Whether opening 输入翻译 reads the clipboard by itself. Off leaves the window empty for typing into.
    var autoReadClipboard: Bool {
        get { defaults.object(forKey: "translate.readClipboard") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "translate.readClipboard") }
    }

    /// Whether a click outside the selection ends 截图翻译. Default `none`: nothing there does anything, which is
    /// what the app has always done.
    var dismissTranslationCapture: DismissAction {
        get { DismissAction(rawValue: defaults.string(forKey: "translate.dismiss") ?? "") ?? .none }
        set { defaults.set(newValue.rawValue, forKey: "translate.dismiss") }
    }

    // MARK: - 大模型

    /// Every saved 大模型 service, in the order they were added. Never empty — a machine that has never been
    /// configured gets the blank first entry to fill in, and the single-config version's values arrive as it.
    var llmConfigs: [LLMConfig] {
        get {
            if let data = defaults.data(forKey: "translate.llmConfigs"),
               let list = try? JSONDecoder().decode([LLMConfig].self, from: data), !list.isEmpty { return list }
            return [carriedOverConfig]
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "translate.llmConfigs") }
    }

    /// The entry the single-config version had. Its three keys are only read now, never written: an older
    /// build — and the rename migration — still find them, so rolling back loses nothing.
    private var carriedOverConfig: LLMConfig {
        LLMConfig(id: LLMConfig.legacyID,
                  baseURL: defaults.string(forKey: "translate.baseURL") ?? "",
                  model: defaults.string(forKey: "translate.model") ?? "",
                  systemPrompt: defaults.string(forKey: "translate.systemPrompt") ?? "")
    }

    /// Which entry the pickers are on. An id that no longer names an entry (it was deleted) reads as the first.
    var selectedLLMConfigID: String {
        get {
            let saved = defaults.string(forKey: "translate.llmConfigID") ?? LLMConfig.legacyID
            let list = llmConfigs
            return list.contains { $0.id == saved } ? saved : list[0].id
        }
        set { defaults.set(newValue, forKey: "translate.llmConfigID") }
    }

    var selectedLLMConfig: LLMConfig {
        let list = llmConfigs
        return list.first { $0.id == selectedLLMConfigID } ?? list[0]
    }

    /// Appends a blank entry and selects it — what 「新增」 does.
    @discardableResult func addLLMConfig() -> LLMConfig {
        let config = LLMConfig()
        llmConfigs = llmConfigs + [config]
        selectedLLMConfigID = config.id
        return config
    }

    /// Removes one entry and its key file. The last entry stays: the pickers would have nothing to show, and
    /// an engine with no entry to use is a state with no purpose.
    func removeLLMConfig(id: String) {
        let list = llmConfigs
        guard list.count > 1, let index = list.firstIndex(where: { $0.id == id }) else { return }
        // Read the selection *before* the list changes: the getter falls back to the first entry, so asking it
        // once the list is shorter would answer with a different id than the one actually stored.
        let wasSelected = selectedLLMConfigID
        setAPIKey("", for: id)
        var remaining = list
        remaining.remove(at: index)
        llmConfigs = remaining
        if !remaining.contains(where: { $0.id == wasSelected }) {
            selectedLLMConfigID = remaining[min(index, remaining.count - 1)].id
        }
    }

    /// The selected entry's key, for the callers that only ask "can we translate at all".
    var apiKey: String { apiKey(for: selectedLLMConfig.id) }

    private var hasAnyAPIKey: Bool { llmConfigs.contains { !apiKey(for: $0.id).isEmpty } }

    /// An entry's key, in a file only the user can read, not the Keychain: a Keychain item asks for the login
    /// password again whenever the app's signature changes, which is every rebuild. The carried-over entry
    /// keeps the old `api-key` name so nothing has to move; new entries get one file each. An unbundled dev
    /// build (`.build/debug/OmniShot`) reads DEEPSEEK_API_KEY instead, so scripted runs never touch the real key.
    func apiKey(for id: String) -> String {
        guard Bundle.main.bundleIdentifier != nil else { return ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] ?? "" }
        return SecretFile.read(Self.keyFile(for: id)) ?? ""
    }

    func setAPIKey(_ value: String, for id: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        SecretFile.write(value, Self.keyFile(for: id))
    }

    /// Not private: `--check llm-configs` asserts the naming rule (the old entry keeps the old file).
    static func keyFile(for id: String) -> String {
        id == LLMConfig.legacyID ? "api-key" : "api-key-\(id)"
    }

    // MARK: - 文字识别

    /// Which service reads the text — 内置识别 (Vision) or 百度 OCR. Everything that recognises anything follows
    /// this: the OCR panel, the hotkey, translation, a pin's text selection and 自动识别.
    var ocrEngine: OCREngine {
        get { OCREngine(rawValue: defaults.string(forKey: "ocr.engine") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "ocr.engine") }
    }

    /// 高精度 and 标准 have separate quotas, so both are worth keeping one pick away.
    var baiduOCRPrecision: BaiduOCRPrecision {
        get { BaiduOCRPrecision(rawValue: defaults.string(forKey: "ocr.baidu.precision") ?? "") ?? .accurate }
        set { defaults.set(newValue.rawValue, forKey: "ocr.baidu.precision") }
    }

    var baiduOCRLanguage: BaiduOCRLanguage {
        get { BaiduOCRLanguage(rawValue: defaults.string(forKey: "ocr.baidu.language") ?? "") ?? .chineseEnglish }
        set { defaults.set(newValue.rawValue, forKey: "ocr.baidu.language") }
    }

    /// The two halves of a Baidu application. Same rule as the translation key — files under Application
    /// Support, 0600, and an unbundled build reads environment variables instead so scripted runs never touch
    /// the real ones.
    var baiduOCRAPIKey: String {
        get { secret("ocr-api-key", environment: "BAIDU_OCR_API_KEY") }
        set { writeSecret(newValue, "ocr-api-key") }
    }

    var baiduOCRSecretKey: String {
        get { secret("ocr-secret-key", environment: "BAIDU_OCR_SECRET_KEY") }
        set { writeSecret(newValue, "ocr-secret-key") }
    }

    var baiduOCRConfig: BaiduOCRConfig {
        BaiduOCRConfig(apiKey: baiduOCRAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                       secretKey: baiduOCRSecretKey.trimmingCharacters(in: .whitespacesAndNewlines),
                       precision: baiduOCRPrecision, language: baiduOCRLanguage)
    }

    /// 扫码 → 扫码后自动复制 (设置 → 文字识别, on by default): a scan writes what it found to the clipboard
    /// without a press on 复制. Off is for people who keep something on the clipboard and only want to look.
    var scanAutoCopy: Bool {
        get { defaults.object(forKey: "scan.autoCopy") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "scan.autoCopy") }
    }

    private func secret(_ file: String, environment: String) -> String {
        guard Bundle.main.bundleIdentifier != nil else { return ProcessInfo.processInfo.environment[environment] ?? "" }
        return SecretFile.read(file) ?? ""
    }

    private func writeSecret(_ value: String, _ file: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        SecretFile.write(value, file)
    }

    var saveDirectory: URL {
        get {
            if let path = defaults.string(forKey: "output.directory") { return URL(fileURLWithPath: path) }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        }
        set { defaults.set(newValue.path, forKey: "output.directory") }
    }

    var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: defaults.string(forKey: "output.format") ?? "") ?? .png }
        set { defaults.set(newValue.rawValue, forKey: "output.format") }
    }

    /// Whether the pins get covered by the capture overlay (the default) or float above it while capturing,
    /// so they can be looked at while framing the next screenshot.
    var hidesPinsWhileCapturing: Bool {
        get { defaults.object(forKey: "pin.hideWhileCapturing") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "pin.hideWhileCapturing") }
    }

    /// What a left click on the menu bar icon does (设置 → 通用). Default 下拉菜单 — the app's behaviour until
    /// this setting existed. A right click always opens the menu, whatever this says.
    var menuBarClickAction: MenuBarClickAction {
        get { MenuBarClickAction(rawValue: defaults.string(forKey: "menubar.leftClick") ?? "") ?? .menu }
        set { defaults.set(newValue.rawValue, forKey: "menubar.leftClick") }
    }

    /// What every piece of the app's chrome is drawn in: the capture selection frame and its handles, the
    /// active tool, the size chip, the translation bar's buttons, a pin's border and its glow. Chosen by the
    /// user in 设置 → 通用; the default is the light blue the app has always used.
    ///
    /// The defaults key is still `pin.borderColor` — this started out as the pin's own colour and grew into the
    /// theme, and renaming the key would quietly drop the choice of anyone who had already set one.
    var themeColor: NSColor {
        get {
            guard let parts = defaults.array(forKey: "pin.borderColor") as? [Double], parts.count == 4 else { return Self.defaultThemeColor }
            return NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
        }
        set {
            let color = newValue.usingColorSpace(.sRGB) ?? newValue
            defaults.set([Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent),
                          Double(color.alphaComponent)], forKey: "pin.borderColor")
        }
    }

    /// A light, airy blue (Apple's "light blue" from its palette), the app's look since the beginning. A
    /// saturated one goes dark and heavy where it runs over bright content, which the selection frame does.
    static let defaultThemeColor = NSColor(srgbRed: 0.35, green: 0.78, blue: 0.98, alpha: 1)

    /// Corner radius in points of everything this app hands out — copied, saved, pinned. 0 leaves square corners.
    var cornerRadius: CGFloat {
        get { CGFloat(defaults.object(forKey: "output.cornerRadius") as? Double ?? 8) }
        set { defaults.set(Double(newValue), forKey: "output.cornerRadius") }
    }

    var shortcut: Shortcut {
        get {
            guard let data = defaults.data(forKey: "capture.shortcut"),
                  let value = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .default }
            return value
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "capture.shortcut") }
    }

    /// 截图翻译：截图后不用再按翻译按钮，选区一确定就自动翻译。
    var translateCaptureShortcut: Shortcut? {
        get { optionalShortcut("capture.translateShortcut", default: .defaultTranslateCapture) }
        set { setOptionalShortcut(newValue, "capture.translateShortcut") }
    }

    /// 文字识别：框选完直接把识别到的文字复制到剪贴板，不弹识别面板。
    var ocrCaptureShortcut: Shortcut? {
        get { optionalShortcut("ocr.shortcut", default: .defaultOCRCapture) }
        set { setOptionalShortcut(newValue, "ocr.shortcut") }
    }

    /// 输入翻译：一个独立窗口，翻译输入或粘贴进来的文字。
    var textTranslateShortcut: Shortcut? {
        get { optionalShortcut("text.shortcut", default: .defaultTextTranslate) }
        set { setOptionalShortcut(newValue, "text.shortcut") }
    }

    /// nil means the user cleared the shortcut.
    var pinClipboardShortcut: Shortcut? {
        get { optionalShortcut("pin.shortcut", default: .defaultPinClipboard) }
        set { setOptionalShortcut(newValue, "pin.shortcut") }
    }

    var togglePinsShortcut: Shortcut? {
        get { optionalShortcut("pin.toggleShortcut", default: .defaultTogglePins) }
        set { setOptionalShortcut(newValue, "pin.toggleShortcut") }
    }

    var closePinsShortcut: Shortcut? {
        get { optionalShortcut("pin.closeAllShortcut", default: .defaultClosePins) }
        set { setOptionalShortcut(newValue, "pin.closeAllShortcut") }
    }

    /// Not set by default: scanning is an occasional action and shouldn't take a key combination unasked.
    var scanCodeShortcut: Shortcut? {
        get {
            guard let data = defaults.data(forKey: "scan.shortcut") else { return nil }
            return try? JSONDecoder().decode(Shortcut.self, from: data)
        }
        set { setOptionalShortcut(newValue, "scan.shortcut") }
    }

    /// A missing key means "never set", which gets the default; empty data means the user cleared it.
    private func optionalShortcut(_ key: String, default value: Shortcut) -> Shortcut? {
        guard let data = defaults.data(forKey: key) else { return value }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    private func setOptionalShortcut(_ shortcut: Shortcut?, _ key: String) {
        defaults.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }

    var translationConfig: TranslationConfig {
        let config = selectedLLMConfig
        return TranslationConfig(baseURL: config.effectiveBaseURL, model: config.effectiveModel,
                                 apiKey: apiKey(for: config.id), targetLanguage: targetLanguage,
                                 systemPrompt: config.effectiveSystemPrompt,
                                 engine: engine, clientKey: clientKey, configID: config.id,
                                 provider: config.provider)
    }
}

/// Small secrets in `~/Library/Application Support/OmniShot`, readable and writable only by the user (0600).
enum SecretFile {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OmniShot", isDirectory: true)
    }

    static func read(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// An empty value removes the file.
    static func write(_ value: String, _ name: String) {
        let url = directory.appendingPathComponent(name)
        let fm = FileManager.default
        guard !value.isEmpty else {
            try? fm.removeItem(at: url)
            return
        }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Created with 0600 before any bytes are written, so the key is never readable by others.
        fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try? Data(value.utf8).write(to: url)
    }
}
