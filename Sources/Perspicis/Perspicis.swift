import Foundation

/// Perspicis iOS SDK
/// Privacy-native mobile advertising - cohorts computed on-device
public final class PerspicisSDK: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = PerspicisSDK()
    private init() {}

    // MARK: - State

    public enum State: String, Sendable {
        case uninitialized
        case initializing
        case ready
        case error
    }

    public internal(set) var state: State = .uninitialized
    public private(set) var lastError: PerspicisError?

    private var appKey: String?

    /// Public accessor for app key (for internal SDK use)
    public var currentAppKey: String? { appKey }

    /// Set app key (called early so telemetry events have the correct key)
    internal func setAppKey(_ key: String) {
        self.appKey = key
    }

    /// Public accessor for server URL (for internal SDK use)
    public var serverUrl: URL? { config?.apiEndpoint }

    private var config: Configuration?
    private var cohortEngine: CohortEngine?
    private var signalCollector: SignalCollector?
    private var offlineQueue: OfflineQueue?
    private var networkMonitor: NetworkMonitor?
    private var sessionStartTime: Date?
    private var attManager: ATTManager?

    // Phase 2: Custom Cohorts
    private var cohortRegistry: CohortRegistry?
    private var cachedCohorts: [String]?
    private var cohortCacheTimestamp: Date?
    private let cohortCacheTTL: TimeInterval = 60 // 1 minute

    /// Access to ATT (App Tracking Transparency) manager
    public var att: ATTManager? { attManager }

    /// Access to network monitor for connectivity status
    public var network: NetworkMonitor? { networkMonitor }

    // MARK: - SDK Version

    /// Current SDK version
    public static let version = "2.1.0"

    /// SDK build number
    public static let build = "1"

    // MARK: - Nested Types (for module interface compatibility)

    /// Reward structure for rewarded video ads
    public struct Reward: Sendable {
        public let type: String
        public let amount: Int

        public init(type: String = "coins", amount: Int = 1) {
            self.type = type
            self.amount = amount
        }
    }

    // MARK: - Validation

    /// Result of SDK configuration validation
    public struct ValidationResult: Sendable {
        /// Whether the configuration is valid
        public let isValid: Bool

        /// List of errors found (empty if valid)
        public let errors: [ValidationError]

        /// List of warnings (non-blocking issues)
        public let warnings: [ValidationWarning]

        /// Human-readable summary
        public var summary: String {
            if isValid && warnings.isEmpty {
                return "Configuration valid. Ready for production."
            } else if isValid {
                return "Configuration valid with \(warnings.count) warning(s)."
            } else {
                return "Configuration invalid: \(errors.count) error(s) found."
            }
        }
    }

    /// Validation error types
    public enum ValidationError: Sendable, CustomStringConvertible {
        case notInitialized
        case invalidKeyFormat(String)
        case missingInfoPlistKey(String)
        case networkUnavailable
        case telemetryEndpointUnreachable(String)

        public var description: String {
            switch self {
            case .notInitialized:
                return "SDK not initialized. Call Perspicis.spark() first."
            case .invalidKeyFormat(let key):
                return "Invalid key format '\(key)'. Use pk_live_xxx, pk_test_xxx, or pk_demo_xxx."
            case .missingInfoPlistKey(let key):
                return "Missing Info.plist key: \(key). Add it to your app's Info.plist."
            case .networkUnavailable:
                return "Network unavailable. Some features may not work."
            case .telemetryEndpointUnreachable(let url):
                return "Telemetry endpoint unreachable: \(url)"
            }
        }

        /// Suggested fix for this error
        public var fix: String {
            switch self {
            case .notInitialized:
                return "Add Perspicis.spark(\"pk_live_xxx\") to your app's init()."
            case .invalidKeyFormat:
                return "Get a valid key from https://dashboard.perspicis.com"
            case .missingInfoPlistKey(let key):
                return "Add <key>\(key)</key><string>YOUR_VALUE</string> to Info.plist"
            case .networkUnavailable:
                return "Check device network connection."
            case .telemetryEndpointUnreachable:
                return "Check firewall settings or try again later."
            }
        }
    }

    /// Validation warning types
    public enum ValidationWarning: Sendable, CustomStringConvertible {
        case demoMode
        case testMode
        case debugEnabled
        case attNotDetermined
        case lowBatchSize(Int)

        public var description: String {
            switch self {
            case .demoMode:
                return "Running in demo mode. Ads are simulated."
            case .testMode:
                return "Running in test mode. No real billing."
            case .debugEnabled:
                return "Debug logging enabled. Disable for production."
            case .attNotDetermined:
                return "ATT status not determined. Consider requesting permission."
            case .lowBatchSize(let size):
                return "Batch size (\(size)) is low. May increase network usage."
            }
        }
    }

    /// Validate SDK configuration
    ///
    /// Call this before going to production to ensure everything is set up correctly.
    ///
    /// ```swift
    /// let result = Perspicis.validate()
    /// if !result.isValid {
    ///     result.errors.forEach { print("Error: \($0)\nFix: \($0.fix)") }
    /// }
    /// ```
    ///
    /// - Returns: ValidationResult with errors and warnings
    public static func validate() -> ValidationResult {
        var errors: [ValidationError] = []
        var warnings: [ValidationWarning] = []

        // Check initialization
        if shared.state == .uninitialized {
            errors.append(.notInitialized)
            return ValidationResult(isValid: false, errors: errors, warnings: warnings)
        }

        // Check app key format
        if let key = shared.appKey {
            if !key.hasPrefix("pk_live_") && !key.hasPrefix("pk_test_") && !key.hasPrefix("pk_demo_") {
                errors.append(.invalidKeyFormat(key))
            }

            // Warnings for non-production modes
            if key.hasPrefix("pk_demo_") {
                warnings.append(.demoMode)
            } else if key.hasPrefix("pk_test_") {
                warnings.append(.testMode)
            }
        }

        // Check debug mode
        if shared.config?.enableDebugLogging == true {
            warnings.append(.debugEnabled)
        }

        // Note: Network check is async, so we skip it here.
        // Network errors will be caught when making actual ad requests.

        // Note: ATT status check requires async context, skipped in sync validation
        // Use Perspicis.shared.att?.currentStatus() to check manually

        // Check batch size
        if let batchSize = shared.config?.eventBatchSize, batchSize < 5 {
            warnings.append(.lowBatchSize(batchSize))
        }

        return ValidationResult(
            isValid: errors.isEmpty,
            errors: errors,
            warnings: warnings
        )
    }

    /// Quick validation check - returns true if ready for production
    public static var isConfigured: Bool {
        shared.state == .ready && shared.appKey != nil
    }

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var apiEndpoint: URL
        public var enableDebugLogging: Bool
        public var ruleCacheMaxAge: TimeInterval
        public var eventBatchSize: Int
        public var eventFlushInterval: TimeInterval

        public init(
            apiEndpoint: URL = URL(string: "https://api.perspicis.com")!,
            enableDebugLogging: Bool = false,
            ruleCacheMaxAge: TimeInterval = 3600,
            eventBatchSize: Int = 20,
            eventFlushInterval: TimeInterval = 60
        ) {
            self.apiEndpoint = apiEndpoint
            self.enableDebugLogging = enableDebugLogging
            self.ruleCacheMaxAge = ruleCacheMaxAge
            self.eventBatchSize = eventBatchSize
            self.eventFlushInterval = eventFlushInterval
        }

        /// Development configuration with verbose logging
        public static var development: Configuration {
            Configuration(
                apiEndpoint: URL(string: "http://localhost:8080")!,
                enableDebugLogging: true,
                ruleCacheMaxAge: 60 // 1 minute for dev
            )
        }
    }

    // MARK: - Public API

    /// Configure and initialize the SDK
    ///
    /// Call this once on app launch, typically in `application(_:didFinishLaunchingWithOptions:)`
    ///
    /// ```swift
    /// await Perspicis.shared.configure(appKey: "pk_live_xxxxx")
    /// ```
    ///
    /// - Parameters:
    ///   - appKey: Your Perspicis app key (starts with "pk_")
    ///   - config: Optional configuration overrides
    /// - Returns: Result indicating success or failure
    @discardableResult
    public func configure(
        appKey: String,
        config: Configuration = Configuration()
    ) async -> Result<Void, PerspicisError> {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard state == .uninitialized else {
            log("SDK already initialized")
            return .failure(.alreadyInitialized)
        }

        state = .initializing
        self.config = config

        // Validate app key format
        guard appKey.hasPrefix("pk_") else {
            let error = PerspicisError.invalidAppKey(
                "App key must start with 'pk_'. Get your key at dashboard.perspicis.com"
            )
            self.lastError = error
            self.state = .error
            return .failure(error)
        }

        self.appKey = appKey

        // Initialize components
        let apiClient = HTTPCohortAPIClient(baseURL: config.apiEndpoint)
        var engineConfig = CohortEngine.EngineConfig()
        engineConfig.cacheMaxAge = config.ruleCacheMaxAge
        engineConfig.enableDebugLogging = config.enableDebugLogging

        self.cohortEngine = CohortEngine(apiClient: apiClient, config: engineConfig)
        self.signalCollector = SignalCollector()
        self.attManager = ATTManager()
        self.cohortRegistry = CohortRegistry()
        await attManager?.setDebugLogging(config.enableDebugLogging)

        // Initialize network monitor and offline queue
        self.networkMonitor = NetworkMonitor()
        let queueConfig = OfflineQueue.Config(
            batchSize: config.eventBatchSize,
            flushInterval: config.eventFlushInterval
        )
        self.offlineQueue = OfflineQueue(
            apiEndpoint: config.apiEndpoint,
            appKey: appKey,
            config: queueConfig,
            networkMonitor: networkMonitor
        )
        await offlineQueue?.setDebugLogging(config.enableDebugLogging)
        await offlineQueue?.start()

        // Start signal collection
        await signalCollector?.start()
        sessionStartTime = Date()

        // Load cohort rules (with cache fallback)
        do {
            try await cohortEngine?.loadRules(appKey: appKey)
        } catch {
            // Non-fatal - we can operate with cached rules or no rules
            log("Warning: Failed to load cohort rules: \(error)")
        }

        let initTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        log("Initialized in \(String(format: "%.1f", initTime))ms")

        // Report init telemetry
        await offlineQueue?.enqueue(name: "_sdk_init", properties: ["init_time_ms": initTime])

        state = .ready
        return .success(())
    }

    /// Track a custom event
    ///
    /// Events are used for on-device cohort computation and batched analytics.
    ///
    /// ```swift
    /// Perspicis.shared.trackEvent("level_complete", properties: ["level": 5])
    /// ```
    ///
    /// - Parameters:
    ///   - name: Event name (snake_case recommended)
    ///   - properties: Optional key-value properties
    public func trackEvent(_ name: String, properties: [String: Any]? = nil) {
        guard state == .ready else {
            log("Cannot track event: SDK not ready (state: \(state))")
            return
        }

        // Update local signals (for cohort computation)
        Task {
            await signalCollector?.trackEvent(name, properties: properties)
        }

        // Queue for server (batched, with offline support)
        Task {
            await offlineQueue?.enqueue(name: name, properties: properties)
        }

        log("Tracked: \(name)")
    }

    /// Get current cohort IDs for this user
    ///
    /// Cohorts are computed entirely on-device based on local signals.
    /// Only the cohort IDs are sent with ad requests - no raw signals leave the device.
    ///
    /// - Returns: Array of cohort identifiers the user matches
    public func getCohorts() async -> [String] {
        guard state == .ready else { return [] }

        guard let signals = await signalCollector?.currentSignals,
              let engine = cohortEngine else {
            return []
        }

        return await engine.getCohortIds(from: signals)
    }

    /// Get detailed cohort matches with priority info
    public func getCohortMatches() async -> [CohortMatch] {
        guard state == .ready else { return [] }

        guard let signals = await signalCollector?.currentSignals,
              let engine = cohortEngine else {
            return []
        }

        return await engine.computeCohorts(from: signals)
    }

    /// Request an ad for the given placement
    ///
    /// ```swift
    /// let result = await Perspicis.shared.requestAd(placement: .rewardedVideo)
    /// switch result {
    /// case .success(let ad):
    ///     // Show ad
    /// case .failure(.noFill):
    ///     // No ad available
    /// }
    /// ```
    ///
    /// - Parameter placement: Ad placement type
    /// - Returns: Ad response or error
    public func requestAd(placement: AdPlacement) async -> Result<AdResponse, PerspicisError> {
        guard state == .ready else {
            return .failure(.notInitialized)
        }

        guard let appKey = appKey,
              let config = config else {
            return .failure(.notInitialized)
        }

        let cohorts = await getCohorts()

        let request = AdRequest(
            appKey: appKey,
            placement: placement,
            cohortIds: cohorts,
            deviceType: nil,
            osVersion: nil,
            appVersion: nil,
            sessionId: nil
        )

        // Send ad request
        do {
            let response = try await sendAdRequest(request, endpoint: config.apiEndpoint)
            log("Ad received: \(response.adId) from campaign \(response.campaignId)")
            return .success(response)
        } catch let error as PerspicisError {
            log("Ad request failed: \(error.localizedDescription)")
            return .failure(error)
        } catch {
            log("Ad request failed: \(error.localizedDescription)")
            return .failure(.networkError(error))
        }
    }

    /// Call when app enters background to record session duration
    public func applicationDidEnterBackground() {
        guard let startTime = sessionStartTime else { return }
        let duration = Date().timeIntervalSince(startTime) / 60.0 // minutes

        Task {
            await signalCollector?.endSession(durationMinutes: duration)
            await offlineQueue?.flush()
        }
    }

    /// Call when app enters foreground
    public func applicationWillEnterForeground() {
        sessionStartTime = Date()

        Task {
            await signalCollector?.start()
        }
    }

    // MARK: - ATT (App Tracking Transparency)

    /// Request App Tracking Transparency authorization
    ///
    /// Call this at an appropriate moment in your app (e.g., after onboarding)
    /// to request permission to track the user.
    ///
    /// ```swift
    /// let status = await Perspicis.shared.requestTrackingAuthorization()
    /// ```
    ///
    /// - Returns: The authorization status after the request
    @MainActor
    public func requestTrackingAuthorization() async -> ATTManager.AuthorizationStatus {
        guard let attManager = attManager else {
            return .unavailable
        }
        return await attManager.requestAuthorization()
    }

    /// Get the current tracking authorization status
    public func getTrackingStatus() async -> ATTManager.AuthorizationStatus {
        guard let attManager = attManager else {
            return .unavailable
        }
        return await attManager.currentStatus()
    }

    /// Check if the user has authorized tracking
    public func isTrackingAuthorized() async -> Bool {
        guard let attManager = attManager else {
            return false
        }
        return await attManager.isTrackingAuthorized()
    }

    // MARK: - Offline Queue

    /// Get statistics about the offline event queue
    public func getQueueStats() async -> OfflineQueue.QueueStats? {
        return await offlineQueue?.stats()
    }

    /// Check if the device is currently connected to the network
    public func isNetworkConnected() async -> Bool {
        guard let monitor = networkMonitor else { return false }
        return await monitor.isConnected()
    }

    /// Force flush pending events (use sparingly)
    public func flushEvents() async {
        await offlineQueue?.flush()
    }

    // MARK: - Phase 2: Custom Cohorts

    /// Register a custom cohort definition
    ///
    /// Custom cohorts are evaluated on-device using local signals and event history.
    /// Only cohort IDs are exported - no raw data leaves the device.
    ///
    /// ```swift
    /// try Perspicis.shared.registerCohort(CohortCriteria(
    ///     cohortId: "festival_goer",
    ///     rules: [.eventCount(event: "session_completed", minCount: 3)],
    ///     timeWindowDays: 90
    /// ))
    /// ```
    ///
    /// - Parameter criteria: The cohort definition
    public func registerCohort(_ criteria: CohortCriteria) throws {
        guard let registry = cohortRegistry else {
            log("Cannot register cohort: SDK not initialized")
            return
        }

        Task {
            try await registry.register(criteria)
            invalidateCohortCache()
        }
    }

    /// Register multiple cohorts at once
    public func registerCohorts(_ criteriaList: [CohortCriteria]) throws {
        guard let registry = cohortRegistry else {
            log("Cannot register cohorts: SDK not initialized")
            return
        }

        Task {
            try await registry.registerMultiple(criteriaList)
            invalidateCohortCache()
        }
    }

    /// Remove a registered cohort
    public func unregisterCohort(id: String) {
        Task {
            await cohortRegistry?.unregister(cohortId: id)
            invalidateCohortCache()
        }
    }

    /// Get all registered cohort IDs
    public func getRegisteredCohortIds() async -> [String] {
        await cohortRegistry?.getRegisteredIds() ?? []
    }

    // MARK: - Phase 2: Cohort Export

    /// Get current cohort IDs (combines server + app-defined cohorts)
    ///
    /// PRIVACY GUARANTEE:
    /// - Cohorts computed ENTIRELY ON-DEVICE
    /// - Only cohort IDs returned (no raw signals)
    ///
    /// ```swift
    /// let cohorts = await Perspicis.shared.currentCohorts()
    /// // ["festival_goer", "super_engaged"]
    /// ```
    public func currentCohorts() async -> [String] {
        guard state == .ready else { return [] }

        // Check cache
        if let cached = cachedCohorts, !isCohortCacheExpired() {
            return cached
        }

        // Get server-defined cohorts
        let serverCohorts = await getCohorts()

        // Get app-defined cohorts
        var appCohortIds: [String] = []
        if let registry = cohortRegistry,
           let signals = await signalCollector?.currentSignals {
            let eventHistory = LocalEventHistory()
            let matches = await registry.evaluate(signals: signals, eventHistory: eventHistory)
            appCohortIds = matches.map(\.cohortId)
        }

        // Combine and deduplicate
        let allCohorts = Array(Set(serverCohorts + appCohortIds)).sorted()

        // Cache result
        cachedCohorts = allCohorts
        cohortCacheTimestamp = Date()

        return allCohorts
    }

    /// Check if user is in a specific cohort
    public func isInCohort(_ cohortId: String) async -> Bool {
        await currentCohorts().contains(cohortId)
    }

    // MARK: - Phase 2: AdMob Integration

    /// Get cohorts formatted for AdMob custom targeting
    ///
    /// ```swift
    /// let request = GADRequest()
    /// request.customTargeting = await Perspicis.shared.admobTargeting()
    /// ```
    ///
    /// - Returns: Dictionary suitable for GADRequest.customTargeting
    public func admobTargeting() async -> [String: String] {
        let cohortIds = await currentCohorts()

        return AdMobTargeting(
            cohorts: cohortIds.joined(separator: ","),
            sdkVersion: PerspicisSDK.version,
            privacyStatus: "k_anon_verified"
        ).toDictionary()
    }

    // MARK: - Phase 2: MAX Integration

    /// Get cohorts formatted for AppLovin MAX mediation
    ///
    /// ```swift
    /// let targeting = await Perspicis.shared.maxTargeting()
    /// interstitialAd.setLocalExtraParameterForKey("custom_data", value: targeting.customData)
    /// ```
    public func maxTargeting() async -> MAXTargetingData {
        let cohortIds = await currentCohorts()
        let keywords = deriveKeywordsFromCohorts(cohortIds)

        return MAXTargetingData(
            cohorts: cohortIds,
            keywords: keywords,
            customData: [
                "perspicis_version": PerspicisSDK.version,
                "cohort_count": String(cohortIds.count)
            ]
        )
    }

    /// Derive keywords from cohort IDs for MAX bidding
    private func deriveKeywordsFromCohorts(_ cohortIds: [String]) -> [String] {
        let keywordMap: [String: [String]] = [
            "festival_goer": ["music", "events", "outdoor", "festivals"],
            "genre_explorer": ["music", "discovery", "streaming"],
            "super_engaged": ["premium", "power_user", "engaged"],
            "social_sharer": ["social", "sharing", "viral"],
            "premium_candidate": ["freemium", "conversion", "premium"],
            "dj_fan": ["music", "dj", "electronic", "nightlife"],
            "local_legend": ["local", "events", "community"],
            "new_user": ["new_user", "acquisition", "onboarding"]
        ]

        var keywords = Set<String>()
        for cohortId in cohortIds {
            if let mapped = keywordMap[cohortId] {
                keywords.formUnion(mapped)
            }
        }
        return Array(keywords).sorted()
    }

    // MARK: - Phase 2: Debug

    /// Enable verbose debug logging
    public var debugMode: Bool = false {
        didSet {
            if debugMode {
                log("Debug mode ENABLED - do not use in production")
            }
        }
    }

    /// Get debug information about SDK state
    public func debugInfo() async -> PerspicisDebugInfo {
        let signals = await signalCollector?.currentSignals ?? UserSignals()
        let queueStats = await offlineQueue?.stats()
        let networkConnected = await networkMonitor?.isConnected() ?? false

        return PerspicisDebugInfo(
            sdkVersion: PerspicisSDK.version,
            isConfigured: state == .ready,
            appKey: maskAppKey(appKey),
            registeredCohorts: await getRegisteredCohortIds(),
            currentCohorts: await currentCohorts(),
            signalsSummary: [
                "session_count": signals.sessionCount,
                "session_count_7d": signals.sessionCount7d,
                "days_since_install": signals.daysSinceInstall,
                "event_count": signals.eventCount
            ],
            eventQueueSize: queueStats?.pendingCount ?? 0,
            cohortCacheAge: cohortCacheTimestamp.map { Date().timeIntervalSince($0) },
            lastError: lastError?.localizedDescription,
            networkStatus: networkConnected ? "connected" : "offline"
        )
    }

    private func maskAppKey(_ key: String?) -> String? {
        guard let key = key else { return nil }
        if key.count <= 8 { return "***" }
        return String(key.prefix(8)) + "***"
    }

    private func invalidateCohortCache() {
        cachedCohorts = nil
        cohortCacheTimestamp = nil
    }

    private func isCohortCacheExpired() -> Bool {
        guard let timestamp = cohortCacheTimestamp else { return true }
        return Date().timeIntervalSince(timestamp) > cohortCacheTTL
    }

    // MARK: - Private

    private func sendAdRequest(_ request: AdRequest, endpoint: URL) async throws -> AdResponse {
        var urlRequest = URLRequest(url: endpoint.appendingPathComponent("v1/ads/request"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PerspicisError.networkError(URLError(.badServerResponse))
        }

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let serverResponse = try decoder.decode(AdServerResponse.self, from: data)

            guard serverResponse.success, let ad = serverResponse.ad else {
                throw PerspicisError.noFill
            }

            return ad
        case 204:
            throw PerspicisError.noFill
        case 401:
            throw PerspicisError.invalidAppKey("Invalid or expired app key")
        case 503:
            throw PerspicisError.disabled
        default:
            throw PerspicisError.networkError(URLError(.badServerResponse))
        }
    }

    private func log(_ message: String) {
        if config?.enableDebugLogging == true {
            print("[Perspicis] \(message)")
        }
    }
}

