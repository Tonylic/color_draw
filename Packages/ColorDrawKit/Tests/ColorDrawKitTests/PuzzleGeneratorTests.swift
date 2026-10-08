import CoreGraphics
import Foundation
import Testing
@testable import ColorDrawKit

/// A deterministic "photo": soft blobs of color plus sensor-like noise.
func makeNoisyPhoto(width: Int = 200, height: Int = 150, seed: UInt64 = 7) -> RGBAImage {
    var rng = SplitMix64(seed: seed)
    let blobs: [(x: Double, y: Double, r: Double, color: (Double, Double, Double))] = (0..<9).map { _ in
        (Double.random(in: 0..<Double(width), using: &rng),
         Double.random(in: 0..<Double(height), using: &rng),
         Double.random(in: 15..<60, using: &rng),
         (Double.random(in: 0..<255, using: &rng), Double.random(in: 0..<255, using: &rng), Double.random(in: 0..<255, using: &rng)))
    }
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            var color = (Double(x) / Double(width) * 120 + 60, 140.0, Double(y) / Double(height) * 120 + 60)
            for blob in blobs {
                let d = ((Double(x) - blob.x) * (Double(x) - blob.x) + (Double(y) - blob.y) * (Double(y) - blob.y)).squareRoot()
                if d < blob.r { color = blob.color }
            }
            let noise = Double.random(in: -18...18, using: &rng)
            let i = (y * width + x) * 4
            pixels[i] = UInt8(max(0, min(255, color.0 + noise)))
            pixels[i + 1] = UInt8(max(0, min(255, color.1 + noise)))
            pixels[i + 2] = UInt8(max(0, min(255, color.2 + noise)))
        }
    }
    return RGBAImage(width: width, height: height, pixels: pixels)
}

/// A very busy "photo": a mosaic of small tiles in many strong colors.
func makeBusyPhoto(width: Int = 560, height: Int = 420, tile: Int = 20, colorCount: Int = 16, seed: UInt64 = 3) -> RGBAImage {
    var rng = SplitMix64(seed: seed)
    let colors: [RGBColor] = (0..<colorCount).map { _ in
        RGBColor(r: .random(in: 0...255, using: &rng), g: .random(in: 0...255, using: &rng), b: .random(in: 0...255, using: &rng))
    }
    let columns = (width + tile - 1) / tile, rows = (height + tile - 1) / tile
    let tiles = (0..<(columns * rows)).map { _ in colors.randomElement(using: &rng)! }
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let color = tiles[(y / tile) * columns + x / tile]
            let i = (y * width + x) * 4
            pixels[i] = color.r
            pixels[i + 1] = color.g
            pixels[i + 2] = color.b
        }
    }
    return RGBAImage(width: width, height: height, pixels: pixels)
}

extension PuzzleSettings {
    /// The same level with shapes that follow the photo's outlines instead of tiles.
    var organic: PuzzleSettings {
        var copy = self
        copy.tiles = nil
        return copy
    }
}

/// Checks the invariants every puzzle must satisfy for the app to work.
func expectValid(_ puzzle: Puzzle, settings: PuzzleSettings? = nil) {
    #expect(puzzle.regionMap.count == puzzle.width * puzzle.height)
    #expect(!puzzle.regions.isEmpty)
    #expect(puzzle.palette.count <= (settings?.colorCount ?? 255))
    #expect(puzzle.regions.count <= (settings?.maximumRegionCount ?? .max))
    #expect(puzzle.regions.reduce(0) { $0 + $1.area } == puzzle.width * puzzle.height)

    var areas = [Int](repeating: 0, count: puzzle.regions.count)
    for id in puzzle.regionMap { areas[Int(id)] += 1 }
    for (index, region) in puzzle.regions.enumerated() {
        #expect(areas[index] == region.area)
        #expect(puzzle.palette.indices.contains(region.colorIndex))
        // The number is printed inside its own region.
        #expect(puzzle.region(atX: Int(region.labelX), y: Int(region.labelY)) == index)
        #expect(region.minX <= Int(region.labelX) && Int(region.labelX) <= region.maxX)
        #expect(region.minY <= Int(region.labelY) && Int(region.labelY) <= region.maxY)
        if let settings, settings.tiles == nil, puzzle.regions.count > 1 {
            #expect(region.area >= settings.minimumRegionArea)
            #expect(region.labelRadius >= settings.minimumRegionRadius - 0.01)
        }
    }
    if let tiling = puzzle.tiling {
        #expect(puzzle.regions.count == tiling.tileCount)
        if let tiles = settings?.tiles {
            #expect(tiling.shape == tiles.shape)
        }
    }
    // Every palette color is used, so no number is left without regions.
    #expect(Set(puzzle.regions.map(\.colorIndex)).count == puzzle.palette.count)
}

