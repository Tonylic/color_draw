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

    /// The pale "ghost" of a paint: a light, washed-out hint of it (like a faded photo), light
    /// enough for dark numbers to stay easy to read and clearly paler than real paint.
    public func ghost(of paint: RGBColor) -> RGBColor {
        let lab = paint.lab
        let chroma = lab.chroma
        // Keep a little of the hue so the picture is recognizable, never more than a tint.
        let keep = chroma > 0 ? min(0.4, 16 / chroma) : 0
        return LabColor(l: 84 + 0.13 * lab.l, a: lab.a * keep, b: lab.b * keep).rgb
    }

    public static let standard = CanvasStyle(
        // Warm paper rather than pure white, so painting a white shape visibly changes it.
        blank: RGBColor(hex: 0xF9F6F0),
        // Lavender stripes for gray, black, white and beige paints, which have no tint to show:
        // clearly different from the gray ghosts of those paints.
        highlightLight: RGBColor(hex: 0xECE8FA),
        highlightDark: RGBColor(hex: 0xD2CAF2),
        outline: RGBColor(hex: 0x4C4560),
        number: RGBColor(hex: 0x5A5372)
    )
}

/// What a region looks like right now.
public enum RegionAppearance: Hashable, Sendable {
    /// Not painted yet.
    case blank
    /// Not painted yet, showing a very pale gray hint of its final color. Pictures with hundreds of
    /// shapes would otherwise be just a web of lines; this keeps the photo faintly recognizable.
    case ghost(RGBColor)
    /// Not painted yet, and its color is the one selected: striped (in a light tint of the
    /// selected paint) so children can find it.
    case highlighted
    /// Painted.
    case painted(RGBColor)
}

/// The high-res bitmap of painted / blank / highlighted regions shown under the outlines.
/// Updating a region rewrites only the pixels inside its bounding box.
///
/// Mosaics carry their grid lines in this bitmap rather than in a separate outline image: lines
/// are drawn only on tiles that aren't painted yet, so a finished mosaic is crisp, seamless color.
public final class PaintBuffer {
    public let detail: DetailMap
    public let style: CanvasStyle
    private var pixels: [UInt32]
    private let stripePeriod: Int
    private var stripes: (light: UInt32, dark: UInt32)
    private let gridLineOpacity: Float
    /// Mosaics: how strongly each pixel is covered by a grid line (0–255). Made on first use,
    /// so a fully painted picture never needs it.
    private lazy var gridLines: [UInt8]? = detail.tiling != nil && gridLineOpacity > 0
        ? Self.gridLineCoverage(detail, opacity: gridLineOpacity)
        : nil

    /// How dark grid lines are, as a fraction of the outline color: lighter for small tiles, whose
    /// dense grid would otherwise veil the picture when it's seen whole.
    static func gridLineStrength(tileSize: Float) -> Float {
        min(0.5, max(0.35, 0.2 + tileSize * 0.0075))
    }

    /// - Parameter gridLineOpacity: Scales mosaic grid lines (`0` hides them), e.g. for small
    ///   thumbnails where full-strength lines would cover the picture.
    public init(detail: DetailMap, style: CanvasStyle = .standard, gridLineOpacity: Float = 1) {
        self.detail = detail
        self.style = style
        pixels = [UInt32](repeating: style.blank.pixel, count: detail.width * detail.height)
        stripePeriod = max(10, detail.scale * 3)
        stripes = (style.highlightLight.pixel, style.highlightDark.pixel)
        self.gridLineOpacity = gridLineOpacity
    }

    /// Anti-aliased lines along the tiles' shared edges, about 3.5% of a tile wide (at least
    /// 1.4 pixels).
    private static func gridLineCoverage(_ detail: DetailMap, opacity: Float) -> [UInt8] {
        // The side of a square of the same area as a tile.
        let tileSize = (Float(detail.width * detail.height) / Float(max(1, detail.bounds.count))).squareRoot()
        let halfWidth = max(0.7, tileSize * 0.0175)
        let strength = gridLineStrength(tileSize: tileSize) * min(1, opacity) * 255
        return detail.margins.map { margin in
            guard margin < 255 else { return 0 }
            let coverage = min(1, max(0, halfWidth + 0.5 - Float(margin) / 32))
            return UInt8((coverage * strength).rounded())
        }
    }