// MARK: - Ad Types

public enum AdPlacement: String, Codable, Sendable {
    case banner
    case interstitial
    case rewardedVideo = "rewarded_video"
}

/// Response from ad-server
public struct AdServerResponse: Codable, Sendable {
    public let success: Bool
    public let ad: AdResponse?
    public let requestId: String
    public let auctionId: String?
    public let message: String?
}

/// The actual ad to display
public struct AdResponse: Codable, Sendable {
    public let adId: String
    public let campaignId: String
    public let creativeUrl: String
    public let clickUrl: String
    public let type: String
    public let duration: Int?
    public let width: Int?
    public let height: Int?
    public let trackingUrls: TrackingURLs
}

/// Tracking URLs for impression/click/video events
public struct TrackingURLs: Codable, Sendable {
    public let impression: String
    public let click: String
    public let complete: String?
    public let firstQuartile: String?
    public let midpoint: String?
    public let thirdQuartile: String?
}

struct AdRequest: Encodable {
    let appKey: String
    let placement: AdPlacement
    let cohortIds: [String]
    let deviceType: String?
    let osVersion: String?
    let appVersion: String?
    let sessionId: String?
}

// MARK: - Debug Info

/// Debug information for troubleshooting
public struct PerspicisDebugInfo: Sendable {
    public let sdkVersion: String
    public let isConfigured: Bool
    public let appKey: String?
    public let registeredCohorts: [String]
    public let currentCohorts: [String]
    public let signalsSummary: [String: Int]
    public let eventQueueSize: Int
    public let cohortCacheAge: TimeInterval?
    public let lastError: String?
    public let networkStatus: String
}

