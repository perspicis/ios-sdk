import Foundation
import Network

/// Monitors network connectivity for offline queue management
public actor NetworkMonitor {

    // MARK: - Types

    public enum ConnectionStatus: String, Sendable {
        case connected
        case disconnected
        case unknown
    }

    public struct ConnectionInfo: Sendable {
        public let status: ConnectionStatus
        public let isExpensive: Bool  // Cellular
        public let isConstrained: Bool  // Low Data Mode
        public let interfaceType: InterfaceType

        public enum InterfaceType: String, Sendable {
            case wifi
            case cellular
            case wiredEthernet
            case loopback
            case other
            case none
        }
    }

    // MARK: - Properties

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var currentPath: NWPath?
    private var statusContinuation: AsyncStream<ConnectionStatus>.Continuation?
    private var isMonitoring = false
    private var enableDebugLogging = false

    // MARK: - Initialization

    public init() {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "com.perspicis.networkmonitor")
    }

    deinit {
        monitor.cancel()
    }

    // MARK: - Public API

    /// Start monitoring network status
    public func start() {
        guard !isMonitoring else { return }

        monitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                await self?.handlePathUpdate(path)
            }
        }

        monitor.start(queue: queue)
        isMonitoring = true
        log("Network monitoring started")
    }

    /// Stop monitoring
    public func stop() {
        guard isMonitoring else { return }
        monitor.cancel()
        isMonitoring = false
        statusContinuation?.finish()
        log("Network monitoring stopped")
    }

    /// Get current connection status
    public func currentStatus() -> ConnectionStatus {
        guard let path = currentPath else { return .unknown }
        return path.status == .satisfied ? .connected : .disconnected
    }

    /// Get detailed connection info
    public func connectionInfo() -> ConnectionInfo {
        guard let path = currentPath else {
            return ConnectionInfo(
                status: .unknown,
                isExpensive: false,
                isConstrained: false,
                interfaceType: .none
            )
        }

        let interfaceType: ConnectionInfo.InterfaceType
        if path.usesInterfaceType(.wifi) {
            interfaceType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            interfaceType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            interfaceType = .wiredEthernet
        } else if path.usesInterfaceType(.loopback) {
            interfaceType = .loopback
        } else {
            interfaceType = .other
        }

        return ConnectionInfo(
            status: path.status == .satisfied ? .connected : .disconnected,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            interfaceType: interfaceType
        )
    }

    /// Check if network is currently available
    public func isConnected() -> Bool {
        return currentStatus() == .connected
    }

    /// Stream of connection status changes
    public func statusStream() -> AsyncStream<ConnectionStatus> {
        AsyncStream { continuation in
            self.statusContinuation = continuation
        }
    }

    /// Wait for network to become available
    /// - Parameter timeout: Maximum time to wait
    /// - Returns: true if connected within timeout, false otherwise
    public func waitForConnection(timeout: TimeInterval = 30) async -> Bool {
        if isConnected() { return true }

        return await withCheckedContinuation { continuation in
            Task {
                let deadline = Date().addingTimeInterval(timeout)

                for await status in statusStream() {
                    if status == .connected {
                        continuation.resume(returning: true)
                        return
                    }
                    if Date() > deadline {
                        continuation.resume(returning: false)
                        return
                    }
                }

                continuation.resume(returning: false)
            }
        }
    }

    /// Enable or disable debug logging
    public func setDebugLogging(_ enabled: Bool) {
        enableDebugLogging = enabled
    }

    // MARK: - Private

    private func handlePathUpdate(_ path: NWPath) {
        let oldStatus = currentStatus()
        currentPath = path
        let newStatus = currentStatus()

        if oldStatus != newStatus {
            log("Network status changed: \(oldStatus.rawValue) -> \(newStatus.rawValue)")
            statusContinuation?.yield(newStatus)
        }
    }

    private func log(_ message: String) {
        if enableDebugLogging {
            print("[Perspicis.Network] \(message)")
        }
    }
}
