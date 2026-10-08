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
    /// Makes a region pulse without moving the picture.
    func point(at region: Int)
    /// The id of an unpainted region of `color` near the middle of the screen.
    func nearestUnpaintedRegion(of color: Int) -> Int?
    /// Whether any unpainted region of `color` is on screen right now.
    func isAnyUnpaintedRegionVisible(of color: Int) -> Bool
    /// One finger moves the picture (instead of painting) while this is on.
    func setMoveMode(_ isOn: Bool)
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
    /// Per color: changes whenever that paint pot should wiggle to show it's the one a shape needs.
    private(set) var hintTokens: [Int]
    /// The color of the most recent hint, so the palette can scroll to it.
    private(set) var hintedColor: Int?
    /// A short message that pops up after finishing a color.
    private(set) var cheer: Cheer?
    /// Whether the "You did it!" card is showing.
    private(set) var showsCelebration = false
    /// Changes when the child seems stuck, to make the light-bulb button wiggle.
    private(set) var helpNudge = 0
    /// Set when progress couldn't be saved (say, the device is full); cleared by the next good save.
    private(set) var saveFailed = false
    /// One finger moves the picture instead of painting.
    var isMoveMode = false {
        didSet { canvas?.setMoveMode(isMoveMode) }
    }

    @ObservationIgnored weak var canvas: PaintCanvasControlling?
    @ObservationIgnored private let store: ArtworkStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var cheerTask: Task<Void, Never>?
    @ObservationIgnored private var celebrationTask: Task<Void, Never>?
    @ObservationIgnored private var cheerCount = 0
    @ObservationIgnored private var hintCount = 0
    @ObservationIgnored private var hasUnsavedChanges = false
    @ObservationIgnored private var unsavedSince: Date?
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var lastWrongTap: (region: Int, date: Date)?
    @ObservationIgnored private var idleNudges = 0

    private static let cheers = ["Great job!", "Super!", "Wow!", "Amazing!", "You rock!", "Yay!", "So pretty!", "Brilliant!"]

    init(artwork: ArtworkMetadata, puzzle: Puzzle, detail: DetailMap, store: ArtworkStore) {
        artworkID = artwork.id
        self.puzzle = puzzle
        self.detail = detail
        self.store = store
        let progress = PaintProgress(puzzle: puzzle, filledRegions: artwork.filledRegions)
        self.progress = progress
        selectedColor = progress.remainingByColor.firstIndex { $0 > 0 } ?? 0
        hintTokens = [Int](repeating: 0, count: puzzle.palette.count)
    }

    var isComplete: Bool { progress.isComplete }

    var selectedPaint: RGBColor { puzzle.palette[selectedColor] }

    func appearance(of region: Int) -> RegionAppearance {
        let color = puzzle.regions[region].colorIndex
        if progress.filled[region] { return .painted(puzzle.palette[color]) }
        return color == selectedColor && !progress.isComplete ? .highlighted : .blank
    }

    func select(color: Int) {
        guard puzzle.palette.indices.contains(color) else { return }
        noteActivity()
        if progress.isFinished(color: color) {
            // Nothing left to paint with this pot: it wiggles "all done!" instead.
            hintCount += 1
            hintTokens[color] = hintCount
            hintedColor = color
            Haptics.select()
            return
        }
        guard color != selectedColor else { return }
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
            markUnsaved()
            noteActivity()
            lastWrongTap = nil
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
            guard isTap else { return false }
            noteActivity()
            hintCount += 1
            hintTokens[expected] = hintCount
            hintedColor = expected
            SoundPlayer.shared.playOops()
            Haptics.oops()
            // Tapping the same shape again soon: hand over the right paint and paint it, so nobody
            // gets stuck.
            if let last = lastWrongTap, last.region == region, Date().timeIntervalSince(last.date) < 10 {
                lastWrongTap = nil
                select(color: expected)
                return paint(region: region, isTap: true)
            }
            lastWrongTap = (region, Date())
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
        lastActivity = Date()
        if progress.isFinished(color: selectedColor), let next = progress.nextUnfinishedColor(after: selectedColor) {
            select(color: next)
        }
        if let region = canvas?.nearestUnpaintedRegion(of: selectedColor) {
            canvas?.focus(on: region)
        }
    }

    /// Before the first stroke, shows where to start: the biggest shape of the selected color pulses.
    func showStartHint() {
        guard progress.filledCount == 0 else { return }
        if let biggest = unpaintedRegions(of: selectedColor).max(by: { puzzle.regions[$0].labelRadius < puzzle.regions[$1].labelRadius }) {
            canvas?.point(at: biggest)
        }
    }

    /// The child touched the picture or a control, so they're not stuck.
    func noteActivity() {
        lastActivity = Date()
        idleNudges = 0
    }

    /// Called every few seconds. When a child hasn't done anything for a while, help step by step:
    /// first make sure shapes of the paint are on screen and point at one (twice), then zoom right
    /// to one. After that only the light bulb wiggles now and then, until the child does something.
    func nudgeIfIdle() {
        guard !progress.isComplete, !showsCelebration, Date().timeIntervalSince(lastActivity) > 9 else { return }
        lastActivity = Date()
        idleNudges += 1
        helpNudge += 1
        switch idleNudges {
        case 1, 2:
            if canvas?.isAnyUnpaintedRegionVisible(of: selectedColor) == false {
                canvas?.zoomToFit()
            }
            // Pointing would keep moving VoiceOver's focus around; VoiceOver users have Find.
            guard !UIAccessibility.isVoiceOverRunning else { break }
            Task { [weak self] in
                guard (try? await Task.sleep(for: .seconds(0.5))) != nil,
                      let self, let region = canvas?.nearestUnpaintedRegion(of: selectedColor) else { return }
                canvas?.point(at: region)
            }
        case 3:
            findNextShape()
        default:
            break
        }
    }

    func dismissCelebration() {
        showsCelebration = false
    }

    /// Brings back the "You did it!" card (with its Save button) for a finished painting.
    func celebrateAgain() {
        guard progress.isComplete else { return }
        showsCelebration = true
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
        let saved = store.saveProgress(
            artworkID,
            filledRegions: progress.filledRegions,
            regionCount: progress.regionCount,
            isComplete: progress.isComplete,
            thumbnail: { [weak self] in self?.snapshot(width: 360) }
        )
        saveFailed = !saved
        if saved {
            hasUnsavedChanges = false
            unsavedSince = nil
        } else {
            // Keep the changes marked unsaved and try again in a little while, rather than on
            // every stroke.
            unsavedSince = Date()
            saveTask = Task { [weak self] in
                guard (try? await Task.sleep(for: .seconds(5))) != nil else { return }
                self?.saveNow()
            }
        }
    }

    /// Stops pending work when the painting screen goes away.
    func tearDown() {
        saveNow()
        celebrationTask?.cancel()
        cheerTask?.cancel()
    }

    private func markUnsaved() {
        hasUnsavedChanges = true
        if unsavedSince == nil { unsavedSince = Date() }
    }

    private func unpaintedRegions(of color: Int) -> [Int] {
        puzzle.regions.indices.filter { !progress.filled[$0] && puzzle.regions[$0].colorIndex == color }
    }

    /// Saves 1.5 s after the last stroke, but never lets more than 8 s of painting go unsaved
    /// (a child who never pauses would otherwise keep postponing the save).
    private func scheduleSave() {
        if let since = unsavedSince, Date().timeIntervalSince(since) > 8 {
            saveNow()
            return
        }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            self?.saveNow()
        }
    }

    private func finishColor() {
        SoundPlayer.shared.playColorDone()
        Haptics.success()
        cheerCount += 1
        showCheer(Self.cheers[cheerCount % Self.cheers.count])
        // Hand the child the next paint pot automatically…
        guard let next = progress.nextUnfinishedColor(after: selectedColor) else { return }
        selectedColor = next
        canvas?.selectionChanged()
        // …and if none of its shapes are on screen, step back so the child can see them.
        if canvas?.isAnyUnpaintedRegionVisible(of: next) == false {
            canvas?.zoomToFit()
        }
    }

    private func finishPicture() {
        SoundPlayer.shared.playPictureDone()
        Haptics.success()
        canvas?.selectionChanged()
        canvas?.zoomToFit()
        isMoveMode = false
        saveNow()
        celebrationTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(0.7))) != nil else { return }
            self?.showsCelebration = true
            SoundPlayer.shared.say("You did it!")
            UIAccessibility.post(notification: .announcement, argument: "You did it! The picture is finished.")
        }
    }

    private func showCheer(_ text: String) {
        cheer = Cheer(id: cheerCount, text: text)
        cheerTask?.cancel()
        UIAccessibility.post(notification: .announcement, argument: text)
        cheerTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            self?.cheer = nil
        }
    }
}
