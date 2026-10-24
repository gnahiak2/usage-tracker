import Foundation
import Testing
@testable import UsageCore

@Suite("Settings")
struct SettingsTests {
    @Test func refreshIntervalsHaveWholeMinutes() {
        #expect(RefreshInterval.one.seconds == 60)
        #expect(RefreshInterval.fifteen.seconds == 900)
        #expect(RefreshInterval.allCases.map(\.title) == ["1 min", "2 min", "5 min", "15 min"])
    }

    @Test @MainActor func settingsDefaultsAreHonest() throws {
        let name = "usage-tracker-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let store = Store(defaults: defaults, loadCache: false, automaticallyRefresh: false)
        #expect(store.showMarks)
        #expect(store.refreshInterval == .two)
        #expect(store.commandCodePlan == nil)
        #expect(Service.allCases.allSatisfy { store.isVisibleInMenuBar($0) })
    }

    @Test @MainActor func settingsSurviveAReload() throws {
        let name = "usage-tracker-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let store = Store(defaults: defaults, loadCache: false, automaticallyRefresh: false)
        store.showMarks = false
        store.refreshInterval = .fifteen
        store.setVisible(.claude, false)
        store.commandCodePlan = .pro

        let reloaded = Store(defaults: defaults, loadCache: false, automaticallyRefresh: false)
        #expect(!reloaded.showMarks)
        #expect(reloaded.refreshInterval == .fifteen)
        #expect(!reloaded.isVisibleInMenuBar(.claude))
        #expect(reloaded.isVisibleInMenuBar(.codex))
        #expect(reloaded.commandCodePlan == .pro)

        reloaded.setVisible(.claude, true)
        reloaded.commandCodePlan = nil
        #expect(reloaded.isVisibleInMenuBar(.claude))
        #expect(reloaded.commandCodePlan == nil)
    }
}
