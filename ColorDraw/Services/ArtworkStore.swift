import ColorDrawKit
import Observation
import UIKit

/// The child's paintings: what's saved on disk plus a thumbnail of each.
@Observable
@MainActor
final class ArtworkStore {
    private(set) var artworks: [ArtworkMetadata] = []
    private(set) var thumbnails: [UUID: UIImage] = [:]
    /// Set when the storage folder can't be used; paintings then live only until the app quits.
    private(set) var storageError: Error?

    private let repository: ArtworkRepository?

    init(repository: ArtworkRepository? = nil) {
        if let repository {
            self.repository = repository
        } else {
            do {
                self.repository = try ArtworkRepository.standard()
            } catch {
                self.repository = nil
                storageError = error
            }
        }
        reload()
    }

    /// The app's store. UI tests pass `-resetPaintings` to start from a clean slate.
    static func forLaunch() -> ArtworkStore {
        #if DEBUG
        if CommandLine.arguments.contains("-resetPaintings"), let repository = try? ArtworkRepository.standard() {
            try? FileManager.default.removeItem(at: repository.rootURL)
        }
        #endif
        return ArtworkStore()
    }

    func reload() {
        guard let repository else { return }
        artworks = repository.loadAll()
        var images: [UUID: UIImage] = [:]
        for artwork in artworks {
            images[artwork.id] = UIImage(contentsOfFile: repository.thumbnailURL(artwork.id).path)
        }
        thumbnails = images
    }

    func artwork(_ id: UUID) -> ArtworkMetadata? {
        artworks.first { $0.id == id }
    }

    /// The newest unfinished painting of a built-in picture, so tapping it again continues it.
    func unfinishedArtwork(forSample sample: SamplePicture) -> ArtworkMetadata? {
        artworks.first { $0.sampleID == sample.rawValue && !$0.isComplete }
    }

    func create(puzzle: Puzzle, title: String, level: String?, sampleID: String?, thumbnail: UIImage?) async throws -> ArtworkMetadata {
        guard let repository else { throw CocoaError(.fileWriteUnknown) }
        let png = thumbnail?.pngData()
        let metadata = try await Task.detached(priority: .userInitiated) {
            try repository.create(puzzle: puzzle, title: title, level: level, sampleID: sampleID, thumbnailPNG: png)
        }.value
        artworks.insert(metadata, at: 0)
        thumbnails[metadata.id] = thumbnail
        return metadata
    }

    func loadPuzzle(_ id: UUID) async throws -> Puzzle {
        guard let repository else { throw CocoaError(.fileReadNoSuchFile) }
        return try await Task.detached(priority: .userInitiated) {
            try repository.loadPuzzle(id)
        }.value
    }

    /// Records painting progress. Writes are small, so they happen right away.
    func saveProgress(_ id: UUID, filledRegions: [Int], isComplete: Bool, thumbnail: UIImage?) {
        guard var metadata = artwork(id) else { return }
        metadata.filledRegions = filledRegions
        metadata.updatedAt = Date()
        if isComplete, metadata.completedAt == nil { metadata.completedAt = Date() }
        do {
            try repository?.save(metadata)
            if let thumbnail, let png = thumbnail.pngData() {
                try repository?.saveThumbnail(png, for: id)
                thumbnails[id] = thumbnail
            }
        } catch {
            storageError = error
        }
        artworks.removeAll { $0.id == id }
        artworks.insert(metadata, at: 0)
    }

    func delete(_ id: UUID) {
        try? repository?.delete(id)
        artworks.removeAll { $0.id == id }
        thumbnails[id] = nil
    }
}

/// Pictures of the built-in drawings for the home screen, rendered once in the background.
@Observable
@MainActor
final class SampleCatalog {
    private(set) var previews: [SamplePicture: UIImage] = [:]

    func loadPreviews() async {
        guard previews.isEmpty else { return }
        for sample in SamplePicture.allCases {
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                let puzzle = sample.makePuzzle()
                let detail = DetailMap(puzzle: puzzle, scale: 3)
                return PuzzleSnapshot.render(
                    puzzle: puzzle,
                    detail: detail,
                    appearance: { .painted(puzzle.palette[puzzle.regions[$0].colorIndex]) },
                    outputWidth: 360
                )
            }.value
            if let image { previews[sample] = UIImage(cgImage: image) }
        }
    }
}
