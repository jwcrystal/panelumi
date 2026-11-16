// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwitchDeck",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SwitchKit", targets: ["SwitchKit"]),
        .library(name: "SwitchDeckCore", targets: ["SwitchDeckCore"]),
        .executable(name: "SwitchDeck", targets: ["SwitchDeck"]),
    ],
    targets: [
        .target(name: "SwitchKit"),
        .target(name: "SwitchDeckCore", dependencies: ["SwitchKit"]),
        .executableTarget(name: "SwitchDeck", dependencies: ["SwitchDeckCore"]),
        .testTarget(name: "SwitchKitTests", dependencies: ["SwitchKit"]),
        .testTarget(name: "ScreenshotTests", dependencies: ["SwitchDeckCore"]),
    ]
)
