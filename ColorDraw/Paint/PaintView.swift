import ColorDrawKit
import SwiftUI

/// Loads a saved painting, then shows the painting screen.
struct PaintScreen: View {
    let artworkID: UUID
    @Environment(ArtworkStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var session: PaintSession?
    @State private var failed = false

    var body: some View {
        ZStack {
            // A calm, still background: nothing should move behind the picture while painting.
            Theme.background.ignoresSafeArea()
            if let session {
                PaintView(session: session) {
                    session.saveNow()
                    dismiss()
                }
                .transition(.opacity)
            } else if failed {
                VStack(spacing: 20) {
                    Mascot(size: 100)
                    Text("Oh no! This painting got lost.")
                        .font(Theme.font(.title2))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                    Button("Go Home") { dismiss() }
                        .buttonStyle(ChunkyButtonStyle(color: Theme.blue))
                }
                .padding()
            } else {
                LoadingView(message: "Getting your paints ready…")
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard session == nil else { return }
        guard let artwork = store.artwork(artworkID) else {
            failed = true
            return
        }
        do {
            let puzzle = try await store.loadPuzzle(artworkID)
            let detail = await Task.detached(priority: .userInitiated) {
                DetailMap(puzzle: puzzle, scale: DetailMap.recommendedScale(for: puzzle))
            }.value
            withAnimation(.easeOut(duration: 0.25)) {
                session = PaintSession(artwork: artwork, puzzle: puzzle, detail: detail, store: store)
            }
        } catch {
            failed = true
        }
    }
}

struct PaintView: View {
    let session: PaintSession
    let onClose: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SoundPlayer.enabledKey) private var soundEnabled = true
    @AppStorage("startTipsSpoken") private var startTipsSpoken = 0
    @State private var startTipExpired = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                ZStack(alignment: .bottom) {
                    PaintCanvas(session: session)
                        .overlay {
                            // A blue frame shows that one finger moves the picture right now.
                            if session.isMoveMode {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Theme.blue, lineWidth: 5)
                                    .padding(4)
                                    .allowsHitTesting(false)
                            }
                        }
                    bottomRow
                        .frame(height: PaintCanvasView.bottomControlsHeight - 6)
                        .padding(.bottom, 6)
                }
                PaletteBar(session: session)
            }

