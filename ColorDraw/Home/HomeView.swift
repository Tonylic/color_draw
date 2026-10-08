import AVFoundation
import ColorDrawKit
import PhotosUI
import SwiftUI

/// The first screen: take or pick a photo, continue a painting, or start a built-in picture.
struct HomeView: View {
    @Environment(ArtworkStore.self) private var store
    @Environment(SampleCatalog.self) private var samples
    @AppStorage(SoundPlayer.enabledKey) private var soundEnabled = true

    @State private var photoItem: PhotosPickerItem?
    @State private var pickedPhoto: PickedPhoto?
    @State private var showCamera = false
    @State private var cameraPhoto: UIImage?
    @State private var showNoCamera = false
    @State private var showCameraPermissionHelp = false
    @State private var showPhotoError = false
    @State private var isLoadingPhoto = false
    @State private var openArtwork: ArtworkLink?
    @State private var artworkToOpenNext: UUID?
    @State private var artworkToDelete: ArtworkMetadata?
    @State private var preparingSample: SamplePicture?

    private struct ArtworkLink: Identifiable {
        let id: UUID
    }

    var body: some View {
        ZStack {
            BubbleBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    photoButtons
                    if !store.artworks.isEmpty {
                        myPaintings
                    }
                    pictures
                    Label("Your pictures stay on this device.", systemImage: "lock.fill")
                        .font(Theme.font(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.softInk)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 12)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)

            if isLoadingPhoto {
                Color.white.opacity(0.7).ignoresSafeArea()
                LoadingView(message: "Opening your picture…")
            }
        }
        .fullScreenCover(item: $openArtwork) { link in
            PaintScreen(artworkID: link.id)
        }
        .sheet(item: $pickedPhoto, onDismiss: openPendingArtwork) { photo in
            CreatePuzzleView(photo: photo) { id in
                artworkToOpenNext = id
                pickedPhoto = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: useCameraPhoto) {
            CameraPicker { cameraPhoto = $0 }
                .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            loadPhoto(item)
        }
        .alert("No camera here", isPresented: $showNoCamera) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device can't take pictures. Try Photos instead!")
        }
        .alert("Ask a grown-up", isPresented: $showCameraPermissionHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            // No button that leaves the app: grown-ups can go to Settings themselves.
            Text("Color Draw needs permission to use the camera. A grown-up can turn it on in Settings › Color Draw › Camera.")
        }
        .alert("Oops!", isPresented: Binding(get: { store.storageError != nil }, set: { if !$0 { store.clearError() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your paintings couldn't be saved. Is the device full?")
        }
        .alert("Oops!", isPresented: $showPhotoError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("That picture couldn't be opened. Please pick another one.")
        }
        .confirmationDialog(
            "Throw away this painting?",
            isPresented: Binding(get: { artworkToDelete != nil }, set: { if !$0 { artworkToDelete = nil } }),
            titleVisibility: .visible,
            presenting: artworkToDelete
        ) { artwork in
            Button("Delete Painting", role: .destructive) {
                withAnimation { store.delete(artwork.id) }
            }
            Button("Keep It", role: .cancel) {}
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Mascot(size: 84)
            VStack(alignment: .leading, spacing: 2) {
                RainbowTitle(text: "Color Draw")
                Text("Turn any picture into a coloring page!")
                    .font(Theme.font(.subheadline, weight: .bold))
                    .foregroundStyle(Theme.softInk)
            }
            Spacer(minLength: 0)
            Button {
                soundEnabled.toggle()
                if soundEnabled { SoundPlayer.shared.playTick() }
            } label: {
                Image(systemName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
            }
            .buttonStyle(RoundIconButtonStyle(size: 46, tint: soundEnabled ? Theme.ink : Theme.softInk))
            .accessibilityLabel(soundEnabled ? "Sound on" : "Sound off")
        }
        .padding(.top, 8)
    }

    private var photoButtons: some View {
        HStack(spacing: 14) {
            Button {
                openCamera()
            } label: {
                BigButtonLabel(title: "Camera", systemImage: "camera.fill")
            }
            .buttonStyle(ChunkyButtonStyle(color: Theme.pink, cornerRadius: 30))

            PhotosPicker(selection: $photoItem, matching: .images, photoLibrary: .shared()) {
                BigButtonLabel(title: "Photos", systemImage: "photo.fill.on.rectangle.fill")
            }
            .buttonStyle(ChunkyButtonStyle(color: Theme.blue, cornerRadius: 30))
        }
    }

    private var myPaintings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "My Paintings", systemImage: "paintpalette.fill", color: Theme.orange)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(store.artworks) { artwork in
                        Button {
                            openArtwork = ArtworkLink(id: artwork.id)
                        } label: {
                            ArtworkCard(artwork: artwork, thumbnail: store.thumbnails[artwork.id])
                        }
                        .buttonStyle(CardButtonStyle())
                        .contextMenu {
                            Button(role: .destructive) {
                                artworkToDelete = artwork
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, -4)
        }
    }

    private var pictures: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Pictures to Paint", systemImage: "sparkles", color: Theme.purple)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)], spacing: 16) {
                ForEach(SamplePicture.allCases) { sample in
                    Button {
                        start(sample)
                    } label: {
                        SampleCard(
                            title: sample.title,
                            image: samples.previews[sample],
                            isPreparing: preparingSample == sample,
                            isFinished: store.artworks.contains { $0.sampleID == sample.rawValue && $0.isComplete }
                        )
                    }
                    .buttonStyle(CardButtonStyle())
                    .disabled(preparingSample != nil)
                }
            }
        }
        .padding(.bottom, 20)
    }

    // MARK: Actions

    private func openCamera() {
        guard CameraPicker.isAvailable else {
            showNoCamera = true
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showCamera = true
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) {
                    showCamera = true
                } else {
                    showCameraPermissionHelp = true
                }
            }
        default:
            showCameraPermissionHelp = true
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        artworkToOpenNext = nil
        isLoadingPhoto = true
        Task {
            defer {
                isLoadingPhoto = false
                photoItem = nil
            }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = await Task.detached(operation: { ImageLoader.image(from: data) }).value else {
                showPhotoError = true
                return
            }
            pickedPhoto = PickedPhoto(image: image)
        }
    }

    private func useCameraPhoto() {
        guard let photo = cameraPhoto else { return }
        cameraPhoto = nil
        artworkToOpenNext = nil
        isLoadingPhoto = true
        Task {
            defer { isLoadingPhoto = false }
            if let image = await ImageLoader.image(from: photo) {
                pickedPhoto = PickedPhoto(image: image)
            } else {
                showPhotoError = true
            }
        }
    }

    private func openPendingArtwork() {
        guard let id = artworkToOpenNext else { return }
        artworkToOpenNext = nil
        openArtwork = ArtworkLink(id: id)
    }

    private func start(_ sample: SamplePicture) {
        if let unfinished = store.unfinishedArtwork(forSample: sample) {
            openArtwork = ArtworkLink(id: unfinished.id)
            return
        }
        preparingSample = sample
        Task {
            defer { preparingSample = nil }
            let (puzzle, thumbnail) = await Task.detached(priority: .userInitiated) { () -> (Puzzle, UIImage?) in
                let puzzle = sample.makePuzzle()
                return (puzzle, PuzzleSnapshot.thumbnail(of: puzzle, painted: false, width: 360).map(UIImage.init(cgImage:)))
            }.value
            // A failure shows up through `store.storageError`.
            if let artwork = try? await store.create(puzzle: puzzle, title: sample.title, level: nil, sampleID: sample.rawValue, thumbnail: thumbnail) {
                openArtwork = ArtworkLink(id: artwork.id)
            }
        }
    }
}

