import Foundation

/// Parses the ISO-8601 timestamps written by Command Code and Codex.
/// Two formatters are used because some records include fractional seconds and some do not.
struct DateParser {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractional.timeZone = TimeZone(secondsFromGMT: 0)
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        plain.timeZone = TimeZone(secondsFromGMT: 0)
    }

    func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return fractional.date(from: value) ?? plain.date(from: value)
    }
}
