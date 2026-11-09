import AppKit
import CoreGraphics
import Darwin
import Foundation
import OmniShotCore

// MARK: - What travels over the pipe

/// A picture's pixels, always sent as 8-bit sRGB premultiplied last so both ends agree on the layout.
private struct ImageHeader: Codable {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var byteCount: Int
}

private struct ServiceRequest: Codable {
    enum Kind: String, Codable {
        case recognize
        case layout
        case autoMask
    }

    var kind: Kind
    /// `recognize` / `autoMask`: the selection, in the picture's own points.
    var selection: [Double]?
    /// `layout`: where the boxes should be expressed, in points.
    var bounds: [Double]?
    var segmentation: String?
    var autoDetectsLanguage: Bool?
    /// Self-check only: make this child behave like an engine that has wedged, so the restart path runs.
    var wedge: Bool?
    var image: ImageHeader?
}

private struct WireError: Codable {
    var domain: String
    var code: Int
    var message: String
}

private struct WireGlyph: Codable {
    var text: String
    var rect: [Double]
}

private struct WireLine: Codable {
    var text: String
    var rect: [Double]
    var firstWordWidth: Double?
    var wordGap: Double?
    var glyphs: [WireGlyph]
}

private struct WireBlock: Codable {
    var id: Int
    var lines: [WireLine]
}

private struct WireGlyphLine: Codable {
    var text: String
    var rect: [Double]
    var boxes: [[Double]]
}

private struct ServiceResponse: Codable {
    var lines: [WireLine]?
    var blocks: [WireBlock]?
    var notice: String?
    var glyphLines: [WireGlyphLine]?
    var error: WireError?
}

