// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AINewsAlert",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AINewsAlert",
            path: "Sources/AINewsAlert",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AINewsAlertTests",
            dependencies: ["AINewsAlert"],
            path: "Tests/AINewsAlertTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
