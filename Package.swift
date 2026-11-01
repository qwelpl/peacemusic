// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PeaceMusic",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "PeaceMusic",
            path: "Sources/PeaceMusic",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
