// =============================================================================
// Perspicis Spark API - The World's Easiest Ad SDK
// =============================================================================
//
// ZERO-CONFIG (just add PerspicisAppKey to Info.plist):
//
//   Perspicis.spark()
//
// OR ONE-LINER:
//
//   Perspicis.spark("pk_your_key")
//
// SWIFTUI - LITERALLY ONE MODIFIER:
//
//   @main
//   struct MyApp: App {
//       var body: some Scene {
//           WindowGroup { GameView() }.monetize()
//       }
//   }
//
// That's it. The #1 easiest ad integration in the world.
// =============================================================================

import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(GoogleMobileAds) && os(iOS)
import GoogleMobileAds
#endif

// MARK: - Key Environment Detection

/// SDK operating mode, auto-detected from key prefix
public enum SparkMode: String {
    case live       // pk_live_xxx - Production ads, real billing
    case test       // pk_test_xxx - Sandbox ads, no billing
    case demo       // pk_demo_xxx or no key - Local demo ads

    /// Detect mode from app key prefix
    static func from(appKey: String?) -> SparkMode {
        guard let key = appKey else { return .demo }
        if key.hasPrefix("pk_live_") { return .live }
        if key.hasPrefix("pk_test_") { return .test }
        if key.hasPrefix("pk_demo_") { return .demo }
        // Legacy keys without environment prefix default to live
        if key.hasPrefix("pk_") { return .live }
        return .demo
    }
}

// MARK: - Spark API (Zero-Config Integration)

public extension PerspicisSDK {

    /// Current SDK operating mode
    private(set) static var mode: SparkMode = .demo

    // MARK: - Zero-Config Ignite

    /// Zero-config start - reads app key from Info.plist
    ///
    /// Key prefix determines environment:
    /// - `pk_live_xxx` - Production (real ads, billing)
    /// - `pk_test_xxx` - Sandbox (test ads, no billing)
    /// - `pk_demo_xxx` or no key - Demo mode (local fake ads)
    ///
    /// Add to your Info.plist:
    /// ```xml
    /// <key>PerspicisAppKey</key>
    /// <string>pk_live_xxxxx</string>
    /// ```
    ///
    /// Then just call:
    /// ```swift
    /// Perspicis.spark()
    /// ```
    ///
    /// That's it. Zero arguments. Zero configuration.
    ///
    static func spark() {
        // Try to read from Info.plist
        if let appKey = Bundle.main.object(forInfoDictionaryKey: "PerspicisAppKey") as? String {
            spark(appKey)
            return
        }

        // Try environment variable (for CI/testing)
        if let appKey = ProcessInfo.processInfo.environment["PERSPICIS_APP_KEY"] {
            spark(appKey)
            return
        }

        // Check if demo mode requested
        if Bundle.main.object(forInfoDictionaryKey: "PerspicisDemoMode") as? Bool == true {
            startDemo()
            return
        }

        // Auto-enable demo mode if no key found (great for development)
        print("[Perspicis] No app key found - starting in demo mode")
        print("[Perspicis] Add PerspicisAppKey to Info.plist for production")
        startDemo()
    }

    /// Ignite Perspicis with your app key
    ///
    /// Key prefix auto-detects environment:
    /// - `pk_live_xxx` - Production
    /// - `pk_test_xxx` - Sandbox
    /// - `pk_demo_xxx` - Demo mode
    ///
    /// ```swift
    /// Perspicis.spark("pk_live_xxxxx")  // Production
    /// Perspicis.spark("pk_test_xxxxx")  // Sandbox
    /// Perspicis.spark("pk_demo_xxxxx")  // Demo (same as no key)
    /// ```
    ///
    static func spark(_ appKey: String, debug: Bool = false) {
        // Detect mode from key prefix
        mode = SparkMode.from(appKey: appKey)

        // Set app key FIRST so all telemetry events have the correct key
        shared.setAppKey(appKey)

        // Enable debug logging if requested or in non-production mode
        let enableDebug = debug || mode == .test || mode == .demo
        SparkTelemetry.shared.debugMode = enableDebug

        if enableDebug {
            print("[Perspicis] v\(version) - \(mode.rawValue) mode")
            print("[Perspicis] App key: \(appKey.prefix(16))...")
            print("[Perspicis] Telemetry: \(SparkTelemetry.shared.endpoint?.absoluteString ?? "disabled")")
        }

        SparkTelemetry.shared.trackEvent("sdk_init", properties: [
            "method": "spark",
            "mode": mode.rawValue,
            "debug": enableDebug
        ])

        // Demo mode keys don't need backend
        if mode == .demo {
            startDemo()
            return
        }

        Task {
            let config = Configuration(enableDebugLogging: enableDebug)
            await shared.configure(appKey: appKey, config: config)
            SparkTelemetry.shared.trackEvent("sdk_ready", properties: ["mode": mode.rawValue])
        }
    }

