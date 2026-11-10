import AppKit
import OmniShotCore
import SwiftUI

/// Sidebar on the left, the chosen page on the right. Every change is written through as it is made;
/// there is no save button.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var permissions = PermissionCenter.shared
    @State private var pane: SettingsPane
    private let onPaneChange: (SettingsPane) -> Void

    init(model: SettingsModel, pane: SettingsPane, onPaneChange: @escaping (SettingsPane) -> Void = { _ in }) {
        self.model = model
        _pane = State(initialValue: pane)
        self.onPaneChange = onPaneChange
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(pane: $pane)
                .navigationTitle("OmniShot")
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section(header: pageHeader) {
                        VStack(alignment: .leading, spacing: 20) {
                            page
                            Spacer()
                        }
                        .padding(.horizontal, 32)
                        .padding(.bottom, 32)
                        .padding(.top, 12)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onChange(of: pane) { _, new in onPaneChange(new) }
        .onAppear { permissions.startMonitoring() }
        .onDisappear { permissions.stopMonitoring() }
        // Match DockMinimize's layout envelope; the window owns the default size and its 700×480 floor.
        .frame(minWidth: 200, idealWidth: 820, maxWidth: 900,
               minHeight: 200, idealHeight: 560, maxHeight: 900)
    }

    /// The pinned page header from DockMinimize: page title, the About app header when needed, a hairline,
    /// and a background that reaches up over the titlebar so scrolled content cannot show through.
    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(pane.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if pane == .about {
                aboutHeader
                    .padding(.bottom, 16)
            }

            Divider().opacity(0.4)
        }
        .padding(.horizontal, 32)
        .padding(.top, -10)
        .background(
            Color(nsColor: .windowBackgroundColor)
                .padding(.top, -100)
        )
    }

    @ViewBuilder private var page: some View {
        switch pane {
        case .permissions: permissionsPage
        case .shortcuts: shortcutsPage
        case .output: outputPage
        case .translate: translatePage
        case .ocr: ocrPage
        case .general: generalPage
        case .about: aboutPage
        }
    }

    // MARK: - 权限设置

    private var permissionsPage: some View {
        VStack(spacing: 18) {
            SettingsPermissionCard(
                title: "屏幕录制",
                isGranted: permissions.screenRecording,
                grantTitle: "授权",
                grant: { permissions.requestScreenRecording() },
                openSettings: { permissions.openScreenRecordingSettings() })

            SettingsPermissionCard(
                title: "辅助功能",
                detail: "只有长截图的自动滚动用得到",
                isGranted: permissions.accessibility,
                isRequired: false,
                grantTitle: "授权",
                grant: { permissions.requestAccessibility() },
                openSettings: { permissions.openAccessibilitySettings() })

            if permissions.needsRestartToApply {
                SettingsCard {
                    SettingsRow("屏幕录制刚授权", detail: "重启一次才会生效") {
                        Button("重新启动 OmniShot") { permissions.restart() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - 快捷键

    private var shortcutsPage: some View {
        VStack(spacing: 18) {
            SettingsCard {
                shortcutRow("截图", .capture, $model.shortcut)
                SettingsRowDivider()
                shortcutRow("截图翻译", .translateCapture, $model.translateCaptureShortcut)
                SettingsRowDivider()
                shortcutRow("输入翻译", .textTranslate, $model.textTranslateShortcut)
                SettingsRowDivider()
                shortcutRow("文字识别", .ocrCapture, $model.ocrCaptureShortcut)
                SettingsRowDivider()
                shortcutRow("从剪贴板贴图", .pinClipboard, $model.pinShortcut)
                SettingsRowDivider()
                shortcutRow("隐藏 / 显示全部贴图", .togglePins, $model.togglePinsShortcut)
                SettingsRowDivider()
                shortcutRow("关闭全部贴图", .closePins, $model.closePinsShortcut)
                SettingsRowDivider()
                shortcutRow("扫描屏幕上二维码/条形码", .scanCode, $model.scanCodeShortcut)
            }
        }
    }

    private func shortcutRow(_ title: String, _ target: ShortcutTarget, _ value: Binding<Shortcut?>,
                             detail: String? = nil) -> some View {
        SettingsRow(title, detail: detail) {
            HStack(spacing: 8) {
                ShortcutKeyCap(value: value.wrappedValue,
                               isRecording: model.recording == target,
                               start: { model.recording == target ? model.stopRecordingShortcut() : model.startRecording(target) })
                if value.wrappedValue != nil {
                    Button("清除") { value.wrappedValue = nil }
                        .controlSize(.small)
                }
            }
        }
    }

    /// The required one: it cannot be cleared, only changed.
    private func shortcutRow(_ title: String, _ target: ShortcutTarget, _ value: Binding<Shortcut>,
                             detail: String? = nil) -> some View {
        SettingsRow(title, detail: detail) {
            ShortcutKeyCap(value: value.wrappedValue,
                           isRecording: model.recording == target,
                           start: { model.recording == target ? model.stopRecordingShortcut() : model.startRecording(target) })
        }
    }

    // MARK: - 保存

    private var outputPage: some View {
        VStack(spacing: 18) {
            SettingsCard {
                SettingsRow("保存位置") {
                    HStack(spacing: 8) {
                        Text(model.saveDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("选择…") { model.chooseDirectory() }
                            .controlSize(.small)
                    }
                }
                SettingsRowDivider()
                SettingsRow("保存格式") {
                    Picker("", selection: $model.imageFormat) {
                        Text("PNG").tag(ImageFormat.png)
                        Text("JPG").tag(ImageFormat.jpeg)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                SettingsRowDivider()
                SettingsRow("截图圆角") {
                    HStack(spacing: 10) {
                        Slider(value: $model.cornerRadius, in: 0...40, step: 1)
                            .frame(width: 150)
                        Text("\(Int(model.cornerRadius.rounded())) pt")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - 翻译

    private var translatePage: some View {
        VStack(spacing: 18) {
            // The two that are the same whatever translates: they come first, and they never move.
            SettingsCard {
                SettingsToggleRow(title: "自动读取剪贴板翻译", isOn: $model.autoReadClipboard)
                SettingsRowDivider()
                SettingsRow("默认翻译为", detail: "屏幕上是外文时译成这门语言") {
                    Picker("", selection: $model.targetLanguage) {
                        ForEach(SettingsModel.languages, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                SettingsRowDivider()
                // 截图翻译 的那条路不摆工具栏，这是它除 Esc 之外的退出方式。
                SettingsRow("关闭截图翻译") {
                    Picker("", selection: $model.dismissTranslationCapture) {
                        ForEach(DismissAction.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            SettingsCard {
                SettingsRow("翻译引擎") {
                    Picker("", selection: $model.engine) {
                        Text("免费翻译").tag(TranslationEngine.free)
                        Text("大模型").tag(TranslationEngine.llm)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
                if model.engine == .llm {
                    SettingsRowDivider()
                    SettingsRow("大模型") {
                        HStack(spacing: 8) {
                            Picker("", selection: $model.selectedConfigID) {
                                ForEach(model.configs) { config in
                                    Text(model.configLabels[config.id] ?? LLMConfig.defaultName).tag(config.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 170)
                            Button("新增") { model.addConfig() }
                                .controlSize(.small)
                        }
                    }
                }
            }

            if model.engine == .llm { modelConfigCard }
        }
    }

    /// The selected 大模型 entry itself. Every field is written through as it is typed; 「恢复默认提示词」and
    /// 「删除大模型」live at the end of it, 「测试连接」at the bottom right.
    private var modelConfigCard: some View {
        SettingsCard {
            // First, because it decides what the two boxes below mean — and it belongs to this entry, not to
            // the app: one DeepSeek and one Claude side by side is the normal case.
            SettingsRow("接口类型", detail: "DeepSeek、Groq、Kimi 这些都用 OpenAI 兼容") {
                Picker("", selection: $model.provider) {
                    ForEach(LLMProvider.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            SettingsRowDivider()
            SettingsRow("大模型名称", detail: "下拉和输入翻译里显示的就是它") {
                TextField("", text: $model.configName, prompt: Text(LLMConfig.defaultName))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            SettingsRowDivider()
            SettingsRow("Base URL") {
                TextField("", text: $model.baseURL, prompt: Text(model.provider.defaultBaseURL))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            SettingsRowDivider()
            SettingsRow("模型") {
                TextField("", text: $model.model, prompt: Text(model.provider.defaultModel))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            SettingsRowDivider()
            SettingsRow("API Key", detail: "存在本机，只有你能读") {
                SecureField("", text: $model.apiKey, prompt: Text("sk-…"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            SettingsRowDivider()

            VStack(alignment: .leading, spacing: 8) {
                Text("系统提示词").font(.system(size: 13))
                TextEditor(text: $model.systemPrompt)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(height: 108)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12)))
                Text("发给大模型的指令。`{target}` / `{source}` 会换成这次用的语言，其余原样发出去。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("恢复默认提示词") { model.resetPrompt() }
                        .controlSize(.small)
                        .disabled(model.systemPrompt == TranslationConfig.defaultSystemPrompt)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            SettingsRowDivider()
            HStack(spacing: 10) {
                Button("删除大模型") { model.deleteSelectedConfig() }
                    .controlSize(.small)
                    .disabled(!model.canDeleteConfig)
                Spacer()
                if model.isTesting { ProgressView().controlSize(.small) }
                Button("测试连接") { model.testConnection() }
                    .controlSize(.small)
                    .disabled(model.isTesting || model.apiKey.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            if let result = model.testResult {
                SettingsRowDivider()
                Text(result)
                    .font(.system(size: 11))
                    .foregroundStyle(result.hasPrefix("失败") ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
        }
    }

    // MARK: - 文字识别

    /// Same shape as 翻译: what recognises the text first, then the scan option, then the third-party
    /// service's own card.
    private var ocrPage: some View {
        VStack(spacing: 18) {
            SettingsCard {
                SettingsRow("识别引擎", detail: "选百度后截图会上传到百度服务器；翻译、贴图选字也跟着走") {
                    Picker("", selection: $model.ocrEngine) {
                        ForEach(OCREngine.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
            }

            SettingsCard {
                SettingsToggleRow(title: "扫码后自动复制", isOn: $model.scanAutoCopy)
            }

            if model.ocrEngine == .baidu { baiduCard }
        }
    }

    private var baiduCard: some View {
        SettingsCard {
            SettingsRow("API Key") {
                SecureField("", text: $model.baiduAPIKey, prompt: Text("百度应用的 API Key"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            SettingsRowDivider()
            SettingsRow("Secret Key", detail: "存在本机，只有你能读") {
                SecureField("", text: $model.baiduSecretKey, prompt: Text("百度应用的 Secret Key"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            SettingsRowDivider()
            // 两个接口各有一份免费额度，用完了会自动换到另一个，所以它只是「先用哪个」。
            SettingsRow("识别精度", detail: "两份额度分开算，用完一份会自动换另一份") {
                Picker("", selection: $model.baiduPrecision) {
                    ForEach(BaiduOCRPrecision.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            SettingsRowDivider()
            SettingsRow("识别语言") {
                Picker("", selection: $model.baiduLanguage) {
                    ForEach(BaiduOCRLanguage.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            SettingsRowDivider()
            HStack(spacing: 10) {
                Spacer()
                if model.isTesting { ProgressView().controlSize(.small) }
                Button("测试识别") { model.testOCR() }
                    .controlSize(.small)
                    .disabled(model.isTesting || model.baiduAPIKey.isEmpty || model.baiduSecretKey.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            if let result = model.testResult {
                SettingsRowDivider()
                Text(result)
                    .font(.system(size: 11))
                    .foregroundStyle(result.hasPrefix("失败") ? Color.red : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
        }
    }

    // MARK: - 通用

    private var generalPage: some View {
        VStack(spacing: 18) {
            SettingsCard {
                SettingsToggleRow(title: "登录时启动 OmniShot", isOn: $model.launchAtLogin)
                if let error = model.loginItemError {
                    SettingsRowDivider()
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
            }

            SettingsCard {
                SettingsRow("单击菜单栏图标") {
                    Picker("", selection: $model.menuBarClickAction) {
                        ForEach(MenuBarClickAction.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                // Leaving the menu behind on the left click hides 设置 from anyone who only ever clicks the
                // icon, so say where it went. Only when it can actually happen.
                if model.menuBarClickAction != .menu {
                    SettingsRowDivider()
                    Text("右键单击菜单栏图标，可以打开其余菜单和设置。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
            }

            SettingsCard {
                SettingsToggleRow(title: "截图时自动隐藏贴图", isOn: $model.hidesPinsWhileCapturing)
                SettingsRowDivider()
                SettingsRow("主题色") {
                    ColorPicker("", selection: $model.themeColor, supportsOpacity: false)
                        .labelsHidden()
                }
            }

            SettingsCard {
                SettingsRow("检查更新", detail: "当前版本：\(appVersion)") {
                    Button("立即检查") { Updater.shared.checkForUpdates() }
                        .controlSize(.small)
                        .disabled(!Updater.isAvailable)
                }
                SettingsRowDivider()
                SettingsToggleRow(title: "自动检查更新",
                                  detail: Updater.isAvailable ? "发现新版本只在菜单里提示，由你决定何时安装" : "暂未开通，新版本要手动下载",
                                  isOn: $model.automaticallyChecksForUpdates)
                    .disabled(!Updater.isAvailable)
            }
        }
    }

    /// The short version, without the build number: About shows it in the title badge, General in the
    /// update row. `Updater.versionString` still carries the build for places that need both.
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    // MARK: - 关于

    /// The app header lives inside the pinned page header, exactly where DockMinimize puts it.
    private var aboutHeader: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("OmniShot")
                        .font(.system(size: 19, weight: .semibold))
                    Text("v\(appVersion)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text("截图、标注、贴图、长截图，外加原位翻译")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    aboutLink("访问网站", systemImage: "globe", url: "https://ivean.com/omnishot/")
                    aboutLink("赞助", systemImage: "heart.fill", url: "https://ivean.com/donate/")
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            RecommendationsSection()

            SettingsCard {
                SettingsRow("感谢Shotlate的开源") {
                    EmptyView()
                }
                SettingsRowDivider()
                SettingsRow("图标来源", detail: "Phosphor Icons 与 Lucide") {
                    EmptyView()
                }
            }
        }
    }

    /// The two text links in the About header. DockMinimize puts them under the tagline, in the accent
    /// colour, with the same plain style; the page is not a control surface otherwise.
    private func aboutLink(_ title: String, systemImage: String, url: String) -> some View {
        Button {
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}

/// The shortcut itself, drawn as a key cap. Clicking it starts recording.
private struct ShortcutKeyCap: View {
    let value: Shortcut?
    let isRecording: Bool
    let start: () -> Void

    private var label: String {
        if isRecording { return "按下新的组合键…" }
        return value?.displayString ?? "未设置"
    }

    var body: some View {
        Button(action: start) {
            Text(label)
                .font(.system(size: 12, weight: isRecording ? .semibold : .medium, design: .rounded))
                .foregroundStyle(isRecording ? Color.accentColor : (value == nil ? Color.secondary : Color.primary))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(minWidth: 56)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isRecording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help(isRecording ? "按 Esc 取消" : "点击后按下新的组合键")
    }
}
