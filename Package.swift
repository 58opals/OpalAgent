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
        .package(url: "https://github.com/58opals/OpalBase.git", revision: "d7038c2d18f89d4805059b0a4f7a84ca525849a1"),
        .package(url: "https://github.com/58opals/OpalDiagnostics.git", revision: "aa56dec5d6c8581beb2b3cef43b03dd577ccd9f1")
    ],
    targets: [
        .target(name: "AgentValues"),
        .target(name: "AgentNativeIPC", dependencies: ["AgentValues"]),
        .target(name: "AgentClient", dependencies: ["AgentValues", "AgentNativeIPC"]),
        .target(name: "AgentAppIntents", dependencies: ["AgentClient", "AgentValues"]),
        .target(name: "AgentMCP", dependencies: [.product(name: "OpalDiagnostics", package: "OpalDiagnostics"), "AgentClient", "AgentValues"]),
        .systemLibrary(name: "CSQLite"),
        .target(name: "AgentServiceCore", dependencies: [.product(name: "OpalDiagnostics", package: "OpalDiagnostics"), "AgentValues", "AgentNativeIPC", "CSQLite", .product(name: "OpalBaseCore", package: "OpalBase")]),
        .executableTarget(name: "AgentService", dependencies: [.product(name: "OpalDiagnostics", package: "OpalDiagnostics"), "AgentValues", "AgentServiceCore"]),
        .executableTarget(name: "AgentBridge", dependencies: [.product(name: "OpalDiagnostics", package: "OpalDiagnostics"), "AgentMCP", "AgentClient"]),
        .executableTarget(name: "AgentProtocolFixture", dependencies: ["AgentNativeIPC", "AgentMCP", "AgentClient", "AgentValues", "AgentServiceCore", .product(name: "OpalBaseCore", package: "OpalBase")]),
        .executableTarget(name: "StoreLockProbe", dependencies: ["AgentServiceCore"]),
        .target(name: "AgentMCPTestSupport", dependencies: ["AgentMCP"], path: "Tests/AgentMCPTestSupport"),
        .testTarget(name: "AgentMCPTests", dependencies: ["AgentMCPTestSupport", .product(name: "OpalDiagnostics", package: "OpalDiagnostics"), "AgentMCP", "AgentClient", "AgentValues"]),
        .testTarget(name: "AgentNativeIPCTests", dependencies: ["AgentNativeIPC", "AgentClient", "AgentValues"]),
        .testTarget(name: "AgentProtocolIntegrationTests", dependencies: ["AgentMCPTestSupport", "AgentNativeIPC", "AgentProtocolFixture", "AgentMCP", "AgentClient", "AgentValues", "AgentServiceCore", .product(name: "OpalBaseCore", package: "OpalBase")]),
        .testTarget(name: "AgentClientTests", dependencies: ["AgentClient", "AgentValues"]),
        .testTarget(name: "AgentAppIntentsTests", dependencies: ["AgentAppIntents", "AgentClient", "AgentValues"]),
        .testTarget(name: "AgentServiceCoreTests", dependencies: [.product(name: "OpalDiagnostics", package: "OpalDiagnostics"), "AgentServiceCore", "AgentClient", "AgentAppIntents", "AgentNativeIPC", "AgentValues", "CSQLite", .product(name: "OpalBaseCore", package: "OpalBase")], resources: [.copy("Fixtures/LegacyGrantV2")])
    ],
    swiftLanguageModes: [.v6]
)
