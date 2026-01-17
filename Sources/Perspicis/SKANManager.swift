import Foundation

#if os(iOS)
import StoreKit
#endif

/// Manages SKAdNetwork integration for Perspicis SDK
/// See: docs/specs/APPLE_SKADNETWORK_SPECIFICATION.md
///
/// Features:
/// - Version-aware API usage (SKAN 2.x, 3.0, 4.0)
/// - Conversion value management with validation
/// - Telemetry for monitoring
public actor SKANManager {

    // MARK: - State

    /// Current SKAN state
    public struct State: Sendable {
        public var isRegistered: Bool = false
        public var skanVersion: String = ""
        public var currentFineValue: Int = 0
        public var currentCoarseValue: SKANCoarseValue?
        public var updateCount: Int = 0
        public var updateFailureCount: Int = 0
        public var lastUpdateTime: Date?
    }

    private var state = State()
    private let skanAPI: SKANAPIProtocol
    private let telemetry: TelemetryTracker?

    // MARK: - Init

    /// Initialize with default (real) SKAN API
    public init() {
        self.skanAPI = RealSKANAPI()
        self.telemetry = nil
    }

    /// Initialize with custom API (for testing)
    public init(skanAPI: SKANAPIProtocol, telemetry: TelemetryTracker? = nil) {
        self.skanAPI = skanAPI
        self.telemetry = telemetry
    }

    // MARK: - Public API

    /// Get current SKAN state
    public func currentState() -> State {
        return state
    }

    /// Register for SKAdNetwork attribution
    /// - Returns: Success or error
    public func register() async -> Result<Void, SKANError> {
        // Idempotent: already registered
        if state.isRegistered {
            return .success(())
        }

        // Check availability
        guard skanAPI.isAvailable() else {
            return .failure(.notAvailable)
        }

        // Register
        do {
            try skanAPI.registerForAttribution()
            state.isRegistered = true
            state.skanVersion = skanAPI.getVersion()

            telemetry?.track("_skan_register", properties: [
                "version": state.skanVersion,
                "success": true
            ])

            return .success(())
        } catch {
            telemetry?.track("_skan_register_failed", properties: [
                "error": error.localizedDescription
            ])
            return .failure(.registrationFailed)
        }
    }

    /// Update conversion value
    /// - Parameters:
    ///   - fine: Fine-grained value (0-63)
    ///   - coarse: Coarse value (low/medium/high)
    ///   - lockWindow: Whether to lock the current measurement window (SKAN 4.0+)
    /// - Returns: Success or error
    public func updateConversionValue(
        fine: Int,
        coarse: SKANCoarseValue,
        lockWindow: Bool = false
    ) async -> Result<Void, SKANError> {
        // Must be registered
        guard state.isRegistered else {
            state.updateFailureCount += 1
            telemetry?.track("_skan_cv_update_failed", properties: [
                "error": "not_registered"
            ])
            return .failure(.notRegistered)
        }

        // Validate range (0-63)
        guard fine >= 0 && fine <= 63 else {
            state.updateFailureCount += 1
            telemetry?.track("_skan_cv_update_failed", properties: [
                "error": "invalid_value",
                "value": fine
            ])
            return .failure(.invalidValue)
        }

        // SKAN <4.0: Values can only increase
        if !isVersion4OrLater() && fine < state.currentFineValue {
            state.updateFailureCount += 1
            telemetry?.track("_skan_cv_update_failed", properties: [
                "error": "value_not_increasing",
                "current": state.currentFineValue,
                "attempted": fine
            ])
            return .failure(.valueNotIncreasing)
        }

        // Call Apple API
        do {
            try await skanAPI.updateConversionValue(
                fine: fine,
                coarse: coarse,
                lockWindow: lockWindow
            )

            // Update state
            state.currentFineValue = fine
            state.currentCoarseValue = coarse
            state.updateCount += 1
            state.lastUpdateTime = Date()

            telemetry?.track("_skan_cv_update", properties: [
                "fine_value": fine,
                "coarse_value": coarse.rawValue,
                "update_count": state.updateCount
            ])

            return .success(())
        } catch {
            state.updateFailureCount += 1
            telemetry?.track("_skan_cv_update_failed", properties: [
                "error": error.localizedDescription
            ])
            return .failure(.updateFailed)
        }
    }

    /// Update conversion value from user signals
    /// Convenience method that derives CV from signals
    public func updateFromSignals(_ signals: UserSignals, lockWindow: Bool = false) async -> Result<Void, SKANError> {
        let result = ConversionValueMapper.deriveConversionValue(from: signals)
        return await updateConversionValue(
            fine: result.fineValue,
            coarse: result.coarseValue,
            lockWindow: lockWindow
        )
    }

    // MARK: - Private

    private func isVersion4OrLater() -> Bool {
        guard let version = Double(state.skanVersion) else {
            return false
        }
        return version >= 4.0
    }
}

// MARK: - SKAN Errors

public enum SKANError: Error, Equatable, Sendable {
    case notAvailable
    case notRegistered
    case invalidValue
    case valueNotIncreasing
    case registrationFailed
    case updateFailed
}

// MARK: - SKAN API Protocol

public protocol SKANAPIProtocol: Sendable {
    func isAvailable() -> Bool
    func getVersion() -> String
    func registerForAttribution() throws
    func updateConversionValue(fine: Int, coarse: SKANCoarseValue?, lockWindow: Bool) async throws
}

// MARK: - Telemetry Protocol

public protocol TelemetryTracker: AnyObject {
    func track(_ name: String, properties: [String: Any])
}

// MARK: - Real SKAN API Implementation

/// Real implementation that calls Apple's SKAdNetwork APIs
final class RealSKANAPI: SKANAPIProtocol, @unchecked Sendable {

    func isAvailable() -> Bool {
        #if os(iOS)
        if #available(iOS 14.0, *) {
            return true
        }
        #endif
        return false
    }

    func getVersion() -> String {
        #if os(iOS)
        if #available(iOS 16.1, *) {
            return "4.0"
        } else if #available(iOS 15.4, *) {
            return "3.0"
        } else if #available(iOS 14.5, *) {
            return "2.2"
        } else if #available(iOS 14.0, *) {
            return "2.0"
        }
        #endif
        return "0.0"
    }

    func registerForAttribution() throws {
        #if os(iOS)
        if #available(iOS 14.0, *) {
            SKAdNetwork.registerAppForAdNetworkAttribution()
        } else {
            throw SKANError.notAvailable
        }
        #else
        throw SKANError.notAvailable
        #endif
    }

    func updateConversionValue(fine: Int, coarse: SKANCoarseValue?, lockWindow: Bool) async throws {
        #if os(iOS)
        if #available(iOS 16.1, *) {
            // SKAN 4.0: Full API with coarse value and lock window
            let coarseValue: SKAdNetwork.CoarseConversionValue
            switch coarse {
            case .low:
                coarseValue = .low
            case .medium:
                coarseValue = .medium
            case .high:
                coarseValue = .high
            case .none:
                coarseValue = .low
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                SKAdNetwork.updatePostbackConversionValue(fine, coarseValue: coarseValue, lockWindow: lockWindow) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } else if #available(iOS 15.4, *) {
            // SKAN 3.0: Fine value only with completion handler
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                SKAdNetwork.updatePostbackConversionValue(fine) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } else if #available(iOS 14.0, *) {
            // SKAN 2.x: Simple update, no completion
            SKAdNetwork.updateConversionValue(fine)
        } else {
            throw SKANError.notAvailable
        }
        #else
        throw SKANError.notAvailable
        #endif
    }
}
