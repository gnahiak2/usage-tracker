#if canImport(SwiftUI) && os(macOS)
import AppKit
import SwiftUI
import UsageCore

@MainActor
struct SettingsView: View {
    var model: AppModel

    @State private var commandCodePath = ""
    @State private var codexPath = ""
    @State private var refreshInterval: Double = 20
    @State private var didLoad = false
    @State private var statusMessage: String?

    private let preferredIntervals: [Double] = [10, 20, 30, 60, 300]

    var body: some View {
        Form {
            Section("Local data sources") {
                pathRow(
                    title: "Command Code sessions folder",
                    text: $commandCodePath,
                    defaultPath: CommandCodeProvider.defaultRoot.path,
                    startingAt: commandCodePath
                )
                pathRow(
                    title: "Codex sessions folder",
                    text: $codexPath,
                    defaultPath: CodexProvider.defaultRoot.path,
                    startingAt: codexPath
                )
                Text("Leave a path empty to use the default location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Refresh") {
                Picker("Local refresh interval", selection: $refreshInterval) {
                    ForEach(intervalChoices, id: \.self) { interval in
                        Text(Format.interval(interval)).tag(interval)
                    }
                }
                Text("Provider quota snapshots refresh at their own cadence; this interval only controls how often local session files are scanned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cache") {
                if let location = model.store.cacheLocation {
                    LabeledContent("Cache file") {
                        Text(location.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("The cache is created after the first refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Reveal in Finder") { revealCache() }
                        .disabled(model.store.cacheLocation == nil)
                    Button("Clear cache", role: .destructive) {
                        model.clearCache()
                        statusMessage = "Cache cleared. Refreshing…"
                    }
                }
            }

            Section {
                HStack {
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Apply") {
                        Task { await apply() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 430)
        .task { await loadIfNeeded() }
    }

    private var intervalChoices: [Double] {
        preferredIntervals.contains(refreshInterval)
            ? preferredIntervals
            : (preferredIntervals + [refreshInterval]).sorted()
    }

    private func pathRow(
        title: String,
        text: Binding<String>,
        defaultPath: String,
        startingAt currentPath: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(defaultPath, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("Choose…") {
                    if let chosen = chooseFolder(startingAt: currentPath) {
                        text.wrappedValue = chosen
                    }
                }
                Button("Default") {
                    text.wrappedValue = ""
                }
                .disabled(text.wrappedValue.isEmpty)
            }
            if let warning = pathWarning(for: text.wrappedValue) {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func pathWarning(for path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            return "Folder not found. The provider will show as unavailable."
        }
        if !isDirectory.boolValue {
            return "This path is a file, not a folder."
        }
        return nil
    }

    private func chooseFolder(startingAt path: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"

        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            panel.directoryURL = URL(
                fileURLWithPath: (trimmed as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        commandCodePath = model.settings.commandCodeRoot
        codexPath = model.settings.codexRoot
        refreshInterval = model.settings.refreshInterval
    }

    private func apply() async {
        statusMessage = nil
        await model.applySettings(
            commandCodeRoot: commandCodePath,
            codexRoot: codexPath,
            refreshInterval: refreshInterval
        )
        statusMessage = "Applied."
    }

    private func revealCache() {
        guard let url = model.store.cacheLocation else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
#endif
