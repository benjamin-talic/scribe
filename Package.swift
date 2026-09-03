// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Scribe",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Scribe", targets: ["Scribe"]),
    ],
    targets: [
        .executableTarget(name: "Scribe"),
        .testTarget(name: "ScribeTests", dependencies: ["Scribe"]),
    ]
)
