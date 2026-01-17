import Foundation

// =============================================================================
// PHASE 2: Custom Cohort Registration & Export
// =============================================================================
// Enables apps to define their own cohorts evaluated on-device
// Privacy: All computation happens locally - only cohort IDs are exported
// =============================================================================

// MARK: - Errors

public enum CohortError: Error, LocalizedError, Sendable {
    case invalidCohortId(String)
    case noRules(String)
    case invalidTimeWindow(String)
    case invalidMinOccurrences(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCohortId(let msg): return msg
        case .noRules(let msg): return msg
        case .invalidTimeWindow(let msg): return msg
        case .invalidMinOccurrences(let msg): return msg
        }
    }
}

// MARK: - CohortCriteria

/// Definition of a custom cohort with matching rules
public struct CohortCriteria: Codable, Sendable {
    /// Unique identifier (lowercase alphanumeric with underscores, starting with letter)
    public let cohortId: String

    /// Matching rules (all must pass - AND logic)
    public let rules: [CohortRule]

    /// Minimum times rules must be satisfied (default: 1)
    public let minOccurrences: Int

    /// Time window for rule evaluation in days (1-365)
    public let timeWindowDays: Int

    /// Higher priority cohorts listed first (default: 0)
    public let priority: Int

    /// Validated initializer
    public init(
        cohortId: String,
        rules: [CohortRule],
        timeWindowDays: Int = 30,
        minOccurrences: Int = 1,
        priority: Int = 0
    ) throws {
        // Validate cohort ID format: lowercase alphanumeric + underscore, starting with letter
        let pattern = "^[a-z][a-z0-9_]*$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              regex.firstMatch(in: cohortId, range: NSRange(cohortId.startIndex..., in: cohortId)) != nil else {
            throw CohortError.invalidCohortId(
                "Cohort ID must be lowercase alphanumeric with underscores, starting with letter. Got: '\(cohortId)'"
            )
        }

        // Validate rules
        guard !rules.isEmpty else {
            throw CohortError.noRules("At least one rule is required")
        }

        // Validate time window
        guard timeWindowDays >= 1 && timeWindowDays <= 365 else {
            throw CohortError.invalidTimeWindow("Time window must be 1-365 days. Got: \(timeWindowDays)")
        }

        // Validate min occurrences
        guard minOccurrences >= 1 else {
            throw CohortError.invalidMinOccurrences("minOccurrences must be >= 1. Got: \(minOccurrences)")
        }

        self.cohortId = cohortId
        self.rules = rules
        self.timeWindowDays = timeWindowDays
        self.minOccurrences = minOccurrences
        self.priority = priority
    }
}

// MARK: - CohortRule

/// Rule types for cohort matching
public enum CohortRule: Codable, Sendable {

    // Event-based rules
    /// Event occurred at least N times in time window
    case eventCount(event: String, minCount: Int)

    /// Event has property with specific value
    case eventValue(event: String, property: String, equals: CohortRuleValue)

    /// Event property value falls within range
    case eventValueRange(event: String, property: String, min: Double, max: Double)

    // Signal-based rules
    /// Aggregated signal exceeds threshold
    case signalThreshold(signal: String, minValue: Double)

    /// Signal value falls within range
    case signalRange(signal: String, min: Double, max: Double)

    // Time-based rules
    /// Total time in app exceeds threshold
    case timeInApp(minMinutes: Int)

    /// Days since first app launch
    case daysSinceInstall(minDays: Int, maxDays: Int?)

    /// Days since last session (recency)
    case daysSinceLastSession(maxDays: Int)

    // Composite rules
    /// Combine multiple rules with AND/OR logic
    case combined(rules: [CohortRule], requireAll: Bool)

    // MARK: - Convenience Initializers

    /// Event has property with String value
    public static func eventValueString(event: String, property: String, equals value: String) -> CohortRule {
        .eventValue(event: event, property: property, equals: .string(value))
    }

    /// Event has property with Int value
    public static func eventValueInt(event: String, property: String, equals value: Int) -> CohortRule {
        .eventValue(event: event, property: property, equals: .int(value))
    }

    /// Event has property with Double value
    public static func eventValueDouble(event: String, property: String, equals value: Double) -> CohortRule {
        .eventValue(event: event, property: property, equals: .double(value))
    }

