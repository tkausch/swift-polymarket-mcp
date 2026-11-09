// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PolymarketAdapter",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "PolymarketAdapter", targets: ["PolymarketAdapter"]),
        .executable(name: "polymarket-cli", targets: ["polymarket-cli"]),
        .executable(name: "polymarket-mcp", targets: ["polymarket-mcp"]),
    ],
    targets: [
        .target(name: "PolymarketAdapter"),
        .executableTarget(name: "polymarket-cli", dependencies: ["PolymarketAdapter"]),
        .executableTarget(name: "polymarket-mcp", dependencies: ["PolymarketAdapter"]),
        .testTarget(name: "PolymarketAdapterTests", dependencies: ["PolymarketAdapter"]),
    ]
)
