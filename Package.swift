// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "dockToggle",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DockClickMinimize", targets: ["dockToggle"])
    ],
    targets: [
        .executableTarget(
            name: "dockToggle"
        ),
        .testTarget(
            name: "dockToggleTests",
            dependencies: ["dockToggle"]
        )
    ]
)
