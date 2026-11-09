import AppKit

enum Exporter {
    /// Renders the selection with annotations and visible translations at full pixel density.
    static func render(renderer: ContentRenderer, selection: CGRect, scale: CGFloat,
                       items: [AnnotationItem], translation: [TranslatedBlock]) -> NSBitmapImageRep? {
        let width = Int((selection.width * scale).rounded())
        let height = Int((selection.height * scale).rounded())
        guard width > 0, height > 0,
              let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Work in flipped points so drawing code matches the on-screen view.
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: 0, y: selection.height)
        cg.scaleBy(x: 1, y: -1)
        let context = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        let transform = NSAffineTransform()
        transform.translateX(by: -selection.minX, yBy: -selection.minY)
        transform.concat()
        renderer.draw(items: items, translation: translation)

        guard let image = cg.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = selection.size // keeps 2x images at their on-screen size when pasted
        return roundCorners(rep, radius: Settings.shared.cornerRadius * scale)
    }

    /// Clears the alpha outside the four corner arcs, so the picture comes out with rounded corners.
    ///
    /// Done on the pixels rather than by clipping the context: the export context is flipped and scaled, and a
    /// clip path built for it came out in the wrong place (a quarter of the picture instead of all of it).
    ///
    /// The arc is anti-aliased by coverage. A hard cut leaves a staircase, and the dark pixels at those steps
    /// turn into visible speckles once a pin is zoomed in. All four channels are scaled together, which is what
    /// premultiplied alpha wants — scaling only the alpha would leave a dark fringe.
    private static func roundCorners(_ rep: NSBitmapImageRep, radius: CGFloat) -> NSBitmapImageRep {
        let radius = Int(radius.rounded())
        let width = rep.pixelsWide, height = rep.pixelsHigh
        guard radius > 0, width > 2 * radius, height > 2 * radius,
              rep.samplesPerPixel == 4, let data = rep.bitmapData else { return rep }
        let corners = [(0, 0), (width - radius, 0), (0, height - radius), (width - radius, height - radius)]
        for (originX, originY) in corners {
            let centreX = Double(originX == 0 ? radius : width - radius - 1)
            let centreY = Double(originY == 0 ? radius : height - radius - 1)
            for y in originY..<(originY + radius) {
                for x in originX..<(originX + radius) {
                    let dx = Double(x) - centreX, dy = Double(y) - centreY
                    let coverage = min(1, max(0, Double(radius) - (dx * dx + dy * dy).squareRoot() + 0.5))
                    guard coverage < 1 else { continue }
                    let i = y * rep.bytesPerRow + x * 4
                    for channel in 0..<4 {
                        data[i + channel] = UInt8((Double(data[i + channel]) * coverage).rounded())
                    }
                }
            }
        }
        return rep
    }

    static func data(_ rep: NSBitmapImageRep, format: ImageFormat) -> Data? {
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    static func copy(_ rep: NSBitmapImageRep, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if let png = rep.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pasteboard.writeObjects([item])
    }

    /// `OmniShot 2026-09-25 15.30.00.png`
    static func defaultFileName(format: ImageFormat, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "OmniShot \(formatter.string(from: date)).\(format.fileExtension)"
    }

    /// Saves into the configured folder with a timestamped name and returns the file URL.
    static func save(_ rep: NSBitmapImageRep, format: ImageFormat, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = defaultFileName(format: format)
        var url = directory.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let base = (name as NSString).deletingPathExtension
            url = directory.appendingPathComponent("\(base) \(suffix).\(format.fileExtension)")
            suffix += 1
        }
        try write(rep, format: format, to: url)
        return url
    }

    static func write(_ rep: NSBitmapImageRep, format: ImageFormat, to url: URL) throws {
        guard let data = data(rep, format: format) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}

/// Small floating message at the bottom of the screen, used after the overlay has closed.
enum HUD {
    private static var window: NSWindow?

    /// Where the message goes: centred on `rect` when there is one, else just above the bottom of the screen.
    /// Either way it is kept inside `screen`, so a capture against an edge still gets a readable message.
    static func frame(width: CGFloat, height: CGFloat, in screen: CGRect, at rect: CGRect?) -> CGRect {
        let center = rect.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: screen.midX, y: screen.minY + 120 + height / 2)
        return CGRect(x: min(max(center.x - width / 2, screen.minX + 20), screen.maxX - width - 20),
                      y: min(max(center.y - height / 2, screen.minY + 20), screen.maxY - height - 20),
                      width: width, height: height)
    }

    /// `at` puts the message in the middle of that screen rect instead of at the bottom of the screen; after a
    /// capture that keeps the eye where the work just happened instead of pulling it to a corner.
    static func show(_ text: String, at rect: CGRect? = nil, on screen: NSScreen? = nil, duration: TimeInterval = 1.6) {
        // A self-check drives the same paths a capture does; its feedback has no business on the user's screen.
        guard !SelfCheck.isRunning else { return }
        window?.orderOut(nil)
        // A rect picks the screen it lands on, so multi-monitor captures get their message on the right one.
        let target = screen
            ?? rect.flatMap { r in NSScreen.screens.first { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) } }
            ?? NSScreen.main
        guard let screen = target else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        let size = label.fittingSize
        let width = min(size.width + 32, screen.frame.width - 40)
        let frame = frame(width: width, height: 36, in: screen.frame, at: rect)

        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .transient]
        let background = NSView(frame: CGRect(origin: .zero, size: frame.size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        background.layer?.cornerRadius = 10
        label.frame = CGRect(x: 16, y: (frame.height - size.height) / 2, width: width - 32, height: size.height)
        background.addSubview(label)
        w.contentView = background
        w.orderFrontRegardless()
        window = w
        // Fade out rather than blink away: the message is the only thing telling the user what happened.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard window === w else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                w.animator().alphaValue = 0
            } completionHandler: {
                guard window === w else { return }
                w.orderOut(nil)
                window = nil
            }
        }
    }
}
