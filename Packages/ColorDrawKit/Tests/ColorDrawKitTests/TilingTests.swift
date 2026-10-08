import CoreGraphics
import Foundation
import Testing
@testable import ColorDrawKit

@Suite("Mosaic tiles")
struct TilingTests {
    /// Whether a point lies inside a convex polygon (or on its edge).
    private func contains(_ corners: [(x: Double, y: Double)], _ x: Double, _ y: Double) -> Bool {
        var sign = 0.0
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            let cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)
            if abs(cross) < 1e-9 { continue }
            if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
        }
        return true
    }

    @Test(arguments: Tiling.Shape.allCases)
    func everyPointBelongsToTheTileAroundIt(shape: Tiling.Shape) {
        let tiling = Tiling(shape: shape, columns: 9, rows: 5)
        let layout = TileLayout(tiling, width: 80, height: 50)
        var hits = [Int](repeating: 0, count: tiling.tileCount)
        for y in stride(from: 0.25, to: 50, by: 0.5) {
            for x in stride(from: 0.25, to: 80, by: 0.5) {
                let tile = layout.tile(atX: x, y: y)
                hits[tile] += 1
                #expect(contains(layout.corners(of: tile), x, y), "(\(x), \(y)) is not inside tile \(tile)")
            }
        }
        #expect(hits.allSatisfy { $0 > 0 }, "Every tile covers part of the picture")
        for tile in 0..<tiling.tileCount {
            let label = layout.label(of: tile)
            #expect(layout.tile(atX: label.x, y: label.y) == tile, "A number sits inside its own tile")
            #expect(label.radius > 0)
            // The label circle fits inside the tile.
            #expect(layout.distanceToSharedEdge(x: label.x, y: label.y, tile: tile) >= label.radius - 1e-6)
        }
    }

    @Test func trianglesAlternateAndHalvesSitAtTheEdges() {
        let tiling = Tiling(shape: .triangles, columns: 7, rows: 2)
        let layout = TileLayout(tiling, width: 60, height: 2 * 10 * 3.0.squareRoot())
        #expect(tiling.pointsUp(row: 0, column: 0) && !tiling.pointsUp(row: 0, column: 1) && !tiling.pointsUp(row: 1, column: 0))
        let full = layout.label(of: 3).radius, half = layout.label(of: 0).radius
        // An equilateral triangle's incircle is a third of its height.
        #expect(abs(full - layout.rowHeight / 3) < 1e-9)
        #expect(half < full && half > full / 2)
    }

    @Test(arguments: Tiling.Shape.allCases)
    func neighborsShareAnEdge(shape: Tiling.Shape) {
        let tiling = Tiling(shape: shape, columns: 6, rows: 4)
        for tile in 0..<tiling.tileCount {
            let neighbors = tiling.neighbors(of: tile)
            #expect(neighbors.count <= (shape == .squares ? 4 : 3))
            for neighbor in neighbors {
                #expect(tiling.neighbors(of: neighbor).contains(tile), "Neighbors go both ways")
            }
        }
        // A middle square has four neighbors; a corner square two.
        if shape == .squares {
            #expect(Set(tiling.neighbors(of: 7)) == [6, 8, 1, 13])
            #expect(Set(tiling.neighbors(of: 0)) == [1, 6])
        }
    }

    @Test func gridLinesFollowSharedEdgesButNotThePictureBorder() {
        let layout = TileLayout(Tiling(shape: .squares, columns: 2, rows: 2), width: 20, height: 20)
        // Next to the shared vertical edge…
        #expect(abs(layout.distanceToSharedEdge(x: 9.5, y: 5, tile: 0) - 0.5) < 1e-9)
        // …but the picture's own border doesn't count.
        #expect(abs(layout.distanceToSharedEdge(x: 0.5, y: 1, tile: 0) - 9) < 1e-9)
    }

    @Test(arguments: [("easy", PuzzleSettings.easy), ("medium", .medium), ("hard", .hard)])
    func mosaicsFollowTheLevelsGrid(level: String, settings: PuzzleSettings) throws {
        let photo = try #require(makeNoisyPhoto(width: 300, height: 200).makeCGImage())
        let tiles = try #require(settings.tiles)
        let squares = try PuzzleGenerator.generate(from: photo, settings: settings.with(shape: .squares))
        let triangles = try PuzzleGenerator.generate(from: photo, settings: settings.with(shape: .triangles))
        for (puzzle, shape) in [(squares, Tiling.Shape.squares), (triangles, .triangles)] {
            expectValid(puzzle, settings: settings.with(shape: shape))
            let tiling = try #require(puzzle.tiling)
            let layout = TileLayout(tiling, width: Double(puzzle.width), height: Double(puzzle.height))
            // The working map agrees with the tile geometry.
            for y in Swift.stride(from: 0, to: puzzle.height, by: 3) {
                for x in Swift.stride(from: 0, to: puzzle.width, by: 3) {
                    #expect(puzzle.region(atX: x, y: y) == layout.tile(atX: Double(x) + 0.5, y: Double(y) + 0.5))
                }
            }
        }
        let grid = try #require(squares.tiling)
        #expect(grid.columns == tiles.alongLongSide)
        #expect(grid.rows == Int((Double(tiles.alongLongSide) * 2 / 3).rounded()))
        // Triangles come in about as many as squares, so both make the same size of puzzle.
        let ratio = Double(triangles.regions.count) / Double(squares.regions.count)
        #expect(ratio > 0.9 && ratio < 1.15, "\(level): \(triangles.regions.count) triangles vs \(squares.regions.count) squares")
    }

    @Test(arguments: Tiling.Shape.allCases)
    func tilesTakeTheColorMostOfTheirPixelsHave(shape: Tiling.Shape) throws {
        // Red on the left 55%, blue on the right: no muddy purple tiles along the border.
        let image = try #require(RGBAImage.render(width: 400, height: 300, antialias: false) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 220, height: 300))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 220, y: 0, width: 180, height: 300))
        }?.makeCGImage())
        let puzzle = try PuzzleGenerator.generate(from: image, settings: PuzzleSettings.easy.with(shape: shape))
        #expect(Set(puzzle.palette) == [RGBColor(r: 255, g: 0, b: 0), RGBColor(r: 0, g: 0, b: 255)])
        let red = try #require(puzzle.palette.firstIndex(of: RGBColor(r: 255, g: 0, b: 0)))
        for region in puzzle.regions {
            let isLeft = region.labelX < Float(puzzle.width) * 0.55
            // Tiles right on the border may go either way; the rest match their side.
            if abs(region.labelX - Float(puzzle.width) * 0.55) > 8 {
                #expect((region.colorIndex == red) == isLeft)
            }
        }
    }

    @Test func loneSpecksBlendInButRealDetailsStay() {
        let tiling = Tiling(shape: .squares, columns: 5, rows: 5)
        // 0: sky blue, 1: a barely different blue, 2: bright yellow.
        let palette = [LabColor(l: 70, a: -10, b: -30), LabColor(l: 73, a: -10, b: -33), LabColor(l: 90, a: 0, b: 80)]
        var colors = [Int](repeating: 0, count: 25)
        colors[6] = 1
        colors[18] = 2
        PuzzleGenerator.removeSpecks(&colors, tiling: tiling, palette: palette, maximumDistance: 10)
        #expect(colors[6] == 0, "A lone tile of a barely different blue joins the sky")
        #expect(colors[18] == 2, "A star in the sky stays")
    }

    @Test func checkerboardsOfCloseShadesSettle() {
        let tiling = Tiling(shape: .squares, columns: 6, rows: 6)
        let palette = [LabColor(l: 60, a: 20, b: 20), LabColor(l: 62, a: 20, b: 22)]
        var colors = (0..<36).map { ($0 / 6 + $0 % 6) % 2 }
        PuzzleGenerator.removeSpecks(&colors, tiling: tiling, palette: palette, maximumDistance: 10)
        let alone = colors.indices.filter { tile in !tiling.neighbors(of: tile).contains { colors[$0] == colors[tile] } }
        #expect(alone.count < 4, "Most tiles end up next to a tile of their own color")
    }

    @Test func rareColorsJoinASimilarNeighbor() {
        let tiling = Tiling(shape: .squares, columns: 6, rows: 1)
        let palette = [LabColor(l: 50, a: 0, b: 0), LabColor(l: 55, a: 0, b: 0), LabColor(l: 20, a: 60, b: 0)]
        // Two tiles of color 1 (close to 0) and one of color 2 (far from everything).
        var colors = [0, 0, 0, 1, 1, 2]
        PuzzleGenerator.mergeRareColors(&colors, tiling: tiling, palette: palette, maximumDistance: 10)
        #expect(colors == [0, 0, 0, 0, 0, 2])
    }

    @Test(arguments: Tiling.Shape.allCases)
    func detailMapDrawsTilesStraightFromTheirGeometry(shape: Tiling.Shape) throws {
        let puzzle = PuzzleGenerator.generate(from: makeNoisyPhoto(), settings: PuzzleSettings.easy.with(shape: shape))
        let tiling = try #require(puzzle.tiling)
        let detail = DetailMap(puzzle: puzzle, scale: 4)
        #expect(detail.tiling == tiling)
        let layout = TileLayout(tiling, width: Double(detail.width), height: Double(detail.height))
        for y in Swift.stride(from: 0, to: detail.height, by: 7) {
            for x in Swift.stride(from: 0, to: detail.width, by: 7) {
                #expect(detail.region(atX: x, y: y) == layout.tile(atX: Double(x) + 0.5, y: Double(y) + 0.5))
            }
        }
        for (index, region) in puzzle.regions.enumerated() {
            let x = Int(region.labelX * 4), y = Int(region.labelY * 4)
            #expect(detail.region(atX: x, y: y) == index, "Tapping a number must hit its tile")
        }
        if shape == .squares {
            // Square tiles are exact pixel rectangles: 8 working pixels × 4.
            #expect(detail.bounds[0] == PixelBounds(minX: 0, minY: 0, maxX: 31, maxY: 31))
            #expect(detail.bounds[tiling.columns + 1] == PixelBounds(minX: 32, minY: 32, maxX: 63, maxY: 63))
        }
    }

    @Test func gridLinesAreOnlyDrawnOnUnpaintedTiles() throws {
        let puzzle = PuzzleGenerator.generate(from: makeNoisyPhoto(), settings: .easy)
        let detail = DetailMap(puzzle: puzzle, scale: 4)
        let buffer = PaintBuffer(detail: detail)
        let style = CanvasStyle.standard
        // Tiles 0 and 1 share the vertical edge at x = 32; pixel 31 is in tile 0, pixel 32 in tile 1.
        func pixel(_ x: Int, _ y: Int, in image: CGImage) throws -> RGBColor {
            let data = try #require(image.dataProvider?.data as Data?)
            let i = y * image.bytesPerRow + x * 4
            return RGBColor(r: data[i], g: data[i + 1], b: data[i + 2])
        }
        buffer.render { _ in .blank }
        var image = try #require(buffer.makeImage())
        #expect(try pixel(31, 16, in: image) != style.blank, "A line runs along the shared edge")
        #expect(try pixel(16, 16, in: image) == style.blank, "No line inside the tile")
        #expect(try pixel(1, 16, in: image) == style.blank, "No line along the picture's border")

        let red = RGBColor(r: 220, g: 40, b: 40)
        buffer.render { $0 == 0 || $0 == 1 ? .painted(red) : .blank }
        image = try #require(buffer.makeImage())
        #expect(try pixel(31, 16, in: image) == red, "Between two painted tiles: seamless paint")
        #expect(try pixel(32, 16, in: image) == red)
        // Painting and unpainting one tile updates it the same way a full render does.
        buffer.update(region: 1, to: .blank)
        image = try #require(buffer.makeImage())
        #expect(try pixel(31, 16, in: image) == red, "The painted side stays clean…")
        #expect(try pixel(32, 16, in: image) != style.blank, "…and the blank side gets its line back")
    }

    @Test func paintedMosaicPicturesHaveNoGridLines() throws {
        let puzzle = PuzzleGenerator.generate(from: makeNoisyPhoto(), settings: .easy)
        // One pixel per working pixel: tile 0 and its right neighbor meet at x = 8.
        func render(_ appearance: @escaping (Int) -> RegionAppearance) throws -> (CGImage, Data) {
            let image = try #require(PuzzleSnapshot.render(puzzle: puzzle, detail: DetailMap(puzzle: puzzle, scale: 1), appearance: appearance, outputWidth: puzzle.width))
            return (image, try #require(image.dataProvider?.data as Data?))
        }
        let (painted, data) = try render { .painted(puzzle.palette[puzzle.regions[$0].colorIndex]) }
        for (x, tile) in [(7, 0), (8, 1)] {
            let i = 4 * painted.bytesPerRow + x * 4
            let expected = puzzle.palette[puzzle.regions[tile].colorIndex]
            #expect(RGBColor(r: data[i], g: data[i + 1], b: data[i + 2]) == expected, "Seamless paint, no grid line")
        }
        let (blank, blankData) = try render { _ in .blank }
        let i = 4 * blank.bytesPerRow + 7 * 4
        #expect(RGBColor(r: blankData[i], g: blankData[i + 1], b: blankData[i + 2]) != CanvasStyle.standard.blank, "Unpainted tiles show the grid")
    }

    @Test func mosaicNumbersAllHaveTheSameSize() {
        let puzzle = PuzzleGenerator.generate(from: makeBusyPhoto(tile: 14, colorCount: 300), settings: .easy)
        #expect(puzzle.palette.count >= 10)
        let sizes = Set(puzzle.regions.map { NumberRenderer.fontSize(for: $0, in: puzzle, pixelSize: 1) })
        #expect(sizes.count == 1, "Single digits are as big as double digits in a grid")
    }

    @Test func mosaicsRoundTripAndRejectMismatchedTiles() throws {
        let puzzle = PuzzleGenerator.generate(from: makeNoisyPhoto(), settings: PuzzleSettings.medium.with(shape: .triangles))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        #expect(try PropertyListDecoder().decode(Puzzle.self, from: encoder.encode(puzzle)) == puzzle)

        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(puzzle)) as? [String: Any])
        var tiling = try #require(json["tiling"] as? [String: Any])
        tiling["columns"] = (tiling["columns"] as? Int ?? 0) + 1
        json["tiling"] = tiling
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Puzzle.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func puzzlesSavedBeforeMosaicsStillLoad() throws {
        let puzzle = SamplePicture.kitty.makePuzzle()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(puzzle)) as? [String: Any])
        json["version"] = 1
        json["tiling"] = nil
        let old = try JSONDecoder().decode(Puzzle.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old == puzzle)
        #expect(old.tiling == nil)
    }
}
