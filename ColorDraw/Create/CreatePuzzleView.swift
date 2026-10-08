import ColorDrawKit
import SwiftUI

/// How hard a photo puzzle is: how many colors and how much detail.
enum Difficulty: String, CaseIterable, Identifiable {
    case easy, medium, hard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .easy: "Easy"
        case .medium: "Medium"
        case .hard: "Tricky"
        }
    }

    var animal: String {
        switch self {
        case .easy: "🐣"
        case .medium: "🐰"
        case .hard: "🦁"
        }
    }

    var color: Color {
        switch self {
        case .easy: Theme.green
        case .medium: Theme.blue
        case .hard: Theme.purple
        }
    }

    var settings: PuzzleSettings {
        switch self {
        case .easy: .easy
        case .medium: .medium
        case .hard: .hard
        }
    }
}

/// A photo the child picked, already upright and shrunk.
struct PickedPhoto: Identifiable {
    let id = UUID()
    let image: CGImage
}

/// Lets the child pick how tricky the coloring page should be, with a live preview.
struct CreatePuzzleView: View {
    let photo: PickedPhoto
    let onCreated: (UUID) -> Void

    @Environment(ArtworkStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var difficulty: Difficulty = .easy
    @State private var previews: [Difficulty: Preview] = [:]
    @State private var isCreating = false
    @State private var showError = false

    private struct Preview {
        let puzzle: Puzzle
        let image: UIImage
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    HStack {
                        Text("How tricky?")
                            .font(Theme.font(.largeTitle, weight: .black))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(RoundIconButtonStyle(size: 46))
                        .accessibilityLabel("Close")
                    }

                    previewCard

                    HStack(spacing: 12) {
                        ForEach(Difficulty.allCases) { level in
                            DifficultyCard(difficulty: level, isSelected: level == difficulty) {
                                difficulty = level
                                Haptics.select()
                            }
                        }
                    }

                    Button {
                        create()
                    } label: {
                        HStack {
                            if isCreating { ProgressView().tint(.white) }
                            Text("Let's Paint!")
                            Image(systemName: "paintbrush.pointed.fill")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChunkyButtonStyle(color: Theme.pink))
                    .disabled(previews[difficulty] == nil || isCreating)
                    .opacity(previews[difficulty] == nil ? 0.6 : 1)
                }
                .padding(22)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: difficulty) { await makePreview(for: difficulty) }
        .alert("Oops!", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That picture didn't work. Please try another one.")
        }
    }

    private var previewCard: some View {
        ZStack {
            if let preview = previews[difficulty] {
                Image(uiImage: preview.image)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .id(difficulty)
                    .accessibilityLabel("Preview of the coloring page")
            } else {
                Image(decorative: photo.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .blur(radius: 8)
                    .overlay(LoadingView(message: "Mixing the paints…").scaleEffect(0.7))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(maxHeight: 340)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(.white).shadow(color: Theme.ink.opacity(0.12), radius: 12, y: 6))
        .overlay(alignment: .bottom) {
            if let preview = previews[difficulty] {
                Text("\(preview.puzzle.palette.count) colors · \(preview.puzzle.regions.count) shapes")
                    .font(Theme.font(.headline))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white))
                    .offset(y: 14)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: previews[difficulty] == nil)
    }

    private func makePreview(for level: Difficulty) async {
        guard previews[level] == nil else { return }
        let image = photo.image
        let settings = level.settings
        let result = await Task.detached(priority: .userInitiated) { () -> Preview? in
            guard let puzzle = try? PuzzleGenerator.generate(from: image, settings: settings) else { return nil }
            let detail = DetailMap(puzzle: puzzle, scale: DetailMap.recommendedScale(for: puzzle, targetLongSide: 900))
            guard let snapshot = PuzzleSnapshot.render(
                puzzle: puzzle,
                detail: detail,
                appearance: { .painted(puzzle.palette[puzzle.regions[$0].colorIndex]) },
                outputWidth: 900
            ) else { return nil }
            return Preview(puzzle: puzzle, image: UIImage(cgImage: snapshot))
        }.value
        guard !Task.isCancelled || previews[level] == nil else { return }
        if let result {
            withAnimation { previews[level] = result }
        } else {
            showError = true
        }
    }

    private func create() {
        guard let preview = previews[difficulty], !isCreating else { return }
        isCreating = true
        let puzzle = preview.puzzle
        Task {
            let thumbnail = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let detail = DetailMap(puzzle: puzzle, scale: DetailMap.recommendedScale(for: puzzle, targetLongSide: 720))
                return PuzzleSnapshot.render(puzzle: puzzle, detail: detail, appearance: { _ in .blank }, outputWidth: 360).map(UIImage.init(cgImage:))
            }.value
            do {
                let artwork = try await store.create(puzzle: puzzle, title: "My Photo", level: difficulty.rawValue, sampleID: nil, thumbnail: thumbnail)
                onCreated(artwork.id)
            } catch {
                isCreating = false
                showError = true
            }
        }
    }
}

private struct DifficultyCard: View {
    let difficulty: Difficulty
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(difficulty.animal)
                    .font(.system(size: 40))
                Text(difficulty.title)
                    .font(Theme.font(.headline))
                Text("\(difficulty.settings.colorCount) colors")
                    .font(Theme.font(.caption, weight: .bold))
                    .opacity(0.8)
            }
            .foregroundStyle(isSelected ? .white : Theme.ink)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(difficulty.color.gradient) : AnyShapeStyle(Color.white))
            )
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(isSelected ? difficulty.color.darker() : Color.black.opacity(0.08))
                    .offset(y: 5)
            )
            .scaleEffect(isSelected ? 1.05 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(difficulty.title), \(difficulty.settings.colorCount) colors")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
