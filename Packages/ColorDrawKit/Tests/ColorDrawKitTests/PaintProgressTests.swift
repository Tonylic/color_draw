import Foundation
import Testing
@testable import ColorDrawKit

@Suite("Painting rules")
struct PaintProgressTests {
    let puzzle = SamplePicture.kitty.makePuzzle()

    @Test func startsEmpty() {
        let progress = PaintProgress(puzzle: puzzle)
        #expect(progress.totalByColor == puzzle.regionsByColor.map(\.count))
        #expect(progress.filledCount == 0)
        #expect(!progress.isComplete)
        #expect(progress.fraction == 0)
        #expect(progress.remainingByColor.reduce(0, +) == puzzle.regions.count)
    }

    @Test func onlyTheRightColorPaints() {
        var progress = PaintProgress(puzzle: puzzle)
        let region = 0
        let right = puzzle.regions[region].colorIndex
        let wrong = (right + 1) % puzzle.palette.count
        #expect(progress.fill(region: region, with: wrong) == .wrongColor(expected: right))
        #expect(progress.filledCount == 0)
        if case .filled = progress.fill(region: region, with: right) {} else { Issue.record("Expected a fill") }
        #expect(progress.fill(region: region, with: right) == .alreadyFilled)
        #expect(progress.filledCount == 1)
    }

    @Test func reportsFinishedColorsAndPicture() {
        var progress = PaintProgress(puzzle: puzzle)
        var finishedColors = Set<Int>()
        var pictureDone = 0
        for (index, region) in puzzle.regions.enumerated() {
            if case let .filled(colorFinished, pictureFinished) = progress.fill(region: index, with: region.colorIndex) {
                if colorFinished { finishedColors.insert(region.colorIndex) }
                if pictureFinished { pictureDone += 1 }
            }
        }
        #expect(finishedColors.count == puzzle.palette.count)
        #expect(pictureDone == 1)
        #expect(progress.isComplete)
        #expect(progress.nextUnfinishedColor(after: 0) == nil)
    }

    @Test func nextColorSkipsFinishedOnesAndWraps() {
        let byColor = puzzle.regionsByColor
        // Finish every color except the first.
        let painted = byColor.dropFirst().flatMap { $0 }
        let progress = PaintProgress(puzzle: puzzle, filledRegions: painted)
        #expect(progress.nextUnfinishedColor(after: 2) == 0)
        #expect(progress.isFinished(color: 1))
        #expect(!progress.isFinished(color: 0))
    }

    @Test func restoringIgnoresInvalidAndDuplicateRegions() {
        let progress = PaintProgress(puzzle: puzzle, filledRegions: [0, 0, 1, -4, 99_999])
        #expect(progress.filledCount == 2)
        #expect(progress.filledRegions == [0, 1])
    }
}

@Suite("Saved paintings")
struct ArtworkRepositoryTests {
    func makeRepository() -> ArtworkRepository {
        ArtworkRepository(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("ColorDrawTests-\(UUID().uuidString)"))
    }

    @Test func createLoadSaveDelete() throws {
        let repository = makeRepository()
        defer { try? FileManager.default.removeItem(at: repository.rootURL) }
        let puzzle = SamplePicture.fish.makePuzzle()

        var metadata = try repository.create(puzzle: puzzle, title: "Fishy", level: nil, sampleID: "fish", thumbnailPNG: Data([1, 2, 3]))
        #expect(repository.loadAll().map(\.id) == [metadata.id])
        #expect(try repository.loadPuzzle(metadata.id) == puzzle)
        #expect(FileManager.default.fileExists(atPath: repository.thumbnailURL(metadata.id).path))

        metadata.filledRegions = [0, 2]
        metadata.updatedAt = Date().addingTimeInterval(5)
        try repository.save(metadata)
        let reloaded = try #require(repository.loadAll().first)
        #expect(reloaded.filledRegions == [0, 2])
        #expect(reloaded.title == "Fishy")
        #expect(abs(reloaded.fraction - 2 / Double(puzzle.regions.count)) < 0.0001)

        try repository.delete(metadata.id)
        #expect(repository.loadAll().isEmpty)
    }

    @Test func newestFirstAndSkipsJunk() throws {
        let repository = makeRepository()
        defer { try? FileManager.default.removeItem(at: repository.rootURL) }
        let puzzle = SamplePicture.house.makePuzzle()
        var older = try repository.create(puzzle: puzzle, title: "Old", level: "easy", sampleID: nil, thumbnailPNG: nil)
        older.updatedAt = Date(timeIntervalSince1970: 1000)
        try repository.save(older)
        let newer = try repository.create(puzzle: puzzle, title: "New", level: "easy", sampleID: nil, thumbnailPNG: nil)
        try FileManager.default.createDirectory(at: repository.rootURL.appendingPathComponent("not-a-painting"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository.rootURL.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)

        #expect(repository.loadAll().map(\.id) == [newer.id, older.id])
    }

    @Test func oldOrPartialMetadataStillLoads() throws {
        let repository = makeRepository()
        defer { try? FileManager.default.removeItem(at: repository.rootURL) }
        let created = try repository.create(puzzle: SamplePicture.rocket.makePuzzle(), title: "Rocket", level: nil, sampleID: "rocket", thumbnailPNG: nil)
        // Rewrite the metadata with only an id, like a file from a much older app version.
        let metaURL = repository.rootURL.appendingPathComponent(created.id.uuidString).appendingPathComponent("meta.json")
        try JSONSerialization.data(withJSONObject: ["id": created.id.uuidString, "title": "Rocket"]).write(to: metaURL)
        let loaded = try #require(repository.loadAll().first)
        #expect(loaded.id == created.id)
        #expect(loaded.title == "Rocket")
        #expect(loaded.filledRegions.isEmpty)
        #expect(!loaded.isComplete)
    }

    @Test func corruptMetadataIsSkippedAndHalfMadeFoldersAreCleanedUp() throws {
        let repository = makeRepository()
        defer { try? FileManager.default.removeItem(at: repository.rootURL) }
        let puzzle = SamplePicture.flower.makePuzzle()
        let good = try repository.create(puzzle: puzzle, title: "Good", level: nil, sampleID: nil, thumbnailPNG: nil)
        let broken = try repository.create(puzzle: puzzle, title: "Broken", level: nil, sampleID: nil, thumbnailPNG: nil)
        try Data("not json".utf8).write(to: repository.rootURL.appendingPathComponent(broken.id.uuidString).appendingPathComponent("meta.json"))
        let halfMade = repository.rootURL.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: halfMade, withIntermediateDirectories: true)

        #expect(repository.loadAll().map(\.id) == [good.id])
        repository.removeIncompleteFolders()
        #expect(!FileManager.default.fileExists(atPath: halfMade.path))
        #expect(repository.loadAll().map(\.id) == [good.id])
    }

    @Test func emptyWhenNothingSaved() {
        #expect(makeRepository().loadAll().isEmpty)
    }
}