private func wireRect(_ rect: CGRect) -> [Double] {
    [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
}

private func rectFromWire(_ values: [Double]) -> CGRect {
    guard values.count == 4 else { return .zero }
    return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
}

private extension CGRect {
    var wire: [Double] { wireRect(self) }
}

private extension OCRLine {
    var wire: WireLine {
        WireLine(text: text, rect: wireRect(rect), firstWordWidth: firstWordWidth.map(Double.init),
                 wordGap: wordGap.map(Double.init),
                 glyphs: glyphs.map { WireGlyph(text: $0.text, rect: wireRect($0.rect)) })
    }
}

private extension WireLine {
    var ocrLine: OCRLine {
        OCRLine(text: text, rect: rectFromWire(rect),
                firstWordWidth: firstWordWidth.map { CGFloat($0) },
                wordGap: wordGap.map { CGFloat($0) },
                glyphs: glyphs.map { OCRGlyph(text: $0.text, rect: rectFromWire($0.rect)) })
    }
}

private extension WireBlock {
    var block: TextBlock { TextBlock(id: id, lines: lines.map(\.ocrLine)) }
}

private extension GlyphLine {
    var wire: WireGlyphLine { WireGlyphLine(text: text, rect: wireRect(rect), boxes: boxes.map(wireRect)) }
}

private extension WireGlyphLine {
    var glyphLine: GlyphLine { GlyphLine(text: text, rect: rectFromWire(rect), finalBoxes: boxes.map(rectFromWire)) }
}

// MARK: - The service

/// Text recognition runs in a child process of the app, not in the app.
///
/// macOS 26/27 has a bug where Vision's text engine (TextRecognition → E5RT) wedges inside a process: after
/// some hours every request fails with `CRImageReaderError` — the log says
/// `e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed (Code: 13)` —
/// and stays that way until that process is restarted. OmniShot sits in the menu bar for days, so on
/// 2026-11-04 a copy that had been up for 46 hours lost OCR and 截图翻译 entirely (17 failures in a row),
/// while a freshly started process read the same pictures perfectly. Another app hit the same thing on
/// macOS 27 (Keyboard Maestro's forum), and Apple has not fixed it.
///
/// So the engine lives in `OmniShot --ocr-service`. The app sends it pixels, it sends back lines and boxes.
/// A request that fails the way a wedged engine fails costs one child restart and one retry — the user sees a
/// slower retry instead of a feature that stays broken until they quit the app. Everything else (paragraphs,
/// the small-text second pass, auto-mask strips, the Baidu fill-in pass) stays in `TextRecognizer`, so the
/// two paths cannot drift.
/// Everything mutable is touched either on `queue` or under `lock`, which is what makes this safe across the
/// pipe writer and the watchdog thread.
final class OCRService: @unchecked Sendable {
    static let shared = OCRService()

    /// Why a request did not come back. `RecognitionEngine` turns these into in-process fallbacks or the
    /// message the user sees.
    enum Failure: Error {
        /// No child process could be started — the caller should read the picture in-process instead.
        case unavailable
        /// The engine died or hung mid-request; a fresh one is started for the next attempt.
        case crashed
        /// The engine did not answer within the deadline.
        case timedOut
        /// The recogniser itself failed (an error it reported, not a lost engine).
        case engine(domain: String, code: Int, message: String)
        /// The pipe carried something this app does not understand.
        case protocolViolation(String)

        /// Whether this is the wedge (or a dead/hung child), where starting over with a new process helps.
        var lostEngine: Bool {
            switch self {
            case .crashed, .timedOut, .protocolViolation:
                return true
            case let .engine(domain, _, message):
                return domain.contains("TextRecognition") || domain.contains("CRImageReader")
                    || message.localizedCaseInsensitiveContains("e5rt")
            case .unavailable:
                return false
            }
        }
    }

    private struct Outgoing {
        var request: ServiceRequest
        var pixels: Data
    }

    private let queue = DispatchQueue(label: "app.omnishot.ocr.service")
    /// Guards the two things the watchdog thread and the check hooks touch; everything else lives on `queue`.
    private let lock = NSLock()

    // Touched only on `queue`.
    private var child: Process?
    private var toChild: FileHandle?
    private var fromChild: FileHandle?
    private var spawnCount = 0
    private var freshChild = false

    private var timedOut = false      // guarded by `lock`
    private var wedgeNext = false     // guarded by `lock`, set by the self-check

    private init() {
        // Writing to a child that just died raises SIGPIPE, whose default action is to kill this process.
        _ = signal(SIGPIPE, SIG_IGN)
    }

    // MARK: Requests

    func recognize(_ image: CGImage, selection: CGRect, segmentation: Segmentation,
                   autoDetectsLanguage: Bool) async throws -> RecognitionResult {
        let outgoing = try makeOutgoing(kind: .recognize, image: image, selection: selection,
                                        segmentation: segmentation.rawValue,
                                        autoDetectsLanguage: autoDetectsLanguage)
        let response = try await send(outgoing)
        guard let lines = response.lines else { throw Failure.protocolViolation("no lines") }
        return RecognitionResult(lines: lines.map(\.ocrLine), blocks: response.blocks?.map(\.block),
                                 notice: response.notice)
    }

    func layout(_ image: CGImage, bounds: CGRect) async throws -> TextLayout {
        let outgoing = try makeOutgoing(kind: .layout, image: image, bounds: bounds)
        let response = try await send(outgoing)
        guard let lines = response.glyphLines else { throw Failure.protocolViolation("no layout") }
        return TextLayout(lines.map(\.glyphLine))
    }

    func recognizeForAutoMask(_ image: CGImage, selection: CGRect) async throws -> RecognitionResult {
        let outgoing = try makeOutgoing(kind: .autoMask, image: image, selection: selection)
        let response = try await send(outgoing)
        guard let lines = response.lines else { throw Failure.protocolViolation("no lines") }
        return RecognitionResult(lines: lines.map(\.ocrLine), blocks: response.blocks?.map(\.block),
                                 notice: response.notice)
    }

    /// Kills the engine when the app quits. Belt and braces: the child also watches its parent and exits on
    /// its own, because a force-quit never reaches this.
    func shutdown() {
        queue.async { self.stop() }
    }

    // MARK: Lifetime of the child

    /// The request is sent on a serial queue, and a failed engine is replaced before one retry.
    private func send(_ base: Outgoing) async throws -> ServiceResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.sendOnQueue(base)) } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func sendOnQueue(_ base: Outgoing) throws -> ServiceResponse {
        var outgoing = base
        lock.lock()
        outgoing.request.wedge = wedgeNext ? true : nil
        wedgeNext = false
        lock.unlock()

        do {
            return try checked(perform(outgoing))
        } catch let failure as Failure where failure.lostEngine {
            // The engine is in the state that made 截图翻译 fail for hours on end; a new process reads the
            // picture perfectly, so start one and ask again. The retry is never marked as a wedge.
            stop()
            outgoing.request.wedge = nil
            return try checked(perform(outgoing))
        }
    }

    /// An error the recogniser reported travels as a failed request, so a lost engine can be retried here.
    private func checked(_ response: ServiceResponse) throws -> ServiceResponse {
        if let error = response.error {
            throw Failure.engine(domain: error.domain, code: error.code, message: error.message)
        }
        return response
    }

    private func perform(_ outgoing: Outgoing) throws -> ServiceResponse {
        let process = try start()
        lock.lock()
        timedOut = false
        lock.unlock()

        // A new child has to load Vision's models; after that an answer takes a fraction of a second.
        let deadline: TimeInterval = freshChild ? 120 : 45
        freshChild = false
        let pid = process.processIdentifier
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.timedOut = true
            self.lock.unlock()
            kill(pid, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline, execute: watchdog)
        defer { watchdog.cancel() }

        do {
            try write(outgoing)
            return try readResponse()
        } catch let failure as Failure {
            throw failure
        } catch {
            lock.lock()
            let late = timedOut
            lock.unlock()
            throw late ? Failure.timedOut : Failure.crashed
        }
    }

    @discardableResult
    private func start() throws -> Process {
        if let child, child.isRunning { return child }
        stop()
        guard let executable = Self.executableURL else { throw Failure.unavailable }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--ocr-service"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        process.environment = ProcessInfo.processInfo.environment
        do {
            try process.run()
        } catch {
            throw Failure.unavailable
        }
        // The child owns these ends now. Keeping our copies open would hide the child's death: the read
        // would never see EOF.
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        child = process
        toChild = input.fileHandleForWriting
        fromChild = output.fileHandleForReading
        spawnCount += 1
        freshChild = true
        return process
    }

    private func stop() {
        try? toChild?.close()
        try? fromChild?.close()
        toChild = nil
        fromChild = nil
        if let child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        child = nil
    }

    // MARK: Pipes

    private func write(_ outgoing: Outgoing) throws {
        guard let toChild else { throw Failure.crashed }
        let header = try JSONEncoder().encode(outgoing.request)
        var length = UInt32(header.count).bigEndian
        do {
            try toChild.write(contentsOf: Data(bytes: &length, count: 4))
            try toChild.write(contentsOf: header)
            try toChild.write(contentsOf: outgoing.pixels)
        } catch {
            throw Failure.crashed
        }
    }

    private func readResponse() throws -> ServiceResponse {
        guard let fromChild else { throw Failure.crashed }
        let header = try readExactly(4, from: fromChild)
        let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length > 0, length < 16 * 1024 * 1024 else {
            throw Failure.protocolViolation("header of \(length) bytes")
        }
        let payload = try readExactly(length, from: fromChild)
        return try JSONDecoder().decode(ServiceResponse.self, from: payload)
    }

    private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            let chunk = try? handle.read(upToCount: count - data.count)
            guard let chunk, !chunk.isEmpty else {
                lock.lock()
                let late = timedOut
                lock.unlock()
                throw late ? Failure.timedOut : Failure.crashed
            }
            data.append(chunk)
        }
        return data
    }

    /// Copies the picture into a fresh 8-bit sRGB bitmap. Sending the provider's own bytes would be cheaper,
    /// but `cropping(to:)` hands back an image whose provider still holds the whole screen, so the layout
    /// would not be what the header says. A copy costs a millisecond or two against an OCR that takes a
    /// tenth of a second.
    private static func pixels(of image: CGImage) -> (ImageHeader, Data)? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 20_000, height <= 20_000,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = context.data else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let byteCount = context.bytesPerRow * height
        let header = ImageHeader(width: width, height: height, bytesPerRow: context.bytesPerRow,
                                 byteCount: byteCount)
        return (header, Data(bytes: base, count: byteCount))
    }

    private func makeOutgoing(kind: ServiceRequest.Kind, image: CGImage, selection: CGRect? = nil,
                              bounds: CGRect? = nil, segmentation: String? = nil,
                              autoDetectsLanguage: Bool? = nil) throws -> Outgoing {
        guard let (header, pixels) = Self.pixels(of: image) else {
            throw Failure.protocolViolation("the picture could not be copied")
        }
        let request = ServiceRequest(kind: kind, selection: selection?.wire, bounds: bounds?.wire,
                                     segmentation: segmentation, autoDetectsLanguage: autoDetectsLanguage,
                                     wedge: nil, image: header)
        return Outgoing(request: request, pixels: pixels)
    }

    /// The binary to run the service with: the app's own executable in a bundle, the built binary in a
    /// command-line run.
    private static var executableURL: URL? {
        if let url = Bundle.main.executableURL, FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        let path = CommandLine.arguments.first ?? ""
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    // MARK: Self-check hooks

    var testing_spawnCount: Int { queue.sync { spawnCount } }
    var testing_isRunning: Bool { queue.sync { child?.isRunning == true } }

    func testing_killEngine() {
        queue.sync { stop() }
    }

    func testing_wedgeNextRequest() {
        lock.lock()
        wedgeNext = true
        lock.unlock()
    }

    // MARK: The engine process

    /// `OmniShot --ocr-service`: reads requests from stdin, writes answers to stdout, never returns.
    ///
    /// Nothing else may write to stdout here — a stray `print` would be read as a frame header.
    static func serve() -> Never {
        signal(SIGPIPE, SIG_IGN)
        // A force-quit of the app never gets to terminate us; when the parent goes, `getppid()` changes.
        let parent = getppid()
        DispatchQueue.global(qos: .utility).async {
            while true {
                Thread.sleep(forTimeInterval: 2)
                if getppid() != parent { exit(0) }
            }
        }

        // What a wedged engine does: from the first failure on, every request fails the same way.
        var wedged = false
        while true {
            let request: ServiceRequest
            let pixels: Data
            do {
                (request, pixels) = try readFrame()
            } catch {
                exit(0)
            }
            if request.wedge == true { wedged = true }
            let response = wedged
                ? ServiceResponse(error: WireError(domain: "TextRecognition.CRImageReaderError", code: 1,
                                                   message: "未能完成操作。（TextRecognition.CRImageReaderError错误1。）"))
                : handle(request, pixels: pixels)
            do {
                try writeFrame(response)
            } catch {
                exit(0)
            }
        }
    }

    private static func handle(_ request: ServiceRequest, pixels: Data) -> ServiceResponse {
        guard let header = request.image, let image = makeImage(header, pixels) else {
            return ServiceResponse(error: WireError(domain: "OmniShot.OCRService", code: 1,
                                                    message: "图片没能送到识别进程"))
        }
        let selection = request.selection.map(rectFromWire)
            ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
        do {
            switch request.kind {
            case .recognize:
                let segmentation = request.segmentation.flatMap(Segmentation.init(rawValue:)) ?? .current
                let result = try wait {
                    try await TextRecognizer.recognizeLocally(image, selection: selection,
                                                              segmentation: segmentation,
                                                              autoDetectsLanguage: request.autoDetectsLanguage ?? true)
                }
                return ServiceResponse(lines: result.lines.map(\.wire), blocks: result.blocks?.map {
                    WireBlock(id: $0.id, lines: $0.lines.map(\.wire))
                }, notice: result.notice)
            case .autoMask:
                let result = try wait {
                    try await TextRecognizer.recognizeForAutoMaskLocally(image, selection: selection)
                }
                return ServiceResponse(lines: result.lines.map(\.wire), notice: result.notice)
            case .layout:
                let bounds = request.bounds.map(rectFromWire) ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
                let layout = try wait { try await TextRecognizer.layoutLocally(image, bounds: bounds) }
                return ServiceResponse(glyphLines: layout.lines.map(\.wire))
            }
        } catch {
            let ns = error as NSError
            return ServiceResponse(error: WireError(domain: ns.domain, code: ns.code, message: ns.localizedDescription))
        }
    }

    private static func makeImage(_ header: ImageHeader, _ pixels: Data) -> CGImage? {
        guard header.width > 0, header.height > 0, pixels.count >= header.byteCount,
              header.bytesPerRow >= header.width * 4,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels.prefix(header.byteCount)) as CFData) else {
            return nil
        }
        return CGImage(width: header.width, height: header.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: header.bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func readFrame() throws -> (ServiceRequest, Data) {
        let input = FileHandle.standardInput
        let header = try readExactly(4, from: input)
        let length = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length > 0, length < 16 * 1024 * 1024 else { throw Failure.protocolViolation("header") }
        let request = try JSONDecoder().decode(ServiceRequest.self, from: readExactly(length, from: input))
        let byteCount = request.image?.byteCount ?? 0
        guard byteCount >= 0, byteCount <= 4 * 1024 * 1024 * 1024 else {
            throw Failure.protocolViolation("picture of \(byteCount) bytes")
        }
        return (request, byteCount > 0 ? try readExactly(byteCount, from: input) : Data())
    }

    private static func writeFrame(_ response: ServiceResponse) throws {
        let payload = try JSONEncoder().encode(response)
        var length = UInt32(payload.count).bigEndian
        let output = FileHandle.standardOutput
        try output.write(contentsOf: Data(bytes: &length, count: 4))
        try output.write(contentsOf: payload)
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            guard let chunk = try? handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw Failure.crashed
            }
            data.append(chunk)
        }
        return data
    }

    /// Runs an async operation to completion on a thread of its own. The service loop is blocking by design
    /// (one request at a time, straight off the pipe), and Swift concurrency has no run loop to come back to.
    private static func wait<T>(_ operation: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>!
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }
}