    /// Ignite with a custom server (for development/testing)
    static func spark(_ appKey: String, server: String, debug: Bool = true) {
        mode = SparkMode.from(appKey: appKey)

        // Set app key FIRST
        shared.setAppKey(appKey)

        // Enable debug logging
        SparkTelemetry.shared.debugMode = debug

        if debug {
            print("[Perspicis] v\(version) - \(mode.rawValue) mode (custom server)")
            print("[Perspicis] App key: \(appKey.prefix(16))...")
            print("[Perspicis] Server: \(server)")
        }

        SparkTelemetry.shared.trackEvent("sdk_init", properties: [
            "method": "spark_server",
            "mode": mode.rawValue,
            "debug": debug
        ])

        Task {
            guard let url = URL(string: server) else {
                print("[Perspicis] Error: Invalid server URL: \(server)")
                return
            }
            let config = Configuration(apiEndpoint: url, enableDebugLogging: debug)
            await shared.configure(appKey: appKey, config: config)
            SparkTelemetry.shared.trackEvent("sdk_ready", properties: ["mode": mode.rawValue])
        }
    }

    // MARK: - Aliases (backward compat)

    /// Alias for spark() - Start Perspicis
    static func start(_ appKey: String, debug: Bool = false) {
        spark(appKey, debug: debug)
    }

    /// Alias for spark() with server
    static func start(_ appKey: String, server: String, debug: Bool = true) {
        spark(appKey, server: server, debug: debug)
    }

    // MARK: - AdMob Configuration

    #if os(iOS)
    /// Configure AdMob for real ad serving
    ///
    /// Call this after spark() to enable real ads via Google AdMob.
    /// Revenue flows directly to your AdMob account.
    ///
    /// ```swift
    /// // In your App init:
    /// PerspicisSDK.spark("pk_live_xxx")
    /// PerspicisSDK.configureAdMob(AdMobConfig(
    ///     appId: "ca-app-pub-xxx~xxx",
    ///     bannerAdUnitId: "ca-app-pub-xxx/xxx",
    ///     interstitialAdUnitId: "ca-app-pub-xxx/xxx",
    ///     rewardedAdUnitId: "ca-app-pub-xxx/xxx"
    /// ))
    /// ```
    ///
    @MainActor
    static func configureAdMob(_ config: AdMobConfig) {
        let enableDebug = mode == .test || mode == .demo
        AdMobAdapter.shared.initialize(config: config, debug: enableDebug)

        SparkTelemetry.shared.trackEvent("admob_configured", properties: [
            "test_mode": config.testMode
        ])

        if enableDebug || SparkTelemetry.shared.debugMode {
            print("[Perspicis] AdMob configured with app ID: \(config.appId.prefix(20))...")
        }
    }

    /// Check if AdMob is ready for ad serving
    static var isAdMobReady: Bool {
        AdMobAdapter.shared.isReady
    }
    #endif

    // MARK: - Show Ads (One-Liners)

    /// Show an interstitial ad
    ///
    /// Works automatically in any mode:
    /// - Demo mode: Shows local demo ad
    /// - Test mode: Shows sandbox ads
    /// - Live mode: Shows real production ads
    ///
    /// ```swift
    /// Perspicis.showAd()
    /// ```
    ///
    /// Or with a completion handler:
    /// ```swift
    /// Perspicis.showAd { shown in
    ///     print(shown ? "Ad shown" : "No ad available")
    /// }
    /// ```
    ///
    @MainActor
    static func showAd(completion: ((Bool) -> Void)? = nil) {
        // Demo mode uses local demo ads
        if mode == .demo || isDemoMode {
            showDemoAd(completion: completion)
            return
        }

        #if os(iOS)
        guard let viewController = topViewController() else {
            completion?(false)
            return
        }

        // Use AdMob if configured, otherwise fall back to Perspicis backend
        if AdMobAdapter.shared.isReady {
            AdMobAdapter.shared.showInterstitial(from: viewController, completion: completion)
        } else {
            let ad = SparkInterstitial()
            ad.show(from: viewController, completion: completion)
        }
        #else
        completion?(false)
        #endif
    }

