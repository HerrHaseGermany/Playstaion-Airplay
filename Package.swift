// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PlayLink",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "PlayLink", path: "Sources/PlayLink"),
        .testTarget(name: "PlayLinkTests", dependencies: ["PlayLink"], path: "Tests/PlayLinkTests")
    ]
)
