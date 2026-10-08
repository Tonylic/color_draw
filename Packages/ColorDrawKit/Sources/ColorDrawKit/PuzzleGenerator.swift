import CoreGraphics
import Foundation

/// How a photo is turned into a puzzle.
public struct PuzzleSettings: Hashable, Sendable {
    /// Upper bound on the number of paint colors.
    public var colorCount: Int
    /// When set, the photo is cut into a grid of tiles (see `Tiling`). Otherwise its shapes follow
    /// the photo's own outlines, simplified with the settings below.
    public var tiles: TileSettings?
    /// Optional upper bound on the number of shapes to paint. Busy photos are simplified down to
    /// this many (the smallest shapes merge into their neighbors); simple ones may have fewer.
    public var maximumRegionCount: Int
    /// The photo is shrunk so its longest side is at most this many working pixels. Fewer pixels
    /// means bigger, simpler shapes.
    public var maxDimension: Int
    /// Regions smaller than this (in working pixels) are merged into a neighbor.
    public var minimumRegionArea: Int
    /// Regions thinner than this radius (in working pixels) are merged into a neighbor, so every
    /// region has room for its number and a child's finger.
    public var minimumRegionRadius: Float
    /// Strength of the edge-preserving smoothing that removes photo texture before quantizing.
    public var smoothingPasses: Int
    /// Palette colors closer than this (CIE76 ΔE) are merged so every number looks different.
    public var minimumColorDistance: Float
    /// Longer side ÷ shorter side above which photos are center-cropped, so panoramas don't
    /// become thin strips with slivers for shapes.
    public var maximumAspectRatio: Double

    public init(
        colorCount: Int,
        tiles: TileSettings? = nil,
        maximumRegionCount: Int = .max,
        maxDimension: Int,
        minimumRegionArea: Int,
        minimumRegionRadius: Float,
        smoothingPasses: Int,
        minimumColorDistance: Float,
        maximumAspectRatio: Double = 2
    ) {
        self.colorCount = colorCount
        self.tiles = tiles
        self.maximumRegionCount = maximumRegionCount
        self.maxDimension = maxDimension
        self.minimumRegionArea = minimumRegionArea
        self.minimumRegionRadius = minimumRegionRadius
        self.smoothingPasses = smoothingPasses
        self.minimumColorDistance = minimumColorDistance
        self.maximumAspectRatio = maximumAspectRatio
    }

    /// For about five-year-olds: up to 50 clearly different colors, in big tiles (about 700 in
    /// a 3:2 photo).
    public static let easy = PuzzleSettings(
        colorCount: 50, tiles: TileSettings(shape: .squares, alongLongSide: 32, speckleDistance: 14),
        maxDimension: 220, minimumRegionArea: 18, minimumRegionRadius: 2.0, smoothingPasses: 2, minimumColorDistance: 10
    )
    /// About 2,100 tiles in a 3:2 photo.
    public static let medium = PuzzleSettings(
        colorCount: 100, tiles: TileSettings(shape: .squares, alongLongSide: 56, speckleDistance: 11),
        maxDimension: 300, minimumRegionArea: 14, minimumRegionRadius: 1.8, smoothingPasses: 1, minimumColorDistance: 7
    )
    /// For about eight-year-olds: up to 200 colors and lots of detail (about 4,300 tiles in a 3:2
    /// photo).
    public static let hard = PuzzleSettings(
        colorCount: 200, tiles: TileSettings(shape: .squares, alongLongSide: 80, speckleDistance: 8),
        maxDimension: 400, minimumRegionArea: 12, minimumRegionRadius: 1.6, smoothingPasses: 1, minimumColorDistance: 6
    )

    /// The same settings with another tile shape.
    public func with(shape: Tiling.Shape) -> PuzzleSettings {
        var copy = self
        copy.tiles?.shape = shape
        return copy
    }
}

