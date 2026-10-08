// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ColorDrawKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ColorDrawKit", targets: ["ColorDrawKit"]),
    ],
    targets: [
        // The photo → paint-by-number engine. Pure Swift + CoreGraphics so it runs on iOS and macOS.
        // Image processing is ~50× slower unoptimized, so optimize even Debug builds; otherwise
        // making a puzzle in a Debug run of the app takes several seconds.
        .target(name: "ColorDrawKit", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        // Developer tool: renders puzzles to PNG files so the engine can be tuned without a device.
        .executableTarget(name: "puzzle-preview", dependencies: ["ColorDrawKit"]),
        .testTarget(name: "ColorDrawKitTests", dependencies: ["ColorDrawKit"]),
    ]
)