// MARK: - Local Event History

/// Local event history for cohort evaluation
final class LocalEventHistory: @unchecked Sendable, EventHistoryProtocol {
    private let defaults = UserDefaults.standard
    private let eventsKey = "perspicis_event_history"

    func count(eventName: String, since: Date) -> Int {
        let events = loadEvents()
        return events.filter { $0.name == eventName && $0.timestamp >= since }.count
    }

    func count(eventName: String, where predicate: ([String: Any]) -> Bool, since: Date) -> Int {
        let events = loadEvents()
        return events.filter {
            $0.name == eventName && $0.timestamp >= since && predicate($0.getProperties())
        }.count
    }

    func recordEvent(_ name: String, properties: [String: Any]) {
        var events = loadEvents()
        events.append(StoredEvent(name: name, properties: properties, timestamp: Date()))

        // Keep only last 30 days of events
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        events = events.filter { $0.timestamp >= cutoff }

        saveEvents(events)
    }

    private func loadEvents() -> [StoredEvent] {
        guard let data = defaults.data(forKey: eventsKey) else { return [] }
        return (try? JSONDecoder().decode([StoredEvent].self, from: data)) ?? []
    }

    private func saveEvents(_ events: [StoredEvent]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        defaults.set(data, forKey: eventsKey)
    }
}

