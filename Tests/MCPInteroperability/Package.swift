// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OpalMCPInteroperability",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .testTarget(
            name: "MCPInteroperabilityTests",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        )
    ],
    swiftLanguageModes: [.v6]
)
