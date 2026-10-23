#if canImport(SwiftUI) && os(macOS)
import SwiftUI
import UsageCore

@MainActor
struct MenuContentView: View {
    var model: AppModel
    @State private var period: ActivityPeriod = .today

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            periodPicker
            Divider()
            providerList
            Divider()
            footer
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Usage Tracker")
                    .font(.headline)
                Text(lastRefreshText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button(action: model.refreshAll) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh all providers")
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isRefreshing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var lastRefreshText: String {
        guard let last = model.store.lastRefresh else { return "Waiting for first refresh" }
        return "Updated \(Format.relative(last))"
    }

    private var periodPicker: some View {
        Picker("Period", selection: $period) {
            ForEach(ActivityPeriod.allCases) { activityPeriod in
                Text(activityPeriod.displayName).tag(activityPeriod)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var providerList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(model.store.providerOrder) { provider in
                    ProviderCard(
                        store: model.store,
                        provider: provider,
                        period: period,
                        onRefresh: { model.refresh(provider: provider) }
                    )
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 430)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            SettingsLink {
                Text("Settings…")
            }
            .buttonStyle(.link)

            Spacer()

            Button("Quit", action: model.quit)
                .buttonStyle(.link)
                .keyboardShortcut("q", modifiers: .command)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
#endif
