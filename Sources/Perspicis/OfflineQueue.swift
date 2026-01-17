import Foundation

/// Persistent event queue with offline support
///
/// Features:
/// - Persists events to disk (UserDefaults)
/// - Monitors network connectivity
/// - Automatically syncs when connection restored
/// - Exponential backoff for failed requests
/// - Deduplication via event IDs
public actor OfflineQueue {

    // MARK: - Types

    public struct QueuedEvent: Codable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let properties: [String: AnyCodableValue]?
        public let timestamp: Date
        public let retryCount: Int
        public let createdAt: Date

        init(name: String, properties: [String: Any]?, timestamp: Date) {
            self.id = UUID().uuidString
            self.name = name
            self.timestamp = timestamp
            self.properties = properties?.compactMapValues { AnyCodableValue($0) }
            self.retryCount = 0
            self.createdAt = Date()
        }

        func incrementRetry() -> QueuedEvent {
            QueuedEvent(
                id: id,
                name: name,
                properties: properties,
                timestamp: timestamp,
                retryCount: retryCount + 1,
                createdAt: createdAt
            )
        }

        private init(id: String, name: String, properties: [String: AnyCodableValue]?, timestamp: Date, retryCount: Int, createdAt: Date) {
            self.id = id
            self.name = name
            self.properties = properties
            self.timestamp = timestamp
            self.retryCount = retryCount
            self.createdAt = createdAt
        }
    }

    public struct QueueStats: Sendable {
        public let pendingCount: Int
        public let oldestEventAge: TimeInterval?
        public let totalRetries: Int
        public let lastSyncTime: Date?
        public let lastSyncSuccess: Bool
    }

    // MARK: - Configuration

    public struct Config: Sendable {
        /// Maximum events to store
        public var maxQueueSize: Int

        /// Events older than this are discarded
        public var maxEventAge: TimeInterval

        /// Maximum retries before discarding
        public var maxRetries: Int

        /// Base delay for exponential backoff (seconds)
        public var baseRetryDelay: TimeInterval

        /// Maximum delay between retries (seconds)
        public var maxRetryDelay: TimeInterval

        /// Batch size for sending
        public var batchSize: Int

        /// Auto-flush interval when connected
        public var flushInterval: TimeInterval

        public init(
            maxQueueSize: Int = 1000,
            maxEventAge: TimeInterval = 7 * 24 * 60 * 60, // 7 days
            maxRetries: Int = 5,
            baseRetryDelay: TimeInterval = 5,
            maxRetryDelay: TimeInterval = 300, // 5 minutes
            batchSize: Int = 50,
            flushInterval: TimeInterval = 60
        ) {
            self.maxQueueSize = maxQueueSize
            self.maxEventAge = maxEventAge
            self.maxRetries = maxRetries
            self.baseRetryDelay = baseRetryDelay
            self.maxRetryDelay = maxRetryDelay
            self.batchSize = batchSize
            self.flushInterval = flushInterval
        }
    }

    // MARK: - Properties

    private var queue: [QueuedEvent] = []
    private let config: Config
    private let apiEndpoint: URL
    private let appKey: String
    private let networkMonitor: NetworkMonitor
    private let storageKey: String

    private var lastSyncTime: Date?
    private var lastSyncSuccess = false
    private var totalRetries = 0
    private var enableDebugLogging = false
    private var flushTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(
        apiEndpoint: URL,
        appKey: String,
        config: Config = Config(),
        networkMonitor: NetworkMonitor? = nil
    ) {
        self.apiEndpoint = apiEndpoint
        self.appKey = appKey
        self.config = config
        self.networkMonitor = networkMonitor ?? NetworkMonitor()
        self.storageKey = "com.perspicis.eventqueue.\(appKey.prefix(20))"
    }

    // MARK: - Public API

    /// Start the queue processor
    public func start() async {
        // Load persisted events
        loadFromStorage()

        // Start network monitoring
        await networkMonitor.start()
        await networkMonitor.setDebugLogging(enableDebugLogging)

        // Start listening for connectivity changes
        startNetworkListener()

        // Start periodic flush
        startPeriodicFlush()

        // Initial sync if connected
        if await networkMonitor.isConnected() {
            await flush()
        }

        log("Offline queue started with \(queue.count) pending events")
    }

    /// Stop the queue processor
    public func stop() async {
        flushTask?.cancel()
        networkTask?.cancel()
        await networkMonitor.stop()
        saveToStorage()
        log("Offline queue stopped")
    }

    /// Add an event to the queue
    public func enqueue(_ event: QueuedEvent) async {
        // Check for duplicates
        if queue.contains(where: { $0.id == event.id }) {
            log("Duplicate event ignored: \(event.id)")
            return
        }

        queue.append(event)
        log("Enqueued: \(event.name) (queue size: \(queue.count))")

        // Enforce max size (remove oldest)
        pruneQueue()

        // Persist
        saveToStorage()

        // Flush if connected and batch size reached
        if queue.count >= config.batchSize {
            let isConnected = await networkMonitor.isConnected()
            if isConnected {
                await flush()
            }
        }
    }

    /// Add an event by parameters
    public func enqueue(name: String, properties: [String: Any]? = nil) async {
        let event = QueuedEvent(name: name, properties: properties, timestamp: Date())
        await enqueue(event)
    }

    /// Force flush all pending events
    public func flush() async {
        guard !queue.isEmpty else {
            log("Nothing to flush")
            return
        }

        guard await networkMonitor.isConnected() else {
            log("Cannot flush: offline")
            return
        }

        log("Flushing \(queue.count) events...")

        // Process in batches
        while !queue.isEmpty {
            let isConnected = await networkMonitor.isConnected()
            guard isConnected else { break }

            let batch = Array(queue.prefix(config.batchSize))

            do {
                try await sendBatch(batch)

                // Remove successfully sent events
                let sentIds = Set(batch.map { $0.id })
                queue.removeAll { sentIds.contains($0.id) }

                lastSyncTime = Date()
                lastSyncSuccess = true
                saveToStorage()

                log("Sent \(batch.count) events, \(queue.count) remaining")

            } catch {
                lastSyncSuccess = false
                log("Batch send failed: \(error)")

                // Increment retry counts and apply backoff
                await handleFailedBatch(batch, error: error)
                break
            }
        }
    }

    /// Get current queue statistics
    public func stats() -> QueueStats {
        let oldestAge: TimeInterval?
        if let oldest = queue.first {
            oldestAge = Date().timeIntervalSince(oldest.createdAt)
        } else {
            oldestAge = nil
        }

        return QueueStats(
            pendingCount: queue.count,
            oldestEventAge: oldestAge,
            totalRetries: totalRetries,
            lastSyncTime: lastSyncTime,
            lastSyncSuccess: lastSyncSuccess
        )
    }

    /// Clear all pending events
    public func clear() {
        queue.removeAll()
        saveToStorage()
        log("Queue cleared")
    }

    /// Enable debug logging
    public func setDebugLogging(_ enabled: Bool) async {
        enableDebugLogging = enabled
        await networkMonitor.setDebugLogging(enabled)
    }

    // MARK: - Private Methods

    private func startNetworkListener() {
        networkTask = Task { [weak self] in
            guard let self = self else { return }

            for await status in await networkMonitor.statusStream() {
                if status == .connected {
                    await self.log("Network restored, triggering flush")
                    await self.flush()
                }
            }
        }
    }

    private func startPeriodicFlush() {
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self?.config.flushInterval ?? 60) * 1_000_000_000)
                await self?.flush()
            }
        }
    }

    private func sendBatch(_ events: [QueuedEvent]) async throws {
        var request = URLRequest(url: apiEndpoint.appendingPathComponent("v1/events"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(appKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let batch = EventBatchPayload(
            appKey: appKey,
            events: events.map { EventPayload(from: $0) }
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(batch)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QueueError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return // Success
        case 401:
            throw QueueError.unauthorized
        case 429:
            throw QueueError.rateLimited
        case 500...599:
            throw QueueError.serverError(httpResponse.statusCode)
        default:
            throw QueueError.httpError(httpResponse.statusCode)
        }
    }

    private func handleFailedBatch(_ batch: [QueuedEvent], error: Error) async {
        totalRetries += batch.count

        for event in batch {
            // Find and update the event in queue
            if let index = queue.firstIndex(where: { $0.id == event.id }) {
                let updated = event.incrementRetry()

                if updated.retryCount >= config.maxRetries {
                    // Max retries reached, discard
                    queue.remove(at: index)
                    log("Event discarded after \(config.maxRetries) retries: \(event.name)")
                } else {
                    // Update with incremented retry count
                    queue[index] = updated

                    // Calculate backoff delay
                    let delay = calculateBackoff(retryCount: updated.retryCount)
                    log("Event \(event.name) will retry in \(Int(delay))s (attempt \(updated.retryCount + 1))")
                }
            }
        }

        saveToStorage()
    }

    private func calculateBackoff(retryCount: Int) -> TimeInterval {
        let delay = config.baseRetryDelay * pow(2.0, Double(retryCount))
        return min(delay, config.maxRetryDelay)
    }

    private func pruneQueue() {
        let now = Date()

        // Remove expired events
        queue.removeAll { event in
            now.timeIntervalSince(event.createdAt) > config.maxEventAge
        }

        // Remove excess events (keep newest)
        if queue.count > config.maxQueueSize {
            let overflow = queue.count - config.maxQueueSize
            queue.removeFirst(overflow)
            log("Pruned \(overflow) oldest events")
        }
    }

    // MARK: - Persistence

    private func loadFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            queue = try decoder.decode([QueuedEvent].self, from: data)
            pruneQueue() // Remove expired events
            log("Loaded \(queue.count) events from storage")
        } catch {
            log("Failed to load queue from storage: \(error)")
        }
    }

    private func saveToStorage() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(queue)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            log("Failed to save queue to storage: \(error)")
        }
    }

    private func log(_ message: String) {
        if enableDebugLogging {
            print("[Perspicis.Queue] \(message)")
        }
    }

    // MARK: - Errors

    enum QueueError: Error, LocalizedError {
        case invalidResponse
        case unauthorized
        case rateLimited
        case serverError(Int)
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid server response"
            case .unauthorized: return "Invalid app key"
            case .rateLimited: return "Rate limited, will retry"
            case .serverError(let code): return "Server error: \(code)"
            case .httpError(let code): return "HTTP error: \(code)"
            }
        }
    }
}

