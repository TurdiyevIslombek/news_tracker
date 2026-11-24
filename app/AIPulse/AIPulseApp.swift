import AppKit
import SwiftUI
import WidgetKit

@main
struct AIPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate.settings)
        } label: {
            Image(systemName: "sparkles.rectangle.stack")
                .accessibilityLabel("AI Pulse")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.store)
                .environmentObject(appDelegate.settings)
        }
    }
}

/// Owns the store and the refresh schedule: on launch, on wake, and every N hours.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    lazy var store = FeedStore(feedURL: settings.feedURL)
    private var ticker: Timer?
    private var lastAttempt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Snapshot.requested { Snapshot.run(store: store, settings: settings); return }
        settings.onFeedURLChange = { [weak self] url in
            self?.store.feedURL = url
            WidgetCenter.shared.reloadAllTimelines()   // the widget reads the same setting
        }
        // New or updated days: let the widget fetch them now instead of on its next hourly tick.
        store.onDaysChanged = { WidgetCenter.shared.reloadAllTimelines() }
        Task { await refresh() }

        // Waking from sleep: give Wi-Fi a moment, then catch up on missed days.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                await self?.refresh()
            }
        }

        // Check every 10 minutes; refresh when the interval has passed, or sooner
        // if the last attempt failed (e.g. no network yet).
        ticker = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        let interval = TimeInterval(settings.refreshHours * 3600)
        let last = store.lastRefresh ?? .distantPast
        let failedRecently = store.lastError != nil && Date().timeIntervalSince(lastAttempt ?? .distantPast) > 600
        if Date().timeIntervalSince(last) >= interval || failedRecently {
            Task { await refresh() }
        }
    }

    func refresh() async {
        lastAttempt = Date()
        await store.refresh()
    }

    // MARK: aipulse:// links (the widget header opens the app)

    // SwiftUI's scene machinery swallows URL events before the delegate's
    // application(_:open:) sees them, so take the "open URL" Apple Event directly.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              URL(string: s)?.scheme == "aipulse" else { return }
        // If the link is what launched us, give the status item a moment to appear.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.showPopover() }
    }

    /// SwiftUI's MenuBarExtra has no "open" API; clicking its status item does the same thing.
    static func showPopover() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let button = Self.findStatusButton(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
        NSLog("AIPulse: status item not found; windows=%@", NSApp.windows.map(\.className).joined(separator: ","))
    }

    private static func findStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let b = view as? NSStatusBarButton { return b }
        for sub in view.subviews { if let b = findStatusButton(in: sub) { return b } }
        return nil
    }
}
