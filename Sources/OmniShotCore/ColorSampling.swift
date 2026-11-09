import CoreGraphics
import Foundation

public struct RGBA: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Relative luminance in 0...1 (sRGB coefficients, no gamma correction; good enough to pick black or white).
    public var luminance: Double {
        (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
    }

    /// WCAG relative luminance, gamma-corrected, for contrast ratios.
    public var relativeLuminance: Double {
        func linear(_ value: UInt8) -> Double {
            let v = Double(value) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio, 1...21.
    public func contrastRatio(with other: RGBA) -> Double {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public func mixed(with other: RGBA, fraction: Double) -> RGBA {
        let f = min(max(fraction, 0), 1)
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) + (Double(b) - Double(a)) * f).rounded()) }
        return RGBA(r: mix(r, other.r), g: mix(g, other.g), b: mix(b, other.b))
    }

    /// Moves toward white or black — whichever side this color already leans to — until it reads on
    /// `background`. The light/dark direction is never flipped, so white text on a green button stays
    /// white instead of turning into black text (which is what a plain "pick black or white" rule does).
    public func ensuringContrast(_ minimum: Double, against background: RGBA) -> RGBA {
        guard contrastRatio(with: background) < minimum else { return self }
        let preferred: RGBA = relativeLuminance > background.relativeLuminance ? .white : .black
        guard preferred.contrastRatio(with: background) >= minimum else { return preferred }
        var low = 0.0, high = 1.0
        for _ in 0..<8 {
            let middle = (low + high) / 2
            if mixed(with: preferred, fraction: middle).contrastRatio(with: background) >= minimum { high = middle } else { low = middle }
        }
        return mixed(with: preferred, fraction: high)
    }

    func distance(to other: RGBA) -> Int {
        abs(Int(r) - Int(other.r)) + abs(Int(g) - Int(other.g)) + abs(Int(b) - Int(other.b))
    }

    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let white = RGBA(r: 255, g: 255, b: 255)
}

/// Opaque RGBA8 pixels with a top-left origin.
public struct PixelBuffer: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let data: [UInt8]

    public init(width: Int, height: Int, bytesPerRow: Int, data: [UInt8]) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.data = data
    }

    /// Renders `image` into an sRGB RGBA8 buffer so pixels can be read directly.
    public init?(image: CGImage) {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, bytesPerRow: bytesPerRow, data: data)
    }

    public func pixel(x: Int, y: Int) -> RGBA {
        let i = y * bytesPerRow + x * 4
        return RGBA(r: data[i], g: data[i + 1], b: data[i + 2])
    }
}

public enum ColorSampler {
    /// The pixels just outside `rect`: the background the text was drawn on.
    ///
    /// A median of those is less affected by anti-aliased glyph edges than an average would be. When the
    /// rect touches every edge of the image the ring is empty, so its own border pixels stand in.
    public static func ringPixels(_ buffer: PixelBuffer, rect: CGRect, ring: Int = 2) -> [RGBA] {
        let inner = clamp(rect.integral, buffer)
        let outer = clamp(rect.integral.insetBy(dx: -CGFloat(ring), dy: -CGFloat(ring)), buffer)
        guard inner.width > 0, inner.height > 0 else { return [] }
        var pixels: [RGBA] = []
        for y in Int(outer.minY)..<Int(outer.maxY) {
            for x in Int(outer.minX)..<Int(outer.maxX) where !inner.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
                pixels.append(buffer.pixel(x: x, y: y))
            }
        }
        if pixels.isEmpty {
            for x in Int(inner.minX)..<Int(inner.maxX) {
                pixels.append(buffer.pixel(x: x, y: Int(inner.minY)))
                pixels.append(buffer.pixel(x: x, y: Int(inner.maxY) - 1))
            }
        }
        return pixels
    }

    /// Scans left and right from the rect along its middle row until the background color ends.
    static func margins(_ buffer: PixelBuffer, _ rect: CGRect, _ background: RGBA) -> (Int?, Int?) {
        let y = Int(rect.midY)
        func scan(from start: Int, step: Int) -> Int? {
            var x = start
            var distance = 0
            while x >= 0, x < buffer.width {
                if buffer.pixel(x: x, y: y).distance(to: background) > 60 { return distance }
                x += step
                distance += 1
            }
            return nil
        }
        return (scan(from: Int(rect.minX) - 1, step: -1), scan(from: Int(rect.maxX), step: 1))
    }

    static func clamp(_ rect: CGRect, _ buffer: PixelBuffer) -> CGRect {
        rect.intersection(CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height))
    }

    static func median(_ pixels: [RGBA]) -> RGBA {
        guard !pixels.isEmpty else { return .white }
        func mid(_ values: [UInt8]) -> UInt8 { values.sorted()[values.count / 2] }
        return RGBA(r: mid(pixels.map(\.r)), g: mid(pixels.map(\.g)), b: mid(pixels.map(\.b)))
    }
}
