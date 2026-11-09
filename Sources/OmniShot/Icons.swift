import AppKit

/// Every icon on the toolbar and the style bar.
///
/// These are the libraries' own SVG files, bundled with the app and drawn by the system: nothing is
/// redrawn, traced or converted here. (An earlier attempt turned the paths into `CGPath` by hand and got
/// their fill rules wrong, which filled the "translate" glyph into a solid blob — hence the files.)
///
///     Icons/phosphor   Phosphor Icons (MIT), fill weight — https://phosphoricons.com
///     Icons/lucide     Lucide's scan-text (ISC) — https://lucide.dev
///     Icons/settings   the settings sidebar's six page icons, supplied by the project owner (iconfont)
///     Icons/outline    Phosphor Icons (MIT), regular weight — the 输入翻译 window's own controls
///     Icons/custom     the one icon OmniShot draws for itself: the spotlight's highlight frame
///     Icons/app        the menu bar's own icon, exported by the project owner (a white-on-alpha PNG mask)
///
/// One family across the row is the whole point: SF Symbols mixed metaphors and weights (a filled
/// checkerboard beside a hairline square, a text badge for OCR, a numeral for the number tool), which read
/// as icons borrowed from three different sets.
enum Icon {
    enum Asset: String, CaseIterable {
        // Tools
        case square = "phosphor/square"
        case arrowUpRight = "phosphor/arrow-up-right"
        case pencilSimple = "phosphor/pencil-simple"
        /// The pen tool's highlighter sub-tool.
        case highlighter = "phosphor/highlighter"
        case magnifyingGlassPlus = "phosphor/magnifying-glass-plus"
        case textT = "phosphor/text-t"
        case numberCircleOne = "phosphor/number-circle-one"
        case highlight = "custom/highlight"
        // Actions
        case arrowUUpLeft = "phosphor/arrow-u-up-left"
        case scanText = "lucide/scan-text"
        /// 识别内容's second reading: a QR code, for 扫码. The project owner's own drawing — the thicker of the
        /// two they supplied, which matches the toolbar's other strokes.
        case qrCode = "custom/scan-code"
        case translate = "phosphor/translate"
        case pushPin = "phosphor/push-pin"
        /// 截图翻译's disc pins: Phosphor's pushpins with the stroke widened to the owner's disc-glyph weight.
        case discPinRow = "custom/disc-pin-row"
        case discPinUpright = "custom/disc-pin-upright"
        case arrowsDownUp = "phosphor/arrows-down-up"
        case xmark = "phosphor/x"
        case download = "phosphor/download-simple"
        case swap = "phosphor/arrows-left-right"
        /// 智能擦除 — the mosaic tool's third effect, which fills the region in rather than hiding it.
        case eraser = "phosphor/eraser"
        /// The pin's rotate button — counter-clockwise, the only direction it turns.
        case rotateCounterClockwise = "phosphor/arrow-counter-clockwise"
        /// The style bar's delete button: the bin at the end of a selected annotation's options.
        case trash = "phosphor/trash"
        /// The caret on the translation bar's 大模型 chip, to say "this opens a list".
        case caretDown = "phosphor/caret-down"
        case check = "phosphor/check"
        // Style bar
        case paintBrush = "phosphor/paint-brush"
        case selection = "phosphor/selection"
        /// 自动识别: two stacked dashed boxes, the way a multi-selection reads.
        case autoMask = "custom/auto-mask"
        case checkerboard = "phosphor/checkerboard"
        case drop = "phosphor/drop"
        case circle = "phosphor/circle"
        // Settings window
        case settingsPermissions = "settings/permissions"
        case settingsShortcuts = "settings/shortcuts"
        case settingsOutput = "settings/output"
        case settingsTranslate = "settings/translate"
        /// 文字识别's page icon is Lucide's scan-text — the owner's iconfont set has six page icons and no OCR
        /// one yet, and this matches their stroke weight. Swap the file when they draw one.
        case settingsOCR = "settings/ocr"
        case settingsGeneral = "settings/general"
        case settingsAbout = "settings/about"
        // The 输入翻译 window draws its own little buttons, and takes Phosphor at regular weight so it does not
        // mix a hairline set with a solid one. (The settings cards used to have row icons from this set; the owner
        // had them removed so every row reads the same.)
        case granted = "outline/check-circle"
        case missing = "outline/warning"
        /// The 输入翻译 window's pin, lying flat and standing up.
        case pinRow = "outline/push-pin"
        case pinUpright = "outline/push-pin-simple"
        /// The 输入翻译 window's copy button, which is an icon rather than a word.
        case copyText = "outline/copy"
        /// …and its 清空 button, which empties 原文.
        case clearText = "outline/eraser"
        // The menu bar's own icon, drawn by the project owner: a white-on-alpha PNG mask, which a
        // template image (alpha only) takes as it is.
        case menuBar = "app/menubar"
        // The three glyphs the disc buttons wear — the ×, the copy sheets and the pencil — drawn by the project
        // owner. The pencil is scaled up inside its canvas so it reads at the same weight as the other two.
        case closeDisc = "custom/disc-close"
        case copyDisc = "custom/disc-copy"
        case editDisc = "custom/disc-edit"
    }

