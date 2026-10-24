import AppKit
import SwiftUI
import UsageCore

@main
struct UsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.shared

    init() {
        if CommandLine.arguments.contains("--probe") {
            Probe.run()
            exit(0)
        }
        if CommandLine.arguments.contains("--statusline") {
            Statusline.run()
            exit(0)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-preview"),
           CommandLine.arguments.count > flag + 1 {
            Preview.render(to: CommandLine.arguments[flag + 1])
            exit(0)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-tray"),
           CommandLine.arguments.count > flag + 1 {
            Preview.renderTray(to: CommandLine.arguments[flag + 1])
            exit(0)
        }
        if CommandLine.arguments.contains("--refresh-once") {
            Task { @MainActor in
                let store = Store()
                await store.refresh(force: true)
                for (service, snapshot) in store.snapshots.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    print("\(service.rawValue): \(snapshot.state.rawValue) windows=\(snapshot.windows.count)")
                }
                print("cache: \(Paths.stateFile) exists=\(FileManager.default.fileExists(atPath: Paths.stateFile))")
                exit(0)
            }
            RunLoop.main.run()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            TrayLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in Store.shared.start() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in Store.shared.refreshIfStale() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }
}
