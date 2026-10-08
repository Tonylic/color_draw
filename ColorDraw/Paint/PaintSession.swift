import ColorDrawKit
import Observation
import UIKit

/// What the painting screen asks of the canvas.
@MainActor
protocol PaintCanvasControlling: AnyObject {
    func regionPainted(_ region: Int)
    func selectionChanged()
    func zoom(by factor: CGFloat)
    func zoomToFit()
    /// Zooms to a region so its number is easy to read, and makes it pulse.
    func focus(on region: Int)
    /// The id of an unpainted region of `color` near the middle of the screen.
    func nearestUnpaintedRegion(of color: Int) -> Int?
    func snapshot(width: CGFloat) -> UIImage?
}

/// One painting in progress: the rules, the selected paint, and the fun reactions.
@Observable
@MainActor
final class PaintSession {
    struct Cheer: Equatable {
        let id: Int
        let text: String
    }

    let artworkID: UUID
    let puzzle: Puzzle
    let detail: DetailMap
    private(set) var progress: PaintProgress
    private(set) var selectedColor: Int
    /// Changes whenever a palette swatch should wiggle to show which color a shape needs.
    private(set) var hint: (color: Int, token: Int)?
    /// A short message that pops up after finishing a color.
    private(set) var cheer: Cheer?
    /// True from the moment the last shape is painted.
    private(set) var showsCelebration = false

    @ObservationIgnored weak var canvas: PaintCanvasControlling?
    @ObservationIgnored private let store: ArtworkStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var cheerTask: Task<Void, Never>?
    @ObservationIgnored private var cheerCount = 0
    @ObservationIgnored private var hintCount = 0
    @ObservationIgnored private var hasUnsavedChanges = false

    private static let cheers = ["Great job!", "Super!", "Wow!", "Amazing!", "You rock!", "Yay!", "So pretty!", "Brilliant!"]

    init(artwork: ArtworkMetadata, puzzle: Puzzle, detail: DetailMap, store: ArtworkStore) {
        artworkID = artwork.id
        self.puzzle = puzzle
        self.detail = detail
        self.store = store
        let progress = PaintProgress(puzzle: puzzle, filledRegions: artwork.filledRegions)
        self.progress = progress
        selectedColor = progress.remainingByColor.firstIndex { $0 > 0 } ?? 0
    }

    var isComplete: Bool { progress.isComplete }

    func appearance(of region: Int) -> RegionAppearance {
        let color = puzzle.regions[region].colorIndex
        if progress.filled[region] { return .painted(puzzle.palette[color]) }
        return color == selectedColor ? .highlighted : .blank
    }

    func select(color: Int) {
        guard color != selectedColor, puzzle.palette.indices.contains(color) else { return }
        selectedColor = color
        canvas?.selectionChanged()
        Haptics.select()
        SoundPlayer.shared.playTick()
    }

    /// Paints `region` if it takes the selected color. Wrong colors are ignored unless `isTap`,
    /// in which case the child gets a gentle hint about the right color.
    @discardableResult
    func paint(region: Int, isTap: Bool) -> Bool {
        switch progress.fill(region: region, with: selectedColor) {
        case let .filled(colorFinished, pictureFinished):
            hasUnsavedChanges = true
            canvas?.regionPainted(region)
            SoundPlayer.shared.playPaint(colorIndex: selectedColor)
            Haptics.paint()
            if pictureFinished {
                finishPicture()
            } else {
                if colorFinished { finishColor() }
                scheduleSave()
            }
            return true
        case let .wrongColor(expected):
            if isTap {
                hintCount += 1
                hint = (expected, hintCount)
                SoundPlayer.shared.playOops()
                Haptics.oops()
            }
            return false
        case .alreadyFilled:
            return false
        }
    }

    /// Whether a region would take the selected paint right now.
    func canPaint(region: Int) -> Bool {
        !progress.filled[region] && puzzle.regions[region].colorIndex == selectedColor
    }

    func findNextShape() {
        guard !progress.isComplete else { return }
        if progress.isFinished(color: selectedColor), let next = progress.nextUnfinishedColor(after: selectedColor) {
            select(color: next)
        }
        if let region = canvas?.nearestUnpaintedRegion(of: selectedColor) {
            canvas?.focus(on: region)
        }
    }

    func dismissCelebration() {
        showsCelebration = false
    }

    /// The painting as it looks now, for thumbnails and saving to Photos.
    func snapshot(width: CGFloat) -> UIImage? {
        canvas?.snapshot(width: width)
    }

    /// Saves immediately (used when leaving the screen or the app going to the background).
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard hasUnsavedChanges else { return }
        hasUnsavedChanges = false
        store.saveProgress(artworkID, filledRegions: progress.filledRegions, isComplete: progress.isComplete, thumbnail: snapshot(width: 360))
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func finishColor() {
        SoundPlayer.shared.playColorDone()
        Haptics.success()
        cheerCount += 1
        showCheer(Self.cheers[cheerCount % Self.cheers.count])
        // Hand the child the next paint pot automatically.
        if let next = progress.nextUnfinishedColor(after: selectedColor) {
            selectedColor = next
            canvas?.selectionChanged()
        }
    }

    private func finishPicture() {
        SoundPlayer.shared.playPictureDone()
        Haptics.success()
        canvas?.selectionChanged()
        canvas?.zoomToFit()
        saveNow()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.7))
            self?.showsCelebration = true
        }
    }

    private func showCheer(_ text: String) {
        cheer = Cheer(id: cheerCount, text: text)
        cheerTask?.cancel()
        cheerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.cheer = nil
        }
    }
}
