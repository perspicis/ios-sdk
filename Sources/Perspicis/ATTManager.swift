import Foundation

#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

#if canImport(AdSupport)
import AdSupport
#endif

/// Manages App Tracking Transparency authorization
///
/// ATT (App Tracking Transparency) is required on iOS 14.5+ to access the IDFA.
/// This manager handles authorization state and provides privacy-safe fallbacks.
public actor ATTManager {

    // MARK: - Authorization Status

    /// Represents the current tracking authorization status
    public enum AuthorizationStatus: String, Sendable {
        /// User has not yet been prompted
        case notDetermined
        /// Tracking is restricted by the system (parental controls, etc.)
        case restricted
        /// User explicitly denied tracking
        case denied
        /// User authorized tracking
        case authorized
        /// ATT is not available on this OS version (pre-iOS 14)
        case unavailable
    }

    // MARK: - Properties

    /// Whether ATT prompt has been shown this session
    private var promptShown = false

    /// Cached authorization status
    private var cachedStatus: AuthorizationStatus?

    /// Enable debug logging
    private var enableDebugLogging: Bool = false

    /// Set debug logging state
    public func setDebugLogging(_ enabled: Bool) {
        enableDebugLogging = enabled
    }

    // MARK: - Public API

    /// Get the current tracking authorization status
    public func currentStatus() -> AuthorizationStatus {
        #if os(iOS)
        if #available(iOS 14, *) {
            switch ATTrackingManager.trackingAuthorizationStatus {
            case .notDetermined:
                return .notDetermined
            case .restricted:
                return .restricted
            case .denied:
                return .denied
            case .authorized:
                return .authorized
            @unknown default:
                return .notDetermined
            }
        } else {
            // Pre-iOS 14: tracking was allowed by default
            return .unavailable
        }
        #else
        return .unavailable
        #endif
    }

    /// Request tracking authorization from the user
    ///
    /// This will show the system ATT prompt if:
    /// - Running on iOS 14+
    /// - Status is currently `.notDetermined`
    /// - The app has the proper Info.plist key (`NSUserTrackingUsageDescription`)
    ///
    /// ```swift
    /// let status = await attManager.requestAuthorization()
    /// if status == .authorized {
    ///     // Can use IDFA for attribution
    /// }
    /// ```
    ///
    /// - Returns: The authorization status after the request
    public func requestAuthorization() async -> AuthorizationStatus {
        #if os(iOS)
        if #available(iOS 14, *) {
            // Only prompt if not determined
            let currentStatus = ATTrackingManager.trackingAuthorizationStatus
            if currentStatus != .notDetermined {
                log("ATT already determined: \(currentStatus.rawValue)")
                return mapStatus(currentStatus)
            }

            log("Requesting ATT authorization...")
            promptShown = true

            // Request authorization (Apple's API handles main thread internally)
            let status = await ATTrackingManager.requestTrackingAuthorization()
            let mappedStatus = mapStatus(status)

            log("ATT authorization result: \(mappedStatus.rawValue)")
            cachedStatus = mappedStatus

            return mappedStatus
        } else {
            return .unavailable
        }
        #else
        return .unavailable
        #endif
    }

    /// Check if tracking is authorized
    ///
    /// Returns true if:
    /// - User authorized tracking, OR
    /// - Running on pre-iOS 14 where tracking was allowed
    public func isTrackingAuthorized() -> Bool {
        let status = currentStatus()
        return status == .authorized || status == .unavailable
    }

    /// Check if the ATT prompt should be shown
    ///
    /// Returns true if status is `.notDetermined` and running on iOS 14+
    public func shouldShowPrompt() -> Bool {
        return currentStatus() == .notDetermined
    }

    /// Get the IDFA if available and authorized
    ///
    /// Returns nil if:
    /// - Tracking is not authorized
    /// - IDFA is all zeros (Limited Ad Tracking enabled)
    /// - Not running on iOS
    public func getIDFA() -> String? {
        #if os(iOS)
        guard isTrackingAuthorized() else {
            return nil
        }

        let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString

        // Check if IDFA is valid (not all zeros)
        let zeroIDFA = "00000000-0000-0000-0000-000000000000"
        if idfa == zeroIDFA {
            return nil
        }

        return idfa
        #else
        return nil
        #endif
    }

    /// Get a privacy-safe device identifier
    ///
    /// This returns:
    /// - IDFA if tracking is authorized
    /// - Vendor ID (IDFV) as a fallback
    /// - A generated UUID if no identifiers are available
    public func getDeviceIdentifier() -> String {
        // Try IDFA first
        if let idfa = getIDFA() {
            return idfa
        }

        // Fall back to IDFV
        #if os(iOS)
        if let idfv = UIDevice.current.identifierForVendor?.uuidString {
            return idfv
        }
        #endif

        // Last resort: generate and persist a UUID
        return getPersistentUUID()
    }

    // MARK: - Private Helpers

    #if os(iOS)
    @available(iOS 14, *)
    private func mapStatus(_ status: ATTrackingManager.AuthorizationStatus) -> AuthorizationStatus {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .notDetermined
        }
    }
    #endif

    private func getPersistentUUID() -> String {
        let key = "com.perspicis.device_uuid"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newUUID = UUID().uuidString
        UserDefaults.standard.set(newUUID, forKey: key)
        return newUUID
    }

    private func log(_ message: String) {
        if enableDebugLogging {
            print("[Perspicis/ATT] \(message)")
        }
    }
}

#if os(iOS)
import UIKit
#endif

// MARK: - Convenience Extension

public extension ATTManager {

    /// Get a summary of the current ATT state
    func statusSummary() -> [String: Any] {
        [
            "status": currentStatus().rawValue,
            "tracking_authorized": isTrackingAuthorized(),
            "prompt_shown": promptShown,
            "idfa_available": getIDFA() != nil
        ]
    }
}
