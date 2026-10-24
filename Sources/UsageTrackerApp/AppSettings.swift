#if canImport(SwiftUI) && os(macOS)
import Foundation
import Observation
import UsageCore

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let commandCodeRoot = "commandCodeRoot"
        static let codexRoot = "codexRoot"
        static let refreshInterval = "refreshInterval"
    }

    private let defaults: UserDefaults

    var commandCodeRoot: String
    var codexRoot: String
    var refreshInterval: TimeInterval

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.commandCodeRoot = defaults.string(forKey: Key.commandCodeRoot) ?? ""
        self.codexRoot = defaults.string(forKey: Key.codexRoot) ?? ""
        let storedInterval = defaults.double(forKey: Key.refreshInterval)
        self.refreshInterval = storedInterval > 0 ? storedInterval : 20
    }

    var resolvedCommandCodeRoot: URL {
        Self.resolve(commandCodeRoot, fallback: CommandCodeProvider.defaultRoot)
    }

    var resolvedCodexRoot: URL {
        Self.resolve(codexRoot, fallback: CodexProvider.defaultRoot)
    }

    func save() {
        defaults.set(commandCodeRoot, forKey: Key.commandCodeRoot)
        defaults.set(codexRoot, forKey: Key.codexRoot)
        defaults.set(refreshInterval, forKey: Key.refreshInterval)
    }

    private static func resolve(_ path: String, fallback: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}
#endif
