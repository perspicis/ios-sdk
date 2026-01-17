// =============================================================================
// Perspicis AdMob Adapter - Real Ad Serving via Google Mobile Ads
// =============================================================================
//
// This adapter wraps Google Mobile Ads SDK to provide real ad serving
// while maintaining Perspicis's simple API and cohort intelligence.
//
// Revenue flows directly to the publisher's AdMob account.
// Perspicis takes no cut - we add value through cohort targeting.
//
// =============================================================================

import Foundation

#if canImport(UIKit) && os(iOS)
import UIKit
import GoogleMobileAds

// MARK: - AdMob Configuration

/// Configuration for AdMob integration
public struct AdMobConfig: Sendable {
    /// Your AdMob App ID (ca-app-pub-xxx~xxx)
    public let appId: String

    /// Ad Unit ID for banner ads
    public let bannerAdUnitId: String?

    /// Ad Unit ID for interstitial ads
    public let interstitialAdUnitId: String?

    /// Ad Unit ID for rewarded video ads
    public let rewardedAdUnitId: String?

    /// Enable test mode (uses Google test ad units)
    public let testMode: Bool

    /// Test device IDs (for real device testing)
    public let testDeviceIds: [String]

    public init(
        appId: String,
        bannerAdUnitId: String? = nil,
        interstitialAdUnitId: String? = nil,
        rewardedAdUnitId: String? = nil,
        testMode: Bool = false,
        testDeviceIds: [String] = []
    ) {
        self.appId = appId
        self.bannerAdUnitId = bannerAdUnitId
        self.interstitialAdUnitId = interstitialAdUnitId
        self.rewardedAdUnitId = rewardedAdUnitId
        self.testMode = testMode
        self.testDeviceIds = testDeviceIds
    }

    /// Google's test ad unit IDs for development
    public static let testBannerAdUnitId = "ca-app-pub-3940256099942544/2934735716"
    public static let testInterstitialAdUnitId = "ca-app-pub-3940256099942544/4411468910"
    public static let testRewardedAdUnitId = "ca-app-pub-3940256099942544/1712485313"
}

// MARK: - AdMob Adapter

/// Main adapter for Google Mobile Ads integration
@MainActor
public final class AdMobAdapter: NSObject {

    // MARK: - Singleton

    public static let shared = AdMobAdapter()

    private override init() {
        super.init()
    }

    // MARK: - State

    private var config: AdMobConfig?
    private var _isInitialized = false
    private var debugMode = false

    /// Thread-safe check for initialization status
    private static var _isReadyFlag = false

    // Preloaded ads
    private var preloadedInterstitial: GADInterstitialAd?
    private var preloadedRewarded: GADRewardedAd?

    // Callbacks
    private var interstitialCompletion: ((Bool) -> Void)?
    private var rewardedCompletion: ((PerspicisSDK.Reward?) -> Void)?

    // MARK: - Initialization

    /// Initialize AdMob with configuration
    public func initialize(config: AdMobConfig, debug: Bool = false) {
        self.config = config
        self.debugMode = debug

        // Configure test devices
        if !config.testDeviceIds.isEmpty || config.testMode {
            var testIds = config.testDeviceIds
            testIds.append(GADSimulatorID)
            GADMobileAds.sharedInstance().requestConfiguration.testDeviceIdentifiers = testIds
        }

        // Initialize Google Mobile Ads SDK
        GADMobileAds.sharedInstance().start { [weak self] status in
            self?._isInitialized = true
            AdMobAdapter._isReadyFlag = true
            self?.log("AdMob initialized")

            // Log adapter status
            for (adapterClass, adapterStatus) in status.adapterStatusesByClassName {
                self?.log("Adapter \(adapterClass): \(adapterStatus.state.rawValue)")
            }

            // Preload ads
            self?.preloadInterstitial()
            self?.preloadRewarded()
        }
    }

    /// Check if AdMob is initialized and ready (thread-safe)
    nonisolated public var isReady: Bool {
        AdMobAdapter._isReadyFlag
    }

    // MARK: - Banner Ads

    /// Create a banner view
    public func createBannerView(size: GADAdSize = GADAdSizeBanner) -> GADBannerView? {
        guard let config = config else {
            log("AdMob not configured")
            return nil
        }

        let adUnitId = config.testMode ? AdMobConfig.testBannerAdUnitId : config.bannerAdUnitId
        guard let adUnitId = adUnitId else {
            log("No banner ad unit ID configured")
            return nil
        }

        let bannerView = GADBannerView(adSize: size)
        bannerView.adUnitID = adUnitId

        return bannerView
    }

