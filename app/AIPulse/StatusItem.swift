import AppKit
import SwiftUI

/// The menu bar icon and its popover.
///
/// This is a plain NSStatusItem + NSPopover rather than SwiftUI's MenuBarExtra,
/// because MenuBarExtra can't be opened from code, and the widget needs exactly
/// that: clicking it (aipulse://open) must pop the digest open.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()

    init(store: FeedStore, settings: AppSettings) {
        super.init()
        if let button = item.button {
            let image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: "AI Pulse")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(toggle(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let root = PopoverView()
            .environmentObject(store)
            .environmentObject(settings)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 420, height: 620)
        popover.behavior = .transient          // closes when you click elsewhere, like a menu
        popover.animates = true
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    @objc private func toggle(_ sender: Any?) {
        popover.isShown ? popover.performClose(sender) : show()
    }

    func show() {
        guard let button = item.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)   // so the search field can take typing
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() { popover.performClose(nil) }
}

/// The Settings window, owned by AppKit so the popover's gear button can open it
/// (on macOS 14+ the old showSettingsWindow: action no longer opens SwiftUI's scene).
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let makeRoot: () -> AnyView

    init(store: FeedStore, settings: AppSettings) {
        makeRoot = { AnyView(SettingsView().environmentObject(store).environmentObject(settings)) }
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: makeRoot())
            let w = NSWindow(contentViewController: host)
            w.title = "AI Pulse Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
