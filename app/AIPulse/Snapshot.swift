import AppKit
import SwiftUI

/// Debug/docs helper: render the real popover offscreen to a PNG, then quit.
///   AIPulse --snapshot out.png [--dark] [--search "query"] [--category Research]
/// No screen-recording permission needed (it draws the view hierarchy itself).
@MainActor
enum Snapshot {
    static var requested: Bool { CommandLine.arguments.contains("--snapshot") }

    static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func run(store: FeedStore, settings: AppSettings) {
        guard let out = arg("--snapshot") else { return }
        let dark = CommandLine.arguments.contains("--dark")
        let state = PopoverState()
        state.query = arg("--search") ?? ""
        state.category = arg("--category").flatMap(DigestCategory.init(rawValue:))
        if CommandLine.arguments.contains("--more") { state.showMore = true }
        state.selectedDate = arg("--date")

        let root = PopoverView(initialState: state)
            .environmentObject(store)
            .environmentObject(settings)
            .background(.background)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))  // offscreen
        window.orderFrontRegardless()

        Task { @MainActor in
            if store.days.isEmpty { await store.refresh() }
            try? await Task.sleep(for: .seconds(1.5))           // let layout + async loads settle
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            print("snapshot → \(out)")
            exit(0)
        }
    }
}
