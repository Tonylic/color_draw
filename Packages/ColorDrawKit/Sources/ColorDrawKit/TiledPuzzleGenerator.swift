import CoreGraphics
import Foundation

extension PuzzleGenerator {
    /// Working pixels along the side of a square tile. Triangles have the same area.
    static let tilePixels = 8.0

    /// Cuts a photo into tiles. Each tile takes the color most of its pixels have after
    /// quantizing (so tiles on an edge pick a side instead of a muddy blend), then lone specks
    /// blend into their surroundings.
    static func generateTiled(from cgImage: CGImage, settings: PuzzleSettings, tiles: TileSettings) throws -> Puzzle {
        let plan = planTiling(imageWidth: cgImage.width, imageHeight: cgImage.height, tiles: tiles)
        guard let cropped = centerCrop(cgImage, toAspect: Double(plan.width) / Double(plan.height)),
              let image = RGBAImage(cgImage: cropped, width: plan.width, height: plan.height) else {
            throw PuzzleGeneratorError.unreadableImage
        }
        let (quantized, isExact) = quantize(image, settings: settings)
        let palette = quantized.palette
        let tiling = plan.tiling
        let width = plan.width, height = plan.height
        let layout = TileLayout(tiling, width: Double(width), height: Double(height))

        // Every working pixel votes for its tile's color.
        let tileCount = tiling.tileCount
        let colorCount = palette.count
        var votes = [UInt16](repeating: 0, count: tileCount * colorCount)
        var regionMap = [UInt16](repeating: 0, count: width * height)
        var areas = [Int](repeating: 0, count: tileCount)
        var bounds = [PixelBounds](repeating: .empty, count: tileCount)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * width + x
                let tile = layout.tile(atX: Double(x) + 0.5, y: Double(y) + 0.5)
                regionMap[p] = UInt16(tile)
                areas[tile] += 1
                votes[tile * colorCount + Int(quantized.indices[p])] += 1
                bounds[tile].minX = min(bounds[tile].minX, x)
                bounds[tile].maxX = max(bounds[tile].maxX, x)
                bounds[tile].minY = min(bounds[tile].minY, y)
                bounds[tile].maxY = max(bounds[tile].maxY, y)
            }
        }
        var colors = [Int](repeating: 0, count: tileCount)
        for tile in 0..<tileCount {
            let row = tile * colorCount
            var best = 0
            for color in 1..<max(colorCount, 1) where votes[row + color] > votes[row + best] { best = color }
            colors[tile] = best
        }
        // Flat artwork keeps its exact colors; photo noise gets cleaned up.
        if !isExact {
            removeSpecks(&colors, tiling: tiling, palette: palette, maximumDistance: tiles.speckleDistance)
            mergeRareColors(&colors, tiling: tiling, palette: palette, maximumDistance: tiles.speckleDistance * 1.5)
        }

        var used = [Bool](repeating: false, count: colorCount)
        for color in colors { used[color] = true }
        let order = rainbowOrder(palette.indices.filter { used[$0] }.map { ($0, palette[$0]) })
        var remap = [Int](repeating: 0, count: colorCount)
        for (newIndex, oldIndex) in order.enumerated() { remap[oldIndex] = newIndex }

        let regions = (0..<tileCount).map { tile in
            let label = layout.label(of: tile)
            return PuzzleRegion(
                colorIndex: remap[colors[tile]],
                area: areas[tile],
                labelX: Float(label.x),
                labelY: Float(label.y),
                labelRadius: Float(label.radius),
                minX: bounds[tile].minX,
                minY: bounds[tile].minY,
                maxX: bounds[tile].maxX,
                maxY: bounds[tile].maxY
            )
        }
        return Puzzle(width: width, height: height, regionMap: regionMap, regions: regions, palette: order.map { palette[$0].rgb }, tiling: tiling)
    }

    /// The tile grid for a photo of the given size, and the picture's size in working pixels.
    static func planTiling(imageWidth: Int, imageHeight: Int, tiles: TileSettings) -> (tiling: Tiling, width: Int, height: Int) {
        var long = max(2, tiles.alongLongSide)
        while true {
            let plan = planTiling(imageWidth: imageWidth, imageHeight: imageHeight, shape: tiles.shape, alongLongSide: long)
            // Region ids are 16-bit: absurdly fine grids get coarser until they fit.
            if plan.tiling.tileCount <= Tiling.maximumTileCount || long <= 2 { return plan }
            long = long * 9 / 10
        }
    }

    private static func planTiling(imageWidth: Int, imageHeight: Int, shape: Tiling.Shape, alongLongSide: Int) -> (tiling: Tiling, width: Int, height: Int) {
        let aspect = Double(max(imageWidth, 1)) / Double(max(imageHeight, 1))
        let long = Double(alongLongSide)
        // The picture's size, measured in square tiles.
        let across = aspect >= 1 ? long : max(1, (long * aspect).rounded())
        let down = aspect >= 1 ? max(1, (long / aspect).rounded()) : long
        switch shape {
        case .squares:
            let tiling = Tiling(shape: .squares, columns: Int(across), rows: Int(down))
            return (tiling, tiling.columns * Int(tilePixels), tiling.rows * Int(tilePixels))
        case .triangles:
            // Equilateral triangles as big as a square tile: a side is 1.52 squares long, so
            // neighboring triangles' centers are 0.76 squares apart and a row is 1.32 squares tall.
            let side = (4 / 3.0.squareRoot()).squareRoot()
            let step = side / 2, rowHeight = side * 3.0.squareRoot() / 2
            let steps = max(1, Int((across / step).rounded()))
            let rows = max(1, Int((down / rowHeight).rounded()))
            return (
                Tiling(shape: .triangles, columns: steps + 1, rows: rows),
                Int((Double(steps) * step * tilePixels).rounded()),
                Int((Double(rows) * rowHeight * tilePixels).rounded())
            )
        }
    }

    /// Trims an image's long sides so it has the given width ÷ height.
    static func centerCrop(_ image: CGImage, toAspect aspect: Double) -> CGImage? {
        let width = Double(image.width), height = Double(image.height)
        guard width > 0, height > 0, aspect > 0 else { return nil }
        if width / height > aspect {
            let cropWidth = max(1, (height * aspect).rounded())
            return image.cropping(to: CGRect(x: ((width - cropWidth) / 2).rounded(), y: 0, width: cropWidth, height: height))
        }
        let cropHeight = max(1, (width / aspect).rounded())
        guard cropHeight < height else { return image }
        return image.cropping(to: CGRect(x: 0, y: ((height - cropHeight) / 2).rounded(), width: width, height: cropHeight))
    }

    /// A tile that matches none of its neighbors, while most of them share a color close to its
    /// own, takes that color. Tiles are updated in reading order (so a checkerboard of two close
    /// shades settles instead of flipping back and forth).
    static func removeSpecks(_ colors: inout [Int], tiling: Tiling, palette: [LabColor], maximumDistance: Float) {
        let limit = maximumDistance * maximumDistance
        for _ in 0..<2 {
            var changed = false
            for tile in colors.indices {
                let own = colors[tile]
                let neighbors = tiling.neighbors(of: tile)
                guard !neighbors.contains(where: { colors[$0] == own }) else { continue }
                var best = own, bestCount = 0, bestDistance = Float.infinity
                for neighbor in neighbors {
                    let color = colors[neighbor]
                    let count = neighbors.reduce(0) { $0 + (colors[$1] == color ? 1 : 0) }
                    let distance = palette[own].distanceSquared(to: palette[color])
                    if count > bestCount || (count == bestCount && distance < bestDistance) {
                        best = color
                        bestCount = count
                        bestDistance = distance
                    }
                }
                guard bestCount * 2 >= neighbors.count, bestDistance <= limit else { continue }
                colors[tile] = best
                changed = true
            }
            if !changed { break }
        }
    }

    /// A color used by only a tile or two is one more number to hunt for in the chart. If such a
    /// tile has a neighbor of a similar color, it takes that color instead.
    static func mergeRareColors(_ colors: inout [Int], tiling: Tiling, palette: [LabColor], maximumDistance: Float, maximumTiles: Int = 2) {
        var counts = [Int](repeating: 0, count: palette.count)
        for color in colors { counts[color] += 1 }
        let limit = maximumDistance * maximumDistance
        for tile in colors.indices where counts[colors[tile]] <= maximumTiles {
            let own = colors[tile]
            let closest = tiling.neighbors(of: tile).map { colors[$0] }.filter { $0 != own }
                .min { palette[own].distanceSquared(to: palette[$0]) < palette[own].distanceSquared(to: palette[$1]) }
            guard let closest, palette[own].distanceSquared(to: palette[closest]) <= limit else { continue }
            colors[tile] = closest
            counts[own] -= 1
            counts[closest] += 1
        }
    }
}
