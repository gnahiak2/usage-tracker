import SwiftUI
import UsageCore

struct TrayLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 9) {
            if visible.isEmpty {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 13, weight: .medium))
            } else {
                ForEach(visible, id: \.self) { service in
                    HStack(spacing: store.showMarks ? 3 : 0) {
                        if store.showMarks {
                            Image(systemName: service.symbol)
                                .font(.system(size: 11, weight: .medium))
                                .symbolRenderingMode(.monochrome)
                        }
                        digit(for: service)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel(service))
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .fixedSize()
    }

    private var visible: [Service] {
        store.installed.filter { store.isVisibleInMenuBar($0) }
    }

    @ViewBuilder
    private func digit(for service: Service) -> some View {
        let snapshot = store.snapshots[service]
        if let window = snapshot?.bar, let used = window.used, !window.resetPassed {
            let hot = used >= 90
            text(used: used, weekly: window.short == "w", hot: hot,
                 bang: snapshot?.otherHot ?? false)
                .foregroundStyle(hot ? Color.red : Color.primary)
                .opacity((snapshot?.isStale() ?? true) ? 0.5 : 1)
        } else if let text = snapshot?.menuText, snapshot?.state == .ok {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .opacity((snapshot?.isStale() ?? true) ? 0.5 : 1)
        } else {
            Text("—")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func text(used: Double, weekly: Bool, hot: Bool, bang: Bool) -> Text {
        var value = Text(percentText(used))
            .font(.system(size: 13, weight: hot ? .semibold : .regular, design: .monospaced))
        if weekly || bang || hot {
            var suffix = Text(weekly ? "w" : "").font(.system(size: 8.5, weight: .medium))
            if bang || hot { suffix = suffix + Text("!").font(.system(size: 8.5, weight: .heavy)) }
            value = value + suffix.baselineOffset(5)
        }
        return value
    }

    private func accessibilityLabel(_ service: Service) -> String {
        guard let snapshot = store.snapshots[service] else {
            return "\(service.displayName), no reading"
        }
        if let window = snapshot.bar, let used = window.used {
            return "\(service.displayName), \(window.label), \(percentText(used)) percent used"
        }
        return "\(service.displayName), \(snapshot.menuText ?? "no reading")"
    }
}
