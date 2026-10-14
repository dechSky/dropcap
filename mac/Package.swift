// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dropcap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Dropcap",
            dependencies: ["DropcapShared"],
            path: "Sources/Dropcap",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 앱과 위젯 확장이 함께 쓰는 스냅숏 형식·위젯 화면
        .target(
            name: "DropcapShared",
            path: "Sources/DropcapShared",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 위젯 확장 실행 파일: build.sh 가 Contents/PlugIns/DropcapWidgets.appex 로 묶는다
        .executableTarget(
            name: "DropcapWidgets",
            dependencies: ["DropcapShared"],
            path: "Sources/DropcapWidgets",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DropcapTests",
            dependencies: ["Dropcap", "DropcapShared"],
            path: "Tests/DropcapTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
