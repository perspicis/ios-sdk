// =============================================================================
// Perspicis Spark Telemetry - OpenTelemetry Export
// =============================================================================
//
// Automatic, invisible instrumentation that exports to Grafana.
// Developers write 2 lines. We collect 200 data points.
//
// =============================================================================

import Foundation

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Spark Telemetry (OpenTelemetry Compatible)

/// Automatic telemetry collection with OpenTelemetry export
///
/// All telemetry is:
/// - Collected automatically (no developer code needed)
/// - Batched for efficiency
/// - Exported in OTLP format
/// - Privacy-safe (no PII)
///
public final class SparkTelemetry {

    // MARK: - Singleton

    public static let shared = SparkTelemetry()

    // MARK: - Configuration

    /// Telemetry endpoint (OTLP compatible)
    /// - Simulator: localhost:8090 (connects to your Mac's telemetry collector)
    /// - Device in demo/test mode: localhost:8090 (won't work without custom setup)
    /// - Device in live mode: telemetry.perspicis.io (production)
    ///
    /// Override for custom setups:
    /// ```swift
    /// SparkTelemetry.shared.endpoint = URL(string: "https://your-server.com/v1/otlp")
    /// ```
    public var endpoint: URL? = {
        #if targetEnvironment(simulator)
        // Simulator can reach Mac host via localhost
        return URL(string: "http://localhost:8090/v1/otlp")
        #else
        // Real device - use production endpoint
        // For local testing on device, override this with your Mac's IP
        return URL(string: "https://telemetry.perspicis.io/v1/otlp")
        #endif
    }()

    /// Configure telemetry endpoint
    /// - Parameter url: Custom endpoint URL
    public func configure(endpoint url: URL) {
        self.endpoint = url
        if debugMode {
            print("[Perspicis] Telemetry endpoint: \(url.absoluteString)")
        }
    }

    /// Configure for local development (use Mac's IP for real device testing)
    /// - Parameter macIP: Your Mac's local IP address (e.g., "192.168.1.100")
    public func configureForLocalDevice(macIP: String) {
        let url = URL(string: "http://\(macIP):8090/v1/otlp")!
        configure(endpoint: url)
    }

    /// Batch size before auto-flush
    public var batchSize: Int = 10  // Smaller batch for faster dev feedback

    /// Flush interval in seconds
    public var flushInterval: TimeInterval = 5  // Faster flush for dev

    /// Enable debug logging
    public var debugMode: Bool = false  // Disabled by default for production

    // MARK: - Internal State

    private var events: [TelemetryEvent] = []
    private var metrics: [String: TelemetryMetric] = [:]
    private var spans: [TelemetrySpan] = []
    private let queue = DispatchQueue(label: "com.perspicis.telemetry", qos: .utility)
    private var flushTimer: Timer?
    private var sessionId: String
    private var sessionStartTime: Date

    /// Track ad request start times for latency measurement
    private var adRequestStartTimes: [String: Date] = [:]

    // MARK: - Device Context (collected once)

    private lazy var deviceContext: [String: Any] = {
        var context: [String: Any] = [
            "sdk_version": PerspicisSDK.version,
            "sdk_name": "perspicis-ios",
            "telemetry_version": "1.0.0"
        ]

        #if os(iOS)
        context["os_name"] = "iOS"
        context["os_version"] = UIDevice.current.systemVersion
        context["device_model"] = UIDevice.current.model
        context["device_name"] = UIDevice.current.name

        // Screen info
        let screen = UIScreen.main
        context["screen_width"] = Int(screen.bounds.width * screen.scale)
        context["screen_height"] = Int(screen.bounds.height * screen.scale)
        context["screen_scale"] = screen.scale
        #else
        context["os_name"] = "macOS"
        if #available(macOS 10.15, *) {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            context["os_version"] = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        }
        #endif

        // App info
        if let info = Bundle.main.infoDictionary {
            context["app_version"] = info["CFBundleShortVersionString"] as? String ?? "unknown"
            context["app_build"] = info["CFBundleVersion"] as? String ?? "unknown"
            context["app_bundle_id"] = info["CFBundleIdentifier"] as? String ?? "unknown"
        }

        // Locale
        context["locale"] = Locale.current.identifier
        context["timezone"] = TimeZone.current.identifier

        return context
    }()

    // MARK: - Init

    private init() {
        sessionId = UUID().uuidString
        sessionStartTime = Date()

        // Start flush timer
        startFlushTimer()

        // Track session start
        trackEvent("session_start")

        // Track app lifecycle
        setupLifecycleObservers()
    }

    deinit {
        flushTimer?.invalidate()
    }

    // MARK: - Public API: Events

