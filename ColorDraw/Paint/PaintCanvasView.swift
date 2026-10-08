import ColorDrawKit
import SwiftUI
import UIKit

/// How forgiving painting with a finger is. All values are in screen points, so they feel the
/// same at every zoom level.
enum PaintTouch {
    /// Radius of the round "brush" under a finger dragging across the picture: every shape of the
    /// selected color within it gets painted. A child's fingertip covers about 40 pt, so a 32 pt
    /// wide brush paints what the finger visibly touches. Raise it to make swiping more forgiving.
    static let strokeRadius: CGFloat = 16
    /// How far a tap may land from a shape of the selected color and still paint it.
    static let tapForgiveness: CGFloat = 16
    /// When zoomed in, a drag that starts on a shape of another color paints whatever it crosses.
    /// After this distance without painting, it becomes "move the picture" — unless a shape of
    /// the selected color lies ahead in the direction the finger is heading, in which case the
    /// child is sweeping toward it and the drag keeps painting.
    static let moveDecisionDistance: CGFloat = 40
}

/// The zoomable picture. One finger paints (tap or drag), two fingers pinch and move. When zoomed
/// in, a one-finger drag that paints nothing moves the picture instead, and in move mode every
/// one-finger drag does.
///
/// Layers inside the zoomed content view, bottom to top:
/// 1. Paint tiles: the painted / blank / striped regions (a bitmap from `PaintBuffer`), split into
///    tiles so painting a shape re-uploads only the few tiles it touches. Mosaics carry their
///    grid lines in this bitmap.
/// 2. `outlineLayer`: smooth region borders (a bitmap made once; not used by mosaics).
/// 3. `numbersLayer`: numbers as vector text, redrawn sharply for every zoom level.
/// Sparkles and pulses live in `effectsView` above the scroll view, so they keep their size.
final class PaintCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate, PaintCanvasControlling {
    private let session: PaintSession
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let paintTilesLayer = CALayer()
    private var paintTiles: [CALayer] = []
    private var tileColumns = 0
    private var dirtyTiles = IndexSet()
    private static let tileSize = 256
    private let outlineLayer = CALayer()
    /// Lights up the shapes of a newly chosen paint for a moment (see `flashSelection`).
    private let flashLayer = CALayer()
    private let numbersLayer = NumbersLayer()
    private let effectsView = UIView()
    private let buffer: PaintBuffer
    private var outlineImage: CGImage?
    /// Square mosaics are drawn pixel-sharp once zoomed in far enough (see `updatePaintFilter`).
    private var usesSharpPixels = false
    /// A small map for drawing small pictures of a mosaic in progress (see `snapshot`).
    private var snapshotDetail: DetailMap?
    private var needsPaintUpload = false
    private var laidOutSize: CGSize = .zero
    private var lastStrokePoint: CGPoint?
    /// The paint a drag started with; the stroke ends if the color changes underneath it.
    private var strokeColor: Int?
    /// What the current one-finger drag does.
    private enum StrokeMode { case paint, undecided, move }
    private var strokeMode: StrokeMode?
    /// Screen distance an undecided drag has traveled without painting anything.
    private var undecidedTravel: CGFloat = 0
    /// Where the current drag started (content coordinates).
    private var strokeStart: CGPoint?
    private var lastSparkle = Date.distantPast
    /// Set while a one-finger drag is moving the picture rather than painting: the content
    /// offset when the drag began.
    private var panStartOffset: CGPoint?
    private var isMoveMode = false
    /// True while the picture glides on after a one-finger flick.
    private var isGliding = false
    private weak var focusMarker: UIView?
    private var visibleColorsWorkItem: DispatchWorkItem?

    /// Room kept free under the picture for the zoom buttons.
    static let bottomControlsHeight: CGFloat = 62


