#if canImport(SwiftUI) && os(macOS)
import SwiftUI
import UsageCore

@MainActor
struct ProviderCard: View {
    var store: UsageStore
    var provider: ProviderID
    var period: ActivityPeriod
    var onRefresh: () -> Void

    private var snapshot: UsageSnapshot? { store.snapshot(for: provider) }
    private var summary: ActivitySummary { store.summary(for: provider, period: period) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            if let snapshot {
                if let scope = snapshot.accountScope, !scope.isEmpty {
                    Text(scope)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                quotaSection(for: snapshot)
                activitySection
                modelSection
                noteSection(for: snapshot)
            } else {
                Text("Waiting for the first refresh…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var headerRow: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(provider.displayName)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Refresh \(provider.displayName)")
            .disabled(store.refreshing.contains(provider))
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }

    @ViewBuilder
    private func quotaSection(for snapshot: UsageSnapshot) -> some View {
        if !snapshot.quotas.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(snapshot.quotas) { window in
                    QuotaRow(window: window)
                }
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 3) {
            if summary.isEmpty {
                Text("No local activity recorded \(period.displayName.lowercased()).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Text(period.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Format.tokens(summary.tokens.total)) tokens")
                        .font(.caption.weight(.medium))
                    Spacer()
                    costView
                }
                if summary.hasIncompleteTokenData {
                    Text("Some sessions did not report token counts.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var costView: some View {
        switch summary.reportedCostUSD {
        case .available(let value):
            Text("\(Format.usd(value)) reported")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unavailable:
            switch summary.estimatedCostUSD {
            case .available(let value):
                Text("\(Format.usd(value)) est.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("API-equivalent estimate, not a billed amount.")
            case .unavailable:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        if summary.models.count > 1 || (summary.models.count == 1 && summary.models[0].model != "Unknown model") {
            DisclosureGroup("Models (\(summary.models.count))") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(summary.models.prefix(6), id: \.id) { model in
                        HStack(spacing: 6) {
                            Text(model.model)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(Format.tokens(model.tokens.total))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 3)
            }
            .font(.caption2)
        }
    }

    @ViewBuilder
    private func noteSection(for snapshot: UsageSnapshot) -> some View {
        if !snapshot.notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(snapshot.notes.indices, id: \.self) { index in
                    noteRow(snapshot.notes[index])
                }
            }
        }
    }

    private func noteRow(_ note: MetricNote) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(note.message)
                .font(.caption2)
                .foregroundStyle(noteColor(note.kind))
            if let recovery = note.recovery {
                Text(recovery)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let url = note.actionURL {
                Link("Open", destination: url)
                    .font(.caption2)
            }
        }
    }

    private var statusText: String {
        guard let snapshot else { return "Loading" }
        switch snapshot.status {
        case .loading: return "Loading"
        case .ok: return "Live"
        case .empty: return "No data"
        case .notConfigured: return "Not found"
        case .unsupported: return "Unavailable"
        case .stale: return "Stale"
        case .error: return "Error"
        }
    }

    private var statusColor: Color {
        guard let snapshot else { return .secondary }
        switch snapshot.status {
        case .loading: return .secondary
        case .ok: return .green
        case .empty: return .secondary
        case .notConfigured: return .orange
        case .unsupported: return .secondary
        case .stale: return .yellow
        case .error: return .red
        }
    }

    private func noteColor(_ kind: MetricNoteKind) -> Color {
        switch kind {
        case .error: return .red
        case .stale: return .orange
        case .unavailable, .unsupported: return .secondary
        case .info: return .secondary
        }
    }
}

struct QuotaRow: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(window.label)
                    .font(.caption)
                Spacer()
                Text("\(Format.percent(window.usedPercent)) used")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            QuotaBar(fraction: window.usedPercent / 100, tint: tint)
            if let resetsAt = window.resetsAt {
                Text(resetText(resetsAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tint: Color {
        if window.usedPercent >= 90 { return .red }
        if window.usedPercent >= 70 { return .orange }
        return .accentColor
    }

    private func resetText(_ date: Date) -> String {
        if date <= Date() { return "Window has reset" }
        return "Resets \(Format.countdown(to: date))"
    }
}

struct QuotaBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: CGFloat(max(0, min(1, fraction))) * proxy.size.width)
            }
        }
        .frame(height: 5)
    }
}
#endif