            if session.showsCelebration {
                CelebrationView(session: session, onHome: onClose)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.65), value: session.cheer)
        .animation(.easeInOut(duration: 0.25), value: showsStartTip)
        .animation(.easeInOut(duration: 0.3), value: session.showsCelebration)
        .task {
            SoundPlayer.shared.prepare()
            try? await Task.sleep(for: .seconds(0.8))
            session.showStartHint()
            // Say the first tip out loud for children who can't read yet (only the first few times).
            if showsStartTip && startTipsSpoken < 3 && SoundPlayer.shared.say(Self.startTip) {
                startTipsSpoken += 1
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                session.nudgeIfIdle()
            }
        }
        .task(id: tipShowing) {
            // The tip gives the controls their place back after a while, painted or not.
            guard tipShowing else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { startTipExpired = true }
        }
        .onChange(of: session.helpNudge) {
            // Still nothing painted after a while: show the tip again.
            if session.progress.filledCount == 0 { startTipExpired = false }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.saveNow() }
        }
        .onDisappear { session.saveNow() }
    }

    private static let startTip = "Tap the striped shapes!"

    private var showsStartTip: Bool {
        session.progress.filledCount == 0 && !session.isComplete && !startTipExpired
    }

    /// Identity for the tip's expiry timer: restarts whenever the tip comes back.
    private var tipShowing: Bool { showsStartTip }

    // MARK: Top bar

    private var topBar: some View {
        let still = reduceMotion
        return HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "house.fill")
            }
            .buttonStyle(RoundIconButtonStyle())
            .accessibilityLabel("Home")

            ProgressPill(fraction: session.progress.fraction)

            if session.isComplete {
                Button {
                    session.celebrateAgain()
                } label: {
                    Image(systemName: "party.popper.fill")
                }
                .buttonStyle(RoundIconButtonStyle(tint: .white, background: Theme.pink))
                .accessibilityLabel("Celebrate and save")
            } else {
                Button {
                    session.findNextShape()
                } label: {
                    Image(systemName: "lightbulb.fill")
                }
                .buttonStyle(RoundIconButtonStyle(tint: .white, background: Theme.orange))
                .keyframeAnimator(initialValue: 1.0, trigger: session.helpNudge) { content, scale in
                    content.scaleEffect(still ? 1 : scale)
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(1.3, duration: 0.18)
                        SpringKeyframe(0.9, duration: 0.15)
                        SpringKeyframe(1.15, duration: 0.15)
                        SpringKeyframe(1.0, duration: 0.2)
                    }
                }
                .accessibilityLabel("Find a shape to paint")
            }
        }
    }

    // MARK: Bottom row: a tip, a cheer, or the picture controls

    @ViewBuilder
    private var bottomRow: some View {
        if let cheer = session.cheer {
            CheerBubble(text: cheer.text)
                .id(cheer.id)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                .allowsHitTesting(false)
        } else if showsStartTip {
            CheerBubble(text: Self.startTip, systemImage: "hand.tap.fill")
                .transition(.opacity)
                .allowsHitTesting(false)
        } else {
            controls
                .transition(.opacity)
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            // Paint or move: both choices visible, the active one filled in.
            HStack(spacing: 2) {
                modeButton(moves: false, systemImage: "paintbrush.pointed.fill", label: "Paint with one finger")
                modeButton(moves: true, systemImage: "hand.raised.fill", label: "Move with one finger")
            }
            .padding(3)
            .background(Capsule().fill(Theme.ink.opacity(0.07)))

            Divider().frame(height: 26).padding(.horizontal, 4)

            Button { control { session.canvas?.zoom(by: 1 / 1.8) } } label: { Image(systemName: "minus") }
                .accessibilityLabel("Zoom out")
            Button { control { session.canvas?.zoomToFit() } } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                .accessibilityLabel("Show whole picture")
            Button { control { session.canvas?.zoom(by: 1.8) } } label: { Image(systemName: "plus") }
                .accessibilityLabel("Zoom in")

            Divider().frame(height: 26).padding(.horizontal, 4)

            Button {
                control {
                    soundEnabled.toggle()
                    if soundEnabled { SoundPlayer.shared.playTick() }
                }
            } label: {
                Image(systemName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .accessibilityLabel(soundEnabled ? "Sound on" : "Sound off")
        }
        .buttonStyle(PillIconButtonStyle())
        .padding(.horizontal, 6)
        .background(
            Capsule()
                .fill(.white.opacity(0.94))
                .shadow(color: Theme.ink.opacity(0.15), radius: 6, y: 3)
        )
        .overlay(Capsule().stroke(Theme.ink.opacity(0.12), lineWidth: 1.5))
    }

    private func modeButton(moves: Bool, systemImage: String, label: String) -> some View {
        let isActive = session.isMoveMode == moves
        return Button {
            control {
                session.isMoveMode = moves
                Haptics.select()
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(isActive ? .white : Theme.ink.opacity(0.6))
                .frame(width: 42, height: 40)
                .background(Capsule().fill(isActive ? (moves ? Theme.blue : Theme.pink) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// Runs a control's action and counts it as the child being busy (not stuck).
    private func control(_ action: () -> Void) {
        session.noteActivity()
        action()
    }
}

/// Icon buttons inside the controls pill.
private struct PillIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .heavy, design: .rounded))
            .foregroundStyle(Theme.ink)
            .frame(width: 46, height: 46)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A chunky rainbow progress bar with a star at the end.
struct ProgressPill: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white)
                Capsule()
                    .fill(LinearGradient(colors: Theme.rainbow, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(28, (geometry.size.width - 10) * fraction))
                    .padding(5)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: fraction)
                HStack {
                    Spacer()
                    Text("\(Int((fraction * 100).rounded(.down)))%")
                        .font(Theme.font(.headline))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.85)))
                    Image(systemName: "star.fill")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(fraction >= 1 ? Theme.yellow : Theme.ink.opacity(0.18))
                        .padding(.trailing, 10)
                }
            }
        }
        .frame(height: 46)
        .background(Capsule().fill(Color.black.opacity(0.1)).offset(y: 4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(fraction * 100)) percent painted")
    }
}

/// "Great job!" speech bubble with Dotty. Sized to fit the controls row under the picture.
struct CheerBubble: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 8) {
            Mascot(size: 40, mood: .cheering)
            Text(text)
                .font(Theme.font(.title3))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let systemImage {
                TappingIcon(systemImage: systemImage)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(Capsule().fill(.white).shadow(color: Theme.ink.opacity(0.2), radius: 10, y: 4))
        .overlay(Capsule().stroke(Theme.yellow, lineWidth: 3))
        .accessibilityElement(children: .combine)
    }
}

/// An icon that keeps "tapping" (a little press-down bounce).
private struct TappingIcon: View {
    let systemImage: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 24, weight: .bold))
            .foregroundStyle(Theme.pink)
            .scaleEffect(pressed ? 0.8 : 1.05)
            .offset(y: pressed ? 4 : -2)
            .onAppear {
                guard !reduceMotion, !LaunchOptions.isUITesting else { return }
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { pressed = true }
            }
            .accessibilityHidden(true)
    }
}

struct LoadingView: View {
    let message: String
    @State private var spinning = false

    var body: some View {
        VStack(spacing: 24) {
            Mascot(size: 110, mood: .cheering)
            HStack(spacing: 10) {
                ForEach(0..<4) { index in
                    Circle()
                        .fill(Theme.rainbow[index])
                        .frame(width: 16, height: 16)
                        .offset(y: spinning ? -10 : 6)
                        .animation(.easeInOut(duration: 0.45).repeatForever().delay(Double(index) * 0.12), value: spinning)
                }
            }
            Text(message)
                .font(Theme.font(.title3))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
        }
        .padding()
        .onAppear { spinning = true }
    }
}