    /// Event has property with Bool value
    public static func eventValueBool(event: String, property: String, equals value: Bool) -> CohortRule {
        .eventValue(event: event, property: property, equals: .bool(value))
    }
}

// MARK: - CohortRuleValue

/// Type-erased codable value for cohort rules
public enum CohortRuleValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else {
            throw DecodingError.typeMismatch(CohortRuleValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unknown type"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        }
    }

    /// Check equality with Any value
    public func matches(_ value: Any) -> Bool {
        switch self {
        case .string(let s): return (value as? String) == s
        case .int(let i): return (value as? Int) == i
        case .double(let d): return (value as? Double) == d
        case .bool(let b): return (value as? Bool) == b
        }
    }

    /// Get as Double for numeric comparisons
    public var asDouble: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }
}

// MARK: - Event History Protocol

/// Protocol for accessing event history
public protocol EventHistoryProtocol: Sendable {
    func count(eventName: String, since: Date) -> Int
    func count(eventName: String, where predicate: ([String: Any]) -> Bool, since: Date) -> Int
}

// MARK: - AppCohortMatch

/// Result of cohort evaluation with metadata
public struct AppCohortMatch: Sendable {
    public let cohortId: String
    public let matchedAt: Date
    public let confidence: Double
    public let source: CohortSource
    public let priority: Int

    public init(cohortId: String, matchedAt: Date, confidence: Double, source: CohortSource, priority: Int) {
        self.cohortId = cohortId
        self.matchedAt = matchedAt
        self.confidence = confidence
        self.source = source
        self.priority = priority
    }
}

/// Where cohort was defined
public enum CohortSource: String, Codable, Sendable {
    case serverDefined
    case appDefined
}

// MARK: - CohortRegistry