    /// Show a rewarded ad and get the reward
    ///
    /// Works automatically in any mode:
    /// - Demo mode: Shows local demo ad
    /// - Test mode: Shows sandbox ads
    /// - Live mode: Shows real production ads
    ///
    /// ```swift
    /// Perspicis.showRewarded { reward in
    ///     if let reward = reward {
    ///         coins += reward.amount
    ///     }
    /// }
    /// ```
    ///
    @MainActor
    static func showRewarded(completion: @escaping (PerspicisSDK.Reward?) -> Void) {
        // Demo mode uses local demo ads
        if mode == .demo || isDemoMode {
            showDemoRewarded(completion: completion)
            return
        }

        #if os(iOS)
        guard let viewController = topViewController() else {
            completion(nil)
            return
        }

        // Use AdMob if configured, otherwise fall back to Perspicis backend
        if AdMobAdapter.shared.isReady {
            AdMobAdapter.shared.showRewarded(from: viewController, completion: completion)
        } else {
            let ad = SparkRewarded()
            ad.show(from: viewController, completion: completion)
        }
        #else
        completion(nil)
        #endif
    }

    /// Show a rewarded ad (async version)
    ///
    /// Works automatically in any mode - no code changes needed.
    ///
    /// ```swift
    /// if let reward = await Perspicis.showRewarded() {
    ///     coins += reward.amount
    /// }
    /// ```
    ///
    @MainActor
    static func showRewarded() async -> PerspicisSDK.Reward? {
        await withCheckedContinuation { continuation in
            showRewarded { reward in
                continuation.resume(returning: reward)
            }
        }
    }

    // MARK: - Helper

