import ColorDrawKit
import SwiftUI

/// How hard a photo puzzle is: at most how many colors (50 for about five-year-olds, up to 200 for
/// about eight-year-olds) and how many tiles. Photos with fewer distinct colors get fewer.
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

extension Tiling.Shape {
    var title: String {
        switch self {
        case .squares: "Squares"
        case .triangles: "Triangles"
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
    @AppStorage("lastDifficulty") private var difficulty: Difficulty = .easy
    @AppStorage("lastTileShape") private var shape: Tiling.Shape = .squares
    @State private var previews: [Choice: Preview] = [:]
    /// Generation that is running or done, per choice, so switching back and forth never repeats work.
    @State private var generators: [Choice: Task<Preview?, Never>] = [:]
    @State private var isCreating = false
    @State private var showError = false
    @State private var showSaveError = false

    private struct Preview {
        let puzzle: Puzzle
        let image: UIImage
    }

    private struct Choice: Hashable {
        let difficulty: Difficulty
        let shape: Tiling.Shape
    }

    private var choice: Choice { Choice(difficulty: difficulty, shape: shape) }

    var body: some View {
        GeometryReader { proxy in
            content(previewHeight: min(560, max(180, proxy.size.height - 470)))
        }
        .background(Theme.background.ignoresSafeArea())
        .modifier(RoomySheet())
        // Don't let the sheet be swiped away halfway through saving the new painting.
        .interactiveDismissDisabled(isCreating)
        .task(id: choice) { await makePreview(for: choice) }
        .alert("Oops!", isPresented: $showError) {
            Button("OK", role: .cancel) { dismiss() }
        } message: {
            Text("That picture didn't work. Please try another one.")
        }
        .alert("Couldn't save", isPresented: $showSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("There's no room to save a new painting. Is the device full?")
        }
    }

    /// The preview takes whatever height is left, so "Let's Paint!" stays on screen without scrolling.
    private func content(previewHeight: CGFloat) -> some View {
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
                    .disabled(isCreating)
                    .accessibilityLabel("Close")
                }

                previewCard(maxHeight: previewHeight)

                HStack(spacing: 12) {
                    ForEach(Tiling.Shape.allCases, id: \.self) { option in
                        ShapeChoiceButton(shape: option, isSelected: option == shape) {
                            shape = option
                            Haptics.select()
                        }
                    }
                }
                .padding(.top, 8)

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
                .disabled(!canStart || isCreating)
                .opacity(canStart ? 1 : 0.6)
            }
            .padding(22)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    /// A picture with only one color isn't a puzzle.
    private var canStart: Bool {
        (previews[choice]?.puzzle.palette.count ?? 0) > 1
    }

    private func previewCard(maxHeight: CGFloat) -> some View {
        ZStack {
            if let preview = previews[choice] {
                Image(uiImage: preview.image)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .id(choice)
                    .accessibilityLabel("Preview of the coloring page")
                    .accessibilityValue("\(difficulty.title), \(preview.puzzle.palette.count) colors, \(preview.puzzle.regions.count) \(shape.title.lowercased())")
            } else {
                Image(decorative: photo.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .blur(radius: 8)
                    .overlay(LoadingView(message: "Mixing the paints…").scaleEffect(0.7))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(maxHeight: maxHeight)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(.white).shadow(color: Theme.ink.opacity(0.12), radius: 12, y: 6))
        .overlay(alignment: .topLeading) {
            // The original photo, so children see what their picture will become.
            Image(decorative: photo.image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white, lineWidth: 4))
                .shadow(color: Theme.ink.opacity(0.25), radius: 6, y: 3)
                .offset(x: -18, y: -18)
        }
        .overlay(alignment: .bottom) {
            if let preview = previews[choice] {
                Text(preview.puzzle.palette.count > 1
                     ? "\(preview.puzzle.palette.count) colors · \(preview.puzzle.regions.count) \(shape.title.lowercased())"
                     : "Not much to color here. Try another picture!")
                    .font(Theme.font(.headline))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.white))
                    .offset(y: 14)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: previews[choice] == nil)
    }

    private func makePreview(for choice: Choice) async {
        guard previews[choice] == nil else { return }
        let generator = generators[choice] ?? {
            let image = photo.image
            let settings = choice.difficulty.settings.with(shape: choice.shape)
            let task = Task.detached(priority: .userInitiated) { () -> Preview? in
                guard let puzzle = try? PuzzleGenerator.generate(from: image, settings: settings),
                      let snapshot = PuzzleSnapshot.thumbnail(of: puzzle, painted: true, width: 900) else { return nil }
                return Preview(puzzle: puzzle, image: UIImage(cgImage: snapshot))
            }
            generators[choice] = task
            return task
        }()
        let result = await generator.value
        if let result {
            withAnimation { previews[choice] = result }
        } else if choice == self.choice {
            showError = true
        }
    }

    private func create() {
        guard let preview = previews[choice], !isCreating else { return }
        isCreating = true
        let puzzle = preview.puzzle
        Task {
            let thumbnail = await Task.detached(priority: .userInitiated) {
                let isLarge = puzzle.palette.count > PaintSession.smallPaletteLimit
                return PuzzleSnapshot.thumbnail(of: puzzle, painted: false, ghost: isLarge, outlineOpacity: isLarge ? 0.35 : 1, width: 360)
                    .map(UIImage.init(cgImage:))
            }.value
            let title = "Photo, " + Date().formatted(.dateTime.month(.abbreviated).day())
            do {
                let artwork = try await store.create(puzzle: puzzle, title: title, level: difficulty.rawValue, sampleID: nil, thumbnail: thumbnail)
                onCreated(artwork.id)
            } catch {
                // Keep the sheet (and the child's photo) so they can try again. The sheet shows
                // its own message, so the home screen doesn't need to repeat it.
                store.clearError()
                isCreating = false
                showSaveError = true
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
                Text("up to \(difficulty.settings.colorCount) colors")
                    .font(Theme.font(.caption, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .opacity(0.9)
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
        .accessibilityLabel("\(difficulty.title), up to \(difficulty.settings.colorCount) colors")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "Squares" or "Triangles", with a tiny rainbow mosaic of that shape.
private struct ShapeChoiceButton: View {
    let shape: Tiling.Shape
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MosaicIcon(shape: shape)
                    .frame(width: 40, height: 28)
                Text(shape.title)
                    .font(Theme.font(.headline))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isSelected ? .white : Theme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(isSelected ? AnyShapeStyle(Theme.orange.gradient) : AnyShapeStyle(Color.white)))
            .background(Capsule().fill(isSelected ? Theme.orange.darker() : Color.black.opacity(0.08)).offset(y: 4))
            .scaleEffect(isSelected ? 1.04 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(shape.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Two rows of little tiles in rainbow colors, outlined in white so they read on any background.
private struct MosaicIcon: View {
    let shape: Tiling.Shape

    var body: some View {
        Canvas { context, size in
            let colors = Theme.rainbow
            switch shape {
            case .squares:
                let side = min(size.width / 3, size.height / 2)
                for row in 0..<2 {
                    for column in 0..<3 {
                        let rect = CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side)
                        let path = Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 2)
                        context.fill(path, with: .color(colors[(row * 3 + column) % colors.count]))
                    }
                }
            case .triangles:
                let height = size.height / 2
                let half = height / 3.squareRoot()
                for row in 0..<2 {
                    for column in 0..<4 {
                        let center = CGFloat(column) * half + half
                        let top = CGFloat(row) * height
                        let up = (row + column).isMultiple(of: 2)
                        var path = Path()
                        path.move(to: CGPoint(x: center, y: up ? top : top + height))
                        path.addLine(to: CGPoint(x: center + half, y: up ? top + height : top))
                        path.addLine(to: CGPoint(x: center - half, y: up ? top + height : top))
                        path.closeSubpath()
                        context.fill(path, with: .color(colors[(row * 4 + column + 1) % colors.count]))
                        context.stroke(path, with: .color(.white), lineWidth: 1)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// On iPad, a page-sized sheet leaves room for a big preview.
private struct RoomySheet: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.presentationSizing(.page)
        } else {
            content
        }
    }
}
