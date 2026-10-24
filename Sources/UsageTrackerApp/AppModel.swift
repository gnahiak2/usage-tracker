#if canImport(SwiftUI) && os(macOS)
import AppKit
import Foundation
import Observation
import UsageCore

@MainActor
@Observable
final class AppModel {
    let store = UsageStore()
    let settings = AppSettings()

    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    var isRefreshing: Bool { !store.refreshing.isEmpty }

    func start() async {
        guard !isConfigured else { return }
        isConfigured = true
        await configureStore()
        observeSystemEvents()
    }

    func applySettings(
        commandCodeRoot: String,
        codexRoot: String,
        refreshInterval: TimeInterval
    ) async {
        settings.commandCodeRoot = commandCodeRoot
        settings.codexRoot = codexRoot
        settings.refreshInterval = refreshInterval
        settings.save()
        await configureStore()
    }

    func refreshAll() {
        Task { await store.refreshAll(trigger: .manual) }
    }

    func refresh(provider: ProviderID) {
        Task { await store.refresh(provider: provider, trigger: .manual) }
    }

    func clearCache() {
        Task { await store.clearCache() }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func configureStore() async {
        await store.configure(
            providers: makeProviders(),
            cacheDirectory: UsageCache.defaultDirectory,
            refreshInterval: settings.refreshInterval
        )
    }

    private func makeProviders() -> [any UsageProvider] {
        [
            CommandCodeProvider(root: settings.resolvedCommandCodeRoot),
            CodexProvider(root: settings.resolvedCodexRoot),
            ClaudeChatProvider()
        ]
    }

    private func observeSystemEvents() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.store.wake()
            }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let last = self.store.lastRefresh else { return }
                if Date().timeIntervalSince(last) > 60 {
                    await self.store.refreshAll(trigger: .wake)
                }
            }
        }
    }
}
#endif
