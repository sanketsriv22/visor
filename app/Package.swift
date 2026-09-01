// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Visor",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // Real-time note sharing ("beam → live sync"). The transport is the
        // Realtime Database's HTTP API, spoken directly over URLSession — the
        // SDK was 25 MB for a key-value store and a change stream that the
        // service exposes as server-sent events. Automerge stays: it is the
        // merge itself, running locally on every keystroke, and there is no
        // API call that can do that for you.
        .package(url: "https://github.com/automerge/automerge-swift", from: "0.5.2"),
    ],
    targets: [
        .executableTarget(
            name: "Visor",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Automerge", package: "automerge-swift"),
            ],
            path: "Sources/Visor",
            // Menu-bar icon PNGs live here as build inputs for make-app.sh, which
            // copies them into the .app's Contents/Resources. They're not SPM
            // resources, so exclude them to keep the build quiet.
            exclude: ["Resources"]
        ),
        // Covers the pure layers — storage, memory, the voice log, prompt
        // shaping. The UI isn't testable without a display, and that's exactly
        // why everything that *can* live outside a view does.
        .testTarget(
            name: "VisorTests",
            dependencies: ["Visor"],
            path: "Tests/VisorTests"
        ),
    ]
)
