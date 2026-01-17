// =============================================================================
// Rewarded Video Ad System - Implementation
// US-5.1, US-5.2, US-5.3, US-5.4, US-5.5
// =============================================================================

#if os(iOS)
import Foundation
import AVFoundation
import UIKit

// MARK: - Configuration

/// Configuration options for rewarded video ads
public struct RewardedAdConfiguration {
    /// Time after which a loaded ad expires (default: 1 hour)
    public var expirationTimeout: TimeInterval

    /// Delay before skip button appears (nil = no skip allowed)
    public var skipButtonDelay: TimeInterval?

    /// Whether to show companion ad after video
    public var showCompanionAd: Bool

    /// Server-to-server callback URL for reward verification
    public var serverCallbackURL: String?

    /// Custom data to include in S2S callback
    public var customData: String?

    public init(
        expirationTimeout: TimeInterval = 3600,
        skipButtonDelay: TimeInterval? = nil,
        showCompanionAd: Bool = false,
        serverCallbackURL: String? = nil,
        customData: String? = nil
    ) {
        self.expirationTimeout = expirationTimeout
        self.skipButtonDelay = skipButtonDelay
        self.showCompanionAd = showCompanionAd
        self.serverCallbackURL = serverCallbackURL
        self.customData = customData
    }
}

// MARK: - Reward Model

/// Represents a reward earned by watching a video ad
public struct Reward: Equatable {
    /// Type of reward (e.g., "coins", "lives", "gems")
    public let type: String

    /// Amount of reward
    public let amount: Int

    public init(type: String, amount: Int) {
        self.type = type
        self.amount = amount
    }
}

// MARK: - Delegate Protocol

/// Delegate protocol for rewarded video ad events
public protocol PerspicisRewardedAdDelegate: AnyObject {
    /// Called when ad successfully loads
    func rewardedAdDidLoad(_ ad: PerspicisRewardedAd)

    /// Called when ad fails to load
    func rewardedAdDidFailToLoad(_ ad: PerspicisRewardedAd, error: PerspicisError)

    /// Called when ad is presented full-screen
    func rewardedAdDidPresent(_ ad: PerspicisRewardedAd)

    /// Called when ad fails to show
    func rewardedAdDidFailToShow(_ ad: PerspicisRewardedAd, error: PerspicisError)

    /// Called when ad is dismissed
    func rewardedAdDidDismiss(_ ad: PerspicisRewardedAd)

    /// Called when user earns reward (video completed)
    func rewardedAdDidEarnReward(_ ad: PerspicisRewardedAd, reward: Reward)

    /// Called when user clicks on ad (optional)
    func rewardedAdDidClick(_ ad: PerspicisRewardedAd)
}

// Default implementation for optional methods
public extension PerspicisRewardedAdDelegate {
    func rewardedAdDidClick(_ ad: PerspicisRewardedAd) {}
}

// MARK: - Rewarded Ad State

enum RewardedAdState {
    case idle
    case loading
    case ready
    case showing
    case expired
    case error
}

// MARK: - Main Rewarded Ad Class

/// Main class for loading and showing rewarded video ads
public class PerspicisRewardedAd {

    // MARK: - Public Properties

    public weak var delegate: PerspicisRewardedAdDelegate?
    public let placement: String
    public let configuration: RewardedAdConfiguration

    /// Ad service (injectable for testing)
    public var adService: BannerAdServiceProtocol?

    // MARK: - Private Properties

    private var state: RewardedAdState = .idle
    private var vastResponse: VASTResponse?
    private var videoURL: URL?
    private var reward: Reward?
    private var auctionID: String?
    private var loadedAt: Date?
    private var downloadTask: URLSessionDownloadTask?
    private var cachedVideoPath: URL?

    // MARK: - Computed Properties

    /// Whether the ad is loaded and ready to show
    public var isReady: Bool {
        return state == .ready && !isExpired
    }

    /// Whether the loaded ad has expired
    public var isExpired: Bool {
        guard let loadedAt = loadedAt else { return true }
        let elapsed = Date().timeIntervalSince(loadedAt)
        return elapsed > configuration.expirationTimeout
    }

    // MARK: - Initialization

    public init(placement: String, configuration: RewardedAdConfiguration = RewardedAdConfiguration()) {
        self.placement = placement
        self.configuration = configuration
    }

    // MARK: - Public Methods