// MARK: - Pieces

private struct BigButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .bold))
            Text(title)
                .font(Theme.font(.title2, weight: .black))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

private struct SectionTitle: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
        }
        .font(Theme.font(.title2, weight: .black))
        .foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .rotationEffect(.degrees(configuration.isPressed ? -1.5 : 0))
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

private struct ArtworkCard: View {
    let artwork: ArtworkMetadata
    let thumbnail: UIImage?

    private var percent: Int {
        artwork.regionCount == 0 ? 0 : artwork.filledRegions.count * 100 / artwork.regionCount
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(10)
                }
            }
            .frame(width: 150, height: 150)
            .overlay(alignment: .topTrailing) { badge.offset(x: 8, y: -8) }
            .shadow(color: Theme.ink.opacity(0.14), radius: 8, y: 5)
            Text(artwork.title)
                .font(Theme.font(.subheadline))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(artwork.title)
        .accessibilityValue(artwork.isComplete ? "Finished" : "\(percent) percent painted")
        .accessibilityHint("Opens the painting")
    }

    @ViewBuilder
    private var badge: some View {
        if artwork.isComplete {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 36))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.yellow)
                .shadow(color: Theme.orange.opacity(0.5), radius: 0, y: 2)
        } else {
            ZStack {
                Circle().fill(.white)
                Circle().stroke(Theme.ink.opacity(0.1), lineWidth: 5).padding(4)
                Circle()
                    .trim(from: 0, to: artwork.fraction)
                    .stroke(Theme.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(4)
                Text("\(percent)")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.ink)
            }
            .frame(width: 40, height: 40)
            .shadow(color: Theme.ink.opacity(0.15), radius: 3, y: 2)
        }
    }
}

private struct SampleCard: View {
    let title: String
    let image: UIImage?
    let isPreparing: Bool
    /// Already painted once: shows a check next to the "paint me" brush.
    let isFinished: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Rectangle().fill(Theme.paper)
                    ProgressView()
                }
                if isPreparing {
                    Color.white.opacity(0.6)
                    ProgressView().controlSize(.large)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.white))
            .overlay(alignment: .topTrailing) {
                // "Paint me!" badge, so these don't look like finished paintings.
                HStack(spacing: -6) {
                    if isFinished {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .black))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Theme.green))
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                    }
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.pink))
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                }
                .offset(x: 8, y: -8)
            }
            .shadow(color: Theme.ink.opacity(0.14), radius: 8, y: 5)
            Text(title)
                .font(Theme.font(.headline))
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isFinished ? "Painted before" : "")
        .accessibilityHint("Starts painting this picture")
    }
}
