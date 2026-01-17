// swift-tools-version: 5.9
// Perspicis iOS SDK - Privacy-First AdTech

import PackageDescription

let package = Package(
    name: "Perspicis",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "Perspicis",
            targets: ["Perspicis"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "Perspicis",
            path: "Perspicis.xcframework"
        ),
    ]
)
