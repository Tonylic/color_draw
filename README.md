# Color Draw 🎨

A color-by-number iPhone and iPad game for kids. Take a photo or pick one from your library, and
Color Draw turns it into a numbered mosaic of crisp little squares or triangles to paint with a
tap or a swipe.

<p>
  <img src="docs/screenshots/home.png" width="180" alt="Home screen">
  <img src="docs/screenshots/create.png" width="180" alt="Choosing shape and difficulty">
  <img src="docs/screenshots/mosaic.png" width="180" alt="A photo mosaic after a few swipes">
  <img src="docs/screenshots/celebration.png" width="180" alt="Finished!">
</p>

- **Any picture**: camera, photo library, or six built-in drawings.
- **Three levels**: Easy, Medium and Tricky, with up to 50, 100 or 200 colors (made for about 5- to 8-year-olds).
- **Swipe to paint**: only the right color sticks, so a picture can't be spoiled.
- **Zoom** with pinch or buttons; numbers stay sharp at every size.
- **Kid-friendly help**: striped hints, a light-bulb finder, spoken tips, cheers and confetti.
- **Private**: everything stays on the device. No network, accounts, ads or purchases.

## Build and run

Requires Xcode 16 or newer and iOS 17 or newer. Open `ColorDraw.xcodeproj`, pick the
**ColorDraw** scheme and a simulator, and press **Run**. For a real device, set your team and
the `BUNDLE_ID_PREFIX` build setting.

## Tests

```bash
cd Packages/ColorDrawKit && swift test
```

```bash
xcodebuild test -project ColorDraw.xcodeproj -scheme ColorDraw -destination 'platform=iOS Simulator,name=iPhone 17'
```

The first runs the engine's unit tests; the second runs everything, including UI tests.

## Learn more

See the [guide](docs/GUIDE.md) for how photos become puzzles, the project layout, device
builds, and the engine tuning tool.
