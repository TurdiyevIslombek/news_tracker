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

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "aipulse" }) else { return }
        // Let the launch finish if the link is what started us, then show the popover.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.showPopover() }
    }

    /// SwiftUI's MenuBarExtra has no "open" API; clicking its status item does the same thing.
    static func showPopover() {
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let button = window.contentView?.subviews.compactMap({ $0 as? NSStatusBarButton }).first
                ?? window.contentView as? NSStatusBarButton {
                button.performClick(nil)
                return
            }
        }
    }
}