    init(session: PaintSession) {
        self.session = session
        buffer = PaintBuffer(detail: session.detail)
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = true

        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        // Moving needs two fingers; one finger is for painting.
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        scrollView.delaysContentTouches = false
        addSubview(scrollView)

        scrollView.addSubview(contentView)

        contentView.layer.addSublayer(paintTilesLayer)
        flashLayer.contentsGravity = .resize
        flashLayer.magnificationFilter = .linear
        flashLayer.opacity = 0
        flashLayer.cornerRadius = 6
        flashLayer.masksToBounds = true
        contentView.layer.addSublayer(flashLayer)
        outlineLayer.contentsGravity = .resize
        outlineLayer.magnificationFilter = .linear
        outlineLayer.minificationFilter = .trilinear
        // Rounded per layer: cheap for single-image layers, unlike masking the zooming view.
        outlineLayer.cornerRadius = 6
        outlineLayer.masksToBounds = true
        contentView.layer.addSublayer(outlineLayer)
        contentView.layer.addSublayer(numbersLayer)
        makePaintTiles()

        effectsView.isUserInteractionEnabled = false
        addSubview(effectsView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
        let stroke = UIPanGestureRecognizer(target: self, action: #selector(handleStroke(_:)))
        stroke.maximumNumberOfTouches = 1
        stroke.delegate = self
        addGestureRecognizer(stroke)

        // The picture is one accessibility element; the "Find" marker is another one beside it.
        contentView.isAccessibilityElement = true
        contentView.accessibilityLabel = "Coloring picture"
        contentView.accessibilityHint = "Tap shapes with the matching number to paint them. Use the light bulb button to find one."

        if session.detail.tiling == nil {
            outlineImage = OutlineRenderer.makeImage(session.detail, color: CanvasStyle.standard.outline)
            outlineLayer.contents = outlineImage
        } else {
            outlineLayer.isHidden = true
        }
        renderAllRegions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var puzzle: Puzzle { session.puzzle }

    // MARK: Layout

    override func didMoveToWindow() {
        super.didMoveToWindow()
        numbersLayer.contentsScale = traitCollection.displayScale
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        effectsView.frame = bounds
        guard bounds.width > 0, bounds.height > 0, bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        focusMarker?.removeFromSuperview()

        // At zoom 1 the whole picture fits on screen, above the zoom buttons.
        var available = bounds.insetBy(dx: 14, dy: 14).size
        available.height -= Self.bottomControlsHeight
        let aspect = CGFloat(puzzle.width) / CGFloat(puzzle.height)
        var size = available
        if available.width / available.height > aspect {
            size.width = (available.height * aspect).rounded()
        } else {
            size.height = (available.width / aspect).rounded()
        }
        scrollView.zoomScale = 1
        contentView.frame = CGRect(origin: .zero, size: size)
        scrollView.contentSize = size
        for layer in [paintTilesLayer, flashLayer, outlineLayer, numbersLayer] as [CALayer] {
            layer.frame = contentView.bounds
        }
        layoutPaintTiles()
        let pixelSize = size.width / CGFloat(puzzle.width)
        let maximumZoom = Self.maximumZoom(for: puzzle, pixelSize: pixelSize)
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = maximumZoom
        numbersLayer.configure(puzzle: puzzle, filled: session.progress.filled, pixelSize: pixelSize, maximumZoom: maximumZoom)
        centerContent()
        refreshVisibleColors()
        updateOutlineStrength()
        updatePaintFilter()
    }

    /// Enough zoom that even the smallest number becomes big enough to read comfortably.
    private static func maximumZoom(for puzzle: Puzzle, pixelSize: CGFloat) -> CGFloat {
        let smallest = puzzle.regions.map { NumberRenderer.fontSize(for: $0, in: puzzle, pixelSize: pixelSize) }.min() ?? 10
        return min(10, max(3, 24 / max(smallest, 0.5)))
    }

    /// Centers the picture while it's smaller than the screen, and always leaves room to scroll
    /// its bottom edge above the zoom buttons.
    private func centerContent() {
        let reserve = Self.bottomControlsHeight
        let horizontal = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
        let vertical = max((scrollView.bounds.height - reserve - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical + reserve, right: horizontal)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        scheduleVisibleColorsRefresh()
        updateOutlineStrength()
        updatePaintFilter()
    }

    /// Smoothing a magnified bitmap softens the edges of square tiles, so once each bitmap pixel
    /// covers 3 or more screen pixels, square mosaics switch to sharp pixels (blocky like pixel
    /// art, but crisp). Below that, sharp pixels would come out unevenly sized, and triangles'
    /// slanted sides always need smoothing.
    private func updatePaintFilter() {
        guard session.detail.tiling?.shape == .squares, contentView.bounds.width > 0 else { return }
        let screenPixelsPerPixel = contentView.bounds.width * scrollView.zoomScale * traitCollection.displayScale / CGFloat(session.detail.width)
        let sharp = screenPixelsPerPixel >= 3
        guard sharp != usesSharpPixels else { return }
        usesSharpPixels = sharp
        for tile in paintTiles {
            tile.magnificationFilter = sharp ? .nearest : .linear
        }
    }

    /// Pictures with hundreds of shapes are a dense web of lines when zoomed out, which hides the
    /// picture. Their outlines start soft and become fully crisp as the child zooms in to paint.
    private func updateOutlineStrength() {
        guard session.usesLargePalette, outlineImage != nil else { return }
        let zoomedIn = min(1, max(0, (scrollView.zoomScale - 1) / 2))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outlineLayer.opacity = Float(0.45 + 0.55 * zoomedIn)
        CATransaction.commit()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        scheduleVisibleColorsRefresh()
        guard scrollView.isTracking || scrollView.isZooming || scrollView.isDecelerating else { return }
        // The child is moving the picture around: they're busy, not stuck. And the marker sits in
        // screen space, so it would drift away from its shape.
        session.noteActivity()
        focusMarker?.removeFromSuperview()
    }

    // MARK: Painting gestures

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // Like any scroll view: a tap on a gliding picture just stops it.
        if isGliding {
            stopGlide()
            return
        }
        let point = gesture.location(in: contentView)
        guard let region = region(at: point) else { return }
        if session.canPaint(region: region) {
            session.paint(region: region, isTap: true)
            return
        }
        if session.usesLargePalette && !session.progress.filled[region] {
            // Big puzzles: a tap on an unpainted shape picks up its paint — unless it landed
            // right next to a shape of the paint in hand (tiny mosaic tiles are easy to miss by a
            // hair). Near the middle of the shape, it's clearly that shape the child wants.
            let shapeRadius = CGFloat(puzzle.regions[region].labelRadius) * contentView.bounds.width / CGFloat(puzzle.width) * scrollView.zoomScale
            let reach = min(PaintTouch.tapForgiveness, shapeRadius * 0.5)
            let nearby = regions(along: point, to: point, screenRadius: reach).first(where: session.canPaint(region:))
            session.paint(region: nearby ?? region, isTap: true)
            return
        }
        // Forgive slightly-off taps on small shapes: paint the closest matching shape nearby.
        if let nearby = regions(along: point, to: point, screenRadius: PaintTouch.tapForgiveness).first(where: session.canPaint(region:)) {
            session.paint(region: nearby, isTap: true)
        } else {
            session.paint(region: region, isTap: true)
        }
    }

    @objc private func handleStroke(_ gesture: UIPanGestureRecognizer) {
        // A second finger means the child is zooming, not painting.
        if gesture.numberOfTouches > 1 || scrollView.pinchGestureRecognizer?.state == .changed {
            endStroke()
            return
        }
        let point = gesture.location(in: contentView)
        switch gesture.state {
        case .began:
            // Catch a gliding picture first, so the finger's position is measured against what's
            // actually on screen.
            stopGlide()
            // Start where the finger first touched, not where the drag was recognized.
            let translation = gesture.translation(in: contentView)
            lastStrokePoint = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            strokeStart = lastStrokePoint
            strokeColor = session.selectedColor
            undecidedTravel = 0
            if isMoveMode {
                beginMoving(gesture, keepingCurrentPosition: false)
            } else {
                // Zoomed out, a drag always paints. Zoomed in, it paints too, unless it turns out
                // the child is trying to move the picture (see `continueStroke`).
                strokeMode = scrollView.zoomScale > 1.05 ? .undecided : .paint
                continueStroke(to: point, gesture: gesture)
            }
        case .changed:
            if strokeMode == .move, let panStartOffset {
                movePicture(with: gesture, from: panStartOffset)
            } else {
                continueStroke(to: point, gesture: gesture)
            }
        case .ended:
            if strokeMode == .move, let panStartOffset {
                movePicture(with: gesture, from: panStartOffset)
            } else {
                // Paint the last stretch too: a quick flick may have reported only one or two
                // positions before the finger lifted.
                continueStroke(to: point, gesture: gesture)
            }
            endStroke()
        default:
            if strokeMode == .move, let panStartOffset {
                movePicture(with: gesture, from: panStartOffset)
            }
            endStroke()
        }
    }

    /// Paints everything the brush crosses from the last finger position to `point`.
    private func continueStroke(to point: CGPoint, gesture: UIPanGestureRecognizer) {
        // Finishing a color hands over the next paint; don't let the same stroke keep going
        // with a color the child didn't choose.
        guard let last = lastStrokePoint, strokeColor == session.selectedColor else {
            lastStrokePoint = nil
            return
        }
        let paintedSomething = paintStroke(from: last, to: point)
        lastStrokePoint = point
        guard strokeMode == .undecided else { return }
        if paintedSomething {
            strokeMode = .paint
        } else {
            undecidedTravel += hypot(point.x - last.x, point.y - last.y) * scrollView.zoomScale
            if undecidedTravel > PaintTouch.moveDecisionDistance {
                if isPaintAhead(of: point) {
                    strokeMode = .paint
                } else {
                    beginMoving(gesture, keepingCurrentPosition: true)
                }
            }
        }
    }

    /// Switches the drag to moving the picture. `keepingCurrentPosition` makes the picture start
    /// following the finger from where it is now (instead of jumping by the distance the finger
    /// already traveled while the drag was undecided).
    private func beginMoving(_ gesture: UIPanGestureRecognizer, keepingCurrentPosition: Bool) {
        strokeMode = .move
        let translation = keepingCurrentPosition ? gesture.translation(in: scrollView) : .zero
        panStartOffset = CGPoint(x: scrollView.contentOffset.x + translation.x, y: scrollView.contentOffset.y + translation.y)
        movePicture(with: gesture, from: panStartOffset!)
    }

    /// Whether a shape of the selected color lies on screen in the direction the finger has been
    /// moving, within the brush's reach.
    private func isPaintAhead(of point: CGPoint) -> Bool {
        guard let start = strokeStart else { return false }
        let dx = point.x - start.x, dy = point.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return false }
        // Follow the direction to the edge of what's visible.
        let visible = visibleContentRect
        var reach = CGFloat.greatestFiniteMagnitude
        if dx > 0 { reach = min(reach, (visible.maxX - point.x) / (dx / length)) }
        if dx < 0 { reach = min(reach, (visible.minX - point.x) / (dx / length)) }
        if dy > 0 { reach = min(reach, (visible.maxY - point.y) / (dy / length)) }
        if dy < 0 { reach = min(reach, (visible.minY - point.y) / (dy / length)) }
        guard reach > 0, reach < .greatestFiniteMagnitude else { return false }
        let end = CGPoint(x: point.x + dx / length * reach, y: point.y + dy / length * reach)
        return regions(along: point, to: end, screenRadius: PaintTouch.strokeRadius).contains(where: session.canPaint(region:))
    }

    private func endStroke() {
        strokeStart = nil
        lastStrokePoint = nil
        strokeColor = nil
        strokeMode = nil
        panStartOffset = nil
    }

    /// Scrolls the picture along with a one-finger drag, gliding a little after the finger lifts.
    private func movePicture(with gesture: UIPanGestureRecognizer, from startOffset: CGPoint) {
        session.noteActivity()
        focusMarker?.removeFromSuperview()
        let translation = gesture.translation(in: scrollView)
        switch gesture.state {
        case .began, .changed:
            scrollView.contentOffset = clampedOffset(CGPoint(x: startOffset.x - translation.x, y: startOffset.y - translation.y))
        default:
            panStartOffset = nil
            let velocity = gesture.velocity(in: scrollView)
            let current = scrollView.contentOffset
            let target = clampedOffset(CGPoint(x: current.x - velocity.x * 0.18, y: current.y - velocity.y * 0.18))
            isGliding = true
            UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                self.scrollView.contentOffset = target
            } completion: { _ in
                self.isGliding = false
            }
        }
    }

    /// Stops a glide where the picture is on screen right now. Only touches our own glide, never
    /// an in-flight zoom animation.
    private func stopGlide() {
        guard isGliding else { return }
        isGliding = false
        let onScreen = scrollView.layer.presentation()?.bounds.origin ?? scrollView.contentOffset
        scrollView.layer.removeAllAnimations()
        scrollView.contentOffset = onScreen
    }

    private func clampedOffset(_ offset: CGPoint) -> CGPoint {
        let insets = scrollView.contentInset
        let maxX = max(-insets.left, scrollView.contentSize.width - scrollView.bounds.width + insets.right)
        let maxY = max(-insets.top, scrollView.contentSize.height - scrollView.bounds.height + insets.bottom)
        return CGPoint(x: min(max(offset.x, -insets.left), maxX), y: min(max(offset.y, -insets.top), maxY))
    }

    /// Paints every shape of the selected color that the brush sweeps over between two finger
    /// positions, in the order the finger reaches them. Returns whether anything got painted.
    @discardableResult
    private func paintStroke(from start: CGPoint, to end: CGPoint) -> Bool {
        session.noteActivity()
        var paintedSomething = false
        for region in regions(along: start, to: end, screenRadius: PaintTouch.strokeRadius) where session.canPaint(region: region) {
            session.paint(region: region, isTap: false)
            paintedSomething = true
            if session.selectedColor != strokeColor { break }
        }
        return paintedSomething
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    // MARK: Hit testing

    /// High-res map coordinates for a point in content view coordinates.
    private func detailPoint(_ point: CGPoint) -> (x: Int, y: Int) {
        let scale = CGFloat(session.detail.width) / max(contentView.bounds.width, 1)
        return (Int((point.x * scale).rounded(.down)), Int((point.y * scale).rounded(.down)))
    }

    private func region(at point: CGPoint) -> Int? {
        let p = detailPoint(point)
        return session.detail.region(atX: p.x, y: p.y)
    }

    /// Regions within a screen-sized radius of the path between two points (content view
    /// coordinates), in the order the path reaches them.
    private func regions(along start: CGPoint, to end: CGPoint, screenRadius: CGFloat) -> [Int] {
        let scale = CGFloat(session.detail.width) / max(contentView.bounds.width, 1)
        return session.detail.regions(
            alongSegmentFrom: CGPoint(x: start.x * scale, y: start.y * scale),
            to: CGPoint(x: end.x * scale, y: end.y * scale),
            radius: screenRadius / scrollView.zoomScale * scale
        )
    }

    // MARK: PaintCanvasControlling

    func regionPainted(_ region: Int) {
        focusMarker?.removeFromSuperview()
        buffer.update(region: region, to: session.appearance(of: region))
        markTilesDirty(for: session.detail.bounds[region])
        numbersLayer.markFilled(region)
        scheduleVisibleColorsRefresh()
        schedulePaintUpload()
        // A fast swipe can paint dozens of shapes a second; a burst of stars for each would just
        // be clutter (and work), so sparkles are spaced out.
        if Date().timeIntervalSince(lastSparkle) > 0.07 {
            lastSparkle = Date()
            sparkle(at: region)
        }
    }

    func selectionChanged() {
        focusMarker?.removeFromSuperview()
        renderAllRegions()
        flashSelection()
    }

    /// Every unpainted shape of the paint in hand blinks twice in that paint, so a child sees at
    /// a glance where it goes — even tiny tiles of a big mosaic seen whole, where stripes are
    /// too fine to notice. With Reduce Motion it fades in and out once instead.
    func flashSelection() {
        guard !session.isComplete else { return }
        let color = session.selectedColor
        let filled = session.progress.filled
        let shapes = puzzle.regions.indices.filter { !filled[$0] && puzzle.regions[$0].colorIndex == color }
        flashLayer.removeAnimation(forKey: "flash")
        flashLayer.contents = PuzzleSnapshot.mask(of: puzzle, regions: shapes, color: puzzle.palette[color])
        let flash = CAKeyframeAnimation(keyPath: "opacity")
        if UIAccessibility.isReduceMotionEnabled {
            flash.values = [0, 0.7, 0]
            flash.keyTimes = [0, 0.4, 1]
            flash.duration = 1.2
        } else {
            flash.values = [0, 0.85, 0.15, 0.85, 0]
            flash.keyTimes = [0, 0.2, 0.5, 0.7, 1]
            flash.duration = 1.4
        }
        flashLayer.add(flash, forKey: "flash")
    }

    func zoom(by factor: CGFloat) {
        let target = min(max(scrollView.zoomScale * factor, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        let visibleCenter = CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY)
        let center = scrollView.convert(visibleCenter, to: contentView)
        zoom(to: center, scale: target)
    }

    func zoomToFit() {
        focusMarker?.removeFromSuperview()
        scrollView.setZoomScale(1, animated: true)
    }

    func setMoveMode(_ isOn: Bool) {
        // In move mode one-finger drags scroll the picture; taps still paint.
        isMoveMode = isOn
    }

    /// The part of the picture the child can see: the screen minus the strip under the controls.
    private var visibleContentRect: CGRect {
        var visible = scrollView.bounds
        visible.size.height -= Self.bottomControlsHeight
        return scrollView.convert(visible, to: contentView)
    }

    /// How many nearby colors are reported to the paint tray (it shows as many as fit).
    static let nearbyColorCount = 12

    /// Tells the session which colors have unpainted shapes closest to the middle of the screen:
    /// the ones the child is looking at. Cheap enough for every scroll step (one distance per
    /// shape); the session ignores unchanged results.
    /// While the picture moves, the tray keeps still (pots shouldn't shuffle under a finger);
    /// it catches up a moment after the picture comes to rest.
    private func scheduleVisibleColorsRefresh() {
        visibleColorsWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshVisibleColors() }
        visibleColorsWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func refreshVisibleColors() {
        guard contentView.bounds.width > 0 else { return }
        let visible = visibleContentRect
        let center = CGPoint(x: visible.midX, y: visible.midY)
        let pixelSize = contentView.bounds.width / CGFloat(puzzle.width)
        let zoom = scrollView.zoomScale
        // Shapes whose number the child can read right now come first; then (say, a mosaic seen
        // whole, its numbers still too small) the colors they can see.
        var readable: [Int: CGFloat] = [:], seen: [Int: CGFloat] = [:]
        let filled = session.progress.filled
        for (index, region) in puzzle.regions.enumerated() where !filled[index] {
            let point = labelPoint(of: index)
            guard visible.contains(point) else { continue }
            // Close to the middle, with a head start for bigger shapes: those catch the eye first.
            let score = hypot(point.x - center.x, point.y - center.y) - CGFloat(region.labelRadius) * pixelSize
            let isReadable = NumberRenderer.fontSize(for: region, in: puzzle, pixelSize: pixelSize) * zoom >= NumbersLayer.minimumReadableSize
            if isReadable {
                if score < readable[region.colorIndex, default: .infinity] { readable[region.colorIndex] = score }
            } else if score < seen[region.colorIndex, default: .infinity] {
                seen[region.colorIndex] = score
            }
        }
        let closest = readable.sorted { $0.value < $1.value }.map(\.key)
            + seen.filter { readable[$0.key] == nil }.sorted { $0.value < $1.value }.map(\.key)
        session.updateVisibleColors(Array(closest.prefix(Self.nearbyColorCount)))
    }

    func isAnyUnpaintedRegionVisible(of color: Int) -> Bool {
        let visible = visibleContentRect
        return puzzle.regions.indices.contains { region in
            !session.progress.filled[region] && puzzle.regions[region].colorIndex == color && visible.contains(labelPoint(of: region))
        }
    }

    func focus(on region: Int) {
        let center = labelPoint(of: region)
        // Zoom in until the number is comfortably big (but never zoom out). Mosaics stop sooner,
        // so the child still sees the tiles around it.
        let fontSize = NumberRenderer.fontSize(for: puzzle.regions[region], in: puzzle, pixelSize: contentView.bounds.width / CGFloat(puzzle.width))
        let comfortable: CGFloat = puzzle.tiling != nil ? 18 : 30
        let wanted = min(scrollView.maximumZoomScale, max(scrollView.zoomScale, comfortable / max(fontSize, 1)))
        zoom(to: center, scale: wanted) { [weak self] finished in
            if finished { self?.showFocusMarker(on: region) }
        }
    }

    func point(at region: Int) {
        // Only point at shapes the child can see right now. Automatic pointing never moves
        // VoiceOver's focus; only the light bulb (`focus(on:)`) does.
        guard visibleContentRect.contains(labelPoint(of: region)) else { return }
        showFocusMarker(on: region, showsHand: true, movesVoiceOverFocus: false)
    }

    func nearestUnpaintedRegion(of color: Int) -> Int? {
        let visibleCenter = scrollView.convert(CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: contentView)
        let pixelSize = contentView.bounds.width / CGFloat(puzzle.width)
        let filled = session.progress.filled
        let candidates = puzzle.regions.indices.filter { !filled[$0] && puzzle.regions[$0].colorIndex == color }
        if puzzle.tiling != nil {
            // All tiles are the same size: prefer one in the middle of a patch of its color over
            // a lone speck nearby. It's easier to spot, and a swipe there paints many.
            let tileSize = CGFloat(puzzle.regions.first?.labelRadius ?? 1) * 2 * pixelSize
            let scored = candidates.map { tile -> (tile: Int, score: CGFloat) in
                let point = labelPoint(of: tile)
                let distance = hypot(point.x - visibleCenter.x, point.y - visibleCenter.y)
                return (tile, (distance + tileSize * 4) / CGFloat(1 + session.patchSize(around: tile)))
            }
            return scored.min { $0.score < $1.score }?.tile
        }
        return candidates
            .min { a, b in
                let pa = labelPoint(of: a), pb = labelPoint(of: b)
                // Prefer close shapes, but give big ones a head start: they're easier to find.
                let da = hypot(pa.x - visibleCenter.x, pa.y - visibleCenter.y) - CGFloat(puzzle.regions[a].labelRadius) * pixelSize * 2
                let db = hypot(pb.x - visibleCenter.x, pb.y - visibleCenter.y) - CGFloat(puzzle.regions[b].labelRadius) * pixelSize * 2
                return da < db
            }
    }

    func snapshot(width: CGFloat) -> UIImage? {
        // Hundreds of outlines would turn a small picture of a big puzzle into a gray mesh.
        let outlineAlpha: CGFloat = session.usesLargePalette ? 0.35 : 1
        if puzzle.tiling != nil && !session.isComplete {
            // The canvas draws a mosaic's grid lines into the paint at full strength; a small
            // picture gets fainter ones, like the thumbnail made when the puzzle was created.
            let scale = max(1, min(4, Int((Double(width) * 2 / Double(puzzle.width)).rounded(.up))))
            if snapshotDetail?.scale != scale { snapshotDetail = DetailMap(puzzle: puzzle, scale: scale) }
            guard let detail = snapshotDetail else { return nil }
            return PuzzleSnapshot.render(
                puzzle: puzzle,
                detail: detail,
                appearance: { [session] in session.appearance(of: $0) },
                outputWidth: Int(width),
                outlineOpacity: outlineAlpha
            ).map(UIImage.init(cgImage:))
        }
        // Read the buffer, not the layer: the layer's bitmap is refreshed on the next run loop,
        // so it can still miss the shape that was just painted.
        guard let paintImage = buffer.makeImage() else { return nil }
        let size = CGSize(width: width, height: (width * CGFloat(puzzle.height) / CGFloat(puzzle.width)).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIImage(cgImage: paintImage).draw(in: rect)
            // Mosaics have their grid lines in the paint (and none on painted tiles).
            if let outlineImage {
                UIImage(cgImage: outlineImage).draw(in: rect, blendMode: .normal, alpha: outlineAlpha)
            }
        }
    }

    // MARK: Drawing

    private func renderAllRegions() {
        buffer.setHighlightTint(session.selectedPaint)
        buffer.render { [session] in session.appearance(of: $0) }
        dirtyTiles.insert(integersIn: 0..<paintTiles.count)
        schedulePaintUpload()
    }

    // MARK: Paint tiles

    /// One layer per 256 × 256 block of the high-res picture. Each tile's image carries a
    /// one-pixel apron from its neighbors (hidden with `contentsRect`), so smoothing at the
    /// edges blends with the right colors and no seams show between tiles.
    private func makePaintTiles() {
        let detail = session.detail
        tileColumns = (detail.width + Self.tileSize - 1) / Self.tileSize
        let rows = (detail.height + Self.tileSize - 1) / Self.tileSize
        paintTiles = (0..<(tileColumns * rows)).map { index in
            let tile = CALayer()
            tile.isOpaque = true
            tile.contentsGravity = .resize
            tile.magnificationFilter = .linear
            tile.minificationFilter = .trilinear
            // Round the picture's outer corners on the corner tiles only.
            let column = index % tileColumns, row = index / tileColumns
            var corners: CACornerMask = []
            if column == 0 && row == 0 { corners.insert(.layerMinXMinYCorner) }
            if column == tileColumns - 1 && row == 0 { corners.insert(.layerMaxXMinYCorner) }
            if column == 0 && row == rows - 1 { corners.insert(.layerMinXMaxYCorner) }
            if column == tileColumns - 1 && row == rows - 1 { corners.insert(.layerMaxXMaxYCorner) }
            if !corners.isEmpty {
                tile.cornerRadius = 6
                tile.maskedCorners = corners
                tile.masksToBounds = true
            }
            paintTilesLayer.addSublayer(tile)
            return tile
        }
        dirtyTiles.insert(integersIn: 0..<paintTiles.count)
    }

    /// The pixel block a tile shows (inclusive bounds).
    private func tilePixels(_ index: Int) -> PixelBounds {
        let detail = session.detail
        let column = index % tileColumns, row = index / tileColumns
        return PixelBounds(
            minX: column * Self.tileSize,
            minY: row * Self.tileSize,
            maxX: min(detail.width, (column + 1) * Self.tileSize) - 1,
            maxY: min(detail.height, (row + 1) * Self.tileSize) - 1
        )
    }

    private func layoutPaintTiles() {
        let pointsPerPixel = contentView.bounds.width / CGFloat(session.detail.width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, tile) in paintTiles.enumerated() {
            let pixels = tilePixels(index)
            tile.frame = CGRect(
                x: CGFloat(pixels.minX) * pointsPerPixel,
                y: CGFloat(pixels.minY) * pointsPerPixel,
                width: CGFloat(pixels.maxX - pixels.minX + 1) * pointsPerPixel,
                height: CGFloat(pixels.maxY - pixels.minY + 1) * pointsPerPixel
            )
        }
        CATransaction.commit()
    }

    private func markTilesDirty(for bounds: PixelBounds) {
        guard !bounds.isEmpty, tileColumns > 0 else { return }
        for row in (bounds.minY / Self.tileSize)...(bounds.maxY / Self.tileSize) {
            for column in (bounds.minX / Self.tileSize)...(bounds.maxX / Self.tileSize) {
                dirtyTiles.insert(row * tileColumns + column)
            }
        }
    }

    /// Coalesces many region updates (e.g. during a stroke) into one upload per frame, of only
    /// the tiles that changed.
    private func schedulePaintUpload() {
        guard !needsPaintUpload else { return }
        needsPaintUpload = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            needsPaintUpload = false
            let detail = session.detail
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            for index in dirtyTiles where paintTiles.indices.contains(index) {
                let inner = tilePixels(index)
                let apron = PixelBounds(
                    minX: max(0, inner.minX - 1), minY: max(0, inner.minY - 1),
                    maxX: min(detail.width - 1, inner.maxX + 1), maxY: min(detail.height - 1, inner.maxY + 1)
                )
                guard let image = buffer.makeImage(minX: apron.minX, minY: apron.minY, maxX: apron.maxX, maxY: apron.maxY) else { continue }
                let tile = paintTiles[index]
                tile.contents = image
                let width = CGFloat(apron.maxX - apron.minX + 1), height = CGFloat(apron.maxY - apron.minY + 1)
                tile.contentsRect = CGRect(
                    x: CGFloat(inner.minX - apron.minX) / width,
                    y: CGFloat(inner.minY - apron.minY) / height,
                    width: CGFloat(inner.maxX - inner.minX + 1) / width,
                    height: CGFloat(inner.maxY - inner.minY + 1) / height
                )
            }
            dirtyTiles.removeAll()
            CATransaction.commit()
        }
    }

    private func zoom(to center: CGPoint, scale: CGFloat, completion: ((Bool) -> Void)? = nil) {
        // The marker sits in screen space, so it can't stay once the picture moves.
        focusMarker?.removeFromSuperview()
        let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            self.scrollView.zoom(to: rect, animated: false)
        } completion: { finished in
            completion?(finished)
        }
    }

    private func labelPoint(of region: Int) -> CGPoint {
        let pixelSize = contentView.bounds.width / CGFloat(puzzle.width)
        let r = puzzle.regions[region]
        return CGPoint(x: CGFloat(r.labelX) * pixelSize, y: CGFloat(r.labelY) * pixelSize)
    }

    // MARK: Effects

    private func sparkle(at region: Int) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let center = contentView.convert(labelPoint(of: region), to: effectsView)
        let color = Color(puzzle.palette[puzzle.regions[region].colorIndex])
        let colors = [UIColor(color), .white, UIColor(Theme.yellow)]
        for index in 0..<7 {
            let star = CAShapeLayer()
            let size: CGFloat = index.isMultiple(of: 2) ? 12 : 8
            star.path = Self.starPath(size: size)
            star.fillColor = colors[index % colors.count].cgColor
            star.strokeColor = UIColor(Theme.ink).withAlphaComponent(0.25).cgColor
            star.lineWidth = 1
            star.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            star.position = center
            effectsView.layer.addSublayer(star)

            let angle = CGFloat(index) / 7 * 2 * .pi + .random(in: -0.3...0.3)
            let distance = CGFloat.random(in: 26...44)
            let end = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(cgPoint: center)
            move.toValue = NSValue(cgPoint: end)
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let spin = CABasicAnimation(keyPath: "transform.rotation")
            spin.toValue = CGFloat.pi * (index.isMultiple(of: 2) ? 1 : -1)
            let group = CAAnimationGroup()
            group.animations = [move, fade, spin]
            group.duration = 0.55

            CATransaction.begin()
            CATransaction.setCompletionBlock { star.removeFromSuperlayer() }
            star.opacity = 0
            star.position = end
            star.add(group, forKey: "sparkle")
            CATransaction.commit()
        }
    }

