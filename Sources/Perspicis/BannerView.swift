//
//  BannerView.swift
//  Perspicis
//
//  Banner ad display component
//  US-3.1, US-3.2, US-3.3
//

#if os(iOS)
import UIKit
import WebKit

// MARK: - Banner Size

/// Supported banner ad sizes
public enum BannerSize: String, CaseIterable {
    case standard    // 320x50
    case mediumRect  // 300x250
    case leaderboard // 728x90

    /// Banner dimensions in points
    public var dimensions: CGSize {
        switch self {
        case .standard:
            return CGSize(width: 320, height: 50)
        case .mediumRect:
            return CGSize(width: 300, height: 250)
        case .leaderboard:
            return CGSize(width: 728, height: 90)
        }
    }

    /// Human-readable description
    public var description: String {
        switch self {
        case .standard: return "320x50"
        case .mediumRect: return "300x250"
        case .leaderboard: return "728x90"
        }
    }
}

// MARK: - Banner Position

/// Banner positioning options
public enum BannerPosition {
    case top
    case bottom
    case custom
}

// MARK: - Banner Configuration

/// Configuration options for banner ads
public struct BannerConfiguration {
    public var size: BannerSize
    public var position: BannerPosition
    public var refreshInterval: Int  // seconds, 0 = disabled
    public var showCloseButton: Bool
    public var backgroundColor: UIColor
    public var margins: UIEdgeInsets

    public init(
        size: BannerSize = .standard,
        position: BannerPosition = .bottom,
        refreshInterval: Int = 60,
        showCloseButton: Bool = false,
        backgroundColor: UIColor = .clear,
        margins: UIEdgeInsets = .zero
    ) {
        self.size = size
        self.position = position
        self.refreshInterval = Self.clampRefreshInterval(refreshInterval)
        self.showCloseButton = showCloseButton
        self.backgroundColor = backgroundColor
        self.margins = margins
    }

    /// Clamps refresh interval to valid range (0 or 30-120)
    private static func clampRefreshInterval(_ interval: Int) -> Int {
        if interval == 0 { return 0 }  // Disabled
        return max(30, min(120, interval))
    }
}

// MARK: - Banner Delegate

/// Delegate protocol for banner lifecycle events
public protocol PerspicisBannerViewDelegate: AnyObject {
    func bannerDidLoad(_ banner: PerspicisBannerView)
    func banner(_ banner: PerspicisBannerView, didFailToLoadWithError error: Error)
    func bannerDidRecordImpression(_ banner: PerspicisBannerView)
    func bannerDidRecordClick(_ banner: PerspicisBannerView)
    func bannerWillPresentScreen(_ banner: PerspicisBannerView)
    func bannerDidDismissScreen(_ banner: PerspicisBannerView)
    func bannerDidClose(_ banner: PerspicisBannerView)
}

// Default implementations (all optional)
public extension PerspicisBannerViewDelegate {
    func bannerDidLoad(_ banner: PerspicisBannerView) {}
    func banner(_ banner: PerspicisBannerView, didFailToLoadWithError error: Error) {}
    func bannerDidRecordImpression(_ banner: PerspicisBannerView) {}
    func bannerDidRecordClick(_ banner: PerspicisBannerView) {}
    func bannerWillPresentScreen(_ banner: PerspicisBannerView) {}
    func bannerDidDismissScreen(_ banner: PerspicisBannerView) {}
    func bannerDidClose(_ banner: PerspicisBannerView) {}
}

// MARK: - Banner Ad Service Protocol

/// Protocol for banner ad service dependency injection
public protocol BannerAdServiceProtocol {
    func requestAd(_ request: BannerAdRequest) async throws -> BannerAdResponse
}

// MARK: - Banner Ad Request/Response

/// Request for a banner ad
public struct BannerAdRequest {
    public let appKey: String
    public let placement: String
    public let cohorts: [String]
    public let adSize: CGSize

    public init(appKey: String, placement: String, cohorts: [String], adSize: CGSize) {
        self.appKey = appKey
        self.placement = placement
        self.cohorts = cohorts
        self.adSize = adSize
    }
}

/// Response containing banner ad data
public struct BannerAdResponse {
    public let success: Bool
    public let auctionId: String
    public let campaignId: String
    public let creativeId: String
    public let creativeType: CreativeType
    public let creativeUrl: String?
    public let htmlContent: String?
    public let clickUrl: String
    public let impressionUrl: String
    public let width: Int
    public let height: Int

    public init(
        success: Bool,
        auctionId: String,
        campaignId: String,
        creativeId: String,
        creativeType: CreativeType,
        creativeUrl: String? = nil,
        htmlContent: String? = nil,
        clickUrl: String,
        impressionUrl: String,
        width: Int,
        height: Int
    ) {
        self.success = success
        self.auctionId = auctionId
        self.campaignId = campaignId
        self.creativeId = creativeId
        self.creativeType = creativeType
        self.creativeUrl = creativeUrl
        self.htmlContent = htmlContent
        self.clickUrl = clickUrl
        self.impressionUrl = impressionUrl
        self.width = width
        self.height = height
    }
}