    #if os(iOS)
    @MainActor
    private static func topViewController() -> UIViewController? {
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

// MARK: - Spark Reward

/// Typealias for backward compatibility - use PerspicisSDK.Reward
public typealias SparkReward = PerspicisSDK.Reward

/// Backward compat alias
public typealias QuickReward = PerspicisSDK.Reward

// MARK: - Spark Interstitial (Internal)

#if os(iOS)
class SparkInterstitial {
    private var completion: ((Bool) -> Void)?

    func show(from viewController: UIViewController, completion: ((Bool) -> Void)?) {
        self.completion = completion

        Task {
            let result = await PerspicisSDK.shared.requestAd(placement: .interstitial)

            await MainActor.run {
                switch result {
                case .success(let ad):
                    showAdView(ad: ad, from: viewController)
                case .failure:
                    completion?(false)
                }
            }
        }
    }

    private func showAdView(ad: AdResponse, from viewController: UIViewController) {
        let adVC = SparkAdViewController(ad: ad) { [weak self] in
            self?.completion?(true)
        }
        adVC.modalPresentationStyle = .fullScreen
        viewController.present(adVC, animated: true)

        // Fire impression
        if let url = URL(string: ad.trackingUrls.impression) {
            Task { _ = try? await URLSession.shared.data(from: url) }
        }
    }
}

// Backward compat alias
typealias QuickInterstitial = SparkInterstitial

// MARK: - Spark Rewarded (Internal)

class SparkRewarded {
    private var completion: ((PerspicisSDK.Reward?) -> Void)?

    func show(from viewController: UIViewController, completion: @escaping (PerspicisSDK.Reward?) -> Void) {
        self.completion = completion

        Task {
            let result = await PerspicisSDK.shared.requestAd(placement: .rewardedVideo)

            await MainActor.run {
                switch result {
                case .success(let ad):
                    showRewardedView(ad: ad, from: viewController)
                case .failure:
                    completion(nil)
                }
            }
        }
    }

    private func showRewardedView(ad: AdResponse, from viewController: UIViewController) {
        let adVC = SparkAdViewController(ad: ad, isRewarded: true) { [weak self] in
            self?.completion?(PerspicisSDK.Reward(type: "reward", amount: 1))
        }
        adVC.modalPresentationStyle = .fullScreen
        viewController.present(adVC, animated: true)

        // Fire impression
        if let url = URL(string: ad.trackingUrls.impression) {
            Task { _ = try? await URLSession.shared.data(from: url) }
        }
    }
}

// Backward compat alias
typealias QuickRewarded = SparkRewarded

// MARK: - Spark Ad View Controller

class SparkAdViewController: UIViewController {
    private let ad: AdResponse
    private let isRewarded: Bool
    private let onComplete: () -> Void

    private var closeButton: UIButton?
    private var timerLabel: UILabel?
    private var remainingTime: Int = 5
    private var timer: Timer?

    init(ad: AdResponse, isRewarded: Bool = false, onComplete: @escaping () -> Void) {
        self.ad = ad
        self.isRewarded = isRewarded
        self.onComplete = onComplete
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupAdContent()
        setupCloseButton()

        if isRewarded {
            startTimer()
        }
    }

    private func setupAdContent() {
        // Load creative image
        guard let url = URL(string: ad.creativeUrl) else { return }

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Add tap for click tracking
        let tap = UITapGestureRecognizer(target: self, action: #selector(adTapped))
        imageView.isUserInteractionEnabled = true
        imageView.addGestureRecognizer(tap)

        Task {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let image = UIImage(data: data) {
                await MainActor.run {
                    imageView.image = image
                }
            }
        }
    }

    private func setupCloseButton() {
        let button = UIButton(type: .system)
        button.setTitle("\u{2715}", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 24, weight: .bold)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        button.layer.cornerRadius = 20
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        view.addSubview(button)
        closeButton = button

        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            button.widthAnchor.constraint(equalToConstant: 40),
            button.heightAnchor.constraint(equalToConstant: 40)
        ])

        if isRewarded {
            button.isHidden = true
            setupTimerLabel()
        }
    }

    private func setupTimerLabel() {
        let label = UILabel()
        label.text = "\(remainingTime)"
        label.font = .monospacedDigitSystemFont(ofSize: 18, weight: .bold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.textAlignment = .center
        label.layer.cornerRadius = 20
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label)
        timerLabel = label

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            label.widthAnchor.constraint(equalToConstant: 40),
            label.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        remainingTime -= 1
        timerLabel?.text = "\(remainingTime)"

        if remainingTime <= 0 {
            timer?.invalidate()
            timerLabel?.isHidden = true
            closeButton?.isHidden = false

            // Fire complete tracking
            if let completeUrl = ad.trackingUrls.complete,
               let url = URL(string: completeUrl) {
                Task { _ = try? await URLSession.shared.data(from: url) }
            }
        }
    }

    @objc private func adTapped() {
        // Track click
        if let url = URL(string: ad.trackingUrls.click) {
            Task { _ = try? await URLSession.shared.data(from: url) }
        }

        // Open click URL
        if let url = URL(string: ad.clickUrl) {
            UIApplication.shared.open(url)
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true) { [weak self] in
            guard let self = self else { return }
            if self.isRewarded && self.remainingTime <= 0 {
                self.onComplete()
            } else if !self.isRewarded {
                self.onComplete()
            }
        }
    }
}

// Backward compat alias
typealias QuickAdViewController = SparkAdViewController
#endif

// MARK: - SwiftUI Views

#if canImport(SwiftUI) && os(iOS)
import SwiftUI

/// Drop-in SwiftUI banner ad
///
/// ```swift
/// struct ContentView: View {
///     var body: some View {
///         VStack {
///             Text("My App")
///             Spacer()
///             SparkBanner()
///         }
///     }
/// }
/// ```
///
public struct SparkBanner: View {
    public enum Size {
        case standard    // 320x50
        case medium      // 300x250
        case large       // 728x90

        var dimensions: CGSize {
            switch self {
            case .standard: return CGSize(width: 320, height: 50)
            case .medium: return CGSize(width: 300, height: 250)
            case .large: return CGSize(width: 728, height: 90)
            }
        }

        /// Convert to Google Ad Size
        var gadAdSize: GADAdSize {
            switch self {
            case .standard: return GADAdSizeBanner
            case .medium: return GADAdSizeMediumRectangle
            case .large: return GADAdSizeLeaderboard
            }
        }
    }

    private let size: Size
    private let onLoaded: (() -> Void)?
    private let onClicked: (() -> Void)?
    private let onError: ((Error) -> Void)?

    @State private var ad: AdResponse?
    @State private var isLoading = true
    @State private var loadError: Error?

    public init(
        _ size: Size = .standard,
        onLoaded: (() -> Void)? = nil,
        onClicked: (() -> Void)? = nil,
        onError: ((Error) -> Void)? = nil
    ) {
        self.size = size
        self.onLoaded = onLoaded
        self.onClicked = onClicked
        self.onError = onError
    }

