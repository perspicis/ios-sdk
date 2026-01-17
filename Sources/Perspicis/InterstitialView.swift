//
//  InterstitialView.swift
//  Perspicis
//
//  Full-screen interstitial ad component
//  US-4.1, US-4.2, US-4.3
//

#if os(iOS)
import UIKit
import WebKit

// MARK: - Interstitial Configuration

/// Configuration options for interstitial ads
public struct InterstitialConfiguration {
    /// Delay before close button appears (seconds)
    public var closeButtonDelay: TimeInterval

    /// How long the ad remains valid before expiring (seconds)
    public var expirationTimeout: TimeInterval

    /// Alpha value for dimmed background
    public var dimmedBackgroundAlpha: CGFloat

    /// Size of close button
    public var closeButtonSize: CGSize

    /// Animation duration for transitions
    public var animationDuration: TimeInterval

    public init(
        closeButtonDelay: TimeInterval = 5.0,
        expirationTimeout: TimeInterval = 3600,
        dimmedBackgroundAlpha: CGFloat = 0.85,
        closeButtonSize: CGSize = CGSize(width: 44, height: 44),
        animationDuration: TimeInterval = 0.3
    ) {
        self.closeButtonDelay = closeButtonDelay
        self.expirationTimeout = expirationTimeout
        self.dimmedBackgroundAlpha = dimmedBackgroundAlpha
        self.closeButtonSize = closeButtonSize
        self.animationDuration = animationDuration
    }
}

// MARK: - Interstitial Delegate

/// Delegate protocol for interstitial lifecycle events
public protocol PerspicisInterstitialDelegate: AnyObject {
    // Load lifecycle
    func interstitialDidLoad(_ interstitial: PerspicisInterstitial)
    func interstitial(_ interstitial: PerspicisInterstitial, didFailToLoadWithError error: Error)

    // Show lifecycle
    func interstitialWillPresent(_ interstitial: PerspicisInterstitial)
    func interstitialDidPresent(_ interstitial: PerspicisInterstitial)
    func interstitial(_ interstitial: PerspicisInterstitial, didFailToShowWithError error: Error)

    // Dismiss lifecycle
    func interstitialWillDismiss(_ interstitial: PerspicisInterstitial)
    func interstitialDidDismiss(_ interstitial: PerspicisInterstitial)

    // Tracking
    func interstitialDidRecordImpression(_ interstitial: PerspicisInterstitial)
    func interstitialDidRecordClick(_ interstitial: PerspicisInterstitial)

    // Expiration
    func interstitialDidExpire(_ interstitial: PerspicisInterstitial)
}

// Default implementations (all optional)
public extension PerspicisInterstitialDelegate {
    func interstitialDidLoad(_ interstitial: PerspicisInterstitial) {}
    func interstitial(_ interstitial: PerspicisInterstitial, didFailToLoadWithError error: Error) {}
    func interstitialWillPresent(_ interstitial: PerspicisInterstitial) {}
    func interstitialDidPresent(_ interstitial: PerspicisInterstitial) {}
    func interstitial(_ interstitial: PerspicisInterstitial, didFailToShowWithError error: Error) {}
    func interstitialWillDismiss(_ interstitial: PerspicisInterstitial) {}
    func interstitialDidDismiss(_ interstitial: PerspicisInterstitial) {}
    func interstitialDidRecordImpression(_ interstitial: PerspicisInterstitial) {}
    func interstitialDidRecordClick(_ interstitial: PerspicisInterstitial) {}
    func interstitialDidExpire(_ interstitial: PerspicisInterstitial) {}
}

// MARK: - Interstitial Ad Data

/// Internal struct for storing loaded interstitial ad data
struct InterstitialAd {
    let auctionId: String
    let campaignId: String
    let creativeId: String
    let creativeType: CreativeType
    let creativeUrl: String?
    let htmlContent: String?
    let clickUrl: String
    let impressionUrl: String
    let loadedAt: Date
    let expiresAt: Date
}

// MARK: - Interstitial State

private enum InterstitialState {
    case idle
    case loading
    case ready
    case presenting
    case expired
    case failed
}

// MARK: - Perspicis Interstitial

/// A full-screen interstitial advertisement
public class PerspicisInterstitial {

    // MARK: - Public Properties

    /// Delegate for receiving interstitial events
    public weak var delegate: PerspicisInterstitialDelegate?

    /// Interstitial configuration
    public let configuration: InterstitialConfiguration

    /// Ad service (injectable for testing)
    public var adService: BannerAdServiceProtocol?

    /// Whether the interstitial is currently loading
    public var isLoading: Bool {
        return state == .loading
    }

    /// Whether the interstitial is ready to show
    public var isReady: Bool {
        return state == .ready
    }

    /// Whether the interstitial is currently presenting
    public var isPresenting: Bool {
        return state == .presenting
    }

    // MARK: - Private Properties

    private var state: InterstitialState = .idle
    private var currentAd: InterstitialAd?
    private var expirationTimer: Timer?
    private var impressionTracked = false
    private weak var presentingViewController: UIViewController?

