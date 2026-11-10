import AppKit
import Carbon.HIToolbox
import CoreImage
import OmniShotCore
import SwiftUI

/// Set while the self-checks run.
///
/// The checks drive the same code a real capture does, in the same process, so anything that puts a window on
/// screen lands on the user's display: the 输入翻译 window, a long-screenshot result, a HUD. That is noise at
/// best and, at worst, looks like the app doing something on its own — which is exactly how it was reported:
/// "偶尔会自动跳出输入翻译的界面然后立刻消失" while the installed app was running untouched.
enum SelfCheck {
    static var isRunning = false
}

/// Scripted behaviour checks that need AppKit (windows, pasteboard, rendering) and so can't live in OmniShotCore's tests.
/// Each check prints PASS/FAIL lines and the process exits non-zero if any expectation failed.
///
///   OmniShot --check <name|all> [output-directory]
enum FeatureChecks {
    @MainActor private static var failures = 0
    @MainActor static var outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("omnishot-checks")

    @MainActor static func expect(_ condition: Bool, _ message: String) {
        print(condition ? "PASS  \(message)" : "FAIL  \(message)")
        if !condition { failures += 1 }
    }

    @MainActor static let checks: [(String, @MainActor () async -> Void)] = [
        ("pins-hide", pinsHide),
        ("pin-keys", pinKeys),
        ("pin-clipboard", pinClipboard),
        ("tool-colors", toolColors),
        ("item-styles", itemStyles),
        ("delete-item", deleteItem),
        ("shape-tool", shapeTool),
        ("highlighter", highlighterTool),
        ("mosaic-strength", mosaicStrength),
        ("mosaic-hints", mosaicHints),
        ("auto-mask", autoMask),
        ("erase", erase),
        ("number-caption", numberCaption),
        ("scan-code", scanCode),
        ("pin-annotate", pinAnnotate),
        ("hotkeys", hotkeys),
        ("settings", settings),
        ("magnifier", magnifierTool),
        ("loupe", loupe),
        ("pin-translate", pinTranslate),
        ("translate-capture", translateCapture),
        ("translate-dismiss", translateDismiss),
        ("translate-pin", translatePin),
        ("click-outside-cancel", clickOutsideCancel),
        ("translation-bar", translationBar),
        ("translation-engine", translationEngine),
        ("translation-language", translationLanguage),
        ("small-text", smallText),
        ("text-translate", textTranslate),
        ("translation-style", translationStyle),
        ("text-blocks", textBlocks),
        ("document-segments", documentSegments),
        ("highlight", highlight),
        ("tool-icons", toolIcons),
        ("ocr-shortcut", ocrShortcut),
        ("menubar-icon", menuBarIcon),
        ("menubar-click", menuBarClick),
        ("pins-while-capturing", pinsWhileCapturing),
        ("rounded-corners", roundedCorners),
        ("pin-text", pinText),
        ("double-click-pin", doubleClickPin),
        ("pin-close", pinClose),
        ("pin-layer", pinLayer),
        ("theme-color", themedChrome),
        ("pin-buttons", pinButtons),
        ("pin-rotate", pinRotate),
        ("pin-resize", pinResize),
        ("toolbar-placement", toolbarPlacement),
        ("size-chip", sizeChip),
        ("toolbar-keys", toolbarKeys),
        ("ocr", ocr),
        ("ocr-service", ocrService),
        ("baidu-ocr", baiduOCR),
        ("scroll-result-keys", scrollResultKeys),
        ("secret-file", secretFile),
        ("llm-configs", llmConfigs),
        ("legacy-migration", legacyMigration),
        ("updater", updater),
    ]

    @MainActor
    static func run(_ name: String, output: URL?) async -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Everything below drives real code; nothing it does may reach the user's screen.
        SelfCheck.isRunning = true
        // Start from default preferences so one run's choices (colors, dashes, ratios) can't leak into the next.
        // Only when running unbundled from .build: then the domain is the executable's, never the app's.
        if Bundle.main.bundleIdentifier == nil {
            UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
        }
        if let output { outputDirectory = output }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let selected = name == "all" ? checks : checks.filter { $0.0 == name }
        guard !selected.isEmpty else {
            print("unknown check \(name); available: \(checks.map(\.0).joined(separator: ", "))")
            return 2
        }
        for (checkName, body) in selected {
            print("== \(checkName)")
            await body()
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    /// A small solid-color image, `size` in points at 2x.
    static func sampleRep(_ size: CGSize = CGSize(width: 120, height: 80), color: NSColor = .systemTeal) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        CGRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The name the checks print for a 打码 mode.
    static func mosaicModeName(_ mode: MosaicMode) -> String {
        switch mode {
        case .brush: return "画笔"
        case .rect: return "框选"
        case .auto: return "自动识别"
        }
    }

    @MainActor static func write(_ rep: NSBitmapImageRep, _ name: String) {
        try? rep.representation(using: .png, properties: [:])?.write(to: outputDirectory.appendingPathComponent(name))
    }

    // MARK: - Checks

    @MainActor static func pinsHide() async {
        let manager = PinManager.shared
        let a = manager.pin(sampleRep(), frame: CGRect(x: -4000, y: -4000, width: 120, height: 80))
        let b = manager.pin(sampleRep(), frame: CGRect(x: -3800, y: -4000, width: 120, height: 80))
        expect(a.isVisible && b.isVisible, "new pins are visible")
        manager.toggleHidden()
        expect(manager.isHidingAll && !a.isVisible && !b.isVisible, "toggle hides every pin")
        manager.toggleHidden()
        expect(!manager.isHidingAll && a.isVisible && b.isVisible, "toggle again shows them")
        manager.toggleHidden()
        let c = manager.pin(sampleRep(), frame: CGRect(x: -3600, y: -4000, width: 120, height: 80))
        expect(!manager.isHidingAll && a.isVisible && c.isVisible, "a new pin while hidden brings the others back")
        manager.closeAll()
        expect(!manager.hasPins, "close all empties the list")
    }

    @MainActor static func key(_ window: NSWindow, _ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        window.keyDown(with: event)
    }

    @MainActor static func pinKeys() async {
        let manager = PinManager.shared
        let pin = manager.pin(sampleRep(CGSize(width: 120, height: 80)), frame: CGRect(x: -4000, y: -4000, width: 120, height: 80))
        key(pin, "=", code: 24)
        expect(abs(pin.zoom - 1.1) < 0.001, "= zooms in (zoom \(pin.zoom))")
        key(pin, "-", code: 27)
        expect(abs(pin.zoom - 1) < 0.001, "- zooms out")
        key(pin, "0", code: 29)
        pin.setZoom(2)
        key(pin, "0", code: 29)
        expect(abs(pin.zoom - 1) < 0.001, "0 goes back to 100%")
        key(pin, "\u{1b}", code: 53)
        expect(!manager.pins.contains { $0 === pin }, "Esc closes the pin")
    }

    @MainActor static func pinClipboard() async {
        let manager = PinManager.shared
        let pb = NSPasteboard(name: NSPasteboard.Name("app.omnishot.check"))
        func pinned(_ fill: () -> Void) -> [PinWindow] {
            pb.clearContents()
            fill()
            let before = manager.pins.count
            manager.pinClipboard(pb)
            return Array(manager.pins.dropFirst(before))
        }
        func pixel(_ pin: PinWindow, _ x: Int, _ y: Int) -> NSColor? { pin.rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }

        let dir = outputDirectory.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.png"), txt = dir.appendingPathComponent("notes.txt")
        try? sampleRep(color: .systemRed).representation(using: .png, properties: [:])?.write(to: a)
        try? sampleRep(color: .systemBlue).representation(using: .png, properties: [:])?.write(to: b)
        try? "hello".write(to: txt, atomically: true, encoding: .utf8)
        let images = pinned { pb.writeObjects([a as NSURL, b as NSURL]) }
        expect(images.count == 2, "two copied image files become two pins")
        if let c = images.first.flatMap({ pixel($0, 20, 20) }) {
            expect(c.redComponent > 0.8 && c.blueComponent < 0.4, "the pin shows the file's image (\(c))")
        }
        let picture = NSImage(size: CGSize(width: 60, height: 40))
        picture.addRepresentation(sampleRep(CGSize(width: 60, height: 40)))
        let bitmap = pinned { pb.writeObjects([picture]) }
        expect(bitmap.count == 1 && bitmap[0].rep.size == CGSize(width: 60, height: 40), "copied image data becomes a pin")
        let text = pinned { pb.setString("#FF8000", forType: .string) }
        expect(text.isEmpty, "text is not pinned")
        let paths = pinned { pb.writeObjects([txt as NSURL]) }
        expect(paths.isEmpty, "a non-image file is not pinned")

        let empty = pinned { }
        expect(empty.isEmpty, "empty clipboard pins nothing")
        manager.closeAll()
    }

    @MainActor static func toolbarPlacement() async {
        func chrome(_ h: CaptureHarness) -> (ToolbarView, StyleBarView) {
            (h.view.subviews.compactMap { $0 as? ToolbarView }.first!, h.view.subviews.compactMap { $0 as? StyleBarView }.first!)
        }
        let size = CGSize(width: 1200, height: 860)

        var h = CaptureHarness(size: size)
        h.select(CGRect(x: 100, y: 100, width: 600, height: 300))
        var (bar, style) = chrome(h)
        expect(!bar.isVertical && bar.frame.minY >= 400, "room below: the toolbar is a row under the selection")
        let card = bar.hoverCard
        expect(card.isHidden, "no hover card until the pointer is on a button")
        bar.toolButtons[.mosaic]?.onHover?(true)
        try? await Task.sleep(for: .milliseconds(120))
        expect(card.isHidden, "no card while the pointer is only passing over")
        try? await Task.sleep(for: .milliseconds(300))
        let mosaic = bar.toolButtons[.mosaic]!.convert(bar.toolButtons[.mosaic]!.bounds, to: h.view)
        expect(!card.isHidden && card.frame.maxY <= bar.frame.minY && abs(card.frame.midX - mosaic.midX) < 1,
               "hovering a button shows its card above it (\(card.frame))")
        h.screenshot().map { write($0, "toolbar-hover.png") }
        bar.toolButtons[.mosaic]?.onHover?(false)
        expect(!card.isHidden, "leaving the button leaves time to reach the card")
        bar.toolButtons[.arrow]?.onHover?(true)
        let arrow = bar.toolButtons[.arrow]!.convert(bar.toolButtons[.arrow]!.bounds, to: h.view)
        expect(!card.isHidden && abs(card.frame.midX - arrow.midX) < 1, "with a card up, the next button's card shows at once")
        bar.toolButtons[.arrow]?.onHover?(false)
        try? await Task.sleep(for: .milliseconds(600))
        expect(card.isHidden, "and then hides it")
        bar.toolButtons[.rectangle]?.onHover?(true)
        bar.toolButtons[.rectangle]?.onHover?(false)
        try? await Task.sleep(for: .milliseconds(600))
        expect(card.isHidden, "a pointer that leaves before the delay never shows a card")

        // 卡片第一行是「名称 + 按键」，第二行只在有额外说明时出现；文案就是这次定的那几句。
        // 第一张要等它弹出来，后面的卡片已经在了，换过去立刻更新。
        bar.actionButtons[.ocr]?.onHover?(true)
        try? await Task.sleep(for: .milliseconds(600))
        let ocrHint = card.isHidden ? nil : card.testing_text
        expect(ocrHint?.title == "识别内容" && ocrHint?.note == "可识别文字与二维码",
               "识别内容的卡片：名称 + 按键，说明覆盖文字和二维码（\(ocrHint.map { "\($0)" } ?? "nil")）")
        func hint(_ action: ToolbarAction) -> (title: String, note: String)? {
            bar.actionButtons[action]?.onHover?(true)
            return card.isHidden ? nil : card.testing_text
        }
        let translateHint = hint(.translate)
        expect(translateHint?.title == "翻译到原位" && translateHint?.note == "可在原文与译文间切换",
               "翻译的说明是「可在原文与译文间切换」（\(translateHint.map { "\($0)" } ?? "nil")）")
        write(h.screenshot() ?? sampleRep(), "toolbar-hover-note.png")
        let pinHint = hint(.pin)
        expect(pinHint?.title == "贴到屏幕上" && pinHint?.note == "双击图片快捷贴图",
               "贴到屏幕上的说明是「双击图片快捷贴图」（\(pinHint.map { "\($0)" } ?? "nil")）")
        let longHint = hint(.longCapture)
        expect(longHint?.title == "长截图" && longHint?.note == "在选区内滚动鼠标截长屏",
               "长截图的说明是「在选区内滚动鼠标截长屏」（\(longHint.map { "\($0)" } ?? "nil")）")
        let undoHint = hint(.undo)
        expect(undoHint?.title == "撤销" && undoHint?.note == "",
               "没有额外说明的按钮只有一行（\(undoHint.map { "\($0)" } ?? "nil")）")
        expect(card.frame.height < 45, "没有说明时卡片只有一行高（\(card.frame.height)）")

        h = CaptureHarness(size: size)
        let low = CGRect(x: 100, y: 300, width: 700, height: 540)
        h.select(low)
        h.key("1", code: 18)
        (bar, style) = chrome(h)
        expect(bar.isVertical && bar.frame.minX == low.maxX + 8, "no room below: a column against the right edge (\(bar.frame))")
        expect(bar.frame.maxY <= size.height - 4 && bar.frame.minY >= 4, "the column stays on screen")
        let icon = bar.anchor(for: .rectangle)!.y + bar.frame.minY
        expect(!style.isHidden && style.frame.maxX <= bar.frame.minX && abs(style.frame.midY - icon) < 2,
               "the style bar sits left of the column, level with its tool (\(style.frame))")
        bar.toolButtons[.arrow]?.onHover?(true)
        try? await Task.sleep(for: .milliseconds(600))
        expect(!bar.hoverCard.isHidden && bar.hoverCard.frame.minX >= bar.frame.maxX, "in a column the card goes beside it (\(bar.hoverCard.frame))")
        h.screenshot().map { write($0, "toolbar-right.png") }

        h = CaptureHarness(size: size)
        let wide = CGRect(x: 400, y: 300, width: 790, height: 540)
        h.select(wide)
        h.key("1", code: 18)
        (bar, style) = chrome(h)
        expect(bar.isVertical && bar.frame.maxX == wide.minX - 8, "no room right: the column goes left (\(bar.frame))")
        expect(style.frame.minX >= bar.frame.maxX, "with the style bar right of it")
        h.screenshot().map { write($0, "toolbar-left.png") }

        h = CaptureHarness(size: size)
        h.select(CGRect(x: 2, y: 2, width: 1196, height: 856))
        (bar, style) = chrome(h)
        expect(bar.isVertical && bar.frame.maxX == 1198 - 8, "no room outside: a column inside the right edge (\(bar.frame))")

        // A narrow full-height selection at the right edge: the column goes outside, on its left.
        h = CaptureHarness(size: size)
        h.select(CGRect(x: 1100, y: 2, width: 98, height: 856))
        (bar, style) = chrome(h)
        expect(bar.isVertical && bar.frame.maxX == 1100 - 8, "a narrow selection at the edge gets the column on its left (\(bar.frame))")

        // Back from a column to a row when the selection moves up.
        h = CaptureHarness(size: size)
        h.select(low)
        for _ in 0..<100 { h.key("", code: 126) }
        (bar, style) = chrome(h)
        expect(!bar.isVertical, "moving the selection up turns the column back into a row (\(bar.frame))")

        // The size chip has to stay out of the selection too. Against the top of the screen there is no room
        // above it, and it used to drop into the selection's top-left corner — over the first line of whatever
        // the user was capturing. Now it steps aside instead.
        let high = CaptureHarness(size: size)
        let atTop = CGRect(x: 100, y: 6, width: 600, height: 300)
        high.select(atTop)
        let chip = high.view.testing_sizeChipFrame
        expect(chip == nil || !(chip!.intersects(atTop)),
               "顶上放不下时尺寸框让位，不会落进选区（\(chip.map { "\($0)" } ?? "已让位")）")
    }

    /// 尺寸框：点进去改数字，选区跟着变。只能是大于 1 的正整数，改完还能拖着挪位置。
    @MainActor static func sizeChip() async {
        func shown(_ rect: CGRect?) -> String { rect.map { "\($0)" } ?? "无" }
        func chip(_ h: CaptureHarness) -> TopBarView? { h.view.subviews.compactMap { $0 as? TopBarView }.first }

        // 改数字：左上角是锚点，往右下长。
        let a = CaptureHarness(size: CGSize(width: 1400, height: 1200))
        a.select(CGRect(x: 100, y: 100, width: 600, height: 300))
        guard let first = chip(a) else { return expect(false, "选区上方有尺寸框") }
        expect(first.testing_fields.width == "600" && first.testing_fields.height == "300",
               "尺寸框显示当前选区的大小（\(first.testing_fields.width) × \(first.testing_fields.height)）")

        first.testing_beginEditing()
        first.testing_type("800", intoWidth: true)
        expect(a.view.testing_selection == CGRect(x: 100, y: 100, width: 800, height: 300),
               "输入 800，选区从左上角往右长（\(shown(a.view.testing_selection))）")
        first.testing_type("900", intoWidth: false)
        expect(a.view.testing_selection == CGRect(x: 100, y: 100, width: 800, height: 900),
               "高度也一样（\(shown(a.view.testing_selection))）")
        a.screenshot().map { write($0, "size-chip.png") }
        renderControls(first, name: "size-chip-fields.png")

        // 不是大于 1 的正整数就不算数，选区不动。
        for bad in ["", "0", "1", "abc"] {
            first.testing_type(bad, intoWidth: true)
            expect(a.view.testing_selection?.width == 800, "「\(bad)」不算数，选区不动")
        }
        // 但混进来的字母和空格直接忽略：粘一句「800 px」也能用。
        first.testing_type("800 px", intoWidth: true)
        expect(a.view.testing_selection?.width == 800 && first.testing_fields.width == "800",
               "「800 px」按 800 算，字母和空格丢掉（\(first.testing_fields.width)）")

        // 空着提交：数字要回到选区真实的大小，不能留个空框在那儿。
        first.testing_type("", intoWidth: true)
        first.testing_endEditing()
        expect(first.testing_fields.width == "800", "空着提交，数字回到真实大小（\(first.testing_fields.width)）")

        // 比屏幕大：截到屏幕，数字也改成实际值——屏幕上显示的必须是你真正拿到的那块。
        first.testing_beginEditing()
        first.testing_type("5000", intoWidth: true)
        first.testing_endEditing()
        expect(a.view.testing_selection?.width == 1400, "超出屏幕就截到屏幕宽（\(shown(a.view.testing_selection))）")
        expect(first.testing_fields.width == "1400", "数字跟着改成实际值（\(first.testing_fields.width)）")

        // 贴着右边缘改大：尺寸照给，整块往左挪，不戳出屏幕。（换一个 harness：上一步的选区已经铺满，再
        // 拖会变成「移动」而不是重新框选。）
        let b = CaptureHarness(size: CGSize(width: 1400, height: 1200))
        b.select(CGRect(x: 1200, y: 100, width: 150, height: 300))
        guard let second = chip(b) else { return expect(false, "第二个 harness 里也有尺寸框") }
        second.testing_beginEditing()
        second.testing_type("600", intoWidth: true)
        expect(b.view.testing_selection == CGRect(x: 800, y: 100, width: 600, height: 300),
               "放不下就整块往左挪（\(shown(b.view.testing_selection))）")

        // Esc 反悔：改到一半，选区和数字都回到原样。
        second.testing_beginEditing()
        second.testing_type("300", intoWidth: true)
        expect(b.view.testing_selection?.width == 300, "改的过程中就生效，不用等回车")
        second.testing_endEditing(cancelled: true)
        expect(b.view.testing_selection == CGRect(x: 800, y: 100, width: 600, height: 300),
               "Esc 把选区改回去（\(shown(b.view.testing_selection))）")
        expect(second.testing_fields.width == "600", "Esc 把数字也改回去（\(second.testing_fields.width)）")

        // 改完大小，选区照常能拖着挪。
        b.drag(CGPoint(x: 1000, y: 200), CGPoint(x: 900, y: 260))
        expect(b.view.testing_selection?.minX == 700, "改完大小还能拖着挪（\(shown(b.view.testing_selection))）")
    }

    @MainActor static func toolbarKeys() async {
        ToolbarKeys.reset()
        defer { ToolbarKeys.reset() }
        let h = CaptureHarness()
        h.select(CGRect(x: 100, y: 100, width: 600, height: 200))
        let bar = h.view.subviews.compactMap { $0 as? ToolbarView }.first!
        let card = bar.hoverCard
        let rect = bar.toolButtons[.rectangle]!

        rect.onHover?(true)
        try? await Task.sleep(for: .milliseconds(600))
        rect.onHover?(false)
        card.onHover?(true) // the pointer arrives on the card within the grace time
        try? await Task.sleep(for: .milliseconds(600))
        expect(!card.isHidden, "the card stays while the pointer is on it")

        h.window.makeFirstResponder(h.view)
        let cap = card.subviews.first { $0.layer?.cornerRadius == 4 }!
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: card.convert(CGPoint(x: cap.frame.midX, y: cap.frame.midY), to: nil),
                                      modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber, context: nil,
                                      eventNumber: 0, clickCount: 1, pressure: 1)!
        card.mouseDown(with: down)
        expect(card.isRecording && h.window.firstResponder === card, "clicking the key cap waits for a new key")
        h.screenshot().map { write($0, "toolbar-key-recording.png") }
        h.key("e", code: 14)
        expect(!card.isRecording && ToolbarKeys.key(for: "rectangle") == "e" && h.window.firstResponder === h.view,
               "pressing E makes it the rectangle's key and gives the keyboard back")
        h.key("e", code: 14)
        expect(bar.toolButtons[.rectangle]!.isActive, "E now picks the rectangle")
        h.key("1", code: 18)
        expect(bar.toolButtons[.rectangle]!.isActive, "1 no longer does anything")

        card.startRecording()
        h.key("2", code: 19)
        expect(ToolbarKeys.key(for: "rectangle") == "2" && ToolbarKeys.key(for: "arrow") == "e", "a taken key swaps with its owner")
        h.screenshot().map { write($0, "toolbar-key-swapped.png") }
        card.startRecording()
        h.key("\u{1b}", code: 53)
        expect(!card.isRecording && ToolbarKeys.key(for: "rectangle") == "2", "Esc cancels without changing the key")
        card.startRecording()
        h.key("a", code: 0, flags: .command)
        expect(card.isRecording && ToolbarKeys.key(for: "rectangle") == "2", "keys with ⌘ are refused")
        h.window.makeFirstResponder(h.view)
        expect(!card.isRecording, "clicking elsewhere stops waiting")
    }

    @MainActor static func render(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Renders a settings page offscreen and writes it as a PNG, for looking at the layout without
    /// opening the window. The window is parked off screen and never ordered in, so nothing flashes on
    /// the user's display.
    ///
    /// Drawn through `displayIgnoringOpacity` into a bitmap of our own, not `cacheDisplay` — the latter
    /// leaves controls out entirely (buttons came out as bare text), the same trap that caught the
    /// 输入翻译 window. The view has no background of its own either, so the window colour goes under it.
    ///
    /// `ImageRenderer` would be the tidier tool, but it cannot draw a `NavigationSplitView`: it answers
    /// with a "prohibited" placeholder instead of the view.
    ///
    /// One thing does not survive any offscreen draw: a `.bordered` button's bezel is window material,
    /// so the buttons in these PNGs are flat. Judge their look in the running app.
    @MainActor static func renderPane(_ view: some View, size: CGSize, name: String) -> NSBitmapImageRep? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -9000, y: -9000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                            pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        canvas.size = size
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: canvas)!
        NSGraphicsContext.current = context
        NSColor.windowBackgroundColor.setFill()
        hosting.bounds.fill()
        hosting.displayIgnoringOpacity(hosting.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()
        write(canvas, name)
        return canvas
    }

