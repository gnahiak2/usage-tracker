import Foundation

public enum Service: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case gemini
    case grok
    case commandCode

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .commandCode: return "Command Code"
        }
    }

    public var product: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .gemini: return "Google Antigravity"
        case .grok: return "Grok Build"
        case .commandCode: return "command-code"
        }
    }

    public var cli: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .gemini: return "agy"
        case .grok: return "grok"
        case .commandCode: return "cmd"
        }
    }

    public var loginHint: String {
        switch self {
        case .claude: return "run `claude`, then /login"
        case .codex: return "run `codex login`"
        case .gemini: return "run `agy` once and sign in"
        case .grok: return "run `grok login`"
        case .commandCode: return "run `cmd login`"
        }
    }

    public var symbol: String {
        switch self {
        case .claude: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "sparkles"
        case .grok: return "xmark.seal"
        case .commandCode: return "terminal"
        }
    }
}

public enum ServiceState: String, Codable, Sendable {
    case ok
    case missing
    case untrusted
    case signedOut
    case failed
    case unavailable
}

/// One limit window exactly as the vendor (or a documented local source) reports it.
/// `used` is percent USED, 0...100. It is nil when only a raw amount is known.
public struct LimitWindow: Codable, Equatable, Sendable {
    public var label: String
    public var short: String
    public var used: Double?
    public var resetsAt: Date?
    public var detail: String?
    public var estimated: Bool

    public init(label: String, short: String, used: Double?, resetsAt: Date? = nil,
                detail: String? = nil, estimated: Bool = false) {
        self.label = label
        self.short = short
        self.used = used
        self.resetsAt = resetsAt
        self.detail = detail
        self.estimated = estimated
    }

    public var resetPassed: Bool {
        guard let resetsAt else { return false }
        return resetsAt < Date()
    }
}

public struct Snapshot: Codable, Equatable, Sendable {
    public var service: Service
    public var state: ServiceState
    public var plan: String
    public var windows: [LimitWindow]
    public var notes: [String]
    public var measuredAt: Date?
    public var error: String?
    public var actionTitle: String?
    public var actionURL: String?
    /// Shown in the menu bar when no percentage is available (for example a dollar estimate).
    public var menuText: String?

    public init(service: Service, state: ServiceState = .ok, plan: String = "",
                windows: [LimitWindow] = [], notes: [String] = [], measuredAt: Date? = nil,
                error: String? = nil, actionTitle: String? = nil, actionURL: String? = nil,
                menuText: String? = nil) {
        self.service = service
        self.state = state
        self.plan = plan
        self.windows = windows
        self.notes = notes
        self.measuredAt = measuredAt
        self.error = error
        self.actionTitle = actionTitle
        self.actionURL = actionURL
        self.menuText = menuText
    }

    public static func status(_ service: Service, _ state: ServiceState, _ error: String? = nil) -> Snapshot {
        Snapshot(service: service, state: state, error: error)
    }

    public var bar: LimitWindow? { windows.first }

    /// Another window of this service is at 90 % or more, but not the one in the menu bar.
    public var otherHot: Bool {
        guard let bar else { return false }
        return windows.contains { window in
            window.label != bar.label && !window.resetPassed && (window.used ?? 0) >= 90
        }
    }

    /// True when the reading is older than the freshness limit.
    public func isStale(now: Date = Date()) -> Bool {
        guard let measuredAt else { return true }
        return now.timeIntervalSince(measuredAt) > 45 * 60
    }
}

public enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case one = 1
    case two = 2
    case five = 5
    case fifteen = 15

    public var id: Int { rawValue }
    public var title: String { "\(rawValue) min" }
    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }
}

public enum CommandCodePlan: String, CaseIterable, Codable, Sendable {
    case go
    case goat
    case pro
    case max10
    case max20
    case teamPro

    public var title: String {
        switch self {
        case .go: return "Go"
        case .goat: return "GOAT"
        case .pro: return "Pro"
        case .max10: return "Max 10x"
        case .max20: return "Max 20x"
        case .teamPro: return "Team Pro"
        }
    }

    /// Documented caps in US dollars for the rolling 5-hour and weekly windows.
    public var fiveHourCap: Double {
        switch self {
        case .go: return 2
        case .goat: return 14
        case .pro: return 16
        case .max10: return 45
        case .max20: return 90
        case .teamPro: return 12
        }
    }

    public var weeklyCap: Double {
        switch self {
        case .go: return 5
        case .goat: return 35
        case .pro: return 40
        case .max10: return 90
        case .max20: return 180
        case .teamPro: return 24
        }
    }
}

/// Percentages from a CLI are only used when they are finite and within 0...100.
public func percent(_ any: Any?) -> Double? {
    let value: Double?
    switch any {
    case let d as Double: value = d
    case let i as Int: value = Double(i)
    case let n as NSNumber: value = n.doubleValue
    default: value = nil
    }
    guard let x = value, x.isFinite, x >= 0, x <= 100 else { return nil }
    return x
}

public func epochDate(_ any: Any?) -> Date? {
    switch any {
    case let d as Double: return Date(timeIntervalSince1970: d > 1e12 ? d / 1000 : d)
    case let i as Int: return Date(timeIntervalSince1970: Double(i))
    case let s as String:
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    default: return nil
    }
}