// MARK: - Payload Types

private struct EventBatchPayload: Encodable {
    let appKey: String
    let events: [EventPayload]
}

private struct EventPayload: Encodable {
    let eventId: String
    let name: String
    let properties: [String: AnyCodableValue]?
    let timestamp: Date

    init(from event: OfflineQueue.QueuedEvent) {
        self.eventId = event.id
        self.name = event.name
        self.properties = event.properties
        self.timestamp = event.timestamp
    }
}

// MARK: - AnyCodableValue for Properties

public struct AnyCodableValue: Codable, Sendable {
    private enum ValueType: Codable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
    }

    private let valueType: ValueType

    public var value: Any {
        switch valueType {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        }
    }

    public init?(_ value: Any) {
        if let v = value as? String {
            valueType = .string(v)
        } else if let v = value as? Int {
            valueType = .int(v)
        } else if let v = value as? Double {
            valueType = .double(v)
        } else if let v = value as? Bool {
            valueType = .bool(v)
        } else {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) {
            valueType = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            valueType = .int(v)
        } else if let v = try? container.decode(Double.self) {
            valueType = .double(v)
        } else if let v = try? container.decode(String.self) {
            valueType = .string(v)
        } else {
            throw DecodingError.typeMismatch(
                AnyCodableValue.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported type")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch valueType {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        }
    }
}
