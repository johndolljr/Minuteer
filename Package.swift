// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Minuteer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MinuteerCore", targets: ["MinuteerCore"]),
        .executable(name: "Minuteer", targets: ["Minuteer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
    ],
    targets: [
        .target(
            name: "MinuteerCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .executableTarget(
            name: "Minuteer",
            dependencies: ["MinuteerCore"],
            exclude: ["Info.plist"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MinuteerCoreTests",
            dependencies: ["MinuteerCore"]
        ),
    ]
)
