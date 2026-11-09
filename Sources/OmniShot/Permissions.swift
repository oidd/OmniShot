import AppKit
import ApplicationServices
import Combine

/// The two system permissions OmniShot can want, and whether they are granted.
///
/// This is only a *view* of system state: nothing here decides when to ask. The app still asks by
/// itself the first time a feature needs a permission — Screen Recording at launch, Accessibility when
/// 长截图 first reaches for it — and the settings window shows the same two switches so the user can
/// see what is missing and grant it without having to trip over the feature first.
@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    @Published private(set) var screenRecording = CaptureEngine.hasPermission
    @Published private(set) var accessibility = AXIsProcessTrusted()

    /// Whether Screen Recording was already granted when this process started. macOS reads that
    /// permission once, at launch, so granting it later in the same run changes nothing until a restart
    /// — which only the app can tell the user, and only if it remembers what it started with.
    let launchedWithScreenRecording = CaptureEngine.hasPermission

    private var timer: Timer?

    private init() {}

    /// Screenshots and OCR need Screen Recording; 长截图's auto-scroll is the only thing that wants
    /// Accessibility, so a missing Accessibility is a much smaller problem.
    var needsRestartToApply: Bool { screenRecording && !launchedWithScreenRecording }

    func refresh() {
        let screen = CaptureEngine.hasPermission
        let trusted = AXIsProcessTrusted()
        if screen != screenRecording { screenRecording = screen }
        if trusted != accessibility { accessibility = trusted }
    }

    /// Polls while the settings window is open. The status can also change from System Settings, which
    /// nothing here can observe, so polling is the only way to notice the user coming back.
    func startMonitoring() {
        stopMonitoring()
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Asks the system to put up its own prompt. It returns before the user has answered, so the
    /// polling above is what eventually shows the new state.
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// The prompt can't be shown twice, so this is the way back once it has been dismissed.
    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Relaunches the app, which is what newly granted Screen Recording needs. Does nothing from an
    /// unbundled build: there is no .app to reopen, and quitting would just be quitting.
    func restart() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -n so the new copy starts even though this one has not exited yet.
        task.arguments = ["-n", bundle.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
