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

/// Checks the invariants every puzzle must satisfy for the app to work.
func expectValid(_ puzzle: Puzzle, settings: PuzzleSettings? = nil) {
    #expect(puzzle.regionMap.count == puzzle.width * puzzle.height)
    #expect(!puzzle.regions.isEmpty)
    #expect(puzzle.palette.count <= (settings?.colorCount ?? 255))
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
        if let settings, puzzle.regions.count > 1 {
            #expect(region.area >= settings.minimumRegionArea)
            #expect(region.labelRadius >= settings.minimumRegionRadius - 0.01)
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
        let puzzle = PuzzleGenerator.generate(from: image, settings: .easy)
        expectValid(puzzle, settings: .easy)
        #expect(puzzle.regions.count == 2)
        #expect(Set(puzzle.palette) == [RGBColor(r: 255, g: 0, b: 0), RGBColor(r: 0, g: 0, b: 255)])
        // Rainbow order puts red before blue.
        #expect(puzzle.palette.first == RGBColor(r: 255, g: 0, b: 0))
        let left = puzzle.regions[puzzle.region(atX: 5, y: 10)]
        #expect(left.labelX < 20)
    }

    @Test(arguments: [("easy", PuzzleSettings.easy), ("medium", .medium), ("hard", .hard)])
    func noisyPhotoSatisfiesSettings(level: String, settings: PuzzleSettings) {
        let puzzle = PuzzleGenerator.generate(from: makeNoisyPhoto(), settings: settings)
        expectValid(puzzle, settings: settings)
        #expect(puzzle.palette.count >= 2, "\(level) should keep several colors")
    }

    @Test func harderLevelsHaveMoreRegions() throws {
        let photo = try #require(makeNoisyPhoto(width: 400, height: 300).makeCGImage())
        let easy = try PuzzleGenerator.generate(from: photo, settings: .easy)
        let hard = try PuzzleGenerator.generate(from: photo, settings: .hard)
        #expect(easy.regions.count < hard.regions.count)
        #expect(max(easy.width, easy.height) <= PuzzleSettings.easy.maxDimension)
        #expect(max(hard.width, hard.height) <= PuzzleSettings.hard.maxDimension)
    }

    @Test func paletteColorsAreClearlyDifferent() {
        let puzzle = PuzzleGenerator.generate(from: makeNoisyPhoto(), settings: .medium)
        let labs = puzzle.palette.map(\.lab)
        for i in labs.indices {
            for j in labs.indices where j > i {
                // The storybook boost only spreads colors further apart.
                #expect(labs[i].distanceSquared(to: labs[j]).squareRoot() >= PuzzleSettings.medium.minimumColorDistance * 0.9)
            }
        }
    }

    @Test func generationIsDeterministic() {
        let photo = makeNoisyPhoto()
        #expect(PuzzleGenerator.generate(from: photo, settings: .medium) == PuzzleGenerator.generate(from: photo, settings: .medium))
    }

    @Test func singleColorImageIsOneRegion() {
        let puzzle = PuzzleGenerator.generate(from: RGBAImage(width: 30, height: 30), settings: .hard)
        expectValid(puzzle)
        #expect(puzzle.regions.count == 1)
        #expect(puzzle.palette == [RGBColor(r: 255, g: 255, b: 255)])
    }

    @Test func tinyImagesStillWork() {
        let puzzle = PuzzleGenerator.generate(from: makeNoisyPhoto(width: 3, height: 2), settings: .easy)
        expectValid(puzzle)
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

    @Test func pixelPacking() {
        let pixel = RGBColor(r: 1, g: 2, b: 3).pixel
        withUnsafeBytes(of: pixel.littleEndian) { bytes in
            #expect(Array(bytes) == [1, 2, 3, 255])
        }
    }
}
