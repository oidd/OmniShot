import AppKit

/// Renders the website's product shots offscreen from the real capture view.
///
///   OmniShot --site-shots sample.png output-directory
///
/// Unlike `--ui-demo`, every scene selects the whole sample window and only adds
/// the annotations that belong to that feature. The website should not ship a
/// feature shot with unrelated annotations all over it.
enum SiteShots {
    @MainActor
    static func run(input: URL, outputDirectory: URL) async {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        // The site's one blue. The app's default theme is a cyan-leaning light blue;
        // the marketing shots use the same pure blue as the translation demo.
        Settings.shared.themeColor = NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 255 / 255, alpha: 1)

        guard let image = NSImage(contentsOf: input),
              let account = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            FileHandle.standardError.write(Data("cannot read \(input.path)\n".utf8))
            return
        }

        let size = CGSize(width: 1200, height: 760)
        let scale: CGFloat = 2
        let pixelsWide = Int(size.width * scale), pixelsHigh = Int(size.height * scale)
        guard let canvas = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        canvas.setFillColor(NSColor.white.cgColor)
        canvas.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        // The sample is 1600x680 pixels: 800x340 points at the top-left (80, 80).
        let drawRect = CGRect(x: 80 * scale,
                              y: CGFloat(pixelsHigh) - 80 * scale - CGFloat(account.height),
                              width: CGFloat(account.width), height: CGFloat(account.height))
        canvas.draw(account, in: drawRect)
        guard let snapshot = canvas.makeImage() else { return }

        let frame = CGRect(origin: .zero, size: size)
        let windowRect = CGRect(x: 80, y: 80, width: 800, height: 340)

        func makeView() -> (NSWindow, CaptureView) {
            let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = CaptureView(frame: frame, snapshot: snapshot, windowRects: [windowRect], displayID: 0)
            view.testing_hidesDim = true
            window.contentView = CaptureRootView(frame: frame, snapshot: snapshot, captureView: view)
            window.makeFirstResponder(view)
            return (window, view)
        }

        func shot(_ view: CaptureView, _ name: String) {
            view.layoutSubtreeIfNeeded()
            guard let overlay = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            overlay.size = size
            if let data = overlay.bitmapData { memset(data, 0, overlay.bytesPerRow * overlay.pixelsHigh) }
            view.cacheDisplay(in: view.bounds, to: overlay)
            let out = NSImage(size: size)
            out.lockFocus()
            NSImage(cgImage: snapshot, size: size).draw(in: frame)
            overlay.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            out.unlockFocus()
            if let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: outputDirectory.appendingPathComponent("\(name).png"))
            }
        }

        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1,
                   window: NSWindow, view: CaptureView) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: flags, timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                               pressure: 1)!
        }

        func click(_ p: CGPoint, window: NSWindow, view: CaptureView) {
            view.mouseDown(with: mouse(.leftMouseDown, p, window: window, view: view))
            view.mouseUp(with: mouse(.leftMouseUp, p, window: window, view: view))
        }

        func drag(_ from: CGPoint, _ to: CGPoint, steps: Int = 8, window: NSWindow, view: CaptureView) {
            view.mouseDown(with: mouse(.leftMouseDown, from, window: window, view: view))
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                view.mouseDragged(with: mouse(.leftMouseDragged, p, window: window, view: view))
            }
            view.mouseUp(with: mouse(.leftMouseUp, to, window: window, view: view))
        }

        func key(_ chars: String, _ code: UInt16, window: NSWindow, view: CaptureView) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            (window.firstResponder ?? view).keyDown(with: event)
        }

        func selectWindow(_ window: NSWindow, _ view: CaptureView) {
            view.mouseMoved(with: mouse(.mouseMoved, CGPoint(x: 400, y: 200), window: window, view: view))
            click(CGPoint(x: 400, y: 200), window: window, view: view)
        }

        // Hero: the whole window, no annotations, no extra chrome.
        do {
            let (window, view) = makeView()
            selectWindow(window, view)
            shot(view, "hero")
        }

        // Annotation: one rectangle around the recovery code, one arrow pointing at it.
        do {
            let (window, view) = makeView()
            selectWindow(window, view)
            key("1", 18, window: window, view: view)
            drag(CGPoint(x: 130, y: 236), CGPoint(x: 410, y: 266), window: window, view: view)
            view.testing_deselectItem() // drop the handles, keep the annotation and the style bar
            shot(view, "annotate")
        }

        // OCR: the whole window selected, then X. The panel has room to the right.
        do {
            let (window, view) = makeView()
            selectWindow(window, view)
            key("x", 7, window: window, view: view)
            for _ in 0..<400 where view.testing_ocrText == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            shot(view, "ocr")
        }

        // Pin: pin the clean selection, at 100%, without the zoom flash.
        do {
            let (window, view) = makeView()
            selectWindow(window, view)
            if let rep = view.exportImage() {
                let pin = PinWindow(rep: rep, frame: CGRect(x: -6000, y: -6000, width: rep.size.width, height: rep.size.height))
                if let content = pin.contentView {
                    (content as? PinView)?.testing_showButtons()
                    content.layoutSubtreeIfNeeded()
                    let size = content.bounds.size
                    if let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                                     pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                        canvas.size = size
                        NSGraphicsContext.saveGraphicsState()
                        let context = NSGraphicsContext(bitmapImageRep: canvas)!
                        NSGraphicsContext.current = context
                        NSColor.white.setFill()
                        content.bounds.fill()
                        content.displayIgnoringOpacity(content.bounds, in: context)
                        NSGraphicsContext.restoreGraphicsState()
                        if let png = canvas.representation(using: .png, properties: [:]) {
                            try? png.write(to: outputDirectory.appendingPathComponent("pin.png"))
                        }
                    }
                }
            }
            _ = window
        }

        print("Wrote site shots to \(outputDirectory.path)")
    }
}
