// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Visor",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // Real-time note sharing ("beam → live sync"). Firebase is the transport
        // (Firestore for the change log + anonymous Auth for identity); Automerge
        // is the CRDT that merges concurrent edits without a server-side merge.
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "11.0.0"),
        .package(url: "https://github.com/automerge/automerge-swift", from: "0.5.2"),
    ],
    targets: [
        .executableTarget(
            name: "Visor",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseDatabase", package: "firebase-ios-sdk"),
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
