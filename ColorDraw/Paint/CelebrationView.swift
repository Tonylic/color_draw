import SwiftUI

/// Shown when the whole picture is painted: confetti, Dotty cheering and the finished painting.
struct CelebrationView: View {
    let session: PaintSession
    let onHome: () -> Void

    @State private var finished: UIImage?
    @State private var appeared = false
    @State private var saveState: SaveState = .idle
    @State private var showPermissionHelp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum SaveState {
        case idle, saving, saved, failed
    }

    var body: some View {
        ZStack {
            Theme.ink.opacity(0.45).ignoresSafeArea()
            ConfettiView()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            GeometryReader { geometry in
                ScrollView {
                    card
                        .frame(maxWidth: 440)
                        .padding(24)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
            .scaleEffect(appeared ? 1 : 0.6)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            finished = session.snapshot(width: 1600)
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.65)) { appeared = true }
        }
        .alert("Ask a grown-up", isPresented: $showPermissionHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            // No button that leaves the app: grown-ups can go to Settings themselves.
            Text("To save paintings, Color Draw needs permission to add to Photos. A grown-up can turn it on in Settings › Color Draw › Photos.")
        }
    }

    private var card: some View {
        VStack(spacing: 18) {
            Mascot(size: 96, mood: .cheering)
                .offset(y: 26)
                .zIndex(1)
            VStack(spacing: 14) {
                Text("You did it!")
                    .font(Theme.font(.largeTitle, weight: .black))
                    .foregroundStyle(Theme.pink)
                    .padding(.top, 18)
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in
                        Image(systemName: "star.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(Theme.yellow)
                            .shadow(color: Theme.orange.opacity(0.6), radius: 0, y: 3)
                            .scaleEffect(appeared || reduceMotion ? 1 : 0.1)
                            .rotationEffect(.degrees(appeared || reduceMotion ? 0 : -90))
                            .animation(.spring(response: 0.5, dampingFraction: 0.5).delay(0.3 + Double(index) * 0.18), value: appeared)
                    }
                }
                if let finished {
                    Image(uiImage: finished)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.ink.opacity(0.1), lineWidth: 2))
                        .frame(maxHeight: 260)
                        .accessibilityLabel("Your finished painting")
                }
                VStack(spacing: 12) {
                    Button(action: onHome) {
                        Label("More Pictures", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChunkyButtonStyle(color: Theme.orange))
                    .accessibilityIdentifier("celebrationHome")

                    HStack(spacing: 12) {
                        Button {
                            session.dismissCelebration()
                        } label: {
                            Label("Look", systemImage: "eye.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ChunkyButtonStyle(color: Theme.purple, cornerRadius: 22, depth: 4))
                        Button {
                            save()
                        } label: {
                            Label(saveTitle, systemImage: saveState == .saved ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ChunkyButtonStyle(color: saveState == .saved ? Theme.green : Theme.blue, cornerRadius: 22, depth: 4))
                        .disabled(saveState == .saving || saveState == .saved || finished == nil)
                        .accessibilityLabel(saveState == .saved ? "Saved to Photos" : "Save to Photos")
                    }
                    .font(Theme.font(.headline))
                }
                .padding(.top, 4)
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Theme.paper)
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
            )
        }
    }

    private var saveTitle: String {
        switch saveState {
        case .idle: "Save"
        case .saving: "Saving…"
        case .saved: "Saved!"
        case .failed: "Try Again"
        }
    }

    private func save() {
        guard let finished else { return }
        saveState = .saving
        Task {
            switch await PhotoSaver.save(finished) {
            case .saved:
                saveState = .saved
                Haptics.success()
            case .notAllowed:
                saveState = .idle
                showPermissionHelp = true
            case .failed:
                saveState = .failed
            }
        }
    }
}

/// Falling, fluttering paper confetti.
struct ConfettiView: View {
    private struct Piece {
        let x: Double
        let delay: Double
        let speed: Double
        let sway: Double
        let size: CGSize
        let color: Color
        let spin: Double
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var isDone = false
    // In @State so the pieces don't jump around whenever the parent view updates.
    @State private var pieces: [Piece] = (0..<90).map { _ in
        Piece(
            x: .random(in: 0...1),
            delay: .random(in: 0...1.6),
            speed: .random(in: 0.18...0.32),
            sway: .random(in: 10...40),
            size: CGSize(width: .random(in: 8...14), height: .random(in: 12...20)),
            color: Theme.rainbow.randomElement()!,
            spin: .random(in: 2...6)
        )
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || isDone)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                for piece in pieces {
                    let t = elapsed - piece.delay
                    guard t > 0 else { continue }
                    let y = -30 + t * piece.speed * size.height
                    guard y < size.height + 30 else { continue }
                    let x = piece.x * size.width + sin(t * 2 + piece.x * 10) * piece.sway
                    var copy = context
                    copy.translateBy(x: x, y: y)
                    copy.rotate(by: .radians(t * piece.spin))
                    // Squash horizontally to look like paper turning over.
                    copy.scaleBy(x: cos(t * piece.spin * 1.3), y: 1)
                    let rect = CGRect(origin: CGPoint(x: -piece.size.width / 2, y: -piece.size.height / 2), size: piece.size)
                    copy.fill(RoundedRectangle(cornerRadius: 2).path(in: rect), with: .color(piece.color))
                }
            }
        }
        .task {
            // Slowest piece: last to start, falling the whole height at the lowest speed.
            try? await Task.sleep(for: .seconds(1.6 + 1.2 / 0.18))
            isDone = true
        }
        .accessibilityHidden(true)
    }
}
