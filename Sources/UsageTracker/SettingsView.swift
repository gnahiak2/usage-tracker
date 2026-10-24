import AppKit
import SwiftUI
import UsageCore

struct SettingsView: View {
    @ObservedObject var store: Store

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            claude
                .tabItem { Label("Claude Code", systemImage: "asterisk") }
            data
                .tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 480, height: 560)
    }

    private var general: some View {
        Form {
            Section("Menu Bar") {
                Toggle("Show service marks", isOn: Binding(
                    get: { store.showMarks },
                    set: { store.showMarks = $0 }
                ))
                if store.installed.isEmpty {
                    Text("No supported CLIs installed.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.installed, id: \.self) { service in
                        Toggle(service.displayName, isOn: Binding(
                            get: { store.isVisibleInMenuBar(service) },
                            set: { store.setVisible(service, $0) }
                        ))
                    }
                }
            }

            Section("Refresh") {
                Picker("Check for updates", selection: Binding(
                    get: { store.refreshInterval },
                    set: { store.refreshInterval = $0 }
                )) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                Text("Claude backs off to at least 20 minutes; Antigravity and Grok to at least 5.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                ))
                Text("Requires the app to live in /Applications or ~/Applications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Command Code") {
                Picker("Plan", selection: Binding(
                    get: { store.commandCodePlan?.rawValue ?? "none" },
                    set: { raw in
                        store.commandCodePlan = raw == "none" ? nil : CommandCodePlan(rawValue: raw)
                    }
                )) {
                    Text("Not set").tag("none")
                    ForEach(CommandCodePlan.allCases, id: \.rawValue) { plan in
                        Text(plan.title).tag(plan.rawValue)
                    }
                }
                Text("Only used to turn local session spend into an estimated percentage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var claude: some View {
        Form {
            Section("Live limits from Claude Code") {
                Text("Claude Code's headless /usage may omit plan windows. Add this to ~/.claude/settings.json to feed live percentages and reset times to this app:")
                    .fixedSize(horizontal: false, vertical: true)
                Text(statuslineSnippet)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                HStack {
                    Button("Copy snippet") { copySnippet() }
                    Spacer()
                }
                Text("This replaces any existing statusLine. The app never edits your settings, and the helper stores only percentages and reset times.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var data: some View {
        Form {
            Section("Readings") {
                Button("Refresh now") { store.refreshNow() }
                Button("Clear cached readings") { store.clearCache() }
                Text("Cache: ~/Library/Caches/usage-tracker")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("The app never reads credentials. It asks installed CLIs and reads their documented local usage files. Codex, Antigravity and Grok run inside a sandbox; no API keys or SSH agent are passed to them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var statuslineSnippet: String {
        let raw = Bundle.main.executablePath ?? "/Applications/UsageTracker.app/Contents/MacOS/UsageTracker"
        let path = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        "statusLine": {
          "type": "command",
          "command": "\(path) --statusline",
          "refreshInterval": 60
        }
        """
    }

    private func copySnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(statuslineSnippet, forType: .string)
    }
}
