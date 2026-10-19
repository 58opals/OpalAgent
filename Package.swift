// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OpalAgent",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "AgentValues", targets: ["AgentValues"]),
        .library(name: "AgentClient", targets: ["AgentClient"]),
        .library(name: "AgentAppIntents", targets: ["AgentAppIntents"]),
        .executable(name: "AgentService", targets: ["AgentService"]),
        .executable(name: "AgentBridge", targets: ["AgentBridge"]),
        .executable(name: "StoreLockProbe", targets: ["StoreLockProbe"]),
        .executable(name: "AgentProtocolFixture", targets: ["AgentProtocolFixture"])
    ],
    dependencies: [
        .package(url: "https://github.com/58opals/OpalBase.git", revision: "f1ec2dc05ce778eb2d29230b0fd9ba5fc1c02597"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        .target(name: "AgentValues"),
        .target(name: "AgentNativeIPC", dependencies: ["AgentValues"]),
        .target(name: "AgentClient", dependencies: ["AgentValues", "AgentNativeIPC"]),
        .target(name: "AgentAppIntents", dependencies: ["AgentClient", "AgentValues"]),
        .target(name: "AgentMCP", dependencies: ["AgentClient", "AgentValues", .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")]),
        .systemLibrary(name: "CSQLite"),
        .target(name: "AgentServiceCore", dependencies: ["AgentValues", "AgentNativeIPC", "CSQLite", .product(name: "OpalBaseCore", package: "OpalBase")]),
        .executableTarget(name: "AgentService", dependencies: ["AgentValues", "AgentServiceCore"]),
        .executableTarget(name: "AgentBridge", dependencies: ["AgentMCP", "AgentClient"]),
        .executableTarget(name: "AgentProtocolFixture", dependencies: ["AgentNativeIPC", "AgentMCP", "AgentClient", "AgentValues", "AgentServiceCore", .product(name: "OpalBaseCore", package: "OpalBase"), .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "StoreLockProbe", dependencies: ["AgentServiceCore"]),
        .testTarget(name: "AgentMCPTests", dependencies: ["AgentMCP", "AgentClient", "AgentValues", .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "AgentNativeIPCTests", dependencies: ["AgentNativeIPC", "AgentClient", "AgentValues"]),
        .testTarget(name: "AgentProtocolIntegrationTests", dependencies: ["AgentNativeIPC", "AgentProtocolFixture", "AgentMCP", "AgentClient", "AgentValues", "AgentServiceCore", .product(name: "OpalBaseCore", package: "OpalBase"), .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "AgentClientTests", dependencies: ["AgentClient", "AgentValues"]),
        .testTarget(name: "AgentAppIntentsTests", dependencies: ["AgentAppIntents", "AgentClient", "AgentValues"]),
        .testTarget(name: "AgentServiceCoreTests", dependencies: ["AgentServiceCore", "AgentClient", "AgentAppIntents", "AgentNativeIPC", "AgentValues", "CSQLite", .product(name: "OpalBaseCore", package: "OpalBase")], resources: [.copy("Fixtures/LegacyGrantV2")])
    ],
    swiftLanguageModes: [.v6]
)