    /// Renders one AppKit view and its subviews, for panels whose whole point is text fields and buttons —
    /// `cacheDisplay` (which `CaptureHarness.screenshot` uses) draws neither, so the size chip came out as an
    /// empty blue pill.
    @MainActor @discardableResult
    static func renderControls(_ view: NSView, name: String) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                            pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        canvas.size = size
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: canvas)!
        NSGraphicsContext.current = context
        view.displayIgnoringOpacity(view.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()
        write(canvas, name)
        return canvas
    }

    /// Whether a rendering looks like a settings page. Two ways it can go wrong, and both have been
    /// seen: an empty draw (one flat colour), and SwiftUI refusing to draw a view at all — `ImageRenderer`
    /// answers a `NavigationSplitView` with a saturated "prohibited" graphic, which is not blank, so a
    /// colour count alone would wave it through.
    @MainActor static func looksLikeAPage(_ rep: NSBitmapImageRep) -> Bool {
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 3 else { return false }
        var seen = Set<UInt32>()
        var saturation = 0.0
        var count = 0.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                let offset = y * rep.bytesPerRow + x * rep.samplesPerPixel
                let r = Double(data[offset]), g = Double(data[offset + 1]), b = Double(data[offset + 2])
                seen.insert(UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b))
                let high = max(r, max(g, b)), low = min(r, min(g, b))
                saturation += high > 0 ? (high - low) / high : 0
                count += 1
            }
        }
        // A page is mostly the window's neutral background with a little accent on top.
        return seen.count > 20 && count > 0 && saturation / count < 0.25
    }

    @MainActor static func toolColors() async {
        UserDefaults.standard.removeObject(forKey: "style.colors")
        UserDefaults.standard.removeObject(forKey: "style.sizes")
        expect(StyleMemory.color(for: .rectangle).isApproximately(StyleState.palette[0]), "tools start red")

        let h = CaptureHarness()
        h.select(CGRect(x: 40, y: 40, width: 600, height: 360))
        h.key("1", code: 18)
        h.view.testing_applyStyle(.color(StyleState.palette[3]))
        h.view.testing_applyStyle(.size(8))
        h.key("2", code: 19)
        h.view.testing_applyStyle(.color(StyleState.palette[5]))
        h.key("1", code: 18)
        h.drag(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200))
        let rect = h.view.testing_items.last
        expect(rect?.color.isApproximately(StyleState.palette[3]) == true && rect?.size == 8, "rectangle keeps its own green and size 8")
        h.key("2", code: 19)
        h.drag(CGPoint(x: 300, y: 100), CGPoint(x: 400, y: 200))
        expect(h.view.testing_items.last?.color.isApproximately(StyleState.palette[5]) == true, "arrow keeps its own purple")
        expect(StyleMemory.color(for: .rectangle).isApproximately(StyleState.palette[3]) && StyleMemory.size(for: .rectangle) == 8,
               "choices are saved for the next launch")

        h.export().map { write($0, "tool-colors.png") }
    }

    /// 智能擦除：MI-GAN 把选中的内容补成周围的背景。这里量一块纸面上的深色方块——擦掉之后方块的位置应该和
    /// 纸面一样亮；同一个形状用毛玻璃盖住时中间仍是暗的，这一条用来证明真的走了模型，而不是退回了占位。
    /// 自动识别：点一下文字，相同内容全打码；⌥ 只处理这一处，⇧ 处理同一类，拖动补一块。
    ///
    /// The fixture repeats one email twice and has two *different* phone numbers, which is what tells the two
    /// kinds of click apart: a plain click on an email must cover two places, a plain click on a phone one, and
    /// ⇧ on a phone both.
    @MainActor static func autoMask() async {
        let mode = StyleMemory.mosaicMode
        let effect = StyleMemory.mosaicEffect
        let strength = StyleMemory.mosaicStrength
        defer {
            StyleMemory.mosaicMode = mode
            StyleMemory.mosaicEffect = effect
            StyleMemory.mosaicStrength = strength
        }
        StyleMemory.mosaicMode = .rect
        StyleMemory.mosaicEffect = .blur
        StyleMemory.mosaicStrength = 0.7

        let size = CGSize(width: 960, height: 780)
        let lines = [
            "Phone 业务员 +86 13800138001",
            "Phone 业务员 +86 13800138002",
            "Mail  alice.brown927@qq.com",
            "Mail  alice.brown927@qq.com",
            "Date  2026-10-20",
            "Date  2026-11-21",
            "Row A  Approved by admin",
            "Row B  Approved by admin",
        ]
        let h = CaptureHarness(size: size, paint: { _ in
            NSColor.white.setFill()
            CGRect(origin: .zero, size: size).fill()
            for (index, text) in lines.enumerated() {
                NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black,
                ]).draw(at: CGPoint(x: 360, y: 90 + CGFloat(index) * 36))
            }
        })
        let selection = CGRect(x: 320, y: 60, width: 540, height: 340)
        h.select(selection)
        h.key("4", code: 21)

        // The mode sits to the right of 框选, on the same row.
        if let bar = h.view.subviews.compactMap({ $0 as? StyleBarView }).first,
           let rect = bar.testing_modeButtons[.rect], let auto = bar.testing_modeButtons[.auto] {
            let rectFrame = rect.convert(rect.bounds, to: bar)
            let autoFrame = auto.convert(auto.bounds, to: bar)
            expect(autoFrame.minX > rectFrame.maxX - 1 && abs(autoFrame.midY - rectFrame.midY) < 1,
                   "自动识别在框选区域右边、同一行")
        } else {
            expect(false, "样式条上有自动识别按钮")
        }

        h.view.testing_applyStyle(.mosaicMode(.auto))
        for _ in 0..<600 where h.view.testing_autoTargets.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let targets = h.view.testing_autoTargets
        guard !targets.isEmpty else { return expect(false, "自动识别找到了内容") }
        expect(h.view.testing_autoMode, "自动识别模式下运行")

        let phones = targets.filter { $0.category == .phone }
        let emails = targets.filter { $0.category == .email }.filter { $0.text.contains("alice") }
        guard phones.count >= 2, let email = emails.first else {
            return expect(false, "两个电话、一个邮箱（\(targets.map { "\($0.text):\($0.category?.rawValue ?? "-")" })）")
        }
        expect(phones.allSatisfy { $0.groupCount == 1 && $0.categoryCount >= 2 },
               "两个电话值不同：各自的组只有一处，同类有两处")
        expect(email.groupCount == 2, "同一个邮箱出现两次，属于一组（\(email.groupCount)）")
        expect(targets.contains { $0.text == "业务员" && $0.groupCount == 2 },
               "重复出现的中文单元格（业务员）进入同一个组")
        let phrase = targets.first { $0.groupKey.hasPrefix("phrase:") && $0.text == "Approved by admin" }
        expect(phrase?.groupCount == 2, "相同的短语识别成一组（\(phrase?.text ?? "nil") / \(phrase?.groupCount ?? 0)）")

        // What the green frames would cover: the same set the click will touch.
        let phonePoint = CGPoint(x: phones[0].rect.midX, y: phones[0].rect.midY)
        let emailPoint = CGPoint(x: email.rect.midX, y: email.rect.midY)
        expect(h.view.testing_autoHoverTargets(at: phonePoint, flags: []).count == 1, "悬停一个号码，只亮这一处")
        expect(h.view.testing_autoHoverTargets(at: phonePoint, flags: .shift).count >= 2, "按住 ⇧，同类电话一起亮")
        expect(h.view.testing_autoHoverTargets(at: emailPoint, flags: []).count == 2, "悬停邮箱，两处一起亮")
        if let approved = targets.first(where: { $0.text == "Approved" }) {
            let hovered = h.view.testing_autoHoverTargets(
                at: CGPoint(x: approved.rect.midX, y: approved.rect.midY), flags: [])
            expect(hovered.count == 2 && hovered.allSatisfy { $0.text == "Approved by admin" },
                   "悬停短语里的一个词，亮的是整句短语（\(hovered.map(\.text))）")
        } else {
            expect(false, "「Approved」被识别成一个词")
        }

        // The guide lights the rule in use: first by default, another when a modifier is held.
        expect(h.view.testing_autoGuideRule == 0, "默认亮第一条规则")
        expect(h.view.testing_autoGuideRule(at: phonePoint, flags: .option) == 1, "⌥ 亮第二条")
        expect(h.view.testing_autoGuideRule(at: phonePoint, flags: .shift) == 2, "⇧ 亮第三条")
        expect(h.view.testing_autoGuideRule(at: phonePoint, flags: []) == 0, "没按修饰键时回到第一条")

        // The picture itself: no frames at rest, green frames on hover, gone again when the pointer leaves.
        func greenPixels(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
            var count = 0
            for x in stride(from: rect.minX, to: rect.maxX, by: 2) {
                for y in stride(from: rect.minY, to: rect.maxY, by: 2) {
                    guard let color = rep.color(atPoint: CGPoint(x: x, y: y))?.usingColorSpace(.sRGB) else { continue }
                    if color.greenComponent > 0.55,
                       color.greenComponent > color.redComponent + 0.15,
                       color.greenComponent > color.blueComponent + 0.15 { count += 1 }
                }
            }
            return count
        }
        let emailArea = emails.reduce(CGRect.null) { $0.union($1.rect) }.insetBy(dx: -8, dy: -8)
        if let idle = h.screenshot() {
            expect(greenPixels(idle, in: emailArea) == 0, "没有悬停时画面上没有虚线框（\(greenPixels(idle, in: emailArea))）")
            write(idle, "auto-mask-idle.png")
        }
        h.view.testing_setAutoHover(at: emailPoint)
        if let hovering = h.screenshot() {
            let green = greenPixels(hovering, in: emailArea)
            expect(green > 20, "悬停邮箱后两处都框成绿色虚线（\(green) 个绿点）")
            write(hovering, "auto-mask-hover.png")
        }
        h.view.testing_setAutoHover(at: nil)
        if let away = h.screenshot() {
            expect(greenPixels(away, in: emailArea) == 0, "鼠标移开后虚线框消失（\(greenPixels(away, in: emailArea))）")
        }

        // A modifier held and released: the second phone lights only while ⇧ is down and goes out on release.
        let secondPhoneArea = phones[1].rect.insetBy(dx: -8, dy: -8)
        h.view.testing_setAutoHover(at: phonePoint)
        h.view.testing_setAutoModifiers(.shift)
        if let held = h.screenshot() {
            expect(greenPixels(held, in: secondPhoneArea) > 0,
                   "按住 ⇧ 时第二个号码亮起（\(greenPixels(held, in: secondPhoneArea))）")
        }
        h.view.testing_setAutoModifiers([])
        if let released = h.screenshot() {
            expect(greenPixels(released, in: secondPhoneArea) == 0,
                   "松开 ⇧ 后第二个号码立即灭掉（\(greenPixels(released, in: secondPhoneArea))）")
        }
        h.view.testing_setAutoHover(at: nil)

        // The guide: left of the selection, top-aligned with it.
        guard let guide = h.view.testing_autoGuideFrame else { return expect(false, "操作指南显示出来了") }
        expect(guide.maxX <= selection.minX - 8, "指南在选区左边（\(guide) / \(selection)）")
        expect(abs(guide.minY - selection.minY) < 1, "指南和选区顶对齐（\(guide.minY) / \(selection.minY)）")
        h.screenshot().map { write($0, "auto-mask-candidates.png") }

        // Plain click on one phone: one place.
        let phone = phones[0]
        h.click(phonePoint)
        expect(h.view.testing_mosaicMaskCount == 1, "点一个号码，只打这一处（\(h.view.testing_mosaicMaskCount)）")
        expect(h.view.testing_autoGuideRule == 4, "悬停已打码的内容，亮「再点一次」（\(h.view.testing_autoGuideRule)）")
        h.click(phonePoint)
        expect(h.view.testing_mosaicMaskCount == 0, "再点一次取消（\(h.view.testing_mosaicMaskCount)）")

        // Plain click on the email: both places.
        h.click(CGPoint(x: email.rect.midX, y: email.rect.midY))
        expect(h.view.testing_mosaicMaskCount == 2, "点邮箱，两处一起打码（\(h.view.testing_mosaicMaskCount)）")
        h.screenshot().map { write($0, "auto-mask-masked.png") }
        if let after = h.export() {
            func changedFraction(_ rect: CGRect) -> Double {
                var changed = 0, total = 0
                for x in stride(from: rect.minX + 2, to: rect.maxX - 2, by: 3) {
                    for y in stride(from: rect.minY + 2, to: rect.maxY - 2, by: 3) {
                        let point = CGPoint(x: x, y: y)
                        guard let a = after.color(atPoint: CGPoint(x: point.x - selection.minX, y: point.y - selection.minY)),
                              let b = h.original(point) else { continue }
                        total += 1
                        if abs(a.brightnessComponent - b.brightnessComponent) > 0.03 { changed += 1 }
                    }
                }
                return total == 0 ? 0 : Double(changed) / Double(total)
            }
            let masked = changedFraction(email.rect)
            expect(masked > 0.3, "两处邮箱的文字被盖住了（\(Int(masked * 100))% 的取样点变了）")
            if let date = targets.first(where: { $0.category == .date }) {
                let untouched = changedFraction(date.rect)
                expect(untouched < 0.05, "没点的日期原样留着（\(Int(untouched * 100))% 变了）")
            }
        } else {
            expect(false, "导出打码后的图")
        }

        // ⌥ on the second masked email takes only that one.
        guard emails.count >= 2 else { return expect(false, "两个邮箱目标") }
        h.click(CGPoint(x: emails[1].rect.midX, y: emails[1].rect.midY), flags: .option)
        expect(h.view.testing_mosaicMaskCount == 1, "⌥ 点击只取消这一处（\(h.view.testing_mosaicMaskCount)）")

        // ⇧ on a phone masks the whole kind, even though the two numbers differ.
        h.click(CGPoint(x: phone.rect.midX, y: phone.rect.midY), flags: .shift)
        expect(h.view.testing_mosaicMaskCount == 3, "⇧ 打码全部电话，另一处邮箱不受影响（\(h.view.testing_mosaicMaskCount)）")

        // One undo takes the whole group back.
        h.key("z", code: 6, flags: .command)
        expect(h.view.testing_mosaicMaskCount == 1, "一次撤销收回整组（\(h.view.testing_mosaicMaskCount)）")

        // A drag adds a box of its own, and a click on it takes it away.
        let empty = CGRect(x: 780, y: 370, width: 60, height: 24)
        h.drag(CGPoint(x: empty.minX, y: empty.minY), CGPoint(x: empty.maxX, y: empty.maxY))
        expect(h.view.testing_mosaicMaskCount == 2, "拖动补一块（\(h.view.testing_mosaicMaskCount)）")
        h.click(CGPoint(x: empty.midX, y: empty.midY))
        expect(h.view.testing_mosaicMaskCount == 1, "点自己补的那块取消（\(h.view.testing_mosaicMaskCount)）")

        h.screenshot().map { write($0, "auto-mask.png") }
    }

    @MainActor static func erase() async {
        let mode = StyleMemory.mosaicMode
        let effect = StyleMemory.mosaicEffect
        defer {
            StyleMemory.mosaicMode = mode
            StyleMemory.mosaicEffect = effect
        }
        StyleMemory.mosaicMode = .rect
        expect(Inpainting.isAvailable, "MI-GAN 模型在应用包里，能加载")

        let size = CGSize(width: 520, height: 400)
        let block = CGRect(x: 200, y: 170, width: 120, height: 60)
        let selection = CGRect(x: 20, y: 20, width: 480, height: 360)
        func paper(_ h: CaptureHarness) -> CaptureHarness { h }

        let h = CaptureHarness(size: size, paint: { context in
            context.setFillColor(gray: 0.86, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(gray: 0.18, alpha: 1)
            context.fill(block)
        })
        h.select(selection)
        h.key("4", code: 21)
        StyleMemory.mosaicEffect = .erase
        let area = block.insetBy(dx: -12, dy: -10)
        h.drag(CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.maxY))
        write(h.screenshot() ?? sampleRep(), "erase-before.png")

        // 导出的图是选区坐标，采样的点要跟着减掉选区原点。
        let centre = CGPoint(x: block.midX - selection.minX, y: block.midY - selection.minY)
        guard let after = h.export(), let erased = after.color(atPoint: centre) else { return expect(false, "导出擦除后的图") }
        write(after, "erase-after.png")
        expect(erased.brightnessComponent > 0.72,
               "擦掉的地方补成了纸面的亮度（\(String(format: "%.2f", erased.brightnessComponent))，纸面 0.86）")

        // 渐变背景：把「上下颠倒」钉住。原图自上而下由亮到暗，补出来的那块也必须同向 —— 反了会在按钮、
        // 渐变底图上留下一条明显的接缝（真实截图里就是这么发现的，纯色背景看不出来）。
        let shaded = CaptureHarness(size: size, paint: { context in
            for row in 0..<Int(size.height) {
                context.setFillColor(gray: 0.95 - 0.5 * CGFloat(row) / size.height, alpha: 1)
                context.fill(CGRect(x: 0, y: CGFloat(row), width: size.width, height: 1))
            }
            context.setFillColor(gray: 0.18, alpha: 1)
            context.fill(block)
        })
        shaded.select(selection)
        shaded.key("4", code: 21)
        StyleMemory.mosaicEffect = .erase
        shaded.drag(CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.maxY))
        if let rep = shaded.export() {
            let high = rep.color(atPoint: CGPoint(x: block.midX - selection.minX, y: block.minY + 8 - selection.minY))
            let low = rep.color(atPoint: CGPoint(x: block.midX - selection.minX, y: block.maxY - 8 - selection.minY))
            let above = high?.brightnessComponent ?? 0, below = low?.brightnessComponent ?? 1
            expect(above > below + 0.02, "渐变背景上补出来的那块，明暗方向和原图一致（上 \(String(format: "%.2f", above)) / 下 \(String(format: "%.2f", below))）")
        } else {
            expect(false, "导出渐变擦除图")
        }
        write(shaded.screenshot() ?? sampleRep(), "erase-gradient.png")

        // 对照：同一个形状换成毛玻璃，中间应该还是暗的——否则上面那条只证明了「有东西盖住了」。
        let blur = CaptureHarness(size: size, paint: { context in
            context.setFillColor(gray: 0.86, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
            context.setFillColor(gray: 0.18, alpha: 1)
            context.fill(block)
        })
        blur.select(selection)
        blur.key("4", code: 21)
        StyleMemory.mosaicEffect = .blur
        StyleMemory.mosaicStrength = 1
        blur.drag(CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.maxY))
        if let rep = blur.export(), let covered = rep.color(atPoint: centre) {
            expect(covered.brightnessComponent < 0.6,
                   "对照：同样的形状用毛玻璃时中间仍是暗的（\(String(format: "%.2f", covered.brightnessComponent))）")
        } else {
            expect(false, "导出毛玻璃对照图")
        }
    }

    @MainActor static func numberCaption() async {
        let h = CaptureHarness()
        h.select(CGRect(x: 20, y: 20, width: 760, height: 460))
        func type(_ text: String) {
            (h.window.firstResponder as? NSTextView)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        func texts() -> [String] { h.view.testing_items.compactMap { if case let .text(t, _, _) = $0.shape { t } else { nil } } }
        func numbers() -> [CGPoint] { h.view.testing_items.compactMap { if case let .number(c) = $0.shape { c } else { nil } } }

        h.key("7", code: 26)
        h.click(CGPoint(x: 100, y: 100))
        expect(numbers().count == 1 && h.window.firstResponder is NSTextView, "placing a number starts typing its caption")
        type("第一步")
        h.click(CGPoint(x: 100, y: 200))
        expect(texts() == ["第一步"] && numbers().count == 2, "the next click keeps the caption and places number 2")
        if let caption = h.view.testing_items.first(where: { if case .text = $0.shape { true } else { false } }) {
            expect(caption.bounds.minX > 100 && abs(caption.bounds.midY - 100) < 16, "the caption sits right of its number (\(caption.bounds))")
        }
        h.screenshot().map { write($0, "number-caption.png") }
        h.key("\u{1b}", code: 53)
        expect(texts() == ["第一步"] && h.window.firstResponder === h.view, "Esc with nothing typed leaves just the number")
        h.key("", code: 51)
        expect(numbers().count == 1, "which is selected, so Delete removes it")
    }

    @MainActor static func itemStyles() async {
        UserDefaults.standard.removeObject(forKey: "style.options")
        for tool in Tool.allCases { StyleMemory.setColor(StyleState.palette[0], for: tool) }
        StyleMemory.sizes = [:]
        let h = CaptureHarness()
        h.select(CGRect(x: 20, y: 20, width: 760, height: 460))
        func option(_ change: @escaping (inout ItemStyle) -> Void) { h.view.testing_applyStyle(.options(change)) }

        h.key("1", code: 18)
        option { $0.dash = .dashed }
        option { $0.rounded = true }
        h.drag(CGPoint(x: 60, y: 60), CGPoint(x: 260, y: 160))
        // Esc first each time: an option change applies to the selected annotation, and the last one drawn is selected.
        h.key("\u{1b}", code: 53)
        h.key("2", code: 19)
        option { $0.arrowHead = .open }
        h.drag(CGPoint(x: 300, y: 160), CGPoint(x: 450, y: 70))
        h.key("\u{1b}", code: 53)
        option { $0.arrowHead = .double }
        h.drag(CGPoint(x: 480, y: 120), CGPoint(x: 700, y: 120))
        h.key("\u{1b}", code: 53)
        h.key("3", code: 20)
        option { $0.dash = .dotted }
        h.drag(CGPoint(x: 60, y: 220), CGPoint(x: 400, y: 220))
        h.key("\u{1b}", code: 53)
        h.key("6", code: 22)
        option { $0.text = .background }
        h.click(CGPoint(x: 460, y: 200))
        (h.window.firstResponder as? NSTextView)?.insertText("底色文字", replacementRange: NSRange(location: NSNotFound, length: 0))
        h.key("\u{1b}", code: 53)
        h.key("\u{1b}", code: 53)
        option { $0.text = .outline }
        h.click(CGPoint(x: 460, y: 330))
        (h.window.firstResponder as? NSTextView)?.insertText("描边文字", replacementRange: NSRange(location: NSNotFound, length: 0))
        h.key("\u{1b}", code: 53)

        let items = h.view.testing_items
        expect(items.count == 6, "six styled annotations (\(items.count))")
        expect(items[0].style.dash == .dashed && items[0].style.rounded, "rectangle is dashed and rounded")
        expect(items[1].style.arrowHead == .open && items[2].style.arrowHead == .double, "arrow heads are remembered per new arrow")
        expect(items[4].style.text == .background && items[5].style.text == .outline, "text decorations applied")
        expect(StyleMemory.style(for: .rectangle).dash == .dashed && StyleMemory.style(for: .text).text == .outline, "options are remembered per tool")

        h.key("\u{1b}", code: 53)
        h.key("\u{1b}", code: 53)
        h.key("2", code: 19)
        h.screenshot().map { write($0, "item-styles-bar.png") }
        guard let rep = h.export() else { return expect(false, "export") }
        write(rep, "item-styles.png")
        func out(_ x: CGFloat, _ y: CGFloat) -> NSColor { rep.color(atPoint: CGPoint(x: x - 20, y: y - 20))! }
        func red(_ c: NSColor) -> Bool { c.redComponent > 0.8 && c.greenComponent < 0.45 }
        let edge = (0..<60).map { out(100 + CGFloat($0), 60) }
        expect(edge.contains(where: red) && edge.contains(where: { !red($0) }), "dashed edge has both ink and gaps")
        expect(!red(out(61, 61)), "rounded rectangle leaves the sharp corner empty")
        expect(red(out(486, 120)), "double arrow has a head at the start too")
        // Inside the background pill, between glyphs.
        let text = items[4]
        expect(red(out(text.bounds.minX + 2, text.bounds.midY)), "text background is filled with the color")
    }

    /// 马赛克的「模糊程度」横条：真的改变结果、改的是选中那一条、两种模式下都在。
    @MainActor static func mosaicStrength() async {
        let mode = StyleMemory.mosaicMode
        let effect = StyleMemory.mosaicEffect
        let strength = StyleMemory.mosaicStrength
        defer {
            StyleMemory.mosaicMode = mode
            StyleMemory.mosaicEffect = effect
            StyleMemory.mosaicStrength = strength
        }
        // 出厂默认：框选 + 毛玻璃 + 0.7×。`--check all` 里只有这里会动这几个静态值，所以在动手之前读到的就是声明时的默认。
        expect(StyleMemory.mosaicMode == .rect, "默认是框选（\(StyleMemory.mosaicMode.rawValue)）")
        expect(StyleMemory.mosaicEffect == .blur, "默认是毛玻璃（\(StyleMemory.mosaicEffect.rawValue)）")
        expect(abs(StyleMemory.mosaicStrength - 0.7) < 0.001, "默认强度 0.7×（\(StyleMemory.mosaicStrength)）")

        StyleMemory.mosaicMode = .rect
        StyleMemory.mosaicEffect = .pixelate
        StyleMemory.mosaicStrength = 1

        func styleBar(_ h: CaptureHarness) -> StyleBarView {
            h.view.subviews.compactMap { $0 as? StyleBarView }.first!
        }

        let h = CaptureHarness(size: CGSize(width: 520, height: 400))
        h.select(CGRect(x: 20, y: 20, width: 480, height: 360))
        h.key("4", code: 21)
        let area = CGRect(x: 80, y: 90, width: 300, height: 200)
        h.drag(CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.maxY))
        // Exported pictures are in selection coordinates, so the area to sample moves with it.
        let inside = area.offsetBy(dx: -20, dy: -20)

        /// 颜色被量化到 1/64 再数：马赛克越大，一块里剩下的颜色越少。
        func distinctColors(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
            var seen = Set<Int>()
            for x in stride(from: rect.minX + 3, to: rect.maxX - 3, by: 3) {
                for y in stride(from: rect.minY + 3, to: rect.maxY - 3, by: 3) {
                    guard let c = rep.color(atPoint: CGPoint(x: x, y: y)) else { continue }
                    let r = Int(c.redComponent * 64), g = Int(c.greenComponent * 64), b = Int(c.blueComponent * 64)
                    seen.insert(r << 12 | g << 6 | b)
                }
            }
            return seen.count
        }

        /// 相邻像素的亮度差：毛玻璃越强，这个数越小。
        func localContrast(_ rep: NSBitmapImageRep, in rect: CGRect) -> Double {
            var total = 0.0
            var count = 0
            for x in stride(from: rect.minX + 3, to: rect.maxX - 8, by: 3) {
                for y in stride(from: rect.minY + 3, to: rect.maxY - 3, by: 3) {
                    guard let a = rep.color(atPoint: CGPoint(x: x, y: y)),
                          let b = rep.color(atPoint: CGPoint(x: x + 5, y: y)) else { continue }
                    total += abs(a.brightnessComponent - b.brightnessComponent)
                    count += 1
                }
            }
            return count == 0 ? 0 : total / Double(count)
        }

        guard let fine = h.export() else { return expect(false, "export") }
        let fineColors = distinctColors(fine, in: inside)
        write(fine, "mosaic-strength-1x.png")

        // 选中刚画的那块，拖横条——走滑块自己那条路（`sendAction`），不是直接调内部方法。
        guard let slider = styleBar(h).testing_mosaicSlider else { return expect(false, "马赛克工具条上有强度横条") }
        expect(slider.minValue == 0.2 && slider.maxValue == 2,
               "横条范围是 0.2–2 倍（\(slider.minValue)–\(slider.maxValue)）")

        // 粗的一头。
        slider.doubleValue = 2
        slider.sendAction(slider.action, to: slider.target)
        expect(h.view.testing_items.last?.mosaicStrength == 2, "拖横条改的是选中那条标注")
        expect(StyleMemory.mosaicStrength == 2, "也记住了，下一条新画的用这个强度")
        guard let coarse = h.export() else { return expect(false, "export") }
        let coarseColors = distinctColors(coarse, in: inside)
        write(coarse, "mosaic-strength-2x.png")
        expect(coarseColors < fineColors, "格子越大颜色越少（1× \(fineColors) 种 → 2× \(coarseColors) 种）")

        // 细的一头。这一端是重点：1× 本来就偏粗，滑到底必须**真的更细**，否则这条横条的下半截等于没有
        // （格子的 `max(8, …)` 地板原来就卡在这里，0.5× 和 1× 看起来差不多）。
        slider.doubleValue = 0.2
        slider.sendAction(slider.action, to: slider.target)
        guard let finest = h.export() else { return expect(false, "export") }
        let finestColors = distinctColors(finest, in: inside)
        write(finest, "mosaic-strength-0.2x.png")
        expect(finestColors > fineColors * 6 / 5,
               "滑到底确实更细（1× \(fineColors) 种 → 0.2× \(finestColors) 种）")

        // 毛玻璃换一张粗细条的高对比底图来量：这张底图上的细字被 9pt 的模糊一抹就平了，量不出强弱差别
        // （试过，两个强度都是 0.00x，断言能过但什么也没证明）。
        let striped = CaptureHarness(size: CGSize(width: 520, height: 400)) { _ in
            NSColor.white.setFill()
            CGRect(x: 0, y: 0, width: 520, height: 400).fill()
            NSColor.black.setFill()
            for x in stride(from: 30.0, to: 500, by: 44) { CGRect(x: x, y: 30, width: 22, height: 340).fill() }
        }
        StyleMemory.mosaicEffect = .blur
        StyleMemory.mosaicStrength = 1
        striped.select(CGRect(x: 20, y: 20, width: 480, height: 360))
        striped.key("4", code: 21)
        striped.drag(CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.maxY))
        guard let soft = striped.export() else { return expect(false, "export") }
        let softContrast = localContrast(soft, in: inside)
        expect(softContrast > 0.05, "毛玻璃 1× 还看得见条纹（\(String(format: "%.3f", softContrast))）")
        striped.view.testing_applyStyle(.mosaicStrength(0.2))
        guard let light = striped.export() else { return expect(false, "export") }
        let lightContrast = localContrast(light, in: inside)
        write(light, "mosaic-strength-blur-0.2x.png")
        expect(lightContrast > softContrast * 1.2,
               "毛玻璃滑到底明显更清楚（1× \(String(format: "%.3f", softContrast)) → 0.2× \(String(format: "%.3f", lightContrast))）")
        striped.view.testing_applyStyle(.mosaicStrength(2))
        guard let heavy = striped.export() else { return expect(false, "export") }
        let heavyContrast = localContrast(heavy, in: inside)
        write(heavy, "mosaic-strength-blur-2x.png")
        expect(heavyContrast < softContrast * 0.7,
               "毛玻璃越强条纹越平（1× \(String(format: "%.3f", softContrast)) → 2× \(String(format: "%.3f", heavyContrast))）")

        // 马赛克要铺满整个框：四条边的内侧不能留一圈没被处理的原图（报过："框选后四边方框线条内侧有
        // 未模糊的间隙，像是选框比模糊区域大"）。拿同一张条纹底图渲两遍——一遍什么都不画——逐像素比，
        // 紧贴框内 1pt 那一圈必须和没画马赛克时不一样。
        func stripedHarness() -> CaptureHarness {
            CaptureHarness(size: CGSize(width: 520, height: 400)) { _ in
                NSColor.white.setFill()
                CGRect(x: 0, y: 0, width: 520, height: 400).fill()
                NSColor.black.setFill()
                for x in stride(from: 30.0, to: 500, by: 44) { CGRect(x: x, y: 30, width: 22, height: 340).fill() }
            }
        }
        let plain = stripedHarness()
        plain.select(CGRect(x: 20, y: 20, width: 480, height: 360))
        let framed = stripedHarness()
        framed.select(CGRect(x: 20, y: 20, width: 480, height: 360))
        // 按出厂的那一套来试：框选 + 毛玻璃 + 0.7×。
        StyleMemory.mosaicMode = .rect
        StyleMemory.mosaicEffect = .blur
        StyleMemory.mosaicStrength = 0.7
        framed.key("4", code: 21)
        // 左边缘落在一条黑条的边上（条从 x=30 起、宽 22），这样紧贴内侧那一点原本是白的、外侧是黑的，
        // 抹开之后必然不一样；有缝隙的话它会保持纯白，这条断言就会挂。
        let box = CGRect(x: 52, y: 150, width: 200, height: 100)
        framed.drag(CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY))
        guard let withMosaic = framed.export(), let untouched = plain.export() else { return expect(false, "export") }
        write(withMosaic, "mosaic-frame-edge.png")

        /// 边框内侧 1pt 那一圈，和"没画马赛克"的同一位置比，有多少点不一样。
        func edgeCoverage(_ side: String) -> Double {
            var total = 0, changed = 0
            let inset: CGFloat = 1
            for t in stride(from: 6.0, to: (side == "left" || side == "right" ? box.height : box.width) - 6, by: 2) {
                let point: CGPoint
                switch side {
                case "left": point = CGPoint(x: box.minX + inset, y: box.minY + t)
                case "right": point = CGPoint(x: box.maxX - inset, y: box.minY + t)
                case "top": point = CGPoint(x: box.minX + t, y: box.minY + inset)
                default: point = CGPoint(x: box.minX + t, y: box.maxY - inset)
                }
                // 导出图是选区坐标，减掉选区原点，再按 2x 取样。
                let inSelection = CGPoint(x: point.x - 20, y: point.y - 20)
                guard let a = withMosaic.color(atPoint: inSelection), let b = untouched.color(atPoint: inSelection) else { continue }
                total += 1
                if abs(a.brightnessComponent - b.brightnessComponent) > 0.02 { changed += 1 }
            }
            return total == 0 ? 0 : Double(changed) / Double(total)
        }
        for side in ["left", "right", "top", "bottom"] {
            let coverage = edgeCoverage(side)
            expect(coverage > 0.8, "\(side) 内侧 1pt 那圈已经处理过了（\(Int(coverage * 100))%）")
        }
        // 选中状态下截一张：虚线框应该正好压在模糊区域的边上，两者之间不该再露出一圈原图。
        framed.screenshot().map { write($0, "mosaic-frame-selected.png") }

        // 两种模式下都留着这条横条：框选模式本来一个能调的东西都没有。画笔模式那条最宽（横条加上
        // 尺寸按钮），也顺带守住它别撑出屏幕。
        h.key("\u{1b}", code: 53)
        for mode in [MosaicMode.brush, .rect, .auto] {
            StyleMemory.mosaicMode = mode
            h.view.testing_applyStyle(.mosaicMode(mode))
            let bar = styleBar(h)
            expect(bar.testing_mosaicSlider != nil, "\(mosaicModeName(mode))模式下也能调强度")
            expect(h.view.bounds.contains(bar.frame), "工具条整条都在画面里（\(mosaicModeName(mode))：\(bar.frame)）")
        }
        // 新画的一块用的是记忆值，也就是默认那一套。
        StyleMemory.mosaicStrength = 0.7
        h.drag(CGPoint(x: 120, y: 300), CGPoint(x: 260, y: 380))
        expect(h.view.testing_items.last?.mosaicStrength == 0.7, "新画的按记忆值 0.7× 来")

        // 别的工具的工具条上没有它。
        h.key("1", code: 18)
        expect(styleBar(h).testing_mosaicSlider == nil, "换了工具，横条收起来")
        h.key("4", code: 21)
        h.screenshot().map { write($0, "mosaic-strength-bar.png") }
    }

    /// 马赛克的三个效果按钮有悬停说明（智能擦除尤其需要），和主工具条一样停一下才弹。
    @MainActor static func mosaicHints() async {
        let effectBefore = StyleMemory.mosaicEffect
        defer { StyleMemory.mosaicEffect = effectBefore }
        let h = CaptureHarness(size: CGSize(width: 900, height: 700))
        h.select(CGRect(x: 20, y: 20, width: 620, height: 400))
        h.key("4", code: 21)
        guard let bar = h.view.subviews.compactMap({ $0 as? StyleBarView }).first else { return expect(false, "style bar is up") }
        let toolbar = h.view.subviews.compactMap { $0 as? ToolbarView }.first
        expect(Tool.mosaic.title == "打码", "马赛克工具改名为「打码」（\(Tool.mosaic.title)）")
        expect(Tool.highlight.title == "聚光灯", "高亮工具改名为「聚光灯」（\(Tool.highlight.title)）")
        let buttons = bar.testing_effectButtons
        expect(buttons.count == 3, "打码有三个效果按钮（\(buttons.count)）")
        // 三个效果在最左边，画笔 / 框选排在它右边。
        func frame(_ view: NSView?) -> CGRect { view.map { $0.convert($0.bounds, to: bar) } ?? .null }
        let effectFrames = [MosaicEffect.pixelate, .blur, .erase].map { frame(bar.testing_effectButtons[$0]) }
        let modeFrames = [MosaicMode.brush, .rect, .auto].map { frame(bar.testing_modeButtons[$0]) }
        expect(effectFrames.allSatisfy { !$0.isNull } && modeFrames.allSatisfy { !$0.isNull }
               && effectFrames.map(\.maxX).max()! < modeFrames.map(\.minX).min()!,
               "像素块 / 模糊 / 智能擦除排在画笔、框选和自动识别左边")
        expect(toolbar?.testing_mosaicEffect == StyleMemory.mosaicEffect,
               "工具条上的打码图标对应选中的效果（\(String(describing: toolbar?.testing_mosaicEffect))）")
        // 画笔 / 框选 / 自动识别也走同一张卡，避免系统 tooltip 和卡片两种样子混在一起。
        expect(bar.testing_modeButtons.count == 3, "画笔、框选和自动识别各有说明")
        if let brush = bar.testing_modeButtons[.brush] {
            brush.onHover?(true)
            try? await Task.sleep(for: .milliseconds(400))
            expect(bar.testing_hint?.title == "画笔涂抹", "画笔模式也弹同样的说明卡（\(bar.testing_hint?.title ?? "nil")）")
            brush.onHover?(false)
            try? await Task.sleep(for: .milliseconds(500))
            expect(bar.hoverCard.isHidden, "画笔模式移开后卡片收起")
        }
        guard let pixelate = buttons[.pixelate], let blur = buttons[.blur], let erase = buttons[.erase] else {
            return expect(false, "三个效果按钮都在")
        }
        erase.onHover?(true)
        try? await Task.sleep(for: .milliseconds(120))
        expect(bar.hoverCard.isHidden, "悬停智能擦除时先不弹，和主工具条一样要停一下")
        try? await Task.sleep(for: .milliseconds(300))
        expect(bar.testing_hint?.title == "智能擦除", "停一下后弹出「智能擦除」的说明（\(bar.testing_hint?.title ?? "nil")）")
        expect(bar.testing_hint?.note.contains("补上") == true, "说明写清楚了它是把这块补上（\(bar.testing_hint?.note ?? "nil")）")
        write(h.screenshot() ?? sampleRep(), "mosaic-hints.png")

        // 卡片已经出来时，换到旁边的效果立即换成那一条。
        pixelate.onHover?(true)
        expect(bar.testing_hint?.title == "像素块", "换到像素块，卡片立即换成它的说明")
        expect(bar.testing_hint?.note.contains("马赛克") == true, "像素块的说明")
        blur.onHover?(true)
        expect(bar.testing_hint?.title == "模糊", "换到模糊，卡片立即换成它的说明")
        blur.onHover?(false)
        try? await Task.sleep(for: .milliseconds(500))
        expect(bar.hoverCard.isHidden, "移开后提示卡收起")

        // 换到别的工具，控制条重建，卡片也跟着收起。
        erase.onHover?(true)
        try? await Task.sleep(for: .milliseconds(600))
        expect(!bar.hoverCard.isHidden, "再悬停一次仍然会弹")

        // 选哪个效果，工具条上的打码图标就换成哪个。
        for effect in [MosaicEffect.pixelate, .blur, .erase] {
            bar.testing_effectButtons[effect]?.performClick(nil)
            expect(toolbar?.testing_mosaicEffect == effect,
                   "选 \(effect.rawValue) 后工具条图标跟着换（\(String(describing: toolbar?.testing_mosaicEffect))）")
        }

        h.key("1", code: 18)
        expect(bar.hoverCard.isHidden, "换成矩形工具后卡片收起")
    }

    /// 形状工具：默认矩形，切成圆形后工具条图标、样式条和画出来的东西都跟着变；圆形没有圆角，
    /// 其余（颜色、粗细、线型、Shift 正圆）和矩形一样。
    @MainActor static func shapeTool() async {
        let savedMode = StyleMemory.shapeMode
        defer { StyleMemory.shapeMode = savedMode }
        StyleMemory.shapeMode = .rect
        StyleMemory.setColor(StyleState.palette[0], for: .rectangle)
        StyleMemory.setStyle(ItemStyle(), for: .rectangle)
        StyleMemory.sizes[.rectangle] = 4

        let h = CaptureHarness(size: CGSize(width: 800, height: 500))
        h.select(CGRect(x: 60, y: 60, width: 600, height: 380))
        h.key("1", code: 18)
        guard let bar = h.view.subviews.compactMap({ $0 as? StyleBarView }).first else { return expect(false, "style bar") }
        let toolbar = h.view.subviews.compactMap { $0 as? ToolbarView }.first
        expect(toolbar?.testing_shapeMode == .rect,
               "工具条上的形状图标默认是矩形（\(toolbar?.testing_shapeMode.map(\.rawValue) ?? "nil")）")
        expect(bar.testing_shapeButtons.count == 2, "形状下面有矩形和圆形两个选项（\(bar.testing_shapeButtons.count)）")
        expect(bar.testing_roundedButton != nil, "矩形有圆角选项")
        // 子菜单的悬停提示只要标题，不要再加解释。
        bar.testing_shapeButtons[.rect]?.onHover?(true)
        try? await Task.sleep(for: .milliseconds(400))
        expect(bar.testing_hint?.title == "矩形" && bar.testing_hint?.note == "",
               "矩形 / 圆形的悬停提示只有标题（\(bar.testing_hint.map { "\($0)" } ?? "nil")）")
        expect(bar.hoverCard.frame.height < 45, "只有标题时卡片没有多出来的空白行（\(bar.hoverCard.frame.height)）")
        write(h.screenshot() ?? sampleRep(), "shape-hint.png")
        bar.testing_shapeButtons[.rect]?.onHover?(false)

        // 默认拖出来的是矩形。
        h.drag(CGPoint(x: 80, y: 80), CGPoint(x: 160, y: 130))
        guard case let .rectangle(first)? = h.view.testing_items.last?.shape else { return expect(false, "默认画的是矩形") }
        expect(abs(first.width - 80) < 1 && abs(first.height - 50) < 1, "矩形框选尺寸正确（\(first)）")

        // 点圆形：选中记忆、工具条图标、样式条三处一起换。
        h.key("\u{1b}", code: 53)
        bar.testing_shapeButtons[.ellipse]?.performClick(nil)
        expect(StyleMemory.shapeMode == .ellipse, "点圆形之后记住了圆形")
        expect(toolbar?.testing_shapeMode == .ellipse,
               "工具条上的形状图标换成圆形（\(toolbar?.testing_shapeMode.map(\.rawValue) ?? "nil")）")
        expect(bar.testing_roundedButton == nil, "圆形没有圆角选项")
        expect(bar.testing_shapeButtons[.ellipse]?.isActive == true, "圆形按钮是选中态")

        // 画一个椭圆：尺寸和颜色都按矩形工具那套来。
        h.drag(CGPoint(x: 300, y: 150), CGPoint(x: 420, y: 230))
        guard case let .ellipse(second)? = h.view.testing_items.last?.shape else { return expect(false, "选圆形后画出来的是椭圆") }
        expect(abs(second.width - 120) < 1 && abs(second.height - 80) < 1, "椭圆框选尺寸正确（\(second)）")
        expect(h.view.testing_items.last?.color == StyleMemory.color(for: .rectangle), "圆形和矩形用同一套颜色")

        // 按住 Shift 是正圆。
        h.drag(CGPoint(x: 450, y: 200), CGPoint(x: 530, y: 260), flags: .shift)
        guard case let .ellipse(third)? = h.view.testing_items.last?.shape else { return expect(false, "Shift 画的是圆") }
        expect(abs(third.width - third.height) < 0.5, "按住 Shift 是正圆（\(third)）")

        // 导出的图里确实是一条椭圆描边、中间不填充。导出按选区裁切，所以坐标要减去选区原点。
        if let rep = h.export(),
           let edge = rep.color(atPoint: CGPoint(x: 240, y: 130)),
           let center = rep.color(atPoint: CGPoint(x: 300, y: 130)) {
            expect(edge.redComponent > 0.8 && edge.greenComponent < 0.4, "导出的椭圆描边画出来了（\(edge)）")
            expect(center.redComponent > 0.8 && center.greenComponent > 0.8 && center.blueComponent > 0.8,
                   "椭圆里面没有填充（\(center)）")
        } else {
            expect(false, "导出椭圆取样")
        }
        h.screenshot().map { write($0, "shape-tool.png") }

        // 选中一个已经画好的圆，再点矩形：那条标注原地变回矩形，圆角选项也回来。
        bar.testing_shapeButtons[.rect]?.performClick(nil)
        guard case let .rectangle(converted)? = h.view.testing_items.last?.shape else {
            return expect(false, "选中的圆可以切回矩形")
        }
        expect(abs(converted.width - third.width) < 0.5 && abs(converted.height - third.height) < 0.5,
               "切换形状时外框不变（\(converted)）")
        expect(bar.testing_roundedButton != nil, "切回矩形后圆角选项回来了")
        expect(toolbar?.testing_shapeMode == .rect, "工具条图标也切回方形")
        expect(Tool.rectangle.title == "形状", "工具改名为「形状」")
    }

    /// 荧光笔：画笔下面的第二种笔迹。线条是胶囊形、粗细 1–50（默认 20）；矩形是直角块；颜色有预设，
    /// 也能自定义；工作方式有正片叠底和半透明两种。
    @MainActor static func highlighterTool() async {
        let saved = (StyleMemory.penMode, StyleMemory.highlighterMode, StyleMemory.highlighterBlend,
                     StyleMemory.highlighterWidth, StyleMemory.highlighterColor)
        defer {
            StyleMemory.penMode = saved.0
            StyleMemory.highlighterMode = saved.1
            StyleMemory.highlighterBlend = saved.2
            StyleMemory.highlighterWidth = saved.3
            StyleMemory.highlighterColor = saved.4
        }
        StyleMemory.penMode = .pencil
        StyleMemory.highlighterMode = .line
        StyleMemory.highlighterBlend = .multiply
        StyleMemory.highlighterWidth = 20
        StyleMemory.highlighterColor = StyleMemory.defaultHighlighterColor

        expect(HighlighterBlend.multiply.alpha > HighlighterBlend.translucent.alpha,
               "正片叠底比半透明更浓（\(HighlighterBlend.multiply.alpha) > \(HighlighterBlend.translucent.alpha)）")
        expect(inkCoverage(.highlighter) > 0.03, "荧光笔图标画出了内容（\(Int(inkCoverage(.highlighter) * 100))%）")

        let h = CaptureHarness(size: CGSize(width: 900, height: 600))
        h.select(CGRect(x: 60, y: 60, width: 760, height: 460))
        h.key("3", code: 20)
        guard let bar = h.view.subviews.compactMap({ $0 as? StyleBarView }).first else { return expect(false, "style bar") }
        let toolbar = h.view.subviews.compactMap { $0 as? ToolbarView }.first
        expect(bar.testing_penModeButtons.count == 2, "画笔下面有铅笔和荧光笔两个子工具（\(bar.testing_penModeButtons.count)）")
        expect(toolbar?.testing_penMode == .pencil, "默认还是铅笔")
        expect(bar.testing_highlighterModeButtons.isEmpty, "铅笔模式下没有荧光笔的子选项")

        bar.testing_penModeButtons[.highlighter]?.performClick(nil)
        expect(StyleMemory.penMode == .highlighter, "点荧光笔之后切过去")
        expect(toolbar?.testing_penMode == .highlighter, "工具条上的画笔图标换成荧光笔")
        expect(bar.testing_highlighterModeButtons.count == 2, "荧光笔有矩形和线条两种笔迹")
        expect(bar.testing_highlighterModeButtons[.line]?.isActive == true, "默认是线条")
        expect(bar.testing_highlighterSlider != nil && bar.testing_highlighterLabel == "20",
               "线条模式有 1–50 的粗细滑条，默认 20（\(bar.testing_highlighterLabel)）")
        expect(bar.testing_highlighterSlider?.minValue == 1 && bar.testing_highlighterSlider?.maxValue == 50,
               "滑条范围是 1–50")
        expect(bar.testing_highlighterBlendButtons.count == 2, "工作方式有正片叠底和半透明")
        expect(bar.testing_highlighterBlendButtons[.multiply]?.isActive == true, "默认正片叠底")
        expect(bar.testing_colorButtons.count == StyleMemory.highlighterPalette.count && bar.testing_customColorButton != nil,
               "荧光笔有自己的一组预设颜色和一个自定义颜色入口")
        expect(StyleMemory.highlighterPalette.first == StyleMemory.defaultHighlighterColor,
               "调色板第一格就是默认颜色")
        // 存过旧版偏橙黄色的，读出来要当成新的纯黄，不用让用户重新选一次。
        UserDefaults.standard.set(["r": 1.0, "g": 0.92, "b": 0.23], forKey: "style.highlighterColor")
        expect(StyleMemory.highlighterColor == StyleMemory.defaultHighlighterColor, "旧的偏橙黄色读成新的纯黄")
        StyleMemory.highlighterColor = StyleMemory.defaultHighlighterColor
        write(h.screenshot() ?? sampleRep(), "highlighter-bar.png")

        // 粗细：滑条的值写进记忆，贴到 1–50。
        h.view.testing_applyStyle(.highlighterWidth(40))
        expect(StyleMemory.highlighterWidth == 40 && bar.testing_highlighterLabel == "40",
               "拖到 40 之后记忆和数字都变（\(bar.testing_highlighterLabel)）")
        h.view.testing_applyStyle(.highlighterWidth(0))
        expect(StyleMemory.highlighterWidth == 1, "下限贴到 1")
        h.view.testing_applyStyle(.highlighterWidth(80))
        expect(StyleMemory.highlighterWidth == 50, "上限贴到 50")
        h.view.testing_applyStyle(.highlighterWidth(20))

        // 正片叠底的线条：横向拖一条，导出里应该是黄色、胶囊两端是圆的。
        h.drag(CGPoint(x: 160, y: 260), CGPoint(x: 420, y: 280))
        guard let line = h.view.testing_items.last, case let .highlighterLine(a, b) = line.shape else {
            return expect(false, "线条画出来的是 highlighterLine")
        }
        expect(abs(a.x - 160) < 1 && abs(b.x - 420) < 1, "线条端点就是拖拽的两头（\(a) → \(b)）")
        expect(line.size == 20 && line.highlighterBlend == .multiply, "线条用 20 宽、正片叠底")
        expect(line.color == StyleMemory.highlighterColor, "线条用荧光笔自己的颜色")
        if let debug = h.export() { write(debug, "highlighter-export.png") }
        let multiplyBlue = highlighterSample(h, at: CGPoint(x: 290, y: 270)).blueComponent
        // 端点外面 8pt 仍在圆头里，13pt 之外就回到白纸。
        let insideCap = highlighterSample(h, at: CGPoint(x: 428, y: 281))
        let outsideCap = highlighterSample(h, at: CGPoint(x: 433, y: 281))
        expect(insideCap.blueComponent < 0.9, "线条端点外 8pt 还有颜色（圆头）")
        expect(outsideCap.redComponent > 0.95 && outsideCap.greenComponent > 0.95 && outsideCap.blueComponent > 0.95,
               "再往外 13pt 就回到白底（说明是圆头而不是方头）")

        // 半透明更轻：换过工作方式再画一条，蓝通道比正片叠底高。
        bar.testing_highlighterBlendButtons[.translucent]?.performClick(nil)
        expect(StyleMemory.highlighterBlend == .translucent, "点半透明之后记住它")
        h.drag(CGPoint(x: 460, y: 270), CGPoint(x: 560, y: 290))
        guard let translucentLine = h.view.testing_items.last, case .highlighterLine = translucentLine.shape else {
            return expect(false, "第二条线也是 highlighterLine")
        }
        expect(translucentLine.highlighterBlend == .translucent, "第二条线用半透明")
        let translucentBlue = highlighterSample(h, at: CGPoint(x: 510, y: 280)).blueComponent
        expect(translucentBlue > multiplyBlue + 0.1,
               "半透明比正片叠底更轻（蓝通道 \(translucentBlue) > \(multiplyBlue)）")

        // 矩形模式：滑条收起，拖出来的是直角块。
        bar.testing_highlighterModeButtons[.rect]?.performClick(nil)
        expect(StyleMemory.highlighterMode == .rect && bar.testing_highlighterSlider == nil,
               "切成矩形后粗细滑条收起")
        h.drag(CGPoint(x: 100, y: 250), CGPoint(x: 150, y: 295))
        guard case let .highlighterRect(rect)? = h.view.testing_items.last?.shape else {
            return expect(false, "矩形模式画出来的是 highlighterRect")
        }
        expect(abs(rect.width - 50) < 1 && abs(rect.height - 45) < 1, "矩形范围正确（\(rect)）")
        expect(highlighterSample(h, at: CGPoint(x: 125, y: 272)).blueComponent < 0.9, "矩形里面盖上了荧光色")

        // 换一支预设颜色：记忆和选中的矩形一起变。
        bar.testing_colorButtons[2].1.performClick(nil)
        expect(StyleMemory.highlighterColor == StyleMemory.highlighterPalette[2], "点第三个色块之后记住它")
        expect(h.view.testing_items.last?.color == StyleMemory.highlighterPalette[2], "选中的矩形也跟着换色")
        let blue = highlighterSample(h, at: CGPoint(x: 125, y: 272))
        expect(blue.blueComponent > blue.redComponent, "导出里是换过之后的蓝色（\(blue)）")

        // 再切回线条：滑条回来，新线条按新的粗细。
        bar.testing_highlighterModeButtons[.line]?.performClick(nil)
        expect(bar.testing_highlighterSlider != nil, "切回线条后滑条回来")
        h.view.testing_applyStyle(.highlighterWidth(40))
        h.drag(CGPoint(x: 200, y: 200), CGPoint(x: 320, y: 200))
        expect(h.view.testing_items.last?.size == 40, "新线条用刚选的 40 宽（\(h.view.testing_items.last?.size ?? 0)）")

        // 切回铅笔：工具条图标和样式条都回到铅笔那一套。
        bar.testing_penModeButtons[.pencil]?.performClick(nil)
        expect(StyleMemory.penMode == .pencil && toolbar?.testing_penMode == .pencil, "切回铅笔后图标也回来")
        expect(bar.testing_highlighterModeButtons.isEmpty && bar.testing_highlighterSlider == nil,
               "铅笔模式下荧光笔的子选项收起")
        h.screenshot().map { write($0, "highlighter.png") }

        // 真正的正片叠底：黑底白字上，黑底保持黑，白字变成荧光色。
        StyleMemory.penMode = .highlighter
        StyleMemory.highlighterMode = .rect
        StyleMemory.highlighterBlend = .multiply
        StyleMemory.highlighterColor = StyleMemory.defaultHighlighterColor
        let bw = CaptureHarness(size: CGSize(width: 500, height: 300)) { _ in
            NSColor.black.setFill()
            CGRect(x: 0, y: 0, width: 500, height: 300).fill()
            NSColor.white.setFill()
            CGRect(x: 180, y: 100, width: 140, height: 60).fill()
        }
        bw.select(CGRect(x: 60, y: 60, width: 380, height: 180))
        bw.key("3", code: 20)
        bw.drag(CGPoint(x: 150, y: 80), CGPoint(x: 350, y: 180))
        guard case .highlighterRect? = bw.view.testing_items.last?.shape else {
            return expect(false, "黑白底上的荧光笔矩形")
        }
        let whiteUnderInk = highlighterSample(bw, at: CGPoint(x: 250, y: 130))
        let blackUnderInk = highlighterSample(bw, at: CGPoint(x: 160, y: 90))
        expect(whiteUnderInk.redComponent > 0.95 && whiteUnderInk.greenComponent > 0.85 && whiteUnderInk.blueComponent < 0.4,
               "正片叠底：白底部分变成荧光色（\(whiteUnderInk)）")
        expect(blackUnderInk.redComponent < 0.1 && blackUnderInk.greenComponent < 0.1 && blackUnderInk.blueComponent < 0.1,
               "正片叠底：黑底保持黑色（\(blackUnderInk)）")
        bw.screenshot().map { write($0, "highlighter-multiply.png") }
    }

    /// The exported picture's colour at a point given in the harness view's coordinates.
    @MainActor private static func highlighterSample(_ h: CaptureHarness, at p: CGPoint) -> NSColor {
        let selection = h.view.testing_selection ?? .zero
        let rep = h.export() ?? sampleRep()
        return rep.color(atPoint: CGPoint(x: p.x - selection.minX, y: p.y - selection.minY)) ?? .white
    }

    /// 删除标注：选中之后样式条最右端出现垃圾桶，点掉这一条；⌘Z 能撤回。没选中时那儿什么都没有。
    @MainActor static func deleteItem() async {
        let h = CaptureHarness()
        h.select(CGRect(x: 20, y: 20, width: 760, height: 460))
        func bar() -> StyleBarView? { h.view.subviews.compactMap { $0 as? StyleBarView }.first }

        // 选了工具但还没画：样式条上有颜色、没有垃圾桶。
        h.key("1", code: 18)
        expect(bar()?.testing_deleteButton == nil, "没选中标注时，样式条上没有垃圾桶")

        // 画一个矩形：画完它就是选中状态。
        h.drag(CGPoint(x: 60, y: 60), CGPoint(x: 260, y: 160))
        expect(h.view.testing_items.count == 1, "画了一个矩形")
        guard let barView = bar(), let trash = barView.testing_deleteButton else {
            return expect(false, "选中之后样式条上有垃圾桶")
        }
        // The bar was just rebuilt around the selection; lay it out before reading where the bin ended up.
        barView.layoutSubtreeIfNeeded()
        let stack = barView.subviews.compactMap { $0 as? NSStackView }.first
        let buttons = stack?.arrangedSubviews.compactMap { $0 as? ChromeButton } ?? []
        let trashFrame = trash.convert(trash.bounds, to: barView)
        let others = buttons.filter { $0 !== trash }.map { $0.convert($0.bounds, to: barView) }
        expect(others.allSatisfy { $0.maxX <= trashFrame.minX + 0.5 }, "垃圾桶在样式条最右端（\(trashFrame)）")
        expect(trashFrame.width >= 20, "垃圾桶的点击区域有按钮那么大（\(trashFrame)）")
        write(render(barView) ?? sampleRep(), "style-delete.png")

        // 点它：删掉，撤销能回来。
        trash.performClick(nil)
        expect(h.view.testing_items.isEmpty, "点垃圾桶删掉选中的标注")
        expect(h.view.testing_canUndo, "删除之后撤销是亮的")
        h.key("z", code: 6, flags: .command)
        expect(h.view.testing_items.count == 1, "⌘Z 把删掉的标注拿回来")

        // 取消选中之后桶就没了。
        h.key("\u{1b}", code: 53)
        expect(bar()?.testing_deleteButton == nil, "取消选中之后垃圾桶消失")
    }

    /// 扫码 is the second reading under 识别内容. The scanner itself, then the whole capture path: the two mode
    /// buttons, the panel beside the selection (and its step to the left), 复制 / 自动复制 / 钉住, and C.
    @MainActor static func scanCode() async {
        func qr(_ text: String) -> CIImage {
            let filter = CIFilter(name: "CIQRCodeGenerator")!
            filter.setValue(Data(text.utf8), forKey: "inputMessage")
            return filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        }
        let ci = CIContext()
        let first = "https://omnishot.example/app"
        let second = "WIFI:S:Office;P:12345678;;"
        func qrImage(_ text: String, side: CGFloat) -> NSImage {
            let image = ci.createCGImage(qr(text), from: qr(text).extent)!
            return NSImage(cgImage: image, size: NSSize(width: side, height: side))
        }

        // Two codes placed on a big light "screen", like a web page with a QR code on it.
        let size = CGSize(width: 1600, height: 1000)
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.draw(ci.createCGImage(qr(first), from: qr(first).extent)!, in: CGRect(x: 200, y: 300, width: 264, height: 264))
        ctx.draw(ci.createCGImage(qr(second), from: qr(second).extent)!, in: CGRect(x: 1000, y: 500, width: 296, height: 296))
        let screen = ctx.makeImage()!
        let codes = await CodeScanner.scan([screen, screen])
        expect(codes.count == 2 && codes.contains(first) && codes.contains(second),
               "finds both codes on the screen, without duplicates across screens (\(codes))")
        let blank = sampleRep(CGSize(width: 400, height: 300), color: .white).cgImage!
        let none = await CodeScanner.scan([blank])
        expect(none.isEmpty, "a screen without codes finds nothing")

        // MARK: the capture overlay

        func copiedCodes() -> [String] {
            (NSPasteboard.general.string(forType: .string) ?? "").split(separator: "\n").map(String.init).sorted()
        }

        let previousMode = StyleMemory.textReadingMode
        let previousAutoCopy = Settings.shared.scanAutoCopy
        defer {
            StyleMemory.textReadingMode = previousMode
            Settings.shared.scanAutoCopy = previousAutoCopy
            NSPasteboard.general.clearContents()
            for pin in PinManager.shared.pins { pin.closePin() }
        }
        StyleMemory.textReadingMode = .text
        expect(Settings.shared.scanAutoCopy, "扫码后自动复制默认是开的")
        Settings.shared.scanAutoCopy = false

        let h = CaptureHarness(size: CGSize(width: 1000, height: 700)) { _ in
            NSColor.white.setFill()
            CGRect(x: 0, y: 0, width: 1000, height: 700).fill()
            qrImage(first, side: 220).draw(in: CGRect(x: 80, y: 80, width: 220, height: 220))
            qrImage(second, side: 220).draw(in: CGRect(x: 420, y: 320, width: 220, height: 220))
        }
        h.select(CGRect(x: 40, y: 40, width: 600, height: 560))
        h.key("x", code: 7)
        guard let bar = h.view.subviews.compactMap({ $0 as? StyleBarView }).first else {
            return expect(false, "按 X 之后摆出样式条")
        }
        // The bar was just built; lay it out before reading where the buttons ended up.
        bar.layoutSubtreeIfNeeded()
        expect(!bar.isHidden, "识别内容也有自己的一排（\(bar.frame)）")
        expect(bar.testing_textReadingButtons.count == 2, "这一排是两个模式：识别文字 / 扫码")
        expect(inkCoverage(.qrCode) > 0.02, "扫码图标画得出内容（资源包里找得到 custom/scan-code）")
        if let textButton = bar.testing_textReadingButtons[.text],
           let scanButton = bar.testing_textReadingButtons[.scan] {
            let t = textButton.convert(textButton.bounds, to: bar)
            let s = scanButton.convert(scanButton.bounds, to: bar)
            expect(s.minX > t.maxX - 1 && abs(s.midY - t.midY) < 1, "扫码在识别文字右边、同一行")
            expect(textButton.isActive && !scanButton.isActive, "刚按 X 时亮的是识别文字")
            scanButton.onHover?(true)
            try? await Task.sleep(for: .milliseconds(320))
            expect(bar.testing_hint?.title == "扫码", "悬停有说明卡片（\(bar.testing_hint?.title ?? "nil")）")
            scanButton.onHover?(false)
        } else {
            expect(false, "两个模式按钮都在")
        }

        // Switching reading while OCR is still reading the QR-only picture must not be dropped: the scan runs
        // when the recognition hands the task over.
        bar.testing_textReadingButtons[.scan]?.performClick(nil)
        for _ in 0..<300 where h.view.testing_scanCodes == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let scanned = h.view.testing_scanCodes else { return expect(false, "扫码面板显示结果") }
        expect(scanned.count == 2 && scanned.contains(first) && scanned.contains(second),
               "面板里是两个码的原文（\(scanned)）")
        expect(h.view.testing_textReadingMode == .scan, "样式条切到了扫码")
        expect(bar.testing_textReadingButtons[.scan]?.isActive == true, "扫码按钮亮着")
        if let toolbar = h.view.subviews.compactMap({ $0 as? ToolbarView }).first {
            expect(toolbar.testing_textReadingMode == .scan, "工具条上的识别内容图标换成了扫码")
        } else {
            expect(false, "工具条还在")
        }
        if let frame = h.view.testing_scanPanelFrame, let selection = h.view.testing_selection {
            expect(frame.minX > selection.maxX, "右侧有地方时面板在选区右边（\(frame)）")
            expect(frame.minY >= 4 && frame.maxY <= h.size.height - 4, "面板留在画面里")
        } else {
            expect(false, "扫码面板有位置")
        }
        let panel = h.view.testing_scanPanel
        expect(panel.testing_rowCount == 2, "一个码一行（\(panel.testing_rowCount) 行）")
        let pinFrame = panel.testing_pinButton.convert(panel.testing_pinButton.bounds, to: panel)
        expect(pinFrame.minX > panel.frame.width - 40 && pinFrame.minY < 12,
               "钉住在右上角（\(pinFrame)），没有关闭按钮")
        h.screenshot().map { write($0, "scan-code.png") }

        // A row's buttons appear on hover. The URL row gets 访问; the Wi-Fi payload is not a link and does not.
        expect(!panel.testing_rowShowsActions(0), "不悬停时行上没有按钮")
        panel.testing_hoverRow(0, true)
        expect(panel.testing_rowShowsActions(0), "悬停后出现复制按钮")
        expect(panel.testing_rowHasVisit(0) && !panel.testing_rowHasVisit(1),
               "链接那一行有访问，Wi-Fi 那一行没有")
        h.screenshot().map { write($0, "scan-code-hover.png") }
        NSPasteboard.general.clearContents()
        panel.testing_pressCopyRow(0)
        expect(NSPasteboard.general.string(forType: .string) == first, "这一行的复制只复制这一个码")
        panel.testing_hoverRow(0, false)
        expect(!panel.testing_rowShowsActions(0), "移开后按钮收起")

        NSPasteboard.general.clearContents()
        panel.testing_pressVisitRow(0)
        expect(h.view.testing_openedScanURL?.absoluteString == first, "访问把这一行的链接交出去")
        expect(h.view.testing_scanCodes != nil, "访问不关面板")

        // 自动复制 is a setting now (设置 → 文字识别) and is on out of the box. The panel no longer carries the
        // switch: scan again after turning it on and the codes arrive without a press.
        Settings.shared.scanAutoCopy = true
        NSPasteboard.general.clearContents()
        bar.testing_textReadingButtons[.scan]?.performClick(nil)
        for _ in 0..<300 where NSPasteboard.general.string(forType: .string) == nil { try? await Task.sleep(for: .milliseconds(100)) }
        expect(copiedCodes() == [first, second].sorted(), "打开自动复制后扫码结果自己进剪贴板")

        // C copies everything and leaves the panel up — 钉住 is what ends it.
        NSPasteboard.general.clearContents()
        h.key("c", code: 8)
        expect(copiedCodes() == [first, second].sorted(), "C 复制全部码")
        expect(h.view.testing_scanCodes != nil, "C 不关扫码面板")
        h.key("\u{1b}", code: 53)
        expect(h.view.testing_scanCodes == nil, "Esc 关掉扫码面板")
        expect(h.view.testing_textReadingMode == nil, "识别内容这一排也收起来了")
        expect(h.view.testing_selection != nil, "选区还在")

        // No room on the right: the panel steps to the left of the selection.
        let narrow = CaptureHarness(size: CGSize(width: 700, height: 500)) { _ in
            NSColor.white.setFill()
            CGRect(x: 0, y: 0, width: 700, height: 500).fill()
            qrImage(first, side: 160).draw(in: CGRect(x: 400, y: 120, width: 160, height: 160))
        }
        narrow.select(CGRect(x: 380, y: 80, width: 280, height: 300))
        StyleMemory.textReadingMode = .scan
        narrow.key("x", code: 7)
        for _ in 0..<300 where narrow.view.testing_scanCodes == nil { try? await Task.sleep(for: .milliseconds(100)) }
        if let frame = narrow.view.testing_scanPanelFrame {
            expect(frame.maxX <= 380, "右侧放不下时面板落在选区左边（\(frame)）")
        } else {
            expect(false, "左边也摆出了扫码面板")
        }

        // 钉住 ends the capture and leaves the result behind. Under 自检 the window is not opened, so this only
        // records what would have been pinned.
        let narrowPanel = narrow.view.testing_scanPanel
        narrowPanel.testing_pinButton.testing_press()
        expect(narrow.view.testing_pinnedScanCodes == [first], "钉住把面板上的码交给贴住的结果")
        expect(narrow.view.testing_finished, "钉住之后这次截图结束")

        // The pinned window is the same view, not a second UI: title, rows and the pin now in the theme colour.
        let pinned = ScanResultPinWindow(codes: [first, second], frame: CGRect(x: -5000, y: -5000, width: 340, height: 100))
        expect(pinned.testing_panel.testing_codes == [first, second], "钉住的窗口里还是同一份扫码结果")
        expect(pinned.testing_panel.testing_rowCount == 2, "钉住的窗口里还是一行一个码")
        expect(!pinned.testing_panel.testing_pinButton.testing_isPinned, "钉住的窗口里图钉先躺着，等着立起来")
        pinned.playPinAppearance()
        expect(pinned.testing_panel.testing_pinButton.testing_isPinned, "钉住后图钉立起来")
        expect(pinned.testing_panel.testing_pinButton.testing_isAnimating, "立起来是动画（0.22 秒），不是换图")
        expect(pinned.frame.size == ScanPanelView.size(codeCount: 2), "钉住的窗口和面板一样大")
        write(render(pinned.testing_panel) ?? sampleRep(), "scan-pinned.png")
        pinned.close()
    }

    /// 贴图的编辑：只有铅笔这一条路（右键的「编辑」和空格都走它）。贴图全程留在屏幕上，右边那列按钮
    /// 一直在；工具条的 ✓ 复制图片并把工具条收起来，贴图留着。
    @MainActor static func pinAnnotate() async {
        let stage = CGRect(x: -4400, y: -4300, width: 600, height: 600)
        let pin = PinManager.shared.pin(sampleRep(CGSize(width: 200, height: 100), color: .white),
                                        frame: CGRect(x: -4000, y: -4000, width: 200, height: 100))
        pin.setZoom(1.5, anchor: CGPoint(x: -4000, y: -3900), flash: false)

        guard let first = CaptureSession.beginPinTools(pin, in: stage) else {
            return expect(false, "铅笔会话开起来")
        }
        let view = first.testing_views[0]
        let local = view.testing_selection ?? .zero
        expect(local.size == CGSize(width: 200, height: 100), "编辑时回到 100%（\(local)）")
        expect(pin.isVisible && pin.isEditing, "铅笔打开时贴图还在，并且处于编辑状态")
        expect(pin.testing_view.testing_buttonsVisible && pin.testing_view.testing_toolsButton.isActive,
               "贴图的四个按钮一直露着，铅笔变成蓝色激活态")
        expect(view.testing_toolbarVisible, "贴图编辑时工具条摆出来")
        expect(view.testing_toastFrame == nil, "贴图编辑不再往图片上方浮一句提示语")
        expect(!view.testing_toolbarShows(.ocr) && !view.testing_toolbarShows(.longCapture) && !view.testing_toolbarShows(.pin),
               "贴图编辑的工具条上没有识别内容、长截图、贴到屏幕上")
        expect(view.testing_toolbarShows(.tool(.rectangle)) && view.testing_toolbarShows(.undo) && view.testing_toolbarShows(.translate)
               && view.testing_toolbarShows(.save) && view.testing_toolbarShows(.done),
               "标注、撤销、翻译、保存、复制都还在")
        // 16 个按钮的条宽约 590pt，藏掉三个之后约 480pt —— 藏了却仍占位置的话，条会照旧那么长。
        expect(view.testing_toolbarWidth < 520, "藏起来的按钮没有继续占位置（宽 \(view.testing_toolbarWidth)）")
        write(render(pin.testing_view) ?? sampleRep(), "pin-pencil-active.png")
        write(render(view) ?? sampleRep(), "pin-pencil-stage.png")

        // 激活态和工具条上被按下的「翻译」同一套颜色：底色是主题色的一层薄纱，图标是主题色本身。
        // 换一支红色主题渲染一次，铅笔底板上的像素就该偏红。
        let savedTheme = Settings.shared.themeColor
        Settings.shared.themeColor = .systemRed
        let activeShot = render(pin.testing_view)
        Settings.shared.themeColor = savedTheme
        let pencil = pin.testing_view.testing_toolsButton.frame
        if let plate = activeShot?.color(atPoint: CGPoint(x: pencil.minX + 2, y: pencil.midY))?.usingColorSpace(.sRGB) {
            expect(plate.redComponent > plate.blueComponent + 0.05, "铅笔的激活底色跟着主题色走（\(plate)）")
        } else {
            expect(false, "渲染铅笔激活态取像素")
        }

        func pencilKey(_ view: CaptureView, _ chars: String, _ code: UInt16, flags: NSEvent.ModifierFlags = []) {
            view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!)
        }
        func pencilMouse(_ view: CaptureView, _ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        pencilKey(view, "x", 7)
        expect(view.testing_ocrText == nil, "按 X 也不会在贴图编辑里打开识别面板")

        // 一个工具都没选时，在图片里拖是移动这张贴图，不是重新框选。
        let pictureBeforeDrag = PinView.pictureFrame(in: pin.frame)
        let dragFrom = CGPoint(x: local.midX, y: local.midY)
        let dragTo = CGPoint(x: dragFrom.x + 30, y: dragFrom.y + 20)
        view.mouseDown(with: pencilMouse(view, .leftMouseDown, dragFrom))
        view.mouseDragged(with: pencilMouse(view, .leftMouseDragged, dragTo))
        view.mouseUp(with: pencilMouse(view, .leftMouseUp, dragTo))
        let pictureAfterDrag = PinView.pictureFrame(in: pin.frame)
        expect(abs(pictureAfterDrag.minX - pictureBeforeDrag.minX - 30) < 0.6
               && abs(pictureAfterDrag.minY - pictureBeforeDrag.minY + 20) < 0.6,
               "没选工具时拖动图片，移动的是贴图本身（\(pictureBeforeDrag.origin) → \(pictureAfterDrag.origin)）")
        expect(view.testing_selection == local && view.testing_items.isEmpty,
               "拖动没有重新框选，也没有落下标注")

        StyleMemory.setColor(StyleState.palette[0], for: .rectangle)
        StyleMemory.setStyle(ItemStyle(), for: .rectangle) // earlier checks may have left it dashed
        StyleMemory.sizes[.rectangle] = 4
        pencilKey(view, "1", 18)
        let from = CGPoint(x: local.minX + 20, y: local.minY + 20)
        let to = CGPoint(x: local.minX + 120, y: local.minY + 70)
        view.mouseDown(with: pencilMouse(view, .leftMouseDown, from))
        view.mouseDragged(with: pencilMouse(view, .leftMouseDragged, to))
        view.mouseUp(with: pencilMouse(view, .leftMouseUp, to))
        expect(view.testing_items.count == 1, "在舞台上画下一条标注（\(view.testing_items.count)）")

        // ✓：复制图片、收起工具条，贴图留着。以前这里连贴图一起关掉，用户就没东西可以再双击了。
        NSPasteboard.general.clearContents()
        pencilKey(view, "\r", 36)
        expect(first.isFinished && pin.isVisible && PinManager.shared.pins.contains { $0 === pin },
               "✓ 收起工具条，贴图留着")
        expect(!pin.isEditing && !pin.testing_view.testing_toolsButton.isActive, "铅笔恢复成普通样子")
        expect(NSPasteboard.general.data(forType: .png) != nil || NSPasteboard.general.data(forType: .tiff) != nil,
               "✓ 还是把图片复制到了剪贴板")
        expect(abs(pin.zoom - 1.5) < 0.001, "收起工具条后回到原来的缩放（\(pin.zoom)）")
        let baked = pin.rep.color(atPoint: CGPoint(x: 20, y: 45))
        expect((baked?.redComponent ?? 0) > 0.8 && (baked?.greenComponent ?? 1) < 0.4,
               "边框已经折进贴图（\(baked.map { "\($0)" } ?? "nil")）")

        // 再打开：上一轮的标注还在，撤销按得到；撤销之后贴图回到没有那条矩形的样子。
        guard let second = CaptureSession.beginPinTools(pin, in: stage) else {
            return expect(false, "铅笔再打开")
        }
        let view2 = second.testing_views[0]
        expect(view2.testing_items.count == 1, "再打开时上一轮的标注还在（\(view2.testing_items.count)）")
        expect(view2.testing_canUndo, "撤销按钮在再次打开时是亮的")
        pencilKey(view2, "z", 6, flags: .command)
        expect(view2.testing_items.isEmpty, "再打开后可以撤销上一轮画的东西")
        second.finishPinTools()
        expect(second.isFinished && pin.isVisible, "撤销之后贴图仍然留着")
        let undone = pin.rep.color(atPoint: CGPoint(x: 20, y: 45))
        expect((undone?.redComponent ?? 0) > 0.8 && abs((undone?.greenComponent ?? 1) - (undone?.redComponent ?? 0)) < 0.25,
               "撤销后的贴图回到原来的底色（\(undone.map { "\($0)" } ?? "nil")）")

        // 工具条的「退出截图」还是关掉贴图。
        guard let third = CaptureSession.beginPinTools(pin, in: stage) else {
            return expect(false, "cancel 用的铅笔会话")
        }
        third.cancel()
        expect(third.isFinished && !PinManager.shared.pins.contains { $0 === pin }, "退出截图关掉贴图")

        // 舞台的摆放规则：停在图片右边（按钮在那边）、盖住图片、不离开屏幕。
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let picture = CGRect(x: 400, y: 300, width: 200, height: 100)
        let stageFrame = CaptureSession.stageFrame(for: picture, visible: visible)
        expect(stageFrame.maxX <= picture.maxX + 1, "舞台停在图片右边缘，不挡右边那列按钮（\(stageFrame)）")
        expect(stageFrame.contains(picture), "舞台盖住图片")
        expect(stageFrame.minX >= visible.minX && stageFrame.maxX <= visible.maxX
               && stageFrame.minY >= visible.minY && stageFrame.maxY <= visible.maxY, "舞台不离开屏幕（\(stageFrame)）")
        PinManager.shared.closeAll()
    }

    @MainActor static func hotkeys() async {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        // An unusual combination so it is free: ⌃⌥⇧⌘ + F13.
        let shortcut = Shortcut(keyCode: 105, carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey), keyLabel: "F13")
        var fired = 0
        let ok = center.register(.scanCode, shortcut: shortcut) { fired += 1 }
        expect(ok && center.registeredCount == 1, "a shortcut registers with the system")
        center.testing_fire(HotKeyCenter.Action.scanCode.rawValue)
        expect(fired == 1, "it runs its action")
        center.register(.scanCode, shortcut: nil) { fired += 1 }
        expect(center.registeredCount == 0, "a cleared shortcut is released")
        center.unregisterAll()

        // Settings take effect as they change; there is no save button.
        let model = SettingsModel(loadSecrets: false)
        var notified = 0
        let token = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        model.imageFormat = .jpeg
        expect(Settings.shared.imageFormat == .jpeg, "changing the format saves it at once")
        model.imageFormat = .png
        model.targetLanguage = "English"
        expect(Settings.shared.targetLanguage == "English", "so does the target language")
        model.targetLanguage = "简体中文"
        model.scanCodeShortcut = shortcut
        expect(Settings.shared.scanCodeShortcut == shortcut && notified == 1, "a new global shortcut is saved and re-registered")
        model.scanCodeShortcut = nil
        center.unregisterAll()

        // The free engine is the default and needs no key; the LLM engine is one pick away.
        expect(model.engine == .free && Settings.shared.translationConfig.engine == .free, "translation starts on the free engine, without an API key")
        expect(!Settings.shared.translationConfig.clientKey.isEmpty && Settings.shared.clientKey == Settings.shared.clientKey, "the free engine gets a stable per-install client key")
        model.engine = .llm
        expect(Settings.shared.engine == .llm, "picking the LLM engine saves at once")
        for engine in TranslationEngine.allCases {
            model.engine = engine
            _ = renderPane(SettingsView(model: model, pane: .translate),
                           size: CGSize(width: 860, height: 600), name: "settings-translate-\(engine.rawValue).png")
        }
        // 大模型那份卡片很长，单独按它自己的高度渲一张，看图时不用滚。
        model.engine = .llm
        _ = renderPane(SettingsView(model: model, pane: .translate),
                       size: CGSize(width: 860, height: 900), name: "settings-translate-llm-full.png")
        model.engine = .free
    }

    /// The settings window: all seven pages render, and the permission page reports what the system says
    /// rather than a guess of its own.
    @MainActor static func settings() async {
        let model = SettingsModel(loadSecrets: false)
        let panes = SettingsPane.allCases
        expect(panes.count == 7, "the sidebar has seven pages: \(panes.map(\.title).joined(separator: "、"))")
        expect(Set(panes.map(\.icon)).count == panes.count, "each page has an icon of its own")
        // The page icons are not toolbar icons, so `tool-icons` does not cover them.
        for pane in panes {
            expect(inkCoverage(pane.icon) > 0.03, "「\(pane.title)」的图标画出了内容（\(Int(inkCoverage(pane.icon) * 100))%）")
        }
        expect(inkCoverage(.granted) > 0.03 && inkCoverage(.missing) > 0.03,
               "权限卡片的两个状态图标都画出了内容")
        // The rows and note boxes inside the pages, which `tool-icons` does not reach either.
        for asset in [Icon.Asset.pinRow, .pinUpright, .copyText, .clearText] {
            expect(inkCoverage(asset) > 0.02, "输入翻译里用的 \(asset.rawValue) 画出了内容（\(Int(inkCoverage(asset) * 100))%）")
        }

        for pane in panes {
            let image = renderPane(SettingsView(model: model, pane: pane),
                                   size: CGSize(width: 860, height: 600), name: "settings-\(pane.rawValue).png")
            expect(image.map(looksLikeAPage) == true, "「\(pane.title)」 renders a page")
        }

        // 菜单栏左键不是下拉菜单时，通用页会多一行灰色提示（右键还能打开菜单）；单独出一张图看排版。
        Settings.shared.menuBarClickAction = .ocr
        let withHint = renderPane(SettingsView(model: SettingsModel(loadSecrets: false), pane: .general),
                                  size: CGSize(width: 860, height: 600), name: "settings-general-menubar-click.png")
        expect(withHint.map(looksLikeAPage) == true, "「通用」在左键改走别的功能时仍然画得出来")
        Settings.shared.menuBarClickAction = .menu

        let center = PermissionCenter.shared
        center.refresh()
        expect(center.screenRecording == CaptureEngine.hasPermission, "屏幕录制 的状态和系统一致")
        expect(center.accessibility == AXIsProcessTrusted(), "辅助功能 的状态和系统一致")
        expect(center.needsRestartToApply == (center.screenRecording && !center.launchedWithScreenRecording),
               "刚授权的屏幕录制会提示重启应用")

        // The window must come back the size it should be. Assigning `contentViewController` used to leave it
        // 1×1 — a window nobody can see, which reads as「设置点了没反应」and is a pain to diagnose after the
        // fact. `install` is `present` minus showing the window, so this runs without putting anything up.
        let controller = SettingsWindowController.shared
        let size = controller.install(pane: .permissions)
        expect(size.width >= 700 && size.height >= 480,
               "窗口装上设置界面后仍有正常尺寸（\(Int(size.width))×\(Int(size.height))）")
        if let window = controller.window {
            let floor = controller.windowWillResize(window, to: NSSize(width: 100, height: 100))
            expect(floor.width >= 700 && floor.height >= 480,
                   "设置窗口不能拖到 700×480 以下（\(Int(floor.width))×\(Int(floor.height))）")
            expect(window.minSize.width >= 700 && window.minSize.height >= 480,
                   "设置窗口的最小尺寸已经固定")
        }
        expect(controller.capturableWindowNumbers == [],
               "没显示出来的设置窗口不会被算进截图")
        controller.window?.orderOut(nil)
    }

    @MainActor static func magnifierTool() async {
        StyleMemory.setColor(StyleState.palette[0], for: .magnifier)
        let h = CaptureHarness()
        h.select(CGRect(x: 40, y: 40, width: 700, height: 400))
        h.key("5", code: 23)
        let source = CGPoint(x: 110, y: 88)
        h.drag(source, CGPoint(x: 134, y: 88))
        guard case let .magnifier(s0, target, radius)? = h.view.testing_items.last?.shape else { return expect(false, "draws a magnifier") }
        expect(s0 == source && abs(radius - 24) < 0.5 && target.x > source.x + radius, "circle where dragged, lens beside it (\(target))")
        guard let rep = h.export() else { return expect(false, "export") }
        write(rep, "magnifier.png")
        // Every probe near the source (skipping the ring) must look the same inside the lens, at twice the offset.
        var matches = 0, total = 0
        for dx in stride(from: -14, through: 14, by: 2) {
            for dy in stride(from: -8, through: 8, by: 2) {
                let q = CGPoint(x: source.x + CGFloat(dx), y: source.y + CGFloat(dy))
                guard let original = h.original(q) else { continue }
                let lensPoint = CGPoint(x: target.x + CGFloat(dx) * 2 - 40, y: target.y + CGFloat(dy) * 2 - 40)
                guard let shown = rep.color(atPoint: lensPoint) else { continue }
                total += 1
                if abs(original.brightnessComponent - shown.brightnessComponent) < 0.2 { matches += 1 }
            }
        }
        // Anti-aliased glyph edges don't land on exactly doubled points, so allow some disagreement there.
        expect(total > 100 && Double(matches) / Double(total) > 0.8, "the lens shows the source area at 2× (\(matches)/\(total))")
        // Drag the lens elsewhere by its handle.
        h.drag(target, CGPoint(x: target.x + 60, y: target.y + 150))
        if case let .magnifier(_, moved, _)? = h.view.testing_items.last?.shape {
            expect(abs(moved.y - target.y - 150) < 0.5, "the lens can be moved on its own")
        }
        h.screenshot().map { write($0, "magnifier-overlay.png") }
    }

    @MainActor static func loupe() async {
        let h = CaptureHarness()
        h.view.mouseMoved(with: h.mouse(.mouseMoved, CGPoint(x: 70, y: 70)))
        expect(h.view.testing_magnifierVisible, "the loupe follows the pointer while choosing")
        expect(h.view.testing_magnifier.colorString == "#FFFFFF", "it samples the pixel under the pointer (\(h.view.testing_magnifier.colorString))")
        NSPasteboard.general.clearContents()
        h.key("c", code: 8)
        expect(NSPasteboard.general.string(forType: .string) == "#FFFFFF", "C copies the color")
        let shift = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
        h.view.flagsChanged(with: shift)
        expect(h.view.testing_magnifier.colorString == "255, 255, 255", "⇧ switches to RGB")
        let release = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                       characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
        h.view.flagsChanged(with: release)
        h.view.flagsChanged(with: shift)
        h.view.flagsChanged(with: release)
        expect(h.view.testing_magnifier.colorString == "#FFFFFF", "and back to HEX")
    }

    @MainActor static func pinTranslate() async {
        let engine = Settings.shared.engine
        defer { Settings.shared.engine = engine }
        Settings.shared.engine = .free
        let h = CaptureHarness(lines: ["Settings", "Automatically check for updates", "Save screenshots to Pictures"])
        h.select(CGRect(x: 60, y: 60, width: 420, height: 110))
        guard let rep = h.export() else { return expect(false, "export") }
        let pin = PinManager.shared.pin(rep, frame: CGRect(origin: CGPoint(x: -4000, y: -4000), size: rep.size))
        var sent: [String] = []
        pin.translate = { rep in
            try await ImageTranslator.translate(rep) { items in
                sent = items.map(\.text)
                return Dictionary(uniqueKeysWithValues: items.map { ($0.id, "译文\($0.id)：检查更新") })
            }
        }
        let original = pin.rep
        if Settings.shared.apiKey.isEmpty {
            Settings.shared.engine = .llm
            key(pin, "y", code: 16)
            expect(sent.isEmpty && !pin.showsTranslation, "the LLM engine still requires an API key")
            Settings.shared.engine = .free
        }
        key(pin, "y", code: 16)
        for _ in 0..<400 where !pin.showsTranslation { try? await Task.sleep(for: .milliseconds(100)) }
        expect(pin.showsTranslation && pin.rep !== original, "Y translates the pin in place")
        expect(sent.contains { $0.contains("Automatically check for updates") }, "the pin's text was sent for translation (\(sent))")
        // 贴图窗口比图片大一圈（左边和下边留边框和外发光，右边和上边留给按钮），比的是图片本身。
        let margin = PinView.borderInset + PinView.buttonInset
        expect(pin.rep.size == original.size
               && pin.frame.size == CGSize(width: original.size.width + margin, height: original.size.height + margin),
               "the translated pin keeps its size")
        write(pin.rep, "pin-translated.png")
        key(pin, "y", code: 16)
        expect(!pin.showsTranslation && pin.rep === original, "Y again shows the original")
        key(pin, "y", code: 16)
        expect(pin.showsTranslation, "and back to the translation without translating again")
        PinManager.shared.closeAll()
    }

    /// 截图翻译：按下快捷键截图，选区一放下就自己翻译，不用再按翻译按钮。
    @MainActor static func translateCapture() async {
        let engine = Settings.shared.engine
        defer { Settings.shared.engine = engine }
        Settings.shared.engine = .free

        // 设置里的这一个快捷键：能注册、能清除、能改回来。
        let center = HotKeyCenter.shared
        center.unregisterAll()
        let combo = Shortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(optionKey | shiftKey), keyLabel: "A")
        expect(Settings.shared.translateCaptureShortcut == combo, "截图翻译默认是 ⌥⇧A")
        var fired = 0
        center.register(.translateCapture, shortcut: combo) { fired += 1 }
        center.testing_fire(HotKeyCenter.Action.translateCapture.rawValue)
        expect(fired == 1, "这个组合键触发截图翻译")
        center.unregisterAll()
        let model = SettingsModel(loadSecrets: false)
        model.translateCaptureShortcut = nil
        expect(Settings.shared.translateCaptureShortcut == nil, "可以在设置里清除这个快捷键")
        model.translateCaptureShortcut = combo
        expect(Settings.shared.translateCaptureShortcut == combo, "也可以改成别的组合键")

        // 选区一放下就翻译。
        let h = CaptureHarness(lines: ["Settings", "Automatically check for updates", "Save screenshots to Pictures"])
        h.view.autoTranslate = true
        var sent: [[String]] = []
        h.view.translate = { items, _ in
            sent.append(items.map(\.text))
            return Dictionary(uniqueKeysWithValues: items.map { ($0.id, "译文 \($0.id)") })
        }
        let rect = CGRect(x: 60, y: 60, width: 420, height: 110)
        h.select(rect)
        expect(h.view.testing_translating, "放下选区就开始翻译，没按翻译按钮")
        for _ in 0..<600 where h.view.testing_translation.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        guard let first = h.view.testing_translation.first else { return expect(false, "译文画回选区原位") }
        expect(first.rect.intersects(rect), "译文画在选区里（\(first.rect)）")
        expect(sent.first?.contains { $0.contains("Automatically check for updates") } == true, "翻译的是选区里的文字")
        h.screenshot().map { write($0, "translate-capture.png") }

        // 挪动选区后自动重翻一次，译文跟着新位置。
        h.drag(CGPoint(x: 200, y: 100), CGPoint(x: 220, y: 160))
        expect(h.view.testing_translating, "挪完选区又自己翻了一次")
        for _ in 0..<600 {
            if let moved = h.view.testing_translation.first, moved.rect != first.rect { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        expect(h.view.testing_translation.first.map { $0.rect != first.rect } == true, "译文画到了挪动后的位置")

        // 普通截图还是老样子：按 Y 才翻译。
        let plain = CaptureHarness(lines: ["Settings", "Automatically check for updates"])
        plain.view.translate = { items, _ in Dictionary(uniqueKeysWithValues: items.map { ($0.id, "译文") }) }
        plain.select(rect)
        expect(!plain.view.testing_translating, "普通截图不会自己翻译")
        expect(plain.view.testing_toolbarVisible, "普通截图还是有底部的工具条")
        // The chip still belongs to a plain capture — that one is about measuring a region before you take it.
        let chip = plain.view.testing_sizeChipFrame
        expect(chip != nil && !(chip!.intersects(rect)),
               "普通截图仍然有尺寸框，而且在选区外面（\(chip.map { "\($0)" } ?? "没有")）")
        plain.key("y", code: 16)
        expect(plain.view.testing_translating, "按 Y 才开始翻译")
        expect(plain.view.testing_toastFrame != nil, "手动翻译时提示语还在")
    }

    /// The translation bar, the direction it guesses, and where the app's messages go. The messages used to
    /// be drawn inside the selection, over the very translation the user was trying to read.
    @MainActor static func translationBar() async {
        let rect = CGRect(x: 60, y: 60, width: 420, height: 110)

        // 英文屏幕：译成设置里的目标语言。
        var targets: [String] = []
        let en = CaptureHarness(lines: ["Settings", "Automatically check for updates", "Save screenshots to Pictures"])
        en.view.autoTranslate = true
        en.view.translate = { items, config in
            targets.append(config.targetLanguage)
            return Dictionary(uniqueKeysWithValues: items.map { ($0.id, "译文") })
        }
        en.select(rect)
        // 截图翻译不摆工具条，也不在翻译过程中报进度：选区上的微光和屏幕上的译文就是反馈。
        expect(!en.view.testing_toolbarVisible, "截图翻译不显示底部的工具条")
        expect(en.view.testing_sizeChipFrame == nil, "截图翻译不显示左上角那个尺寸框")
        expect(en.view.testing_toastFrame == nil, "翻译过程中不弹提示语")
        for _ in 0..<600 where en.view.testing_translation.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        expect(en.view.testing_toastFrame == nil, "翻译完了也不弹「已翻译」")

        guard let bar = en.view.testing_translationBar, let barFrame = en.view.testing_translationBarFrame else {
            return expect(false, "截图翻译模式下选区上方出现翻译悬浮条")
        }
        expect(bar.source == "英文" && bar.target == Settings.shared.targetLanguage,
               "英文屏幕上悬浮条是「\(bar.source) → \(bar.target)」")
        expect(bar.action == "显示原文", "按钮先写着「显示原文」")
        // A missing SVG makes an icon quietly draw nothing, which is how the swap arrow shipped invisible once.
        expect(inkCoverage(.swap) > 0.02, "对调方向用的图标画出了内容（\(Int(inkCoverage(.swap) * 100))%）")
        expect(targets.last == Settings.shared.targetLanguage, "翻成的是设置里的目标语言")
        expect(!barFrame.intersects(rect), "悬浮条在选区外面（\(barFrame)）")

        // 提示语落在选区外面 —— 原来它在选区左上角，正好压着译文。
        en.view.testing_showToast("测试用的提示语")
        guard let toast = en.view.testing_toastFrame else { return expect(false, "提示语有位置") }
        expect(!toast.intersects(rect), "提示语不在选区里（\(toast)）")
        // Above the bar when there is room for it there, otherwise under the selection with the toolbar —
        // which is what this short harness screen forces. What matters is that it is not over the picture.
        expect(!toast.intersects(barFrame), "提示语也不压着悬浮条（\(toast)）")

        // 中文占多数的屏幕：自己反过来，把中文送出去翻成英文，英文那行不动。
        var sent: [[String]] = []
        let mixed = CaptureHarness(lines: ["自动检查更新和下载", "保存截图到图片文件夹里", "Open settings"])
        mixed.view.autoTranslate = true
        mixed.view.translate = { items, config in
            sent.append(items.map(\.text))
            targets.append(config.targetLanguage)
            return Dictionary(uniqueKeysWithValues: items.map { ($0.id, "translation") })
        }
        mixed.select(rect)
        for _ in 0..<600 where mixed.view.testing_translation.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        expect(mixed.view.testing_translationBar.map { $0.source == "中文" && $0.target == "English" } == true,
               "中文屏幕上自动变成「中文 → English」（\(mixed.view.testing_translationBar?.source ?? "-")）")
        expect(sent.first?.contains { $0.contains("自动检查更新和下载") } == true, "送出去翻的是中文那几行")
        expect(sent.first?.contains { $0.contains("Open settings") } != true, "英文那行没被送去翻")
        mixed.screenshot().map { write($0, "translation-bar.png") }

        // 日文屏幕：方向条认得出日文（`ScreenLanguageTests` 也单独测了），送出去的筛子就必须跟着认——早先
        // 日文和韩文落在「要两个拉丁字母」那条分支上，一屏假名一个块都过不去，用户看到的是「没有找到需要
        // 翻译的外文」，方向条却写着「日文 → 简体中文」。
        var japanese: [[String]] = []
        let ja = CaptureHarness(lines: ["設定を開く", "アップデートを確認します", "Open settings"])
        ja.view.autoTranslate = true
        ja.view.translate = { items, _ in
            japanese.append(items.map(\.text))
            return Dictionary(uniqueKeysWithValues: items.map { ($0.id, "翻訳") })
        }
        ja.select(rect)
        for _ in 0..<600 where ja.view.testing_translation.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        expect(ja.view.testing_translationBar.map { $0.source == "日文" } == true,
               "日文屏幕上悬浮条写着「日文 → …」（\(ja.view.testing_translationBar?.source ?? "-")）")
        expect(!ja.view.testing_translation.isEmpty, "日文屏幕上有东西被翻出来（送出 \(japanese.count) 批）")
        expect(japanese.first?.contains { $0.contains("設定") } == true, "送出去的是日文那几行")
        expect(japanese.first?.contains { $0.contains("Open settings") } != true, "日文屏幕上的英文行不送")
        ja.screenshot().map { write($0, "translation-bar-japanese.png") }

        // 点中间那个箭头：方向对调，并且按新方向重翻一次。
        let before = targets.count
        mixed.view.testing_swapDirection()
        for _ in 0..<600 where targets.count == before { try? await Task.sleep(for: .milliseconds(100)) }
        expect(mixed.view.testing_translationBar.map { $0.source == "英文" && $0.target == Settings.shared.targetLanguage } == true,
               "点完箭头变成「英文 → \(Settings.shared.targetLanguage)」（\(mixed.view.testing_translationBar?.source ?? "-")）")
        expect(sent.last?.contains { $0.contains("Open settings") } == true, "这次送出去的是英文那行")
        expect(sent.last?.contains { $0.contains("自动检查更新和下载") } != true, "中文那几行不再送出去")
        expect(mixed.view.testing_translationBar?.hasFullText == false, "没有被截断的段落，悬浮条上就没有「全文」")

        // 小选区放不下长译文：截断的那部分进面板，不丢。
        let long = String(repeating: "This is a far longer translation than the little box can hold. ", count: 3)
        let small = CaptureHarness(lines: ["自动检查更新"])
        small.view.autoTranslate = true
        small.view.translate = { items, _ in Dictionary(uniqueKeysWithValues: items.map { ($0.id, long) }) }
        // The harness draws its first line at y 80, so this box is tight around it but still small enough
        // that a long translation cannot possibly fit.
        let tiny = CGRect(x: 70, y: 72, width: 120, height: 26)
        small.select(tiny)
        for _ in 0..<600 where small.view.testing_translation.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        guard let trimmed = small.view.testing_translation.first else { return expect(false, "小选区里也翻出来了") }
        expect(trimmed.text != trimmed.fullText, "放不下的译文在画面上被截短了")
        expect(small.view.testing_translationBar?.hasFullText == true, "悬浮条上出现了「全文」")
        expect(small.view.testing_translationPanelFrame == nil, "面板不自己弹出来，要点了才开")

        small.view.testing_showFullText()
        guard let panel = small.view.testing_translationPanelFrame else { return expect(false, "点「全文」打开了面板") }
        expect(!panel.intersects(tiny), "面板在选区外面（\(panel)）")
        expect(small.view.testing_translationPanelText?.contains(long.trimmingCharacters(in: .whitespaces)) == true,
               "面板里给的是完整译文")
        small.screenshot().map { write($0, "translation-full-text.png") }
    }

    /// The bar's engine chip, the list it opens, and 重新翻译. 截图翻译 has no toolbar, so before this the only way
    /// out of a translation that timed out was to nudge the selection and let it start over — the message it
    /// showed pointed at a 翻译按钮 that is not on screen in that mode.
    @MainActor static func translationEngine() async {
        let engine = Settings.shared.engine
        let storedConfigs = Settings.shared.llmConfigs
        let storedSelection = Settings.shared.selectedLLMConfigID
        defer {
            Settings.shared.engine = engine
            Settings.shared.llmConfigs = storedConfigs
            Settings.shared.selectedLLMConfigID = storedSelection
        }
        Settings.shared.engine = .free
        let longName = "公司内部 DeepSeek 网关（华东二区）"
        Settings.shared.llmConfigs = [LLMConfig(id: "one", name: "DeepSeek", model: "deepseek-chat"),
                                      LLMConfig(id: "two", name: longName, model: "gateway-model")]
        Settings.shared.selectedLLMConfigID = "one"
        // An unpackaged run reads the key from the environment only, so whether picking a 大模型 can actually
        // translate depends on the machine this check is running on.
        let hasKey = !Settings.shared.apiKey.isEmpty

        let rect = CGRect(x: 60, y: 60, width: 420, height: 110)
        // 这一页的文字是这条检查专用的：下面要数「到底发了几次请求」，而缓存是按文字算的，撞上别的检查
        // 用过的那几句就永远命中了。
        let h = CaptureHarness(lines: ["Zebra configuration panel", "Automatically check for updates"])
        h.view.autoTranslate = true
        /// 每一次真正发出去的请求。注入的 closure 自己走 `TranslationService.cache`，和正式那条路一样 ——
        /// 绕开缓存直接返回的话，「按「重新翻译」会不会被缓存顶回去」这件事在这里根本测不到。
        var sent: [(engine: TranslationEngine, model: String, id: String, target: String, texts: [String])] = []
        h.view.translate = { items, config in
            try await TranslationService.cache.translate(items, config: config) { fresh in
                sent.append((config.engine, config.model, config.configID, config.targetLanguage, fresh.map(\.text)))
                return Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, "译文") })
            }
        }
        h.select(rect)

        expect(h.view.testing_barEngine?.all == ["免费翻译", "DeepSeek", longName],
               "悬浮条上是「免费翻译」加每一份大模型（\(h.view.testing_barEngine?.all ?? [])）")
        expect(h.view.testing_barEngine?.shown == "免费翻译", "条上写的是当前在用的那份（\(h.view.testing_barEngine?.shown ?? "-")）")
        expect(h.view.testing_barEngine?.retry == "正在翻译中…" && h.view.testing_barRetryEnabled == false,
               "翻译中按钮写着「正在翻译中…」，而且不给按（再按只会把这次丢掉重来）")

        for _ in 0..<600 where h.view.testing_translation.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        expect(!h.view.testing_translation.isEmpty, "免费翻译先翻出来了一版")
        expect(h.view.testing_barEngine?.retry == "重新翻译" && h.view.testing_barRetryEnabled == true,
               "翻完之后按钮回到「重新翻译」，可以按了")
        let firstTexts = sent.first?.texts ?? []
        expect(sent.count == 1 && !firstTexts.isEmpty, "第一次翻译发出去了（\(sent.count) 次）")
        // 翻过的文字确实躺在缓存里 —— 下面那条「又发了一次」才有意义：同样的文字、同样的配置，不发请求
        // 就该从缓存里拿回来。
        var firstConfig = Settings.shared.translationConfig
        firstConfig.targetLanguage = sent.first?.target ?? firstConfig.targetLanguage
        expect(firstTexts.allSatisfy { TranslationService.cache.get($0, config: firstConfig) != nil },
               "翻过的文字进了缓存")

        // 点「重新翻译」：同样的文字、同样的引擎，但这次真的要再发一次 —— 缓存里那条必须让开，否则屏幕上
        // 原样重画一遍，看着就是一个按了没反应的按钮。这就是超时之后的重试。
        guard let retryFrame = h.view.testing_barRetryFrame else { return expect(false, "「重新翻译」在条上有位置") }
        // 真的用鼠标点：先过命中测试，落到按钮身上才轮到 handler。直接调 handler 会把「按钮点不到」这类
        // 问题全绕过去。
        let hit = h.view.testing_hitTest(CGPoint(x: retryFrame.midX, y: retryFrame.midY))
        expect(hit is ChromeTextButton, "「重新翻译」那段文字点得到（命中的是 \(String(describing: hit.map { type(of: $0) }))）")
        h.view.testing_pressBarRetry()
        for _ in 0..<600 where sent.count == 1 { try? await Task.sleep(for: .milliseconds(100)) }
        expect(sent.count == 2 && sent.last?.texts == firstTexts && sent.last?.engine == .free
               && sent.last?.target == sent.first?.target,
               "点「重新翻译」用同一个引擎把同一段文字又发了一次（\(sent.count) 次）")
        for _ in 0..<600 where h.view.testing_translation.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        expect(!h.view.testing_translation.isEmpty, "重试的译文也画了出来")

        // 引擎名点开是列表：画在覆盖层里面的一张面板，不是 NSMenu（NSMenu 是 AppKit 自己的窗口，层号 101，
        // 会被层 1000 的覆盖层整个盖住 —— 菜单真的弹出来了，用户什么都没看见，报的就是「点不动」）。
        guard let chipFrame = h.view.testing_barEngineFrame else { return expect(false, "引擎名在条上有位置") }
        let chipHit = h.view.testing_hitTest(CGPoint(x: chipFrame.midX, y: chipFrame.midY))
        expect(chipHit is ChromeTextButton, "引擎名点得到（命中的是 \(String(describing: chipHit.map { type(of: $0) }))）")
        expect(h.view.testing_engineMenu == nil, "没点之前列表是收着的")
        h.view.testing_openEngineMenu()
        guard let menu = h.view.testing_engineMenu else { return expect(false, "点一下引擎名就打开了列表") }
        expect(menu.titles == ["免费翻译", "DeepSeek", longName], "列表里是每一份引擎（\(menu.titles)）")
        expect(menu.current == 0, "当前那份是打勾的那一行")
        expect(abs(menu.frame.minX - chipFrame.minX) < 1 && menu.frame.minY >= chipFrame.maxY,
               "列表对齐着引擎名挂在下面（chip \(chipFrame)，list \(menu.frame)）")
        expect(CGRect(origin: .zero, size: h.size).contains(menu.frame), "列表整个在屏幕里（\(menu.frame)）")
        let rowPoint = CGPoint(x: menu.frame.midX, y: menu.frame.minY + 5 + EngineMenuView.rowHeight * 1.5)
        let rowHit = h.view.testing_hitTest(rowPoint)
        expect(rowHit is EngineMenuView, "列表的每一行点得到（命中的是 \(String(describing: rowHit.map { type(of: $0) }))）")
        h.view.testing_hoverEngineRow(1)
        h.screenshot().map { write($0, "translation-engine-menu.png") }

        // 换成第二份大模型：写进设置（以后所有翻译都用它），并且立刻用它重翻一遍。
        let beforeSwitch = sent.count
        h.view.testing_pickBarEngine(2)
        expect(h.view.testing_engineMenu == nil, "选完列表就收起来了")
        expect(Settings.shared.engine == .llm && Settings.shared.selectedLLMConfigID == "two",
               "在悬浮条上选的模型就是设置里的默认模型")
        let shown = h.view.testing_barEngine?.shown ?? "-"
        expect(shown.hasSuffix("…") && shown.count < longName.count, "名字太长时条上截短显示（\(shown)）")
        expect(h.view.testing_barMenu?.titles.last == longName, "列表里仍然是全名")
        expect(h.view.testing_barMenu?.checked == 2, "打勾的是换成的那一份")
        if hasKey {
            for _ in 0..<600 where sent.count == beforeSwitch { try? await Task.sleep(for: .milliseconds(100)) }
            expect(sent.count == beforeSwitch + 1 && sent.last?.model == "gateway-model" && sent.last?.id == "two",
                   "换成哪一份就用哪一份发请求（\(sent.last.map { "\($0)" } ?? "没有"))")
        } else {
            try? await Task.sleep(for: .milliseconds(300))
            expect(sent.count == beforeSwitch, "没填 API Key 时不会去发请求")
            expect(h.view.testing_toastFrame != nil, "而是要用户去填 Key")
        }

        // 换回免费翻译。
        h.view.testing_openEngineMenu()
        h.view.testing_pickBarEngine(0)
        expect(Settings.shared.engine == .free, "也可以换回免费翻译")
        expect(h.view.testing_barMenu?.checked == 0 && h.view.testing_barEngine?.shown == "免费翻译",
               "条上和列表里都跟着回到免费翻译")
        h.screenshot().map { write($0, "translation-bar-engine.png") }
    }

    /// 输入翻译：一个独立窗口，翻译剪贴板里或手动输入的文字。
    @MainActor static func textTranslate() async {
        let engine = Settings.shared.engine
        let storedConfigs = Settings.shared.llmConfigs
        let storedSelection = Settings.shared.selectedLLMConfigID
        defer {
            Settings.shared.engine = engine
            Settings.shared.llmConfigs = storedConfigs
            Settings.shared.selectedLLMConfigID = storedSelection
        }
        Settings.shared.engine = .free
        // Two named entries, so the engine popup has something to list and to tell apart.
        Settings.shared.llmConfigs = [LLMConfig(id: "one", name: "DeepSeek"),
                                      LLMConfig(id: "two", name: "公司网关")]
        Settings.shared.selectedLLMConfigID = "one"

        // 设置里的快捷键：能注册、能清除、能改回来。
        let center = HotKeyCenter.shared
        center.unregisterAll()
        let combo = Shortcut(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(optionKey | shiftKey), keyLabel: "T")
        expect(Settings.shared.textTranslateShortcut == combo, "输入翻译默认是 ⌥⇧T")
        var fired = 0
        center.register(.textTranslate, shortcut: combo) { fired += 1 }
        center.testing_fire(HotKeyCenter.Action.textTranslate.rawValue)
        expect(fired == 1, "这个组合键打开输入翻译")
        center.unregisterAll()
        let model = SettingsModel(loadSecrets: false)
        model.textTranslateShortcut = nil
        expect(Settings.shared.textTranslateShortcut == nil, "可以在设置里清除这个快捷键")
        model.textTranslateShortcut = combo
        expect(Settings.shared.textTranslateShortcut == combo, "也可以改成别的组合键")

        // 空窗口的样子：两个框里是灰色的「原文 / 译文」占位字。先截一张，免得后面填了内容看不到。
        TextTranslationWindow.shared().testing_setSource("")
        if let content = TextTranslationWindow.shared().contentView {
            renderControls(content, name: "text-translate-empty.png")
        }

        // 打开就翻译剪贴板里的文字。
        let window = TextTranslationWindow.shared()
        var sent: [[String]] = []
        window.translate = { items, _ in
            sent.append(items.map(\.text))
            return Dictionary(uniqueKeysWithValues: items.map { ($0.id, "译文：\($0.text)") })
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("Take a screenshot and translate it in place.", forType: .string)
        TextTranslationWindow.show()
        expect(window.testing_source == "Take a screenshot and translate it in place.", "打开时把剪贴板里的文字填进原文")
        // 开着的输入翻译窗口要能被拍进截图里，不然按截图快捷键它自己就消失了（用户报过）。
        expect(window.capturableWindowNumbers.count == 1, "开着的窗口算进截图")
        for _ in 0..<400 where window.testing_result.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        expect(sent.first == ["Take a screenshot and translate it in place."], "没按任何键就送出去翻译了")
        expect(window.testing_result.hasPrefix("译文："), "译文出来了（\(window.testing_result)）")
        // 状态行只在有事要说的时候才出现：翻好了就该是空的，不再常驻一行提示。
        expect(window.testing_status.isEmpty, "翻好了不留提示文字（\(window.testing_status.debugDescription)）")
        // 两个下拉框默认就是「自动检测 ⇄ 自动选择」——没有输入内容时也是这个，不再显示「外文 → 简体中文」。
        expect(window.testing_direction.source == TranslationConfig.autoSource && window.testing_targetChoice == TextTranslationWindow.autoTarget,
               "默认是「自动检测 → 自动选择」（\(window.testing_direction.source) → \(window.testing_targetChoice)）")
        expect(window.testing_direction.target == Settings.shared.targetLanguage,
               "英文原文时自动选择解析成设置里那门语言（\(window.testing_direction.target)）")

        // 边打字边提示按哪个键；翻过了才改口说识别到什么。
        // 用真正的输入路径打字，不是直接塞字符串——胶囊原来就栽在这上面：窗口只在它自己的入口
        // （剪贴板 / 清空按钮 / 自检）更新，用户敲键盘那条路谁也没管。
        window.testing_setSource("")
        window.testing_type("Open settings")
        expect(window.testing_source == "Open settings", "打进去的字进到原文里（\(window.testing_source)）")
        expect(window.testing_chip == "↩翻译 · ⌘↩ 换行", "打字的时候胶囊提示按键（\(window.testing_chip)）")
        if let content = window.contentView { renderControls(content, name: "text-translate-typing.png") }
        expect(window.testing_popups.source == TranslationConfig.autoSource
               && window.testing_popups.target == TextTranslationWindow.autoTarget,
               "还没翻的时候两个下拉框还是自动检测 / 自动选择（\(window.testing_popups.source) → \(window.testing_popups.target)）")
        expect(window.testing_engine == "免费翻译", "中间那栏右边是翻译引擎，默认免费翻译（\(window.testing_engine)）")

        // 无标题栏窗口默认成不了 key，成不了 key 就一个字符都打不进去——这条守的就是这个。
        expect(window.canBecomeKey, "无标题栏的窗口也要能成为 key，否则原文打不了字")
        expect(window.makeFirstResponder(window.testing_sourceView), "原文输入框能拿到键盘焦点")

        // 引擎可以在这一栏里直接换，换的是设置里那个引擎和那一份大模型（截图翻译跟着一起变，不各说各话）。
        // 下拉里列的是配置名称，不是模型型号——用户给哪份起过名字就显示哪个名字。
        let configs = Settings.shared.llmConfigs
        let labels = LLMConfig.labels(for: configs)
        let formerlySelected = Settings.shared.selectedLLMConfigID
        expect(window.testing_engine == "免费翻译", "默认选中的是免费翻译（\(window.testing_engine)）")
        window.testing_chooseEngine(labels[1])
        expect(Settings.shared.engine == .llm, "在这一栏选大模型，设置里的引擎跟着变")
        expect(Settings.shared.selectedLLMConfigID == configs[1].id,
               "选中的是第二份配置，不是「反正就用第一个」")
        expect(window.testing_engine == labels[1], "选项文字是配置名称（\(window.testing_engine)）")
        window.testing_chooseEngine(labels[0])
        expect(Settings.shared.selectedLLMConfigID == configs[0].id, "换回第一份，选中的配置也跟着换")
        window.testing_chooseEngine("免费翻译")
        expect(Settings.shared.engine == .free, "选回免费翻译")
        expect(window.testing_engine == "免费翻译", "文字也跟着回去（\(window.testing_engine)）")
        Settings.shared.selectedLLMConfigID = formerlySelected

        window.testing_pressReturn(command: false)
        for _ in 0..<400 where !window.testing_result.hasPrefix("译文：") { try? await Task.sleep(for: .milliseconds(50)) }
        expect(window.testing_chip == "识别为 English", "翻过之后胶囊改说识别到什么（\(window.testing_chip)）")
        expect(window.testing_popups.source == "English" && window.testing_popups.target == Settings.shared.targetLanguage,
               "翻完两个下拉框直接显示这次用的语言（\(window.testing_popups.source) → \(window.testing_popups.target)）")

        // 中文原文：自动选择解析成 English，方向自己就反过来了。
        window.testing_setSource("自动检查更新和下载")
        expect(window.testing_direction.target == "English",
               "中文原文时自动选择解析成 English（\(window.testing_direction.target)）")

        // 点箭头：认出的是什么就钉下什么，两头对调，下拉框也跟着显出来。
        window.testing_swapDirection()
        expect(window.testing_direction.source == "English"
               && window.testing_direction.target == "简体中文",
               "点箭头把这一对钉下来并对调（\(window.testing_direction.source) → \(window.testing_direction.target)）")

        // 换回自动：拿掉两头的手动选择，方向重新跟着原文走。
        window.testing_chooseLanguages(source: TranslationConfig.autoSource, target: TextTranslationWindow.autoTarget)
        expect(window.testing_direction.source == TranslationConfig.autoSource
               && window.testing_direction.target == "English",
               "选回自动检测 / 自动选择，方向又跟着原文（\(window.testing_direction.source) → \(window.testing_direction.target)）")
        // The window's own background is not part of the view tree, so it is painted under the snapshot.
        if let content = window.contentView,
           let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(content.bounds.width * 2),
                                         pixelsHigh: Int(content.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            canvas.size = content.bounds.size
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep: canvas)!
            NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill()
            content.bounds.fill()
            // displayIgnoringOpacity draws the whole tree, cells and all; cacheDisplay skips the controls.
            content.displayIgnoringOpacity(content.bounds, in: context)
            NSGraphicsContext.restoreGraphicsState()
            write(canvas, "text-translate.png")
        }

        // 改了原文：回车重翻，⌘↩ 才是换行——和一般输入框正好相反，因为这个窗口是用来贴东西看译文的。
        window.testing_setSource("Ship it today.")
        window.testing_pressReturn(command: false)
        for _ in 0..<400 where !window.testing_result.hasPrefix("译文：Ship it today.") { try? await Task.sleep(for: .milliseconds(50)) }
        expect(sent.last == ["Ship it today."], "回车就重翻（\(sent.last ?? [])）")
        expect(!window.testing_source.contains("\n"), "回车不会往原文里塞换行")

        window.testing_pressReturn(command: true)
        expect(window.testing_source.contains("\n"), "⌘↩ 才是换行（\(window.testing_source.debugDescription)）")

        // 复制译文进剪贴板。
        pasteboard.clearContents()
        window.testing_copy()
        expect(pasteboard.string(forType: .string) == "译文：Ship it today.", "复制译文写进剪贴板")
        expect(window.testing_status == "已复制译文", "顶行确认复制了")

        // Esc 关窗。
        window.keyDown(with: textKeyEvent(window, "\u{1b}", code: 53))
        expect(!window.testing_visible, "Esc 关掉窗口")
        expect(window.capturableWindowNumbers.isEmpty, "关掉之后就不再算进截图")

        // 关掉再打开：干净，而且同一份剪贴板不会被再读一遍——原来看着就像「记住了上次的译文」，
        // 其实每次开都又把还躺在剪贴板里的那段重翻了一次。（这一段中间不能碰剪贴板：重新复制同一段
        // 文字本身就是一次新的复制，那当然该再读一遍。）
        pasteboard.clearContents()
        pasteboard.setString("Once is enough", forType: .string)
        let first = TextTranslationWindow.shared()
        first.translate = window.translate
        TextTranslationWindow.show()
        expect(first.testing_source == "Once is enough", "打开时读一次剪贴板（\(first.testing_source)）")
        first.close()
        let reopened = TextTranslationWindow.shared()
        reopened.translate = window.translate
        TextTranslationWindow.show()
        expect(reopened !== first, "关过之后打开的是新窗口")
        expect(reopened.testing_source.isEmpty && reopened.testing_result.isEmpty,
               "再打开是干净的，同一份剪贴板不会再读一遍（\(reopened.testing_source.debugDescription)）")

        // 换了剪贴板才自动填。
        pasteboard.clearContents()
        pasteboard.setString("Brand new clipboard text", forType: .string)
        reopened.close()
        let fresh = TextTranslationWindow.shared()
        fresh.translate = window.translate
        TextTranslationWindow.show()
        expect(fresh.testing_source == "Brand new clipboard text", "剪贴板换了才自动填（\(fresh.testing_source)）")

        // 关掉「自动读取剪贴板翻译」：打开时留空，什么都不翻。
        Settings.shared.autoReadClipboard = false
        pasteboard.clearContents()
        pasteboard.setString("Should not be read", forType: .string)
        fresh.close()
        let manual = TextTranslationWindow.shared()
        manual.translate = window.translate
        TextTranslationWindow.show()
        expect(manual.testing_source.isEmpty && manual.testing_result.isEmpty,
               "关掉自动读取就留空等你输入（\(manual.testing_source.debugDescription)）")
        Settings.shared.autoReadClipboard = true

        // 置顶：图钉从躺着变成立起来，窗口层级也跟着浮上去。
        expect(!manual.testing_pinned && manual.level == .normal, "默认不置顶")
        manual.testing_togglePin()
        expect(manual.testing_pinned && manual.level == .floating, "点了之后窗口浮上去")
        if let content = manual.contentView { renderControls(content, name: "text-translate-pinned.png") }
        manual.testing_togglePin()
        expect(!manual.testing_pinned && manual.level == .normal, "再点一下放下来")

        // 原文右下角的清空按钮：一键清掉原文，译文也跟着走。
        manual.testing_setSource("Something to clear")
        manual.testing_clear()
        expect(manual.testing_source.isEmpty && manual.testing_result.isEmpty, "清空按钮把原文清掉，译文也跟着走")
        manual.close()

        // 大模型引擎没填 Key 时只提示，不发送。
        if Settings.shared.apiKey.isEmpty {
            Settings.shared.engine = .llm
            pasteboard.clearContents()
            pasteboard.setString("Anything worth translating", forType: .string)
            var calls = 0
            TextTranslationWindow.shared().translate = { _, _ in
                calls += 1
                return [:]
            }
            TextTranslationWindow.show()
            expect(calls == 0 && TextTranslationWindow.shared().testing_status.contains("API Key"),
                   "没填 API Key 只提示不发送（\(TextTranslationWindow.shared().testing_status)）")
            TextTranslationWindow.shared().close()
        }
    }

    /// 译文还原：把一张合成的「文档截图」整张翻一遍，看字号、颜色、底色和原文对不对得上。
    /// 悬浮条上原文 / 译文两边都能点开语言列表：识别猜错了可以自己改，改完立刻按新方向重翻。
    @MainActor static func translationLanguage() async {
        let rect = CGRect(x: 60, y: 60, width: 420, height: 110)
        var sent: [(source: String, target: String, texts: [String])] = []
        // 英文占多数、夹一行中文：原文会被判成英文，只送英文那几行——把原文改成中文之后，送的应该只剩中文那行。
        let h = CaptureHarness(lines: ["Advanced", "Automatically update Dia", "保存设置"])
        h.view.autoTranslate = true
        h.view.translate = { items, config in
            sent.append((config.sourceLanguage, config.targetLanguage, items.map(\.text)))
            return Dictionary(uniqueKeysWithValues: items.map { ($0.id, "translation") })
        }
        h.select(rect)
        // Vision compiles its models on the first recognition of a new build (about 30 s), so the first wait
        // gets twice the usual budget.
        func waitFor(_ what: @escaping () -> Bool) async {
            for _ in 0..<1200 where !what() { try? await Task.sleep(for: .milliseconds(50)) }
        }
        await waitFor { !sent.isEmpty }

        guard let bar = h.view.testing_translationBar, let frames = h.view.testing_barLanguageFrames else {
            return expect(false, "悬浮条上有两个语言选择")
        }
        expect(bar.source == "英文" && bar.target == Settings.shared.targetLanguage,
               "先按猜的来（\(bar.source) → \(bar.target)）")
        // 两边都要真的点得到：走命中测试，不是直接调 handler。
        expect(h.view.testing_hitTest(CGPoint(x: frames.source.midX, y: frames.source.midY)) is ChromeTextButton,
               "原文语言点得到")
        expect(h.view.testing_hitTest(CGPoint(x: frames.target.midX, y: frames.target.midY)) is ChromeTextButton,
               "译文语言点得到")

        // 原文：自动检测 + 四种语言，打勾的是猜出来的英文。
        h.view.testing_pressSourceLanguage()
        guard let menu = h.view.testing_languageMenu else { return expect(false, "点原文打开语言列表") }
        expect(menu.titles == ["自动检测", "中文", "英文", "日文", "韩文"], "原文列表（\(menu.titles)）")
        expect(menu.checked == 2, "打勾的是猜出来的英文（\(menu.checked)）")
        expect(abs(menu.frame.minX - frames.source.minX) < 1 && menu.frame.minY >= frames.source.maxY,
               "列表挂在原文那边下面（\(menu.frame)）")
        h.view.testing_hoverLanguageRow(1)
        h.screenshot().map { write($0, "translation-language-source.png") }

        // 把原文改成中文：条上跟着变，而且只把中文那一段送出去（按英文时送的是另外两行）。
        let before = sent.count
        h.view.testing_pickLanguage(1)
        expect(h.view.testing_languageMenu == nil, "选完列表收起来")
        await waitFor { sent.count > before }
        expect(sent.last?.source == "简体中文", "用中文重翻（\(sent.last?.source ?? "nil")）")
        expect(sent.last?.texts == ["保存设置"], "只送中文那段（\(sent.last?.texts ?? [])）")
        expect(h.view.testing_translationBar?.source == "中文", "条上写着中文")

        // 改回英文。
        h.view.testing_pressSourceLanguage()
        h.view.testing_pickLanguage(2)
        await waitFor { sent.last?.source == "English" }
        expect(h.view.testing_translationBar?.source == "英文", "原文改回英文")

        // 译文：自动选择 + 五种目标语言，选日本語。
        h.view.testing_pressTargetLanguage()
        guard let targetMenu = h.view.testing_languageMenu else { return expect(false, "点译文打开目标语言列表") }
        expect(targetMenu.titles == ["自动选择", "简体中文", "繁體中文", "English", "日本語", "한국어"],
               "译文列表（\(targetMenu.titles)）")
        expect(targetMenu.checked == 1, "打勾的是实际在用的「简体中文」（\(targetMenu.checked)）")
        let beforeTarget = sent.count
        h.view.testing_pickLanguage(4)
        await waitFor { sent.count > beforeTarget }
        expect(sent.last?.target == "日本語", "译成日文（\(sent.last?.target ?? "nil")）")
        expect(h.view.testing_translationBar?.target == "日本語", "条上写着译成日文")

        // 对调箭头：两边对调，而且两边都被钉住了（不再靠「翻一下猜测」）。
        h.view.testing_pressSwapDirection()
        await waitFor { h.view.testing_translationBar?.source == "日文" }
        expect(h.view.testing_translationBar?.source == "日文" && h.view.testing_translationBar?.target == "English",
               "对调之后是「日文 → English」（\(h.view.testing_translationBar?.source ?? "-") → \(h.view.testing_translationBar?.target ?? "-")）")

        // 新的一次截图重新猜：钉住的语言不跟过去。
        let beforeReset = sent.count
        h.view.testing_resetSelection()
        h.select(rect)
        await waitFor { sent.count > beforeReset && h.view.testing_translationBar?.source == "英文" }
        expect(h.view.testing_translationBar?.source == "英文",
               "新选区回到自动判断的英文（\(h.view.testing_translationBar?.source ?? "-")）")
    }

    /// 小字：Vision 整图会把行丢掉（用户那封 2000×623、行框 23px 的邮件只认出 16 行里的 12 行），
    /// 放大再认一遍才齐。
    @MainActor static func smallText() async {
        let size = CGSize(width: 900, height: 300)
        let lines = (1...8).map { "Line \($0) of a small email body that must all be recognized." }
        let h = CaptureHarness(size: size, paint: { _ in
            NSColor.white.setFill()
            CGRect(origin: .zero, size: size).fill()
            for (i, text) in lines.enumerated() {
                NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 7), .foregroundColor: NSColor.black,
                ]).draw(at: CGPoint(x: 20, y: 20 + CGFloat(i) * 14))
            }
        })
        let result = (try? await TextRecognizer.recognize(h.snapshot, selection: CGRect(origin: .zero, size: size)))
            ?? RecognitionResult(lines: [])
        expect(result.lines.count == lines.count, "小字也全部认出来（\(result.lines.count)/\(lines.count)）")
    }

    @MainActor static func translationStyle() async {
        let fixture = CaptureHarness(size: CGSize(width: 900, height: 620), paint: paintFixture)
        write(NSBitmapImageRep(cgImage: fixture.snapshot), "translation-style-before.png")
        let bounds = CGRect(origin: .zero, size: fixture.size)

        let recognition = (try? await TextRecognizer.recognize(fixture.snapshot, selection: bounds)) ?? RecognitionResult(lines: [])
        let blocks = recognition.translatedBlocks.filter { TextBlockBuilder.shouldTranslate($0.text) }
        expect(blocks.count >= 4, "合成截图里认出了 \(blocks.count) 段可翻译文字")
        let translations = fixtureTranslations(blocks)
        let laidOut = TranslationLayout.layout(blocks: blocks, translations: translations, crop: fixture.snapshot, selection: bounds)
        expect(laidOut.count == blocks.count, "每段都有译文（\(laidOut.count)/\(blocks.count)）")

        func block(_ needle: String) -> (TextBlock, TranslatedBlock)? {
            for (index, source) in blocks.enumerated() where source.text.localizedCaseInsensitiveContains(needle) {
                return index < laidOut.count ? (source, laidOut[index]) : nil
            }
            return nil
        }
        func kind(_ block: TranslatedBlock) -> String {
            if case .plate = block.background { return "plate" }
            return "solid"
        }

        // The heading is 26 pt: the translation has to come out the same size, or the page looks wrong.
        if let (_, heading) = block("Translate screenshots") {
            expect(abs(heading.fontSize - 26) < 4, "标题字号跟着原文走（\(heading.fontSize) pt，原文 26）")
            expect(heading.bold, "标题是粗体")
        } else {
            expect(false, "认出了标题")
        }

        // White text on a blue button must stay white: flipping it to black is the classic mistake.
        if let (_, button) = block("Download") {
            let f = button.foreground.usingColorSpace(.sRGB)!
            expect(f.redComponent > 0.75 && f.greenComponent > 0.75 && f.blueComponent > 0.75,
                   "彩色按钮上的白字还是白的（\(f)）")
            expect(kind(button) == "solid", "按钮的底色是纯色，直接填掉原文")
        } else {
            expect(false, "认出了按钮文字")
        }

        // Text on a photo can't be erased with one color: it gets a blurred plate of what was underneath.
        if let (_, photo) = block("photo") {
            expect(kind(photo) == "plate", "照片上的文字用模糊底板")
        } else {
            expect(false, "认出了照片上的文字")
        }

        // The tight paragraph: the whole point is that all three lines give the same size, so the translation
        // comes out as the paragraph it replaced instead of three times as big.
        if let (_, tight) = block("tight leading") {
            expect(abs(tight.fontSize - 14) < 2.5, "紧排多行段落的字号跟着原文（\(tight.fontSize) pt，原文 14）")
        } else {
            expect(false, "认出了紧排段落")
        }

        // A translation far longer than the original grows into the blank space below it first, and only then
        // shrinks and finally loses its tail — it must stay inside the room it was allowed.
        if let (_, long) = block("OmniShot reads the text") {
            let lines = TranslationText.lines(long.text, TranslationText.attributes(size: long.fontSize, bold: long.bold,
                                                                                   language: long.language), width: long.wrapWidth)
            let height = TranslationText.height(lines, pitch: long.pitch)
            let room = long.rect.height + CGFloat(TranslationLayout.maximumExtraLines) * long.pitch + long.fontSize * 0.3
            expect(height <= room, "长译文没超出允许的高度（\(height) ≤ \(room)）")
            expect(long.fontSize >= 10.5, "长译文最多缩到 75%（\(long.fontSize) pt）")
        } else {
            expect(false, "认出了正文")
        }

        // A heading's OCR box is often shorter than the line the text was set on. Four characters must still
        // come out whole and at the original size — this used to shrink them and then collapse them to「…」.
        let tight = TranslationLayout.fit("建议采取的措施：", from: 28,
                                          in: CGRect(x: 0, y: 0, width: 300, height: 8),
                                          pitch: 36, language: "zh-Hans", bold: true)
        expect(tight.text == "建议采取的措施：" && tight.fontSize == 28,
               "框比字矮时短译文也原样出来（\(tight.fontSize) pt，\(tight.text)）")

        let renderer = ContentRenderer(base: NSImage(cgImage: fixture.snapshot, size: fixture.size), bounds: bounds,
                                       effect: { _ in ContentRenderer.EffectImage(image: NSImage(), rect: bounds) })
        if let rep = Exporter.render(renderer: renderer, selection: bounds, scale: 2, items: [], translation: laidOut) {
            write(rep, "translation-style-after.png")
        }
        for (source, block) in zip(blocks, laidOut) {
            print("   \(block.rect.integral) \(kind(block)) size \(block.fontSize) pitch \(block.pitch) bold \(block.bold) "
                  + "「\(source.text.prefix(24))」→「\(block.text)」")
        }
    }

    /// A page-like fixture: three type sizes, white-on-color, a photo band and a table rule.
    @MainActor static func paintFixture(_ ctx: CGContext) {
        func text(_ string: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
                  color: NSColor = .black, width: CGFloat = 780) {
            NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                            .foregroundColor: color])
                .draw(in: CGRect(x: x, y: y, width: width, height: size * 3))
        }
        NSColor.white.setFill()
        CGRect(x: 0, y: 0, width: 900, height: 620).fill()

        text("Translate screenshots in place", 60, 40, size: 26, weight: .bold)
        text("OmniShot reads the text and draws the translation where it was", 60, 96, size: 14, color: .darkGray)

        NSColor(srgbRed: 0.16, green: 0.5, blue: 0.9, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 60, y: 150, width: 190, height: 46), xRadius: 10, yRadius: 10).fill()
        text("Download now", 92, 163, size: 15, weight: .semibold, color: .white, width: 150)

        // A photo: something with structure, so a flat fill would show and a blurred plate would not.
        let photo = CGRect(x: 60, y: 230, width: 560, height: 130)
        for row in 0..<Int(photo.height) {
            let t = CGFloat(row) / photo.height
            NSColor(srgbRed: 0.15 + t * 0.5, green: 0.35 + t * 0.2, blue: 0.6 - t * 0.35, alpha: 1).setFill()
            CGRect(x: photo.minX, y: photo.minY + CGFloat(row), width: photo.width, height: 1).fill()
        }
        for ring in 0..<7 {
            NSColor(white: 1, alpha: 0.18).setFill()
            CGRect(x: photo.minX + 40 + CGFloat(ring) * 62, y: photo.minY + 20, width: 26, height: 90).fill()
        }
        text("Text over a photo", 100, 278, size: 17, weight: .medium, color: .white)

        // A table row with a rule beside the text.
        text("Name", 60, 400, size: 15)
        NSColor(srgbRed: 0.7, green: 0.7, blue: 0.72, alpha: 1).setFill()
        CGRect(x: 300, y: 380, width: 2, height: 46).fill()
        text("Settings", 330, 400, size: 15)

        // A paragraph on tight leading, the normal case in an email: Vision's line boxes overlap here, and
        // reading the block as one piece used to make the whole paragraph measure two to three times its size.
        text("A paragraph set on tight leading is the normal case in", 60, 470, size: 14, width: 620)
        text("an email, where the lines sit close together and the", 60, 488.5, size: 14, width: 620)
        text("boxes Vision reports overlap by a few pixels.", 60, 507, size: 14, width: 620)
    }

    /// A Chinese translation per block, deliberately including one far longer than its original.
    @MainActor static func fixtureTranslations(_ blocks: [TextBlock]) -> [Int: String] {
        var result: [Int: String] = [:]
        for block in blocks {
            let text = block.text
            switch true {
            case text.localizedCaseInsensitiveContains("Translate screenshots"): result[block.id] = "在原位翻译截图"
            case text.localizedCaseInsensitiveContains("Download"): result[block.id] = "立即下载"
            case text.localizedCaseInsensitiveContains("photo"): result[block.id] = "照片上的文字"
            case text.localizedCaseInsensitiveContains("Name"): result[block.id] = "名称"
            case text.localizedCaseInsensitiveContains("Settings"): result[block.id] = "设置"
            case text.localizedCaseInsensitiveContains("tight leading"): result[block.id] = "紧排的正文是邮件的常态"
            default:
                result[block.id] = "OmniShot 会读出截图里的文字，并把译文画在原来那段文字的位置上，"
                    + "长句子会先缩小字号，实在放不下才在末尾收个省略号，绝不会压到下面一行去。"
            }
        }
        return result
    }

    /// 双击选区直接置顶；双击文字标注仍然是进入编辑。
    @MainActor static func doubleClickPin() async {
        let h = CaptureHarness()
        h.select(CGRect(x: 60, y: 60, width: 420, height: 110))
        let before = PinManager.shared.pins.count
        h.click(CGPoint(x: 200, y: 100), clicks: 2)
        expect(PinManager.shared.pins.count == before + 1, "双击选区直接置顶")
        expect(PinManager.shared.pins.last?.rep.size == CGSize(width: 420, height: 110),
               "钉住的就是选区那块（\(PinManager.shared.pins.last?.rep.size ?? .zero)）")
        PinManager.shared.closeAll()

        // 双击已有的文字标注要进编辑，不能又冒出一个贴图
        let h2 = CaptureHarness()
        h2.select(CGRect(x: 20, y: 20, width: 760, height: 460))
        h2.key("6", code: 22)
        h2.click(CGPoint(x: 120, y: 100))
        (h2.window.firstResponder as? NSTextView)?.insertText("Hi", replacementRange: NSRange(location: NSNotFound, length: 0))
        h2.key("\u{1b}", code: 53)
        guard let text = h2.view.testing_items.first(where: { if case .text = $0.shape { true } else { false } }) else {
            return expect(false, "放下了文字标注")
        }
        let pins = PinManager.shared.pins.count
        h2.click(CGPoint(x: text.bounds.midX, y: text.bounds.midY), clicks: 2)
        expect(PinManager.shared.pins.count == pins, "双击文字标注不会置顶")
        expect(h2.window.firstResponder is NSTextView, "而是进入文字编辑")
        PinManager.shared.closeAll()
    }

    /// 主题色：设置里改一处，选边框（含手柄）、工具条上的激活态、尺寸框全跟着变；换成深色主题后尺寸框
    /// 里的数字仍然清楚（底色和字色一起按对比度挑，不是写死的白字）。
    ///
    /// 每一轮都新建一个 harness，就像用户改完设置又截了一次图那样——`CaptureView` 是每块屏幕一份、每次
    /// 截图重来的，中途改主题不该是常态，别让这条检查去依赖"改完还得手动触发一次布局"。
    @MainActor static func themedChrome() async {
        let chosen = Settings.shared.themeColor
        defer { Settings.shared.themeColor = chosen }
        let box = CGRect(x: 100, y: 80, width: 320, height: 220)

        func capture() -> CaptureHarness {
            let h = CaptureHarness(size: CGSize(width: 600, height: 420))
            h.select(box)
            h.key("4", code: 21) // 工具条上得有一个"激活"的工具，才看得出主题色
            return h
        }
        // 边框描在选区边上（中心线），所以正好落在 midX / minY 那一点上。
        func edge(_ shot: NSBitmapImageRep) -> NSColor? {
            shot.color(atPoint: CGPoint(x: box.midX, y: box.minY))?.usingColorSpace(.sRGB)
        }
        func chipFrame(_ h: CaptureHarness) -> CGRect? {
            h.view.subviews.compactMap { $0 as? TopBarView }.first.map { $0.convert($0.bounds, to: h.view) }
        }

        guard let shot0 = capture().screenshot() else { return expect(false, "渲染选区") }
        write(shot0, "theme-default.png")
        expect(edge(shot0).map { $0.blueComponent > $0.redComponent } == true, "默认还是那支浅蓝")

        Settings.shared.themeColor = .systemRed
        let h = capture()
        guard let red = h.screenshot() else { return expect(false, "渲染选区") }
        write(red, "theme-red.png")
        expect(edge(red).map { isRed($0) } == true, "选边框跟着主题色走")
        let corner = red.color(atPoint: CGPoint(x: box.minX, y: box.minY))?.usingColorSpace(.sRGB)
        expect(corner.map { isRed($0) } == true, "四角的手柄是同一个颜色")

        // 工具条上激活的那个工具：底色是主题色的半透明，图标本身也是主题色。
        if let bar = h.view.subviews.compactMap({ $0 as? ToolbarView }).first,
           let button = bar.toolButtons[.mosaic] {
            let centre = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: h.view)
            let pixel = red.color(atPoint: centre)?.usingColorSpace(.sRGB)
            expect(pixel.map { $0.redComponent - max($0.greenComponent, $0.blueComponent) > 0.05 } == true,
                   "工具条激活态也是主题色（\(pixel.map { "\($0)" } ?? "nil")）")
        } else {
            expect(false, "找得到工具条上马赛克那个按钮")
        }

        // 尺寸框：底色是主题色。
        guard let chip = chipFrame(h) else { return expect(false, "选区左上角有尺寸框") }
        let fill = red.color(atPoint: CGPoint(x: chip.midX, y: chip.minY + 3))?.usingColorSpace(.sRGB)
        expect(fill.map { isRed($0) } == true, "尺寸框底色也是主题色（\(fill.map { "\($0)" } ?? "nil")）")

        // 换成近黑的主题：底色要变深，而里面的数字必须仍然是亮的——这就是「深色主题下还看得清」那条。
        Settings.shared.themeColor = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1)
        let dark = capture()
        guard let darkChip = chipFrame(dark), let content = dark.window.contentView,
              let rendered = renderControls(content, name: "theme-dark-chip.png") else {
            return expect(false, "渲染尺寸框")
        }
        var bright = 0, total = 0
        for x in stride(from: darkChip.minX + 2, to: darkChip.maxX - 2, by: 1) {
            for y in stride(from: darkChip.minY + 2, to: darkChip.maxY - 2, by: 1) {
                guard let c = rendered.color(atPoint: CGPoint(x: x, y: y))?.usingColorSpace(.sRGB) else { continue }
                total += 1
                if c.brightnessComponent > 0.7 { bright += 1 }
            }
        }
        expect(total > 200, "尺寸框渲染出来了（\(total) 个采样点）")
        expect(bright > 0, "深色主题下尺寸框里的数字还在（\(bright)/\(total) 个亮点）")
        expect(Double(bright) / Double(max(total, 1)) < 0.5, "底色是深的，只有字是亮的（\(bright)/\(total)）")
    }

    /// 够不够红：红色分量高，而且明显压过绿蓝（`systemRed` 的具体数值随系统色调变，不写死）。
    @MainActor private static func isRed(_ c: NSColor) -> Bool {
        c.redComponent > 0.8 && c.redComponent - max(c.greenComponent, c.blueComponent) > 0.4
    }

    /// 贴图右上角的圆形关闭按钮：悬停出现，点它关闭，且不影响贴图里的文字选择。
    @MainActor static func pinClose() async {
        let h = CaptureHarness(lines: ["Settings", "Automatically check for updates"])
        h.select(CGRect(x: 60, y: 60, width: 420, height: 110))
        guard let rep = h.export() else { return expect(false, "export") }
        let pin = PinManager.shared.pin(rep, frame: CGRect(origin: CGPoint(x: -4000, y: -4000), size: rep.size))
        let view = pin.testing_view
        let button = view.testing_closeButton

        func mouse(_ type: NSEvent.EventType, in target: NSView, at p: CGPoint, clicks: Int = 1) -> NSEvent {
            let location = target.convert(p, to: nil)
            // Enter and exit events have their own constructor; mouseEvent(with:) blocks on them.
            if type == .mouseEntered || type == .mouseExited {
                return NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                              windowNumber: pin.windowNumber, context: nil, eventNumber: 0,
                                              trackingNumber: 0, userData: nil)!
            }
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                      windowNumber: pin.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        let outside = CGPoint(x: 60, y: view.bounds.midY)
        expect(button.isHidden, "没把鼠标移到图片上时，关闭按钮不显示")
        expect(button.acceptsFirstMouse(for: nil), "点一下就生效，不用先点一次激活贴图")

        // 边框用的是设置里选的颜色
        let chosen = Settings.shared.themeColor
        defer { Settings.shared.themeColor = chosen }
        Settings.shared.themeColor = .systemRed
        guard let shot = render(view),
              let border = shot.color(atPoint: CGPoint(x: shot.size.width / 2, y: PinView.buttonInset - 0.75))?.usingColorSpace(.sRGB)
        else { return expect(false, "渲染贴图取边框像素") }
        expect(border.redComponent > 0.7 && border.greenComponent < 0.4, "贴图边框用设置里选的颜色（\(border)）")
        // 发光：边框外侧是一圈越远越淡的同色光晕，不是第二道描边；也不能渗到图片里去（用户要的是边缘发光）。
        let edge = PinView.borderInset
        let midline = shot.size.height / 2
        func margin(_ distance: CGFloat) -> NSColor? {
            shot.color(atPoint: CGPoint(x: edge - distance, y: midline))?.usingColorSpace(.sRGB)
        }
        let near = margin(2.5), mid = margin(4.5), far = margin(6.5)
        expect(near?.alphaComponent ?? 0 > 0.05 && (far?.alphaComponent ?? 0) > 0.01,
               "边框外侧有光晕，一直到 6.5pt 外还看得见（\(near?.alphaComponent ?? 0) \(mid?.alphaComponent ?? 0) \(far?.alphaComponent ?? 0)）")
        expect((near?.alphaComponent ?? 0) > (mid?.alphaComponent ?? 1)
               && (mid?.alphaComponent ?? 0) > (far?.alphaComponent ?? 1), "光晕越往外越淡，不是一道硬边")
        expect(margin(2.5).map { $0.redComponent > 0.5 } == true, "光晕用的是边框那个颜色，不是黑边")
        if let inside = shot.color(atPoint: CGPoint(x: edge + 3, y: midline))?.usingColorSpace(.sRGB),
           let source = rep.color(atPoint: CGPoint(x: 3, y: midline - PinView.buttonInset))?.usingColorSpace(.sRGB) {
            expect(abs(inside.redComponent - source.redComponent) < 0.02 && abs(inside.blueComponent - source.blueComponent) < 0.02,
                   "光晕没有渗进图片边缘（图片像素没被染色）")
        }
        // 失去焦点（点到别处）也要保持彩色：边框是用来认贴图的，变灰就认不出来了。
        pin.resignKey()
        pin.resignMain()
        let idle = render(view)?.color(atPoint: CGPoint(x: view.bounds.midX, y: PinView.buttonInset - 0.75))?.usingColorSpace(.sRGB)
        expect(pin.isKeyWindow == false, "贴图已失去焦点，用来测下面那条")
        expect(idle.map { $0.redComponent > 0.7 && $0.greenComponent < 0.4 } == true,
               "点到别处后边框照样是彩色（\(idle.map { "\($0)" } ?? "nil")）")
        pin.makeKey()
        Settings.shared.themeColor = chosen // 换回真实颜色再出一张，方便对着看
        write(render(view) ?? shot, "pin-border.png")
        view.mouseEntered(with: mouse(.mouseEntered, in: view, at: outside))
        expect(!button.isHidden, "鼠标移到图片上，关闭按钮出现")
        let picture = view.imageRect
        let corner = CGRect(x: picture.maxX + PinView.buttonGap, y: picture.minY,
                            width: GlyphButton.diameter, height: GlyphButton.diameter)
        expect(button.frame == corner, "按钮在图片外侧的右上角（\(button.frame)）")
        expect(!button.frame.intersects(picture), "按钮不压在图片上")
        write(render(view) ?? rep, "pin-close.png")

        // Hovering also starts recognizing the pin's text; wait for it so the selection check below has something
        // to select. This is the one the user asked to protect: the button must not cost them word selection.
        // A cold Vision model takes about half a minute to compile, so this waits longer than the other checks.
        for _ in 0..<600 where view.textLayout == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let layout = view.textLayout, let settings = layout.lines.firstIndex(where: { $0.text == "Settings" }),
              let box = layout.lines[settings].boxes.first else { return expect(false, "贴图识别出了文字") }
        // The layout is in image coordinates; the view has the border to the left and the buttons above.
        let word = CGPoint(x: box.midX + PinView.borderInset, y: layout.lines[settings].rect.midY + PinView.buttonInset)
        view.mouseDown(with: mouse(.leftMouseDown, in: view, at: word, clicks: 2))
        expect(view.selectedText == layout.lines[settings].text, "按钮出现时双击文字照样选词（\(view.selectedText ?? "nil")）")

        // 指针离开贴图，按钮也不藏（它们一直显示）；再移回来点它。
        view.mouseExited(with: mouse(.mouseExited, in: view, at: CGPoint(x: -40, y: -40)))
        expect(button.isHidden, "鼠标离开贴图，关闭按钮跟着藏起来")

        view.mouseEntered(with: mouse(.mouseEntered, in: view, at: outside))
        let center = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        button.mouseDown(with: mouse(.leftMouseDown, in: button, at: center))
        button.mouseUp(with: mouse(.leftMouseUp, in: button, at: center))
        expect(!PinManager.shared.pins.contains { $0 === pin }, "点它就关掉贴图")
        PinManager.shared.closeAll()
    }


    /// 贴图窗口的层级：要压在 Finder 的 Quick Look（`QLPreviewPanel` 在层 9）上面，但留在程序坞（20）和
    /// 菜单栏（24）下面。`.floating`（3）那版用户报过「贴上了却看不见，关掉预览才出现」。
    @MainActor static func pinLayer() async {
        let pin = PinManager.shared.pin(sampleRep(CGSize(width: 40, height: 30)),
                                        frame: CGRect(x: -4000, y: -4000, width: 40, height: 30))
        defer { pin.closePin() }
        expect(pin.level == .pinned, "贴图窗口用 pinned 层级（\(pin.level.rawValue)）")
        expect(pin.level.rawValue > 9, "贴在 Quick Look（QLPreviewPanel 是 9）上面")
        expect(pin.level.rawValue < NSWindow.Level.mainMenu.rawValue, "仍在菜单栏下面")

        let scan = ScanResultPinWindow(codes: ["https://omnishot.example/app"],
                                       frame: CGRect(x: -5000, y: -5000, width: 340, height: 100))
        expect(scan.level == .pinned, "扫码结果的钉住窗口也在同一层（\(scan.level.rawValue)）")
        scan.close()
    }

    /// 贴图的两个按钮：一直在图片右边**外面**（不挡内容），图片被拖出显示器右边缘时跟着一起消失；关闭按钮
    /// 下面的圆点是拖动贴图的手柄，鼠标移上去就展开（不用先按一下）。
    /// 贴图八条边 / 八个角上的拉伸：拖任何一个都等比缩放，对面那个点不动，而且**指针拖到贴图外面也不许断**
    /// （窗口跟着缩放在长，但快拖时跟不上指针，点阵手柄当初就是这么丢的）。
    /// 贴图的旋转按钮：逆时针 90°。按钮列钉在图片的**右上角**，所以转完之后它还停在指针底下——这是能连点
    /// 四下转回原样的前提。
    @MainActor static func pinRotate() async {
        // The picture is white with a red block in its top-left corner: where that block ends up is the direction.
        let rep: NSBitmapImageRep = {
            let size = CGSize(width: 200, height: 100)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            CGRect(origin: .zero, size: size).fill()
            NSColor.red.setFill()
            // The rep's drawing space is y-up, so this is the top-left block.
            CGRect(x: 0, y: size.height - 20, width: 20, height: 20).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }()
        let pin = PinManager.shared.pin(rep, frame: CGRect(x: -4000, y: -4000, width: 200, height: 100))
        defer { PinManager.shared.closeAll() }
        let view = pin.testing_view
        let rotate = view.testing_rotateButton

        func picture() -> CGRect { PinView.pictureFrame(in: pin.frame) }
        func buttonOnScreen() -> CGRect {
            pin.convertToScreen(rotate.convert(rotate.bounds, to: nil))
        }
        func isRed(_ x: Int, _ y: Int) -> Bool {
            guard let c = pin.rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return c.redComponent > 0.7 && c.greenComponent < 0.4
        }
        func same(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 0.6 && abs(a.minY - b.minY) < 0.6
                && abs(a.width - b.width) < 0.6 && abs(a.height - b.height) < 0.6
        }

        let startPicture = picture()
        let startButton = buttonOnScreen()
        expect(abs(startPicture.width - 200) < 0.6 && abs(startPicture.height - 100) < 0.6,
               "起始图片 200×100（\(startPicture)）")
        expect(isRed(4, 4), "原图左上角那一点是红的（方向判据）")
        expect(view.testing_toolsButton.frame.maxY <= rotate.frame.minY
               && rotate.frame.maxY <= view.testing_handleButton.frame.minY,
               "旋转按钮在编辑下面、点阵手柄上面（\(rotate.frame)）")

        rotate.testing_press()
        // 点一下先起动画：这一刻模型还没换，按钮也还钉在原地。
        guard let progress = view.testing_rotationProgress, let angle = view.testing_rotationAngle else {
            return expect(false, "点一下先转动画")
        }
        expect(progress < 1 && angle < 0, "朝逆时针转（进度 \(progress)，角度 \(angle)）")
        expect(same(buttonOnScreen(), startButton), "转的过程中按钮也不动（\(buttonOnScreen()) vs \(startButton)）")
        try? await Task.sleep(for: .milliseconds(120))
        write(render(view) ?? sampleRep(), "pin-rotate-turning.png")
        view.testing_finishRotation()
        expect(view.testing_rotationProgress == nil, "动画落地，状态清掉")
        expect(abs(picture().width - 100) < 0.6 && abs(picture().height - 200) < 0.6,
               "转一次宽高互换（\(picture())）")
        expect(abs(picture().maxX - startPicture.maxX) < 0.6, "右边那条边一动不动（\(picture()) vs \(startPicture)）")
        // 上边会为了让按钮列不跳，最多挪一个「矮贴图把按钮往上挤」的高度（这里是 6pt）。
        expect(abs(picture().maxY - startPicture.maxY) <= 8,
               "上边只让出一丁点，换来按钮不动（\(picture()) vs \(startPicture)）")
        expect(same(buttonOnScreen(), startButton), "转完按钮还停在原地（\(buttonOnScreen()) vs \(startButton)）")
        expect(isRed(4, pin.rep.pixelsHigh - 5), "逆时针：左上角那块红转到了左下角")

        for _ in 0..<3 {
            rotate.testing_press()
            view.testing_finishRotation()
        }
        expect(same(picture(), startPicture), "连点四下转回原样（\(picture())）")
        expect(same(buttonOnScreen(), startButton), "四下之后按钮还在同一个像素上（\(buttonOnScreen())）")
        expect(isRed(4, 4), "红色标记也回来了")

        // 快速连点：第二下把第一下的动画直接落地，再起第二下——四下快速点仍然是四下。
        rotate.testing_press()
        rotate.testing_press()
        view.testing_finishRotation()
        expect(view.testing_rotationProgress == nil && same(picture(), startPicture),
               "连点两下等于转两下，画幅回到原样（\(picture())）")

        // 缩放是图片的，不是窗口的：转的是图，百分比不变。
        pin.setZoom(0.5, flash: false)
        let zoomed = picture()
        rotate.testing_press()
        view.testing_finishRotation()
        expect(abs(pin.zoom - 0.5) < 0.001, "旋转不改缩放（\(pin.zoom)）")
        expect(abs(picture().width - zoomed.height) < 0.6 && abs(picture().height - zoomed.width) < 0.6,
               "50% 下转完宽高照样互换（\(picture())）")

        // 编辑中禁用：标注是钉在旧方向上的。
        view.setEditing(true)
        expect(!rotate.isEnabled, "编辑中旋转按钮变灰")
        let before = pin.rep
        pin.rotateImage()
        expect(pin.rep === before, "编辑中点了也不转")
        view.setEditing(false)
        expect(rotate.isEnabled, "退出编辑后又能转了")
        expect(pin.makeMenu().items.contains { $0.title == "逆时针旋转 90°" && $0.isEnabled },
               "右键菜单里也有这个动作")
    }

    @MainActor static func pinResize() async {
        let size = CGSize(width: 300, height: 200)
        let pin = PinManager.shared.pin(sampleRep(size), frame: CGRect(x: -4000, y: -4000, width: size.width, height: size.height))
        let view = pin.testing_view
        /// 视图坐标（翻转，y 向下）→ 屏幕坐标（y 向上）。
        func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: pin.frame.minX + p.x, y: pin.frame.maxY - p.y) }
        func picture() -> CGRect { PinView.pictureFrame(in: pin.frame) }

        expect(view.imageRect.size == size, "图片就铺在视图里（\(view.imageRect.size)）")
        // 光标的切换（拉伸抓手、选字的 I 型）全靠 `mouseMoved`，而窗口不开这一项就一个移动事件都收不到 ——
        // 覆盖层一直开着，贴图窗口以前没开，贴图刚出现时光标就停在手型上，得先点一下（窗口成了 key）才好。
        expect(pin.acceptsMouseMovedEvents, "贴图窗口收鼠标移动事件")
        // 抓手各挂一个 tracking area：光标靠它，而它不要求窗口是 key —— 贴图是 `.nonactivatingPanel`，截完图
        // 激活权还给了上一个应用，所以刚贴出来的窗口既不是 key 也不在最前，`mouseMoved` 和 cursor rect 都靠不住。
        view.updateTrackingAreas()
        let expected = ResizeHandle.allCases.flatMap { view.gripRects($0) }.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        let tracked = view.testing_gripTrackingRects.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        expect(tracked == expected, "每个抓手的每一块都挂了 tracking area（\(tracked.count) 个）")

        // 八个手柄各在图片外面那 8pt 一圈里，方向对得上。
        for handle in ResizeHandle.allCases {
            // 从图片中心指向这个手柄，再往外挪 4pt —— 就是用户会按下去的那条窄带。
            let grip = handle.point(in: view.imageRect)
            let direction = CGPoint(x: grip.x - view.imageRect.midX, y: grip.y - view.imageRect.midY)
            let length = max(hypot(direction.x, direction.y), 1)
            let p = CGPoint(x: grip.x + direction.x / length * 4, y: grip.y + direction.y / length * 4)
            expect(view.resizeHandle(at: p) == handle, "\(handle) 这个方向抓得到（\(p)）")
        }

        // 角上沿边吃回来的那一段：用户瞄的是「图片的角」，落点却常常沿着某条边偏出去十几点，只给 8×8 的话
        // 那一按会变成移动贴图，四个角就成了「看起来不能拉」。这一段用的是边本来就有的带子，所以左、下那两
        // 条只有 10pt 宽的窄边也一样好抓 —— 不必去动贴图的留白。
        expect(view.resizeHandle(at: CGPoint(x: view.imageRect.minX - 4, y: view.imageRect.minY + 12)) == .topLeft,
               "左边那条带靠近左上角的头一段，算左上角")
        expect(view.resizeHandle(at: CGPoint(x: view.imageRect.minX - 4, y: view.imageRect.minY + 30)) == .left,
               "再往下就回到「左」")
        expect(view.resizeHandle(at: CGPoint(x: view.imageRect.maxX - 12, y: view.imageRect.maxY + 4)) == .bottomRight,
               "下面那条带靠近右下角的头一段，算右下角")
        expect(view.resizeHandle(at: CGPoint(x: view.imageRect.midX, y: view.imageRect.minY - 20)) == nil,
               "上面那条边的中段往外 20pt 不是手柄")

        // 图片里不是手柄 —— 那里是选字和拖动。但**紧贴边缘的那 6pt 算拉伸**：边框是一条细线，只认线上那一点
        // 等于要求用户精确瞄准；从图片里往外靠近边框也该抓得到（所有者提的）。
        expect(view.resizeHandle(at: CGPoint(x: view.imageRect.minX + 3, y: view.imageRect.midY)) == .left,
               "从图片里面靠近左边缘 3pt，算「左」这个抓手")
        expect(view.resizeHandle(at: CGPoint(x: view.imageRect.midX, y: view.imageRect.maxY - 3)) == .bottom,
               "从图片里面靠近下边缘 3pt，算「下」这个抓手")
        expect(view.resizeHandle(at: CGPoint(x: view.imageRect.minX + 12, y: view.imageRect.midY)) == nil,
               "再往里 12pt 就回到选字那条路")
        expect(view.resizeHandle(at: CGPoint(x: view.imageRect.midX, y: view.imageRect.midY)) == nil, "图片中间不是手柄")
        // 右边那 30pt 是留给按钮的，再往外仍然是拖动，不该被手柄吃掉。
        expect(view.resizeHandle(at: CGPoint(x: view.imageRect.maxX + 20, y: view.imageRect.midY)) == nil,
               "右边 20pt 之外不是手柄（那一圈还是拖动）")

        // 八个方向逐个拖一遍：每一个都要真的缩放，而且锚点（对面那个抓手）不动。角上出过一次问题
        // （鼠标移上去没反应、也拖不动），所以这里不抽查，全跑。
        for handle in ResizeHandle.allCases {
            // 从图片中心指向这个抓手，再往外挪 4pt —— 用户会按下去的那条窄带。
            let grip = handle.point(in: view.imageRect)
            let direction = CGPoint(x: grip.x - view.imageRect.midX, y: grip.y - view.imageRect.midY)
            let length = max(hypot(direction.x, direction.y), 1)
            let p = CGPoint(x: grip.x + direction.x / length * 4, y: grip.y + direction.y / length * 4)
            let before = picture()
            let anchor = screen(handle.anchor(in: view.imageRect))
            guard view.beginResize(at: p) else {
                expect(false, "\(handle) 按下去就该是一次拉伸")
                continue
            }
            let gripScreen = screen(p)
            view.resizeDrag(to: CGPoint(x: anchor.x + (gripScreen.x - anchor.x) * 1.25,
                                        y: anchor.y + (gripScreen.y - anchor.y) * 1.25))
            view.endResize()
            let after = picture()
            expect(abs(after.width - before.width * 1.25) < 1 && abs(after.height - before.height * 1.25) < 1,
                   "拖 \(handle) 到 1.25 倍：宽高一起变（\(before.size) → \(after.size)）")
            let anchorAfter = screen(handle.anchor(in: view.imageRect))
            // 允许 1pt：窗口 frame 落在整数像素上，锚点会跟着挪半个点。
            expect(hypot(anchorAfter.x - anchor.x, anchorAfter.y - anchor.y) < 1,
                   "拖 \(handle) 时对面那个点没动（\(anchor) → \(anchorAfter)）")
            pin.setZoom(1, flash: false)
        }

        // 右下角往外拖到 1.5 倍：宽高一起变，左上角纹丝不动。
        let before = picture()
        let anchor = CGPoint(x: before.minX, y: before.maxY)
        let corner = CGPoint(x: view.imageRect.maxX + 4, y: view.imageRect.maxY + 4)
        expect(view.beginResize(at: corner), "按住右下角")
        let cornerGrip = screen(corner)
        view.resizeDrag(to: CGPoint(x: anchor.x + (cornerGrip.x - anchor.x) * 1.5,
                                    y: anchor.y + (cornerGrip.y - anchor.y) * 1.5))
        view.endResize()
        let scaled = picture()
        expect(abs(scaled.width - before.width * 1.5) < 1 && abs(scaled.height - before.height * 1.5) < 1,
               "右下角拖到 1.5 倍：宽高一起变（\(before.size) → \(scaled.size)）")
        expect(abs(scaled.minX - anchor.x) < 0.5 && abs(scaled.maxY - anchor.y) < 0.5,
               "对角那个角没动（锚点 \(anchor)，现在是 \(CGPoint(x: scaled.minX, y: scaled.maxY))）")
        expect(abs(pin.zoom - 1.5) < 0.01, "缩放值也跟着走（\(pin.zoom)）")

        // 右边那条边缩到 0.5 倍：左边那条线和垂直中线都不动，纵向跟着等比。
        let edgeBefore = picture()
        let leftEdge = edgeBefore.minX
        let middle = edgeBefore.midY
        let edge = CGPoint(x: view.imageRect.maxX + 4, y: view.imageRect.midY)
        expect(view.beginResize(at: edge), "按住右边那条边")
        let edgeGrip = screen(edge)
        view.resizeDrag(to: CGPoint(x: leftEdge + (edgeGrip.x - leftEdge) * 0.5, y: middle))
        view.endResize()
        let edgeAfter = picture()
        expect(abs(edgeAfter.width - edgeBefore.width * 0.5) < 1 && abs(edgeAfter.height - edgeBefore.height * 0.5) < 1,
               "右边那条边拖到 0.5 倍：宽高一起变（\(edgeBefore.size) → \(edgeAfter.size)）")
        expect(abs(edgeAfter.minX - leftEdge) < 0.5 && abs(edgeAfter.midY - middle) < 0.5,
               "左边那条线和垂直中线都没动（\(edgeAfter)）")

        // 往外拖一定把指针拖到贴图外面：拉伸不能因此断掉。
        let zoomBefore = pin.zoom
        expect(view.beginResize(at: CGPoint(x: view.imageRect.maxX + 4, y: view.imageRect.midY)), "再按一次右边")
        view.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: CGPoint(x: -500, y: -500),
                                                      modifierFlags: [], timestamp: 0, windowNumber: pin.windowNumber,
                                                      context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!)
        view.resizeDrag(to: CGPoint(x: pin.frame.maxX + 60, y: pin.frame.midY))
        expect(pin.zoom > zoomBefore, "指针跑到贴图外面，拉伸照样继续（\(zoomBefore) → \(pin.zoom)）")
        view.endResize()

        write(render(view) ?? sampleRep(), "pin-resize.png")
        PinManager.shared.closeAll()
    }

    @MainActor static func pinButtons() async {
        // 摆放规则是纯函数，用假屏幕直接驱动，不必真把窗口拖到屏幕边上。
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let roomy = CGRect(x: 400, y: 300, width: 500, height: 300)
        let pastRightEdge = CGRect(x: 1200, y: 300, width: 500, height: 300)   // maxX = 1700，出了屏幕
        expect(PinView.showsButtons(picture: roomy, visible: screen), "图片右边有地方：按钮露出来")
        expect(!PinView.showsButtons(picture: pastRightEdge, visible: screen), "图片右边出了屏幕：按钮收起来，不乱跑")

        let frames = PinView.buttonFrames(picture: roomy)
        guard let rotateFrame = frames.rotate else { return expect(false, "高的贴图上有旋转按钮") }
        expect(frames.close.minX >= roomy.maxX && frames.tools.minY >= frames.close.maxY
               && rotateFrame.minY >= frames.tools.maxY && frames.handle.minY >= rotateFrame.maxY,
               "关闭在上、编辑、旋转、手柄依次往下，都在图片右侧外面（\(frames.close) \(frames.tools) \(rotateFrame) \(frames.handle)）")
        // 很矮的贴图（缩到 10% 就是）按钮要往上让，但不能让出窗口被裁掉。
        let short = CGRect(x: 0, y: 30, width: 200, height: 20)
        let shortFrames = PinView.buttonFrames(picture: short)
        expect(shortFrames.close.minY >= 0 && shortFrames.handle.minY >= shortFrames.close.maxY,
               "贴图很矮时按钮往上挤，也不出窗口（\(shortFrames.close) \(shortFrames.handle)）")
        // 留的位置要按**展开后**的点阵算：只按折叠的四个按钮留，矮贴图一 hover 就被窗口底部切掉半截。
        let fits = CGRect(x: 0, y: PinView.buttonInset, width: 200, height: 90)
        let fitsFrames = PinView.buttonFrames(picture: fits)
        expect(fitsFrames.handle.minY + PinHandleButton.expandedSize.height <= fits.maxY + PinView.borderInset,
               "90pt 高的贴图上，展开后的点阵落在窗口里（底 \(fitsFrames.handle.minY + PinHandleButton.expandedSize.height) ≤ \(fits.maxY + PinView.borderInset)）")
        // 再矮就连窗口本身都装不下（四个按钮 88 + 三条缝 12 + 展开的点阵再往下 16 + 阴影 4 = 120 > 窗口高）：
        // 按钮先挤到最上面，剩下的交给 `PinHandleButton.expandedFrame` 兜底（下面真窗口那一段验的就是它）。
        expect(shortFrames.close.minY == 0, "窗口实在装不下时，按钮先挤到最上面（\(shortFrames.close)）")

        // 贴图矮到装不下四颗时，旋转那颗先让位：点阵是「整张图全是字」时唯一能拖的地方，不能被窗口底边切掉。
        // 55pt：四颗要 100pt，窗口只有 95pt。右键菜单里还留着「逆时针旋转 90°」。
        let low = CGRect(x: 0, y: 30, width: 200, height: 55)
        let lowFrames = PinView.buttonFrames(picture: low)
        expect(lowFrames.rotate == nil, "55pt 高的贴图放不下四颗，旋转那颗让位")
        expect(lowFrames.handle.maxY <= low.maxY + PinView.borderInset + 0.5,
               "点阵整个落在窗口里（\(lowFrames.handle.maxY) ≤ \(low.maxY + PinView.borderInset)）")
        // 再矮连三颗都放不下：点阵往里压，宁可压在上一颗上面，也要抓得到。
        let tinier = CGRect(x: 0, y: 30, width: 200, height: 20)
        let tinierFrames = PinView.buttonFrames(picture: tinier)
        expect(tinierFrames.rotate == nil
               && tinierFrames.handle.maxY <= tinier.maxY + PinView.borderInset + 0.5,
               "20pt 高的贴图也把点阵压在窗口里（\(tinierFrames.handle)）")

        // 真窗口：离屏的贴图走默认那一列，按钮得落在图片外面。
        let pin = PinManager.shared.pin(sampleRep(CGSize(width: 420, height: 110)),
                                        frame: CGRect(x: -4000, y: -4000, width: 420, height: 110))
        let view = pin.testing_view
        let close = view.testing_closeButton
        let tools = view.testing_toolsButton
        let handle = view.testing_handleButton

        func mouse(_ type: NSEvent.EventType, in target: NSView, at p: CGPoint) -> NSEvent {
            let location = target.convert(p, to: nil)
            // Enter and exit events have their own constructor; mouseEvent(with:) blocks on them.
            if type == .mouseEntered || type == .mouseExited {
                return NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                              windowNumber: pin.windowNumber, context: nil, eventNumber: 0,
                                              trackingNumber: 0, userData: nil)!
            }
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                      windowNumber: pin.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let onPicture = CGPoint(x: 60, y: view.bounds.midY)
        // 图片外面、按钮区外面（左边那圈边框）：真正「离开图片」的点。
        let offPicture = CGPoint(x: view.imageRect.minX - 4, y: view.imageRect.midY)
        expect(close.isHidden && tools.isHidden && handle.isHidden, "没把鼠标移到图片上时，三个按钮不显示")
        view.mouseEntered(with: mouse(.mouseEntered, in: view, at: onPicture))
        expect(!close.isHidden && !tools.isHidden && !handle.isHidden, "鼠标移到图片上，三个按钮出现")
        expect(!close.frame.intersects(view.imageRect) && !tools.frame.intersects(view.imageRect)
               && !handle.frame.intersects(view.imageRect),
               "三个按钮都不压在图片上（图片 \(view.imageRect)）")
        expect(tools.frame.minY >= close.frame.maxY && handle.frame.minY >= tools.frame.maxY,
               "编辑按钮夹在关闭和手柄中间")

        // 悬停时图案轻轻放大，指针移开后缩回去。
        close.mouseEntered(with: mouse(.mouseEntered, in: close, at: CGPoint(x: close.bounds.midX, y: close.bounds.midY)))
        try? await Task.sleep(for: .milliseconds(220))
        expect(close.testing_glyphScale > 1.05, "悬停时按钮里的图案放大了（\(close.testing_glyphScale)）")
        close.mouseExited(with: mouse(.mouseExited, in: close, at: CGPoint(x: -20, y: -20)))
        try? await Task.sleep(for: .milliseconds(220))
        expect(abs(close.testing_glyphScale - 1) < 0.01, "移开后图案回到原大小（\(close.testing_glyphScale)）")

        // 手柄：鼠标移上去就展开成 2 列 3 行、更好抓的圆点，等着被拖。
        let folded = handle.frame
        let centre = CGPoint(x: handle.bounds.midX, y: handle.bounds.midY)
        handle.mouseEntered(with: mouse(.mouseEntered, in: handle, at: centre))
        expect(handle.isExpanded && handle.frame.height > folded.height && handle.frame.contains(folded),
               "鼠标移到手柄上就展开（\(folded.size) → \(handle.frame.size)）")
        write(render(view) ?? sampleRep(), "pin-handle.png")

        // 按住手柄就能拖动贴图 —— 这是它存在的理由：截图里全是文字时没有空白处下手。
        let press = NSEvent.mouseLocation
        handle.mouseDown(with: mouse(.leftMouseDown, in: handle, at: centre))
        handle.mouseDragged(with: mouse(.leftMouseDragged, in: handle, at: centre))
        let origin = pin.frame.origin
        view.drag(to: CGPoint(x: press.x + 30, y: press.y - 20))
        expect(pin.frame.origin == CGPoint(x: origin.x + 30, y: origin.y - 20),
               "按住手柄拖动会移动贴图（\(origin) → \(pin.frame.origin)）")
        handle.mouseUp(with: mouse(.leftMouseUp, in: handle, at: centre))
        expect(handle.isExpanded, "拖动时手柄保持展开")

        handle.mouseExited(with: mouse(.mouseExited, in: handle, at: CGPoint(x: -40, y: -40)))
        expect(!handle.isExpanded && handle.frame == folded, "鼠标离开手柄就收回去（\(handle.frame)）")

        view.mouseExited(with: mouse(.mouseExited, in: view, at: CGPoint(x: -40, y: -40)))
        expect(close.isHidden && tools.isHidden && handle.isHidden, "鼠标离开贴图，三个按钮跟着藏起来")

        // 从图片走到边框上（还在贴图里）：按钮也该收起来 —— 它们只在指针位于图片上时出来；但「指针在贴图
        // 里」这个状态不能因此被清掉（抓手自己的 exited 曾经把这个搞混过）。
        view.mouseEntered(with: mouse(.mouseEntered, in: view, at: onPicture))
        view.mouseExited(with: mouse(.mouseExited, in: view, at: offPicture))
        expect(view.testing_pointerInside, "走到边框上仍然算在贴图里（指针没离开窗口）")
        expect(close.isHidden && tools.isHidden && handle.isHidden, "但指针不在图片上了，按钮收起来")

        // 最容易做错的一条：按钮在图片**外面**，而且和图片之间、按钮彼此之间各有一条缝。指针跨过这些缝
        // 的一瞬间既不在图片上、也不在按钮上——只按按钮算，指针一移过去按钮就会消失，那就永远点不到了。
        // 所以**整条按钮区**（从图片右边缘到窗口右边缘、三个按钮连同缝）都算悬停。
        let gapToButtons = CGPoint(x: view.imageRect.maxX + 2, y: close.frame.midY)
        let gapBetweenButtons = CGPoint(x: close.frame.midX, y: close.frame.maxY + 2)
        let gapAboveHandle = CGPoint(x: tools.frame.midX, y: tools.frame.maxY + 2)
        view.mouseEntered(with: mouse(.mouseEntered, in: view, at: onPicture))
        view.mouseExited(with: mouse(.mouseExited, in: view, at: gapToButtons))
        expect(!close.isHidden && !tools.isHidden && !handle.isHidden, "跨过图片与按钮之间的缝，三个按钮仍然在")
        view.mouseExited(with: mouse(.mouseExited, in: view, at: gapBetweenButtons))
        expect(!close.isHidden && !tools.isHidden && !handle.isHidden, "跨过关闭与编辑之间的缝，三个按钮仍然在")
        view.mouseExited(with: mouse(.mouseExited, in: view, at: gapAboveHandle))
        expect(!close.isHidden && !tools.isHidden && !handle.isHidden, "跨过编辑与手柄之间的缝，三个按钮仍然在")
        view.mouseExited(with: mouse(.mouseExited, in: view, at: offPicture))
        expect(close.isHidden && tools.isHidden && handle.isHidden, "指针离开图片、也离开按钮区，按钮才藏起来")

        // 快拖的时候窗口永远比指针慢一两帧，指针会真的跑到贴图外面 —— 手柄离窗口右边只有 8pt，很容易出去。
        // 而拖拽是从点阵上按下去的：把这个视图藏起来就等于当场掐断拖拽，用户看到的就是「图停在半路」。
        view.mouseEntered(with: mouse(.mouseEntered, in: view, at: CGPoint(x: 60, y: view.bounds.midY)))
        handle.mouseEntered(with: mouse(.mouseEntered, in: handle, at: centre))
        let quickPress = NSEvent.mouseLocation
        handle.mouseDown(with: mouse(.leftMouseDown, in: handle, at: centre))
        let quickOrigin = pin.frame.origin
        view.mouseExited(with: mouse(.mouseExited, in: view, at: CGPoint(x: -40, y: -40)))
        handle.mouseExited(with: mouse(.mouseExited, in: handle, at: CGPoint(x: -40, y: -40)))
        expect(!view.testing_pointerInside, "指针跑到贴图外面了")
        expect(!handle.isHidden && handle.isExpanded, "拖动中的点阵不藏、也不收回去")
        view.drag(to: CGPoint(x: quickPress.x + 50, y: quickPress.y - 30))
        expect(pin.frame.origin == CGPoint(x: quickOrigin.x + 50, y: quickOrigin.y - 30),
               "指针出了贴图，这回贴图照样跟着走（\(quickOrigin) → \(pin.frame.origin)）")
        handle.mouseUp(with: mouse(.leftMouseUp, in: handle, at: centre))
        expect(handle.isHidden, "松手之后，指针不在图片上，按钮就藏起来")

        // 矮贴图（比如只截到一行字）上真展开一次：整块点阵必须留在窗口里。这些 handler 不看事件里的窗口号，
        // 所以可以借用上面那套构造器。
        let shortPin = PinManager.shared.pin(sampleRep(CGSize(width: 420, height: 30)),
                                             frame: CGRect(x: -4000, y: -4000, width: 420, height: 30))
        let shortView = shortPin.testing_view
        let shortHandle = shortView.testing_handleButton
        shortView.mouseEntered(with: mouse(.mouseEntered, in: shortView, at: CGPoint(x: 60, y: shortView.bounds.midY)))
        shortHandle.mouseEntered(with: mouse(.mouseEntered, in: shortHandle,
                                             at: CGPoint(x: shortHandle.bounds.midX, y: shortHandle.bounds.midY)))
        expect(shortHandle.isExpanded, "矮贴图上光标移到手柄上照样展开")
        expect(shortHandle.frame.height == PinHandleButton.expandedSize.height, "展开后是完整的大小，没有被压扁")
        expect(shortHandle.frame.maxY <= shortView.bounds.height,
               "展开后整块都在窗口里，没有被底部切掉（底 \(shortHandle.frame.maxY) ≤ 窗口高 \(shortView.bounds.height)）")
        expect(shortView.testing_rotateButton.isHidden, "30pt 的贴图不摆旋转按钮")
        write(render(shortView) ?? sampleRep(), "pin-handle-short.png")

        // 55pt：就是用户报「点阵只剩半截」的那个高度段——旋转让位，剩下的三颗连点阵一起完整落进窗口。
        let lowPin = PinManager.shared.pin(sampleRep(CGSize(width: 420, height: 55)),
                                           frame: CGRect(x: -4000, y: -4000, width: 420, height: 55))
        let lowView = lowPin.testing_view
        lowView.mouseEntered(with: mouse(.mouseEntered, in: lowView, at: CGPoint(x: 60, y: lowView.bounds.midY)))
        expect(lowView.testing_rotateButton.isHidden, "55pt 的贴图不摆旋转按钮")
        expect(!lowView.testing_closeButton.isHidden && !lowView.testing_toolsButton.isHidden
               && !lowView.testing_handleButton.isHidden, "其余三颗照常出现")
        expect(lowView.testing_handleButton.frame.maxY <= lowView.bounds.height + 0.5,
               "点阵完整地在窗口里（\(lowView.testing_handleButton.frame) / 窗口高 \(lowView.bounds.height)）")
        write(render(lowView) ?? sampleRep(), "pin-buttons-short.png")
        PinManager.shared.closeAll()
    }

    /// 分段：拿合成出来的行几何直接驱动 `TextBlockBuilder`（不开窗口、不跑 Vision），逐条验规则，
    /// 并把"哪几行被并成一段"画成一张对照图。
    @MainActor static func textBlocks() async {
        func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, word: CGFloat? = nil) -> OCRLine {
            OCRLine(text: text, rect: CGRect(x: x, y: y, width: w, height: 14), firstWordWidth: word)
        }
        // 一页编号说明，就是你截图里那种排版：续行缩进一个标记宽，有的断在连字符上，有的顶到版心。
        let page: [OCRLine] = [
            line("1. Identify endpoint references: Locate all instances of gemini-omni-", 10, 10, 380),
            line("flash-preview within your codebase and configuration files", 24, 28, 340),
            line("2. Update API endpoints: Update your API requests to point to", 10, 52, 380),
            line("gemini-1.1-flash-preview", 24, 70, 160),
            line("3. Validate integrations: Test and verify application performance on the new", 10, 94, 390),
            line("endpoint", 90, 112, 70, word: 70),
            line("A short line", 10, 140, 100),
            line("far away from it", 90, 158, 90, word: 30),
        ]
        let blocks = TextBlockBuilder.group(page)
        expect(blocks.count == 5, "三条编号项各一段，最后那两行短行各自一段（\(blocks.count) 段）")
        expect(blocks[0].text.hasSuffix("flash-preview within your codebase and configuration files"),
               "缩进的续行并回它那一条（\(blocks[0].text.suffix(40))）")
        expect(blocks[0].text.contains("gemini-omniflash-preview"),
               "断在连字符上的词拼回一个（\(blocks[0].text.prefix(40))…）")
        expect(blocks[1].text == "2. Update API endpoints: Update your API requests to point to gemini-1.1-flash-preview",
               "第二条整条是一段（\(blocks[1].text)）")
        expect(blocks[2].text.hasSuffix("the new endpoint"),
               "顶到版心那一行也被认成续行（第 4 条规则：首词放不下）")
        expect(blocks[3].lines.count == 1 && blocks[4].lines.count == 1,
               "上一行没写满时，下一行不硬并进来（\(blocks[3].text) / \(blocks[4].text)）")

        // 中文：两条圆点各自成段（列表标记一律另起），续行不插空格。
        let chinese = TextBlockBuilder.group([
            line("• 支持长截图和滚动拼接，", 10, 10, 300),
            line("结果可以复制、保存或贴图", 24, 28, 260),
            line("• 支持截图翻译，", 10, 52, 300),
            line("识别到的文字直接画回原位", 24, 70, 260),
        ])
        expect(chinese.count == 2, "两条圆点各自成段（\(chinese.count) 段）")
        expect(chinese[0].text == "• 支持长截图和滚动拼接，结果可以复制、保存或贴图",
               "中文续行并进来、中间不加空格（\(chinese[0].text)）")

        // 行距是拿这一页自己的行距比的：1.8 倍行距的正文也要并成一段（旧的 0.8 倍行高会切成三段）。
        let airy = TextBlockBuilder.group([
            line("Airy paragraph first line", 10, 10, 300),
            line("Airy paragraph second line", 10, 38, 300),
            line("Airy paragraph third line", 10, 66, 300),
            line("A new paragraph after a bigger gap", 10, 100, 300),
        ])
        expect(airy.count == 2, "1.8 倍行距的正文并成一段，间距更大的新段落照旧断开（\(airy.count) 段）")

        // 列表项的续行按量出来的标记宽度对齐：标记 30pt 宽时，34pt 的缩进算它的续行；
        // 量不到标记宽度时不敢这么并（那 34pt 就超了 1.6 倍行高的兜底）。
        func listContinuation(marker: CGFloat?) -> Int {
            var first = line("10. Install the app and open it once so the menu", 10, 10, 380)
            first.firstWordWidth = marker
            return TextBlockBuilder.group([first, line("Icon appears in the menu bar bar", 44, 28, 200)]).count
        }
        expect(listContinuation(marker: 30) == 1, "缩进正好是标记宽 + 一个空格 → 续行")
        expect(listContinuation(marker: nil) == 2, "量不到标记宽度时不敢这么并")

        // 对照图：同一段的行同一种颜色，右边写出合并后的文本。（画布按行坐标来，所以要显式铺一个 flipped
        // 上下文，不然整张图上下颠倒。）
        let size = CGSize(width: 900, height: 420)
        guard let cg = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
                                 bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        cg.scaleBy(x: 2, y: 2)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        let palette: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal]
        for (index, block) in blocks.enumerated() {
            let colour = palette[index % palette.count]
            for textLine in block.lines {
                colour.withAlphaComponent(0.16).setFill()
                textLine.rect.fill()
                colour.setStroke()
                NSBezierPath(rect: textLine.rect).stroke()
                NSAttributedString(string: textLine.text, attributes: [
                    .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black,
                ]).draw(at: CGPoint(x: textLine.rect.minX + 2, y: textLine.rect.minY + 2))
            }
            NSAttributedString(string: "#\(index)  " + block.text, attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: colour,
            ]).draw(with: CGRect(x: 430, y: block.rect.minY, width: 460, height: 40), options: [.usesLineFragmentOrigin])
        }
        NSGraphicsContext.restoreGraphicsState()
        if let image = cg.makeImage() {
            let rep = NSBitmapImageRep(cgImage: image)
            rep.size = size
            write(rep, "text-blocks.png")
        }
    }

    /// 两条分段路径的对照：Apple 的文档识别（macOS 26 起）和我们自己的阶梯。同一条编号列表两条路应当给出
    /// 同样的段落；带表格的一页上，文档识别**每格独立**，而阶梯会跨格并——这正是默认值切过去的原因。
    @MainActor static func documentSegments() async {
        guard #available(macOS 26.0, *) else {
            return expect(true, "这台系统没有文档识别（macOS 26 起才有），只跑得了阶梯那条路")
        }
        func page(_ size: CGSize, _ paint: (CGContext) -> Void) -> CGImage? {
            guard let ctx = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.scaleBy(x: 2, y: 2)
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSColor.white.setFill()
            CGRect(origin: .zero, size: size).fill()
            paint(ctx)
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()
        }
        func draw(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat = 14) {
            NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black,
            ]).draw(at: CGPoint(x: x, y: y))
        }

        // 一、编号列表：两条路应当**完全一致**。
        let list = page(CGSize(width: 520, height: 130)) { _ in
            draw("1. Identify endpoint references: Locate all instances of gemini-omni-", 20, 20)
            draw("flash-preview within your codebase and configuration files", 34, 40)
            draw("2. Update API endpoints: Update your API requests to point to", 20, 70)
            draw("gemini-1.1-flash-preview", 34, 90)
        }
        guard let list else { return expect(false, "画列表样张") }
        let bounds = CGRect(origin: .zero, size: CGSize(width: 520, height: 130))
        let byLines = (try? await TextRecognizer.recognize(list, selection: bounds, segmentation: .lines))?.translatedBlocks ?? []
        let byDocument = (try? await TextRecognizer.recognize(list, selection: bounds, segmentation: .document))?.translatedBlocks ?? []
        expect(byLines.count == 2, "阶梯：两条编号各一段（\(byLines.count)）")
        expect(byDocument.count == 2, "文档识别：两条编号各一段（\(byDocument.count)）")
        if byLines.map(\.text) != byDocument.map(\.text) {
            print("   阶梯：  \(byLines.map(\.text))")
            print("   文档：  \(byDocument.map(\.text))")
        }
        expect(byLines.map(\.text) == byDocument.map(\.text), "两条路给出的段落文本一致")

        // 二、表格：文档识别每格独立，阶梯会跨格并（下面把它打出来，供对照）。
        let table = page(CGSize(width: 520, height: 120)) { _ in
            for (row, cells) in [["Setting", "Default", "Where"],
                                 ["Engine", "Free", "Settings > Translate"],
                                 ["Corner", "8 pt", "Settings > Output"]].enumerated() {
                for (column, cell) in cells.enumerated() { draw(cell, 20 + CGFloat(column) * 170, 20 + CGFloat(row) * 30) }
            }
        }
        guard let table else { return expect(false, "画表格样张") }
        let tableBounds = CGRect(origin: .zero, size: CGSize(width: 520, height: 120))
        // 关键词要互不包含（"Settings" 里就含 "Setting"），否则一条块里数出两个"格子"来是假警报。
        let cells = ["Engine", "Free", "8 pt", "Corner", "Translate", "Output"]
        let documentTable = (try? await TextRecognizer.recognize(table, selection: tableBounds, segmentation: .document))?.translatedBlocks ?? []
        expect(!documentTable.isEmpty, "文档识别认出了表格里的文字（\(documentTable.count) 段）")
        for block in documentTable {
            let hits = cells.filter { block.text.contains($0) }.count
            expect(hits <= 1, "文档识别每格独立，一段里不该出现两个格子的词（\(block.text)）")
        }
        let linesTable = (try? await TextRecognizer.recognize(table, selection: tableBounds, segmentation: .lines))?.translatedBlocks ?? []
        print("   （阶梯那条路在表格上给出 \(linesTable.count) 段：）")
        for block in linesTable { print("      \(block.text)") }
    }

    /// 截图翻译的退出方式：选区旁的「关闭」按钮，和「关闭截图翻译」这个设置（无操作 / 单击外侧 / 双击外侧）。
    @MainActor static func translateDismiss() async {
        let previous = Settings.shared.dismissTranslationCapture
        defer { Settings.shared.dismissTranslationCapture = previous }

        let box = CGRect(x: 80, y: 60, width: 300, height: 200)
        func harness(autoTranslate: Bool) -> CaptureHarness {
            let h = CaptureHarness(lines: ["Settings", "Automatically check for updates"])
            // 自检不联网：翻译这一路换成桩。
            h.view.translate = { items, _ in Dictionary(uniqueKeysWithValues: items.map { ($0.id, "译文 \($0.id)") }) }
            h.view.autoTranslate = autoTranslate
            h.select(box)
            return h
        }
        func clickOutside(_ h: CaptureHarness, clicks: Int) -> Bool {
            let p = CGPoint(x: box.maxX + 120, y: box.maxY + 80)
            h.view.mouseDown(with: h.mouse(.leftMouseDown, p, clicks: clicks))
            h.view.mouseUp(with: h.mouse(.leftMouseUp, p, clicks: clicks))
            return h.view.testing_finished
        }

        // 一、按钮：截图翻译 时摆在选区外面；普通截图里根本不摆（工具栏本来就有 ✕）。
        let translated = harness(autoTranslate: true)
        guard let frame = translated.view.testing_closeButtonFrame else {
            return expect(false, "截图翻译时选区旁有「关闭」按钮")
        }
        expect(!frame.intersects(box), "按钮在选区外面（\(frame)）")
        expect(translated.view.bounds.contains(frame), "按钮在画面里（\(frame)）")
        expect(harness(autoTranslate: false).view.testing_closeButtonFrame == nil, "普通截图不摆这个按钮")

        // 三颗按钮竖着排：关闭 / 钉住 / 复制，同一列、同一个大小（贴图那一列也是这么排的）。
        guard let pinFrame = translated.view.testing_translatePinFrame,
              let copyFrame = translated.view.testing_copyButtonFrame else {
            return expect(false, "截图翻译时还有「钉住」和「复制到剪贴板」两个按钮")
        }
        expect(abs(pinFrame.minX - frame.minX) < 0.5 && abs(pinFrame.width - frame.width) < 0.5,
               "钉住和关闭同一列、同宽（\(pinFrame) vs \(frame)）")
        expect(pinFrame.minY >= frame.maxY, "钉住在关闭按钮下面（\(pinFrame)）")
        expect(abs(copyFrame.minX - frame.minX) < 0.5 && abs(copyFrame.width - frame.width) < 0.5,
               "复制按钮和它们同一列、同宽（\(copyFrame)）")
        expect(copyFrame.minY >= pinFrame.maxY, "复制按钮在钉住下面（\(copyFrame)）")
        expect(harness(autoTranslate: false).view.testing_translatePinFrame == nil, "普通截图没有钉住按钮")
        expect(harness(autoTranslate: false).view.testing_copyButtonFrame == nil, "普通截图也不摆复制按钮")

        // 选区贴着屏幕右边缘时退回选区里面——它不能像贴图那两个按钮那样直接消失。
        let flush = CaptureHarness(lines: ["Settings"])
        flush.view.autoTranslate = true
        flush.select(CGRect(x: flush.view.bounds.maxX - 200, y: 40, width: 200, height: 160))
        let flushFrames = [flush.view.testing_closeButtonFrame, flush.view.testing_translatePinFrame,
                           flush.view.testing_copyButtonFrame]
        expect(flushFrames.allSatisfy { $0.map { flush.view.bounds.contains($0) } == true },
               "贴着右边缘时三颗按钮都退回里面，仍在画面内（\(flushFrames)）")

        // 二、三种设置。`clickCount` 是 AppKit 给的，双击那条不需要自己加延时。
        Settings.shared.dismissTranslationCapture = .none
        expect(!clickOutside(harness(autoTranslate: true), clicks: 1), "「无操作」：单击外侧什么都不做")
        expect(!clickOutside(harness(autoTranslate: true), clicks: 2), "「无操作」：双击也一样")

        Settings.shared.dismissTranslationCapture = .singleClick
        expect(clickOutside(harness(autoTranslate: true), clicks: 1), "「单击截图外侧」：一下就退出")
        // 普通截图现在点外面也退出，但那是它自己的规矩（见 `click-outside-cancel`），不是这个设置在管它。
        expect(clickOutside(harness(autoTranslate: false), clicks: 1), "普通截图点外面退出，走的是截图自己的规矩")

        Settings.shared.dismissTranslationCapture = .doubleClick
        expect(!clickOutside(harness(autoTranslate: true), clicks: 1), "「双击截图外侧」：第一下不关，等着第二下")
        expect(clickOutside(harness(autoTranslate: true), clicks: 2), "第二下才退出")

        // 三、两个既有行为不许被带坏：点选区里面不算「外侧」；外侧拖拽也不能被当成关闭（译文在屏幕上时
        // 外侧拖拽本来就是空操作，只在还没有译文时才会重新框选——这条不在这里验）。
        Settings.shared.dismissTranslationCapture = .singleClick
        let inside = harness(autoTranslate: true)
        let middle = CGPoint(x: box.midX, y: box.midY)
        inside.view.mouseDown(with: inside.mouse(.leftMouseDown, middle, clicks: 1))
        expect(!inside.view.testing_finished, "点选区里面不关（那里是移动选区/双击置顶的地盘）")
        inside.view.mouseUp(with: inside.mouse(.leftMouseUp, middle, clicks: 1))

        let dragged = harness(autoTranslate: true)
        dragged.drag(CGPoint(x: 520, y: 420), CGPoint(x: 640, y: 480))
        expect(!dragged.view.testing_finished, "外侧拖拽不是关闭（拖拽还从同一个 mouse down 开始）")

        // 四、关闭按钮自己：与设置无关，点一下就退出。复制按钮走的是 ↩ 那条路——真的把图放进剪贴板。
        Settings.shared.dismissTranslationCapture = .none
        let button = harness(autoTranslate: true)
        button.view.testing_pressCloseButton()
        expect(button.view.testing_finished, "点「关闭」按钮照样退出，设置只管外侧点击")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copying = harness(autoTranslate: true)
        copying.view.testing_pressCopyButton()
        expect(copying.view.testing_output == .copy, "复制按钮走的是复制那条路（\(copying.view.testing_output as Any)）")
        expect(pasteboard.data(forType: .tiff) != nil || pasteboard.canReadItem(withDataConformingToTypes: [NSPasteboard.PasteboardType.png.rawValue]),
               "图进了剪贴板（\(pasteboard.types ?? [])）")
        write(copying.screenshot() ?? sampleRep(), "translate-dismiss.png")
    }

    /// 截图翻译 的钉住：夹在关闭和复制中间，按下先把图钉立起来，动画结束后才把**当前画面**（译文或原文）
    /// 贴到屏幕上并结束截图。`exportImage()` 用的是 `visibleTranslation`，所以切到原文时钉的就是原文。
    @MainActor static func translatePin() async {
        let rect = CGRect(x: 60, y: 60, width: 420, height: 110)

        func translatedHarness() -> CaptureHarness {
            let h = CaptureHarness(lines: ["Settings", "Automatically check for updates"])
            h.view.autoTranslate = true
            h.view.translate = { items, _ in
                Dictionary(uniqueKeysWithValues: items.map { ($0.id, "译文 \($0.id)") })
            }
            h.select(rect)
            return h
        }
        func waitForTranslation(_ h: CaptureHarness) async {
            for _ in 0..<600 where h.view.testing_translation.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        }
        func waitForPin(_ before: Int) async -> PinWindow? {
            for _ in 0..<80 where PinManager.shared.pins.count == before { try? await Task.sleep(for: .milliseconds(50)) }
            return PinManager.shared.pins.count > before ? PinManager.shared.pins.last : nil
        }

        let h = translatedHarness()
        await waitForTranslation(h)
        expect(!h.view.testing_translation.isEmpty, "先翻出译文")
        expect(!h.view.testing_translatePinPinned, "没按时图钉是躺着的")

        // 悬停时图案轻轻放大再缩回去，和旁边两颗 GlyphButton 一样（0.12 秒 ease-out，只放大图案）。
        expect(abs(h.view.testing_translatePinGlyphScale - 1) < 0.01,
               "默认是原大小（\(h.view.testing_translatePinGlyphScale)）")
        h.view.testing_hoverTranslatePin(true)
        try? await Task.sleep(for: .milliseconds(220))
        expect(h.view.testing_translatePinGlyphScale > 1.05,
               "悬停时图钉放大了（\(h.view.testing_translatePinGlyphScale)）")
        h.view.testing_hoverTranslatePin(false)
        try? await Task.sleep(for: .milliseconds(220))
        expect(abs(h.view.testing_translatePinGlyphScale - 1) < 0.01,
               "移开后回到原大小（\(h.view.testing_translatePinGlyphScale)）")
        write(h.screenshot() ?? sampleRep(), "translate-pin-before.png")

        // 钉的是按下那一刻屏幕上那一版：译文。
        let expected = h.view.exportImage()
        let before = PinManager.shared.pins.count
        h.view.testing_pressTranslatePin()
        expect(h.view.testing_translatePinPinned, "按下后图钉立起来")
        expect(h.view.testing_translatePinAnimating, "立起来是动画，不是换图")
        expect(PinManager.shared.pins.count == before, "动画没跑完之前截图还在")
        guard let pin = await waitForPin(before) else { return expect(false, "动画结束后钉出贴图") }
        expect(pin.rep.tiffRepresentation == expected?.tiffRepresentation,
               "钉住的是当时屏幕上的那一版（译文），大小 \(pin.rep.size)")
        pin.closePin()

        // 切到「原文」之后再钉：钉的是原文，不是刚才那份译文。
        let original = translatedHarness()
        await waitForTranslation(original)
        original.key("y", code: 16)
        let originalExpected = original.view.exportImage()
        let pinsBefore = PinManager.shared.pins.count
        original.view.testing_pressTranslatePin()
        guard let originalPin = await waitForPin(pinsBefore) else { return expect(false, "原文也钉得出来") }
        expect(originalPin.rep.tiffRepresentation == originalExpected?.tiffRepresentation,
               "切到原文后钉的是原文，大小 \(originalPin.rep.size)")
        originalPin.closePin()

        write(h.screenshot() ?? sampleRep(), "translate-pin.png")
    }

    /// 选区外面点一下：退出这次截图，而不是把整块屏幕当成新选区。拖出去仍然是重新框选，截图翻译自己的
    /// 「关闭截图翻译」设置也照旧说了算。
    @MainActor static func clickOutsideCancel() async {
        let box = CGRect(x: 100, y: 100, width: 400, height: 250)
        func harness() -> CaptureHarness {
            let h = CaptureHarness(size: CGSize(width: 900, height: 600))
            h.select(box)
            return h
        }

        let click = harness()
        click.click(CGPoint(x: 700, y: 480))
        expect(click.view.testing_finished, "点选区外面就退出截图")

        let inside = harness()
        inside.click(CGPoint(x: 200, y: 200))
        expect(!inside.view.testing_finished, "点选区里面不退出")

        let drag = harness()
        let fresh = CGRect(x: 560, y: 400, width: 180, height: 120)
        drag.select(fresh)
        expect(!drag.view.testing_finished, "从选区外面拖出去是重新框选，不退出")
        expect(drag.view.testing_selection == fresh,
               "新的选框就是拖出来的那块（\(drag.view.testing_selection as Any)）")

        let annotated = harness()
        annotated.key("1", code: 18)
        annotated.drag(CGPoint(x: 150, y: 150), CGPoint(x: 300, y: 250))
        expect(annotated.view.testing_items.count == 1, "先画一个框")
        annotated.click(CGPoint(x: 720, y: 500))
        expect(annotated.view.testing_finished, "有标注时点外面同样退出")

        // 截图翻译：它有自己的「关闭截图翻译」设置，不能被这条覆盖。
        let previous = Settings.shared.dismissTranslationCapture
        defer { Settings.shared.dismissTranslationCapture = previous }
        Settings.shared.dismissTranslationCapture = .none
        let translated = CaptureHarness(lines: ["Settings"])
        translated.view.translate = { items, _ in
            Dictionary(uniqueKeysWithValues: items.map { ($0.id, "译文 \($0.id)") })
        }
        translated.view.autoTranslate = true
        translated.select(box)
        translated.click(CGPoint(x: 700, y: 480))
        expect(!translated.view.testing_finished, "截图翻译设成「无操作」时，点外面还是不动")
    }

    /// 高亮工具：框内保持原来的色彩和亮度，框外压暗；同一张图能反复框选，也能切成椭圆。
    @MainActor static func highlight() async {
        // 对照：普通标注只重画自己那一块，高亮必须整块重画（它把遮罩铺满整张图）。
        // 只重画一圈的话，屏幕上看到的就是一条半透明粗边框，而不是高亮——这个 bug 出过一次。
        let plain = CaptureHarness()
        plain.select(CGRect(x: 20, y: 20, width: 400, height: 300))
        plain.key("1", code: 18)
        plain.drag(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 180))
        expect(plain.view.testing_lastRedraw != plain.view.bounds,
               "普通标注照旧只重画自己那一块（\(plain.view.testing_lastRedraw as Any)）")

        let selection = CGRect(x: 20, y: 20, width: 760, height: 460)
        let h = CaptureHarness()
        h.select(selection)
        h.key("8", code: 28)
        expect(h.view.testing_tool == .highlight, "按 8 选到高亮工具")

        /// 导出图里的颜色（导出的是选区那块，坐标要减去选区原点）。
        func exported(_ p: CGPoint) -> NSColor? {
            h.export()?.color(atPoint: CGPoint(x: p.x - selection.minX, y: p.y - selection.minY))?.usingColorSpace(.sRGB)
        }

        // 第一块压在深色横条上（0.15/0.17/0.2），压暗与否一眼能分出来
        h.drag(CGPoint(x: 100, y: 290), CGPoint(x: 300, y: 350))
        expect(h.view.testing_items.count == 1 && h.view.testing_items[0].shape.isHighlight, "拖出一块高亮")
        expect(h.view.testing_lastRedraw == h.view.bounds, "高亮让整块重绘（\(h.view.testing_lastRedraw as Any)）")
        expect(StyleMemory.highlightOpacity == 0.5, "默认不透明度是 50%")

        let inside = CGPoint(x: 200, y: 320)
        let outside = CGPoint(x: 640, y: 400)
        guard let bright = exported(inside), let dark = exported(outside),
              let originalInside = h.original(inside), let originalOutside = h.original(outside)
        else { return expect(false, "取到像素") }
        expect(abs(bright.redComponent - originalInside.redComponent) < 0.01
               && abs(bright.greenComponent - originalInside.greenComponent) < 0.01,
               "框内保持原来的色彩和亮度（\(originalInside) → \(bright)）")
        expect(dark.redComponent < originalOutside.redComponent * 0.8 && dark.redComponent > originalOutside.redComponent * 0.1,
               "框外被压暗（\(originalOutside) → \(dark)）")

        // 两端是准的：不透明度最低就不遮，最高就是纯黑遮罩；中间随滑块单调变暗。
        // （中间值不写死“正好减半”：这条绘制链路带色彩管理，混出来的数值不等于按分量相乘。）
        h.view.testing_applyStyle(.highlightOpacity(0))
        expect(abs(exported(outside)!.redComponent - originalOutside.redComponent) < 0.01, "不透明度拉到最低就等于没遮")
        h.view.testing_applyStyle(.highlightOpacity(1))
        expect(exported(outside)!.redComponent < 0.02, "拉到最高就是纯黑遮罩（\(exported(outside)!)）")
        h.view.testing_applyStyle(.highlightOpacity(0.8))
        let heavier = exported(outside)!
        expect(heavier.redComponent < dark.redComponent - 0.05,
               "调高不透明度遮罩更重（50% → \(dark.redComponent)，80% → \(heavier.redComponent)）")
        h.view.testing_applyStyle(.highlightOpacity(0.5))

        // 第二块：反复框选，两块都得是原样
        h.drag(CGPoint(x: 400, y: 100), CGPoint(x: 600, y: 200))
        expect(h.view.testing_items.count == 2, "同一张图能框第二块")
        guard let firstAgain = exported(inside), let second = exported(CGPoint(x: 500, y: 150)),
              let originalSecond = h.original(CGPoint(x: 500, y: 150)) else { return expect(false, "取到像素") }
        expect(abs(firstAgain.redComponent - originalInside.redComponent) < 0.01, "第一块没有被第二块压暗")
        expect(abs(second.redComponent - originalSecond.redComponent) < 0.01, "第二块也是原样")

        // 椭圆：包围盒的角上被遮罩，中心是原样
        h.view.testing_applyStyle(.highlightEllipse(true))
        h.drag(CGPoint(x: 620, y: 290), CGPoint(x: 760, y: 410))
        guard let center = exported(CGPoint(x: 690, y: 350)), let corner = exported(CGPoint(x: 630, y: 300)),
              let originalCenter = h.original(CGPoint(x: 690, y: 350)), let originalCorner = h.original(CGPoint(x: 630, y: 300))
        else { return expect(false, "取到像素") }
        expect(abs(center.redComponent - originalCenter.redComponent) < 0.01, "椭圆中心是原样")
        expect(corner.redComponent < originalCorner.redComponent * 0.75, "椭圆外的角上被遮罩（\(originalCorner) → \(corner)）")

        h.screenshot().map { write($0, "highlight.png") }
    }

    /// 工具栏图标：把工具图标放大画成一张图，改图标时对着看线宽和风格是否还统一。
    @MainActor static func toolIcons() async {
        expect(Icon.isAvailable, "找到图标资源包（打包的 .app 里由 build-app.sh 放进 Contents/Resources）")
        let actions = ToolbarAction.displayOrder
        let iconSize: CGFloat = 60
        let cell = CGSize(width: iconSize + 40, height: iconSize + 52)
        let size = CGSize(width: cell.width * CGFloat(actions.count), height: cell.height)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // The toolbar is dark and draws these as templates, so show them the same way.
        NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        for (index, action) in actions.enumerated() {
            let origin = CGPoint(x: CGFloat(index) * cell.width, y: 0)
            let icon = tinted(Icon.image(for: action, size: iconSize), .white)
            icon.draw(in: CGRect(x: origin.x + (cell.width - iconSize) / 2, y: cell.height - iconSize - 22,
                                 width: iconSize, height: iconSize))
            let label = NSAttributedString(string: action.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.75),
            ])
            label.draw(at: CGPoint(x: origin.x + (cell.width - label.size().width) / 2, y: 16))
        }
        NSGraphicsContext.restoreGraphicsState()
        write(rep, "tool-icons.png")

        // 同一套图标，缩放到同一尺寸后“上墨”的面积占比应当接近——明显跑偏的那个就是混进来的异类
        // （原来那块实心棋盘和粗记号笔就是这样看出来的）。
        var inked: [(ToolbarAction, Double)] = []
        for action in actions {
            inked.append((action, inkCoverage(Icon.asset(for: action))))
        }
        // 每个图标都得画出东西来：资源包丢了的话它们会全是空白（按钮看不见，但应用照跑）。
        let coverage = inked.map(\.1)
        expect(coverage.allSatisfy { $0 > 0.02 }, "每个图标都画出了内容（" + inked.map { "\($0.0.title) \(Int($0.1 * 100))%" }.joined(separator: " ") + "）")

        // 同一套图标的上墨占比应当接近——明显跑偏的那个就是混进来的异类（原来是实心棋盘和粗记号笔）。
        // 打码的像素块图标是刻意带实心格的（棋盘样式），不参与这条。
        let library = inked.filter { Icon.asset(for: $0.0) != .checkerboard }.map(\.1)
        if let low = library.min(), let high = library.max() {
            expect(high / low < 4.0, "同一套图标的笔画占比接近（最高 \(Int(high * 100))%，最低 \(Int(low * 100))%）")
        }
    }

    /// How much of its box an icon actually inks, 0…1. An icon that failed to load — resource bundle
    /// missing, file renamed — draws nothing, which is invisible in the app but shows up here.
    @MainActor static func inkCoverage(_ asset: Icon.Asset, size: CGFloat = 48) -> Double {
        let icon = Icon.image(asset, size: size)
        let canvas = NSImage(size: icon.size)
        canvas.lockFocus()
        NSColor.white.setFill()
        CGRect(origin: .zero, size: icon.size).fill()
        icon.draw(in: CGRect(origin: .zero, size: icon.size))
        canvas.unlockFocus()
        guard let cg = canvas.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let buffer = PixelBuffer(image: cg) else { return 0 }
        var ink = 0
        for y in 0..<buffer.height {
            for x in 0..<buffer.width where buffer.pixel(x: x, y: y).r < 160 { ink += 1 }
        }
        return Double(ink) / Double(buffer.width * buffer.height)
    }

    @MainActor static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        let rect = CGRect(origin: .zero, size: image.size)
        color.setFill()
        rect.fill()
        image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
        out.unlockFocus()
        return out
    }

    /// 文字识别快捷键：框选完直接把文字复制到剪贴板，不弹识别面板。
    @MainActor static func ocrShortcut() async {
        // 提示落在刚框的那块正中，不是屏幕底部（别把注意力拽走），贴边时也不出屏
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let area = CGRect(x: 400, y: 300, width: 300, height: 200)
        let centred = HUD.frame(width: 152, height: 36, in: screen, at: area)
        expect(abs(centred.midX - area.midX) < 0.5 && abs(centred.midY - area.midY) < 0.5, "提示落在框选正中（\(centred)）")
        let edge = HUD.frame(width: 152, height: 36, in: screen, at: CGRect(x: 1430, y: 890, width: 20, height: 20))
        expect(screen.contains(edge), "贴着屏幕边角框选时提示也不出屏（\(edge)）")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let h = CaptureHarness(lines: ["Settings", "Automatically check for updates"])
        h.view.autoOCR = true
        h.select(CGRect(x: 60, y: 60, width: 420, height: 110))
        expect(!h.view.testing_toolbarVisible, "连工具栏都不摆出来（摆出来就是那一下闪烁）")
        expect(h.view.testing_sizeChipFrame == nil, "也不摆左上角那个尺寸框")
        expect(h.view.testing_ocrText == nil, "不弹识别面板")
        for _ in 0..<600 where pasteboard.string(forType: .string) == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let copied = pasteboard.string(forType: .string) ?? ""
        expect(copied.contains("Settings") && copied.contains("Automatically check for updates"),
               "框选完直接把识别到的文字复制走（\(copied.debugDescription)）")
        expect(copied.hasSuffix("\n") == false, "复制的是纯文本，没有多余空行（\(copied.debugDescription)）")

        // 普通截图（没有这个标记）不会往剪贴板里塞东西
        let plain = CaptureHarness(lines: ["Settings"])
        pasteboard.clearContents()
        plain.select(CGRect(x: 60, y: 60, width: 420, height: 110))
        try? await Task.sleep(for: .seconds(2))
        expect(pasteboard.string(forType: .string) == nil, "普通截图不碰剪贴板")
    }

    /// 菜单栏图标：按菜单栏的实际尺寸画一张对照图（浅色 / 深色菜单栏各一份），顺便守住它的尺寸与模板属性。
    @MainActor static func menuBarClick() async {
        // 默认还是老行为：左键开菜单。右键任何时候都开菜单，不然选了别的功能就找不到设置了。
        expect(Settings.shared.menuBarClickAction == .menu, "单击菜单栏图标默认是下拉菜单")
        for action in MenuBarClickAction.allCases {
            expect(MenuBarClickAction.outcome(for: action, rightClick: false) == action,
                   "左键执行设置里选的那一项（\(action.title)）")
            expect(MenuBarClickAction.outcome(for: action, rightClick: true) == .menu,
                   "右键始终打开下拉菜单（\(action.title)）")
        }

        let model = SettingsModel(loadSecrets: false)
        model.menuBarClickAction = .ocr
        expect(Settings.shared.menuBarClickAction == .ocr, "设置里选完立即写进去（\(Settings.shared.menuBarClickAction)）")
        expect(MenuBarClickAction.outcome(for: .ocr, rightClick: false) == .ocr, "选文字识别之后左键就是文字识别")
        model.menuBarClickAction = .menu
        expect(Settings.shared.menuBarClickAction == .menu, "改回下拉菜单")
    }

    @MainActor static func menuBarIcon() async {
        let icon = Icon.image(.menuBar, size: 16)
        expect(icon.size == CGSize(width: 16, height: 16), "按菜单栏尺寸生成 16pt（\(icon.size)）")
        expect(icon.isTemplate, "是模板图，跟着菜单栏明暗自动着色")

        let size = CGSize(width: 420, height: 150)
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let bars: [(NSColor, NSColor, String)] = [
                (NSColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1), .black, "浅色菜单栏"),
                (NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1), .white, "深色菜单栏"),
            ]
            for (index, bar) in bars.enumerated() {
                let top = CGFloat(1 - index) * (size.height / 2)
                bar.0.setFill()
                CGRect(x: 0, y: top, width: size.width, height: size.height / 2).fill()
                let tinted = tinted(icon, bar.1)
                tinted.draw(in: CGRect(x: 40, y: top + (size.height / 2 - 16) / 2, width: 16, height: 16))
                tinted.draw(in: CGRect(x: 100, y: top + (size.height / 2 - 48) / 2, width: 48, height: 48))
                NSAttributedString(string: "\(bar.2) · 16pt 与放大 3 倍", attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: bar.1.withAlphaComponent(0.6),
                ]).draw(at: CGPoint(x: 170, y: top + size.height / 4 - 8))
            }
            NSGraphicsContext.restoreGraphicsState()
            write(rep, "menubar-icon.png")
        }
    }

    /// 「截图时自动隐藏贴图」：这个开关决定新截图里会不会带上桌面上已经贴好的图。
    @MainActor static func pinsWhileCapturing() async {
        let previous = Settings.shared.hidesPinsWhileCapturing
        defer {
            Settings.shared.hidesPinsWhileCapturing = previous
            PinManager.shared.closeAll()
        }
        let pin = PinManager.shared.pin(sampleRep(), frame: CGRect(x: -4000, y: -4000, width: 120, height: 80))

        expect(Settings.shared.hidesPinsWhileCapturing && SettingsModel(loadSecrets: false).hidesPinsWhileCapturing,
               "默认就是不拍贴图，设置里的开关也是打开的")
        expect(!CaptureEngine.includesPins, "默认：新截图不带贴图")
        expect(PinManager.shared.capturableWindowNumbers == [CGWindowID(pin.windowNumber)],
               "可见的贴图会被列进可拍窗口（\(PinManager.shared.capturableWindowNumbers)）")

        Settings.shared.hidesPinsWhileCapturing = false
        expect(CaptureEngine.includesPins, "关掉之后，截图会把贴图一起拍进去")

        PinManager.shared.toggleHidden()
        expect(PinManager.shared.capturableWindowNumbers.isEmpty, "收起来的贴图不参与")
        PinManager.shared.toggleHidden()
        expect(PinManager.shared.capturableWindowNumbers.count == 1, "显示回来又参与")
    }

    /// 截图圆角：交给外面（复制 / 保存 / 贴图）的图四角是透明的，0 就是直角。
    @MainActor static func roundedCorners() async {
        let previous = Settings.shared.cornerRadius
        defer { Settings.shared.cornerRadius = previous }
        let h = CaptureHarness()
        h.select(CGRect(x: 60, y: 60, width: 200, height: 120))

        /// 直接读位图的 alpha 字节（`colorAt` 在这条色彩管理链路上不可靠）。
        func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> UInt8 {
            guard let data = rep.bitmapData else { return 255 }
            return data[y * rep.bytesPerRow + x * 4 + 3]
        }

        Settings.shared.cornerRadius = 0
        guard let square = h.export() else { return expect(false, "export") }
        expect(alpha(square, 1, 1) == 255, "圆角 0 时四角是实心的（alpha \(alpha(square, 1, 1))）")

        Settings.shared.cornerRadius = 12
        guard let rounded = h.export() else { return expect(false, "export") }
        expect(alpha(rounded, 1, 1) == 0, "设了圆角之后四角透明（alpha \(alpha(rounded, 1, 1))）")
        expect(alpha(rounded, rounded.pixelsWide / 2, rounded.pixelsHigh / 2) == 255, "中间不受影响")

        // 圆弧边缘要是抗锯齿的（有半透明的过渡像素），不能是硬切——硬切的锯齿在贴图放大后会变成颗粒。
        // 同时：预乘 alpha 下颜色和覆盖率一起缩，半透明的地方不该比覆盖率更黑（那就是脏边）。
        var partial = 0, halo = 0
        if let data = rounded.bitmapData {
            for y in 0..<min(40, rounded.pixelsHigh) {
                for x in 0..<min(40, rounded.pixelsWide) {
                    let i = y * rounded.bytesPerRow + x * 4
                    let coverage = Int(data[i + 3])
                    guard coverage > 8, coverage < 247 else { continue }
                    partial += 1
                    if Int(data[i]) + 8 < coverage { halo += 1 }
                }
            }
        }
        expect(partial > 20, "圆弧是抗锯齿的，边缘有过渡像素（\(partial) 个）")
        expect(halo == 0, "半透明的边缘不发黑（\(halo) 个脏像素）")

        // 垫一层底色再出图：透明角在白色查看器里看不出来。用 CoreGraphics 合成——
        // AppKit 的 draw(in:) 会把透明角当成 copy，底色一起被抹掉。
        if let source = rounded.cgImage,
           let ctx = CGContext(data: nil, width: rounded.pixelsWide, height: rounded.pixelsHigh,
                               bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            let frame = CGRect(x: 0, y: 0, width: rounded.pixelsWide, height: rounded.pixelsHigh)
            ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.5, blue: 0.9, alpha: 1))
            ctx.fill(frame)
            ctx.draw(source, in: frame)
            if let image = ctx.makeImage() {
                let canvas = NSBitmapImageRep(cgImage: image)
                canvas.size = rounded.size
                write(canvas, "rounded-corners.png")
            }
        }
        // 再把左上角放大 6 倍（不插值，看原始像素）：锯齿/颗粒在这里一眼能看出来。
        let crop = 30
        if let source = rounded.cgImage, let piece = source.cropping(to: CGRect(x: 0, y: 0, width: crop, height: crop)),
           let zoom = CGContext(data: nil, width: crop * 6, height: crop * 6, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            let frame = CGRect(x: 0, y: 0, width: crop * 6, height: crop * 6)
            zoom.setFillColor(CGColor(srgbRed: 0.25, green: 0.5, blue: 0.9, alpha: 1))
            zoom.fill(frame)
            zoom.interpolationQuality = .none
            zoom.draw(piece, in: frame)
            if let image = zoom.makeImage() { write(NSBitmapImageRep(cgImage: image), "rounded-corner-zoom.png") }
        }
    }

    @MainActor static func textKeyEvent(_ window: NSWindow, _ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @MainActor static func secretFile() async {
        let name = "check-secret"
        defer { SecretFile.write("", name) }
        SecretFile.write("sk-first", name)
        SecretFile.write("sk-second", name)
        expect(SecretFile.read(name) == "sk-second", "the saved key reads back")
        let path = SecretFile.directory.appendingPathComponent(name).path
        let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0
        expect(mode == 0o600, "only the user can read it (mode \(String(mode, radix: 8)))")
        SecretFile.write("", name)
        expect(SecretFile.read(name) == nil, "an empty key removes the file")
    }

    /// 大模型可以存多份：旧配置怎么变成一个列表、名字怎么显示、新增/删除、以及「至少留一份」。
    @MainActor static func llmConfigs() async {
        let defaults = UserDefaults.standard
        let engine = Settings.shared.engine
        let storedConfigs = Settings.shared.llmConfigs
        let storedSelection = Settings.shared.selectedLLMConfigID
        let legacyKeys = ["translate.baseURL", "translate.model", "translate.systemPrompt"]
        let storedLegacy = legacyKeys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            Settings.shared.engine = engine
            Settings.shared.llmConfigs = storedConfigs
            Settings.shared.selectedLLMConfigID = storedSelection
            for (key, value) in storedLegacy {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }

        // 单份配置那三个键，变成列表里的第一条。id 是 legacyID，所以它的 Key 还是老文件，名字留空。
        defaults.removeObject(forKey: "translate.llmConfigs")
        defaults.removeObject(forKey: "translate.llmConfigID")
        defaults.set("https://api.example.com/v1", forKey: "translate.baseURL")
        defaults.set("my-model", forKey: "translate.model")
        defaults.set("说人话", forKey: "translate.systemPrompt")

        let migrated = Settings.shared.llmConfigs
        expect(migrated.count == 1 && migrated[0].id == LLMConfig.legacyID, "旧配置变成列表里的第一条")
        expect(migrated[0].baseURL == "https://api.example.com/v1" && migrated[0].model == "my-model"
               && migrated[0].systemPrompt == "说人话",
               "Base URL / 模型 / 提示词都带过来了（\(migrated[0].baseURL) / \(migrated[0].model)）")
        expect(LLMConfig.labels(for: migrated) == [LLMConfig.defaultName], "没起名字的那条显示「自定义大模型」")
        expect(Settings.keyFile(for: LLMConfig.legacyID) == "api-key", "迁移过来的那条继续用老的 api-key 文件")

        // 新增：空白一份、自动选中；两条都没名字时，后面那条带序号，否则下拉里两行一模一样的字。
        let added = Settings.shared.addLLMConfig()
        expect(Settings.shared.llmConfigs.count == 2 && Settings.shared.selectedLLMConfigID == added.id,
               "「新增」插进一份并选中它")
        expect(added.baseURL.isEmpty && added.model.isEmpty, "新增的那份是空白的（占位文字显示默认值）")
        expect(LLMConfig.labels(for: Settings.shared.llmConfigs) == [LLMConfig.defaultName, "\(LLMConfig.defaultName) 2"],
               "两条都没名字时后面那条编号（\(LLMConfig.labels(for: Settings.shared.llmConfigs))）")
        expect(Settings.keyFile(for: added.id) == "api-key-\(added.id)", "新增的那份有自己的 Key 文件")

        // 起过名字就用名字；两份起一样的名字也照样分得开。
        var named = Settings.shared.llmConfigs
        named[0].name = "DeepSeek"
        named[1].name = "DeepSeek"
        expect(LLMConfig.labels(for: named) == ["DeepSeek", "DeepSeek 2"], "重名也编号（\(LLMConfig.labels(for: named))）")

        // 设置页改的是「当前选中那份」：改动立即写回列表，翻译用的就是它。
        var list = Settings.shared.llmConfigs
        list[0].name = "DeepSeek"
        list[1].name = "备用"
        Settings.shared.llmConfigs = list
        Settings.shared.selectedLLMConfigID = list[1].id
        Settings.shared.engine = .llm
        let model = SettingsModel(loadSecrets: false)
        expect(model.configName == "备用" && model.baseURL.isEmpty, "设置页打开时装载的是选中那份（\(model.configName)）")
        model.baseURL = "https://changed.example/v1"
        expect(Settings.shared.translationConfig.baseURL == "https://changed.example/v1",
               "改完立即写回那份，翻译配置跟着变")
        expect(Settings.shared.translationConfig.configID == list[1].id, "翻译配置带着那份的 id")
        expect(Settings.shared.translationConfig.model == TranslationConfig.defaultModel,
               "模型留空时回落到内置默认（\(Settings.shared.translationConfig.model)）")
        model.selectedConfigID = list[0].id
        expect(model.configName == "DeepSeek" && model.baseURL == "https://api.example.com/v1",
               "换一份时字段跟着换成那一份自己的（\(model.configName) / \(model.baseURL)）")

        // 删除：删掉当前选中的那份，选到相邻一份；最后一份删不掉，下拉里总得有东西可选。
        Settings.shared.llmConfigs = [LLMConfig(id: "a", name: "A"), LLMConfig(id: "b", name: "B"), LLMConfig(id: "c", name: "C")]
        Settings.shared.selectedLLMConfigID = "b"
        Settings.shared.removeLLMConfig(id: "b")
        expect(Settings.shared.llmConfigs.map(\.id) == ["a", "c"], "删掉的那份从列表里消失")
        expect(Settings.shared.selectedLLMConfigID == "c", "删掉选中的那份后落到相邻一份（\(Settings.shared.selectedLLMConfigID)）")
        Settings.shared.removeLLMConfig(id: "c")
        Settings.shared.removeLLMConfig(id: "a")
        expect(Settings.shared.llmConfigs.count == 1, "最后一份删不掉，始终留着一条")

        // 多份配置时设置页照样画得出来。
        Settings.shared.llmConfigs = [LLMConfig(id: "one", name: "DeepSeek"),
                                      LLMConfig(id: "two", name: "公司网关")]
        Settings.shared.selectedLLMConfigID = "one"
        Settings.shared.engine = .llm
        let page = SettingsModel(loadSecrets: false)
        let image = renderPane(SettingsView(model: page, pane: .translate),
                               size: CGSize(width: 860, height: 760), name: "settings-translate-two-models.png")
        expect(image.map(looksLikeAPage) == true, "两份大模型时翻译页照样画得出来")

        // 接口类型是每份配置自己的事：换了它，空着的 Base URL / 模型跟着换这家的默认——不然一份 Claude
        // 会拿着 DeepSeek 的地址和模型名去发请求。
        page.selectedConfigID = "two"
        page.baseURL = ""
        page.model = ""
        page.provider = .gemini
        expect(Settings.shared.selectedLLMConfig.provider == .gemini, "接口类型写回那一份")
        expect(Settings.shared.translationConfig.provider == .gemini, "翻译配置带上接口类型")
        expect(Settings.shared.translationConfig.baseURL == LLMProvider.gemini.defaultBaseURL,
               "空着就按这家的默认地址（\(Settings.shared.translationConfig.baseURL)）")
        expect(Settings.shared.translationConfig.model == LLMProvider.gemini.defaultModel,
               "模型也一样（\(Settings.shared.translationConfig.model)）")

        // 三种接口类型的设置页都画得出来（字段名一样，占位文字不一样）。
        for provider in LLMProvider.allCases {
            page.provider = provider
            let rendered = renderPane(SettingsView(model: page, pane: .translate),
                                      size: CGSize(width: 860, height: 900), name: "settings-translate-\(provider.rawValue)-provider.png")
            expect(rendered.map(looksLikeAPage) == true, "「\(provider.title)」的设置页画得出来")
        }

        // 早先存的 JSON 里没有 provider 字段（那会儿只有 OpenAI 一种）。解码必须成功——`Settings.llmConfigs`
        // 把解码失败当成「没存过」，失败就意味着用户存的几份会静默消失，只剩下旧键拼出来的那一条。
        let beforeProviders = #"[{"id":"default","name":"DeepSeek","baseURL":"https://api.deepseek.com","model":"deepseek-flash"}]"#
        defaults.set(Data(beforeProviders.utf8), forKey: "translate.llmConfigs")
        expect(Settings.shared.llmConfigs.count == 1 && Settings.shared.llmConfigs[0].provider == .openai,
               "没有 provider 字段的老配置解出来是 OpenAI 兼容")
        expect(Settings.shared.llmConfigs[0].name == "DeepSeek" && Settings.shared.llmConfigs[0].model == "deepseek-flash",
               "名字和地址都还在，没被当成空列表")

        // 未打包运行时 Key 一律来自环境变量，绝不碰真实配置文件（和以前一样）。
        expect(Settings.shared.apiKey(for: "one") == Settings.shared.apiKey(for: "two"),
               "未打包运行时每份配置读的都是环境变量，不去动真实 Key 文件")
    }

    /// The rename moved the bundle id, which is also the UserDefaults domain, so the settings the app
    /// saved under the old name have to come across once — without ever overwriting a newer value.
    @MainActor static func legacyMigration() async {
        let legacyName = "app.omnishot.check.legacy"
        let currentName = "app.omnishot.check.current"
        let legacy = UserDefaults(suiteName: legacyName)!
        let current = UserDefaults(suiteName: currentName)!
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            current.removePersistentDomain(forName: currentName)
        }
        legacy.removePersistentDomain(forName: legacyName)
        current.removePersistentDomain(forName: currentName)
        legacy.set("⌥⇧A", forKey: "shortcut.capture")
        legacy.set(0.5, forKey: "style.highlightOpacity")
        current.set("改过的值", forKey: "shortcut.capture")

        LegacyMigration.copyDefaults(from: legacyName, into: current)

        expect(current.object(forKey: "style.highlightOpacity") as? Double == 0.5, "a setting only the old app had is carried over")
        expect(current.string(forKey: "shortcut.capture") == "改过的值", "a setting already saved under the new name is kept")
        expect(legacy.string(forKey: "shortcut.capture") == "⌥⇧A", "the old domain is left alone, so an older build still finds its settings")

        // The real entry point, from an unbundled build: it must do nothing at all.
        UserDefaults.standard.removeObject(forKey: "migrated.from.legacy.app")
        LegacyMigration.run(into: .standard)
        expect(UserDefaults.standard.object(forKey: "migrated.from.legacy.app") == nil,
               "an unbundled build never migrates the real app's settings into a scripted run")
    }

    @MainActor static func ocr() async {
        let h = CaptureHarness(lines: ["Settings", "Automatically check for updates", "识别截图里的文字"])
        h.select(CGRect(x: 60, y: 60, width: 420, height: 110))
        NSPasteboard.general.clearContents()
        h.key("x", code: 7)
        for _ in 0..<300 where h.view.testing_ocrText == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let text = h.view.testing_ocrText else { return expect(false, "X shows the recognized text") }
        expect(text.contains("Automatically check for updates") && text.contains("截图"), "X recognizes the text (\(text.debugDescription))")
        expect(NSPasteboard.general.string(forType: .string) == nil, "without copying it by itself")
        let panel = h.view.subviews.compactMap { $0 as? OCRPanelView }.first!
        panel.textView.string = text + "（已修改）"
        h.screenshot().map { write($0, "ocr.png") }
        h.key("c", code: 8)
        expect(NSPasteboard.general.string(forType: .string) == text + "（已修改）", "C copies the edited text")
        expect(h.view.testing_ocrText == nil && h.view.testing_selection != nil, "and closes the panel, keeping the selection")

        h.key("x", code: 7)
        for _ in 0..<300 where h.view.testing_ocrText == nil { try? await Task.sleep(for: .milliseconds(100)) }
        h.key("\u{1b}", code: 53)
        expect(h.view.testing_ocrText == nil && h.view.testing_selection != nil, "Esc closes the panel first, keeping the selection")
    }

    /// 识别跑在子进程里（`OCRService`）：macOS 26/27 的 Vision 引擎会在这个进程里「卡死」，之后每次识别都失败，
    /// 直到进程重启。子进程被杀、或者卡死模拟触发时，应用要能悄悄重起一个并把这次请求重试成功；进程起不来时退回
    /// 本进程那条老路。
    @MainActor static func ocrService() async {
        // The rest of the checks may run with the escape hatch set; this one has to see the real path.
        let forced = ProcessInfo.processInfo.environment["OMNISHOT_OCR_INPROCESS"]
        unsetenv("OMNISHOT_OCR_INPROCESS")
        defer {
            if let forced { setenv("OMNISHOT_OCR_INPROCESS", forced, 1) }
        }

        let size = CGSize(width: 600, height: 180)
        let h = CaptureHarness(size: size, paint: { _ in
            NSColor.white.setFill()
            CGRect(origin: .zero, size: size).fill()
            for (i, text) in ["Settings", "Automatically check for updates", "识别截图里的文字"].enumerated() {
                NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black,
                ]).draw(at: CGPoint(x: 20, y: 20 + CGFloat(i) * 34))
            }
        })
        let bounds = CGRect(origin: .zero, size: size)
        func text() async -> String? {
            do {
                return try await TextRecognizer.recognize(h.snapshot, selection: bounds).plainText
            } catch {
                print("   （识别失败：\(error.localizedDescription)）")
                return nil
            }
        }

        let first = await text()
        expect(first?.contains("Automatically check for updates") == true, "识别结果和以前一样")
        expect(OCRService.shared.testing_isRunning, "识别在子进程里跑")

        let spawned = OCRService.shared.testing_spawnCount
        OCRService.shared.testing_killEngine()
        let afterKill = await text()
        expect(afterKill?.contains("识别截图") == true, "识别进程被杀掉后，下一次识别照样成功（\(afterKill ?? "nil")）")
        expect(OCRService.shared.testing_spawnCount > spawned, "并且重新起了一个进程")

        let beforeWedge = OCRService.shared.testing_spawnCount
        OCRService.shared.testing_wedgeNextRequest()
        let afterWedge = await text()
        expect(afterWedge?.contains("Settings") == true, "识别进程卡死时自动重启，重试成功")
        expect(OCRService.shared.testing_spawnCount == beforeWedge + 1,
               "卡死只重启一次（重启了 \(OCRService.shared.testing_spawnCount - beforeWedge) 次）")

        let layout = try? await TextRecognizer.layout(h.snapshot, bounds: bounds)
        expect(layout?.lines.contains { $0.text.contains("Settings") } == true, "贴图选字走同一条路")

        setenv("OMNISHOT_OCR_INPROCESS", "1", 1)
        defer { unsetenv("OMNISHOT_OCR_INPROCESS") }
        let inProcess = await text()
        expect(inProcess?.contains("Settings") == true, "OMNISHOT_OCR_INPROCESS=1 时退回本进程识别")
    }

    /// 设置 → 文字识别 → 百度 OCR, end to end. A made-up transport stands in for Baidu, so the check never
    /// touches the network and never needs a key — it drives the request, the parsing, every entry point that
    /// dispatch feeds, and the error that reaches the user.
    @MainActor static func baiduOCR() async {
        let previousEngine = Settings.shared.ocrEngine
        let previousMode = StyleMemory.mosaicMode
        defer {
            TextRecognizer.baiduOverride = nil
            Settings.shared.ocrEngine = previousEngine
            StyleMemory.mosaicMode = previousMode
        }
        Settings.shared.ocrEngine = .baidu
        _ = renderPane(SettingsView(model: SettingsModel(loadSecrets: false), pane: .ocr),
                       size: CGSize(width: 860, height: 600), name: "settings-ocr-baidu.png")

        // The picture is 100×50 px, and `upscaledForSmallText` doubles anything this small before the upload —
        // so the reply describes the 200×100 picture that actually went over the wire: two lines at
        // (20,40,60,20) and (20,70,40,20). Normalized, that is the 0.1 / 0.4 / 0.3 / 0.2 asserted below.
        let page = Data("""
        {"log_id": 1,
         "words_result": [
          {"words": "业务员", "location": {"left": 20, "top": 40, "width": 60, "height": 20},
           "chars": [{"char": "业", "location": {"left": 20, "top": 40, "width": 20, "height": 20}},
                     {"char": "务", "location": {"left": 40, "top": 40, "width": 20, "height": 20}},
                     {"char": "员", "location": {"left": 60, "top": 40, "width": 20, "height": 20}}]},
          {"words": "刘伟", "location": {"left": 20, "top": 70, "width": 40, "height": 20}}],
         "paragraphs_result": [{"words_result_idx": [0, 1]}]}
        """.utf8)
        let counter = OCRRequestCounter()
        let transport: BaiduOCR.Transport = { request in
            let path = request.url?.path ?? ""
            await counter.note(path)
            if path == "/oauth/2.0/token" {
                return (Data(#"{"access_token":"check-token","expires_in":2592000}"#.utf8), httpResponse())
            }
            return (page, httpResponse())
        }
        TextRecognizer.baiduOverride = (BaiduOCRConfig(apiKey: "check-key", secretKey: "check-secret"), transport)

        // 1. The boxes come back in the selection's coordinates, with glyphs and paragraphs intact.
        //    50×25 points at the harness's 2x backing is the 100×50-pixel picture the reply describes.
        let rep = sampleRep(CGSize(width: 50, height: 25))
        guard let cg = rep.cgImage else { return expect(false, "有一张测试图") }
        let selection = CGRect(x: 200, y: 100, width: 400, height: 200)
        let result = (try? await TextRecognizer.recognize(cg, selection: selection))
            ?? RecognitionResult(lines: [], blocks: nil)
        expect(result.lines.count == 2, "百度返回的行都在（\(result.lines.count) 行）")
        expect(result.lines.first?.text == "业务员", "文字原样保留")
        let rect = result.lines.first?.rect ?? .zero
        expect(abs(rect.minX - 240) < 0.01 && abs(rect.minY - 180) < 0.01
               && abs(rect.width - 120) < 0.01 && abs(rect.height - 40) < 0.01,
               "行框从图片像素换算进选区（\(rect)）")
        expect(result.lines.first?.glyphs.count == 3, "逐字框也带过来了（贴图选字要用）")
        expect(result.translatedBlocks.count == 1 && result.translatedBlocks[0].lines.count == 2,
               "百度给的段落直接成块")

        // 2. The OCR panel reads through the same dispatch. It now also runs a local pass to fill Baidu's holes,
        //    and a check run on its own compiles Vision's models first — hence the long wait.
        let h = CaptureHarness(lines: ["Placeholder for the OCR panel"])
        h.select(CGRect(x: 60, y: 60, width: 420, height: 110))
        h.key("x", code: 7)
        for _ in 0..<600 where h.view.testing_ocrText == nil { try? await Task.sleep(for: .milliseconds(100)) }
        expect(h.view.testing_ocrText?.contains("业务员") == true,
               "X 面板显示的是百度认出来的字（\(h.view.testing_ocrText ?? "nil")）")

        // 3. A failure is reported, not quietly answered by Vision — a silent fallback would hide a dead key.
        let failing: BaiduOCR.Transport = { request in
            if request.url?.path == "/oauth/2.0/token" {
                return (Data(#"{"access_token":"check-token-2","expires_in":2592000}"#.utf8), httpResponse())
            }
            return (Data(#"{"error_code":17,"error_msg":"Open api daily request limit reached"}"#.utf8), httpResponse())
        }
        TextRecognizer.baiduOverride = (BaiduOCRConfig(apiKey: "check-key-2", secretKey: "check-secret-2"), failing)
        do {
            _ = try await TextRecognizer.recognize(cg, selection: selection)
            expect(false, "百度报错时不能悄悄换回内置识别")
        } catch {
            expect(error.localizedDescription.contains("免费次数用完了"),
                   "百度自己的错误码说成人话（\(error.localizedDescription)）")
        }
        TextRecognizer.baiduOverride = (BaiduOCRConfig(apiKey: "check-key", secretKey: "check-secret"), transport)

        // 3b. 高精度的额度用完了：换标准版接着认，并且只在那一次说一句。
        let fallingBack: BaiduOCR.Transport = { request in
            if request.url?.path == "/oauth/2.0/token" {
                return (Data(#"{"access_token":"check-token-3","expires_in":2592000}"#.utf8), httpResponse())
            }
            if request.url?.path == "/rest/2.0/ocr/v1/accurate" {
                return (Data(#"{"error_code":17,"error_msg":"Open api daily request limit reached"}"#.utf8), httpResponse())
            }
            return (page, httpResponse())
        }
        TextRecognizer.baiduOverride = (BaiduOCRConfig(apiKey: "check-key-3", secretKey: "check-secret-3", precision: .accurate), fallingBack)
        let fallback = (try? await TextRecognizer.recognize(cg, selection: selection))
            ?? RecognitionResult(lines: [], blocks: nil)
        expect(fallback.lines.count == 2 && fallback.notice?.contains("免费额度") == true,
               "额度用完时换到另一份，并说一句（\(fallback.notice ?? "nil")）")
        let quiet = (try? await TextRecognizer.recognize(cg, selection: selection))
            ?? RecognitionResult(lines: [], blocks: nil)
        expect(quiet.notice == nil, "第二张图直接用另一份，不再重复提示")
        TextRecognizer.baiduOverride = (BaiduOCRConfig(apiKey: "check-key", secretKey: "check-secret"), transport)

        // 4. 自动识别 works through Baidu in one request, and reading the same selection again costs nothing —
        //    this engine is billed per picture, and the mode re-reads the screen every time the selection rests.
        StyleMemory.mosaicMode = .auto
        let h2 = CaptureHarness(lines: ["Phone 13800138001", "Phone 13800138001"])
        h2.select(CGRect(x: 60, y: 60, width: 420, height: 110))
        h2.key("4", code: 21)
        for _ in 0..<100 where h2.view.testing_autoTargets.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        expect(!h2.view.testing_autoTargets.isEmpty,
               "百度引擎下自动识别也找得到目标（\(h2.view.testing_autoTargets.count) 个）")
        let before = await counter.count("/rest/2.0/ocr/v1/accurate")
        h2.view.testing_restartAutoMaskDetection()
        try? await Task.sleep(for: .milliseconds(100))
        let after = await counter.count("/rest/2.0/ocr/v1/accurate")
        expect(after == before, "同一块选区再读一次不会重新请求百度（\(before) → \(after)）")

        // 4b. 百度自己会漏行（同一请求两次结果都不一样），漏掉的行用本机识别补上，百度认出来的字不动。
        // 假回复只给第一行；第二行由本机那一遍补进来。
        let holePage = Data("""
        {"words_result": [{"words": "Alpha one two three", "location": {"left": 300, "top": 300, "width": 1200, "height": 94}}]}
        """.utf8)
        let holeTransport: BaiduOCR.Transport = { request in
            if request.url?.path == "/oauth/2.0/token" {
                return (Data(#"{"access_token":"check-token-4","expires_in":2592000}"#.utf8), httpResponse())
            }
            return (holePage, httpResponse())
        }
        TextRecognizer.baiduOverride = (BaiduOCRConfig(apiKey: "check-key-4", secretKey: "check-secret-4"), holeTransport)
        let twoLines = CaptureHarness(lines: ["Alpha one two three", "Beta four five six"])
        let merged = (try? await TextRecognizer.recognize(twoLines.snapshot, selection: CGRect(origin: .zero, size: twoLines.size)))
            ?? RecognitionResult(lines: [], blocks: nil)
        expect(merged.lines.count >= 2, "百度漏掉的行由本机识别补上（\(merged.lines.count) 行）")
        expect(merged.lines.contains { $0.text == "Alpha one two three" }, "百度自己认出来的字原样保留")

        // 5. Back to the built-in engine: the dispatch lets go.
        TextRecognizer.baiduOverride = nil
        Settings.shared.ocrEngine = .system
        let builtIn = (try? await TextRecognizer.recognize(h.snapshot, selection: CGRect(x: 60, y: 60, width: 420, height: 110)))
            ?? RecognitionResult(lines: [], blocks: nil)
        expect(!builtIn.lines.isEmpty, "切回内置识别后仍然走 Vision（\(builtIn.lines.count) 行）")
    }

    private static func httpResponse(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://aip.baidubce.com")!, statusCode: status,
                        httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    @MainActor static func scrollResultKeys() async {
        guard let screen = NSScreen.main, let image = sampleRep().cgImage else { return expect(false, "screen and sample image") }
        func open() -> ScrollResultWindow? {
            ScrollResultWindow.show(image: image, scale: 2, on: screen)
            return ScrollResultWindow.testing_open.last
        }

        NSPasteboard.general.clearContents()
        guard let w1 = open() else { return expect(false, "result window opens") }
        key(w1, "c", code: 8)
        expect(NSPasteboard.general.data(forType: .png) != nil || NSPasteboard.general.data(forType: .tiff) != nil, "C copies the long screenshot")
        expect(!w1.isVisible, "and closes the window")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omnishot-scroll-keys-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = Settings.shared.saveDirectory
        Settings.shared.saveDirectory = directory
        defer { Settings.shared.saveDirectory = previous; try? FileManager.default.removeItem(at: directory) }
        guard let w2 = open() else { return expect(false, "result window opens") }
        key(w2, "s", code: 1)
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        expect(saved.count == 1 && !w2.isVisible, "S saves it to the save folder (\(saved))")

        let before = PinManager.shared.pins.count
        guard let w3 = open() else { return expect(false, "result window opens") }
        key(w3, "t", code: 17)
        expect(PinManager.shared.pins.count == before + 1 && !w3.isVisible, "T pins it")
        PinManager.shared.pins.last?.close()
    }

    @MainActor static func pinText() async {
        let h = CaptureHarness(lines: ["Settings", "Automatically check for updates", "直接在贴图上选择文字"])
        h.select(CGRect(x: 60, y: 60, width: 420, height: 110))
        guard let rep = h.export() else { return expect(false, "export") }
        let pin = PinManager.shared.pin(rep, frame: CGRect(origin: CGPoint(x: -4000, y: -4000), size: rep.size))
        let view = pin.testing_view
        for _ in 0..<300 where view.textLayout == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let layout = view.textLayout else { return expect(false, "a new pin recognizes its text") }
        expect(layout.lines.count == 3, "three lines recognized (\(layout.lines.map(\.text)))")
        guard let auto = layout.lines.firstIndex(where: { $0.text.contains("check") }), auto + 1 < layout.lines.count else { return }
        let line = layout.lines[auto]
        let start = line.text.distance(from: line.text.startIndex, to: line.text.range(of: "check")!.lowerBound)
        // At 100% the view shows the image one to one.
        func point(_ l: Int, _ k: Int) -> CGPoint { CGPoint(x: layout.lines[l].boxes[k].minX + 0.5, y: layout.lines[l].rect.midY) }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) -> NSEvent {
            // 传进来的是图片坐标；贴图窗口左边和下边留给边框、右边和上边留给按钮，换算成窗口坐标要加回来。
            let inView = CGPoint(x: p.x + PinView.borderInset, y: p.y + PinView.buttonInset)
            return NSEvent.mouseEvent(with: type, location: view.convert(inView, to: nil), modifierFlags: [], timestamp: 0,
                                      windowNumber: pin.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        let last = layout.lines[auto + 1]
        let end = CGPoint(x: last.rect.maxX + 30, y: last.rect.midY)
        view.mouseDown(with: mouse(.leftMouseDown, point(auto, start)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 200, y: 60)))
        view.mouseDragged(with: mouse(.leftMouseDragged, end))
        view.mouseUp(with: mouse(.leftMouseUp, end))
        let origin = pin.frame.origin
        expect(pin.frame.origin == origin && view.textSelection != nil, "dragging on text selects instead of moving the pin")
        NSPasteboard.general.clearContents()
        key(pin, "c", code: 8, flags: .command)
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        expect(copied == "check for updates\n" + last.text, "⌘C copies the selected text across lines (\(copied.debugDescription))")
        write(render(view) ?? rep, "pin-text-selection.png")

        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 100)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 400, y: 100)))
        expect(view.textSelection == nil, "clicking off the text clears the selection")
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 100), clicks: 2))
        expect(pin.isVisible, "double-clicking a pin no longer closes it")
        let settings = layout.lines.firstIndex { $0.text == "Settings" } ?? 0
        view.mouseDown(with: mouse(.leftMouseDown, point(settings, 2), clicks: 2))
        expect(view.selectedText == layout.lines[settings].text, "double-click selects a word (\(view.selectedText ?? "nil"))")
        view.mouseDown(with: mouse(.leftMouseDown, point(auto, 2), clicks: 3))
        expect(view.selectedText == line.text, "triple-click selects the line")
        key(pin, "\u{1b}", code: 53)
        expect(view.textSelection == nil && pin.isVisible, "Esc first clears the selection")

        key(pin, "\u{1b}", code: 53)
        expect(!pin.isVisible, "Esc then closes the pin")
        PinManager.shared.closeAll()
    }

    /// Unbundled runs never start Sparkle; the settings switch still lands where Sparkle reads it.
    @MainActor static func updater() async {
        expect(!Updater.isAvailable, "an unbundled build does not start the updater")
        expect(Updater.versionString == "开发版", "an unbundled build calls itself 开发版 instead of a version")
        let model = SettingsModel(loadSecrets: false)
        expect(model.automaticallyChecksForUpdates, "automatic update checks are on by default")
        model.automaticallyChecksForUpdates = false
        expect(UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool == false, "turning them off is saved at once, under Sparkle's key")
        model.automaticallyChecksForUpdates = true
        expect(Updater.shared.automaticallyChecks, "and turning them back on too")
    }
}

/// Counts what a check's stand-in transport was asked to send, so a check can say "one request, not three".
private actor OCRRequestCounter {
    private var paths: [String] = []

    func note(_ path: String) { paths.append(path) }

    func count(_ fragment: String) -> Int { paths.filter { $0.contains(fragment) }.count }
}
