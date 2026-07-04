// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Sweep",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Sweep", path: "Sources/Sweep")
    ]
)
