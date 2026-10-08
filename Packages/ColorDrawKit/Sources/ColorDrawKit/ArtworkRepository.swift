import Foundation

/// Everything about a saved painting except the (large) puzzle itself.
public struct ArtworkMetadata: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Difficulty the puzzle was made with (`nil` for built-in pictures).
    public var level: String?
    /// The built-in picture this came from, if any.
    public var sampleID: String?
    public var regionCount: Int
    public var filledRegions: [Int]
    public var completedAt: Date?

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), level: String?, sampleID: String?, regionCount: Int) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        updatedAt = createdAt
        self.level = level
        self.sampleID = sampleID
        self.regionCount = regionCount
        filledRegions = []
        completedAt = nil
    }

    public var isComplete: Bool { completedAt != nil }
    public var fraction: Double { regionCount == 0 ? 0 : Double(filledRegions.count) / Double(regionCount) }

    // Tolerant decoding: only `id` is essential. Anything else that is missing (say, from an
    // older version of the app) falls back to a default instead of making the painting vanish.
    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, level, sampleID, regionCount, filledRegions, completedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? "My Picture"
        createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        updatedAt = (try? container.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? createdAt
        level = try? container.decodeIfPresent(String.self, forKey: .level)
        sampleID = try? container.decodeIfPresent(String.self, forKey: .sampleID)
        regionCount = (try? container.decodeIfPresent(Int.self, forKey: .regionCount)) ?? 0
        filledRegions = (try? container.decodeIfPresent([Int].self, forKey: .filledRegions)) ?? []
        completedAt = try? container.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

/// Stores paintings on disk, one folder per painting:
///
///     <root>/<id>/meta.json      ArtworkMetadata
///     <root>/<id>/puzzle.plist   Puzzle (binary property list)
///     <root>/<id>/thumbnail.png  Small picture of the painting so far
public struct ArtworkRepository: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    /// `Application Support/Artworks` for the app.
    public static func standard() throws -> ArtworkRepository {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return ArtworkRepository(rootURL: support.appendingPathComponent("Artworks", isDirectory: true))
    }

    private func folder(_ id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func metadataURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("meta.json") }
    private func puzzleURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("puzzle.plist") }
    public func thumbnailURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("thumbnail.png") }

    /// Deletes folders left behind by a create that never finished (no metadata, or no puzzle).
    /// Call only at launch, before any painting is being created.
    public func removeIncompleteFolders() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            let complete = FileManager.default.fileExists(atPath: metadataURL(id).path)
                && FileManager.default.fileExists(atPath: puzzleURL(id).path)
            if !complete { try? FileManager.default.removeItem(at: folder) }
        }
    }

    /// All paintings, most recently touched first. Unreadable folders are skipped.
    public func loadAll() -> [ArtworkMetadata] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  let data = try? Data(contentsOf: metadataURL(id)) else { return nil }
            return try? Self.decoder.decode(ArtworkMetadata.self, from: data)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func create(puzzle: Puzzle, title: String, level: String?, sampleID: String?, thumbnailPNG: Data?) throws -> ArtworkMetadata {
        let metadata = ArtworkMetadata(title: title, level: level, sampleID: sampleID, regionCount: puzzle.regions.count)
        try FileManager.default.createDirectory(at: folder(metadata.id), withIntermediateDirectories: true)
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(puzzle).write(to: puzzleURL(metadata.id), options: .atomic)
            if let thumbnailPNG { try thumbnailPNG.write(to: thumbnailURL(metadata.id), options: .atomic) }
            // Metadata goes last: a folder without it is ignored, so a failed create leaves no half painting.
            try save(metadata)
        } catch {
            try? FileManager.default.removeItem(at: folder(metadata.id))
            throw error
        }
        return metadata
    }

    public func loadPuzzle(_ id: UUID) throws -> Puzzle {
        try PropertyListDecoder().decode(Puzzle.self, from: Data(contentsOf: puzzleURL(id)))
    }

    public func save(_ metadata: ArtworkMetadata) throws {
        try Self.encoder.encode(metadata).write(to: metadataURL(metadata.id), options: .atomic)
    }

    public func saveThumbnail(_ png: Data, for id: UUID) throws {
        try png.write(to: thumbnailURL(id), options: .atomic)
    }

    public func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: folder(id))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
