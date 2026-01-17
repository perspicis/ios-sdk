// =============================================================================
// Perspicis Demo Mode - Test Without Backend
// =============================================================================
//
// For demos and testing:
//
//   Perspicis.startDemo()  // Uses fake ads, no backend needed
//
// =============================================================================

import Foundation

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Demo Mode

public extension PerspicisSDK {

    /// Start in demo mode - no backend required
    ///
    /// ```swift
    /// // For demos and testing
    /// Perspicis.startDemo()
    /// ```
    ///
    /// Uses built-in sample ads. Perfect for:
    /// - Quick demos
    /// - UI testing
    /// - Development without backend
    ///
    static func startDemo() {
        DemoAdServer.shared.isEnabled = true
        shared.state = .ready
        print("[Perspicis] Demo mode enabled - using sample ads")
    }

    /// Check if running in demo mode
    static var isDemoMode: Bool {
        DemoAdServer.shared.isEnabled
    }
}

// MARK: - Demo Ad Server

class DemoAdServer {
    static let shared = DemoAdServer()

    var isEnabled = false

    // Sample ad catalog
    private let sampleAds: [AdPlacement: [AdResponse]] = [
        .banner: [
            AdResponse(
                adId: "demo_banner_1",
                campaignId: "demo_campaign",
                creativeUrl: "https://placehold.co/320x50/4A90D9/white?text=Sample+Banner+Ad",
                clickUrl: "https://perspicis.com",
                type: "image",
                duration: nil,
                width: 320,
                height: 50,
                trackingUrls: TrackingURLs(
                    impression: "https://httpbin.org/get?event=impression",
                    click: "https://httpbin.org/get?event=click",
                    complete: nil,
                    firstQuartile: nil,
                    midpoint: nil,
                    thirdQuartile: nil
                )
            ),
            AdResponse(
                adId: "demo_banner_2",
                campaignId: "demo_campaign",
                creativeUrl: "https://placehold.co/320x50/2ECC71/white?text=Get+50%25+Off+Today!",
                clickUrl: "https://perspicis.com",
                type: "image",
                duration: nil,
                width: 320,
                height: 50,
                trackingUrls: TrackingURLs(
                    impression: "https://httpbin.org/get?event=impression",
                    click: "https://httpbin.org/get?event=click",
                    complete: nil,
                    firstQuartile: nil,
                    midpoint: nil,
                    thirdQuartile: nil
                )
            )
        ],
        .interstitial: [
            AdResponse(
                adId: "demo_interstitial_1",
                campaignId: "demo_campaign",
                creativeUrl: "https://placehold.co/400x600/9B59B6/white?text=Interstitial+Ad\\nTap+to+Learn+More",
                clickUrl: "https://perspicis.com",
                type: "image",
                duration: nil,
                width: 400,
                height: 600,
                trackingUrls: TrackingURLs(
                    impression: "https://httpbin.org/get?event=impression",
                    click: "https://httpbin.org/get?event=click",
                    complete: nil,
                    firstQuartile: nil,
                    midpoint: nil,
                    thirdQuartile: nil
                )
            )
        ],
        .rewardedVideo: [
            AdResponse(
                adId: "demo_rewarded_1",
                campaignId: "demo_campaign",
                creativeUrl: "https://placehold.co/400x600/E74C3C/white?text=Watch+for+Reward\\n5+seconds",
                clickUrl: "https://perspicis.com",
                type: "image",
                duration: 5,
                width: 400,
                height: 600,
                trackingUrls: TrackingURLs(
                    impression: "https://httpbin.org/get?event=impression",
                    click: "https://httpbin.org/get?event=click",
                    complete: "https://httpbin.org/get?event=complete",
                    firstQuartile: "https://httpbin.org/get?event=q1",
                    midpoint: "https://httpbin.org/get?event=mid",
                    thirdQuartile: "https://httpbin.org/get?event=q3"
                )
            )
        ]
    ]

    func getAd(placement: AdPlacement) -> AdResponse? {
        guard isEnabled else { return nil }
        return sampleAds[placement]?.randomElement()
    }
}

// MARK: - Override requestAd for Demo Mode

public extension PerspicisSDK {

    /// Request an ad (with demo mode support)
    func requestAdWithDemo(placement: AdPlacement) async -> Result<AdResponse, PerspicisError> {
        // Check demo mode first
        if DemoAdServer.shared.isEnabled {
            if let ad = DemoAdServer.shared.getAd(placement: placement) {
                // Simulate network delay
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                return .success(ad)
            }
            return .failure(.noFill)
        }

        // Fall through to real request
        return await requestAd(placement: placement)
    }
}

// MARK: - Demo-Aware Spark API

public extension PerspicisSDK {

    /// Show an interstitial ad (demo-aware)
    @MainActor
    static func showDemoAd(completion: ((Bool) -> Void)? = nil) {
        #if os(iOS)
        guard let viewController = topViewControllerForDemo() else {
            completion?(false)
            return
        }

        Task {
            let result = await shared.requestAdWithDemo(placement: .interstitial)

            await MainActor.run {
                switch result {
                case .success(let ad):
                    let adVC = SparkAdViewController(ad: ad) {
                        completion?(true)
                    }
                    adVC.modalPresentationStyle = .fullScreen
                    viewController.present(adVC, animated: true)
                case .failure:
                    completion?(false)
                }
            }
        }
        #else
        completion?(false)
        #endif
    }