    /// `base` with `line` laid over it at `alpha` (0–255).
    @inline(__always)
    private static func blend(_ base: UInt32, _ line: UInt32, alpha: UInt8) -> UInt32 {
        let a = UInt32(alpha), keep = 255 - a
        let r = ((base & 0xFF) * keep + (line & 0xFF) * a) / 255
        let g = ((base >> 8 & 0xFF) * keep + (line >> 8 & 0xFF) * a) / 255
        let b = ((base >> 16 & 0xFF) * keep + (line >> 16 & 0xFF) * a) / 255
        return r | g << 8 | b << 16 | 0xFF00_0000
    }

    /// Tints the stripes of highlighted regions with the selected paint (`nil`: neutral stripes).
    /// Takes effect on the next `render` / `update`.
    public func setHighlightTint(_ paint: RGBColor?) {
        if let paint, let tint = Self.stripeColors(for: paint) {
            stripes = (tint.light.pixel, tint.dark.pixel)
        } else {
            stripes = (style.highlightLight.pixel, style.highlightDark.pixel)
        }
    }

    /// Two pale tints of a paint, light enough that dark numbers stay easy to read on them.
    /// Returns `nil` for paints too pale or gray to make a visible tint.
    public static func stripeColors(for paint: RGBColor) -> (light: RGBColor, dark: RGBColor)? {
        let lab = paint.lab
        guard lab.chroma >= 18 else { return nil }
        let scale = min(1, 34 / lab.chroma)
        let light = LabColor(l: 93, a: lab.a * scale * 0.55, b: lab.b * scale * 0.55)
        let dark = LabColor(l: 84, a: lab.a * scale, b: lab.b * scale)
        return (light.rgb, dark.rgb)
    }