    /// Load a rewarded video ad
    public func load() {
        // Validate state
        guard state != .loading else {
            delegate?.rewardedAdDidFailToLoad(self, error: .alreadyLoading)
            return
        }

        guard !(state == .ready && !isExpired) else {
            delegate?.rewardedAdDidFailToLoad(self, error: .alreadyLoaded)
            return
        }

        state = .loading

        // Get ad service
        let service = adService ?? AdService.shared

        // Build request
        let request = AdRequest(
            appKey: Perspicis.shared?.appKey ?? "",
            placement: placement,
            adType: .rewardedVideo,
            cohortIDs: Perspicis.shared?.currentCohorts ?? []
        )

        // Make request
        service.requestAd(request) { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let response):
                self.handleAdResponse(response)
            case .failure(let error):
                self.state = .error
                DispatchQueue.main.async {
                    self.delegate?.rewardedAdDidFailToLoad(self, error: error)
                }
            }
        }
    }

    /// Show the loaded rewarded video ad
    public func show(from viewController: UIViewController) {
        // Validate state
        guard state == .ready else {
            delegate?.rewardedAdDidFailToShow(self, error: .adNotReady)
            return
        }

        guard !isExpired else {
            state = .expired
            delegate?.rewardedAdDidFailToShow(self, error: .adExpired)
            return
        }

        guard let videoPath = cachedVideoPath ?? videoURL else {
            delegate?.rewardedAdDidFailToShow(self, error: .noVideoURL)
            return
        }

        state = .showing

        // Create video controller
        let videoController = RewardedVideoViewController(
            videoURL: videoPath,
            vastResponse: vastResponse,
            configuration: configuration,
            reward: reward,
            auctionID: auctionID
        )

        videoController.delegate = self
        videoController.modalPresentationStyle = .fullScreen

        viewController.present(videoController, animated: true) { [weak self] in
            guard let self = self else { return }
            self.delegate?.rewardedAdDidPresent(self)
        }
    }

    // MARK: - Private Methods

    private func handleAdResponse(_ response: AdServerResponse) {
        guard response.success, let ad = response.ad else {
            state = .error
            DispatchQueue.main.async {
                self.delegate?.rewardedAdDidFailToLoad(self, error: .noFill)
            }
            return
        }

        auctionID = response.auctionID

        // Parse VAST
        guard let vastXML = ad.vastXML else {
            state = .error
            DispatchQueue.main.async {
                self.delegate?.rewardedAdDidFailToLoad(self, error: .invalidResponse)
            }
            return
        }

        let parser = VASTParser()
        let parseResult = parser.parse(vastXML)

        switch parseResult {
        case .success(let vast):
            self.vastResponse = vast
            self.reward = Reward(
                type: ad.rewardType ?? "reward",
                amount: ad.rewardAmount ?? 1
            )

            // Select best media file
            guard let vastAd = vast.ad,
                  let selectedMedia = MediaFileSelector().selectBestFile(from: vastAd.mediaFiles),
                  let url = URL(string: selectedMedia.url) else {
                state = .error
                DispatchQueue.main.async {
                    self.delegate?.rewardedAdDidFailToLoad(self, error: .noMediaFile)
                }
                return
            }

            self.videoURL = url
            downloadVideo(url: url)

        case .failure:
            state = .error
            DispatchQueue.main.async {
                self.delegate?.rewardedAdDidFailToLoad(self, error: .vastParseError)
            }
        }
    }

    private func downloadVideo(url: URL) {
        downloadTask = URLSession.shared.downloadTask(with: url) { [weak self] localURL, response, error in
            guard let self = self else { return }

            if error != nil {
                self.state = .error
                DispatchQueue.main.async {
                    self.delegate?.rewardedAdDidFailToLoad(self, error: .downloadFailed)
                }
                return
            }

            guard let localURL = localURL else {
                self.state = .error
                DispatchQueue.main.async {
                    self.delegate?.rewardedAdDidFailToLoad(self, error: .downloadFailed)
                }
                return
            }

            // Move to cache
            do {
                let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                let cachedPath = cacheDir.appendingPathComponent("perspicis_video_\(self.auctionID ?? UUID().uuidString).mp4")

                if FileManager.default.fileExists(atPath: cachedPath.path) {
                    try FileManager.default.removeItem(at: cachedPath)
                }
                try FileManager.default.moveItem(at: localURL, to: cachedPath)

                self.cachedVideoPath = cachedPath
                self.loadedAt = Date()
                self.state = .ready

                DispatchQueue.main.async {
                    self.delegate?.rewardedAdDidLoad(self)
                }
            } catch {
                self.state = .error
                DispatchQueue.main.async {
                    self.delegate?.rewardedAdDidFailToLoad(self, error: .cacheError)
                }
            }
        }

        downloadTask?.resume()
    }
}

// MARK: - Video Controller Delegate

extension PerspicisRewardedAd: RewardedVideoViewControllerDelegate {
    func videoDidComplete(earnedReward: Bool) {
        if earnedReward, let reward = reward {
            delegate?.rewardedAdDidEarnReward(self, reward: reward)

            // Send S2S callback if configured
            if let callbackURL = configuration.serverCallbackURL,
               let auctionID = auctionID {
                RewardVerificationService.shared.sendRewardCallback(
                    auctionID: auctionID,
                    userID: Perspicis.shared?.userID ?? "",
                    reward: reward,
                    customData: configuration.customData,
                    callbackURL: callbackURL
                )
            }
        }
    }