/// Stored event for persistence
struct StoredEvent: Codable {
    let name: String
    let properties: [String: CodableValue]
    let timestamp: Date

    init(name: String, properties: [String: Any], timestamp: Date) {
        self.name = name
        self.timestamp = timestamp

        var codableProps: [String: CodableValue] = [:]
        for (key, value) in properties {
            if let v = value as? String { codableProps[key] = .string(v) }
            else if let v = value as? Int { codableProps[key] = .int(v) }
            else if let v = value as? Double { codableProps[key] = .double(v) }
            else if let v = value as? Bool { codableProps[key] = .bool(v) }
        }
        self.properties = codableProps
    }

    func getProperties() -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in properties {
            switch value {
            case .string(let v): result[key] = v
            case .int(let v): result[key] = v
            case .double(let v): result[key] = v
            case .bool(let v): result[key] = v
            }
        }
        return result
    }
}

enum CodableValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        }
    }
}

// MARK: - Errors

public enum PerspicisError: Error, LocalizedError, Sendable {
    case invalidAppKey(String)
    case alreadyInitialized
    case notInitialized
    case networkError(Error)
    case noFill
    case disabled
    case vastParseError
    case invalidResponse
    case noMediaFile
    case downloadFailed
    case cacheError
    case adNotReady
    case adExpired
    case noVideoURL
    case alreadyLoading
    case alreadyLoaded
    case playbackError
    case invalidCreative
    case configurationError