    // MARK: - Initialization

    /// Initialize with configuration
    public init(configuration: InterstitialConfiguration = InterstitialConfiguration()) {
        self.configuration = configuration
    }

    deinit {
        expirationTimer?.invalidate()
    }

    // MARK: - Factory Methods

    /// Create a new interstitial with default configuration
    public static func create() -> PerspicisInterstitial {
        return PerspicisInterstitial()
    }

    /// Create a new interstitial with custom close button delay
    public static func create(closeButtonDelay: TimeInterval) -> PerspicisInterstitial {
        let config = InterstitialConfiguration(closeButtonDelay: closeButtonDelay)
        return PerspicisInterstitial(configuration: config)
    }

    // MARK: - Public API

    /// Load an interstitial ad
    public func loadAd() {
        guard state != .loading else {
            print("[Perspicis] Interstitial already loading, ignoring request")
            return
        }

        // Cancel any existing expiration timer
        expirationTimer?.invalidate()

        state = .loading
        impressionTracked = false

        // Get cohorts for targeting (empty for now, will be populated async)
        let cohorts: [String] = []

        // Build request
        let request = BannerAdRequest(
            appKey: PerspicisSDK.shared.currentAppKey ?? "",
            placement: "interstitial",
            cohorts: cohorts,
            adSize: UIScreen.main.bounds.size
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

    /// Show the interstitial ad
    public func show(from viewController: UIViewController) {
        guard state == .ready else {
            let error: Error
            if state == .expired {
                error = PerspicisError.adExpired
            } else {
                error = PerspicisError.adNotReady
            }
            delegate?.interstitial(self, didFailToShowWithError: error)
            print("[Perspicis] Cannot show interstitial: \(state)")
            return
        }

        guard let ad = currentAd else {
            delegate?.interstitial(self, didFailToShowWithError: PerspicisError.adNotReady)
            return
        }

        presentingViewController = viewController
        state = .presenting

        // Notify will present
        delegate?.interstitialWillPresent(self)

        // Create and present the interstitial view controller
        let interstitialVC = InterstitialViewController(
            ad: ad,
            configuration: configuration,
            delegate: self
        )
        interstitialVC.modalPresentationStyle = .overFullScreen
        interstitialVC.modalTransitionStyle = .crossDissolve

        viewController.present(interstitialVC, animated: true) { [weak self] in
            guard let self = self else { return }
            self.trackImpression(ad)
            self.delegate?.interstitialDidPresent(self)
        }
    }

    /// Check if the ad has expired
    public func isExpired() -> Bool {
        guard let ad = currentAd else { return false }
        return Date() > ad.expiresAt
    }

    // MARK: - Response Handling

    private func handleAdResponse(_ response: BannerAdResponse) {
        guard response.success else {
            handleNoFill()
            return
        }

        let now = Date()
        let expiresAt = now.addingTimeInterval(configuration.expirationTimeout)

        currentAd = InterstitialAd(
            auctionId: response.auctionId,
            campaignId: response.campaignId,
            creativeId: response.creativeId,
            creativeType: response.creativeType,
            creativeUrl: response.creativeUrl,
            htmlContent: response.htmlContent,
            clickUrl: response.clickUrl,
            impressionUrl: response.impressionUrl,
            loadedAt: now,
            expiresAt: expiresAt
        )

        state = .ready

        // Start expiration timer
        startExpirationTimer()

        delegate?.interstitialDidLoad(self)
        print("[Perspicis] Interstitial loaded: \(response.auctionId)")
    }

    private func handleAdError(_ error: Error) {
        state = .failed
        delegate?.interstitial(self, didFailToLoadWithError: error)
        print("[Perspicis] Interstitial load failed: \(error)")
    }

    private func handleNoFill() {
        state = .failed
        delegate?.interstitial(self, didFailToLoadWithError: PerspicisError.noFill)
        print("[Perspicis] Interstitial no fill")
    }

    // MARK: - Expiration

    private func startExpirationTimer() {
        expirationTimer?.invalidate()

        expirationTimer = Timer.scheduledTimer(
            timeInterval: configuration.expirationTimeout,
            target: self,
            selector: #selector(handleExpiration),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func handleExpiration() {
        guard state == .ready else { return }

        state = .expired
        currentAd = nil

        delegate?.interstitialDidExpire(self)
        print("[Perspicis] Interstitial expired")
    }

    // MARK: - Tracking

    private func trackImpression(_ ad: InterstitialAd) {
        guard !impressionTracked else { return }
        impressionTracked = true

        // Fire impression pixel
        if let url = URL(string: ad.impressionUrl) {
            Task {
                _ = try? await URLSession.shared.data(from: url)
            }
        }

        delegate?.interstitialDidRecordImpression(self)
        print("[Perspicis] Interstitial impression tracked")
    }

    private func trackClick(_ ad: InterstitialAd) {
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

        delegate?.interstitialDidRecordClick(self)
        print("[Perspicis] Interstitial click tracked")
    }
}

// MARK: - InterstitialViewControllerDelegate

extension PerspicisInterstitial: InterstitialViewControllerDelegate {

    func interstitialDidTapCreative(_ controller: InterstitialViewController) {
        guard let ad = currentAd else { return }

        // Track click
        trackClick(ad)

        // Open destination URL
        guard let url = URL(string: ad.clickUrl) else { return }

        UIApplication.shared.open(url)
    }

    func interstitialDidTapClose(_ controller: InterstitialViewController) {
        // Notify will dismiss
        delegate?.interstitialWillDismiss(self)

        // Dismiss the interstitial
        controller.dismiss(animated: true) { [weak self] in
            guard let self = self else { return }
            self.state = .idle
            self.currentAd = nil
            self.delegate?.interstitialDidDismiss(self)
        }
    }

    func interstitialDidFailToRender(_ controller: InterstitialViewController) {
        controller.dismiss(animated: false)
        state = .failed
        delegate?.interstitial(self, didFailToShowWithError: PerspicisError.invalidCreative)
    }
}

// MARK: - Interstitial View Controller Delegate Protocol

protocol InterstitialViewControllerDelegate: AnyObject {
    func interstitialDidTapCreative(_ controller: InterstitialViewController)
    func interstitialDidTapClose(_ controller: InterstitialViewController)
    func interstitialDidFailToRender(_ controller: InterstitialViewController)
}

// MARK: - Interstitial View Controller

class InterstitialViewController: UIViewController {

    private let ad: InterstitialAd
    private let configuration: InterstitialConfiguration
    private weak var interstitialDelegate: InterstitialViewControllerDelegate?

    private var dimmedBackground: UIView?
    private var contentView: UIView?
    private var closeButton: UIButton?
    private var closeButtonTimer: Timer?

    // MARK: - Initialization

    init(ad: InterstitialAd, configuration: InterstitialConfiguration, delegate: InterstitialViewControllerDelegate) {
        self.ad = ad
        self.configuration = configuration
        self.interstitialDelegate = delegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        setupDimmedBackground()
        setupContentView()
        startCloseButtonTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        closeButtonTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupDimmedBackground() {
        dimmedBackground = UIView(frame: view.bounds)
        dimmedBackground?.backgroundColor = UIColor.black.withAlphaComponent(configuration.dimmedBackgroundAlpha)
        dimmedBackground?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let bg = dimmedBackground {
            view.addSubview(bg)
        }
    }

    private func setupContentView() {
        switch ad.creativeType {
        case .image:
            setupImageContent()
        case .html:
            setupHtmlContent()
        }
    }

    private func setupImageContent() {
        guard let urlString = ad.creativeUrl, let url = URL(string: urlString) else {
            interstitialDelegate?.interstitialDidFailToRender(self)
            return
        }

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Add tap gesture for clicks
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(creativeTapped))
        imageView.addGestureRecognizer(tapGesture)
        imageView.isUserInteractionEnabled = true

        view.addSubview(imageView)
        contentView = imageView

        // Load image
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data) else {
                    throw PerspicisError.invalidCreative
                }

                await MainActor.run {
                    imageView.image = image
                }
            } catch {
                print("[Perspicis] Failed to load interstitial image: \(error)")
            }
        }
    }

