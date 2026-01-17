import Foundation

// MARK: - User Signals

/// All signals collected on-device for cohort computation
/// These NEVER leave the device - only computed cohort IDs are sent
public struct UserSignals: Sendable {

    // MARK: - Core Engagement

    /// Total sessions since install
    public var sessionCount: Int = 0

    /// Sessions in last 7 days
    public var sessionCount7d: Int = 0

    /// Sessions in last 30 days
    public var sessionCount30d: Int = 0

    /// Average session duration in minutes
    public var avgSessionMinutes: Double = 0

    /// Days since app install
    public var daysSinceInstall: Int = 0

    /// Days since last session
    public var daysSinceLastSession: Int = 0

    /// Total events tracked
    public var eventCount: Int = 0

    // MARK: - Monetization Signals

    /// In-app purchase events (attempts, not necessarily completed)
    public var iapEventCount: Int = 0

    /// Rewarded video completion rate (0.0 - 1.0)
    public var rewardedVideoCompletionRate: Double = 0

    // MARK: - Progression Signals

    /// Highest level/stage reached
    public var levelReached: Int = 0

    /// Whether tutorial was completed
    public var tutorialCompleted: Bool = false

    /// Time to complete tutorial in minutes
    public var tutorialCompletionMinutes: Double = 0

    // MARK: - Custom Signals

    /// Publisher-defined custom signals
    public var customSignals: [String: ConditionValue] = [:]

    // MARK: - Init

    public init() {}

    // MARK: - Anonymized Export

    /// Returns anonymized bucketed signals for ad request context
    /// These are safe to send to the server (no PII, no device ID)
    public func anonymized() -> AnonymizedSignals {
        AnonymizedSignals(
            engagementTier: computeEngagementTier(),
            sessionBucket: sessionBucket(),
            retentionBucket: retentionBucket(),
            monetizationSignal: monetizationSignal()
        )
    }

    // MARK: - Bucketing (k-anonymity)

    private func computeEngagementTier() -> EngagementTier {
        // Whale: High session count + long sessions + monetization signals
        if sessionCount > 20 && avgSessionMinutes > 15 && iapEventCount > 0 {
            return .whale
        }
        // Core: Regular engagement
        if sessionCount7d >= 5 && avgSessionMinutes > 10 {
            return .core
        }
        // Casual: Everyone else
        return .casual
    }

    private func sessionBucket() -> SessionBucket {
        switch sessionCount {
        case 0...3: return .new
        case 4...10: return .exploring
        case 11...30: return .regular
        default: return .power
        }
    }

    private func retentionBucket() -> RetentionBucket {
        switch daysSinceInstall {
        case 0...1: return .d0_d1
        case 2...7: return .d2_d7
        case 8...30: return .d8_d30
        default: return .d30plus
        }
    }

    private func monetizationSignal() -> MonetizationSignal {
        if iapEventCount > 0 { return .payer }
        if rewardedVideoCompletionRate > 0.5 { return .adEngaged }
        return .none
    }
}

// MARK: - Anonymized Signals (Safe to Send)

public struct AnonymizedSignals: Codable, Sendable {
    public let engagementTier: EngagementTier
    public let sessionBucket: SessionBucket
    public let retentionBucket: RetentionBucket
    public let monetizationSignal: MonetizationSignal

    enum CodingKeys: String, CodingKey {
        case engagementTier = "engagement_tier"
        case sessionBucket = "session_bucket"
        case retentionBucket = "retention_bucket"
        case monetizationSignal = "monetization_signal"
    }
}

public enum EngagementTier: String, Codable, Sendable {
    case casual, core, whale
}

public enum SessionBucket: String, Codable, Sendable {
    case new, exploring, regular, power
}

public enum RetentionBucket: String, Codable, Sendable {
    case d0_d1 = "d0_d1"
    case d2_d7 = "d2_d7"
    case d8_d30 = "d8_d30"
    case d30plus = "d30plus"
}

public enum MonetizationSignal: String, Codable, Sendable {
    case none, adEngaged = "ad_engaged", payer
}

// MARK: - Signal Collector

