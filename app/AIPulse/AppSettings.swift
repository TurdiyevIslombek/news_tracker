import Foundation
import ServiceManagement

/// The only three settings: feed URL, refresh interval, launch at login.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard
    var onFeedURLChange: ((String) -> Void)?

    @Published var feedURL: String {
        didSet {
            defaults.set(feedURL, forKey: "feedURL")
            if oldValue != feedURL { onFeedURLChange?(feedURL) }
        }
    }

    /// Hours between refreshes (1–6). The app also refreshes on launch and wake.
    @Published var refreshHours: Int {
        didSet { defaults.set(refreshHours, forKey: "refreshHours") }
    }

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var launchAtLoginNote: String?

    init() {
        feedURL = defaults.string(forKey: "feedURL") ?? FeedConfig.defaultFeedURL
        let h = defaults.integer(forKey: "refreshHours")
        refreshHours = (1...6).contains(h) ? h : 2
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginNote = SMAppService.mainApp.status == .requiresApproval
                ? "Approve AI Pulse in System Settings → General → Login Items." : nil
        } catch {
            launchAtLoginNote = "Couldn't change login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func resetFeedURL() { feedURL = FeedConfig.defaultFeedURL }
}