    /// Show a rewarded ad (demo-aware)
    @MainActor
    static func showDemoRewarded(completion: @escaping (PerspicisSDK.Reward?) -> Void) {
        #if os(iOS)
        guard let viewController = topViewControllerForDemo() else {
            completion(nil)
            return
        }

        Task {
            let result = await shared.requestAdWithDemo(placement: .rewardedVideo)

            await MainActor.run {
                switch result {
                case .success(let ad):
                    let adVC = SparkAdViewController(ad: ad, isRewarded: true) {
                        completion(PerspicisSDK.Reward(type: "coins", amount: 100))
                    }
                    adVC.modalPresentationStyle = .fullScreen
                    viewController.present(adVC, animated: true)
                case .failure:
                    completion(nil)
                }
            }
        }
        #else
        completion(nil)
        #endif
    }

    #if os(iOS)
    @MainActor
    private static func topViewControllerForDemo() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = windowScene.windows.first?.rootViewController else {
            return nil
        }

        var top = rootVC
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
    #endif
}

// MARK: - Demo SwiftUI Banner (Cross-platform)

#if canImport(SwiftUI)
import SwiftUI

/// Demo banner that works without backend
public struct DemoBanner: View {
    public enum Size {
        case standard, medium, large

        var dimensions: CGSize {
            switch self {
            case .standard: return CGSize(width: 320, height: 50)
            case .medium: return CGSize(width: 300, height: 250)
            case .large: return CGSize(width: 728, height: 90)
            }
        }
    }

    private let size: Size

    public init(_ size: Size = .standard) {
        self.size = size
    }

    public var body: some View {
        // Simple styled banner - no network dependency
        HStack(spacing: 8) {
            Image(systemName: "megaphone.fill")
                .foregroundColor(.white)
            Text("Sample Ad Banner")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.white)
            Spacer()
            Text("Learn More →")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .frame(width: size.dimensions.width, height: size.dimensions.height)
        .background(
            LinearGradient(
                colors: [Color.blue, Color.purple],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .cornerRadius(8)
    }
}

// MARK: - Cross-Platform Rewarded Ad View

/// A SwiftUI sheet that displays a rewarded ad (works on macOS and iOS)
public struct DemoRewardedAdView: View {
    let onComplete: (PerspicisSDK.Reward?) -> Void
    @State private var remainingTime: Int = 5
    @State private var canClose: Bool = false
    @State private var isLoading: Bool = true
    @State private var loadTimeMs: Int = 0
    @Environment(\.presentationMode) private var presentationMode

    public init(onComplete: @escaping (PerspicisSDK.Reward?) -> Void) {
        self.onComplete = onComplete
    }

    public var body: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [Color.purple, Color.blue, Color.indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if isLoading {
                // Loading state (simulates ad fetching)
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                        .tint(.white)
                    Text("Loading ad...")
                        .font(.headline)
                        .foregroundColor(.white)
                }
            } else {
                VStack(spacing: 30) {
                    Spacer()

                    // Ad content
                    VStack(spacing: 20) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 80))
                            .foregroundColor(.white)

                        Text("Rewarded Video Ad")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.white)

                        Text("Watch this ad to earn your reward!")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.8))

                        // Fake product promo
                        VStack(spacing: 8) {
                            Text("🎮 Super Game Pro")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("Download Now - Free!")
                                .font(.subheadline)
                                .foregroundColor(.yellow)
                        }
                        .padding()
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(12)

                        // Show actual load time
                        Text("Loaded in \(loadTimeMs)ms")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }

                    Spacer()

                    // Timer or close button
                    if canClose {
                        Button {
                            presentationMode.wrappedValue.dismiss()
                            onComplete(PerspicisSDK.Reward(type: "coins", amount: 100))
                        } label: {
                            HStack {
                                Image(systemName: "gift.fill")
                                Text("Claim 100 Coins!")
                            }
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .padding(.horizontal, 40)
                    } else {
                        VStack(spacing: 8) {
                            Text("\(remainingTime)")
                                .font(.system(size: 48, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text("seconds remaining")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }

                    Spacer()
                }
                .padding()
            }
        }
        .frame(minWidth: 400, minHeight: 500)
        .onAppear {
            simulateAdLoad()
        }
    }

    private func simulateAdLoad() {
        // Track ad request when view appears
        SparkTelemetry.shared.trackAdRequest(placement: "rewarded")

        // Simulate realistic ad network latency (30-80ms)
        let simulatedLatencyMs = Int.random(in: 30...80)

        DispatchQueue.main.asyncAfter(deadline: .now() + Double(simulatedLatencyMs) / 1000.0) {
            // Track ad fill with actual measured latency
            SparkTelemetry.shared.trackAdFill(placement: "rewarded", adId: "demo_rewarded")
            loadTimeMs = simulatedLatencyMs
            isLoading = false
            startTimer()
        }
    }

    private func startTimer() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if remainingTime > 1 {
                remainingTime -= 1
            } else {
                timer.invalidate()
                canClose = true
            }
        }
    }
}

/// A SwiftUI sheet for interstitial ads
public struct DemoInterstitialView: View {
    let onComplete: () -> Void
    @Environment(\.presentationMode) private var presentationMode

    public init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    public var body: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [Color.orange, Color.red, Color.pink],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack {
                // Close button
                HStack {
                    Spacer()
                    Button {
                        presentationMode.wrappedValue.dismiss()
                        onComplete()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .padding()
                }

                Spacer()

                // Ad content
                VStack(spacing: 24) {
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 100))
                        .foregroundColor(.yellow)

                    Text("Special Offer!")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    Text("Check out this amazing deal")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.9))

                    // Fake CTA
                    Button {
                        // Would open URL in real ad
                    } label: {
                        Text("Learn More")
                            .font(.headline)
                            .padding()
                            .frame(width: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundColor(.orange)
                }

                Spacer()

                Text("Advertisement")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.bottom)
            }
        }
        .frame(minWidth: 400, minHeight: 500)
    }
}
#endif
