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

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                ZStack(alignment: .bottom) {
                    PaintCanvas(session: session)
                    zoomButtons
                        .padding(.bottom, 8)
                }
                PaletteBar(session: session)
            }

            if let cheer = session.cheer {
                CheerBubble(text: cheer.text)
                    .id(cheer.id)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 130)
                    .allowsHitTesting(false)
            }

            if session.showsCelebration {
                CelebrationView(session: session, onHome: onClose)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.65), value: session.cheer)
        .animation(.easeInOut(duration: 0.3), value: session.showsCelebration)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.saveNow() }
        }
        .onDisappear { session.saveNow() }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "house.fill")
            }
            .buttonStyle(RoundIconButtonStyle())
            .accessibilityLabel("Home")

            ProgressPill(fraction: session.progress.fraction)

            Button {
                session.findNextShape()
            } label: {
                Image(systemName: "lightbulb.fill")
            }
            .buttonStyle(RoundIconButtonStyle(tint: .white, background: Theme.orange))
            .accessibilityLabel("Find a shape to paint")
            .disabled(session.isComplete)
            .opacity(session.isComplete ? 0.4 : 1)
        }
    }

    private var zoomButtons: some View {
        HStack(spacing: 16) {
            Button { session.canvas?.zoom(by: 1 / 1.8) } label: { Image(systemName: "minus") }
                .accessibilityLabel("Zoom out")
            Button { session.canvas?.zoomToFit() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                .accessibilityLabel("Show whole picture")
            Button { session.canvas?.zoom(by: 1.8) } label: { Image(systemName: "plus") }
                .accessibilityLabel("Zoom in")
        }
        .buttonStyle(RoundIconButtonStyle(size: 46))
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
                    .frame(width: max(28, geometry.size.width * fraction))
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

/// "Great job!" speech bubble with Dotty.
struct CheerBubble: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Mascot(size: 54, mood: .cheering)
            Text(text)
                .font(Theme.font(.title))
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Capsule().fill(.white).shadow(color: Theme.ink.opacity(0.2), radius: 14, y: 6))
        .overlay(Capsule().stroke(Theme.yellow, lineWidth: 4))
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
