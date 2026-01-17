import Foundation

/// Maps user signals to SKAdNetwork conversion values
/// See: docs/specs/APPLE_SKADNETWORK_SPECIFICATION.md Section 3
///
/// Bit encoding (6 bits = 0-63):
/// - Bits 0-2: Revenue tier (0-7)
/// - Bits 3-4: Retention tier (0-3)
/// - Bit 5: Tutorial/milestone completion (0-1)
public enum ConversionValueMapper {

    // MARK: - Types

    /// Result of deriving a conversion value
    public struct ConversionValueResult: Sendable {
        public let fineValue: Int
        public let coarseValue: SKANCoarseValue
    }

    /// Decoded conversion value components
    public struct DecodedConversionValue: Sendable {
        public let revenueTier: Int
        public let retentionTier: Int
        public let tutorialCompleted: Bool
    }

    // MARK: - Constants

    /// Revenue tier thresholds (IAP event count)
    private static let revenueTierThresholds: [(min: Int, max: Int, tier: Int)] = [
        (0, 0, 0),      // No purchases
        (1, 1, 1),      // First purchase
        (2, 4, 2),      // Occasional
        (5, 9, 3),      // Regular
        (10, 19, 4),    // Frequent
        (20, 29, 5),    // Heavy
        (30, 49, 6),    // Very heavy
        (50, Int.max, 7) // Whale
    ]

    /// Coarse value thresholds
    private static let coarseThresholdLow = 20
    private static let coarseThresholdMedium = 44

    // MARK: - Public API

    /// Derive SKAN conversion value from user signals
    /// - Parameter signals: User engagement signals collected on-device
    /// - Returns: Fine value (0-63) and coarse value (low/medium/high)
    public static func deriveConversionValue(from signals: UserSignals) -> ConversionValueResult {
        let revenueTier = computeRevenueTier(iapCount: signals.iapEventCount)
        let retentionTier = computeRetentionTier(
            sessions7d: signals.sessionCount7d,
            sessions30d: signals.sessionCount30d
        )

        let fineValue = encodeConversionValue(
            revenueTier: revenueTier,
            retentionTier: retentionTier,
            tutorialCompleted: signals.tutorialCompleted
        )

        let coarseValue = deriveCoarseValue(from: fineValue)

        return ConversionValueResult(fineValue: fineValue, coarseValue: coarseValue)
    }

    /// Compute revenue tier from IAP event count
    /// - Parameter iapCount: Number of in-app purchase events
    /// - Returns: Tier 0-7
    public static func computeRevenueTier(iapCount: Int) -> Int {
        for threshold in revenueTierThresholds {
            if iapCount >= threshold.min && iapCount <= threshold.max {
                return threshold.tier
            }
        }
        return 7 // Max tier for any count >= 50
    }

    /// Compute retention tier from session counts
    /// - Parameters:
    ///   - sessions7d: Sessions in last 7 days
    ///   - sessions30d: Sessions in last 30 days
    /// - Returns: Tier 0-3
    public static func computeRetentionTier(sessions7d: Int, sessions30d: Int) -> Int {
        // Tier 3: High engagement (7d >= 10 AND 30d >= 30)
        if sessions7d >= 10 && sessions30d >= 30 {
            return 3
        }
        // Tier 2: Moderate engagement
        if sessions7d >= 5 || sessions30d >= 10 {
            return 2
        }
        // Tier 1: Some engagement
        if sessions7d >= 1 || sessions30d >= 1 {
            return 1
        }
        // Tier 0: No engagement
        return 0
    }

    /// Derive coarse value from fine value
    /// - Parameter fineValue: The 6-bit fine value (0-63)
    /// - Returns: Coarse value (low/medium/high)
    public static func deriveCoarseValue(from fineValue: Int) -> SKANCoarseValue {
        if fineValue <= coarseThresholdLow {
            return .low
        } else if fineValue <= coarseThresholdMedium {
            return .medium
        } else {
            return .high
        }
    }

    /// Encode tiers into 6-bit conversion value
    /// - Parameters:
    ///   - revenueTier: Revenue tier (0-7)
    ///   - retentionTier: Retention tier (0-3)
    ///   - tutorialCompleted: Whether tutorial was completed
    /// - Returns: Encoded value (0-63)
    public static func encodeConversionValue(
        revenueTier: Int,
        retentionTier: Int,
        tutorialCompleted: Bool
    ) -> Int {
        // Clamp values to valid ranges
        let rev = min(max(revenueTier, 0), 7)      // 3 bits: 0-7
        let ret = min(max(retentionTier, 0), 3)    // 2 bits: 0-3
        let tut = tutorialCompleted ? 1 : 0        // 1 bit: 0-1

        // Encode: tut[5] | ret[4:3] | rev[2:0]
        return (tut << 5) | (ret << 3) | rev
    }

    /// Decode conversion value into component tiers
    /// - Parameter value: The encoded conversion value (0-63)
    /// - Returns: Decoded components
    public static func decodeConversionValue(_ value: Int) -> DecodedConversionValue {
        let clampedValue = min(max(value, 0), 63)

        let revenueTier = clampedValue & 0b111           // Bits 0-2
        let retentionTier = (clampedValue >> 3) & 0b11   // Bits 3-4
        let tutorialCompleted = (clampedValue >> 5) & 0b1 == 1  // Bit 5

        return DecodedConversionValue(
            revenueTier: revenueTier,
            retentionTier: retentionTier,
            tutorialCompleted: tutorialCompleted
        )
    }
}

// MARK: - SKAN Coarse Value

/// SKAdNetwork 4.0 coarse conversion value
public enum SKANCoarseValue: String, Codable, Sendable {
    case low
    case medium
    case high
}