    private func setupHtmlContent() {
        guard let html = ad.htmlContent else {
            interstitialDelegate?.interstitialDidFailToRender(self)
            return
        }

        let webView = WKWebView(frame: view.bounds)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Add tap gesture
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(creativeTapped))
        webView.addGestureRecognizer(tapGesture)

        view.addSubview(webView)
        webView.loadHTMLString(html, baseURL: nil)

        contentView = webView
    }

    private func setupCloseButton() {
        closeButton = UIButton(type: .system)
        closeButton?.setTitle("✕", for: .normal)
        closeButton?.titleLabel?.font = .systemFont(ofSize: 20, weight: .bold)
        closeButton?.tintColor = .white
        closeButton?.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        closeButton?.layer.cornerRadius = configuration.closeButtonSize.width / 2
        closeButton?.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)

        guard let closeButton = closeButton else { return }

        view.addSubview(closeButton)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: configuration.closeButtonSize.width),
            closeButton.heightAnchor.constraint(equalToConstant: configuration.closeButtonSize.height)
        ])

        // Animate in
        closeButton.alpha = 0
        UIView.animate(withDuration: configuration.animationDuration) {
            closeButton.alpha = 1
        }
    }

    // MARK: - Close Button Timer

    private func startCloseButtonTimer() {
        closeButtonTimer = Timer.scheduledTimer(
            timeInterval: configuration.closeButtonDelay,
            target: self,
            selector: #selector(showCloseButton),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func showCloseButton() {
        setupCloseButton()
    }

    // MARK: - Actions

    @objc private func creativeTapped() {
        interstitialDelegate?.interstitialDidTapCreative(self)
    }

    @objc private func closeButtonTapped() {
        interstitialDelegate?.interstitialDidTapClose(self)
    }
}

#endif