    /// A pulsing ring around a shape the child should paint next. It is also an accessibility
    /// element, so VoiceOver users can paint the shape by double-tapping it.
    private func showFocusMarker(on region: Int, showsHand: Bool = false, movesVoiceOverFocus: Bool = true) {
        focusMarker?.removeFromSuperview()
        let marker = FocusMarkerView(number: puzzle.regions[region].colorIndex + 1, showsHand: showsHand) { [weak self] in
            self?.session.paint(region: region, isTap: true)
        }
        marker.center = contentView.convert(labelPoint(of: region), to: effectsView)
        effectsView.addSubview(marker)
        focusMarker = marker
        if movesVoiceOverFocus {
            UIAccessibility.post(notification: .layoutChanged, argument: marker)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + FocusMarkerView.lifetime) { [weak marker] in
            marker?.removeFromSuperview()
        }
    }

    private static func starPath(size: CGFloat) -> CGPath {
        let path = UIBezierPath()
        let center = CGPoint(x: size / 2, y: size / 2)
        for i in 0..<10 {
            let radius = i.isMultiple(of: 2) ? size / 2 : size / 4.5
            let angle = CGFloat(i) / 10 * 2 * .pi - .pi / 2
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.close()
        return path.cgPath
    }
}

/// The pulsing "paint me!" ring shown by the Find button.
private final class FocusMarkerView: UIView {
    static let lifetime: TimeInterval = 4.2
    private static let ringSize: CGFloat = 80
    private let activate: () -> Void

