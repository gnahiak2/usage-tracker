import Foundation

/// Rounded percentage for display. 99.6 must never read as 100.
public func percentText(_ value: Double?) -> String {
    guard let value else { return "—" }
    let rounded = value.rounded()
    if rounded >= 100 && value < 100 { return "99" }
    return String(Int(max(0, rounded)))
}

public func currencyText(_ value: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .currency
    f.currencyCode = "USD"
    f.locale = Locale(identifier: "en_US")
    f.maximumFractionDigits = value < 1 ? 2 : 2
    return f.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
}

public func ageText(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(seconds / 60) min ago" }
    if seconds < 86_400 { return "\(seconds / 3600) h ago" }
    return "\(seconds / 86_400) d ago"
}

/// "resets 21:10" today, "resets Tue 16:31" later, and a neutral line once it has passed.
public func resetText(_ date: Date?, kind: String = "resets", now: Date = Date()) -> String {
    guard let date else { return "opens on next request" }
    if date < now { return "reset, awaiting update" }
    let f = DateFormatter()
    f.locale = Locale.current
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
    return "\(kind) \(f.string(from: date))"
}

public func durationText(seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let h = total / 3600
    let m = (total % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}
