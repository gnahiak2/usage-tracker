#if canImport(SwiftUI) && os(macOS)
import Foundation

enum Format {
    static func tokens(_ value: Int64) -> String {
        let amount = Double(value)
        let magnitude = abs(amount)
        switch magnitude {
        case 1_000_000_000...:
            return String(format: "%.1fB", amount / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", amount / 1_000_000)
        case 10_000...:
            return String(format: "%.0fK", amount / 1_000)
        case 1_000...:
            return String(format: "%.1fK", amount / 1_000)
        default:
            return String(format: "%.0f", amount)
        }
    }

    static func usd(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2

        let number = NSDecimalNumber(decimal: value)
        let magnitude = abs(number.doubleValue)
        if magnitude > 0 && magnitude < 0.01 {
            formatter.minimumFractionDigits = 4
            formatter.maximumFractionDigits = 4
        }
        return formatter.string(from: number) ?? "$0.00"
    }

    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value == value.rounded() {
            return String(format: "%.0f%%", value)
        }
        return String(format: "%.1f%%", value)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 10 else { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 60 { return "in <1m" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "in \(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return remainingMinutes == 0
                ? "in \(hours)h"
                : "in \(hours)h \(remainingMinutes)m"
        }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0
            ? "in \(days)d"
            : "in \(days)d \(remainingHours)h"
    }

    static func interval(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds)) seconds" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60
        return "\(hours) hour\(hours == 1 ? "" : "s")"
    }
}
#endif
