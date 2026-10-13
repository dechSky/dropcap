// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dropcap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Dropcap",
            path: "Sources/Dropcap",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DropcapTests",
            dependencies: ["Dropcap"],
            path: "Tests/DropcapTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
