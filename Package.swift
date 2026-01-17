// swift-tools-version: 5.9
// Perspicis iOS SDK - Privacy-First AdTech
// Version 2.1.0 - Now with AdMob integration

import PackageDescription

let package = Package(
    name: "Perspicis",
    platforms: [
        .iOS(.v15),
        .macOS(.v12) // For development/testing
    ],
    products: [
        .library(
            name: "Perspicis",
            type: .dynamic,
            targets: ["Perspicis"]
        ),
    ],
    dependencies: [
        // Google Mobile Ads SDK for real ad serving
        .package(url: "https://github.com/googleads/swift-package-manager-google-mobile-ads.git", from: "11.0.0")
    ],
    targets: [
        .target(
            name: "Perspicis",
            dependencies: [
                .product(name: "GoogleMobileAds", package: "swift-package-manager-google-mobile-ads")
            ],
            path: "Sources/Perspicis",
            exclude: [
                "RewardedVideo.swift"  // Temporarily excluded - needs API alignment
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        ),
    ]
)
