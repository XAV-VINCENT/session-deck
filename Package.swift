// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SessionDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SessionDeck", path: "Sources/SessionDeck")
    ]
)
