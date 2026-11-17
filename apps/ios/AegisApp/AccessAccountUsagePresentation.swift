import Foundation

/// Display-only helpers. Neither cached freshness nor a byte label authorizes traffic.
struct AccessAccountUsagePresentation {
    enum Freshness: Equatable { case current, delayed, unavailable }

    /// Floating point is only used for the meter, never for billing or byte labels.
    static func usedFraction(used: String?, quota: String?) -> Double? {
        guard let used, let quota, let usedValue = UInt64(used), let quotaValue = UInt64(quota),
              String(usedValue) == used, String(quotaValue) == quota, quotaValue > 0 else { return nil }
        return min(Double(usedValue) / Double(quotaValue), 1)
    }

    static func freshness(
        snapshot: AccessAccountEntitlement,
        // The earliest trustworthy local anchor, including request/transport time.
        receivedUptime: TimeInterval?,
        nowUptime: TimeInterval,
        stale: Bool
    ) -> Freshness {
        guard !stale,
              let measuredAt = snapshot.measuredAt, measuredAt >= 0,
              let receivedAt = snapshot.receivedAt, receivedAt >= measuredAt,
              let age = snapshot.snapshotAgeMs, age >= receivedAt - measuredAt,
              let receivedUptime, receivedUptime.isFinite, receivedUptime >= 0,
              nowUptime.isFinite, nowUptime >= receivedUptime else { return .unavailable }
        // Never upgrade absent or inconsistent server freshness metadata.
        let expected: AccessAccountEntitlement.Freshness = age > 15_000 ? .unavailable : age > 5_000 ? .delayed : .current
        guard snapshot.freshness == expected else { return .unavailable }

        let milliseconds = (nowUptime - receivedUptime) * 1_000
        // Round elapsed time up: a fractional millisecond past a boundary is not current.
        // Saturate before conversion, including subtraction/multiplication overflow.
        let elapsed: UInt64
        if !milliseconds.isFinite || milliseconds >= Double(UInt64.max) {
            elapsed = .max
        } else {
            elapsed = UInt64(milliseconds.rounded(.up))
        }
        let (sum, overflow) = UInt64(age).addingReportingOverflow(elapsed)
        let effectiveAge = overflow ? UInt64.max : sum
        if effectiveAge > 15_000 { return .unavailable }
        return effectiveAge > 5_000 ? .delayed : .current
    }

    /// Speak exact bytes with a unit. Foundation's byte style accepts signed values
    /// and can round large integers, so keep the full unsigned range lossless.
    static func accessibleBytes(_ raw: String?, locale: Locale) -> String {
        guard let raw, let value = UInt64(raw), String(value) == raw else { return "—" }
        if value < 1 << 53 {
            return ByteCountFormatStyle(allowedUnits: .bytes, spellsOutZero: false, locale: locale)
                .format(Int64(value))
        }
        return value.formatted(.number.locale(locale)) + " B"
    }

    /// Binary units, truncated to two decimal places without converting bytes to floating point.
    /// The session retains the exact canonical source string.
    static func formattedBytes(_ raw: String?) -> String {
        guard let raw, let value = UInt64(raw), String(value) == raw else { return "—" }
        guard value >= 1_024 else { return "\(value) B" }
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
        var unit = 0
        var divisor: UInt64 = 1
        while unit < units.count - 1 && value / divisor >= 1_024 {
            divisor *= 1_024
            unit += 1
        }
        let whole = value / divisor
        let remainder = value % divisor
        // remainder * 100 may exceed UInt64 at EiB scale; divide the full-width product.
        let fraction = divisor.dividingFullWidth(remainder.multipliedFullWidth(by: 100)).quotient
        let decimals = fraction < 10 ? "0\(fraction)" : String(fraction)
        return "\(whole).\(decimals) \(units[unit])"
    }
}