@Suite("Puzzle generation")
struct PuzzleGeneratorTests {
    @Test func twoFlatHalvesBecomeTwoRegions() {
        let image = RGBAImage.render(width: 40, height: 20, antialias: false) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        }!
        let puzzle = PuzzleGenerator.generate(from: image, settings: .easy.organic)
        expectValid(puzzle, settings: .easy.organic)
        #expect(puzzle.regions.count == 2)
        #expect(Set(puzzle.palette) == [RGBColor(r: 255, g: 0, b: 0), RGBColor(r: 0, g: 0, b: 255)])
        // Rainbow order puts red before blue.
        #expect(puzzle.palette.first == RGBColor(r: 255, g: 0, b: 0))
        let left = puzzle.regions[puzzle.region(atX: 5, y: 10)]
        #expect(left.labelX < 20)
    }

    @Test(arguments: [("easy", PuzzleSettings.easy), ("medium", .medium), ("hard", .hard)])
    func noisyPhotoSatisfiesSettings(level: String, settings: PuzzleSettings) {
        for settings in [settings, settings.with(shape: .triangles), settings.organic] {
            let puzzle = PuzzleGenerator.generate(from: makeNoisyPhoto(), settings: settings)
            expectValid(puzzle, settings: settings)
            #expect(puzzle.palette.count >= 2, "\(level) \(settings.tiles?.shape.rawValue ?? "organic") should keep several colors")
        }
    }

    @Test(arguments: [("easy", PuzzleSettings.easy, 50), ("medium", .medium, 100), ("hard", .hard, 200)])
    func colorfulPhotosUseUpToTheLevelsColorLimit(level: String, settings: PuzzleSettings, limit: Int) throws {
        #expect(settings.colorCount == limit)
        let photo = try #require(makeBusyPhoto(tile: 14, colorCount: 300).makeCGImage())
        for settings in [settings, settings.with(shape: .triangles), settings.organic] {
            let puzzle = try PuzzleGenerator.generate(from: photo, settings: settings)
            expectValid(puzzle, settings: settings)
            let name = "\(level) \(settings.tiles?.shape.rawValue ?? "organic")"
            #expect(puzzle.palette.count <= limit, "\(name) allows at most \(limit) colors")
            // A very colorful photo uses most of the level's colors.
            #expect(puzzle.palette.count >= limit * 6 / 10, "\(name) made only \(puzzle.palette.count) colors")
        }
    }

    @Test func simplePhotosStayBelowTheLimit() throws {
        // Two flat halves: two shapes at every level, nowhere near the limit.
        let image = try #require(RGBAImage.render(width: 300, height: 200, antialias: false) { context in
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 120))
            context.setFillColor(CGColor(srgbRed: 0.3, green: 0.8, blue: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 120, width: 300, height: 80))
        }?.makeCGImage())
        for settings in [PuzzleSettings.easy, .medium, .hard] {
            let organic = try PuzzleGenerator.generate(from: image, settings: settings.organic)
            #expect(organic.palette.count == 2)
            #expect(organic.regions.count == 2)
            for shape in Tiling.Shape.allCases {
                let mosaic = try PuzzleGenerator.generate(from: image, settings: settings.with(shape: shape))
                #expect(mosaic.palette.count == 2)
            }
        }
    }

    @Test func harderLevelsHaveMoreRegions() throws {
        let photo = try #require(makeNoisyPhoto(width: 400, height: 300).makeCGImage())
        let easy = try PuzzleGenerator.generate(from: photo, settings: .easy.organic)
        let hard = try PuzzleGenerator.generate(from: photo, settings: .hard.organic)
        #expect(easy.regions.count < hard.regions.count)
        #expect(max(easy.width, easy.height) <= PuzzleSettings.easy.maxDimension)
        #expect(max(hard.width, hard.height) <= PuzzleSettings.hard.maxDimension)
        for shape in Tiling.Shape.allCases {
            let easyMosaic = try PuzzleGenerator.generate(from: photo, settings: PuzzleSettings.easy.with(shape: shape))
            let mediumMosaic = try PuzzleGenerator.generate(from: photo, settings: PuzzleSettings.medium.with(shape: shape))
            let hardMosaic = try PuzzleGenerator.generate(from: photo, settings: PuzzleSettings.hard.with(shape: shape))
            #expect(easyMosaic.regions.count < mediumMosaic.regions.count)
            #expect(mediumMosaic.regions.count < hardMosaic.regions.count)
        }
    }

    @Test func paletteColorsAreClearlyDifferent() {
        for settings in [PuzzleSettings.medium, .medium.organic] {
            let puzzle = PuzzleGenerator.generate(from: makeNoisyPhoto(), settings: settings)
            let labs = puzzle.palette.map(\.lab)
            for i in labs.indices {
                for j in labs.indices where j > i {
                    // The storybook boost only spreads colors further apart.
                    #expect(labs[i].distanceSquared(to: labs[j]).squareRoot() >= PuzzleSettings.medium.minimumColorDistance * 0.9)
                }
            }
        }
    }

    @Test func generationIsDeterministic() {
        let photo = makeNoisyPhoto()
        for settings in [PuzzleSettings.medium, .medium.with(shape: .triangles), .medium.organic] {
            #expect(PuzzleGenerator.generate(from: photo, settings: settings) == PuzzleGenerator.generate(from: photo, settings: settings))
        }
    }

    @Test func singleColorImageIsOneRegion() {
        let puzzle = PuzzleGenerator.generate(from: RGBAImage(width: 30, height: 30), settings: .hard.organic)
        expectValid(puzzle)
        #expect(puzzle.regions.count == 1)
        #expect(puzzle.palette == [RGBColor(r: 255, g: 255, b: 255)])
        let mosaic = PuzzleGenerator.generate(from: RGBAImage(width: 30, height: 30), settings: .hard)
        expectValid(mosaic)
        #expect(mosaic.palette == [RGBColor(r: 255, g: 255, b: 255)])
    }

    @Test func tinyImagesStillWork() {
        for settings in [PuzzleSettings.easy, .easy.with(shape: .triangles), .easy.organic] {
            let puzzle = PuzzleGenerator.generate(from: makeNoisyPhoto(width: 3, height: 2), settings: settings)
            expectValid(puzzle)
        }
    }

    @Test func photosAreNotFlipped() throws {
        // Red on top, blue on the bottom.
        let image = try #require(RGBAImage.render(width: 10, height: 10, antialias: false) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 5))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 5, width: 10, height: 5))
        }?.makeCGImage())
        let reloaded = try #require(RGBAImage(cgImage: image, maxDimension: 10))
        #expect(reloaded.color(atX: 5, y: 1) == RGBColor(r: 255, g: 0, b: 0))
        #expect(reloaded.color(atX: 5, y: 8) == RGBColor(r: 0, g: 0, b: 255))
    }

    @Test func panoramasAreCroppedToAFriendlyShape() throws {
        let panorama = try #require(makeNoisyPhoto(width: 600, height: 60).makeCGImage())
        let tower = try #require(makeNoisyPhoto(width: 50, height: 400).makeCGImage())
        for settings in [PuzzleSettings.easy, .easy.with(shape: .triangles), .easy.organic] {
            let puzzle = try PuzzleGenerator.generate(from: panorama, settings: settings)
            expectValid(puzzle, settings: settings)
            #expect(Double(puzzle.width) / Double(puzzle.height) <= PuzzleSettings.easy.maximumAspectRatio + 0.05)
            let tall = try PuzzleGenerator.generate(from: tower, settings: settings)
            #expect(Double(tall.height) / Double(tall.width) <= 2.05)
        }
    }

    @Test func nearlyIdenticalFlatColorsShareANumber() {
        // A checkerboard of two colors a child could never tell apart.
        var pixels = [UInt8](repeating: 255, count: 40 * 40 * 4)
        for y in 0..<40 {
            for x in 0..<40 {
                let i = (y * 40 + x) * 4
                let shade: UInt8 = (x + y).isMultiple(of: 2) ? 200 : 201
                pixels[i] = shade
                pixels[i + 1] = 100
                pixels[i + 2] = 60
            }
        }
        let puzzle = PuzzleGenerator.generate(from: RGBAImage(width: 40, height: 40, pixels: pixels), settings: .medium.organic)
        expectValid(puzzle)
        #expect(puzzle.palette.count == 1)
        #expect(puzzle.regions.count == 1)
        let mosaic = PuzzleGenerator.generate(from: RGBAImage(width: 40, height: 40, pixels: pixels), settings: .medium)
        #expect(mosaic.palette.count == 1)
    }

    @Test(arguments: SamplePicture.allCases)
    func samplePicturesMakeGoodPuzzles(sample: SamplePicture) {
        let puzzle = sample.makePuzzle()
        expectValid(puzzle, settings: SamplePicture.settings)
        #expect(puzzle.regions.count >= 8)
        #expect(puzzle.palette.count >= 5)
        #expect(puzzle.palette.count <= 16)
    }
}