/// Collects and persists user signals on-device
public actor SignalCollector {

    private var signals = UserSignals()
    private let storage = SignalStorage()

    // MARK: - Lifecycle

    public init() {}

    /// Start collecting signals (call on SDK init)
    public func start() async {
        // Load persisted signals
        signals = await storage.load()

        // Update session data
        signals.sessionCount += 1
        signals.sessionCount7d = await storage.getSessionCount(days: 7) + 1
        signals.sessionCount30d = await storage.getSessionCount(days: 30) + 1
        signals.daysSinceInstall = await storage.daysSinceInstall()
        signals.daysSinceLastSession = await storage.daysSinceLastSession()

        // Persist
        await storage.save(signals)
        await storage.recordSessionStart()
    }

    /// Record session end (call on app background)
    public func endSession(durationMinutes: Double) async {
        // Update average session duration (rolling average)
        let totalSessions = Double(signals.sessionCount)
        let currentAvg = signals.avgSessionMinutes
        signals.avgSessionMinutes = ((currentAvg * (totalSessions - 1)) + durationMinutes) / totalSessions

        await storage.save(signals)
    }

    // MARK: - Event Tracking

    /// Track a custom event
    public func trackEvent(_ name: String, properties: [String: Any]? = nil) {
        signals.eventCount += 1

        // Handle special events
        switch name {
        case "iap_initiated", "purchase_started", "purchase_completed":
            signals.iapEventCount += 1

        case "rewarded_video_completed":
            updateRewardedVideoRate(completed: true)

        case "rewarded_video_started":
            updateRewardedVideoRate(completed: false)

        case "tutorial_completed":
            signals.tutorialCompleted = true
            if let minutes = properties?["duration_minutes"] as? Double {
                signals.tutorialCompletionMinutes = minutes
            }

        case "level_complete", "stage_complete":
            if let level = properties?["level"] as? Int {
                signals.levelReached = max(signals.levelReached, level)
            }

        default:
            break
        }

        // Store custom signal if numeric
        if let value = properties?["value"] {
            if let intVal = value as? Int {
                signals.customSignals[name] = .int(intVal)
            } else if let doubleVal = value as? Double {
                signals.customSignals[name] = .double(doubleVal)
            } else if let boolVal = value as? Bool {
                signals.customSignals[name] = .bool(boolVal)
            }
        }
    }

    private func updateRewardedVideoRate(completed: Bool) {
        // Simple exponential moving average
        let alpha = 0.3
        let newValue: Double = completed ? 1.0 : 0.0
        signals.rewardedVideoCompletionRate = (alpha * newValue) + ((1 - alpha) * signals.rewardedVideoCompletionRate)
    }

    // MARK: - Access

    /// Get current signals snapshot
    public var currentSignals: UserSignals {
        signals
    }
}

// MARK: - Signal Storage

actor SignalStorage {
    private let defaults = UserDefaults.standard
    private let prefix = "perspicis_"

    func load() -> UserSignals {
        var signals = UserSignals()
        signals.sessionCount = defaults.integer(forKey: key("session_count"))
        signals.avgSessionMinutes = defaults.double(forKey: key("avg_session_minutes"))
        signals.eventCount = defaults.integer(forKey: key("event_count"))
        signals.iapEventCount = defaults.integer(forKey: key("iap_event_count"))
        signals.rewardedVideoCompletionRate = defaults.double(forKey: key("rewarded_video_rate"))
        signals.levelReached = defaults.integer(forKey: key("level_reached"))
        signals.tutorialCompleted = defaults.bool(forKey: key("tutorial_completed"))
        signals.tutorialCompletionMinutes = defaults.double(forKey: key("tutorial_completion_minutes"))
        return signals
    }

    func save(_ signals: UserSignals) {
        defaults.set(signals.sessionCount, forKey: key("session_count"))
        defaults.set(signals.avgSessionMinutes, forKey: key("avg_session_minutes"))
        defaults.set(signals.eventCount, forKey: key("event_count"))
        defaults.set(signals.iapEventCount, forKey: key("iap_event_count"))
        defaults.set(signals.rewardedVideoCompletionRate, forKey: key("rewarded_video_rate"))
        defaults.set(signals.levelReached, forKey: key("level_reached"))
        defaults.set(signals.tutorialCompleted, forKey: key("tutorial_completed"))
        defaults.set(signals.tutorialCompletionMinutes, forKey: key("tutorial_completion_minutes"))
    }

    func recordSessionStart() {
        let now = Date()
        defaults.set(now, forKey: key("last_session_start"))

        // Track session timestamps for 7d/30d counts
        var timestamps = defaults.array(forKey: key("session_timestamps")) as? [Date] ?? []
        timestamps.append(now)

        // Keep only last 30 days
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        timestamps = timestamps.filter { $0 > cutoff }
        defaults.set(timestamps, forKey: key("session_timestamps"))
    }

    func getSessionCount(days: Int) -> Int {
        let timestamps = defaults.array(forKey: key("session_timestamps")) as? [Date] ?? []
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return timestamps.filter { $0 > cutoff }.count
    }

    func daysSinceInstall() -> Int {
        if let installDate = defaults.object(forKey: key("install_date")) as? Date {
            return Calendar.current.dateComponents([.day], from: installDate, to: Date()).day ?? 0
        } else {
            defaults.set(Date(), forKey: key("install_date"))
            return 0
        }
    }

    func daysSinceLastSession() -> Int {
        guard let lastSession = defaults.object(forKey: key("last_session_start")) as? Date else {
            return 0
        }
        return Calendar.current.dateComponents([.day], from: lastSession, to: Date()).day ?? 0
    }

    private func key(_ name: String) -> String {
        "\(prefix)\(name)"
    }
}