/// How a photo is cut into tiles.
public struct TileSettings: Hashable, Sendable {
    public var shape: Tiling.Shape
    /// How many tiles fit along the picture's longer side. Triangles come in the same number as
    /// squares would, so both shapes make puzzles of the same size.
    public var alongLongSide: Int
    /// A lone tile whose neighbors mostly share a color at most this far from its own (CIE76 ΔE)
    /// takes their color. Specks like that are hard to find and break up runs a child could
    /// paint in one swipe; really different specks (a sparkle in an eye) stay.
    public var speckleDistance: Float

    public init(shape: Tiling.Shape, alongLongSide: Int, speckleDistance: Float) {
        self.shape = shape
        self.alongLongSide = alongLongSide
        self.speckleDistance = speckleDistance
    }
}

public enum PuzzleGeneratorError: Error, Equatable {
    case unreadableImage
}

public enum PuzzleGenerator {
    /// Builds a puzzle from any image. Safe to call from a background task.
    public static func generate(from cgImage: CGImage, settings: PuzzleSettings) throws -> Puzzle {
        guard let cropped = centerCrop(cgImage, maximumAspectRatio: settings.maximumAspectRatio) else {
            throw PuzzleGeneratorError.unreadableImage
        }
        if let tiles = settings.tiles {
            return try generateTiled(from: cropped, settings: settings, tiles: tiles)
        }
        guard let image = RGBAImage(cgImage: cropped, maxDimension: settings.maxDimension) else {
            throw PuzzleGeneratorError.unreadableImage
        }
        return generate(from: image, settings: settings)
    }

    /// Trims the long sides of very wide or tall images down to `maximumAspectRatio`.
    static func centerCrop(_ image: CGImage, maximumAspectRatio: Double) -> CGImage? {
        let width = Double(image.width), height = Double(image.height)
        guard width > 0, height > 0, maximumAspectRatio >= 1 else { return nil }
        if width / height > maximumAspectRatio {
            let cropWidth = (height * maximumAspectRatio).rounded()
            return image.cropping(to: CGRect(x: ((width - cropWidth) / 2).rounded(), y: 0, width: cropWidth, height: height))
        }
        if height / width > maximumAspectRatio {
            let cropHeight = (width * maximumAspectRatio).rounded()
            return image.cropping(to: CGRect(x: 0, y: ((height - cropHeight) / 2).rounded(), width: width, height: cropHeight))
        }
        return image
    }

    /// Builds a puzzle from a bitmap. With tile settings it becomes a mosaic; otherwise (or should
    /// the bitmap somehow not convert) its shapes follow its outlines, and the bitmap must
    /// already be at working size.
    public static func generate(from image: RGBAImage, settings: PuzzleSettings) -> Puzzle {
        if settings.tiles != nil, let cgImage = image.makeCGImage(), let puzzle = try? generate(from: cgImage, settings: settings) {
            return puzzle
        }
        let width = image.width, height = image.height
        var quantized = quantize(image, settings: settings)
        if !quantized.isExact {
            quantized.result.indices = Segmentation.majorityFilter(quantized.result.indices, width: width, height: height, passes: 3)
        }

        let cleaned = Segmentation.mergeTinyRegions(
            quantized.result.indices,
            palette: quantized.result.palette,
            width: width,
            height: height,
            minimumArea: settings.minimumRegionArea,
            minimumRadius: settings.minimumRegionRadius,
            maximumCount: settings.maximumRegionCount
        )
        return assemble(indices: cleaned, palette: quantized.result.palette, width: width, height: height)
    }

    /// Picks the palette and maps every pixel to it. Flat-color artwork keeps its colors exactly
    /// (`isExact`); photos are smoothed, clustered and brightened like a storybook.
    static func quantize(_ image: RGBAImage, settings: PuzzleSettings) -> (result: Quantizer.Result, isExact: Bool) {
        var lab = LabImage(image)
        if let exact = Quantizer.exactPalette(of: image, maxColors: settings.colorCount) {
            // Skip photo clean-up, but still merge colors nobody could tell apart.
            return (Quantizer.mergeSimilarColors(exact, image: lab, minimumDistance: settings.minimumColorDistance), true)
        }
        for _ in 0..<settings.smoothingPasses {
            lab.applyBilateralFilter(radius: 2, sigmaSpace: 2, sigmaColor: 9)
        }
        var quantized = Quantizer.kMeans(lab, colorCount: settings.colorCount, seed: seed(for: image))
        quantized = Quantizer.mergeSimilarColors(quantized, image: lab, minimumDistance: settings.minimumColorDistance)
        quantized.palette = quantized.palette.map(storybook)
        return (quantized, false)
    }

