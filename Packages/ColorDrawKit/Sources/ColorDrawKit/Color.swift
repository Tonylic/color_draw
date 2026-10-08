import Foundation

/// An 8-bit sRGB color.
public struct RGBColor: Codable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Creates a color from a `0xRRGGBB` literal.
    public init(hex: UInt32) {
        self.init(r: UInt8((hex >> 16) & 0xFF), g: UInt8((hex >> 8) & 0xFF), b: UInt8(hex & 0xFF))
    }

    /// The color as one opaque pixel in an RGBA8 buffer (bytes R, G, B, A in memory).
    public var pixel: UInt32 {
        UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | 0xFF00_0000
    }

    /// Relative luminance in 0...1 (WCAG definition).
    public var luminance: Double {
        0.2126 * Double(ColorMath.linear(r)) + 0.7152 * Double(ColorMath.linear(g)) + 0.0722 * Double(ColorMath.linear(b))
    }

    /// Whether dark text reads better than white text on top of this color.
    public var prefersDarkText: Bool { luminance > 0.36 }

    public var lab: LabColor { ColorMath.lab(r: r, g: g, b: b) }
}

/// A color in CIE L*a*b* (D65) space, where Euclidean distance roughly matches how different colors look.
public struct LabColor: Hashable, Sendable {
    public var l: Float
    public var a: Float
    public var b: Float

    public init(l: Float, a: Float, b: Float) {
        self.l = l
        self.a = a
        self.b = b
    }

    public var chroma: Float { (a * a + b * b).squareRoot() }

    /// Hue angle in degrees, 0..<360.
    public var hue: Float {
        let degrees = atan2(b, a) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    @inline(__always)
    public func distanceSquared(to other: LabColor) -> Float {
        let dl = l - other.l, da = a - other.a, db = b - other.b
        return dl * dl + da * da + db * db
    }

    public var rgb: RGBColor { ColorMath.rgb(from: self) }
}

enum ColorMath {
    /// sRGB byte → linear light lookup table.
    static let linearTable: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    static func linear(_ value: UInt8) -> Float { linearTable[Int(value)] }

    private static let epsilon: Float = 216.0 / 24389.0 // (6/29)^3
    private static let kappa: Float = 24389.0 / 27.0
    private static let whiteX: Float = 0.95047
    private static let whiteZ: Float = 1.08883

    @inline(__always)
    private static func f(_ t: Float) -> Float {
        t > epsilon ? cbrtf(t) : (kappa * t + 16) / 116
    }

    @inline(__always)
    private static func fInverse(_ t: Float) -> Float {
        let cube = t * t * t
        return cube > epsilon ? cube : (116 * t - 16) / kappa
    }

    static func lab(r: UInt8, g: UInt8, b: UInt8) -> LabColor {
        let lr = linear(r), lg = linear(g), lb = linear(b)
        let x = (0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb) / whiteX
        let y = 0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb
        let z = (0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb) / whiteZ
        let fx = f(x), fy = f(y), fz = f(z)
        return LabColor(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    static func rgb(from lab: LabColor) -> RGBColor {
        let fy = (lab.l + 16) / 116
        let fx = fy + lab.a / 500
        let fz = fy - lab.b / 200
        let x = fInverse(fx) * whiteX
        let y = lab.l > kappa * epsilon ? fy * fy * fy : lab.l / kappa
        let z = fInverse(fz) * whiteZ
        let lr = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let lg = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let lb = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        return RGBColor(r: encode(lr), g: encode(lg), b: encode(lb))
    }

    @inline(__always)
    private static func encode(_ linear: Float) -> UInt8 {
        let c = max(0, min(1, linear))
        let srgb = c <= 0.0031308 ? 12.92 * c : 1.055 * powf(c, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (srgb * 255).rounded())))
    }
}
