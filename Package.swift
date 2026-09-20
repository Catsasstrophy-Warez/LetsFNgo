// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DayTradeScanner",
    platforms: [
        .iOS(.v18)
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "DayTradeScanner",
            dependencies: [],
            path: "Sources/DayTradeScanner",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "DayTradeScannerTests",
            dependencies: ["DayTradeScanner"],
            path: "Tests/DayTradeScannerTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
