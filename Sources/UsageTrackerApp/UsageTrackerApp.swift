#if canImport(SwiftUI) && os(macOS)
import AppKit
import SwiftUI

@main
@MainActor
struct UsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
                .task { await model.start() }
        } label: {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .accessibilityLabel("Usage Tracker")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .task { await model.start() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = NSApp.setActivationPolicy(.accessory)
    }
}
#else
import Foundation

@main
struct UsageTrackerAppPlaceholder {
    static func main() {
        print("UsageTrackerApp requires macOS 14 or later.")
    }
}
#endif
