// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Scribe", targets: ["Scribe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", .upToNextMinor(from: "0.18.0")),
    ],
    targets: [
        .executableTarget(
            name: "Scribe",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ]
        ),
        .testTarget(name: "ScribeTests", dependencies: ["Scribe"]),
    ]
)
