import Foundation

public enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case commandCode = "command-code"
    case codex
    case claudeChat = "claude-chat"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .commandCode: return "Command Code"
        case .codex: return "Codex"
        case .claudeChat: return "Claude chat"
        }
    }

    public var shortName: String {
        switch self {
        case .commandCode: return "Command Code"
        case .codex: return "Codex"
        case .claudeChat: return "Claude"
        }
    }
}