    /// Load a banner ad
    public func loadBanner(_ bannerView: GADBannerView, rootViewController: UIViewController) {
        bannerView.rootViewController = rootViewController

        // Add Perspicis cohort targeting
        Task {
            let targeting = await PerspicisSDK.shared.admobTargeting()
            let request = GADRequest()

            // Add custom targeting with cohorts
            var extras: [String: String] = targeting
            extras["perspicis_sdk"] = PerspicisSDK.version

            log("Loading banner with targeting: \(extras)")
            bannerView.load(request)

            SparkTelemetry.shared.trackAdRequest(placement: "banner")
        }
    }

    // MARK: - Interstitial Ads

    /// Preload an interstitial ad
    public func preloadInterstitial() {
        guard let config = config else { return }

        let adUnitId = config.testMode ? AdMobConfig.testInterstitialAdUnitId : config.interstitialAdUnitId
        guard let adUnitId = adUnitId else {
            log("No interstitial ad unit ID configured")
            return
        }

        log("Preloading interstitial...")

        Task {
            let targeting = await PerspicisSDK.shared.admobTargeting()
            let request = GADRequest()

            GADInterstitialAd.load(withAdUnitID: adUnitId, request: request) { [weak self] ad, error in
                if let error = error {
                    self?.log("Interstitial preload failed: \(error.localizedDescription)")
                    return
                }

                self?.preloadedInterstitial = ad
                self?.preloadedInterstitial?.fullScreenContentDelegate = self
                self?.log("Interstitial preloaded successfully")
            }
        }
    }

    /// Show an interstitial ad
    public func showInterstitial(from viewController: UIViewController, completion: ((Bool) -> Void)?) {
        guard let ad = preloadedInterstitial else {
            log("No interstitial ready, loading on-demand...")
            loadAndShowInterstitial(from: viewController, completion: completion)
            return
        }

        interstitialCompletion = completion

        SparkTelemetry.shared.trackImpression(placement: "interstitial", adId: "admob")
        ad.present(fromRootViewController: viewController)

        // Preload next one
        preloadInterstitial()
    }

    private func loadAndShowInterstitial(from viewController: UIViewController, completion: ((Bool) -> Void)?) {
        guard let config = config else {
            completion?(false)
            return
        }

        let adUnitId = config.testMode ? AdMobConfig.testInterstitialAdUnitId : config.interstitialAdUnitId
        guard let adUnitId = adUnitId else {
            log("No interstitial ad unit ID configured")
            completion?(false)
            return
        }

        SparkTelemetry.shared.trackAdRequest(placement: "interstitial")

        Task {
            let request = GADRequest()

            GADInterstitialAd.load(withAdUnitID: adUnitId, request: request) { [weak self] ad, error in
                if let error = error {
                    self?.log("Interstitial load failed: \(error.localizedDescription)")
                    SparkTelemetry.shared.trackEvent("ad_load_failed", properties: [
                        "placement": "interstitial",
                        "error": error.localizedDescription
                    ])
                    completion?(false)
                    return
                }

                guard let ad = ad else {
                    completion?(false)
                    return
                }

                self?.interstitialCompletion = completion
                ad.fullScreenContentDelegate = self

                SparkTelemetry.shared.trackAdFill(placement: "interstitial", adId: "admob", latencyMs: 0)
                SparkTelemetry.shared.trackImpression(placement: "interstitial", adId: "admob")
                ad.present(fromRootViewController: viewController)
            }
        }
    }

    // MARK: - Rewarded Ads

    /// Preload a rewarded ad
    public func preloadRewarded() {
        guard let config = config else { return }

        let adUnitId = config.testMode ? AdMobConfig.testRewardedAdUnitId : config.rewardedAdUnitId
        guard let adUnitId = adUnitId else {
            log("No rewarded ad unit ID configured")
            return
        }

        log("Preloading rewarded...")

        Task {
            let request = GADRequest()

            GADRewardedAd.load(withAdUnitID: adUnitId, request: request) { [weak self] ad, error in
                if let error = error {
                    self?.log("Rewarded preload failed: \(error.localizedDescription)")
                    return
                }

                self?.preloadedRewarded = ad
                self?.preloadedRewarded?.fullScreenContentDelegate = self
                self?.log("Rewarded preloaded successfully")
            }
        }
    }

    /// Show a rewarded ad
    public func showRewarded(from viewController: UIViewController, completion: @escaping (PerspicisSDK.Reward?) -> Void) {
        guard let ad = preloadedRewarded else {
            log("No rewarded ready, loading on-demand...")
            loadAndShowRewarded(from: viewController, completion: completion)
            return
        }

        rewardedCompletion = completion

        SparkTelemetry.shared.trackImpression(placement: "rewarded", adId: "admob")
        ad.present(fromRootViewController: viewController) { [weak self] in
            // User earned reward
            let reward = ad.adReward
            self?.log("User earned reward: \(reward.amount) \(reward.type)")

            SparkTelemetry.shared.trackEvent("ad_reward_earned", properties: [
                "type": reward.type,
                "amount": reward.amount.intValue
            ])
        }

        // Preload next one
        preloadRewarded()
    }

