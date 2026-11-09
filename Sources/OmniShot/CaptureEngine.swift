import AppKit
import ScreenCaptureKit

/// A frozen image of one screen, taken before the overlay appears.
struct ScreenSnapshot {
    let screen: NSScreen
    let image: CGImage
}

enum CaptureEngine {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Whether the pinned screenshots on the desktop end up in the new screenshot. On by default they do not,
    /// which is what 设置 → 通用 → 「截图时自动隐藏贴图」 switches.
    static var includesPins: Bool { !Settings.shared.hidesPinsWhileCapturing }

    /// Captures every screen at full pixel resolution, leaving out OmniShot's own windows — except the ones
    /// the user is actually looking at. Three kinds come back in through `exceptingWindows`: the settings
    /// window and the 输入翻译 window, always, and the pins when 「截图时自动隐藏贴图」 is off.
    ///
    /// Our own windows are kept because leaving them out looks like a bug: press the capture hotkey while
    /// 设置 or 输入翻译 is open and the window vanishes from the frozen picture, as though it had hidden
    /// itself — which is exactly how it was reported, twice. The capture overlay and the 长截图 chrome are not
    /// on screen yet when this runs, so they are covered by the blanket exclusion and need no special case.
    @MainActor
    static func captureScreens(includingPins: Bool = false) async throws -> [ScreenSnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var kept = Set(SettingsWindowController.shared.capturableWindowNumbers)
        kept.formUnion(TextTranslationWindow.existing?.capturableWindowNumbers ?? [])
        if includingPins { kept.formUnion(PinManager.shared.capturableWindowNumbers) }
        let excepting = content.windows.filter { kept.contains($0.windowID) }
        var snapshots: [ScreenSnapshot] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value })
            else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: excepting)
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            snapshots.append(ScreenSnapshot(screen: screen, image: image))
        }
        return snapshots
    }

    /// Frames of normal app windows, front to back, in Cocoa global coordinates (origin bottom-left of the main screen).
    static func windowFrames() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height
        else { return [] }
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40
            else { return nil }
            // CG window bounds use a top-left origin on the primary display.
            return CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
        }
    }
}