    /// Track an event
    ///
    /// ```swift
    /// SparkTelemetry.shared.trackEvent("ad_shown", properties: ["placement": "banner"])
    /// ```
    ///
    public func trackEvent(_ name: String, properties: [String: Any] = [:]) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let event = TelemetryEvent(
                name: name,
                timestamp: Date(),
                properties: properties,
                sessionId: self.sessionId
            )

            self.events.append(event)

            if self.debugMode {
                print("[Perspicis/Telemetry] Event: \(name) \(properties)")
            }

            // Auto-flush if batch is full
            if self.events.count >= self.batchSize {
                self.flush()
            }
        }
    }

    // MARK: - Public API: Metrics

    /// Increment a counter metric
    public func incrementCounter(_ name: String, value: Int = 1, tags: [String: String] = [:]) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let key = "\(name):\(tags.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))"

            if var metric = self.metrics[key] {
                metric.value += Double(value)
                self.metrics[key] = metric
            } else {
                self.metrics[key] = TelemetryMetric(
                    name: name,
                    type: .counter,
                    value: Double(value),
                    tags: tags
                )
            }
        }
    }

    /// Record a gauge metric
    public func recordGauge(_ name: String, value: Double, tags: [String: String] = [:]) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let key = "\(name):\(tags.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))"

            self.metrics[key] = TelemetryMetric(
                name: name,
                type: .gauge,
                value: value,
                tags: tags
            )
        }
    }

    /// Record a histogram value (for latency, sizes, etc.)
    public func recordHistogram(_ name: String, value: Double, tags: [String: String] = [:]) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let key = "\(name):\(tags.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))"

            if var metric = self.metrics[key] {
                metric.histogramValues.append(value)
                self.metrics[key] = metric
            } else {
                var metric = TelemetryMetric(
                    name: name,
                    type: .histogram,
                    value: 0,
                    tags: tags
                )
                metric.histogramValues = [value]
                self.metrics[key] = metric
            }
        }
    }

    // MARK: - Public API: Spans (Tracing)

    /// Start a span for tracing
    public func startSpan(_ name: String, attributes: [String: Any] = [:]) -> SpanContext {
        let span = TelemetrySpan(
            traceId: UUID().uuidString,
            spanId: UUID().uuidString,
            name: name,
            startTime: Date(),
            attributes: attributes
        )

        queue.async { [weak self] in
            self?.spans.append(span)
        }

        return SpanContext(spanId: span.spanId, telemetry: self)
    }

    /// End a span
    func endSpan(_ spanId: String, status: SpanStatus = .ok, attributes: [String: Any] = [:]) {
        queue.async { [weak self] in
            guard let self = self,
                  let index = self.spans.firstIndex(where: { $0.spanId == spanId }) else { return }

            var span = self.spans[index]
            span.endTime = Date()
            span.status = status
            span.attributes.merge(attributes) { _, new in new }
            self.spans[index] = span

            if self.debugMode {
                let duration = span.endTime!.timeIntervalSince(span.startTime) * 1000
                print("[Perspicis/Telemetry] Span: \(span.name) completed in \(Int(duration))ms")
            }
        }
    }

    // MARK: - Ad-Specific Tracking

    /// Track ad request - starts the latency timer
    public func trackAdRequest(placement: String) {
        queue.async { [weak self] in
            self?.adRequestStartTimes[placement] = Date()
        }
        trackEvent("ad_request", properties: ["placement": placement])
        incrementCounter("ad_requests_total", tags: ["placement": placement])
    }

    /// Track ad fill with automatic latency calculation
    /// Call this after trackAdRequest() - latency is auto-measured
    public func trackAdFill(placement: String, adId: String) {
        var latencyMs: Int = 0

        queue.sync { [weak self] in
            if let startTime = self?.adRequestStartTimes[placement] {
                latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)
                self?.adRequestStartTimes.removeValue(forKey: placement)
            }
        }

        trackAdFill(placement: placement, adId: adId, latencyMs: latencyMs)
    }

    /// Track ad fill with explicit latency (for cases where you measure yourself)
    public func trackAdFill(placement: String, adId: String, latencyMs: Int) {
        // Clear any pending start time
        queue.async { [weak self] in
            self?.adRequestStartTimes.removeValue(forKey: placement)
        }

        trackEvent("ad_fill", properties: [
            "placement": placement,
            "ad_id": adId,
            "latency_ms": latencyMs
        ])
        incrementCounter("ad_fills_total", tags: ["placement": placement])
        recordHistogram("ad_fill_latency_ms", value: Double(latencyMs), tags: ["placement": placement])

        if debugMode {
            print("[Perspicis/Telemetry] Ad fill latency: \(latencyMs)ms for \(placement)")
        }
    }

    /// Track ad no-fill - also clears the latency timer
    public func trackAdNoFill(placement: String, reason: String) {
        queue.async { [weak self] in
            self?.adRequestStartTimes.removeValue(forKey: placement)
        }

        trackEvent("ad_no_fill", properties: [
            "placement": placement,
            "reason": reason
        ])
        incrementCounter("ad_no_fills_total", tags: ["placement": placement, "reason": reason])
    }

    /// Track ad impression
    public func trackImpression(placement: String, adId: String) {
        trackEvent("ad_impression", properties: [
            "placement": placement,
            "ad_id": adId
        ])
        incrementCounter("ad_impressions_total", tags: ["placement": placement])
    }

    /// Track ad click
    public func trackClick(placement: String, adId: String) {
        trackEvent("ad_click", properties: [
            "placement": placement,
            "ad_id": adId
        ])
        incrementCounter("ad_clicks_total", tags: ["placement": placement])
    }

    /// Track revenue
    public func trackRevenue(placement: String, amount: Double, currency: String = "USD") {
        trackEvent("ad_revenue", properties: [
            "placement": placement,
            "amount": amount,
            "currency": currency
        ])
        incrementCounter("ad_revenue_total", tags: ["placement": placement, "currency": currency])
    }

    // MARK: - Flush

    /// Flush all pending telemetry to the server
    public func flush() {
        queue.async { [weak self] in
            guard let self = self else { return }

            let eventsToSend = self.events
            let metricsToSend = self.metrics
            let spansToSend = self.spans.filter { $0.endTime != nil }

            // Clear sent data
            self.events.removeAll()
            self.spans.removeAll { $0.endTime != nil }

            // Build OTLP payload
            let payload = self.buildOTLPPayload(
                events: eventsToSend,
                metrics: metricsToSend,
                spans: spansToSend
            )

            // Send to server
            self.sendPayload(payload)
        }
    }

    // MARK: - Private: Timer

    private func startFlushTimer() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
            self?.flush()
        }
    }

    // MARK: - Private: Lifecycle

    private func setupLifecycleObservers() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.trackEvent("app_foreground")
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.trackEvent("app_background")
            self?.flush() // Flush before going to background
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.trackEvent("session_end")
            self?.flush()
        }
        #endif
    }

    // MARK: - Private: OTLP Payload Builder

    private func buildOTLPPayload(
        events: [TelemetryEvent],
        metrics: [String: TelemetryMetric],
        spans: [TelemetrySpan]
    ) -> [String: Any] {
        let timestamp = ISO8601DateFormatter().string(from: Date())

        // Resource attributes (device context)
        let resource: [String: Any] = [
            "attributes": deviceContext.map { ["key": $0.key, "value": ["stringValue": "\($0.value)"]] }
        ]

        // Convert events to OTLP logs
        let logs: [[String: Any]] = events.map { event in
            var attributes: [[String: Any]] = [
                ["key": "event.name", "value": ["stringValue": event.name]],
                ["key": "session.id", "value": ["stringValue": event.sessionId]]
            ]
            for (key, value) in event.properties {
                attributes.append(["key": key, "value": ["stringValue": "\(value)"]])
            }

            return [
                "timeUnixNano": "\(Int(event.timestamp.timeIntervalSince1970 * 1_000_000_000))",
                "severityNumber": 9, // INFO
                "severityText": "INFO",
                "body": ["stringValue": event.name],
                "attributes": attributes
            ]
        }

        // Convert metrics to OTLP format
        let otlpMetrics: [[String: Any]] = metrics.values.map { metric in
            var data: [String: Any] = [
                "name": metric.name,
                "description": ""
            ]

            let dataPoint: [String: Any] = [
                "timeUnixNano": "\(Int(Date().timeIntervalSince1970 * 1_000_000_000))",
                "attributes": metric.tags.map { ["key": $0.key, "value": ["stringValue": $0.value]] }
            ]

            switch metric.type {
            case .counter:
                var counterPoint = dataPoint
                counterPoint["asDouble"] = metric.value
                data["sum"] = [
                    "dataPoints": [counterPoint],
                    "isMonotonic": true,
                    "aggregationTemporality": 2 // CUMULATIVE
                ]
            case .gauge:
                var gaugePoint = dataPoint
                gaugePoint["asDouble"] = metric.value
                data["gauge"] = ["dataPoints": [gaugePoint]]
            case .histogram:
                var histPoint = dataPoint
                histPoint["count"] = metric.histogramValues.count
                histPoint["sum"] = metric.histogramValues.reduce(0, +)
                histPoint["min"] = metric.histogramValues.min() ?? 0
                histPoint["max"] = metric.histogramValues.max() ?? 0
                data["histogram"] = [
                    "dataPoints": [histPoint],
                    "aggregationTemporality": 2
                ]
            }

            return data
        }

        // Convert spans to OTLP format
        let otlpSpans: [[String: Any]] = spans.map { span in
            var spanData: [String: Any] = [
                "traceId": span.traceId.replacingOccurrences(of: "-", with: ""),
                "spanId": String(span.spanId.replacingOccurrences(of: "-", with: "").prefix(16)),
                "name": span.name,
                "startTimeUnixNano": "\(Int(span.startTime.timeIntervalSince1970 * 1_000_000_000))",
                "endTimeUnixNano": "\(Int((span.endTime ?? Date()).timeIntervalSince1970 * 1_000_000_000))",
                "kind": 1, // INTERNAL
                "status": ["code": span.status == .ok ? 1 : 2]
            ]

            spanData["attributes"] = span.attributes.map { ["key": $0.key, "value": ["stringValue": "\($0.value)"]] }

            return spanData
        }

        return [
            "resourceLogs": [
                [
                    "resource": resource,
                    "scopeLogs": [
                        [
                            "scope": ["name": "perspicis-sdk", "version": "2.0.0"],
                            "logRecords": logs
                        ]
                    ]
                ]
            ],
            "resourceMetrics": [
                [
                    "resource": resource,
                    "scopeMetrics": [
                        [
                            "scope": ["name": "perspicis-sdk", "version": "2.0.0"],
                            "metrics": otlpMetrics
                        ]
                    ]
                ]
            ],
            "resourceSpans": [
                [
                    "resource": resource,
                    "scopeSpans": [
                        [
                            "scope": ["name": "perspicis-sdk", "version": "2.0.0"],
                            "spans": otlpSpans
                        ]
                    ]
                ]
            ]
        ]
    }

    // MARK: - Private: Send Payload

    private func sendPayload(_ payload: [String: Any]) {
        // Use Perspicis server endpoint or default
        let telemetryEndpoint = endpoint ?? URL(string: "https://telemetry.perspicis.io/v1/otlp")!

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            if debugMode { print("[Perspicis/Telemetry] Failed to serialize payload") }
            return
        }

        var request = URLRequest(url: telemetryEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(PerspicisSDK.shared.currentAppKey ?? "demo", forHTTPHeaderField: "X-Perspicis-App-Key")
        request.httpBody = jsonData

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self, self.debugMode else { return }

            if let error = error {
                print("[Perspicis/Telemetry] Send failed: \(error.localizedDescription)")
            } else if let httpResponse = response as? HTTPURLResponse {
                print("[Perspicis/Telemetry] Sent \(jsonData.count) bytes, status: \(httpResponse.statusCode)")
            }
        }.resume()
    }
}

