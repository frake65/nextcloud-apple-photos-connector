// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "APCSharedInventoryCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "InventoryCore", targets: ["InventoryCore"])
    ],
    targets: [
        .target(name: "InventoryCore"),
        .testTarget(name: "InventoryCoreTests", dependencies: ["InventoryCore"])
    ]
)