    private func loadAndShowRewarded(from viewController: UIViewController, completion: @escaping (PerspicisSDK.Reward?) -> Void) {
        guard let config = config else {
            completion(nil)
            return
        }

        let adUnitId = config.testMode ? AdMobConfig.testRewardedAdUnitId : config.rewardedAdUnitId
        guard let adUnitId = adUnitId else {
            log("No rewarded ad unit ID configured")
            completion(nil)
            return
        }

        SparkTelemetry.shared.trackAdRequest(placement: "rewarded")

        Task {
            let request = GADRequest()

            GADRewardedAd.load(withAdUnitID: adUnitId, request: request) { [weak self] ad, error in
                if let error = error {
                    self?.log("Rewarded load failed: \(error.localizedDescription)")
                    SparkTelemetry.shared.trackEvent("ad_load_failed", properties: [
                        "placement": "rewarded",
                        "error": error.localizedDescription
                    ])
                    completion(nil)
                    return
                }

                guard let ad = ad else {
                    completion(nil)
                    return
                }

                self?.rewardedCompletion = completion
                ad.fullScreenContentDelegate = self

                SparkTelemetry.shared.trackAdFill(placement: "rewarded", adId: "admob", latencyMs: 0)
                SparkTelemetry.shared.trackImpression(placement: "rewarded", adId: "admob")

                ad.present(fromRootViewController: viewController) { [weak self] in
                    let reward = ad.adReward
                    self?.log("User earned reward: \(reward.amount) \(reward.type)")

                    SparkTelemetry.shared.trackEvent("ad_reward_earned", properties: [
                        "type": reward.type,
                        "amount": reward.amount.intValue
                    ])
                }
            }
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        if debugMode {
            print("[Perspicis/AdMob] \(message)")
        }
    }
}

// MARK: - GADFullScreenContentDelegate

extension AdMobAdapter: GADFullScreenContentDelegate {

    nonisolated public func adDidRecordImpression(_ ad: GADFullScreenPresentingAd) {
        Task { @MainActor in
            log("Ad recorded impression")
        }
    }

    nonisolated public func adDidRecordClick(_ ad: GADFullScreenPresentingAd) {
        Task { @MainActor in
            log("Ad recorded click")
        }
        SparkTelemetry.shared.trackClick(placement: "fullscreen", adId: "admob")
    }

    nonisolated public func ad(_ ad: GADFullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) {
        Task { @MainActor in
            log("Ad failed to present: \(error.localizedDescription)")

            // Call appropriate completion
            interstitialCompletion?(false)
            interstitialCompletion = nil

            rewardedCompletion?(nil)
            rewardedCompletion = nil
        }
    }

    nonisolated public func adWillPresentFullScreenContent(_ ad: GADFullScreenPresentingAd) {
        Task { @MainActor in
            log("Ad will present")
        }
    }

    nonisolated public func adWillDismissFullScreenContent(_ ad: GADFullScreenPresentingAd) {
        Task { @MainActor in
            log("Ad will dismiss")
        }
    }

    nonisolated public func adDidDismissFullScreenContent(_ ad: GADFullScreenPresentingAd) {
        Task { @MainActor in
            log("Ad dismissed")

            // Call completions
            if let completion = interstitialCompletion {
                completion(true)
                interstitialCompletion = nil
            }

            if let completion = rewardedCompletion {
                // If rewarded, the reward was already granted in the present callback
                completion(PerspicisSDK.Reward(type: "coins", amount: 1))
                rewardedCompletion = nil
            }
        }
    }
}

// MARK: - SwiftUI Banner View

import SwiftUI

/// SwiftUI wrapper for AdMob banner
public struct AdMobBannerView: UIViewRepresentable {
    let adSize: GADAdSize

    public init(adSize: GADAdSize = GADAdSizeBanner) {
        self.adSize = adSize
    }

    public func makeUIView(context: Context) -> GADBannerView {
        let bannerView = AdMobAdapter.shared.createBannerView(size: adSize) ?? GADBannerView()
        return bannerView
    }

    public func updateUIView(_ bannerView: GADBannerView, context: Context) {
        // Find root view controller and load ad
        if bannerView.rootViewController == nil {
            DispatchQueue.main.async {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootVC = windowScene.windows.first?.rootViewController {
                    AdMobAdapter.shared.loadBanner(bannerView, rootViewController: rootVC)
                }
            }
        }
    }
}

#endif