@Suite("Colors")
struct ColorTests {
    @Test func labRoundTrip() {
        for hex: UInt32 in [0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFA94D, 0x3D3A4B, 0x74C0FC] {
            let color = RGBColor(hex: hex)
            let back = color.lab.rgb
            #expect(abs(Int(back.r) - Int(color.r)) <= 1)
            #expect(abs(Int(back.g) - Int(color.g)) <= 1)
            #expect(abs(Int(back.b) - Int(color.b)) <= 1)
        }
    }

    @Test func knownLabValues() {
        let white = RGBColor(hex: 0xFFFFFF).lab
        #expect(abs(white.l - 100) < 0.1)
        #expect(abs(white.a) < 0.1 && abs(white.b) < 0.1)
        let red = RGBColor(hex: 0xFF0000).lab
        #expect(abs(red.l - 53.24) < 0.1)
        #expect(abs(red.a - 80.09) < 0.2)
    }

    @Test func textContrast() {
        #expect(RGBColor(hex: 0xFFE066).prefersDarkText)
        #expect(!RGBColor(hex: 0x25285C).prefersDarkText)
    }

    @Test func colorNames() {
        #expect(RGBColor(hex: 0xFFFFFF).name == "white")
        #expect(RGBColor(hex: 0x000000).name == "black")
        #expect(RGBColor(hex: 0xFF0000).name == "red")
        #expect(RGBColor(hex: 0xFFD43B).name == "yellow")
        #expect(RGBColor(hex: 0x40C057).name == "green")
        #expect(RGBColor(hex: 0x1C3FAA).name == "dark blue")
        #expect(RGBColor(hex: 0x845EF7).name == "purple")
        #expect(RGBColor(hex: 0xFF8FAB).name == "pink")
        #expect(RGBColor(hex: 0x8B5A2B).name == "brown")
        #expect(RGBColor(hex: 0xA5D8FF).name == "light blue")
    }

