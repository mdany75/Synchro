// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Synchro",
    platforms: [.macOS(.v14)],
    targets: [
        // Moteur de synchronisation, sans interface : c'est lui que couvrent les tests.
        .target(name: "SynchroCore", path: "Sources/SynchroCore"),
        .executableTarget(name: "Synchro", dependencies: ["SynchroCore"], path: "Sources/Synchro"),
        .testTarget(name: "SynchroCoreTests", dependencies: ["SynchroCore"], path: "Tests/SynchroCoreTests"),
    ]
)
