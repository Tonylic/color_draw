import CoreGraphics
import Foundation

/// How a photo is turned into a puzzle.
public struct PuzzleSettings: Hashable, Sendable {
    /// Upper bound on the number of paint colors.
    public var colorCount: Int
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

    public init(colorCount: Int, maxDimension: Int, minimumRegionArea: Int, minimumRegionRadius: Float, smoothingPasses: Int, minimumColorDistance: Float) {
        self.colorCount = colorCount
        self.maxDimension = maxDimension
        self.minimumRegionArea = minimumRegionArea
        self.minimumRegionRadius = minimumRegionRadius
        self.smoothingPasses = smoothingPasses
        self.minimumColorDistance = minimumColorDistance
    }

    public static let easy = PuzzleSettings(colorCount: 6, maxDimension: 120, minimumRegionArea: 36, minimumRegionRadius: 2.5, smoothingPasses: 3, minimumColorDistance: 18)
    public static let medium = PuzzleSettings(colorCount: 10, maxDimension: 170, minimumRegionArea: 30, minimumRegionRadius: 2.2, smoothingPasses: 3, minimumColorDistance: 14)
    public static let hard = PuzzleSettings(colorCount: 16, maxDimension: 240, minimumRegionArea: 28, minimumRegionRadius: 2.0, smoothingPasses: 2, minimumColorDistance: 10)
}

public enum PuzzleGeneratorError: Error, Equatable {
    case unreadableImage
}

public enum PuzzleGenerator {
    /// Builds a puzzle from any image. Safe to call from a background task.
    public static func generate(from cgImage: CGImage, settings: PuzzleSettings) throws -> Puzzle {
        guard let image = RGBAImage(cgImage: cgImage, maxDimension: settings.maxDimension) else {
            throw PuzzleGeneratorError.unreadableImage
        }
        return generate(from: image, settings: settings)
    }

    /// Builds a puzzle from a bitmap that is already at working size.
    public static func generate(from image: RGBAImage, settings: PuzzleSettings) -> Puzzle {
        let width = image.width, height = image.height
        var lab = LabImage(image)
        var quantized: Quantizer.Result
        if let exact = Quantizer.exactPalette(of: image, maxColors: settings.colorCount) {
            // Flat-color artwork: keep its colors exactly and skip photo clean-up.
            quantized = exact
        } else {
            for _ in 0..<settings.smoothingPasses {
                lab.applyBilateralFilter(radius: 2, sigmaSpace: 2, sigmaColor: 9)
            }
            quantized = Quantizer.kMeans(lab, colorCount: settings.colorCount, seed: seed(for: image))
            quantized = Quantizer.mergeSimilarColors(quantized, image: lab, minimumDistance: settings.minimumColorDistance)
            quantized.indices = Segmentation.majorityFilter(quantized.indices, width: width, height: height, passes: 3)
            quantized.palette = quantized.palette.map(storybook)
        }

        let cleaned = Segmentation.mergeTinyRegions(
            quantized.indices,
            palette: quantized.palette,
            width: width,
            height: height,
            minimumArea: settings.minimumRegionArea,
            minimumRadius: settings.minimumRegionRadius
        )
        return assemble(indices: cleaned, palette: quantized.palette, width: width, height: height)
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
    private static func rainbowOrder(_ colors: [(index: Int, color: LabColor)]) -> [Int] {
        let chromatic = colors.filter { $0.color.chroma >= 12 }
            .sorted { (($0.color.hue + 345).truncatingRemainder(dividingBy: 360)) < (($1.color.hue + 345).truncatingRemainder(dividingBy: 360)) }
        let neutral = colors.filter { $0.color.chroma < 12 }.sorted { $0.color.l > $1.color.l }
        return (chromatic + neutral).map(\.index)
    }

    /// A seed derived from the image so the same photo always gives the same puzzle.
    private static func seed(for image: RGBAImage) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        let step = max(1, image.pixels.count / 4096)
        for i in Swift.stride(from: 0, to: image.pixels.count, by: step) {
            hash = (hash ^ UInt64(image.pixels[i])) &* 0x0000_0100_0000_01B3
        }
        return hash ^ UInt64(image.width << 32 | image.height)
    }
}
