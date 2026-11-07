// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "iwifyou",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "iwifyou", targets: ["iwifyou"])],
    targets: [
        .target(name: "IWiFiYouCore"),
        .executableTarget(
            name: "iwifyou",
            dependencies: ["IWiFiYouCore"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "IWiFiYouCoreTests",
            dependencies: ["IWiFiYouCore", "iwifyou"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