    func videoDidDismiss() {
        state = .idle
        delegate?.rewardedAdDidDismiss(self)
    }

    func videoDidClick() {
        delegate?.rewardedAdDidClick(self)
    }

    func videoDidFailToPlay(error: PerspicisError) {
        state = .error
        delegate?.rewardedAdDidFailToShow(self, error: error)
    }
}

// MARK: - Video View Controller Delegate Protocol

protocol RewardedVideoViewControllerDelegate: AnyObject {
    func videoDidComplete(earnedReward: Bool)
    func videoDidDismiss()
    func videoDidClick()
    func videoDidFailToPlay(error: PerspicisError)
}

// MARK: - Quartile Tracker

/// Tracks video progress and fires quartile events
class QuartileTracker {
    private let duration: TimeInterval
    private var firedQuartiles: Set<VASTEventType> = []

    init(duration: TimeInterval) {
        self.duration = duration
    }

    func shouldFireQuartile(_ event: VASTEventType, atProgress progress: Double) -> Bool {
        switch event {
        case .start:
            return progress >= 0.0
        case .firstQuartile:
            return progress >= 0.25
        case .midpoint:
            return progress >= 0.50
        case .thirdQuartile:
            return progress >= 0.75
        case .complete:
            return progress >= 1.0
        default:
            return false
        }
    }

    func fireQuartileIfNeeded(_ event: VASTEventType, atProgress progress: Double) -> Bool {
        guard !firedQuartiles.contains(event),
              shouldFireQuartile(event, atProgress: progress) else {
            return false
        }

        firedQuartiles.insert(event)
        return true
    }

    func reset() {
        firedQuartiles.removeAll()
    }
}

// MARK: - Media File Selector

/// Selects optimal media file based on device capabilities
class MediaFileSelector {
    func selectBestFile(from files: [VASTMediaFile]) -> VASTMediaFile? {
        guard !files.isEmpty else { return nil }

        // Prefer MP4 on iOS
        let mp4Files = files.filter { $0.type == "video/mp4" }
        let candidates = mp4Files.isEmpty ? files : mp4Files

        // Sort by bitrate and select middle quality
        let sorted = candidates.sorted { $0.bitrate < $1.bitrate }
        let index = sorted.count / 2

        return sorted[index]
    }
}

// MARK: - Reward Verification Service

/// Handles server-side reward verification callbacks
class RewardVerificationService {
    static let shared = RewardVerificationService()

    private init() {}

    func sendRewardCallback(
        auctionID: String,
        userID: String,
        reward: Reward,
        customData: String?,
        callbackURL: String
    ) {
        guard let url = buildCallbackURL(
            baseURL: callbackURL,
            auctionID: auctionID,
            userID: userID,
            reward: reward,
            customData: customData
        ) else { return }

        URLSession.shared.dataTask(with: url) { _, _, error in
            if let error = error {
                // Queue for retry
                print("[Perspicis] Reward callback failed: \(error)")
            }
        }.resume()
    }

    func buildCallbackURL(
        baseURL: String,
        auctionID: String,
        userID: String,
        reward: Reward,
        customData: String?
    ) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }

        let timestamp = Int(Date().timeIntervalSince1970)

        var queryItems = [
            URLQueryItem(name: "auction_id", value: auctionID),
            URLQueryItem(name: "user_id", value: userID),
            URLQueryItem(name: "reward_type", value: reward.type),
            URLQueryItem(name: "reward_amount", value: String(reward.amount)),
            URLQueryItem(name: "timestamp", value: String(timestamp)),
        ]

        if let customData = customData {
            queryItems.append(URLQueryItem(name: "custom_data", value: customData))
        }

        // Generate signature
        let signature = generateSignature(
            auctionID: auctionID,
            userID: userID,
            rewardType: reward.type,
            rewardAmount: reward.amount,
            timestamp: timestamp,
            secretKey: Perspicis.shared?.secretKey ?? ""
        )
        queryItems.append(URLQueryItem(name: "signature", value: signature))

        components.queryItems = queryItems
        return components.url
    }

    func generateSignature(
        auctionID: String,
        userID: String,
        rewardType: String,
        rewardAmount: Int,
        timestamp: Int,
        secretKey: String
    ) -> String {
        let input = "\(auctionID):\(userID):\(rewardType):\(rewardAmount):\(timestamp)"
        // In production, use proper HMAC-SHA256
        // This is a placeholder implementation
        return input.data(using: .utf8)?.base64EncodedString() ?? ""
    }
}

#endif
