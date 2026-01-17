import Foundation

// MARK: - Cohort Rule Models

/// Represents a complete cohort rule set from the backend
public struct CohortRuleSet: Codable, Sendable {
    public let version: Int
    public let appId: String
    public let updatedAt: Date
    public let cohorts: [CohortDefinition]

    enum CodingKeys: String, CodingKey {
        case version
        case appId = "app_id"
        case updatedAt = "updated_at"
        case cohorts
    }

    /// Memberwise initializer for testing
    public init(version: Int, appId: String, updatedAt: Date, cohorts: [CohortDefinition]) {
        self.version = version
        self.appId = appId
        self.updatedAt = updatedAt
        self.cohorts = cohorts
    }
}

/// A single cohort definition with conditions
public struct CohortDefinition: Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let conditions: [CohortCondition]
    public let priority: Int
    public let advertiserValue: AdvertiserValue

    enum CodingKeys: String, CodingKey {
        case id, name, description, conditions, priority
        case advertiserValue = "advertiser_value"
    }

    /// Memberwise initializer for testing/manual creation
    public init(
        id: String,
        name: String,
        description: String? = nil,
        conditions: [CohortCondition],
        priority: Int = 0,
        advertiserValue: AdvertiserValue = .standard
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.conditions = conditions
        self.priority = priority
        self.advertiserValue = advertiserValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        conditions = try container.decode([CohortCondition].self, forKey: .conditions)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        advertiserValue = try container.decodeIfPresent(AdvertiserValue.self, forKey: .advertiserValue) ?? .standard
    }
}

public enum AdvertiserValue: String, Codable, Sendable {
    case premium, standard, low
}

/// A condition within a cohort rule
public struct CohortCondition: Codable, Sendable {
    public let field: SignalField
    public let customField: String?
    public let op: Operator
    public let value: ConditionValue

    enum CodingKeys: String, CodingKey {
        case field
        case customField = "custom_field"
        case op
        case value
    }

    /// Memberwise initializer for testing
    public init(field: SignalField, customField: String? = nil, op: Operator, value: ConditionValue) {
        self.field = field
        self.customField = customField
        self.op = op
        self.value = value
    }
}

public enum SignalField: String, Codable, Sendable {
    case sessionCount = "session_count"
    case sessionCount7d = "session_count_7d"
    case sessionCount30d = "session_count_30d"
    case avgSessionMinutes = "avg_session_minutes"
    case daysSinceInstall = "days_since_install"
    case daysSinceLastSession = "days_since_last_session"
    case eventCount = "event_count"
    case iapEventCount = "iap_event_count"
    case rewardedVideoCompletionRate = "rewarded_video_completion_rate"
    case levelReached = "level_reached"
    case tutorialCompleted = "tutorial_completed"
    case tutorialCompletionMinutes = "tutorial_completion_minutes"
    case custom
}

public enum Operator: String, Codable, Sendable {
    case eq, neq, gt, gte, lt, lte, `in`, between
}

