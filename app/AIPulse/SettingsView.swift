import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: FeedStore
    @StateObject private var draft = TextBox()
    private var draftURL: String { draft.text }

    var body: some View {
        Form {
            Section {
                TextField("Feed URL", text: $draft.text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(apply)
                HStack {
                    Button("Use default feed") {
                        settings.resetFeedURL()
                        draft.text = settings.feedURL
                    }
                    .disabled(settings.feedURL == FeedConfig.defaultFeedURL)
                    Spacer()
                    Button("Apply", action: apply)
                        .keyboardShortcut(.defaultAction)
                        .disabled(draftURL == settings.feedURL)
                }
            } header: {
                Text("Feed")
            } footer: {
                Text("Point this at your own fork's GitHub Pages URL to run your own feed.")
                    .foregroundStyle(.secondary)
            }

            Section("Refresh") {
                Picker("Check for new items every", selection: $settings.refreshHours) {
                    ForEach([1, 2, 3, 6], id: \.self) { Text($0 == 1 ? "hour" : "\($0) hours").tag($0) }
                }
                Text("AI Pulse also refreshes on launch and when your Mac wakes up, and catches up on any days it missed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                if let note = settings.launchAtLoginNote {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            draft.text = settings.feedURL
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func apply() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FeedClient(feedURL: trimmed) != nil else { return }
        settings.feedURL = trimmed
    }
}
