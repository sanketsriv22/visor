// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Visor",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // Block-level Markdown for replies: headings, lists, tables, fences.
        // Supports macOS 12+, so the macOS 13 floor stays where it is.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "Visor",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
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
