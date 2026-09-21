// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentConversationFinder",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentConversationFinderCore", targets: ["AgentConversationFinderCore"]),
        .executable(name: "AgentConversationFinderApp", targets: ["AgentConversationFinderApp"]),
        .executable(name: "acf", targets: ["AgentConversationFinderCLI"])
    ],
    targets: [
        .target(name: "AgentConversationFinderCore"),
        .executableTarget(
            name: "AgentConversationFinderApp",
            dependencies: ["AgentConversationFinderCore"]
        ),
        .executableTarget(name: "AgentConversationFinderCLI", dependencies: ["AgentConversationFinderCore"]),
        .testTarget(
            name: "AgentConversationFinderCoreTests",
            dependencies: ["AgentConversationFinderCore"]
        )
    ]
)
