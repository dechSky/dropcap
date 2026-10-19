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
        // 시작점은 시스템 확장 입구(_NSExtensionMain) — Xcode 의 앱 확장 타깃과 같게. 이것 없이 @main 으로 바로 들어가면
        // ExtensionFoundation 이 확장 설정(ExtensionMain)을 받지 못해 시작하자마자 끝났다(10-15 충돌 보고).
        .executableTarget(
            name: "DropcapWidgets",
            dependencies: ["DropcapShared"],
            path: "Sources/DropcapWidgets",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .testTarget(
            name: "DropcapTests",
            dependencies: ["Dropcap", "DropcapShared"],
            path: "Tests/DropcapTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
