import Foundation

/// The app's single source of truth: cached days + refresh/catch-up logic.
@MainActor
final class FeedStore: ObservableObject {
    @Published private(set) var days: [String: DayDigest] = [:]
    @Published private(set) var index: FeedIndex?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var lastError: String?

    var feedURL: String { didSet { if oldValue != feedURL { resetForNewFeed() } } }
    private var cache: DayCache
    var onDaysChanged: (() -> Void)?

    init(feedURL: String, cache: DayCache? = nil) {
        self.feedURL = feedURL
        self.cache = cache ?? DayCache(dir: FeedStore.cacheDirectory(for: feedURL))
        index = self.cache.loadIndex()
        days = self.cache.loadAll()
    }

    /// Newest first: every day we know about (from the index or the cache).
    var availableDates: [String] {
        Set(days.keys).union(index?.days.map(\.date) ?? []).filter(FeedSafety.isDayKey).sorted(by: >)
    }

    var latestDate: String? { availableDates.first }

    func digest(for date: String) -> DayDigest? { days[date] }

    /// Fetch index.json, then every day that's new or changed since we cached it.
    /// That's how missed days (laptop asleep / off) are caught up after wake.
    func refresh() async {
        guard !isRefreshing else { return }
        guard let client = FeedClient(feedURL: feedURL) else {
            lastError = FeedError.badURL.localizedDescription
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let idx = try await client.index()
            var changed = false
            for entry in idx.days.filter({ FeedSafety.isDayKey($0.date) }).prefix(FeedConfig.catchUpDays) {
                let cached = days[entry.date]
                if let cached, let v = entry.generatedAt, cached.generatedAt == v { continue }
                do {
                    let day = try await client.day(entry.date, version: entry.generatedAt)
                    try? cache.save(day)
                    days[day.date] = day
                    changed = true
                } catch {
                    lastError = "Couldn't load \(entry.date): \(error.localizedDescription)"
                }
            }
            index = idx
            try? cache.save(idx)
            lastRefresh = Date()
            if lastError?.hasPrefix("Couldn't load") != true { lastError = nil }
            if changed { onDaysChanged?() }
        } catch {
            lastError = (error as? URLError)?.code == .notConnectedToInternet
                ? "Offline — showing saved days." : error.localizedDescription
        }
    }

    /// Load an older day on demand (beyond the catch-up window).
    func ensureLoaded(_ date: String) async {
        guard days[date] == nil, let client = FeedClient(feedURL: feedURL) else { return }
        let version = index?.days.first { $0.date == date }?.generatedAt
        if let day = try? await client.day(date, version: version) {
            try? cache.save(day)
            days[date] = day
        }
    }

    /// A different feed is a different dataset, so each feed URL gets its own cache folder.
    nonisolated static func cacheDirectory(for feedURL: String) -> URL {
        let base = DayCache.defaultDirectory()
        if feedURL == FeedConfig.defaultFeedURL { return base }
        // Stable FNV-1a hash (Swift's hashValue is randomized per launch).
        let key = String(feedURL.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 },
                         radix: 36)
        return base.deletingLastPathComponent().appendingPathComponent("Feed-\(key)")
    }

    private func resetForNewFeed() {
        cache = DayCache(dir: FeedStore.cacheDirectory(for: feedURL))
        index = self.cache.loadIndex()
        days = self.cache.loadAll()
        lastRefresh = nil
        Task { await refresh() }
    }

    // MARK: Search across every cached day

    struct SearchHit: Identifiable, Hashable {
        let date: String
        let item: DigestItem
        var id: String { "\(date)|\(item.id)" }
    }

    func search(_ query: String, category: DigestCategory?) -> [SearchHit] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        var hits: [SearchHit] = []
        for date in days.keys.sorted(by: >) {
            for item in days[date]?.items ?? [] {
                if let category, item.category != category { continue }
                let hay = "\(item.title) \(item.summary) \(item.whyItMatters) \(Display.source(item.source))".lowercased()
                if terms.allSatisfy(hay.contains) { hits.append(SearchHit(date: date, item: item)) }
            }
        }
        return Array(hits.prefix(150))
    }
}
