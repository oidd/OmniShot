import AppKit
import CoreImage
import CoreML

/// 智能擦除: MI-GAN makes up the pixels inside a masked area from what surrounds it — the same model PixPin's
/// 智能擦除 runs, and the reason that feature feels instant (a ~20 MB network, nothing leaves the machine).
///
/// The network takes an image and a mask at a fixed 512×512 and normalizes both itself, so it is fed **raw 0–255
/// values**. Its mask convention is **white = keep, black = make up** (the graph blends `image * mask + out *
/// (1 - mask)`), which is the opposite of what a painter would guess — `CIBlendWithMask`, on the other hand,
/// wants white = the foreground, so the blend below uses the inverted mask.
///
/// Everything around the network is ours: the crop with context, the mask at pixel resolution, the feathered
/// blend back and the cache. When the model cannot be loaded the caller falls back to a blur, so 智能擦除 never
/// leaves a hole in the picture — it only gets less clever.
enum Inpainting {
    /// What the network was trained at. The crop is resized to this and back, which is why a big region loses
    /// detail: the model only ever sees 512×512 of it.
    static let side = 512
    private static let ciContext = CIContext()
    private static var loadAttempted = false
    private static var loaded: MLModel?

    /// Whether the model is there. False (a missing or broken resource) means the tool degrades to a blur.
    static var isAvailable: Bool { model() != nil }