// MARK: - Supporting Types

struct TelemetryEvent {
    let name: String
    let timestamp: Date
    var properties: [String: Any]
    let sessionId: String
}

struct TelemetryMetric {
    let name: String
    let type: MetricType
    var value: Double
    let tags: [String: String]
    var histogramValues: [Double] = []

    enum MetricType {
        case counter
        case gauge
        case histogram
    }
}

struct TelemetrySpan {
    let traceId: String
    let spanId: String
    let name: String
    let startTime: Date
    var endTime: Date?
    var status: SpanStatus = .ok
    var attributes: [String: Any]
}

public enum SpanStatus {
    case ok
    case error
}

/// Context for tracking span lifecycle
public class SpanContext {
    private let spanId: String
    private weak var telemetry: SparkTelemetry?

    init(spanId: String, telemetry: SparkTelemetry) {
        self.spanId = spanId
        self.telemetry = telemetry
    }

    /// End this span
    public func end(status: SpanStatus = .ok, attributes: [String: Any] = [:]) {
        telemetry?.endSpan(spanId, status: status, attributes: attributes)
    }
}

// MARK: - Convenience Extensions

public extension SparkTelemetry {

    /// Time a block of code and record as histogram
    func time<T>(_ name: String, tags: [String: String] = [:], block: () throws -> T) rethrows -> T {
        let start = Date()
        let result = try block()
        let duration = Date().timeIntervalSince(start) * 1000 // ms
        recordHistogram(name, value: duration, tags: tags)
        return result
    }

    /// Time an async block
    func time<T>(_ name: String, tags: [String: String] = [:], block: () async throws -> T) async rethrows -> T {
        let start = Date()
        let result = try await block()
        let duration = Date().timeIntervalSince(start) * 1000 // ms
        recordHistogram(name, value: duration, tags: tags)
        return result
    }
}
