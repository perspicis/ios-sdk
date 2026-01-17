# Perspicis iOS SDK

Privacy-first mobile advertising SDK with on-device cohort computation.

## Installation

### Swift Package Manager

Add Perspicis to your project in Xcode:

1. File → Add Package Dependencies
2. Enter: `https://github.com/perspicis/ios-sdk`
3. Select version: `2.0.0` or later

Or add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/perspicis/ios-sdk", from: "2.0.0")
]
```

## Quick Start

```swift
import Perspicis

@main
struct MyApp: App {
    init() {
        PerspicisSDK.spark("pk_live_your_key_here")
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

### Show Ads

```swift
// Banner
SparkBanner()

// Rewarded Video
SparkRewardedView { reward in
    if let r = reward {
        print("User earned \(r.amount) \(r.type)")
    }
}

// Interstitial
SparkInterstitialView {
    print("Ad closed")
}
```

## Requirements

- iOS 15.0+
- Swift 5.9+
- Xcode 15.0+

## Privacy

- **No IDFA required** - Works without tracking permission
- **On-device cohorts** - User data never leaves the device
- **GDPR/CCPA compliant** - Privacy by design

## Support

- Email: raj@heliosnexus.com

## License

Copyright 2024 Aperture Media. All rights reserved.
