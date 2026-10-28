// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FCDock",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "FCDock", path: "Sources/FCDock")
    ],
    swiftLanguageVersions: [.v5]
)
