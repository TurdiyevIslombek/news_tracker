import AppKit
import SwiftUI
import WidgetKit

// Renders the widget views offscreen at their real sizes, for layout checks and docs:
//   app/scripts/widget-snapshot.sh OUT_DIR
@main
struct WidgetSnapshotTool {
    @MainActor static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let day = (try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            .flatMap { try? FeedJSON.decoder().decode(DayDigest.self, from: $0) }
        let entry = DigestEntry(date: Date(), digest: day)
        // Widget sizes differ by Mac/display; check the big and the compact variants.
        let sizes: [(WidgetFamily, String, CGSize)] = [
            (.systemSmall, "small", CGSize(width: 170, height: 170)),
            (.systemSmall, "small-compact", CGSize(width: 158, height: 158)),
            (.systemMedium, "medium", CGSize(width: 364, height: 170)),
            (.systemMedium, "medium-compact", CGSize(width: 338, height: 158)),
            (.systemLarge, "large", CGSize(width: 364, height: 382)),
            (.systemLarge, "large-compact", CGSize(width: 344, height: 344)),
        ]
        _ = NSApplication.shared
        for dark in [false, true] {
            for (family, name, size) in sizes {
                let view = DigestWidgetView(entry: entry, familyOverride: family)
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(12)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: size.width + 24, height: size.height + 24)
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                win.contentView = host
                host.layoutSubtreeIfNeeded()
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                let file = out.appendingPathComponent("widget-\(name)\(dark ? "-dark" : "").png")
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
                print("→ \(file.path)")
            }
        }
    }
}
