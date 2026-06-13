// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Visor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Visor",
            path: "Sources/Visor"
        )
    ]
)
