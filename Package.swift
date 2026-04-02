// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "Lapis",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "LapisCore", targets: ["LapisCore"]),
        .executable(name: "LapisApp", targets: ["LapisApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.8.0"),
    ],
    targets: [
        .target(
            name: "LapisCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "LapisApp",
            dependencies: ["LapisCore"]
        ),
        .testTarget(
            name: "LapisCoreTests",
            dependencies: ["LapisCore"]
        ),
        .testTarget(
            name: "LapisAppTests",
            dependencies: ["LapisApp", "LapisCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