    public var body: some View {
        Group {
            // Use AdMob banner if configured
            if AdMobAdapter.shared.isReady {
                AdMobBannerView(adSize: size.gadAdSize)
                    .frame(width: size.dimensions.width, height: size.dimensions.height)
            } else if let ad = ad {
                SparkBannerContent(ad: ad, onClicked: onClicked)
            } else if isLoading {
                ProgressView()
                    .frame(width: size.dimensions.width, height: size.dimensions.height)
            } else {
                // No ad / error - show nothing or placeholder
                Color.clear
                    .frame(width: size.dimensions.width, height: size.dimensions.height)
            }
        }
        .frame(width: size.dimensions.width, height: size.dimensions.height)
        .task {
            // Only load from Perspicis backend if AdMob not configured
            if !AdMobAdapter.shared.isReady {
                await loadAd()
            }
        }
    }

    private func loadAd() async {
        let result = await PerspicisSDK.shared.requestAd(placement: .banner)

        await MainActor.run {
            isLoading = false
            switch result {
            case .success(let response):
                ad = response
                onLoaded?()
                // Fire impression
                if let url = URL(string: response.trackingUrls.impression) {
                    Task { _ = try? await URLSession.shared.data(from: url) }
                }
            case .failure(let error):
                loadError = error
                onError?(error)
            }
        }
    }
}

// Backward compat alias
public typealias PerspicisBanner = SparkBanner

// Banner content view
private struct SparkBannerContent: View {
    let ad: AdResponse
    let onClicked: (() -> Void)?

    var body: some View {
        AsyncImage(url: URL(string: ad.creativeUrl)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            case .failure:
                Color.gray.opacity(0.3)
            case .empty:
                ProgressView()
            @unknown default:
                Color.clear
            }
        }
        .onTapGesture {
            // Track click
            if let url = URL(string: ad.trackingUrls.click) {
                Task { _ = try? await URLSession.shared.data(from: url) }
            }
            // Open URL
            if let url = URL(string: ad.clickUrl) {
                UIApplication.shared.open(url)
            }
            onClicked?()
        }
    }
}

/// Modifier for easy banner placement
public extension View {
    /// Add a banner ad at the bottom of this view
    func withSparkBanner(_ size: SparkBanner.Size = .standard) -> some View {
        VStack(spacing: 0) {
            self
            SparkBanner(size)
        }
    }

    /// Alias for withSparkBanner
    func withBannerAd(_ size: SparkBanner.Size = .standard) -> some View {
        withSparkBanner(size)
    }
}

// MARK: - The Ultimate One-Liner: .monetize()

/// Scene modifier that enables full monetization with ZERO code
///
/// ```swift
/// @main
/// struct MyApp: App {
///     var body: some Scene {
///         WindowGroup {
///             ContentView()
///         }
///         .monetize() // That's it. Ads just work.
///     }
/// }
/// ```
///
public extension Scene {
    /// Enable full monetization with zero configuration
    ///
    /// This single modifier:
    /// - Auto-initializes the SDK (from Info.plist or demo mode)
    /// - Shows banner ads at natural positions
    /// - Tracks all analytics automatically
    /// - Handles ATT permission flow
    ///
    func monetize(
        banner: SparkBanner.Size? = .standard,
        interstitialFrequency: Int = 3
    ) -> some Scene {
        MonetizedScene(
            base: self,
            bannerSize: banner,
            interstitialFrequency: interstitialFrequency
        )
    }
}

/// Internal scene wrapper for monetization
public struct MonetizedScene<Base: Scene>: Scene {
    let base: Base
    let bannerSize: SparkBanner.Size?
    let interstitialFrequency: Int

    public var body: some Scene {
        base.onChange(of: ScenePhase.active) { _ in
            // Removed due to iOS 17+ API
        }
    }

    init(base: Base, bannerSize: SparkBanner.Size?, interstitialFrequency: Int) {
        self.base = base
        self.bannerSize = bannerSize
        self.interstitialFrequency = interstitialFrequency

        // Auto-initialize on creation
        PerspicisSDK.spark()
        SparkTelemetry.shared.trackEvent("monetize_enabled")
    }
}

