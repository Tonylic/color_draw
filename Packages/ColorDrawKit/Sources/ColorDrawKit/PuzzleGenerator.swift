import CoreGraphics
import Foundation

/// How a photo is turned into a puzzle.
public struct PuzzleSettings: Hashable, Sendable {
    /// Upper bound on the number of paint colors.
    public var colorCount: Int
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
        maximumRegionCount: Int = .max,
        maxDimension: Int,
        minimumRegionArea: Int,
        minimumRegionRadius: Float,
        smoothingPasses: Int,
        minimumColorDistance: Float,
        maximumAspectRatio: Double = 2
    ) {
        self.colorCount = colorCount
        self.maximumRegionCount = maximumRegionCount
        self.maxDimension = maxDimension
        self.minimumRegionArea = minimumRegionArea
        self.minimumRegionRadius = minimumRegionRadius
        self.smoothingPasses = smoothingPasses
        self.minimumColorDistance = minimumColorDistance
        self.maximumAspectRatio = maximumAspectRatio
    }

    /// For about five-year-olds: up to 50 colors, in fairly big shapes.
    public static let easy = PuzzleSettings(colorCount: 50, maxDimension: 220, minimumRegionArea: 18, minimumRegionRadius: 2.0, smoothingPasses: 2, minimumColorDistance: 7)
    public static let medium = PuzzleSettings(colorCount: 100, maxDimension: 300, minimumRegionArea: 14, minimumRegionRadius: 1.8, smoothingPasses: 1, minimumColorDistance: 5)
    /// For about eight-year-olds: up to 200 colors and lots of detail.
    public static let hard = PuzzleSettings(colorCount: 200, maxDimension: 400, minimumRegionArea: 12, minimumRegionRadius: 1.6, smoothingPasses: 1, minimumColorDistance: 4)
}

public enum PuzzleGeneratorError: Error, Equatable {
    case unreadableImage
}

public enum PuzzleGenerator {
    /// Builds a puzzle from any image. Safe to call from a background task.
    public static func generate(from cgImage: CGImage, settings: PuzzleSettings) throws -> Puzzle {
        guard let cropped = centerCrop(cgImage, maximumAspectRatio: settings.maximumAspectRatio),
              let image = RGBAImage(cgImage: cropped, maxDimension: settings.maxDimension) else {
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

    /// Builds a puzzle from a bitmap that is already at working size.
    public static func generate(from image: RGBAImage, settings: PuzzleSettings) -> Puzzle {
        let width = image.width, height = image.height
        var lab = LabImage(image)
        var quantized: Quantizer.Result
        if let exact = Quantizer.exactPalette(of: image, maxColors: settings.colorCount) {
            // Flat-color artwork: keep its colors exactly and skip photo clean-up, but still merge
            // colors nobody could tell apart.
            quantized = Quantizer.mergeSimilarColors(exact, image: lab, minimumDistance: settings.minimumColorDistance)
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
            minimumRadius: settings.minimumRegionRadius,
            maximumCount: settings.maximumRegionCount
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