    public var errorDescription: String? {
        switch self {
        case .invalidAppKey(let message):
            return "Invalid app key: \(message)"
        case .alreadyInitialized:
            return "SDK already initialized. Perspicis.spark() should only be called once."
        case .notInitialized:
            return "SDK not initialized. Call Perspicis.spark() in your app's init()."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .noFill:
            return "No ad available. This is normal - try again later."
        case .disabled:
            return "Ads are disabled for this user or region."
        case .vastParseError:
            return "Failed to parse ad response. The ad server returned invalid data."
        case .invalidResponse:
            return "Invalid ad response from server."
        case .noMediaFile:
            return "No compatible media file found in ad response."
        case .downloadFailed:
            return "Failed to download ad creative. Check network connection."
        case .cacheError:
            return "Failed to cache ad. Device may be low on storage."
        case .adNotReady:
            return "Ad is not ready. Wait for load completion before showing."
        case .adExpired:
            return "Ad has expired. Request a new ad."
        case .noVideoURL:
            return "Video ad has no playable URL."
        case .alreadyLoading:
            return "Ad is already loading. Wait for completion."
        case .alreadyLoaded:
            return "Ad is already loaded. Show it or request a new one."
        case .playbackError:
            return "Video playback failed. The ad may be corrupted."
        case .invalidCreative:
            return "Ad creative is invalid or unsupported."
        case .configurationError:
            return "SDK configuration error. Check your setup."
        }
    }

