# Color Draw 🎨

A color-by-number iPhone and iPad game for kids. Snap a photo or pick one from your library,
and Color Draw turns it into a numbered coloring page. Each number is a paint color, and
little fingers tap or drag over the shapes to fill them in.

## What kids can do

- **Use any picture**: take a photo with the camera, pick one from Photos, or start with one of
  six built-in drawings (kitty, rainbow, fish, house, flower, rocket).
- **Choose how tricky**: 🐣 *Easy* (up to 6 colors, big shapes), 🐰 *Medium* (up to 10) or
  🦁 *Tricky* (up to 14 colors, more detail), with a live preview of the finished picture.
- **Paint by number**: pick a paint pot from the palette. Every shape that takes that color is
  striped in a light tint of it, so kids can see where to paint. Tap a shape, or drag a finger
  across many shapes at once. Only the right color sticks, so a picture can't be spoiled. A wrong
  tap wiggles the paint pot that's needed, and tapping the same shape again hands that pot over.
- **Zoom so numbers are clear**: pinch with two fingers or use the **+ / − / fit** buttons.
  Numbers are drawn as vector text, so they stay sharp at every zoom level. Tiny numbers
  appear as you zoom in. Kids who can't manage two-finger panning can switch the 🖌 button to
  ✋, so one finger moves the picture.
- **Get help**: a spoken tip and a pulsing shape show how to start. The 💡 button jumps to the
  next shape of the chosen color and makes it pulse. After a quiet spell it wiggles by itself,
  and if a child stays stuck it finds a shape for them.
- **Celebrate**: every paint stroke plays a xylophone note and makes sparkles. Finishing a color
  earns a cheer from Dotty the paint drop and moves on to the next color by itself. Finishing the
  picture brings confetti, three stars and a **Save to Photos** button.
- **Come back later**: paintings save automatically and show up under *My Paintings* with
  their progress. The ⭐ button on a finished painting brings back its celebration and
  **Save to Photos** button. Grown-ups can delete a painting by long-pressing it.

Everything happens on the device. There's no network access, no accounts, no ads and no in-app
purchases.

## How a photo becomes a puzzle

The engine lives in [`Packages/ColorDrawKit`](Packages/ColorDrawKit) and is plain Swift and Core
Graphics, so it is unit-tested on the Mac.

1. **Shrink** the photo to a small working size (120 to 240 pixels on the long side, depending on
   difficulty). Fewer pixels means simpler shapes.
2. **Smooth** it with an edge-preserving bilateral filter in CIE L\*a\*b\* space, which flattens
   texture and noise but keeps outlines.
3. **Pick the palette** with k-means++ in Lab space, merge colors a child couldn't tell apart,
   then give the palette a gentle "storybook" boost (brighter and more colorful).
   Flat-color artwork, like the built-in drawings, keeps its exact colors.
4. **Clean up** with a majority filter, then find connected regions and fold every region that
   is too small or too thin to paint into its best neighbor.
5. **Place the numbers** at the deepest point of each region, found with an exact Euclidean
   distance transform. The number's size comes from the largest circle that fits there.
6. **Smooth the outlines** by scaling the region map up about 10×. Each high-res pixel votes with
   Gaussian weights, which turns pixel staircases into soft, cartoon-like curves. Painting, hit
   testing and outlines all use this map, so what kids see is exactly what responds to their
   finger.
7. **Order the palette like a rainbow**, so the numbers run red, orange, yellow, green, blue,
   purple, then grays.

## Project layout

```
ColorDraw.xcodeproj           Xcode project (iOS 17+, Swift 6)
ColorDraw/
  App/                        App entry point
  Home/                       Home screen: photo buttons, my paintings, built-in pictures
  Create/                     Difficulty picker with live preview, camera picker
  Paint/                      Painting screen
    PaintSession.swift          Game state: selection, painting rules, cheers, saving
    PaintCanvasView.swift       UIKit zoomable canvas, gestures, sparkles
    NumbersLayer.swift          CATiledLayer that draws crisp numbers at any zoom
    PaletteBar.swift            The paint pots
    CelebrationView.swift       Confetti and "You did it!"
  Services/                   Saving, synthesized sounds, haptics, photo loading
  Theme/                      Colors, candy buttons, Dotty the mascot, bubble background
  Resources/                  Asset catalog (app icon)
ColorDrawUITests/             End-to-end UI tests that play the game
Packages/ColorDrawKit/        The engine (Swift package)
  Sources/ColorDrawKit/         Generator, regions, rendering, progress rules, storage
  Sources/puzzle-preview/       Mac tool that renders puzzles to PNG for tuning
  Tests/ColorDrawKitTests/      Unit tests
scripts/make-app-icon.swift   Draws the app icon
```

## Build and run

Requires Xcode 16 or newer. The project uses folder-synchronized groups.

1. Open `ColorDraw.xcodeproj`.
2. Pick the **ColorDraw** scheme and an iPhone or iPad simulator, then press **Run**.
3. To run on a real device, choose your team under *Signing & Capabilities* and change the
   bundle identifier (`com.example.ColorDraw`) to one of your own.

The simulator has no camera, so use **Photos** there; the simulator ships with sample photos.

## Tests

Engine unit tests (fast, run on the Mac):

```bash
cd Packages/ColorDrawKit && swift test
```

Everything, including UI tests that paint a whole picture, from the repository root:

```bash
xcodebuild test -project ColorDraw.xcodeproj -scheme ColorDraw -destination 'platform=iOS Simulator,name=iPhone 17'
```

Set `TEST_RUNNER_SCREENSHOT_DIR=/some/folder` to also save a screenshot of each UI test step.

## Tuning the engine

`puzzle-preview` renders puzzles to PNG files: blank with numbers, partly painted, finished,
and a side-by-side sheet comparing all three difficulties.

```bash
cd Packages/ColorDrawKit
swift run -c release puzzle-preview /tmp/previews               # built-in pictures
swift run -c release puzzle-preview /tmp/previews ~/Pictures/*.jpg
```

Difficulty presets live in `PuzzleSettings` (`PuzzleGenerator.swift`).

## App icon

```bash
swift scripts/make-app-icon.swift ColorDraw/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```
