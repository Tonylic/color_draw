import CoreGraphics
import Foundation

/// A simple 8-bit RGBA bitmap (non-premultiplied, sRGB) that the engine works on.
public struct RGBAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Row-major pixels, 4 bytes each: R, G, B, A.
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0, "Image must not be empty")
        precondition(pixels.count == width * height * 4, "Pixel buffer does not match the image size")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Creates a white image.
    public init(width: Int, height: Int) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: 255, count: width * height * 4))
    }

    /// Draws `cgImage` into a new bitmap whose longest side is at most `maxDimension`,
    /// flattening any transparency onto white.
    public init?(cgImage: CGImage, maxDimension: Int) {
        let sourceWidth = cgImage.width, sourceHeight = cgImage.height
        guard sourceWidth > 0, sourceHeight > 0, maxDimension > 0 else { return nil }
        let scale = min(1, Double(maxDimension) / Double(max(sourceWidth, sourceHeight)))
        let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        guard let image = RGBAImage.render(width: width, height: height, antialias: true, draw: { context in
            // `render` flips to a top-left origin, but `draw(_:in:)` expects Core Graphics'
            // native bottom-left origin, so flip back or the photo comes out upside down.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }) else { return nil }
        self = image
    }

    /// Renders with Core Graphics into a new white bitmap. The context uses a top-left origin.
    public static func render(width: Int, height: Int, antialias: Bool, draw: (CGContext) -> Void) -> RGBAImage? {
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setShouldAntialias(antialias)
            context.setAllowsAntialiasing(antialias)
            // Flip so callers can think in top-left-origin image coordinates.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            draw(context)
            return true
        }
        guard drawn else { return nil }
        // The background was opaque white, so premultiplied and straight alpha are identical.
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    @inline(__always)
    public func color(atX x: Int, y: Int) -> RGBColor {
        let i = (y * width + x) * 4
        return RGBColor(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2])
    }

    public func makeCGImage() -> CGImage? {
        CGImage.make(rgbaBytes: pixels, width: width, height: height)
    }
}

extension CGImage {
    /// Wraps a copy of a straight-alpha RGBA8 buffer as an sRGB image.
    static func make(rgbaBytes: [UInt8], width: Int, height: Int, premultiplied: Bool = false) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgbaBytes) as CFData) else { return nil }
        let alpha: CGImageAlphaInfo = premultiplied ? .premultipliedLast : .last
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// Wraps a copy of a buffer of packed pixels (see `RGBColor.pixel`). On little-endian
    /// hardware (every Apple device) each `UInt32` lies in memory as the bytes R, G, B, A.
    static func make(pixels: [UInt32], width: Int, height: Int, premultiplied: Bool = false) -> CGImage? {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let alpha: CGImageAlphaInfo = premultiplied ? .premultipliedLast : .last
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