    /// Packs the cleaned color map into the final puzzle: drops unused colors, orders the
    /// palette like a rainbow, and finds where each number goes.
    private static func assemble(indices: [UInt8], palette: [LabColor], width: Int, height: Int) -> Puzzle {
        var used = [Bool](repeating: false, count: palette.count)
        for index in indices { used[Int(index)] = true }
        let order = rainbowOrder(palette.indices.filter { used[$0] }.map { ($0, palette[$0]) })
        var remap = [Int](repeating: 0, count: palette.count)
        for (newIndex, oldIndex) in order.enumerated() { remap[oldIndex] = newIndex }
        let finalPalette = order.map { palette[$0].rgb }

        let components = Segmentation.connectedComponents(indices, width: width, height: height)
        precondition(components.count <= Int(UInt16.max), "Too many regions; raise minimumRegionArea")
        let distances = Segmentation.edgeDistanceSquared(components.labels, width: width, height: height)
        let labels = Segmentation.labelPlacement(components, distances: distances)

        var bounds = [(minX: Int, minY: Int, maxX: Int, maxY: Int)](repeating: (Int.max, Int.max, Int.min, Int.min), count: components.count)
        for (p, id) in components.labels.enumerated() {
            let x = p % width, y = p / width
            let i = Int(id)
            bounds[i].minX = min(bounds[i].minX, x)
            bounds[i].minY = min(bounds[i].minY, y)
            bounds[i].maxX = max(bounds[i].maxX, x)
            bounds[i].maxY = max(bounds[i].maxY, y)
        }

        let regions = (0..<components.count).map { id in
            PuzzleRegion(
                colorIndex: remap[Int(components.colors[id])],
                area: components.areas[id],
                labelX: Float(labels[id].x) + 0.5,
                labelY: Float(labels[id].y) + 0.5,
                labelRadius: labels[id].radius,
                minX: bounds[id].minX,
                minY: bounds[id].minY,
                maxX: bounds[id].maxX,
                maxY: bounds[id].maxY
            )
        }
        let regionMap = components.labels.map { UInt16($0) }
        return Puzzle(width: width, height: height, regionMap: regionMap, regions: regions, palette: finalPalette)
    }

    /// Photos make muddy, dark palettes; children enjoy brighter paint. Boost saturation and lift
    /// the deepest shadows a little, like a picture-book illustration of the photo.
    static func storybook(_ color: LabColor) -> LabColor {
        LabColor(l: 10 + color.l * 0.9, a: color.a * 1.25, b: color.b * 1.25)
    }

    /// Red → orange → yellow → green → blue → purple → pink, then grays from light to dark.
    static func rainbowOrder(_ colors: [(index: Int, color: LabColor)]) -> [Int] {
        let chromatic = colors.filter { $0.color.chroma >= 12 }
            .sorted { (($0.color.hue + 345).truncatingRemainder(dividingBy: 360)) < (($1.color.hue + 345).truncatingRemainder(dividingBy: 360)) }
        let neutral = colors.filter { $0.color.chroma < 12 }.sorted { $0.color.l > $1.color.l }
        return (chromatic + neutral).map(\.index)
    }

    /// A seed derived from the image so the same photo always gives the same puzzle.
    static func seed(for image: RGBAImage) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        let step = max(1, image.pixels.count / 4096)
        for i in Swift.stride(from: 0, to: image.pixels.count, by: step) {
            hash = (hash ^ UInt64(image.pixels[i])) &* 0x0000_0100_0000_01B3
        }
        return hash ^ UInt64(image.width << 32 | image.height)
    }
}
