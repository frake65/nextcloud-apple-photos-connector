// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ApplePhotosConnector",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacAgent", targets: ["MacAgent"]), .executable(name: "APCConfigureConnection", targets: ["APCConfigureConnection"])],
    targets: [
        .target(name: "InventoryCore"),
        .executableTarget(name: "MacAgent", dependencies: ["InventoryCore"]),
        .executableTarget(name: "APCConfigureConnection", dependencies: ["InventoryCore"]),
        .testTarget(name: "InventoryCoreTests", dependencies: ["InventoryCore", "MacAgent"])
    ]
)