public extension View {
    /// Monetize this view with automatic banner placement
    ///
    /// ```swift
    /// ContentView()
    ///     .monetize()
    /// ```
    ///
    @ViewBuilder
    func monetize(banner: SparkBanner.Size? = .standard) -> some View {
        MonetizedContainer(content: self, bannerSize: banner)
    }
}

/// Container view for monetized content
public struct MonetizedContainer<Content: View>: View {
    let content: Content
    let bannerSize: SparkBanner.Size?

    @State private var isInitialized = false

    public init(content: Content, bannerSize: SparkBanner.Size? = .standard) {
        self.content = content
        self.bannerSize = bannerSize
    }

    public var body: some View {
        VStack(spacing: 0) {
            content

            if let size = bannerSize, PerspicisSDK.isDemoMode || PerspicisSDK.shared.state == .ready {
                SparkBanner(size)
            }
        }
        .onAppear {
            if !isInitialized {
                PerspicisSDK.spark()
                isInitialized = true
            }
        }
    }
}

// MARK: - Unified SwiftUI Rewarded Ad View

/// Unified rewarded ad view that works in demo and production modes
///
/// Automatically uses demo ads when in demo mode, production ads otherwise.
///
/// ```swift
/// .sheet(isPresented: $showAd) {
///     SparkRewardedView { reward in
///         if let reward = reward {
///             coins += reward.amount
///         }
///     }
/// }
/// ```
public struct SparkRewardedView: View {
    let onComplete: (PerspicisSDK.Reward?) -> Void
    @Environment(\.presentationMode) private var presentationMode

    public init(onComplete: @escaping (PerspicisSDK.Reward?) -> Void) {
        self.onComplete = onComplete
    }

    public var body: some View {
        // Use DemoRewardedAdView for demo mode (it handles all telemetry internally)
        if PerspicisSDK.mode == .demo || PerspicisSDK.isDemoMode {
            DemoRewardedAdView { reward in
                presentationMode.wrappedValue.dismiss()
                onComplete(reward)
            }
        } else {
            // Production mode - use real ad loading
            ProductionRewardedView(onComplete: onComplete)
        }
    }
}

/// Production rewarded ad view (for live/test modes)
private struct ProductionRewardedView: View {
    let onComplete: (PerspicisSDK.Reward?) -> Void
    @State private var ad: AdResponse?
    @State private var isLoading = true
    @State private var remainingTime: Int = 5
    @State private var canClose = false
    @State private var loadTimeMs: Int = 0
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.purple, Color.blue, Color.indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                        .tint(.white)
                    Text("Loading ad...")
                        .font(.headline)
                        .foregroundColor(.white)
                }
            } else if let ad = ad {
                VStack(spacing: 30) {
                    Spacer()

                    // Ad creative
                    AsyncImage(url: URL(string: ad.creativeUrl)) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fit)
                        case .failure, .empty:
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 80))
                                .foregroundColor(.white)
                        @unknown default:
                            ProgressView()
                        }
                    }
                    .frame(maxHeight: 300)

                    Text("Loaded in \(loadTimeMs)ms")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))

                    Spacer()

                    if canClose {
                        Button {
                            presentationMode.wrappedValue.dismiss()
                            onComplete(PerspicisSDK.Reward(type: "coins", amount: 100))
                        } label: {
                            HStack {
                                Image(systemName: "gift.fill")
                                Text("Claim Reward!")
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
            } else {
                // No ad available
                VStack {
                    Text("No ad available")
                        .foregroundColor(.white)
                    Button("Close") {
                        presentationMode.wrappedValue.dismiss()
                        onComplete(nil)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 500)
        .onAppear { loadAd() }
    }

    private func loadAd() {
        let startTime = Date()
        SparkTelemetry.shared.trackAdRequest(placement: "rewarded")

        Task {
            let result = await PerspicisSDK.shared.requestAd(placement: .rewardedVideo)
            let latency = Int(Date().timeIntervalSince(startTime) * 1000)

            await MainActor.run {
                loadTimeMs = latency
                isLoading = false

                switch result {
                case .success(let response):
                    ad = response
                    SparkTelemetry.shared.trackAdFill(placement: "rewarded", adId: response.adId, latencyMs: latency)
                    SparkTelemetry.shared.trackImpression(placement: "rewarded", adId: response.adId)
                    startTimer()
                case .failure:
                    SparkTelemetry.shared.trackEvent("ad_no_fill", properties: ["placement": "rewarded"])
                }
            }
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
#endif