/// Manages custom cohort definitions
public actor CohortRegistry {

    // MARK: - Properties

    private var registeredCohorts: [String: CohortCriteria] = [:]
    private let persistenceKey = "perspicis_custom_cohorts"
    private var debugLogging = false

    // MARK: - Init

    public init() {
        // Load persisted cohorts synchronously on init
        if let data = UserDefaults.standard.data(forKey: persistenceKey),
           let cohorts = try? JSONDecoder().decode([String: CohortCriteria].self, from: data) {
            registeredCohorts = cohorts
        }
    }

    // MARK: - Registration

    /// Register a custom cohort definition
    public func register(_ criteria: CohortCriteria) throws {
        registeredCohorts[criteria.cohortId] = criteria
        persist()
        log("Registered cohort: \(criteria.cohortId) with \(criteria.rules.count) rules")
    }

    /// Register multiple cohorts atomically
    public func registerMultiple(_ criteriaList: [CohortCriteria]) throws {
        for criteria in criteriaList {
            registeredCohorts[criteria.cohortId] = criteria
        }
        persist()
        log("Registered \(criteriaList.count) cohorts")
    }

    /// Remove a registered cohort
    public func unregister(cohortId: String) {
        registeredCohorts.removeValue(forKey: cohortId)
        persist()
        log("Unregistered cohort: \(cohortId)")
    }

    /// Get all registered cohort IDs
    public func getRegisteredIds() -> [String] {
        Array(registeredCohorts.keys).sorted()
    }

    // MARK: - Evaluation

    /// Evaluate all registered cohorts against user signals
    public func evaluate(signals: UserSignals, eventHistory: EventHistoryProtocol) -> [AppCohortMatch] {
        var matches: [AppCohortMatch] = []

        for (cohortId, criteria) in registeredCohorts {
            if evaluateCriteria(criteria, signals: signals, eventHistory: eventHistory) {
                matches.append(AppCohortMatch(
                    cohortId: cohortId,
                    matchedAt: Date(),
                    confidence: 1.0,
                    source: .appDefined,
                    priority: criteria.priority
                ))
            }
        }

        // Sort by priority (highest first)
        matches.sort { $0.priority > $1.priority }

        return matches
    }

    // MARK: - Rule Evaluation

    private func evaluateCriteria(
        _ criteria: CohortCriteria,
        signals: UserSignals,
        eventHistory: EventHistoryProtocol
    ) -> Bool {
        // All rules must pass (AND logic)
        for rule in criteria.rules {
            if !evaluateRule(rule, signals: signals, eventHistory: eventHistory, timeWindowDays: criteria.timeWindowDays) {
                return false
            }
        }
        return true
    }

    private func evaluateRule(
        _ rule: CohortRule,
        signals: UserSignals,
        eventHistory: EventHistoryProtocol,
        timeWindowDays: Int
    ) -> Bool {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -timeWindowDays, to: Date()) ?? Date()

        switch rule {
        case .eventCount(let event, let minCount):
            let count = eventHistory.count(eventName: event, since: cutoffDate)
            return count >= minCount

        case .eventValue(let event, let property, let equals):
            let count = eventHistory.count(eventName: event, where: { props in
                guard let value = props[property] else { return false }
                return equals.matches(value)
            }, since: cutoffDate)
            return count > 0

        case .eventValueRange(let event, let property, let min, let max):
            let count = eventHistory.count(eventName: event, where: { props in
                guard let value = props[property] as? Double else { return false }
                return value >= min && value <= max
            }, since: cutoffDate)
            return count > 0

        case .signalThreshold(let signal, let minValue):
            if let signalValue = signals.customSignals[signal]?.asDouble {
                return signalValue >= minValue
            }
            return false

        case .signalRange(let signal, let min, let max):
            if let signalValue = signals.customSignals[signal]?.asDouble {
                return signalValue >= min && signalValue <= max
            }
            return false

        case .timeInApp(let minMinutes):
            // Use avgSessionMinutes * sessionCount as approximation
            let totalMinutes = signals.avgSessionMinutes * Double(signals.sessionCount)
            return totalMinutes >= Double(minMinutes)

        case .daysSinceInstall(let minDays, let maxDays):
            let days = signals.daysSinceInstall
            if days < minDays { return false }
            if let maxDays = maxDays, days > maxDays { return false }
            return true

        case .daysSinceLastSession(let maxDays):
            return signals.daysSinceLastSession <= maxDays

        case .combined(let rules, let requireAll):
            if requireAll {
                // AND logic
                for subRule in rules {
                    if !evaluateRule(subRule, signals: signals, eventHistory: eventHistory, timeWindowDays: timeWindowDays) {
                        return false
                    }
                }
                return true
            } else {
                // OR logic
                for subRule in rules {
                    if evaluateRule(subRule, signals: signals, eventHistory: eventHistory, timeWindowDays: timeWindowDays) {
                        return true
                    }
                }
                return false
            }
        }
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(registeredCohorts) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func loadPersistedCohorts() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey) else { return }
        let decoder = JSONDecoder()
        if let cohorts = try? decoder.decode([String: CohortCriteria].self, from: data) {
            registeredCohorts = cohorts
            log("Loaded \(cohorts.count) persisted cohorts")
        }
    }

    // MARK: - Debug

    public func setDebugLogging(_ enabled: Bool) {
        debugLogging = enabled
    }

    private func log(_ message: String) {
        if debugLogging {
            print("[CohortRegistry] \(message)")
        }
    }
}

// MARK: - MAX Targeting Data

/// Targeting data formatted for AppLovin MAX
public struct MAXTargetingData: Sendable {
    public let cohorts: [String]
    public let keywords: [String]
    public let customData: [String: String]

    public init(cohorts: [String], keywords: [String], customData: [String: String]) {
        self.cohorts = cohorts
        self.keywords = keywords
        self.customData = customData
    }

    /// Format for MAX local extra parameters
    public func toLocalExtraParameters() -> [String: Any] {
        [
            "perspicis_cohorts": cohorts,
            "perspicis_keywords": keywords.joined(separator: ",")
        ]
    }
}

// MARK: - AdMob Targeting

/// Targeting data formatted for Google Mobile Ads
public struct AdMobTargeting: Sendable {
    public let cohorts: String
    public let sdkVersion: String
    public let privacyStatus: String

    public init(cohorts: String, sdkVersion: String, privacyStatus: String) {
        self.cohorts = cohorts
        self.sdkVersion = sdkVersion
        self.privacyStatus = privacyStatus
    }

    public func toDictionary() -> [String: String] {
        [
            "perspicis_cohorts": cohorts,
            "perspicis_version": sdkVersion,
            "perspicis_privacy": privacyStatus
        ]
    }
}