/// Creative types
public enum CreativeType: String {
    case image
    case html
}

// MARK: - Banner View

/// A view that displays banner advertisements
public class PerspicisBannerView: UIView {

    // MARK: - Public Properties

    /// Delegate for receiving banner events
    public weak var delegate: PerspicisBannerViewDelegate?

    /// Banner configuration
    public let configuration: BannerConfiguration

    /// Ad service (injectable for testing)
    public var adService: BannerAdServiceProtocol?

    /// Whether the banner is currently loading
    public var isLoading: Bool {
        return state == .loading
    }

    /// Whether the banner has loaded an ad
    public var isLoaded: Bool {
        return state == .loaded || state == .displaying
    }

    /// Current ad data
    public private(set) var currentAd: BannerAdResponse?

    /// Convenience accessors
    public var bannerSize: BannerSize { configuration.size }
    public var position: BannerPosition { configuration.position }
    public var refreshInterval: Int { configuration.refreshInterval }
    public var showsCloseButton: Bool { configuration.showCloseButton }

    /// Whether auto-refresh is currently active
    public var isAutoRefreshEnabled: Bool {
        return refreshTimer != nil && configuration.refreshInterval > 0
    }

    // MARK: - Private Properties

    private enum State {
        case idle
        case loading
        case loaded
        case displaying
        case failed
    }

    private var state: State = .idle
    private var contentView: UIView?
    private var closeButton: UIButton?
    private var refreshTimer: Timer?
    private var impressionTracked = false

    // MARK: - Initialization

    /// Initialize with configuration
    public init(configuration: BannerConfiguration) {
        self.configuration = configuration
        super.init(frame: CGRect(origin: .zero, size: configuration.size.dimensions))
        setupView()
    }

    /// Convenience initializer with size only
    public convenience init(size: BannerSize) {
        self.init(configuration: BannerConfiguration(size: size))
    }

    /// Convenience initializer with size and position
    public convenience init(size: BannerSize, position: BannerPosition) {
        self.init(configuration: BannerConfiguration(size: size, position: position))
    }

    /// Convenience initializer with size, position, and refresh
    public convenience init(size: BannerSize, position: BannerPosition = .bottom, refreshInterval: Int) {
        self.init(configuration: BannerConfiguration(
            size: size,
            position: position,
            refreshInterval: refreshInterval
        ))
    }

    required init?(coder: NSCoder) {
        self.configuration = BannerConfiguration()
        super.init(coder: coder)
        setupView()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupView() {
        backgroundColor = configuration.backgroundColor
        clipsToBounds = true
        isHidden = true  // Hidden until ad loads

        if configuration.showCloseButton {
            setupCloseButton()
        }
    }

    private func setupCloseButton() {
        let button = UIButton(type: .system)
        button.setTitle("✕", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        button.tintColor = .darkGray
        button.backgroundColor = UIColor.white.withAlphaComponent(0.8)
        button.layer.cornerRadius = 10
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        addSubview(button)
        closeButton = button

        // Position in top-right corner
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    // MARK: - Intrinsic Size

    public override var intrinsicContentSize: CGSize {
        return configuration.size.dimensions
    }

    // MARK: - Public API

    /// Load an ad into the banner
    public func loadAd() {
        guard state != .loading else {
            print("[Perspicis] Banner already loading, ignoring request")
            return
        }

        state = .loading
        impressionTracked = false

        // Get cohorts for targeting (empty for now, will be populated async)
        let cohorts: [String] = []

        // Build request
        let request = BannerAdRequest(
            appKey: PerspicisSDK.shared.currentAppKey ?? "",
            placement: "banner",
            cohorts: cohorts,
            adSize: configuration.size.dimensions
        )

        // Use injected service or default
        let service = adService ?? DefaultAdService.shared

        Task {
            do {
                let response = try await service.requestAd(request)
                await MainActor.run {
                    handleAdResponse(response)
                }
            } catch {
                await MainActor.run {
                    handleAdError(error)
                }
            }
        }
    }

    /// Stop auto-refresh
    public func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Simulate close button tap (for testing)
    internal func simulateCloseTap() {
        closeTapped()
    }

    // MARK: - Response Handling

    private func handleAdResponse(_ response: BannerAdResponse) {
        guard response.success else {
            handleNoFill()
            return
        }

        currentAd = response
        renderAd(response)
    }

    private func handleAdError(_ error: Error) {
        state = .failed
        delegate?.banner(self, didFailToLoadWithError: error)
        print("[Perspicis] Banner load failed: \(error)")
    }

    private func handleNoFill() {
        state = .failed
        delegate?.banner(self, didFailToLoadWithError: PerspicisError.noFill)
        print("[Perspicis] Banner no fill")
    }

    // MARK: - Rendering

    private func renderAd(_ ad: BannerAdResponse) {
        // Remove old content
        contentView?.removeFromSuperview()

        switch ad.creativeType {
        case .image:
            renderImageAd(ad)
        case .html:
            renderHtmlAd(ad)
        }
    }

    private func renderImageAd(_ ad: BannerAdResponse) {
        guard let urlString = ad.creativeUrl, let url = URL(string: urlString) else {
            handleAdError(PerspicisError.invalidCreative)
            return
        }

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.frame = bounds

        // Load image asynchronously
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data) else {
                    throw PerspicisError.invalidCreative
                }

                await MainActor.run {
                    imageView.image = image
                    finishRender(imageView)
                }
            } catch {
                await MainActor.run {
                    handleAdError(error)
                }
            }
        }
    }

