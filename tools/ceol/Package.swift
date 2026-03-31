// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ceol",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "ceol",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "CeolTests",
            dependencies: ["ceol"],
            path: "Tests/CeolTests"
        ),
    ]
)
