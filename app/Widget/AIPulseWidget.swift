import SwiftUI
import WidgetKit

// The widget is its own sandboxed process. Without an App Group (which needs a paid
// developer account) it can't read the app's cache, so it fetches latest.json itself
// and keeps its own offline copy. It reads the app's chosen feed URL through a
// read-only preference exception (see Widget.entitlements).

let appBundleID = "io.github.turdiyevislombek.aipulse"

struct DigestEntry: TimelineEntry {
    let date: Date
    let digest: DayDigest?
    var isSample = false
}

struct DigestProvider: TimelineProvider {
    private var feedURL: String {
        UserDefaults(suiteName: appBundleID)?.string(forKey: "feedURL") ?? FeedConfig.defaultFeedURL
    }

    private var cache: DayCache { DayCache() }

    private func cachedLatest() -> DayDigest? {
        cache.dates().first.flatMap(cache.load)
    }

    func placeholder(in context: Context) -> DigestEntry {
        DigestEntry(date: .now, digest: SampleDigest.day, isSample: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (DigestEntry) -> Void) {
        // The gallery preview: real data if we have it, otherwise the sample.
        if let day = cachedLatest() {
            completion(DigestEntry(date: .now, digest: day))
        } else {
            completion(DigestEntry(date: .now, digest: SampleDigest.day, isSample: true))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DigestEntry>) -> Void) {
        nonisolated(unsafe) let done = completion
        let url = feedURL
        Task {
            var day: DayDigest?
            if let client = FeedClient(feedURL: url) {
                day = try? await client.latest()
                if let day { try? cache.save(day) }
            }
            let entry = DigestEntry(date: .now, digest: day ?? cachedLatest())
            // Hourly is well inside WidgetKit's daily refresh budget; the app also
            // asks for a reload whenever it sees new data.
            let next = Date.now.addingTimeInterval(day == nil ? 20 * 60 : 60 * 60)
            done(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct AIPulseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AIPulseDigest", provider: DigestProvider()) { entry in
            DigestWidgetView(entry: entry)
        }
        .configurationDisplayName("AI Pulse")
        .description("Today's AI research, releases and news, summarized.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

/// Shown in the gallery before the first download, and as the loading placeholder.
enum SampleDigest {
    static let day: DayDigest? = {
        let json = #"""
        {"schema_version":1,"date":"2026-11-23","generated_at":"2026-11-23T18:00:00Z",
         "headline":"New open models, faster training recipes and a busy day for agent research.",
         "items":[
          {"id":"1","title":"A new open-weights model for coding","url":"https://example.com/1","source":"hn","category":"Model release","summary":"","why_it_matters":"","score":5,"signals":{"hn_points":850},"published_at":"2026-11-23T12:00:00Z","summary_status":"done"},
          {"id":"2","title":"Cheaper long-context attention","url":"https://example.com/2","source":"hf_papers","category":"Research","summary":"","why_it_matters":"","score":4,"signals":{"hf_upvotes":84},"published_at":"2026-11-23T10:00:00Z","summary_status":"done"},
          {"id":"3","title":"A training recipe for small reasoning models","url":"https://example.com/3","source":"hf_papers","category":"Training method","summary":"","why_it_matters":"","score":4,"signals":{"hf_upvotes":53},"published_at":"2026-11-23T09:00:00Z","summary_status":"done"},
          {"id":"4","title":"An open-source agent framework","url":"https://example.com/4","source":"github","category":"Tool / Open source","summary":"","why_it_matters":"","score":3,"signals":{"github_stars":3000},"published_at":"2026-11-23T08:00:00Z","summary_status":"done"},
          {"id":"5","title":"A lab announces new data-center plans","url":"https://example.com/5","source":"hn","category":"Industry","summary":"","why_it_matters":"","score":3,"signals":{"hn_points":600},"published_at":"2026-11-23T07:00:00Z","summary_status":"done"},
          {"id":"6","title":"Benchmarking spatial memory in agents","url":"https://example.com/6","source":"hf_papers","category":"Research","summary":"","why_it_matters":"","score":3,"signals":{"hf_upvotes":21},"published_at":"2026-11-23T06:00:00Z","summary_status":"done"}
         ],"more":[]}
        """#
        return try? FeedJSON.decoder().decode(DayDigest.self, from: Data(json.utf8))
    }()
}
