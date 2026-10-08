import ColorDrawKit
import Observation
import UIKit

/// The child's paintings: what's saved on disk plus a thumbnail of each.
@Observable
@MainActor
final class ArtworkStore {
    private(set) var artworks: [ArtworkMetadata] = []
    private(set) var thumbnails: [UUID: UIImage] = [:]
    /// The last thing that went wrong while saving or deleting, for the home screen to report.
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
        // Nothing is being created yet, so any half-written folder is left over from a crash.
        self.repository?.removeIncompleteFolders()
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

    private func reload() {
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
        guard let repository else { throw storageError ?? CocoaError(.fileWriteUnknown) }
        let metadata: ArtworkMetadata
        do {
            metadata = try await Task.detached(priority: .userInitiated) {
                try repository.create(puzzle: puzzle, title: title, level: level, sampleID: sampleID, thumbnailPNG: thumbnail?.pngData())
            }.value
        } catch {
            storageError = error
            throw error
        }
        artworks.insert(metadata, at: 0)
        thumbnails[metadata.id] = thumbnail
        return metadata
    }

    func loadPuzzle(_ id: UUID) async throws -> Puzzle {
        guard let repository else { throw storageError ?? CocoaError(.fileReadNoSuchFile) }
        return try await Task.detached(priority: .userInitiated) {
            try repository.loadPuzzle(id)
        }.value
    }

    /// Records painting progress. The small metadata file is written right away; the thumbnail
    /// (only rendered once the metadata is safely saved) is encoded and written in the
    /// background, in order. Returns `false` if the progress couldn't be saved.
    @discardableResult
    func saveProgress(_ id: UUID, filledRegions: [Int], regionCount: Int, isComplete: Bool, thumbnail: () -> UIImage?) -> Bool {
        guard let repository, var metadata = artwork(id) else { return false }
        metadata.filledRegions = filledRegions
        metadata.regionCount = regionCount
        metadata.updatedAt = Date()
        if isComplete, metadata.completedAt == nil { metadata.completedAt = Date() }
        do {
            try repository.save(metadata)
        } catch {
            storageError = error
            return false
        }
        // The painting is safe again; don't warn about an earlier failure that's been retried.
        storageError = nil
        artworks.removeAll { $0.id == id }
        artworks.insert(metadata, at: 0)
        if let image = thumbnail() {
            thumbnails[id] = image
            writeThumbnail(image, for: id, in: repository)
        }
        return true
    }

    /// Thumbnail files are written one after another on a background queue, and the app asks
    /// for a little extra time so a write isn't cut off when the app goes to the background.
    private func writeThumbnail(_ image: UIImage, for id: UUID, in repository: ArtworkRepository) {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save thumbnail")
        Self.thumbnailQueue.async {
            if let png = image.pngData() { try? repository.saveThumbnail(png, for: id) }
            DispatchQueue.main.async {
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
            }
        }
    }

    private static let thumbnailQueue = DispatchQueue(label: "ColorDraw.thumbnails", qos: .utility)

    func delete(_ id: UUID) {
        do {
            try repository?.delete(id)
            artworks.removeAll { $0.id == id }
            thumbnails[id] = nil
        } catch {
            storageError = error
        }
    }

    func clearError() {
        storageError = nil
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
            let image = await Task.detached(priority: .utility) {
                PuzzleSnapshot.thumbnail(of: sample.makePuzzle(), painted: true, width: 360)
            }.value
            if let image { previews[sample] = UIImage(cgImage: image) }
        }
    }
}
