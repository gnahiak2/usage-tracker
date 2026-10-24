import AppKit
import SwiftUI
import UsageCore

struct PanelView: View {
    @ObservedObject var store: Store
    @Environment(\.previewRendering) private var previewRendering

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                header(now: context.date)
                Divider()
                if previewRendering {
                    sections(now: context.date)
                } else {
                    ScrollView {
                        sections(now: context.date)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: scrollHeight)
                }
                Divider()
                if store.installed.contains(.commandCode) {
                    planPicker
                    Divider()
                }
                footer
            }
            .frame(width: 340)
        }
        .onAppear { store.refreshIfStale() }
    }

    private func sections(now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(store.installed, id: \.self) { service in
                ServiceSection(service: service,
                               snapshot: store.snapshots[service],
                               busy: store.busy.contains(service),
                               now: now)
                Divider()
            }
            if !store.missing.isEmpty {
                MissingSection(services: store.missing)
                Divider()
            }
        }
    }

    private var scrollHeight: CGFloat {
        var height: CGFloat = 0
        for service in store.installed {
            height += 64
            guard let snapshot = store.snapshots[service] else {
                height += 30
                continue
            }
            height += CGFloat(snapshot.windows.count) * 50
            height += CGFloat(snapshot.notes.count) * 15
            if snapshot.state == .signedOut { height += 22 }
            if snapshot.error != nil { height += 18 }
            if snapshot.actionTitle != nil { height += 22 }
        }
        if !store.missing.isEmpty { height += 42 }
        return min(560, max(150, height))
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 6) {
            Text("Usage Tracker")
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.2)
            Spacer()
            if store.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                    .frame(width: 12, height: 12)
            }
            Text(updatedText(now))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func updatedText(_ now: Date) -> String {
        let dates = store.installed.compactMap { store.snapshots[$0]?.measuredAt }
        guard let newest = dates.max() else { return "not read yet" }
        return "updated " + ageText(newest, now: now)
    }

    private var planPicker: some View {
        HStack {
            Text("Command Code plan").font(.system(size: 12))
            Spacer()
            if previewRendering {
                planLabel
            } else {
                Menu {
                    Button("Not set") { store.commandCodePlan = nil }
                    Divider()
                    ForEach(CommandCodePlan.allCases, id: \.rawValue) { plan in
                        Button(plan.title) { store.commandCodePlan = plan }
                    }
                } label: {
                    planLabel
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var planLabel: some View {
        HStack(spacing: 4) {
            Text(store.commandCodePlan?.title ?? "Not set")
                .font(.system(size: 11))
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
    }

    private var footer: some View {
        HStack(spacing: 7) {
            FooterButton(title: store.isBusy ? "Refreshing…" : "Refresh") {
                store.refreshNow()
            }
            .disabled(store.isBusy)
            Spacer()
            Text("Launch at Login").font(.system(size: 11))
            LaunchAtLoginToggle(store: store)
            Spacer()
            SettingsButton()
            Spacer()
            FooterButton(title: "Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct ServiceSection: View {
    let service: Service
    let snapshot: Snapshot?
    let busy: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                mark
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(-0.2)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(age)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }

            let windows = snapshot?.windows ?? []
            ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                WindowRow(window: window, service: service, primary: index == 0)
                    .padding(.top, 9)
            }

            if snapshot?.state == .signedOut {
                Text("Signed out — \(service.loginHint)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            } else if windows.isEmpty {
                Text(busy ? "Reading…" : (snapshot?.state == .missing ? "Not installed" : "No reading yet"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }

            if let error = snapshot?.error, snapshot?.state != .ok {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
            }

            ForEach(snapshot?.notes ?? [], id: \.self) { note in
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            }

            if let title = snapshot?.actionTitle, let raw = snapshot?.actionURL, let url = URL(string: raw) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 3) {
                        Text(title)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .padding(.top, 7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(snapshot?.isStale(now: now) == true && !(snapshot?.windows.isEmpty ?? true) ? 0.62 : 1)
    }

    private var mark: some View {
        Image(systemName: service.symbol)
            .font(.system(size: 13, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(ServiceTint.color(service))
            .frame(width: 18, height: 18)
    }

    private var subtitle: String {
        let plan = snapshot?.plan ?? ""
        return plan.isEmpty ? service.product : "\(service.product) · \(plan)"
    }

    private var age: String {
        if busy && snapshot?.measuredAt == nil { return "reading…" }
        guard let measured = snapshot?.measuredAt else { return "" }
        return "updated " + ageText(measured, now: now)
    }
}

private struct WindowRow: View {
    let window: LimitWindow
    let service: Service
    let primary: Bool

    var body: some View {
        let due = window.resetPassed
        let hot = !due && (window.used ?? 0) >= 90
        let value = valueText
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.system(size: primary ? 12 : 11.5, weight: primary ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: primary ? 13 : 12,
                                  weight: hot ? .bold : primary ? .semibold : .medium,
                                  design: .monospaced))
                    .foregroundStyle(hot ? Color.red : Color.primary)
            }
            if due {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 4)
            } else {
                Track(fraction: (window.used ?? 0) / 100, service: service, hot: hot)
            }
            HStack(spacing: 4) {
                Text(resetLabel(due))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                if window.estimated {
                    Text("est.").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
                if window.used != nil, let detail = window.detail {
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.label), \(value), \(resetLabel(due))")
    }

    private var valueText: String {
        if window.resetPassed { return "—" }
        if let used = window.used { return "\(percentText(used))%" }
        return window.detail ?? "—"
    }

    private func resetLabel(_ due: Bool) -> String {
        if due { return "reset, awaiting update" }
        let kind = service == .grok ? "ends" : "resets"
        return resetText(window.resetsAt, kind: kind)
    }
}

private struct Track: View {
    let fraction: Double
    let service: Service
    let hot: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.13))
                Capsule()
                    .fill(hot ? AnyShapeStyle(Color.red) : ServiceTint.style(service))
                    .frame(width: max(fraction > 0 ? 3 : 0,
                                      geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }
}

private struct MissingSection: View {
    let services: [Service]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Not installed")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(services.map { "\($0.displayName) (\($0.product))" }.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11.5))
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct LaunchAtLoginToggle: View {
    @ObservedObject var store: Store

    var body: some View {
        let enabled = store.launchAtLogin
        Button {
            store.setLaunchAtLogin(!enabled)
        } label: {
            Capsule()
                .fill(enabled ? Color.accentColor : Color.primary.opacity(0.18))
                .frame(width: 26, height: 15)
                .overlay(alignment: enabled ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 11, height: 11)
                        .padding(2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Launch at login")
        .accessibilityValue(enabled ? "on" : "off")
    }
}

struct PreviewRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var previewRendering: Bool {
        get { self[PreviewRenderingKey.self] }
        set { self[PreviewRenderingKey.self] = newValue }
    }
}

enum ServiceTint {
    static func color(_ service: Service) -> Color {
        switch service {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .gemini: return Color(red: 0.42, green: 0.55, blue: 0.95)
        case .commandCode: return Color(red: 0.20, green: 0.62, blue: 0.53)
        case .codex, .grok: return .primary
        }
    }

    static func style(_ service: Service) -> AnyShapeStyle {
        if service == .gemini {
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.24, green: 0.55, blue: 1.0),
                         Color(red: 0.69, green: 0.42, blue: 0.86)],
                startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(color(service).opacity(service == .codex || service == .grok ? 0.65 : 1))
    }
}
