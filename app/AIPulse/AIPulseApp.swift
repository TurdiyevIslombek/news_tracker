import AppKit
import OSLog
import SwiftUI
import WidgetKit

@main
struct AIPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The menu bar icon + popover live in StatusItemController (AppKit), so the
    // widget can open them; SwiftUI only provides the Settings window.
    var body: some Scene {
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
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Snapshot.requested { Snapshot.run(store: store, settings: settings); return }
        Self.shared = self
        statusItem = StatusItemController(store: store, settings: settings)
        settingsWindow = SettingsWindowController(store: store, settings: settings)
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

    // MARK: Links from the widget
    //
    // Third-party widgets don't open URLs themselves: WidgetKit hands every clicked
    // URL (our aipulse:// links *and* the stories' https links) to the containing
    // app. So the app opens story links in the browser and shows the popover for
    // aipulse://open.

    static let log = Logger(subsystem: "io.github.turdiyevislombek.aipulse", category: "links")

    // SwiftUI's scene machinery swallows URL events before the delegate's
    // application(_:open:) sees them, so take the "open URL" Apple Event directly.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue ?? ""
        Self.log.notice("URL event: \(s, privacy: .public)")
        if let url = URL(string: s) { handle(url) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Self.log.notice("application(open:) \(urls.map(\.absoluteString).joined(separator: " "), privacy: .public)")
        urls.forEach(handle)
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        Self.log.notice("user activity \(userActivity.activityType, privacy: .public) url=\(userActivity.webpageURL?.absoluteString ?? "-", privacy: .public)")
        if let url = userActivity.webpageURL { handle(url); return true }
        return false
    }

    private func handle(_ url: URL) {
        if url.scheme == "aipulse", url.host == "settings" {
            Self.openSettings()
        } else if url.scheme == "aipulse" {
            // If the link is what launched us, give the status item a moment to appear.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.showPopover() }
        } else if let web = FeedSafety.webURL(url.absoluteString) {
            NSWorkspace.shared.open(web)   // a story link: open it in the default browser
        }
    }

    static func openSettings() {
        shared?.statusItem?.close()
        shared?.settingsWindow?.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let titles = NSApp.windows.filter { $0.isVisible && !$0.title.isEmpty && $0.className != "NSStatusBarWindow" }.map(\.title)
            log.notice("visible app windows: \(titles.joined(separator: ", "), privacy: .public)")
        }
    }

    static func showPopover() {
        guard let controller = shared?.statusItem else {
            log.error("showPopover: no status item yet")
            return
        }
        controller.show()
        log.notice("popover shown: \(controller.isShown, privacy: .public)")
    }
}
