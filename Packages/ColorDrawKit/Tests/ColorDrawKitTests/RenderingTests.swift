import CoreGraphics
import Foundation
import Testing
@testable import ColorDrawKit

@Suite("Puzzle storage")
struct PuzzleCodingTests {
    @Test func roundTripsThroughPropertyList() throws {
        let puzzle = PuzzleGenerator.generate(from: makeNoisyPhoto(), settings: .medium)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(puzzle)
        #expect(try PropertyListDecoder().decode(Puzzle.self, from: data) == puzzle)
        // The region map is stored compactly (2 bytes per pixel plus overhead).
        #expect(data.count < puzzle.width * puzzle.height * 2 + 40_000)
    }

    @Test func rejectsCorruptRegionMap() throws {
        let puzzle = SamplePicture.kitty.makePuzzle()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(puzzle)) as? [String: Any])
        json["width"] = puzzle.width + 1
        let corrupt = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Puzzle.self, from: corrupt) }
    }

    @Test func rejectsHugeOrInconsistentPuzzles() throws {
        let puzzle = SamplePicture.house.makePuzzle()
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(puzzle)) as? [String: Any])

        var huge = original
        huge["width"] = 1 << 62
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Puzzle.self, from: JSONSerialization.data(withJSONObject: huge))
        }

        var badRegion = original
        var regions = try #require(original["regions"] as? [[String: Any]])
        regions[0]["maxX"] = 100_000
        badRegion["regions"] = regions
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Puzzle.self, from: JSONSerialization.data(withJSONObject: badRegion))
        }
    }

    @Test func rejectsNewerFormats() throws {
        let puzzle = SamplePicture.fish.makePuzzle()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(puzzle)) as? [String: Any])
        json["version"] = Puzzle.formatVersion + 1
        let future = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Puzzle.self, from: future) }
    }
}

@Suite("High-res map and painting")
struct RenderingTests {
    @Test(arguments: [SamplePicture.kitty, .rocket, .house])
    func detailMapKeepsEveryRegion(sample: SamplePicture) {
        let puzzle = sample.makePuzzle()
        let scale = DetailMap.recommendedScale(for: puzzle)
        let detail = DetailMap(puzzle: puzzle, scale: scale)
        #expect(detail.width == puzzle.width * scale)
        #expect(detail.height == puzzle.height * scale)
        for (index, region) in puzzle.regions.enumerated() {
            #expect(!detail.bounds[index].isEmpty)
            let x = Int(region.labelX * Float(scale)), y = Int(region.labelY * Float(scale))
            #expect(detail.region(atX: x, y: y) == index, "Tapping a number must hit its region")
        }
        #expect(detail.region(atX: -1, y: 0) == nil)
        #expect(detail.region(atX: detail.width, y: 0) == nil)
    }

    @Test func marginsAreSmallAtBordersAndMaxedInside() {
        let puzzle = SamplePicture.kitty.makePuzzle()
        let detail = DetailMap(puzzle: puzzle, scale: 6)
        var borderPixels = 0, closeToZero = 0
        for y in 0..<detail.height {
            for x in 0..<(detail.width - 1) {
                let p = y * detail.width + x
                if detail.labels[p] != detail.labels[p + 1] {
                    borderPixels += 1
                    if detail.margins[p] < 64 { closeToZero += 1 }
                }
            }
        }
        #expect(borderPixels > 0)
        // Almost every border pixel is near the zero crossing the smooth outline is drawn along.
        #expect(Double(closeToZero) / Double(borderPixels) > 0.9)
        // Deep inside the big background region nothing is close to a border.
        #expect(detail.margins[0] == 255)
    }

    @Test func detailMapOfPhotoKeepsEveryRegion() {
        let puzzle = PuzzleGenerator.generate(from: makeNoisyPhoto(), settings: .hard)
        let detail = DetailMap(puzzle: puzzle, scale: DetailMap.recommendedScale(for: puzzle))
        var areas = [Int](repeating: 0, count: puzzle.regions.count)
        for id in detail.labels { areas[Int(id)] += 1 }
        #expect(areas.allSatisfy { $0 > 0 })
    }

    @Test func updatingRegionsMatchesFullRender() throws {
        let puzzle = SamplePicture.flower.makePuzzle()
        let detail = DetailMap(puzzle: puzzle, scale: 4)
        let appearance: (Int) -> RegionAppearance = { index in
            switch index % 3 {
            case 0: .blank
            case 1: .highlighted
            default: .painted(puzzle.palette[puzzle.regions[index].colorIndex])
            }
        }
        let full = PaintBuffer(detail: detail)
        full.render(appearance)
        let incremental = PaintBuffer(detail: detail)
        incremental.render { _ in .blank }
        for index in puzzle.regions.indices { incremental.update(region: index, to: appearance(index)) }
        let a = try #require(full.makeImage()?.dataProvider?.data as Data?)
        let b = try #require(incremental.makeImage()?.dataProvider?.data as Data?)
        #expect(a == b)
    }

    @Test func outlinesAndSnapshotsRender() throws {
        let puzzle = SamplePicture.rainbow.makePuzzle()
        let detail = DetailMap(puzzle: puzzle, scale: 3)
        let outline = try #require(OutlineRenderer.makeImage(detail, color: CanvasStyle.standard.outline))
        #expect(outline.width == detail.width)
        let snapshot = try #require(PuzzleSnapshot.render(puzzle: puzzle, detail: detail, appearance: { _ in .blank }, outputWidth: 300))
        #expect(snapshot.width == 300)
        #expect(snapshot.height == 300)
    }

    @Test func thumbnails() throws {
        let puzzle = SamplePicture.fish.makePuzzle()
        let thumbnail = try #require(PuzzleSnapshot.thumbnail(of: puzzle, painted: true, width: 120))
        #expect(thumbnail.width == 120)
        #expect(thumbnail.height == 120)
    }

    @Test func numbersFitTheirRegions() {
        let puzzle = SamplePicture.kitty.makePuzzle()
        for region in puzzle.regions {
            let size = NumberRenderer.fontSize(for: region, in: puzzle, pixelSize: 1)
            #expect(size > 0)
            #expect(size <= CGFloat(region.labelRadius) * 2)
        }
    }
}
