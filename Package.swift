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
    dependencies: [.package(url: "https://github.com/58opals/OpalBase.git", revision: "f1ec2dc05ce778eb2d29230b0fd9ba5fc1c02597")],
    targets: [
        .target(name: "AgentValues"),
        .target(name: "AgentClient", dependencies: ["AgentValues"]),
        .systemLibrary(name: "CSQLite"),
        .target(name: "AgentServiceCore", dependencies: ["CSQLite", .product(name: "OpalBaseCore", package: "OpalBase")]),
        .executableTarget(name: "AgentService", dependencies: ["AgentValues", "AgentServiceCore"]),
        .executableTarget(name: "AgentBridge", dependencies: ["AgentClient"]),
        .executableTarget(name: "StoreLockProbe", dependencies: ["AgentServiceCore"]),
        .testTarget(name: "AgentClientTests", dependencies: ["AgentClient", "AgentValues"]),
        .testTarget(name: "AgentServiceCoreTests", dependencies: ["AgentServiceCore", "CSQLite", .product(name: "OpalBaseCore", package: "OpalBase")])
    ],
    swiftLanguageModes: [.v6]
)