extension OCRService.Failure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .engine(_, _, message): return message
        case .unavailable: return "本机识别进程没能启动"
        case .crashed: return "本机识别进程意外退出了"
        case .timedOut: return "本机识别进程没有响应"
        case let .protocolViolation(detail): return "本机识别进程返回了无法解析的数据（\(detail)）"
        }
    }
}

// MARK: - Choosing the engine

/// Where a recognition runs: in the engine process, or in this one.
///
/// The child is the normal path. Reading in-process survives only as the fallback for an engine that cannot
/// be started at all (and for `OMNISHOT_OCR_INPROCESS=1`, which keeps `--translate-image` and the checks
/// usable for comparing the two). It is exactly what the app always did, so a machine where spawning fails
/// still works — it just keeps the old failure mode.
enum RecognitionEngine {
    static func recognize(_ image: CGImage, selection: CGRect, segmentation: Segmentation,
                          autoDetectsLanguage: Bool) async throws -> RecognitionResult {
        if inProcess {
            return try await TextRecognizer.recognizeLocally(image, selection: selection,
                                                             segmentation: segmentation,
                                                             autoDetectsLanguage: autoDetectsLanguage)
        }
        do {
            return try await OCRService.shared.recognize(image, selection: selection, segmentation: segmentation,
                                                         autoDetectsLanguage: autoDetectsLanguage)
        } catch OCRService.Failure.unavailable {
            return try await TextRecognizer.recognizeLocally(image, selection: selection,
                                                             segmentation: segmentation,
                                                             autoDetectsLanguage: autoDetectsLanguage)
        }
    }

    static func layout(_ image: CGImage, bounds: CGRect) async throws -> TextLayout {
        if inProcess {
            return try await TextRecognizer.layoutLocally(image, bounds: bounds)
        }
        do {
            return try await OCRService.shared.layout(image, bounds: bounds)
        } catch OCRService.Failure.unavailable {
            return try await TextRecognizer.layoutLocally(image, bounds: bounds)
        }
    }

    static func recognizeForAutoMask(_ image: CGImage, selection: CGRect) async throws -> RecognitionResult {
        if inProcess {
            return try await TextRecognizer.recognizeForAutoMaskLocally(image, selection: selection)
        }
        do {
            return try await OCRService.shared.recognizeForAutoMask(image, selection: selection)
        } catch OCRService.Failure.unavailable {
            return try await TextRecognizer.recognizeForAutoMaskLocally(image, selection: selection)
        }
    }

    private static var inProcess: Bool {
        ProcessInfo.processInfo.environment["OMNISHOT_OCR_INPROCESS"] != nil
    }
}