public enum ConditionValue: Codable, Sendable {
    case int(Int)
    case double(Double)
    case string(String)
    case bool(Bool)
    case array([String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
        } else if let boolVal = try? container.decode(Bool.self) {
            self = .bool(boolVal)
        } else if let stringVal = try? container.decode(String.self) {
            self = .string(stringVal)
        } else if let arrayVal = try? container.decode([String].self) {
            self = .array(arrayVal)
        } else {
            throw DecodingError.typeMismatch(
                ConditionValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown value type")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        }
    }

    var asDouble: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }

    var asBool: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
}

// MARK: - Cohort Engine

/// On-device cohort computation engine with dynamic rule loading
public actor CohortEngine {

    // MARK: - Properties

    private var ruleSet: CohortRuleSet?
    private var cachedVersion: Int = 0
    private let cache: RuleCache
    private let apiClient: CohortAPIClient
    private let config: EngineConfig

    public struct EngineConfig {
        public var cacheMaxAge: TimeInterval = 3600 // 1 hour
        public var fetchTimeout: TimeInterval = 10
        public var enableDebugLogging: Bool = false

        public init() {}
    }

    // MARK: - Init

    public init(apiClient: CohortAPIClient, config: EngineConfig = EngineConfig()) {
        self.apiClient = apiClient
        self.config = config
        self.cache = RuleCache()
    }

    // MARK: - Public API

    /// Load rules from backend (with local cache fallback)
    public func loadRules(appKey: String) async throws {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Try cache first
        if let cached = await cache.load(), !cached.isExpired(maxAge: config.cacheMaxAge) {
            self.ruleSet = cached.ruleSet
            self.cachedVersion = cached.ruleSet.version
            log("Loaded \(cached.ruleSet.cohorts.count) rules from cache (v\(cached.ruleSet.version))")
            return
        }

        // Fetch from backend
        do {
            let newRuleSet = try await apiClient.fetchRules(appKey: appKey, currentVersion: cachedVersion)

            if let newRuleSet = newRuleSet {
                self.ruleSet = newRuleSet
                self.cachedVersion = newRuleSet.version
                await cache.save(newRuleSet)
                log("Fetched \(newRuleSet.cohorts.count) rules from backend (v\(newRuleSet.version))")
            } else {
                log("Rules unchanged (v\(cachedVersion))")
            }
        } catch {
            // Fallback to any cached rules (even expired)
            if let cached = await cache.load() {
                self.ruleSet = cached.ruleSet
                log("Using stale cache due to network error: \(error)")
            } else {
                throw CohortEngineError.noRulesAvailable(underlying: error)
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        log("Rule load completed in \(String(format: "%.1f", elapsed))ms")
    }

    /// Compute matching cohorts for given signals
    /// - Returns: Array of cohort IDs, sorted by priority (highest first)
    public func computeCohorts(from signals: UserSignals) -> [CohortMatch] {
        guard let ruleSet = ruleSet else {
            log("No rules loaded, returning empty cohorts")
            return []
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        var matches: [CohortMatch] = []

        for cohort in ruleSet.cohorts {
            if evaluateCohort(cohort, signals: signals) {
                matches.append(CohortMatch(
                    id: cohort.id,
                    priority: cohort.priority,
                    advertiserValue: cohort.advertiserValue
                ))
            }
        }

        // Sort by priority descending
        matches.sort { $0.priority > $1.priority }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        log("Computed \(matches.count) cohorts in \(String(format: "%.2f", elapsed))ms")

        return matches
    }

    /// Get just the cohort IDs (convenience method)
    public func getCohortIds(from signals: UserSignals) -> [String] {
        computeCohorts(from: signals).map(\.id)
    }

    // MARK: - Evaluation

    private func evaluateCohort(_ cohort: CohortDefinition, signals: UserSignals) -> Bool {
        // All conditions must match (AND logic)
        for condition in cohort.conditions {
            if !evaluateCondition(condition, signals: signals) {
                return false
            }
        }
        return true
    }

    private func evaluateCondition(_ condition: CohortCondition, signals: UserSignals) -> Bool {
        let signalValue = getSignalValue(field: condition.field, customField: condition.customField, signals: signals)

        switch condition.op {
        case .eq:
            return compareEqual(signalValue, condition.value)
        case .neq:
            return !compareEqual(signalValue, condition.value)
        case .gt:
            return compareNumeric(signalValue, condition.value) { $0 > $1 }
        case .gte:
            return compareNumeric(signalValue, condition.value) { $0 >= $1 }
        case .lt:
            return compareNumeric(signalValue, condition.value) { $0 < $1 }
        case .lte:
            return compareNumeric(signalValue, condition.value) { $0 <= $1 }
        case .in:
            return compareIn(signalValue, condition.value)
        case .between:
            return compareBetween(signalValue, condition.value)
        }
    }

    private func getSignalValue(field: SignalField, customField: String?, signals: UserSignals) -> ConditionValue {
        switch field {
        case .sessionCount: return .int(signals.sessionCount)
        case .sessionCount7d: return .int(signals.sessionCount7d)
        case .sessionCount30d: return .int(signals.sessionCount30d)
        case .avgSessionMinutes: return .double(signals.avgSessionMinutes)
        case .daysSinceInstall: return .int(signals.daysSinceInstall)
        case .daysSinceLastSession: return .int(signals.daysSinceLastSession)
        case .eventCount: return .int(signals.eventCount)
        case .iapEventCount: return .int(signals.iapEventCount)
        case .rewardedVideoCompletionRate: return .double(signals.rewardedVideoCompletionRate)
        case .levelReached: return .int(signals.levelReached)
        case .tutorialCompleted: return .bool(signals.tutorialCompleted)
        case .tutorialCompletionMinutes: return .double(signals.tutorialCompletionMinutes)
        case .custom:
            if let customField = customField, let value = signals.customSignals[customField] {
                return value
            }
            return .int(0)
        }
    }

    private func compareEqual(_ a: ConditionValue, _ b: ConditionValue) -> Bool {
        switch (a, b) {
        case (.int(let av), .int(let bv)): return av == bv
        case (.double(let av), .double(let bv)): return av == bv
        case (.string(let av), .string(let bv)): return av == bv
        case (.bool(let av), .bool(let bv)): return av == bv
        case (.int(let av), .double(let bv)): return Double(av) == bv
        case (.double(let av), .int(let bv)): return av == Double(bv)
        default: return false
        }
    }

    private func compareNumeric(_ a: ConditionValue, _ b: ConditionValue, _ op: (Double, Double) -> Bool) -> Bool {
        guard let av = a.asDouble, let bv = b.asDouble else { return false }
        return op(av, bv)
    }

    private func compareIn(_ a: ConditionValue, _ b: ConditionValue) -> Bool {
        guard case .string(let av) = a, case .array(let bv) = b else { return false }
        return bv.contains(av)
    }

    private func compareBetween(_ a: ConditionValue, _ b: ConditionValue) -> Bool {
        guard let av = a.asDouble, case .array(let bv) = b, bv.count == 2,
              let min = Double(bv[0]), let max = Double(bv[1]) else { return false }
        return av >= min && av <= max
    }

    // MARK: - Logging

    private func log(_ message: String) {
        if config.enableDebugLogging {
            print("[CohortEngine] \(message)")
        }
    }
}

// MARK: - Cohort Match

public struct CohortMatch: Sendable {
    public let id: String
    public let priority: Int
    public let advertiserValue: AdvertiserValue
}

// MARK: - Errors

public enum CohortEngineError: Error {
    case noRulesAvailable(underlying: Error)
    case invalidRuleFormat
}

// MARK: - Rule Cache

actor RuleCache {
    private let cacheKey = "perspicis_cohort_rules"
    private let timestampKey = "perspicis_cohort_rules_timestamp"

    struct CachedRules {
        let ruleSet: CohortRuleSet
        let timestamp: Date

        func isExpired(maxAge: TimeInterval) -> Bool {
            Date().timeIntervalSince(timestamp) > maxAge
        }
    }

    func load() -> CachedRules? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let timestamp = UserDefaults.standard.object(forKey: timestampKey) as? Date else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let ruleSet = try? decoder.decode(CohortRuleSet.self, from: data) else {
            return nil
        }

        return CachedRules(ruleSet: ruleSet, timestamp: timestamp)
    }

    func save(_ ruleSet: CohortRuleSet) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(ruleSet) else { return }

        UserDefaults.standard.set(data, forKey: cacheKey)
        UserDefaults.standard.set(Date(), forKey: timestampKey)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: timestampKey)
    }
}

// MARK: - API Client Protocol

public protocol CohortAPIClient: Sendable {
    /// Fetch rules from backend. Returns nil if version unchanged (304).
    func fetchRules(appKey: String, currentVersion: Int) async throws -> CohortRuleSet?
}

// MARK: - Default HTTP Client

public final class HTTPCohortAPIClient: CohortAPIClient, Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval

    public init(baseURL: URL, timeout: TimeInterval = 10) {
        self.baseURL = baseURL
        self.timeout = timeout

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: config)
    }

    public func fetchRules(appKey: String, currentVersion: Int) async throws -> CohortRuleSet? {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/cohorts/rules"))
        request.setValue("Bearer \(appKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(currentVersion), forHTTPHeaderField: "If-None-Match")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CohortRuleSet.self, from: data)
        case 304:
            return nil // Not modified
        default:
            throw URLError(.badServerResponse)
        }
    }
}