    private func renderHtmlAd(_ ad: BannerAdResponse) {
        guard let html = ad.htmlContent else {
            handleAdError(PerspicisError.invalidCreative)
            return
        }

        let webView = WKWebView(frame: bounds)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear

        webView.loadHTMLString(html, baseURL: nil)
        finishRender(webView)
    }

    private func finishRender(_ view: UIView) {
        contentView = view
        insertSubview(view, at: 0)  // Behind close button

        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Add tap gesture
        let tap = UITapGestureRecognizer(target: self, action: #selector(adTapped))
        view.addGestureRecognizer(tap)
        view.isUserInteractionEnabled = true

        // Update state
        state = .displaying
        isHidden = false

        // Notify delegate
        delegate?.bannerDidLoad(self)

        // Start refresh timer
        startRefreshTimer()

        print("[Perspicis] Banner rendered successfully")
    }

    // MARK: - Refresh

    private func startRefreshTimer() {
        guard configuration.refreshInterval >= 30 else { return }

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            timeInterval: TimeInterval(configuration.refreshInterval),
            target: self,
            selector: #selector(refreshTimerFired),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func refreshTimerFired() {
        print("[Perspicis] Banner refresh triggered")
        loadAd()
    }

    // MARK: - Actions

    @objc private func adTapped() {
        guard let ad = currentAd else { return }

        // Track click
        trackClick(ad)

        // Open destination
        if let url = URL(string: ad.clickUrl) {
            delegate?.bannerWillPresentScreen(self)
            UIApplication.shared.open(url)
        }
    }

    @objc private func closeTapped() {
        stopAutoRefresh()
        isHidden = true
        state = .idle
        delegate?.bannerDidClose(self)
    }

    // MARK: - Tracking

    private func trackImpression(_ ad: BannerAdResponse) {
        guard !impressionTracked else { return }
        impressionTracked = true

        // Fire impression pixel
        if let url = URL(string: ad.impressionUrl) {
            Task {
                _ = try? await URLSession.shared.data(from: url)
            }
        }

        delegate?.bannerDidRecordImpression(self)
        print("[Perspicis] Banner impression tracked")
    }

    private func trackClick(_ ad: BannerAdResponse) {
        // Fire click pixel
        let clickUrl = ad.clickUrl.replacingOccurrences(
            of: "{timestamp}",
            with: "\(Date().timeIntervalSince1970)"
        )

        if let url = URL(string: clickUrl) {
            Task {
                _ = try? await URLSession.shared.data(from: url)
            }
        }

        delegate?.bannerDidRecordClick(self)
        print("[Perspicis] Banner click tracked")
    }
}

// MARK: - Default Ad Service

/// Default implementation that calls the Perspicis backend
class DefaultAdService: BannerAdServiceProtocol {
    static let shared = DefaultAdService()

    private init() {}

    func requestAd(_ request: BannerAdRequest) async throws -> BannerAdResponse {
        // Build URL
        guard let baseUrl = PerspicisSDK.shared.serverUrl,
              var components = URLComponents(string: "\(baseUrl)/v1/ads/request") else {
            throw PerspicisError.configurationError
        }

        // Build request body
        let body: [String: Any] = [
            "app_key": request.appKey,
            "placement": request.placement,
            "cohorts": request.cohorts,
            "ad_size": ["width": Int(request.adSize.width), "height": Int(request.adSize.height)]
        ]

        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw PerspicisError.noFill
        }

        // Parse response
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let auctionId = json?["auction_id"] as? String,
              let ad = json?["ad"] as? [String: Any],
              let campaignId = ad["campaign_id"] as? String,
              let creative = ad["creative"] as? [String: Any],
              let creativeId = creative["id"] as? String else {
            throw PerspicisError.noFill
        }

        let creativeType: CreativeType = (creative["type"] as? String) == "html" ? .html : .image

        return BannerAdResponse(
            success: true,
            auctionId: auctionId,
            campaignId: campaignId,
            creativeId: creativeId,
            creativeType: creativeType,
            creativeUrl: creative["url"] as? String,
            htmlContent: creative["html"] as? String,
            clickUrl: ad["click_url"] as? String ?? "",
            impressionUrl: ad["impression_url"] as? String ?? "",
            width: Int(request.adSize.width),
            height: Int(request.adSize.height)
        )
    }
}

#endif
