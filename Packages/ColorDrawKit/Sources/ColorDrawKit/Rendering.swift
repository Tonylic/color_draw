import CoreGraphics
import CoreText
import Foundation

/// Colors used to draw a puzzle that is being painted.
public struct CanvasStyle: Sendable {
    public var blank: RGBColor
    public var highlightLight: RGBColor
    public var highlightDark: RGBColor
    public var outline: RGBColor
    public var number: RGBColor

    public init(blank: RGBColor, highlightLight: RGBColor, highlightDark: RGBColor, outline: RGBColor, number: RGBColor) {
        self.blank = blank
        self.highlightLight = highlightLight
        self.highlightDark = highlightDark
        self.outline = outline
        self.number = number
    }

    public static let standard = CanvasStyle(
        blank: RGBColor(hex: 0xFFFFFF),
        highlightLight: RGBColor(hex: 0xE4E7F0),
        highlightDark: RGBColor(hex: 0xCDD3E2),
        outline: RGBColor(hex: 0x4C4560),
        number: RGBColor(hex: 0x5A5372)
    )
}

/// What a region looks like right now.
public enum RegionAppearance: Hashable, Sendable {
    /// Not painted yet.
    case blank
    /// Not painted yet, and its color is the one selected: striped so children can find it.
    case highlighted
    /// Painted.
    case painted(RGBColor)
}

/// The high-res bitmap of painted / blank / highlighted regions shown under the outlines.
/// Updating a region rewrites only the pixels inside its bounding box.
public final class PaintBuffer {
    public let detail: DetailMap
    public let style: CanvasStyle
    private var pixels: [UInt32]
    private let stripePeriod: Int

    public init(detail: DetailMap, style: CanvasStyle = .standard) {
        self.detail = detail
        self.style = style
        pixels = [UInt32](repeating: style.blank.pixel, count: detail.width * detail.height)
        stripePeriod = max(8, detail.scale * 2)
    }

    /// Redraws every region.
    public func render(_ appearance: (Int) -> RegionAppearance) {
        let lookup = detail.bounds.indices.map { appearance($0) }
        let blank = style.blank.pixel
        let light = style.highlightLight.pixel, dark = style.highlightDark.pixel
        let width = detail.width
        let period = stripePeriod
        let colors: [UInt32] = lookup.map {
            switch $0 {
            case .blank: return blank
            case .highlighted: return 0 // Marker: draw stripes.
            case let .painted(color): return color.pixel
            }
        }
        detail.labels.withUnsafeBufferPointer { labels in
            pixels.withUnsafeMutableBufferPointer { out in
                for y in 0..<detail.height {
                    let row = y * width
                    for x in 0..<width {
                        let color = colors[Int(labels[row + x])]
                        out[row + x] = color != 0 ? color : (((x + y) / (period / 2)) & 1 == 0 ? light : dark)
                    }
                }
            }
        }
    }

    /// Redraws a single region.
    public func update(region: Int, to appearance: RegionAppearance) {
        let bounds = detail.bounds[region]
        guard !bounds.isEmpty else { return }
        let width = detail.width
        let half = stripePeriod / 2
        let id = UInt16(region)
        let light = style.highlightLight.pixel, dark = style.highlightDark.pixel
        let solid: UInt32? = switch appearance {
        case .blank: style.blank.pixel
        case .highlighted: nil
        case let .painted(color): color.pixel
        }
        detail.labels.withUnsafeBufferPointer { labels in
            pixels.withUnsafeMutableBufferPointer { out in
                for y in bounds.minY...bounds.maxY {
                    let row = y * width
                    for x in bounds.minX...bounds.maxX where labels[row + x] == id {
                        out[row + x] = solid ?? (((x + y) / half) & 1 == 0 ? light : dark)
                    }
                }
            }
        }
    }

    public func makeImage() -> CGImage? {
        CGImage.make(pixels: pixels, width: detail.width, height: detail.height)
    }
}

