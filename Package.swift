// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Synchro",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Synchro", path: "Sources/Synchro")
    ]
)