    /// The masked pixels of `crop` made up and blended back over the original with a soft edge. Both images are
    /// in pixels and the same size; the result has that size too.
    static func inpaint(crop: CGImage, mask: CGImage) -> CGImage? {
        guard let model = model(),
              let small = resize(crop, to: side),
              let smallMask = resize(mask, to: side),
              let input = buffer(from: small, channels: 3),
              let maskInput = buffer(from: smallMask, channels: 1)
        else { return nil }
        let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": input, "mask": maskInput])
        guard let provider,
              let output = try? model.prediction(from: provider),
              let value = output.featureValue(for: "result")?.multiArrayValue,
              let made = image(from: value)
        else { return nil }
        if ProcessInfo.processInfo.environment["OMNISHOT_DEBUG_ERASE"] != nil {
            let total = 3 * side * side
            let raw = value.dataPointer.bindMemory(to: Float.self, capacity: total)
            var low = Float.greatestFiniteMagnitude, high: Float = -1, sum: Float = 0
            for index in 0..<total { low = min(low, raw[index]); high = max(high, raw[index]); sum += raw[index] }
            let centre = 256 * side + 256
            print("[erase] output \(value.dataType.rawValue) \(value.shape) min \(low) max \(high) mean \(sum / Float(total)) centre \(raw[centre])")
        }
        let result = blend(made, over: crop, mask: mask) ?? crop
        if ProcessInfo.processInfo.environment["OMNISHOT_DEBUG_ERASE"] != nil {
            for (image, name) in [(small, "small"), (smallMask, "small-mask"), (made, "made"), (result, "result")] {
                if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "/tmp/omnishot-erase-\(name).png"))
                }
            }
        }
        return result
    }

    // MARK: - The model

    /// Loaded once, on first use: the resource is an uncompiled `.mlpackage`, so Core ML compiles it (a second or
    /// so, once) and the compiled copy is kept in Application Support for every launch after that.
    private static func model() -> MLModel? {
        if let loaded { return loaded }
        if loadAttempted { return nil }
        loadAttempted = true
        guard let package = Bundle.module.resourceURL?.appendingPathComponent("Models/migan.mlpackage"),
              FileManager.default.fileExists(atPath: package.path) else { return nil }
        let compiled = supportDirectory.appendingPathComponent("migan.mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            guard let built = try? MLModel.compileModel(at: package) else { return nil }
            try? FileManager.default.removeItem(at: compiled)
            try? FileManager.default.copyItem(at: built, to: compiled)
        }
        let configuration = MLModelConfiguration()
        // **Not `.all`.** On this model `.all` routes to the Neural Engine and quietly returns the wrong
        // picture — measured on a uniform fill: 85 where the reference and `.cpuAndGPU` both give 216 — and it is
        // slower than the GPU as well. The GPU path is ~21 ms, the CPU ~112 ms, and both agree with the
        // reference. A machine without a usable GPU falls back to the CPU on its own.
        configuration.computeUnits = .cpuAndGPU
        loaded = try? MLModel(contentsOf: compiled, configuration: configuration)
        return loaded
    }

    private static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmniShot", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - Pixels

    /// A copy scaled to `side`×`side`. Bilinear is what the reference implementation uses.
    private static func resize(_ image: CGImage, to side: Int) -> CGImage? {
        let source = CIImage(cgImage: image)
        let size = CGSize(width: side, height: side)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(image.width),
                                                             y: size.height / CGFloat(image.height)))
        return ciContext.createCGImage(scaled, from: CGRect(origin: .zero, size: size))
    }

    /// The image's bytes as an RGBA8 buffer. In a bitmap context the first byte row is the **top** of the
    /// picture — measured, not assumed: drawing a red-over-blue image into one puts red at the front of the
    /// buffer. So the rows go straight into the tensor, and the answer comes back the same way up. (Turning
    /// them round "to be safe" is what mirrored a button's gradient in a real screenshot.)
    private static func pixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    /// NCHW float32, which is the layout the model was exported with.
    private static func buffer(from image: CGImage, channels: Int) -> MLMultiArray? {
        let width = image.width, height = image.height
        guard let data = pixels(image),
              let array = try? MLMultiArray(shape: [1, NSNumber(value: channels), NSNumber(value: height),
                                                    NSNumber(value: width)],
                                            dataType: .float32) else { return nil }
        let out = array.dataPointer.bindMemory(to: Float.self, capacity: channels * width * height)
        for y in 0..<height {
            for x in 0..<width {
                let source = (y * width + x) * 4
                for channel in 0..<channels {
                    let value = Float(data[source + channel])
                    // The mask has to be binary: the graph reads `mask - 0.5` and `image * mask`, so a resized
                    // edge that came out grey is read as content, and the model fills around it with made-up
                    // structure instead of continuing the background. Nearest-neighbour in the reference
                    // implementation is why; a threshold is the same thing without a second resampling path.
                    out[channel * width * height + y * width + x] = channels == 1 ? (value >= 127.5 ? 255 : 0) : value
                }
            }
        }
        if ProcessInfo.processInfo.environment["OMNISHOT_DEBUG_ERASE"] != nil {
            let count = channels * width * height
            var low = Float.greatestFiniteMagnitude, high: Float = -1, sum: Float = 0
            for index in 0..<count {
                let value = out[index]
                low = min(low, value); high = max(high, value); sum += value
            }
            print("[erase] tensor \(channels)ch \(width)x\(height) min \(low) max \(high) mean \(sum / Float(count))")
        }
        return array
    }

    private static func image(from array: MLMultiArray) -> CGImage? {
        let count = 3 * side * side
        guard array.count >= count else { return nil }
        let values = array.dataPointer.bindMemory(to: Float.self, capacity: count)
        var highest: Float = 0
        for index in 0..<count { highest = max(highest, values[index]) }
        // The export stops at 0–255; a graph that stops one step earlier returns −1…1 instead. One look at the
        // range tells them apart, and both are handled rather than guessed at conversion time.
        let scaled = highest > 1.5
        var data = [UInt8](repeating: 255, count: side * side * 4)
        for index in 0..<(side * side) {
            for channel in 0..<3 {
                var value = values[channel * side * side + index]
                if !scaled { value = value * 127.5 + 127.5 }
                data[index * 4 + channel] = UInt8(max(0, min(255, value.rounded())))
            }
        }
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The made-up pixels over the original, with the mask's edge softened so the join is invisible.
    private static func blend(_ made: CGImage, over original: CGImage, mask: CGImage) -> CGImage? {
        let size = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        let foreground = CIImage(cgImage: made).transformed(
            by: CGAffineTransform(scaleX: size.width / CGFloat(made.width), y: size.height / CGFloat(made.height)))
        // White is "keep" for the model and "the foreground" for the blend, so it is flipped on the way in.
        let alpha = CIImage(cgImage: mask).clampedToExtent()
            .applyingFilter("CIColorInvert")
            .applyingGaussianBlur(sigma: max(1, min(6, size.width / 128)))
            .cropped(to: size)
        guard let filter = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: foreground,
            kCIInputBackgroundImageKey: CIImage(cgImage: original),
            kCIInputMaskImageKey: alpha,
        ]), let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: size)
    }
}
