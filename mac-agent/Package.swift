// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ApplePhotosConnector",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacAgent", targets: ["MacAgent"]), .executable(name: "APCConfigureConnection", targets: ["APCConfigureConnection"])],
    dependencies: [
        .package(name: "APCSharedInventoryCore", path: "../shared/InventoryCore")
    ],
    targets: [
        .target(name: "MacAgentSupport", dependencies: [.product(name: "InventoryCore", package: "APCSharedInventoryCore")]),
        .executableTarget(name: "MacAgent", dependencies: ["MacAgentSupport", .product(name: "InventoryCore", package: "APCSharedInventoryCore")]),
        .executableTarget(name: "APCConfigureConnection", dependencies: ["MacAgentSupport", .product(name: "InventoryCore", package: "APCSharedInventoryCore")]),
        .testTarget(name: "MacAgentTests", dependencies: ["MacAgentSupport", "MacAgent", .product(name: "InventoryCore", package: "APCSharedInventoryCore")])
    ]
)