    @Test func stripesStayLightEnoughForNumbers() throws {
        for hex: UInt32 in [0xFF0000, 0x25285C, 0x40C057, 0xFFD43B, 0x845EF7, 0x8B5A2B] {
            let stripes = try #require(PaintBuffer.stripeColors(for: RGBColor(hex: hex)))
            // Dark ink numbers need a light background (WCAG contrast ≥ 4.5 against #5A5372).
            let ink = CanvasStyle.standard.number.luminance
            for stripe in [stripes.light, stripes.dark] {
                #expect((stripe.luminance + 0.05) / (ink + 0.05) >= 4.5)
            }
        }
        #expect(PaintBuffer.stripeColors(for: RGBColor(hex: 0xF1F3F5)) == nil, "Grays use neutral stripes")
        let ink = CanvasStyle.standard.number.luminance
        for stripe in [CanvasStyle.standard.highlightLight, CanvasStyle.standard.highlightDark] {
            #expect((stripe.luminance + 0.05) / (ink + 0.05) >= 4.5)
        }
        // Neutral stripes stand out from the gray ghost of a black or gray paint.
        let ghost = CanvasStyle.standard.ghost(of: RGBColor(hex: 0x222222)).lab
        #expect(CanvasStyle.standard.highlightDark.lab.distanceSquared(to: ghost).squareRoot() > 12)
    }

    @Test func pixelPacking() {
        let pixel = RGBColor(r: 1, g: 2, b: 3).pixel
        withUnsafeBytes(of: pixel.littleEndian) { bytes in
            #expect(Array(bytes) == [1, 2, 3, 255])
        }
    }
}
