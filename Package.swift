// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Panelumi",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PanelumiKit", targets: ["PanelumiKit"]),
        .library(name: "PanelumiCore", targets: ["PanelumiCore"]),
        .executable(name: "Panelumi", targets: ["Panelumi"]),
    ],
    targets: [
        .target(name: "PanelumiKit"),
        .target(name: "PanelumiCore", dependencies: ["PanelumiKit"]),
        .executableTarget(name: "Panelumi", dependencies: ["PanelumiCore"]),
        .testTarget(name: "PanelumiKitTests", dependencies: ["PanelumiKit"]),
        .testTarget(name: "ScreenshotTests", dependencies: ["PanelumiCore"]),
    ]
)