    /// Suggested fix for this error
    public var recoverySuggestion: String? {
        switch self {
        case .invalidAppKey:
            return "Use a valid key: pk_live_xxx, pk_test_xxx, or pk_demo_xxx. Get keys at https://dashboard.perspicis.com"
        case .alreadyInitialized:
            return "Remove duplicate Perspicis.spark() calls. Only call once in App.init()."
        case .notInitialized:
            return "Add Perspicis.spark(\"your_key\") to your @main App struct's init()."
        case .networkError:
            return "Check device network connection and try again."
        case .noFill:
            return "This is expected sometimes. Implement a fallback or retry after 30 seconds."
        case .disabled:
            return "Check if the user has disabled personalized ads or is in a restricted region."
        case .vastParseError, .invalidResponse:
            return "This is a server-side issue. Contact raj@heliosnexus.com if it persists."
        case .noMediaFile:
            return "The ad format may not be supported on this device."
        case .downloadFailed:
            return "Ensure the device has network connectivity and retry."
        case .cacheError:
            return "Free up device storage and retry."
        case .adNotReady:
            return "Use the onAdLoaded callback before calling show()."
        case .adExpired:
            return "Ads expire after 1 hour. Request a fresh ad before showing."
        case .noVideoURL:
            return "Report this issue to raj@heliosnexus.com."
        case .alreadyLoading:
            return "Wait for the current load to complete before requesting another."
        case .alreadyLoaded:
            return "Call show() to display the loaded ad, or discard and reload."
        case .playbackError:
            return "Try loading a new ad. Report if issue persists."
        case .invalidCreative:
            return "Report this ad to raj@heliosnexus.com with the ad ID."
        case .configurationError:
            return "Run Perspicis.validate() to identify configuration issues."
        }
    }

    /// Error code for logging/analytics
    public var code: String {
        switch self {
        case .invalidAppKey: return "E001"
        case .alreadyInitialized: return "E002"
        case .notInitialized: return "E003"
        case .networkError: return "E004"
        case .noFill: return "E005"
        case .disabled: return "E006"
        case .vastParseError: return "E007"
        case .invalidResponse: return "E008"
        case .noMediaFile: return "E009"
        case .downloadFailed: return "E010"
        case .cacheError: return "E011"
        case .adNotReady: return "E012"
        case .adExpired: return "E013"
        case .noVideoURL: return "E014"
        case .alreadyLoading: return "E015"
        case .alreadyLoaded: return "E016"
        case .playbackError: return "E017"
        case .invalidCreative: return "E018"
        case .configurationError: return "E019"
        }
    }
}


