import Combine
import Foundation
import ServiceManagement

@MainActor
public final class Store: ObservableObject {
    public static let shared = Store()

    @Published public private(set) var snapshots: [Service: Snapshot] = [:]
    @Published public private(set) var busy: Set<Service> = []
    @Published public private(set) var installed: [Service] = []
    @Published public private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let providers: [Service: any UsageProvider]
    private let defaults: UserDefaults
    private let automaticallyRefresh: Bool
    private var lastAttempt: [Service: Date] = [:]
    private var refreshing = false
    private var planStorage: CommandCodePlan?

    public init(defaults: UserDefaults = .standard, loadCache: Bool = true,
                automaticallyRefresh: Bool = true) {
        self.defaults = defaults
        self.automaticallyRefresh = automaticallyRefresh
        providers = Self.makeProviders()
        planStorage = defaults.string(forKey: "commandCodePlan")
            .flatMap(CommandCodePlan.init(rawValue:))
        installed = Self.detectInstalled()
        if loadCache { load() }
    }

    public init(preview snapshots: [Service: Snapshot], installed: [Service],
                defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticallyRefresh = false
        providers = Self.makeProviders()
        planStorage = defaults.string(forKey: "commandCodePlan")
            .flatMap(CommandCodePlan.init(rawValue:))
        self.snapshots = snapshots
        self.installed = installed
    }

    private static func makeProviders() -> [Service: any UsageProvider] {
        [
            .claude: ClaudeProvider(),
            .codex: CodexProvider(),
            .gemini: GeminiProvider(),
            .grok: GrokProvider(),
            .commandCode: CommandCodeProvider(),
        ]
    }

    public var commandCodePlan: CommandCodePlan? {
        get { planStorage }
        set {
            guard newValue != planStorage else { return }
            planStorage = newValue
            if let newValue {
                defaults.set(newValue.rawValue, forKey: "commandCodePlan")
            } else {
                defaults.removeObject(forKey: "commandCodePlan")
            }
            objectWillChange.send()
            if automaticallyRefresh {
                Task { await refresh(force: true, only: .commandCode) }
            }
        }
    }

    public var missing: [Service] {
        Service.allCases.filter { !installed.contains($0) }
    }

    public var isBusy: Bool { !busy.isEmpty }

    public var showMarks: Bool {
        get { defaults.object(forKey: "showMarks") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "showMarks")
            objectWillChange.send()
        }
    }

    public var refreshInterval: RefreshInterval {
        get {
            (defaults.object(forKey: "refreshInterval") as? Int)
                .flatMap(RefreshInterval.init) ?? .two
        }
        set {
            defaults.set(newValue.rawValue, forKey: "refreshInterval")
            objectWillChange.send()
        }
    }

    public func isVisibleInMenuBar(_ service: Service) -> Bool {
        let hidden = defaults.stringArray(forKey: "hiddenMenuBarServices") ?? []
        return !hidden.contains(service.rawValue)
    }

    public func setVisible(_ service: Service, _ visible: Bool) {
        var hidden = Set(defaults.stringArray(forKey: "hiddenMenuBarServices") ?? [])
        if visible { hidden.remove(service.rawValue) } else { hidden.insert(service.rawValue) }
        defaults.set(hidden.sorted(), forKey: "hiddenMenuBarServices")
        objectWillChange.send()
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    public func clearCache() {
        snapshots.removeAll()
        lastAttempt.removeAll()
        try? FileManager.default.removeItem(atPath: Paths.stateFile)
        try? FileManager.default.removeItem(atPath: Paths.claudeStatusFile)
        objectWillChange.send()
        Task { await refresh(force: true) }
    }

    public func start() {
        installed = Self.detectInstalled()
        Task { await refresh(force: false) }
    }

    public func refreshIfStale() {
        Task { await refresh(force: false) }
    }

    public func refreshNow() {
        Task { await refresh(force: true) }
    }

    public func refresh(force: Bool, only: Service? = nil) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        installed = Self.detectInstalled()
        let services = only.map { [$0] } ?? installed

        for service in services {
            guard let provider = providers[service] else { continue }
            if !force && !needsRefresh(service) { continue }

            busy.insert(service)
            let snapshot = await Task.detached(priority: .utility) { provider.read() }.value
            snapshots[service] = snapshot
            lastAttempt[service] = Date()
            busy.remove(service)
            save()
        }
    }

    private func needsRefresh(_ service: Service) -> Bool {
        guard snapshots[service] != nil, let last = lastAttempt[service] else { return true }
        let base = refreshInterval.seconds
        let interval: TimeInterval
        switch service {
        case .claude: interval = max(20 * 60, base)
        case .gemini, .grok: interval = max(5 * 60, base)
        case .codex, .commandCode: interval = base
        }
        return Date().timeIntervalSince(last) >= interval
    }

    private static func detectInstalled() -> [Service] {
        Service.allCases.filter { service in
            if case .missing = CLI.find(service.cli) { return false }
            return true
        }
    }

    // MARK: - Cache

    private struct Cache: Codable {
        var version: Int
        var snapshots: [String: Snapshot]
    }

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.stateFile)),
              let cache = try? JSONDecoder().decode(Cache.self, from: data)
        else { return }
        for (key, snapshot) in cache.snapshots {
            guard let service = Service(rawValue: key) else { continue }
            snapshots[service] = snapshot
        }
    }

    private func save() {
        let cache = Cache(version: 1,
                          snapshots: Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.rawValue, $0.value) }))
        guard let data = try? JSONEncoder().encode(cache) else { return }
        Paths.write(data, to: Paths.stateFile)
    }
}
