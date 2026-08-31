// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SecretKeeper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SecretKeeperCore", targets: ["SecretKeeperCore"]),
        .executable(name: "secret-keeper-mcp", targets: ["secret-keeper-mcp"]),
        .executable(name: "SecretKeeperApp", targets: ["SecretKeeperApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "SecretKeeperCore",
            dependencies: []
        ),
        .executableTarget(
            name: "secret-keeper-mcp",
            dependencies: [
                "SecretKeeperCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "SecretKeeperApp",
            dependencies: ["SecretKeeperCore"]
        ),
        .testTarget(
            name: "SecretKeeperCoreTests",
            dependencies: ["SecretKeeperCore"]
        ),
    ]
)
