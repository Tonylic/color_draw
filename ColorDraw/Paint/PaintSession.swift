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
    /// While the color chart is open the child is busy choosing, not stuck.
    var isChoosingColor = false {
        didSet { noteActivity() }
    }
    /// Set when progress couldn't be saved (say, the device is full); cleared by the next good save.
    private(set) var saveFailed = false
    /// Colors with unpainted shapes near the middle of the screen, closest first. With big
    /// palettes the paint tray offers these, so the pot a child needs is close at hand.
    private(set) var visibleColors: [Int] = []
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
    @ObservationIgnored private var reachedQuarter = 0

    private static let cheers = ["Great job!", "Super!", "Wow!", "Amazing!", "You rock!", "Yay!", "So pretty!", "Brilliant!"]

    init(artwork: ArtworkMetadata, puzzle: Puzzle, detail: DetailMap, store: ArtworkStore) {
        artworkID = artwork.id
        self.puzzle = puzzle
        self.detail = detail
        self.store = store
        let progress = PaintProgress(puzzle: puzzle, filledRegions: artwork.filledRegions)
        self.progress = progress
        let firstUnfinished = progress.remainingByColor.firstIndex { $0 > 0 } ?? 0
        if puzzle.tiling != nil {
            // Mosaics start with the color that has the most tiles: big runs to swipe across.
            let remaining = progress.remainingByColor
            selectedColor = remaining.indices.max { remaining[$0] < remaining[$1] } ?? firstUnfinished
        } else if puzzle.palette.count > Self.smallPaletteLimit {
            // Big puzzles start with the color of the biggest unpainted shape: easy to see and
            // to tap, so the first stroke is a success.
            let biggest = puzzle.regions.indices
                .filter { !progress.filled[$0] }
                .max { puzzle.regions[$0].labelRadius < puzzle.regions[$1].labelRadius }
            selectedColor = biggest.map { puzzle.regions[$0].colorIndex } ?? firstUnfinished
        } else {
            selectedColor = firstUnfinished
        }
        hintTokens = [Int](repeating: 0, count: puzzle.palette.count)
        reachedQuarter = progress.filledCount * 4 / max(1, progress.regionCount)
    }

    var isComplete: Bool { progress.isComplete }

    /// Pictures with many colors get the tray of on-screen colors plus the full color chart;
    /// small palettes simply show every pot.
    var usesLargePalette: Bool { puzzle.palette.count > Self.smallPaletteLimit }
    nonisolated static let smallPaletteLimit = 12

    /// Called by the canvas whenever the picture moves or a shape gets painted.
    func updateVisibleColors(_ colors: [Int]) {
        if colors != visibleColors { visibleColors = colors }
    }

    var selectedPaint: RGBColor { puzzle.palette[selectedColor] }

    func appearance(of region: Int) -> RegionAppearance {
        let color = puzzle.regions[region].colorIndex
        if progress.filled[region] { return .painted(puzzle.palette[color]) }
        if color == selectedColor && !progress.isComplete { return .highlighted }
        // Big photo puzzles show a pale ghost of the picture, so there's something to recognize
        // among hundreds of shapes; small ones are a classic white coloring page.
        return usesLargePalette ? .ghost(puzzle.palette[color]) : .blank
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
        if hintedColor == color { hintedColor = nil }
        canvas?.selectionChanged()
        Haptics.select()
        SoundPlayer.shared.playTick()
    }

    /// Picks a color from the color chart. If none of its shapes are on screen, the picture
    /// zooms to one so the child isn't left searching.
    func pickFromChart(color: Int) {
        select(color: color)
        guard !progress.isFinished(color: color), canvas?.isAnyUnpaintedRegionVisible(of: color) == false else { return }
        Task { [weak self] in
            // Let the chart slide away first.
            guard (try? await Task.sleep(for: .seconds(0.45))) != nil else { return }
            self?.findNextShape()
        }
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
                celebrateMilestone()
                scheduleSave()
            }
            return true
        case let .wrongColor(expected):
            guard isTap else { return false }
            noteActivity()
            hintCount += 1
            hintTokens[expected] = hintCount
            if usesLargePalette {
                // With dozens of paints, hunting for one is no fun: tapping a shape picks up its
                // paint (the pot pops in the tray), and the next tap paints.
                lastWrongTap = nil
                hintedColor = nil
                select(color: expected)
                return false
            }
            hintedColor = expected
            SoundPlayer.shared.playOops()
            Haptics.oops()
            // Tapping the same shape again soon: hand over the right paint and paint it, so nobody
            // gets stuck.
            if let last = lastWrongTap, last.region == region, Date().timeIntervalSince(last.date) < 20 {
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

    /// Before the first stroke, shows where to start: the biggest shape of the selected color
    /// pulses — in a mosaic, a tile in the middle of the biggest patch of it.
    func showStartHint() {
        guard progress.filledCount == 0 else { return }
        let candidates = unpaintedRegions(of: selectedColor)
        let start: Int?
        if let tiling = puzzle.tiling {
            // Among the fullest patches, the one nearest the middle of the picture.
            let middle = (x: Float(puzzle.width) / 2, y: Float(puzzle.height) / 2)
            let scores = candidates.map { tile -> Float in
                let region = puzzle.regions[tile]
                let offset = hypot(region.labelX - middle.x, region.labelY - middle.y) / Float(max(puzzle.width, puzzle.height))
                return Float(patchSize(around: tile, in: tiling)) - offset
            }
            start = scores.indices.max { scores[$0] < scores[$1] }.map { candidates[$0] }
        } else {
            start = candidates.max { puzzle.regions[$0].labelRadius < puzzle.regions[$1].labelRadius }
        }
        if let start { canvas?.point(at: start) }
    }

    /// How many unpainted tiles of a tile's color lie in the block of tiles around it.
    private func patchSize(around tile: Int, in tiling: Tiling) -> Int {
        let (row, column) = tiling.position(of: tile)
        let color = puzzle.regions[tile].colorIndex
        // Triangles are narrower than they are tall, so look a little further sideways.
        let across = tiling.shape == .triangles ? 3 : 2
        var count = 0
        for r in max(0, row - 2)...min(tiling.rows - 1, row + 2) {
            for c in max(0, column - across)...min(tiling.columns - 1, column + across) {
                let neighbor = r * tiling.columns + c
                if puzzle.regions[neighbor].colorIndex == color && !progress.filled[neighbor] { count += 1 }
            }
        }
        return count
    }

    /// The child touched the picture or a control, so they're not stuck.
    func noteActivity() {
        lastActivity = Date()
        idleNudges = 0
    }

    /// Called every few seconds. When a child hasn't done anything for a while, help step by step,
    /// without ever yanking the picture away from what they're looking at: first the light bulb
    /// wiggles and a shape of the paint on screen gets pointed at (twice); only if they're still
    /// stuck after about half a minute does the picture glide to a shape for them. After that
    /// only the bulb wiggles now and then, until the child does something.
    func nudgeIfIdle() {
        guard !progress.isComplete, !showsCelebration, !isChoosingColor,
              Date().timeIntervalSince(lastActivity) > 9 else { return }
        lastActivity = Date()
        idleNudges += 1
        helpNudge += 1
        // Moving the picture or VoiceOver's focus around on its own would disorient VoiceOver
        // users, who can ask for help with the light bulb; for them only the bulb wiggles.
        guard !UIAccessibility.isVoiceOverRunning else { return }
        switch idleNudges {
        case 1, 2:
            if canvas?.isAnyUnpaintedRegionVisible(of: selectedColor) == true,
               let region = canvas?.nearestUnpaintedRegion(of: selectedColor) {
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
        // In big puzzles many colors have only a shape or two; cheering for each would turn into
        // noise, so those just chime softly and the cheers are saved for milestones.
        if !usesLargePalette || progress.totalByColor[selectedColor] >= 3 {
            SoundPlayer.shared.playColorDone()
            Haptics.success()
            cheerCount += 1
            showCheer(Self.cheers[cheerCount % Self.cheers.count])
        }
        // Hand the child the next paint pot automatically: preferably one they can use right
        // where they are looking…
        guard let next = visibleColors.first(where: { !progress.isFinished(color: $0) })
            ?? progress.nextUnfinishedColor(after: selectedColor) else { return }
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
            // VoiceOver already reads the celebration card; don't talk over it.
            if !UIAccessibility.isVoiceOverRunning { SoundPlayer.shared.say("You did it!") }
        }
    }

    /// Big puzzles take a while; a cheer at each quarter keeps the child going.
    private func celebrateMilestone() {
        guard usesLargePalette else { return }
        let quarter = progress.filledCount * 4 / max(1, progress.regionCount)
        guard quarter > reachedQuarter else { return }
        reachedQuarter = quarter
        let message = ["", "A quarter done!", "Halfway there!", "Almost done!"][min(quarter, 3)]
        guard !message.isEmpty else { return }
        SoundPlayer.shared.playColorDone()
        Haptics.success()
        cheerCount += 1
        showCheer(message)
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