    /// - Parameter showsHand: Adds a ghost finger that keeps tapping the shape ("tap here!").
    init(number: Int, showsHand: Bool, activate: @escaping () -> Void) {
        self.activate = activate
        super.init(frame: CGRect(x: 0, y: 0, width: Self.ringSize, height: Self.ringSize))
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "focusMarker"
        accessibilityLabel = "Shape number \(number)"
        accessibilityHint = "Double-tap to paint it."
        accessibilityTraits = .button

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let ring = CAShapeLayer()
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).cgPath
        ring.frame = bounds
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor(Theme.pink).cgColor
        ring.lineWidth = 6
        ring.opacity = 0
        layer.addSublayer(ring)

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.2, 0.7, 1]
        let group = CAAnimationGroup()
        group.duration = 0.84
        group.repeatCount = Float(Self.lifetime / group.duration)
        if reduceMotion {
            group.animations = [fade]
            ring.transform = CATransform3DMakeScale(0.8, 0.8, 1)
        } else {
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1.5
            shrink.toValue = 0.5
            group.animations = [shrink, fade]
        }
        ring.add(group, forKey: "pulse")

        if showsHand {
            let hand = UIImageView(image: UIImage(systemName: "hand.point.up.left.fill"))
            hand.tintColor = .white
            hand.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 38, weight: .bold)
            hand.layer.shadowColor = UIColor(Theme.ink).cgColor
            hand.layer.shadowOpacity = 0.6
            hand.layer.shadowRadius = 3
            hand.layer.shadowOffset = CGSize(width: 0, height: 2)
            hand.sizeToFit()
            // The fingertip rests on the shape's center.
            hand.center = CGPoint(x: bounds.midX + hand.bounds.width * 0.32, y: bounds.midY + hand.bounds.height * 0.42)
            addSubview(hand)
            if !reduceMotion {
                let press = CAKeyframeAnimation(keyPath: "transform")
                press.values = [CATransform3DIdentity, CATransform3DMakeScale(0.85, 0.85, 1), CATransform3DIdentity]
                press.keyTimes = [0, 0.3, 0.6]
                press.duration = 0.84
                press.repeatCount = group.repeatCount
                hand.layer.add(press, forKey: "tap")
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func accessibilityActivate() -> Bool {
        activate()
        return true
    }
}

/// SwiftUI wrapper for the canvas.
struct PaintCanvas: UIViewRepresentable {
    let session: PaintSession

    func makeUIView(context: Context) -> PaintCanvasView {
        let view = PaintCanvasView(session: session)
        session.canvas = view
        return view
    }

    func updateUIView(_ uiView: PaintCanvasView, context: Context) {}
}
