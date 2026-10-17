// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OpalAgent",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "AgentValues", targets: ["AgentValues"]),
        .library(name: "AgentClient", targets: ["AgentClient"]),
        .executable(name: "AgentService", targets: ["AgentService"]),
        .executable(name: "AgentBridge", targets: ["AgentBridge"]),
        .executable(name: "StoreLockProbe", targets: ["StoreLockProbe"])
    ],
    targets: [
        .target(name: "AgentValues"),
        .target(name: "AgentClient", dependencies: ["AgentValues"]),
        .target(name: "AgentServiceCore"),
        .executableTarget(name: "AgentService", dependencies: ["AgentValues", "AgentServiceCore"]),
        .executableTarget(name: "AgentBridge", dependencies: ["AgentClient"]),
        .executableTarget(name: "StoreLockProbe", dependencies: ["AgentServiceCore"]),
        .testTarget(name: "AgentClientTests", dependencies: ["AgentClient", "AgentValues"]),
        .testTarget(name: "AgentServiceCoreTests", dependencies: ["AgentServiceCore"])
    ],
    swiftLanguageModes: [.v6]
)
