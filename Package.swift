// swift-tools-version: 6.1
// SPDX-License-Identifier: GPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "ossover",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OssoverKit", targets: ["OssoverKit"]),
        .executable(name: "ossover", targets: ["ossover"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "OssoverKit",
            path: "Sources/OssoverKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ossover",
            dependencies: [
                "OssoverKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/ossover",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OssoverKitTests",
            dependencies: ["OssoverKit"],
            path: "Tests/OssoverKitTests",
            resources: [.copy("../Fixtures")]
        ),
    ]
)