    /// Redraws every region.
    public func render(_ appearance: (Int) -> RegionAppearance) {
        let lookup = detail.bounds.indices.map { appearance($0) }
        let blank = style.blank.pixel
        let (light, dark) = stripes
        let width = detail.width
        let period = stripePeriod
        let colors: [UInt32] = lookup.map {
            switch $0 {
            case .blank: return blank
            case let .ghost(paint): return style.ghost(of: paint).pixel
            case .highlighted: return 0 // Marker: draw stripes.
            case let .painted(color): return color.pixel
            }
        }
        // Grid lines go on tiles that aren't painted yet.
        let lined: [Bool] = lookup.map {
            if case .painted = $0 { return false }
            return true
        }
        let gridLines = lined.contains(true) ? self.gridLines : nil
        let lineColor = style.outline.pixel
        detail.labels.withUnsafeBufferPointer { labels in
            pixels.withUnsafeMutableBufferPointer { out in
                for y in 0..<detail.height {
                    let row = y * width
                    for x in 0..<width {
                        let id = Int(labels[row + x])
                        let color = colors[id]
                        var pixel = color != 0 ? color : (((x + y) / (period / 2)) & 1 == 0 ? light : dark)
                        if let gridLines, lined[id], gridLines[row + x] > 0 {
                            pixel = Self.blend(pixel, lineColor, alpha: gridLines[row + x])
                        }
                        out[row + x] = pixel
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
        let (light, dark) = stripes
        let solid: UInt32? = switch appearance {
        case .blank: style.blank.pixel
        case let .ghost(paint): style.ghost(of: paint).pixel
        case .highlighted: nil
        case let .painted(color): color.pixel
        }
        let gridLines: [UInt8]? = if case .painted = appearance { nil } else { self.gridLines }
        let lineColor = style.outline.pixel
        detail.labels.withUnsafeBufferPointer { labels in
            pixels.withUnsafeMutableBufferPointer { out in
                for y in bounds.minY...bounds.maxY {
                    let row = y * width
                    for x in bounds.minX...bounds.maxX where labels[row + x] == id {
                        var pixel = solid ?? (((x + y) / half) & 1 == 0 ? light : dark)
                        if let gridLines, gridLines[row + x] > 0 {
                            pixel = Self.blend(pixel, lineColor, alpha: gridLines[row + x])
                        }
                        out[row + x] = pixel
                    }
                }
            }
        }
    }

    /// A copy of part of the bitmap (inclusive pixel bounds, clamped to the picture), so a canvas
    /// can refresh just the tiles a paint stroke touched instead of the whole picture.
    public func makeImage(minX: Int, minY: Int, maxX: Int, maxY: Int) -> CGImage? {
        let x0 = max(0, minX), y0 = max(0, minY)
        let x1 = min(detail.width - 1, maxX), y1 = min(detail.height - 1, maxY)
        guard x1 >= x0, y1 >= y0 else { return nil }
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        var tile = [UInt32](repeating: 0, count: w * h)
        let width = detail.width
        pixels.withUnsafeBufferPointer { source in
            tile.withUnsafeMutableBufferPointer { destination in
                for row in 0..<h {
                    let from = source.baseAddress! + (y0 + row) * width + x0
                    (destination.baseAddress! + row * w).update(from: from, count: w)
                }
            }
        }
        return CGImage.make(pixels: tile, width: w, height: h, alpha: .noneSkipLast)
    }

    /// The bitmap as an opaque image (opaque, so Core Animation can draw it without blending).
    public func makeImage() -> CGImage? {
        CGImage.make(pixels: pixels, width: detail.width, height: detail.height, alpha: .noneSkipLast)
    }
}

public enum OutlineRenderer {
    /// How far from the true border the line reaches, in high-res pixels (it fades out over the
    /// last pixel).
    static let halfWidth: Float = 1.6

    /// A transparent image with smooth, anti-aliased lines along every region border.
    ///
    /// The line follows the zero crossing of `DetailMap.margins` (which changes smoothly) rather
    /// than the pixel staircase of the region map, so it stays smooth when the picture is zoomed
    /// in. Where the margins don't describe a border (regions restored without smoothing), the
    /// border pixels are simply drawn solid.
    /// Mosaics carry their grid lines in the paint (see `PaintBuffer`), so for them this returns
    /// `nil`.
    public static func makeImage(_ detail: DetailMap, color: RGBColor) -> CGImage? {
        guard detail.tiling == nil else { return nil }
        let w = detail.width, h = detail.height
        var pixels = [UInt32](repeating: 0, count: w * h)
        detail.labels.withUnsafeBufferPointer { labels in
            detail.margins.withUnsafeBufferPointer { margins in
                for y in 0..<h {
                    for x in 0..<w {
                        let p = y * w + x
                        let id = labels[p]
                        let isBorder = (x > 0 && labels[p - 1] != id) || (x + 1 < w && labels[p + 1] != id)
                            || (y > 0 && labels[p - w] != id) || (y + 1 < h && labels[p + w] != id)
                        let margin = margins[p]
                        guard margin < 255 || isBorder else { continue }

                        var coverage: Float = 0
                        if margin < 255 {
                            // Distance to the border ≈ margin ÷ how fast the margin changes here.
                            var slope: Float = 0
                            let m = Float(margin)
                            func compare(_ q: Int) {
                                let n = margins[q]
                                if n < 255 { slope = max(slope, abs(Float(n) - m)) }
                            }
                            if x > 0 { compare(p - 1) }
                            if x + 1 < w { compare(p + 1) }
                            if y > 0 { compare(p - w) }
                            if y + 1 < h { compare(p + w) }
                            if slope > 0 {
                                coverage = min(1, max(0, halfWidth + 0.5 - m / slope))
                            }
                        }
                        if isBorder && coverage == 0 { coverage = 1 }
                        guard coverage > 0 else { continue }

                        let a = UInt32((coverage * 255).rounded())
                        // Premultiplied RGBA.
                        let r = UInt32(color.r) * a / 255, g = UInt32(color.g) * a / 255, b = UInt32(color.b) * a / 255
                        pixels[p] = r | g << 8 | b << 16 | a << 24
                    }
                }
            }
        }
        return CGImage.make(pixels: pixels, width: w, height: h, alpha: .premultipliedLast)
    }
}

/// Draws region numbers with Core Text. Thread-safe: used from `CATiledLayer` background drawing.
public enum NumberRenderer {
    /// Font size (in the same units as `pixelSize`, the size of one working pixel) that fits the
    /// number inside its region, capped so huge areas don't get giant numbers.
    public static func fontSize(for region: PuzzleRegion, in puzzle: Puzzle, pixelSize: CGFloat) -> CGFloat {
        let diameter = CGFloat(region.labelRadius) * 2 * pixelSize
        // Longer numbers are wider, so they need to shrink to stay inside the shape. In a mosaic
        // every number is sized for the longest one (single digits are as big as double digits),
        // so the grid looks even.
        let widthFactor: CGFloat = switch puzzle.tiling != nil ? puzzle.palette.count : region.colorIndex + 1 {
        case ..<10: 0.85
        case ..<100: 0.62
        default: 0.46
        }
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
    /// A transparent image, one pixel per working pixel, with `regions` filled in `color`: a
    /// quick overlay to make those regions light up.
    public static func mask(of puzzle: Puzzle, regions: some Sequence<Int>, color: RGBColor) -> CGImage? {
        var included = [Bool](repeating: false, count: puzzle.regions.count)
        for region in regions where included.indices.contains(region) { included[region] = true }
        let paint = color.pixel
        var pixels = [UInt32](repeating: 0, count: puzzle.width * puzzle.height)
        for (p, region) in puzzle.regionMap.enumerated() where included[Int(region)] {
            pixels[p] = paint
        }
        return CGImage.make(pixels: pixels, width: puzzle.width, height: puzzle.height, alpha: .premultipliedLast)
    }

    /// A small picture of a puzzle, either fully painted or not painted at all (just outlines, or
    /// outlines over the pale ghost picture for `ghost`). Painted mosaics have no grid lines.
    public static func thumbnail(of puzzle: Puzzle, painted: Bool, ghost: Bool = false, outlineOpacity: CGFloat = 1, width: Int) -> CGImage? {
        let scale = max(1, min(4, Int((Double(width * 2) / Double(puzzle.width)).rounded(.up))))
        let detail = DetailMap(puzzle: puzzle, scale: scale)
        return render(
            puzzle: puzzle,
            detail: detail,
            appearance: { region in
                let paint = puzzle.palette[puzzle.regions[region].colorIndex]
                return painted ? .painted(paint) : (ghost ? .ghost(paint) : .blank)
            },
            outputWidth: width,
            outlineOpacity: outlineOpacity
        )
    }

    /// Renders the puzzle as it currently looks — painted regions, outlines and optionally the
    /// numbers of unpainted regions — into an image `outputWidth` pixels wide.
    public static func render(
        puzzle: Puzzle,
        detail: DetailMap,
        appearance: (Int) -> RegionAppearance,
        outputWidth: Int,
        showOutlines: Bool = true,
        outlineOpacity: CGFloat = 1,
        numberFont: CTFont? = nil,
        style: CanvasStyle = .standard
    ) -> CGImage? {
        // Mosaics carry their grid lines in the paint itself.
        let isMosaic = detail.tiling != nil
        let buffer = PaintBuffer(detail: detail, style: style, gridLineOpacity: showOutlines ? Float(outlineOpacity) : 0)
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
        if showOutlines, !isMosaic, outlineOpacity > 0, let outline = OutlineRenderer.makeImage(detail, color: style.outline) {
            context.saveGState()
            context.setAlpha(outlineOpacity)
            context.draw(outline, in: rect)
            context.restoreGState()
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
