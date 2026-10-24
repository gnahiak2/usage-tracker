import AppKit
import SwiftUI
import UsageCore

enum Preview {
    @MainActor
    static func render(to path: String) {
        let store = Store(preview: fixtures(), installed: Service.allCases)
        let content = PanelView(store: store)
            .environment(\.previewRendering, true)
            .frame(width: 340)
            .background(Color(nsColor: .windowBackgroundColor))
        write(content, to: path)
    }

    @MainActor
    static func renderTray(to path: String) {
        let store = Store(preview: fixtures(), installed: Service.allCases)
        let content = TrayLabel(store: store)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        write(content, to: path)
    }

    @MainActor
    private static func write<Content: View>(_ content: Content, to path: String) {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("could not render preview\n".utf8))
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }

    static func fixtures(now: Date = Date()) -> [Service: Snapshot] {
        [
            .claude: Snapshot(
                service: .claude, plan: "Max",
                windows: [
                    LimitWindow(label: "5-hour", short: "5h", used: 23.5, resetsAt: now.addingTimeInterval(3 * 3600)),
                    LimitWindow(label: "Week", short: "w", used: 41.2, resetsAt: now.addingTimeInterval(2 * 86_400)),
                ],
                measuredAt: now.addingTimeInterval(-2 * 60)),
            .codex: Snapshot(
                service: .codex, plan: "ChatGPT Plus",
                windows: [
                    LimitWindow(label: "5-hour", short: "5h", used: 2, resetsAt: now.addingTimeInterval(4 * 3600)),
                    LimitWindow(label: "Week", short: "w", used: 1, resetsAt: now.addingTimeInterval(6 * 86_400)),
                ],
                notes: ["3 free full resets · next expires tomorrow 19:26"],
                measuredAt: now.addingTimeInterval(-2 * 60)),
            .gemini: Snapshot(
                service: .gemini,
                windows: [
                    LimitWindow(label: "Gemini · week", short: "w", used: 78, resetsAt: now.addingTimeInterval(2 * 86_400)),
                    LimitWindow(label: "Flash Pro · 5-hour", short: "5h", used: 0, resetsAt: now.addingTimeInterval(3 * 3600)),
                    LimitWindow(label: "Flash Pro · week", short: "w", used: 0, resetsAt: now.addingTimeInterval(5 * 86_400)),
                ],
                notes: ["Gemini 5-hour window disabled"],
                measuredAt: now.addingTimeInterval(-58)),
            .grok: Snapshot(service: .grok, state: .signedOut, measuredAt: now.addingTimeInterval(-30)),
            .commandCode: Snapshot(
                service: .commandCode, plan: "Pro",
                windows: [
                    LimitWindow(label: "5-hour spend", short: "5h", used: 53.25,
                                resetsAt: now.addingTimeInterval(2 * 3600),
                                detail: "$8.52", estimated: true),
                    LimitWindow(label: "Weekly spend", short: "w", used: 36.1,
                                resetsAt: now.addingTimeInterval(7 * 86_400),
                                detail: "$14.44", estimated: true),
                ],
                notes: ["Estimated from local session logs on this Mac",
                        "Compared with Pro caps: $16.00 / $40.00",
                        "This 5-hour window: 63,609,564 tokens"],
                measuredAt: now,
                actionTitle: "Open Studio usage",
                actionURL: "https://commandcode.ai/usage"),
        ]
    }
}