public enum OutlineRenderer {
    /// A transparent image with lines along every region border. Lines are two high-res pixels
    /// wide with a faint one-pixel halo, so they look smooth both zoomed out and zoomed in.
    public static func makeImage(_ detail: DetailMap, color: RGBColor) -> CGImage? {
        let w = detail.width, h = detail.height
        var strength = [UInt8](repeating: 0, count: w * h)
        detail.labels.withUnsafeBufferPointer { labels in
            for y in 0..<h {
                for x in 0..<w {
                    let p = y * w + x
                    if x + 1 < w, labels[p] != labels[p + 1] {
                        strength[p] = 255
                        strength[p + 1] = 255
                    }
                    if y + 1 < h, labels[p] != labels[p + w] {
                        strength[p] = 255
                        strength[p + w] = 255
                    }
                }
            }
        }
        var halo = strength
        for y in 0..<h {
            for x in 0..<w where strength[y * w + x] == 0 {
                let p = y * w + x
                let touches = (x > 0 && strength[p - 1] == 255) || (x + 1 < w && strength[p + 1] == 255)
                    || (y > 0 && strength[p - w] == 255) || (y + 1 < h && strength[p + w] == 255)
                if touches { halo[p] = 80 }
            }
        }
        var pixels = [UInt32](repeating: 0, count: w * h)
        for p in 0..<(w * h) where halo[p] > 0 {
            let a = UInt32(halo[p])
            // Premultiplied RGBA.
            let r = UInt32(color.r) * a / 255, g = UInt32(color.g) * a / 255, b = UInt32(color.b) * a / 255
            pixels[p] = r | g << 8 | b << 16 | a << 24
        }
        return CGImage.make(pixels: pixels, width: w, height: h, premultiplied: true)
    }
}

/// Draws region numbers with Core Text. Thread-safe: used from `CATiledLayer` background drawing.
public enum NumberRenderer {
    /// Font size (in the same units as `pixelSize`, the size of one working pixel) that fits the
    /// number inside its region, capped so huge areas don't get giant numbers.
    public static func fontSize(for region: PuzzleRegion, in puzzle: Puzzle, pixelSize: CGFloat) -> CGFloat {
        let diameter = CGFloat(region.labelRadius) * 2 * pixelSize
        // Two-digit numbers are wider, so they need to shrink to stay inside the shape.
        let widthFactor: CGFloat = region.colorIndex >= 9 ? 0.62 : 0.85
        let cap = CGFloat(min(puzzle.width, puzzle.height)) * pixelSize * 0.09
        return min(diameter * widthFactor, cap)
    }

    /// Draws `text` centered on `center` in a top-left-origin context.
    public static func draw(_ text: String, centeredAt center: CGPoint, font: CTFont, color: CGColor, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let capHeight = CTFontGetCapHeight(font)
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: center.x - CGFloat(width) / 2, y: center.y + capHeight / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

public enum PuzzleSnapshot {
    /// Renders the puzzle as it currently looks — painted regions, outlines and optionally the
    /// numbers of unpainted regions — into an image `outputWidth` pixels wide.
    public static func render(
        puzzle: Puzzle,
        detail: DetailMap,
        appearance: (Int) -> RegionAppearance,
        outputWidth: Int,
        showOutlines: Bool = true,
        numberFont: CTFont? = nil,
        style: CanvasStyle = .standard
    ) -> CGImage? {
        let buffer = PaintBuffer(detail: detail, style: style)
        buffer.render(appearance)
        guard let paint = buffer.makeImage() else { return nil }
        let outputHeight = max(1, Int((Double(outputWidth) * Double(puzzle.height) / Double(puzzle.width)).rounded()))
        guard let context = CGContext(
            data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        context.interpolationQuality = .high
        context.draw(paint, in: rect)
        if showOutlines, let outline = OutlineRenderer.makeImage(detail, color: style.outline) {
            context.draw(outline, in: rect)
        }
        if let numberFont {
            context.translateBy(x: 0, y: CGFloat(outputHeight))
            context.scaleBy(x: 1, y: -1)
            let pixelSize = CGFloat(outputWidth) / CGFloat(puzzle.width)
            let color = CGColor(srgbRed: CGFloat(style.number.r) / 255, green: CGFloat(style.number.g) / 255, blue: CGFloat(style.number.b) / 255, alpha: 1)
            for (index, region) in puzzle.regions.enumerated() {
                if case .painted = appearance(index) { continue }
                let text = String(region.colorIndex + 1)
                let size = NumberRenderer.fontSize(for: region, in: puzzle, pixelSize: pixelSize)
                guard size >= 4 else { continue }
                let font = CTFontCreateCopyWithAttributes(numberFont, size, nil, nil)
                let center = CGPoint(x: CGFloat(region.labelX) * pixelSize, y: CGFloat(region.labelY) * pixelSize)
                NumberRenderer.draw(text, centeredAt: center, font: font, color: color, in: context)
            }
        }
        return context.makeImage()
    }
}