    /// A template image, so every control tints it the same way.
    ///
    /// The SVG is rasterized once per size, at 2x, because the controls draw their art unscaled
    /// (`imageScaling = .scaleNone`) and an SVG's natural size is 256 points.
    static func image(_ asset: Asset, size: CGFloat = 16) -> NSImage {
        let key = Key(asset: asset, size: size)
        if let cached = cache[key] { return cached }
        let image = render(asset, size: size)
        cache[key] = image
        return image
    }

    /// The toolbar is one row of these, tools and actions alike.
    static func image(for action: ToolbarAction, size: CGFloat = 16) -> NSImage {
        image(asset(for: action), size: size)
    }

    /// The same icon, painted white — the white case of the tint below, kept as its own name because that is
    /// what the callers mean. Cached, because the disc buttons redraw theirs on every hover.
    static func whiteImage(_ asset: Asset, size: CGFloat) -> NSImage {
        let key = Key(asset: asset, size: size)
        if let cached = whiteCache[key] { return cached }
        let white = image(asset, size: size, tint: .white)
        whiteCache[key] = white
        return white
    }

    /// The same icon painted a flat colour, for the places that draw one themselves rather than handing a
    /// template image to a control that would tint it (the 大模型 list's tick is the accent colour, and it has
    /// to be read while drawing because the theme can be changed between two captures). `.sourceAtop` only
    /// paints where the icon already has ink, so the shape survives.
    static func image(_ asset: Asset, size: CGFloat, tint: NSColor) -> NSImage {
        let source = image(asset, size: size)
        let painted = NSImage(size: source.size)
        painted.lockFocus()
        source.draw(in: CGRect(origin: .zero, size: source.size))
        tint.setFill()
        CGRect(origin: .zero, size: source.size).fill(using: .sourceAtop)
        painted.unlockFocus()
        return painted
    }

    /// Whether the icon files were found at all; the self-checks use it to catch a missing resource bundle.
    static var isAvailable: Bool { resources != nil }

    /// Which file an action's icon comes from; the self-checks use it to tell the drawn-by-us ones apart.
    static func asset(for action: ToolbarAction) -> Asset {
        switch action {
        case let .tool(tool):
            switch tool {
            case .rectangle: return .square
            case .arrow: return .arrowUpRight
            case .pen: return .pencilSimple
            // 打码 uses the same checkerboard as its 像素块 sub-tool: one icon for the effect everywhere.
            case .mosaic: return .checkerboard
            case .magnifier: return .magnifyingGlassPlus
            case .text: return .textT
            case .number: return .numberCircleOne
            case .highlight: return .highlight
            }
        case .undo: return .arrowUUpLeft
        case .ocr: return .scanText
        case .translate: return .translate
        case .pin: return .pushPin
        case .longCapture: return .arrowsDownUp
        case .cancel: return .xmark
        case .save: return .download
        case .done: return .check
        }
    }

    // MARK: - Files

    private struct Key: Hashable {
        var asset: Asset
        var size: CGFloat
    }

    private static var cache: [Key: NSImage] = [:]
    private static var whiteCache: [Key: NSImage] = [:]

    /// The resource bundle SwiftPM builds for this target. In the packaged app it is copied into
    /// `Contents/Resources` by `scripts/build-app.sh`; running `.build/debug/OmniShot` it sits next to the
    /// executable. When it is missing the icons come out empty (the app still runs; `--check tool-icons`
    /// fails loudly).
    private static let resources: Bundle? = {
        let name = "OmniShot_OmniShot.bundle"
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.bundleURL.deletingLastPathComponent()] {
            if let url = base?.appendingPathComponent(name), let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }()

    /// The file an icon is drawn from. The libraries' icons are their own SVG files; the menu bar's
    /// artwork is whatever the project owner exported, which has been a PNG mask as often as an SVG.
    /// A template is rendered from its alpha channel alone, so a flat PNG needs no tracing into paths.
    private static func sourceImage(_ parts: [String]) -> NSImage? {
        for ext in ["svg", "png"] {
            if let url = resources?.url(forResource: parts[1], withExtension: ext, subdirectory: "Icons/" + parts[0]),
               let image = NSImage(contentsOf: url) { return image }
        }
        return nil
    }

    private static func render(_ asset: Asset, size: CGFloat) -> NSImage {
        let parts = asset.rawValue.split(separator: "/").map(String.init)
        let empty = NSImage(size: CGSize(width: size, height: size))
        guard parts.count == 2, let source = sourceImage(parts) else { return empty }

        let scale: CGFloat = 2
        let pixels = Int((size * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return empty }
        rep.size = CGSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Fit into the square, keeping the icon's own proportions — menu bar icons are rarely exactly square,
        // and stretching one is what makes it look off next to the system's.
        let sourceSize = source.size
        let fit = min(size / max(sourceSize.width, 1), size / max(sourceSize.height, 1))
        let drawn = CGSize(width: sourceSize.width * fit, height: sourceSize.height * fit)
        source.draw(in: CGRect(x: (size - drawn.width) / 2, y: (size - drawn.height) / 2,
                               width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: CGSize(width: size, height: size))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}
